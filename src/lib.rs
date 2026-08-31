//! cooked — a terminal emulator core for Emacs that knows when to get out of the way.
//!
//! Lisp entry points live here; everything below is plain Rust and unit-testable without
//! an Emacs in the loop.

pub mod platform;
pub mod emu;
pub mod env;
pub mod error;
pub mod pty;
pub mod session;

use emu::{
    Anchor, CellMetrics, Color, Deco, Event, ImageData, ImageId, LinkId, MarkId, Run, Style,
};
use env::{Env, Result, Runtime, Value, plist};
use nix::sys::signal::Signal;
use pty::{Pid, Winsize};
use session::{Session, Update};

/// Join the `///` lines of a table entry into the docstring Emacs will show.
///
/// The lines arrive as `#[doc]` attributes, which is what a doc comment is once the
/// lexer has been through it, and each carries the space `///` puts after the marker.
/// That space is right for Rust and wrong here: a Lisp docstring is displayed exactly as
/// given, so leaving it would indent every line of every `C-h f' by one column. Blank
/// lines have no space to remove and stay blank.
fn docstring(lines: &[&str]) -> String {
    lines
        .iter()
        .map(|line| line.strip_prefix(' ').unwrap_or(line))
        .collect::<Vec<_>>()
        .join("\n")
}

/// Register a table of Lisp functions, each a `fn(Env, &[Value]) -> Result<Value>`.
///
/// Expands to an array of `Result<()>`, one per entry, for the caller to collect. This
/// table is the only place cooked's Lisp surface is written down, so it is worth being
/// able to read against `cooked.el' -- which is what the shape buys: one line stating the
/// name, arity and handler, under the docstring it belongs to.
///
/// The docstring is a doc comment because that is where prose about a function goes, and
/// the lexer has already turned it into `#[doc]` attributes by the time this matches --
/// so the text a user reads at `C-h f' sits directly above the entry it documents.
macro_rules! defuns {
    ($env:expr, {
        $( $(#[doc = $doc:literal])+ $name:literal $arity:expr => $f:ident; )*
    }) => {
        [ $( $env.defun($name, $arity, &docstring(&[$($doc),+]), $f) ),* ]
    };
}

/// Register Lisp functions that are one [`Session`] method on the handle in `args[0]`.
///
/// Ten defuns share one body -- take the handle, call the method, convert what comes
/// back -- so they are written as the table they are. `=> alive` names the method, which
/// is the only thing such a body ever says.
///
/// The result goes through [`env::IntoLisp`], so a method returning `()` yields `nil`
/// without a special case. The optional `as CONV` arm is for a return type that needs a
/// step before that, which is only `pid`.
///
/// A defun whose body is not exactly this shape does not belong here: `foreground_pid`
/// has its own `Err` handling and `job_control` builds a plist, so both stay written out
/// in full.
macro_rules! accessors {
    ($env:expr, {
        $( $(#[doc = $doc:literal])+ $name:literal => $method:ident; )*
    }) => {
        [ $( $env.defun($name, 1..=1, &docstring(&[$($doc),+]), {
            fn accessor(env: Env, args: &[Value]) -> Result<Value> {
                env.into_lisp(handle(env, args[0])?.$method())
            }
            accessor
        }) ),* ]
    };
}

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

    let registered = defuns!(env, {
        /// Spawn ARGV on a new pty and return a session handle.
        /// Arguments are ARGV, ENV, ROWS, COLS, WAKE, optional DIRECTORY, optional
        /// MIN-REDISPLAY-INTERVAL and optional BACKLOG-LIMIT. ENV is an alist of strings. WAKE is a
        /// pipe process whose filter runs when output is pending. MIN-REDISPLAY-INTERVAL, in
        /// milliseconds, floors how often a rapidly-rewriting child (a spinner, a progress meter)
        /// triggers a redisplay; it defaults to 8 when omitted or nil. BACKLOG-LIMIT caps the items
        /// awaiting collection before the child is left to block on its own writes; it defaults to
        /// 8000 when omitted or nil.
        "cooked--spawn" 5..=8 => spawn;

        /// Collect everything that changed in SESSION since the last call.
        /// Returns a plist with :scrolled, :rows, :height, :used, :head, :cursor, :alt,
        /// :app-cursor, :keys, :mode, :images, :events and :exit.
        ///
        /// :scrolled and :rows are the same shape, so one renderer handles both: a block is
        /// (TEXT STYLE-SPANS DECO-SPANS), where the spans carry character offsets into TEXT and
        /// appear only where there is something to say.  :scrolled is one block for the whole
        /// batch; :rows is an alist of (INDEX . BLOCK), one per damaged screen row.
        /// With REJOIN non-nil (the default), a line the terminal wrapped is emitted as one
        /// line rather than one per screen row.
        ///
        /// :height, :used and :head describe the grid's shape, so the buffer is shaped by what
        /// the emulator has rather than by a second opinion of it: the grid's row count, how many
        /// of those rows are occupied, and how many characters of screen row 0's logical line are
        /// already in the buffer above the screen. The last is the seam — 0 unless the last row
        /// handed to scrollback was a wrapped one that row 0 continues.
        ///
        /// The fields are levels — the state as of this drain — and carry everything redisplay
        /// needs. :events are occurrences, for what Emacs must react to that redisplay does not
        /// cover. Nothing is sent both ways.
        ///
        /// :images is neither, and is the one thing that must be consumed *before* :scrolled and
        /// :rows are rendered: it carries resources those rows refer to by id. Each image crosses
        /// once, however often the child sends or places it.
        "cooked--drain" 1..=2 => drain;

        /// Write STRING to the pty of SESSION.
        "cooked--send" 2..=2 => send;

        /// Answer an OSC query on SESSION with CODE, PAYLOAD and BELL.
        /// Writes `ESC ] CODE ; PAYLOAD' terminated by BEL when BELL is non-nil and by ST
        /// otherwise; pass the BELL-P the `osc' event carried, since a client that queried with
        /// BEL will not recognise an ST-terminated answer. Signals if PAYLOAD contains control
        /// characters, which could close the sequence early.
        "cooked--reply-osc" 4..=4 => reply_osc;

        /// Resize SESSION to ROWS by COLS, each cell CELL-WIDTH by CELL-HEIGHT pixels.
        /// The cell size may be nil or omitted, which is what a terminal frame has to
        /// say: it reaches the child as a zero `ws_xpixel'/`ws_ypixel', meaning "not
        /// reported", and leaves image sizing in pixels with nothing to work from.
        "cooked--resize" 3..=5 => resize;

        /// Remove COUNT rows from SESSION's grid, starting at screen row FIRST.
        ///
        /// Rows below close the gap and blanks come in at the bottom, exactly as if the
        /// child had done it.  The emulator is the only thing that edits rows -- Emacs asks
        /// and then renders the result on the next drain, rather than deleting buffer text
        /// the grid still holds, which would leave the two ends disagreeing about what the
        /// screen is.
        ///
        /// The rows are discarded, not archived: they are a finished command's output being
        /// deleted, and archiving would return them to the buffer as scrollback.
        "cooked--remove-rows" 3..=3 => remove_rows;

        /// Send signal NUMBER to SESSION's foreground group.
        "cooked--signal" 2..=2 => signal;

        /// SESSION's job-control characters, as a plist.
        ///
        /// Keys are :intr, :quit and :susp -- each the character code the tty currently
        /// turns into a signal, or nil where the character is disabled -- and :isig, which
        /// is non-nil while the line discipline still acts on them.  :eof is the
        /// end-of-file character, which :isig says nothing about: ICANON decides whether
        /// the line discipline acts on it, and a raw-mode program just reads the byte.  A terminal writes one
        /// of these bytes rather than sending a signal, so honouring them is what makes
        /// `stty intr ^X' work; with :isig nil the byte reaches the child verbatim, which
        /// is what a program that cleared ISIG asked for.
        "cooked--job-control" 1..=1 => job_control;

        /// Version of the native core, as `Cargo.toml' declares it.
        ///
        /// Compiled in rather than reported by the Lisp side, so the string always
        /// describes the artifact actually loaded.  What a stale .so answers is then its
        /// own version, not the version the Lisp wishes it were.
        "cooked--core-version" 0..=0 => core_version;

        /// Process id of SESSION's foreground process group, or nil.
        ///
        /// Not the same as `cooked--pid': that is the process cooked spawned, which is
        /// usually a shell, while this is the program the user is actually looking at --
        /// what the shell put in the foreground.  nil when the tty has no answer, which is
        /// ordinary between jobs and once the session is over.
        "cooked--foreground-pid" 1..=1 => foreground_pid;
    });

    let accessors = accessors!(env, {
        /// Tell SESSION that Emacs no longer holds any of its scrollback.
        ///
        /// Call after discarding the buffer text above the live screen: the emulator tracks
        /// how much of its top row's line already left for Emacs, so that a rewrap resumes
        /// that line where the buffer actually wraps it.  Once the text is gone the top row
        /// begins a line again, and saying so is what keeps the two ends agreeing.
        "cooked--forget-history" => forget_history;

        /// Mark SESSION's whole screen damaged, so the next drain re-sends it.
        /// For recovering from a redisplay that failed part-way: an ordinary drain only reports
        /// what changed since the last one, so it cannot repair a buffer that is missing rows of
        /// a drain that signalled halfway through applying them.
        "cooked--redraw" => redraw;

        /// Remove the rows above SESSION's current prompt, returning how many went.
        ///
        /// The emulator's half of clearing the terminal.  Emacs deletes the scrollback,
        /// which is its own buffer text; the rows still on the grid are the emulator's, and
        /// which of them are above the prompt is a question only it can answer -- from the
        /// last OSC 133;A mark, falling back to the cursor's row when the shell never said.
        ///
        /// Returns 0 and does nothing on the alternate screen: that grid belongs to a
        /// running program, not to a transcript.
        "cooked--clear-to-prompt" => clear_to_prompt;

        /// Text of the last non-blank line written by SESSION's child.
        /// Used as the minibuffer prompt when SESSION enters `secret' mode.
        "cooked--prompt-text" => trailing_text;

        /// Process id of SESSION's child.
        "cooked--pid" => pid;

        /// Whether SESSION's child is still running.
        "cooked--live-p" => alive;

        /// Whether SESSION requested bracketed paste.
        "cooked--bracketed-paste-p" => bracketed_paste;

        /// Whether SESSION asked to be told when the window gains or loses focus.
        "cooked--focus-events-p" => focus_events;

        /// Whether a wheel notch on SESSION should be sent as cursor keys.
        "cooked--alt-scroll-p" => alt_scroll;

        /// Tear SESSION's child down now and reap it.
        /// Returns t if this call ended the session, nil if it had already ended. Safe to call
        /// repeatedly. The child is sent SIGHUP, given a moment, then SIGKILL, so a process that
        /// ignores SIGHUP cannot outlive its buffer. Afterwards the handle is inert and garbage
        /// collecting it costs nothing.
        "cooked--kill" => shutdown;
    });

    match registered
        .into_iter()
        .chain(accessors)
        .collect::<Result<Vec<_>>>()
        .and_then(|_| env::provide(&env, "cooked-core"))
    {
        Ok(()) => 0,
        Err(_) => 1,
    }
}

fn handle<'e>(env: Env<'e>, value: Value) -> Result<&'e Session> {
    env.get_user_ptr::<Session>(value)
}

/// Walk a proper list, handing each element to `f`.
///
/// `car`/`cdr` rather than `nth` per index: `nth` restarts at the head every time, which
/// makes reading a list off the boundary quadratic in its length. Nothing we are handed
/// is long enough today for that to matter, but the environment alist is the child's to
/// grow, and this is not the place to let it decide how much work we do.
/// A cyclic list would otherwise spin this forever on the thread holding the
/// `emacs_env` — see `env.rs`'s own rule against that. `argv`/env alists are built by
/// `cooked.el` itself rather than arriving from a child process, so this is a guard
/// against a bug on that side rather than a hostile input, but the cost of getting it
/// wrong (all of Emacs wedged) is exactly the kind this crate otherwise refuses to
/// accept on trust elsewhere in this file.
const MAX_LIST_LEN: usize = 1 << 20;

fn each<T>(env: Env, mut list: Value, mut f: impl FnMut(Value) -> Result<T>) -> Result<Vec<T>> {
    let mut out = Vec::new();
    while !env.is_nil(list) {
        if out.len() >= MAX_LIST_LEN {
            return Err(env.signal("error", "cooked: list argument too long or improper"));
        }
        out.push(f(env.call("car", &[list])?)?);
        list = env.call("cdr", &[list])?;
    }
    Ok(out)
}

fn strings(env: Env, list: Value) -> Result<Vec<String>> {
    each(env, list, |item| env.from_lisp::<String>(item))
}

fn pairs(env: Env, alist: Value) -> Result<Vec<(String, String)>> {
    each(env, alist, |cell| {
        Ok((
            env.from_lisp::<String>(env.call("car", &[cell])?)?,
            env.from_lisp::<String>(env.call("cdr", &[cell])?)?,
        ))
    })
}

/// Turn a core error into a Lisp signal, at the point `?` would carry it.
///
/// An extension trait rather than a free function because there is no `impl From` to be
/// had -- the conversion needs an `Env`, which the error does not carry -- and six call
/// sites spelling `.or_signal(env)?` is what that shortfall looked like.
/// `Display` on [`cooked::error::Error`] does the message, so this no longer has to know
/// anything about what went wrong.
/// The crate's id newtypes, which are all one integer wide.
///
/// Without these every id crossed the boundary as `i64::from(id.0)`, which reached past
/// the newtype to the field it exists to hide.
macro_rules! into_lisp_id {
    ($($t:ty),* $(,)?) => {
        $(impl env::IntoLisp for $t {
            fn into_lisp(self, env: &Env) -> Result<Value> {
                self.0.into_lisp(env)
            }
        })*
    };
}

into_lisp_id!(MarkId, LinkId, ImageId);

impl env::IntoLisp for Pid {
    fn into_lisp(self, env: &Env) -> Result<Value> {
        self.get().into_lisp(env)
    }
}

trait OrSignal<T> {
    fn or_signal(self, env: Env) -> Result<T>;
}

impl<T> OrSignal<T> for std::result::Result<T, crate::error::Error> {
    fn or_signal(self, env: Env) -> Result<T> {
        self.map_err(|e| env.signal("cooked-error", &e.to_string()))
    }
}

fn spawn(env: Env, args: &[Value]) -> Result<Value> {
    let argv = strings(env, args[0])?;
    let vars = pairs(env, args[1])?;
    let size = Winsize {
        rows: env.from_lisp::<u16>(args[2])?.max(1),
        cols: env.from_lisp::<u16>(args[3])?.max(1),
        // Reported by the first resize rather than at spawn: the buffer usually has no
        // window yet here, so there is no font to measure.
        cell: CellMetrics::default(),
    };
    let wake = env.open_channel(args[4])?;
    let cwd = env.opt::<String>(args, 5)?;
    let defaults = session::Options::default();
    let options = session::Options {
        min_redisplay_interval: match env.opt::<i64>(args, 6)? {
            Some(ms) => std::time::Duration::from_millis(ms.max(0) as u64),
            None => defaults.min_redisplay_interval,
        },
        backlog_limit: env
            .opt::<i64>(args, 7)?
            .map_or(defaults.backlog_limit, |n| n.max(1) as usize),
    };

    let session = Session::spawn(
        &argv,
        &vars,
        size,
        cwd.as_ref().map(std::path::Path::new),
        wake,
        options,
    )
    .or_signal(env)?;
    env.user_ptr(session)
}

fn drain(env: Env, args: &[Value]) -> Result<Value> {
    let rejoin = args.get(1).is_none_or(|v| !env.is_nil(*v));
    let update = handle(env, args[0])?.drain();
    update_to_lisp(env, &update, rejoin)
}

fn send(env: Env, args: &[Value]) -> Result<Value> {
    let mut bytes = env.from_lisp::<Vec<u8>>(args[1])?;
    let sent = handle(env, args[0]).map(|s| s.send(&bytes));
    // Zero unconditionally rather than only for secrets: at keystroke sizes it costs
    // nothing, and it means the password path needs no special case to be covered.
    // `write_volatile` because an ordinary write to a buffer about to be freed is
    // exactly the store a compiler is entitled to drop.
    for b in &mut bytes {
        unsafe { std::ptr::write_volatile(b, 0) };
    }
    std::sync::atomic::compiler_fence(std::sync::atomic::Ordering::SeqCst);
    sent?.or_signal(env)?;
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
    handle(env, args[0])?.send(&bytes).or_signal(env)?;
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
    handle(env, args[0])?.resize(size).or_signal(env)?;
    Ok(env.nil())
}

fn remove_rows(env: Env, args: &[Value]) -> Result<Value> {
    let first = env.from_lisp::<i64>(args[1])?.max(0) as usize;
    let count = env.from_lisp::<i64>(args[2])?.max(0) as usize;
    handle(env, args[0])?.remove_rows(first, count);
    Ok(env.nil())
}

fn signal(env: Env, args: &[Value]) -> Result<Value> {
    // Validated here rather than inside `Pty::signal`, because this is the only caller
    // whose number is untrusted -- the rest name the signal statically. A number that is
    // not a signal is the caller passing the wrong thing, so it gets the Lisp condition
    // for that rather than being flattened into a `cooked-error' string.
    //
    // `try_from` rather than `as i32`: the cast wraps, so 4294967305 would arrive as 9
    // and kill the child outright. Lisp integers are wider than the signal number they
    // stand in for, and one that does not fit is a mistake to report rather than a bit
    // pattern to truncate.
    let sig = env.from_lisp::<i64>(args[1])?;
    let sig = i32::try_from(sig)
        .ok()
        .and_then(|n| Signal::try_from(n).ok())
        .ok_or_else(|| env.signal("args-out-of-range", "not a signal number"))?;
    handle(env, args[0])?.signal(sig).or_signal(env)?;
    Ok(env.nil())
}

fn job_control(env: Env, args: &[Value]) -> Result<Value> {
    let jc = handle(env, args[0])?.job_control().or_signal(env)?;
    let ch = |env: Env, c: Option<u8>| match c {
        Some(b) => env.into_lisp(b),
        None => Ok(env.nil()),
    };
    plist!(&env, {
        ":intr" => ch(env, jc.intr)?,
        ":quit" => ch(env, jc.quit)?,
        ":susp" => ch(env, jc.susp)?,
        ":eof"  => ch(env, jc.eof)?,
        ":isig" => jc.isig,
    })
}

fn core_version(env: Env, _args: &[Value]) -> Result<Value> {
    env.into_lisp(env!("CARGO_PKG_VERSION"))
}

fn foreground_pid(env: Env, args: &[Value]) -> Result<Value> {
    // nil rather than an error: `tcgetpgrp' has nothing to report between a shell putting
    // one job down and the next taking over, and once the session is gone it can answer 0.
    // Neither is a fault the caller can do anything about, and both are ordinary.
    match handle(env, args[0])?.foreground() {
        Ok(pid) => env.into_lisp(pid),
        Err(_) => Ok(env.nil()),
    }
}

/// `(:scrolled ROWS :rows ((INDEX . RUNS)...) :height N :used N :head N
/// :cursor (ROW COL VISIBLE) :marks ((ID . ANCHOR)...) ...)`
fn update_to_lisp(env: Env, update: &Update, rejoin: bool) -> Result<Value> {
    // The scrollback is assembled first because the events are resolved against it: a
    // mark on a row that scrolled away during this very drain is spelled as an offset
    // into the text about to be inserted, which only exists once that text is built.
    let (scrolled, spans) = update.scrolled_rows(env, rejoin)?;
    // `(INDEX . BLOCK)`, the same [`Block`] scrollback arrives in, so one renderer in
    // Lisp handles both. A damaged row carries no newline: it is written into a line
    // that already exists.
    let rows = update
        .delta
        .rows
        .iter()
        .map(|(index, runs)| {
            let mut block = Block::default();
            block.push_runs(env, runs)?;
            env.cons(env.into_lisp(*index)?, block.into_lisp(&env)?)
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
    // `(ID . ANCHOR)`, in the same coordinates a mark's own event carries, so Lisp
    // resolves both with `cooked--anchor-position'. Empty on every drain but a resize.
    let marks = update
        .delta
        .marks
        .iter()
        .map(|(id, at)| {
            env.cons(
                env.into_lisp(*id)?,
                update.anchor_to_lisp(env, *at, &spans)?,
            )
        })
        .collect::<Result<Vec<_>>>()?;

    plist!(env, {
        ":scrolled"   => scrolled,
        ":rows"       => env.list(&rows)?,
        ":height"     => update.delta.height,
        ":used"       => update.delta.used,
        ":head"       => update.delta.head,
        ":cursor"     => cursor,
        ":marks"      => env.list(&marks)?,
        ":alt"        => update.delta.alt,
        ":app-cursor" => update.delta.app_cursor,
        ":keys"       => env.intern(update.delta.keys.as_str())?,
        ":mode"       => env.intern(update.mode.as_str())?,
        ":images"     => env.list(&images_to_lisp(env, &update.delta.images)?)?,
        ":links"      => env.list(&links_to_lisp(env, &update.delta.links)?)?,
        ":events"     => env.list(&events)?,
        ":exit"       => update.exit.map(i64::from),
    })
}

/// A run of buffer text with its styling and decoration held off to the side.
///
/// The one shape rendered text crosses in, for the live screen and for scrollback alike
/// — one encoder here and one renderer in Lisp, which is the point: a second shape means
/// every field has to be taught to both, and they drift.
///
/// Sparse rather than a run per damaged row, because Emacs pays for every `insert`. One
/// insert of one string, plus properties only where they depart from the default, beats
/// N inserts and N property calls, and it keeps roughly a million cons cells from
/// crossing the boundary on a flood. A plain unstyled row — the overwhelming majority on
/// the primary screen — pays for neither span list, and a row of eight styled runs costs
/// one insert rather than eight.
///
/// STYLE-SPANS and DECO-SPANS share a prefix and diverge in their last element, which is
/// not an accident worth tidying: a style span's tail is the underline colour, and a
/// decoration renders from the foreground, background and attributes but never from
/// that, so giving DECO-SPANS an underline it would ignore would be carrying a field to
/// look symmetric.
///
/// LINK-SPANS shares neither shape. It is `(START END ID)` and nothing else, because a
/// hyperlink says nothing about how its characters are drawn — whatever style they
/// carry is already in STYLE-SPANS, and Lisp deliberately leaves it alone. The id is
/// resolved against the `:links` table the same drain carries.
#[derive(Default)]
struct Block {
    text: String,
    styles: Vec<Value>,
    decos: Vec<Value>,
    links: Vec<Value>,
    offset: usize,
}

impl Block {
    /// One span: the run's extent and rendition, then whatever distinguishes this list.
    ///
    /// The style and deco spans agree on five of their six elements, so they are built
    /// once here and given their differing sixth as `tail`. That difference is the whole
    /// distinction between them, which the type's doc comment explains; writing the shared
    /// five out twice would bury it.
    fn span(&self, env: Env, chars: usize, style: Style, tail: Value) -> Result<Value> {
        let Style { fg, bg, attrs } = style;
        env.list(&[
            env.into_lisp(self.offset)?,
            env.into_lisp(self.offset + chars)?,
            env.into_lisp(fg)?,
            env.into_lisp(bg)?,
            env.into_lisp(u32::from(attrs.bits()))?,
            tail,
        ])
    }

    /// Append RUNS, emitting spans only where there is something to say.
    fn push_runs(&mut self, env: Env, runs: &[Run]) -> Result<()> {
        for run in runs {
            let chars = run.text.chars().count();
            if run.style != Style::default() || run.underline != Color::Default {
                let tail = env.into_lisp(run.underline)?;
                self.styles.push(self.span(env, chars, run.style, tail)?);
            }
            if let Some(link) = run.link {
                self.links.push(env.list(&[
                    env.into_lisp(self.offset)?,
                    env.into_lisp(self.offset + chars)?,
                    env.into_lisp(link)?,
                ])?);
            }
            if run.deco.is_some() {
                let tail = env.into_lisp(run.deco.as_ref())?;
                self.decos.push(self.span(env, chars, run.style, tail)?);
            }
            self.text.push_str(&run.text);
            self.offset += chars;
        }
        Ok(())
    }

    fn push_newline(&mut self) {
        self.text.push('\n');
        self.offset += 1;
    }

    fn into_lisp(self, env: &Env) -> Result<Value> {
        env.list(&[
            env.into_lisp(self.text.as_str())?,
            env.list(&self.styles)?,
            env.list(&self.decos)?,
            env.list(&self.links)?,
        ])
    }
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
    /// This drain's scrollback as one [`Block`], plus where each row landed in it.
    ///
    /// Assembled here rather than handed over row by row, for the reason [`Block`]
    /// gives: a flood is tens of thousands of rows, and Emacs pays for every `insert`.
    fn scrolled_rows(&self, env: Env, rejoin: bool) -> Result<(Value, Vec<RowSpan>)> {
        if self.delta.scrolled.is_empty() {
            return Ok((env.nil(), Vec::new()));
        }
        let mut block = Block::default();
        let mut rows: Vec<RowSpan> = Vec::with_capacity(self.delta.scrolled.len());
        let last = self.delta.scrolled.len() - 1;

        for (i, line) in self.delta.scrolled.iter().enumerate() {
            let start = block.offset;
            block.push_runs(env, &line.runs)?;
            rows.push(RowSpan {
                start,
                chars: block.offset - start,
            });
            // A wrapped row is a continuation, so it joins the line above rather
            // than starting a new one — except when it is the batch's last row and
            // the alt screen is up. Then what follows at screen-start is the alt
            // grid's own row 0, not this row's continuation on the primary grid, and
            // joining onto it would permanently weld this frozen scrollback text to
            // the front of a live row that gets rewritten every redraw.
            if !(rejoin && line.wrapped && !(i == last && self.delta.alt)) {
                block.push_newline();
            }
        }

        Ok((block.into_lisp(&env)?, rows))
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
    fn anchor_to_lisp(&self, env: Env, at: Anchor, rows: &[RowSpan]) -> Result<Value> {
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
fn images_to_lisp(env: Env, images: &[ImageData]) -> Result<Vec<Value>> {
    images
        .iter()
        .map(|image| {
            env.list(&[
                env.into_lisp(image.id)?,
                env.intern(image.format.as_str())?,
                env.into_lisp(image.bytes.as_slice())?,
                env.into_lisp(image.px.w)?,
                env.into_lisp(image.px.h)?,
                env.into_lisp(image.cells.cols)?,
                env.into_lisp(image.cells.rows)?,
            ])
        })
        .collect()
}

/// Hyperlink destinations first seen this drain, each as `(ID . URI)`.
///
/// [`images_to_lisp`]'s much smaller sibling, and for the same reason: ids are
/// content-addressed, so a URI crosses once however many cells name it, and Lisp
/// installs the table before rendering rows that refer to it.
fn links_to_lisp(env: Env, links: &[(LinkId, String)]) -> Result<Vec<Value>> {
    links
        .iter()
        .map(|(id, uri)| env.cons(env.into_lisp(*id)?, env.into_lisp(uri.as_str())?))
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
impl env::IntoLisp for Option<&Deco> {
    fn into_lisp(self, env: &Env) -> Result<Value> {
        let Some(deco) = self else {
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
}

impl env::IntoLisp for Color {
    fn into_lisp(self, env: &Env) -> Result<Value> {
        match self {
            Color::Default => Ok(env.nil()),
            Color::Indexed(i) => env.into_lisp(i),
            Color::Rgb(r, g, b) => {
                let parts = [r, g, b]
                    .map(|c| env.into_lisp(c))
                    .into_iter()
                    .collect::<Result<Vec<_>>>()?;
                env.list(&parts)
            }
        }
    }
}

/// A single event, with any anchor it carries already resolved against `update`.
///
/// The semantic marks are lists of a uniform shape — `(prompt-start ANCHOR ID)`,
/// `(command-end CODE ANCHOR ID)` — rather than dotted pairs, so that one family of
/// events has one spelling however many fields a member carries. `(osc CODE BELL-P
/// PART...)` is variadic and stands outside that family.
///
/// ID names the mark for the rest of the session: the anchor resolves to a buffer
/// position once, here, and stops being true the next time a resize rewraps the grid, so
/// `:marks` reports the same id with a fresh anchor and Lisp moves the marker it made.
/// See `Delta::marks` and `cooked--relocate-marks'.
fn event_to_lisp(env: Env, event: &Event, update: &Update, rows: &[RowSpan]) -> Result<Value> {
    let tagged = |name: &str, payload: Value| env.cons(env.intern(name)?, payload);
    let mark = |name: &str, at: Anchor, id: MarkId| {
        env.list(&[
            env.intern(name)?,
            update.anchor_to_lisp(env, at, rows)?,
            env.into_lisp(id)?,
        ])
    };
    match event {
        Event::Bell => env.list(&[env.intern("bell")?]),
        // (osc CODE BELL-P PART...) — Lisp decides what the code means. BELL-P is
        // opaque to the handler: it hands it back to `cooked--reply-osc' if it answers.
        Event::Osc(code, parts, bell) => {
            let mut items = vec![
                env.intern("osc")?,
                env.into_lisp(*code)?,
                env.into_lisp(*bell)?,
            ];
            for part in parts {
                items.push(env.into_lisp(part.as_str())?);
            }
            env.list(&items)
        }
        Event::PromptStart(at, id) => mark("prompt-start", *at, *id),
        Event::PromptContinuation(at, id) => mark("prompt-continuation", *at, *id),
        Event::PromptEnd(at, id) => mark("prompt-end", *at, *id),
        Event::CommandStart(at, id) => mark("command-start", *at, *id),
        Event::CommandEnd(code, at, id) => env.list(&[
            env.intern("command-end")?,
            env.into_lisp(code.map(i64::from))?,
            update.anchor_to_lisp(env, *at, rows)?,
            env.into_lisp(*id)?,
        ]),
        // (mouse ENABLED SGR DRAG MOTION). Flattening this to a single "wants the
        // mouse" bit lost the reach of the request: 1002 and 1003 ask to be told
        // where the pointer went, not merely which cell it was pressed in, and the
        // sender cannot manufacture motion reports it was never told to send.
        Event::Mouse(m) => env.list(&[
            env.intern("mouse")?,
            env.into_lisp(m.enabled())?,
            env.into_lisp(m.sgr)?,
            env.into_lisp(m.drag)?,
            env.into_lisp(m.motion)?,
        ]),
        Event::Reply(bytes) => tagged("reply", env.into_lisp(bytes.as_slice())?),
        Event::EraseScrollback => env.list(&[env.intern("erase-scrollback")?]),
        Event::DisplayCleared => env.list(&[env.intern("display-cleared")?]),
        // (title-stack PUSH-P)
        Event::TitleStack(push) => env.list(&[env.intern("title-stack")?, env.into_lisp(*push)?]),
    }
}
