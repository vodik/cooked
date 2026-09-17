//! Linux. Everything cooked wants, Linux has a first-class version of.

use nix::fcntl::OFlag;
use nix::libc;
use nix::pty::PtyMaster;
use std::ffi::{CStr, CString};
use std::io;
use std::os::fd::OwnedFd;

// The tty ioctls, as functions: `ioctl(fd, request, arg)` with the result checked, and
// the request number written once. `unreachable_pub` is allowed because the macros can
// only make them `pub`, and `pub(crate)` is what a private module makes of that.
nix::ioctl_write_int_bad!(
    #[allow(unreachable_pub)]
    tiocsctty,
    libc::TIOCSCTTY
);
nix::ioctl_write_ptr_bad!(
    #[allow(unreachable_pub)]
    tiocswinsz,
    libc::TIOCSWINSZ,
    libc::winsize
);
nix::ioctl_read_bad!(
    #[allow(unreachable_pub)]
    tiocgwinsz,
    libc::TIOCGWINSZ,
    libc::winsize
);
nix::ioctl_write_int_bad!(
    #[allow(unreachable_pub)]
    tiocsig,
    libc::TIOCSIG
);
nix::ioctl_write_int_bad!(
    #[allow(unreachable_pub)]
    tiocgptpeer,
    libc::TIOCGPTPEER
);

/// The tty's window size, as the kernel holds it.
pub(crate) fn winsize(fd: std::os::fd::BorrowedFd<'_>) -> nix::Result<libc::winsize> {
    use std::os::fd::AsRawFd;
    let mut ws = libc::winsize {
        ws_row: 0,
        ws_col: 0,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    // SAFETY: an ioctl on a live descriptor into a struct that outlives it.
    unsafe { tiocgwinsz(fd.as_raw_fd(), &raw mut ws) }?;
    Ok(ws)
}

/// Set the tty's window size.
///
/// The safe face of `tiocswinsz`, for the parent; the child between fork and exec calls
/// the raw one on the descriptor number it has.
pub(crate) fn set_winsize(fd: std::os::fd::BorrowedFd<'_>, ws: &libc::winsize) -> nix::Result<()> {
    use std::os::fd::AsRawFd;
    // SAFETY: an ioctl on a live descriptor from a struct that outlives it.
    unsafe { tiocswinsz(fd.as_raw_fd(), ws) }.map(drop)
}

/// `_POSIX_VDISABLE` — the `c_cc` value meaning "this character is turned off".
pub(crate) const POSIX_VDISABLE: libc::cc_t = 0;

/// Path of the slave belonging to `master`.
///
/// `ptsname_r` writes into a caller-supplied buffer, so unlike `ptsname` there is no
/// shared static to race over and no window to copy out of.
pub(crate) fn slave_name(master: &PtyMaster) -> crate::error::Result<CString> {
    let name = nix::pty::ptsname_r(master)?;
    Ok(CString::new(name)?)
}

/// A pipe neither end of which survives an exec.
///
/// `pipe2` applies the flags as part of creating the descriptors, so there is no
/// instant in which they exist without `FD_CLOEXEC` — which matters in Emacs, where
/// another thread may fork at any moment and would otherwise inherit both ends.
pub(crate) fn cloexec_pipe() -> io::Result<(OwnedFd, OwnedFd)> {
    Ok(nix::unistd::pipe2(OFlag::O_CLOEXEC | OFlag::O_NONBLOCK)?)
}

/// Something that says when the process PID has exited.
///
/// A `pidfd` (Linux 5.3), polled: the kernel says the moment `waitpid` will succeed,
/// which is how `Pty::reap` waits without a timer. Opened right after the fork and
/// before anything could reap the child, so the pid it names cannot have been reused.
#[derive(Debug)]
pub(crate) struct ExitWatch(OwnedFd);

impl ExitWatch {
    /// `None` where the kernel or a seccomp filter refuses, and the caller falls back to
    /// asking `waitpid` on a timer.
    pub(crate) fn new(pid: libc::pid_t) -> Option<Self> {
        use std::os::fd::FromRawFd;
        // SAFETY: `pidfd_open` takes a pid and flags and returns a new descriptor or -1;
        // there is no memory for it to touch. Every pidfd is close-on-exec by construction.
        let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
        (fd >= 0).then(|| Self(unsafe { OwnedFd::from_raw_fd(fd as std::os::fd::RawFd) }))
    }

    /// Wait up to TIMEOUT for the process to exit, answering whether it has.
    ///
    /// A `false` is a timeout or a signal, and the caller re-checks its own deadline;
    /// a `true` means `waitpid` will not block.
    pub(crate) fn wait(&self, timeout: std::time::Duration) -> bool {
        use nix::poll::{PollFd, PollFlags, PollTimeout, poll};
        use std::os::fd::AsFd;
        let mut fds = [PollFd::new(self.0.as_fd(), PollFlags::POLLIN)];
        let timeout = PollTimeout::try_from(timeout).unwrap_or(PollTimeout::MAX);
        matches!(poll(&mut fds, timeout), Ok(1..))
    }
}

/// The slave end of MASTER, opened for the child; see `pty::child_exec`.
///
/// `TIOCGPTPEER` (Linux 4.13) opens it from the master alone, which needs no path and so
/// works inside a mount namespace whose `/dev/pts` is not the one the master came from.
/// Older kernels answer `ENOTTY` or `EINVAL`, and SLAVE, the path `ptsname_r` gave,
/// is opened instead. Only async-signal-safe calls: this runs between fork and exec, so
/// the fallback is `libc::open` rather than `nix::fcntl::open`, which is the same call
/// behind a path conversion this window cannot afford to reason about.
pub(crate) unsafe fn open_slave(master: libc::c_int, slave: *const libc::c_char) -> libc::c_int {
    let flags = libc::O_RDWR | libc::O_NOCTTY;
    // SAFETY: two syscalls on descriptors and a NUL-terminated path the caller owns.
    unsafe {
        if let Ok(fd) = tiocgptpeer(master, flags) {
            return fd;
        }
        libc::open(slave, flags)
    }
}

/// Signal the pty's foreground process group, as a keystroke would.
///
/// `TIOCSIG` on the master has the kernel deliver to whatever group holds the terminal
/// at that instant, under its own lock. The `tcgetpgrp` then `killpg` it replaces had a
/// window between the two in which the group could change hands. `None` for a signal
/// the kernel will not carry this way -- it takes exactly the three a keystroke can
/// raise -- and the caller takes the two-step path.
pub(crate) fn signal_foreground(
    master: std::os::fd::BorrowedFd<'_>,
    sig: nix::sys::signal::Signal,
) -> Option<nix::Result<()>> {
    use nix::sys::signal::Signal;
    use std::os::fd::AsRawFd;
    if !matches!(sig, Signal::SIGINT | Signal::SIGQUIT | Signal::SIGTSTP) {
        return None;
    }
    // SAFETY: an ioctl on a live descriptor with an integer argument.
    Some(unsafe { tiocsig(master.as_raw_fd(), sig as libc::c_int) }.map(drop))
}

/// Start PROGRAM with ARGV and ENVP on the slave SLAVE, in a session of its own, with
/// CWD as its directory: the pid, or the error that stopped it.
///
/// `posix_spawn`, which glibc runs on `clone(CLONE_VM | CLONE_VFORK)`: no copy of Emacs'
/// page tables, which for a large heap is milliseconds a spawn and can fail outright
/// under strict overcommit, and no window in which a half-made child runs Emacs' signal
/// handlers. The call returns once the child has exec'd or failed to, so a program that
/// cannot be run comes back here as its errno rather than as a session that dies with
/// status 127 a moment later.
///
/// What the fork path did by hand is done by attributes and file actions:
/// `POSIX_SPAWN_SETSID` makes the session, and a session leader that then opens a tty
/// without `O_NOCTTY` acquires it as its controlling terminal, so the open of the slave
/// onto fd 0 is also the `TIOCSCTTY`; the two `dup2`s fill 1 and 2; every signal goes
/// back to its default and the mask is emptied, since Emacs ignores SIGPIPE and blocks
/// signals and a child inheriting that is subtly broken. The master is close-on-exec.
///
/// Through `nix::spawn` but for two things it has no spelling for: the `SETSID` flag,
/// which goes in as a raw bit, and `addchdir_np`, a glibc extension called on the
/// actions object directly, which `repr(transparent)` makes sound.
///
/// The initial window size is not set here: the parent sets it on the master once this
/// returns, which Linux accepts at any time.
///
/// `Some` always: this platform has the call. Darwin answers `None` and the caller
/// forks; see [`crate::platform`].
pub(crate) fn spawn(
    program: &CStr,
    argv: &[CString],
    envp: &[CString],
    slave: &CStr,
    cwd: Option<&CStr>,
) -> Option<crate::error::Result<libc::pid_t>> {
    use nix::errno::Errno;
    use nix::spawn::{PosixSpawnAttr, PosixSpawnFileActions, PosixSpawnFlags, posix_spawn};
    use nix::sys::signal::SigSet;
    use nix::sys::stat::Mode;
    let spawned = (|| -> crate::error::Result<libc::pid_t> {
        let mut attr = PosixSpawnAttr::init()?;
        attr.set_sigdefault(&SigSet::all())?;
        attr.set_sigmask(&SigSet::empty())?;
        attr.set_flags(
            PosixSpawnFlags::POSIX_SPAWN_SETSIGDEF
                | PosixSpawnFlags::POSIX_SPAWN_SETSIGMASK
                | PosixSpawnFlags::from_bits_retain(libc::POSIX_SPAWN_SETSID as libc::c_int),
        )?;
        let mut actions = PosixSpawnFileActions::init()?;
        if let Some(dir) = cwd {
            // SAFETY: `PosixSpawnFileActions` is `repr(transparent)` over the libc
            // struct, initialised by the `init` above and destroyed on drop.
            let rc = unsafe {
                libc::posix_spawn_file_actions_addchdir_np(
                    (&raw mut actions).cast::<libc::posix_spawn_file_actions_t>(),
                    dir.as_ptr(),
                )
            };
            if rc != 0 {
                return Err(Errno::from_raw(rc).into());
            }
        }
        actions.add_open(0, slave, OFlag::O_RDWR, Mode::empty())?;
        actions.add_dup2(0, 1)?;
        actions.add_dup2(0, 2)?;
        Ok(posix_spawn(program, &actions, &attr, argv, envp)?.as_raw())
    })();
    Some(spawned)
}
