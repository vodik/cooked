//! Draining for a consumer with no copy of the screen; see `Drain::Scrolled`.

use super::*;

/// The scrollback, the events and the resources, and not one [`DamagedRow`]: the consumer
/// reads what is still on the grid whole, so every row the core would diff against the
/// front would be built and then dropped.
#[test]
fn a_scrolled_drain_carries_the_scrollback_and_the_events_but_builds_no_row() {
    let mut t = term(3, 10, b"one\r\ntwo\r\nthree");
    t.drain();
    t.feed(b"\r\nfour\r\nfive\x1b]2;building\x07\x07");
    let delta = t.drain_scrolled();
    assert!(delta.rows.is_empty());
    assert_eq!(delta.shifts, Vec::new());
    assert!(
        !delta.withheld,
        "the consumer holds no screen, so it is owed none"
    );
    let scrolled: Vec<String> = delta.scrolled.iter().map(runs_text).collect();
    assert_eq!(scrolled, ["one", "two"]);
    assert_eq!(
        delta.events,
        vec![
            Event::Osc(2, vec!["building".into()], Terminator::Bel),
            Event::Bell
        ]
    );
}

/// A build repainting a progress bar in place damages a row on every drain and retires
/// nothing, and no drain of it ever builds a row.
#[test]
fn a_child_rewriting_one_row_costs_a_scrolled_drain_no_rows_at_all() {
    let mut t = term(3, 10, b"");
    t.drain();
    for i in 0..50 {
        t.feed(format!("\r[{i:>3}%]").as_bytes());
        let delta = t.drain_scrolled();
        assert!(delta.rows.is_empty(), "drain {i} built a row");
        assert!(delta.scrolled.is_empty());
    }
}

/// The damage waits in the core exactly as a hidden drain leaves it, so the type allows
/// what `cooked-process--pump' never does: a whole drain of the same session, which
/// brings the screen up to date in one go however many scrolled drains went by.
#[test]
fn the_screen_a_scrolled_drain_left_out_arrives_with_the_next_whole_drain() {
    let script: [&[u8]; 3] = [b"a\r\nb\r\nc", b"\r\nd", b"\r\ne\x1b[1;1Hx"];
    let mut skipped = term(4, 10, b"");
    let mut shown = term(4, 10, b"");
    skipped.drain();
    shown.drain();
    for bytes in script {
        skipped.feed(bytes);
        shown.feed(bytes);
        assert!(skipped.drain_scrolled().rows.is_empty());
    }
    let (a, b) = (skipped.drain(), shown.drain());
    let rows = |delta: &Delta| -> Vec<(usize, String)> {
        delta
            .rows
            .iter()
            .map(|row| (row.index, row.runs.iter().map(|r| r.text).collect()))
            .collect()
    };
    assert_eq!(a.shifts, b.shifts);
    assert_eq!(rows(&a), rows(&b));
}

/// The one deliberate difference from a hidden drain. A mark makes a hidden drain whole
/// because Lisp turns it into a marker on a row the buffer has to be holding; a consumer
/// here declines the events and holds no such row, so the screen is left out anyway.
#[test]
fn a_mark_does_not_make_a_scrolled_drain_whole() {
    let mut t = term(3, 10, b"");
    t.drain();
    t.feed(b"\x1b]133;A\x07$ ");
    let delta = t.drain_scrolled();
    assert!(delta.rows.is_empty());
    assert!(!delta.withheld);
    assert!(matches!(delta.events[..], [Event::Mark(..)]));
}
