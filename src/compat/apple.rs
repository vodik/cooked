//! macOS. Three things Linux gives us for free have to be done by hand here.

use super::nixerr;
use nix::fcntl::{FcntlArg, FdFlag, OFlag, fcntl};
use nix::pty::PtyMaster;
use std::ffi::CString;
use std::io;
use std::os::fd::{AsFd, OwnedFd};

/// Terminal ioctls the kernel has but neither `libc` nor `nix` defines for Apple.
///
/// BSD encodes the direction and payload size into the request number:
/// `TIOCSCTTY` is `_IO('t', 97)` and `TIOCSWINSZ` is `_IOW('t', 103, struct winsize)`,
/// with `IOC_VOID = 0x20000000`, `IOC_IN = 0x80000000` and the 8-byte `winsize` landing
/// in bits 16..29. Written out rather than computed so they can be checked against
/// `sys/ttycom.h` by eye.
pub const TIOCSCTTY: libc::c_ulong = 0x2000_7461;
pub const TIOCSWINSZ: libc::c_ulong = 0x8008_7467;

/// Path of the slave belonging to `master`.
///
/// macOS has no `ptsname_r`, only `ptsname`, which returns a pointer to a static buffer
/// — hence nix marking it `unsafe`. The exposure is another thread in this process
/// calling `ptsname` between our call and the copy below, which would need a second
/// terminal emulator inside the same Emacs racing us on the same instant. We copy
/// immediately and hold nothing.
pub fn slave_name(master: &PtyMaster) -> io::Result<CString> {
    let name = unsafe { nix::pty::ptsname(master) }.map_err(nixerr)?;
    CString::new(name).map_err(|_| io::Error::other("interior NUL in pty name"))
}

/// A pipe neither end of which survives an exec.
///
/// No `pipe2`, so the flags go on afterwards and there is a window — between `pipe`
/// returning and the `fcntl`s landing — in which a fork on another thread would inherit
/// both ends. Unavoidable without `pipe2`; it is microseconds once per session, and the
/// descriptors are a wakeup pipe rather than anything secret.
pub fn cloexec_pipe() -> io::Result<(OwnedFd, OwnedFd)> {
    let (read, write) = nix::unistd::pipe().map_err(nixerr)?;
    for fd in [read.as_fd(), write.as_fd()] {
        fcntl(fd, FcntlArg::F_SETFD(FdFlag::FD_CLOEXEC)).map_err(nixerr)?;
        let flags = OFlag::from_bits_truncate(fcntl(fd, FcntlArg::F_GETFL).map_err(nixerr)?);
        fcntl(fd, FcntlArg::F_SETFL(flags | OFlag::O_NONBLOCK)).map_err(nixerr)?;
    }
    Ok((read, write))
}
