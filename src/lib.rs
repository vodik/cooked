//! cooked — a terminal emulator core for Emacs that knows when to get out of the way.
//!
//! Lisp entry points live here; everything below is plain Rust and unit-testable without
//! an Emacs in the loop.

pub mod emu;
pub(crate) mod env;
pub(crate) mod error;
pub(crate) mod platform;
pub(crate) mod pty;
pub(crate) mod session;

use emu::{
    Anchor, CellMetrics, Color, ColorScheme, CursorShape, Deco, Event, ImageData, ImageFormat,
    ImageId, KeyEncoding, LinkId, MarkId, Run, Style,
};
use env::{Env, Result, Runtime, Value, lisp_enum, list, plist, sym};
use nix::sys::signal::Signal;
use pty::{Mode, Pid, Winsize};
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

        /// Tell SESSION that Emacs has finished drawing the last drain.
        ///
        /// Re-arms the wakeup: the core sends one wake byte and then stays quiet until this
        /// says the buffer is drawn, so the child's output accumulates in the emulator
        /// instead of buying a redisplay per write.  That is the whole of cooked's
        /// backpressure, and it is deliberately released here rather than at
        /// `cooked--drain' -- taking a delta is cheap, rendering it is not, and re-arming
        /// before the render made `cooked-min-redisplay-interval' a floor that had always
        /// elapsed by the time it was consulted.
        ///
        /// Call it once per drain, from the cleanup of an `unwind-protect' rather than the
        /// body: a render that signals must still re-arm.  Failing to call it is slow
        /// rather than fatal -- the reader thread's own tick wakes Emacs instead, at
        /// roughly 100ms -- which is what makes the callers that never do (the benchmark,
        /// the tests that drain by hand) merely leisurely.
        "cooked--ready" => ready;

        /// Text of the last non-blank line written by SESSION's child.
        /// Used as the minibuffer prompt when SESSION enters `secret' mode.
        "cooked--prompt-text" => trailing_text;

        /// Process id of SESSION's child.
        "cooked--pid" => pid;

        /// Whether SESSION's child is still running.
        "cooked--live-p" => alive;

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
        "cooked--sample-mode" => sample_mode;

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

// Every enum this module sends as a bare symbol, and the symbol each variant is. One
// list per type, so the drain's `:mode' and `cooked--sample-mode' cannot drift into
// disagreeing about what to call the same state -- they now reach the same table through
// the same impl, where before one went through an impl here and the other interned
// `Mode::as_str' on its own.
lisp_enum! {
    Mode {
        Cooked => "cooked",
        Raw => "raw",
        Secret => "secret",
    }
    /// `cooked.el' maps these onto `cursor-type'.
    CursorShape {
        Block => "block",
        Underline => "underline",
        Bar => "bar",
    }
    /// What the child negotiated, which decides how a modified key is encoded on the way
    /// back. See [`KeyEncoding`] for why the default is the conservative one.
    KeyEncoding {
        Legacy => "legacy",
        ModifyOtherKeys => "modify-other",
        Kitty => "kitty",
    }
    /// The type symbol handed to `create-image'.
    ImageFormat {
        Png => "png",
        Jpeg => "jpeg",
        Gif => "gif",
        Ppm => "pbm",
    }
}

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
        cell: CellMetrics::default(),
    };
    let wake = env.open_channel(args[4])?;
    let cwd = env.opt::<String>(args, 5)?;
    // The interval through the constructor rather than as a field of a struct literal,
    // because the frame ceiling is derived from it and update syntax would compute that
    // from the default and then overwrite the interval it came from; see
    // `Options::with_min_redisplay_interval`. `backlog_limit` is nobody's derivation and
    // stays an ordinary field.
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

fn image_forget(env: Env, args: &[Value]) -> Result<Value> {
    // An id outside the module's own range is one it certainly does not hold, so it is
    // nothing to forget rather than something to signal about: the caller is handing back
    // an id the module gave it, and a number that could never have been one is the same
    // no-op as an id already retired.
    if let Ok(id) = u32::try_from(env.from_lisp::<i64>(args[1])?) {
        handle(env, args[0])?.forget_image(ImageId(id));
    }
    Ok(env.nil())
}

fn set_color_scheme(env: Env, args: &[Value]) -> Result<Value> {
    // Two symbols compared by identity rather than a `FromLisp` for a two-value enum:
    // the protocol has exactly these two answers, and anything else is the caller
    // passing the wrong thing rather than a scheme we have no name for.
    let scheme = if env.eq(args[1], sym!(env, "dark")?) {
        ColorScheme::Dark
    } else if env.eq(args[1], sym!(env, "light")?) {
        ColorScheme::Light
    } else {
        return Err(env.signal_wrong_type("cooked-color-scheme-p", args[1]));
    };
    let owed = handle(env, args[0])?.set_color_scheme(scheme);
    env.into_lisp(owed.as_deref())
}

fn signal(env: Env, args: &[Value]) -> Result<Value> {
    let sig = to_signal(env, args[1])?;
    handle(env, args[0])?.signal(sig).or_signal(env)?;
    Ok(env.nil())
}

/// The signal named by a Lisp `sigtstp'-style symbol, or given as a raw number.
///
/// Names exist because the numbers are not portable and Lisp cannot see which platform
/// it is on. `SIGTSTP` is 20 on Linux and 18 on the BSDs, where 20 is `SIGCHLD` and 18
/// is what Linux calls `SIGCONT` -- so a number written down in Lisp is right on one
/// platform and quietly wrong on the other. It was: `cooked-suspend' sent 20, which on
/// macOS is a `SIGCHLD' the child ignores, and `cooked-continue' sent 18, which there
/// stops the job it is supposed to restart. This is the side that links libc, so this is
/// the side that should be turning a name into a number.
///
/// Numbers still work, and are still validated here rather than inside `Pty::signal`:
/// that is the one caller whose number is untrusted, and one that is not a signal is the
/// caller passing the wrong thing, so it gets the Lisp condition for that rather than
/// being flattened into a `cooked-error' string.
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
    let cursor = list!(
        env,
        [
            update.delta.cursor.row,
            update.delta.cursor.col,
            update.delta.cursor_visible,
            update.delta.cursor_shape,
        ]
    )?;
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
        ":rows"       => rows,
        ":height"     => update.delta.height,
        ":used"       => update.delta.used,
        ":head"       => update.delta.head,
        ":cursor"     => cursor,
        ":marks"      => marks,
        ":alt"        => update.delta.alt,
        ":app-cursor" => update.delta.app_cursor,
        ":keys"       => update.delta.keys,
        ":mode"       => update.mode,
        ":images"     => images_to_lisp(env, &update.delta.images)?,
        ":links"      => links_to_lisp(env, &update.delta.links)?,
        ":events"     => events,
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
/// the primary screen — pays for no spans at all, not even an empty string, and a row of
/// eight styled runs costs one insert rather than eight. Sparseness survived the move to
/// packed records precisely because it is the property the flood path rests on: an
/// unstyled block still allocates nothing, and the `plain` benchmark row is the control
/// that says so.
///
/// STYLE-SPANS is a unibyte string of fixed-width records rather than a list, and it is
/// the only one carrying a rendition — see [`Block::push_style`] for the layout and for
/// why the live-row path cannot afford the conses. DECO-SPANS is `(START DECO)` and
/// LINK-SPANS `(START END ID)`, both for the same reason: neither says anything about
/// how its characters are *coloured*.
/// Emacs draws a box glyph in the colours of the face at the position it sits on, which
/// STYLE-SPANS has already put there over exactly those characters, so a decoration
/// span repeating them would be handing Lisp a second, staler answer to a question it
/// has already had — see `cooked--box-glyph-image-1' for what reading that second copy
/// cost. A hyperlink is the same story: whatever style it has is in STYLE-SPANS, and
/// Lisp deliberately leaves it alone.
///
/// A decoration span needs no END either: its packed records account for every
/// character it covers, whether one apiece or one per run of them — see
/// `deco_to_lisp`. The link id is resolved against the `:links` table the same drain
/// carries.
#[derive(Default)]
struct Block {
    text: String,
    styles: Vec<u8>,
    decos: Vec<Value>,
    links: Vec<Value>,
    offset: usize,
}

/// Bytes in one packed style span. See [`Block::push_style`] for the field layout.
const STYLE_RECORD: usize = 22;

impl Block {
    /// Pack one style span onto `styles`: the run's extent, its rendition, and its
    /// underline colour, as fixed-width little-endian fields.
    ///
    ///   0..4    START    `u32`, character offset into [`Block::text`]
    ///   4..8    END      `u32`, exclusive
    ///   8..12   FG       `u32`, tagged — see [`Color::packed`]
    ///   12..16  BG       `u32`, tagged
    ///   16..20  UNDERLINE `u32`, tagged; `SGR 58`, the underline's own colour
    ///   20..22  ATTRS    `u16`, the [`Attrs`](emu::cell::Attrs) bitmask
    ///
    /// A packed string rather than a list of lists, for the reason [`Deco::packed`]
    /// gives at greater length: Rust parses at 74-422 MB/s while the Emacs apply path
    /// manages roughly 21 MB/s equivalent, so anything the protocol declines to say
    /// outright is rediscovered on the slow side, on every damaged row of every frame.
    /// A span used to cross as `(START END FG BG ATTRS UNDERLINE)` — six conses, and up
    /// to twelve once an RGB colour spelled itself as a three-element list.
    ///
    /// Measured 1.20 -> 1.03 ms/frame on a 24x80 frame of eight-run rows, three runs
    /// either side at a background load of ~2. That is about 0.9us of the 6.5us a span
    /// cost, and it is worth writing down that the estimate which motivated this change
    /// was three times larger: attribution had put ~3.5us of the 6.5 in construction and
    /// marshalling, on the reasoning that `cooked--face' was 1.1us and
    /// `put-text-property' 1.8us. The missing three quarters are that the two of those
    /// dominate more of the remainder than subtracting them suggested, and that building
    /// a short list on the Rust side was never as expensive as the Lisp-side allocation
    /// it was grouped with. The saving is real and the direction was right; the size was
    /// not, and a microbenchmark also under-counts what it removes, since ~1500-2300
    /// fewer cons cells per frame is collector pressure that shows up later and
    /// elsewhere.
    ///
    /// **START and END are `u32`, and that is not over-provisioning.** A `u16` is the
    /// trap here and it fails silently. [`Update::scrolled_rows`] assembles a whole
    /// drain's scrollback into *one* `Block`, so offsets are not bounded by a row or
    /// even by a screen: the flood benchmark reaches 200k characters in a single block
    /// and a 20k-line paste goes past 600k. A `u16` start would wrap at 65536 and hand
    /// Lisp a span that styles the wrong characters, with no error anywhere to point at
    /// — the buffer would simply come out miscoloured somewhere far from the cause.
    ///
    /// A span whose offsets do not fit is dropped rather than truncated. It is not
    /// reachable — 4.29 billion characters would have to arrive between two drains —
    /// but the two failure modes are not equally bad, and the choice should be the
    /// deliberate one: dropping loses the colour of a run that is already off the far
    /// end of anything a user can see, while clamping would paint it over text that is
    /// on screen. Wrong-but-plausible is the expensive kind of wrong.
    ///
    /// The rendition is packed inline rather than interned behind an id minted through
    /// [`Ledger`](emu::intern::Ledger), the way `:links` and `:images` are. Interning
    /// would save Lisp about three `u32` decodes per span and cost it an id lifetime:
    /// ids are per-session, so Lisp would need a reset on session start — the hazard
    /// `cooked--cached' warns about — and the ledger's cap means eviction must either
    /// never reuse an id or announce when it does. A reused id read against a stale
    /// Lisp cache is wrong colours with no error, which is the same silent-miscolouring
    /// failure the `u32` offsets are chosen to avoid. Three decodes is not worth buying
    /// that.
    fn push_style(&mut self, chars: usize, style: Style, underline: Color) {
        let (Ok(start), Ok(end)) = (
            u32::try_from(self.offset),
            u32::try_from(self.offset + chars),
        ) else {
            return;
        };
        let Style { fg, bg, attrs } = style;
        self.styles.extend_from_slice(&start.to_le_bytes());
        self.styles.extend_from_slice(&end.to_le_bytes());
        self.styles.extend_from_slice(&fg.packed().to_le_bytes());
        self.styles.extend_from_slice(&bg.packed().to_le_bytes());
        self.styles
            .extend_from_slice(&underline.packed().to_le_bytes());
        self.styles.extend_from_slice(&attrs.bits().to_le_bytes());
        // The stride is the format: Lisp walks the packed string by adding
        // [`STYLE_RECORD`] and never by decoding a length, so a field added to the
        // record without widening the constant would desynchronise the two sides at the
        // second span of the first styled row.
        debug_assert_eq!(
            self.styles.len() % STYLE_RECORD,
            0,
            "a style record must be exactly {STYLE_RECORD} bytes"
        );
    }

    /// Append RUNS, emitting spans only where there is something to say.
    fn push_runs(&mut self, env: Env, runs: &[Run]) -> Result<()> {
        for run in runs {
            let chars = run.text.chars().count();
            if run.style != Style::default() || run.underline != Color::Default {
                self.push_style(chars, run.style, run.underline);
            }
            if let Some(link) = run.link {
                self.links
                    .push(list!(env, [self.offset, self.offset + chars, link])?);
            }
            if run.deco.is_some() {
                let deco = env.into_lisp(run.deco.as_ref())?;
                self.decos.push(list!(env, [self.offset, deco])?);
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
        list!(
            *env,
            [
                self.text.as_str(),
                self.styles.as_slice(),
                self.decos,
                self.links
            ]
        )
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
                sym!(env, "screen")?,
                env.cons(env.into_lisp(at.row - on_grid)?, env.into_lisp(at.col)?)?,
            );
        }
        match at.row.checked_sub(base).and_then(|i| rows.get(i)) {
            // Trailing blanks are trimmed out of the runs, so a column past the end of
            // what the row actually kept is clamped rather than run off the line.
            Some(row) => env.cons(
                sym!(env, "scrolled")?,
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
            list!(
                env,
                [
                    image.id,
                    image.format,
                    image.bytes.as_slice(),
                    image.px.w,
                    image.px.h,
                ]
            )
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
/// fixed-width little-endian records covering the run's text. The kind is carried once
/// for the run rather than per character because a run is homogeneous in it — see
/// [`Deco`] — which is what keeps the record narrow:
///
///   `glyph`   four bytes per *run of identical shapes*: a `BoxGlyph` bit pattern and
///             the number of consecutive characters drawing it, both `u16`. A border
///             row is one record, not eighty.
///   `image`   twelve bytes per *character*: a `u32` image id, then the cell's row and
///             column within that image, then the rectangle that placement was laid at,
///             as `u16`s.
///
/// That the two kinds count differently is the point rather than an inconsistency, and
/// [`Deco::packed`] argues it: a glyph run is genuinely one decision repeated, while
/// every cell of a picture displays its own slice and so needs its own record whatever
/// the wire says. Compressing the wire where Lisp must decompress it again immediately
/// would move nothing off the side that is actually slow.
///
/// The rectangle is repeated on every image cell rather than carried once per image
/// because it belongs to the placement — see [`Placement`](emu::image::Placement). Four
/// bytes a cell against a picture's own megabytes, and it is what lets two placements of
/// one id at two sizes both draw correctly.
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
        // The bytes are [`Deco::packed`]'s, which is where the record layouts are
        // written down and where the tests that pin them can reach them; what belongs
        // here is only the kind tag, because `sym!' needs its literal at the call site
        // to do the lookup at compile time.
        let packed = env.into_lisp(deco.packed().as_slice())?;
        match deco {
            Deco::Glyphs(_) => env.cons(sym!(env, "glyph")?, packed),
            Deco::Images(_) => env.cons(sym!(env, "image")?, packed),
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
    // The tag arrives already resolved, because `sym!` needs the literal at its own
    // call site to do the lookup at compile time -- which is the point of it.
    let mark = |name: Value, at: Anchor, id: MarkId| {
        list!(env, [name, update.anchor_to_lisp(env, at, rows)?, id])
    };
    match event {
        Event::Bell => list!(env, [sym!(env, "bell")?]),
        // (osc CODE BELL-P PART...) — Lisp decides what the code means. BELL-P is
        // opaque to the handler: it hands it back to `cooked--reply-osc' if it answers.
        Event::Osc(code, parts, bell) => {
            let mut items = vec![
                sym!(env, "osc")?,
                env.into_lisp(*code)?,
                env.into_lisp(*bell)?,
            ];
            for part in parts {
                items.push(env.into_lisp(part.as_str())?);
            }
            env.into_lisp(items)
        }
        Event::PromptStart(at, id) => mark(sym!(env, "prompt-start")?, *at, *id),
        Event::PromptContinuation(at, id) => mark(sym!(env, "prompt-continuation")?, *at, *id),
        Event::PromptEnd(at, id) => mark(sym!(env, "prompt-end")?, *at, *id),
        // (command-start CMDLINE ANCHOR ID), CMDLINE nil when the shell did not say.
        Event::CommandStart(cmdline, at, id) => list!(
            env,
            [
                sym!(env, "command-start")?,
                cmdline.as_deref(),
                update.anchor_to_lisp(env, *at, rows)?,
                *id,
            ]
        ),
        Event::CommandEnd(code, at, id) => list!(
            env,
            [
                sym!(env, "command-end")?,
                code.map(i64::from),
                update.anchor_to_lisp(env, *at, rows)?,
                *id,
            ]
        ),
        // (mouse ENABLED SGR DRAG MOTION). Flattening this to a single "wants the
        // mouse" bit lost the reach of the request: 1002 and 1003 ask to be told
        // where the pointer went, not merely which cell it was pressed in, and the
        // sender cannot manufacture motion reports it was never told to send.
        Event::Mouse(m) => list!(
            env,
            [sym!(env, "mouse")?, m.enabled(), m.sgr, m.drag, m.motion,]
        ),
        Event::Reply(bytes) => env.cons(sym!(env, "reply")?, env.into_lisp(bytes.as_slice())?),
        Event::EraseScrollback => list!(env, [sym!(env, "erase-scrollback")?]),
        Event::DisplayCleared => list!(env, [sym!(env, "display-cleared")?]),
        // (title-stack PUSH-P)
        Event::TitleStack(push) => list!(env, [sym!(env, "title-stack")?, *push]),
    }
}

/// [`Block::push_style`] needs no `Env`: it writes bytes into a `Vec`, and the format is
/// the whole of what it decides. So the layout both sides have to agree on forever is
/// pinned here, without an Emacs in the loop -- which is the same reason the rest of the
/// crate is testable, applied to the one file that usually is not.
#[cfg(test)]
mod tests {
    use super::*;
    use emu::cell::Attrs;
    use emu::{Color, Style};

    /// The trailing fields of a record, as a `Block` holding exactly one would have them.
    fn record(style: Style, underline: Color) -> Vec<u8> {
        let mut block = Block {
            offset: 0,
            ..Default::default()
        };
        block.push_style(1, style, underline);
        block.styles
    }

    fn u32_at(bytes: &[u8], at: usize) -> u32 {
        u32::from_le_bytes(bytes[at..at + 4].try_into().unwrap())
    }

    #[test]
    fn a_style_record_is_exactly_the_stride_lisp_steps_by() {
        let packed = record(Style::default(), Color::Default);
        assert_eq!(
            packed.len(),
            STYLE_RECORD,
            "`cooked--style-record' in cooked.el is this number: {packed:?}"
        );
    }

    #[test]
    fn each_colour_variant_survives_the_round_trip_through_a_record() {
        // The three tags `cooked--color-spec' in cooked-face.el decodes, in the layout
        // its docstring states: tag in the top byte, value in the low three.
        for (colour, expected) in [
            (Color::Default, 0u32),
            (Color::Indexed(0), 1 << 24),
            (Color::Indexed(255), (1 << 24) | 255),
            (Color::Rgb(0x12, 0x34, 0x56), (2 << 24) | 0x123456),
        ] {
            let packed = record(
                Style {
                    fg: colour,
                    ..Style::default()
                },
                Color::Default,
            );
            assert_eq!(u32_at(&packed, 8), expected, "fg {colour:?}: {packed:?}");
        }
    }

    #[test]
    fn the_underline_colour_has_its_own_field_and_does_not_alias_the_foreground() {
        // `SGR 58' is a colour of its own, and it shared a slot with nothing before the
        // record existed -- it rode a tail cons. A field that aliased fg would show up
        // only on text that is both coloured and underlined, which is rare enough to
        // ship.
        let packed = record(
            Style {
                fg: Color::Indexed(1),
                bg: Color::Indexed(2),
                attrs: Attrs::UNDERLINE,
            },
            Color::Indexed(3),
        );
        assert_eq!(u32_at(&packed, 8), (1 << 24) | 1, "fg");
        assert_eq!(u32_at(&packed, 12), (1 << 24) | 2, "bg");
        assert_eq!(u32_at(&packed, 16), (1 << 24) | 3, "underline");
        assert_eq!(
            u16::from_le_bytes([packed[20], packed[21]]),
            Attrs::UNDERLINE.bits(),
            "attrs"
        );
    }

    /// The `u16` trap the field widths exist to avoid, stated as a test rather than only
    /// as a comment. `Update::scrolled_rows` assembles a whole drain's scrollback into
    /// one `Block`, so an offset is bounded by the flood rather than by a row: a `u16`
    /// start would wrap at 65536 and style the wrong characters, with nothing anywhere
    /// to point at.
    #[test]
    fn an_offset_past_a_u16_packs_at_full_width_rather_than_wrapping() {
        let mut block = Block {
            offset: 70_000,
            ..Default::default()
        };
        block.push_style(5, Style::default(), Color::Default);
        assert_eq!(u32_at(&block.styles, 0), 70_000, "start");
        assert_eq!(u32_at(&block.styles, 4), 70_005, "end");
    }

    /// Dropped rather than truncated, which is the deliberate half of the choice: a lost
    /// colour is invisible off the far end of a flood, while a clamped one would paint
    /// over text that is on screen. Unreachable in practice -- it takes four billion
    /// characters between two drains -- so the only thing that can keep it right is this.
    #[test]
    fn a_span_whose_offsets_do_not_fit_is_dropped_and_never_clamped() {
        let mut block = Block {
            offset: usize::try_from(u32::MAX).unwrap(),
            ..Default::default()
        };
        block.push_style(2, Style::default(), Color::Default);
        assert!(
            block.styles.is_empty(),
            "an unrepresentable span leaves no record: {:?}",
            block.styles
        );
    }
}
