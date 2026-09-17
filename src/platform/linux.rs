//! Linux. Everything cooked wants, Linux has a first-class version of.

use nix::fcntl::OFlag;
use nix::pty::PtyMaster;
use std::ffi::CString;
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
