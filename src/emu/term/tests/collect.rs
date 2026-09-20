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

/// The sequence `State::collect_links`' `pending_scrollback` mark exists for.
///
/// `pending_links` only covers a link between the drain that opens it and the drain
/// that announces it, and `front` only covers a row from the drain that first shows it
/// onward -- neither covers a row that is *never* part of any drain before it scrolls
/// off. That is reachable: open the link with nothing printed under it yet, drain (which
/// announces the link -- it needed nothing written to become non-fresh -- while the
/// still-blank row makes no difference for `front` to pick up), then print under the
/// still-open pen link and scroll the row off before draining again. The row reaches
/// `pending_scrollback` having never been part of any drain that could have put it in
/// `front`, and its link left `pending_links` on the drain before it existed.
///
/// A link limit of one makes the second destination collect before it is interned. If
/// `pending_scrollback` were not marked, the collection would find nothing live, free
/// the first id, and -- being the only entry on a limit-of-one free list -- hand it
/// straight back out to the second destination.
#[test]
fn a_link_only_ever_seen_in_scrollback_survives_a_collection_pressed_by_a_new_one() {
    let mut t = Term::with_id_limits(2, 20, 4096, 1);

    // The link is opened, and nothing is printed under it before this drain: the row is
    // still blank, so `front` picks up nothing new, but the link is no longer fresh --
    // `pending_links` will not mark it again after this.
    t.feed(b"\x1b]8;;https://first.example/\x1b\\");
    let first = t.drain();
    let first_id = first
        .links
        .iter()
        .find(|(_, uri)| uri == "https://first.example/")
        .map(|(id, _)| *id)
        .expect("announced on this drain, even though nothing is printed under it yet");

    // Now "here" is printed under the pen's still-open link (it carries across the
    // drain, the way it carries across a newline) and the row scrolls off -- two rows
    // down on a two-row grid -- before anything is drained again. `front` never saw this
    // row; `pending_links` forgot the link a drain ago.
    t.feed(b"here\x1b]8;;\x1b\\\r\n\r\n");

    // The second destination presses a collection before it is interned.
    t.feed(b"\x1b]8;;https://second.example/\x1b\\there\x1b]8;;\x1b\\");

    let second = t.drain();
    let second_id = second
        .links
        .iter()
        .find(|(_, uri)| uri == "https://second.example/")
        .map(|(id, _)| *id)
        .expect("the second destination is announced once interned");
    assert_ne!(
        first_id, second_id,
        "the row in pending_scrollback still names first_id, so the collection the \
         second destination pressed must not have freed it"
    );

    let scrolled_link = second
        .scrolled
        .first()
        .and_then(|row| row.runs.iter().find(|r| r.text == "here"))
        .and_then(|run| run.link)
        .expect("the archived row still carries its link");
    assert_eq!(
        scrolled_link, first_id,
        "the row that scrolled off is exactly the one that was drained linked"
    );
}
