//! The VT parser front end: turns a byte stream into grid mutations and [`Event`]s.
//!
//! Scrollback deliberately lives in the Emacs buffer, not here. Rows that fall off the
//! top of the primary screen are handed over once, in [`Delta::scrolled`], and forgotten.

use super::cell::{Attrs, Color, Row, Run, Style};
use super::screen::{Cursor, Erase, Resize, Screen};
use std::collections::VecDeque;
use unicode_width::UnicodeWidthChar;
use vte::{Params, Parser, Perform};

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

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Block => "block",
            Self::Underline => "underline",
            Self::Bar => "bar",
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
    PromptStart(Anchor),
    /// OSC 133;B — user input begins; this is where comint takes over.
    PromptEnd(Anchor),
    /// OSC 133;C — the command is running and owns the output region.
    CommandStart(Anchor),
    /// OSC 133;D — the command finished, with its exit status when reported.
    CommandEnd(Option<i32>, Anchor),
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

impl KeyEncoding {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Legacy => "legacy",
            Self::ModifyOtherKeys => "modify-other",
            Self::Kitty => "kitty",
        }
    }
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
}

/// Backlog at which the reader stops pulling from the pty, letting the child block.
/// How long a child may hold back a redisplay with DEC mode 2026 before we draw anyway.
///
/// Synchronized output exists so a half-drawn frame is never shown; it is not a licence
/// to freeze the buffer. A child killed mid-frame never sends the end marker, so without
/// a cap the last thing the user sees is a partial screen. xterm and contour use 150ms,
/// kitty 100; the longer of the two is the safer choice on a loaded machine.
pub const SYNC_TIMEOUT: std::time::Duration = std::time::Duration::from_millis(150);

pub const BACKLOG_HIGH_WATER: usize = 8_000;

/// Largest OSC payload forwarded to Lisp, in bytes. Well past any real title or
/// hyperlink, and short of letting a single escape sequence allocate without bound.
pub const OSC_PAYLOAD_LIMIT: usize = 1 << 20;

/// Depth of the kitty keyboard flag stack. Real clients push once around a full-screen
/// session; anything deeper is a child that never pops.
const KITTY_STACK_LIMIT: usize = 16;

/// Frame `ESC ] CODE ; PAYLOAD` with the terminator the query used.
///
/// Queries whose answer only Emacs knows — the default colours, which resolve against
/// the buffer's faces rather than any palette we hold — are answered from Lisp, but the
/// framing belongs here so that no Lisp ever splices control bytes by hand.
///
/// `bell` picks BEL over ST because xterm echoes the terminator it was asked with, and a
/// client scanning its input for BEL hangs on an ST-terminated reply.
///
/// Returns `None` for a payload carrying C0 controls or DEL, which would end the sequence
/// early or inject one of their own. Payloads are attacker-reachable — a colour name can
/// arrive from the child in a set request and come straight back out in the echo — so
/// centralising the framing buys nothing unless it also refuses to frame a lie.
pub fn osc_reply(code: u16, payload: &str, bell: bool) -> Option<Vec<u8>> {
    if payload.chars().any(|c| c.is_control() || c == '\u{7f}') {
        return None;
    }
    let terminator = if bell { "\x07" } else { "\x1b\\" };
    Some(format!("\x1b]{code};{payload}{terminator}").into_bytes())
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

    pub fn feed(&mut self, bytes: &[u8]) {
        self.parser.advance(&mut self.state, bytes);
    }

    pub fn drain(&mut self) -> Delta {
        self.state.drain()
    }

    pub fn resize(&mut self, rows: usize, cols: usize) {
        self.state.resize(rows, cols);
    }

    /// Emacs has discarded the scrollback, so the top row continues nothing.
    pub fn forget_history(&mut self) {
        self.state.primary.forget_carry();
    }

    /// Mark every row of the current screen damaged, so the next drain re-sends all of
    /// it. The way back from a redisplay that failed part-way and left Emacs' idea of
    /// the screen region disagreeing with ours.
    pub fn touch_all(&mut self) {
        self.state.screen_mut().touch_all();
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
        self.state.mouse
    }

    pub fn bracketed_paste(&self) -> bool {
        self.state.bracketed_paste
    }

    pub fn focus_events(&self) -> bool {
        self.state.focus_events
    }

    /// How long this frame may still suppress a redisplay, if it may at all.
    pub fn sync_deadline(&self) -> Option<std::time::Instant> {
        self.state
            .sync_until
            .filter(|t| std::time::Instant::now() < *t)
    }

    /// Whether a wheel notch should become cursor keys: the child asked for alternate
    /// scroll, the alternate screen is up, and it did not ask for the mouse itself —
    /// a program that wants mouse reports gets mouse reports, as in xterm.
    pub fn alt_scroll(&self) -> bool {
        self.state.alt_scroll && self.state.on_alt && !self.state.mouse.enabled()
    }

    pub fn app_cursor(&self) -> bool {
        self.state.app_cursor
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
    pub fn backlog(&self) -> usize {
        self.state.pending_scrollback.len() + self.state.events.len()
    }

    /// Text of the last non-blank line — the prompt a `getpass` child just printed.
    pub fn trailing_text(&self) -> Option<String> {
        self.state.screen().last_nonblank_text()
    }
}

struct State {
    primary: Screen,
    alt: Screen,
    on_alt: bool,
    pen: Style,
    pending_scrollback: VecDeque<Scrolled>,
    /// Rows that have ever left the top of the primary screen. Screen row 0 is this row,
    /// counting from the beginning of the session, which is what makes an [`Anchor`]
    /// outlive the grid position it was taken from.
    evicted_total: usize,
    events: Vec<Event>,
    cursor_visible: bool,
    cursor_shape: CursorShape,
    bracketed_paste: bool,
    /// DEC mode 1004: the child wants `CSI I`/`CSI O` when the window gains or loses
    /// focus. Read at the moment focus changes, so it is state rather than a level.
    focus_events: bool,
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
    /// The last graphic character printed, for REP. Held after `dec_graphic` translation,
    /// so repeating a box-drawing character repeats what was actually drawn.
    ///
    /// Zero-width characters never land here. REP is defined for the last *graphic*
    /// character, and repeating a combining mark would fold it onto the cell to the left
    /// over and over rather than printing anything.
    last_print: Option<char>,
    /// The pen's underline colour (`SGR 58`). Not part of [`Style`]: it is stored per row
    /// in a side table, so that a rare feature does not grow every cell on the grid.
    underline: Color,
    /// Where the shell last said its prompt begins (OSC 133;A), in [`Anchor`] coordinates.
    ///
    /// Emacs keeps markers for the *command* regions it renders; this keeps the one row
    /// the grid itself needs an answer about, for [`Term::clear_to_prompt`]. Absolute, so
    /// it survives the rows above it scrolling away, and rebased when rows are removed
    /// from under it — the two ways row 0 can stop meaning what it meant.
    prompt_start: Option<Anchor>,
}

impl State {
    fn new(rows: usize, cols: usize) -> Self {
        Self {
            primary: Screen::new(rows, cols),
            alt: Screen::new(rows, cols),
            on_alt: false,
            pen: Style::default(),
            pending_scrollback: VecDeque::new(),
            evicted_total: 0,
            events: Vec::new(),
            cursor_visible: true,
            cursor_shape: CursorShape::default(),
            bracketed_paste: false,
            focus_events: false,
            alt_scroll: false,
            sync_until: None,
            mouse: Mouse::default(),
            origin_mode: false,
            dec_graphics: false,
            app_cursor: false,
            app_keypad: false,
            modify_other_keys: 0,
            kitty_keys: Vec::new(),
            newline_mode: false,
            last_print: None,
            underline: Color::Default,
            prompt_start: None,
        }
    }

    /// Kitty wins when both are on: a child that pushed kitty flags is speaking the newer
    /// protocol deliberately, and libraries that enable both expect kitty to take effect.
    fn key_encoding(&self) -> KeyEncoding {
        match (
            self.kitty_keys.last().copied().unwrap_or(0),
            self.modify_other_keys,
        ) {
            (flags, _) if flags & 1 != 0 => KeyEncoding::Kitty,
            (_, 2) => KeyEncoding::ModifyOtherKeys,
            _ => KeyEncoding::Legacy,
        }
    }

    fn screen(&self) -> &Screen {
        if self.on_alt {
            &self.alt
        } else {
            &self.primary
        }
    }

    fn screen_mut(&mut self) -> &mut Screen {
        if self.on_alt {
            &mut self.alt
        } else {
            &mut self.primary
        }
    }

    /// Rows leaving the *current* screen: buffer text on the primary, discarded on the alt.
    ///
    /// The guard is about which screen produced the rows, so callers that already know the
    /// rows came from the primary must use [`State::archive`] instead — see `resize`.
    ///
    /// Growth is bounded by backpressure rather than by discarding: the reader stops
    /// reading once [`Term::backlog`] is high, the pty's own buffer fills, and the
    /// child blocks in `write` exactly as it would against a slow terminal. Dropping
    /// would be lossy, and losing the middle of a build log is worse than waiting.
    ///
    /// The alt screen is exempt from that measure by design. It contributes no scrollback,
    /// its grid is a fixed size, and `min_redisplay_interval` already bounds how often its
    /// frames are drawn — so intermediate frames of a repaint are genuinely discardable in
    /// a way log lines are not, and there is nothing to apply backpressure against.
    fn evicted(&mut self, rows: Vec<Row>) {
        if self.on_alt {
            return;
        }
        self.archive(rows);
    }

    /// The child cleared the whole display; see [`Event::DisplayCleared`].
    ///
    /// Silent on the alternate screen, which archives nothing and is pinned to the top of
    /// the window already: there is no transcript there to scroll out of view.
    fn cleared_display(&mut self) {
        if !self.on_alt {
            self.events.push(Event::DisplayCleared);
        }
    }

    /// Send rows to scrollback unconditionally, for callers holding primary rows.
    ///
    /// The single funnel for rows leaving the primary screen, which is why the absolute
    /// row counter is kept here rather than at each of its callers.
    fn archive(&mut self, rows: Vec<Row>) {
        self.evicted_total += rows.len();
        // Reduced to runs here rather than at drain time: a Row owns a cell for every
        // column, so retaining thousands of them keeps megabytes of mostly-blank grid
        // alive. Runs are trimmed to content, and the work has to happen regardless.
        // `line_runs` rather than `runs`: these rows are becoming buffer text as part of a
        // logical line, and a continuation row has to keep the blanks that are interior to
        // it. See `Row::line_runs`.
        self.pending_scrollback
            .extend(rows.iter().map(|row| Scrolled {
                runs: row.line_runs(),
                wrapped: row.wrapped,
            }));
    }

    /// See [`Term::clear_to_prompt`].
    ///
    /// A no-op on the alternate screen: that grid is a running program's frame, not a
    /// transcript, and removing rows from under it would corrupt a redisplay we cannot
    /// repair. The scrollback Emacs deletes alongside is the primary's, and is untouched
    /// by whatever is on screen.
    fn clear_to_prompt(&mut self) -> usize {
        if self.on_alt {
            return 0;
        }
        let cursor = self.primary.cursor.row;
        let keep = self
            .prompt_start
            .and_then(|at| at.row.checked_sub(self.evicted_total))
            .filter(|row| *row <= cursor)
            .unwrap_or(cursor);
        if keep == 0 {
            return 0;
        }
        self.remove_rows(0, keep);
        keep
    }

    /// The single funnel for rows being removed from the grid, which is what keeps
    /// [`State::prompt_start`] meaning what it says.
    ///
    /// Rows removed this way are discarded rather than archived, so `evicted_total` does
    /// not move and screen row 0 keeps its absolute number — but every row *below* the
    /// cut slides up, so an anchor pointing at one of them has to come down to meet it.
    /// The rebase is the same arithmetic [`Screen::remove_rows`] applies to the cursor,
    /// and for the same reason: both name a row by where it sits, and the rows moved.
    ///
    /// Going through here rather than reaching for [`State::screen_mut`] is not a style
    /// preference. `clear_to_prompt` rebased and `Term::remove_rows` did not, so
    /// `cooked-delete-output` — which removes rows above the prompt — left the anchor
    /// stale by exactly the count it dropped. A later `clear_to_prompt` then measured a
    /// prompt row past the cursor, failed its own sanity filter, and silently fell back
    /// to cutting at the cursor: right for a one-line prompt, and wrong for the
    /// multi-line case the anchor exists to get right.
    fn remove_rows(&mut self, first: usize, count: usize) {
        self.screen_mut().remove_rows(first, count);
        // The alt grid holds a running program's frame, not a transcript; no anchor
        // points into it, and the primary's rows have not moved.
        if self.on_alt {
            return;
        }
        if let Some(at) = &mut self.prompt_start {
            let Some(row) = at.row.checked_sub(self.evicted_total) else {
                // Already below the screen's top edge, so nothing on the grid moved it.
                return;
            };
            let moved = match row {
                row if row >= first + count => row - count,
                // The anchored row itself went. The nearest row it can still name is
                // the one that closed the gap, exactly as the cursor is clamped.
                row if row >= first => first,
                row => row,
            };
            at.row = self.evicted_total + moved;
        }
    }

    /// Where the cursor is now, in the coordinates an [`Anchor`] keeps.
    fn anchor(&self) -> Anchor {
        let cursor = self.screen().cursor;
        Anchor {
            row: self.evicted_total + cursor.row,
            col: cursor.col,
        }
    }

    fn linefeed(&mut self) {
        let pen = self.pen;
        let evicted = self.screen_mut().linefeed(pen);
        self.evicted(evicted);
    }

    fn resize(&mut self, rows: usize, cols: usize) {
        let evicted = self.primary.resize(rows, cols, Resize::Rewrap);
        self.alt.resize(rows, cols, Resize::Clamp);
        // These rows came off the primary whichever screen is showing, so they are history
        // even mid-alt. Routing them through `evicted` would drop the top of the transcript
        // whenever the frame was resized with a full-screen program open.
        self.archive(evicted);
    }

    fn drain(&mut self) -> Delta {
        let damaged = self.screen_mut().drain_damage();
        let scrolled = Vec::from(std::mem::take(&mut self.pending_scrollback));
        // Taken before the batch is handed over, so it names the first line *in* it.
        let scrolled_base = self.evicted_total - scrolled.len();
        let events = std::mem::take(&mut self.events);
        let (cursor_visible, alt, app_cursor) = (self.cursor_visible, self.on_alt, self.app_cursor);
        let cursor_shape = self.cursor_shape;
        let keys = self.key_encoding();
        let screen = self.screen();
        Delta {
            scrolled,
            scrolled_base,
            rows: damaged
                .into_iter()
                .filter_map(|i| screen.row(i).map(|r| (i, r.runs())))
                .collect(),
            height: screen.height(),
            used: screen.used(),
            // The seam is a property of the primary: the alt screen contributes no
            // scrollback, and its row 0 begins a buffer line of its own.
            head: if alt { 0 } else { screen.head() },
            cursor: screen.cursor,
            cursor_visible,
            cursor_shape,
            alt,
            app_cursor,
            keys,
            events,
        }
    }

    fn set_alt(&mut self, on: bool) {
        if self.on_alt == on {
            return;
        }
        self.on_alt = on;
        if on {
            // Dropped rather than archived: this is the previous full-screen program's
            // leftover frame, which was never history to begin with.
            // `Style::default()`, not the pen: a freshly entered alt screen is not the
            // outgoing program's background wash.
            drop(self.alt.erase_display(Erase::All, Style::default()));
            self.alt.goto(0, 0);
        }
        // No event to match: `Delta::alt` is the level, and Lisp acts on that. See the
        // note on `Event` about not sending the same state two ways.
        self.screen_mut().touch_all();
    }

    fn dec_mode(&mut self, mode: u16, on: bool) {
        match mode {
            1 => self.app_cursor = on,
            66 => self.app_keypad = on,
            6 => {
                self.origin_mode = on;
                self.screen_mut().goto(0, 0);
            }
            7 => {
                self.primary.set_autowrap(on);
                self.alt.set_autowrap(on);
            }
            // Cursor *blink*, deliberately ignored: that is `blink-cursor-mode', which is
            // the user's setting and not the child's to drive. Visibility is mode 25.
            12 => {}
            25 => self.cursor_visible = on,
            1000 => self.mouse.click = on,
            1002 => (self.mouse.click, self.mouse.drag) = (on, on),
            1003 => (self.mouse.click, self.mouse.motion) = (on, on),
            1006 => self.mouse.sgr = on,
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
            // No event: nothing reacts to this. It is read at the one moment it matters,
            // by `Term::bracketed_paste` as a multi-line submission is being framed.
            1004 => self.focus_events = on,
            1007 => self.alt_scroll = on,
            2026 => {
                self.sync_until = on.then(|| std::time::Instant::now() + SYNC_TIMEOUT);
            }
            2004 => self.bracketed_paste = on,
            _ => return,
        }
        if matches!(mode, 1000 | 1002 | 1003 | 1006) {
            self.events.push(Event::Mouse(self.mouse));
        }
    }

    /// DECRQM's answer for a private mode: 1 set, 2 reset, 3 permanently set, 4
    /// permanently reset, 0 not recognised.
    fn dec_mode_state(&self, mode: u16) -> u8 {
        let set = |on: bool| 2 - u8::from(on);
        match mode {
            1 => set(self.app_cursor),
            6 => set(self.origin_mode),
            7 => set(self.screen().autowrap()),
            25 => set(self.cursor_visible),
            66 => set(self.app_keypad),
            1000 => set(self.mouse.click && !self.mouse.drag && !self.mouse.motion),
            1002 => set(self.mouse.drag),
            1003 => set(self.mouse.motion),
            1006 => set(self.mouse.sgr),
            1004 => set(self.focus_events),
            1007 => set(self.alt_scroll),
            2026 => set(self
                .sync_until
                .is_some_and(|t| std::time::Instant::now() < t)),
            47 | 1047 | 1049 => set(self.on_alt),
            // Implemented, but stateless — it saves and restores rather than turning
            // anything on — so "set" is the only honest answer that is not "unknown".
            1048 => 1,
            2004 => set(self.bracketed_paste),
            // Dropped from our terminfo, and this is where a child finds that out
            // without having to guess: 12 is cursor blink (`blink-cursor-mode' is the
            // user's), 69 left-right margins, 1034 meta-sends-escape.
            12 | 69 | 1034 => 4,
            _ => 0,
        }
    }

    /// ANSI (non-private) modes. Only two of these are real: everything else a child
    /// sends here is a mode we neither implement nor advertise.
    fn ansi_mode(&mut self, mode: u16, on: bool) {
        match mode {
            4 => {
                self.primary.set_insert_mode(on);
                self.alt.set_insert_mode(on);
            }
            20 => self.newline_mode = on,
            _ => {}
        }
    }

    /// DECSTR, and the mode half of RIS.
    ///
    /// Everything the child negotiated goes back to its power-on value. The screen and
    /// the scrollback are deliberately not touched — that is the whole difference between
    /// a soft reset and RIS, and it is why `rs2` can be sent without losing the session's
    /// transcript.
    fn soft_reset(&mut self) {
        self.pen = Style::default();
        self.underline = Color::Default;
        self.origin_mode = false;
        self.dec_graphics = false;
        self.app_cursor = false;
        self.app_keypad = false;
        self.cursor_visible = true;
        self.cursor_shape = CursorShape::default();
        self.bracketed_paste = false;
        self.focus_events = false;
        self.alt_scroll = false;
        self.sync_until = None;
        self.newline_mode = false;
        self.last_print = None;
        self.modify_other_keys = 0;
        self.kitty_keys.clear();
        for screen in [&mut self.primary, &mut self.alt] {
            screen.reset_region();
            screen.set_autowrap(true);
            screen.set_insert_mode(false);
            screen.saved = None;
        }
        if self.mouse != Mouse::default() {
            self.mouse = Mouse::default();
            self.events.push(Event::Mouse(self.mouse));
        }
    }

    fn save_restore(&mut self, save: bool) {
        let screen = self.screen_mut();
        if save {
            screen.saved = Some(screen.cursor);
        } else if let Some(cursor) = screen.saved.take() {
            screen.goto(cursor.row, cursor.col);
        }
    }

    fn semantic(&mut self, params: &[&[u8]]) {
        let Some(kind) = params.get(1).and_then(|p| p.first()) else {
            return;
        };
        // Anchored here, where the mark actually is in the stream. See [`Anchor`].
        let at = self.anchor();
        self.events.push(match kind {
            b'A' => {
                self.prompt_start = Some(at);
                Event::PromptStart(at)
            }
            b'B' => Event::PromptEnd(at),
            b'C' => Event::CommandStart(at),
            b'D' => Event::CommandEnd(
                params
                    .get(2)
                    .and_then(|p| std::str::from_utf8(p).ok())
                    .and_then(|s| s.parse().ok()),
                at,
            ),
            _ => return,
        });
    }

    fn sgr(&mut self, params: &Params) {
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
}

/// `38;5;n` / `38;2;r;g;b` and their colon-subparameter spellings.
fn extended(param: &[u16], iter: &mut vte::ParamsIter<'_>) -> Option<Color> {
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

fn arg(params: &Params, index: usize, default: usize) -> usize {
    params
        .iter()
        .nth(index)
        .and_then(|p| p.first().copied())
        .filter(|v| *v != 0)
        .map_or(default, usize::from)
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

impl Perform for State {
    fn print(&mut self, c: char) {
        let c = if self.dec_graphics { dec_graphic(c) } else { c };
        let pen = self.pen;
        let underline = self.underline;
        let width = c.width().unwrap_or(0);
        let screen = self.screen_mut();
        let evicted = screen.write(c, pen);
        // After the write, so it lands on the cell the write actually chose — which a
        // wrap or DECAWM may have moved. The second test is what retires a stale colour
        // when a cell that had one is overwritten by a cell that does not: `Row::set`
        // deliberately knows nothing about underlines, because a branch there is a branch
        // per character written.
        // Zero-width characters fold onto the cell to their left and never own one, so
        // they must not move an underline colour either.
        if width > 0 && (underline != Color::Default || screen.underlined()) {
            screen.mark_underline(underline, width);
        }
        self.evicted(evicted);
        if width > 0 {
            self.last_print = Some(c);
        }
    }

    fn execute(&mut self, byte: u8) {
        match byte {
            0x07 => self.events.push(Event::Bell),
            0x08 => self.screen_mut().backspace(),
            0x09 => self.screen_mut().tab(1),
            0x0A..=0x0C => {
                self.linefeed();
                // LNM: the child asked for LF to imply CR.
                if self.newline_mode {
                    self.screen_mut().carriage_return();
                }
            }
            0x0D => self.screen_mut().carriage_return(),
            0x0E => self.dec_graphics = true,
            0x0F => self.dec_graphics = false,
            _ => {}
        }
    }

    fn csi_dispatch(&mut self, params: &Params, intermediates: &[u8], _ignore: bool, action: char) {
        let private = intermediates.first().copied();
        // `bce`: erases and scrolls leave the pen's background behind. See `Style::erase`.
        let pen = self.pen;
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
            (None, 'A') => self.screen_mut().move_by(-(arg(params, 0, 1) as isize), 0),
            (None, 'B' | 'e') => self.screen_mut().move_by(arg(params, 0, 1) as isize, 0),
            (None, 'C' | 'a') => self.screen_mut().move_by(0, arg(params, 0, 1) as isize),
            (None, 'D') => self.screen_mut().move_by(0, -(arg(params, 0, 1) as isize)),
            (None, 'E') => {
                self.screen_mut().move_by(arg(params, 0, 1) as isize, 0);
                self.screen_mut().carriage_return();
            }
            (None, 'F') => {
                self.screen_mut().move_by(-(arg(params, 0, 1) as isize), 0);
                self.screen_mut().carriage_return();
            }
            (None, 'G' | '`') => {
                let row = self.screen().cursor.row;
                self.screen_mut().goto(row, arg(params, 0, 1) - 1);
            }
            (None, 'H' | 'f') => {
                let top = if self.origin_mode {
                    self.screen().region.top
                } else {
                    0
                };
                let (row, col) = (arg(params, 0, 1) - 1 + top, arg(params, 1, 1) - 1);
                self.screen_mut().goto(row, col);
            }
            (None, 'J') => {
                let param = arg(params, 0, 0) as u16;
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
                if let Some(how) = Erase::from_param(arg(params, 0, 0) as u16) {
                    self.screen_mut().erase_line(how, pen);
                }
            }
            (None, 'L') => self.screen_mut().insert_lines(arg(params, 0, 1), pen),
            (None, 'M') => self.screen_mut().delete_lines(arg(params, 0, 1), pen),
            (None, 'P') => self.screen_mut().delete_chars(arg(params, 0, 1), pen),
            (None, 'S') => {
                let n = arg(params, 0, 1);
                let evicted = self.screen_mut().scroll_up(n, pen);
                self.evicted(evicted);
            }
            (None, 'T') => self.screen_mut().scroll_down(arg(params, 0, 1), pen),
            (None, 'X') => self.screen_mut().erase_chars(arg(params, 0, 1), pen),
            (None, '@') => self.screen_mut().insert_chars(arg(params, 0, 1), pen),
            (None, 'd') => {
                let col = self.screen().cursor.col;
                self.screen_mut().goto(arg(params, 0, 1) - 1, col);
            }
            (None, 'g') => self.screen_mut().clear_tabs(arg(params, 0, 0) == 3),
            (None, 'm') => self.sgr(params),
            (None, 'r') => {
                let bottom = arg(params, 1, self.screen().height());
                self.screen_mut()
                    .set_region(arg(params, 0, 1) - 1, bottom - 1);
            }
            // XTMODKEYS, `CSI > 4 ; Ps m`. Bare `CSI > 4 m` means "back to the default",
            // which is level 0 for our purposes.
            (Some(b'>'), 'm') => {
                if arg(params, 0, 4) == 4 {
                    self.modify_other_keys = params
                        .iter()
                        .nth(1)
                        .and_then(|p| p.first().copied())
                        .unwrap_or(0) as u8;
                }
            }
            // Kitty keyboard protocol: push, pop, and set. The stack is capped because a
            // child can push without ever popping, and only the top is ever read.
            (Some(b'>'), 'u') => {
                if self.kitty_keys.len() < KITTY_STACK_LIMIT {
                    self.kitty_keys.push(arg(params, 0, 0) as u8);
                }
            }
            (Some(b'<'), 'u') => {
                for _ in 0..arg(params, 0, 1).max(1) {
                    self.kitty_keys.pop();
                }
            }
            (Some(b'='), 'u') => {
                let flags = arg(params, 0, 0) as u8;
                match self.kitty_keys.last_mut() {
                    Some(top) => *top = flags,
                    None => self.kitty_keys.push(flags),
                }
            }
            // A child that probes and gets no answer may wait for one.
            (Some(b'?'), 'u') => {
                let flags = self.kitty_keys.last().copied().unwrap_or(0);
                self.events
                    .push(Event::Reply(format!("\x1b[?{flags}u").into_bytes()));
            }
            // DECRQM. The machine-readable half of the terminfo audit: a mode we
            // implement answers 1 or 2, one we deliberately do not answers 4
            // ("permanently reset"), and one we have never heard of answers 0. A child
            // can therefore stop inferring our capabilities from TERM and just ask.
            (Some(b'?'), 'p') if intermediates.contains(&b'$') => {
                let mode = arg(params, 0, 0) as u16;
                let status = self.dec_mode_state(mode);
                self.events.push(Event::Reply(
                    format!("\x1b[?{mode};{status}$y").into_bytes(),
                ));
            }
            // The ANSI form has `$` as its only intermediate, so it arrives here as the
            // "private" byte rather than alongside one.
            (Some(b'$'), 'p') => {
                let mode = arg(params, 0, 0) as u16;
                let status = match mode {
                    4 => 2 - u8::from(self.screen().insert_mode()),
                    20 => 2 - u8::from(self.newline_mode),
                    _ => 0,
                };
                self.events
                    .push(Event::Reply(format!("\x1b[{mode};{status}$y").into_bytes()));
            }
            // XTWINOPS, read-only. The reporting and geometry operations are refused
            // rather than merely unimplemented: `21t` answers with the window title *on
            // the child's input stream*, which turns a title the child set itself into
            // typed input at the next prompt, and `3t`/`4t`/`8t` move and resize the
            // window, which is Emacs' business and not the child's.
            (None, 't') => match arg(params, 0, 0) {
                18 => {
                    let (h, w) = (self.screen().height(), self.screen().width());
                    self.events
                        .push(Event::Reply(format!("\x1b[8;{h};{w}t").into_bytes()));
                }
                22 => self.events.push(Event::TitleStack(true)),
                23 => self.events.push(Event::TitleStack(false)),
                _ => {}
            },
            // REP. Bounded by the screen: a child should not turn three bytes into an
            // arbitrarily long print loop.
            (None, 'b') => {
                if let Some(ch) = self.last_print {
                    let cap = self.screen().width() * self.screen().height();
                    let pen = self.pen;
                    for _ in 0..arg(params, 0, 1).min(cap) {
                        let evicted = self.screen_mut().write(ch, pen);
                        self.evicted(evicted);
                    }
                }
            }
            (None, 'Z') => self.screen_mut().back_tab(arg(params, 0, 1)),
            // DECSCUSR. A level, not an event: the shape is state Emacs renders from,
            // so it rides the drain rather than arriving twice.
            (Some(b' '), 'q') => {
                if let Some(shape) = CursorShape::from_param(arg(params, 0, 1)) {
                    self.cursor_shape = shape;
                }
            }
            // DECSTR. Unlike RIS this keeps the screen and the scrollback.
            (Some(b'!'), 'p') => self.soft_reset(),
            // Primary DA. We answer for what we implement and nothing else: VT220 level
            // (62) with ANSI colour (22). Not 1/132-column, not 4/sixel, not 6/selective
            // erase, not 2/printer — see the printer capabilities dropped from terminfo.
            (None, 'c') => self.events.push(Event::Reply(b"\x1b[?62;22c".to_vec())),
            // Secondary DA. Unanswered, a child that queries and waits hangs.
            (Some(b'>'), 'c') => self.events.push(Event::Reply(b"\x1b[>0;0;0c".to_vec())),
            (None, 'n') if arg(params, 0, 0) == 5 => {
                self.events.push(Event::Reply(b"\x1b[0n".to_vec()));
            }
            (None, 'n') if arg(params, 0, 0) == 6 => {
                let Cursor { row, col, .. } = self.screen().cursor;
                self.events.push(Event::Reply(
                    format!("\x1b[{};{}R", row + 1, col + 1).into_bytes(),
                ));
            }
            (None, 'I') => self.screen_mut().tab(arg(params, 0, 1)),
            (None, 's') => self.save_restore(true),
            (None, 'u') => self.save_restore(false),
            _ => {}
        }
    }

    fn esc_dispatch(&mut self, intermediates: &[u8], _ignore: bool, byte: u8) {
        match (intermediates.first().copied(), byte) {
            (Some(b'('), b'0') => self.dec_graphics = true,
            (Some(b'('), _) => self.dec_graphics = false,
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
            (None, b'=') => self.app_keypad = true,
            (None, b'>') => self.app_keypad = false,
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

    fn osc_dispatch(&mut self, params: &[&[u8]], bell_terminated: bool) {
        let Some(code) = params.first().and_then(|p| std::str::from_utf8(p).ok()) else {
            return;
        };
        if code == "133" {
            self.semantic(params);
            return;
        }
        let Ok(code) = code.parse::<u16>() else {
            return;
        };
        // A hostile stream should not get to size our heap for us, and nothing
        // legitimate — title, working directory, hyperlink, clipboard — comes close.
        if params[1..].iter().map(|p| p.len()).sum::<usize>() > OSC_PAYLOAD_LIMIT {
            return;
        }
        // Payloads are handed over lossily rather than dropped: a mangled title is
        // better than a silently vanished one, and callers can validate.
        let parts = params[1..]
            .iter()
            .map(|p| String::from_utf8_lossy(p).into_owned())
            .collect();
        self.events.push(Event::Osc(code, parts, bell_terminated));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn term(rows: usize, cols: usize, input: &[u8]) -> Term {
        let mut t = Term::new(rows, cols);
        t.feed(input);
        t
    }

    fn runs_text(line: &Scrolled) -> String {
        line.runs.iter().map(|r| r.text.as_str()).collect()
    }

    fn text(t: &Term, row: usize) -> String {
        t.screen().row(row).unwrap().to_text()
    }

    #[test]
    fn plain_text_lands_on_the_grid() {
        let t = term(4, 20, b"hello");
        assert_eq!(text(&t, 0), "hello");
    }

    #[test]
    fn cursor_addressing_is_one_based() {
        let t = term(4, 20, b"\x1b[2;3Hx");
        assert_eq!(text(&t, 1), "  x");
    }

    #[test]
    fn sgr_sets_colors_and_attributes() {
        let mut t = term(2, 20, b"\x1b[1;31mred\x1b[0m.");
        let delta = t.drain();
        let runs = &delta.rows.iter().find(|(i, _)| *i == 0).unwrap().1;
        assert_eq!(runs[0].text, "red");
        assert_eq!(runs[0].style.fg, Color::Indexed(1));
        assert!(runs[0].style.attrs.contains(Attrs::BOLD));
        assert_eq!(runs[1].text, ".");
        assert_eq!(runs[1].style, Style::default());
    }

    #[test]
    fn truecolor_arrives_in_both_spellings() {
        let semi = term(2, 20, b"\x1b[38;2;10;20;30mx");
        assert_eq!(
            semi.screen().row(0).unwrap().runs()[0].style.fg,
            Color::Rgb(10, 20, 30)
        );

        let colon = term(2, 20, b"\x1b[38:2::10:20:30mx");
        assert_eq!(
            colon.screen().row(0).unwrap().runs()[0].style.fg,
            Color::Rgb(10, 20, 30)
        );
    }

    #[test]
    fn indexed_256_color() {
        let t = term(2, 20, b"\x1b[38;5;200mx");
        assert_eq!(
            t.screen().row(0).unwrap().runs()[0].style.fg,
            Color::Indexed(200)
        );
    }

    #[test]
    fn underline_styles_arrive_from_the_subparameter() {
        for (input, want) in [
            (&b"\x1b[4mx"[..], 1u8),
            (&b"\x1b[4:1mx"[..], 1),
            (&b"\x1b[4:3mx"[..], 3),
            (&b"\x1b[4:5mx"[..], 5),
        ] {
            let t = term(2, 8, input);
            let style = t.screen().row(0).unwrap().runs()[0].style;
            assert!(style.attrs.contains(Attrs::UNDERLINE), "{input:?}");
            assert_eq!(style.attrs.underline_style(), want, "{input:?}");
        }
    }

    #[test]
    fn underline_is_removed_by_both_spellings() {
        for input in [&b"\x1b[4:3m\x1b[4:0mx"[..], &b"\x1b[4:3m\x1b[24mx"[..]] {
            let style = term(2, 8, input).screen().row(0).unwrap().runs()[0].style;
            assert!(!style.attrs.contains(Attrs::UNDERLINE), "{input:?}");
            assert_eq!(style.attrs.underline_style(), 0, "{input:?}");
        }
    }

    #[test]
    fn underline_colour_parses_both_spellings() {
        let indexed = term(2, 8, b"\x1b[4m\x1b[58;5;196mx");
        assert_eq!(
            indexed.screen().row(0).unwrap().runs()[0].underline,
            Color::Indexed(196)
        );
        let rgb = term(2, 8, b"\x1b[4m\x1b[58:2::255:0:0mx");
        assert_eq!(
            rgb.screen().row(0).unwrap().runs()[0].underline,
            Color::Rgb(255, 0, 0)
        );
        let reset = term(2, 8, b"\x1b[4m\x1b[58;5;196m\x1b[59mx");
        assert_eq!(
            reset.screen().row(0).unwrap().runs()[0].underline,
            Color::Default
        );
    }

    #[test]
    fn a_wide_character_keeps_its_underline_colour() {
        // The colour has to land on the lead cell. `Row::runs` skips continuation cells,
        // so a colour recorded one column to the right disappears entirely.
        let t = term(2, 8, b"\x1b[4;58;5;196m\xe5\xb9\xb8");
        let runs = t.screen().row(0).unwrap().runs();
        assert_eq!(runs.len(), 1, "{runs:?}");
        assert_eq!(runs[0].underline, Color::Indexed(196));
    }

    #[test]
    fn a_combining_mark_does_not_move_an_underline_colour() {
        let t = term(2, 8, b"\x1b[4;58;5;196me\xcc\x81x");
        let runs = t.screen().row(0).unwrap().runs();
        assert!(
            runs.iter().all(|r| r.underline == Color::Indexed(196)),
            "{runs:?}"
        );
    }

    #[test]
    fn an_underline_colour_splits_a_run() {
        // Two cells differing only in underline colour are not the same style.
        let t = term(2, 8, b"\x1b[4ma\x1b[58;5;196mb");
        assert_eq!(t.screen().row(0).unwrap().runs().len(), 2);
    }

    #[test]
    fn an_erase_drops_the_underline_colour() {
        let t = term(2, 8, b"\x1b[4;58;5;196m\x1b[41mab\x1b[K");
        let runs = t.screen().row(0).unwrap().runs();
        let last = runs.last().unwrap();
        assert_eq!(last.underline, Color::Default);
        assert!(!last.style.attrs.contains(Attrs::UNDERLINE));
    }

    #[test]
    fn an_underline_colour_survives_a_rewrap() {
        // The side table is keyed by column, so a reflow has to rebase it the way the
        // combining-mark table is rebased or the colour lands on the wrong character.
        let mut t = term(2, 4, b"ab\x1b[4;58;5;196mcd");
        t.resize(2, 8);
        let runs = t.screen().row(0).unwrap().runs();
        assert_eq!(runs.len(), 2, "{runs:?}");
        assert_eq!(runs[0].text, "ab");
        assert_eq!(runs[1].text, "cd");
        assert_eq!(runs[1].underline, Color::Indexed(196));
    }

    #[test]
    fn overwriting_a_cell_retires_its_underline_colour() {
        // `Row::set` knows nothing about underlines, so this is what proves the screen
        // level flag actually retires a stale entry rather than leaving it on the cell.
        let t = term(2, 8, b"\x1b[4;58;5;196mab\x1b[1G\x1b[mxy");
        let runs = t.screen().row(0).unwrap().runs();
        assert_eq!(runs.len(), 1, "{runs:?}");
        assert_eq!(runs[0].text, "xy");
        assert_eq!(runs[0].underline, Color::Default);
    }

    #[test]
    fn an_erased_row_forgets_its_underline_colours() {
        let t = term(2, 8, b"\x1b[4;58;5;196mab\x1b[1G\x1b[K\x1b[mxy");
        assert_eq!(
            t.screen().row(0).unwrap().runs()[0].underline,
            Color::Default
        );
    }

    #[test]
    fn decrqm_answers_honestly_about_every_mode() {
        for (setup, mode, want) in [
            // Implemented and off, implemented and on.
            (&b""[..], 2004u16, 2u8),
            (&b"\x1b[?2004h"[..], 2004, 1),
            (&b""[..], 7, 1),
            (&b"\x1b[?7l"[..], 7, 2),
            (&b"\x1b[?1004h"[..], 1004, 1),
            (&b"\x1b[?1049h"[..], 1049, 1),
            // Deliberately not implemented — the drop list, machine readable.
            (&b""[..], 12, 4),
            (&b""[..], 69, 4),
            (&b""[..], 1034, 4),
            // Never heard of it.
            (&b""[..], 9999, 0),
            // Implemented, and must not answer "never heard of it".
            (&b""[..], 1048, 1),
        ] {
            let mut t = term(4, 8, setup);
            t.feed(format!("\x1b[?{mode}$p").as_bytes());
            let want = Event::Reply(format!("\x1b[?{mode};{want}$y").into_bytes());
            assert!(
                t.drain().events.contains(&want),
                "mode {mode} after {setup:?}"
            );
        }
    }

    #[test]
    fn decrqm_answers_for_ansi_modes_too() {
        let mut t = term(2, 8, b"\x1b[4h\x1b[4$p");
        assert!(
            t.drain()
                .events
                .contains(&Event::Reply(b"\x1b[4;1$y".to_vec()))
        );
    }

    #[test]
    fn alternate_scroll_needs_the_alt_screen() {
        let mut t = term(2, 8, b"\x1b[?1007h");
        assert!(!t.alt_scroll(), "not while the primary screen is up");
        t.feed(b"\x1b[?1049h");
        assert!(t.alt_scroll());
    }

    #[test]
    fn mouse_reporting_outranks_alternate_scroll() {
        // xterm's precedence: a program that asked for the wheel receives the wheel.
        let mut t = term(2, 8, b"\x1b[?1007h\x1b[?1049h\x1b[?1000h");
        assert!(!t.alt_scroll());
        t.feed(b"\x1b[?1000l");
        assert!(t.alt_scroll());
    }

    #[test]
    fn focus_reporting_is_off_until_asked_for() {
        let mut t = term(2, 8, b"");
        assert!(!t.focus_events());
        t.feed(b"\x1b[?1004h");
        assert!(t.focus_events());
        t.feed(b"\x1b[?1004l");
        assert!(!t.focus_events());
    }

    #[test]
    fn a_soft_reset_stops_focus_reporting() {
        let t = term(2, 8, b"\x1b[?1004h\x1b[!p");
        assert!(!t.focus_events());
    }

    #[test]
    fn decscusr_names_a_shape() {
        for (input, want) in [
            (&b"\x1b[ q"[..], CursorShape::Block),
            (&b"\x1b[2 q"[..], CursorShape::Block),
            (&b"\x1b[3 q"[..], CursorShape::Underline),
            (&b"\x1b[4 q"[..], CursorShape::Underline),
            (&b"\x1b[5 q"[..], CursorShape::Bar),
            (&b"\x1b[6 q"[..], CursorShape::Bar),
        ] {
            let mut t = term(2, 8, input);
            assert_eq!(t.drain().cursor_shape, want, "{input:?}");
        }
    }

    #[test]
    fn an_unknown_cursor_shape_is_left_alone() {
        let mut t = term(2, 8, b"\x1b[5 q\x1b[9 q");
        assert_eq!(t.drain().cursor_shape, CursorShape::Bar);
    }

    #[test]
    fn a_soft_reset_returns_the_cursor_to_a_block() {
        let mut t = term(2, 8, b"\x1b[5 q\x1b[!p");
        assert_eq!(t.drain().cursor_shape, CursorShape::Block);
    }

    #[test]
    fn xtwinops_reports_the_text_area_in_cells() {
        let mut t = term(24, 80, b"\x1b[18t");
        assert!(
            t.drain()
                .events
                .contains(&Event::Reply(b"\x1b[8;24;80t".to_vec()))
        );
    }

    #[test]
    fn xtwinops_pushes_and_pops_the_title() {
        let mut t = term(2, 10, b"\x1b[22;0;0t\x1b[23;0;0t");
        let events = t.drain().events;
        assert!(events.contains(&Event::TitleStack(true)));
        assert!(events.contains(&Event::TitleStack(false)));
    }

    #[test]
    fn xtwinops_refuses_to_report_the_title_or_move_the_window() {
        // `21t` would put the child's own title back on its input stream. `3t`/`4t`/`8t`
        // are Emacs' geometry. All four answer with silence, not with a reply.
        let mut t = term(2, 10, b"\x1b[21t\x1b[3;0;0t\x1b[4;0;0t\x1b[8;9;9t");
        assert!(
            t.drain()
                .events
                .iter()
                .all(|e| !matches!(e, Event::Reply(_))),
            "no window operation may answer the child"
        );
    }

    #[test]
    fn rep_repeats_the_last_graphic_character() {
        let t = term(2, 10, b"-\x1b[4b");
        assert_eq!(text(&t, 0), "-----");
    }

    #[test]
    fn rep_repeats_what_dec_graphics_drew() {
        // `q` in the DEC graphics set is a horizontal rule; REP must repeat the rule,
        // not the letter that was on the wire.
        let t = term(2, 10, b"\x1b(0q\x1b[2b");
        assert_eq!(text(&t, 0), "───");
    }

    #[test]
    fn rep_without_a_preceding_print_does_nothing() {
        let t = term(2, 10, b"\x1b[5b");
        assert_eq!(text(&t, 0), "");
    }

    #[test]
    fn rep_ignores_a_combining_mark() {
        // The mark folds onto the `e`; REP then repeats the `e`, not the accent.
        let t = term(2, 10, b"e\xcc\x81\x1b[2b");
        assert_eq!(t.screen().row(0).unwrap().to_text().chars().count(), 4);
    }

    #[test]
    fn rep_is_bounded_by_the_screen() {
        let mut t = term(2, 10, b"x\x1b[65535b");
        // Twenty cells exist; the count is capped rather than looped 65535 times.
        assert!(t.drain().scrolled.len() <= 2);
    }

    #[test]
    fn back_tab_walks_to_the_previous_stop() {
        let t = term(2, 24, b"\x1b[20G\x1b[Z");
        assert_eq!(t.screen().cursor.col, 16);
        let t = term(2, 24, b"\x1b[20G\x1b[3Z");
        assert_eq!(t.screen().cursor.col, 0, "floors at column zero");
    }

    #[test]
    fn autowrap_off_pins_the_cursor_to_the_last_column() {
        let t = term(2, 5, b"\x1b[?7labcdefgh");
        assert_eq!(text(&t, 0), "abcdh", "the last column keeps overwriting");
        assert_eq!(text(&t, 1), "", "and nothing wrapped below");
    }

    #[test]
    fn autowrap_back_on_resumes_wrapping() {
        let t = term(2, 5, b"\x1b[?7labcde\x1b[?7hfg");
        assert_eq!(text(&t, 0), "abcdf");
        assert_eq!(text(&t, 1), "g");
    }

    #[test]
    fn turning_autowrap_off_disarms_a_pending_wrap() {
        // "abcde" leaves the cursor on the last column with a wrap already decided on.
        // Clearing DECAWM has to withdraw that decision, not honour it on the next write.
        let t = term(2, 5, b"abcde\x1b[?7lX");
        assert_eq!(text(&t, 0), "abcdX");
        assert_eq!(text(&t, 1), "");
    }

    #[test]
    fn insert_mode_shifts_the_rest_of_the_row() {
        let t = term(2, 10, b"abcd\x1b[3G\x1b[4hXY");
        assert_eq!(text(&t, 0), "abXYcd");
    }

    #[test]
    fn insert_mode_shifts_by_a_wide_characters_full_width() {
        let t = term(2, 10, b"abcd\x1b[3G\x1b[4h\xe5\xb9\xb8");
        assert_eq!(text(&t, 0), "ab\u{5e78}cd");
    }

    #[test]
    fn soft_reset_keeps_the_screen_but_clears_the_modes() {
        let mut t = term(2, 10, b"hello\x1b[?7l\x1b[4h\x1b[31m\x1b[?25l\x1b[!p");
        assert_eq!(text(&t, 0), "hello", "DECSTR is not RIS");
        assert!(t.drain().cursor_visible, "mode 25 is back on");

        // Autowrap and insert mode are back to their power-on values.
        t.feed(b"\x1b[6Gabcdefg");
        assert_eq!(text(&t, 1), "fg", "autowrap was restored");
    }

    #[test]
    fn the_init_string_is_understood_end_to_end() {
        // `is2`/`rs2` verbatim: DECSTR, private 3 and 4 off, ANSI 4 off, normal keypad.
        let mut t = term(2, 10, b"\x1b[4h\x1b=");
        t.feed(b"\x1b[!p\x1b[?3;4l\x1b[4l\x1b>");
        t.feed(b"ab\x1b[1GX");
        assert_eq!(text(&t, 0), "Xb", "insert mode is off, so X overwrites");
    }

    #[test]
    fn device_attributes_name_only_what_we_implement() {
        let mut t = term(2, 10, b"\x1b[c\x1b[>c");
        let events = t.drain().events;
        assert!(events.contains(&Event::Reply(b"\x1b[?62;22c".to_vec())));
        assert!(events.contains(&Event::Reply(b"\x1b[>0;0;0c".to_vec())));
    }

    /// The style of the last cell of a row, which is where an erase-to-end lands.
    fn last_style(t: &Term, row: usize) -> Style {
        let r = t.screen().row(row).unwrap();
        r.runs().last().map(|run| run.style).unwrap_or_default()
    }

    #[test]
    fn bce_fills_an_erase_with_the_pens_background() {
        // Red background, then erase to end of line: the bar reaches the right margin.
        let t = term(2, 8, b"\x1b[41mab\x1b[K");
        assert_eq!(last_style(&t, 0).bg, Color::Indexed(1));
        assert_eq!(
            t.screen().row(0).unwrap().to_text(),
            "ab      ",
            "the wash is blanks, not text"
        );
    }

    #[test]
    fn bce_ignores_the_foreground_and_the_attributes() {
        // The regression guard for `Row::content_len`, which counts a styled blank as
        // content: a coloured *foreground* must not turn an erase into trailing cells.
        let plain = term(2, 8, b"ab\x1b[K");
        let fg = term(2, 8, b"\x1b[31;4mab\x1b[K");
        assert_eq!(
            fg.screen().row(0).unwrap().runs().len(),
            plain.screen().row(0).unwrap().runs().len(),
            "SGR 31 then EL must not append a run"
        );
        assert_eq!(last_style(&fg, 0).bg, Color::Default);
    }

    #[test]
    fn bce_keeps_reverse_video() {
        // Reverse is resolved into a face by Lisp, so the bar's colour is the foreground.
        let t = term(2, 8, b"\x1b[7;31mab\x1b[K");
        let style = last_style(&t, 0);
        assert!(style.attrs.contains(Attrs::REVERSE));
        assert_eq!(style.fg, Color::Indexed(1));
    }

    #[test]
    fn bce_applies_to_ech_ich_and_scrolls() {
        let t = term(3, 8, b"abcdef\r\x1b[41m\x1b[3X");
        assert_eq!(
            t.screen().row(0).unwrap().runs()[0].style.bg,
            Color::Indexed(1),
            "ECH erases with the pen"
        );

        // A scroll exposes a fresh row, which is an erase too.
        let t = term(2, 8, b"\x1b[41m\x1b[2Sx");
        assert_eq!(
            t.screen().row(1).unwrap().runs()[0].style.bg,
            Color::Indexed(1)
        );
    }

    #[test]
    fn a_background_wash_is_not_transcript() {
        // Paint the screen and clear it. Without `has_text` this hands Emacs a screenful
        // of pure colour with nothing written on it.
        let mut t = term(3, 8, b"\x1b[41m\x1b[2J");
        assert!(
            t.drain().scrolled.is_empty(),
            "an erased wash must not become scrollback"
        );
    }

    #[test]
    fn a_washed_screen_still_archives_its_text() {
        let mut t = term(3, 8, b"\x1b[41mhello\x1b[2J");
        let scrolled = t.drain().scrolled;
        assert_eq!(scrolled.len(), 1, "the written row is still history");
        assert_eq!(runs_text(&scrolled[0]), "hello");
    }

    #[test]
    fn an_erase_with_no_background_is_unchanged() {
        // The common case must stay byte-identical to life before `bce`.
        let mut t = term(2, 8, b"one\x1b[K\r\ntwo\r\nthree");
        let delta = t.drain();
        assert_eq!(runs_text(&delta.scrolled[0]), "one");
    }

    #[test]
    fn scrolled_rows_are_handed_over_exactly_once() {
        let mut t = term(2, 8, b"one\r\ntwo\r\nthree");
        let delta = t.drain();
        assert_eq!(delta.scrolled.len(), 1);
        assert_eq!(runs_text(&delta.scrolled[0]), "one");
        assert!(t.drain().scrolled.is_empty());
    }

    #[test]
    fn scrolled_lines_carry_their_wrap_provenance() {
        // Eight columns, so "abcdefghij" is one logical line spread over two rows.
        let mut t = term(2, 8, b"abcdefghij\r\nsecond\r\nthird");
        let delta = t.drain();

        assert_eq!(delta.scrolled.len(), 2);
        assert!(
            delta.scrolled[0].wrapped,
            "the overflowing row continues below"
        );
        assert_eq!(runs_text(&delta.scrolled[0]), "abcdefgh");
        assert!(!delta.scrolled[1].wrapped, "a real newline ends the line");
        assert_eq!(runs_text(&delta.scrolled[1]), "ij");
    }

    /// A continuation row's trailing blanks are interior to the line, not the end of it.
    /// Emacs rejoins a wrapped row onto the line above without a newline, so cutting them
    /// pulls the continuation forward — and column-aligned output like `ps` is padded with
    /// spaces at every boundary, so a wrap landing inside a run of them is the common case.
    #[test]
    fn a_wrapped_row_keeps_the_blanks_that_are_interior_to_its_line() {
        // Eight columns. "abc     def" wraps with the row boundary inside the spaces.
        let mut t = term(2, 8, b"abc     def\r\nsecond\r\nthird");
        let delta = t.drain();

        assert_eq!(delta.scrolled.len(), 2);
        assert!(delta.scrolled[0].wrapped);
        assert_eq!(
            runs_text(&delta.scrolled[0]),
            "abc     ",
            "all eight columns, or the line reassembles as `abcdef`"
        );
        assert_eq!(runs_text(&delta.scrolled[1]), "def");
    }

    /// The invariant [`Screen::carried`] rests on: every row that leaves for Emacs while
    /// its line continues is exactly `cols` characters, so `carried * cols` measures the
    /// head. A rewrap blank-pads its chunks out to the full width, so this is what keeps
    /// the seam from drifting once a resize has evicted padded rows.
    #[test]
    fn every_wrapped_row_handed_over_is_exactly_a_full_row_wide() {
        let mut t = Term::new(4, 10);
        // Four space-padded lines, each reaching the right edge, filling the grid.
        for _ in 0..4 {
            t.feed(b"aa   bb   \r\n");
        }
        t.drain();
        t.resize(2, 4);
        let delta = t.drain();

        for line in &delta.scrolled {
            if line.wrapped {
                assert_eq!(
                    runs_text(line).chars().count(),
                    4,
                    "a continuation row must fill its width: {:?}",
                    runs_text(line)
                );
            }
        }
    }

    #[test]
    fn alt_screen_output_never_reaches_scrollback() {
        let mut t = term(2, 8, b"keep\r\n");
        t.drain();
        t.feed(b"\x1b[?1049h");
        t.feed(b"a\r\nb\r\nc\r\nd\r\n");
        let delta = t.drain();
        assert!(
            delta.scrolled.is_empty(),
            "alt screen must not pollute history"
        );
        assert!(delta.alt);

        t.feed(b"\x1b[?1049l");
        let back = t.drain();
        assert!(!back.alt);
        assert_eq!(text(&t, 0), "keep");
    }

    #[test]
    fn osc_133_becomes_semantic_events() {
        let mut t = term(
            4,
            20,
            b"\x1b]133;A\x07$ \x1b]133;B\x07ls\x1b]133;C\x07out\x1b]133;D;3\x07",
        );
        let events = t.drain().events;
        let at = |row, col| Anchor { row, col };
        assert_eq!(
            events,
            vec![
                // Anchored where each mark actually fell on the one row this writes:
                // column 0, then after "$ ", then after "ls", then after "out".
                Event::PromptStart(at(0, 0)),
                Event::PromptEnd(at(0, 2)),
                Event::CommandStart(at(0, 4)),
                Event::CommandEnd(Some(3), at(0, 7)),
            ]
        );
    }

    #[test]
    fn osc_133_d_without_a_status() {
        let mut t = term(4, 20, b"\x1b]133;D\x07");
        assert_eq!(
            t.drain().events,
            vec![Event::CommandEnd(None, Anchor { row: 0, col: 0 })]
        );
    }

    #[test]
    fn unhandled_osc_is_passed_through_verbatim() {
        let mut t = term(4, 20, b"\x1b]0;hi\x07\x1b]7;file://h/tmp\x07");
        assert_eq!(
            t.drain().events,
            vec![
                Event::Osc(0, vec!["hi".into()], true),
                Event::Osc(7, vec!["file://h/tmp".into()], true),
            ]
        );
    }

    #[test]
    fn osc_payloads_keep_their_internal_separators() {
        // vterm's eval protocol embeds quoted arguments that may contain ';'.
        let mut t = term(4, 20, b"\x1b]51;E\"find-file\" \"/tmp/a;b\"\x1b\\");
        assert_eq!(
            t.drain().events,
            vec![Event::Osc(
                51,
                vec!["E\"find-file\" \"/tmp/a".into(), "b\"".into()],
                false
            )]
        );
    }

    #[test]
    fn osc_52_clipboard_is_passed_through() {
        let mut t = term(4, 20, b"\x1b]52;c;aGVsbG8=\x07");
        assert_eq!(
            t.drain().events,
            vec![Event::Osc(52, vec!["c".into(), "aGVsbG8=".into()], true)]
        );
    }

    #[test]
    fn osc_133_stays_typed() {
        let mut t = term(4, 20, b"\x1b]133;A\x07");
        assert_eq!(
            t.drain().events,
            vec![Event::PromptStart(Anchor { row: 0, col: 0 })]
        );
    }

    /// The bug anchors exist for: two commands inside one drain must not collapse onto
    /// the end-of-drain cursor, which is where the *second* one ended.
    #[test]
    fn marks_in_one_drain_keep_their_own_positions() {
        let mut t = term(
            8,
            20,
            b"\x1b]133;C\x07one\r\n\x1b]133;D;0\x07\x1b]133;C\x07two\r\n\x1b]133;D;0\x07",
        );
        let starts: Vec<Anchor> = t
            .drain()
            .events
            .into_iter()
            .filter_map(|e| match e {
                Event::CommandStart(at) => Some(at),
                _ => None,
            })
            .collect();
        assert_eq!(
            starts,
            vec![Anchor { row: 0, col: 0 }, Anchor { row: 1, col: 0 }]
        );
    }

    /// An anchor outlives the row it was taken from: once the marked row has scrolled
    /// away, its absolute row is below the base of the batch still on the grid.
    #[test]
    fn an_anchor_survives_the_row_scrolling_off() {
        let mut t = term(3, 20, b"\x1b]133;C\x07start\r\n");
        t.feed(b"a\r\nb\r\nc\r\nd\r\n");
        let delta = t.drain();
        let Some(&Event::CommandStart(at)) = delta.events.first() else {
            panic!("no command-start: {:?}", delta.events);
        };
        assert_eq!(at.row, 0, "the mark fell on the first row written");
        assert!(
            at.row < delta.scrolled_base + delta.scrolled.len(),
            "the marked row is in this batch of scrollback, not on the grid"
        );
        assert_eq!(delta.scrolled_base, 0, "nothing scrolled before this drain");
    }

    #[test]
    fn mouse_modes_accumulate_and_report() {
        let mut t = term(4, 20, b"\x1b[?1002h\x1b[?1006h");
        let mouse = t.mouse();
        assert!(mouse.click && mouse.drag && mouse.sgr);
        assert!(
            t.drain()
                .events
                .iter()
                .any(|e| matches!(e, Event::Mouse(_)))
        );

        t.feed(b"\x1b[?1002l\x1b[?1006l");
        assert!(!t.mouse().enabled());
    }

    #[test]
    fn cursor_position_report_is_answered() {
        let mut t = term(4, 20, b"\x1b[3;5H\x1b[6n");
        assert!(
            t.drain()
                .events
                .contains(&Event::Reply(b"\x1b[3;5R".to_vec()))
        );
    }

    #[test]
    fn status_report_is_answered() {
        let mut t = term(4, 20, b"\x1b[5n");
        assert!(
            t.drain()
                .events
                .contains(&Event::Reply(b"\x1b[0n".to_vec()))
        );
    }

    /// The terminator has to survive the trip to Lisp: a client that queried with BEL
    /// will not recognise an ST-terminated answer, and vice versa.
    #[test]
    fn osc_terminator_travels_with_the_event() {
        let mut t = term(4, 20, b"\x1b]11;?\x07\x1b]11;?\x1b\\");
        assert_eq!(
            t.drain().events,
            vec![
                Event::Osc(11, vec!["?".into()], true),
                Event::Osc(11, vec!["?".into()], false),
            ]
        );
    }

    #[test]
    fn osc_reply_echoes_the_terminator_it_was_asked_with() {
        assert_eq!(
            osc_reply(11, "rgb:0000/0000/0000", true).unwrap(),
            b"\x1b]11;rgb:0000/0000/0000\x07"
        );
        assert_eq!(
            osc_reply(11, "rgb:ffff/ffff/ffff", false).unwrap(),
            b"\x1b]11;rgb:ffff/ffff/ffff\x1b\\"
        );
    }

    /// A colour name can arrive from the child in a set request and come straight back
    /// out in the echo, so the payload is not ours to trust.
    #[test]
    fn osc_reply_refuses_a_payload_that_could_close_the_sequence() {
        assert_eq!(osc_reply(11, "red\x07\x1b]0;pwned", true), None);
        assert_eq!(osc_reply(11, "red\x1b\\", false), None);
        assert_eq!(osc_reply(11, "red\x7f", true), None);
    }

    #[test]
    fn erase_display_clears_below() {
        let mut t = term(3, 8, b"aaa\r\nbbb\r\nccc");
        t.feed(b"\x1b[2;1H\x1b[J");
        assert_eq!(text(&t, 0), "aaa");
        assert_eq!(text(&t, 1), "");
        assert_eq!(text(&t, 2), "");
    }

    #[test]
    fn erase_scrollback_is_flagged_as_an_event_and_leaves_the_screen_alone() {
        // Unlike `CSI 2 J`, real xterm's `3 J` never touches the visible screen — only
        // the scrollback, which the grid does not hold, so it does nothing at all here.
        let mut t = term(3, 8, b"aaa\r\nbbb\r\nccc");
        t.drain();
        t.feed(b"\x1b[3J");
        let delta = t.drain();
        assert_eq!(delta.events, vec![Event::EraseScrollback]);
        assert!(delta.rows.is_empty(), "nothing on the grid changed");
        assert_eq!(text(&t, 0), "aaa");
        assert_eq!(text(&t, 1), "bbb");
        assert_eq!(text(&t, 2), "ccc");
    }

    #[test]
    fn a_partial_erase_raises_neither_clearing_event() {
        // `0 J` and `1 J` are a child rewriting part of a screen it is still drawing on,
        // not finishing with one: no scrollback goes, and no viewport moves.
        let mut t = term(3, 8, b"aaa\r\nbbb\r\nccc");
        t.drain();
        t.feed(b"\x1b[0J\x1b[1J");
        assert!(t.drain().events.is_empty());
    }

    #[test]
    fn clearing_the_display_asks_emacs_to_show_the_blank_screen() {
        // The rows are archived rather than lost, so nothing scrolls out of view on its
        // own: `2 J` looks like nothing happened unless Emacs moves the window, and this
        // event is what tells it to.
        let mut t = term(3, 8, b"aaa\r\nbbb\r\nccc");
        t.drain();
        t.feed(b"\x1b[2J");
        assert_eq!(t.drain().events, vec![Event::DisplayCleared]);
    }

    #[test]
    fn a_reset_clears_the_display_like_any_other() {
        let mut t = term(3, 8, b"aaa\r\nbbb\r\nccc");
        t.drain();
        t.feed(b"\x1bc");
        assert!(t.drain().events.contains(&Event::DisplayCleared));
    }

    #[test]
    fn the_alt_screen_never_reports_a_cleared_display() {
        // It archives nothing and is pinned to the top of the window already, so there is
        // no transcript for a window to scroll away from.
        let mut t = term(3, 8, b"aaa\r\nbbb");
        t.feed(b"\x1b[?1049h");
        t.drain();
        t.feed(b"\x1b[2J");
        assert!(t.drain().events.is_empty());
    }

    #[test]
    fn clearing_to_the_prompt_keeps_the_prompt_and_drops_what_is_above_it() {
        let mut t = term(4, 8, b"one\r\ntwo\r\n\x1b]133;A\x1b\\$ ls");
        t.drain();
        assert_eq!(t.clear_to_prompt(), 2);
        assert_eq!(text(&t, 0), "$ ls");
        assert_eq!(text(&t, 1), "");
        assert_eq!(t.screen().cursor.row, 0, "the cursor rides up with its row");
    }

    #[test]
    fn clearing_to_the_prompt_falls_back_to_the_cursor_row() {
        // No OSC 133 to go on: whatever the child is on now is the line being looked at.
        let mut t = term(4, 8, b"one\r\ntwo\r\nthree");
        t.drain();
        assert_eq!(t.clear_to_prompt(), 2);
        assert_eq!(text(&t, 0), "three");
    }

    #[test]
    fn clearing_to_the_prompt_twice_still_knows_where_the_prompt_is() {
        // The mark is absolute, and rows removed this way are discarded rather than
        // archived, so the count they are absolute against does not move: the anchor has
        // to come down instead, or the second call cuts at the cursor and eats the prompt.
        let mut t = term(4, 8, b"one\r\ntwo\r\n\x1b]133;A\x1b\\$ ls");
        t.drain();
        t.clear_to_prompt();
        t.feed(b"\r\nout");
        t.drain();
        assert_eq!(t.clear_to_prompt(), 0, "the prompt is already on row 0");
        assert_eq!(text(&t, 0), "$ ls");
        assert_eq!(text(&t, 1), "out");
    }

    #[test]
    fn removing_rows_brings_the_prompt_mark_down_with_them() {
        // `cooked-delete-output' removes a finished command's rows, which sit above the
        // prompt. The mark is absolute and these rows are discarded rather than archived,
        // so nothing else moves it: left alone it names a row past the cursor, fails
        // `clear_to_prompt's own sanity filter, and silently falls back to cutting at the
        // cursor -- eating the first line of a two-line prompt.
        let mut t = term(6, 8, b"out1\r\nout2\r\n\x1b]133;A\x1b\\user\r\n$ ");
        t.drain();
        // The two output rows above the prompt.
        t.remove_rows(0, 2);
        assert_eq!(text(&t, 0), "user");
        assert_eq!(text(&t, 1), "$");
        // The prompt is two rows tall and now starts at row 0, so there is nothing above
        // it left to clear. Without the rebase this cuts one row, taking `user' with it.
        assert_eq!(t.clear_to_prompt(), 0);
        assert_eq!(text(&t, 0), "user", "the prompt's first line must survive");
        assert_eq!(text(&t, 1), "$");
    }

    #[test]
    fn removing_the_prompts_own_row_clamps_the_mark_rather_than_losing_it() {
        let mut t = term(6, 8, b"out\r\n\x1b]133;A\x1b\\$ ls");
        t.drain();
        // Takes the output row and the prompt row with it.
        t.remove_rows(0, 2);
        // The mark clamps to the row that closed the gap, exactly as the cursor does, so
        // it stays a row on the grid rather than one past the end of it.
        assert_eq!(t.clear_to_prompt(), 0);
    }

    #[test]
    fn removing_rows_below_the_prompt_leaves_the_mark_where_it_is() {
        let mut t = term(6, 8, b"\x1b]133;A\x1b\\$ ls\r\nout1\r\nout2\r\ntail");
        t.drain();
        t.remove_rows(2, 1);
        assert_eq!(text(&t, 0), "$ ls");
        assert_eq!(text(&t, 1), "out1");
        assert_eq!(text(&t, 2), "tail");
        assert_eq!(t.clear_to_prompt(), 0, "the prompt is still on row 0");
    }

    #[test]
    fn removing_alt_screen_rows_does_not_move_the_primarys_prompt_mark() {
        let mut t = term(6, 8, b"out\r\n\x1b]133;A\x1b\\$ ls");
        t.drain();
        t.feed(b"\x1b[?1049h\x1b[1;1Haaa\r\nbbb");
        t.drain();
        t.remove_rows(0, 1);
        t.feed(b"\x1b[?1049l");
        t.drain();
        // The primary's rows never moved, so the mark must still name row 1.
        assert_eq!(t.clear_to_prompt(), 1);
        assert_eq!(text(&t, 0), "$ ls");
    }

    #[test]
    fn leaving_the_alt_screen_restores_the_cursor_the_primary_saved() {
        // `save_restore' acts on whichever screen is showing, so the restore has to run
        // after the switch back. Run before it, it reads the alt screen's saved cursor
        // and leaves the primary's -- the one `1049h' saved -- untouched.
        // The saved position has to be one something later moves, or a restore that never
        // ran is indistinguishable from one that did. A rewrap is that something: it is
        // the one thing which relocates the primary's cursor while the alt screen is up.
        // So the line here is wrapped, and the resize below re-chunks it.
        let mut t = term(6, 4, b"aaaabb");
        assert_eq!((t.screen().cursor.row, t.screen().cursor.col), (1, 2));
        t.feed(b"\x1b[?1049h");
        t.feed(b"\x1b[1;1Hframe");
        // Widening rejoins the two rows into one, putting the primary's cursor at (0, 6).
        t.resize(6, 8);
        t.feed(b"\x1b[?1049l");
        assert_eq!(
            (t.screen().cursor.row, t.screen().cursor.col),
            (1, 2),
            "the primary's saved cursor is the one 1049 restores"
        );
    }

    #[test]
    fn clearing_to_the_prompt_leaves_the_alt_screen_alone() {
        let mut t = term(3, 8, b"aaa");
        t.feed(b"\x1b[?1049h\x1b[2;1Hbbb");
        t.drain();
        assert_eq!(t.clear_to_prompt(), 0);
        assert_eq!(text(&t, 1), "bbb");
    }

    #[test]
    fn dec_graphics_draws_boxes() {
        let t = term(2, 8, b"\x1b(0lqk\x1b(B");
        assert_eq!(text(&t, 0), "┌─┐");
    }

    #[test]
    fn scroll_region_then_linefeed_stays_off_scrollback() {
        let mut t = term(4, 8, b"a\r\nb\r\nc\r\nd");
        t.drain();
        t.feed(b"\x1b[2;3r\x1b[3;1H\n");
        assert!(t.drain().scrolled.is_empty());
    }

    #[test]
    fn application_cursor_keys_are_tracked() {
        // ncurses sends this via smkx; without it, arrow keys reach the app in the
        // wrong encoding and simply do nothing.
        let mut t = term(4, 20, b"\x1b[?1h");
        assert!(t.app_cursor());
        assert!(t.drain().app_cursor);

        t.feed(b"\x1b[?1l");
        assert!(!t.app_cursor());
        assert!(!t.drain().app_cursor);
    }

    #[test]
    fn modify_other_keys_is_negotiated() {
        let mut t = term(4, 20, b"");
        assert_eq!(
            t.keys(),
            KeyEncoding::Legacy,
            "nothing is on until the child asks"
        );

        t.feed(b"\x1b[>4;2m");
        assert_eq!(t.keys(), KeyEncoding::ModifyOtherKeys);
        assert_eq!(t.drain().keys, KeyEncoding::ModifyOtherKeys);

        // Level 1 does not cover Return and friends, so it is not enough for us.
        t.feed(b"\x1b[>4;1m");
        assert_eq!(t.keys(), KeyEncoding::Legacy);

        t.feed(b"\x1b[>4;2m\x1b[>4m");
        assert_eq!(
            t.keys(),
            KeyEncoding::Legacy,
            "a bare reset turns it back off"
        );
    }

    #[test]
    fn kitty_keyboard_flags_stack() {
        let mut t = term(4, 20, b"\x1b[>1u");
        assert_eq!(t.keys(), KeyEncoding::Kitty);

        t.feed(b"\x1b[>0u");
        assert_eq!(
            t.keys(),
            KeyEncoding::Legacy,
            "the pushed level is what counts"
        );

        t.feed(b"\x1b[<u");
        assert_eq!(
            t.keys(),
            KeyEncoding::Kitty,
            "popping restores what was underneath"
        );

        t.feed(b"\x1b[=0u");
        assert_eq!(
            t.keys(),
            KeyEncoding::Legacy,
            "set replaces the top of the stack"
        );
    }

    #[test]
    fn a_kitty_query_is_answered() {
        // A child that probes and hears nothing back may sit there waiting.
        let mut t = term(4, 20, b"\x1b[>5u\x1b[?u");
        assert!(
            t.drain()
                .events
                .contains(&Event::Reply(b"\x1b[?5u".to_vec()))
        );
    }

    #[test]
    fn reset_clears_negotiated_keyboard_modes() {
        let mut t = term(4, 20, b"\x1b[>4;2m\x1b[>1u");
        assert_eq!(t.keys(), KeyEncoding::Kitty);
        t.feed(b"\x1bc");
        assert_eq!(t.keys(), KeyEncoding::Legacy);
    }

    /// Queried, never announced: the state is read as a submission is framed, which is
    /// later — and so more accurate — than any drain that preceded it.
    #[test]
    fn bracketed_paste_toggles() {
        let mut t = term(2, 8, b"\x1b[?2004h");
        assert!(t.bracketed_paste());
        assert!(t.drain().events.is_empty());
        t.feed(b"\x1b[?2004l");
        assert!(!t.bracketed_paste());
    }

    #[test]
    fn trailing_text_finds_a_password_prompt() {
        let t = term(4, 30, b"Warming up\r\nPassword: ");
        assert_eq!(t.trailing_text().as_deref(), Some("Password:"));
    }

    #[test]
    fn damage_covers_only_touched_rows() {
        let mut t = term(4, 8, b"a\r\nb");
        t.drain();
        t.feed(b"\x1b[1;1Hz");
        let rows = t.drain().rows;
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].0, 0);
    }

    #[test]
    fn resize_preserves_the_tail() {
        let mut t = term(3, 10, b"one\r\ntwo\r\nthree");
        t.drain();
        t.resize(2, 10);
        let delta = t.drain();
        assert_eq!(delta.scrolled.len(), 1);
        assert_eq!(runs_text(&delta.scrolled[0]), "one");
        assert_eq!(text(&t, 0), "two");
    }

    #[test]
    fn box_drawing_bytes_produce_glyphs_in_the_drained_delta() {
        let mut t = term(2, 10, "\u{250C}\u{2500}\u{2500}\u{2510}".as_bytes());
        let delta = t.drain();
        let (_, runs) = delta
            .rows
            .iter()
            .find(|(i, _)| *i == 0)
            .expect("row 0 is damaged");
        assert_eq!(runs.len(), 1);
        let glyphs = runs[0].glyphs.as_ref().expect("box-glyph run");
        assert_eq!(glyphs.len(), 4, "one descriptor per character");
        assert_eq!(runs[0].text, "\u{250C}\u{2500}\u{2500}\u{2510}");
    }

    #[test]
    fn diagonal_and_stub_bytes_also_produce_glyphs() {
        let mut t = term(2, 10, "\u{2571}\u{2572}\u{2573}\u{2574}".as_bytes());
        let delta = t.drain();
        let (_, runs) = delta
            .rows
            .iter()
            .find(|(i, _)| *i == 0)
            .expect("row 0 is damaged");
        assert_eq!(runs.len(), 1);
        let glyphs = runs[0].glyphs.as_ref().expect("box-glyph run");
        assert_eq!(glyphs.len(), 4);
        assert!(glyphs[0].is_diagonal());
        assert!(
            !glyphs[3].is_diagonal(),
            "the stub is edge-based, not a diagonal"
        );
    }

    /// The alt screen produces no history of its own, but the primary's rows are still
    /// history — a resize while a full-screen program is up must not discard them.
    #[test]
    fn resize_on_the_alt_screen_still_archives_primary_rows() {
        let mut t = term(3, 10, b"one\r\ntwo\r\nthree");
        t.feed(b"\x1b[?1049h");
        t.drain();

        t.resize(2, 10);
        let delta = t.drain();

        assert_eq!(delta.scrolled.len(), 1, "primary history lost during alt");
        assert_eq!(runs_text(&delta.scrolled[0]), "one");
    }

    /// `clear` and the shell's `C-l` both end up here, and the screen they wipe is
    /// transcript Emacs is holding — the grid does not get to drop it on their behalf.
    #[test]
    fn clearing_the_display_keeps_the_screen_as_history() {
        let mut t = term(4, 10, b"one\r\ntwo");
        t.drain();

        t.feed(b"\x1b[2J");
        let delta = t.drain();

        assert_eq!(delta.scrolled.len(), 2);
        assert_eq!(runs_text(&delta.scrolled[0]), "one");
        assert_eq!(runs_text(&delta.scrolled[1]), "two");
        assert_eq!(text(&t, 0), "");
    }

    #[test]
    fn clearing_the_alt_screen_archives_nothing() {
        let mut t = term(4, 10, b"\x1b[?1049hframe");
        t.drain();

        t.feed(b"\x1b[2J");

        assert!(
            t.drain().scrolled.is_empty(),
            "the alt screen has no history to keep"
        );
    }

    #[test]
    fn a_partial_erase_is_not_a_finished_screen() {
        let mut t = term(4, 10, b"one\r\ntwo");
        t.drain();

        t.feed(b"\x1b[J");

        assert!(
            t.drain().scrolled.is_empty(),
            "a partial erase is a redraw, not a screen being finished with"
        );
    }

    /// The primary is rewrapped even while a full-screen program is up, because its rows
    /// are the transcript that program will hand back on exit.
    #[test]
    fn narrowing_mid_alt_rewraps_the_primary_underneath() {
        let mut t = term(4, 10, b"abcdefghijklmno");
        t.feed(b"\x1b[?1049h");
        t.drain();

        t.resize(4, 5);
        t.feed(b"\x1b[?1049l");
        let delta = t.drain();

        assert!(delta.scrolled.is_empty());
        assert_eq!(text(&t, 0), "abcde");
        assert_eq!(text(&t, 1), "fghij");
        assert_eq!(text(&t, 2), "klmno");
    }

    #[test]
    fn backlog_counts_pending_events_as_well_as_scrollback() {
        let mut t = term(4, 10, b"");
        assert_eq!(t.backlog(), 0);

        t.feed(b"\x1b]0;a\x07\x1b]0;b\x07\x1b]0;c\x07");
        assert_eq!(
            t.backlog(),
            3,
            "OSC-only output scrolls nothing, so a scrollback-only measure misses it"
        );

        t.drain();
        assert_eq!(t.backlog(), 0, "draining clears the measure");
    }
}
