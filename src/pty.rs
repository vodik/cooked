//! Pseudoterminal ownership, and the line-discipline signal the rest of cooked is built on.
//!
//! We allocate the pty ourselves rather than letting Emacs do it, because only the master
//! fd exposes the child's termios via [`Pty::mode`].
//!
//! Note that neither kernel pushes a termios change to the master. Packet mode
//! (`TIOCPKT`) reports flow control and flushes, and reports a `tcsetattr` only while
//! `EXTPROC` is set in the slave's `c_lflag`. That flag looks like the answer and is
//! not: it means "the line is edited elsewhere", and both line disciplines then hand
//! every byte straight to the reader -- no echo, no erase, no `ISIG`, so a typed line
//! never appears in the transcript and `^C` stops being an interrupt. Tried, and the
//! echo tests failed at once. So `ICANON`/`ECHO` changes are silent and callers sample
//! [`Pty::mode`]; the reader thread already wakes on a poll timeout, which makes sampling
//! free in practice, and takes an extra sample after output for the common `getpass`.
//! See `session::read_loop`.

//! Parent-side syscalls go through `nix`, so failures arrive as `Result` and termios and
//! wait statuses as types rather than bit patterns. The one exception is `child_exec`,
//! which runs between `fork` and `exec` and must stay allocation-free; see the comment
//! there for why no wrapper is safe in that window.

use crate::error::{Error, Result};
use crate::lock::LockExt;
use nix::errno::Errno;
use nix::fcntl::{FcntlArg, FdFlag, OFlag, fcntl};
use nix::libc;
use nix::poll::{PollFd, PollFlags, PollTimeout};
use nix::pty::{PtyMaster, grantpt, posix_openpt, unlockpt};
use nix::sys::signal::{Signal, killpg};
use nix::sys::termios::{LocalFlags, SpecialCharacterIndices, Termios, tcgetattr};
use nix::sys::wait::{WaitPidFlag, WaitStatus, waitpid};
use nix::unistd::{AccessFlags, Pid, access, tcgetpgrp};
use std::ffi::{CStr, CString, OsStr};
use std::os::fd::{AsFd, AsRawFd, BorrowedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

use crate::emu::CellMetrics;
use crate::platform;

/// What the child is currently asking the tty for.
///
/// The three states are disjoint and exactly identify intent: no full-screen program runs
/// canonically, and nothing but a secret read disables echo while keeping canonical mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
#[repr(u8)]
pub(crate) enum Mode {
    /// `ICANON | ECHO` — the kernel is line-editing; Emacs should own the input region.
    #[default]
    Cooked,
    /// `!ICANON` — a full-screen application; pass every keystroke through untouched.
    Raw,
    /// `ICANON & !ECHO` — `getpass(3)` and friends. Prompt in the minibuffer.
    Secret,
}

/// The tty's job-control characters, and whether the line discipline still acts on them.
///
/// A terminal does not send signals. It writes one of these bytes and lets the line
/// discipline decide what that means — which is why `stty intr ^X` works at all, and why
/// assuming `^C`/`^\`/`^Z` is a guess about state we can simply read. `isig` is the other
/// half: with `ISIG` cleared the byte reaches the child verbatim instead of becoming a
/// signal, and a program that cleared it did so precisely to read the byte itself.
///
/// `None` means the character is disabled (`_POSIX_VDISABLE`), so there is nothing to send
/// and a caller with a signal to fall back on should use it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct JobControl {
    pub intr: Option<u8>,
    pub quit: Option<u8>,
    pub susp: Option<u8>,
    /// End-of-file. Unlike the three above this is not a signal character and `isig` says
    /// nothing about it: `ICANON` is what decides whether the line discipline turns it
    /// into end-of-input, and a raw-mode program simply reads the byte. So there is
    /// nothing to fall back to — send it or send nothing.
    pub eof: Option<u8>,
    pub isig: bool,
}

impl From<&Termios> for JobControl {
    fn from(t: &Termios) -> Self {
        let cc = |i: SpecialCharacterIndices| match t.control_chars[i as usize] {
            platform::POSIX_VDISABLE => None,
            byte => Some(byte),
        };
        Self {
            intr: cc(SpecialCharacterIndices::VINTR),
            quit: cc(SpecialCharacterIndices::VQUIT),
            susp: cc(SpecialCharacterIndices::VSUSP),
            eof: cc(SpecialCharacterIndices::VEOF),
            isig: t.local_flags.contains(LocalFlags::ISIG),
        }
    }
}

impl From<&Termios> for Mode {
    fn from(t: &Termios) -> Self {
        let flags = t.local_flags;
        match (
            flags.contains(LocalFlags::ICANON),
            flags.contains(LocalFlags::ECHO),
        ) {
            (true, true) => Self::Cooked,
            (true, false) => Self::Secret,
            (false, _) => Self::Raw,
        }
    }
}

impl TryFrom<u8> for Mode {
    type Error = u8;

    fn try_from(n: u8) -> std::result::Result<Self, u8> {
        match n {
            0 => Ok(Self::Cooked),
            1 => Ok(Self::Raw),
            2 => Ok(Self::Secret),
            other => Err(other),
        }
    }
}

/// A [`Mode`] readable from the reader thread and Emacs' thread alike.
///
/// Lives beside the enum rather than at the use site because it is the discriminant that
/// makes it work: `Mode` is `#[repr(u8)]`, so `as u8` and [`Mode::try_from`] are inverses
/// by declaration rather than by a match that happens to agree with the variant order.
#[derive(Debug)]
pub(crate) struct AtomicMode(std::sync::atomic::AtomicU8);

impl AtomicMode {
    pub(crate) fn new(mode: Mode) -> Self {
        Self(std::sync::atomic::AtomicU8::new(mode as u8))
    }

    pub(crate) fn load(&self) -> Mode {
        let raw = self.0.load(std::sync::atomic::Ordering::Relaxed);
        // Only `store` ever writes here, and it writes a discriminant.
        Mode::try_from(raw).unwrap_or_default()
    }

    pub(crate) fn store(&self, mode: Mode) {
        self.0
            .store(mode as u8, std::sync::atomic::Ordering::Relaxed);
    }
}

/// What the child's tty has in the foreground: the process group holding it, and the
/// program that group's leader is running.
///
/// Both together, because neither half answers the question on its own. The group is what
/// a keystroke reaches and what `tcgetpgrp` reports, and it changes when a job-control
/// shell hands the terminal over. The name is what `cooked-key-protocol-overrides' and
/// the mode line match on, and it changes without the group doing so every time a shell
/// `exec`s into the command it just read -- `sh -c 'exec cat'` is one pid from start to
/// finish and two programs.
///
/// A struct rather than a pair so that the two are sampled and compared as one fact: a
/// change in either is a change in what is running, and `Shared::sample_foreground` --
/// which is what samples it, on the reader's idle tick -- needs no rule about which half
/// to look at first.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Foreground {
    pub pgrp: Pid,
    /// `None` where the platform declines to say or the group has already gone; see
    /// [`crate::platform::process_name`].
    pub name: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Winsize {
    pub rows: u16,
    pub cols: u16,
    /// One cell in pixels, or `None` when unreported.
    ///
    /// A terminal frame has no such thing, and the tty is then told zero pixels, which
    /// is how `winsize` says "not reported". On a graphical frame it is the
    /// font's, and it moves with `text-scale-mode` as well as with the font — so it is
    /// reported alongside the row and column count rather than sampled once.
    ///
    /// The child needs it: an image protocol sizes a transmission in pixels, and tools
    /// consult `ws_xpixel`/`ws_ypixel` — or the XTWINOPS reports built from them —
    /// before deciding whether to draw a picture at all.
    pub cell: Option<CellMetrics>,
}

impl Winsize {
    /// ROWS by COLS, with no cell size reported -- what a terminal frame's window is, and
    /// what a graphical one is before its first resize has measured a font.
    pub fn new(rows: u16, cols: u16) -> Self {
        Self {
            rows,
            cols,
            cell: None,
        }
    }

    /// The same size, with CELL as the font's measured size.
    pub fn with_cell(self, cell: CellMetrics) -> Self {
        Self {
            cell: Some(cell),
            ..self
        }
    }
}

impl From<Winsize> for libc::winsize {
    fn from(w: Winsize) -> Self {
        Self {
            ws_row: w.rows,
            ws_col: w.cols,
            // The text area, which is what these fields mean: cells times cell size.
            ws_xpixel: w.cell.map_or(0, |cell| w.cols.saturating_mul(cell.width())),
            ws_ypixel: w
                .cell
                .map_or(0, |cell| w.rows.saturating_mul(cell.height())),
        }
    }
}

/// The descriptors a pty holds: the master end, and the kernel's word on when the child
/// exits.
///
/// Behind one [`Arc`](std::sync::Arc) so that [`Pty::close`] can release them all the moment the session
/// is over, and so that a thread already inside a call keeps them alive for the length of
/// it. The reader polls the master on a thread [`crate::session::Session::shutdown`]
/// deliberately does not join, so an fd closed out from under it would be one the kernel
/// is free to hand straight back for the next session's pty -- and the reader would then
/// be polling somebody else's child. Holding an `Arc` for the call is what makes the
/// close wait for the last user rather than race it.
#[derive(Debug)]
pub(crate) struct Fds {
    pub(crate) master: PtyMaster,
    /// Says when the child has exited, where the platform can; see
    /// [`platform::ExitWatch`]. What lets [`Pty::reap`] wait on the kernel instead of
    /// on a timer.
    exit_watch: Option<platform::ExitWatch>,
}

/// The right to write to the child: the master end, as the half of it that sends.
///
/// The same descriptor [`Pty::fds`] hands out, behind a type only [`Pty::write_half`] can
/// produce — and only for as long as [`Pty::take_write_half`] has not taken it. That is
/// the whole point of it being a type rather than a flag: teardown begins by taking the
/// write half away, so a `Session::send`, a queued reply or a resize arriving afterwards
/// has nothing to borrow and answers [`Error::Closed`], while the reader keeps the
/// descriptors it polls, reads and waits for the exit on until it has reaped the child.
/// There is no spelling for writing to a child teardown has already hung up on.
///
/// A clone of the `Arc` rather than a borrow through the lock, exactly as [`Pty::fds`] is:
/// the lock is a leaf, and a write already in flight when teardown arrives finishes on the
/// half it took out rather than being cut in two.
#[derive(Debug, Clone)]
pub(crate) struct WriteHalf(std::sync::Arc<Fds>);

/// A forked child attached to a pty we own the master end of.
#[derive(Debug)]
pub(crate) struct Pty {
    /// `None` once [`Pty::close`] has released them; see [`Fds`].
    fds: std::sync::Mutex<Option<std::sync::Arc<Fds>>>,
    /// The right to write, which teardown takes back before the descriptors; see
    /// [`WriteHalf`].
    write: std::sync::Mutex<Option<WriteHalf>>,
    /// The pid the fork returned, which outlives the child: `cooked--pid' answers with it
    /// after the exit, and [`Child::Collected`] is what says it is no longer ours to aim
    /// a signal at.
    child: Pid,
    /// Whether the child is still ours, and what it exited with once it is not; see
    /// [`Child`] and [`Live`].
    state: std::sync::Mutex<Child>,
}

/// Whether the child is still ours to signal.
///
/// One state under one lock, where there were three fields beside each other: a `reaped`
/// flag, the `collected` status written before it so that whoever saw the flag could read
/// the status behind it, and a `reap_lock` serialising `signal`'s
/// reaped-check-then-`killpg` against `waitpid`'s own reaped-check-then-collect. The
/// order between the first two was a comment, and the third existed only because the
/// other two could be read apart: a `cooked--signal' on Emacs' thread could see the flag
/// clear, have the reader's `waitpid` collect the child -- freeing its pid for reuse -- in
/// the gap, and `killpg` a process group the kernel had since handed to something else.
///
/// Now there is nothing to keep in order and nothing to remember to check: the pid is
/// reachable only through [`Live`], which is this lock held on `Running`, and `waitpid` is
/// the same lock. Both critical sections are one `killpg` or one `WNOHANG` `waitpid`,
/// never blocking, so holding it across either is always short.
#[derive(Debug)]
enum Child {
    /// Running, or a zombie nobody has collected: the pid is ours and a signal reaches it
    /// and nothing else.
    Running,
    /// What `waitpid` collected, for whoever did not collect it.
    ///
    /// `waitpid` hands a status to exactly one caller, and since `Session::shutdown`
    /// stopped joining the reader either thread may be that caller. The loser needs the
    /// real status all the same -- `Session::alive` answers from it -- and without this it
    /// had only `Exit::Lost` to record, or nothing at all, which would leave a killed
    /// session reporting itself alive for as long as the winner took to write the status
    /// down.
    Collected(i32),
}

/// The child while it is still ours, with the lock that keeps it so held.
///
/// A signal aims at a pid, and a pid the kernel has taken back belongs to whatever it was
/// handed to next -- which is why `killpg` after the reap is the one thing this file must
/// make impossible rather than merely refuse. So the target is not a field anyone can
/// reach: it is behind [`Pty::live`], which answers [`Error::Reaped`] once the child has
/// been collected, and which holds the lock `waitpid` needs for as long as the caller
/// holds it. There is no spelling for signalling a reaped pid.
///
/// The descriptors are taken under this and never the other way round: `Pty::signal`
/// reads the foreground group and asks the platform to deliver while it holds the child,
/// and the `fds` lock is a leaf everywhere, cloned out and let go in the one expression.
struct Live<'a> {
    pid: Pid,
    /// The child, still `Running` for as long as this lives.
    _held: std::sync::MutexGuard<'a, Child>,
}

impl Live<'_> {
    /// The child's own pid, which is also its process group: `Pty::spawn` puts it in a
    /// session of its own.
    fn pid(&self) -> Pid {
        self.pid
    }

    /// `killpg` TARGET, refusing anything that could reach our own process group.
    ///
    /// The guard is not paranoia: `tcgetpgrp` can report 0 once the session is gone, and
    /// `kill(-0, ...)` means "my own process group" — which here is Emacs.
    fn signal(&self, target: Pid, sig: Signal) -> Result<()> {
        match target {
            // `killpg` rather than `kill(-pid)`, which one missed negation turns into a
            // signal to the wrong process.
            target if target.as_raw() > 1 => Ok(killpg(target, sig)?),
            _ => Err(Error::NoForeground),
        }
    }
}

/// How long [`WriteHalf::write`] waits on a child that is not draining its input before it
/// gives up and reports an error rather than blocking Emacs' single thread further.
/// Generous enough that a legitimate large bracketed paste to a briefly slow reader
/// (a shell about to start echoing) never trips it; short enough that a genuinely
/// stopped job (`C-z`) turns into a prompt error instead of a frozen editor.
pub(crate) const WRITE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(3);

/// Cap a remaining-time budget to what [`nix::poll::poll`] accepts, without waiting past
/// the deadline computed from [`WRITE_TIMEOUT`].
fn poll_timeout(remaining: std::time::Duration) -> PollTimeout {
    PollTimeout::try_from(remaining).unwrap_or(PollTimeout::MAX)
}

/// How often a wait on the child asks whether it should stop early; see [`Wait`].
///
/// Fifty milliseconds is below what a person notices between pressing `C-g` and the
/// editor answering, and far above the cost of the question, which is one call.
const STOP_CHECK: std::time::Duration = std::time::Duration::from_millis(50);

/// How long a write to the child may block, and who may cut it short.
///
/// A deadline, and a question asked every [`STOP_CHECK`] while the deadline has not
/// passed. The question is for the thread holding the `emacs_env`: `should_quit` says the
/// user pressed `C-g`, and a paste into a stopped job should stop then rather than three
/// seconds later. A caller with nothing to ask passes `&|| false`.
///
/// The time is asked for the same way, and for the same reason the deadlines in
/// `session.rs` are read through a `Clock`: a test that waits out real seconds to watch
/// this one fire is a test that can be wrong about time. NOW is the session's clock, so
/// `a_write_the_child_never_takes_ends_at_the_deadline` steps the deadline past rather
/// than sitting through [`WRITE_TIMEOUT`].
pub(crate) struct Wait<'a> {
    deadline: std::time::Instant,
    now: &'a dyn Fn() -> std::time::Instant,
    stop: &'a dyn Fn() -> bool,
}

impl<'a> Wait<'a> {
    /// Wait BUDGET from NOW's reading of the clock, asking NOW and STOP along the way.
    pub(crate) fn new(
        budget: std::time::Duration,
        now: &'a dyn Fn() -> std::time::Instant,
        stop: &'a dyn Fn() -> bool,
    ) -> Self {
        Self {
            deadline: now() + budget,
            now,
            stop,
        }
    }

    /// The error to give up with now, if any: the deadline has passed, or STOP says so.
    fn check(&self) -> Result<std::time::Duration> {
        let remaining = self.deadline.saturating_duration_since((self.now)());
        if remaining.is_zero() {
            return Err(Error::WriteTimeout);
        }
        if (self.stop)() {
            return Err(Error::Interrupted);
        }
        Ok(remaining.min(STOP_CHECK))
    }

    /// How long one blocking call may last now, or `None` once there is no waiting left
    /// to do -- the deadline has passed, or STOP says to stop.
    ///
    /// [`Self::check`] with the two reasons collapsed into one, for [`Pty::reap`], which
    /// has nothing to report about *why* it stopped waiting: a reap that runs out of
    /// patience and a reap the caller cut short both answer "not reapable yet".
    fn slice(&self) -> Option<std::time::Duration> {
        self.check().ok()
    }
}

/// How long a hung-up child has to exit on its own before it is killed.
///
/// What a closing terminal window gives its shell, and it has to cover what a shell does
/// on SIGHUP: forward it to its jobs, write its history, run its exit hooks. A shell
/// killed part-way through loses the history of the session, so the figure is chosen
/// from measurement rather than from taste. An interactive bash and an interactive zsh,
/// each with a three-thousand line history file, a `HUP` trap that writes it and an
/// `EXIT` trap that writes it again, hung up exactly the way [`Pty::hangup`] does it,
/// took from SIGHUP to reapable: 2.1 ms and 2.6 ms at the median idle, 4.1 and 4.3 at the
/// 99th percentile of 60 runs each; 4.2 ms median and 9.1 ms worst for bash at a load
/// average of 11, 6.2 ms median and 16.5 ms worst for zsh at 32, 6.0 ms median and 12.0
/// ms worst for bash at 57. Nothing in 240 runs came near a tenth of a second. Fifty
/// milliseconds, the figure before the last change, was a real risk of that loss; half a
/// second is not.
///
/// The wait is not paid in the common case: [`Pty::reap`] returns the moment the child
/// is reapable, so a shell that exits at once costs its own exit time and nothing more.
/// The full period is only spent on a child that is still working through its HUP trap,
/// or one that ignores SIGHUP -- `nohup`, `trap '' HUP` -- and then once, on the thread
/// tearing the session down.
///
/// Which is why there are two of them rather than one constant: since teardown split in
/// two, the thread that waits is not the same thread on both paths, and what a wait costs
/// is entirely a question of whose thread it is spent on. A grace is therefore a value
/// chosen at the call site, from the two named constructors below, and never a duration
/// typed out again.
#[derive(Clone, Copy, Debug)]
pub(crate) struct HangupGrace(std::time::Duration);

impl HangupGrace {
    /// The grace for teardown nobody is waiting on: `Session::drop` hands the wait to
    /// the reader thread, and the reader's own exit pays it too.
    ///
    /// That thread has nothing else left to do and blocks no one -- not Emacs' command
    /// loop, not the garbage collector that dropped the handle -- so the only thing this
    /// bound has to beat is a child that will never exit at all, and it can be as generous
    /// as it likes. Five seconds: three hundred times the slowest shell measured above,
    /// which leaves room for the exit work nobody here can measure -- a history file on a
    /// network mount, a `zsh_history` merge, an `atexit` hook that talks to a daemon --
    /// and is closer to what other terminals do, which is to close the pty and never send
    /// SIGKILL at all.
    pub(crate) fn detached() -> Self {
        Self(std::time::Duration::from_secs(5))
    }

    /// The grace for the explicit kill, which is paid on Emacs' own thread.
    ///
    /// `cooked--kill' runs from `kill-buffer-hook' and `cooked--kill-emacs' from
    /// `kill-emacs-hook', so this wait is Emacs sitting still: a half-second per session
    /// is what a user notices when closing a window, and `kill-emacs-hook' pays it once
    /// per live session in turn. It stays short on purpose, and it is the old figure
    /// unchanged: the measurements above leave it a factor of thirty over the slowest
    /// shell seen at a load average of 57. A child slower still is SIGKILLed part-way
    /// through saving its history, which is a real loss; it is the loss
    /// `cooked--kill-emacs' exists to accept, since that hook runs as the last code in the
    /// process and a wait handed to the reader thread there is a wait nothing will ever
    /// finish.
    pub(crate) fn explicit() -> Self {
        Self(std::time::Duration::from_millis(500))
    }
}

impl From<HangupGrace> for std::time::Duration {
    fn from(grace: HangupGrace) -> Self {
        grace.0
    }
}

/// How long a killed child has to become reapable. SIGKILL cannot be caught, so this
/// only covers the kernel's own bookkeeping and a child stuck in uninterruptible sleep.
pub(crate) const KILL_GRACE: std::time::Duration = std::time::Duration::from_millis(50);

/// How long [`Pty::reap`] waits between `waitpid`s on a platform with no exit watch.
const REAP_TICK: std::time::Duration = std::time::Duration::from_millis(2);

/// The longest [`Pty::spawn`] waits for the child to reach `execve`.
///
/// Reaching it takes well under a millisecond, so this only bounds the case where the
/// child is stuck before it, which would otherwise freeze Emacs for good: past it, spawn
/// returns anyway, as it did before it waited at all.
const SPAWN_EXEC_GRACE: std::time::Duration = std::time::Duration::from_secs(1);

impl Pty {
    /// Fork `argv` on a fresh pty in its own session, with `size` and `env` applied.
    pub(crate) fn spawn(
        argv: &[impl AsRef<OsStr>],
        env: &[(impl AsRef<str>, impl AsRef<str>)],
        size: Winsize,
        cwd: Option<&Path>,
    ) -> Result<Self> {
        if argv.is_empty() {
            return Err(Error::EmptyArgv);
        }
        let cargs = argv
            .iter()
            .map(|a| cstring(a.as_ref().as_bytes()))
            .collect::<Result<Vec<_>>>()?;
        let cargv = cargs
            .iter()
            .map(|c| c.as_ptr())
            .chain(std::iter::once(std::ptr::null()))
            .collect::<Vec<_>>();
        let cenv = env
            .iter()
            .map(|(k, v)| cstring(format!("{}={}", k.as_ref(), v.as_ref()).as_bytes()))
            .collect::<Result<Vec<_>>>()?;
        let cenvp = cenv
            .iter()
            .map(|c| c.as_ptr())
            .chain(std::iter::once(std::ptr::null()))
            .collect::<Vec<_>>();
        let ccwd = cwd.map(|p| cstring(p.as_os_str().as_bytes())).transpose()?;
        // argv[0] stays whatever the caller wrote; only the path we exec is resolved.
        let path = env
            .iter()
            .find(|(k, _)| k.as_ref() == "PATH")
            .map(|(_, v)| v.as_ref());
        let program = resolve(argv[0].as_ref(), path)?;

        let master = open_master()?;
        grantpt(&master)?;
        unlockpt(&master)?;
        let name = platform::slave_name(&master)?;

        // The child sets its own initial size, on its own slave fd, in `child_exec`. Not
        // done here on the parent side first: macOS's ptmx master refuses every
        // termios/winsize ioctl — `TIOCSWINSZ`, even `tcgetattr` — with `ENOTTY` until some
        // process has opened the slave and kept it open, and the child is the process that
        // does that; a parent-side `open`, transient or not, is at best redundant and at
        // worst races the child's own for that same "first" slot in ways this crate no
        // longer tries to guess at (see `resize`). It would also sit right before `fork`,
        // which on its own reliably deadlocked a child inside its own `open` on macOS in a
        // real, multithreaded session — almost certainly a lock some other thread held at
        // fork time with nobody left in the child to release it. A single isolated fork
        // never reproduced it; it took the accumulated threads of a real session to see it.
        //
        // Everything the child needs is allocated above; between fork and exec we touch
        // only async-signal-safe calls. `libc::fork` rather than `nix::unistd::fork` for
        // the same reason `child_exec` is raw: nix's wrapper runs registered `atfork`
        // handlers, which is exactly the kind of arbitrary code this window forbids.
        // The platform may start the child itself, by `posix_spawn`, and then the
        // paragraphs above about the fork window do not apply: see `platform::spawn`. The
        // window size goes on the master afterwards, where the reader's pending-resize
        // retry already covers a tty that is not ready for it.
        let child = match platform::spawn(&program, &cargs, &cenv, &name, ccwd.as_deref()) {
            Some(spawned) => {
                let child = spawned?;
                let _ = set_winsize(master.as_fd(), size);
                child
            }
            None => Self::fork_child(
                &master,
                &name,
                size,
                &program,
                &cargv,
                &cenvp,
                ccwd.as_deref(),
            )?,
        };

        // Non-blocking, so a reply can be offered to a child that is not reading without
        // waiting on it; see `WriteHalf::write_some`. Nothing here ever relied on blocking: the
        // reader polls before it reads and `WriteHalf::write` polls before it writes. Set on the
        // parent's side after the fork, since the flag belongs to the open file and the
        // child has closed its copy of the master either way.
        let flags = OFlag::from_bits_retain(fcntl(&master, FcntlArg::F_GETFL)?);
        fcntl(&master, FcntlArg::F_SETFL(flags | OFlag::O_NONBLOCK))?;

        let fds = std::sync::Arc::new(Fds {
            master,
            exit_watch: platform::ExitWatch::new(child),
        });
        Ok(Self {
            write: std::sync::Mutex::new(Some(WriteHalf(std::sync::Arc::clone(&fds)))),
            fds: std::sync::Mutex::new(Some(fds)),
            child,
            state: std::sync::Mutex::new(Child::Running),
        })
    }

    /// The fork-and-exec way of starting the child, for a platform without
    /// [`platform::spawn`].
    ///
    /// `exec_seen` is closed in the child by `execve` or by its `_exit`, whichever comes
    /// first, and nothing is ever written to it: its end of file is the signal. Both ends
    /// are close-on-exec, so neither this child nor any other keeps one open past its
    /// `execve`. Set with `fcntl` because macOS has no `pipe2`; Emacs forks only from its
    /// main thread, which is this one, so nothing forks between the calls.
    ///
    /// Waited for before the session is handed out, because until `setsid` the child is
    /// still in Emacs' process group, where no signal cooked sends can reach it: the
    /// `killpg` of its pid fails with ESRCH. And until `execve` it still runs Emacs'
    /// signal handlers, so a signal that did reach it would run those in the wrong
    /// process. `vfork`, which Emacs' own `make-process` uses, waits for the same thing.
    fn fork_child(
        master: &PtyMaster,
        slave: &CStr,
        size: Winsize,
        program: &CStr,
        argv: &[*const libc::c_char],
        envp: &[*const libc::c_char],
        cwd: Option<&CStr>,
    ) -> Result<Pid> {
        let (exec_seen, exec_seen_child) = nix::unistd::pipe()?;
        for end in [&exec_seen, &exec_seen_child] {
            fcntl(end, FcntlArg::F_SETFD(FdFlag::FD_CLOEXEC))?;
        }
        let master_fd = master.as_raw_fd();
        let child = Errno::result(unsafe { libc::fork() })?;
        if child == 0 {
            unsafe {
                child_exec(
                    slave.as_ptr(),
                    master_fd,
                    size,
                    program.as_ptr(),
                    argv,
                    envp,
                    cwd,
                )
            }
        }
        drop(exec_seen_child);
        wait_for_eof(&exec_seen, SPAWN_EXEC_GRACE);
        Ok(Pid::from_raw(child))
    }

    /// The descriptors, for the length of the caller's own call.
    ///
    /// Cloned out from under the lock rather than borrowed through it, so nothing holds
    /// this lock while it polls or writes: it is a leaf, taken and let go in the same
    /// expression everywhere it appears.
    pub(crate) fn fds(&self) -> Result<std::sync::Arc<Fds>> {
        self.fds.held().clone().ok_or(Error::Closed)
    }

    /// The right to write to the child, for the length of the caller's own call, or
    /// [`Error::Closed`] once teardown has taken it; see [`WriteHalf`].
    pub(crate) fn write_half(&self) -> Result<WriteHalf> {
        self.write.held().clone().ok_or(Error::Closed)
    }

    /// Take the right to write away, so that nothing can offer the child another byte.
    ///
    /// Called by `Session::begin_shutdown`, which is where both paths out of a session
    /// start: the child has been hung up on, and input typed after that is input for a
    /// terminal that is closing. The descriptors themselves stay, since the reader is
    /// still polling the master and waiting on the exit watch through the grace; this is
    /// the half of them that nobody has any business using again.
    ///
    /// The taken half is returned rather than dropped here, so the release is one move at
    /// the call site and a write already in flight -- holding a clone of its own -- is
    /// still finished rather than torn in half.
    pub(crate) fn take_write_half(&self) -> Option<WriteHalf> {
        self.write.held().take()
    }

    /// Release the descriptors, leaving the pid and the exit status this pty recorded.
    ///
    /// Called by [`crate::session::Session::shutdown`] once the child has been reaped, so
    /// that the four descriptors a session holds go back when the session ends rather than
    /// when the garbage collector reaches the user pointer Emacs keeps it in. Nothing in
    /// Lisp makes a collection happen at a chosen moment, so without this a suite that
    /// starts a session per test ran hundreds of finished ptys deep into Emacs' own
    /// 1024-descriptor limit and failed with EMFILE somewhere unrelated.
    ///
    /// A reader still inside a poll or a read holds its own `Arc` and keeps the
    /// descriptors open until it returns; see [`Fds`]. Every call after this answers
    /// [`Error::Closed`], which is what a caller acting on a session that is over should
    /// hear anyway.
    ///
    /// The write half goes with them. Teardown has always taken it first -- this is
    /// reached only from `Session::shutdown`, after `begin_shutdown` -- but leaving it
    /// behind would leave an `Arc` holding the very descriptors this exists to release.
    pub(crate) fn close(&self) {
        drop(self.take_write_half());
        drop(self.fds.held().take());
    }

    pub(crate) fn pid(&self) -> Pid {
        self.child
    }

    /// The child's current line-discipline state.
    pub(crate) fn mode(&self) -> Result<Mode> {
        Ok(Mode::from(&tcgetattr(self.fds()?.master.as_fd())?))
    }

    /// The child's job-control characters, as the tty currently defines them.
    ///
    /// Sampled on demand rather than carried in [`Mode`]: these change when someone runs
    /// `stty`, not on every read, and the one caller asks only when about to send one.
    pub(crate) fn job_control(&self) -> Result<JobControl> {
        Ok(JobControl::from(&tcgetattr(self.fds()?.master.as_fd())?))
    }

    /// Process group in the foreground of the tty — i.e. what is actually running.
    pub(crate) fn foreground(&self) -> Result<Pid> {
        match tcgetpgrp(self.fds()?.master.as_fd())? {
            pgrp if pgrp.as_raw() > 1 => Ok(pgrp),
            _ => Err(Error::NoForeground),
        }
    }

    /// What the tty has in the foreground, group and program together; see
    /// [`Foreground`].
    ///
    /// `None` while nothing holds the terminal, which [`Self::foreground`] already treats
    /// as ordinary: a shell has put one job down and the next has not taken over, or the
    /// session is gone.
    pub(crate) fn foreground_program(&self) -> Option<Foreground> {
        let pgrp = self.foreground().ok()?;
        Some(Foreground {
            pgrp,
            name: platform::process_name(pgrp),
        })
    }

    /// The size the tty currently reports, which is not always the size we last set.
    ///
    /// `child_exec` sets the initial winsize on its own slave fd, and that runs after the
    /// fork — so a `resize` issued in the moments after `spawn` can be applied to the
    /// master, return success, and then be overwritten by the child's own initialisation.
    /// Reading it back is what lets `session` tell "applied" from "applied and lost".
    pub(crate) fn winsize(&self) -> Result<Winsize> {
        let ws = platform::winsize(self.fds()?.master.as_fd())?;
        Ok(Winsize {
            rows: ws.ws_row,
            cols: ws.ws_col,
            cell: CellMetrics::new(
                ws.ws_xpixel / ws.ws_col.max(1),
                ws.ws_ypixel / ws.ws_row.max(1),
            ),
        })
    }

    /// Read available output. An empty slice means the child closed the slave end.
    pub(crate) fn read<'b>(&self, buf: &'b mut [u8]) -> Result<&'b [u8]> {
        loop {
            return match nix::unistd::read(self.fds()?.master.as_fd(), buf) {
                Ok(n) => Ok(&buf[..n]),
                Err(Errno::EINTR) => continue,
                Err(e) => Err(e.into()),
            };
        }
    }

    /// The child, for as long as the caller holds it, or [`Error::Reaped`] once it has
    /// been collected; see [`Live`].
    fn live(&self) -> Result<Live<'_>> {
        let held = self.state.held();
        match *held {
            Child::Running => Ok(Live {
                pid: self.child,
                _held: held,
            }),
            Child::Collected(_) => Err(Error::Reaped),
        }
    }

    /// Signal the foreground process group, falling back to the child's own.
    ///
    /// The child is held across the whole of it, so a `waitpid` on another thread cannot
    /// reap it -- and free its pid for reuse -- between the group being read and the
    /// signal going out. See [`Live`].
    pub(crate) fn signal(&self, sig: Signal) -> Result<()> {
        let live = self.live()?;
        match self.foreground() {
            // The platform may deliver to the foreground group itself, under the
            // kernel's lock; otherwise the group is read here and signalled in two steps.
            Ok(foreground) => match platform::signal_foreground(self.fds()?.master.as_fd(), sig) {
                Some(result) => Ok(result?),
                None => live.signal(foreground, sig),
            },
            Err(_) => live.signal(live.pid(), sig),
        }
    }

    /// Hang up on the child, as a terminal window closing does.
    ///
    /// SIGHUP to the child's *own* process group first, which [`Pty::signal`] never
    /// targets. The child is the session leader -- the shell -- and a hangup is its news
    /// to break: bash, zsh and fish all forward it to their jobs, save what they save,
    /// and exit. Sending it to the foreground job alone killed the job and left the shell
    /// standing, with nothing telling it the terminal was gone until the master closed.
    ///
    /// Then to the foreground group as well, when that is a different one. It is what
    /// the kernel does on a real hangup once the leader is gone, and it matters for a
    /// shell that traps SIGHUP: a trap runs only once the foreground command returns, so
    /// a shell waiting on `sleep` would sit on the trap for as long as the sleep lasted,
    /// and be killed for it at the end of the grace. A job that gets the hangup twice,
    /// once from here and once forwarded by its shell, is no worse off than one closing
    /// terminal window already leaves it.
    ///
    /// The foreground group is read *before* either signal goes out, not between them.
    /// A shell that has begun to act on the hangup takes the terminal back for itself
    /// with `tcsetpgrp` before it runs the trap, so a group read after the first `killpg`
    /// can already be the shell's own -- and then the job the shell is still waiting on
    /// gets no hangup at all, the trap does not run until that job ends by itself, and a
    /// `sleep 300` turns teardown into a five minute wait. The sample is one `tcgetpgrp`
    /// either way; taking it first is what makes the second signal land on the job that
    /// was in the foreground when the hangup was decided on.
    pub(crate) fn hangup(&self) -> Result<()> {
        let live = self.live()?;
        let foreground = self.foreground();
        let result = live.signal(live.pid(), Signal::SIGHUP);
        if let Ok(foreground) = foreground
            && foreground != live.pid()
        {
            let _ = live.signal(foreground, Signal::SIGHUP);
        }
        result
    }

    /// Kill the child's process group outright, for a child that has ignored a hangup.
    pub(crate) fn kill(&self) -> Result<()> {
        self.signal_group(Signal::SIGKILL)
    }

    fn signal_group(&self, sig: Signal) -> Result<()> {
        let live = self.live()?;
        live.signal(live.pid(), sig)
    }

    /// Whether the child has been collected, and its pid therefore no longer ours.
    pub(crate) fn reaped(&self) -> bool {
        self.collected().is_some()
    }

    /// The status whoever reaped the child collected, if anyone has; see
    /// [`Child::Collected`].
    pub(crate) fn collected(&self) -> Option<i32> {
        match *self.state.held() {
            Child::Running => None,
            Child::Collected(status) => Some(status),
        }
    }

    /// Exit status if the child has terminated, without blocking.
    ///
    /// [`Self::collect`] with the two ways of having nothing to report collapsed, for the
    /// callers that do not care which it was.
    pub(crate) fn try_wait(&self) -> Result<Option<i32>> {
        Ok(match self.collect()? {
            Collected::Here(status) => Some(status),
            Collected::Elsewhere | Collected::NotYet => None,
        })
    }

    /// Reap the child, giving it until WAIT's deadline to become reapable.
    ///
    /// A plain `try_wait` races a child that has closed the pty but has not yet been
    /// reaped, which loses the real exit code; a blocking `waitpid` would deadlock
    /// teardown against a child that is not exiting at all. Hence a bounded wait.
    ///
    /// The wait is spent in `poll` on the exit watch where the platform has one, so it
    /// returns the instant the child exits and costs nothing while it has not. Without
    /// one it asks `waitpid` every [`REAP_TICK`], which is the shape this always had.
    ///
    /// A [`Wait`] rather than a plain duration, so the deadline and the blocking call are
    /// two separate things: the call blocks in real time for at most [`STOP_CHECK`], and
    /// between calls the deadline is re-read from WAIT's clock. In a session that is a
    /// bounded wait with a 50 ms granularity on noticing it has run out, which nothing can
    /// tell apart from the old one. In a test on a stepped clock it is the difference
    /// between "the child exited" and "the grace expired": with the clock stopped, this
    /// waits on the child alone and no amount of load can turn a slow HUP trap into a
    /// kill. See `shutdown_hangs_up_the_shell_rather_than_its_foreground_job`.
    pub(crate) fn reap(&self, wait: &Wait<'_>) -> Option<i32> {
        // Whether the watch has already said the child is gone; see the match below.
        let mut exited = false;
        loop {
            match self.collect() {
                Ok(Collected::Here(status)) => return Some(status),
                // Nothing left to wait for: whoever got there first collected it, and its
                // status is theirs to report rather than this call's.
                Ok(Collected::Elsewhere) | Err(_) => return None,
                Ok(Collected::NotYet) => {}
            }
            let slice = wait.slice()?;
            match self
                .fds()
                .ok()
                .as_deref()
                .and_then(|fds| fds.exit_watch.as_ref())
            {
                // A watch that reports the child gone while `waitpid` still says otherwise
                // is the gap between the two the kernel is closing, and a tick covers it
                // rather than a spin here.
                Some(watch) if !exited => exited = watch.wait(slice),
                _ => std::thread::sleep(REAP_TICK.min(slice)),
            }
        }
    }

    /// [`Self::reap`] with a budget measured on the wall clock and nothing able to cut it
    /// short, for the callers whose wait is not a grace anyone chose.
    ///
    /// [`KILL_GRACE`] is the kernel's own bookkeeping after an uncatchable signal and
    /// `REAP_PATIENCE` in `session.rs` is how often the reader asks whether teardown has
    /// started; neither is a policy a test would want to step past, and a session clock
    /// that has stopped must not stop either of them.
    pub(crate) fn reap_for(&self, patience: std::time::Duration) -> Option<i32> {
        let now = std::time::Instant::now;
        self.reap(&Wait::new(patience, &now, &|| false))
    }

    /// One non-blocking attempt at collecting the child, under one take of its lock.
    ///
    /// The three answers [`Self::reap`] has to tell apart on every turn. It asked
    /// `reaped()` and then `try_wait()` before, which is the same lock twice a turn to
    /// distinguish "somebody else collected it" from "still running" -- the very
    /// distinction the state already carries, and one the second take could see change
    /// under it.
    fn collect(&self) -> Result<Collected> {
        // The same lock a signal holds, and for the same reason: this call (always
        // `WNOHANG`, so never blocking) is what takes the child away from a concurrent
        // `killpg`. See [`Live`].
        let mut state = self.state.held();
        let Child::Running = *state else {
            return Ok(Collected::Elsewhere);
        };
        let collected = match waitpid(self.child, Some(WaitPidFlag::WNOHANG))? {
            WaitStatus::Exited(_, code) => code,
            // The shell convention, and what `cooked-last-exit-code' renders.
            WaitStatus::Signaled(_, sig, _) => 128 + sig as i32,
            // Still alive, or merely stopped or continued: the child is still ours.
            _ => return Ok(Collected::NotYet),
        };
        // One write, so there is no order to keep between the status and the fact that
        // there is one.
        *state = Child::Collected(collected);
        Ok(Collected::Here(collected))
    }
}

/// What one attempt at collecting the child found; see [`Pty::collect`].
enum Collected {
    /// This call collected it, and this is the status `waitpid` handed over.
    Here(i32),
    /// Somebody else collected it, so the pid is no longer ours and there is no status
    /// here to report; [`Pty::collected`] is where the loser reads it.
    Elsewhere,
    /// Still ours, and still running -- or merely stopped, which is not an exit.
    NotYet,
}

impl WriteHalf {
    /// Write to the child, without blocking Emacs' only thread forever on it.
    ///
    /// `write(2)` on a tty cannot complete once its input queue is full -- a stopped job
    /// (`C-z`/`SIGSTOP`), a full-screen program not reading, or flow control all fill it.
    /// This function is called directly on the thread holding the `emacs_env` (see
    /// `env.rs`'s own rule that such a thread must never block), so it polls for
    /// writability and gives up at DEADLINE rather than waiting on the child indefinitely.
    /// A short individual poll keeps the common case (plenty of room) indistinguishable
    /// from an unconditional write; the bound only ever bites when the child truly cannot
    /// make progress, and WAIT says how long that may go on and who may cut it short.
    pub(crate) fn write(&self, mut buf: &[u8], wait: &Wait<'_>) -> Result<()> {
        while !buf.is_empty() {
            self.wait_writable(wait)?;
            buf = &buf[self.write_some(buf)?..];
        }
        Ok(())
    }

    /// Wait until the child's input queue has room, or WAIT says to stop.
    pub(crate) fn wait_writable(&self, wait: &Wait<'_>) -> Result<()> {
        loop {
            let remaining = wait.check()?;
            let mut fds = [PollFd::new(self.master(), PollFlags::POLLOUT)];
            match nix::poll::poll(&mut fds, poll_timeout(remaining)) {
                // Timed out this round; the loop re-checks the deadline.
                Ok(0) | Err(Errno::EINTR) => continue,
                Ok(_) => {}
                Err(e) => return Err(e.into()),
            }
            // Anything but POLLOUT is an error or a hangup, which the write itself reports
            // more precisely than the event bits do.
            if fds[0].revents().is_some_and(|r| !r.is_empty()) {
                return Ok(());
            }
        }
    }

    /// Write as much of BUF as the child's input queue has room for, without waiting.
    ///
    /// Answers how many bytes went, which is 0 when the queue is full. The master is
    /// non-blocking, so this can never park the calling thread; it is how a reply is
    /// offered to a child that may have stopped reading.
    pub(crate) fn write_some(&self, buf: &[u8]) -> Result<usize> {
        loop {
            return match nix::unistd::write(self.master(), buf) {
                Ok(n) => Ok(n),
                Err(Errno::EAGAIN) => Ok(0),
                Err(Errno::EINTR) => continue,
                Err(e) => Err(e.into()),
            };
        }
    }

    /// Match the emulator's idea of the terminal size to `size`.
    ///
    /// A write in the sense that matters here: the ioctl changes the child's tty and
    /// delivers it a SIGWINCH, so a session on its way out has no more business resizing
    /// the child than sending it a keystroke. Reading the size back is [`Pty::winsize`],
    /// which stays with the read half.
    ///
    /// A single attempt, deliberately: this can be called synchronously from Lisp, and a
    /// native module function must never block the thread holding the `emacs_env` on a
    /// retry loop. Immediately after `spawn`, before the child has opened its slave,
    /// macOS's ptmx master answers no termios/winsize ioctl at all — `session::Session`
    /// is the layer that knows what to do with that `ENOTTY`, by way of its already-running
    /// reader thread; see `Session::resize`.
    pub(crate) fn resize(&self, size: Winsize) -> Result<()> {
        set_winsize(self.master(), size)
    }

    fn master(&self) -> BorrowedFd<'_> {
        self.0.master.as_fd()
    }
}

impl Drop for Pty {
    /// `Session::shutdown` is the path every ordinary teardown takes, and it escalates
    /// from `SIGHUP` to `SIGKILL` because a child that traps or ignores the former —
    /// `nohup`, `trap '' HUP`, a detached session leader — would otherwise survive it
    /// forever. This `Drop` is the backstop for the path that does *not* go through
    /// `Session::shutdown` — e.g. `Session::spawn` failing after `Pty::spawn` already
    /// succeeded — so it gives the same grace period and the same escalation. Stopping at
    /// the `SIGHUP` here would leak exactly the children `Session::shutdown` escalates to
    /// avoid, and which path a failure takes must not decide whether the child goes away.
    fn drop(&mut self) {
        if self.child.as_raw() <= 1 || self.reaped() {
            return;
        }
        let _ = self.hangup();
        // The explicit grace, short, because the caller here is whoever dropped the
        // `Pty`, and on the failure path this exists for -- `Session::spawn` giving up
        // after `Pty::spawn` succeeded -- that is Emacs' own thread inside a module call.
        if self.reap_for(HangupGrace::explicit().into()).is_some() {
            return;
        }
        let _ = self.kill();
        let _ = self.reap_for(KILL_GRACE);
    }
}

/// Block until FD reads end of file or GRACE passes, whichever is first.
///
/// Errors end the wait as end of file does: the caller is waiting for a child to get
/// somewhere, and a pipe it cannot read tells it nothing more by being retried.
fn wait_for_eof(fd: &impl AsFd, grace: std::time::Duration) {
    let deadline = std::time::Instant::now() + grace;
    let mut byte = [0u8; 1];
    loop {
        let remaining = deadline.saturating_duration_since(std::time::Instant::now());
        if remaining.is_zero() {
            return;
        }
        let mut fds = [PollFd::new(fd.as_fd(), PollFlags::POLLIN)];
        match nix::poll::poll(&mut fds, poll_timeout(remaining)) {
            Ok(0) | Err(Errno::EINTR) => continue,
            Ok(_) => {}
            Err(_) => return,
        }
        match nix::unistd::read(fd.as_fd(), &mut byte) {
            Err(Errno::EINTR) => continue,
            // Nothing is ever written, so a byte is as final as end of file.
            _ => return,
        }
    }
}

fn cstring(bytes: &[u8]) -> Result<CString> {
    Ok(CString::new(bytes)?)
}

/// Find the program `execve` should run, searching PATH when the name has no slash.
///
/// Done in the parent rather than by `execvpe` in the child, for two reasons. `execvpe`
/// is a glibc extension that macOS does not have, and it is the only thing in
/// `child_exec` that was not portable. And resolving before the fork turns "command not
/// found" into an error the caller can act on, instead of a session that comes up and
/// immediately dies with status 127.
///
/// PATH is taken from the environment the child will get, not ours, so the lookup agrees
/// with what the child would have done for itself.
fn resolve(program: &OsStr, path: Option<&str>) -> Result<CString> {
    if program.as_bytes().contains(&b'/') {
        // A name with a slash is used as given, exactly as a shell would.
        return cstring(program.as_bytes());
    }
    // The same fallback `execvp` uses when PATH is unset.
    let path = path.unwrap_or("/usr/local/bin:/usr/bin:/bin");
    for dir in path.split(':') {
        // An empty entry means the current directory, as everywhere else in PATH.
        let candidate = Path::new(if dir.is_empty() { "." } else { dir }).join(program);
        // Executable *and* a regular file: a directory named `ls` is not a program.
        if access(&candidate, AccessFlags::X_OK).is_ok() && candidate.is_file() {
            return cstring(candidate.as_os_str().as_bytes());
        }
    }
    Err(Error::NotOnPath(program.to_os_string()))
}

/// Open a pty master no other process will inherit.
///
/// `O_CLOEXEC` is the load-bearing half. Without it the master survives into every
/// program we exec, which leaks a writable handle on the terminal into ssh, build
/// scripts and anything else the user runs — and, because the child then holds a
/// reference, closing our own copy no longer hangs the pty up, so children outlive
/// teardown. `child_exec` closes it as well, but that cannot help here: between this
/// call and our own `fork`, any *other* Emacs thread that forks would inherit it.
///
/// POSIX specifies only `O_RDWR | O_NOCTTY` for `posix_openpt` and macOS rejects
/// anything more with `EINVAL`, so fall back to setting the flag by hand.
fn open_master() -> Result<PtyMaster> {
    match posix_openpt(OFlag::O_RDWR | OFlag::O_NOCTTY | OFlag::O_CLOEXEC) {
        Err(Errno::EINVAL) => {
            let master = posix_openpt(OFlag::O_RDWR | OFlag::O_NOCTTY)?;
            fcntl(&master, FcntlArg::F_SETFD(FdFlag::FD_CLOEXEC))?;
            Ok(master)
        }
        other => Ok(other?),
    }
}

fn set_winsize(fd: BorrowedFd<'_>, size: Winsize) -> Result<()> {
    Ok(platform::set_winsize(fd, &libc::winsize::from(size))?)
}

/// Runs in the forked child and never returns.
///
/// Everything here is raw `libc` on purpose, and must stay that way. Between `fork` and
/// `exec` only async-signal-safe calls are legal: Emacs is multithreaded, so a `malloc`
/// here can deadlock on an allocator lock another thread held at fork time. That rules
/// out any wrapper that allocates — `nix::unistd::execvpe` builds two `Vec`s — which is
/// why every argument array is constructed before the fork and passed in as pointers.
///
/// `program` is the resolved path to exec; `argv[0]` is whatever the caller wrote, which
/// is what the child will see as its own name.
unsafe fn child_exec(
    slave: *const libc::c_char,
    master: libc::c_int,
    size: Winsize,
    program: *const libc::c_char,
    argv: &[*const libc::c_char],
    envp: &[*const libc::c_char],
    cwd: Option<&CStr>,
) -> ! {
    unsafe fn die() -> ! {
        unsafe { libc::_exit(127) }
    }

    unsafe {
        if libc::setsid() == -1 {
            die();
        }
        // The slave is opened from the master where the platform allows, so the master
        // is closed after rather than before. Belt to `O_CLOEXEC`'s braces: the master is
        // ours alone, and a child that can read it can steal input meant for its own
        // siblings. Nothing useful can be done if the close fails, and failing the spawn
        // over it would be a regression.
        let fd = platform::open_slave(master, slave);
        libc::close(master);
        if fd == -1 || platform::tiocsctty(fd, 0).is_err() {
            die();
        }
        // Best-effort: this is the first slave open, which is also the first moment any
        // termios/winsize ioctl is legal on macOS (see `WriteHalf::resize`), so it happens here
        // rather than being left to race the parent's own attempt at it. A wrong initial
        // size self-heals at the caller's next `resize`, so it is not worth `die`-ing over.
        let ws = libc::winsize::from(size);
        let _ = platform::tiocswinsz(fd, &raw const ws);
        for target in 0..=2 {
            if libc::dup2(fd, target) == -1 {
                die();
            }
        }
        if fd > 2 {
            libc::close(fd);
        }

        // Emacs ignores SIGPIPE and blocks signals; a child inheriting that is subtly broken.
        for sig in [
            libc::SIGPIPE,
            libc::SIGHUP,
            libc::SIGINT,
            libc::SIGQUIT,
            libc::SIGTERM,
            libc::SIGCHLD,
            libc::SIGTTIN,
            libc::SIGTTOU,
        ] {
            libc::signal(sig, libc::SIG_DFL);
        }
        let mut empty = std::mem::zeroed::<libc::sigset_t>();
        libc::sigemptyset(&raw mut empty);
        libc::sigprocmask(libc::SIG_SETMASK, &raw const empty, std::ptr::null_mut());

        // Every other step in this function `die()`s on failure; a bad `cwd` (removed,
        // never existed, no permission) should not be the one silent exception that
        // execs from wherever Emacs happened to be instead — that is a session opened
        // in the wrong place with nothing on screen to say so, rather than an error the
        // caller sees.
        if let Some(dir) = cwd
            && libc::chdir(dir.as_ptr()) == -1
        {
            die();
        }
        // Plain `execve`: `resolve` already did the PATH search, in the parent, where
        // failure is a real error rather than a child that exits 127 after the session
        // has been created. `execvpe` would have done the lookup here, but it is a glibc
        // extension and macOS has no equivalent.
        libc::execve(program, argv.as_ptr(), envp.as_ptr());
        die()
    }
}

/// Multiply every deadline in the Rust tests by `COOKED_TEST_TIMEOUT_SCALE`.
///
/// The numbers in those tests were chosen on an idle machine, and each is a bet about how
/// fast a real child gets through a real pty. On a shared CI runner, or while cargo is
/// linking, the bet is wrong and the code is not -- `resize_reaches_the_child` failed at a
/// load average of 38 and passes in isolation. Describing the machine once beats raising
/// every deadline in the tree.
///
/// Here rather than in a `tests` module because both this file's tests and the session's
/// use it, and a helper inside one module's private `tests` is not reachable from another.
/// There was a copy in each until they disagreed about what they accepted.
#[cfg(test)]
pub(crate) fn timeout_scale() -> f64 {
    parse_timeout_scale(std::env::var("COOKED_TEST_TIMEOUT_SCALE").ok().as_deref())
}

/// The parse behind [`timeout_scale`]: a positive decimal number, or 1.
///
/// Digits with an optional fraction and nothing else, which is exactly what the Lisp suite's
/// `cooked-tests--parse-timeout-scale` accepts, so one value means the same thing to both
/// halves of `make test`. `str::parse::<f64>` alone would take `1e3`, `+4`, `.5` and `inf`,
/// the last of which makes every wait unbounded, a hang rather than a failure.
///
/// A scale of zero would expire every deadline at once, failing every test that needs a
/// child with nothing in the output to say why, and an empty variable is what a makefile
/// exporting an unset variable produces, so the guard is the point of this function rather
/// than a formality around it.
///
/// Separated from the environment so it can be tested: `std::env::set_var` is unsafe and
/// process-global, so a test that went through the variable would race every other test in
/// this binary for it.
#[cfg(test)]
fn parse_timeout_scale(raw: Option<&str>) -> f64 {
    let decimal = |text: &str| {
        let (whole, fraction) = text.split_once('.').unwrap_or((text, "0"));
        [whole, fraction]
            .iter()
            .all(|digits| !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()))
    };
    raw.map(str::trim)
        .filter(|text| decimal(text))
        .and_then(|text| text.parse::<f64>().ok())
        .filter(|scale| scale.is_finite() && *scale > 0.0)
        .unwrap_or(1.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_timeout_scale_only_accepts_a_positive_number() {
        assert_eq!(parse_timeout_scale(Some("4")), 4.0);
        assert_eq!(parse_timeout_scale(Some(" 2.5 ")), 2.5);
        assert_eq!(parse_timeout_scale(None), 1.0);
        // The whole reason the guard exists: an empty variable is what a CI config
        // declaring the name without a value produces, and what a makefile exporting an
        // unset variable produces. Read as 0 it would expire every deadline here before
        // it was taken.
        assert_eq!(parse_timeout_scale(Some("")), 1.0);
        assert_eq!(parse_timeout_scale(Some("   ")), 1.0);
        assert_eq!(parse_timeout_scale(Some("0")), 1.0);
        assert_eq!(parse_timeout_scale(Some("0.0")), 1.0);
        assert_eq!(parse_timeout_scale(Some("-3")), 1.0);
        assert_eq!(parse_timeout_scale(Some("wat")), 1.0);
        assert_eq!(parse_timeout_scale(Some("4x")), 1.0);
        // What `str::parse::<f64>` takes and the Lisp parser does not. The two suites read
        // one variable, and a value one of them rejects must not scale the other.
        assert_eq!(parse_timeout_scale(Some("1e3")), 1.0);
        assert_eq!(parse_timeout_scale(Some("+4")), 1.0);
        assert_eq!(parse_timeout_scale(Some(".5")), 1.0);
        assert_eq!(parse_timeout_scale(Some("5.")), 1.0);
        // `inf` would make every wait unbounded, which is a hang rather than a failure and
        // is the worse of the two.
        assert_eq!(parse_timeout_scale(Some("inf")), 1.0);
        assert_eq!(parse_timeout_scale(Some("NaN")), 1.0);
    }

    /// The 80x24 window every spawn here asks for; no test turns on the size.
    fn size() -> Winsize {
        Winsize::new(24, 80)
    }

    fn termios_with(lflag: LocalFlags) -> Termios {
        let mut t = Termios::from(unsafe { std::mem::zeroed::<libc::termios>() });
        t.local_flags = lflag;
        t
    }

    #[test]
    fn job_control_reads_the_characters_the_tty_actually_holds() {
        let mut t = termios_with(LocalFlags::ISIG);
        t.control_chars[SpecialCharacterIndices::VINTR as usize] = 0x18; // ^X, as `stty intr ^X`
        t.control_chars[SpecialCharacterIndices::VQUIT as usize] = 0x1c; // ^\
        t.control_chars[SpecialCharacterIndices::VSUSP as usize] = 0x1a; // ^Z
        t.control_chars[SpecialCharacterIndices::VEOF as usize] = 0x04; // ^D
        assert_eq!(
            JobControl::from(&t),
            JobControl {
                intr: Some(0x18),
                quit: Some(0x1c),
                susp: Some(0x1a),
                eof: Some(0x04),
                isig: true,
            },
            "a reconfigured intr must be reported, not assumed to be ^C"
        );
    }

    #[test]
    fn job_control_reports_a_disabled_character_as_none() {
        let mut t = termios_with(LocalFlags::ISIG);
        t.control_chars[SpecialCharacterIndices::VINTR as usize] = platform::POSIX_VDISABLE;
        t.control_chars[SpecialCharacterIndices::VQUIT as usize] = 0x1c;
        // There is no byte to write for a disabled character, so the caller needs to know
        // to fall back on the signal rather than sending `_POSIX_VDISABLE` itself.
        assert_eq!(JobControl::from(&t).intr, None);
        assert_eq!(JobControl::from(&t).quit, Some(0x1c));
    }

    #[test]
    fn job_control_reports_isig_so_a_raw_reader_gets_the_byte() {
        // A program that cleared ISIG did so to read ^C itself; writing the byte would be
        // swallowed into a signal if we got this backwards.
        assert!(JobControl::from(&termios_with(LocalFlags::ISIG)).isig);
        assert!(!JobControl::from(&termios_with(LocalFlags::empty())).isig);
    }

    #[test]
    fn mode_discriminates_the_three_states() {
        assert_eq!(
            Mode::from(&termios_with(LocalFlags::ICANON | LocalFlags::ECHO)),
            Mode::Cooked
        );
        assert_eq!(Mode::from(&termios_with(LocalFlags::ICANON)), Mode::Secret);
        assert_eq!(Mode::from(&termios_with(LocalFlags::empty())), Mode::Raw);
        assert_eq!(Mode::from(&termios_with(LocalFlags::ECHO)), Mode::Raw);
    }

    #[test]
    fn signalling_never_targets_our_own_process_group() {
        // tcgetpgrp reporting 0 would make kill(-0, ...) hit the Emacs that loaded us.
        let pty = Pty::spawn(
            &["/bin/sh", "-c", "exit 0"],
            &[("TERM", "dumb")],
            size(),
            None,
        )
        .unwrap();
        assert!(pty.reap_for(std::time::Duration::from_secs(2)).is_some());
        for _ in 0..3 {
            assert!(
                pty.signal(Signal::SIGHUP).is_err(),
                "must refuse to signal a dead session"
            );
        }
    }

    #[test]
    fn a_spawned_child_can_be_signalled_at_once() {
        // `Session::spawn` hands Lisp a live session as soon as this returns, and
        // `cooked--signal` can follow on the next line. A child that has not yet reached
        // `setsid` is still in Emacs' process group, so the `killpg` of its pid that
        // `signal` falls back to found no such group, and a Lisp test that signals a
        // fresh shell failed with ESRCH under load. SIGCONT, because a child that does
        // receive it carries on as before.
        for _ in 0..200 {
            let pty = Pty::spawn(
                &["/bin/sh", "-c", "sleep 5"],
                &[("PATH", "/usr/bin:/bin")],
                size(),
                None,
            )
            .expect("spawn");
            pty.signal(Signal::SIGCONT)
                .expect("the child is in a process group of its own");
        }
    }

    #[test]
    fn resolve_searches_path_only_for_bare_names() {
        // A name with a slash is taken literally, exactly as a shell would.
        assert_eq!(
            resolve(OsStr::new("/bin/sh"), Some("/nowhere"))
                .unwrap()
                .to_str()
                .unwrap(),
            "/bin/sh"
        );
        assert_eq!(
            resolve(OsStr::new("./x"), Some("/nowhere"))
                .unwrap()
                .to_str()
                .unwrap(),
            "./x"
        );

        // A bare name is searched, and the first hit in order wins.
        let found = resolve(OsStr::new("sh"), Some("/nowhere:/bin:/usr/bin")).unwrap();
        assert!(found.to_str().unwrap().ends_with("/sh"), "{found:?}");

        // A directory on PATH named like the program is not the program.
        assert!(
            resolve(OsStr::new("bin"), Some("/usr")).is_err(),
            "a directory is not executable"
        );

        let missing =
            resolve(OsStr::new("cooked-does-not-exist"), Some("/bin:/usr/bin")).unwrap_err();
        // Named, not `ErrorKind::NotFound`, which cannot tell this from "child already
        // reaped" or "no foreground process group". See `error.rs`.
        assert!(matches!(missing, Error::NotOnPath(_)), "{missing:?}");
    }

    /// A program that cannot be exec'd is an error from `spawn`, not a child that dies.
    ///
    /// Where the platform starts the child with `posix_spawn`, the call returns once the
    /// exec has happened or failed, so the failure comes back as its errno. The fork path
    /// cannot know until the child has exited 127, and is not held to this.
    #[test]
    fn an_unexecutable_program_fails_the_spawn_itself() {
        if !cfg!(target_os = "linux") {
            return;
        }
        let result = Pty::spawn(&["/etc/passwd"], &[("PATH", "/usr/bin:/bin")], size(), None);
        assert!(
            matches!(result, Err(Error::Os(Errno::EACCES))),
            "expected EACCES from the spawn, got {result:?}"
        );
    }

    #[test]
    fn a_missing_program_fails_before_the_fork() {
        // The lookup happens in the parent, so a missing program is an ordinary error.
        // Left to `execvpe` in the child it would surface as a session that comes up and
        // immediately exits 127, with nothing to report.
        let err = Pty::spawn(
            &["cooked-does-not-exist"],
            &[("PATH", "/bin:/usr/bin")],
            size(),
            None,
        )
        .expect_err("should not have spawned");
        assert!(matches!(err, Error::NotOnPath(_)), "{err:?}");
    }

    #[test]
    fn a_bare_program_name_is_looked_up_on_path() {
        let path = std::env::var("PATH").unwrap_or_default();
        let pty = Pty::spawn(
            &["sh", "-c", "exit 5"],
            &[("PATH", path.as_str())],
            size(),
            None,
        )
        .expect("spawn");
        assert_eq!(
            pty.reap_for(std::time::Duration::from_secs(2)),
            Some(5),
            "127 here means PATH was never searched"
        );
    }

    /// `waitpid` hands a status to one caller, and the other one needs it too.
    ///
    /// Since `Session::shutdown` stopped joining the reader, either thread may be the one
    /// that collects, and the loser reads the status here instead of recording `Exit::Lost` over
    /// it -- or recording nothing, which left `Session::alive` answering yes for a session
    /// that had just been killed. The second `reap` below is the loser.
    #[test]
    fn the_collected_status_outlives_the_reap_that_collected_it() {
        let pty = Pty::spawn(
            &["/bin/sh", "-c", "exit 7"],
            &[("TERM", "dumb")],
            size(),
            None,
        )
        .expect("spawn");
        assert_eq!(pty.collected(), None, "nothing has been collected yet");
        assert_eq!(pty.reap_for(std::time::Duration::from_secs(2)), Some(7));
        assert!(pty.reaped());
        assert_eq!(
            pty.reap_for(std::time::Duration::from_secs(2)),
            None,
            "the child is gone, so there is nothing left to collect"
        );
        assert_eq!(
            pty.collected(),
            Some(7),
            "the loser of the race must still be able to read the real status"
        );
    }

    #[test]
    fn the_master_is_close_on_exec() {
        let pty = Pty::spawn(
            &["/bin/sh", "-c", "exit 0"],
            &[("TERM", "dumb")],
            size(),
            None,
        )
        .unwrap();
        let flags =
            fcntl(pty.fds().expect("open").master.as_fd(), FcntlArg::F_GETFD).expect("F_GETFD");
        assert_ne!(
            flags & FdFlag::FD_CLOEXEC.bits(),
            0,
            "the master would be inherited by every child"
        );
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn the_child_inherits_only_stdio() {
        // Anything above stderr surviving exec is a leak; the pty master was fd 3.
        let pty = Pty::spawn(
            &["/bin/sh", "-c", "[ -e /proc/self/fd/3 ] && exit 1; exit 0"],
            &[("PATH", "/usr/bin:/bin")],
            size(),
            None,
        )
        .expect("spawn");
        assert_eq!(
            pty.reap_for(std::time::Duration::from_secs(2)),
            Some(0),
            "an fd leaked past exec"
        );
    }

    #[test]
    fn spawn_reports_cooked_then_raw() {
        let pty = Pty::spawn(&["/bin/cat"], &[("TERM", "dumb")], size(), None).expect("spawn");
        std::thread::sleep(std::time::Duration::from_millis(100));
        assert_eq!(pty.mode().unwrap(), Mode::Cooked);
        assert!(pty.foreground().unwrap().as_raw() > 0);
    }

    #[test]
    fn secret_mode_is_detected() {
        let pty = Pty::spawn(
            &["/bin/sh", "-c", "stty -echo; read x"],
            &[("TERM", "dumb")],
            size(),
            None,
        )
        .expect("spawn");
        let deadline =
            std::time::Instant::now() + std::time::Duration::from_secs_f64(2.0 * timeout_scale());
        while std::time::Instant::now() < deadline {
            // `mode()` can transiently fail immediately after spawn, before the child has
            // opened its slave (see `WriteHalf::resize`'s doc comment) — tolerated the same way
            // `session::sample_mode` tolerates it: an `Err` this cycle just means try again.
            if pty.mode().is_ok_and(|mode| mode == Mode::Secret) {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        panic!("never observed Secret mode");
    }
}
