//! Image transmission and placement: kitty (APC), sixel (DCS) and iTerm2 `OSC 1337`.
//!
//! Three producers, one pipeline: each ends at `intern_image` + `lay_image` and shares
//! everything downstream of "here are some pixels".

use super::osc::rejoin;
use super::*;

/// Where the cursor is left once a picture has been laid into the grid.
///
/// The three producers genuinely disagree about this, so it is the caller's to say
/// rather than something [`State::lay_image`] can settle on its own — and getting it
/// wrong is not a cosmetic matter, because a client that draws a frame, moves the cursor
/// back up by the picture's height and draws the next one accumulates one row of drift
/// per frame until the animation walks off the screen.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum CursorAfterImage {
    /// Column 0 of the line below the picture, which is where xterm leaves a sixel and
    /// what makes a bare `printf` of one behave like printing that many lines. Sixel and
    /// iTerm2 both want this.
    NextLine,
    /// On the picture's last row, just past its right edge — kitty's rule. It moves to
    /// the next line only when that column reaches the screen width, which is exactly
    /// the case kitty's clients guard against: viuer emits the newline itself *unless*
    /// the image reached the boundary, because otherwise it would get a blank line.
    PastRightEdge,
}

impl State {
    pub(super) fn place_image(
        &mut self,
        format: ImageFormat,
        bytes: &[u8],
        px: PixelSize,
    ) -> ImageId {
        let id = self.intern_image(format, bytes.to_vec(), px, None);
        self.lay_image(id, CursorAfterImage::NextLine);
        id
    }

    /// Take BYTES as an image and say what we will call it, without drawing anything.
    ///
    /// CELLS is the rectangle the child asked for, `None` when it did not say and the
    /// size should follow from the pixels. An empty `PX` is read out of the bytes where
    /// the format states its own size, which clients rely on: the protocol does not ask
    /// a PNG's sender to repeat dimensions the file already carries.
    ///
    /// **Takes the payload by value, and that is worth a paragraph.** This used to be a
    /// `&[u8]` with a `bytes.to_vec()` on the way into `pending_images`, so every
    /// *distinct* frame — which is every frame of an animation, ids being
    /// content-addressed — paid a full copy of its own payload. At `viu`'s two megabytes
    /// a frame and thirty frames a second that is sixty megabytes a second of memcpy,
    /// spent to put bytes somewhere they already were.
    ///
    /// All three real producers already own a `Vec` at the call: the iTerm2 path has just
    /// base64-decoded one, the sixel path has just had one back from `Bitmap::encode`, and
    /// the kitty path destructures one out of `Outcome::Image`. So the copy bought nothing
    /// but a signature. `State::place_image` is the one caller left holding a borrow, and
    /// it copies there instead — it is reached only from `Term::place_image`, which
    /// nothing but the tests calls.
    ///
    /// A recognised picture drops the payload here rather than copying it, which is the
    /// same shape from the other side: the bytes are not wanted, because Emacs has them.
    pub(super) fn intern_image(
        &mut self,
        format: ImageFormat,
        bytes: Vec<u8>,
        px: PixelSize,
        cells: Option<CellSize>,
    ) -> ImageId {
        let px = if px.is_empty() {
            png_dimensions(&bytes).unwrap_or(px)
        } else {
            px
        };
        let Interned { id, fresh, retired } = self.images.intern(&bytes, px);
        // The count cap can retire an id to make room for this one, and the client's own
        // name for that picture has to go at the same moment: an `a=p` naming it would
        // otherwise place a rectangle the store can no longer describe.
        for gone in retired {
            self.kitty.forget(gone);
        }
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
        let asked = cells.map(|asked| {
            CellSize::new(
                asked.cols.clamp(1, MAX_IMAGE_CELL_SPAN),
                asked.rows.clamp(1, MAX_IMAGE_CELL_SPAN),
            )
        });
        // Shedding also happens at drain time, which is where it decides what *crosses*.
        // This is the other half, and it is about memory rather than about Emacs: a child
        // can transmit far faster than Emacs drains, and every fresh frame parks a copy
        // of its payload here until it does. Two megabytes a frame against a display loop
        // that is already behind is how a gif turns into hundreds of megabytes of frames
        // nobody will ever be shown. Shedding here keeps the queue at the couple of
        // frames actually in play.
        //
        // Not before every transmission: below two there is nothing a scan could find,
        // and the frame just placed is still the one on the grid.
        if fresh && self.pending_images.len() >= 2 {
            self.shed_unplaced_images();
        }
        if fresh {
            self.pending_images.push(ImageData {
                id,
                format,
                bytes,
                px,
            });
        }
        // What the child *said*, not what that came to in cells. Where it said nothing,
        // the rectangle is derived from the pixels against the cell of the moment, and
        // that derivation has to be redone every time it is asked for rather than
        // recorded here -- `ImageStore::cells` is where it happens, and says why.
        self.images.set_asked(id, asked);
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
        let joined = rejoin(params.get(1..).unwrap_or(&[]));
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
        let Some((format, px)) = crate::emu::png::sniff(&bytes) else {
            return true;
        };
        // An axis the child named settles both: the other falls back to one cell, as it
        // did when the pair was a tuple with a zero in it.
        let cells = (cols.is_some() || rows.is_some())
            .then(|| CellSize::new(cols.unwrap_or(1), rows.unwrap_or(1)));
        let id = self.intern_image(format, bytes, px, cells);
        self.lay_image(id, CursorAfterImage::NextLine);
        true
    }

    /// Lay an already-interned image into the grid at the cursor, leaving the cursor
    /// where AFTER says.
    ///
    /// Rows are laid top to bottom, scrolling when the picture runs past the bottom of
    /// the screen, and each is clipped to the screen width rather than wrapped — an
    /// image is a rectangle, and a row of it continuing on the next line would not be
    /// one.
    pub(super) fn lay_image(&mut self, id: ImageId, after: CursorAfterImage) {
        // An id the store has forgotten draws nothing rather than a one-cell stub. No
        // path reaches here with one today -- forgetting a picture retires the client's
        // name for it in the same call, so a bare `a=p` is refused with `ENOENT:image`
        // before it ever becomes a placement -- but the store is the only thing that
        // knows the rectangle, and a guessed one is worse than none: it would put a
        // picture-shaped hole of the wrong shape on the grid, under a cursor left in the
        // wrong place.
        let Some(cells) = self.images.cells(id, self.metrics) else {
            return;
        };
        let pen = self.pen.erase();
        let start_col = self.screen().cursor.col;
        for cell_row in 0..cells.rows {
            self.screen_mut().cursor.col = start_col;
            self.screen_mut().place_image_row(id, cell_row, cells, pen);
            // The linefeed after the *last* row is what separates the two dispositions:
            // running it there is what puts the cursor on the line below the picture,
            // and skipping it is what leaves it on the picture's last row.
            let last = cell_row + 1 == cells.rows;
            if last && after == CursorAfterImage::PastRightEdge {
                break;
            }
            let evicted = self.screen_mut().linefeed(pen);
            self.evicted(evicted);
        }
        match after {
            CursorAfterImage::NextLine => self.screen_mut().carriage_return(),
            CursorAfterImage::PastRightEdge => {
                let end = start_col + usize::from(cells.cols);
                if end < self.screen().width() {
                    self.screen_mut().cursor.col = end;
                    self.screen_mut().cursor.wrap_pending = false;
                } else {
                    // The picture reached the right edge, so the column past it is not
                    // on this line. A real linefeed rather than a clamp, because this is
                    // the case that has to scroll when the picture ends on the bottom
                    // row.
                    let evicted = self.screen_mut().linefeed(pen);
                    self.evicted(evicted);
                    self.screen_mut().carriage_return();
                }
            }
        }
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
        let id = self.intern_image(format, bytes, px, None);
        self.lay_image(id, CursorAfterImage::NextLine);
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
                freeze_cursor,
            } => {
                let id = self.intern_image(format, bytes, px, cells.asked());
                // The child's id space is not ours — ours is content-addressed — so the
                // mapping is what makes a later `a=p` find this picture again.
                self.kitty.bind(client_id, id);
                if display {
                    self.kitty_place(id, freeze_cursor);
                }
            }
            Outcome::Place { id, freeze_cursor } => self.kitty_place(id, freeze_cursor),
            Outcome::Incomplete | Outcome::Nothing => {}
        }
    }

    /// Draw a picture for the kitty protocol, honouring `C=`.
    ///
    /// `C=1` is "do not move the cursor", so the whole of it is putting back what was
    /// there. The one thing that cannot be put back is the *text* the cursor sat in when
    /// a picture tall enough to scroll pushed it up: the row restored is the same screen
    /// row, which is what a terminal that never scrolls at all would have left anyway.
    fn kitty_place(&mut self, id: ImageId, freeze_cursor: bool) {
        let entry = self.screen().cursor;
        self.lay_image(id, CursorAfterImage::PastRightEdge);
        if freeze_cursor {
            self.screen_mut().cursor = entry;
        }
    }
}
