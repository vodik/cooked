//! Terminal emulation: grid, styling, and the VT parser front end.

/// A fast, allocation-free hash of raw bytes, good enough for a hash-map key that
/// content-addressing then always double-checks with a real equality comparison.
///
/// Eight bytes at a time, in the shape rustc's own `FxHash` uses: rotate, xor in the
/// next word, multiply. It was FNV-1a, which is the same idea one byte at a time and so
/// eight times the work — 3ms on a three-megabyte image, on the reader thread, inside
/// the mutex Emacs takes to redisplay, to answer a question the byte-for-byte comparison
/// in `ImageStore::intern` then settles properly for 78us. The quality bar this has to
/// clear is only "distributes well enough to keep buckets short", and the paragraph
/// below is why it is allowed to be that low.
///
/// [`image::ImageStore`] and [`link::LinkStore`] both used `std::hash::DefaultHasher`
/// (SipHash-1-3) here, as their sole test of identity — no comparison of the actual
/// bytes on a hash hit. `DefaultHasher` is *not* randomized per process the way
/// `RandomState` is (its keys are fixed), so a hostile child process, which fully
/// controls both hyperlink URIs and image payloads, could in principle search offline
/// for two different byte strings that collide under it and have the second silently
/// aliased to the first — a wrong image displayed, or worse, a hyperlink's destination
/// swapped under a URI that looks unrelated. Both call sites now compare the actual
/// content on every hash hit, which is what actually closes that hole; once a hit is
/// verified rather than trusted, the hash itself only has to distribute well, not resist
/// a deliberate search for a collision — so it can be, and now is, a plain fast hash
/// rather than a cryptographic one.
pub(crate) fn fast_hash(bytes: &[u8]) -> u64 {
    let mut chunks = bytes.chunks_exact(8);
    let mut hash = 0u64;
    for chunk in &mut chunks {
        hash = mix(hash, u64::from_le_bytes(chunk.try_into().unwrap()));
    }
    let tail = chunks.remainder();
    if !tail.is_empty() {
        let mut word = [0u8; 8];
        word[..tail.len()].copy_from_slice(tail);
        hash = mix(hash, u64::from_le_bytes(word));
    }
    // The length, because the tail is zero-padded: without this, `b"a"` and `b"a\0"`
    // hash alike, and so does every pair differing only in trailing zeros — which raw
    // RGBA pixels are made of.
    mix(hash, bytes.len() as u64)
}

/// One round of [`fast_hash`]: the rotate is what keeps the multiply from discarding the
/// high bits of everything hashed so far, since it alone only ever carries them upward.
fn mix(hash: u64, word: u64) -> u64 {
    const SEED: u64 = 0x517c_c1b7_2722_0a95;
    (hash.rotate_left(5) ^ word).wrapping_mul(SEED)
}

pub(crate) mod cell;
pub(crate) mod glyph;
pub(crate) mod image;
pub(crate) mod intern;
pub(crate) mod kitty;
pub(crate) mod link;
pub(crate) mod parser;
pub(crate) mod screen;
pub(crate) mod sixel;
pub(crate) mod term;

pub(crate) use cell::{Color, Deco, MarkId, Run, Style};
pub(crate) use image::{CellMetrics, ImageData, ImageFormat, ImageId};
pub(crate) use link::LinkId;
pub(crate) use term::{Anchor, ColorScheme, CursorShape, Delta, Event, KeyEncoding, osc_reply};

// The benchmark's whole surface; see `tests/throughput.rs`.
pub use term::{BACKLOG_HIGH_WATER, Term};
