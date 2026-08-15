//! Pseudoterminal ownership, and the line-discipline signal the rest of cooked is built on.
//!
//! We allocate the pty ourselves rather than letting Emacs do it, because only the master
//! fd exposes the child's termios via [`Pty::mode`].
//!
//! Note that Linux offers no push notification for this. Packet mode (`TIOCPKT`) reports
//! only flow-control and `EXTPROC` transitions — `ICANON`/`ECHO` changes are silent, so
//! callers must sample [`Pty::mode`]. The reader thread already wakes on a poll timeout,
//! which makes sampling free in practice; see `session::read_loop`.

//! Parent-side syscalls go through `nix`, so failures arrive as `Result` and termios and
//! wait statuses as types rather than bit patterns. The one exception is `child_exec`,
//! which runs between `fork` and `exec` and must stay allocation-free; see the comment
//! there for why no wrapper is safe in that window.

use crate::error::{Error, Result};
use nix::errno::Errno;
use nix::fcntl::{FcntlArg, FdFlag, fcntl};
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
    /// One cell in pixels, zero when unreported.
    ///
    /// A terminal frame has no such thing and leaves this at zero, which is what the
    /// struct meant before it carried the field at all. On a graphical frame it is the
    /// font's, and it moves with `text-scale-mode` as well as with the font — so it is
    /// reported alongside the row and column count rather than sampled once.
    ///
    /// The child needs it: an image protocol sizes a transmission in pixels, and tools
    /// consult `ws_xpixel`/`ws_ypixel` — or the XTWINOPS reports built from them —
    /// before deciding whether to draw a picture at all.
    pub cell: CellMetrics,
}

impl From<Winsize> for libc::winsize {
    fn from(w: Winsize) -> Self {
        Self {
            ws_row: w.rows,
            ws_col: w.cols,
            // The text area, which is what these fields mean: cells times cell size.
            ws_xpixel: w.cols.saturating_mul(w.cell.width),
            ws_ypixel: w.rows.saturating_mul(w.cell.height),
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
}

/// How long [`Pty::write`] waits on a child that is not draining its input before it
/// gives up and reports an error rather than blocking Emacs' single thread further.
/// Generous enough that a legitimate large bracketed paste to a briefly slow reader
/// (a shell about to start echoing) never trips it; short enough that a genuinely
/// stopped job (`C-z`) turns into a prompt error instead of a frozen editor.
const WRITE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(3);

/// Cap a remaining-time budget to what [`nix::poll::poll`] accepts, without waiting past
/// the deadline computed from [`WRITE_TIMEOUT`].
fn poll_timeout(remaining: std::time::Duration) -> PollTimeout {
    PollTimeout::try_from(remaining).unwrap_or(PollTimeout::MAX)
}

/// The grace period `Drop`'s own `SIGHUP`-then-`SIGKILL` escalation gives at each step.
/// Same value as `session::KILL_GRACE`, kept as its own constant rather than shared:
/// this path only runs when something has already gone wrong (teardown outside
/// `Session::shutdown`), and it should not gain a dependency on `session`'s internals
/// to stay that short.
const DROP_KILL_GRACE: std::time::Duration = std::time::Duration::from_millis(50);

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

        Ok(Self {
            master,
            child: Pid(child),
            reaped: std::sync::atomic::AtomicBool::new(false),
            reap_lock: std::sync::Mutex::new(()),
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
            cell: CellMetrics {
                width: ws.ws_xpixel.checked_div(ws.ws_col.max(1)).unwrap_or(0),
                height: ws.ws_ypixel.checked_div(ws.ws_row.max(1)).unwrap_or(0),
            },
        })
    }

    /// Write to the child, without blocking Emacs' only thread forever on it.
    ///
    /// The master is a blocking fd, and `write(2)` on a tty blocks once its input queue
    /// is full — a stopped job (`C-z`/`SIGSTOP`), a full-screen program not reading, or
    /// flow control all fill it. This function is called directly on the thread holding
    /// the `emacs_env` (see `env.rs`'s own rule that such a thread must never block), so
    /// it polls for writability first and gives up after [`WRITE_TIMEOUT`] rather than
    /// waiting on the child indefinitely. A short individual poll keeps the common case
    /// (plenty of room) indistinguishable from the old unconditional write; the bound
    /// only ever bites when the child truly cannot make progress.
    pub(crate) fn write(&self, mut buf: &[u8]) -> Result<()> {
        let deadline = std::time::Instant::now() + WRITE_TIMEOUT;
        while !buf.is_empty() {
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            if remaining.is_zero() {
                return Err(Error::WriteTimeout);
            }
            let mut fds = [PollFd::new(self.master.as_fd(), PollFlags::POLLOUT)];
            match nix::poll::poll(&mut fds, poll_timeout(remaining)) {
                Ok(0) => continue, // timed out this round; loop re-checks the deadline
                Ok(_) => {}
                Err(Errno::EINTR) => continue,
                Err(e) => return Err(e.into()),
            }
            if !fds[0]
                .revents()
                .is_some_and(|r| r.contains(PollFlags::POLLOUT))
            {
                continue;
            }
            match nix::unistd::write(self.master.as_fd(), buf) {
                Ok(n) => buf = &buf[n..],
                Err(Errno::EINTR) | Err(Errno::EAGAIN) => {}
                Err(e) => return Err(e.into()),
            }
        }
        Ok(())
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
        match self.foreground().unwrap_or(self.child) {
            // `killpg` rather than `kill(-pid)`: the negation was the whole footgun.
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
    pub(crate) fn reap(&self, patience: std::time::Duration) -> Option<i32> {
        let deadline = std::time::Instant::now() + patience;
        loop {
            match self.try_wait() {
                Ok(Some(status)) => return Some(status),
                Ok(None) if std::time::Instant::now() < deadline => {
                    std::thread::sleep(std::time::Duration::from_millis(2));
                }
                _ => return None,
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
        let _ = killpg(NixPid::from_raw(self.child.0), Signal::SIGHUP);
        if self.reap(DROP_KILL_GRACE).is_some() {
            return;
        }
        let _ = killpg(NixPid::from_raw(self.child.0), Signal::SIGKILL);
        let _ = self.reap(DROP_KILL_GRACE);
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
    use nix::fcntl::OFlag;
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
        // Belt to `O_CLOEXEC`'s braces: the master is ours alone, and a child that can
        // read it can steal input meant for its own siblings. Nothing useful can be done
        // if this fails, and failing the spawn over it would be a regression.
        libc::close(master);
        let fd = libc::open(slave, libc::O_RDWR);
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

#[cfg(test)]
mod tests {
    use super::*;

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
                cell: CellMetrics::default(),
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
                cell: CellMetrics::default(),
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
                cell: CellMetrics::default(),
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
                cell: CellMetrics::default(),
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
                cell: CellMetrics::default(),
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
            cell: CellMetrics::default(),
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
            cell: CellMetrics::default(),
        };
        let pty = Pty::spawn(
            &["/bin/sh", "-c", "stty -echo; read x"],
            &[("TERM", "dumb")],
            size,
            None,
        )
        .expect("spawn");
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
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
