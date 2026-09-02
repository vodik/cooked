//! macOS. Three things Linux gives us for free have to be done by hand here.

use nix::fcntl::{FcntlArg, FdFlag, OFlag, fcntl};
use nix::pty::PtyMaster;
use std::ffi::CString;
use std::io;
use std::os::fd::{AsFd, OwnedFd};

/// Terminal ioctls the kernel has but neither `libc` nor `nix` defines for Apple.
///
/// BSD encodes the direction and payload size into the request number:
/// `TIOCSCTTY` is `_IO('t', 97)`, `TIOCSWINSZ` is `_IOW('t', 103, struct winsize)` and
/// `TIOCGWINSZ` is `_IOR('t', 104, struct winsize)`, with `IOC_VOID = 0x20000000`,
/// `IOC_IN = 0x80000000`, `IOC_OUT = 0x40000000` and the 8-byte `winsize` landing in
/// bits 16..29. Written out rather than computed so they can be checked against
/// `sys/ttycom.h` by eye.
pub(crate) const TIOCSCTTY: libc::c_ulong = 0x2000_7461;
pub(crate) const TIOCSWINSZ: libc::c_ulong = 0x8008_7467;
pub(crate) const TIOCGWINSZ: libc::c_ulong = 0x4008_7468;

/// `_POSIX_VDISABLE` — the `c_cc` value meaning "this character is turned off".
///
/// Not zero here, unlike Linux: the BSDs spell it `0xff`, and NUL is a perfectly ordinary
/// character a `c_cc` slot may legitimately hold.
pub(crate) const POSIX_VDISABLE: libc::cc_t = 0xff;

/// Path of the slave belonging to `master`.
///
/// macOS has no `ptsname_r`, only `ptsname`, which returns a pointer to a static buffer
/// — hence nix marking it `unsafe`. The exposure is another thread in this process
/// calling `ptsname` between our call and the copy below, which would need a second
/// terminal emulator inside the same Emacs racing us on the same instant. We copy
/// immediately and hold nothing.
pub(crate) fn slave_name(master: &PtyMaster) -> crate::error::Result<CString> {
    let name = unsafe { nix::pty::ptsname(master) }?;
    Ok(CString::new(name)?)
}

/// A pipe neither end of which survives an exec.
///
/// No `pipe2`, so the flags go on afterwards and there is a window — between `pipe`
/// returning and the `fcntl`s landing — in which a fork on another thread would inherit
/// both ends. Unavoidable without `pipe2`; it is microseconds once per session, and the
/// descriptors are a wakeup pipe rather than anything secret.
pub(crate) fn cloexec_pipe() -> io::Result<(OwnedFd, OwnedFd)> {
    let (read, write) = nix::unistd::pipe()?;
    for fd in [read.as_fd(), write.as_fd()] {
        fcntl(fd, FcntlArg::F_SETFD(FdFlag::FD_CLOEXEC))?;
        let flags = OFlag::from_bits_truncate(fcntl(fd, FcntlArg::F_GETFL)?);
        fcntl(fd, FcntlArg::F_SETFL(flags | OFlag::O_NONBLOCK))?;
    }
    Ok((read, write))
}
