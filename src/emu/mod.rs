//! Terminal emulation: grid, styling, and the VT parser front end.

/// FNV-1a over raw bytes: fast, allocation-free, and good enough for a hash-map key that
/// content-addressing then always double-checks with a real equality comparison.
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
    const OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
    const PRIME: u64 = 0x0000_0100_0000_01B3;
    let mut hash = OFFSET;
    for &b in bytes {
        hash ^= u64::from(b);
        hash = hash.wrapping_mul(PRIME);
    }
    hash
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
pub(crate) use term::{Anchor, CursorShape, Delta, Event, KeyEncoding, osc_reply};

// The benchmark's whole surface; see `tests/throughput.rs`.
pub use term::{BACKLOG_HIGH_WATER, Term};
