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
/// has been turned away.
///
/// The allocation outlives the string, which is why this is a field of the parser and not
/// of the state that is collecting into it.
#[derive(Default)]
pub(super) struct Payload {
    bytes: Vec<u8>,
    limit: usize,
    overflowed: bool,
}

impl Payload {
    /// Start a string of at most LIMIT bytes, forgetting whatever the last one left.
    pub(super) fn begin(&mut self, limit: usize) {
        self.bytes.clear();
        self.limit = limit;
        self.overflowed = false;
    }

    /// Bytes collected so far.
    pub(super) fn len(&self) -> usize {
        self.bytes.len()
    }

    /// Collect BYTES, or as many of them as there is room for.
    #[inline]
    pub(super) fn extend(&mut self, bytes: &[u8]) {
        let room = self.limit.saturating_sub(self.bytes.len());
        self.overflowed |= bytes.len() > room;
        self.bytes
            .extend_from_slice(&bytes[..bytes.len().min(room)]);
    }

    /// The whole payload, or `None` if it was ever more than there was room for.
    pub(super) fn finish(&self) -> Option<&[u8]> {
        (!self.overflowed).then_some(&self.bytes)
    }
}
