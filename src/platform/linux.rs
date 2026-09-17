//! Linux. Everything cooked wants, Linux has a first-class version of.

use nix::fcntl::OFlag;
use nix::pty::PtyMaster;
use std::ffi::{CStr, CString};
use std::io;
use std::os::fd::OwnedFd;

pub(crate) const TIOCSCTTY: libc::c_ulong = libc::TIOCSCTTY;
pub(crate) const TIOCSWINSZ: libc::c_ulong = libc::TIOCSWINSZ;
pub(crate) const TIOCGWINSZ: libc::c_ulong = libc::TIOCGWINSZ;

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
/// is opened instead. Only async-signal-safe calls: this runs between fork and exec.
pub(crate) unsafe fn open_slave(master: libc::c_int, slave: *const libc::c_char) -> libc::c_int {
    let flags = libc::O_RDWR | libc::O_NOCTTY;
    // SAFETY: two syscalls on descriptors and a NUL-terminated path the caller owns.
    unsafe {
        let fd = libc::ioctl(master, libc::TIOCGPTPEER, flags);
        if fd >= 0 {
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
    let rc = unsafe { libc::ioctl(master.as_raw_fd(), libc::TIOCSIG, sig as libc::c_int) };
    Some(nix::errno::Errno::result(rc).map(drop))
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
/// The initial window size is not set here: the parent sets it on the master once this
/// returns, which Linux accepts at any time.
///
/// `Some` always: this platform has the call. Darwin answers `None` and the caller
/// forks; see [`crate::platform`].
pub(crate) fn spawn(
    program: &CStr,
    argv: &[*const libc::c_char],
    envp: &[*const libc::c_char],
    slave: &CStr,
    cwd: Option<&CStr>,
) -> Option<crate::error::Result<libc::pid_t>> {
    use nix::errno::Errno;
    /// An errno-returning call, `posix_spawn` style: zero is success.
    fn check(rc: libc::c_int) -> crate::error::Result<()> {
        if rc == 0 {
            Ok(())
        } else {
            Err(Errno::from_raw(rc).into())
        }
    }
    // SAFETY: every call below is an FFI call on structures initialised by the matching
    // `_init`, destroyed on every path out, with pointers that outlive the `posix_spawn`.
    let result = unsafe {
        let mut attr = std::mem::MaybeUninit::<libc::posix_spawnattr_t>::uninit();
        if let Err(e) = check(libc::posix_spawnattr_init(attr.as_mut_ptr())) {
            return Some(Err(e));
        }
        let mut actions = std::mem::MaybeUninit::<libc::posix_spawn_file_actions_t>::uninit();
        if let Err(e) = check(libc::posix_spawn_file_actions_init(actions.as_mut_ptr())) {
            libc::posix_spawnattr_destroy(attr.as_mut_ptr());
            return Some(Err(e));
        }
        let attr = attr.as_mut_ptr();
        let actions = actions.as_mut_ptr();
        let spawned = (|| {
            let mut all = std::mem::zeroed::<libc::sigset_t>();
            libc::sigfillset(&raw mut all);
            let mut none = std::mem::zeroed::<libc::sigset_t>();
            libc::sigemptyset(&raw mut none);
            check(libc::posix_spawnattr_setsigdefault(attr, &raw const all))?;
            check(libc::posix_spawnattr_setsigmask(attr, &raw const none))?;
            let flags = [
                libc::POSIX_SPAWN_SETSID as libc::c_short,
                libc::POSIX_SPAWN_SETSIGDEF as libc::c_short,
                libc::POSIX_SPAWN_SETSIGMASK as libc::c_short,
            ]
            .into_iter()
            .fold(0, |acc, flag| acc | flag);
            check(libc::posix_spawnattr_setflags(attr, flags))?;
            if let Some(dir) = cwd {
                check(libc::posix_spawn_file_actions_addchdir_np(
                    actions,
                    dir.as_ptr(),
                ))?;
            }
            check(libc::posix_spawn_file_actions_addopen(
                actions,
                0,
                slave.as_ptr(),
                libc::O_RDWR,
                0,
            ))?;
            check(libc::posix_spawn_file_actions_adddup2(actions, 0, 1))?;
            check(libc::posix_spawn_file_actions_adddup2(actions, 0, 2))?;
            let mut pid: libc::pid_t = 0;
            check(libc::posix_spawn(
                &raw mut pid,
                program.as_ptr(),
                actions,
                attr,
                // The prototype spells the vectors mutable, as C's does; nothing writes
                // through them.
                argv.as_ptr().cast::<*mut libc::c_char>(),
                envp.as_ptr().cast::<*mut libc::c_char>(),
            ))?;
            Ok(pid)
        })();
        libc::posix_spawn_file_actions_destroy(actions);
        libc::posix_spawnattr_destroy(attr);
        spawned
    };
    Some(result)
}
