//! `CSI` dispatch, and the mode machinery it drives.

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
    ($($mode:ident => $field:ident),* $(,)?) => {
        impl State {
            /// Set a one-flag mode, or report that this is not one.
            fn set_flag_mode(&mut self, mode: DecMode, on: bool) -> bool {
                match mode {
                    $(DecMode::$mode => self.modes.$field = on,)*
                    _ => return false,
                }
                true
            }

            /// The DECRQM answer for a one-flag mode.
            fn flag_mode_state(&self, mode: DecMode) -> Option<ModeReport> {
                match mode {
                    $(DecMode::$mode => Some(self.modes.$field.into()),)*
                    _ => None,
                }
            }
        }
    };
}

dec_flags! {
    AppCursor => app_cursor,
    ReverseScreen => reverse_screen,
    CursorVisible => cursor_visible,
    AppKeypad => app_keypad,
    FocusEvents => focus_events,
    AltScroll => alt_scroll,
    BracketedPaste => bracketed_paste,
    ColorSchemeUpdates => color_scheme_updates,
    SizeReports => size_reports,
}

use super::modes::{AnsiMode, DecMode, ModeReport};
use super::*;
use crate::emu::cell::Attrs;
use crate::emu::sgr::PUSHABLE;

/// One XTPUSHSGR: the pen as it stood, and which parts of it the matching pop puts back.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct PushedPen {
    pen: Style,
    /// `SGR 58`'s colour, pushed with the pen for the reason [`sgr::apply`] gives for
    /// never holding one of the two back.
    ///
    /// [`sgr::apply`]: crate::emu::sgr::apply
    underline: Color,
    /// `None` for a bare push, which restores the whole pen.
    ///
    /// An `Option` rather than a selection with every part ticked, so that the common
    /// case is one assignment and stays exact when [`Attrs`] grows a bit: a selection
    /// written out part by part would silently leave a new attribute behind on pop.
    parts: Option<PenParts>,
}

/// The attributes a selective `CSI Pm # {` names, in xterm's numbering.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
struct PenParts {
    /// The on/off attributes among [`sgr::PUSHABLE`](crate::emu::sgr::PUSHABLE).
    flags: Attrs,
    /// 4 and 21 alike. xterm keeps double underline as an attribute of its own; here it
    /// is one of the underline's styles, so either number restores the style, and with
    /// it the underline's colour, which has no number of its own in the selection.
    underline: bool,
    fg: bool,
    bg: bool,
}

impl PenParts {
    /// The selection a push's parameters name, or `None` when they name none at all.
    ///
    /// `CSI # {` arrives with no parameters or a single default 0, and both mean "all".
    /// A list of numbers none of which xterm defines is still a selection -- of nothing
    /// -- rather than a bare push, because the child did ask for something specific.
    fn from_params(params: &Params) -> Option<Self> {
        let codes: Vec<u16> = params.values().collect();
        if codes.iter().all(|&code| code == 0) {
            return None;
        }
        let mut parts = Self::default();
        for code in codes {
            match code {
                4 | 21 => parts.underline = true,
                30 => parts.fg = true,
                31 => parts.bg = true,
                _ => {
                    if let Some(flag) = PUSHABLE.iter().find(|flag| flag.set == code) {
                        parts.flags |= flag.attr;
                    }
                }
            }
        }
        Some(parts)
    }
}

/// What XTSAVE kept for one private mode, or for one group of them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum SavedMode {
    /// A mode that is on or off, restored through [`State::dec_mode`] like any `h`/`l`.
    Flag(bool),
    /// 1000, 1002 and 1003, which are one choice of what to report rather than three
    /// flags. Replaying them as flags cannot work: with 1002 on, 1000 reads as reset, and
    /// `1000 l` would turn reporting off.
    Tracking(MouseTracking),
    /// 1006 and 1016, which are one choice of coordinate encoding for the same reason.
    Format(MouseFormat),
}

impl State {
    pub(super) fn dec_mode(&mut self, mode: DecMode, on: bool) {
        match mode {
            DecMode::Origin => {
                self.modes.origin_mode = on;
                self.screen_mut().goto(0, 0);
            }
            DecMode::Autowrap => {
                for screen in self.screens.each_mut() {
                    screen.set_autowrap(on);
                }
            }
            // A set chooses the tracking mode and a reset of any of the three turns
            // tracking off, whichever was in force; see [`MouseTracking`].
            DecMode::MouseClick | DecMode::MouseDrag | DecMode::MouseMotion => {
                self.modes.mouse.tracking = match (on, mode) {
                    (false, _) => MouseTracking::Off,
                    (true, DecMode::MouseClick) => MouseTracking::Click,
                    (true, DecMode::MouseDrag) => MouseTracking::Drag,
                    (true, _) => MouseTracking::Motion,
                };
                self.events.push(Event::Mouse(self.modes.mouse));
            }
            // xterm's rule, and the reason the format is one field: a set replaces
            // whichever coordinate mode was in force, and a reset is effective only
            // against its own. A child that sets 1016 over 1006 and then resets 1006 on
            // the way out of some subroutine has not asked for X10 back.
            DecMode::MouseSgr | DecMode::MouseSgrPixels => {
                let format = if mode == DecMode::MouseSgr {
                    MouseFormat::Sgr
                } else {
                    MouseFormat::SgrPixels
                };
                let mouse = &mut self.modes.mouse;
                if on {
                    mouse.format = format;
                } else if mouse.format == format {
                    mouse.format = MouseFormat::X10;
                }
                self.events.push(Event::Mouse(self.modes.mouse));
            }
            DecMode::AltScreenLegacy | DecMode::AltScreen => self.set_alt(on),
            DecMode::SaveCursor if on => self.save_cursor(),
            DecMode::SaveCursor => self.restore_cursor(),
            // Save, switch, ... switch back, restore. The save and the restore have to
            // bracket the switch, because `restore_cursor` acts on whichever screen is
            // showing: run before `set_alt(false)` it would read the alternate screen's
            // saved cursor and leave the primary's -- the one `1049 h` saved -- untouched.
            // A resize inside a full-screen program moves the primary's cursor, so that
            // is the case that would lose the position.
            DecMode::AltScreenSaveCursor => {
                if on {
                    self.save_cursor();
                    self.set_alt(true);
                } else {
                    self.set_alt(false);
                    self.restore_cursor();
                }
            }
            DecMode::SynchronizedOutput => {
                self.modes.sync_until = on.then(|| std::time::Instant::now() + SYNC_TIMEOUT);
            }
            // Declined or permanent, so a set or a reset changes nothing; see
            // [`State::dec_mode_state`] for what each answers.
            DecMode::Columns132
            | DecMode::SmoothScroll
            | DecMode::CursorBlink
            | DecMode::ReverseWrap
            | DecMode::BackarrowSendsBackspace
            | DecMode::LeftRightMargins
            | DecMode::MouseUtf8
            | DecMode::MouseUrxvt
            | DecMode::EightBitMeta
            | DecMode::MetaSendsEscape
            | DecMode::AltSendsEscape
            | DecMode::ReverseWrapExtended
            | DecMode::GraphemeClusters => {}
            // The one flag whose setting is also a report. Subscribing is how the child
            // learns the size it is starting from, so the answer goes out on every
            // `2048 h`, set already or not: a multiplexer reattaching is asking just as
            // much as the first subscriber was.
            DecMode::SizeReports => {
                self.set_flag_mode(mode, on);
                if on {
                    let report = self.current_size_report();
                    self.events.push(Event::SizeReport(report));
                }
            }
            DecMode::AppCursor
            | DecMode::ReverseScreen
            | DecMode::CursorVisible
            | DecMode::AppKeypad
            | DecMode::FocusEvents
            | DecMode::AltScroll
            | DecMode::BracketedPaste
            | DecMode::ColorSchemeUpdates => {
                self.set_flag_mode(mode, on);
            }
        }
    }

    /// DECRQM's answer for a private mode, or [`ModeReport::Unknown`] for a number cooked
    /// has no [`DecMode`] for.
    pub(super) fn dec_mode_report(&self, number: u16) -> ModeReport {
        DecMode::try_from(number).map_or(ModeReport::Unknown, |mode| self.dec_mode_state(mode))
    }

    /// DECRQM's answer for a private mode.
    ///
    /// The one-flag modes are read through the same table that sets them, so the two
    /// cannot disagree about which field a number names.
    pub(super) fn dec_mode_state(&self, mode: DecMode) -> ModeReport {
        let mouse = self.modes.mouse;
        match mode {
            DecMode::Origin => self.modes.origin_mode.into(),
            DecMode::Autowrap => self.screen().autowrap().into(),
            DecMode::MouseClick => (mouse.tracking == MouseTracking::Click).into(),
            DecMode::MouseDrag => (mouse.tracking == MouseTracking::Drag).into(),
            DecMode::MouseMotion => (mouse.tracking == MouseTracking::Motion).into(),
            DecMode::MouseSgr => (mouse.format == MouseFormat::Sgr).into(),
            DecMode::MouseSgrPixels => mouse.pixels().into(),
            DecMode::SynchronizedOutput => self
                .modes
                .sync_until
                .is_some_and(|t| std::time::Instant::now() < t)
                .into(),
            DecMode::AltScreenLegacy | DecMode::AltScreen | DecMode::AltScreenSaveCursor => {
                self.shown.is_alternate().into()
            }
            // Implemented, but stateless -- it saves and restores rather than turning
            // anything on -- so set is the only honest answer that is not unknown. Not
            // `PermanentlySet`: xterm answers 1 here, and a child that reads 3 concludes
            // the mode cannot be reset.
            DecMode::SaveCursor => ModeReport::Set,
            // Meta sends ESC before the key always: it is how `cooked--encode-event'
            // spells Meta on every key the negotiated protocols do not re-encode. Not 4,
            // which would tell a child that M-x arrives as something other than ESC x.
            DecMode::MetaSendsEscape => ModeReport::PermanentlySet,
            // Not settable because there is nothing to turn off: the segmenter is how
            // every character reaches the grid, and the per-code-point rule a reset would
            // restore puts a ZWJ family on six cells. `emu::text`'s header argues the one
            // rule where this departs from the draft, VS15 narrowing.
            DecMode::GraphemeClusters => ModeReport::PermanentlySet,
            // Declined, and answered 4 rather than 0 so that a child learns it without a
            // retry or a fallback probe. The reason for each is on its variant. The list
            // is `# declined-modes:' in cooked.ti, and the audit test holds the two in
            // step.
            DecMode::Columns132
            | DecMode::SmoothScroll
            | DecMode::CursorBlink
            | DecMode::ReverseWrap
            | DecMode::BackarrowSendsBackspace
            | DecMode::LeftRightMargins
            | DecMode::MouseUtf8
            | DecMode::MouseUrxvt
            | DecMode::EightBitMeta
            | DecMode::AltSendsEscape
            | DecMode::ReverseWrapExtended => ModeReport::PermanentlyReset,
            DecMode::AppCursor
            | DecMode::ReverseScreen
            | DecMode::CursorVisible
            | DecMode::AppKeypad
            | DecMode::FocusEvents
            | DecMode::AltScroll
            | DecMode::BracketedPaste
            | DecMode::ColorSchemeUpdates
            | DecMode::SizeReports => self.flag_mode_state(mode).unwrap_or(ModeReport::Unknown),
        }
    }

    pub(super) fn ansi_mode(&mut self, mode: AnsiMode, on: bool) {
        match mode {
            AnsiMode::Insert => {
                for screen in self.screens.each_mut() {
                    screen.set_insert_mode(on);
                }
            }
            AnsiMode::Newline => self.modes.newline_mode = on,
        }
    }

    /// DECRQM's answer for an ANSI mode.
    fn ansi_mode_report(&self, number: u16) -> ModeReport {
        match AnsiMode::try_from(number) {
            Ok(AnsiMode::Insert) => self.screen().insert_mode().into(),
            Ok(AnsiMode::Newline) => self.modes.newline_mode.into(),
            Err(_) => ModeReport::Unknown,
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
        for screen in self.screens.each_mut() {
            screen.reset_region();
            screen.set_autowrap(true);
            screen.set_insert_mode(false);
            screen.forget_saved_cursor();
        }
        self.saved_charsets = PerScreen::default();
        if had_mouse {
            self.events.push(Event::Mouse(self.modes.mouse));
        }
    }

    /// DECSC: the cursor and the character sets, for the screen being shown.
    pub(super) fn save_cursor(&mut self) {
        self.saved_charsets[self.shown] = Some(self.modes.charsets);
        self.screen_mut().save_cursor();
    }

    /// DECRC: put back what [`State::save_cursor`] kept on this screen, if anything.
    pub(super) fn restore_cursor(&mut self) {
        if let Some(charsets) = self.saved_charsets[self.shown].take() {
            self.modes.charsets = charsets;
        }
        self.screen_mut().restore_cursor();
    }

    /// XTSAVE, `CSI ? Pm s`, for one mode.
    ///
    /// Only a mode with a level to put back is saved: an unknown or declined mode has
    /// none, 1048 is itself a save rather than a setting, and 2026 is the opening of a
    /// frame, which restored later would hold redisplay for a frame nobody is drawing.
    /// The mouse groups are saved whole, into the slot their group shares; see
    /// [`DecMode::save_slot`].
    fn save_mode(&mut self, mode: DecMode) {
        let value = match mode {
            DecMode::MouseClick | DecMode::MouseDrag | DecMode::MouseMotion => {
                SavedMode::Tracking(self.modes.mouse.tracking)
            }
            DecMode::MouseSgr | DecMode::MouseSgrPixels => {
                SavedMode::Format(self.modes.mouse.format)
            }
            DecMode::SaveCursor | DecMode::SynchronizedOutput => return,
            _ => match self.dec_mode_state(mode) {
                ModeReport::Set => SavedMode::Flag(true),
                ModeReport::Reset => SavedMode::Flag(false),
                _ => return,
            },
        };
        let slot = mode.save_slot();
        let slots = &mut self.modes.saved_modes;
        match slots.iter_mut().find(|(saved, _)| *saved == slot) {
            Some(entry) => entry.1 = value,
            None => slots.push((slot, value)),
        }
    }

    /// XTRESTORE, `CSI ? Pm r`, for one mode.
    ///
    /// The slot is kept rather than consumed, as xterm keeps it, so a second restore puts
    /// back the same value. And nothing happens when the mode already stands where it
    /// was saved: a restore is a request for a state, not a replay of `h`/`l`, and
    /// replaying would home the cursor for DECOM or announce a mouse change that is not
    /// one.
    fn restore_mode(&mut self, mode: DecMode) {
        let slot = mode.save_slot();
        let Some(&(_, value)) = self
            .modes
            .saved_modes
            .iter()
            .find(|(saved, _)| *saved == slot)
        else {
            return;
        };
        match value {
            SavedMode::Flag(on) => {
                if self.dec_mode_state(mode) != ModeReport::from(on) {
                    self.dec_mode(mode, on);
                }
            }
            SavedMode::Tracking(saved) => {
                if self.modes.mouse.tracking != saved {
                    self.modes.mouse.tracking = saved;
                    self.events.push(Event::Mouse(self.modes.mouse));
                }
            }
            SavedMode::Format(saved) => {
                if self.modes.mouse.format != saved {
                    self.modes.mouse.format = saved;
                    self.events.push(Event::Mouse(self.modes.mouse));
                }
            }
        }
    }

    /// XTPUSHSGR, `CSI Pm # {`: keep the pen, or the parts of it PARAMS names.
    ///
    /// The pen and not the cursor, which is the whole difference from DECSC: a program
    /// can colour a span and put back exactly the rendition it found, without knowing
    /// what that was and without moving.
    fn push_pen(&mut self, params: &Params) {
        if self.modes.pen_stack.len() < SGR_STACK_LIMIT {
            self.modes.pen_stack.push(PushedPen {
                pen: self.pen,
                underline: self.underline,
                parts: PenParts::from_params(params),
            });
        }
    }

    /// XTPOPSGR, `CSI # }`. A pop with nothing pushed changes nothing.
    fn pop_pen(&mut self) {
        let Some(PushedPen {
            pen,
            underline,
            parts,
        }) = self.modes.pen_stack.pop()
        else {
            return;
        };
        let Some(parts) = parts else {
            (self.pen, self.underline) = (pen, underline);
            return;
        };
        for flag in PUSHABLE.iter().map(|flag| flag.attr) {
            if !parts.flags.contains(flag) {
                continue;
            }
            if pen.attrs.contains(flag) {
                self.pen.attrs |= flag;
            } else {
                self.pen.attrs.remove(flag);
            }
        }
        if parts.underline {
            self.pen
                .attrs
                .set_underline_style(pen.attrs.underline_style());
            self.underline = underline;
        }
        if parts.fg {
            self.pen.fg = pen.fg;
        }
        if parts.bg {
            self.pen.bg = pen.bg;
        }
    }

    /// `CSI Ps m`, decoded by the one decoder both performers share.
    ///
    /// The arm itself is [`sgr::apply`](crate::emu::sgr::apply): the grid is not the only
    /// thing in this crate that keeps a pen, and a second copy of this table is a
    /// divergence waiting to be discovered by a user rather than by a test.
    pub(super) fn sgr(&mut self, params: &Params) {
        crate::emu::sgr::apply(params, &mut self.pen, &mut self.underline);
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

    /// DEC private and ANSI mode set/reset (`CSI ? Ps h/l`, `CSI Ps h/l`), and the save
    /// and restore of private modes (`CSI ? Pm s/r`).
    ///
    /// Returns whether the sequence belonged to this family.
    fn csi_mode(&mut self, private: Option<u8>, action: char, params: &Params) -> bool {
        match (private, action) {
            (Some(b'?'), 'h' | 'l') => {
                let on = action == 'h';
                for mode in params.values().filter_map(|n| DecMode::try_from(n).ok()) {
                    self.dec_mode(mode, on);
                }
            }
            (None, 'h' | 'l') => {
                let on = action == 'h';
                for mode in params.values().filter_map(|n| AnsiMode::try_from(n).ok()) {
                    self.ansi_mode(mode, on);
                }
            }
            // XTSAVE and XTRESTORE. The `?` is the whole of what tells these from SCOSC
            // and DECSTBM, `CSI s` and `CSI r`, which arrive with no private byte and are
            // dispatched in their own families below.
            (Some(b'?'), 's' | 'r') => {
                for mode in params.values().filter_map(|n| DecMode::try_from(n).ok()) {
                    if action == 's' {
                        self.save_mode(mode);
                    } else {
                        self.restore_mode(mode);
                    }
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
                let row = self.screen().cursor().row;
                self.screen_mut().goto(row, params.coord(0));
            }
            (None, 'H' | 'f') => {
                let top = if self.modes.origin_mode {
                    self.screen().region().top
                } else {
                    0
                };
                let (row, col) = (params.coord(0) + top, params.coord(1));
                self.screen_mut().goto(row, col);
            }
            (None, 'd') => {
                let col = self.screen().cursor().col;
                self.screen_mut().goto(params.coord(0), col);
            }
            (None, 'g') => match params.arg(0, 0) {
                0 => self.screen_mut().clear_tab(),
                3 => self.screen_mut().clear_all_tabs(),
                _ => {}
            },
            // DECST8C. `CSI ? 5 W` and no other parameter: the unprefixed `CSI Ps W` is CTC,
            // whose 5 clears every stop rather than resetting them, and is not implemented.
            (Some(b'?'), 'W') if params.arg(0, 0) == 5 => self.screen_mut().reset_tabs(),
            (None, 'Z') => self.screen_mut().back_tab(params.arg(0, 1)),
            (None, 'I') => self.screen_mut().tab(params.arg(0, 1)),
            (None, 's') => self.save_cursor(),
            (None, 'u') => self.restore_cursor(),
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
                    self.erase_display(how, pen);
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
                self.evicting(|screen| screen.scroll_up(n, pen));
            }
            (None, 'T') => self.screen_mut().scroll_down(params.arg(0, 1), pen),
            (None, 'X') => self.screen_mut().erase_chars(params.arg(0, 1), pen),
            (None, '@') => self.screen_mut().insert_chars(params.arg(0, 1), pen),
            (None, 'm') => self.sgr(params),
            // XTPUSHSGR and XTPOPSGR, in both of xterm's spellings: `{`/`}` and the
            // older `p`/`q`.
            (Some(b'#'), '{' | 'p') => self.push_pen(params),
            (Some(b'#'), '}' | 'q') => self.pop_pen(),
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
                        self.evicting(|screen| screen.write(ch, pen));
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
            // which is no level at all for our purposes.
            (Some(b'>'), 'm') => {
                if params.arg(0, 4) == 4 {
                    self.modes.modify_other_keys =
                        ModifyOtherKeys::from_param(params.arg(1, 0) as u16);
                }
            }
            // Kitty keyboard protocol: push, pop, and set, each on the stack of the screen
            // being shown. See [`KittyStack`] for the cap and why a full push evicts.
            (Some(b'>'), 'u') => {
                let flags = KittyFlags::from_bits_retain(params.arg(0, 0) as u8);
                self.kitty_stack_mut().push(flags);
            }
            (Some(b'<'), 'u') => self.kitty_stack_mut().pop(params.arg(0, 1)),
            (Some(b'='), 'u') => {
                let flags = KittyFlags::from_bits_retain(params.arg(0, 0) as u8);
                self.kitty_stack_mut().set(flags, params.arg(1, 1));
            }
            // A child that probes and gets no answer may wait for one.
            //
            // Masked to what is actually honoured, which is not what was pushed. The
            // stack keeps whatever the child asked for -- a pop has to restore exactly
            // what its matching push put there -- but the *reply* is a claim about this
            // terminal, and echoing a flag back unmasked tells the child cooked
            // implements something it does not. A child that asks for alternate keys or
            // associated text, is told yes, and then encodes for them is a child cooked
            // has actively misled; a child told no falls back to a spelling that works.
            (Some(b'?'), 'u') => {
                let flags = self.kitty_flags();
                self.csi_reply(format_args!("?{flags}u"));
            }
            // DECRQM. The machine-readable half of the terminfo audit: a mode we
            // implement answers 1 or 2, one we deliberately do not answers 4
            // ("permanently reset"), and one we have never heard of answers 0. A child
            // can therefore stop inferring our capabilities from TERM and just ask.
            (Some(b'?'), 'p') if intermediates.contains(&b'$') => {
                let mode = params.arg(0, 0) as u16;
                let status = self.dec_mode_report(mode);
                self.csi_reply(format_args!("?{mode};{status}$y"));
            }
            // The ANSI form has `$` as its only intermediate, so it arrives here as the
            // "private" byte rather than alongside one.
            (Some(b'$'), 'p') => {
                let mode = params.arg(0, 0) as u16;
                let status = self.ansi_mode_report(mode);
                self.csi_reply(format_args!("{mode};{status}$y"));
            }
            // XTWINOPS. The reports are answered and most of the operations refused
            // rather than merely unimplemented: `21t` answers with the window title *on
            // the child's input stream*, which turns a title the child set itself into
            // typed input at the next prompt, and `3t`/`4t`/`9t`/`10t`/`13t` move,
            // iconify or maximise the frame, which is Emacs' business and not the
            // child's. A resize (`8t`, and DECSLPP) is the one operation passed on, as a
            // request Lisp is free to refuse -- see `Event::ResizeRequest`.
            (None, 't') => match params.arg(0, 0) {
                // Not iconified. Always true of a window that is receiving output, and
                // the one state report with nothing to measure.
                11 => self.csi_reply(format_args!("1t")),
                // 14 is the text area in pixels, 16 one cell. Both were unanswerable
                // until Emacs began reporting its cell size, and both are what an image
                // producer asks before deciding whether to draw at all. Silent when
                // nothing has been reported — a terminal frame has no cell size, and
                // answering zero would be a claim rather than an absence.
                14 => {
                    if let Some(area) = self.text_area() {
                        let (ph, pw) = (area.h, area.w);
                        self.csi_reply(format_args!("4;{ph};{pw}t"));
                    }
                }
                16 => {
                    if let Some(metrics) = self.metrics {
                        let (ch, cw) = (metrics.height(), metrics.width());
                        self.csi_reply(format_args!("6;{ch};{cw}t"));
                    }
                }
                18 => {
                    let (h, w) = (self.screen().height(), self.screen().width());
                    self.csi_reply(format_args!("8;{h};{w}t"));
                }
                // The frame, which only Emacs can measure. Lisp answers, and answers
                // `15t` only where there are pixels, by the same rule as `14t` above.
                15 => self.events.push(Event::FrameSize(Unit::Pixels)),
                19 => self.events.push(Event::FrameSize(Unit::Cells)),
                22 => self.events.push(Event::TitleStack(StackOp::Push)),
                23 => self.events.push(Event::TitleStack(StackOp::Pop)),
                // A 0 or omitted argument means "leave this dimension", which `arg`'s
                // fallback of 0 folds together with an absent one. A request to leave
                // both is no request.
                8 => {
                    let dim = |i| u16::try_from(params.arg(i, 0)).ok().filter(|&n| n != 0);
                    let (rows, cols) = (dim(1), dim(2));
                    if rows.is_some() || cols.is_some() {
                        self.events.push(Event::ResizeRequest(rows, cols));
                    }
                }
                // DECSLPP: set lines per page. The row count alone, from the VT340, which
                // xterm reads any `CSI Ps t` of 24 or more as.
                lines @ 24.. => {
                    let rows = u16::try_from(lines).unwrap_or(u16::MAX);
                    self.events.push(Event::ResizeRequest(Some(rows), None));
                }
                _ => {}
            },
            // XTSMGRAPHICS, `CSI ? Pi ; Pa ; Pv S`. What a sixel producer asks once it
            // has seen the `4` in our primary DA: how many colour registers it may use,
            // and how many pixels it has to draw into. Unanswered it is the same hang the
            // secondary DA stub exists to prevent -- worse, in fact, because DA1 is what
            // invited the question.
            //
            // Every path here answers, including the ones that answer "no". The protocol
            // carries its own status field -- 0 success, 1 "no such item", 2 "no such
            // action", 3 failure -- so declining out loud costs one number and is what
            // the kitty path already does with `ENOTSUPPORTED`. Silence is only right
            // where the protocol has no way to say "not yet"; here it has one.
            (Some(b'?'), 'S') => {
                let (item, action) = (params.arg(0, 0), params.arg(1, 0));
                match item {
                    // Nothing sixel can draw would be shown, so neither item has an
                    // answer worth giving: failure, which a producer that ignored the
                    // missing `4` in DA1 reads the same way. Registers and geometry
                    // alike, because a palette size is only a promise about a picture.
                    1 | 2 if self.graphics_hidden => {
                        self.csi_reply(format_args!("?{item};3S"));
                    }
                    // Colour registers. Fixed at the palette the sixel decoder actually
                    // allocates, so the answer cannot drift from what a stream may
                    // address. Reading (1) and reading the maximum (4) are the same
                    // number because there is only ever one, and so is resetting to the
                    // default (2) -- the default is all there is. Setting (3) is refused:
                    // a child cannot enlarge a compile-time array.
                    1 => {
                        let registers = sixel::PALETTE_SIZE;
                        let status = if action == 3 { 3 } else { 0 };
                        self.csi_reply(format_args!("?1;{status};{registers}S"));
                    }
                    // Sixel geometry, in pixels. The same product `14t` reports, from the
                    // same cell metrics Emacs hands us, so the two reports cannot come to
                    // disagree about how big the screen is.
                    //
                    // The maximum (4) is the current size as well, deliberately. The
                    // decoder's own bound is on a picture's *area* (`sixel::MAX_PIXELS`),
                    // not on either axis, so there is no honest per-axis maximum to
                    // report except the one the screen sets -- and a picture wider than
                    // the screen has nowhere to be drawn whole regardless.
                    //
                    // Where `14t` falls silent on unreported metrics, this answers
                    // failure (3). Both say "no size to report"; the difference is that
                    // XTWINOPS has no way to spell that and this does, and a producer
                    // waiting on an answer is owed one. Setting or resetting the geometry
                    // is refused the same way: the window is Emacs' and not the child's,
                    // which is why `3t`/`4t` are refused above and `8t` only asks.
                    2 => match self.text_area().filter(|_| action == 1 || action == 4) {
                        // Width first here, where `14t` above reports height first. The
                        // two sequences genuinely disagree about the order.
                        Some(area) => {
                            let (pw, ph) = (area.w, area.h);
                            self.csi_reply(format_args!("?2;0;{pw};{ph}S"));
                        }
                        None => self.csi_reply(format_args!("?2;3S")),
                    },
                    // ReGIS (3) and anything else: an item we do not have, which is what
                    // status 1 means.
                    other => self.csi_reply(format_args!("?{other};1S")),
                }
            }
            // XTVERSION, `CSI > 0 q`. terminfo's `XR` names this, so a child that reads
            // our entry is entitled to an answer -- and the answer names *cooked*. Every
            // other terminal replies with the program it is, and the whole use of the
            // query is telling them apart; answering `XTerm(...)` because that is what
            // the sequence's name says would hand every feature-detecting client a
            // capability list belonging to a different program.
            //
            // The version is the crate's own, so a release cannot ship a stale one.
            (Some(b'>'), 'q') if params.arg(0, 0) == 0 => {
                self.dcs_reply(format_args!(">|cooked({})", env!("CARGO_PKG_VERSION")));
            }
            // DECSCUSR. A level, not an event: the shape is state Emacs renders from,
            // so it rides the drain rather than arriving twice.
            (Some(b' '), 'q') => {
                let param = params.arg(0, 1);
                if let Some(shape) = CursorShape::from_param(param) {
                    self.modes.cursor_shape = shape;
                    self.modes.cursor_blink = param < 2 || param % 2 == 1;
                }
            }
            // DECSTR. Unlike RIS this keeps the screen and the scrollback.
            (Some(b'!'), 'p') => self.soft_reset(),
            // Primary DA. We answer for what we implement and nothing else: VT220 level
            // (62) with sixel graphics (4) and ANSI colour (22). Not 1/132-column, not
            // 6/selective erase, not 2/printer — see the printer capabilities dropped
            // from terminfo. The 4 is load-bearing rather than decorative: it is how
            // every sixel producer in circulation decides whether to emit one at all.
            //
            // Which is why it goes when Emacs has said a picture cannot be shown here
            // (`graphics_hidden`). A producer that finds no `4` does not give up: chafa,
            // timg and their kind draw with half blocks instead, and that renders on a
            // terminal frame or with `cooked-inline-images` off, where a sixel would
            // leave a blank rectangle.
            (None, 'c') if self.graphics_hidden => self.csi_reply(format_args!("?62;22c")),
            (None, 'c') => self.csi_reply(format_args!("?62;4;22c")),
            // Secondary DA. Unanswered, a child that queries and waits hangs.
            (Some(b'>'), 'c') => self.csi_reply(format_args!(">0;0;0c")),
            // Tertiary DA, the unit id, as `DCS ! | 00000000 ST`. Nothing in cooked has a
            // serial number worth reporting, and zero is what xterm sends too; the reply
            // exists for the same reason as DA2's, which is that a child asking the
            // question waits for an answer.
            (Some(b'='), 'c') if params.arg(0, 0) == 0 => {
                self.dcs_reply(format_args!("!|00000000"));
            }
            (None, 'n') if params.arg(0, 0) == 5 => {
                self.csi_reply(format_args!("0n"));
            }
            (None, 'n') if params.arg(0, 0) == 6 => {
                let Cursor { row, col, .. } = self.screen().cursor();
                self.csi_reply(format_args!("{};{}R", row + 1, col + 1));
            }
            // The colour scheme, `CSI ? 996 n`. Silent until Emacs has reported one: the
            // protocol defines dark and light and nothing else, so there is no way to say
            // "not yet" that a child could read. The `996` guard is what keeps every other
            // private DSR -- `CSI ? 6 n`, `CSI ? 15 n` -- falling through to unimplemented
            // rather than being swallowed here.
            (Some(b'?'), 'n') if params.arg(0, 0) == 996 => {
                if let Some(scheme) = self.color_scheme {
                    self.events.push(Event::Reply(color_scheme_report(scheme)));
                }
            }
            _ => return false,
        }
        true
    }

    /// DECRQSS, `DCS $ q Pt ST`: answer with the sequence that would recreate the
    /// setting NAME names, as `DCS 1 $ r <sequence> ST`, or `DCS 0 $ r ST` for a name
    /// not answered.
    ///
    /// Beside the CSI reports rather than with the DCS plumbing in graphics.rs because
    /// every setting it can name is a CSI one, and the answer is read off the same state
    /// those arms write. What is answered is what cooked implements and nothing more:
    ///
    /// - `m`, the pen, spelled by [`sgr::describe`](crate::emu::sgr::describe) so that it
    ///   parses back through the one decoder to the same pen. This is the one a real
    ///   client leans on: neovim sets `48:2::1:2:3`, asks, and turns on `termguicolors`
    ///   if it gets the colour back -- the truecolour probe that works over ssh, where
    ///   no terminfo entry is.
    /// - `r`, DECSTBM, the active screen's region, one-based and inclusive as it is set.
    /// - `SP q`, DECSCUSR, with the blink the child asked for; see `Modes::cursor_blink`.
    /// - `"p`, DECSCL, as `62;1` -- VT220 level, matching the `62` in the primary DA, with
    ///   7-bit controls, which are the only kind any reply here is sent in.
    ///
    /// `s` (DECSLRM) is refused with the rest: left and right margins are declined, and
    /// answering with the full width would claim a setting a child cannot make.
    ///
    /// Every refusal still replies. The protocol has a spelling for "no", and a child
    /// that asks and hears nothing waits out its timeout.
    pub(super) fn status_report(&mut self, name: &[u8]) {
        match name {
            b"m" => {
                let sgr = crate::emu::sgr::describe(self.pen, self.underline);
                self.dcs_reply(format_args!("1$r{sgr}m"));
            }
            b"r" => {
                let region = self.screen().region();
                let (top, bottom) = (region.top + 1, region.bottom + 1);
                self.dcs_reply(format_args!("1$r{top};{bottom}r"));
            }
            b" q" => {
                let style = self.modes.cursor_shape.param(self.modes.cursor_blink);
                self.dcs_reply(format_args!("1$r{style} q"));
            }
            b"\"p" => self.dcs_reply(format_args!("1$r62;1\"p")),
            _ => self.dcs_reply(format_args!("0$r")),
        }
    }
}
