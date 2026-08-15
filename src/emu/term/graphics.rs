//! Image transmission and placement: kitty (APC), sixel (DCS) and iTerm2 `OSC 1337`.
//!
//! Three producers, one pipeline: each ends at `intern_image` + `lay_image` and shares
//! everything downstream of "here are some pixels".

use super::*;

impl State {
    pub(super) fn place_image(
        &mut self,
        format: ImageFormat,
        bytes: &[u8],
        px: PixelSize,
    ) -> ImageId {
        let id = self.intern_image(format, bytes, px, None);
        self.lay_image(id);
        id
    }

    /// Take BYTES as an image and say what we will call it, without drawing anything.
    ///
    /// CELLS is the rectangle the child asked for, `None` when it did not say and the
    /// size should follow from the pixels. An empty `PX` is read out of the bytes where
    /// the format states its own size, which clients rely on: the protocol does not ask
    /// a PNG's sender to repeat dimensions the file already carries.
    pub(super) fn intern_image(
        &mut self,
        format: ImageFormat,
        bytes: &[u8],
        px: PixelSize,
        cells: Option<CellSize>,
    ) -> ImageId {
        let px = if px.is_empty() {
            png_dimensions(bytes).unwrap_or(px)
        } else {
            px
        };
        let metrics = self.metrics;
        let (id, fresh) = self.images.intern(format, bytes, px, metrics);
        // An explicit `c=`/`r=` overrides what the pixels imply: the child is saying how
        // much of the screen the picture should occupy, not how big its source is.
        //
        // `c=`/`r=` are already clamped to `u16::MAX` in `kitty::Command::parse`, but
        // that alone still lets a single tiny PNG transmission (the one format the
        // payload-vs-geometry check in `kitty::finish` does not apply to, since a PNG
        // carries no raw pixel count to check against) ask for up to 65535 rows.
        // `lay_image` does one real `linefeed` — with its own scroll-eviction and
        // scrollback-archival work — per row of `cells.1`, so an unclamped `r=` is a
        // way to force tens of thousands of those from one small APC before the reader
        // loop's own backlog backpressure ever gets a turn between reads. Capping here
        // bounds that to the same order of magnitude as a screenful of images, which is
        // already far more than any picture legitimately needs.
        let cells = match cells {
            Some(asked) => CellSize::new(
                asked.cols.clamp(1, MAX_IMAGE_CELL_SPAN),
                asked.rows.clamp(1, MAX_IMAGE_CELL_SPAN),
            ),
            // The child said nothing, so the pixels decide -- or one cell, if we have
            // not even got those.
            None => self
                .images
                .get(id)
                .map_or(CellSize::new(1, 1), |image| image.cells),
        };
        if fresh {
            self.pending_images.push(ImageData {
                id,
                format,
                bytes: bytes.to_vec(),
                px,
                cells,
            });
        }
        self.image_cells.insert(id, cells);
        id
    }

    /// `OSC 1337 ; File=<key>=<value>;... : <base64>` — iTerm2's inline image.
    ///
    /// A third producer of the same [`ImageData`], and the least structured of them: the
    /// payload is a *file*, with no field saying what kind, so the format and size come
    /// from sniffing the bytes. Only what Emacs decodes natively is accepted.
    ///
    /// `inline=1` is required. Without it the sequence means "download this to the
    /// user's machine", which is a file-writing capability a terminal emulator inside an
    /// editor has no business growing, and which is refused here by doing nothing.
    ///
    /// Semicolons separate the keys, which is also what separates OSC parameters, so the
    /// arguments arrive already split and are rejoined. That the payload's base64 alphabet
    /// contains no semicolon is what makes this safe.
    /// Returns whether this was an inline-image `File=`, handled or refused. `false`
    /// means it was some other `OSC 1337` and belongs to whoever else is listening.
    pub(super) fn iterm_file(&mut self, params: &[&[u8]]) -> bool {
        let mut joined = Vec::new();
        for (at, part) in params[1..].iter().enumerate() {
            if at != 0 {
                joined.push(b';');
            }
            joined.extend_from_slice(part);
        }
        // The colon separates the arguments from the payload, and only the first one
        // does: base64 has no colon in it.
        let colon = joined.iter().position(|&b| b == b':');
        let args = String::from_utf8_lossy(&joined[..colon.unwrap_or(joined.len())]).into_owned();
        let Some(args) = args.strip_prefix("File=") else {
            return false;
        };

        let mut inline = false;
        // What the child asked for, per axis. `None` on either means "work it out from
        // the pixels", which is also what a missing key means.
        let (mut cols, mut rows) = (None, None);
        for pair in args.split(';') {
            let Some((key, value)) = pair.split_once('=') else {
                continue;
            };
            match key {
                "inline" => inline = value != "0",
                // Sizes are in cells unless suffixed. `px` and `%` and `auto` are all
                // spelled here, and all of them mean "work it out from the pixels" —
                // which is what a missing key means too, so they need no case.
                "width" => cols = plain_cells(value),
                "height" => rows = plain_cells(value),
                _ => {}
            }
        }
        // Past this point it is an inline image or a malformed one, and either way it
        // is not somebody else's to handle.
        let Some(colon) = colon else {
            return true;
        };
        if !inline {
            return true;
        }
        let Some(bytes) = decode_base64(&joined[colon + 1..]) else {
            return true;
        };
        let Some((format, px)) = crate::emu::image::sniff(&bytes) else {
            return true;
        };
        // An axis the child named settles both: the other falls back to one cell, as it
        // did when the pair was a tuple with a zero in it.
        let cells = (cols.is_some() || rows.is_some())
            .then(|| CellSize::new(cols.unwrap_or(1), rows.unwrap_or(1)));
        let id = self.intern_image(format, &bytes, px, cells);
        self.lay_image(id);
        true
    }

    /// Lay an already-interned image into the grid at the cursor.
    pub(super) fn lay_image(&mut self, id: ImageId) {
        let cells = self
            .image_cells
            .get(&id)
            .copied()
            .unwrap_or(CellSize::new(1, 1));
        let pen = self.pen.erase();
        let start_col = self.screen().cursor.col;
        for cell_row in 0..cells.rows {
            self.screen_mut().cursor.col = start_col;
            self.screen_mut()
                .place_image_row(id, cell_row, cells.cols, pen);
            let evicted = self.screen_mut().linefeed(pen);
            self.evicted(evicted);
        }
        self.screen_mut().carriage_return();
    }

    /// `ESC P ... q` — the start of a sixel image, and nothing else so far.
    ///
    /// Every other DCS is let through untouched: DECRQSS, DECRSPS and the rest are not
    /// implemented, and collecting a payload we would only discard is worse than not
    /// collecting it. `ignore` is the parser saying the introducer was malformed.
    pub(super) fn dcs_hook(&mut self, intermediates: &[u8], ignore: bool, action: char) {
        // The intermediates are not incidental: DECRQSS is `DCS $ q ... ST`, so a final
        // `q` alone would collect every status request a child makes as though it were a
        // picture. Sixel takes no intermediates.
        //
        // P1, P2 and P3 are aspect ratio, background mode and grid size. None of the
        // three survives the trip: the picture is scaled to a cell rectangle, and what
        // "background" means here is Emacs' buffer face, which alpha already defers to.
        self.sixel = (action == 'q' && intermediates.is_empty() && !ignore).then(Vec::new);
    }

    /// A slice of the running DCS string's payload.
    ///
    /// Slices rather than a call per byte is the vendored parser's doing, and it is what
    /// makes collecting a megabyte of sixel a handful of appends.
    pub(super) fn dcs_put(&mut self, bytes: &[u8]) {
        if let Some(body) = &mut self.sixel {
            // Truncated rather than dropped, unlike an over-long APC: a sixel body is a
            // sequence of independent bands, so its prefix is a shorter picture and not
            // a parse error. A child that overruns this gets the top of its image.
            let room = SIXEL_BODY_LIMIT - body.len().min(SIXEL_BODY_LIMIT);
            body.extend_from_slice(&bytes[..bytes.len().min(room)]);
        }
    }

    /// The DCS string ended: decode what was collected, if it was a sixel.
    pub(super) fn dcs_unhook(&mut self) {
        let Some(body) = self.sixel.take() else {
            return;
        };
        let Some(bitmap) = sixel::decode(&body) else {
            return;
        };
        // Into the same `ImageData` a kitty transmission produces, by the same route.
        // Sixel has transparency and Emacs' pbm reader has no alpha, so this takes the
        // PNG road for the reason `f=32` does rather than the cheaper P6 one.
        let px = bitmap.size;
        let (format, bytes) = bitmap.encode();
        let id = self.intern_image(format, &bytes, px, None);
        self.lay_image(id);
    }

    /// `ESC _ ... ST` — the kitty graphics protocol, and nothing else so far.
    ///
    /// Reachable only because the parser is vendored: upstream vte consumes APC and
    /// tells the performer nothing, which is why an image never arrived at all before.
    pub(super) fn apc(&mut self, bytes: &[u8]) {
        let (outcome, reply) = self.kitty.feed(bytes);
        if let Some(reply) = reply {
            self.events.push(Event::Reply(reply));
        }
        match outcome {
            Outcome::Image {
                format,
                bytes,
                px,
                cells,
                client_id,
                display,
            } => {
                let id = self.intern_image(format, &bytes, px, cells.asked());
                // The child's id space is not ours — ours is content-addressed — so the
                // mapping is what makes a later `a=p` find this picture again.
                self.kitty.bind(client_id, id);
                if display {
                    self.lay_image(id);
                }
            }
            Outcome::Place(id) => self.lay_image(id),
            Outcome::Incomplete | Outcome::Nothing => {}
        }
    }
}
