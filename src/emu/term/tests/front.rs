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

/// What the next drain of T sends for row INDEX: `None` when the row is not sent,
/// `Some(None)` when it is sent whole, and `Some(Some(..))` for an edit, as its offsets
/// and its replacement text.
#[allow(clippy::type_complexity)]
fn edit_of(t: &mut Term, index: usize) -> Option<Option<(usize, Option<usize>, usize, String)>> {
    let row = t.drain().rows.into_iter().find(|r| r.index == index)?;
    Some(row.edit.map(|e| {
        let text = e.runs.iter().map(|r| r.text.as_str()).collect();
        (e.char_start, e.char_end, e.chars, text)
    }))
}

#[test]
fn a_turning_spinner_is_sent_as_its_one_character() {
    let mut t = settled(2, 40, b"working | on the build");
    t.feed(b"\x1b[1;9H/\x1b[2;1H");
    assert_eq!(
        edit_of(&mut t, 0),
        Some(Some((8, Some(9), 22, "/".to_string())))
    );
}

#[test]
fn a_growing_tail_runs_to_the_end_of_the_line() {
    let mut t = settled(2, 40, b"progress [##");
    t.feed(b"#]");
    assert_eq!(
        edit_of(&mut t, 0),
        Some(Some((12, None, 14, "#]".to_string())))
    );
}

#[test]
fn a_shorter_line_deletes_to_the_end_of_the_line() {
    // The blank before the change is a trailing blank of the new text, so it goes too.
    let mut t = settled(2, 40, b"a fairly long line of text ab");
    t.feed(b"\x1b[1;28H\x1b[K");
    assert_eq!(
        edit_of(&mut t, 0),
        Some(Some((26, None, 26, String::new())))
    );
}

#[test]
fn an_edit_counts_a_wide_character_as_one_character() {
    let mut t = settled(2, 40, "\u{4e00}\u{4e8c} x and some more".as_bytes());
    t.feed(b"\x1b[1;6Hy\x1b[2;1H");
    assert_eq!(
        edit_of(&mut t, 0),
        Some(Some((3, Some(4), 18, "y".to_string())))
    );
}

#[test]
fn an_edit_counts_a_combining_mark_as_a_character_of_its_own() {
    let mut t = settled(2, 40, "cafe\u{301} x and some more".as_bytes());
    t.feed(b"\x1b[1;6Hy\x1b[2;1H");
    assert_eq!(
        edit_of(&mut t, 0),
        Some(Some((6, Some(7), 21, "y".to_string())))
    );
}

#[test]
fn a_change_inside_a_glyph_run_replaces_the_whole_run() {
    let row = "status: \u{2500}\u{2500}\u{2500}\u{2500} \u{2500}\u{2500}\u{2500}\u{2500} old";
    let mut t = settled(2, 40, row.as_bytes());
    t.feed("\x1b[1;13H\u{2500}\x1b[2;1H".as_bytes());
    assert_eq!(
        edit_of(&mut t, 0),
        Some(Some((8, Some(17), 21, "\u{2500}".repeat(9))))
    );
}

#[test]
fn a_change_after_a_glyph_run_leaves_the_run_alone() {
    let row = "status: \u{2500}\u{2500}\u{2500}\u{2500} old";
    let mut t = settled(2, 40, row.as_bytes());
    t.feed(b"\x1b[1;14Hnew\x1b[2;1H");
    assert_eq!(
        edit_of(&mut t, 0),
        Some(Some((13, None, 16, "new".to_string())))
    );
}

#[test]
fn a_cursor_leaving_a_glyph_run_redraws_the_run() {
    // Lisp split the run at the cursor's cell, so when the cursor leaves the run it is
    // drawn again as one, even though the change that damaged the row is further along.
    let row = "a label then \u{2500}\u{2500}  \u{2500}\u{2500} and the rest";
    let mut t = settled(2, 40, format!("{row}\x1b[1;16H").as_bytes());
    t.feed(b"\x1b[1;31Hx\x1b[2;1H");
    assert_eq!(
        edit_of(&mut t, 0),
        Some(Some((
            13,
            Some(31),
            32,
            "\u{2500}\u{2500}  \u{2500}\u{2500} and the rex".to_string()
        )))
    );
}

#[test]
fn a_change_to_most_of_the_row_is_sent_whole() {
    let mut t = settled(2, 10, b"abcdefghij");
    t.feed(b"\x1b[1;2HBCDEFG\x1b[2;1H");
    assert_eq!(edit_of(&mut t, 0), Some(None));
}

#[test]
fn a_row_with_an_image_is_sent_whole() {
    let mut t = with_metrics(3, 40);
    t.feed(b"caption text that is long enough\x1b[1;35H");
    let pixels = b64(&[255; 12]);
    t.feed(format!("\x1b_Ga=T,f=24,s=2,v=2,c=2,r=1,C=1;{pixels}\x1b\\").as_bytes());
    t.drain();
    t.feed(b"\x1b[1;2HX\x1b[3;1H");
    assert_eq!(edit_of(&mut t, 0), Some(None));
}

#[test]
fn row_zero_continuing_the_scrollback_is_sent_whole() {
    // Row 0 begins mid-line in the buffer when the row that scrolled off above it wrapped.
    let mut t = settled(2, 10, b"0123456789abcdefghijklmnopqrs");
    assert!(t.screen().head() > 0, "the fixture must leave a seam");
    t.feed(b"\x1b[1;2HX\x1b[2;1H");
    assert_eq!(edit_of(&mut t, 0), Some(None));
}
