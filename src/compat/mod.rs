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

use nix::errno::Errno;
use std::io;

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
    "cooked has compat modules for Linux and macOS only. \
     Most of this crate is plain POSIX, so a new platform is usually a short file in \
     src/compat/ providing TIOCSCTTY, TIOCSWINSZ, slave_name and cloexec_pipe."
);

/// nix reports errors as [`Errno`]; the rest of cooked speaks [`io::Error`], and the
/// `EIO`-means-EOF check in `session::read_loop` depends on `raw_os_error` surviving.
pub fn nixerr(e: Errno) -> io::Error {
    io::Error::from_raw_os_error(e as i32)
}
