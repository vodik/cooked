//! `CSI` dispatch, and the mode machinery it drives.

/// The modes that are exactly one flag on [`Modes`], stated once.
///
/// Set/reset and the DECRQM query are generated from this list together, so a mode cannot
/// be settable and yet report itself unrecognised, or report the opposite of its state.
/// `soft_reset` covers them through `Modes::default()`.
///
/// Modes with an effect beyond one flag -- DECOM's cursor move, the mouse group's event,
/// 1049's save/switch/restore -- stay hand-written in [`State::dec_mode`].
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
    /// `None` for a bare push, which restores the whole pen.
    ///
    /// An `Option` rather than a selection with every part ticked, so a bare pop stays
    /// exact when [`Attrs`] grows a bit.
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

/// The modes a command can leave behind for the shell's prompt, as they stood when the
/// shell handed the terminal to it. See [`State::take_back`].
///
/// Two kinds. Most make the terminal send the child something it did not type. The cursor
/// and DECSCNM change only how the prompt is drawn, and are here because no shell sets
/// them at its prompt, so one a command left is left for good.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Handover {
    cursor_visible: bool,
    cursor_shape: CursorShape,
    cursor_blink: bool,
    reverse_screen: bool,
    mouse: Mouse,
    focus_events: bool,
    color_scheme_updates: bool,
    size_reports: bool,
    alt_scroll: bool,
    app_cursor: bool,
    app_keypad: bool,
    modify_other_keys: Option<ModifyOtherKeys>,
    primary_keys: KittyStack,
}

impl Handover {
    fn capture(modes: &Modes) -> Self {
        Self {
            cursor_visible: modes.cursor_visible,
            cursor_shape: modes.cursor_shape,
            cursor_blink: modes.cursor_blink,
            reverse_screen: modes.reverse_screen,
            mouse: modes.mouse,
            focus_events: modes.focus_events,
            color_scheme_updates: modes.color_scheme_updates,
            size_reports: modes.size_reports,
            alt_scroll: modes.alt_scroll,
            app_cursor: modes.app_cursor,
            app_keypad: modes.app_keypad,
            modify_other_keys: modes.modify_other_keys,
            primary_keys: modes.kitty_keys.primary.clone(),
        }
    }

    fn restore(self, modes: &mut Modes) {
        modes.cursor_visible = self.cursor_visible;
        modes.cursor_shape = self.cursor_shape;
        modes.cursor_blink = self.cursor_blink;
        modes.reverse_screen = self.reverse_screen;
        modes.mouse = self.mouse;
        modes.focus_events = self.focus_events;
        modes.color_scheme_updates = self.color_scheme_updates;
        modes.size_reports = self.size_reports;
        modes.alt_scroll = self.alt_scroll;
        modes.app_cursor = self.app_cursor;
        modes.app_keypad = self.app_keypad;
        modes.modify_other_keys = self.modify_other_keys;
        modes.kitty_keys.primary = self.primary_keys;
    }
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
                self.events.push(Event::Mouse(self.modes.mouse).into());
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
                self.events.push(Event::Mouse(self.modes.mouse).into());
            }
            DecMode::AltScreenLegacy | DecMode::AltScreen => self.set_alt(on),
            DecMode::SaveCursor if on => self.save_cursor(),
            DecMode::SaveCursor => self.restore_cursor(),
            // Save, switch, ... switch back, restore. The save and restore bracket the
            // switch because `restore_cursor` acts on the screen being shown, and the
            // primary's cursor is the one `1049 h` saved -- which a resize inside a
            // full-screen program will have moved.
            //
            // Only on the way out of the alternate screen, and only onto a save, which is
            // where this parts from xterm. A DECRC keeps its save and homes without one,
            // so a stray `rmcup` from a script on the primary screen would otherwise
            // move the shell's cursor back over the output since the last full-screen
            // program, or to the corner after a DECSTR. There the primary's own cursor
            // is already the right answer.
            DecMode::AltScreenSaveCursor => {
                if on {
                    self.save_cursor();
                    self.set_alt(true);
                } else if self.shown.is_alternate() {
                    self.set_alt(false);
                    if self.screen().has_saved_cursor() {
                        self.restore_cursor();
                    }
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
                    self.push_reply(Reply::size_report(report));
                }
            }
            DecMode::ReverseScreen => {
                if self.modes.reverse_screen != on {
                    self.reverse_screen_toggles = self.reverse_screen_toggles.wrapping_add(1);
                }
                self.set_flag_mode(mode, on);
            }
            DecMode::AppCursor
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
            // Meta sends ESC before the key always: it is how the key encoder spells
            // Meta on every key the negotiated protocols do not re-encode. Not 4,
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
            // Declined or permanent; see [`State::ansi_mode_report`].
            AnsiMode::GuardedAreaTransfer
            | AnsiMode::KeyboardAction
            | AnsiMode::ControlRepresentation
            | AnsiMode::StatusReportTransfer
            | AnsiMode::VerticalEditing
            | AnsiMode::HorizontalEditing
            | AnsiMode::PositioningUnit
            | AnsiMode::SendReceive
            | AnsiMode::FormatEffectorAction
            | AnsiMode::FormatEffectorTransfer
            | AnsiMode::MultipleAreaTransfer
            | AnsiMode::TransferTermination
            | AnsiMode::SelectedAreaTransfer
            | AnsiMode::TabulationStop
            | AnsiMode::EditingBoundary => {}
        }
    }

    /// DECRQM's answer for an ANSI mode.
    ///
    /// The numbers xterm answers for, `misc.c`'s `do_ansi_rqm`, answered the same way
    /// wherever cooked is in the same state. Two differ, both because xterm implements
    /// what cooked declines: KAM, which xterm lets a child lock the keyboard with, and
    /// CRM, which xterm answers 2.
    fn ansi_mode_report(&self, number: u16) -> ModeReport {
        let Ok(mode) = AnsiMode::try_from(number) else {
            return ModeReport::Unknown;
        };
        match mode {
            AnsiMode::Insert => self.screen().insert_mode().into(),
            AnsiMode::Newline => self.modes.newline_mode.into(),
            AnsiMode::SendReceive => ModeReport::PermanentlySet,
            AnsiMode::GuardedAreaTransfer
            | AnsiMode::KeyboardAction
            | AnsiMode::ControlRepresentation
            | AnsiMode::StatusReportTransfer
            | AnsiMode::VerticalEditing
            | AnsiMode::HorizontalEditing
            | AnsiMode::PositioningUnit
            | AnsiMode::FormatEffectorAction
            | AnsiMode::FormatEffectorTransfer
            | AnsiMode::MultipleAreaTransfer
            | AnsiMode::TransferTermination
            | AnsiMode::SelectedAreaTransfer
            | AnsiMode::TabulationStop
            | AnsiMode::EditingBoundary => ModeReport::PermanentlyReset,
        }
    }

    /// DECSTR, and the mode half of RIS.
    ///
    /// Everything the child negotiated goes back to its power-on value. The screen and the
    /// scrollback are not touched, which is why `rs2` can be sent without losing the
    /// transcript.
    pub(super) fn soft_reset(&mut self) {
        self.pen.set_style(Style::default());
        // Closed here and *only* here, not by SGR: DECSTR and RIS are the child saying
        // "start over", which is a different statement from any rendition change. See
        // [`PenState`].
        self.pen.set_link(None);
        self.last_print = None;
        // The whole negotiated state in one statement; see [`Modes`].
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
            self.events.push(Event::Mouse(self.modes.mouse).into());
        }
    }

    /// OSC 133 `C`: note the modes the shell is handing to the command; see [`Handover`].
    ///
    /// Only on the primary screen. A `C` on the alternate screen comes from a shell inside
    /// a multiplexer such as tmux, which passes its panes' marks through while it holds
    /// the mouse and the size reports itself, and a capture there would hand tmux's modes
    /// to the outer shell's `D`.
    pub(super) fn hand_over(&mut self) {
        if !self.shown.is_alternate() {
            self.handover = Some(Handover::capture(&self.modes));
        }
    }

    /// OSC 133 `D`: the command is over, so the modes in [`Handover`] go back to what the
    /// shell handed over at its `C`, and the alternate screen's kitty stack is emptied.
    ///
    /// A command that dies with a mode set leaves the shell reading reports it never
    /// asked for. With 2048 on, every resize types `ESC [ 48 ; 24 ; 80 ; ... t` at the
    /// prompt; with 1003 on, every cell the pointer crosses does the same; with a kitty
    /// flag pushed on the primary screen, bash's `C-r` arrives as `CSI 114 ; 5 u`. The
    /// shell's own marks are the one signal that the program is gone however it went, and
    /// no other terminal has them: ghostty, kitty, wezterm and foot record the marks for
    /// navigation and reset nothing on them.
    ///
    /// `D` and not `A`, which a prompt mark would suggest. bash 5.3, zsh 5.9 and fish 4.9
    /// were all watched on a pty: each turns on the modes its line editor wants (bracketed
    /// paste; fish also 2031, modifyOtherKeys and the keypad) *before* printing the prompt
    /// that carries `A`, and turns them off again before `C`. A reset at `A` would take
    /// them away from the shell that has just asked for them, and would do it again at
    /// every redraw, since a resize or zsh's `reset-prompt` reprints the prompt and its
    /// mark. Every shell emits `D` before its line editor starts.
    ///
    /// Restored rather than reset to their power-on values, so a mode the shell set for
    /// itself is kept: a `.zshrc` that turns on focus reports has them on at every `C`.
    /// A `D` with no `C` before it, such as the one zsh sends at its first prompt, puts
    /// nothing back. Neither does a program that runs a command without marks, so
    /// `vim`'s `:!make` keeps vim's own modes across the round trip.
    ///
    /// The cursor's visibility and shape and DECSCNM are restored too, although no report
    /// hangs on them. A spinner killed with its cursor hidden, or an editor that died with
    /// its bar cursor or mid-flash, otherwise leaves the prompt drawn that way for the rest
    /// of the session: bash 5.3, zsh 5.9 and fish 4.9, watched on a pty, set none of the
    /// three at a prompt, so nothing else would ever put them back. A shell or a prompt
    /// theme that does set a shape, as a vi-mode binding does on entering the line editor,
    /// sets it after `D` and keeps it.
    ///
    /// Bracketed paste is not among the modes, though it is the one most often left on.
    /// Every line editor that uses it sets it at each prompt and clears it before each
    /// command, so a stale one never outlives the next prompt, and a prompt theme that
    /// draws its `D` inside `PS1`, after readline has set it, would lose it here.
    ///
    /// The alternate screen is emptied rather than restored because nothing can be alive
    /// on it once the shell is prompting on the primary screen, and a kitty flag left
    /// there would otherwise be handed to the next full-screen program that does not push
    /// its own.
    pub(super) fn take_back(&mut self) {
        if self.shown.is_alternate() {
            return;
        }
        self.modes.kitty_keys.alternate = KittyStack::default();
        if let Some(handover) = self.handover.take() {
            let (mouse, reverse_screen) = (self.modes.mouse, self.modes.reverse_screen);
            handover.restore(&mut self.modes);
            if self.modes.mouse != mouse {
                self.events.push(Event::Mouse(self.modes.mouse).into());
            }
            // Counted as a DECSCNM would be, so a command that reversed the screen and died
            // inside one drain still shows as a flash rather than as nothing.
            if self.modes.reverse_screen != reverse_screen {
                self.reverse_screen_toggles = self.reverse_screen_toggles.wrapping_add(1);
            }
        }
    }

    /// DECSC: the cursor and the character sets, for the screen being shown.
    pub(super) fn save_cursor(&mut self) {
        self.saved_charsets[self.shown] = Some(self.modes.charsets);
        self.screen_mut().save_cursor();
    }

    /// DECRC: put back what [`State::save_cursor`] kept on this screen.
    ///
    /// With nothing kept, the charsets go back to their power-on designations and the
    /// cursor home, as in xterm and ghostty. The save is not used up; see
    /// [`Screen::restore_cursor`].
    pub(super) fn restore_cursor(&mut self) {
        self.modes.charsets = self.saved_charsets[self.shown].unwrap_or_default();
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
    /// The slot is kept rather than consumed, as in xterm. Nothing happens when the mode
    /// already stands where it was saved: a restore asks for a state rather than replaying
    /// `h`/`l`, which would home the cursor for DECOM.
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
            // Which screen, and nothing else: xterm's restore of any of the three only
            // switches, with no clear and no cursor restore, whichever number made the
            // save. A 1049 replay would restore a cursor that 47 never saved. Nothing is
            // lost by it, since each screen here keeps a cursor of its own.
            SavedMode::Flag(on) if slot == DecMode::AltScreen => self.set_alt(on),
            SavedMode::Flag(on) => {
                if self.dec_mode_state(mode) != ModeReport::from(on) {
                    self.dec_mode(mode, on);
                }
            }
            SavedMode::Tracking(saved) => {
                if self.modes.mouse.tracking != saved {
                    self.modes.mouse.tracking = saved;
                    self.events.push(Event::Mouse(self.modes.mouse).into());
                }
            }
            SavedMode::Format(saved) => {
                if self.modes.mouse.format != saved {
                    self.modes.mouse.format = saved;
                    self.events.push(Event::Mouse(self.modes.mouse).into());
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
                pen: self.pen.style(),
                parts: PenParts::from_params(params),
            });
        }
    }

    /// XTPOPSGR, `CSI # }`. A pop with nothing pushed changes nothing.
    fn pop_pen(&mut self) {
        let Some(PushedPen { pen, parts }) = self.modes.pen_stack.pop() else {
            return;
        };
        let Some(parts) = parts else {
            self.pen.set_style(pen);
            return;
        };
        let current = self.pen.style_mut();
        for flag in PUSHABLE.iter().map(|flag| flag.attr) {
            if !parts.flags.contains(flag) {
                continue;
            }
            if pen.attrs.contains(flag) {
                current.attrs |= flag;
            } else {
                current.attrs.remove(flag);
            }
        }
        if parts.underline {
            current
                .attrs
                .set_underline_style(pen.attrs.underline_style());
            current.underline = pen.underline;
        }
        if parts.fg {
            current.fg = pen.fg;
        }
        if parts.bg {
            current.bg = pen.bg;
        }
    }

    /// `CSI Ps m`, decoded by the one decoder both performers share.
    ///
    /// The arm is [`sgr::apply`](crate::emu::sgr::apply), shared with the comint filter,
    /// which keeps a pen of its own.
    pub(super) fn sgr(&mut self, params: &Params) {
        crate::emu::sgr::apply(params, self.pen.style_mut());
    }

    /// Dispatch one `CSI` sequence.
    ///
    /// Four families, tried in turn, each answering whether the sequence was its own. The
    /// patterns are disjoint, so the order carries no meaning; the grouping just makes a
    /// forty-entry table readable.
    pub(super) fn csi(&mut self, params: &Params, intermediates: &[u8], action: char) {
        let private = intermediates.first().copied();
        let _handled = self.csi_mode(private, action, params)
            || self.csi_cursor(private, action, params)
            || self.csi_edit(private, action, params)
            || self.csi_report(private, action, params, intermediates);
        #[cfg(test)]
        {
            self.unrecognised += usize::from(!_handled);
        }
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
        // `bce`: an erase or a scroll leaves the pen's background behind, so each arm that
        // erases asks for the pen as it writes -- see `Style::erase` -- and the arms that
        // only change the pen, `SGR` above all, do not pay for one.
        match (private, action) {
            (None, 'J') => {
                let param = params.arg(0, 0) as u16;
                if let Some(how) = Erase::from_param(param) {
                    let pen = self.pen();
                    self.erase_display(how, pen);
                }
                if param == 3 {
                    self.events.push(Event::EraseScrollback.into());
                }
            }
            (None, 'K') => {
                if let Some(how) = Erase::from_param(params.arg(0, 0) as u16) {
                    let pen = self.pen();
                    self.screen_mut().erase_line(how, pen);
                }
            }
            (None, 'L') => {
                let pen = self.pen();
                self.screen_mut().insert_lines(params.arg(0, 1), pen);
            }
            (None, 'M') => {
                let pen = self.pen();
                self.screen_mut().delete_lines(params.arg(0, 1), pen);
            }
            (None, 'P') => {
                let pen = self.pen();
                self.screen_mut().delete_chars(params.arg(0, 1), pen);
            }
            (None, 'S') => {
                let (n, pen) = (params.arg(0, 1), self.pen());
                self.evicting(|screen| screen.scroll_up(n, pen));
            }
            (None, 'T') => {
                let pen = self.pen();
                self.screen_mut().scroll_down(params.arg(0, 1), pen);
            }
            (None, 'X') => {
                let pen = self.pen();
                self.screen_mut().erase_chars(params.arg(0, 1), pen);
            }
            (None, '@') => {
                let pen = self.pen();
                self.screen_mut().insert_chars(params.arg(0, 1), pen);
            }
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
                    let pen = self.pen();
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
            // XTMODKEYS' other half, `CSI > 4 n`, which xterm reads as setting the
            // resource to -1: modifyOtherKeys disabled, which is the same as no level.
            // An omitted parameter names modifyFunctionKeys, which cooked has no switch
            // for, so it and the other resources are ignored.
            (Some(b'>'), 'n') => {
                if params.value(0) == Some(4) {
                    self.modes.modify_other_keys = None;
                }
            }
            // XTQMODKEYS, `CSI ? 4 m`, answered `CSI > 4 ; LEVEL m` with the level the
            // encoder honours, so a level 3 cooked read as none is reported as 0. The
            // other resources have no level here to report, and get no answer, as
            // xterm gives none for a resource it does not know.
            (Some(b'?'), 'm') => {
                if params.value(0) == Some(4) {
                    let level = self
                        .modes
                        .modify_other_keys
                        .map_or(0, ModifyOtherKeys::level);
                    self.csi_reply(format_args!(">4;{level}m"));
                }
            }
            // Kitty keyboard protocol: push, pop, and set, each on the stack of the screen
            // being shown. See [`KittyStack`] for the cap and why a full push evicts.
            // A parameter out of range drops the whole sequence, as it does in ghostty.
            (Some(b'>'), 'u') => {
                if let Some(flags) = KittyFlags::from_param(params.value(0).unwrap_or(0)) {
                    self.kitty_stack_mut().push(flags);
                }
            }
            (Some(b'<'), 'u') => self.kitty_stack_mut().pop(params.arg(0, 1)),
            (Some(b'='), 'u') => {
                if let (Some(flags), Some(mode)) = (
                    KittyFlags::from_param(params.value(0).unwrap_or(0)),
                    KittySetMode::from_param(params.arg(1, 1)),
                ) {
                    self.kitty_stack_mut().set(flags, mode);
                }
            }
            // A child that probes and gets no answer may wait for one.
            //
            // Masked to what is honoured rather than what was pushed. The stack keeps what
            // the child asked for, so a pop restores it exactly, but the reply is a claim
            // about this terminal: a child told yes to a flag cooked does not implement
            // would encode for it, while one told no falls back to a spelling that works.
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
            // XTWINOPS. The reports are answered and most operations refused: `21t` would
            // put the window title *on the child's input stream*, where a title the child
            // set becomes typed input at the next prompt, and `3t`/`4t`/`9t` move or
            // iconify the frame, which is Emacs' business. A resize (`8t`, and DECSLPP) is
            // passed on as a request Lisp may refuse; see `Event::ResizeRequest`.
            (None, 't') => match params.arg(0, 0) {
                // Not iconified. Always true of a window that is receiving output, and
                // the one state report with nothing to measure.
                11 => self.csi_reply(format_args!("1t")),
                // 14 is the text area in pixels, 16 one cell, which image producers ask
                // before deciding whether to draw. Silent when Emacs has reported no cell
                // size, as on a terminal frame, since zero would be a claim.
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
                // The frame, which only Emacs can measure -- see `FrameSize`. Silent until
                // Lisp has pushed one down, and `15t` silent past that until it has pixels
                // to report, by the same rule `14t` follows above.
                15 => {
                    if let Some(FrameSize {
                        pixels: Some(px), ..
                    }) = self.frame_size
                    {
                        self.csi_reply(format_args!("5;{};{}t", px.h, px.w));
                    }
                }
                19 => {
                    if let Some(FrameSize { rows, cols, .. }) = self.frame_size {
                        self.csi_reply(format_args!("9;{rows};{cols}t"));
                    }
                }
                22 => self.events.push(Event::TitleStack(StackOp::Push).into()),
                23 => self.events.push(Event::TitleStack(StackOp::Pop).into()),
                // A 0 or omitted argument means "leave this dimension", which `arg`'s
                // fallback of 0 folds together with an absent one. A request to leave
                // both is no request.
                8 => {
                    let dim = |i| u16::try_from(params.arg(i, 0)).ok().filter(|&n| n != 0);
                    let (rows, cols) = (dim(1), dim(2));
                    if rows.is_some() || cols.is_some() {
                        self.events.push(Event::ResizeRequest(rows, cols).into());
                    }
                }
                // DECSLPP: set lines per page. The row count alone, from the VT340, which
                // xterm reads any `CSI Ps t` of 24 or more as.
                lines @ 24.. => {
                    let rows = u16::try_from(lines).unwrap_or(u16::MAX);
                    self.events
                        .push(Event::ResizeRequest(Some(rows), None).into());
                }
                _ => {}
            },
            // XTSMGRAPHICS, `CSI ? Pi ; Pa ; Pv S`: what a sixel producer asks after
            // seeing the `4` in our primary DA -- how many colour registers it may use and
            // how many pixels it has. Unanswered, the producer hangs.
            //
            // Every path answers, including "no": the protocol has a status field -- 0
            // success, 1 no such item, 2 no such action, 3 failure -- so declining costs
            // one number.
            (Some(b'?'), 'S') => {
                let (item, action) = (params.arg(0, 0), params.arg(1, 0));
                match item {
                    // Nothing sixel can draw would be shown, so neither item has an
                    // answer worth giving: failure, which a producer that ignored the
                    // missing `4` in DA1 reads the same way. Registers and geometry
                    // alike, because a palette size is only a promise about a picture.
                    1 | 2 if !self.graphics.shows(ImageFormat::Png) => {
                        self.csi_reply(format_args!("?{item};3S"));
                    }
                    // Colour registers, fixed at the palette the sixel decoder allocates.
                    // Reading (1), resetting (2) and reading the maximum (4) give the same
                    // number; setting (3) is refused, since a child cannot enlarge a
                    // compile-time array.
                    1 => {
                        let registers = sixel::PALETTE_SIZE;
                        let status = if action == 3 { 3 } else { 0 };
                        self.csi_reply(format_args!("?1;{status};{registers}S"));
                    }
                    // Sixel geometry, in pixels: the same text area `14t` reports, so the
                    // two cannot disagree.
                    //
                    // The maximum (4) is the current size too. The decoder bounds a
                    // picture's *area* (`sixel::MAX_PIXELS`), not either axis, so the screen
                    // is the only honest per-axis maximum.
                    //
                    // Where `14t` falls silent on unreported metrics, this answers failure,
                    // because this protocol can say so. Setting the geometry is refused the
                    // same way: the window is Emacs'.
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
            // XTVERSION, `CSI > 0 q`, named by terminfo's `XR`. The answer names *cooked*,
            // as every terminal names itself: the query exists to tell them apart, and
            // answering `XTerm(...)` would hand clients another program's capabilities.
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
            // Primary DA, for what we implement and nothing else: VT220 level (62) with
            // sixel graphics (4) and ANSI colour (22). The 4 is how sixel producers decide
            // whether to emit one at all, so it goes when Emacs cannot show the PNG a sixel
            // becomes (see `State::graphics`), and chafa or timg draw with half blocks.
            (None, 'c') if !self.graphics.shows(ImageFormat::Png) => {
                self.csi_reply(format_args!("?62;22c"))
            }
            (None, 'c') => self.csi_reply(format_args!("?62;4;22c")),
            // Secondary DA. Unanswered, a child that queries and waits hangs.
            (Some(b'>'), 'c') => self.csi_reply(format_args!(">0;0;0c")),
            // Tertiary DA, the unit id, as `DCS ! | 00000000 ST`: zero, as xterm sends,
            // because a child asking waits for an answer.
            (Some(b'='), 'c') if params.arg(0, 0) == 0 => {
                self.dcs_reply(format_args!("!|00000000"));
            }
            (None, 'n') if params.arg(0, 0) == 5 => {
                self.csi_reply(format_args!("0n"));
            }
            // CPR, and DECXCPR, its private form, which libvterm answers too. Both count
            // rows from the top of the region under DECOM, as `CSI H` does, so a child can
            // send back the position it was told. DECXCPR's page is left out, as xterm
            // leaves it out below VT330 level, and DA1 says VT220.
            (None, 'n') if params.arg(0, 0) == 6 => {
                let (row, col) = self.reported_cursor();
                self.csi_reply(format_args!("{row};{col}R"));
            }
            (Some(b'?'), 'n') if params.arg(0, 0) == 6 => {
                let (row, col) = self.reported_cursor();
                self.csi_reply(format_args!("?{row};{col}R"));
            }
            // The colour scheme, `CSI ? 996 n`. Silent until Emacs has reported one, since
            // the protocol has no way to say "not yet". The `996` guard leaves other private
            // DSRs such as `CSI ? 15 n` unimplemented rather than swallowed.
            (Some(b'?'), 'n') if params.arg(0, 0) == 996 => {
                if let Some(scheme) = self.color_scheme {
                    self.push_reply(Reply::answer(color_scheme_report(scheme)));
                }
            }
            _ => return false,
        }
        true
    }

    /// The cursor as a CPR reports it: one-based, and under DECOM from the top of the
    /// scroll region.
    fn reported_cursor(&self) -> (usize, usize) {
        let Cursor { row, col, .. } = self.screen().cursor();
        let top = if self.modes.origin_mode {
            self.screen().region().top
        } else {
            0
        };
        (row.saturating_sub(top) + 1, col + 1)
    }

    /// DECRQSS, `DCS $ q Pt ST`: answer with the sequence that would recreate the
    /// setting NAME names, as `DCS 1 $ r <sequence> ST`, or `DCS 0 $ r ST` for a name
    /// not answered.
    ///
    /// Here rather than with the DCS plumbing in graphics.rs because every setting it can
    /// name is a CSI one. What is answered is what cooked implements and nothing more:
    ///
    /// - `m`, the pen, spelled by [`sgr::describe`](crate::emu::sgr::describe) so that it
    ///   parses back to the same pen. neovim sets `48:2::1:2:3`, asks, and turns on
    ///   `termguicolors` if the colour comes back, which is the truecolour probe that
    ///   works over ssh.
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
                let sgr = crate::emu::sgr::describe(self.pen.style());
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
