//! Linux. Everything cooked wants, Linux has a first-class version of.

use super::nixerr;
use nix::fcntl::OFlag;
use nix::pty::PtyMaster;
use std::ffi::CString;
use std::io;
use std::os::fd::OwnedFd;

pub const TIOCSCTTY: libc::c_ulong = libc::TIOCSCTTY;
pub const TIOCSWINSZ: libc::c_ulong = libc::TIOCSWINSZ;

/// Path of the slave belonging to `master`.
///
/// `ptsname_r` writes into a caller-supplied buffer, so unlike `ptsname` there is no
/// shared static to race over and no window to copy out of.
pub fn slave_name(master: &PtyMaster) -> io::Result<CString> {
    let name = nix::pty::ptsname_r(master).map_err(nixerr)?;
    CString::new(name).map_err(|_| io::Error::other("interior NUL in pty name"))
}

/// A pipe neither end of which survives an exec.
///
/// `pipe2` applies the flags as part of creating the descriptors, so there is no
/// instant in which they exist without `FD_CLOEXEC` — which matters in Emacs, where
/// another thread may fork at any moment and would otherwise inherit both ends.
pub fn cloexec_pipe() -> io::Result<(OwnedFd, OwnedFd)> {
    nix::unistd::pipe2(OFlag::O_CLOEXEC | OFlag::O_NONBLOCK).map_err(nixerr)
}
