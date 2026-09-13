//! cooked — a terminal emulator core for Emacs that knows when to get out of the way.
//!
//! Lisp entry points live here; everything below is plain Rust and unit-testable without
//! an Emacs in the loop.

// This crate is a cdylib whose only real consumer is Emacs, reached through the
// `defuns!` table below and not through Rust's visibility rules, so nearly every
// type in it is private by design.  Documentation that explains a public entry
// point therefore has to point *inwards* -- `cooked--drain' cannot be explained
// without naming `Screen::drain_damage' and `Event' -- and rustdoc warns about
// every such link on a build with no defects in it.  Left on, those warnings
// would bury the one class that is a defect, `broken_intra_doc_links', so the
// shape warning is silenced and the defect warning kept.  Read the docs with
// `cargo doc --document-private-items'; without it none of the links resolve.
#![allow(rustdoc::private_intra_doc_links)]

pub mod emu;
pub(crate) mod env;
pub(crate) mod error;
pub(crate) mod platform;
pub(crate) mod pty;
pub(crate) mod session;
mod wire;

use emu::{CellMetrics, ColorScheme, ImageId};
use env::{Env, Result, Runtime, Value, plist, sym};
use nix::sys::signal::Signal;
use pty::Winsize;
use session::Session;
use wire::{emission_to_lisp, update_to_lisp};

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

/// Register Lisp functions whose whole body is one call on the session in `args[0]`.
///
/// Each entry names the call as a function of the session: `Session::alive` for a
/// session method, or `|s| s.term().touch_all()` for a question put straight to the
/// locked emulator. The result goes through [`env::IntoLisp`], so a call returning `()`
/// yields `nil` without a special case.
///
/// A defun whose body is not exactly this shape does not belong here: `foreground_pid`
/// has its own `Err` handling and `job_control` builds a plist, so both stay written out
/// in full.
macro_rules! accessors {
    ($env:expr, {
        $( $(#[doc = $doc:literal])+ $name:literal => $call:expr; )*
    }) => {
        [ $( $env.defun($name, 1..=1, &docstring(&[$($doc),+]), {
            fn accessor(env: Env, args: &[Value]) -> Result<Value> {
                env.into_lisp(on_session(handle(env, args[0])?, $call))
            }
            accessor
        }) ),* ]
    };
}

/// Apply CALL to SESSION. A function rather than `(CALL)(SESSION)` in the macro, so that
/// a closure's parameter takes its type from this bound instead of needing an annotation.
fn on_session<R>(session: &Session, call: impl FnOnce(&Session) -> R) -> R {
    call(session)
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

    // Before any defun exists to be called: `Env::list`, `Env::cons` and `Env::nil` read
    // this table, and `defuns!` itself calls `defalias` through them. Failure here means
    // Emacs signalled during `intern`, which the trampoline has nothing to do with -- so
    // it surfaces the same way an ABI mismatch does rather than leaving a half-registered
    // module behind.
    if env.intern_symbols().is_err() {
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
        /// Returns a plist with :scrolled, :shifts, :rows, :height, :used, :head, :cursor,
        /// :reverse, :marks, :alt, :app-cursor, :keys, :kitty-flags, :modify-other-keys,
        /// :mode, :images, :links, :events and :exit.
        ///
        /// :scrolled and :rows are the same shape, so one renderer handles both: a block is
        /// (TEXT STYLES DECOS LINKS ROWS), where the spans carry character offsets into TEXT
        /// and appear only where there is something to say.  :scrolled is one block for the
        /// whole batch; :rows is an alist of (FIRST . BLOCK), one per run of contiguous
        /// damaged screen rows.  With REJOIN non-nil (the default), a line the terminal
        /// wrapped is emitted as one line rather than one per screen row.  :shifts lists the
        /// row moves to apply before :rows, whose indices are in post-shift coordinates.
        ///
        /// :height, :used and :head describe the grid's shape, so the buffer is shaped by what
        /// the emulator has rather than by a second opinion of it: the grid's row count, how many
        /// of those rows are occupied, and how many characters of screen row 0's logical line are
        /// already in the buffer above the screen.  The last is the seam, 0 unless the last row
        /// handed to scrollback was a wrapped one that row 0 continues.
        ///
        /// The fields are levels, the state as of this drain, and carry everything redisplay
        /// needs.  :events are occurrences, for what Emacs must react to that redisplay does
        /// not cover.  Nothing is sent both ways.  :marks, (ID . ANCHOR) per semantic mark a
        /// resize or redraw moved, is empty on almost every drain.
        ///
        /// :images and :links are neither, and must be consumed *before* :scrolled and :rows
        /// are rendered: they carry resources those rows refer to by id.  Each crosses once,
        /// however often the child sends or places it.
        "cooked--drain" 1..=2 => drain;

        /// Write STRING to the pty of SESSION.
        "cooked--send" 2..=2 => send;

        /// A VT filter with no terminal behind it, for a comint buffer.
        /// Holds a resumable parser, a pen and one line of cells; see `cooked--filter-feed'.
        /// Unrelated to a session: it spawns nothing, owns no pty, and is fed by whatever
        /// already has one.
        "cooked--make-filter" 0..=0 => make_filter;

        /// Resolve STRING through FILTER, returning (RETRACT TEXT STYLES LINKS DIRECTORY).
        ///
        /// Nil when the chunk asked for nothing -- an escape sequence with no text to show
        /// for it, which is what a shell sends around every prompt.
        ///
        /// TEXT is what the child's bytes actually said once carriage returns, backspaces,
        /// tabs and erases have been applied to the line they addressed -- a `\r' overwrites
        /// rather than deleting, which is the whole difference from `comint-carriage-motion'
        /// and from `ansi-color'. STYLES is the same packed span format a drain's blocks
        /// carry, so `cooked--face-packed' decodes both. LINKS is (START END URI) per `OSC 8'
        /// span, carrying the destination itself because there is no session here to resolve
        /// an id through. DIRECTORY is the last `OSC 7' URL of the chunk, or nil.
        ///
        /// RETRACT is how many characters immediately before the insertion point are no
        /// longer true and must be deleted before TEXT is inserted -- a line already handed
        /// over that the child has since rewritten. RETRACT-P is the caller's promise that
        /// those characters are still where it put them; with it nil the filter appends only
        /// what is new and takes nothing back.
        "cooked--filter-feed" 3..=3 => filter_feed;

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

        /// Tell SESSION that Emacs has edited its own text for screen row ROW.
        ///
        /// The core keeps a copy of what Emacs is showing, and leaves a damaged row out of
        /// the next drain when it matches that copy -- a program that erases a line and
        /// writes the same text back costs nothing.  An edit Lisp makes to a live row
        /// itself, such as the width guard deleting characters off a row that wrapped,
        /// makes the copy wrong for that row, and this says so: the row is sent the next
        /// time it is damaged, whatever it holds.  ROW nil forgets every row, for a theme
        /// change, after which a repaint of the same cells has to arrive in the new
        /// colours.
        "cooked--row-unsent" 2..=2 => row_unsent;

        /// Set SESSION's redisplay interval to MILLISECONDS and its backlog to LIMIT.
        ///
        /// Only the first is a pace, and cooked has exactly one of those: the frame ceiling
        /// derives from it and nothing else in the tree sets a rate.  LIMIT is not a rate --
        /// it decides who waits once Emacs has fallen behind, not how fast anything is drawn.
        ///
        /// The two knobs `cooked--spawn' takes, on a session already running, so
        /// `cooked-min-redisplay-interval' and `cooked-backlog-limit' mean the same thing
        /// whether they are set before a session starts or while it is going.  Both are
        /// taken in one call because they are tuned as a pair: a longer interval leaves
        /// more to accumulate between drains, so the queue fills sooner.
        ///
        /// The frame ceiling follows the interval, derived here exactly as it is at spawn,
        /// so the rule that a held frame is never held longer than one redisplay interval
        /// cannot come apart between the two paths.
        ///
        /// Nothing is woken and nothing already in flight is retired: a frame being held
        /// keeps the deadline it was given, which is at most one old interval, and the
        /// reader picks the new values up on its next turn through the loop.
        "cooked--set-tuning" 3..=3 => set_tuning;

        /// Tell SESSION whether anyone is looking at its buffer, as ATTENDED.
        ///
        /// Sets how often the reader thread re-reads the child's termios while the child
        /// is quiet: ten times a second when attended, once a second when not.  The tick
        /// exists to notice a mode change that moves the tty without writing a byte --
        /// `read -s' with no prompt -- and the only things that answer such a change are
        /// raising a password prompt and swapping a keymap, neither of which is worth
        /// anything to a buffer in no window.
        ///
        /// The stretch is not the last word on it.  Anything sent to the child restores
        /// the eager tick for half a second regardless of this, because a terminal in an
        /// unselected window is still one the user can scroll -- see `INTERACTION_WINDOW'
        /// in session.rs.  So the slow tick is what an *idle* unwatched session settles
        /// to, and nothing has to un-tell this to interact with a buffer.
        ///
        /// Safe to leave alone.  A session that is never told stays on the eager tick,
        /// and no keystroke depends on this either way: `cooked--sample-mode' reads the
        /// tty on the input path, which is the guarantee that a stale mode can never
        /// reach a typed character.
        "cooked--set-attended" 2..=2 => set_attended;

        /// Tell SESSION that Emacs renders SCHEME, either `dark' or `light'.
        ///
        /// Returns the bytes owed to a child that subscribed with DEC mode 2031, or nil when
        /// nothing is owed -- because no child asked, or because the theme was reloaded onto
        /// itself.  Sending them is the caller's, through `cooked--send-if-live': a theme
        /// change wakes no drain, and a child that has just exited is an ordinary race rather
        /// than an error.
        ///
        /// The value is held here so the core can answer `CSI ? 996 n' itself, the way it
        /// answers `CSI 14t' from the cell size: the child's query is answered where the
        /// query arrives, rather than by waking Lisp to ask about a theme it already said.
        "cooked--set-color-scheme" 2..=2 => set_color_scheme;

        /// Tell SESSION whether Emacs can show the pictures its child transmits.
        ///
        /// SHOWN nil withdraws the claim to graphics from every answer that makes one: the
        /// primary DA loses its `4', XTSMGRAPHICS answers failure, a kitty `a=q' probe is
        /// told `ENOTSUPPORTED', and an iTerm2 inline image is not drawn.  A producer that
        /// probes then picks its own half-block renderer, which shows something where a
        /// picture cooked cannot display would show nothing.  Held here, like the colour
        /// scheme, so each query is answered where it arrives.
        "cooked--set-graphics-shown" 2..=2 => set_graphics_shown;

        /// Send SIGNAL to SESSION's foreground group.
        ///
        /// SIGNAL is a symbol naming it -- `sigtstp', `sigcont' -- or, for a caller with a
        /// number already in hand, the number. Prefer the name: the numbers differ between
        /// Linux and the BSDs, and Lisp has no way to tell which it is running on. See
        /// `to_signal`.
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

        /// Tell SESSION that Emacs has dropped image ID's transmitted bytes.
        ///
        /// Emacs holds the only copy of an image -- see src/emu/image.rs -- and the module
        /// keeps just enough bookkeeping to answer "has Lisp seen these bytes before?".  This
        /// is what keeps that answer true: every path in cooked-deco.el that drops an image
        /// says so here, and the module then forgets the id, its content digest, its geometry
        /// and the client's own name for it.
        ///
        /// A later transmission of the same picture is then a picture the module has never
        /// seen: it mints a new id and the bytes cross again, which is what makes an
        /// animation whose frames Emacs has been evicting go on drawing.  A kitty client
        /// placing the old id by name (`a=p') is told `ENOENT:image', the same answer it
        /// would get for an id never transmitted, and the remedy is the same one.
        ///
        /// Cheap and safe to call for an id the module no longer has, which is ordinary:
        /// eviction is Emacs' decision and the module may have retired the id first.
        "cooked--image-forget" 2..=2 => image_forget;

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
        "cooked--forget-history" => |s| s.term().forget_history();

        /// Mark SESSION's whole screen damaged, so the next drain re-sends it.
        /// For recovering from a redisplay that failed part-way: an ordinary drain only reports
        /// what changed since the last one, so it cannot repair a buffer that is missing rows of
        /// a drain that signalled halfway through applying them.
        "cooked--redraw" => |s| s.term().touch_all();

        /// Remove the rows above SESSION's current prompt, returning how many went.
        ///
        /// The emulator's half of clearing the terminal.  Emacs deletes the scrollback,
        /// which is its own buffer text; the rows still on the grid are the emulator's, and
        /// which of them are above the prompt is a question only it can answer -- from the
        /// last OSC 133;A mark, falling back to the cursor's row when the shell never said.
        ///
        /// Returns 0 and does nothing on the alternate screen: that grid belongs to a
        /// running program, not to a transcript.
        "cooked--clear-to-prompt" => |s| s.term().clear_to_prompt();

        /// Tell SESSION that Emacs has finished drawing the last drain.
        ///
        /// Re-arms the wakeup: the core sends one wake byte and then stays quiet until this
        /// says the buffer is drawn, so the child's output accumulates in the emulator
        /// instead of buying a redisplay per write.  That is the whole of cooked's
        /// backpressure, and it is deliberately released here rather than at
        /// `cooked--drain' -- taking a delta is cheap, rendering it is not, and re-arming
        /// before the render would make `cooked-min-redisplay-interval' a floor that had
        /// always elapsed by the time it was consulted.
        ///
        /// Call it once per drain, from the cleanup of an `unwind-protect' rather than the
        /// body: a render that signals must still re-arm.  Failing to call it is slow
        /// rather than fatal -- the reader thread's own tick wakes Emacs instead, at
        /// roughly 100ms -- which is what makes the callers that never do (the benchmark,
        /// the tests that drain by hand) merely leisurely.
        "cooked--ready" => Session::ready;

        /// Text of the last non-blank line written by SESSION's child.
        /// Used as the minibuffer prompt when SESSION enters `secret' mode.
        "cooked--prompt-text" => |s| s.term().trailing_text();

        /// Process id of SESSION's child.
        "cooked--pid" => Session::pid;

        /// Whether SESSION's child is still running.
        "cooked--live-p" => Session::alive;

        /// Re-read SESSION's termios now and return the mode it reports.
        ///
        /// cooked's drain carries `:mode', which is what the reader thread last
        /// sampled -- as fresh as the poll interval and no fresher.  This forces a read
        /// instead, for the one caller that cannot afford a stale answer: the input path,
        /// before it lets a typed character into the buffer.
        ///
        /// A child that turns echo off without printing anything -- `read -s' with no
        /// prompt -- leaves nothing on the pty to wake anyone, so the cached mode goes on
        /// saying `cooked' while a password read is in progress.  Asking here, once per
        /// character, is what keeps that window from ever being a window.
        "cooked--sample-mode" => Session::sample_mode;

        /// Whether SESSION requested bracketed paste.
        "cooked--bracketed-paste-p" => |s| s.term().bracketed_paste();

        /// Whether SESSION asked to be told when the window gains or loses focus.
        "cooked--focus-events-p" => |s| s.term().focus_events();

        /// Whether a wheel notch on SESSION should be sent as cursor keys.
        "cooked--alt-scroll-p" => |s| s.term().alt_scroll();

        /// Tear SESSION's child down now and reap it.
        /// Returns t if this call ended the session, nil if it had already ended. Safe to call
        /// repeatedly. The child is sent SIGHUP, given a moment, then SIGKILL, so a process that
        /// ignores SIGHUP cannot outlive its buffer. Afterwards the handle is inert and garbage
        /// collecting it costs nothing.
        "cooked--kill" => Session::shutdown;
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

/// The longest list [`each`] will walk before giving up.
///
/// A cyclic list would otherwise spin forever on the thread holding the `emacs_env`,
/// wedging all of Emacs. `argv` and the environment alist are built by `cooked.el'
/// rather than by a child, so this guards against a bug on that side rather than a
/// hostile input, but the cost of getting it wrong is too high to take on trust.
const MAX_LIST_LEN: usize = 1 << 20;

/// Walk a proper list, handing each element to `f`.
///
/// `car`/`cdr` rather than `nth` per index: `nth` restarts at the head every time, which
/// makes reading a list quadratic in its length, and the environment alist is the
/// child's to grow.
fn each<T>(env: Env, mut list: Value, mut f: impl FnMut(Value) -> Result<T>) -> Result<Vec<T>> {
    let mut out = Vec::new();
    while !env.is_nil(list) {
        if out.len() >= MAX_LIST_LEN {
            return Err(env.signal("error", "cooked: list argument too long or improper"));
        }
        out.push(f(env.car(list)?)?);
        list = env.cdr(list)?;
    }
    Ok(out)
}

fn strings(env: Env, list: Value) -> Result<Vec<String>> {
    each(env, list, |item| env.from_lisp::<String>(item))
}

fn pairs(env: Env, alist: Value) -> Result<Vec<(String, String)>> {
    each(env, alist, |cell| {
        Ok((
            env.from_lisp::<String>(env.car(cell)?)?,
            env.from_lisp::<String>(env.cdr(cell)?)?,
        ))
    })
}

/// Turn a core error into a Lisp signal, at the point `?` would carry it.
///
/// An extension trait because there is no `impl From` to be had: the conversion needs an
/// `Env`, which the error does not carry. `Display` on [`crate::error::Error`] writes the
/// message.
trait OrSignal<T> {
    fn or_signal(self, env: Env) -> Result<T>;
}

impl<T> OrSignal<T> for std::result::Result<T, crate::error::Error> {
    fn or_signal(self, env: Env) -> Result<T> {
        self.map_err(|e| env.signal("cooked-error", &e.to_string()))
    }
}

fn set_tuning(env: Env, args: &[Value]) -> Result<Value> {
    let ms = env.from_lisp::<i64>(args[1])?.max(0) as u64;
    let limit = env.from_lisp::<i64>(args[2])?.max(1) as usize;
    handle(env, args[0])?.set_tuning(std::time::Duration::from_millis(ms), limit);
    Ok(env.nil())
}

fn spawn(env: Env, args: &[Value]) -> Result<Value> {
    let argv = strings(env, args[0])?;
    let vars = pairs(env, args[1])?;
    let size = Winsize {
        rows: env.from_lisp::<u16>(args[2])?.max(1),
        cols: env.from_lisp::<u16>(args[3])?.max(1),
        // Reported by the first resize rather than at spawn: the buffer usually has no
        // window yet here, so there is no font to measure.
        cell: None,
    };
    let wake = env.open_channel(args[4])?;
    let cwd = env.opt::<String>(args, 5)?;
    // The interval through the constructor, because the frame ceiling derives from it;
    // see `Options::with_min_redisplay_interval`.
    let defaults = match env.opt::<i64>(args, 6)? {
        Some(ms) => session::Options::with_min_redisplay_interval(
            std::time::Duration::from_millis(ms.max(0) as u64),
        ),
        None => session::Options::default(),
    };
    let options = session::Options {
        backlog_limit: env
            .opt::<i64>(args, 7)?
            .map_or(defaults.backlog_limit, |n| n.max(1) as usize),
        ..defaults
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
    let terminator = emu::Terminator::from_bell(!env.is_nil(args[3]));
    let Some(bytes) = emu::osc_reply(code, &payload, terminator) else {
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
        cell: CellMetrics::new(cell(3)?, cell(4)?),
    };
    handle(env, args[0])?.resize(size).or_signal(env)?;
    Ok(env.nil())
}

fn remove_rows(env: Env, args: &[Value]) -> Result<Value> {
    let first = env.from_lisp::<i64>(args[1])?.max(0) as usize;
    let count = env.from_lisp::<i64>(args[2])?.max(0) as usize;
    handle(env, args[0])?.term().remove_rows(first, count);
    Ok(env.nil())
}

fn row_unsent(env: Env, args: &[Value]) -> Result<Value> {
    // A negative row names no row, which is the same no-op as one past the bottom.
    let row = if env.is_nil(args[1]) {
        None
    } else {
        match usize::try_from(env.from_lisp::<i64>(args[1])?) {
            Ok(row) => Some(row),
            Err(_) => return Ok(env.nil()),
        }
    };
    handle(env, args[0])?.term().forget_sent(row);
    Ok(env.nil())
}

fn image_forget(env: Env, args: &[Value]) -> Result<Value> {
    // An id outside the module's own range is one it cannot hold, so it is the same
    // no-op as an id already retired.
    if let Ok(id) = u32::try_from(env.from_lisp::<i64>(args[1])?) {
        handle(env, args[0])?.term().forget_image(ImageId(id));
    }
    Ok(env.nil())
}

fn set_color_scheme(env: Env, args: &[Value]) -> Result<Value> {
    // Two symbols compared by identity: the protocol has exactly these two answers, and
    // anything else is the caller passing the wrong thing.
    let scheme = if env.eq(args[1], sym!(env, "dark")?) {
        ColorScheme::Dark
    } else if env.eq(args[1], sym!(env, "light")?) {
        ColorScheme::Light
    } else {
        return Err(env.signal_wrong_type("cooked-color-scheme-p", args[1]));
    };
    let owed = handle(env, args[0])?.term().set_color_scheme(scheme);
    env.into_lisp(owed.as_deref())
}

fn set_graphics_shown(env: Env, args: &[Value]) -> Result<Value> {
    // Nil-or-not, as `set_attended` reads its flag.
    let shown = env.from_lisp(args[1])?;
    handle(env, args[0])?.term().set_graphics_shown(shown);
    Ok(env.nil())
}

fn signal(env: Env, args: &[Value]) -> Result<Value> {
    let sig = to_signal(env, args[1])?;
    handle(env, args[0])?.signal(sig).or_signal(env)?;
    Ok(env.nil())
}

/// The signal named by a Lisp `sigtstp'-style symbol, or given as a raw number.
///
/// Names exist because the numbers are not portable: `SIGTSTP` is 20 on Linux and 18 on
/// the BSDs, where 20 is `SIGCHLD` and 18 is what Linux calls `SIGCONT`. A number written
/// in Lisp would suspend on one platform and do something else on the other, and this is
/// the side that links libc.
///
/// Numbers still work, validated here rather than in `Pty::signal`, so a number that is
/// not a signal gets the Lisp condition for a wrong argument rather than a
/// `cooked-error' string.
fn to_signal(env: Env, value: Value) -> Result<Signal> {
    // Asked before `from_lisp`, not after: a failed conversion leaves a non-local exit
    // pending on the Emacs side, and everything after it is a no-op until Lisp unwinds.
    // So there is no trying the number first and falling back to the name.
    if !env.is_nil(env.call("symbolp", &[value])?) {
        let name = env.from_lisp::<String>(env.call("symbol-name", &[value])?)?;
        return name
            .to_uppercase()
            .parse()
            .map_err(|_| env.signal("args-out-of-range", "not a signal name"));
    }
    // `try_from` rather than `as i32`: the cast wraps, so 4294967305 would arrive as 9
    // and kill the child outright. Lisp integers are wider than the signal number they
    // stand in for, and one that does not fit is a mistake to report rather than a bit
    // pattern to truncate.
    i32::try_from(env.from_lisp::<i64>(value)?)
        .ok()
        .and_then(|n| Signal::try_from(n).ok())
        .ok_or_else(|| env.signal("args-out-of-range", "not a signal number"))
}

/// Not an `accessors!` entry: those take the handle alone, and this carries a flag.
fn set_attended(env: Env, args: &[Value]) -> Result<Value> {
    // `from_lisp::<bool>` is nil-or-not rather than a type check, which is what a Lisp
    // caller means by a boolean -- so anything non-nil reads as attended and there is no
    // wrong value to report.
    handle(env, args[0])?.set_attended(env.from_lisp(args[1])?);
    Ok(env.nil())
}

fn job_control(env: Env, args: &[Value]) -> Result<Value> {
    let jc = handle(env, args[0])?.job_control().or_signal(env)?;
    let ch = |env: Env, c: Option<u8>| match c {
        Some(b) => env.into_lisp(b),
        None => Ok(env.nil()),
    };
    plist!(env, {
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

/// A grid-less VT filter, for a comint buffer that is not a terminal.
///
/// Wrapped in a `RefCell` because [`Env::get_user_ptr`] hands back a shared reference --
/// a session is behind a mutex and needs no more than that -- while a filter is plain
/// single-threaded state that a feed mutates. The cell is also the type tag Emacs
/// carries: a user-pointer holding a `Session` cannot be passed to these, because the
/// finalizer it was made with is a different function. See [`Env::get_user_ptr`].
type FilterCell = std::cell::RefCell<emu::stream::Filter>;

fn make_filter(env: Env, _args: &[Value]) -> Result<Value> {
    env.user_ptr(FilterCell::new(emu::stream::Filter::new()))
}

/// Resolve one chunk of a comint child's output; see `cooked--filter-feed'.
fn filter_feed(env: Env, args: &[Value]) -> Result<Value> {
    let filter = env.get_user_ptr::<FilterCell>(args[0])?;
    // The chunk arrives as an Emacs string rather than as bytes, because
    // `comint-preoutput-filter-functions' is handed output the process coding system has
    // already decoded, and Emacs is the one holding back a multibyte character split
    // across two reads. `copy_string_contents' re-encodes it as UTF-8 for the parser; a
    // byte the coding system could not decode reaches the parser as the invalid
    // sequence it is.
    let bytes = env.from_lisp::<Vec<u8>>(args[1])?;
    let retract = !env.is_nil(args[2]);
    let mut filter = filter
        .try_borrow_mut()
        .map_err(|_| env.signal("error", "cooked: this filter is already running"))?;
    filter.feed(&bytes, retract);
    emission_to_lisp(env, &filter)
}
