//! The VT parser front end: turns a byte stream into grid mutations and [`Event`]s.
//!
//! Scrollback deliberately lives in the Emacs buffer, not here. Rows that fall off the
//! top of the primary screen are handed over once, in [`Delta::scrolled`], and forgotten.

use super::cell::{Deco, Extra, MarkId, Pen, RowRef, Run, Style};
use super::image::{
    CellMetrics, CellSize, ImageData, ImageFormat, ImageId, ImageStore, Interned, PixelSize,
};
use super::kitty::{Kitty, Outcome, decode_base64};
use super::link::{LinkId, LinkStore, MAX_URI_LEN};
use super::parser::{Params, Parser, Perform};
use super::png::png_dimensions;
use super::screen::{Cursor, Erase, Evicted, Resize, Screen, Shift};
use super::sixel;
use super::style::{StyleId, StyleStore};
use super::text::{self, Segmenter, Step, Width};
use csi::{PushedPen, SavedMode};
use keys::KittyStack;
pub(crate) use keys::{KeyEncoding, KittyFlags, ModifyOtherKeys};
use reply::{Framing, color_scheme_report, size_report};
pub(crate) use reply::{Terminator, osc_reply};
use screens::{PerScreen, ScreenId};
use std::collections::{HashSet, VecDeque};

mod csi;
mod front;
mod graphics;
mod keys;
mod modes;
pub(crate) mod osc;
mod perform;
pub(crate) mod reply;
mod screens;
mod state;
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
    /// the shell said it was about to run, from `cmdline_url=`. See [`State::cmdline`]
    /// for why that spelling and not kitty's `cmdline=`.
    CommandStart(Option<String>),
    /// `133;D`: the command finished, with its exit status when reported.
    CommandEnd(Option<i32>),
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
    /// Bytes the terminal owes the child (device attributes, cursor reports).
    Reply(Vec<u8>),
    /// The mode 2048 report, which is a [`Event::Reply`] in every respect but one: a resize
    /// supersedes it. See [`Term::set_size`], which drops an undrained one by this variant.
    SizeReport(Vec<u8>),
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
    /// 9;4 progress and the OSC 22 pointer stacks. A reset that cleared the screen but left
    /// a progress indicator on the mode line would be the stuck state `reset` is typed to
    /// cure.
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
    pub runs: Vec<Run>,
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
    /// of it: how tall it is, how many rows of it are occupied ([`Screen::used`]), and how
    /// many characters of row 0's logical line are already in Emacs ([`Screen::head`]).
    ///
    /// The last is the seam, and the only one of the three Emacs cannot see for itself —
    /// the marker sitting mid-line is the *consequence* of the head, not a measure of it.
    pub height: usize,
    pub used: usize,
    pub head: usize,
    /// Everything else a drain restates in full every time; see [`Levels`].
    pub levels: Levels,
    pub events: Vec<Event>,
    /// Semantic marks whose position changed during this drain, as `(ID, ANCHOR)`.
    ///
    /// Empty on most drains. A resize fills it, because a rewrap re-lays every logical
    /// line at the new width and the old buffer positions stop holding; so does a redraw,
    /// which destroys the markers naming them (see [`Term::touch_all`]); and so does an
    /// eviction, which moves them by the difference in how the departing row renders.
    ///
    /// Marks that left the grid during a resize are here too, anchored into this drain's
    /// scrollback batch, which `anchor_to_lisp` already knows how to spell.
    pub marks: Vec<(MarkId, Anchor)>,
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
    pub runs: Vec<Run>,
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
    pub runs: Vec<Run>,
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

/// Largest OSC payload forwarded to Lisp, in bytes. Well past any real title or
/// hyperlink, and short of letting a single escape sequence allocate without bound.
pub(crate) const OSC_PAYLOAD_LIMIT: usize = 1 << 20;

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
            self.events.push(Event::Reply(bytes));
        }
    }
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
        let before = Pending::of(&self.state);
        self.parser.advance(&mut self.state, bytes);
        Pending::of(&self.state) != before
    }

    pub fn drain(&mut self) -> Delta {
        self.state.drain()
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
            .retain(|e| !matches!(e, Event::SizeReport(_)));
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

    /// Tell the emulator whether Emacs can show a picture this session transmits.
    ///
    /// Nothing is owed on a change: none of the answers it governs is a subscription.
    pub fn set_graphics_shown(&mut self, shown: bool) {
        self.state.graphics_hidden = !shown;
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
    /// kitty, nothing clears the alternate stack on the way back in.
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
    pen: Style,
    pending_scrollback: VecDeque<Scrolled>,
    images: ImageStore,
    kitty: Kitty,
    /// Images transmitted since the last drain, awaiting their one trip to Lisp.
    pending_images: Vec<ImageData>,
    /// The `OSC 8` destinations this session has seen, content-addressed.
    links: LinkStore,
    /// Destinations first seen since the last drain, awaiting their one trip to Lisp.
    pending_links: Vec<(LinkId, String)>,
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
    /// The light/dark scheme Emacs reports, for answering `CSI ? 996 n`.
    ///
    /// Emacs' to know and ours to answer with, as `metrics` is: the theme resolves against
    /// the buffer's faces. Silent until Emacs reports one, since the protocol has no number
    /// for "unknown". On [`State`] rather than [`Modes`] because the child did not
    /// negotiate it, so a soft reset must not clear it.
    color_scheme: Option<ColorScheme>,
    /// Emacs has said nothing this session transmits can be shown: images are off, or
    /// every window on the buffer is on a terminal frame.
    ///
    /// It changes what the child is *told* -- DA1 drops its `4`, XTSMGRAPHICS answers
    /// failure, a kitty `a=q` probe is refused -- because producers probe first and fall
    /// back to half blocks, which show something where a picture would be a blank
    /// rectangle. `OSC 1337 File=` has no probe, so it is dropped outright.
    ///
    /// Negative so the default claims graphics until Lisp reports otherwise at session
    /// start. Not in [`Modes`], because no reset can change what Emacs can display.
    graphics_hidden: bool,
    /// Rows that have ever left the top of the primary screen. Screen row 0 is this row,
    /// counting from the beginning of the session, which is what makes an [`Anchor`]
    /// outlive the grid position it was taken from.
    evicted_total: usize,
    events: Vec<Event>,
    /// The last graphic character printed, for REP. Held after the designated set has
    /// translated it, so repeating a box-drawing character repeats what was drawn.
    ///
    /// Zero-width characters never land here. REP is defined for the last *graphic*
    /// character, and repeating a combining mark would fold it onto the cell to the left
    /// over and over rather than printing anything.
    last_print: Option<char>,
    /// Where one grapheme cluster ends and the next begins, carried across reads.
    ///
    /// The printing path's other half: [`Perform::print`] asks this what the code point
    /// in hand does — open a cell of its own, or ride the one before it — rather than
    /// asking a width table, because a width belongs to a cluster and not to a code
    /// point. See [`crate::emu::text`], which also explains why every dispatch below
    /// that is not a print resets it.
    text: Segmenter,
    /// Test-only: force every character through [`State::print`] rather than the batched
    /// [`Perform::print_str`] path.
    ///
    /// The two paths are only worth having if they are indistinguishable, and nothing else
    /// can show that: feeding a byte at a time still runs `print_str`, with runs of length
    /// one, so it compares the fast path against itself. See
    /// `batched_and_per_character_printing_agree`.
    ///
    /// `#[cfg(test)]`, so the field and its test do not exist in a release build.
    #[cfg(test)]
    force_per_character_print: bool,
    /// The renditions the grids' cells name by id; see [`crate::emu::style`].
    styles: StyleStore,
    /// The ids [`State::pen`] last gave the pen, with the rendition they were looked up
    /// for, so a run of characters in one pen looks the pen up once.
    pen_ids: Option<(Style, Pen)>,
    /// The `OSC 8` hyperlink the child currently has open, if any.
    ///
    /// Written into every cell printed while it is open, beside the pen's rendition, but
    /// unlike anything in the pen it is not an SGR attribute, so no rendition change
    /// closes it. Terminals hold it open
    /// until an explicit `OSC 8 ; ; ST`, which is what lets a program colour a link as it
    /// prints it. See `hyperlink` for what does close it.
    ///
    /// One field for both screens, like `pen`: an open hyperlink belongs to the byte
    /// stream, so a child that opens one and then takes the alternate screen goes on
    /// writing it there.
    link: Option<LinkId>,
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
    /// Set by a resize, which moves them; by a redraw, which destroys the markers naming
    /// them; and by an eviction, which moves them by however much the departing row
    /// renders differently as scrollback. A flag rather than the positions, because the
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

    pub(super) fn lock(&mut self, slot: usize) {
        self.gl = slot.min(3);
    }

    pub(super) fn single_shift(&mut self, slot: usize) {
        self.single = Some(slot.min(3));
    }

    /// Whether printing is the identity, which is what lets [`Perform::print_str`] take
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
