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
    fn end_cluster(&mut self) {
        self.text.reset();
    }
}

impl Perform for State {
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

    /// The batched half of [`Perform::print`], and the path nearly all output takes.
    ///
    /// Only printable ASCII goes fast: `0x20..=0x7e` is exactly the set that is one byte
    /// in the stream, one column on the grid, never zero-width and never a control. DEL
    /// arrives here too, since the parser does not treat `0x7f` as a control, but it has
    /// no width, so it and anything else -- a wide character, a combining mark -- falls
    /// through to `print` one character at a time.
    ///
    /// The pen cannot change inside a run, because changing it takes an escape sequence
    /// and that would have ended the run, so the conditions are tested once here rather
    /// than per character.
    fn print_str(&mut self, text: &str) {
        // A designated set or a single shift substitutes the character, which is
        // per-character work the run form does not do, so either disqualifies the whole
        // run. A single shift spends itself on the run's first character, after which the
        // rest of the run is plain again but goes the slow way anyway -- an `ESC N` is rare
        // enough that re-deciding mid-run is not worth a second test. The pen's rendition
        // and link are fields of every cell written, so neither needs the slow path.
        let batched = self.modes.charsets.is_plain();
        // Compiled out of a release build entirely; see `State::force_per_character_print`.
        #[cfg(test)]
        let batched = batched && !self.force_per_character_print;
        let pen = self.pen();

        let mut rest = text;
        while !rest.is_empty() {
            let plain = if batched {
                text::printable_ascii_len(rest.as_bytes())
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
                // One exception is accepted: `GB9b` joins a `Prepend` code point to what
                // follows, so `U+0600 ARABIC NUMBER SIGN` before a digit is one cluster
                // and is segmented here as two. Every `Prepend` is zero width, so the
                // column count is the same, and avoiding it would cost a lookup per
                // character on the path that exists to have none.
                if let Some(last) = last {
                    let mut buf = [0u8; 4];
                    self.text
                        .restart(last.encode_utf8(&mut buf), Width::Measured(1));
                }
                rest = &rest[placed..];
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
            // LS2 and LS3, and SS2 and SS3: G2 or G3 into GL until told otherwise, or for
            // the next character alone.
            (None, b'n') => self.modes.charsets.lock(2),
            (None, b'o') => self.modes.charsets.lock(3),
            (None, b'N') => self.modes.charsets.single_shift(2),
            (None, b'O') => self.modes.charsets.single_shift(3),
            // DECALN. Erased first, exactly as `CSI 2J` erases, so a primary screen's
            // contents reach history before the pattern covers them; see `Screen::align`.
            (Some(b'#'), b'8') => {
                self.erase_display(Erase::All, Pen::default());
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

    fn osc_dispatch(&mut self, params: &[&[u8]], bell_terminated: bool) {
        self.end_cluster();
        self.osc(params, bell_terminated);
    }
}
