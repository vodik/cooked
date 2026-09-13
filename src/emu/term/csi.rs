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
    /// Permanently on: the behaviour the mode asks for is the only one there is, so a
    /// reset would be a lie. Mode 2027 and 1036, Meta sending ESC, answer this.
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
    2031 => color_scheme_updates,
    2048 => size_reports,
}

use super::*;
use crate::emu::cell::Attrs;

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
    /// The on/off attributes among [`PEN_FLAGS`].
    flags: Attrs,
    /// 4 and 21 alike. xterm keeps double underline as an attribute of its own; here it
    /// is one of the underline's styles, so either number restores the style, and with
    /// it the underline's colour, which has no number of its own in the selection.
    underline: bool,
    fg: bool,
    bg: bool,
}

/// The attributes that are a single bit, which a selective pop copies bit by bit.
const PEN_FLAGS: [Attrs; 7] = [
    Attrs::BOLD,
    Attrs::FAINT,
    Attrs::ITALIC,
    Attrs::BLINK,
    Attrs::REVERSE,
    Attrs::CONCEAL,
    Attrs::STRIKE,
];

impl PenParts {
    /// The selection a push's parameters name, or `None` when they name none at all.
    ///
    /// `CSI # {` arrives with no parameters or a single default 0, and both mean "all".
    /// A list of numbers none of which xterm defines is still a selection -- of nothing
    /// -- rather than a bare push, because the child did ask for something specific.
    fn from_params(params: &Params) -> Option<Self> {
        let codes: Vec<u16> = params.iter().filter_map(|p| p.first().copied()).collect();
        if codes.iter().all(|&code| code == 0) {
            return None;
        }
        let mut parts = Self::default();
        for code in codes {
            match code {
                1 => parts.flags |= Attrs::BOLD,
                2 => parts.flags |= Attrs::FAINT,
                3 => parts.flags |= Attrs::ITALIC,
                4 | 21 => parts.underline = true,
                5 => parts.flags |= Attrs::BLINK,
                7 => parts.flags |= Attrs::REVERSE,
                8 => parts.flags |= Attrs::CONCEAL,
                9 => parts.flags |= Attrs::STRIKE,
                30 => parts.fg = true,
                31 => parts.bg = true,
                _ => {}
            }
        }
        Some(parts)
    }
}

/// What XTSAVE kept for one private mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum SavedMode {
    /// A mode that is on or off, restored through [`State::dec_mode`] like any `h`/`l`.
    Flag(bool),
    /// 1000, 1002 and 1003, which are not three flags but one choice of what to report.
    ///
    /// Saved whole, as xterm saves its single mouse-mode value for any of the three
    /// numbers. Restoring them as flags cannot work: with 1002 on, 1000 reads as reset,
    /// and replaying `1000 l` would clear the click reporting 1002 depends on. The
    /// encoding bit, 1006, is a separate mode and is left out of this.
    Tracking(Mouse),
}

impl State {
    pub(super) fn dec_mode(&mut self, mode: u16, on: bool) {
        if self.set_flag_mode(mode, on) {
            // The one flag whose setting is also a report. Subscribing is how the child
            // learns the size it is starting from, so the answer goes out on every
            // `2048 h`, set already or not -- a second subscriber in the same session,
            // a multiplexer reattaching, is asking just as much as the first was.
            if mode == 2048 && on {
                let report = self.current_size_report();
                self.events.push(Event::Reply(report));
            }
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
            1000 | 1002 | 1003 | 1006 | 1016 => {
                let mouse = &mut self.modes.mouse;
                match mode {
                    1000 => mouse.click = on,
                    1002 => (mouse.click, mouse.drag) = (on, on),
                    1003 => (mouse.click, mouse.motion) = (on, on),
                    _ => {
                        let format = if mode == 1006 {
                            MouseFormat::Sgr
                        } else {
                            MouseFormat::SgrPixels
                        };
                        // xterm's rule, and the reason this is one field: a set replaces
                        // whichever coordinate mode was in force, and a reset is effective
                        // only against its own. A child that sets 1016 over 1006 and then
                        // resets 1006 on the way out of some subroutine has not asked for
                        // X10 back, and would be handed it by a flag cleared blindly.
                        if on {
                            mouse.format = format;
                        } else if mouse.format == format {
                            mouse.format = MouseFormat::X10;
                        }
                    }
                }
                // Emitted inside the arm rather than after the match: out there it would
                // have to re-test the same five numbers to know one of them was handled.
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
            1006 => (mouse.format == MouseFormat::Sgr).into(),
            1016 => mouse.pixels().into(),
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
            // Meta sends ESC before the key, always, and nothing a child can send turns
            // that off: it is how `cooked--encode-event' spells Meta on every key the
            // negotiated protocols do not re-encode, which is exactly the reach xterm
            // gives `metaSendsEscape'. So the honest answer is "on, for good" -- not 4,
            // which would tell a child that M-x arrives as something other than ESC x.
            1036 => ModeReport::PermanentlySet,
            // Dropped from our terminfo, and this is where a child finds that out
            // without having to guess: 5 is reverse screen (`flash'), 12 cursor blink
            // (`blink-cursor-mode' is the user's), 69 left-right margins, 1034
            // eight-bit meta. 3 and 4 were never claimed, but `is2' and `rs2' reset
            // them -- 132 columns and smooth scroll, neither of which a buffer has -- so
            // a child reading the entry has seen their numbers and may well ask.
            //
            // The rest were never in the entry and are decided against all the same, and
            // 4 rather than 0 is what saves a child a retry or a fallback probe. 45 and
            // 1045 are reverse wraparound, which `bw' would claim and the entry leaves
            // out because nothing here lets a backspace cross into the row above. 1005
            // and 1015 are the UTF-8 and urxvt mouse encodings, both superseded by 1006
            // and ambiguous where it is not. 1039 is Alt sending ESC, which matters only
            // where Alt and Meta are different keys -- and there Emacs reports an `alt'
            // modifier cooked does not spell at all; on the usual keyboard Alt *is* Meta
            // and 1036 answers for it. 67 is DECBKM, backarrow sending BS, and `kbs=^?'
            // fixes it at DEL.
            //
            // The list is `# declined-modes:' in cooked.ti, and the audit test holds the
            // two in step.
            3 | 4 | 5 | 12 | 45 | 67 | 69 | 1005 | 1015 | 1034 | 1039 | 1045 => {
                ModeReport::PermanentlyReset
            }
            // Grapheme cluster segmentation, in contour's terminal-unicode-core sense.
            // Not settable because there is nothing to turn off: the segmenter is how
            // every character reaches the grid, and the per-code-point rule a reset
            // would restore is the bug that put a ZWJ family on six cells. The one rule
            // where this departs from the draft's wording — VS15 narrows — is argued in
            // `emu::text`'s header. `dec_mode` ignores a set or reset of it, as it does
            // any number it has no arm for.
            2027 => ModeReport::PermanentlySet,
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
        self.saved_charsets = [None; 2];
        if had_mouse {
            self.events.push(Event::Mouse(self.modes.mouse));
        }
    }

    pub(super) fn save_restore(&mut self, save: bool) {
        let charsets = self.modes.charsets;
        let saved = &mut self.saved_charsets[usize::from(self.on_alt)];
        if save {
            *saved = Some(charsets);
        } else if let Some(charsets) = saved.take() {
            self.modes.charsets = charsets;
        }
        let screen = self.screen_mut();
        if save {
            screen.saved = Some(screen.cursor);
        } else if let Some(cursor) = screen.saved.take() {
            screen.goto(cursor.row, cursor.col);
        }
    }

    /// XTSAVE, `CSI ? Pm s`, for one mode.
    ///
    /// Only a mode with a level to put back is saved: an unknown or declined mode has
    /// none, 1048 is itself a save rather than a setting, and 2026 is the opening of a
    /// frame, which restored later would hold redisplay for a frame nobody is drawing.
    fn save_mode(&mut self, mode: u16) {
        let value = match mode {
            1000 | 1002 | 1003 => SavedMode::Tracking(self.modes.mouse),
            1048 | 2026 => return,
            _ => match self.dec_mode_state(mode) {
                ModeReport::Set => SavedMode::Flag(true),
                ModeReport::Reset => SavedMode::Flag(false),
                _ => return,
            },
        };
        let slots = &mut self.modes.saved_modes;
        match slots.iter_mut().find(|(saved, _)| *saved == mode) {
            Some(slot) => slot.1 = value,
            None => slots.push((mode, value)),
        }
    }

    /// XTRESTORE, `CSI ? Pm r`, for one mode.
    ///
    /// The slot is kept rather than consumed, as xterm keeps it, so a second restore puts
    /// back the same value. And nothing happens when the mode already stands where it
    /// was saved: a restore is a request for a state, not a replay of `h`/`l`, and
    /// replaying would home the cursor for DECOM or announce a mouse change that is not
    /// one.
    fn restore_mode(&mut self, mode: u16) {
        let Some(&(_, value)) = self
            .modes
            .saved_modes
            .iter()
            .find(|(saved, _)| *saved == mode)
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
                let now = self.modes.mouse;
                let restored = Mouse {
                    format: now.format,
                    ..saved
                };
                if restored != now {
                    self.modes.mouse = restored;
                    self.events.push(Event::Mouse(restored));
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
        for flag in PEN_FLAGS
            .into_iter()
            .filter(|&flag| parts.flags.contains(flag))
        {
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
            // XTSAVE and XTRESTORE. The `?` is the whole of what tells these from SCOSC
            // and DECSTBM, `CSI s` and `CSI r`, which arrive with no private byte and are
            // dispatched in their own families below.
            (Some(b'?'), 's' | 'r') => {
                for mode in params.iter().filter_map(|p| p.first().copied()) {
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
            // DECST8C. `CSI ? 5 W` and no other parameter: the unprefixed `CSI Ps W` is CTC,
            // whose 5 clears every stop rather than resetting them, and is not implemented.
            (Some(b'?'), 'W') if params.arg(0, 0) == 5 => self.screen_mut().reset_tabs(),
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
            //
            // Masked to what is actually honoured, which is not what was pushed. The
            // stack keeps whatever the child asked for -- a pop has to restore exactly
            // what its matching push put there -- but the *reply* is a claim about this
            // terminal, and echoing a flag back unmasked tells the child cooked
            // implements something it does not. A child that asks for alternate keys or
            // associated text, is told yes, and then encodes for them is a child cooked
            // has actively misled; a child told no falls back to a spelling that works.
            (Some(b'?'), 'u') => {
                let flags = self.modes.kitty_keys.last().copied().unwrap_or(0) & KITTY_HONOURED;
                self.csi_reply(format_args!("?{flags}u"));
            }
            // DECRQM. The machine-readable half of the terminfo audit: a mode we
            // implement answers 1 or 2, one we deliberately do not answers 4
            // ("permanently reset"), and one we have never heard of answers 0. A child
            // can therefore stop inferring our capabilities from TERM and just ask.
            (Some(b'?'), 'p') if intermediates.contains(&b'$') => {
                let mode = params.arg(0, 0) as u16;
                let status = self.dec_mode_state(mode);
                self.csi_reply(format_args!("?{mode};{status}$y"));
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
                14 if self.metrics.is_reported() => {
                    let (h, w) = (self.screen().height(), self.screen().width());
                    let (ph, pw) = (
                        h.saturating_mul(usize::from(self.metrics.height)),
                        w.saturating_mul(usize::from(self.metrics.width)),
                    );
                    self.csi_reply(format_args!("4;{ph};{pw}t"));
                }
                16 if self.metrics.is_reported() => {
                    let (ch, cw) = (self.metrics.height, self.metrics.width);
                    self.csi_reply(format_args!("6;{ch};{cw}t"));
                }
                18 => {
                    let (h, w) = (self.screen().height(), self.screen().width());
                    self.csi_reply(format_args!("8;{h};{w}t"));
                }
                // The frame, which only Emacs can measure. Lisp answers, and answers
                // `15t` only where there are pixels, by the same rule as `14t` above.
                15 => self.events.push(Event::FrameSize(true)),
                19 => self.events.push(Event::FrameSize(false)),
                22 => self.events.push(Event::TitleStack(true)),
                23 => self.events.push(Event::TitleStack(false)),
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
                    2 if self.metrics.is_reported() && (action == 1 || action == 4) => {
                        let (h, w) = (self.screen().height(), self.screen().width());
                        let (pw, ph) = (
                            w.saturating_mul(usize::from(self.metrics.width)),
                            h.saturating_mul(usize::from(self.metrics.height)),
                        );
                        // Width first here, where `14t` above reports height first. The
                        // two sequences genuinely disagree about the order, and reading
                        // one off the other is the way to get this wrong.
                        self.csi_reply(format_args!("?2;0;{pw};{ph}S"));
                    }
                    2 => self.csi_reply(format_args!("?2;3S")),
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
                let Cursor { row, col, .. } = self.screen().cursor;
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
}
