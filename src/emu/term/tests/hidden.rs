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
            .map(|row| (row.index, row.runs.iter().map(|r| r.text).collect()))
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
    assert_eq!(delta.marks, vec![(MarkId::from_index(0), anchor(0, 0))]);
    let whole = t.drain();
    assert_eq!(whole.marks, vec![(MarkId::from_index(1), anchor(1, 0))]);
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

/// NOT REAL: same probe as `a_non_evicting_rewrap_leaves_prompt_start_naming_the_wrong_row`
/// (see marks.rs), question 3 -- whether a key can be wrongly forwarded or withheld
/// between a program pushing kitty flags and the next drain.
///
/// A push (`CSI > flags u`) or a pop mutates the kitty stack directly and queues no
/// [`Event`], so it neither sets [`Term::woken`]'s hidden branch (which only answers to
/// an event or a filling backlog) nor forces [`Term::drain_hidden`] to go whole (which
/// only happens for an [`Event::needs_text`]). So a session genuinely hidden -- no window
/// anywhere, `Session::hidden` true, wakes suppressed at the notifier -- can hold a kitty
/// flags change indefinitely without Emacs finding out.
///
/// That is safe rather than a bug: nothing can type a key into a buffer with no window,
/// and `cooked--sync-before-redisplay` forces a whole drain, which is what actually
/// refreshes Lisp's `cooked--kitty-flags` copy, before the window is redrawn -- see
/// `cooked-showing-a-hidden-buffer-catches-it-up-before-it-is-drawn` in
/// tests/cooked-tests-session.el. This test pins the Rust half of that story: the flags
/// really do go unreported while hidden, so the Lisp-side catch-up is load-bearing and
/// not merely defensive.
#[test]
fn a_kitty_flags_push_neither_wakes_a_hidden_session_nor_forces_a_whole_drain() {
    let mut t = term(3, 10, b"");
    t.drain();
    assert!(
        !t.feed_hidden(b"\x1b[>1u", 10),
        "a kitty flags push queues no event and should not wake a hidden session"
    );
    assert_eq!(t.kitty_flags().bits(), 1);
    assert!(
        t.drain_hidden().withheld,
        "with no event needing the screen's text, the drain should still be withheld"
    );
}
