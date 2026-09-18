//! Draining a buffer no window shows; see `Term::drain_hidden`.

use super::*;

#[test]
fn a_hidden_drain_carries_the_events_and_the_scrollback_but_not_the_screen() {
    let mut t = term(3, 10, b"one\r\ntwo\r\nthree");
    t.drain();
    t.feed(b"\r\nfour\r\nfive\x1b]2;building\x07\x07");
    let delta = t.drain_hidden();
    assert!(delta.withheld);
    assert_eq!(delta.rows.len(), 0);
    assert_eq!(delta.shifts, Vec::new());
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

/// The screen a hidden drain left out is what the next whole drain sends: the move the
/// scroll made, and the rows it damaged, exactly as if nothing had drained in between.
#[test]
fn the_screen_left_out_arrives_with_the_next_whole_drain() {
    let script: [&[u8]; 3] = [b"a\r\nb\r\nc", b"\r\nd", b"\r\ne\x1b[1;1Hx"];
    let mut hidden = term(4, 10, b"");
    let mut shown = term(4, 10, b"");
    hidden.drain();
    shown.drain();
    for bytes in script {
        hidden.feed(bytes);
        shown.feed(bytes);
        assert!(hidden.drain_hidden().withheld);
    }
    let (a, b) = (hidden.drain(), shown.drain());
    let rows = |delta: &Delta| -> Vec<(usize, String)> {
        delta
            .rows
            .iter()
            .map(|row| {
                (
                    row.index,
                    row.runs.iter().map(|r| r.text).collect(),
                )
            })
            .collect()
    };
    assert_eq!(a.shifts, b.shifts);
    assert_eq!(rows(&a), rows(&b));
    assert!(!a.withheld);
}

/// A mark becomes a marker on a row, so a drain carrying one sends the row.
#[test]
fn a_mark_makes_a_hidden_drain_whole() {
    let mut t = term(3, 10, b"");
    t.drain();
    t.feed(b"\x1b]133;A\x07$ ");
    let delta = t.drain_hidden();
    assert!(!delta.withheld);
    assert_eq!(delta.rows.iter().map(|r| r.index).collect::<Vec<_>>(), [0]);
}

/// A mark whose row scrolls away while hidden is relocated in the batch that carries the
/// row, since no later drain carries it. A mark still on the grid is not, because the row
/// it would be resolved against is not in the buffer yet; the next whole drain reports it.
#[test]
fn a_hidden_drain_relocates_only_the_marks_that_scrolled_away() {
    let mut t = term(3, 10, b"\x1b]133;A\x07$ one\r\n\x1b]133;A\x07$ two");
    t.drain();
    t.feed(b"\r\n\r\n");
    let delta = t.drain_hidden();
    assert!(delta.withheld);
    assert_eq!(
        delta.marks,
        vec![(MarkId::from_index(0), Anchor { row: 0, col: 0 })]
    );
    let whole = t.drain();
    assert_eq!(
        whole.marks,
        vec![(MarkId::from_index(1), Anchor { row: 1, col: 0 })]
    );
}

/// Two scroll regions taking turns while nobody drains the moves would grow the log by
/// one entry a scroll. Past the screen's height it is cheaper to rewrite every row, so
/// the log is emptied and every row damaged.
#[test]
fn the_move_log_a_hidden_buffer_accumulates_stays_shorter_than_the_screen() {
    let mut t = term(4, 10, b"");
    t.drain();
    for _ in 0..50 {
        t.feed(b"\x1b[1;2r\x1b[2;1H\n\x1b[3;4r\x1b[4;1H\n");
        assert!(t.drain_hidden().withheld);
    }
    t.feed(b"\x1b[r");
    let delta = t.drain();
    assert!(delta.shifts.len() <= 4, "{} moves", delta.shifts.len());
}

/// A hidden buffer is woken for an event, which a child may be waiting on, and for a
/// backlog half way to the limit that would stop the reader, and for nothing else.
#[test]
fn a_hidden_buffer_is_woken_only_for_events_and_a_filling_backlog() {
    let mut t = term(3, 10, b"");
    t.drain();
    assert!(!t.feed_hidden(b"text\r\n\x1b[2;5Hmore", 10));
    assert!(t.feed_hidden(b"\x1b]2;title\x07", 10));
    t.drain_hidden();
    // The cursor is on the middle row, so four line feeds scroll three rows away and the
    // fourth and fifth reach half of ten.
    assert!(!t.feed_hidden(b"\r\n\r\n\r\n\r\n", 10));
    assert!(t.feed_hidden(b"\r\n\r\n", 10));
}
