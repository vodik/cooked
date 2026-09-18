//! macOS. Three things Linux gives us for free have to be done by hand here.

use nix::fcntl::{FcntlArg, FdFlag, OFlag, fcntl};
use nix::libc;
use nix::poll::{PollFd, PollTimeout};
use nix::pty::PtyMaster;
use nix::sys::event::{EvFlags, EventFilter, FilterFlag, KEvent, Kqueue};
use nix::unistd::Pid;
use std::ffi::{CStr, CString};
use std::io;
use std::os::fd::{AsFd, OwnedFd};
use std::time::Duration;

/// Terminal ioctls the kernel has but neither `libc` nor `nix` defines for Apple.
///
/// BSD encodes the direction and payload size into the request number:
/// `TIOCSCTTY` is `_IO('t', 97)`, `TIOCSWINSZ` is `_IOW('t', 103, struct winsize)` and
/// `TIOCGWINSZ` is `_IOR('t', 104, struct winsize)`, with `IOC_VOID = 0x20000000`,
/// `IOC_IN = 0x80000000`, `IOC_OUT = 0x40000000` and the 8-byte `winsize` landing in
/// bits 16..29. Written out rather than computed so they can be checked against
/// `sys/ttycom.h` by eye. Wrapped as functions by nix's macros, as Linux's are.
nix::ioctl_write_int_bad!(
    #[allow(unreachable_pub)]
    tiocsctty,
    0x2000_7461
);
nix::ioctl_write_ptr_bad!(
    #[allow(unreachable_pub)]
    tiocswinsz,
    0x8008_7467,
    libc::winsize
);
nix::ioctl_read_bad!(
    #[allow(unreachable_pub)]
    tiocgwinsz,
    0x4008_7468,
    libc::winsize
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

/// Wait on FDS for at most WAIT, to the precision the platform offers.
///
/// Darwin has no `ppoll`, so this is `poll` with the wait rounded *up* to whole
/// milliseconds. Up rather than down, because a wait truncated to zero returns at once
/// and the reader spins through its iteration until the deadline passes; rounded up, a
/// sub-millisecond hold is released up to a millisecond late instead, which nobody can
/// see. See the Linux module for the deadlines this is about.
pub(crate) fn poll(fds: &mut [PollFd], wait: Duration) -> nix::Result<libc::c_int> {
    let millis = wait.as_millis() + u128::from(wait.subsec_nanos() % 1_000_000 != 0);
    let timeout = PollTimeout::try_from(millis).unwrap_or(PollTimeout::MAX);
    nix::poll::poll(fds, timeout)
}

/// Something that says when the process PID has exited.
///
/// A `kqueue` with one `EVFILT_PROC` / `NOTE_EXIT` event registered for the pid, which
/// is the BSD spelling of Linux's `pidfd`. Waited on with `kevent` rather than `poll`,
/// since `poll` on a kqueue descriptor is not something every Darwin has supported.
#[derive(Debug)]
pub(crate) struct ExitWatch(Kqueue);

impl ExitWatch {
    /// `None` when the kqueue cannot be made or the event cannot be registered -- the
    /// process may already be gone, which `kevent` answers with `ESRCH` -- and the
    /// caller falls back to asking `waitpid` on a timer.
    pub(crate) fn new(pid: Pid) -> Option<Self> {
        let kq = Kqueue::new().ok()?;
        let change = KEvent::new(
            pid.as_raw() as libc::uintptr_t,
            EventFilter::EVFILT_PROC,
            EvFlags::EV_ADD | EvFlags::EV_ONESHOT,
            FilterFlag::NOTE_EXIT,
            0,
            0,
        );
        // No room in the event list, so a registration that fails is the call failing.
        kq.kevent(&[change], &mut [], None).ok()?;
        Some(Self(kq))
    }

    /// Wait up to TIMEOUT for the process to exit, answering whether it has.
    ///
    /// `EV_ONESHOT`, so the event is delivered once; a later wait times out, which is
    /// right because by then `waitpid` succeeds without waiting.
    pub(crate) fn wait(&self, timeout: std::time::Duration) -> bool {
        let timeout = libc::timespec {
            tv_sec: timeout.as_secs() as libc::time_t,
            tv_nsec: libc::c_long::from(timeout.subsec_nanos()),
        };
        let mut events = [KEvent::new(
            0,
            EventFilter::EVFILT_PROC,
            EvFlags::empty(),
            FilterFlag::empty(),
            0,
            0,
        )];
        matches!(self.0.kevent(&[], &mut events, Some(timeout)), Ok(1..))
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

/// Start a child on the slave: not done here, so `None`, and the caller forks.
///
/// Darwin has `posix_spawn` with `POSIX_SPAWN_SETSID` and `addchdir_np`, and the `libc`
/// crate binds neither for it yet. The fork path in `pty::child_exec` is what has always
/// run here and is kept until the call can be tried on the platform itself.
pub(crate) fn spawn(
    _program: &CStr,
    _argv: &[CString],
    _envp: &[CString],
    _slave: &CStr,
    _cwd: Option<&CStr>,
) -> Option<crate::error::Result<Pid>> {
    None
}
