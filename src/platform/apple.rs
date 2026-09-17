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

/// Something that says when the process PID has exited.
///
/// A `kqueue` with one `EVFILT_PROC` / `NOTE_EXIT` event registered for the pid, which
/// is the BSD spelling of Linux's `pidfd`. Waited on with `kevent` rather than `poll`,
/// since `poll` on a kqueue descriptor is not something every Darwin has supported.
#[derive(Debug)]
pub(crate) struct ExitWatch(OwnedFd);

impl ExitWatch {
    /// `None` when the kqueue cannot be made or the event cannot be registered -- the
    /// process may already be gone, which `kevent` answers with `ESRCH` -- and the
    /// caller falls back to asking `waitpid` on a timer.
    pub(crate) fn new(pid: libc::pid_t) -> Option<Self> {
        use std::os::fd::{AsRawFd, FromRawFd};
        // SAFETY: `kqueue` takes nothing and returns a descriptor or -1.
        let kq = unsafe { libc::kqueue() };
        if kq < 0 {
            return None;
        }
        // SAFETY: the descriptor is ours from the line above.
        let kq = unsafe { OwnedFd::from_raw_fd(kq) };
        // Close-on-exec, so a session spawned while this one is being torn down does not
        // inherit it; kqueue descriptors are not inherited across fork, but the flag
        // costs nothing and states the intent.
        let _ = fcntl(kq.as_fd(), FcntlArg::F_SETFD(FdFlag::FD_CLOEXEC));
        let change = libc::kevent {
            ident: pid as libc::uintptr_t,
            filter: libc::EVFILT_PROC,
            flags: libc::EV_ADD | libc::EV_ONESHOT,
            fflags: libc::NOTE_EXIT,
            data: 0,
            udata: std::ptr::null_mut(),
        };
        // SAFETY: one change, no events asked for, no timeout; the struct outlives the
        // call.
        let rc = unsafe {
            libc::kevent(
                kq.as_raw_fd(),
                &change,
                1,
                std::ptr::null_mut(),
                0,
                std::ptr::null(),
            )
        };
        (rc == 0).then_some(Self(kq))
    }

    /// Wait up to TIMEOUT for the process to exit, answering whether it has.
    ///
    /// `EV_ONESHOT`, so the event is delivered once; a later wait times out, which is
    /// right because by then `waitpid` succeeds without waiting.
    pub(crate) fn wait(&self, timeout: std::time::Duration) -> bool {
        use std::os::fd::AsRawFd;
        let timeout = libc::timespec {
            tv_sec: timeout.as_secs() as libc::time_t,
            tv_nsec: libc::c_long::from(timeout.subsec_nanos()),
        };
        let mut event = std::mem::MaybeUninit::<libc::kevent>::uninit();
        // SAFETY: no changes, room for one event, a timeout that outlives the call.
        let rc = unsafe {
            libc::kevent(
                self.0.as_raw_fd(),
                std::ptr::null(),
                0,
                event.as_mut_ptr(),
                1,
                &timeout,
            )
        };
        rc > 0
    }
}

/// The slave end of MASTER, opened for the child; see `pty::child_exec`.
///
/// By path: Darwin has no `TIOCGPTPEER`. Only async-signal-safe calls, since this runs
/// between fork and exec.
pub(crate) unsafe fn open_slave(_master: libc::c_int, slave: *const libc::c_char) -> libc::c_int {
    // SAFETY: one syscall on a NUL-terminated path the caller owns.
    unsafe { libc::open(slave, libc::O_RDWR | libc::O_NOCTTY) }
}

/// Signal the pty's foreground process group: not something Darwin's master can be
/// asked to do, so `None` and the caller reads the group and signals it itself.
pub(crate) fn signal_foreground(
    _master: std::os::fd::BorrowedFd<'_>,
    _sig: nix::sys::signal::Signal,
) -> Option<nix::Result<()>> {
    None
}
