//! cooked — a terminal emulator core for Emacs that knows when to get out of the way.
//!
//! Lisp entry points live here; everything below is plain Rust and unit-testable without
//! an Emacs in the loop.

pub mod compat;
pub mod emu;
pub mod env;
pub mod pty;
pub mod session;

use emu::{BoxGlyph, Color, Event, Run, Style};
use env::{Env, Error, Result, Runtime, Value};
use pty::Winsize;
use session::{Session, Update};

/// Emacs calls this once when the module is loaded.
///
/// Returns 0 on success. A non-zero return surfaces as `module-init-failed` with the
/// value attached, so 1 and 2 distinguish "this Emacs' runtime predates our mirror of it"
/// from "its environment does" — worth telling apart, since the fix is the same but the
/// diagnosis is not.
///
/// # Safety
/// `runtime` must be the pointer Emacs passes to `emacs_module_init`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn emacs_module_init(runtime: *mut Runtime) -> std::ffi::c_int {
    let Some(runtime) = (unsafe { runtime.as_mut() }) else {
        return 1;
    };
    // Before touching any slot: our `Raw` hardcodes the Emacs 28 layout, and calling
    // through a pointer past the end of a shorter struct is how this crashes rather than
    // complains.
    if !runtime.compatible() {
        return 1;
    }
    let env = unsafe { runtime.env() };
    if env.abi_size() < Env::REQUIRED_ABI {
        if env.abi_size() >= Env::MINIMAL_ABI {
            env.signal(
                "error",
                "cooked requires Emacs 28 or newer (module ABI too old)",
            );
        }
        return 2;
    }

    let registered = [
        env.defun("cooked--spawn", 5..=8, DOC_SPAWN, spawn),
        env.defun("cooked--drain", 1..=2, DOC_DRAIN, drain),
        env.defun(
            "cooked--send",
            2..=2,
            "Write STRING to the pty of SESSION.",
            send,
        ),
        env.defun("cooked--reply-osc", 4..=4, DOC_REPLY_OSC, reply_osc),
        env.defun(
            "cooked--resize",
            3..=3,
            "Resize SESSION to ROWS by COLS.",
            resize,
        ),
        env.defun("cooked--mode", 1..=1, DOC_MODE, mode),
        env.defun("cooked--prompt-text", 1..=1, DOC_PROMPT, prompt_text),
        env.defun(
            "cooked--signal",
            2..=2,
            "Send signal NUMBER to SESSION's foreground group.",
            signal,
        ),
        env.defun("cooked--pid", 1..=1, "Process id of SESSION's child.", pid),
        env.defun(
            "cooked--live-p",
            1..=1,
            "Whether SESSION's child is still running.",
            live_p,
        ),
        env.defun(
            "cooked--bracketed-paste-p",
            1..=1,
            "Whether SESSION requested bracketed paste.",
            bracketed,
        ),
        env.defun("cooked--kill", 1..=1, DOC_KILL, kill),
    ];

    match registered
        .into_iter()
        .collect::<Result<Vec<_>>>()
        .and_then(|_| env::provide(&env, "cooked-core"))
    {
        Ok(()) => 0,
        Err(Error) => 1,
    }
}

const DOC_SPAWN: &str = "Spawn ARGV on a new pty and return a session handle.
Arguments are ARGV, ENV, ROWS, COLS, WAKE, optional DIRECTORY, optional
MIN-REDISPLAY-INTERVAL and optional BACKLOG-LIMIT. ENV is an alist of strings. WAKE is a
pipe process whose filter runs when output is pending. MIN-REDISPLAY-INTERVAL, in
milliseconds, floors how often a rapidly-rewriting child (a spinner, a progress meter)
triggers a redisplay; it defaults to 8 when omitted or nil. BACKLOG-LIMIT caps the items
awaiting collection before the child is left to block on its own writes; it defaults to
8000 when omitted or nil.";

const DOC_DRAIN: &str = "Collect everything that changed in SESSION since the last call.
Returns a plist with :scrolled, :rows, :cursor, :alt, :app-cursor, :keys, :mode, :events
and :exit.
With REJOIN non-nil (the default), a line the terminal wrapped is emitted as one
line rather than one per screen row.";

const DOC_REPLY_OSC: &str = "Answer an OSC query on SESSION with CODE, PAYLOAD and BELL.
Writes `ESC ] CODE ; PAYLOAD' terminated by BEL when BELL is non-nil and by ST
otherwise; pass the BELL-P the `osc' event carried, since a client that queried with
BEL will not recognise an ST-terminated answer. Signals if PAYLOAD contains control
characters, which could close the sequence early.";

const DOC_MODE: &str = "Line discipline of SESSION: `cooked', `raw' or `secret'.
`cooked' means Emacs should own the input region; `secret' means a password is being read.";

const DOC_PROMPT: &str = "Text of the last non-blank line written by SESSION's child.
Used as the minibuffer prompt when SESSION enters `secret' mode.";

const DOC_KILL: &str = "Tear SESSION's child down now and reap it.
Returns t if this call ended the session, nil if it had already ended. Safe to call
repeatedly. The child is sent SIGHUP, given a moment, then SIGKILL, so a process that
ignores SIGHUP cannot outlive its buffer. Afterwards the handle is inert and garbage
collecting it costs nothing.";

fn handle<'e>(env: &Env<'e>, value: Value) -> Result<&'e Session> {
    env.get_user_ptr::<Session>(value)
}

fn strings(env: &Env, list: Value) -> Result<Vec<String>> {
    let len = env.from_lisp::<usize>(env.call("length", &[list])?)?;
    (0..len)
        .map(|i| {
            let item = env.call("nth", &[env.into_lisp(i)?, list])?;
            env.from_lisp::<String>(item)
        })
        .collect()
}

fn pairs(env: &Env, alist: Value) -> Result<Vec<(String, String)>> {
    let len = env.from_lisp::<usize>(env.call("length", &[alist])?)?;
    (0..len)
        .map(|i| {
            let cell = env.call("nth", &[env.into_lisp(i)?, alist])?;
            Ok((
                env.from_lisp::<String>(env.call("car", &[cell])?)?,
                env.from_lisp::<String>(env.call("cdr", &[cell])?)?,
            ))
        })
        .collect()
}

fn io_error(env: &Env, e: std::io::Error) -> Error {
    env.signal("cooked-error", &e.to_string())
}

fn spawn(env: Env, args: &[Value]) -> Result<Value> {
    let argv = strings(&env, args[0])?;
    let vars = pairs(&env, args[1])?;
    let size = Winsize {
        rows: env.from_lisp::<u16>(args[2])?.max(1),
        cols: env.from_lisp::<u16>(args[3])?.max(1),
    };
    let wake = env.open_channel(args[4])?;
    let cwd = args
        .get(5)
        .copied()
        .map(|v| env.from_lisp::<Option<String>>(v))
        .transpose()?
        .flatten();
    let min_redisplay_interval_ms = args
        .get(6)
        .copied()
        .map(|v| env.from_lisp::<Option<i64>>(v))
        .transpose()?
        .flatten()
        .unwrap_or(8)
        .max(0) as u64;
    let backlog_limit = args
        .get(7)
        .copied()
        .map(|v| env.from_lisp::<Option<i64>>(v))
        .transpose()?
        .flatten()
        .unwrap_or(emu::BACKLOG_HIGH_WATER as i64)
        .max(1) as usize;

    let session = Session::spawn(
        &argv,
        &vars,
        size,
        cwd.as_ref().map(std::path::Path::new),
        wake,
        std::time::Duration::from_millis(min_redisplay_interval_ms),
        backlog_limit,
    )
    .map_err(|e| io_error(&env, e))?;
    env.user_ptr(session)
}

fn drain(env: Env, args: &[Value]) -> Result<Value> {
    let rejoin = args.get(1).is_none_or(|v| !env.is_nil(*v));
    let update = handle(&env, args[0])?.drain();
    update_to_lisp(&env, &update, rejoin)
}

fn send(env: Env, args: &[Value]) -> Result<Value> {
    let mut bytes = env.from_lisp::<Vec<u8>>(args[1])?;
    let sent = handle(&env, args[0]).map(|s| s.send(&bytes));
    // Zero unconditionally rather than only for secrets: at keystroke sizes it costs
    // nothing, and it means the password path needs no special case to be covered.
    // `write_volatile` because an ordinary write to a buffer about to be freed is
    // exactly the store a compiler is entitled to drop.
    for b in &mut bytes {
        unsafe { std::ptr::write_volatile(b, 0) };
    }
    std::sync::atomic::compiler_fence(std::sync::atomic::Ordering::SeqCst);
    sent?.map_err(|e| io_error(&env, e))?;
    Ok(env.nil())
}

fn reply_osc(env: Env, args: &[Value]) -> Result<Value> {
    let code = env.from_lisp::<u16>(args[1])?;
    let payload = env.from_lisp::<String>(args[2])?;
    let bell = !env.is_nil(args[3]);
    let Some(bytes) = emu::osc_reply(code, &payload, bell) else {
        return Err(env.signal(
            "error",
            "cooked: refusing to frame an OSC reply containing control characters",
        ));
    };
    handle(&env, args[0])?
        .send(&bytes)
        .map_err(|e| io_error(&env, e))?;
    Ok(env.nil())
}

fn resize(env: Env, args: &[Value]) -> Result<Value> {
    let size = Winsize {
        rows: env.from_lisp::<u16>(args[1])?.max(1),
        cols: env.from_lisp::<u16>(args[2])?.max(1),
    };
    handle(&env, args[0])?
        .resize(size)
        .map_err(|e| io_error(&env, e))?;
    Ok(env.nil())
}

fn mode(env: Env, args: &[Value]) -> Result<Value> {
    env.intern(handle(&env, args[0])?.mode().as_str())
}

fn prompt_text(env: Env, args: &[Value]) -> Result<Value> {
    env.into_lisp(handle(&env, args[0])?.trailing_text())
}

fn signal(env: Env, args: &[Value]) -> Result<Value> {
    let sig = env.from_lisp::<i64>(args[1])? as i32;
    handle(&env, args[0])?
        .signal(sig)
        .map_err(|e| io_error(&env, e))?;
    Ok(env.nil())
}

fn pid(env: Env, args: &[Value]) -> Result<Value> {
    env.into_lisp(i64::from(handle(&env, args[0])?.pid().get()))
}

fn live_p(env: Env, args: &[Value]) -> Result<Value> {
    env.into_lisp(handle(&env, args[0])?.alive())
}

fn bracketed(env: Env, args: &[Value]) -> Result<Value> {
    env.into_lisp(handle(&env, args[0])?.bracketed_paste())
}

fn kill(env: Env, args: &[Value]) -> Result<Value> {
    env.into_lisp(handle(&env, args[0])?.shutdown())
}

fn keyword(env: &Env, name: &str) -> Result<Value> {
    env.intern(name)
}

/// `(:scrolled ROWS :rows ((INDEX . RUNS)...) :cursor (ROW COL VISIBLE) ...)`
fn update_to_lisp(env: &Env, update: &Update, rejoin: bool) -> Result<Value> {
    let scrolled = update.scrolled_rows(env, rejoin)?;
    let rows = update
        .delta
        .rows
        .iter()
        .map(|(index, runs)| {
            let runs = runs
                .iter()
                .map(|r| run_to_lisp(env, r))
                .collect::<Result<Vec<_>>>()?;
            env.cons(env.into_lisp(*index)?, env.list(&runs)?)
        })
        .collect::<Result<Vec<_>>>()?;
    let cursor = env.list(&[
        env.into_lisp(update.delta.cursor.row)?,
        env.into_lisp(update.delta.cursor.col)?,
        env.into_lisp(update.delta.cursor_visible)?,
    ])?;
    let events = update
        .delta
        .events
        .iter()
        .map(|e| event_to_lisp(env, e))
        .collect::<Result<Vec<_>>>()?;

    env.list(&[
        keyword(env, ":scrolled")?,
        scrolled,
        keyword(env, ":rows")?,
        env.list(&rows)?,
        keyword(env, ":cursor")?,
        cursor,
        keyword(env, ":alt")?,
        env.into_lisp(update.delta.alt)?,
        keyword(env, ":app-cursor")?,
        env.into_lisp(update.delta.app_cursor)?,
        keyword(env, ":keys")?,
        env.intern(update.delta.keys.as_str())?,
        keyword(env, ":mode")?,
        env.intern(update.mode.as_str())?,
        keyword(env, ":events")?,
        env.list(&events)?,
        keyword(env, ":exit")?,
        env.into_lisp(update.exit.map(i64::from))?,
    ])
}

impl Update {
    /// Scrollback as `(TEXT (START END FG BG ATTRS)...)`, offsets in characters.
    ///
    /// Assembled here rather than handed over run by run. Emacs pays for every
    /// `insert`, and a flood is tens of thousands of rows: one insert of one string
    /// plus spans only where styling exists beats N inserts and N property calls,
    /// and it keeps roughly a million cons cells from crossing the boundary.
    ///
    /// Deliberately does not carry `run.glyphs`: box-drawing UIs are overwhelmingly
    /// alt-screen programs, and `on_alt` already skips eviction into scrollback
    /// entirely (see `State::evicted`), so scrolled box-glyph content is rare enough
    /// that it isn't worth this path's cost discipline. It renders as plain styled
    /// text, exactly as before this feature existed.
    fn scrolled_rows(&self, env: &Env, rejoin: bool) -> Result<Value> {
        if self.delta.scrolled.is_empty() {
            return Ok(env.nil());
        }
        let mut text = String::new();
        let mut spans: Vec<Value> = Vec::new();
        let mut offset = 0usize;

        for line in &self.delta.scrolled {
            for run in &line.runs {
                let chars = run.text.chars().count();
                if run.style != Style::default() {
                    let Style { fg, bg, attrs } = run.style;
                    spans.push(env.list(&[
                        env.into_lisp(offset)?,
                        env.into_lisp(offset + chars)?,
                        color_to_lisp(env, fg)?,
                        color_to_lisp(env, bg)?,
                        env.into_lisp(u32::from(attrs.bits()))?,
                    ])?);
                }
                text.push_str(&run.text);
                offset += chars;
            }
            // A wrapped row is a continuation, so it joins the line above rather
            // than starting a new one.
            if !(rejoin && line.wrapped) {
                text.push('\n');
                offset += 1;
            }
        }

        let mut items = vec![env.into_lisp(text.as_str())?];
        items.extend(spans);
        env.list(&items)
    }
}

/// `(TEXT FG BG ATTRS GLYPHS)` — colors are nil, an index, or `(R G B)`; GLYPHS is nil
/// for a plain-text run or a list of raw `BoxGlyph` bit patterns, one per character in
/// TEXT, for a run of classified box-drawing/block-element glyphs.
fn run_to_lisp(env: &Env, run: &Run) -> Result<Value> {
    let Style { fg, bg, attrs } = run.style;
    env.list(&[
        env.into_lisp(run.text.as_str())?,
        color_to_lisp(env, fg)?,
        color_to_lisp(env, bg)?,
        env.into_lisp(u32::from(attrs.bits()))?,
        glyphs_to_lisp(env, run.glyphs.as_deref())?,
    ])
}

/// `nil`, or a list of raw `BoxGlyph` bit patterns, one per character. A dedicated
/// helper rather than a blanket conversion so this can take a borrowed slice —
/// `run_to_lisp` only borrows `run`, and cloning `Vec<BoxGlyph>` per drained row is
/// needless allocation on a path this codebase is otherwise careful about (see
/// `scrolled_rows`'s doc comment on avoiding exactly this class of cost).
fn glyphs_to_lisp(env: &Env, glyphs: Option<&[BoxGlyph]>) -> Result<Value> {
    match glyphs {
        None => Ok(env.nil()),
        Some(glyphs) => env.list(
            &glyphs
                .iter()
                .map(|g| env.into_lisp(u32::from(g.bits())))
                .collect::<Result<Vec<_>>>()?,
        ),
    }
}

fn color_to_lisp(env: &Env, color: Color) -> Result<Value> {
    match color {
        Color::Default => Ok(env.nil()),
        Color::Indexed(i) => env.into_lisp(i64::from(i)),
        Color::Rgb(r, g, b) => {
            let parts = [r, g, b]
                .map(i64::from)
                .map(|c| env.into_lisp(c))
                .into_iter()
                .collect::<Result<Vec<_>>>()?;
            env.list(&parts)
        }
    }
}

fn event_to_lisp(env: &Env, event: &Event) -> Result<Value> {
    let tagged = |name: &str, payload: Value| env.cons(env.intern(name)?, payload);
    match event {
        Event::Bell => env.list(&[env.intern("bell")?]),
        // (osc CODE BELL-P PART...) — Lisp decides what the code means. BELL-P is
        // opaque to the handler: it hands it back to `cooked--reply-osc' if it answers.
        Event::Osc(code, parts, bell) => {
            let mut items = vec![
                env.intern("osc")?,
                env.into_lisp(i64::from(*code))?,
                env.into_lisp(*bell)?,
            ];
            for part in parts {
                items.push(env.into_lisp(part.as_str())?);
            }
            env.list(&items)
        }
        Event::PromptStart => env.list(&[env.intern("prompt-start")?]),
        Event::PromptEnd => env.list(&[env.intern("prompt-end")?]),
        Event::CommandStart => env.list(&[env.intern("command-start")?]),
        Event::CommandEnd(code) => tagged("command-end", env.into_lisp(code.map(i64::from))?),
        Event::AltScreen(on) => tagged("alt-screen", env.into_lisp(*on)?),
        Event::BracketedPaste(on) => tagged("bracketed-paste", env.into_lisp(*on)?),
        // (mouse ENABLED SGR): the sender needs the encoding, not just the fact.
        Event::Mouse(m) => env.list(&[
            env.intern("mouse")?,
            env.into_lisp(m.enabled())?,
            env.into_lisp(m.sgr)?,
        ]),
        Event::Reply(bytes) => tagged("reply", env.into_lisp(bytes.as_slice())?),
    }
}
