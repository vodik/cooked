//! Keeping the text Emacs holds for a row that scrolls into history; see
//! `Front::promote`.

use super::*;
use crate::emu::screen::Direction;

/// How many rows DELTA promoted.
fn count(delta: &Delta) -> usize {
    delta.promoted.map_or(0, |shift| shift.count)
}

/// A terminal whose every row has been drained once, so Emacs holds all of it.
fn settled(rows: usize, cols: usize, input: &[u8]) -> Term {
    let mut t = term(rows, cols, input);
    t.drain_promoting();
    t
}

#[test]
fn a_line_fed_at_the_bottom_promotes_the_top_row() {
    // `tail -f`: the row leaving is the one Emacs has at the top, so the scroll is left
    // with nothing to move, and only the new bottom row is sent.
    let mut t = settled(3, 10, b"one\r\ntwo\r\nthree");
    t.feed(b"\r\nfour");
    let delta = t.drain_promoting();
    assert_eq!(count(&delta), 1);
    assert_eq!(runs_text(&delta.scrolled[0]), "one");
    assert_eq!(delta.shifts, Vec::<Shift>::new());
    assert_eq!(
        delta.rows.iter().map(|r| r.index).collect::<Vec<_>>(),
        vec![2]
    );
}

#[test]
fn a_drain_that_does_not_promote_sends_every_row_and_the_whole_scroll() {
    let mut t = settled(3, 10, b"one\r\ntwo\r\nthree");
    t.feed(b"\r\nfour");
    let delta = t.drain();
    assert_eq!(delta.promoted, None);
    assert_eq!(delta.shifts.len(), 1);
    assert_eq!(delta.shifts[0].count, 1);
}

#[test]
fn a_scroll_of_more_lines_than_it_promotes_keeps_the_rest_of_its_rows() {
    // The second line to leave was written after the drain, so Emacs never showed it.
    let mut t = settled(4, 10, b"one\r\ntwo\r\nthree\r\nfour");
    t.feed(b"\x1b[2;1Hsix\x1b[4;5H\r\nfive\r\nseven");
    let delta = t.drain_promoting();
    assert_eq!(count(&delta), 1);
    assert_eq!(delta.scrolled.len(), 2);
    assert_eq!(delta.shifts.len(), 1);
    assert_eq!(delta.shifts[0].count, 1, "the scroll less the promoted row");
}

#[test]
fn a_flood_promotes_only_the_rows_emacs_showed() {
    let mut t = settled(3, 10, b"one\r\ntwo\r\nthree");
    for i in 0..10 {
        t.feed(format!("\r\n{i}").as_bytes());
    }
    let delta = t.drain_promoting();
    assert_eq!(delta.scrolled.len(), 10);
    assert_eq!(count(&delta), 3);
    // The screen turned over, so every row is sent and nothing is left to move.
    assert_eq!(delta.shifts, Vec::<Shift>::new());
    assert_eq!(delta.rows.len(), 3);
}

#[test]
fn a_row_changed_before_it_leaves_is_sent_and_so_is_everything_after_it() {
    let mut t = settled(3, 10, b"one\r\ntwo\r\nthree");
    t.feed(b"\x1b[1;1Hx\x1b[3;6H\r\n\r\n");
    let delta = t.drain_promoting();
    assert_eq!(delta.scrolled.len(), 2);
    assert_eq!(
        delta.promoted, None,
        "`two` is Emacs' second row, but not its first"
    );
}

#[test]
fn a_row_emacs_trimmed_is_sent() {
    let mut t = settled(3, 10, b"one\r\ntwo\r\nthree");
    t.forget_sent(Some(0));
    t.feed(b"\r\nfour");
    assert_eq!(t.drain_promoting().promoted, None);
}

#[test]
fn a_row_emacs_trimmed_after_it_left_is_sent() {
    let mut t = settled(3, 10, b"one\r\ntwo\r\nthree");
    t.feed(b"\r\nfour");
    t.forget_sent(None);
    assert_eq!(t.drain_promoting().promoted, None);
}

#[test]
fn a_row_resized_away_is_sent() {
    let mut t = settled(3, 10, b"one\r\ntwo\r\nthree");
    t.feed(b"\r\nfour");
    t.resize(2, 10);
    assert_eq!(t.drain_promoting().promoted, None);
}

#[test]
fn a_region_from_the_top_row_promotes_above_its_status_line() {
    // tmux's pane above its status line, or a progress bar pinned to the bottom row: the
    // promotion is a scroll of the region, and the status line stays where it is.
    let mut t = settled(3, 10, b"\x1b[1;2rone\r\ntwo\x1b[3;1Hstatus\x1b[2;4H");
    t.feed(b"\r\nthree");
    let delta = t.drain_promoting();
    assert_eq!(
        delta.promoted,
        Some(Shift {
            top: 0,
            bottom: 1,
            count: 1,
            direction: Direction::Up,
        })
    );
    assert_eq!(delta.shifts, Vec::<Shift>::new());
    assert_eq!(
        delta.rows.iter().map(|r| r.index).collect::<Vec<_>>(),
        vec![1]
    );
}

#[test]
fn a_scroll_after_a_region_scroll_is_sent() {
    // The region moved rows 1 and 2 without the top one, so the rows Emacs holds are out
    // of step with the grid's by the time the whole screen scrolls.
    let mut t = settled(3, 10, b"one\r\ntwo\r\nthree");
    t.feed(b"\x1b[2;3r\x1b[3;1H\n\x1b[r\x1b[3;1H\n");
    let delta = t.drain_promoting();
    assert_eq!(delta.scrolled.len(), 1);
    assert_eq!(delta.promoted, None);
}

#[test]
fn a_screen_clear_is_sent() {
    let mut t = settled(3, 10, b"one\r\ntwo\r\nthree");
    t.feed(b"\x1b[2J");
    let delta = t.drain_promoting();
    assert!(!delta.scrolled.is_empty());
    assert_eq!(delta.promoted, None);
}

#[test]
fn a_row_drawn_with_the_cursor_inside_a_glyph_run_is_sent() {
    // Emacs cut the border's image around the cursor, and scrollback has no cursor.
    let mut t = settled(2, 10, "┌──┐\r\nx\x1b[1;2H".as_bytes());
    t.feed(b"\x1b[2;2H\n");
    assert_eq!(t.drain_promoting().promoted, None);
    let mut t = settled(2, 10, "┌──┐\r\nx".as_bytes());
    t.feed(b"\n");
    assert_eq!(
        count(&t.drain_promoting()),
        1,
        "the same border drawn whole"
    );
}

#[test]
fn a_wrapped_row_promotes_with_its_wrap() {
    let mut t = settled(3, 5, b"abcdefg");
    t.feed(b"\r\n\r\n");
    let delta = t.drain_promoting();
    assert_eq!(count(&delta), 1);
    assert!(delta.scrolled[0].wrapped);
}

#[test]
fn a_wrapped_row_ending_in_a_linked_blank_is_sent() {
    // Scrollback keeps a wrapped row's trailing blanks, with their link, while the live
    // row trimmed them, so Emacs cannot pad the row back with plain spaces.
    let mut t = settled(3, 4, b"ab\x1b]8;;https://e.x\x07  \x1b]8;;\x07e");
    t.feed(b"\r\n\r\n");
    let delta = t.drain_promoting();
    assert_eq!(delta.scrolled.len(), 1);
    assert!(delta.scrolled[0].wrapped);
    assert_eq!(delta.promoted, None);
}

#[test]
fn the_alternate_screen_promotes_nothing() {
    let mut t = settled(3, 10, b"one\r\ntwo\r\nthree");
    t.feed(b"\r\nfour\x1b[?1049h");
    assert_eq!(t.drain_promoting().promoted, None);
}

#[test]
fn nothing_is_promoted_across_a_switch_of_screens() {
    // Before the switch and after it, in a drain that ends on the primary screen.
    let mut t = settled(3, 10, b"one\r\ntwo\r\nthree");
    t.feed(b"\r\nfour\x1b[?1049h\x1b[?1049l");
    assert_eq!(t.drain_promoting().promoted, None);
    let mut t = settled(3, 10, b"one\r\ntwo\r\nthree");
    t.feed(b"\x1b[?1049h\x1b[?1049l\r\nfour");
    assert_eq!(t.drain_promoting().promoted, None);
}

#[test]
fn a_hidden_drain_promotes_nothing_and_leaves_its_rows_to_the_scroll() {
    // A buffer no window shows takes the scrollback as text and leaves the scroll in the
    // log, so the rows Emacs shows at the top are still the ones just sent again when the
    // next whole drain comes, and none of the rows after them can be promoted either.
    let mut t = settled(3, 10, b"one\r\ntwo\r\nthree");
    t.feed(b"\r\nfour");
    let hidden = t.drain_hidden();
    assert!(hidden.withheld);
    assert_eq!(hidden.promoted, None);
    assert_eq!(
        hidden.scrolled.iter().map(runs_text).collect::<Vec<_>>(),
        ["one"]
    );
    t.feed(b"\r\nfive");
    let whole = t.drain_promoting();
    assert_eq!(
        whole.promoted, None,
        "`two` is not Emacs' top row until `one` goes"
    );
    assert_eq!(
        whole.scrolled.iter().map(runs_text).collect::<Vec<_>>(),
        ["two"]
    );
    assert_eq!(whole.shifts.len(), 1);
    assert_eq!(whole.shifts[0].count, 2, "the whole scroll, `one` included");
}

#[test]
fn a_hidden_drain_with_nothing_scrolled_leaves_promotion_to_the_next() {
    let mut t = settled(3, 10, b"one\r\ntwo\r\nthree");
    t.feed(b"\x07");
    assert!(t.drain_hidden().scrolled.is_empty());
    t.feed(b"\r\nfour");
    assert_eq!(count(&t.drain_promoting()), 1);
}

#[test]
fn rows_promoted_before_the_log_drops_its_moves_are_sent() {
    // `\r\n` twice promotes `A` and `B` by one scroll, `CSI 2 T` logs a second, and the
    // third scroll finds the 2-row log full and drops both -- every row is damaged on the
    // spot and sent whole, so neither has a share of the promotion to give back and `A`
    // and `B` go as text instead. The fourth scroll, after the drop, moves rows that are
    // already damaged for this drain, so it is not recorded either: replaying it in Lisp
    // would only rotate text `cooked--render-rows` is about to overwrite.
    let mut t = settled(2, 12, b"A\r\nB");
    t.feed(b"\r\nC\r\nD\x1b[2T\r\nE\r\nF");
    let delta = t.drain_promoting();
    assert_eq!(delta.promoted, None);
    assert_eq!(
        delta.scrolled.iter().map(runs_text).collect::<Vec<_>>(),
        ["A", "B", "", ""]
    );
    assert_eq!(delta.shifts, vec![]);
}
