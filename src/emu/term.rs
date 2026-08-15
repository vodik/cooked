//! The VT parser front end: turns a byte stream into grid mutations and [`Event`]s.
//!
//! Scrollback deliberately lives in the Emacs buffer, not here. Rows that fall off the
//! top of the primary screen are handed over once, in [`Delta::scrolled`], and forgotten.

use super::cell::{Attrs, Color, Row, Run, Style};
use super::screen::{Cursor, Erase, Screen};
use std::collections::VecDeque;
use vte::{Params, Parser, Perform};

/// Something the Lisp side must react to, beyond redrawing cells.
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
    PromptStart,
    /// OSC 133;B — user input begins; this is where comint takes over.
    PromptEnd,
    /// OSC 133;C — the command is running and owns the output region.
    CommandStart,
    /// OSC 133;D — the command finished, with its exit status when reported.
    CommandEnd(Option<i32>),
    AltScreen(bool),
    BracketedPaste(bool),
    Mouse(Mouse),
    /// Bytes the terminal owes the child (device attributes, cursor reports).
    Reply(Vec<u8>),
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
    pub rows: Vec<(usize, Vec<Run>)>,
    pub cursor: Cursor,
    pub cursor_visible: bool,
    pub alt: bool,
    /// DECCKM: cursor keys must be sent as SS3 (`ESC O A`), not CSI (`ESC [ A`).
    /// ncurses turns this on via `smkx`, and terminfo's `kcuu1` assumes it.
    pub app_cursor: bool,
    /// How to spell modified Return, Tab, Escape and Backspace for this child.
    pub keys: KeyEncoding,
    pub events: Vec<Event>,
}

/// Backlog at which the reader stops pulling from the pty, letting the child block.
pub const BACKLOG_HIGH_WATER: usize = 8_000;

/// Largest OSC payload forwarded to Lisp, in bytes. Well past any real title or
/// hyperlink, and short of letting a single escape sequence allocate without bound.
pub const OSC_PAYLOAD_LIMIT: usize = 1 << 20;

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

    pub fn screen(&self) -> &Screen {
        self.state.screen()
    }

    pub fn mouse(&self) -> Mouse {
        self.state.mouse
    }

    pub fn bracketed_paste(&self) -> bool {
        self.state.bracketed_paste
    }

    pub fn app_cursor(&self) -> bool {
        self.state.app_cursor
    }

    /// How the child wants modified Return, Tab, Escape and Backspace spelled.
    pub fn keys(&self) -> KeyEncoding {
        self.state.key_encoding()
    }

    /// Scrolled-off lines waiting for Emacs to collect them.
    pub fn backlog(&self) -> usize {
        self.state.pending_scrollback.len()
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
    events: Vec<Event>,
    cursor_visible: bool,
    bracketed_paste: bool,
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
}

impl State {
    fn new(rows: usize, cols: usize) -> Self {
        Self {
            primary: Screen::new(rows, cols),
            alt: Screen::new(rows, cols),
            on_alt: false,
            pen: Style::default(),
            pending_scrollback: VecDeque::new(),
            events: Vec::new(),
            cursor_visible: true,
            bracketed_paste: false,
            mouse: Mouse::default(),
            origin_mode: false,
            dec_graphics: false,
            app_cursor: false,
            app_keypad: false,
            modify_other_keys: 0,
            kitty_keys: Vec::new(),
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

    /// Rows leaving the primary screen become buffer text; on the alt screen they vanish.
    ///
    /// Growth is bounded by backpressure rather than by discarding: the reader stops
    /// reading once [`Term::backlog`] is high, the pty's own buffer fills, and the
    /// child blocks in `write` exactly as it would against a slow terminal. Dropping
    /// would be lossy, and losing the middle of a build log is worse than waiting.
    fn evicted(&mut self, rows: Vec<Row>) {
        if self.on_alt {
            return;
        }
        // Reduced to runs here rather than at drain time: a Row owns a cell for every
        // column, so retaining thousands of them keeps megabytes of mostly-blank grid
        // alive. Runs are trimmed to content, and the work has to happen regardless.
        self.pending_scrollback
            .extend(rows.iter().map(|row| Scrolled {
                runs: row.runs(),
                wrapped: row.wrapped,
            }));
    }

    fn linefeed(&mut self) {
        let evicted = self.screen_mut().linefeed();
        self.evicted(evicted);
    }

    fn resize(&mut self, rows: usize, cols: usize) {
        let evicted = self.primary.resize(rows, cols);
        self.alt.resize(rows, cols);
        self.evicted(evicted);
    }

    fn drain(&mut self) -> Delta {
        let damaged = self.screen_mut().drain_damage();
        let scrolled = Vec::from(std::mem::take(&mut self.pending_scrollback));
        let events = std::mem::take(&mut self.events);
        let (cursor_visible, alt, app_cursor) = (self.cursor_visible, self.on_alt, self.app_cursor);
        let keys = self.key_encoding();
        let screen = self.screen();
        Delta {
            scrolled,
            rows: damaged
                .into_iter()
                .filter_map(|i| screen.row(i).map(|r| (i, r.runs())))
                .collect(),
            cursor: screen.cursor,
            cursor_visible,
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
            self.alt.erase_display(Erase::All);
            self.alt.goto(0, 0);
        }
        self.screen_mut().touch_all();
        self.events.push(Event::AltScreen(on));
    }

    fn dec_mode(&mut self, mode: u16, on: bool) {
        match mode {
            1 => self.app_cursor = on,
            66 => self.app_keypad = on,
            6 => {
                self.origin_mode = on;
                self.screen_mut().goto(0, 0);
            }
            7 => {}
            25 => self.cursor_visible = on,
            1000 => self.mouse.click = on,
            1002 => (self.mouse.click, self.mouse.drag) = (on, on),
            1003 => (self.mouse.click, self.mouse.motion) = (on, on),
            1006 => self.mouse.sgr = on,
            47 | 1047 => self.set_alt(on),
            1048 => self.save_restore(on),
            1049 => {
                self.save_restore(on);
                self.set_alt(on);
            }
            2004 => {
                self.bracketed_paste = on;
                self.events.push(Event::BracketedPaste(on));
            }
            _ => return,
        }
        if matches!(mode, 1000 | 1002 | 1003 | 1006) {
            self.events.push(Event::Mouse(self.mouse));
        }
    }

    fn save_restore(&mut self, save: bool) {
        let screen = self.screen_mut();
        match save {
            true => screen.saved = Some(screen.cursor),
            false => {
                if let Some(cursor) = screen.saved.take() {
                    screen.goto(cursor.row, cursor.col);
                }
            }
        }
    }

    fn semantic(&mut self, params: &[&[u8]]) {
        let Some(kind) = params.get(1).and_then(|p| p.first()) else {
            return;
        };
        self.events.push(match kind {
            b'A' => Event::PromptStart,
            b'B' => Event::PromptEnd,
            b'C' => Event::CommandStart,
            b'D' => Event::CommandEnd(
                params
                    .get(2)
                    .and_then(|p| std::str::from_utf8(p).ok())
                    .and_then(|s| s.parse().ok()),
            ),
            _ => return,
        });
    }

    fn sgr(&mut self, params: &Params) {
        if params.is_empty() {
            self.pen = Style::default();
            return;
        }
        let mut iter = params.iter();
        while let Some(param) = iter.next() {
            let Some(&code) = param.first() else { continue };
            match code {
                0 => self.pen = Style::default(),
                1 => self.pen.attrs |= Attrs::BOLD,
                2 => self.pen.attrs |= Attrs::FAINT,
                3 => self.pen.attrs |= Attrs::ITALIC,
                4 => self.pen.attrs |= Attrs::UNDERLINE,
                5 | 6 => self.pen.attrs |= Attrs::BLINK,
                7 => self.pen.attrs |= Attrs::REVERSE,
                8 => self.pen.attrs |= Attrs::CONCEAL,
                9 => self.pen.attrs |= Attrs::STRIKE,
                21 | 22 => self.pen.attrs.remove(Attrs::BOLD | Attrs::FAINT),
                23 => self.pen.attrs.remove(Attrs::ITALIC),
                24 => self.pen.attrs.remove(Attrs::UNDERLINE),
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
        let evicted = self.screen_mut().write(c, pen);
        self.evicted(evicted);
    }

    fn execute(&mut self, byte: u8) {
        match byte {
            0x07 => self.events.push(Event::Bell),
            0x08 => self.screen_mut().backspace(),
            0x09 => self.screen_mut().tab(1),
            0x0A..=0x0C => self.linefeed(),
            0x0D => self.screen_mut().carriage_return(),
            0x0E => self.dec_graphics = true,
            0x0F => self.dec_graphics = false,
            _ => {}
        }
    }

    fn csi_dispatch(&mut self, params: &Params, intermediates: &[u8], _ignore: bool, action: char) {
        let private = intermediates.first().copied();
        match (private, action) {
            (Some(b'?'), 'h' | 'l') => {
                let on = action == 'h';
                for mode in params.iter().filter_map(|p| p.first().copied()) {
                    self.dec_mode(mode, on);
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
                if let Some(how) = Erase::from_param(arg(params, 0, 0) as u16) {
                    self.screen_mut().erase_display(how);
                }
            }
            (None, 'K') => {
                if let Some(how) = Erase::from_param(arg(params, 0, 0) as u16) {
                    self.screen_mut().erase_line(how);
                }
            }
            (None, 'L') => self.screen_mut().insert_lines(arg(params, 0, 1)),
            (None, 'M') => self.screen_mut().delete_lines(arg(params, 0, 1)),
            (None, 'P') => self.screen_mut().delete_chars(arg(params, 0, 1)),
            (None, 'S') => {
                let n = arg(params, 0, 1);
                let evicted = self.screen_mut().scroll_up(n);
                self.evicted(evicted);
            }
            (None, 'T') => self.screen_mut().scroll_down(arg(params, 0, 1)),
            (None, 'X') => self.screen_mut().erase_chars(arg(params, 0, 1)),
            (None, '@') => self.screen_mut().insert_chars(arg(params, 0, 1)),
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
            // Kitty keyboard protocol: push, pop, and set.
            (Some(b'>'), 'u') => self.kitty_keys.push(arg(params, 0, 0) as u8),
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
            (None, 'c') => self.events.push(Event::Reply(b"\x1b[?62;c".to_vec())),
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
            (None, b'M') => self.screen_mut().reverse_index(),
            (None, b'H') => self.screen_mut().set_tab(),
            (None, b'7') => self.save_restore(true),
            (None, b'8') => self.save_restore(false),
            (None, b'c') => {
                self.pen = Style::default();
                self.screen_mut().reset_region();
                self.screen_mut().erase_display(Erase::All);
                self.screen_mut().goto(0, 0);
                // RIS means everything the child negotiated is off, keyboard included.
                self.modify_other_keys = 0;
                self.kitty_keys.clear();
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
        assert_eq!(
            events,
            vec![
                Event::PromptStart,
                Event::PromptEnd,
                Event::CommandStart,
                Event::CommandEnd(Some(3)),
            ]
        );
    }

    #[test]
    fn osc_133_d_without_a_status() {
        let mut t = term(4, 20, b"\x1b]133;D\x07");
        assert_eq!(t.drain().events, vec![Event::CommandEnd(None)]);
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
        assert_eq!(t.drain().events, vec![Event::PromptStart]);
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

    #[test]
    fn bracketed_paste_toggles() {
        let mut t = term(2, 8, b"\x1b[?2004h");
        assert!(t.bracketed_paste());
        assert!(t.drain().events.contains(&Event::BracketedPaste(true)));
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
}
