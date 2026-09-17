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
use nix::errno::Errno;
use nix::fcntl::{FcntlArg, FdFlag, OFlag, fcntl};
use nix::poll::{PollFd, PollFlags, PollTimeout};
use nix::pty::{PtyMaster, grantpt, posix_openpt, unlockpt};
use nix::sys::signal::{Signal, killpg};
use nix::sys::termios::{LocalFlags, SpecialCharacterIndices, Termios, tcgetattr};
use nix::sys::wait::{WaitPidFlag, WaitStatus, waitpid};
use nix::unistd::{AccessFlags, Pid as NixPid, access, tcgetpgrp};
use std::ffi::{CStr, CString, OsStr};
use std::os::fd::{AsFd, AsRawFd, BorrowedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::sync::PoisonError;

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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Pid(libc::pid_t);

impl Pid {
    pub(crate) fn get(self) -> i32 {
        self.0
    }
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

/// A forked child attached to a pty we own the master end of.
#[derive(Debug)]
pub(crate) struct Pty {
    master: PtyMaster,
    child: Pid,
    /// Set once `waitpid` has collected the child. Signalling after that point would
    /// aim at a pid the kernel is free to have handed to somebody else.
    reaped: std::sync::atomic::AtomicBool,
    /// Serialises `signal`'s reaped-check-then-`killpg` against `waitpid`'s own
    /// reaped-check-then-collect, both of which touch `reaped`. Without this, a
    /// `cooked--signal` call on the Lisp thread can observe `reaped() == false`, have
    /// the reader thread's `waitpid` collect the child (freeing its pid for reuse) in
    /// the gap, and then `killpg` a process group the kernel has since handed to
    /// something else entirely. Both critical sections are a `WNOHANG` `waitpid` or a
    /// single `killpg` — never blocking — so holding this across either is always
    /// short.
    reap_lock: std::sync::Mutex<()>,
    /// Says when the child has exited, where the platform can; see
    /// [`platform::ExitWatch`]. What lets [`Pty::reap`] wait on the kernel instead of
    /// on a timer.
    exit_watch: Option<platform::ExitWatch>,
}

/// How long [`Pty::write`] waits on a child that is not draining its input before it
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
pub(crate) struct Wait<'a> {
    deadline: std::time::Instant,
    stop: &'a dyn Fn() -> bool,
}

impl<'a> Wait<'a> {
    /// Wait until DEADLINE, asking STOP along the way.
    pub(crate) fn new(deadline: std::time::Instant, stop: &'a dyn Fn() -> bool) -> Self {
        Self { deadline, stop }
    }

    /// The error to give up with now, if any: the deadline has passed, or STOP says so.
    fn check(&self) -> Result<std::time::Duration> {
        let remaining = self
            .deadline
            .saturating_duration_since(std::time::Instant::now());
        if remaining.is_zero() {
            return Err(Error::WriteTimeout);
        }
        if (self.stop)() {
            return Err(Error::Interrupted);
        }
        Ok(remaining.min(STOP_CHECK))
    }
}

/// How long a hung-up child has to exit on its own before it is killed.
///
/// What a closing terminal window gives its shell, and it has to cover what a shell does
/// on SIGHUP: forward it to its jobs, write its history, run its exit hooks. zsh does all
/// three in a few milliseconds on an idle machine and can take much longer on a loaded
/// one, and a shell killed part-way through loses the history of the session. Fifty
/// milliseconds, the old figure, was that loss on any busy machine.
///
/// The wait is not paid in the common case: [`Pty::reap`] returns the moment the child
/// is reapable, so a shell that exits at once costs its own exit time and nothing more.
/// The full period is only spent on a child that ignores SIGHUP -- `nohup`, `trap ''
/// HUP` -- and then once, on the thread tearing the session down.
pub(crate) const HANGUP_GRACE: std::time::Duration = std::time::Duration::from_millis(500);

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
        //
        // `exec_seen` is closed in the child by `execve` or by its `_exit`, whichever comes
        // first, and nothing is ever written to it: its end of file is the signal. Both
        // ends are close-on-exec, so neither this child nor any other keeps one open past
        // its `execve`. Set with `fcntl` because macOS has no `pipe2`; Emacs forks only
        // from its main thread, which is this one, so nothing forks between the calls.
        let (exec_seen, exec_seen_child) = nix::unistd::pipe()?;
        for end in [&exec_seen, &exec_seen_child] {
            fcntl(end, FcntlArg::F_SETFD(FdFlag::FD_CLOEXEC))?;
        }
        let master_fd = master.as_raw_fd();
        let child = Errno::result(unsafe { libc::fork() })?;
        if child == 0 {
            unsafe {
                child_exec(
                    name.as_ptr(),
                    master_fd,
                    size,
                    program.as_ptr(),
                    &cargv,
                    &cenvp,
                    ccwd.as_deref(),
                )
            }
        }

        // Waited for before the session is handed out, because until `setsid` the child is
        // still in Emacs' process group, where no signal cooked sends can reach it: the
        // `killpg` of its pid fails with ESRCH. And until `execve` it still runs Emacs'
        // signal handlers, so a signal that did reach it would run those in the wrong
        // process. `vfork`, which Emacs' own `make-process` uses, waits for the same thing.
        drop(exec_seen_child);
        wait_for_eof(&exec_seen, SPAWN_EXEC_GRACE);

        // Non-blocking, so a reply can be offered to a child that is not reading without
        // waiting on it; see `Pty::write_some`. Nothing here ever relied on blocking: the
        // reader polls before it reads and `Pty::write` polls before it writes. Set on the
        // parent's side after the fork, since the flag belongs to the open file and the
        // child has closed its copy of the master either way.
        let flags = OFlag::from_bits_retain(fcntl(&master, FcntlArg::F_GETFL)?);
        fcntl(&master, FcntlArg::F_SETFL(flags | OFlag::O_NONBLOCK))?;

        Ok(Self {
            master,
            child: Pid(child),
            reaped: std::sync::atomic::AtomicBool::new(false),
            reap_lock: std::sync::Mutex::new(()),
            exit_watch: platform::ExitWatch::new(child),
        })
    }

    pub(crate) fn as_fd(&self) -> BorrowedFd<'_> {
        self.master.as_fd()
    }

    pub(crate) fn pid(&self) -> Pid {
        self.child
    }

    /// The child's current line-discipline state.
    pub(crate) fn mode(&self) -> Result<Mode> {
        Ok(Mode::from(&tcgetattr(self.master.as_fd())?))
    }

    /// The child's job-control characters, as the tty currently defines them.
    ///
    /// Sampled on demand rather than carried in [`Mode`]: these change when someone runs
    /// `stty`, not on every read, and the one caller asks only when about to send one.
    pub(crate) fn job_control(&self) -> Result<JobControl> {
        Ok(JobControl::from(&tcgetattr(self.master.as_fd())?))
    }

    /// Process group in the foreground of the tty — i.e. what is actually running.
    pub(crate) fn foreground(&self) -> Result<Pid> {
        match tcgetpgrp(self.master.as_fd())?.as_raw() {
            pgrp if pgrp > 1 => Ok(Pid(pgrp)),
            _ => Err(Error::NoForeground),
        }
    }

    /// Match the emulator's idea of the terminal size to `size`.
    ///
    /// A single attempt, deliberately: this can be called synchronously from Lisp, and a
    /// native module function must never block the thread holding the `emacs_env` on a
    /// retry loop. Immediately after `spawn`, before the child has opened its slave,
    /// macOS's ptmx master answers no termios/winsize ioctl at all — `session::Session`
    /// is the layer that knows what to do with that `ENOTTY`, by way of its already-running
    /// reader thread; see `Session::resize`.
    pub(crate) fn resize(&self, size: Winsize) -> Result<()> {
        set_winsize(self.master.as_fd(), size)
    }

    /// The size the tty currently reports, which is not always the size we last set.
    ///
    /// `child_exec` sets the initial winsize on its own slave fd, and that runs after the
    /// fork — so a `resize` issued in the moments after `spawn` can be applied to the
    /// master, return success, and then be overwritten by the child's own initialisation.
    /// Reading it back is what lets `session` tell "applied" from "applied and lost".
    pub(crate) fn winsize(&self) -> Result<Winsize> {
        let mut ws = libc::winsize {
            ws_row: 0,
            ws_col: 0,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        Errno::result(unsafe {
            libc::ioctl(self.master.as_raw_fd(), platform::TIOCGWINSZ, &raw mut ws)
        })?;
        Ok(Winsize {
            rows: ws.ws_row,
            cols: ws.ws_col,
            cell: CellMetrics::new(
                ws.ws_xpixel / ws.ws_col.max(1),
                ws.ws_ypixel / ws.ws_row.max(1),
            ),
        })
    }

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
            let mut fds = [PollFd::new(self.master.as_fd(), PollFlags::POLLOUT)];
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
            return match nix::unistd::write(self.master.as_fd(), buf) {
                Ok(n) => Ok(n),
                Err(Errno::EAGAIN) => Ok(0),
                Err(Errno::EINTR) => continue,
                Err(e) => Err(e.into()),
            };
        }
    }

    /// Read available output. An empty slice means the child closed the slave end.
    pub(crate) fn read<'b>(&self, buf: &'b mut [u8]) -> Result<&'b [u8]> {
        loop {
            return match nix::unistd::read(self.master.as_fd(), buf) {
                Ok(n) => Ok(&buf[..n]),
                Err(Errno::EINTR) => continue,
                Err(e) => Err(e.into()),
            };
        }
    }

    /// Signal the foreground process group, falling back to the child's own.
    ///
    /// The guard is not paranoia: `tcgetpgrp` can report 0 once the session is gone, and
    /// `kill(-0, ...)` means "my own process group" — which here is Emacs. Once the child
    /// has been reaped its pid is available for reuse, so refuse then too.
    pub(crate) fn signal(&self, sig: Signal) -> Result<()> {
        // Held across the check and the `killpg` so a `waitpid` on another thread
        // cannot reap the child, and free its pid for reuse, in between. See the field
        // comment on `reap_lock`.
        let _guard = self
            .reap_lock
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        if self.reaped() {
            return Err(Error::Reaped);
        }
        match self.foreground() {
            // The platform may deliver to the foreground group itself, under the
            // kernel's lock; otherwise the group is read here and signalled in two steps.
            Ok(foreground) => match platform::signal_foreground(self.master.as_fd(), sig) {
                Some(result) => Ok(result?),
                None => Self::send_to(foreground, sig),
            },
            Err(_) => Self::send_to(self.child, sig),
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
    pub(crate) fn hangup(&self) -> Result<()> {
        let _guard = self
            .reap_lock
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        if self.reaped() {
            return Err(Error::Reaped);
        }
        let result = Self::send_to(self.child, Signal::SIGHUP);
        if let Ok(foreground) = self.foreground()
            && foreground != self.child
        {
            let _ = Self::send_to(foreground, Signal::SIGHUP);
        }
        result
    }

    /// Kill the child's process group outright, for a child that has ignored a hangup.
    pub(crate) fn kill(&self) -> Result<()> {
        self.signal_group(Signal::SIGKILL)
    }

    fn signal_group(&self, sig: Signal) -> Result<()> {
        let _guard = self
            .reap_lock
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        if self.reaped() {
            return Err(Error::Reaped);
        }
        Self::send_to(self.child, sig)
    }

    /// `killpg` TARGET, refusing anything that could reach our own process group.
    fn send_to(target: Pid, sig: Signal) -> Result<()> {
        match target {
            // `killpg` rather than `kill(-pid)`, which one missed negation turns into a
            // signal to the wrong process.
            Pid(target) if target > 1 => Ok(killpg(NixPid::from_raw(target), sig)?),
            _ => Err(Error::NoForeground),
        }
    }

    /// Whether the child has been collected, and its pid therefore no longer ours.
    pub(crate) fn reaped(&self) -> bool {
        self.reaped.load(std::sync::atomic::Ordering::SeqCst)
    }

    /// Exit status if the child has terminated, without blocking.
    pub(crate) fn try_wait(&self) -> Result<Option<i32>> {
        self.waitpid(WaitPidFlag::WNOHANG)
    }

    /// Reap the child, giving it up to `patience` to become reapable.
    ///
    /// A plain `try_wait` races a child that has closed the pty but has not yet been
    /// reaped, which loses the real exit code; a blocking `waitpid` would deadlock
    /// teardown against a child that is not exiting at all. Hence a bounded wait.
    ///
    /// The wait is spent in `poll` on the exit watch where the platform has one, so it
    /// returns the instant the child exits and costs nothing while it has not. Without
    /// one it asks `waitpid` every [`REAP_TICK`], which is the shape this always had.
    pub(crate) fn reap(&self, patience: std::time::Duration) -> Option<i32> {
        let deadline = std::time::Instant::now() + patience;
        // Whether the watch has already said the child is gone; see the match below.
        let mut exited = false;
        loop {
            // Collected already, by whoever got there first: there is nothing to wait
            // for, and `try_wait` cannot say so, since `None` is also "still running".
            if self.reaped() {
                return None;
            }
            match self.try_wait() {
                Ok(Some(status)) => return Some(status),
                Ok(None) => {}
                Err(_) => return None,
            }
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            if remaining.is_zero() {
                return None;
            }
            match &self.exit_watch {
                // A watch that reports the child gone while `waitpid` still says otherwise
                // is the gap between the two the kernel is closing, and a tick covers it
                // rather than a spin here.
                Some(watch) if !exited => exited = watch.wait(remaining),
                _ => std::thread::sleep(REAP_TICK.min(remaining)),
            }
        }
    }

    fn waitpid(&self, flags: WaitPidFlag) -> Result<Option<i32>> {
        // Same lock `signal` takes, and for the same reason: this call (always
        // `WNOHANG`, so never blocking) is what can flip `reaped` out from under a
        // concurrent `signal`.
        let _guard = self
            .reap_lock
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        if self.reaped() {
            return Ok(None);
        }
        let collected = match waitpid(NixPid::from_raw(self.child.0), Some(flags))? {
            WaitStatus::Exited(_, code) => code,
            // The shell convention, and what `cooked-last-exit-code' renders.
            WaitStatus::Signaled(_, sig, _) => 128 + sig as i32,
            // Still alive, or merely stopped or continued: the child is still ours.
            _ => return Ok(None),
        };
        self.reaped.store(true, std::sync::atomic::Ordering::SeqCst);
        Ok(Some(collected))
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
        if self.child.0 <= 1 || self.reaped() {
            return;
        }
        let _ = self.hangup();
        if self.reap(HANGUP_GRACE).is_some() {
            return;
        }
        let _ = self.kill();
        let _ = self.reap(KILL_GRACE);
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

// nix's `ioctl_write_ptr_bad!` would generate an equivalent `unsafe fn` returning
// `Result`, which is a lateral move for a single call that already goes through `check`.
fn set_winsize(fd: BorrowedFd<'_>, size: Winsize) -> Result<()> {
    let ws = libc::winsize::from(size);
    Errno::result(unsafe { libc::ioctl(fd.as_raw_fd(), platform::TIOCSWINSZ, &raw const ws) })?;
    Ok(())
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
        if fd == -1 || libc::ioctl(fd, platform::TIOCSCTTY, 0) == -1 {
            die();
        }
        // Best-effort: this is the first slave open, which is also the first moment any
        // termios/winsize ioctl is legal on macOS (see `Pty::resize`), so it happens here
        // rather than being left to race the parent's own attempt at it. A wrong initial
        // size self-heals at the caller's next `resize`, so it is not worth `die`-ing over.
        let ws = libc::winsize::from(size);
        libc::ioctl(fd, platform::TIOCSWINSZ, &raw const ws);
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
            Winsize {
                rows: 24,
                cols: 80,
                cell: None,
            },
            None,
        )
        .unwrap();
        assert!(pty.reap(std::time::Duration::from_secs(2)).is_some());
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
                Winsize {
                    rows: 24,
                    cols: 80,
                    cell: None,
                },
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

    #[test]
    fn a_missing_program_fails_before_the_fork() {
        // The lookup happens in the parent, so a missing program is an ordinary error.
        // Left to `execvpe` in the child it would surface as a session that comes up and
        // immediately exits 127, with nothing to report.
        let err = Pty::spawn(
            &["cooked-does-not-exist"],
            &[("PATH", "/bin:/usr/bin")],
            Winsize {
                rows: 24,
                cols: 80,
                cell: None,
            },
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
            Winsize {
                rows: 24,
                cols: 80,
                cell: None,
            },
            None,
        )
        .expect("spawn");
        assert_eq!(
            pty.reap(std::time::Duration::from_secs(2)),
            Some(5),
            "127 here means PATH was never searched"
        );
    }

    #[test]
    fn the_master_is_close_on_exec() {
        let pty = Pty::spawn(
            &["/bin/sh", "-c", "exit 0"],
            &[("TERM", "dumb")],
            Winsize {
                rows: 24,
                cols: 80,
                cell: None,
            },
            None,
        )
        .unwrap();
        let flags = unsafe { libc::fcntl(pty.as_fd().as_raw_fd(), libc::F_GETFD) };
        assert_ne!(flags, -1);
        assert_ne!(
            flags & libc::FD_CLOEXEC,
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
            Winsize {
                rows: 24,
                cols: 80,
                cell: None,
            },
            None,
        )
        .expect("spawn");
        assert_eq!(
            pty.reap(std::time::Duration::from_secs(2)),
            Some(0),
            "an fd leaked past exec"
        );
    }

    #[test]
    fn spawn_reports_cooked_then_raw() {
        let size = Winsize {
            rows: 24,
            cols: 80,
            cell: None,
        };
        let pty = Pty::spawn(&["/bin/cat"], &[("TERM", "dumb")], size, None).expect("spawn");
        std::thread::sleep(std::time::Duration::from_millis(100));
        assert_eq!(pty.mode().unwrap(), Mode::Cooked);
        assert!(pty.foreground().unwrap().get() > 0);
    }

    #[test]
    fn secret_mode_is_detected() {
        let size = Winsize {
            rows: 24,
            cols: 80,
            cell: None,
        };
        let pty = Pty::spawn(
            &["/bin/sh", "-c", "stty -echo; read x"],
            &[("TERM", "dumb")],
            size,
            None,
        )
        .expect("spawn");
        let deadline =
            std::time::Instant::now() + std::time::Duration::from_secs_f64(2.0 * timeout_scale());
        while std::time::Instant::now() < deadline {
            // `mode()` can transiently fail immediately after spawn, before the child has
            // opened its slave (see `Pty::resize`'s doc comment) — tolerated the same way
            // `session::sample_mode` tolerates it: an `Err` this cycle just means try again.
            if pty.mode().is_ok_and(|mode| mode == Mode::Secret) {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        panic!("never observed Secret mode");
    }
}
