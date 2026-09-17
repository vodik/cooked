//! Platform-specific implementations, one module per platform.
//!
//! The rule here is that each platform gets the best facility it actually has, rather
//! than everything being levelled down to the intersection of all of them. Linux can
//! allocate a close-on-exec pipe in a single atomic call and has a reentrant
//! `ptsname_r`; macOS has neither, so its module pays for that locally instead of the
//! cost and the caveats being spread everywhere.
//!
//! Adding a platform means adding a file here that provides this surface:
//!
//! | item | why it is here |
//! |---|---|
//! | [`winsize`], [`set_winsize`], and the raw `tiocsctty`, `tiocswinsz` for the child | the request numbers differ, and libc and nix do not define them for every target |
//! | [`POSIX_VDISABLE`] | zero on Linux, `0xff` on the BSDs |
//! | [`slave_name`] | reentrant where possible, careful where not |
//! | [`cloexec_pipe`] | atomic where possible, two-step where not |
//! | [`ExitWatch`] | `pidfd` on Linux, `kqueue` on Darwin |
//! | [`open_slave`] | `TIOCGPTPEER` where there is one, the path where not |
//! | [`signal_foreground`] | `TIOCSIG` where there is one, `None` where not |
//! | [`spawn`] | `posix_spawn` where its attributes suffice, `None` where the fork path stays |
//!
//! Nothing above the shim should carry a `cfg`; if a caller needs one, the abstraction
//! is in the wrong place.
//!
//! # Where `libc` is still called directly
//!
//! nix covers nearly everything here, reached as `nix::libc` for the few things it does
//! not wrap, and errors cross as [`nix::errno::Errno`], which `?` widens to the crate's
//! own error. The raw calls that remain are not leftovers:
//!
//!   `fork`, and everything  only async-signal-safe calls are legal after a fork in a
//!   in `pty::child_exec`    multithreaded process, which rules out any wrapper that
//!                           allocates or reasons about paths. See that function.
//!   `pidfd_open`            nix has no binding; one raw syscall in [`ExitWatch`].
//!   `addchdir_np`,          nix's `spawn` module has neither the glibc extension nor
//!   `POSIX_SPAWN_SETSID`    the flag; both go in beside its own calls in [`spawn`].
//!
//! Everything else named `libc::` in this crate is a type or constant alias.

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
pub(crate) use linux::*;

#[cfg(target_vendor = "apple")]
mod apple;
#[cfg(target_vendor = "apple")]
pub(crate) use apple::*;

#[cfg(not(any(target_os = "linux", target_vendor = "apple")))]
compile_error!(
    "cooked has platform modules for Linux and macOS only. \
     Most of this crate is plain POSIX, so a new platform is usually a short file in \
     src/platform/ providing TIOCSCTTY, TIOCSWINSZ, slave_name and cloexec_pipe."
);
