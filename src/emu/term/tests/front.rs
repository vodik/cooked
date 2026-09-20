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

/// A linked row rewritten exactly as it was is not sent, link and all.
///
/// The other half of `a_row_relinked_under_a_recycled_id_is_still_sent`, and what keeps
/// `ls --hyperlink` reprinting a prompt line from costing Emacs a redraw: the link is part
/// of the cell, so an unchanged destination is an unchanged cell.
#[test]
fn a_linked_line_written_back_as_it_was_is_not_sent() {
    let mut t = settled(
        2,
        20,
        b"\x1b]8;;https://example.com/\x1b\\file\x1b]8;;\x1b\\ ok",
    );
    t.feed(b"\x1b[1;1H\x1b[2K\x1b]8;;https://example.com/\x1b\\file\x1b]8;;\x1b\\ ok");
    assert_eq!(sent(&mut t), Vec::<usize>::new());
}

/// A row whose destination changed is sent, even when a reused id makes its cells match.
///
/// The hazard recycling introduces, and the reason `State::collect_links` marks the front
/// buffer. The front holds *copies of cells*, and a cell names its link by id: if an id
/// were freed while only the front still named it and handed to the next destination,
/// this row's cells would compare equal to the copy Emacs was sent and the row would be
/// left out of the drain -- leaving Emacs showing the first destination under text the
/// child has relinked to the second. The link limit of one makes every new destination
/// collect, which on a real store takes four thousand of them.
#[test]
fn a_row_relinked_under_a_recycled_id_is_still_sent() {
    let mut t = Term::with_id_limits(1, 4, 4096, 1);
    t.feed(b"\x1b]8;;https://first.example/\x1b\\x\x1b]8;;\x1b\\");
    let first = t.drain();
    assert_eq!(first.links.len(), 1, "the destination crossed once");
    // Overwritten, so the grid no longer names the first destination and only the front
    // buffer's copy of the row does; then written back under a second destination.
    t.feed(b"\r ");
    t.feed(b"\r\x1b]8;;https://second.example/\x1b\\x\x1b]8;;\x1b\\");
    let second = t.drain();
    assert_eq!(
        second.rows.iter().map(|r| r.index).collect::<Vec<_>>(),
        vec![0],
        "the row's destination changed, so Emacs has to be told"
    );
    let (id, uri) = second.links.first().expect("the new destination crossed");
    assert_eq!(uri, "https://second.example/");
    assert_eq!(
        second.rows[0].runs.run(0).link,
        Some(*id),
        "and the row names the id this drain announced"
    );
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
    // Lisp cuts a glyph run around the cursor's cell, so the row renders differently.
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
        let text = e.runs.iter().map(|r| r.text).collect();
        (
            e.char_start.get(),
            e.char_end.map(Chars::get),
            e.chars.get(),
            text,
        )
    }))
}

#[test]
fn neighbouring_rows_changing_a_little_are_edits_on_the_primary_screen() {
    // Sent whole they would coalesce into one block, which Emacs deletes and inserts again,
    // taking every marker on the rows' unchanged cells with it.
    let mut t = settled(3, 20, b"1 abcdefghij\r\n2 klmnopqrst");
    t.feed(b"\x1b[1;1H3\x1b[2;1H4\x1b[3;1H");
    let edits: Vec<_> = t
        .drain()
        .rows
        .iter()
        .map(|row| {
            (
                row.index,
                row.edit
                    .as_ref()
                    .map(|e| (e.char_start.get(), e.char_end.map(Chars::get))),
            )
        })
        .collect();
    assert_eq!(
        edits,
        vec![(0, Some((0, Some(1)))), (1, Some((0, Some(1))))]
    );
}

#[test]
fn neighbouring_rows_changing_a_little_are_a_block_on_the_alternate_screen() {
    let mut t = settled(3, 20, b"\x1b[?1049h1 abcdefghij\r\n2 klmnopqrst");
    t.feed(b"\x1b[1;1H3\x1b[2;1H4\x1b[3;1H");
    let delta = t.drain();
    assert_eq!(
        delta.rows.iter().map(|r| r.index).collect::<Vec<_>>(),
        vec![0, 1]
    );
    assert!(delta.rows.iter().all(|row| row.edit.is_none()));
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

/// Two of the same combining mark written back as one: every attachment on either side is
/// also on the other, so only counting them tells the rows apart.
#[test]
fn a_repeated_combining_mark_written_back_once_is_an_edit() {
    let mut t = settled(2, 40, "cafe\u{301}\u{301} x and some more".as_bytes());
    t.feed("\x1b[1;4He\u{301}\x1b[2;1H".as_bytes());
    assert_eq!(
        edit_of(&mut t, 0),
        Some(Some((3, Some(6), 21, "e\u{301}".to_string())))
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
    // Lisp cut the run around the cursor's cell, so when the cursor leaves the run it is
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
fn a_bare_cursor_move_out_of_a_glyph_run_redraws_the_run() {
    // The lone `┌`: the border was drained with the cursor on its second column, where
    // Lisp cut the run, and then the cursor moved away without writing anything. No row
    // is damaged, and the run must still be drawn again as one.
    let mut t = settled(
        3,
        40,
        "a \u{250c}\u{2500}\u{2500}\u{2510} b\x1b[1;4H".as_bytes(),
    );
    t.feed(b"\x1b[3;1H");
    assert_eq!(
        edit_of(&mut t, 0),
        Some(Some((
            2,
            Some(6),
            8,
            "\u{250c}\u{2500}\u{2500}\u{2510}".to_string()
        )))
    );
    // Once drawn, the row is settled, and the next move elsewhere sends nothing.
    t.feed(b"\x1b[2;1H");
    assert_eq!(sent(&mut t), Vec::<usize>::new());
}

#[test]
fn a_forgotten_row_the_cursor_cut_is_redrawn_when_the_cursor_leaves() {
    // The width guard edited row 0 after it was drawn with the cursor inside `┌──┐`, so
    // the copy stopped knowing the row. The cursor then leaves without writing anything:
    // no row is damaged, and the run Lisp cut around the cursor must still be drawn again.
    let mut t = settled(
        3,
        40,
        "a \u{250c}\u{2500}\u{2500}\u{2510} b\x1b[1;4H".as_bytes(),
    );
    t.forget_sent(Some(0));
    t.feed(b"\x1b[3;1H");
    assert_eq!(sent(&mut t), vec![0]);
    // Sent whole and recorded with the cursor elsewhere, so the next move sends nothing.
    t.feed(b"\x1b[2;1H");
    assert_eq!(sent(&mut t), Vec::<usize>::new());
}

#[test]
fn a_bare_cursor_move_into_a_glyph_run_redraws_the_run() {
    let mut t = settled(
        3,
        40,
        "a \u{250c}\u{2500}\u{2500}\u{2510} b\x1b[3;1H".as_bytes(),
    );
    t.feed(b"\x1b[1;5H");
    assert_eq!(
        edit_of(&mut t, 0),
        Some(Some((
            2,
            Some(6),
            8,
            "\u{250c}\u{2500}\u{2500}\u{2510}".to_string()
        )))
    );
}

#[test]
fn a_bare_cursor_move_across_plain_rows_sends_nothing() {
    let mut t = settled(3, 40, b"one\r\ntwo\x1b[1;2H");
    t.feed(b"\x1b[2;2H");
    assert_eq!(sent(&mut t), Vec::<usize>::new());
    t.feed(b"\x1b[3;1H");
    assert_eq!(sent(&mut t), Vec::<usize>::new());
}

#[test]
fn a_cursor_on_the_first_cell_of_a_glyph_run_is_inside_it() {
    // Lisp cuts after the cursor's cell as well as before it, so the corner a cursor sits
    // on is drawn apart from the rest of its border.
    let mut t = settled(
        3,
        40,
        "a \u{250c}\u{2500}\u{2500}\u{2510} b\x1b[3;1H".as_bytes(),
    );
    t.feed(b"\x1b[1;3H");
    assert_eq!(sent(&mut t), vec![0]);
}

#[test]
fn a_cursor_on_a_lone_glyph_changes_nothing() {
    // A one-cell run cut on both sides is the run it was.
    let mut t = settled(3, 40, "a \u{2502} b\x1b[3;1H".as_bytes());
    t.feed(b"\x1b[1;3H");
    assert_eq!(sent(&mut t), Vec::<usize>::new());
}

#[test]
fn a_cursor_moving_into_a_glyph_run_after_a_wide_character_edits_the_run() {
    // `日` takes columns 0 and 1 and one character, so the run in columns 3 to 6 starts
    // two characters in, and that is where the edit has to start for Lisp to find it.
    let mut t = settled(
        3,
        40,
        "\u{65e5} \u{2500}\u{2500}\u{2500}\u{2500} rest\x1b[1;2H".as_bytes(),
    );
    t.feed(b"\x1b[1;6H");
    assert_eq!(
        edit_of(&mut t, 0),
        Some(Some((2, Some(6), 11, "\u{2500}".repeat(4))))
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
    assert!(
        !t.screen().head().is_zero(),
        "the fixture must leave a seam"
    );
    t.feed(b"\x1b[1;2HX\x1b[2;1H");
    assert_eq!(edit_of(&mut t, 0), Some(None));
}

/// An edit's replacement carries the link and the underline colour of the cells it
/// replaces, so a change inside a linked, underlined span keeps both.
#[test]
fn an_edit_inside_a_linked_underlined_span_keeps_the_link_and_the_colour() {
    let mut t = settled(
        2,
        40,
        b"see \x1b]8;;https://example.com/\x1b\\\x1b[4;58;5;196mnumber 1\x1b[0m\x1b]8;;\x1b\\ here",
    );
    t.feed(b"\x1b]8;;https://example.com/\x1b\\\x1b[4;58;5;196m\x1b[1;12H2\x1b[0m\x1b]8;;\x1b\\\x1b[2;1H");
    let row = t.drain().rows.into_iter().find(|r| r.index == 0).unwrap();
    let edit = row.edit.expect("sent as an edit");
    assert_eq!(edit.runs.len(), 1, "{:?}", edit.runs);
    let run = edit.runs.run(0);
    assert_eq!(run.text, "2");
    assert!(run.link.is_some());
    assert_eq!(t.style(run.style).underline, Color::Indexed(196));
}

#[test]
fn a_washed_row_the_screen_grows_back_over_is_sent() {
    // Every row is washed inverse, and Emacs trims the region to the cursor's row, so the
    // two below it are gone from the buffer. The cursor moving down damages nothing, and
    // the row it reaches still has to arrive in its colour rather than as an empty line.
    let mut t = settled(3, 10, b"\x1b[7m\x1b[3M");
    t.feed(b"\r\n");
    assert_eq!(sent(&mut t), vec![1]);
    // Emacs holds it now, so nothing more is sent until something changes.
    assert_eq!(sent(&mut t), Vec::<usize>::new());
}

#[test]
fn a_blank_row_the_screen_grows_back_over_is_not_sent() {
    let mut t = settled(3, 10, b"top");
    t.feed(b"\r\n");
    assert_eq!(sent(&mut t), Vec::<usize>::new());
}

/// A blank row that claims a continuation is the one blank row worth sending: an empty
/// line ends with a newline, and a wrapped row must not.
///
/// The flag gets there without a character being written anywhere near it: a wide
/// character that does not fit in the last column wraps a row of nothing but blanks, `EL`
/// takes away the continuation holding the only text of that line, and `SD` puts the pair
/// below the cursor, where Emacs trims the screen region away. Nothing damages the row
/// again, so the growth back over it is the only thing that can send it.
#[test]
fn a_wrapped_blank_row_the_screen_grows_back_over_is_sent() {
    let mut t = settled(4, 4, "\x1b[1;4H\u{65e5}\x1b[2K\x1b[1;1H\x1b[2T".as_bytes());
    assert!(t.screen().row(2).unwrap().wrapped());
    // Down onto the row itself, which damages nothing.
    t.feed(b"\x1b[3;1H");
    let delta = t.drain();
    let wrapped: Vec<(usize, bool)> = delta.rows.iter().map(|r| (r.index, r.wrapped)).collect();
    assert_eq!(wrapped, [(2, true)]);
}

#[test]
fn a_washed_row_a_scroll_brings_up_from_below_the_region_is_sent() {
    // Emacs holds only row 0; the washed rows below it were trimmed. Scrolling up by two
    // moves one of them to row 0 without damaging it.
    let mut t = settled(5, 10, b"\x1b[42m\x1b[4M");
    t.feed(b"\x1b[2S");
    let delta = t.drain();
    assert_eq!(delta.shifts.len(), 1);
    assert!(
        delta.rows.iter().any(|row| row.index == 0),
        "{:?}",
        delta.rows
    );
}
