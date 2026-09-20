//! The buffer an OSC or an APC is collected into; see [`Payload`].
//!
//! A module of its own so that the promise it makes is the compiler's to keep: the bytes
//! are private here, and the state machine next door has only [`Payload::finish`] to read
//! them by.

/// The payload of a string being collected, which may grow only so far.
///
/// What it guards is the reading. A payload that outgrew its limit is dropped rather than
/// truncated -- half a URI is a different URI, and half a kitty image is not a smaller
/// image but a parse error with a plausible-looking prefix -- and the way that is held to
/// is that [`Payload::finish`] is the only way to the bytes, and gives none once anything
/// has been turned away. Once a payload has overflowed it stops holding bytes at all: the
/// state is [`Buffer::Overflowed`], not a flag next to a buffer someone forgets to check.
///
/// The allocation outlives the string, which is why this is a field of the parser and not
/// of the state that is collecting into it: [`Payload::begin`] hands the same `Vec` back
/// to whichever variant starts the next string, overflowed or not.
#[derive(Default)]
pub(super) struct Payload {
    buffer: Buffer,
    limit: usize,
}

/// Either still collecting, or poisoned and empty.
enum Buffer {
    Collecting(Vec<u8>),
    /// Turned away for growing past the limit. Holds the emptied `Vec` so its allocation
    /// can be reused by the next [`Payload::begin`] rather than freed and reallocated.
    Overflowed(Vec<u8>),
}

impl Default for Buffer {
    fn default() -> Self {
        Buffer::Collecting(Vec::new())
    }
}

impl Payload {
    /// Start a string of at most LIMIT bytes, forgetting whatever the last one left.
    pub(super) fn begin(&mut self, limit: usize) {
        let (Buffer::Collecting(mut bytes) | Buffer::Overflowed(mut bytes)) =
            std::mem::take(&mut self.buffer);
        bytes.clear();
        self.limit = limit;
        self.buffer = Buffer::Collecting(bytes);
    }

    /// Bytes collected so far, or the limit once overflowed: see [`Payload::finish`].
    pub(super) fn len(&self) -> usize {
        match &self.buffer {
            Buffer::Collecting(bytes) => bytes.len(),
            Buffer::Overflowed(_) => self.limit,
        }
    }

    /// Collect BYTES, or as many of them as there is room for.
    #[inline]
    pub(super) fn extend(&mut self, bytes: &[u8]) {
        let Buffer::Collecting(buf) = &mut self.buffer else {
            return;
        };
        let room = self.limit.saturating_sub(buf.len());
        if bytes.len() > room {
            buf.extend_from_slice(&bytes[..room]);
            let mut emptied = std::mem::take(buf);
            emptied.clear();
            self.buffer = Buffer::Overflowed(emptied);
        } else {
            buf.extend_from_slice(bytes);
        }
    }

    /// The whole payload, or `None` if it was ever more than there was room for.
    pub(super) fn finish(&self) -> Option<&[u8]> {
        match &self.buffer {
            Buffer::Collecting(bytes) => Some(bytes),
            Buffer::Overflowed(_) => None,
        }
    }
}
