//! The VT parser front end: turns a byte stream into grid mutations and [`Event`]s.
//!
//! Scrollback deliberately lives in the Emacs buffer, not here. Rows that fall off the
//! top of the primary screen are handed over once, in [`Delta::scrolled`], and forgotten.

use super::cell::{Attrs, Color, Deco, Extra, MarkId, Row, Run, Style};
use super::image::{
    CellMetrics, CellSize, ImageData, ImageFormat, ImageId, ImageStore, Interned, PixelSize,
};
use super::kitty::{Kitty, Outcome, decode_base64};
use super::link::{LinkId, LinkStore, MAX_URI_LEN};
use super::parser::{Params, Parser, Perform};
use super::png::png_dimensions;
use super::screen::{Cursor, Erase, Evicted, Resize, Screen};
use super::sixel;
use std::collections::{HashSet, VecDeque};
use unicode_width::UnicodeWidthChar;

mod csi;
mod graphics;
mod osc;
mod perform;
mod state;
#[cfg(test)]
mod tests;

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
}

/// Where in the output stream a mark landed.
///
/// `row` is *absolute*: screen row 0 is row [`State::evicted_total`], so the coordinate
/// stays meaningful after the marked row scrolls away, which a screen row does not.
///
/// Recorded when the mark is parsed rather than read off the drain, because the drain
/// carries the *end-of-drain* cursor — a different place entirely once more than one
/// command lands in a single drain, which is exactly what a fast script does.
///
/// Best-effort by construction: a resize between the mark and the drain rewraps the
/// scrollback and can shift where the anchor resolves. The fallback in that case is the
/// end-of-drain cursor, which is what this replaced.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Anchor {
    pub row: usize,
    pub col: usize,
}

/// Which of the prompts a `133;A` mark is announcing. See [`State::prompt_kind`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum PromptKind {
    /// The prompt a command is typed at: `PS1`, and the default when `k=` is absent.
    Initial,
    /// `PS2` — the same command, still being typed.
    Continuation,
    /// A right-hand prompt, or a kind this version has never heard of. Neither starts a
    /// command nor continues one, so the mark is dropped and no state moves.
    Other,
}

/// Something the Lisp side must react to, beyond redrawing cells.
///
/// The division of labour with [`Delta`]'s fields is deliberate, and worth keeping to:
/// the drain's fields carry everything *redisplay* needs, so they are levels — the state
/// as of the end of the drain. Events carry what Emacs must *react* to and redisplay does
/// not cover, so they are occurrences. State consulted only when sending to the child —
/// bracketed paste — is neither, and is queried live at that moment, which is fresher
/// than any drain snapshot.
///
/// Sending the same state both ways is what this rules out. An `alt-screen` event
/// alongside [`Delta::alt`] could only ever restate the field, and did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    Bell,
    /// Any OSC the terminal does not act on itself, handed over verbatim as
    /// (code, remaining parts, ended with BEL).
    ///
    /// No OSC changes the grid, so interpreting them is Emacs' business, not ours:
    /// titles, working directories, hyperlinks, clipboard, editor commands. Keeping
    /// this generic means a new integration is a few lines of Lisp rather than a
    /// Rust edit, a rebuild and a release. OSC 133 is the deliberate exception —
    /// it decides who owns the keyboard, which is core behaviour rather than
    /// user-extensible policy.
    ///
    /// The terminator travels with the event because a reply xterm-correctly echoes
    /// it, and Emacs answers asynchronously: by the time a handler runs we may have
    /// parsed several more sequences, so "the terminator of the last OSC" would
    /// answer the wrong query. See [`osc_reply`].
    Osc(u16, Vec<String>, bool),
    /// OSC 133;A — a shell prompt begins.
    ///
    /// The [`MarkId`] is how Emacs is told, later, that the mark has moved: it holds a
    /// buffer marker taken from the [`Anchor`], the anchor stops being true the moment a
    /// resize rewraps the grid, and the id is what pairs the two ends up again. See
    /// [`Delta::marks`].
    PromptStart(Anchor, MarkId),
    /// OSC 133;A;k=s — a *continuation* prompt begins: `PS2`, the second
    /// and later lines of a multi-line construct.
    ///
    /// Its own event rather than a flag on [`Event::PromptStart`] because the two differ
    /// in what they mean to Emacs rather than in degree: this one opens no command and
    /// moves no prompt marker, it only says that the line about to be read continues the
    /// one already submitted. See [`State::continues_prompt`].
    PromptContinuation(Anchor, MarkId),
    /// OSC 133;B — user input begins; this is where comint takes over.
    PromptEnd(Anchor, MarkId),
    /// OSC 133;C — the command is running and owns the output region.
    ///
    /// The [`String`] is the command line the shell said it was about to run, from the
    /// mark's `cmdline_url=`, and is absent when the shell did not say. See
    /// [`State::cmdline`] for why that spelling and not kitty's `cmdline=`.
    CommandStart(Option<String>, Anchor, MarkId),
    /// OSC 133;D — the command finished, with its exit status when reported.
    CommandEnd(Option<i32>, Anchor, MarkId),
    /// The child changed its mind about mouse reporting. An occurrence rather than a
    /// field because nothing in redisplay depends on it: its one consumer swaps a keymap.
    Mouse(Mouse),
    /// Bytes the terminal owes the child (device attributes, cursor reports).
    Reply(Vec<u8>),
    /// `CSI 3 J` — the child asked to erase saved lines, xterm's `clear -x`.
    ///
    /// Unlike `CSI 2 J`, real xterm's `3 J` touches only the scrollback, leaving the
    /// visible screen exactly as it was — so the grid does nothing here at all. And
    /// scrollback lives in the Emacs buffer, not the grid (see the module comment), so
    /// the grid could not honour this itself even if it wanted to: the text is Emacs'
    /// to delete. This event is the whole of the response, and Emacs does act on it —
    /// it is the half of `clear` that actually empties the buffer, the `2 J` before it
    /// having archived the screen rather than lost it.
    EraseScrollback,
    /// `CSI 2 J` — the child finished with this screen.
    ///
    /// The rows themselves are not lost: [`Screen::erase_display`] archives them, because
    /// history belongs to Emacs. But the child asked for a blank screen and every other
    /// terminal gives it one, by scrolling what it cleared out of view. Emacs has no
    /// viewport of its own to scroll — the transcript and the live screen are one buffer
    /// — so the window is what moves, and this is the event that asks it to.
    DisplayCleared,
    /// XTWINOPS 22/23: push or pop the window title. `smcup`/`rmcup` end in these, so a
    /// full-screen program that sets a title expects it restored when it leaves.
    TitleStack(bool),
}

/// How the child wants keys that have no classical encoding — modified Return, Tab,
/// Escape and Backspace — to be spelled.
///
/// This has to be negotiated rather than assumed. `ESC [ 27 ; 2 ; 13 ~` sent to a program
/// that never asked for it is not a shift+enter, it is six characters of garbage in its
/// input, so [`KeyEncoding::Legacy`] is the only safe default and the extended forms are
/// unlocked by the child itself.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum KeyEncoding {
    /// Nothing negotiated: a modified Return is just CR, as it has always been.
    #[default]
    Legacy,
    /// xterm's `modifyOtherKeys` (`CSI > 4 ; 2 m`): `CSI 27 ; MOD ; CHAR ~`.
    ModifyOtherKeys,
    /// The kitty keyboard protocol (`CSI > FLAGS u`): `CSI CHAR ; MOD u`.
    Kitty,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Mouse {
    pub click: bool,
    pub drag: bool,
    pub motion: bool,
    pub sgr: bool,
}

impl Mouse {
    pub fn enabled(self) -> bool {
        self.click || self.drag || self.motion
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
    /// A field rather than an [`Event`], and the drain's third category: the level/
    /// occurrence division sorts state by *what redisplay needs* against *what Emacs
    /// must react to*, and this is neither. It is a resource the rows in this very delta
    /// refer to, so Lisp has to install it before rendering them — and events are
    /// dispatched after both render passes, so a semantic mark's anchor has text to
    /// point at. An image arriving as an event would arrive after the row that needed it.
    ///
    /// Not everything the child transmitted, which is the part worth reading twice. A
    /// transmission is not a placement: a child can draw far faster than Emacs redisplays
    /// and the frames it drew over in between are referred to by nothing by the time this
    /// is built, so they are dropped and the store is told to forget them. See
    /// [`State::shed_unplaced_images`]. What is left crosses exactly once, however many
    /// cells or drains name it afterwards — the cells carry the id, and the geometry to
    /// draw it at travels with them on each [`Placement`](crate::emu::image::Placement)
    /// rather than being carried here.
    ///
    /// Empty on almost every drain.
    pub images: Vec<ImageData>,
    /// Hyperlink destinations first seen during this drain, as `(ID, URI)`.
    ///
    /// [`Delta::images`]'s sibling in every respect: a resource the rows of this very
    /// delta name by id, so Lisp has to record it before it renders them, and each URI
    /// crosses exactly once however many cells or drains refer to it.
    pub links: Vec<(LinkId, String)>,
    /// Scrolled-off lines, already reduced to styled runs.
    pub scrolled: Vec<Scrolled>,
    /// Absolute index of `scrolled`'s first line, so an [`Anchor`] can be told apart
    /// into "in this batch of scrollback" and "still on the grid".
    pub scrolled_base: usize,
    pub rows: Vec<(usize, Vec<Run>)>,
    /// The grid's shape as of this drain, so the buffer never has to hold a second opinion
    /// of it: how tall it is, how many rows of it are occupied ([`Screen::used`]), and how
    /// many characters of row 0's logical line are already in Emacs ([`Screen::head`]).
    ///
    /// The last is the seam, and the only one of the three Emacs cannot see for itself —
    /// the marker sitting mid-line is the *consequence* of the head, not a measure of it.
    pub height: usize,
    pub used: usize,
    pub head: usize,
    pub cursor: Cursor,
    pub cursor_visible: bool,
    pub cursor_shape: CursorShape,
    pub alt: bool,
    /// DECCKM: cursor keys must be sent as SS3 (`ESC O A`), not CSI (`ESC [ A`).
    /// ncurses turns this on via `smkx`, and terminfo's `kcuu1` assumes it.
    pub app_cursor: bool,
    /// How to spell modified Return, Tab, Escape and Backspace for this child.
    pub keys: KeyEncoding,
    pub events: Vec<Event>,
    /// Semantic marks whose position changed during this drain, as `(ID, ANCHOR)`.
    ///
    /// Empty on every drain but a resize, which is the only thing that moves one -- and
    /// a redraw, which does not move them but destroys the markers naming them; see
    /// [`Term::touch_all`]. A scroll does neither: rows leave the top and the grid keeps
    /// its width, so the text
    /// above a live mark in Emacs' buffer grows by exactly what left the screen and the
    /// buffer position of everything still on it is unchanged. A *rewrap* re-lays every
    /// logical line at the new width, and then nothing about the old positions holds --
    /// which is what this exists to repair, and what it was added for: the fringe marker
    /// per command, and every other consumer of a command record, drifted off the row it
    /// described the first time the frame changed width.
    ///
    /// Marks that left the grid during the resize are here too, anchored into this
    /// drain's scrollback batch: the rewrap can push rows off the top, and a mark on one
    /// of them is in text Emacs is about to insert rather than on a row it is about to
    /// rewrite. `anchor_to_lisp` already spells both, so the two cases cost nothing to
    /// tell apart here.
    pub marks: Vec<(MarkId, Anchor)>,
}

/// A reading of everything [`Delta`] carries, cheap enough to take on every read.
///
/// [`Term::feed`] takes one of these either side of a parse and compares them, which is
/// the whole of "did that produce anything to draw". It has to be a *reading* rather than
/// a flag set by the code that changes things: the flag would have to be set in every one
/// of `perform`'s several dozen arms, and the arm that was forgotten would be the one that
/// stopped repainting. Comparing what a drain would report cannot fall out of step that
/// way — a field added to [`Delta`] and not to this is the only failure mode left, and it
/// is one line away from the field it belongs to.
///
/// The queues are counted rather than examined because they only ever grow between
/// drains, and the level fields are copied because a [`Delta`] restates them every time.
/// Damage is counted for a subtler reason: it stays up until Emacs drains, so a flag
/// would read `true` on both sides of a read and make a program repainting flat out look
/// like one doing nothing at all. See [`Screen::touches`].
/// [`Delta::height`], `used` and `head` are the three left out, and deliberately: none can
/// move without either damaging a row or evicting one, both of which are already here.
#[derive(PartialEq, Eq)]
struct Pending {
    touches: u64,
    scrolled: usize,
    images: usize,
    links: usize,
    events: usize,
    marks: (bool, usize),
    cursor: Cursor,
    cursor_visible: bool,
    cursor_shape: CursorShape,
    alt: bool,
    app_cursor: bool,
    keys: KeyEncoding,
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
            cursor: state.screen().cursor,
            cursor_visible: state.modes.cursor_visible,
            cursor_shape: state.modes.cursor_shape,
            alt: state.on_alt,
            app_cursor: state.modes.app_cursor,
            keys: state.key_encoding(),
        }
    }
}

/// How long a child may hold back a redisplay with DEC mode 2026 before we draw anyway.
///
/// Synchronized output exists so a half-drawn frame is never shown; it is not a licence
/// to freeze the buffer. A child killed mid-frame never sends the end marker, so without
/// a cap the last thing the user sees is a partial screen. xterm and contour use 150ms,
/// kitty 100; the longer of the two is the safer choice on a loaded machine.
///
/// Armed here at every BSU, which makes this a cap on one marker rather than on the frame
/// a marker is holding. `Notifier::set_sync` is where the difference is settled: a client
/// that begins its next frame before the last was drawn cannot push the deadline out
/// again, so this stays the longest the buffer can be held still no matter how the
/// markers arrive.
pub(crate) const SYNC_TIMEOUT: std::time::Duration = std::time::Duration::from_millis(150);

/// Backlog at which the reader stops pulling from the pty, letting the child block.
pub const BACKLOG_HIGH_WATER: usize = 8_000;

/// Bytes of pending image payload that count as one unit of [`Term::backlog`].
///
/// A conversion factor, because the backlog is one scalar against one limit and images
/// are not measured in the same thing as rows and events. At 1KB a unit the cap above
/// comes to roughly 8MB of undrained pictures, which is the figure to argue with if this
/// is ever wrong.
///
/// Why that figure, and not something nearer the megabyte or two that 8000 rows come to:
/// backpressure and shedding answer two different problems, and this must not take work
/// away from the one that is free. An animation redrawing in place has its overdrawn
/// frames shed — see `State::shed_unplaced_images` — which costs the child nothing and
/// holds at most two payloads however far behind Emacs falls. Throttling that instead
/// would block the child in `write` and slow the animation down to buy nothing: those
/// frames were never going to be shown.
///
/// So the budget wants to sit above two frames of anything that sheds. `viu`, the case
/// this was measured on, is 2.1MB a frame — two of those is 4.2MB, comfortably under the
/// 8MB here. A producer at 4MB a frame would sit on the limit and be throttled
/// occasionally, which is the right answer at that size rather than a failure of this
/// one. What the budget is really for is the case shedding cannot touch: many *distinct*
/// pictures, all still displayed, all genuinely owed to Emacs, arriving faster than they
/// can be drained.
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

/// Longest sixel body collected from one DCS string.
///
/// Sixel is a verbose encoding — one byte per six pixels per colour pass — so this is
/// smaller than it looks: a full-screen picture is comfortably inside it, and the decoded
/// result is bounded again, and more tightly, by [`sixel::MAX_PIXELS`].
pub(crate) const SIXEL_BODY_LIMIT: usize = 8 << 20;

/// Depth of the kitty keyboard flag stack. Real clients push once around a full-screen
/// session; anything deeper is a child that never pops.
const KITTY_STACK_LIMIT: usize = 16;

/// Ceiling on the `c=`/`r=` cell span an image placement is honoured for.
///
/// See the comment at its one use in `Term::intern_image`: this bounds how many real
/// `linefeed`s (and thus scroll-eviction/scrollback-archival passes) a single image
/// placement can force. 4096 is already far more rows than any legitimate picture
/// needs — a screen is a few dozen to a few hundred rows — while remaining nowhere
/// near tight enough to visibly clip anything real.
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

/// Frame `ESC ] CODE ; PAYLOAD` with the terminator the query used.
///
/// Queries whose answer only Emacs knows — the default colours, which resolve against
/// the buffer's faces rather than any palette we hold — are answered from Lisp, but the
/// framing belongs here so that no Lisp frames a payload the *child* supplied.
///
/// That is narrower than "Lisp never splices control bytes", which is how this used to
/// read and is not the rule the tree keeps: `cooked--encode-event' spells out
/// `ESC [ 27 ; MOD ; CHAR ~', `cooked--mouse-report' spells out an SGR report, and
/// `cooked--alt-scroll-keys' spells out cursor keys — all correctly, because every field
/// in them is an Emacs-side integer or symbol and none can carry an `ESC` the child
/// chose. What cannot be done in Lisp is framing a string that came *from* the child,
/// which is this function's whole case and the reason for the refusal below.
///
/// `bell` picks BEL over ST because xterm echoes the terminator it was asked with, and a
/// client scanning its input for BEL hangs on an ST-terminated reply.
///
/// Returns `None` for a payload carrying C0 controls or DEL, which would end the sequence
/// early or inject one of their own. Payloads are attacker-reachable — a colour name can
/// arrive from the child in a set request and come straight back out in the echo — so
/// centralising the framing buys nothing unless it also refuses to frame a lie.
pub(crate) fn osc_reply(code: u16, payload: &str, bell: bool) -> Option<Vec<u8>> {
    if payload.chars().any(|c| c.is_control() || c == '\u{7f}') {
        return None;
    }
    let terminator = if bell { "\x07" } else { "\x1b\\" };
    Some(format!("\x1b]{code};{payload}{terminator}").into_bytes())
}

/// What `CSI ? 996 n` answers, and what mode 2031 pushes.
///
/// The discriminants are the protocol's own numbers, so that no reporting site spells a
/// bare `1` or `2`. There is deliberately no third variant: "Emacs has not said yet" is
/// `Option::None`, kept outside the enum where it cannot be formatted into a reply by
/// accident. The spec defines these two values and nothing else, so an "unknown" answer
/// would be one we invented and a child would have no way to read it.
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

/// The DSR a child gets for the colour scheme, whether it asked or subscribed.
///
/// One function because the pull and the push are the same report, and a child cannot
/// tell a solicited answer from an unsolicited one -- framed at two sites, the two could
/// come to differ.
pub(crate) fn color_scheme_report(scheme: ColorScheme) -> Vec<u8> {
    format!("\x1b[?997;{scheme}n").into_bytes()
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
    /// The answer is what lets the reader thread not wake Emacs for bytes that turn out
    /// to be nothing to look at, which is most of them under a graphics protocol: a
    /// kitty image arrives as megabytes of base64 inside one APC string, and every read
    /// of it but the last leaves the grid exactly as it was. Measured on `viu` playing a
    /// gif, 55% of drains carried no rows, no images, no events and no cursor move.
    ///
    /// "Anything Emacs would draw" is [`Delta`]'s own contents, which is why
    /// [`Pending`] is a field-for-field reading of them rather than a damage flag: a
    /// [`Delta`] reports the cursor, the alternate screen and the key encoding on every
    /// drain whether or not a row changed, so a cursor move with no damage is a real
    /// update — and, in the gif case, the one that has to be *coalesced* rather than
    /// dropped.
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
    /// cannot become a cell count, and the XTWINOPS reports that tools consult before
    /// deciding whether to draw at all have nothing to say.
    ///
    /// Nothing is forgotten when the cell moves, and that is worth stating because it
    /// used to be. A transmission naming no `c=`/`r=` is measured into cells against the
    /// metrics of the moment, and the store was dropped whole here so that no id minted
    /// against the old font could be answered with — every picture the child redrew
    /// crossed the boundary again, at megabytes a frame, to be remeasured.
    ///
    /// `State::intern_image` measures against `self.metrics` at the time of each
    /// transmission instead, so a recognised id is already laid at the rectangle the
    /// current font implies and there is nothing stale to protect anyone from. The rows
    /// already written keep the rectangle they were laid at — it rides every
    /// [`Placement`](crate::emu::image::Placement) — and `cooked--rescale-deco' re-cuts
    /// their slices to the new cell, which grows the picture with the text around it.
    pub fn set_cell_metrics(&mut self, metrics: CellMetrics) {
        self.state.metrics = metrics;
    }

    pub fn cell_metrics(&self) -> CellMetrics {
        self.state.metrics
    }

    /// Tell the emulator whether Emacs renders light or dark, returning what a subscriber
    /// to mode 2031 is now owed.
    ///
    /// The bytes come back rather than being pushed as an [`Event::Reply`] because events
    /// are collected at drain time, and a theme change produces no child output at all --
    /// nothing wakes the drain, so a subscribed program sitting idle would learn of the
    /// new theme only when the user next typed. Nor are they written to the pty from
    /// here, the way an OSC reply is: that path signals on a write error, which is right
    /// for a query the child is blocking on and wrong for this, which runs from a global
    /// hook where a child that has just exited is an ordinary race. `cooked--send-if-live'
    /// is where that policy is already written down, and it is the same route the `996'
    /// answer leaves through -- one report, one route, one error policy.
    ///
    /// Nothing is owed for a theme reloaded onto itself, and nothing to a child that
    /// never subscribed.
    pub fn set_color_scheme(&mut self, scheme: ColorScheme) -> Option<Vec<u8>> {
        let changed = self.state.color_scheme.replace(scheme) != Some(scheme);
        (changed && self.state.modes.color_scheme_updates).then(|| color_scheme_report(scheme))
    }

    /// Take BYTES as an image and lay it into the grid at the cursor.
    ///
    /// The two halves of what a transmit-and-display does, together because they share
    /// the geometry. Interning is content-addressed, so a child redrawing the same
    /// picture every frame hands the bytes over once; the rest of its transmissions cost
    /// a placement per cell and nothing else.
    ///
    /// Rows are laid top to bottom from the cursor, scrolling when the picture runs past
    /// the bottom of the screen. The cursor lands at the start of the row below the
    /// image — `CursorAfterImage::NextLine`, the sixel and iTerm2 disposition; kitty's
    /// is not reachable from here, because it is the APC handler that knows about `C=`.
    pub fn place_image(&mut self, format: ImageFormat, bytes: &[u8], px: PixelSize) -> ImageId {
        self.state.place_image(format, bytes, px)
    }

    /// Emacs has dropped image ID's bytes, so stop believing it has them.
    ///
    /// Emacs is the only cache -- see [`ImageStore`] -- and this is the one message that
    /// keeps the module's bookkeeping honest about it. Everything the emulator hangs off
    /// an id goes at once: the ledger entry and its digest, the geometry, and the
    /// client's own name for the picture, so a later `a=p` is answered `ENOENT:image`
    /// rather than placing cells nothing can draw.
    ///
    /// A retransmission of the same bytes afterwards is a new picture as far as the
    /// module is concerned: a fresh id, and the payload crosses again.
    pub fn forget_image(&mut self, id: ImageId) {
        self.state.images.forget(id);
        self.state.kitty.forget(id);
    }

    /// Emacs has discarded the scrollback, so the top row continues nothing.
    pub fn forget_history(&mut self) {
        self.state.primary.forget_carry();
    }

    /// Mark every row of the current screen damaged, so the next drain re-sends all of
    /// it. The way back from a redisplay that failed part-way and left Emacs' idea of
    /// the screen region disagreeing with ours.
    ///
    /// Every live mark is reported along with the rows, for the same reason a resize
    /// reports the ones it moved: Emacs is about to delete the whole screen region and
    /// build it again, so the markers it holds into that text collapse to the deletion
    /// point. That the rows come back looking identical does not help -- the markers were
    /// destroyed by the delete, not by the layout. Repairing them is the difference
    /// between `cooked-refresh' fixing the picture and it fixing the picture while
    /// silently taking every command record with it.
    pub fn touch_all(&mut self) {
        self.state.screen_mut().touch_all();
        self.state.marks_dirty = true;
    }

    /// Remove `count` grid rows starting at `first`; see [`Screen::remove_rows`].
    pub fn remove_rows(&mut self, first: usize, count: usize) {
        self.state.remove_rows(first, count);
    }

    /// Drop every grid row above the current prompt, returning how many went.
    ///
    /// The grid's half of clearing the terminal. Emacs owns the scrollback and deletes
    /// its own text, but which row the prompt is on is grid arithmetic over state only
    /// the emulator keeps — [`State::prompt_start`] against [`State::evicted_total`] —
    /// and asking Emacs to rediscover it from buffer positions would get a two-line
    /// prompt wrong, cutting at the input row and eating the line above it that the
    /// shell is still drawing on.
    ///
    /// Without OSC 133 there is no prompt to find, so the cursor row stands in: whatever
    /// the child is on now is the line the user is looking at either way.
    pub fn clear_to_prompt(&mut self) -> usize {
        self.state.clear_to_prompt()
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
        self.state.modes.alt_scroll && self.state.on_alt && !self.state.modes.mouse.enabled()
    }

    pub fn app_cursor(&self) -> bool {
        self.state.modes.app_cursor
    }

    /// How the child wants modified Return, Tab, Escape and Backspace spelled.
    pub fn keys(&self) -> KeyEncoding {
        self.state.key_encoding()
    }

    /// Items waiting for Emacs to collect: scrolled-off lines plus pending events.
    ///
    /// Events are counted because they are the other path that grows without bound while
    /// Emacs is behind — a child spraying OSC titles or DA/CPR queries never scrolls a row,
    /// so a scrollback-only measure would let it allocate freely.
    /// See [`State::force_per_character_print`].
    #[cfg(test)]
    pub(crate) fn force_per_character_print(&mut self) {
        self.state.force_per_character_print = true;
    }

    /// How much undrained work is queued, in the one currency backpressure understands.
    ///
    /// Rows and events count themselves. Pictures are counted by weight instead, at
    /// [`IMAGE_BACKLOG_UNIT`] bytes to the unit: a pending image is one item and several
    /// megabytes, so counting it as an item would let a child hold a gigabyte of frames
    /// without ever troubling a limit written for rows. That is exactly what it did.
    ///
    /// Summed rather than kept as a running total, deliberately. It is the same fact as
    /// the payloads themselves, and a second copy of a fact is a thing that can disagree
    /// with the first — which is the shape of the bug the image path has already had once.
    /// The vector is short (shedding sees to that) and this is called once per read, so
    /// the sum costs nothing worth a bookkeeping invariant.
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
/// One struct rather than fourteen loose fields on [`State`] because DECSTR and RIS are
/// defined as "put every negotiated mode back to power-on" -- and with the fields loose,
/// that definition had to be *restated* as fourteen assignments in `soft_reset`, a list
/// that could fall out of step with the one in `dec_mode` without anything noticing.
/// `Modes::default()` is now the whole of the reset, so adding a mode cannot forget it.
///
/// The `Default` impl is hand-written for one field: DECTCEM starts *set*, so a terminal
/// powers on with a visible cursor.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Modes {
    cursor_visible: bool,
    cursor_shape: CursorShape,
    /// DEC mode 2004. No event: nothing reacts to this. It is read at the one moment it
    /// matters, by [`Term::bracketed_paste`] as a multi-line submission is being framed.
    bracketed_paste: bool,
    /// DEC mode 1004: the child wants `CSI I`/`CSI O` when the window gains or loses
    /// focus. Read at the moment focus changes, so it is state rather than a level.
    focus_events: bool,
    /// DEC mode 2031: the child wants the colour scheme reported again every time it
    /// changes. The subscription is something the child negotiated and so belongs here;
    /// the scheme itself is not -- it is Emacs' answer about its own theme -- and lives
    /// on [`State`], so that a soft reset ends the subscription without also forgetting
    /// which way the theme points.
    color_scheme_updates: bool,
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
    dec_graphics: bool,
    app_cursor: bool,
    app_keypad: bool,
    /// xterm's modifyOtherKeys level, 0-2. Only level 2 changes how we spell keys.
    modify_other_keys: u8,
    /// Kitty keyboard flags. Bit 0 ("disambiguate escape codes") is the one that matters;
    /// the protocol keeps a stack, and a real terminal keeps one per screen. A single
    /// value is enough here — nothing we support cares about the alternate screen's
    /// keyboard mode differing from the primary's.
    kitty_keys: Vec<u8>,
    /// LNM (ANSI mode 20): LF also returns the carriage.
    newline_mode: bool,
}

impl Default for Modes {
    fn default() -> Self {
        Self {
            // DECTCEM: the one mode whose power-on value is not the zero value.
            cursor_visible: true,
            cursor_shape: CursorShape::default(),
            bracketed_paste: false,
            focus_events: false,
            alt_scroll: false,
            color_scheme_updates: false,
            sync_until: None,
            mouse: Mouse::default(),
            origin_mode: false,
            dec_graphics: false,
            app_cursor: false,
            app_keypad: false,
            modify_other_keys: 0,
            kitty_keys: Vec::new(),
            newline_mode: false,
        }
    }
}

#[derive(Default)]
struct State {
    primary: Screen,
    alt: Screen,
    on_alt: bool,
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
    /// The body of a sixel DCS string being collected, if one is open.
    ///
    /// `None` for every other DCS: the parser hands over the payload of whatever string
    /// is running, and only `q` is ours. Collected rather than decoded incrementally
    /// because a sixel's size is not known until its last band -- see [`sixel::decode`].
    sixel: Option<Vec<u8>>,
    /// The cell size Emacs reports, for turning pixels into a cell rectangle.
    metrics: CellMetrics,
    /// The light/dark scheme Emacs reports, for answering `CSI ? 996 n`.
    ///
    /// Emacs' to know and ours to answer with, exactly as `metrics` is: the theme
    /// resolves against the buffer's faces, which nothing here can see. Silent until
    /// Emacs has reported one, on the same grounds as an unreported cell size -- see the
    /// `14t`/`16t` guards in csi.rs -- and one ground stronger, since there is no number
    /// for "I do not know" that would not have to be invented.
    ///
    /// On [`State`] rather than [`Modes`] for the same reason `metrics` is: it is not
    /// something the child negotiated, so a soft reset must not clear it.
    color_scheme: Option<ColorScheme>,
    /// Rows that have ever left the top of the primary screen. Screen row 0 is this row,
    /// counting from the beginning of the session, which is what makes an [`Anchor`]
    /// outlive the grid position it was taken from.
    evicted_total: usize,
    events: Vec<Event>,
    /// The last graphic character printed, for REP. Held after `dec_graphic` translation,
    /// so repeating a box-drawing character repeats what was actually drawn.
    ///
    /// Zero-width characters never land here. REP is defined for the last *graphic*
    /// character, and repeating a combining mark would fold it onto the cell to the left
    /// over and over rather than printing anything.
    last_print: Option<char>,
    /// Test-only: force every character through [`State::print`] rather than the batched
    /// [`Perform::print_str`] path.
    ///
    /// It exists because the two paths are only worth having if they are indistinguishable,
    /// and nothing else can make a `Term` demonstrate that. Feeding a byte at a time does
    /// not do it -- `print_str` still runs, just with runs of length one, so a test built
    /// that way compares the fast path against itself and passes no matter how wrong it
    /// is. That was the first attempt, and it survived deliberately breaking `write_run`
    /// twice. See `batched_and_per_character_printing_agree`.
    ///
    /// `#[cfg(test)]`, so the field and its test do not exist in a release build.
    #[cfg(test)]
    force_per_character_print: bool,
    /// The pen's underline colour (`SGR 58`). Not part of [`Style`]: it is stored per row
    /// in a side table, so that a rare feature does not grow every cell on the grid.
    underline: Color,
    /// The `OSC 8` hyperlink the child currently has open, if any.
    ///
    /// Beside [`State::underline`] and read the same way in `print`, and the resemblance
    /// stops exactly there: an underline colour is `SGR 58`, so `SGR 0` clears it, while
    /// a hyperlink is *not* an SGR attribute and no rendition change may close one. Real
    /// terminals hold it open across arbitrary colour changes until an explicit
    /// `OSC 8 ; ; ST`, which is what makes the common shape — a link the program colours
    /// as it prints it — work at all. See `hyperlink` for what does close it.
    ///
    /// One field for both screens, exactly as `pen` and `underline` are: an open
    /// hyperlink is a property of the byte stream, not of the grid being written to, so
    /// a child that opens one and then switches to the alternate screen goes on writing
    /// it there. No real terminal saves and restores it across 1049 either, and the
    /// alternative — closing it on the switch — would silently drop the link from a
    /// full-screen program that opened it just before taking the screen.
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
    /// them; and by an eviction, which moves them by however much the row that left
    /// renders differently as scrollback than it did as a live row. A flag rather than
    /// the positions themselves, because the positions are only true at the moment they
    /// are read: the child is signalled on a resize and answers by redrawing, so a
    /// snapshot taken when the grid was re-laid is stale by however many rows it scrolls
    /// before the drain -- which made the repair land a row low, intermittently,
    /// depending on how the redraw fell across drains.
    marks_dirty: bool,
    /// Marks that have left the grid since the last drain, with the absolute rows they
    /// left on.
    ///
    /// These cannot be read off the grid at drain time, being no longer on it, and they
    /// cannot go stale either: a row's absolute number is fixed the moment it is
    /// archived.
    evicted_marks: Vec<(MarkId, Anchor)>,
    /// Everything DECSTR and RIS put back; see [`Modes`].
    modes: Modes,
}

/// `38;5;n` / `38;2;r;g;b` and their colon-subparameter spellings.
fn extended(param: &[u16], iter: &mut super::parser::ParamsIter<'_>) -> Option<Color> {
    let mut subs = param[1..].iter().copied();
    let mut next = || {
        subs.next()
            .or_else(|| iter.next().and_then(|p| p.first().copied()))
    };
    match next()? {
        5 => Some(Color::Indexed(next()? as u8)),
        // The colon form permits an empty color-space id: 38:2::R:G:B
        2 => {
            let (a, b, c) = (next()?, next()?, next()?);
            match (param.len() >= 6, next()) {
                (true, Some(d)) => Some(Color::Rgb(b as u8, c as u8, d as u8)),
                _ => Some(Color::Rgb(a as u8, b as u8, c as u8)),
            }
        }
        _ => None,
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
