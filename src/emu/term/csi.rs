//! `CSI` dispatch, and the mode machinery it drives.

/// DECRQM's answer about a mode.
///
/// The protocol's numbers, named once, so that neither reporting site spells them as a
/// bare `1`/`4`/`0` or as arithmetic on a bool.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub(super) enum ModeReport {
    /// The mode is not one we implement, and the child should stop asking.
    Unknown = 0,
    Set = 1,
    Reset = 2,
    /// Implemented but stateless, or permanently on. Nothing answers this today; it is
    /// here because DECRQM defines five values and a partial enum invites a bare `3`.
    #[allow(dead_code)]
    PermanentlySet = 3,
    /// Deliberately not implemented -- this is how a child learns that without guessing.
    PermanentlyReset = 4,
}

impl From<bool> for ModeReport {
    fn from(on: bool) -> Self {
        if on { Self::Set } else { Self::Reset }
    }
}

impl std::fmt::Display for ModeReport {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", *self as u8)
    }
}

/// The modes that are exactly one flag on [`Modes`], stated once.
///
/// Set/reset and the DECRQM query are generated from this list together, because keeping
/// them as two hand-written matches meant a mode could be settable and yet report itself
/// unrecognised -- or, worse, report the opposite of its own state. `soft_reset` is the
/// third member of that family and is handled by `Modes::default()`.
///
/// Modes with an effect beyond one flag -- DECOM's cursor move, DECAWM touching both
/// screens, the mouse group's event, 1049's save/switch/restore -- stay hand-written in
/// [`State::dec_mode`]; there is nothing to share there but the number.
macro_rules! dec_flags {
    ($($number:literal => $field:ident),* $(,)?) => {
        impl State {
            /// Set a one-flag mode, or report that this is not one.
            fn set_flag_mode(&mut self, mode: u16, on: bool) -> bool {
                match mode {
                    $($number => self.modes.$field = on,)*
                    _ => return false,
                }
                true
            }

            /// The DECRQM answer for a one-flag mode.
            fn flag_mode_state(&self, mode: u16) -> Option<ModeReport> {
                match mode {
                    $($number => Some(self.modes.$field.into()),)*
                    _ => None,
                }
            }
        }
    };
}

dec_flags! {
    1 => app_cursor,
    25 => cursor_visible,
    66 => app_keypad,
    1004 => focus_events,
    1007 => alt_scroll,
    2004 => bracketed_paste,
}

use super::*;

impl State {
    pub(super) fn dec_mode(&mut self, mode: u16, on: bool) {
        if self.set_flag_mode(mode, on) {
            return;
        }
        match mode {
            6 => {
                self.modes.origin_mode = on;
                self.screen_mut().goto(0, 0);
            }
            7 => {
                self.primary.set_autowrap(on);
                self.alt.set_autowrap(on);
            }
            // Cursor *blink*, deliberately ignored: that is `blink-cursor-mode', which is
            // the user's setting and not the child's to drive. Visibility is mode 25.
            12 => {}
            1000 | 1002 | 1003 | 1006 => {
                match mode {
                    1000 => self.modes.mouse.click = on,
                    1002 => (self.modes.mouse.click, self.modes.mouse.drag) = (on, on),
                    1003 => (self.modes.mouse.click, self.modes.mouse.motion) = (on, on),
                    _ => self.modes.mouse.sgr = on,
                }
                // Emitted inside the arm rather than after the match: out there it would
                // have to re-test the same four numbers to know one of them was handled.
                self.events.push(Event::Mouse(self.modes.mouse));
            }
            47 | 1047 => self.set_alt(on),
            1048 => self.save_restore(on),
            // Save, switch, ... switch back, restore. The save and the restore have to
            // bracket the switch rather than both precede it, because `save_restore`
            // acts on whichever screen is showing: run before `set_alt(false)` it read
            // the *alt* screen's saved cursor and left the primary's — the one
            // `1049 h` actually saved — untouched.
            //
            // That was invisible for as long as nothing moved the primary's cursor while
            // the alt screen was up, since a restore to where it already was is a no-op.
            // `State::resize` moves it: a rewrap re-chunks the primary and places the
            // cursor at the new width. So resizing the frame inside a full-screen program
            // and then leaving it was already the case that lost the position.
            1049 => {
                if on {
                    self.save_restore(true);
                    self.set_alt(true);
                } else {
                    self.set_alt(false);
                    self.save_restore(false);
                }
            }
            2026 => {
                self.modes.sync_until = on.then(|| std::time::Instant::now() + SYNC_TIMEOUT);
            }
            _ => {}
        }
    }

    /// DECRQM's answer for a private mode.
    ///
    /// The one-flag modes come from the same table that sets them, so the two can no
    /// longer disagree; only modes with state elsewhere are listed here.
    pub(super) fn dec_mode_state(&self, mode: u16) -> ModeReport {
        if let Some(report) = self.flag_mode_state(mode) {
            return report;
        }
        let mouse = self.modes.mouse;
        match mode {
            6 => self.modes.origin_mode.into(),
            7 => self.screen().autowrap().into(),
            1000 => (mouse.click && !mouse.drag && !mouse.motion).into(),
            1002 => mouse.drag.into(),
            1003 => mouse.motion.into(),
            1006 => mouse.sgr.into(),
            2026 => self
                .modes
                .sync_until
                .is_some_and(|t| std::time::Instant::now() < t)
                .into(),
            47 | 1047 | 1049 => self.on_alt.into(),
            // Implemented, but stateless — it saves and restores rather than turning
            // anything on — so "set" is the only honest answer that is not "unknown".
            // Deliberately `Set` and not `PermanentlySet`: xterm answers 1 here, and a
            // child that reads 3 concludes the mode cannot be reset.
            1048 => ModeReport::Set,
            // Dropped from our terminfo, and this is where a child finds that out
            // without having to guess: 12 is cursor blink (`blink-cursor-mode' is the
            // user's), 69 left-right margins, 1034 meta-sends-escape.
            12 | 69 | 1034 => ModeReport::PermanentlyReset,
            _ => ModeReport::Unknown,
        }
    }

    /// ANSI (non-private) modes. Only two of these are real: everything else a child
    /// sends here is a mode we neither implement nor advertise.
    pub(super) fn ansi_mode(&mut self, mode: u16, on: bool) {
        match mode {
            4 => {
                self.primary.set_insert_mode(on);
                self.alt.set_insert_mode(on);
            }
            20 => self.modes.newline_mode = on,
            _ => {}
        }
    }

    /// DECSTR, and the mode half of RIS.
    ///
    /// Everything the child negotiated goes back to its power-on value. The screen and
    /// the scrollback are deliberately not touched — that is the whole difference between
    /// a soft reset and RIS, and it is why `rs2` can be sent without losing the session's
    /// transcript.
    pub(super) fn soft_reset(&mut self) {
        self.pen = Style::default();
        self.underline = Color::Default;
        // Closed here and *only* here, not by SGR: DECSTR and RIS are the child saying
        // "start over", which is a different statement from any rendition change. See
        // [`State::link`].
        self.link = None;
        self.last_print = None;
        // The whole of the negotiated state, in one statement, so that a new mode is
        // reset by construction rather than by remembering to add an assignment; see
        // [`Modes`].
        let had_mouse = self.modes.mouse != Mouse::default();
        self.modes = Modes::default();
        for screen in [&mut self.primary, &mut self.alt] {
            screen.reset_region();
            screen.set_autowrap(true);
            screen.set_insert_mode(false);
            screen.saved = None;
        }
        if had_mouse {
            self.events.push(Event::Mouse(self.modes.mouse));
        }
    }

    pub(super) fn save_restore(&mut self, save: bool) {
        let screen = self.screen_mut();
        if save {
            screen.saved = Some(screen.cursor);
        } else if let Some(cursor) = screen.saved.take() {
            screen.goto(cursor.row, cursor.col);
        }
    }

    pub(super) fn sgr(&mut self, params: &Params) {
        if params.is_empty() {
            self.pen = Style::default();
            self.underline = Color::Default;
            return;
        }
        let mut iter = params.iter();
        while let Some(param) = iter.next() {
            let Some(&code) = param.first() else { continue };
            match code {
                0 => {
                    self.pen = Style::default();
                    self.underline = Color::Default;
                }
                1 => self.pen.attrs |= Attrs::BOLD,
                2 => self.pen.attrs |= Attrs::FAINT,
                3 => self.pen.attrs |= Attrs::ITALIC,
                // `SGR 4` is single; `4:0`-`4:5` name a style. Only the first
                // subparameter is read, which is all the protocol defines.
                4 => match param.get(1) {
                    None => self.pen.attrs.set_underline_style(1),
                    Some(&style) => self.pen.attrs.set_underline_style(style.min(5) as u8),
                },
                5 | 6 => self.pen.attrs |= Attrs::BLINK,
                7 => self.pen.attrs |= Attrs::REVERSE,
                8 => self.pen.attrs |= Attrs::CONCEAL,
                9 => self.pen.attrs |= Attrs::STRIKE,
                21 | 22 => self.pen.attrs.remove(Attrs::BOLD | Attrs::FAINT),
                23 => self.pen.attrs.remove(Attrs::ITALIC),
                24 => self.pen.attrs.set_underline_style(0),
                25 => self.pen.attrs.remove(Attrs::BLINK),
                27 => self.pen.attrs.remove(Attrs::REVERSE),
                28 => self.pen.attrs.remove(Attrs::CONCEAL),
                29 => self.pen.attrs.remove(Attrs::STRIKE),
                30..=37 => self.pen.fg = Color::Indexed((code - 30) as u8),
                38 => self.pen.fg = extended(param, &mut iter).unwrap_or(self.pen.fg),
                39 => self.pen.fg = Color::Default,
                40..=47 => self.pen.bg = Color::Indexed((code - 40) as u8),
                48 => self.pen.bg = extended(param, &mut iter).unwrap_or(self.pen.bg),
                49 => self.pen.bg = Color::Default,
                // `SGR 58`/`59`: the underline's own colour, parsed by the same
                // `extended` as 38 and 48, so `58:2::r:g:b` and `58:5:n` come free.
                58 => self.underline = extended(param, &mut iter).unwrap_or(self.underline),
                59 => self.underline = Color::Default,
                90..=97 => self.pen.fg = Color::Indexed((code - 90 + 8) as u8),
                100..=107 => self.pen.bg = Color::Indexed((code - 100 + 8) as u8),
                _ => {}
            }
        }
    }

    /// Dispatch one `CSI` sequence.
    ///
    /// Four families, tried in turn, each answering whether the sequence was one of its
    /// own.  The order carries no meaning -- the patterns are disjoint -- but the
    /// grouping does: `CSI` is a dispatch table forty-odd entries long, and the useful
    /// question about any one entry is which of these four things it does.
    pub(super) fn csi(&mut self, params: &Params, intermediates: &[u8], action: char) {
        let private = intermediates.first().copied();
        let _handled = self.csi_mode(private, action, params)
            || self.csi_cursor(private, action, params)
            || self.csi_edit(private, action, params)
            || self.csi_report(private, action, params, intermediates);
    }

    /// DEC private and ANSI mode set/reset (`CSI ? Ps h/l`, `CSI Ps h/l`).
    ///
    /// Returns whether the sequence belonged to this family.
    fn csi_mode(&mut self, private: Option<u8>, action: char, params: &Params) -> bool {
        match (private, action) {
            (Some(b'?'), 'h' | 'l') => {
                let on = action == 'h';
                for mode in params.iter().filter_map(|p| p.first().copied()) {
                    self.dec_mode(mode, on);
                }
            }
            (None, 'h' | 'l') => {
                let on = action == 'h';
                for mode in params.iter().filter_map(|p| p.first().copied()) {
                    self.ansi_mode(mode, on);
                }
            }
            _ => return false,
        }
        true
    }

    /// Cursor motion, addressing, tab stops and the cursor save/restore pair.
    ///
    /// Returns whether the sequence belonged to this family.
    fn csi_cursor(&mut self, private: Option<u8>, action: char, params: &Params) -> bool {
        match (private, action) {
            (None, 'A') => self.screen_mut().move_by(-(params.arg(0, 1) as isize), 0),
            (None, 'B' | 'e') => self.screen_mut().move_by(params.arg(0, 1) as isize, 0),
            (None, 'C' | 'a') => self.screen_mut().move_by(0, params.arg(0, 1) as isize),
            (None, 'D') => self.screen_mut().move_by(0, -(params.arg(0, 1) as isize)),
            (None, 'E') => {
                self.screen_mut().move_by(params.arg(0, 1) as isize, 0);
                self.screen_mut().carriage_return();
            }
            (None, 'F') => {
                self.screen_mut().move_by(-(params.arg(0, 1) as isize), 0);
                self.screen_mut().carriage_return();
            }
            (None, 'G' | '`') => {
                let row = self.screen().cursor.row;
                self.screen_mut().goto(row, params.coord(0));
            }
            (None, 'H' | 'f') => {
                let top = if self.modes.origin_mode {
                    self.screen().region.top
                } else {
                    0
                };
                let (row, col) = (params.coord(0) + top, params.coord(1));
                self.screen_mut().goto(row, col);
            }
            (None, 'd') => {
                let col = self.screen().cursor.col;
                self.screen_mut().goto(params.coord(0), col);
            }
            (None, 'g') => self.screen_mut().clear_tabs(params.arg(0, 0) == 3),
            (None, 'Z') => self.screen_mut().back_tab(params.arg(0, 1)),
            (None, 'I') => self.screen_mut().tab(params.arg(0, 1)),
            (None, 's') => self.save_restore(true),
            (None, 'u') => self.save_restore(false),
            _ => return false,
        }
        true
    }

    /// Everything that writes: erase, insert, delete, scroll, and the pen.
    ///
    /// Returns whether the sequence belonged to this family.
    fn csi_edit(&mut self, private: Option<u8>, action: char, params: &Params) -> bool {
        // `bce`: an erase or a scroll leaves the pen's background behind.  See
        // `Style::erase`.
        let pen = self.pen;
        match (private, action) {
            (None, 'J') => {
                let param = params.arg(0, 0) as u16;
                if let Some(how) = Erase::from_param(param) {
                    let evicted = self.screen_mut().erase_display(how, pen);
                    self.evicted(evicted);
                    if matches!(how, Erase::All) {
                        self.cleared_display();
                    }
                }
                if param == 3 {
                    self.events.push(Event::EraseScrollback);
                }
            }
            (None, 'K') => {
                if let Some(how) = Erase::from_param(params.arg(0, 0) as u16) {
                    self.screen_mut().erase_line(how, pen);
                }
            }
            (None, 'L') => self.screen_mut().insert_lines(params.arg(0, 1), pen),
            (None, 'M') => self.screen_mut().delete_lines(params.arg(0, 1), pen),
            (None, 'P') => self.screen_mut().delete_chars(params.arg(0, 1), pen),
            (None, 'S') => {
                let n = params.arg(0, 1);
                let evicted = self.screen_mut().scroll_up(n, pen);
                self.evicted(evicted);
            }
            (None, 'T') => self.screen_mut().scroll_down(params.arg(0, 1), pen),
            (None, 'X') => self.screen_mut().erase_chars(params.arg(0, 1), pen),
            (None, '@') => self.screen_mut().insert_chars(params.arg(0, 1), pen),
            (None, 'm') => self.sgr(params),
            (None, 'r') => {
                let bottom = params.arg(1, self.screen().height());
                self.screen_mut()
                    .set_region(params.coord(0), bottom.saturating_sub(1));
            }
            // REP. Bounded by the screen: a child should not turn three bytes into an
            // arbitrarily long print loop.
            (None, 'b') => {
                if let Some(ch) = self.last_print {
                    let cap = self.screen().width() * self.screen().height();
                    let pen = self.pen;
                    for _ in 0..params.arg(0, 1).min(cap) {
                        let evicted = self.screen_mut().write(ch, pen);
                        self.evicted(evicted);
                    }
                }
            }
            _ => return false,
        }
        true
    }

    /// What answers the child rather than touching the grid: reports and negotiations.
    ///
    /// Returns whether the sequence belonged to this family.
    fn csi_report(
        &mut self,
        private: Option<u8>,
        action: char,
        params: &Params,
        intermediates: &[u8],
    ) -> bool {
        match (private, action) {
            // XTMODKEYS, `CSI > 4 ; Ps m`. Bare `CSI > 4 m` means "back to the default",
            // which is level 0 for our purposes.
            (Some(b'>'), 'm') => {
                if params.arg(0, 4) == 4 {
                    self.modes.modify_other_keys = params
                        .iter()
                        .nth(1)
                        .and_then(|p| p.first().copied())
                        .unwrap_or(0) as u8;
                }
            }
            // Kitty keyboard protocol: push, pop, and set. The stack is capped because a
            // child can push without ever popping, and only the top is ever read.
            (Some(b'>'), 'u') => {
                if self.modes.kitty_keys.len() < KITTY_STACK_LIMIT {
                    self.modes.kitty_keys.push(params.arg(0, 0) as u8);
                }
            }
            (Some(b'<'), 'u') => {
                for _ in 0..params.arg(0, 1).max(1) {
                    self.modes.kitty_keys.pop();
                }
            }
            (Some(b'='), 'u') => {
                let flags = params.arg(0, 0) as u8;
                match self.modes.kitty_keys.last_mut() {
                    Some(top) => *top = flags,
                    None => self.modes.kitty_keys.push(flags),
                }
            }
            // A child that probes and gets no answer may wait for one.
            (Some(b'?'), 'u') => {
                let flags = self.modes.kitty_keys.last().copied().unwrap_or(0);
                self.events
                    .push(Event::Reply(format!("\x1b[?{flags}u").into_bytes()));
            }
            // DECRQM. The machine-readable half of the terminfo audit: a mode we
            // implement answers 1 or 2, one we deliberately do not answers 4
            // ("permanently reset"), and one we have never heard of answers 0. A child
            // can therefore stop inferring our capabilities from TERM and just ask.
            (Some(b'?'), 'p') if intermediates.contains(&b'$') => {
                let mode = params.arg(0, 0) as u16;
                let status = self.dec_mode_state(mode);
                self.events.push(Event::Reply(
                    format!("\x1b[?{mode};{status}$y").into_bytes(),
                ));
            }
            // The ANSI form has `$` as its only intermediate, so it arrives here as the
            // "private" byte rather than alongside one.
            (Some(b'$'), 'p') => {
                let mode = params.arg(0, 0) as u16;
                let status = match mode {
                    4 => ModeReport::from(self.screen().insert_mode()),
                    20 => ModeReport::from(self.modes.newline_mode),
                    _ => ModeReport::Unknown,
                };
                self.events
                    .push(Event::Reply(format!("\x1b[{mode};{status}$y").into_bytes()));
            }
            // XTWINOPS, read-only. The reporting and geometry operations are refused
            // rather than merely unimplemented: `21t` answers with the window title *on
            // the child's input stream*, which turns a title the child set itself into
            // typed input at the next prompt, and `3t`/`4t`/`8t` move and resize the
            // window, which is Emacs' business and not the child's.
            (None, 't') => match params.arg(0, 0) {
                // 14 is the text area in pixels, 16 one cell. Both were unanswerable
                // until Emacs began reporting its cell size, and both are what an image
                // producer asks before deciding whether to draw at all. Silent when
                // nothing has been reported — a terminal frame has no cell size, and
                // answering zero would be a claim rather than an absence.
                14 if self.metrics.is_reported() => {
                    let (h, w) = (self.screen().height(), self.screen().width());
                    let (ph, pw) = (
                        h.saturating_mul(usize::from(self.metrics.height)),
                        w.saturating_mul(usize::from(self.metrics.width)),
                    );
                    self.events
                        .push(Event::Reply(format!("\x1b[4;{ph};{pw}t").into_bytes()));
                }
                16 if self.metrics.is_reported() => {
                    let (ch, cw) = (self.metrics.height, self.metrics.width);
                    self.events
                        .push(Event::Reply(format!("\x1b[6;{ch};{cw}t").into_bytes()));
                }
                18 => {
                    let (h, w) = (self.screen().height(), self.screen().width());
                    self.events
                        .push(Event::Reply(format!("\x1b[8;{h};{w}t").into_bytes()));
                }
                22 => self.events.push(Event::TitleStack(true)),
                23 => self.events.push(Event::TitleStack(false)),
                _ => {}
            },
            // DECSCUSR. A level, not an event: the shape is state Emacs renders from,
            // so it rides the drain rather than arriving twice.
            (Some(b' '), 'q') => {
                if let Some(shape) = CursorShape::from_param(params.arg(0, 1)) {
                    self.modes.cursor_shape = shape;
                }
            }
            // DECSTR. Unlike RIS this keeps the screen and the scrollback.
            (Some(b'!'), 'p') => self.soft_reset(),
            // Primary DA. We answer for what we implement and nothing else: VT220 level
            // (62) with sixel graphics (4) and ANSI colour (22). Not 1/132-column, not
            // 6/selective erase, not 2/printer — see the printer capabilities dropped
            // from terminfo. The 4 is load-bearing rather than decorative: it is how
            // every sixel producer in circulation decides whether to emit one at all.
            (None, 'c') => self.events.push(Event::Reply(b"\x1b[?62;4;22c".to_vec())),
            // Secondary DA. Unanswered, a child that queries and waits hangs.
            (Some(b'>'), 'c') => self.events.push(Event::Reply(b"\x1b[>0;0;0c".to_vec())),
            (None, 'n') if params.arg(0, 0) == 5 => {
                self.events.push(Event::Reply(b"\x1b[0n".to_vec()));
            }
            (None, 'n') if params.arg(0, 0) == 6 => {
                let Cursor { row, col, .. } = self.screen().cursor;
                self.events.push(Event::Reply(
                    format!("\x1b[{};{}R", row + 1, col + 1).into_bytes(),
                ));
            }
            _ => return false,
        }
        true
    }
}
