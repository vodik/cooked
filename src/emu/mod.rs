//! Terminal emulation: grid, styling, and the VT parser front end.

/// A fast, allocation-free hash of raw bytes, good enough for a hash-map key that
/// content-addressing then always double-checks with a real equality comparison.
///
/// Eight bytes at a time, in the shape rustc's own `FxHash` uses: rotate, xor in the
/// next word, multiply. A byte-at-a-time hash such as FNV-1a would be eight times the
/// work, on the reader thread, inside the mutex Emacs takes to redisplay. The quality bar
/// is only "distributes well enough to keep buckets short", and the next paragraph is
/// why it may be that low.
///
/// A hostile child fully controls hyperlink URIs, and a hash that was a store's sole test
/// of identity could be searched offline for a collision -- even a keyed one like
/// `DefaultHasher`, whose keys are fixed -- so that one URI's destination is silently
/// swapped under another. [`link::LinkStore`] therefore compares the actual content on
/// every hash hit. Once a hit is verified rather than trusted, the hash only has to
/// distribute well, not resist a deliberate search, so it can be a plain fast hash.
/// [`content_hash`] explains why images are the different case.
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
pub(crate) fn mix(hash: u64, word: u64) -> u64 {
    const SEED: u64 = 0x517c_c1b7_2722_0a95;
    (hash.rotate_left(5) ^ word).wrapping_mul(SEED)
}

/// A 128-bit digest of raw bytes, wide enough to *be* the identity rather than to narrow
/// the search for it.
///
/// [`image::ImageStore`] keeps one of these per image instead of the payload, sixteen
/// bytes rather than megabytes, so the digest alone answers "same picture?".
///
/// **Why 128 bits is enough here.** The store tracks at most
/// [`image::MAX_TRACKED_IMAGES`] (4096) images, so an accidental collision between two
/// genuinely different frames is a birthday problem over 2^12 items in a 2^128 space:
/// about 2^-105. Every other way this system can hand back the wrong picture -- a bit
/// flip in the frame buffer, a torn read, the machine losing power mid-decode -- is
/// astronomically more likely.
///
/// **Why a fast hash rather than a cryptographic one.** [`fast_hash`]'s doc comment
/// explains that a *deliberately* searched collision matters for [`link::LinkStore`],
/// where a URI a child controls could be aliased onto one it does not; that store still
/// compares the actual URIs, which are short enough for it to cost nothing. Images are
/// the other case: both sides of an image collision are payloads the same child
/// transmitted, so the most an aliasing attack buys is displaying a picture it could
/// have transmitted directly. There is nothing on the other side of the hole to steal,
/// which is why widening the hash is the whole of the answer here.
///
/// Two lanes over the same words, each [`fast_hash`]-shaped but with its own multiplier
/// and rotation, then a strong finalizer on each. The lanes are what make the width
/// real: a pair of inputs that cancel out in one multiply-xor-rotate chain has no reason
/// to cancel in a chain with a different odd multiplier and a different rotate distance,
/// so this is 128 bits of digest rather than 64 bits repeated. The finalizer is murmur3's
/// `fmix64`, and it is not decoration -- this chain's low bits carry very little of the
/// input on their own, and the low 64 bits are exactly what the ledger buckets by.
///
/// One pass, eight bytes at a time, which keeps it memory-bound: a three-megabyte frame
/// costs about what the single-lane [`fast_hash`] does, on the reader thread inside the
/// mutex Emacs takes to redisplay.
pub(crate) fn content_hash(bytes: &[u8]) -> u128 {
    const SEED_B: u64 = 0x9e37_79b9_7f4a_7c15;
    let mix_b = |hash: u64, word: u64| (hash.rotate_left(27) ^ word).wrapping_mul(SEED_B);
    let (mut a, mut b) = (0u64, SEED_B);
    let mut chunks = bytes.chunks_exact(8);
    for chunk in &mut chunks {
        let word = u64::from_le_bytes(chunk.try_into().unwrap());
        a = mix(a, word);
        b = mix_b(b, word);
    }
    let tail = chunks.remainder();
    if !tail.is_empty() {
        let mut word = [0u8; 8];
        word[..tail.len()].copy_from_slice(tail);
        let word = u64::from_le_bytes(word);
        a = mix(a, word);
        b = mix_b(b, word);
    }
    // The length, for the reason [`fast_hash`] folds it in: the tail is zero-padded, so
    // without it every pair of payloads differing only in trailing zeros -- which raw
    // RGBA pixels are made of -- would collide outright.
    let len = bytes.len() as u64;
    (u128::from(fmix64(mix(a, len))) << 64) | u128::from(fmix64(mix_b(b, len)))
}

/// Murmur3's 64-bit finalizer: shift, multiply, shift, multiply, shift.
///
/// A bijection that avalanches, so every output bit depends on every input bit. It is
/// what lets [`content_hash`]'s lanes -- which mix upward and leave the low bits thin --
/// be bucketed by their low half.
fn fmix64(mut hash: u64) -> u64 {
    hash ^= hash >> 33;
    hash = hash.wrapping_mul(0xff51_afd7_ed55_8ccd);
    hash ^= hash >> 33;
    hash = hash.wrapping_mul(0xc4ce_b9fe_1a85_ec53);
    hash ^ (hash >> 33)
}

pub(crate) mod bytes;
pub(crate) mod cell;
pub(crate) mod glyph;
pub(crate) mod grid;
pub(crate) mod image;
pub(crate) mod intern;
pub(crate) mod kitty;
pub(crate) mod link;
pub(crate) mod parser;
pub(crate) mod png;
pub(crate) mod screen;
pub(crate) mod sgr;
pub(crate) mod sixel;
pub(crate) mod stream;
pub(crate) mod style;
pub(crate) mod term;
pub(crate) mod terminfo;
pub(crate) mod text;
pub(crate) mod units;
pub(crate) mod utf8;

pub(crate) use cell::{Color, MarkId, Style};
pub(crate) use image::{CellMetrics, ImageData, ImageFormat, PixelSize, ShownFormats};
pub(crate) use term::{
    Anchor, Assumed, ColorScheme, CursorShape, Drain, Event, FrameSize, Key, KeyEncoding, Mark,
    Modifiers, MouseButton, MouseKind, MouseReport, NamedKey, Palette, PasteOutcome, Rgb, StackOp,
    Terminator, osc_reply, strip_paste_controls,
};

// What the integration tests are allowed to see, and no more. `tests/throughput.rs` needs
// `Term` and the high-water mark; `tests/delta_replay.rs` needs the rest, because its
// whole subject is what a drain reports — it accumulates `Delta::rows` into a shadow grid
// and compares `Run`s, styles and pictures included, against the grid's own full reading
// of itself. `Deco` and `ImageId` are there so it can rename a picture by its bytes: two
// terminals fed the same script can name one picture by different ids, as they can a
// rendition.
//
// Widened here rather than by making the modules public: an integration test is an
// external crate and cannot reach `pub(crate)`, so a self-oracle over the drain protocol
// either lives in `src/` beside the code it is meant to be independent of, or the
// protocol's own types become nameable from outside. The second is the smaller
// concession — these are already the wire format the Lisp side is written against, so
// nothing here is more exposed than `cooked--apply' already assumes.
pub use cell::{Deco, Run, RunRef, Runs, Wrap};
pub use image::ImageId;
/// Exported for the same reason [`ImageId`] is: `delta_replay` renumbers the ids a
/// drain names, since a terminal recycles them and two fed the same bytes need not agree.
pub use link::LinkId;
pub use screen::{Direction, Shift};
pub use style::{FontBits, StyleId};
pub use term::{
    BACKLOG_HIGH_WATER, DamagedRow, Delta, Edit, Feed, Levels, Progress, Reply, ReplyKind,
    Scrolled, Term,
};
// The units every offset and width in the drain protocol is measured in; see `units`.
pub use units::{Bytes, Chars, Cols};
