//! Image transmission and placement: kitty (APC), sixel (DCS) and iTerm2 `OSC 1337`.
//!
//! Three producers, one pipeline: each ends at `intern_image` + `lay_image` and shares
//! everything downstream of "here are some pixels".

use super::*;
use crate::emu::kitty::CursorMove;

/// Where the cursor is left once a picture has been laid into the grid.
///
/// The producers disagree about this, so the caller says. Getting it wrong is not
/// cosmetic: a client that draws a frame, moves back up by the picture's height and draws
/// the next accumulates a row of drift per frame until the animation walks off screen.
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
    /// Where it was before the picture was laid: kitty's `C=1`. A picture tall enough to
    /// scroll still moves the text the cursor sat in, and the cursor stays on the same
    /// screen row, which is what a terminal that never scrolled would show.
    Unmoved,
}

impl From<CursorMove> for CursorAfterImage {
    fn from(cursor: CursorMove) -> Self {
        match cursor {
            CursorMove::Advance => Self::PastRightEdge,
            CursorMove::Stay => Self::Unmoved,
        }
    }
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
    /// Takes the payload by value, because every producer already owns a `Vec` at the call
    /// and every distinct frame of an animation would otherwise pay a full copy -- about
    /// 60MB a second of memcpy for `viu`. Only `State::place_image`, used by tests, copies.
    /// A recognised picture drops the payload, since Emacs already has the bytes.
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
        // `c=`/`r=` are clamped to `u16::MAX` in `kitty::Command::parse`, but a tiny PNG,
        // which carries no raw pixel count for `kitty::finish` to check against, could
        // still ask for 65535 rows. `lay_image` does a real `linefeed` per row, so that
        // would force tens of thousands of scrolls from one small APC before backpressure
        // gets a turn. [`MAX_IMAGE_CELL_SPAN`] bounds it.
        let asked = cells.map(|asked| {
            CellSize::new(
                asked.cols.clamp(1, MAX_IMAGE_CELL_SPAN),
                asked.rows.clamp(1, MAX_IMAGE_CELL_SPAN),
            )
        });
        // Shedding at drain time decides what crosses; shedding here bounds memory. A child
        // can transmit far faster than Emacs drains, and at two megabytes a frame a gif
        // would otherwise queue hundreds of megabytes nobody will see. Below two pending
        // frames there is nothing a scan could find.
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
    /// `inline=1` is required. Without it the sequence means "download this to the user's
    /// machine", a file-writing capability that is refused by doing nothing.
    ///
    /// Semicolons separate the keys, which is one reason the parser hands a payload over
    /// whole rather than cut at every `;`: this one is megabytes of base64.
    ///
    /// Returns whether this was an inline-image `File=`, handled or refused. `false`
    /// means it was some other `OSC 1337` and belongs to whoever else is listening.
    pub(super) fn iterm_file(&mut self, payload: &[u8]) -> bool {
        // The colon separates the arguments from the payload, and only the first one
        // does: base64 has no colon in it.
        let colon = memchr::memchr(b':', payload);
        let args = String::from_utf8_lossy(&payload[..colon.unwrap_or(payload.len())]).into_owned();
        let Some(args) = args.strip_prefix("File=") else {
            return false;
        };
        // Emacs cannot show it. Refused rather than laid as blanks, because this protocol
        // has no probe to answer "no" to -- `imgcat` just sends -- and a picture-sized hole
        // in the transcript would explain nothing.
        if !self.graphics.any() {
            return true;
        }

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
        let Some(bytes) = decode_base64(&payload[colon + 1..]) else {
            return true;
        };
        let Some((format, px)) = crate::emu::png::sniff(&bytes) else {
            return true;
        };
        // An axis the child named settles both: the other falls back to one cell.
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
        // An id the store has forgotten draws nothing. No path reaches here with one --
        // forgetting a picture retires the client's name for it too -- but only the store
        // knows the rectangle, and a guessed one would leave a wrongly shaped hole under a
        // misplaced cursor.
        let Some(cells) = self.images.cells(id, self.metrics) else {
            return;
        };
        let pen = self.pen();
        let entry = self.screen().cursor();
        let start_col = entry.col;
        for cell_row in 0..cells.rows {
            let row = self.screen().cursor().row;
            self.screen_mut().goto(row, start_col);
            self.screen_mut()
                .place_image_row(id, cell_row, cells, pen.erase);
            // The linefeed after the *last* row is what separates the two dispositions:
            // running it there is what puts the cursor on the line below the picture,
            // and skipping it is what leaves it on the picture's last row.
            let last = cell_row + 1 == cells.rows;
            if last && after != CursorAfterImage::NextLine {
                break;
            }
            self.evicting(|screen| screen.linefeed(pen));
        }
        match after {
            CursorAfterImage::NextLine => self.screen_mut().carriage_return(),
            CursorAfterImage::Unmoved => self.screen_mut().put_cursor(entry),
            CursorAfterImage::PastRightEdge => {
                let end = start_col + usize::from(cells.cols);
                if end < self.screen().width() {
                    let row = self.screen().cursor().row;
                    self.screen_mut().goto(row, end);
                } else {
                    // The picture reached the right edge, so the column past it is not
                    // on this line. A real linefeed rather than a clamp, because this is
                    // the case that has to scroll when the picture ends on the bottom
                    // row.
                    self.evicting(|screen| screen.linefeed(pen));
                    self.screen_mut().carriage_return();
                }
            }
        }
    }

    /// `ESC P ... q` — the start of a sixel image, a DECRQSS or an XTGETTCAP, and
    /// nothing else so far.
    ///
    /// Every other DCS is let through untouched: DECRSPS and the rest are not
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
        self.dcs = match (action, intermediates, ignore) {
            ('q', [], false) => Some(DcsString::Sixel(Vec::new())),
            ('q', [b'$'], false) => Some(DcsString::StatusRequest(Vec::new())),
            ('q', [b'+'], false) => Some(DcsString::CapabilityRequest(Default::default())),
            _ => None,
        };
    }

    /// A slice of the running DCS string's payload.
    ///
    /// Slices rather than a call per byte is the parser's doing, and it is what
    /// makes collecting a megabyte of sixel a handful of appends.
    pub(super) fn dcs_put(&mut self, bytes: &[u8]) {
        // Truncated rather than dropped, unlike an over-long APC: a sixel body is a
        // sequence of independent bands, so its prefix is a shorter picture and not a
        // parse error. A child that overruns this gets the top of its image. A status
        // request's limit is past every name it could validly carry, so there the
        // truncation cannot turn a long request into a short one that is answered.
        let (body, limit) = match &mut self.dcs {
            Some(DcsString::Sixel(body)) => (body, SIXEL_BODY_LIMIT),
            Some(DcsString::StatusRequest(body)) => (body, DECRQSS_BODY_LIMIT),
            Some(DcsString::CapabilityRequest(request)) => return request.put(bytes),
            None => return,
        };
        crate::emu::bytes::extend_bounded(body, bytes, limit);
    }

    /// The DCS string ended: act on what was collected, if it was one of ours.
    pub(super) fn dcs_unhook(&mut self) {
        let body = match self.dcs.take() {
            Some(DcsString::Sixel(body)) => body,
            Some(DcsString::StatusRequest(name)) => return self.status_report(&name),
            Some(DcsString::CapabilityRequest(request)) => return self.capability_report(request),
            None => return,
        };
        // Decoded with the terminal unlocked; see [`Decode`].
        self.decode = Some(Decode(Job::Sixel(body)));
    }

    /// A sixel the reader has decoded, or failed to.
    fn sixel_decoded(&mut self, bitmap: Option<sixel::Bitmap>) {
        let Some(bitmap) = bitmap else {
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

    /// Take up what a [`Decode`] produced, as though `apc` or `dcs_unhook` had done it.
    pub(super) fn apply_decoded(&mut self, decoded: Decoded) {
        match decoded.0 {
            Picture::Kitty(outcome, reply) => self.kitty_outcome(outcome, reply),
            Picture::Sixel(bitmap) => self.sixel_decoded(bitmap),
        }
    }

    /// `ESC _ ... ST` — the kitty graphics protocol, and nothing else so far.
    ///
    /// Reachable only because the parser is cooked's own: upstream vte consumes APC and tells
    /// the performer nothing.
    pub(super) fn apc(&mut self, bytes: &[u8]) {
        // A probe is how a kitty client decides whether to transmit at all, so this is
        // the kitty half of what DA1's missing `4` says to a sixel producer. Skipped when
        // everything can be shown, so a transfer's chunks are not parsed twice for a
        // refusal that cannot come. Answered before `feed` sees it, which is also what `feed` does with a probe arriving
        // mid-transfer: the transfer in flight is left alone.
        if self.graphics != ShownFormats::ALL
            && let Some(refusal) = crate::emu::kitty::refuse_probe(bytes, self.graphics)
        {
            self.push_reply(Event::answer(refusal));
            return;
        }
        let (outcome, reply) = self.kitty.feed(bytes);
        self.kitty_outcome(outcome, reply);
    }

    /// Act on what a kitty command came to, and answer it.
    fn kitty_outcome(&mut self, outcome: Outcome, reply: Option<Vec<u8>>) {
        if let Some(reply) = reply {
            self.push_reply(Event::answer(reply));
        }
        match outcome {
            // The parser stops here -- see `Perform::terminated` -- so the reader can run
            // the decode unlocked and bring the result to `apply_decoded`.
            Outcome::Decode(transfer) => self.decode = Some(Decode(Job::Kitty(transfer))),
            Outcome::Image {
                format,
                bytes,
                px,
                cells,
                client_id,
                display,
            } => {
                let id = self.intern_image(format, bytes, px, cells.asked());
                // The child's id space is not ours — ours is content-addressed — so the
                // mapping is what makes a later `a=p` find this picture again.
                self.kitty.bind(client_id, id);
                if let Some(cursor) = display {
                    self.lay_image(id, cursor.into());
                }
            }
            Outcome::Place { id, cursor } => self.lay_image(id, cursor.into()),
            Outcome::Incomplete | Outcome::Nothing => {}
        }
    }
}
