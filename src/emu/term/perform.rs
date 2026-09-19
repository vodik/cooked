//! The single `Perform` impl, and the two dispatches small enough to live in it.
//!
//! A trait impl cannot be split across files, so the large arms are inherent methods
//! next to the state they touch -- `State::csi` in csi.rs, `State::osc` in osc.rs, the
//! image string handlers in graphics.rs -- and this forwards to them.

use super::*;

impl State {
    /// End the grapheme cluster under the cursor.
    ///
    /// Every dispatch that is not a print calls this first. The cell to the cursor's left
    /// is only this side's to extend while this side is the one that wrote it: an `e`,
    /// then a cursor move, then a combining acute must not join the `e`. See
    /// [`crate::emu::text`].
    ///
    /// A multi-byte sequence the text before this left unfinished ends here too, and for
    /// the same reason: what follows is not text, so nothing can complete it. It is
    /// printed as the `U+FFFD` it has become, before whatever was dispatched acts.
    fn end_cluster(&mut self) {
        if let Some(c) = self.decoder.flush() {
            self.print(c);
        }
        self.text.reset();
    }

    /// Draw one character that is not a control.
    fn print(&mut self, c: char) {
        // The designated set, and any single shift, before anything else sees the
        // character: the segmenter has to measure what is drawn, not what was sent.
        let c = self.modes.charsets.print(c);
        let pen = self.pen();
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
                (0, Evicted::none())
            }
        };
        self.evicted(evicted);
        if width > 0 {
            self.last_print = Some(c);
        }
    }

    /// Draw a run of printable ASCII, which is the path nearly all output takes.
    ///
    /// `0x20..=0x7e` is exactly the set that is one byte in the stream, one column on the
    /// grid, never zero-width and never a control, so a run of it is laid without asking
    /// the segmenter about each. BATCHED says whether it may be, which is
    /// [`Perform::print_bytes`]'s to decide once for everything it was handed; the pen
    /// cannot change inside a run either, because changing it takes an escape sequence
    /// and that would have ended the run.
    fn print_ascii(&mut self, run: &[u8], batched: bool, pen: Pen) {
        // SAFETY: the decoder hands over nothing here but bytes in `0x20..=0x7e`.
        let mut rest = unsafe { std::str::from_utf8_unchecked(run) };
        while !rest.is_empty() {
            let placed = if batched {
                self.screen_mut().write_run(rest, pen)
            } else {
                0
            };
            if placed == 0 {
                // The character `write_run` declined: the last column of a row, a pending
                // wrap. One trip through the full path settles it.
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
                // One exception is accepted: `GB9b` joins a `Prepend` code point to what
                // follows, so `U+0600 ARABIC NUMBER SIGN` before a digit is one cluster
                // and is segmented here as two. Every `Prepend` is zero width, so the
                // column count is the same, and avoiding it would cost a lookup per
                // character on the path that exists to have none.
                if let Some(last) = last {
                    let mut buf = [0u8; 4];
                    self.text
                        .restart(last.encode_utf8(&mut buf), Width::measured(1));
                }
                rest = &rest[placed..];
            }
        }
    }
}

impl Perform for State {
    /// Read a run of text as UTF-8, once, and draw it; see [`crate::emu::utf8`].
    ///
    /// Printable ASCII goes a run at a time through [`State::print_ascii`], and anything
    /// else -- a wide character, a combining mark -- a character at a time through
    /// [`State::print`]. No control is among them: the parser executes C0, and the
    /// decoder drops DEL and C1, so nothing that reaches a cell is `Cc`.
    fn print_bytes(&mut self, bytes: &[u8]) {
        // A designated set or a single shift substitutes the character, which is
        // per-character work the run form does not do, so either disqualifies every run
        // in this text. A single shift spends itself on the first character, after which
        // the rest is plain again but goes the slow way anyway -- an `ESC N` is rare
        // enough that re-deciding mid-text is not worth a second test. The pen's
        // rendition and link are fields of every cell written, so neither needs the slow
        // path.
        let batched = self.modes.charsets.is_plain();
        // Compiled out of a release build entirely; see `State::force_per_character_print`.
        #[cfg(test)]
        let batched = batched && !self.force_per_character_print;
        let pen = self.pen();
        let mut rest = bytes;
        while let Some(piece) = self.decoder.next(&mut rest) {
            match piece {
                Piece::Ascii(run) => self.print_ascii(run, batched, pen),
                Piece::Char(c) => self.print(c),
            }
        }
    }

    fn execute(&mut self, byte: u8) {
        self.end_cluster();
        match byte {
            0x07 => {
                if !self.bell_queued {
                    self.bell_queued = true;
                    self.events.push(Event::Bell);
                }
            }
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
            // SO and SI: locking shifts of G1 and G0 into GL. Which set that draws is
            // whatever was designated there; see [`Charsets`].
            0x0E => self.modes.charsets.lock(1),
            0x0F => self.modes.charsets.lock(0),
            #[cfg(test)]
            _ => self.unrecognised += 1,
            #[cfg(not(test))]
            _ => {}
        }
    }

    fn esc_dispatch(&mut self, intermediates: &[u8], _ignore: bool, byte: u8) {
        self.end_cluster();
        match (intermediates.first().copied(), byte) {
            // SCS into G0-G3. Matched on the first intermediate alone, so a two-byte
            // designator such as `ESC ( % 5` (DEC Supplemental) still lands in its slot --
            // as ASCII, which is `Charset::designated`'s answer for a set it lacks.
            (Some(slot @ (b'(' | b')' | b'*' | b'+')), _) => {
                self.modes
                    .charsets
                    .designate(usize::from(slot - b'('), byte);
            }
            // The 96-character designators, into G1-G3 (there is no G0 form). Every
            // 96-character set is a Latin supplement, which this terminal lacks, so each
            // designates ASCII: ignoring one would leave G1 holding whatever was there,
            // and a `ESC ) 0` from earlier would go on drawing boxes after SO.
            (Some(slot @ (b'-' | b'.' | b'/')), _) => {
                self.modes
                    .charsets
                    .designate_ascii(usize::from(slot - b','));
            }
            // LS2 and LS3, and SS2 and SS3: G2 or G3 into GL until told otherwise, or for
            // the next character alone.
            (None, b'n') => self.modes.charsets.lock(2),
            (None, b'o') => self.modes.charsets.lock(3),
            (None, b'N') => self.modes.charsets.single_shift(2),
            (None, b'O') => self.modes.charsets.single_shift(3),
            // DECALN. Erased first, exactly as `CSI 2J` erases, so a primary screen's
            // contents reach history before the pattern covers them; see `Screen::align`.
            // xterm also turns DECOM off and puts the rendition back, so the home the
            // pattern leaves the cursor at is the screen's corner and not the region's,
            // and a test drawn next is drawn in plain text.
            (Some(b'#'), b'8') => {
                self.erase_display(Erase::All, Pen::default());
                self.modes.origin_mode = false;
                self.pen.set_style(Style::default());
                self.screen_mut().align();
            }
            (None, b'D') => self.linefeed(),
            (None, b'E') => {
                self.screen_mut().carriage_return();
                self.linefeed();
            }
            (None, b'M') => {
                let pen = self.pen();
                self.screen_mut().reverse_index(pen);
            }
            (None, b'H') => self.screen_mut().set_tab(),
            // DECKPAM/DECKPNM. `rs2` and `is2` both end in `ESC >`, which is how a reset
            // puts the keypad back.
            (None, b'=') => self.modes.app_keypad = true,
            (None, b'>') => self.modes.app_keypad = false,
            (None, b'7') => self.save_cursor(),
            (None, b'8') => self.restore_cursor(),
            (None, b'c') => {
                // RIS is a soft reset that also clears the screen, leaves the alternate
                // one and puts the tab stops back. The pen is default by the time the
                // erase runs, so this is `bce` with nothing to carry.
                //
                // The alternate screen goes first, through `set_alt` as `?1049l` does, so
                // `reset` after a full-screen program died without `rmcup` returns the
                // user to the transcript. Before `soft_reset`, so the erase and home below
                // act on the primary. No `restore_cursor`: RIS homes the cursor anyway.
                self.set_alt(false);
                self.soft_reset();
                // Both screens own a stop table, so both are reset. Not in `soft_reset`:
                // DECSTR keeps the stops, as on xterm.
                for screen in self.screens.each_mut() {
                    screen.reset_tabs();
                }
                self.erase_display(Erase::All, Pen::default());
                self.screen_mut().goto(0, 0);
                // Last, so a Lisp handler sees the reset already done; see [`Event::Reset`].
                // A bell queued before it is answered before the reset, and Lisp clears
                // its mark there, so a BEL after the reset has to be queued afresh.
                self.events.push(Event::Reset);
                self.bell_queued = false;
            }
            // ST. The parser has already dispatched the OSC, DCS or APC it ends, and hands
            // on the backslash after the ESC as an escape of its own.
            (None, b'\\') => {}
            #[cfg(test)]
            _ => self.unrecognised += 1,
            #[cfg(not(test))]
            _ => {}
        }
    }

    fn csi_dispatch(&mut self, params: &Params, intermediates: &[u8], _ignore: bool, action: char) {
        self.end_cluster();
        self.csi(params, intermediates, action);
    }

    fn hook(&mut self, _params: &Params, intermediates: &[u8], ignore: bool, action: char) {
        self.end_cluster();
        self.dcs_hook(intermediates, ignore, action);
    }

    fn put(&mut self, bytes: &[u8]) {
        self.dcs_put(bytes);
    }

    fn unhook(&mut self) {
        self.dcs_unhook();
    }

    fn apc_dispatch(&mut self, bytes: &[u8]) {
        self.end_cluster();
        self.apc(bytes);
    }

    /// A picture is waiting to be decoded, which the parser stops for; see [`Decode`].
    fn terminated(&self) -> bool {
        self.decode.is_some()
    }

    fn osc_dispatch(&mut self, code: OscCode, payload: Option<&[u8]>, bell_terminated: bool) {
        self.end_cluster();
        self.osc(code, payload, bell_terminated);
    }
}
