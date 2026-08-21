//! cooked — a terminal emulator core for Emacs that knows when to get out of the way.
//!
//! Lisp entry points live here; everything below is plain Rust and unit-testable without
//! an Emacs in the loop.

pub mod compat;
pub mod emu;
pub mod env;
pub mod pty;
pub mod session;

use emu::{Anchor, CellMetrics, Color, Deco, Event, ImageData, Run, Style};
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
            3..=5,
            "Resize SESSION to ROWS by COLS, each cell CELL-WIDTH by CELL-HEIGHT pixels.\n\
             The cell size may be nil or omitted, which is what a terminal frame has to\n\
             say: it reaches the child as a zero `ws_xpixel'/`ws_ypixel', meaning \"not\n\
             reported\", and leaves image sizing in pixels with nothing to work from.",
            resize,
        ),
        env.defun(
            "cooked--forget-history",
            1..=1,
            "Tell SESSION that Emacs no longer holds any of its scrollback.

Call after discarding the buffer text above the live screen: the emulator tracks
how much of its top row's line already left for Emacs, so that a rewrap resumes
that line where the buffer actually wraps it.  Once the text is gone the top row
begins a line again, and saying so is what keeps the two ends agreeing.",
            forget_history,
        ),
        env.defun("cooked--redraw", 1..=1, DOC_REDRAW, redraw),
        env.defun(
            "cooked--remove-rows",
            3..=3,
            "Remove COUNT rows from SESSION's grid, starting at screen row FIRST.

Rows below close the gap and blanks come in at the bottom, exactly as if the
child had done it.  The emulator is the only thing that edits rows -- Emacs asks
and then renders the result on the next drain, rather than deleting buffer text
the grid still holds, which would leave the two ends disagreeing about what the
screen is.

The rows are discarded, not archived: they are a finished command's output being
deleted, and archiving would return them to the buffer as scrollback.",
            remove_rows,
        ),
        env.defun(
            "cooked--clear-to-prompt",
            1..=1,
            "Remove the rows above SESSION's current prompt, returning how many went.

The emulator's half of clearing the terminal.  Emacs deletes the scrollback,
which is its own buffer text; the rows still on the grid are the emulator's, and
which of them are above the prompt is a question only it can answer -- from the
last OSC 133;A mark, falling back to the cursor's row when the shell never said.

Returns 0 and does nothing on the alternate screen: that grid belongs to a
running program, not to a transcript.",
            clear_to_prompt,
        ),
        env.defun("cooked--prompt-text", 1..=1, DOC_PROMPT, prompt_text),
        env.defun(
            "cooked--signal",
            2..=2,
            "Send signal NUMBER to SESSION's foreground group.",
            signal,
        ),
        env.defun(
            "cooked--job-control",
            1..=1,
            "SESSION's job-control characters, as a plist.

Keys are :intr, :quit and :susp -- each the character code the tty currently
turns into a signal, or nil where the character is disabled -- and :isig, which
is non-nil while the line discipline still acts on them.  :eof is the
end-of-file character, which :isig says nothing about: ICANON decides whether
the line discipline acts on it, and a raw-mode program just reads the byte.  A terminal writes one
of these bytes rather than sending a signal, so honouring them is what makes
`stty intr ^X' work; with :isig nil the byte reaches the child verbatim, which
is what a program that cleared ISIG asked for.",
            job_control,
        ),
        env.defun("cooked--pid", 1..=1, "Process id of SESSION's child.", pid),
        env.defun(
            "cooked--foreground-pid",
            1..=1,
            "Process id of SESSION's foreground process group, or nil.

Not the same as `cooked--pid': that is the process cooked spawned, which is
usually a shell, while this is the program the user is actually looking at --
what the shell put in the foreground.  nil when the tty has no answer, which is
ordinary between jobs and once the session is over.",
            foreground_pid,
        ),
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
        env.defun(
            "cooked--focus-events-p",
            1..=1,
            "Whether SESSION asked to be told when the window gains or loses focus.",
            focus_events,
        ),
        env.defun(
            "cooked--alt-scroll-p",
            1..=1,
            "Whether a wheel notch on SESSION should be sent as cursor keys.",
            alt_scroll,
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
Returns a plist with :scrolled, :rows, :height, :used, :head, :cursor, :alt,
:app-cursor, :keys, :mode, :images, :events and :exit.
With REJOIN non-nil (the default), a line the terminal wrapped is emitted as one
line rather than one per screen row.

:height, :used and :head describe the grid's shape, so the buffer is shaped by what
the emulator has rather than by a second opinion of it: the grid's row count, how many
of those rows are occupied, and how many characters of screen row 0's logical line are
already in the buffer above the screen. The last is the seam — 0 unless the last row
handed to scrollback was a wrapped one that row 0 continues.

The fields are levels — the state as of this drain — and carry everything redisplay
needs. :events are occurrences, for what Emacs must react to that redisplay does not
cover. Nothing is sent both ways.

:images is neither, and is the one thing that must be consumed *before* :scrolled and
:rows are rendered: it carries resources those rows refer to by id. Each image crosses
once, however often the child sends or places it.";

const DOC_REPLY_OSC: &str = "Answer an OSC query on SESSION with CODE, PAYLOAD and BELL.
Writes `ESC ] CODE ; PAYLOAD' terminated by BEL when BELL is non-nil and by ST
otherwise; pass the BELL-P the `osc' event carried, since a client that queried with
BEL will not recognise an ST-terminated answer. Signals if PAYLOAD contains control
characters, which could close the sequence early.";

const DOC_REDRAW: &str = "Mark SESSION's whole screen damaged, so the next drain re-sends it.
For recovering from a redisplay that failed part-way: an ordinary drain only reports
what changed since the last one, so it cannot repair a buffer that is missing rows of
a drain that signalled halfway through applying them.";

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

/// Walk a proper list, handing each element to `f`.
///
/// `car`/`cdr` rather than `nth` per index: `nth` restarts at the head every time, which
/// makes reading a list off the boundary quadratic in its length. Nothing we are handed
/// is long enough today for that to matter, but the environment alist is the child's to
/// grow, and this is not the place to let it decide how much work we do.
fn each<T>(env: &Env, mut list: Value, mut f: impl FnMut(Value) -> Result<T>) -> Result<Vec<T>> {
    let mut out = Vec::new();
    while !env.is_nil(list) {
        out.push(f(env.call("car", &[list])?)?);
        list = env.call("cdr", &[list])?;
    }
    Ok(out)
}

fn strings(env: &Env, list: Value) -> Result<Vec<String>> {
    each(env, list, |item| env.from_lisp::<String>(item))
}

fn pairs(env: &Env, alist: Value) -> Result<Vec<(String, String)>> {
    each(env, alist, |cell| {
        Ok((
            env.from_lisp::<String>(env.call("car", &[cell])?)?,
            env.from_lisp::<String>(env.call("cdr", &[cell])?)?,
        ))
    })
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
        // Reported by the first resize rather than at spawn: the buffer usually has no
        // window yet here, so there is no font to measure.
        cell: CellMetrics::default(),
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
    let cell = |i: usize| -> Result<u16> {
        args.get(i)
            .copied()
            .map(|v| env.from_lisp::<Option<i64>>(v))
            .transpose()?
            .flatten()
            .map_or(Ok(0), |n| Ok(n.clamp(0, i64::from(u16::MAX)) as u16))
    };
    let size = Winsize {
        rows: env.from_lisp::<u16>(args[1])?.max(1),
        cols: env.from_lisp::<u16>(args[2])?.max(1),
        cell: CellMetrics {
            width: cell(3)?,
            height: cell(4)?,
        },
    };
    handle(&env, args[0])?
        .resize(size)
        .map_err(|e| io_error(&env, e))?;
    Ok(env.nil())
}

fn forget_history(env: Env, args: &[Value]) -> Result<Value> {
    handle(&env, args[0])?.forget_history();
    Ok(env.nil())
}

fn redraw(env: Env, args: &[Value]) -> Result<Value> {
    handle(&env, args[0])?.redraw();
    Ok(env.nil())
}

fn remove_rows(env: Env, args: &[Value]) -> Result<Value> {
    let first = env.from_lisp::<i64>(args[1])?.max(0) as usize;
    let count = env.from_lisp::<i64>(args[2])?.max(0) as usize;
    handle(&env, args[0])?.remove_rows(first, count);
    Ok(env.nil())
}

fn clear_to_prompt(env: Env, args: &[Value]) -> Result<Value> {
    let removed = handle(&env, args[0])?.clear_to_prompt();
    env.into_lisp(removed as i64)
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

fn job_control(env: Env, args: &[Value]) -> Result<Value> {
    let jc = handle(&env, args[0])?
        .job_control()
        .map_err(|e| io_error(&env, e))?;
    let ch = |env: &Env, c: Option<u8>| match c {
        Some(b) => env.into_lisp(i64::from(b)),
        None => Ok(env.nil()),
    };
    env.list(&[
        keyword(&env, ":intr")?,
        ch(&env, jc.intr)?,
        keyword(&env, ":quit")?,
        ch(&env, jc.quit)?,
        keyword(&env, ":susp")?,
        ch(&env, jc.susp)?,
        keyword(&env, ":eof")?,
        ch(&env, jc.eof)?,
        keyword(&env, ":isig")?,
        if jc.isig { env.intern("t")? } else { env.nil() },
    ])
}

fn pid(env: Env, args: &[Value]) -> Result<Value> {
    env.into_lisp(i64::from(handle(&env, args[0])?.pid().get()))
}

fn foreground_pid(env: Env, args: &[Value]) -> Result<Value> {
    // nil rather than an error: `tcgetpgrp' has nothing to report between a shell putting
    // one job down and the next taking over, and once the session is gone it can answer 0.
    // Neither is a fault the caller can do anything about, and both are ordinary.
    match handle(&env, args[0])?.foreground() {
        Ok(pid) => env.into_lisp(i64::from(pid.get())),
        Err(_) => Ok(env.intern("nil")?),
    }
}

fn live_p(env: Env, args: &[Value]) -> Result<Value> {
    env.into_lisp(handle(&env, args[0])?.alive())
}

fn bracketed(env: Env, args: &[Value]) -> Result<Value> {
    env.into_lisp(handle(&env, args[0])?.bracketed_paste())
}

fn focus_events(env: Env, args: &[Value]) -> Result<Value> {
    env.into_lisp(handle(&env, args[0])?.focus_events())
}

fn alt_scroll(env: Env, args: &[Value]) -> Result<Value> {
    env.into_lisp(handle(&env, args[0])?.alt_scroll())
}

fn kill(env: Env, args: &[Value]) -> Result<Value> {
    env.into_lisp(handle(&env, args[0])?.shutdown())
}

fn keyword(env: &Env, name: &str) -> Result<Value> {
    env.intern(name)
}

/// `(:scrolled ROWS :rows ((INDEX . RUNS)...) :height N :used N :head N
/// :cursor (ROW COL VISIBLE) ...)`
fn update_to_lisp(env: &Env, update: &Update, rejoin: bool) -> Result<Value> {
    // The scrollback is assembled first because the events are resolved against it: a
    // mark on a row that scrolled away during this very drain is spelled as an offset
    // into the text about to be inserted, which only exists once that text is built.
    let (scrolled, spans) = update.scrolled_rows(env, rejoin)?;
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
        env.intern(update.delta.cursor_shape.as_str())?,
    ])?;
    let events = update
        .delta
        .events
        .iter()
        .map(|e| event_to_lisp(env, e, update, &spans))
        .collect::<Result<Vec<_>>>()?;

    env.list(&[
        keyword(env, ":scrolled")?,
        scrolled,
        keyword(env, ":rows")?,
        env.list(&rows)?,
        keyword(env, ":height")?,
        env.into_lisp(update.delta.height)?,
        keyword(env, ":used")?,
        env.into_lisp(update.delta.used)?,
        keyword(env, ":head")?,
        env.into_lisp(update.delta.head)?,
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
        keyword(env, ":images")?,
        env.list(&images_to_lisp(env, &update.delta.images)?)?,
        keyword(env, ":events")?,
        env.list(&events)?,
        keyword(env, ":exit")?,
        env.into_lisp(update.exit.map(i64::from))?,
    ])
}

/// Where one scrolled row's text ended up in the assembled scrollback string: its start
/// offset in characters, and how many characters it contributed.
///
/// Per *row* rather than per line, so it stays right under `rejoin`, which appends a
/// wrapped row to the line above instead of starting a new one.
#[derive(Clone, Copy, Default)]
struct RowSpan {
    start: usize,
    chars: usize,
}

impl Update {
    /// Scrollback as `(TEXT STYLE-SPANS DECO-SPANS)`, offsets in characters.
    ///
    /// STYLE-SPANS is `(START END FG BG ATTRS UNDERLINE)...`, only where styling departs
    /// from the default. DECO-SPANS is `(START END FG BG ATTRS DECO)...`, only where the
    /// run was decorated — the same `(KIND . PACKED)` [`deco_to_lisp`] produces for a
    /// live row, so `cooked--apply-deco` handles both.
    ///
    /// The two shapes share a prefix and diverge in their last element, which is not an
    /// accident worth tidying: a style span's tail is the underline colour, and a
    /// decoration is rendered from the foreground, background and attributes but never
    /// from that — so giving DECO-SPANS an underline it would ignore would be carrying a
    /// field to look symmetric.
    ///
    /// Assembled here rather than handed over run by run. Emacs pays for every
    /// `insert`, and a flood is tens of thousands of rows: one insert of one string
    /// plus spans only where styling or glyphs exist beats N inserts and N property
    /// calls, and it keeps roughly a million cons cells from crossing the boundary. A
    /// plain-text run — the overwhelming majority on the primary screen, where
    /// box-drawing UIs rarely live — pays for neither list.
    fn scrolled_rows(&self, env: &Env, rejoin: bool) -> Result<(Value, Vec<RowSpan>)> {
        if self.delta.scrolled.is_empty() {
            return Ok((env.nil(), Vec::new()));
        }
        let mut text = String::new();
        let mut spans: Vec<Value> = Vec::new();
        let mut deco_spans: Vec<Value> = Vec::new();
        let mut rows: Vec<RowSpan> = Vec::with_capacity(self.delta.scrolled.len());
        let mut offset = 0usize;
        let last = self.delta.scrolled.len() - 1;

        for (i, line) in self.delta.scrolled.iter().enumerate() {
            let start = offset;
            for run in &line.runs {
                let chars = run.text.chars().count();
                let Style { fg, bg, attrs } = run.style;
                if run.style != Style::default() || run.underline != Color::Default {
                    spans.push(env.list(&[
                        env.into_lisp(offset)?,
                        env.into_lisp(offset + chars)?,
                        color_to_lisp(env, fg)?,
                        color_to_lisp(env, bg)?,
                        env.into_lisp(u32::from(attrs.bits()))?,
                        color_to_lisp(env, run.underline)?,
                    ])?);
                }
                if run.deco.is_some() {
                    deco_spans.push(env.list(&[
                        env.into_lisp(offset)?,
                        env.into_lisp(offset + chars)?,
                        color_to_lisp(env, fg)?,
                        color_to_lisp(env, bg)?,
                        env.into_lisp(u32::from(attrs.bits()))?,
                        deco_to_lisp(env, run.deco.as_ref())?,
                    ])?);
                }
                text.push_str(&run.text);
                offset += chars;
            }
            rows.push(RowSpan {
                start,
                chars: offset - start,
            });
            // A wrapped row is a continuation, so it joins the line above rather
            // than starting a new one — except when it is the batch's last row and
            // the alt screen is up. Then what follows at screen-start is the alt
            // grid's own row 0, not this row's continuation on the primary grid, and
            // joining onto it would permanently weld this frozen scrollback text to
            // the front of a live row that gets rewritten every redraw.
            if !(rejoin && line.wrapped && !(i == last && self.delta.alt)) {
                text.push('\n');
                offset += 1;
            }
        }

        Ok((
            env.list(&[
                env.into_lisp(text.as_str())?,
                env.list(&spans)?,
                env.list(&deco_spans)?,
            ])?,
            rows,
        ))
    }

    /// Spell an [`Anchor`] in whichever coordinate system Emacs can address it in.
    ///
    /// `(scrolled . OFFSET)` — a character offset into this drain's scrollback text, for
    /// a row that scrolled away while this drain was accumulating. `(screen ROW . COL)`
    /// — a cell on the live grid, for one that did not. Resolved here rather than in
    /// Lisp because the arithmetic is over Rust's absolute row numbering, which is not
    /// something the Lisp side should have to hold a copy of.
    ///
    /// `nil` when neither applies. Unreachable as things stand — events and scrollback
    /// are taken by the same drain, so nothing can be older than the batch it arrives
    /// with — and Lisp falls back to the cursor, which is what it used before anchors.
    fn anchor_to_lisp(&self, env: &Env, at: Anchor, rows: &[RowSpan]) -> Result<Value> {
        let base = self.delta.scrolled_base;
        let on_grid = base + self.delta.scrolled.len();
        if at.row >= on_grid {
            return env.cons(
                env.intern("screen")?,
                env.cons(env.into_lisp(at.row - on_grid)?, env.into_lisp(at.col)?)?,
            );
        }
        match at.row.checked_sub(base).and_then(|i| rows.get(i)) {
            // Trailing blanks are trimmed out of the runs, so a column past the end of
            // what the row actually kept is clamped rather than run off the line.
            Some(row) => env.cons(
                env.intern("scrolled")?,
                env.into_lisp(row.start + at.col.min(row.chars))?,
            ),
            None => Ok(env.nil()),
        }
    }
}

/// `(TEXT FG BG ATTRS DECO UNDERLINE)` — colors are nil, an index, or `(R G B)`;
/// DECO is nil for a plain run, or `(KIND . PACKED)`, for which see [`deco_to_lisp`].
fn run_to_lisp(env: &Env, run: &Run) -> Result<Value> {
    let Style { fg, bg, attrs } = run.style;
    env.list(&[
        env.into_lisp(run.text.as_str())?,
        color_to_lisp(env, fg)?,
        color_to_lisp(env, bg)?,
        env.into_lisp(u32::from(attrs.bits()))?,
        deco_to_lisp(env, run.deco.as_ref())?,
        color_to_lisp(env, run.underline)?,
    ])
}

/// Images transmitted this drain, each as `(ID FORMAT DATA PX-WIDTH PX-HEIGHT COLS ROWS)`.
///
/// The bytes cross exactly once per distinct image, however many times the child sends
/// them or places them: ids are content-addressed, so a program redrawing one picture
/// per frame pays for the transfer on the first frame and for placements thereafter.
/// DATA is unibyte and handed straight to `create-image`; FORMAT is its type symbol.
///
/// COLS and ROWS are the cell rectangle the emulator laid the image into, so Lisp can
/// slice the spec per cell without recomputing a geometry the grid has already committed
/// to — and without needing the two to agree by coincidence.
fn images_to_lisp(env: &Env, images: &[ImageData]) -> Result<Vec<Value>> {
    images
        .iter()
        .map(|image| {
            env.list(&[
                env.into_lisp(i64::from(image.id.0))?,
                env.intern(image.format.as_str())?,
                env.into_lisp(image.bytes.as_slice())?,
                env.into_lisp(i64::from(image.px.0))?,
                env.into_lisp(i64::from(image.px.1))?,
                env.into_lisp(i64::from(image.cells.0))?,
                env.into_lisp(i64::from(image.cells.1))?,
            ])
        })
        .collect()
}

/// `nil`, or `(KIND . PACKED)` — what a run's characters display instead of themselves.
///
/// KIND is an interned symbol naming the decoration, and PACKED is a unibyte string of
/// fixed-width records, one per character of the run's text, little-endian. The kind is
/// carried once for the run rather than per character because a run is homogeneous in
/// it — see [`Deco`] — which is what keeps the record narrow:
///
///   `glyph`   two bytes, a `BoxGlyph` bit pattern.
///   `image`   eight bytes: a `u32` image id, then the cell's row and column within
///             that image as `u16`s.
///
/// A packed string rather than a list because this is the live-row path: box drawing is
/// what full-screen programs are made of, so a list would cons per character of every
/// damaged row of every frame — the same cost `scrolled_rows` goes out of its way to
/// avoid on the flood path, paid on the one that redraws continuously. One allocation
/// per run instead, unibyte so Emacs neither decodes nor copies it again.
fn deco_to_lisp(env: &Env, deco: Option<&Deco>) -> Result<Value> {
    let Some(deco) = deco else {
        return Ok(env.nil());
    };
    match deco {
        Deco::Glyphs(glyphs) => {
            let mut packed = Vec::with_capacity(glyphs.len() * 2);
            for glyph in glyphs {
                packed.extend_from_slice(&glyph.bits().to_le_bytes());
            }
            env.cons(env.intern("glyph")?, env.into_lisp(packed.as_slice())?)
        }
        Deco::Images(places) => {
            let mut packed = Vec::with_capacity(places.len() * 8);
            for place in places {
                packed.extend_from_slice(&place.id.0.to_le_bytes());
                packed.extend_from_slice(&place.cell_row.to_le_bytes());
                packed.extend_from_slice(&place.cell_col.to_le_bytes());
            }
            env.cons(env.intern("image")?, env.into_lisp(packed.as_slice())?)
        }
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

/// A single event, with any anchor it carries already resolved against `update`.
///
/// The semantic marks are lists of a uniform shape — `(prompt-start ANCHOR)`,
/// `(command-end CODE ANCHOR)` — rather than the dotted pairs the payload-carrying
/// events used to be, so that adding the anchor did not leave two spellings in one
/// family. `(osc CODE BELL-P PART...)` stays variadic and untouched.
fn event_to_lisp(env: &Env, event: &Event, update: &Update, rows: &[RowSpan]) -> Result<Value> {
    let tagged = |name: &str, payload: Value| env.cons(env.intern(name)?, payload);
    let mark = |name: &str, at: Anchor| {
        env.list(&[env.intern(name)?, update.anchor_to_lisp(env, at, rows)?])
    };
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
        Event::PromptStart(at) => mark("prompt-start", *at),
        Event::PromptEnd(at) => mark("prompt-end", *at),
        Event::CommandStart(at) => mark("command-start", *at),
        Event::CommandEnd(code, at) => env.list(&[
            env.intern("command-end")?,
            env.into_lisp(code.map(i64::from))?,
            update.anchor_to_lisp(env, *at, rows)?,
        ]),
        // (mouse ENABLED SGR): the sender needs the encoding, not just the fact.
        Event::Mouse(m) => env.list(&[
            env.intern("mouse")?,
            env.into_lisp(m.enabled())?,
            env.into_lisp(m.sgr)?,
        ]),
        Event::Reply(bytes) => tagged("reply", env.into_lisp(bytes.as_slice())?),
        Event::EraseScrollback => env.list(&[env.intern("erase-scrollback")?]),
        Event::DisplayCleared => env.list(&[env.intern("display-cleared")?]),
        // (title-stack PUSH-P)
        Event::TitleStack(push) => env.list(&[env.intern("title-stack")?, env.into_lisp(*push)?]),
    }
}
