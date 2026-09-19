//! The VT parser front end: turns a byte stream into grid mutations and [`Event`]s.
//!
//! Scrollback deliberately lives in the Emacs buffer, not here. Rows that fall off the
//! top of the primary screen are handed over once, in [`Delta::scrolled`], and forgotten.

use super::cell::{Deco, Extra, MarkId, Pen, RowRef, Runs, Style};
use super::image::{
    CellMetrics, CellSize, ImageData, ImageFormat, ImageId, ImageStore, Interned, PixelSize,
    ShownFormats,
};
use super::kitty::{Kitty, Outcome, decode_base64};
use super::link::{LinkId, LinkStore, MAX_URI_LEN};
use super::parser::{OscCode, Params, Parser, Perform};
use super::png::png_dimensions;
use super::screen::{Cursor, Erase, Evicted, Resize, Screen, Shift};
use super::sixel;
use super::style::{StyleId, StyleStore};
use super::text::{self, Segmenter, Step, Width};
use super::utf8::{Decoder, Piece};
use csi::{Handover, PushedPen, SavedMode};
pub(crate) use keypress::{Assumed, Key, Modifiers, NamedKey};
pub(crate) use keys::{KeyEncoding, KittyFlags, ModifyOtherKeys};
use keys::{KittySetMode, KittyStack};
pub(crate) use mouse::Button;
pub(crate) use paste::{bracket as bracket_paste, strip_controls as strip_paste_controls};
use pen::PenState;
use reply::{Framing, color_scheme_report, size_report};
pub(crate) use reply::{Terminator, osc_reply};
use screens::{PerScreen, ScreenId};
use std::collections::{HashMap, HashSet, VecDeque};

mod csi;
mod front;
mod graphics;
mod keypress;
mod keys;
mod modes;
pub(crate) mod mouse;
pub(crate) mod osc;
mod paste;
mod pen;
mod perform;
pub(crate) mod reply;
mod screens;
mod state;

pub(crate) use osc::{Palette, Rgb};

#[cfg(test)]
mod tests;
mod xtgettcap;

/// The cursor shape a child asked for with DECSCUSR (`CSI Ps SP q`).
///
/// The blinking and steady spellings collapse into one value each: whether a cursor
/// blinks is `blink-cursor-mode', which belongs to the user and not to the child — the
/// same reasoning that keeps DEC mode 12 unimplemented and `cvvis' out of our terminfo.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CursorShape {
    #[default]
    Block,
    Underline,
    Bar,
}

impl CursorShape {
    fn from_param(n: usize) -> Option<Self> {
        match n {
            0..=2 => Some(Self::Block),
            3 | 4 => Some(Self::Underline),
            5 | 6 => Some(Self::Bar),
            _ => None,
        }
    }

    /// The DECSCUSR parameter that sets this shape, blinking or not: the inverse of
    /// [`CursorShape::from_param`], for DECRQSS. `0` never comes back, being a synonym
    /// for `1`.
    fn param(self, blink: bool) -> u8 {
        let steady = match self {
            Self::Block => 2,
            Self::Underline => 4,
            Self::Bar => 6,
        };
        steady - u8::from(blink)
    }
}

/// Where in the output stream a mark landed.
///
/// `row` is *absolute*: screen row 0 is row [`State::evicted_total`], so the coordinate
/// stays meaningful after the marked row scrolls away, which a screen row does not.
///
/// Recorded when the mark is parsed rather than read off the drain, because the drain
/// carries the *end-of-drain* cursor, which is somewhere else entirely once a fast script
/// lands several commands in one drain.
///
/// Best-effort: a resize between the mark and the drain rewraps the scrollback and can
/// shift where the anchor resolves, and Lisp then falls back to the end-of-drain cursor.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Anchor {
    pub row: usize,
    pub col: usize,
}

/// An OSC 133 mark: where a shell says its prompt, its input and its command's output
/// begin and end.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Mark {
    /// `133;A`: the prompt a command is typed at, `PS1`.
    PromptStart,
    /// `133;A;k=s`: a continuation prompt, `PS2`, for the second and later lines of a
    /// multi-line construct. It opens no command and moves no prompt marker; it says that
    /// the line about to be read continues the one already submitted.
    PromptContinuation,
    /// `133;B`: user input begins, which is where Emacs takes the line.
    PromptEnd,
    /// `133;C`: the command is running and owns the output region, with the command line
    /// the shell said it was about to run, from `cmdline_url=`. See [`Mark::cmdline`]
    /// for why that spelling and not kitty's `cmdline=`.
    CommandStart(Option<String>),
    /// `133;D`: the command finished, with its exit status when reported.
    CommandEnd(Option<i32>),
}

/// What a reply is, which decides whether a later one may replace it.
///
/// It rides on [`Event::Reply`] from where the reply is composed to the session's reply
/// queue, which is what acts on it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReplyKind {
    /// An answer to something the child asked. Each is kept, in order.
    Answer,
    /// A mode 2048 size report. Only the newest describes the terminal, so a resize
    /// replaces one that has not started to go out; ten thousand resizes of a window over
    /// a child that is not reading queue one report, not ten thousand.
    SizeReport,
}

/// Something the Lisp side must react to, beyond redrawing cells.
///
/// The division of labour with [`Delta`]'s fields is deliberate: the drain's fields carry
/// everything *redisplay* needs, as levels -- the state at the end of the drain. Events
/// carry what Emacs must *react* to, as occurrences. State consulted only when sending to
/// the child, such as bracketed paste, is neither, and is queried live at that moment.
///
/// No state is sent both ways: an alternate-screen event beside [`Levels::alt`] could only
/// restate the field.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// At least one BEL since the last drain; see [`State::bell_queued`].
    Bell,
    /// Any OSC the terminal does not act on itself, handed over verbatim as
    /// (code, remaining parts, ended with BEL).
    ///
    /// Interpreting these is Emacs' business: titles, working directories, clipboard,
    /// editor commands. Keeping this generic makes a new integration a few lines of Lisp
    /// rather than a Rust release. OSC 133 is the exception, because it decides who owns
    /// the keyboard; OSC 8 and 66 are grid state and handled here too.
    ///
    /// The terminator travels with the event because a reply echoes it, and Emacs answers
    /// asynchronously: by the time a handler runs several more sequences may have been
    /// parsed, so "the terminator of the last OSC" could answer the wrong query. See
    /// [`osc_reply`].
    Osc(u16, Vec<String>, Terminator),
    /// An OSC 133 mark, and where it landed.
    ///
    /// The [`MarkId`] is how Emacs is told later that the mark has moved: Emacs holds a
    /// buffer marker taken from the [`Anchor`], the anchor stops being true the moment a
    /// resize rewraps the grid, and the id pairs the two up again. See [`Delta::marks`].
    Mark(Mark, Anchor, MarkId),
    /// The child changed its mind about mouse reporting. An occurrence rather than a
    /// field because nothing in redisplay depends on it: its one consumer swaps a keymap.
    Mouse(Mouse),
    /// Bytes the terminal owes the child (device attributes, cursor reports), and which
    /// kind of reply they are.
    ///
    /// The kind is a field rather than a second variant because the two kinds are the same
    /// thing in every respect but one: a resize supersedes a [`ReplyKind::SizeReport`] that
    /// has not gone out yet. See [`Term::set_size`], which drops an undrained one by it.
    Reply(Vec<u8>, ReplyKind),
    /// `CSI 3 J` — the child asked to erase saved lines, xterm's `clear -x`.
    ///
    /// Unlike `CSI 2 J`, xterm's `3 J` touches only the scrollback, so the grid does
    /// nothing. Scrollback is buffer text, so this event is the whole response: it is the
    /// half of `clear` that empties the buffer, the `2 J` before it having archived the
    /// screen.
    EraseScrollback,
    /// `CSI 2 J` — the child finished with this screen.
    ///
    /// The rows are not lost: [`Screen::erase_display`] archives them. But the child asked
    /// for a blank screen, and since the transcript and the live screen are one buffer,
    /// the Emacs window has to move to show one; this event asks it to.
    DisplayCleared,
    /// `ESC c` -- RIS, a full reset of the terminal.
    ///
    /// RIS resets the emulator itself; this event is for state kept in Lisp, such as OSC
    /// 9;4 progress, the OSC 22 pointer stacks and the bell's mark. A reset that cleared the
    /// screen but left a progress indicator on the mode line would be the stuck state
    /// `reset` is typed to cure.
    ///
    /// Not raised by DECSTR (`CSI ! p`), which every `rs2` and `is2` sends: a soft reset is
    /// a program tidying its modes, and a build running underneath has not stopped
    /// reporting progress.
    Reset,
    /// XTWINOPS 22/23: push or pop the window title. `smcup`/`rmcup` end in these, so a
    /// full-screen program that sets a title expects it restored when it leaves.
    TitleStack(StackOp),
    /// XTWINOPS `8t` or DECSLPP (`CSI Ps t`, Ps of 24 or more): the child asks for a
    /// size, as (rows, columns), with `None` for a dimension it asked to leave alone.
    ///
    /// Only asked, never done here. The grid follows the window, so honouring this means
    /// moving an Emacs window and letting the ordinary resize path tell the child, and
    /// `cooked-resize-requests` refuses by default. No reply either way, as xterm sends
    /// none with `allowWindowOps` off; the child reads the answer back with `18t`.
    ResizeRequest(Option<u16>, Option<u16>),
    /// XTWINOPS `19t` (cells) or `15t` (pixels): the size of the *screen*, which in Emacs
    /// is the frame.
    ///
    /// An event rather than a reply because the grid does not know the frame. It knows
    /// the one window it is laid out for, and that is `18t` and `14t`; the frame
    /// around it is Emacs' to measure.
    FrameSize(Unit),
}

impl Event {
    /// The reply to something the child asked, BYTES.
    pub fn answer(bytes: Vec<u8>) -> Self {
        Self::Reply(bytes, ReplyKind::Answer)
    }

    /// The mode 2048 size report, BYTES.
    pub fn size_report(bytes: Vec<u8>) -> Self {
        Self::Reply(bytes, ReplyKind::SizeReport)
    }
}

impl Event {
    /// Whether Lisp may answer this, which holds back every reply composed after it; see
    /// [`ReplyRoute`].
    ///
    /// For an OSC, a query is a part that is `?` or begins with one: `OSC 4 ; 1 ; ?`,
    /// `OSC 11 ; ?`, `OSC 52 ; c ; ?`, `OSC 22 ; ?pointer`. That is the xterm convention
    /// every query Lisp answers follows. A handler answering something else still has its
    /// reply sent, but a reply the emulator composed later in the same stretch of output
    /// may reach the child first.
    fn awaits_answer(&self) -> bool {
        match self {
            Self::Osc(_, parts, _) => parts.iter().any(|part| part.starts_with('?')),
            Self::FrameSize(_) => true,
            _ => false,
        }
    }

    /// Whether this is a colour sequence whose handling may move what the palette holds,
    /// so the core must not answer a colour query from it until Lisp has been through.
    ///
    /// A *set* is the case, and it is not [`Event::awaits_answer`]: `OSC 11 ; #ff0000`
    /// asks for nothing and holds no reply back, and yet a query after it is owed the
    /// colour Lisp is about to remap to rather than the one being replaced. The resets,
    /// `OSC 110` to `OSC 112`, move it the other way for the same reason. A query is
    /// included because a handler may reply and set in one pass; see [`osc::Palette`].
    fn asks_about_color(&self) -> bool {
        matches!(self, Self::Osc(code, ..)
            if *code == 4 || (10..=19).contains(code) || (110..=112).contains(code))
    }

    /// Whether Lisp needs the screen's text in the buffer to act on this, which is what
    /// makes [`Term::drain_hidden`] a whole drain.
    ///
    /// A mark becomes a marker on a row, so the row has to be there: a prompt mark on
    /// screen row 3 of a buffer whose screen region was last drawn a thousand lines ago
    /// would land on whatever row 3 said then. `CSI 3 J` deletes the scrollback above the
    /// screen and `CSI 2 J` pins the window to the screen's top, and each has to happen
    /// between the scrollback before it and the scrollback after it.
    fn needs_text(&self) -> bool {
        matches!(
            self,
            Self::Mark(..) | Self::EraseScrollback | Self::DisplayCleared
        )
    }
}

/// A push or a pop, for [`Event::TitleStack`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StackOp {
    Push,
    Pop,
}

/// What a size is counted in, for [`Event::FrameSize`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Unit {
    Cells,
    Pixels,
}

/// What the child asked to hear from the mouse, and how the reports are to be spelled.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Mouse {
    pub tracking: MouseTracking,
    pub format: MouseFormat,
}

/// Which pointer events are reported: DEC modes 1000, 1002 and 1003.
///
/// One choice rather than three flags, as xterm keeps it: its `send_mouse_pos` holds a
/// single mode, setting any of the three numbers replaces whichever was in force, and
/// resetting any of them turns reporting off (`set_mousemode` in charproc.c assigns
/// `MOUSE_OFF` on every reset). Three flags could say "drag without click", which no
/// terminal has a report for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum MouseTracking {
    #[default]
    Off,
    /// DEC mode 1000: presses and releases.
    Click,
    /// DEC mode 1002: presses, releases, and motion while a button is held.
    Drag,
    /// DEC mode 1003: presses, releases, and all motion, held or not.
    Motion,
}

/// How a mouse report spells its coordinates: DEC modes 1006 and 1016.
///
/// One field rather than a flag per mode, because xterm makes the two mutually exclusive:
/// setting one replaces the other, and resetting one only has effect if it is the one set.
/// Two booleans could say both at once.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum MouseFormat {
    /// The original `CSI M` with three biased bytes, which cannot name a cell past 223.
    #[default]
    X10,
    /// DEC mode 1006: `CSI < B ; COL ; ROW M`, cells counted from 1.
    Sgr,
    /// DEC mode 1016: the SGR form with the cell replaced by the pointer's pixel, counted
    /// from 1 at the screen's top-left as xterm does. For a program placing the pointer
    /// inside a picture, where a cell is too coarse to say which part was clicked.
    SgrPixels,
}

impl Mouse {
    pub fn enabled(self) -> bool {
        self.tracking != MouseTracking::Off
    }

    /// Whether the mode in force is 1002, button-event tracking.
    ///
    /// 1003 reports held motion too, but it is its own mode on the wire: Lisp is told
    /// `drag` and `motion` as the two modes, and asks `(or drag motion)` where it means
    /// held motion.
    pub fn drag(self) -> bool {
        self.tracking == MouseTracking::Drag
    }

    /// Whether motion with no button held is reported, which only 1003 asks for.
    pub fn motion(self) -> bool {
        self.tracking == MouseTracking::Motion
    }

    /// Whether a report takes the SGR form, whichever unit its coordinates are in.
    pub fn sgr(self) -> bool {
        self.format != MouseFormat::X10
    }

    /// Whether a report's coordinates are pixels rather than cells.
    pub fn pixels(self) -> bool {
        self.format == MouseFormat::SgrPixels
    }
}

/// A line that scrolled off the screen, and whether the terminal wrapped it.
///
/// Provenance matters downstream: a wrapped row is the continuation of the line
/// above, not a new one. Emacs can rejoin the pair into a single logical line, so
/// yanking history does not pick up newlines the user never typed, and a resize
/// re-wraps it for free.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Scrolled {
    pub runs: Runs,
    pub wrapped: bool,
}

/// Everything that changed since the last drain.
#[derive(Debug, Clone, Default)]
pub struct Delta {
    /// Pictures this delta's cells refer to and Emacs has not been given yet, in
    /// transmission order.
    ///
    /// A field rather than an [`Event`]: it is neither a level nor an occurrence but a
    /// resource the rows of this delta refer to, so Lisp installs it before rendering
    /// them, while events are dispatched after the render.
    ///
    /// Not everything the child transmitted. A child can draw faster than Emacs
    /// redisplays, and frames it drew over in between are referred to by nothing, so they
    /// are dropped; see [`State::shed_unplaced_images`]. What is left crosses once, however
    /// many cells name it; the geometry travels on each
    /// [`Placement`](crate::emu::image::Placement).
    ///
    /// Empty on almost every drain.
    pub images: Vec<ImageData>,
    /// Hyperlink destinations first seen during this drain, as `(ID, URI)`.
    ///
    /// [`Delta::images`]'s sibling in every respect: a resource the rows of this very
    /// delta name by id, so Lisp has to record it before it renders them, and each URI
    /// crosses exactly once however many cells or drains refer to it.
    pub links: Vec<(LinkId, String)>,
    /// Renditions first named, or named anew, since the last drain, as `(ID, STYLE)`.
    ///
    /// A resource like [`Delta::links`]: the runs in this delta name renditions by
    /// [`StyleId`], and Lisp keeps the table they index, so an id crosses with its
    /// rendition once and is installed before anything naming it renders. An id the store
    /// freed and handed out again crosses again, before any row names it in its new
    /// meaning.
    pub styles: Vec<(StyleId, Style)>,
    /// Which renditions change the font, indexed by [`StyleId`], for the layout hash the
    /// row table carries; see `StyleStore::font_bits`.
    pub fonts: Vec<u8>,
    /// Scrolled-off lines, already reduced to styled runs.
    pub scrolled: Vec<Scrolled>,
    /// Absolute index of `scrolled`'s first line, so an [`Anchor`] can be told apart
    /// into "in this batch of scrollback" and "still on the grid".
    pub scrolled_base: usize,
    /// The rows of `scrolled`'s first lines that Emacs already holds, as the top rows of
    /// its screen, exactly as scrollback would get them but for trailing spaces and the
    /// newline a rejoined row gives up: `count` of them, off the top of the region from
    /// row 0 to `bottom`.
    ///
    /// Emacs keeps those rows where they are and moves the start of its screen past them,
    /// rather than inserting the same text again above the screen and deleting the rows it
    /// had. A marker or an overlay on a row at column 5 then stays on its character as
    /// the row becomes history, and a `tail -f` line costs one insertion at the bottom.
    ///
    /// The promotion is its share of the scroll that took those rows off the top, the
    /// scroll of the same region by `count` rows without the deletion, so Emacs opens as
    /// many blank rows at the bottom of the region, and the first of `shifts` is that
    /// scroll less those rows. Only from [`Term::drain_promoting`], and never while the
    /// alternate screen is shown. Rows go as text instead when the copy of what Emacs holds
    /// does not know them: rows a flood scrolled through between drains, a row the width
    /// guard trimmed, and anything after a resize or a switch of screens. So do rows taken
    /// off the grid by anything but that one scroll, a screen clear, or a scroll after
    /// rows lower down have moved.
    pub promoted: Option<Shift>,
    /// Rows that *moved* during this drain, in the order they moved; see [`Shift`].
    ///
    /// Read together with [`Delta::rows`]: a shift says which buffer text to move where,
    /// and the indices in `rows` are in *post-shift* coordinates, so applying the shifts
    /// first is the contract rather than an optimisation.
    ///
    /// Empty on every drain that did not scroll, which is most of them.
    pub shifts: Vec<Shift>,
    /// Rows to rewrite, in ascending index order; see [`DamagedRow`].
    pub rows: Vec<DamagedRow>,
    /// The grid's shape as of this drain, so the buffer never has to hold a second opinion
    /// of it: how tall and wide it is, how many rows of it are occupied ([`Screen::used`]),
    /// and how many characters of row 0's logical line are already in Emacs
    /// ([`Screen::head`]). A width that differs from the last drain's says the rows were
    /// rewrapped, which Lisp needs to know before it rewrites them.
    ///
    /// The last is the seam, and the only one of the three Emacs cannot see for itself —
    /// the marker sitting mid-line is the *consequence* of the head, not a measure of it.
    pub height: usize,
    pub width: usize,
    pub used: usize,
    pub head: usize,
    /// Everything else a drain restates in full every time; see [`Levels`].
    pub levels: Levels,
    /// The cursor's column as characters of its row's text, which is how Emacs finds it:
    /// on `日本X` with the cursor on `X`, column 4, it is 2. See
    /// [`chars_before`](super::cell::chars_before).
    ///
    /// Beside [`Levels`] rather than in it, because the levels are read on every parse to
    /// decide whether there is anything to draw, and this has to walk the row. It cannot
    /// change unless the cursor or its row did, which the levels and the damage see.
    pub cursor_chars: usize,
    pub events: Vec<Event>,
    /// Semantic marks whose position changed during this drain, as `(ID, ANCHOR)`.
    ///
    /// The anchor's column here, and in every [`Event::Mark`] a drain carries, counts the
    /// characters of the row's text before the mark rather than grid columns, because a
    /// buffer position is what Emacs makes of it: a prompt of `日本 ` ends at column 5 and
    /// 3 characters in.
    ///
    /// Empty on most drains. A resize fills it, because a rewrap re-lays every logical
    /// line at the new width and the old buffer positions stop holding; so does a redraw,
    /// which destroys the markers naming them (see [`Term::touch_all`]); and so does an
    /// eviction, which moves them by the difference in how the departing row renders.
    ///
    /// Marks that left the grid during a resize are here too, anchored into this drain's
    /// scrollback batch, which `anchor_to_lisp` already knows how to spell.
    pub marks: Vec<(MarkId, Anchor)>,
    /// Whether this drain left the screen out, being [`Term::drain_hidden`]'s: `rows`,
    /// `shifts` and the marks still on the grid wait in the core, and the next drain that
    /// is not hidden brings them.
    pub withheld: bool,
}

impl Delta {
    /// This drain's scrollback, each row paired with whether Emacs ends a line after it.
    ///
    /// Without REJOIN, which is `cooked-rejoin-wrapped-lines', every row ends one. With
    /// it, a row the terminal wrapped joins the row after it, so a long command line
    /// yanked from history carries no newline the child never wrote. That holds while
    /// the alternate screen is up too, for rows a resize takes off the primary: the row
    /// after the batch's last is the primary's row 0 and not the alternate screen's, and
    /// Lisp keeps the two apart with a newline of its own; see `cooked--place-seam`.
    ///
    /// Here rather than where the scrollback is assembled for Emacs, which needs an `Env`,
    /// so that a test with no Emacs can hold the rule to the same answer.
    pub fn scrolled_lines(&self, rejoin: bool) -> impl Iterator<Item = (&Scrolled, bool)> {
        self.scrolled
            .iter()
            .map(move |line| (line, !(rejoin && line.wrapped)))
    }
}

/// The state a drain restates in full every time, as of the end of that drain.
///
/// These are the levels of the level/occurrence division [`Event`] describes: what Emacs
/// renders from and encodes keys by, rather than anything it must react to. They are
/// gathered into one struct because they are read three times -- by [`Delta`] for Lisp,
/// by [`Pending`] to decide whether a read changed anything, and by the wire encoding --
/// and a field that one of those readers forgot would be a change nobody draws.
/// [`Levels::of`] is the one place a new level is read from the emulator.
///
/// The grid's shape (`height`, `used`, `head`) is not here, because none of the three can
/// move without damaging or evicting a row, and [`Pending`] counts both of those already.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Levels {
    pub cursor: Cursor,
    pub cursor_visible: bool,
    pub cursor_shape: CursorShape,
    /// DECSCNM (DEC mode 5): the child wants the whole screen in reverse video.
    ///
    /// Emacs renders it as a swap of the buffer's default foreground and background, so
    /// nothing in [`Delta::rows`] changes with it and no row is damaged.
    pub reverse_screen: bool,
    /// How many times DECSCNM has changed since the session began, wrapping.
    ///
    /// The level alone loses a `flash`: a set and a reset that land between two drains
    /// leave it where it was, so nothing wakes and Emacs never draws the reversal. That
    /// is not rare, because a drain waits out 2026's synchronised frames and load, and
    /// `flash` holds the reversal for only 100ms. A count that moved while the level did
    /// not is how Emacs tells there was one. It counts `h` and `l`, but not the resets,
    /// which are the child starting over rather than signalling.
    pub reverse_screen_toggles: u32,
    pub alt: bool,
    /// DECCKM: cursor keys must be sent as SS3 (`ESC O A`), not CSI (`ESC [ A`).
    /// ncurses turns this on via `smkx`, and terminfo's `kcuu1` assumes it.
    pub app_cursor: bool,
    /// How to spell modified keys for this child, with the kitty flags or the
    /// modifyOtherKeys level that spelling needs.
    pub keys: KeyEncoding,
}

/// One damaged row as a drain reports it: where it is, whether its logical line
/// continues onto the row below, and the styled runs to rewrite it from.
///
/// `wrapped` is [`Row::wrapped`](crate::emu::cell::Row::wrapped). Emacs needs it on the
/// live grid as well as in scrollback, so that a URL broken across a row boundary can be
/// matched as one string rather than only as far as the break.
#[derive(Clone, Debug)]
pub struct DamagedRow {
    pub index: usize,
    pub wrapped: bool,
    /// The whole row, which is what the row table is measured from even when only part
    /// of it is sent.
    pub runs: Runs,
    /// Part of the row to replace in Emacs' copy instead of the whole of it, when Emacs
    /// holds the rest already; see [`Edit`].
    pub edit: Option<Edit>,
}

/// A replacement for part of a row Emacs already shows.
///
/// A spinner turning, a clock ticking or a progress bar growing changes a few cells of a
/// row, and rewriting the whole row costs Emacs the insertion and the text properties of
/// everything around them, and takes every marker and overlay on the row along. So the
/// drain names the characters to replace instead: CHAR-START..CHAR-END of the buffer's
/// text for the row, counted in characters as the buffer holds them, and the runs that
/// go there.
///
/// Offsets are characters of the text *Emacs* holds, not columns of the grid: a wide
/// character is one character on two columns, and a combining mark is a character on
/// none. The core counts them from its copy of what it last sent.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Edit {
    /// Characters of the row before the replaced text.
    pub char_start: usize,
    /// Where the replaced text ends, or `None` for the end of the line, which is how a
    /// change that reaches the row's old last character is spelled: it also takes any
    /// spaces Lisp padded the row with.
    pub char_end: Option<usize>,
    /// Characters of the whole row once the edit is made. Text past it in the buffer is
    /// padding Lisp added for a cursor that has since moved on, which rewriting the row
    /// would have removed, and so does an edit.
    pub chars: usize,
    /// What replaces it.
    pub runs: Runs,
}

/// A reading of everything [`Delta`] carries, cheap enough to take on every read.
///
/// [`Term::feed`] takes one of these either side of a parse and compares them to decide
/// whether anything is left to draw. It is a *reading* rather than a flag set by the code
/// that changes things, because a flag would have to be set in each of `perform`'s dozens
/// of arms, and a forgotten one would stop repainting. The levels are the same [`Levels`]
/// the drain carries.
///
/// The queues are counted rather than examined because they only ever grow between
/// drains. Damage is counted for a subtler reason: it stays up until Emacs drains, so a
/// flag would read `true` on both sides of a read and make a program repainting flat out
/// look like one doing nothing at all. See [`Screen::touches`].
#[derive(PartialEq, Eq)]
struct Pending {
    touches: u64,
    scrolled: usize,
    images: usize,
    links: usize,
    events: usize,
    marks: (bool, usize),
    levels: Levels,
}

impl Pending {
    fn of(state: &State) -> Self {
        Self {
            touches: state.screen().touches(),
            scrolled: state.pending_scrollback.len(),
            images: state.pending_images.len(),
            links: state.pending_links.len(),
            events: state.events.len(),
            marks: (state.marks_dirty, state.evicted_marks.len()),
            levels: Levels::of(state),
        }
    }
}

/// How long a child may hold back a redisplay with DEC mode 2026 before we draw anyway.
///
/// Synchronized output exists so a half-drawn frame is never shown, not to freeze the
/// buffer: a child killed mid-frame never sends the end marker. xterm and contour use
/// 150ms and kitty 100; the longer is safer on a loaded machine.
///
/// Armed at every BSU. `Notifier::set_sync` keeps a client that begins its next frame
/// before the last was drawn from pushing the deadline out again.
pub(crate) const SYNC_TIMEOUT: std::time::Duration = std::time::Duration::from_millis(150);

/// Backlog at which the reader stops pulling from the pty, letting the child block.
pub const BACKLOG_HIGH_WATER: usize = 8_000;

/// Bytes of pending image payload that count as one unit of [`Term::backlog`].
///
/// A conversion factor, because the backlog is one scalar against one limit. At 1KB a
/// unit, [`BACKLOG_HIGH_WATER`] comes to roughly 8MB of undrained pictures.
///
/// That figure sits well above what 8000 rows come to because it must not take work away
/// from shedding. An animation redrawing in place has its overdrawn frames shed (see
/// `State::shed_unplaced_images`), which holds at most two payloads however far behind
/// Emacs falls; throttling it instead would slow the animation to buy nothing. `viu` is
/// 2.1MB a frame, so two frames sit comfortably under 8MB. The budget is for what
/// shedding cannot touch: many *distinct* pictures, all still displayed, arriving faster
/// than they can be drained.
pub(crate) const IMAGE_BACKLOG_UNIT: usize = 1024;

/// Largest OSC payload forwarded to Lisp, in bytes: everything after `CODE ;`, the
/// semicolons between its fields included. Well past any real title or
/// hyperlink, and short of letting a single escape sequence allocate without bound.
pub(crate) const OSC_PAYLOAD_LIMIT: usize = 1 << 20;

/// Most fields an OSC payload is cut into for Lisp; the last keeps the semicolons left.
/// No OSC Lisp handles has more than a handful.
pub(crate) const MAX_OSC_FIELDS: usize = 16;

/// How long a `cmdline_url=` may be before the `C` mark is taken without one.
///
/// A command line is typed, so this is generous past anything a person writes and still
/// far short of letting a hostile stream size our heap. A `C` with an over-long command
/// line is still a `C`; only the courtesy is dropped.
pub(crate) const MAX_CMDLINE_LEN: usize = 8 << 10;

/// The longest text one `OSC 66` may carry, which is the spec's own number.
///
/// "the text must be no longer than 4096 bytes. Longer strings than that must be broken
/// up into multiple escape codes." Not a defensive bound -- the parser's
/// [`MAX_OSC_RAW`](crate::emu::parser::MAX_OSC_RAW) is that -- but the protocol's, so a
/// sender that has stopped chunking finds out here rather than in a strange rendering.
pub(crate) const MAX_TEXT_SIZE_LEN: usize = 4096;

/// Longest sixel body collected from one DCS string.
///
/// Sixel is a verbose encoding — one byte per six pixels per colour pass — so this is
/// smaller than it looks: a full-screen picture is comfortably inside it, and the decoded
/// result is bounded again, and more tightly, by [`sixel::MAX_PIXELS`].
pub(crate) const SIXEL_BODY_LIMIT: usize = 8 << 20;

/// Depth of the XTPUSHSGR pen stack: xterm's own `MAX_SAVED_SGR`. A push past it is
/// dropped, as xterm drops it, so a child written against xterm sees the same pops here.
const SGR_STACK_LIMIT: usize = 10;

/// Ceiling on the `c=`/`r=` cell span an image placement is honoured for.
///
/// This bounds how many real `linefeed`s, each a possible scroll and archive, a single
/// placement can force; see its use in `State::intern_image`. 4096 rows is far more than
/// any real picture needs and far short of letting one small transmission stall the
/// reader.
const MAX_IMAGE_CELL_SPAN: u16 = 4096;

/// A `width=`/`height=` value that is a plain cell count, or 0 for anything else.
///
/// iTerm2 spells sizes four ways: bare digits mean cells, `Npx` means pixels, `N%` means
/// a share of the window, and `auto` means the picture decides. Only the first is a cell
/// rectangle we can honour directly; every other spelling falls back to what the pixels
/// imply, which is what a missing key already does.
fn plain_cells(value: &str) -> Option<u16> {
    if value.is_empty() || !value.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    Some(u16::try_from(value.parse::<u32>().ok()?).unwrap_or(u16::MAX))
}

/// What `CSI ? 996 n` answers, and what mode 2031 pushes.
///
/// The discriminants are the protocol's own numbers. There is no third variant: "Emacs
/// has not said yet" is `Option::None`, outside the enum where it cannot be formatted into
/// a reply, because the spec defines no value a child could read as "unknown".
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ColorScheme {
    Dark = 1,
    Light = 2,
}

impl std::fmt::Display for ColorScheme {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", *self as u8)
    }
}

impl State {
    /// The shown screen's text area in pixels, or `None` before Emacs reports a cell size.
    pub(super) fn text_area(&self) -> Option<PixelSize> {
        let screen = self.screen();
        Some(self.metrics?.text_area(screen.height(), screen.width()))
    }

    /// The mode 2048 report for the screen as it stands.
    pub(super) fn current_size_report(&self) -> Vec<u8> {
        size_report(self.screen().height(), self.screen().width(), self.metrics)
    }

    /// Queue a CSI reply, `ESC [ BODY`; see [`reply::frame`] for what is refused.
    pub(crate) fn csi_reply(&mut self, body: std::fmt::Arguments<'_>) {
        self.reply(Framing::Csi, body);
    }

    /// Queue a DCS reply, `ESC P BODY ESC \`.
    pub(crate) fn dcs_reply(&mut self, body: std::fmt::Arguments<'_>) {
        self.reply(Framing::Dcs, body);
    }

    fn reply(&mut self, framing: Framing, body: std::fmt::Arguments<'_>) {
        if let Some(bytes) = reply::frame(framing, body) {
            self.push_reply(Event::answer(bytes));
        }
    }

    /// Owe the child REPLY, an [`Event::Reply`] of either kind.
    ///
    /// Straight to [`Term::take_outbound`] when the session has asked for that and nothing
    /// Lisp has yet to answer came first; otherwise with the drain, as every reply once
    /// went. See [`ReplyRoute`].
    pub(super) fn push_reply(&mut self, reply: Event) {
        debug_assert!(matches!(reply, Event::Reply(..)));
        let route = &mut self.replies;
        if route.direct && !route.undrained && !route.handling {
            route.outbound.push(reply);
        } else {
            // Behind something Lisp answers, so everything after it must wait too, or a
            // later answer would overtake this one.
            route.undrained = true;
            self.events.push(reply);
        }
    }

    /// Hand Lisp EVENT, noting whether it is a question Lisp may answer.
    ///
    /// Only [`Event::Osc`] and [`Event::FrameSize`] come through here, the two that Lisp
    /// replies to. Every other event is pushed directly.
    pub(super) fn push_for_lisp(&mut self, event: Event) {
        if event.awaits_answer() {
            self.replies.undrained = true;
        }
        self.events.push(event);
    }
}

/// Whether a reply the emulator composes may go straight to the child, or must travel
/// with the drain behind a question only Lisp can answer.
///
/// Replies once all went with the drain, and a drain is deferred while a buffer is frozen,
/// so DA1 from a frozen buffer's child waited for the thaw. The emulator composes most
/// replies alone and can send those at once. The exceptions are queries answered from
/// Emacs' own state: the palette and default colours (OSC 4, 10 to 19), the clipboard
/// (OSC 52), the pointer (OSC 22) and the frame's size (`CSI 19 t`).
///
/// Order is what makes that more than a shortcut. `OSC 11 ; ? ST` followed by DA1 is how
/// a program asks for the background with a deadline: DA1 is answered by every terminal,
/// so a reply to it arriving first means the colour query went unanswered. Sending DA1
/// ahead of Lisp's answer would say exactly that. So once such a query is waiting, every
/// later reply waits with it, in the drain, until Lisp says it has handled the drain that
/// carried it.
#[derive(Debug, Default)]
pub(super) struct ReplyRoute {
    /// Whether anything takes replies from [`Term::take_outbound`]. Off by default, so a
    /// [`Term`] with no session behind it keeps every reply in its drain, which is where
    /// the emulator's own tests look for them.
    direct: bool,
    /// Replies bound straight for the child, in the order they were composed.
    outbound: Vec<Event>,
    /// The undrained events hold a question for Lisp, or a reply queued behind one.
    undrained: bool,
    /// A drain carried such a question, and Lisp has not yet said it is handled; see
    /// [`Term::events_handled`].
    handling: bool,
}

pub struct Term {
    parser: Parser,
    state: State,
}

impl Term {
    pub fn new(rows: usize, cols: usize) -> Self {
        Self {
            parser: Parser::new(),
            state: State::new(rows, cols),
        }
    }

    /// A terminal whose rendition table looks for ids to free once LIMIT renditions are
    /// live, rather than at the four thousand an ordinary one holds.
    ///
    /// For a property test to reach id reuse at all: on an 8x12 grid a script would need
    /// thousands of distinct pens before a collection ran, and with a limit of 4 one runs
    /// every few `SGR`s, so an id a collection wrongly freed is soon handed to another
    /// rendition while something still names it.
    #[doc(hidden)]
    pub fn with_style_limit(rows: usize, cols: usize, limit: usize) -> Self {
        let mut term = Self::new(rows, cols);
        term.state.styles = StyleStore::with_limit(limit);
        term
    }

    /// Parse BYTES, reporting whether they changed anything Emacs would draw.
    ///
    /// The answer lets the reader thread avoid waking Emacs for bytes that change nothing,
    /// which under a graphics protocol is most of them: a kitty image arrives as megabytes
    /// of base64 in one APC string, and every read of it but the last leaves the grid as
    /// it was.
    ///
    /// "Anything Emacs would draw" is [`Delta`]'s contents, which is why [`Pending`] reads
    /// them field by field rather than checking a damage flag: a cursor move with no
    /// damage is still a real update.
    pub fn feed(&mut self, bytes: &[u8]) -> bool {
        let progress = self.feed_start();
        self.feed_all(bytes);
        self.woken(&progress, false, 0)
    }

    /// Where a feed began, for [`Term::woken`] to compare against.
    pub fn feed_start(&self) -> Progress {
        Progress {
            pending: Pending::of(&self.state),
            events: self.state.events.len(),
        }
    }

    /// Parse BYTES until they run out or a picture needs decoding.
    ///
    /// The reader's half of [`Term::feed`]: it holds the lock for the parse, which is
    /// microseconds, and not for the decode, which for a kitty transfer is base64 over
    /// megabytes, an inflate and a PNG encode. On [`Feed::Decode`] the caller runs the
    /// job with the terminal unlocked, brings the result to [`Term::resume`], and feeds
    /// the bytes past the count returned. Nothing after the picture is parsed until the
    /// picture is placed, so the cursor moves in the order the child wrote.
    pub fn feed_step(&mut self, bytes: &[u8]) -> Feed {
        let consumed = self.parser.advance_until_terminated(&mut self.state, bytes);
        match self.state.decode.take() {
            Some(job) => Feed::Decode(job, consumed),
            None => Feed::Done,
        }
    }

    /// Place what a [`Feed::Decode`] job produced.
    pub fn resume(&mut self, decoded: Decoded) {
        self.state.apply_decoded(decoded);
    }

    /// Whether anything since PROGRESS warrants waking Emacs.
    ///
    /// For a shown screen, anything Emacs would draw: [`Pending`]'s contents, read field
    /// by field rather than as a damage flag, because a cursor move with no damage is
    /// still a real update. For a HIDDEN one, an event, which a child may be waiting on,
    /// or a backlog half way to LIMIT; see [`Term::feed_hidden`].
    pub fn woken(&self, progress: &Progress, hidden: bool, limit: usize) -> bool {
        if hidden {
            self.state.events.len() != progress.events || self.backlog() >= limit / 2
        } else {
            Pending::of(&self.state) != progress.pending
        }
    }

    /// [`Term::feed_step`] to the end, decoding in place: for a caller with no lock to
    /// drop, which is Lisp's `cooked--feed' and the tests.
    fn feed_all(&mut self, bytes: &[u8]) {
        let mut offset = 0;
        loop {
            match self.feed_step(&bytes[offset..]) {
                Feed::Done => return,
                Feed::Decode(job, consumed) => {
                    offset += consumed;
                    self.resume(job.run());
                }
            }
        }
    }

    /// Parse BYTES for a buffer no window shows, reporting whether Emacs has to be woken.
    ///
    /// [`Term::feed`]'s question with the screen taken out of it, since
    /// [`Term::drain_hidden`] would leave the screen behind anyway. What remains is an
    /// event, which a child may be waiting on, and a backlog half way to LIMIT, the
    /// point at which the reader stops and the child blocks: a hidden build printing a
    /// line a millisecond wakes Emacs once every four thousand lines rather than once a
    /// frame, and one flooding the pty is drained as often as it would be if shown.
    pub fn feed_hidden(&mut self, bytes: &[u8], limit: usize) -> bool {
        let progress = self.feed_start();
        self.feed_all(bytes);
        self.woken(&progress, true, limit)
    }

    /// Everything that changed since the last drain, every scrolled row as text.
    pub fn drain(&mut self) -> Delta {
        self.drain_with(false)
    }

    /// Everything that changed since the last drain, for a consumer that keeps the screen
    /// as text of its own and can promote the rows of it that scroll away; see
    /// [`Delta::promoted`].
    pub fn drain_promoting(&mut self) -> Delta {
        self.drain_with(true)
    }

    fn drain_with(&mut self, promote: bool) -> Delta {
        let route = &mut self.state.replies;
        route.handling |= std::mem::take(&mut route.undrained);
        self.state.drain(promote)
    }

    /// Drain for a buffer no window shows: everything but the screen.
    ///
    /// The events, the scrollback and the resources it names go, so a hidden child is
    /// answered, its bells and titles and notifications arrive, and the backlog that would
    /// otherwise stop the reader is emptied. The damaged rows, the shifts and the marks
    /// still on the grid stay behind and keep accumulating, so the core's copy of the rows
    /// Emacs holds stays true: Emacs has not touched them either. The next [`Term::drain`]
    /// brings the screen up to date in one go, and a shift log that turned the screen over
    /// in the meantime saturates into a repaint of the rows that really changed.
    ///
    /// The marks that scrolled away do go, anchored in this drain's scrollback, because
    /// the rows they sit on arrive here and nowhere else.
    ///
    /// A whole drain after all, marked by [`Delta::withheld`] being false, when an event
    /// needs the screen's text; see [`Event::needs_text`].
    pub fn drain_hidden(&mut self) -> Delta {
        if self.state.events.iter().any(Event::needs_text) {
            return self.drain();
        }
        let route = &mut self.state.replies;
        route.handling |= std::mem::take(&mut route.undrained);
        self.state.drain_hidden()
    }

    /// Drop what a child has stopped sending: a chunked picture with no chunk for
    /// [`crate::emu::kitty::TRANSFER_TIMEOUT`]. For the reader's tick, which is the one
    /// thing that runs while the child is quiet.
    pub fn sweep(&mut self) {
        self.state.kitty.abandon_stale(std::time::Instant::now());
    }

    /// Send replies to [`Term::take_outbound`] from now on, rather than with the drain,
    /// whenever nothing Lisp answers is ahead of them. See [`ReplyRoute`].
    pub fn answer_directly(&mut self) {
        self.state.replies.direct = true;
    }

    /// The replies owed to the child that need nothing from Lisp, oldest first, each an
    /// [`Event::Reply`] of either kind.
    pub fn take_outbound(&mut self) -> Vec<Event> {
        std::mem::take(&mut self.state.replies.outbound)
    }

    /// Lisp has handled every event of the drains so far, and answered what it was asked.
    ///
    /// Replies composed from here on go straight out again, unless a question has arrived
    /// since the last drain. Replies that queued behind the question as events are moved to
    /// [`Term::take_outbound`] when nothing Lisp answers is still ahead of them, since no
    /// drain need carry them any more.
    pub fn events_handled(&mut self) {
        let state = &mut self.state;
        state.replies.handling = false;
        state.palette_pending = state.events.iter().any(Event::asks_about_color);
        if !state.replies.direct || !state.replies.undrained {
            return;
        }
        let ahead = state
            .events
            .iter()
            .position(Event::awaits_answer)
            .unwrap_or(state.events.len());
        if ahead == state.events.len() {
            state.replies.undrained = false;
        }
        let mut index = 0;
        let outbound = &mut state.replies.outbound;
        state.events.retain(|event| {
            let before = index < ahead;
            index += 1;
            let reply = matches!(event, Event::Reply(..));
            if before && reply {
                outbound.push(event.clone());
            }
            !(before && reply)
        });
    }

    pub fn resize(&mut self, rows: usize, cols: usize) {
        self.state.resize(rows, cols);
    }

    /// Tell the emulator how big one cell is, in pixels.
    ///
    /// Emacs' to measure and ours to answer with. Without it a `width=200px` request
    /// cannot become a cell count, and the XTWINOPS reports that image tools consult have
    /// nothing to say.
    ///
    /// Nothing is forgotten when the cell size changes. A transmission is measured into
    /// cells against the metrics at the time it arrives, and rows already written keep the
    /// rectangle they were laid at, which rides every
    /// [`Placement`](crate::emu::image::Placement); `cooked--rescale-deco' re-cuts their
    /// slices to the new cell.
    pub fn set_cell_metrics(&mut self, metrics: Option<CellMetrics>) {
        self.state.metrics = metrics;
    }

    /// Resize to ROWS by COLS with cells of METRICS, returning the mode 2048 report owed.
    ///
    /// [`Term::resize`] and [`Term::set_cell_metrics`] together, because the report
    /// describes both: a font change moves the pixel size with the row count unchanged.
    /// Nothing is owed for a call that changes nothing, or to a child that has not set the
    /// mode.
    ///
    /// The bytes come back rather than being queued, because a resize produces no child
    /// output and no drain is coming to carry them. `Session::resize` writes them right
    /// after the `TIOCSWINSZ`, so the report and the ioctl describe one geometry.
    ///
    /// An undrained report -- the answer to a `2048 h` sent a moment ago -- is dropped,
    /// because it would reach the child *after* this one and leave it on the old size.
    pub fn set_size(
        &mut self,
        rows: usize,
        cols: usize,
        metrics: Option<CellMetrics>,
    ) -> Option<Vec<u8>> {
        let before = self.state.current_size_report();
        self.resize(rows, cols);
        self.set_cell_metrics(metrics);
        if !self.state.modes.size_reports {
            return None;
        }
        let report = self.state.current_size_report();
        if report == before {
            return None;
        }
        self.state
            .events
            .retain(|e| !matches!(e, Event::Reply(_, ReplyKind::SizeReport)));
        self.state
            .replies
            .outbound
            .retain(|e| !matches!(e, Event::Reply(_, ReplyKind::SizeReport)));
        Some(report)
    }

    pub fn cell_metrics(&self) -> Option<CellMetrics> {
        self.state.metrics
    }

    /// Tell the emulator whether Emacs renders light or dark, returning what a subscriber
    /// to mode 2031 is now owed.
    ///
    /// The bytes come back rather than being pushed as an [`Event::Reply`], because a theme
    /// change produces no child output and nothing would wake a drain; an idle subscriber
    /// would hear only when the user next typed. Lisp sends them with
    /// `cooked--send-if-live', since this runs from a global hook where a child that has
    /// just exited is an ordinary race rather than an error.
    ///
    /// Nothing is owed for a theme reloaded onto itself, and nothing to a child that
    /// never subscribed.
    pub fn set_color_scheme(&mut self, scheme: ColorScheme) -> Option<Vec<u8>> {
        let changed = self.state.color_scheme.replace(scheme) != Some(scheme);
        (changed && self.state.modes.color_scheme_updates).then(|| color_scheme_report(scheme))
    }

    /// Tell the emulator the colours Emacs draws with, so it can answer for them.
    ///
    /// Nothing is owed on a change, unlike the colour scheme: a palette entry is not a
    /// subscription, and a child that wants to know a colour again asks again. See
    /// [`osc::Palette`] for what is held and what is still Lisp's, and
    /// `cooked--set-palette' for when Lisp says it.
    pub(crate) fn set_palette(&mut self, palette: osc::Palette) {
        self.state.palette = palette;
    }

    /// Tell the emulator which pictures this session transmits Emacs can show.
    ///
    /// Nothing is owed on a change: none of the answers it governs is a subscription.
    pub fn set_graphics_shown(&mut self, shown: ShownFormats) {
        self.state.graphics = shown;
    }

    /// Take BYTES as an image and lay it into the grid at the cursor.
    ///
    /// Interning is content-addressed, so a child redrawing the same picture every frame
    /// hands the bytes over once. Rows are laid top to bottom from the cursor, scrolling
    /// past the bottom of the screen, and the cursor lands at the start of the row below:
    /// the sixel and iTerm2 disposition.
    pub fn place_image(&mut self, format: ImageFormat, bytes: &[u8], px: PixelSize) -> ImageId {
        self.state.place_image(format, bytes, px)
    }

    /// Emacs has dropped image ID's bytes, so stop believing it has them.
    ///
    /// Emacs is the only cache (see [`ImageStore`]), and this keeps the module's
    /// bookkeeping honest about it. Everything hung off the id goes at once, including the
    /// client's own name for the picture, so a later `a=p` is answered `ENOENT:image`
    /// rather than placing cells nothing can draw. Retransmitting the same bytes later
    /// mints a fresh id and the payload crosses again.
    pub fn forget_image(&mut self, id: ImageId) {
        self.state.forget_image(id);
    }

    /// Emacs has discarded the scrollback, so the top row continues nothing.
    pub fn forget_history(&mut self) {
        self.state.screens.primary.forget_carry();
    }

    /// Mark every row of the current screen damaged, so the next drain re-sends all of
    /// it. The way back from a redisplay that failed part-way and left Emacs' idea of
    /// the screen region disagreeing with ours.
    ///
    /// Every live mark is reported along with the rows. Emacs is about to delete the
    /// screen region and rebuild it, which collapses the markers it holds into that text
    /// even though the rows come back identical; without the repair, `cooked-refresh' would
    /// fix the picture and break every command record on screen.
    pub fn touch_all(&mut self) {
        self.state.screen_mut().touch_all();
        self.state.marks_dirty = true;
        self.state.forget_sent(None);
    }

    /// Emacs has edited its own text for screen row INDEX, or for every row when INDEX is
    /// `None`, so the row is sent the next time it is damaged even if its cells match what
    /// was sent last. The width guard deleting characters off a row that wrapped is the
    /// edit this exists for, and a theme change is the reason for the whole-screen form: a
    /// repaint of the same cells has to pick up the new colours.
    pub fn forget_sent(&mut self, index: Option<usize>) {
        self.state.forget_sent(index);
    }

    /// Remove `count` grid rows starting at `first`; see [`Screen::remove_rows`].
    ///
    /// One of the two edits the grid accepts from Emacs, with [`Term::clear_to_prompt`].
    /// Emacs asks rather than deleting buffer text itself because the rows have one owner,
    /// and the drain that follows repaints what moved like any other.
    pub fn remove_rows(&mut self, first: usize, count: usize) {
        self.state.remove_rows(first, count);
    }

    /// Drop every grid row above the current prompt, returning how many went.
    ///
    /// The grid's half of clearing the terminal. Which row the prompt is on is arithmetic
    /// over state only the emulator keeps -- [`State::prompt_start`] against
    /// [`State::evicted_total`] -- and rediscovering it from buffer positions would get a
    /// two-line prompt wrong, cutting at the input row. Without OSC 133 the cursor row
    /// stands in.
    pub fn clear_to_prompt(&mut self) -> usize {
        self.state.clear_to_prompt()
    }

    /// The rendition a cell or run's [`StyleId`] names, as of now.
    ///
    /// For reading a grid back -- the tests, and anything else holding rows outside a
    /// drain. A drain's own runs are resolved by the `:styles` the same drain carries.
    pub fn style(&self, id: StyleId) -> Style {
        self.state.styles.get(id)
    }

    /// How many renditions the store holds ids for, which a collection keeps bounded.
    pub fn styles_held(&self) -> usize {
        self.state.styles.len()
    }

    pub fn screen(&self) -> &Screen {
        self.state.screen()
    }

    pub fn mouse(&self) -> Mouse {
        self.state.modes.mouse
    }

    pub fn bracketed_paste(&self) -> bool {
        self.state.modes.bracketed_paste
    }

    pub fn focus_events(&self) -> bool {
        self.state.modes.focus_events
    }

    /// What this child is owed for the window gaining or losing focus, if anything.
    ///
    /// `CSI I` and `CSI O`, DEC mode 1004's two notifications, or `None` from a child
    /// that never subscribed. The question and the answer together, because asking
    /// separately is asking about a mode that can have changed by the time the bytes are
    /// queued: a focus change is reported from a global hook, arbitrarily far from
    /// anything the child wrote, and a program that has just turned 1004 off reads a
    /// stray `CSI I` as the escape sequence it looks like rather than as news it asked
    /// for.
    pub fn focus_report(&self, focused: bool) -> Option<&'static [u8]> {
        self.state.modes.focus_events.then(|| {
            if focused {
                &b"\x1b[I"[..]
            } else {
                &b"\x1b[O"[..]
            }
        })
    }

    /// How long this frame may still suppress a redisplay, if it may at all.
    pub fn sync_deadline(&self) -> Option<std::time::Instant> {
        self.state
            .modes
            .sync_until
            .filter(|t| std::time::Instant::now() < *t)
    }

    /// Whether a wheel notch should become cursor keys: the child asked for alternate
    /// scroll, the alternate screen is up, and it did not ask for the mouse itself —
    /// a program that wants mouse reports gets mouse reports, as in xterm.
    pub fn alt_scroll(&self) -> bool {
        self.state.modes.alt_scroll
            && self.state.shown.is_alternate()
            && !self.state.modes.mouse.enabled()
    }

    pub fn app_cursor(&self) -> bool {
        self.state.modes.app_cursor
    }

    /// How the child wants modified keys spelled.
    pub fn keys(&self) -> KeyEncoding {
        self.state.key_encoding()
    }

    /// The kitty keyboard flags on the shown screen's stack, as far as cooked honours
    /// them: what `CSI ? u` answers, whether or not they switch the kitty encoding on.
    pub fn kitty_flags(&self) -> KittyFlags {
        self.state.kitty_flags()
    }

    /// Test-only: send every character down the per-character print path.
    ///
    /// Lets a test compare the slow path against the batched one character for character;
    /// see [`State::force_per_character_print`].
    #[cfg(test)]
    pub(crate) fn force_per_character_print(&mut self) {
        self.state.force_per_character_print = true;
    }

    /// Test-only: how many sequences no arm recognised; see [`State::unrecognised`].
    #[cfg(test)]
    pub(crate) fn unrecognised(&self) -> usize {
        self.state.unrecognised
    }

    /// How much undrained work is queued, in the one currency backpressure understands.
    ///
    /// Rows and events count themselves. Pictures are counted by weight instead, at
    /// [`IMAGE_BACKLOG_UNIT`] bytes to the unit: a pending image is one item and several
    /// megabytes, so counting items would let a child queue a gigabyte of frames without
    /// troubling a limit written for rows.
    ///
    /// Summed rather than kept as a running total, so there is no second copy of the fact
    /// to disagree with the payloads. Shedding keeps the vector short, so the sum is cheap.
    pub fn backlog(&self) -> usize {
        let image_bytes: usize = self
            .state
            .pending_images
            .iter()
            .map(|image| image.bytes.len())
            .sum();
        self.state.pending_scrollback.len()
            + self.state.events.len()
            + image_bytes / IMAGE_BACKLOG_UNIT
    }

    /// Text of the last non-blank line — the prompt a `getpass` child just printed.
    pub fn trailing_text(&self) -> Option<String> {
        self.state.screen().last_nonblank_text()
    }

    /// The rows the shown screen occupies, one [`Runs`] per screen row, top row first.
    ///
    /// The whole of the screen rather than what changed, for a consumer that shows it
    /// without keeping a copy: `cooked-process.el' hangs the live rows under a
    /// compilation buffer as an overlay, where a progress bar the child rewrites in place
    /// is the only thing that never retires. Reading them here is what spares that file a
    /// second reading of [`Delta`]'s shifts, rows and edits — the delta protocol has one
    /// renderer, and `cooked--render-block' is it.
    ///
    /// [`Screen::used`](crate::emu::screen::Screen::used) rows, so a blank row below the
    /// content is left out and the cursor's own row is not, exactly as the drain's
    /// `:used' reports it.
    pub fn screen_text(&self) -> Vec<Runs> {
        let screen = self.state.screen();
        (0..screen.used())
            .filter_map(|index| screen.row(index).map(|row| row.runs()))
            .collect()
    }
}

/// Everything the child negotiated, and nothing else.
///
/// One struct because DECSTR and RIS are defined as "put every negotiated mode back to
/// power-on", and `Modes::default()` says that in one statement, so a new mode cannot be
/// left out of the reset.
///
/// The `Default` impl is hand-written for one field: DECTCEM starts *set*, so a terminal
/// powers on with a visible cursor.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Modes {
    cursor_visible: bool,
    cursor_shape: CursorShape,
    /// Whether the last DECSCUSR asked for the blinking spelling of its shape.
    ///
    /// Never rendered -- blink is `blink-cursor-mode`'s, as [`CursorShape`] says -- and
    /// kept only so DECRQSS hands back the setting the child made: a child that set `1 q`
    /// and saves its style is owed `1 q`, not `2 q`. Starts set, because DECSCUSR defines
    /// the power-on style 0 as a blinking block.
    cursor_blink: bool,
    /// DEC mode 5, DECSCNM: reverse video across the whole screen.
    ///
    /// Screen state the child owns, like SGR 7 over every cell, unlike mode 12's blink,
    /// which is the user's preference. `flash' in our terminfo is a set, a 100ms pause and
    /// a reset, which is how vim's `visualbell' reaches it.
    ///
    /// Cleared by DECSTR, which the VT510 does not do, because `is2' and `rs2' both send
    /// DECSTR and a screen left reversed by a child killed mid-flash is what `reset' is
    /// typed to fix.
    reverse_screen: bool,
    /// DEC mode 2004. No event: nothing reacts to this. It is read at the one moment it
    /// matters, by [`Term::bracketed_paste`] as a multi-line submission is being framed.
    bracketed_paste: bool,
    /// DEC mode 1004: the child wants `CSI I`/`CSI O` when the window gains or loses
    /// focus. Read at the moment focus changes, so it is state rather than a level.
    focus_events: bool,
    /// DEC mode 2031: the child wants the colour scheme reported whenever it changes. The
    /// scheme itself is Emacs' answer and lives on [`State`], so a soft reset ends the
    /// subscription without forgetting the theme.
    color_scheme_updates: bool,
    /// DEC mode 2048: the child wants `CSI 48 ; rows ; cols ; hpx ; wpx t` when it
    /// subscribes and on every resize. SIGWINCH does not cross ssh and bytes do, so this is
    /// how a remote multiplexer learns the size. Read by [`Term::set_size`].
    size_reports: bool,
    /// DEC mode 1007: on the alternate screen, a wheel notch becomes cursor keys. This
    /// is what makes the wheel scroll in `less`, `man` and `git log`.
    alt_scroll: bool,
    /// DEC mode 2026: the deadline until which this frame may suppress redisplay.
    ///
    /// A deadline captured at the transition rather than a bare flag, so the safety
    /// timeout needs no extra bookkeeping: a child that opens a frame and then dies
    /// cannot hold Emacs past it, because the hold expires on its own.
    sync_until: Option<std::time::Instant>,
    mouse: Mouse,
    origin_mode: bool,
    /// SCS designations and the shifts; see [`Charsets`]. A soft reset puts ASCII back in
    /// every slot and G0 in GL, which is what DECSTR is documented to do.
    charsets: Charsets,
    app_cursor: bool,
    app_keypad: bool,
    /// xterm's modifyOtherKeys level, or `None` for a level cooked does not honour.
    modify_other_keys: Option<ModifyOtherKeys>,
    /// Kitty keyboard flag stacks, one per screen; see [`KittyFlags::HONOURED`] for which
    /// bits are read.
    ///
    /// The spec says the screens "must maintain their own, independent, keyboard mode
    /// stacks". A full-screen program pushes after entering the alternate screen, and if
    /// it dies without popping, a shared stack would leave the shell reporting keys in a
    /// protocol it never asked for; with one per screen, `?1049l` is the cleanup. As in
    /// kitty, nothing clears the alternate stack on the way back in, but the shell's OSC
    /// 133 `D` empties it and restores the primary one; see [`State::take_back`].
    kitty_keys: PerScreen<KittyStack>,
    /// LNM (ANSI mode 20): LF also returns the carriage.
    newline_mode: bool,
    /// XTPUSHSGR's stack, innermost last, at most [`SGR_STACK_LIMIT`] deep.
    ///
    /// Here rather than beside [`State::pen`] so a reset clears it: a pop after DECSTR or
    /// RIS must not hand back a pen from before the child said "start over".
    pen_stack: Vec<PushedPen>,
    /// XTSAVE's slots: one saved value per private mode, overwritten by a second save.
    ///
    /// A slot per mode rather than a stack, which is what xterm and ghostty both keep, and
    /// which bounds this by the number of modes [`State::save_mode`] recognises no matter
    /// how often a child saves.
    saved_modes: Vec<(modes::DecMode, SavedMode)>,
}

impl Default for Modes {
    fn default() -> Self {
        Self {
            // DECTCEM: the one mode whose power-on value is not the zero value.
            cursor_visible: true,
            cursor_shape: CursorShape::default(),
            cursor_blink: true,
            reverse_screen: false,
            bracketed_paste: false,
            focus_events: false,
            alt_scroll: false,
            color_scheme_updates: false,
            size_reports: false,
            sync_until: None,
            mouse: Mouse::default(),
            origin_mode: false,
            charsets: Charsets::default(),
            app_cursor: false,
            app_keypad: false,
            modify_other_keys: None,
            kitty_keys: Default::default(),
            newline_mode: false,
            pen_stack: Vec::new(),
            saved_modes: Vec::new(),
        }
    }
}

/// A picture's payload, collected whole and owed a decode.
///
/// Decoding is the one thing the parser does that is not proportional to the bytes it
/// was handed: a 32MB kitty transfer arrives in five hundred reads that each cost a
/// scan, and then one that costs the base64, the inflate and the PNG encode of the
/// whole. Done under the terminal's lock that last read stalled every drain, resize and
/// keystroke on Emacs' thread for as long as it took. So the dispatch that completes a
/// picture stores it here and the parser stops -- `Perform::terminated` -- and the
/// reader runs [`Decode::run`] with the lock dropped.
///
/// Stopping the parser is what keeps the order: nothing after the picture is parsed
/// until [`Term::resume`] has placed it, so a newline the child printed after its image
/// still lands below it.
#[derive(Debug)]
pub struct Decode(Job);

/// The two producers whose payloads are worth decoding off the lock. iTerm2's `OSC 1337`
/// is not one: its file is bounded by the OSC limit and sniffed rather than decoded.
#[derive(Debug)]
enum Job {
    Kitty(crate::emu::kitty::Transfer),
    Sixel(Vec<u8>),
}

/// What a [`Decode`] came to, for [`Term::resume`].
#[derive(Debug)]
pub struct Decoded(Picture);

#[derive(Debug)]
enum Picture {
    Kitty(Outcome, Option<Vec<u8>>),
    Sixel(Option<sixel::Bitmap>),
}

impl Decode {
    /// The decode itself. Pure: nothing here reads or writes the terminal.
    pub fn run(self) -> Decoded {
        Decoded(match self.0 {
            Job::Kitty(transfer) => {
                let (outcome, reply) = transfer.decode();
                Picture::Kitty(outcome, reply)
            }
            Job::Sixel(body) => Picture::Sixel(sixel::decode(&body)),
        })
    }
}

/// What one [`Term::feed_step`] came to.
#[derive(Debug)]
pub enum Feed {
    /// Every byte was parsed.
    Done,
    /// A picture wants decoding; this many bytes were parsed before the parser stopped
    /// for it, and the rest wait on [`Term::resume`].
    Decode(Decode, usize),
}

/// Where a feed began; see [`Term::feed_start`].
pub struct Progress {
    pending: Pending,
    events: usize,
}

/// A DCS string cooked answers, with its payload so far.
///
/// All three are collected whole and acted on at the terminator, because neither means
/// anything until it is complete; what differs is how much either may hold.
enum DcsString {
    /// `DCS P1;P2;P3 q` -- a picture. Collected rather than decoded incrementally because
    /// a sixel's size is not known until its last band -- see [`sixel::decode`].
    Sixel(Vec<u8>),
    /// `DCS $ q Pt` -- DECRQSS, naming a setting in at most two bytes. Capped at
    /// [`DECRQSS_BODY_LIMIT`], which is past the longest name answered, so an over-long
    /// request is still refused rather than truncated into a valid one.
    StatusRequest(Vec<u8>),
    /// `DCS + q Pt` -- XTGETTCAP, hex-encoded terminfo names separated by `;`. Capped at
    /// [`xtgettcap::XTGETTCAP_BODY_LIMIT`] and cut back to the last whole name past it;
    /// see there.
    CapabilityRequest(xtgettcap::Request),
}

/// How much of a DECRQSS payload is kept. See [`DcsString::StatusRequest`].
const DECRQSS_BODY_LIMIT: usize = 3;

#[derive(Default)]
struct State {
    /// The two grids. Which rows may leave one for the transcript is a question of which
    /// grid they left, so the primary is reached by name wherever that matters.
    screens: PerScreen<Screen>,
    /// The grid being written to and shown.
    shown: ScreenId,
    /// The rendition and hyperlink the child is writing with; see [`PenState`].
    pen: PenState,
    pending_scrollback: VecDeque<Scrolled>,
    images: ImageStore,
    kitty: Kitty,
    /// Images transmitted since the last drain, awaiting their one trip to Lisp.
    pending_images: Vec<ImageData>,
    /// The `OSC 8` destinations this session has seen, content-addressed.
    links: LinkStore,
    /// Destinations first seen since the last drain, awaiting their one trip to Lisp.
    pending_links: Vec<(LinkId, String)>,
    /// A picture collected whole and not yet decoded; see [`Decode`]. Set by the
    /// dispatch that collected it, at which point the parser stops, and taken by
    /// [`Term::feed_step`].
    decode: Option<Decode>,
    /// The DCS string being collected, if one is open and it is one of ours.
    ///
    /// `None` for every other DCS: the parser hands over the payload of whatever string
    /// is running, and only the introducers [`DcsString`] names are collected.
    dcs: Option<DcsString>,
    /// The terminfo entry TERM named at spawn, or `None` for one that is not ours, which
    /// is answered from the default entry -- see [`Term::set_terminfo`].
    ///
    /// On [`State`] rather than [`Modes`]: the child did not negotiate it, and a reset
    /// does not change what TERM said.
    terminfo: Option<&'static crate::emu::terminfo::Entry>,
    /// The cell size Emacs reports, for turning pixels into a cell rectangle.
    metrics: Option<CellMetrics>,
    /// The colours Emacs draws with, for answering a colour query where it arrives; see
    /// [`osc::Palette`].
    palette: osc::Palette,
    /// Whether a colour sequence is with Lisp, unhandled, so `palette` may be about to
    /// move under a query; see [`Event::asks_about_color`].
    ///
    /// Raised where the event is pushed and lowered by [`Term::events_handled`], which
    /// recomputes it from the events queued since the drain rather than simply clearing
    /// it: a set that arrived after that drain is still owed a pass through Lisp.
    palette_pending: bool,
    /// The light/dark scheme Emacs reports, for answering `CSI ? 996 n`.
    ///
    /// Emacs' to know and ours to answer with, as `metrics` is: the theme resolves against
    /// the buffer's faces. Silent until Emacs reports one, since the protocol has no number
    /// for "unknown". On [`State`] rather than [`Modes`] because the child did not
    /// negotiate it, so a soft reset must not clear it.
    color_scheme: Option<ColorScheme>,
    /// Which pictures Emacs has said it can show for this session: none when images are
    /// off or every window on the buffer is on a terminal frame, and otherwise the
    /// formats its build decodes.
    ///
    /// It changes what the child is *told* -- DA1 drops its `4` and XTSMGRAPHICS answers
    /// failure where a sixel, which arrives as a PNG, could not be shown, and a kitty
    /// `a=q` probe is refused for a format that could not -- because producers probe
    /// first and fall back to half blocks, which show something where a picture would be
    /// a blank rectangle. `OSC 1337 File=` has no probe, so with nothing shown it is
    /// dropped outright.
    ///
    /// The default shows everything, for a bare emulator; a session sets it from the
    /// spawn arguments before the child runs. Not in [`Modes`], because no reset can
    /// change what Emacs can display.
    graphics: ShownFormats,
    /// Rows that have ever left the top of the primary screen. Screen row 0 is this row,
    /// counting from the beginning of the session, which is what makes an [`Anchor`]
    /// outlive the grid position it was taken from.
    evicted_total: usize,
    events: Vec<Event>,
    /// Whether `events` already holds an [`Event::Bell`] this drain.
    ///
    /// A BEL is an occurrence with no payload, so a second one before Emacs has seen the
    /// first says nothing new, and Lisp rate-limits the noise anyway. Without this, `cat`
    /// of a binary queues about four thousand bells per MiB, each one a round trip through
    /// the seam and a window lookup. A flag rather than a search of `events`, which a
    /// burst of bells among a burst of replies would make quadratic.
    bell_queued: bool,
    /// Where a composed reply goes; see [`ReplyRoute`].
    replies: ReplyRoute,
    /// The last graphic character printed, for REP. Held after the designated set has
    /// translated it, so repeating a box-drawing character repeats what was drawn.
    ///
    /// Zero-width characters never land here. REP is defined for the last *graphic*
    /// character, and repeating a combining mark would fold it onto the cell to the left
    /// over and over rather than printing anything.
    last_print: Option<char>,
    /// Where one grapheme cluster ends and the next begins, carried across reads.
    ///
    /// The printing path's other half: [`State::print`] asks this what the code point
    /// in hand does — open a cell of its own, or ride the one before it — rather than
    /// asking a width table, because a width belongs to a cluster and not to a code
    /// point. See [`crate::emu::text`], which also explains why every dispatch below
    /// that is not a print resets it.
    text: Segmenter,
    /// The start of a multi-byte sequence that the end of a read cut short; see
    /// [`crate::emu::utf8`]. Given up on by whatever resets `text`.
    decoder: Decoder,
    /// Test-only: force every character through [`State::print`] rather than the batched
    /// [`State::print_ascii`] path.
    ///
    /// The two paths are only worth having if they are indistinguishable, and nothing else
    /// can show that: feeding a byte at a time still runs `print_ascii`, with runs of length
    /// one, so it compares the fast path against itself. See
    /// `batched_and_per_character_printing_agree`.
    ///
    /// `#[cfg(test)]`, so the field and its test do not exist in a release build.
    #[cfg(test)]
    force_per_character_print: bool,
    /// Test-only: how many control sequences, escapes and C0 controls arrived that no
    /// arm recognised.
    ///
    /// Everything the core does not recognise it drops without a trace, which is right
    /// for a child and leaves a test nothing to ask. The terminfo audit feeds this every
    /// capability in the entry, so a capability whose sequence nothing handles -- `rep`
    /// with its `CSI b` arm deleted -- is a count rather than a silence. See
    /// `terminfo_sequences_are_all_recognised`.
    #[cfg(test)]
    unrecognised: usize,
    /// The renditions the grids' cells name by id; see [`crate::emu::style`].
    styles: StyleStore,
    /// Where the shell last said its prompt begins (OSC 133;A), in [`Anchor`] coordinates.
    ///
    /// Emacs keeps markers for the *command* regions it renders; this keeps the one row
    /// the grid itself needs an answer about, for [`Term::clear_to_prompt`]. Absolute, so
    /// it survives the rows above it scrolling away, and rebased when rows are removed
    /// from under it — the two ways row 0 can stop meaning what it meant.
    prompt_start: Option<Anchor>,
    /// The next [`MarkId`] to hand out, so no two marks of a session share a name.
    ///
    /// Session-lifetime rather than per-drain: Emacs keeps a marker per id for as long as
    /// the command record owning it lives, and a reused name would move the wrong one.
    next_mark: u32,
    /// Whether this drain owes Emacs the position of every mark still on the grid.
    ///
    /// Set by a resize, which moves them; by a redraw or a switch between the screens,
    /// which destroys the markers naming them; and by an eviction, which moves them by
    /// however much the departing row renders differently as scrollback. A flag rather than the positions, because the
    /// child answers a resize by redrawing, and a snapshot taken at the resize would be
    /// stale by however many rows it scrolls before the drain.
    marks_dirty: bool,
    /// What Emacs is showing of the live screen, so a drain can leave out a damaged row
    /// that ended up the same as the copy it already has. See [`front`].
    front: front::Front,
    /// Marks that have left the grid since the last drain, with the absolute rows they
    /// left on.
    ///
    /// These cannot be read off the grid at drain time, being no longer on it, and they
    /// cannot go stale either: a row's absolute number is fixed the moment it is
    /// archived.
    evicted_marks: Vec<(MarkId, Anchor)>,
    /// Everything DECSTR and RIS put back; see [`Modes`].
    modes: Modes,
    /// [`Levels::reverse_screen_toggles`]. Beside [`Modes`] rather than in it, so that a
    /// reset, which puts every mode back, does not also make a count go backwards.
    reverse_screen_toggles: u32,
    /// The input modes as the shell left them when it handed the terminal to a command,
    /// at OSC 133 `C`, to be put back at the `D` that ends it; see [`Handover`].
    ///
    /// On [`State`] rather than [`Modes`], because it is the shell's and not the child's:
    /// `reset` typed at a prompt runs as a command, and the modes its RIS clears are the
    /// ones the `D` after it has to restore.
    handover: Option<Handover>,
    /// What DECSC saved of [`Modes::charsets`], for the primary screen and the alternate.
    ///
    /// VT100 DECSC saves the designations and the shift along with the cursor, and a child
    /// that draws a box inside a save/restore pair relies on getting its text set back.
    /// Here rather than on the [`Screen`] with the saved cursor, because the charsets
    /// belong to the stream; the screen only decides which save a DECRC reads.
    saved_charsets: PerScreen<Option<Charsets>>,
}

/// A 94-character set that can be designated into one of G0-G3.
///
/// Only the sets anything still emits. Everything else -- the national replacement sets,
/// DEC Supplemental, the 96-character Latin sets -- designates ASCII, as xterm does for a
/// set it lacks: the stream is UTF-8, so a child wanting an umlaut has a better way to ask,
/// and ASCII is the one reading that cannot turn text into boxes.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(super) enum Charset {
    #[default]
    Ascii,
    /// DEC Special Graphics, `0`. Also answers for `2`, the VT100's alternate ROM with
    /// graphics, which xterm draws the same way and vttest still asks for.
    DecGraphics,
    /// United Kingdom, `A`: ASCII with `#` as a pound sign, and nothing else different.
    Uk,
}

impl Charset {
    /// The set an SCS final byte names; see the type for why the unknown ones are ASCII.
    fn designated(final_byte: u8) -> Self {
        match final_byte {
            b'0' | b'2' => Self::DecGraphics,
            b'A' => Self::Uk,
            _ => Self::Ascii,
        }
    }

    fn map(self, c: char) -> char {
        match self {
            Self::Ascii => c,
            Self::DecGraphics => dec_graphic(c),
            Self::Uk if c == '#' => '£',
            Self::Uk => c,
        }
    }
}

/// The four designation slots and the shifts between them, as SCS, SO/SI and the
/// ISO 2022 shifts leave them.
///
/// A locking shift chooses a *slot*, and what the slot holds is a separate question, so
/// the two are kept apart. A single graphics flag set by both `ESC ( 0` and SO would draw
/// letters for SI after `ESC ( 0`, although G0 still holds graphics.
///
/// GL only. There is no GR to invoke anything into: the stream is UTF-8, so the bytes a
/// GR set would decode are continuation bytes of something else.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(super) struct Charsets {
    slots: [Charset; 4],
    /// Which slot is locked into GL: SI makes it 0, SO 1, `ESC n` 2 and `ESC o` 3.
    gl: usize,
    /// A slot invoked for the next printed character alone, by SS2 (`ESC N`) or SS3
    /// (`ESC O`).
    single: Option<usize>,
}

impl Charsets {
    pub(super) fn designate(&mut self, slot: usize, final_byte: u8) {
        if let Some(set) = self.slots.get_mut(slot) {
            *set = Charset::designated(final_byte);
        }
    }

    /// Put ASCII in SLOT, whatever it held, as a 96-character designation does.
    pub(super) fn designate_ascii(&mut self, slot: usize) {
        if let Some(set) = self.slots.get_mut(slot) {
            *set = Charset::Ascii;
        }
    }

    pub(super) fn lock(&mut self, slot: usize) {
        self.gl = slot.min(3);
    }

    pub(super) fn single_shift(&mut self, slot: usize) {
        self.single = Some(slot.min(3));
    }

    /// Whether printing is the identity, which is what lets [`Perform::print_bytes`] take
    /// its batched path: the set in GL is ASCII and no single shift is waiting.
    pub(super) fn is_plain(&self) -> bool {
        self.single.is_none() && self.slots[self.gl] == Charset::Ascii
    }

    /// The character C draws as, consuming a pending single shift.
    ///
    /// Only GL's code points are translated. Anything outside `0x20..=0x7e` arrived as
    /// UTF-8 and means itself, and a single shift is still spent on it -- the shift
    /// applies to the next character, not to the next one it would have changed.
    pub(super) fn print(&mut self, c: char) -> char {
        let slot = self.single.take().unwrap_or(self.gl);
        if (' '..='~').contains(&c) {
            self.slots[slot].map(c)
        } else {
            c
        }
    }
}

/// DEC Special Graphics, for the box-drawing characters TUIs still emit.
fn dec_graphic(c: char) -> char {
    const TABLE: &[char] = &[
        '◆', '▒', '␉', '␌', '␍', '␊', '°', '±', '␤', '␋', '┘', '┐', '┌', '└', '┼', '⎺', '⎻', '─',
        '⎼', '⎽', '├', '┤', '┴', '┬', '│', '≤', '≥', 'π', '≠', '£', '·',
    ];
    match c {
        '`'..='~' => TABLE[c as usize - '`' as usize],
        _ => c,
    }
}
