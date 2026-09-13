//! What a scroll costs Emacs, counted rather than estimated.
//!
//! The numbers in these assertions are the whole point of expressing an ordinary scroll
//! as a scroll: a damaged row is a buffer line deleted, reinserted and re-propertized,
//! which destroys every marker and overlay anchored in it and unfontifies it. A row that
//! merely *moved* costs none of that, and after a scroll the overwhelming majority of the
//! region's rows have only moved.
//!
//! The first half is written against `Delta::rows` alone, no `Delta::shifts`, so that the
//! same file can be run against a build from before this change and say what a scroll cost
//! there: 24, 6, 24, 24 and 13 against the 1, 1, 1, 1 and 3 asserted below. Keeping that
//! property is worth the small awkwardness, because a damage figure nobody can reproduce
//! against the old code is a claim rather than a measurement.
//!
//! Its cases are the ones the report's false-positive matrix distinguishes, and two of
//! them — the scroll region and the alternate screen — are cases cooked was already
//! *ahead* of ghostel on, where their page-dirty flag degrades to a whole-viewport
//! repaint. Those two are here to be watched for regression rather than to improve.
//!
//! The second half asserts the moves themselves, which is where the coalescing rules
//! live: a flood must arrive as one move rather than a thousand, and past the height of
//! the region as none at all.

use cooked::emu::{Shift, Term};

const ROWS: usize = 24;
const COLS: usize = 80;

/// A terminal with every row written, drained so that nothing is outstanding.
fn painted() -> Term {
    let mut term = Term::new(ROWS, COLS);
    for row in 0..ROWS {
        term.feed(format!("\x1b[{};1Hrow {row}", row + 1).as_bytes());
    }
    term.drain();
    term
}

/// Damaged rows for one thing done to a freshly painted screen.
fn damage(script: &[u8]) -> usize {
    let mut term = painted();
    term.feed(script);
    term.drain().rows.len()
}

#[test]
fn an_ordinary_scroll_damages_only_the_row_it_opened() {
    // A line feed on the last row: the commonest thing a terminal is asked to do, and
    // the case the report measured at 25 rows against ghostel's 2. Rows 0..22 moved and
    // row 23 is new, so one row is damaged and nothing else.
    assert_eq!(damage(b"\x1b[24;1H\n"), 1);
}

#[test]
fn a_scroll_region_damages_only_the_row_it_opened() {
    // cooked already beat ghostel here — their page-dirty flag turns a three-row status
    // region into a whole-viewport repaint — and the floor is the same one row.
    assert_eq!(damage(b"\x1b[5;10r\x1b[10;1H\n"), 1);
}

#[test]
fn a_scroll_on_the_alt_screen_damages_only_the_row_it_opened() {
    // The other case cooked was already ahead on. Entering the alt screen damages
    // everything, so the count is taken from a second scroll after a drain has settled
    // the switch.
    let mut term = Term::new(ROWS, COLS);
    term.feed(b"\x1b[?1049h");
    for row in 0..ROWS {
        term.feed(format!("\x1b[{};1Hrow {row}", row + 1).as_bytes());
    }
    term.drain();
    term.feed(b"\x1b[24;1H\n");
    assert_eq!(term.drain().rows.len(), 1);
}

#[test]
fn a_reverse_scroll_damages_only_the_row_it_opened() {
    // `RI` at the top of the region: the same trade in the other direction, and what a
    // pager scrolling backwards does on every keystroke.
    assert_eq!(damage(b"\x1b[1;1H\x1bM"), 1);
}

#[test]
fn insert_and_delete_line_damage_only_what_they_opened() {
    // `IL`/`DL` were already at what the report calls the correct minimum — every row
    // from the cursor down — and are now at the real one: the lines the operator made.
    assert_eq!(damage(b"\x1b[12;1H\x1b[3L"), 3);
    assert_eq!(damage(b"\x1b[12;1H\x1b[3M"), 3);
}

#[test]
fn a_flood_still_damages_every_row_once() {
    // The saturating case, and the one that must *not* be narrowed: twenty-four line
    // feeds turn the region over completely, so every row genuinely holds new text and
    // every row is damaged. A scroll longer than the screen is the same answer.
    assert_eq!(damage("\x1b[24;1H".to_string().as_bytes()), 0);
    let feeds = format!("\x1b[24;1H{}", "\n".repeat(ROWS));
    assert_eq!(damage(feeds.as_bytes()), ROWS);
    let feeds = format!("\x1b[24;1H{}", "\n".repeat(ROWS * 3));
    assert_eq!(damage(feeds.as_bytes()), ROWS);
}

/// The moves one thing done to a freshly painted screen reports.
fn shifts(script: &[u8]) -> Vec<Shift> {
    let mut term = painted();
    term.feed(script);
    term.drain().shifts
}

/// One expected move. `UP` and `DOWN` name the direction rather than the bare boolean,
/// which in a list of four numbers is the one field a reader cannot check at a glance.
const UP: bool = true;
const DOWN: bool = false;

fn shift(top: usize, bottom: usize, count: usize, up: bool) -> Shift {
    Shift {
        top,
        bottom,
        count,
        up,
    }
}

#[test]
fn a_drain_reports_the_moves_it_made() {
    assert_eq!(shifts(b"\x1b[24;1H\n"), vec![shift(0, 23, 1, UP)]);
    assert_eq!(shifts(b"\x1b[5;10r\x1b[10;1H\n"), vec![shift(4, 9, 1, UP)]);
    assert_eq!(shifts(b"\x1b[1;1H\x1bM"), vec![shift(0, 23, 1, DOWN)]);
}

#[test]
fn a_flood_coalesces_into_one_move_and_then_into_none() {
    // Six line feeds are one move of six, not six moves: Emacs pays per buffer edit,
    // and a `cat' scrolls once per line.
    let feeds = format!("\x1b[24;1H{}", "\n".repeat(6));
    assert_eq!(shifts(feeds.as_bytes()), vec![shift(0, 23, 6, UP)]);
    // And past the height of the region there is nothing left to move: every row is
    // damaged, so a shift would be a whole-screen delete and insert bought for nothing.
    let feeds = format!("\x1b[24;1H{}", "\n".repeat(ROWS));
    assert!(shifts(feeds.as_bytes()).is_empty());
    let feeds = format!("\x1b[24;1H{}", "\n".repeat(ROWS * 3));
    assert!(shifts(feeds.as_bytes()).is_empty());
    // And it stays none, which is the whole reason a saturated entry stays in the log
    // until the drain. Dropping it the moment it saturates would let the next line feed
    // start a fresh one, so a flood of a hundred lines would arrive as a move of four --
    // a pair of buffer edits over rows every one of which is about to be rewritten.
    let feeds = format!("\x1b[24;1H{}", "\n".repeat(100));
    assert!(shifts(feeds.as_bytes()).is_empty());
    assert_eq!(damage(feeds.as_bytes()), ROWS);
}

#[test]
fn two_scroll_regions_in_one_drain_stay_two_moves_in_order() {
    // A TUI with a status area alternates between its region and the whole screen, and
    // the buffer has to replay both in order or the rows outside each region land in
    // the wrong place. Neither coalescing rule applies: different regions, and the
    // opposite direction.
    assert_eq!(
        shifts(b"\x1b[1;5r\x1b[5;1H\n\x1b[1;1H\x1bM"),
        vec![shift(0, 4, 1, UP), shift(0, 4, 1, DOWN)]
    );
}

#[test]
fn a_write_that_rides_a_scroll_is_reported_at_the_index_it_ended_at() {
    // The hazard the dirty-flag rotation exists for. Write row 5, scroll, and the row
    // must be reported at 4 — where its text now is — rather than at 5, where Emacs
    // would paint it over a line that did not change.
    let mut term = painted();
    term.feed(b"\x1b[6;1Hmarker\x1b[24;1H\n");
    let delta = term.drain();
    let rows: Vec<usize> = delta.rows.iter().map(|r| r.index).collect();
    assert_eq!(rows, vec![4, 23]);
}
