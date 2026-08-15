//! The single `Perform` impl, and the two dispatches small enough to live in it.
//!
//! A trait impl cannot be split across files, so the large arms are inherent methods
//! next to the state they touch -- `State::csi` in csi.rs, `State::osc` in osc.rs, the
//! image string handlers in image.rs -- and this forwards to them.

use super::*;

impl Perform for State {
    fn print(&mut self, c: char) {
        let c = if self.modes.dec_graphics {
            dec_graphic(c)
        } else {
            c
        };
        let pen = self.pen;
        let underline = self.underline;
        let link = self.link;
        // The segmenter, not a width table. A code point that continues the cluster on
        // the cell to the left costs no column of its own however wide it looks alone,
        // which is the whole of what makes a ZWJ emoji family two cells rather than six.
        let (width, evicted) = match self.text.push(c) {
            Step::Cell(width) => (width, self.screen_mut().place(c, width, pen)),
            Step::Join { before, after } => {
                // `join` answers with the width the cell *ended up* at, because a
                // widening with no room left on the row is declined; the segmenter has
                // to be told, since that number is how it finds the cell next time.
                let settled = self.screen_mut().join(c, before, after);
                self.text.settle(settled);
                // Zero, so the two attachment writers below leave the cell alone: a
                // combining mark neither owns an underline colour nor opens a link, and
                // moving either onto the cell it rides would take it off the character
                // that actually carries it.
                (0, Evicted::none())
            }
        };
        let screen = self.screen_mut();
        // After the write, so it lands on the cell the write actually chose — which a
        // wrap or DECAWM may have moved. Only when there is a colour to record: retiring
        // the *previous* occupant's colour is `Row::set`'s job, so nothing here needs a
        // screen-wide "has anything ever been underlined" latch to guard the call. Such a
        // latch cannot be cleared correctly anyway — one `SGR 58` anywhere in a session
        // would make every subsequent character pay for this call forever.
        // Zero-width characters fold onto the cell to their left and never own one, so
        // they must not move an underline colour either.
        if width > 0 && underline != Color::Default {
            screen.mark_underline(underline, width);
        }
        // The same shape, and only when there is a link open: a cell written outside one
        // has nothing attached, because `Row::set` has already retired whatever the
        // previous occupant carried.
        if width > 0 && link.is_some() {
            screen.mark_link(link, width);
        }
        self.evicted(evicted);
        if width > 0 {
            self.last_print = Some(c);
        }
    }

    /// The batched half of [`Perform::print`], and the path nearly all output takes.
    ///
    /// Only printable ASCII goes fast: `0x20..=0x7e` is exactly the set that is one byte
    /// in the stream, one column on the grid, never zero-width and never a control. DEL
    /// is deliberately outside it -- `ground_dispatch` does not treat `0x7f` as a control,
    /// so it arrives here, and `unicode-width` gives it no width, which is the combining
    /// path. Anything else -- a wide character, a combining mark, a box glyph, DEL --
    /// falls through to `print` one character at a time and behaves exactly as it did.
    ///
    /// The pen cannot change inside a run, because changing it takes an escape sequence
    /// and that would have ended the run, so the conditions are tested once here rather
    /// than per character.
    fn print_str(&mut self, text: &str) {
        // `mark_underline` and `mark_link` attach to each cell written, and DEC graphics
        // substitutes the character; each is per-character work the run form does not do,
        // so their presence disqualifies the whole run rather than being reimplemented.
        let batched =
            !self.modes.dec_graphics && self.underline == Color::Default && self.link.is_none();
        // Compiled out of a release build entirely; see `State::force_per_character_print`.
        #[cfg(test)]
        let batched = batched && !self.force_per_character_print;
        let pen = self.pen;

        let mut rest = text;
        while !rest.is_empty() {
            let plain = if batched {
                rest.as_bytes()
                    .iter()
                    .take_while(|&&b| (0x20..0x7f).contains(&b))
                    .count()
            } else {
                0
            };
            let placed = if plain == 0 {
                0
            } else {
                self.screen_mut().write_run(&rest[..plain], pen)
            };
            if placed == 0 {
                // The character `write_run` declined: the last column of a row, a wide
                // character, a pending wrap. One trip through the full path settles it.
                let c = rest.chars().next().unwrap_or('\0');
                self.print(c);
                rest = &rest[c.len_utf8()..];
            } else {
                let last = rest[..placed].chars().next_back();
                self.last_print = last;
                // The run bypassed the segmenter, so the segmenter is told what it
                // missed: the last character placed is the cell a combining mark arriving
                // next has to find. Only the last one, because every character in the run
                // is printable ASCII, and printable ASCII always starts a cluster.
                //
                // Always, bar one case this declines: `GB9b` joins a `Prepend` code point
                // to whatever follows it, so `U+0600 ARABIC NUMBER SIGN` before an ASCII
                // digit is one cluster and is segmented here as two. It costs nothing
                // visible — every `Prepend` is zero width, so it rides the cell to its
                // *left* rather than the one to its right and the column count is the
                // same either way — and the alternative is a `Grapheme_Cluster_Break`
                // lookup per character on the batched path, which is the path that exists
                // to have no per-character lookups in it.
                if let Some(last) = last {
                    let mut buf = [0u8; 4];
                    self.text.restart(last.encode_utf8(&mut buf), 1, false);
                }
                rest = &rest[placed..];
            }
        }
    }

    fn execute(&mut self, byte: u8) {
        // Anything that is not a print ends the cluster under the cursor: the cell to
        // the cursor's left is only this side's to extend while this side is the one
        // that wrote it. See [`crate::emu::text`].
        self.text.reset();
        match byte {
            0x07 => self.events.push(Event::Bell),
            0x08 => self.screen_mut().backspace(),
            0x09 => self.screen_mut().tab(1),
            0x0A..=0x0C => {
                self.linefeed();
                // LNM: the child asked for LF to imply CR.
                if self.modes.newline_mode {
                    self.screen_mut().carriage_return();
                }
            }
            0x0D => self.screen_mut().carriage_return(),
            0x0E => self.modes.dec_graphics = true,
            0x0F => self.modes.dec_graphics = false,
            _ => {}
        }
    }

    fn esc_dispatch(&mut self, intermediates: &[u8], _ignore: bool, byte: u8) {
        // Anything that is not a print ends the cluster under the cursor: the cell to
        // the cursor's left is only this side's to extend while this side is the one
        // that wrote it. See [`crate::emu::text`].
        self.text.reset();
        match (intermediates.first().copied(), byte) {
            (Some(b'('), b'0') => self.modes.dec_graphics = true,
            (Some(b'('), _) => self.modes.dec_graphics = false,
            (None, b'D') => self.linefeed(),
            (None, b'E') => {
                self.screen_mut().carriage_return();
                self.linefeed();
            }
            (None, b'M') => {
                let pen = self.pen;
                self.screen_mut().reverse_index(pen);
            }
            (None, b'H') => self.screen_mut().set_tab(),
            // DECKPAM/DECKPNM. `rs2` and `is2` both end in `ESC >`, so ignoring these
            // meant a reset left the keypad wherever the last program put it.
            (None, b'=') => self.modes.app_keypad = true,
            (None, b'>') => self.modes.app_keypad = false,
            (None, b'7') => self.save_restore(true),
            (None, b'8') => self.save_restore(false),
            (None, b'c') => {
                // RIS is a soft reset that also clears the screen. The pen is default by
                // the time the erase runs, so this is `bce` with nothing to carry.
                self.soft_reset();
                let evicted = self
                    .screen_mut()
                    .erase_display(Erase::All, Style::default());
                self.evicted(evicted);
                self.cleared_display();
                self.screen_mut().goto(0, 0);
            }
            _ => {}
        }
    }

    fn csi_dispatch(&mut self, params: &Params, intermediates: &[u8], _ignore: bool, action: char) {
        // Anything that is not a print ends the cluster under the cursor: the cell to
        // the cursor's left is only this side's to extend while this side is the one
        // that wrote it. See [`crate::emu::text`].
        self.text.reset();
        self.csi(params, intermediates, action);
    }

    fn hook(&mut self, _params: &Params, intermediates: &[u8], ignore: bool, action: char) {
        // Anything that is not a print ends the cluster under the cursor: the cell to
        // the cursor's left is only this side's to extend while this side is the one
        // that wrote it. See [`crate::emu::text`].
        self.text.reset();
        self.dcs_hook(intermediates, ignore, action);
    }

    fn put(&mut self, bytes: &[u8]) {
        self.dcs_put(bytes);
    }

    fn unhook(&mut self) {
        self.dcs_unhook();
    }

    fn apc_dispatch(&mut self, bytes: &[u8]) {
        // Anything that is not a print ends the cluster under the cursor: the cell to
        // the cursor's left is only this side's to extend while this side is the one
        // that wrote it. See [`crate::emu::text`].
        self.text.reset();
        self.apc(bytes);
    }

    fn osc_dispatch(&mut self, params: &[&[u8]], bell_terminated: bool) {
        // Anything that is not a print ends the cluster under the cursor: the cell to
        // the cursor's left is only this side's to extend while this side is the one
        // that wrote it. See [`crate::emu::text`].
        self.text.reset();
        self.osc(params, bell_terminated);
    }
}
