//! Leaving out of a drain the rows Emacs already has; see `term::front`.

use super::*;

/// The screen row indices the next drain of T sends.
fn sent(t: &mut Term) -> Vec<usize> {
    t.drain().rows.iter().map(|r| r.index).collect()
}

/// A terminal whose every row has been drained once, so Emacs holds all of it.
fn settled(rows: usize, cols: usize, input: &[u8]) -> Term {
    let mut t = term(rows, cols, input);
    t.drain();
    t
}

#[test]
fn a_line_erased_and_written_back_is_not_sent() {
    // The htop and `watch` repaint: every cell of row 1 changes twice and none in the end.
    let mut t = settled(3, 10, b"top\r\nstatus\r\nbottom");
    t.feed(b"\x1b[2;1H\x1b[2Kstatus");
    assert_eq!(sent(&mut t), Vec::<usize>::new());
}

#[test]
fn a_line_written_back_differently_is_sent() {
    let mut t = settled(3, 10, b"top\r\nstatus\r\nbottom");
    t.feed(b"\x1b[2;1H\x1b[2Kstatvs");
    assert_eq!(sent(&mut t), vec![1]);
}

#[test]
fn the_same_text_in_a_new_colour_is_sent() {
    let mut t = settled(2, 10, b"status");
    t.feed(b"\x1b[1;1H\x1b[2K\x1b[31mstatus");
    assert_eq!(sent(&mut t), vec![0]);
}

#[test]
fn a_whole_screen_cleared_and_redrawn_sends_only_what_changed() {
    let mut t = settled(3, 10, b"one\r\ntwo\r\nthree");
    t.feed(b"\x1b[H\x1b[2Jone\r\n2\r\nthree");
    assert_eq!(sent(&mut t), vec![1]);
}

#[test]
fn a_row_emacs_edited_is_sent_even_when_its_cells_match() {
    // The width guard trimmed row 0 after rendering it, so the buffer no longer holds
    // what the core sent.
    let mut t = settled(2, 10, b"status");
    t.forget_sent(Some(0));
    t.feed(b"\x1b[1;1H\x1b[2Kstatus");
    assert_eq!(sent(&mut t), vec![0]);
}

#[test]
fn forgetting_every_row_sends_a_repaint_of_the_same_cells() {
    // A theme change: the faces in the buffer were resolved against the old theme.
    let mut t = settled(2, 10, b"one\r\ntwo");
    t.forget_sent(None);
    t.feed(b"\x1b[H\x1b[2Kone\r\n\x1b[2Ktwo");
    assert_eq!(sent(&mut t), vec![0, 1]);
}

#[test]
fn a_redraw_sends_every_row() {
    let mut t = settled(2, 10, b"one\r\ntwo");
    t.touch_all();
    assert_eq!(sent(&mut t), vec![0, 1]);
}

#[test]
fn a_row_moved_by_a_scroll_is_matched_where_it_went() {
    // After the scroll the buffer holds `two` on row 0; writing it back there is nothing.
    let mut t = settled(2, 10, b"one\r\ntwo");
    t.feed(b"\x1b[2;1H\n\x1b[1;1H\x1b[2Ktwo");
    let delta = t.drain();
    assert_eq!(delta.shifts.len(), 1);
    assert!(delta.rows.is_empty(), "{:?}", delta.rows);
}

#[test]
fn a_cursor_moving_within_a_row_of_box_glyphs_sends_the_row() {
    // Lisp splits a glyph run at the cursor's cell, so the row renders differently.
    let mut t = settled(2, 10, "\u{2502}   \u{2502}".as_bytes());
    t.feed("\x1b[1;1H\x1b[2K\u{2502}   \u{2502}\x1b[1;3H".as_bytes());
    assert_eq!(sent(&mut t), vec![0]);
}

#[test]
fn a_cursor_moving_within_a_plain_row_sends_nothing() {
    let mut t = settled(2, 10, b"hello");
    t.feed(b"\x1b[1;1H\x1b[2Khello\x1b[1;3H");
    assert_eq!(sent(&mut t), Vec::<usize>::new());
}

#[test]
fn a_row_below_the_occupied_rows_is_always_sent() {
    // Emacs trims its screen region to the occupied rows, so what it held for row 2 of a
    // one-line screen is gone and cannot be matched.
    let mut t = settled(3, 10, b"one\x1b[3;1H\x1b[44m\x1b[K\x1b[0m\x1b[1;1H");
    t.feed(b"\x1b[3;1H\x1b[2K\x1b[44m\x1b[2K\x1b[0m\x1b[1;1H");
    assert_eq!(sent(&mut t), vec![2]);
}

#[test]
fn removed_rows_are_sent_from_the_cut_down() {
    let mut t = settled(3, 10, b"one\r\ntwo\r\nthree");
    t.remove_rows(0, 1);
    assert_eq!(sent(&mut t), vec![0, 1, 2]);
}

#[test]
fn the_alternate_screen_is_sent_whole_both_ways() {
    let mut t = settled(2, 10, b"one\r\ntwo");
    t.feed(b"\x1b[?1049h");
    assert_eq!(sent(&mut t), vec![0, 1]);
    t.feed(b"\x1b[?1049l");
    assert_eq!(sent(&mut t), vec![0, 1]);
}

#[test]
fn a_mark_alone_changes_nothing_emacs_draws() {
    let mut t = settled(2, 10, b"$ ");
    t.feed(b"\x1b]133;A\x07\x1b[1;1H\x1b[2K$ ");
    assert_eq!(sent(&mut t), Vec::<usize>::new());
}
