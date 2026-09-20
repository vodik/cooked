//! The true bound on `StyleStore`/`LinkStore`'s growth, measured rather than assumed.
//!
//! `StyleStore::collect` and `LinkStore::collect` grow their `limit` when a collection
//! frees too little, and the only thing that stops that ratchet is the marks running out
//! of anything more to find live: the cells of both grids, the front buffer's copy of
//! what is shown, and the runs of whatever scrollback is still undrained. See
//! `STYLE_TABLE_CAPACITY`'s doc in `style.rs` for the production-scale arithmetic this
//! pins, and the doc above `grown_limit` in `link.rs` for the link id's narrower field.
//!
//! The production numbers (a 200x400 grid, 8,000 undrained rows) are worked out by hand
//! in those two docs rather than driven here: a flood that size is minutes of parsing in
//! a debug build for no more signal than a smaller one already gives. What these tests
//! pin is the shape of the bound, `C * (3 * R + N)`, at a size that stays fast.

use std::fmt::Write as _;

use super::*;
use crate::emu::cell::{LINK_MAX, STYLE_MAX};

/// ROWS x COLS of truecolour SGR, one distinct rendition per character, starting the
/// counter at FROM. No two cells this produces share a rendition -- the worst case a
/// collection is measured against -- and calling it again with FROM past what the first
/// call used keeps that true across the two.
fn truecolour_grid(rows: usize, cols: usize, from: u32) -> (String, u32) {
    let mut bytes = String::new();
    let mut n = from;
    for _ in 0..rows {
        for _ in 0..cols {
            let (r, g, b) = (n as u8, (n >> 8) as u8, (n >> 16) as u8);
            n += 1;
            write!(bytes, "\x1b[38;2;{r};{g};{b}mx").unwrap();
        }
    }
    (bytes, n)
}

/// A rendition-per-cell flood, followed by more undrained scrollback in the same worst
/// case, keeps the live rendition count within `C * (3 * R + N)` and within the 22-bit
/// field it is packed into.
#[test]
fn a_truecolour_flood_keeps_the_table_within_its_bound() {
    const ROWS: usize = 60;
    const COLS: usize = 100;
    const SCROLLED_ROWS: usize = 200;

    let mut t = Term::new(ROWS, COLS);
    let (grid, next) = truecolour_grid(ROWS, COLS, 0);
    t.feed(grid.as_bytes());
    // Settle the front buffer: it now names the same ids the grid does, so this does not
    // by itself grow the live set, but it is what makes the front buffer's own mark in
    // `State::collect_styles` exercised rather than vacuous.
    t.drain();

    // SCROLLED_ROWS more distinctly-coloured rows, scrolled off the top and left
    // undrained -- what stresses `pending_scrollback`, the mark this ticket is about.
    let mut extra = String::new();
    let mut n = next;
    for _ in 0..SCROLLED_ROWS {
        extra.push_str("\r\n");
        for _ in 0..COLS {
            let (r, g, b) = (n as u8, (n >> 8) as u8, (n >> 16) as u8);
            n += 1;
            write!(extra, "\x1b[38;2;{r};{g};{b}mx").unwrap();
        }
    }
    t.feed(extra.as_bytes());

    let bound = COLS * (3 * ROWS + SCROLLED_ROWS);
    assert!(
        t.styles_held() <= bound,
        "{} live renditions past the {bound} the marks bound",
        t.styles_held()
    );
    assert!(
        t.styles_held() <= STYLE_MAX as usize,
        "{} live renditions past what a cell's 22-bit rendition field can hold",
        t.styles_held()
    );
}

/// The same flood, in hyperlinks rather than renditions, and against `LINK_MAX` (21
/// bits) instead.
#[test]
fn a_hyperlink_flood_keeps_the_table_within_its_bound() {
    const ROWS: usize = 30;
    const COLS: usize = 60;
    const SCROLLED_ROWS: usize = 80;

    let mut t = Term::new(ROWS, COLS);
    let mut bytes = String::new();
    let mut n: u32 = 0;
    for _ in 0..ROWS {
        for _ in 0..COLS {
            write!(bytes, "\x1b]8;;https://example.com/{n}\x1b\\x").unwrap();
            n += 1;
        }
    }
    t.feed(bytes.as_bytes());
    t.drain();

    let mut extra = String::new();
    for _ in 0..SCROLLED_ROWS {
        extra.push_str("\r\n");
        for _ in 0..COLS {
            write!(extra, "\x1b]8;;https://example.com/{n}\x1b\\x").unwrap();
            n += 1;
        }
    }
    t.feed(extra.as_bytes());

    let bound = COLS * (3 * ROWS + SCROLLED_ROWS);
    assert!(
        t.links_held() <= bound,
        "{} live links past the {bound} the marks bound",
        t.links_held()
    );
    assert!(
        t.links_held() <= LINK_MAX as usize,
        "{} live links past what a cell's 21-bit link field can hold",
        t.links_held()
    );
}
