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
//! | [`TIOCSCTTY`], [`TIOCSWINSZ`], [`TIOCGWINSZ`] | libc and nix do not define these for every target |
//! | [`POSIX_VDISABLE`] | zero on Linux, `0xff` on the BSDs |
//! | [`slave_name`] | reentrant where possible, careful where not |
//! | [`cloexec_pipe`] | atomic where possible, two-step where not |
//!
//! Nothing above the shim should carry a `cfg`; if a caller needs one, the abstraction
//! is in the wrong place.
//!
//! # Why the rest of the crate still calls `libc` directly
//!
//! nix covers everything it reasonably can here, and errors cross as [`nix::errno::Errno`], which
//! `?` widens to [`std::io::Error`] on its own -- there is no conversion shim, because nix's
//! own `From` is exactly `io::Error::from_raw_os_error`. The `libc` calls that remain
//! are not leftovers, and swapping them is not an improvement:
//!
//!   `fork`               nix's runs registered `pthread_atfork` handlers, which this
//!                        cannot afford between the fork and the exec.
//!   `ioctl` for winsize  no released nix has `tcgetwinsize`/`tcsetwinsize`; `nix::pty`
//!                        only re-exports `libc::winsize`. The `ioctl_*_bad!` macros
//!                        would generate the same `unsafe fn` while moving the request
//!                        codes out of this module, which is the one place they belong.
//!   everything in        only async-signal-safe calls are legal after a fork in a
//!   `pty::child_exec`    multithreaded process, which rules out any wrapper that
//!                        allocates. See that function's own comment.
//!
//! Everything else named `libc::` in this crate is a type or constant alias.

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
pub use linux::*;

#[cfg(target_vendor = "apple")]
mod apple;
#[cfg(target_vendor = "apple")]
pub use apple::*;

#[cfg(not(any(target_os = "linux", target_vendor = "apple")))]
compile_error!(
    "cooked has platform modules for Linux and macOS only. \
     Most of this crate is plain POSIX, so a new platform is usually a short file in \
     src/platform/ providing TIOCSCTTY, TIOCSWINSZ, slave_name and cloexec_pipe."
);
