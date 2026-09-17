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

/// A descriptor that becomes readable once the process PID has exited.
///
/// `pidfd_open`, Linux 5.3. Polling it is how `Pty::reap` waits for a child to become
/// reapable without sleeping in a loop: the kernel says the moment `waitpid` will
/// succeed. `None` where the kernel or a seccomp filter refuses, and the caller falls
/// back to asking `waitpid` on a timer.
///
/// Opened right after the fork and before anything could reap the child, so the pid it
/// names cannot have been reused.
pub(crate) fn exit_watch(pid: libc::pid_t) -> Option<OwnedFd> {
    use std::os::fd::FromRawFd;
    // SAFETY: `pidfd_open` takes a pid and flags and returns a new descriptor or -1;
    // there is no memory for it to touch.
    let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
    // Every pidfd is close-on-exec by construction.
    (fd >= 0).then(|| unsafe { OwnedFd::from_raw_fd(fd as std::os::fd::RawFd) })
}
