//! The crate's own error type.
//!
//! [`std::io::Error`] is the wrong currency for this crate, in both directions. It
//! collapses distinctions that matter: the program was not on `PATH`, the child had
//! already been reaped, and the tty had no foreground process group all arrive as
//! `ErrorKind::NotFound`, so a caller matching on the kind cannot tell a user's typo
//! from an ordinary race. And it has no kind at all for the two conditions this crate
//! most needs to name -- `ENOTTY` on a resize, `EIO` on a read -- which leaves a caller
//! reconstructing the errno through `raw_os_error` to recover what the conversion threw
//! away.
//!
//! Written by hand rather than derived. With this many variants the `Display` match is one
//! arm each and the conversions are three impls, which is less text than the attributes
//! would be -- and it keeps the crate free of proc-macro dependencies.

use nix::errno::Errno;
use std::ffi::OsString;
use std::fmt;

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// A spawn with nothing to exec.
    EmptyArgv,
    /// An argument, environment entry or pty name with a NUL inside it. Nothing that has
    /// to cross `execve` can carry one, since C strings end there.
    InteriorNul,
    /// The program is not on `PATH`, or is there but not executable.
    NotOnPath(OsString),
    /// The child has already been waited for, so there is no process to act on.
    Reaped,
    /// The tty has no foreground process group -- nothing is claiming the terminal.
    NoForeground,
    /// A write could not be handed to the kernel before its deadline.
    WriteTimeout,
    /// A syscall failed, with the errno it failed with kept intact.
    Os(Errno),
}

impl Error {
    /// The errno this is, if it is one. The replacement for `session::is_errno`.
    pub fn errno(&self) -> Option<Errno> {
        match self {
            Self::Os(errno) => Some(*errno),
            _ => None,
        }
    }

    /// Whether this is a particular errno.
    pub fn is(&self, errno: Errno) -> bool {
        self.errno() == Some(errno)
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EmptyArgv => f.write_str("no program to run"),
            Self::InteriorNul => f.write_str("interior NUL byte"),
            Self::NotOnPath(program) => {
                write!(f, "{} not found on PATH", program.to_string_lossy())
            }
            Self::Reaped => f.write_str("child already reaped"),
            Self::NoForeground => f.write_str("no foreground process group"),
            Self::WriteTimeout => f.write_str("write timed out"),
            Self::Os(errno) => write!(f, "{errno}"),
        }
    }
}

impl std::error::Error for Error {}

impl From<Errno> for Error {
    fn from(errno: Errno) -> Self {
        Self::Os(errno)
    }
}

impl From<std::ffi::NulError> for Error {
    fn from(_: std::ffi::NulError) -> Self {
        Self::InteriorNul
    }
}

/// So that `?` still widens into an `io::Result` for any caller that wants one.
///
/// The errno survives the trip -- that is the whole point of the variant keeping it --
/// and the domain variants land on the `ErrorKind` a reader would guess.
impl From<Error> for std::io::Error {
    fn from(e: Error) -> Self {
        match e {
            Error::Os(errno) => Self::from_raw_os_error(errno as i32),
            Error::NotOnPath(_) => Self::new(std::io::ErrorKind::NotFound, e.to_string()),
            Error::WriteTimeout => Self::new(std::io::ErrorKind::TimedOut, e.to_string()),
            other => Self::other(other.to_string()),
        }
    }
}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        match e.raw_os_error() {
            Some(raw) => Self::Os(Errno::from_raw(raw)),
            None => Self::Os(Errno::EIO),
        }
    }
}
