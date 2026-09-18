//! Whatever a child can write, through everything the reader thread and a drain do to it.
//!
//! The bytes a terminal parses are chosen by the program inside it, and the parser here
//! is followed by three hand-written decoders -- sixel, the kitty graphics protocol, a
//! PNG encoder -- a rewrap, and a drain that diffs every damaged row against a copy of
//! what Emacs holds. All of it is index arithmetic over input nobody vetted. Rust keeps
//! a mistake there from being memory corruption; it does not keep it from being a panic,
//! and a panic on the reader thread ends the session. This is the net for that.
//!
//! The input is a four-byte header and then the child's output. The header picks the
//! grid and how the output is cut up, because the two places a terminal's state is
//! carried across a boundary are the two places it goes wrong: a read that ends in the
//! middle of an escape sequence, and a drain or a resize landing between two halves of
//! a frame. `tests/delta_replay.rs` asks whether those produce the *right* grid, over
//! scripts it generates; this asks only that they produce one, over anything at all.
//!
//!   byte 0   rows, 1..=64
//!   byte 1   columns, 1..=255
//!   byte 2   bytes per feed, 1..=256, so every escape is split somewhere eventually
//!   byte 3   which of the operations below may run between feeds, as a bit mask
//!
//! Between feeds one operation runs, chosen by the last byte of the chunk just fed, so
//! that the fuzzer steers it with the same bytes it is already mutating and a seed that
//! is a plain capture of terminal output still means something.

#![no_main]

use cooked::emu::Term;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let [rows, cols, chunk, allowed, output @ ..] = data else {
        return;
    };
    let rows = usize::from(*rows % 64) + 1;
    let cols = usize::from(*cols).max(1);
    let chunk = usize::from(*chunk) + 1;
    let mut term = Term::new(rows, cols);

    for piece in output.chunks(chunk) {
        term.feed(piece);
        let pick = piece.last().copied().unwrap_or(0);
        // A cleared bit in the header turns the operation into the plain drain, so the
        // fuzzer can find a failure with the fewest moving parts that still shows it.
        match (pick % 8, allowed & (1 << (pick % 8)) != 0) {
            (1, true) => drop(term.drain_promoting()),
            (2, true) => drop(term.drain_hidden()),
            // A resize derived from the same byte: narrower and wider, shorter and
            // taller, including down to a single cell, which is where a rewrap is thin.
            (3, true) => term.resize(
                usize::from(pick >> 3) % 64 + 1,
                usize::from(pick.rotate_left(3)).max(1),
            ),
            (4, true) => term.remove_rows(usize::from(pick >> 3), usize::from(pick >> 5) + 1),
            (5, true) => drop(term.clear_to_prompt()),
            (6, true) => term.forget_sent(Some(usize::from(pick >> 3))),
            // Nothing at all: two feeds with no drain between them, which is what a
            // burst of reads inside one redisplay interval is.
            (7, true) => {}
            _ => drop(term.drain()),
        }
    }
    // The emulator reading its whole grid back out, so every row still standing is
    // turned into runs at least once whatever the script drained along the way.
    term.touch_all();
    drop(term.drain());
});
