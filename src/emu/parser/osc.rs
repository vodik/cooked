//! What the parser knows about an OSC beyond where it ends: its code; see [`OscCode`].

use core::str;

/// The number an OSC opens with, once it has been read as one.
///
/// A performer that holds one of these has already been told that the digits were digits
/// and that they fit, so it matches on the codes it acts on rather than re-deciding what
/// counts as a code. The named constants below are the ones cooked answers in Rust; every
/// other code is a number Lisp is handed and is only ever compared against these, so the
/// match compiles to the integer compare it was before the type existed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct OscCode(u16);

impl OscCode {
    /// `OSC 7`: the working directory the shell is in, as a `file://` URL.
    pub(crate) const WORKING_DIRECTORY: Self = Self(7);
    /// `OSC 8`: a hyperlink opened or closed.
    pub(crate) const HYPERLINK: Self = Self(8);
    /// `OSC 66`: kitty's text sizing protocol.
    pub(crate) const TEXT_SIZE: Self = Self(66);
    /// `OSC 133`: a shell's semantic prompt marks.
    pub(crate) const SEMANTIC_PROMPT: Self = Self(133);
    /// `OSC 1337`: iTerm2's private channel, `File=` among much else.
    pub(crate) const ITERM: Self = Self(1337);

    /// The code DIGITS spell: digits and nothing else, and no more than fit.
    pub(super) fn parse(digits: &[u8]) -> Option<Self> {
        if digits.is_empty() || !digits.iter().all(u8::is_ascii_digit) {
            return None;
        }
        // ASCII digits are UTF-8, so only an overflow can fail from here.
        Some(Self(str::from_utf8(digits).ok()?.parse().ok()?))
    }

    /// The number itself, for the one consumer that needs it as a number: an OSC cooked
    /// does not act on crosses to Lisp as `(osc CODE ...)`, and Lisp decides what it means.
    pub(crate) fn get(self) -> u16 {
        self.0
    }
}
