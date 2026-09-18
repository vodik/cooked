//! Printing, cursor motion, erasing, scrolling, tab stops, charsets and the alternate screen.

use super::*;

#[test]
fn plain_text_lands_on_the_grid() {
    let t = term(4, 20, b"hello");
    assert_eq!(text(&t, 0), "hello");
}

#[test]
fn cursor_addressing_is_one_based() {
    let t = term(4, 20, b"\x1b[2;3Hx");
    assert_eq!(text(&t, 1), "  x");
}

#[test]
fn decstbm_on_a_zero_height_screen_does_not_underflow() {
    // `CSI r` with no parameters defaults its bottom margin to the screen's own
    // height, unlike every other `arg(...) - 1` call site in this module, which
    // passes a non-zero literal default. `Term::new`/`Screen::resize` now floor
    // height at 1 regardless of what is asked for, so this can no longer reach a
    // real `0 - 1`, but the call site's own `saturating_sub` is exercised directly
    // here in case that floor is ever relaxed.
    let mut t = Term::new(0, 20);
    t.feed(b"\x1b[r"); // must not panic (underflow) in a debug/overflow-checked build
    assert_eq!(t.screen().height(), 1, "height is floored, not left at 0");
}

#[test]
fn rep_repeats_the_last_graphic_character() {
    let t = term(2, 10, b"-\x1b[4b");
    assert_eq!(text(&t, 0), "-----");
}

#[test]
fn rep_repeats_what_dec_graphics_drew() {
    // `q` in the DEC graphics set is a horizontal rule; REP must repeat the rule,
    // not the letter that was on the wire.
    let t = term(2, 10, b"\x1b(0q\x1b[2b");
    assert_eq!(text(&t, 0), "───");
}

#[test]
fn rep_without_a_preceding_print_does_nothing() {
    let t = term(2, 10, b"\x1b[5b");
    assert_eq!(text(&t, 0), "");
}

#[test]
fn rep_ignores_a_combining_mark() {
    // The mark folds onto the `e`; REP then repeats the `e`, not the accent.
    //
    // Compared as text rather than counted: a REP that repeated the mark would fold both
    // copies back onto the same first cell, for `e` plus three accents -- four characters
    // either way, so a count cannot tell the two apart and this passed with `last_print`
    // capturing zero-width marks.
    let t = term(2, 10, b"e\xcc\x81\x1b[2b");
    assert_eq!(t.screen().row(0).unwrap().to_text(), "e\u{301}ee");
}

#[test]
fn rep_is_bounded_by_the_screen() {
    let mut t = term(2, 10, b"x\x1b[65535b");
    // Twenty cells exist; the count is capped rather than looped 65535 times.
    assert!(t.drain().scrolled.len() <= 2);
}

#[test]
fn a_tab_count_is_bounded_by_the_width() {
    // `CSI 65535 I` and `CSI 65535 Z`: both saturate long before the count runs out, so
    // unbounded they would be work past `cols` that does nothing, 158x slower than plain
    // text on a 24x200 grid.
    let t = term(2, 24, b"\x1b[65535I");
    assert_eq!(t.screen().cursor().col, 23);
    let t = term(2, 24, b"\x1b[20G\x1b[65535Z");
    assert_eq!(t.screen().cursor().col, 0);
}

#[test]
fn back_tab_walks_to_the_previous_stop() {
    let t = term(2, 24, b"\x1b[20G\x1b[Z");
    assert_eq!(t.screen().cursor().col, 16);
    let t = term(2, 24, b"\x1b[20G\x1b[3Z");
    assert_eq!(t.screen().cursor().col, 0, "floors at column zero");
}

#[test]
fn scrolled_rows_are_handed_over_exactly_once() {
    let mut t = term(2, 8, b"one\r\ntwo\r\nthree");
    let delta = t.drain();
    assert_eq!(delta.scrolled.len(), 1);
    assert_eq!(runs_text(&delta.scrolled[0]), "one");
    assert!(t.drain().scrolled.is_empty());
}

#[test]
fn scrolled_lines_carry_their_wrap_provenance() {
    // Eight columns, so "abcdefghij" is one logical line spread over two rows.
    let mut t = term(2, 8, b"abcdefghij\r\nsecond\r\nthird");
    let delta = t.drain();

    assert_eq!(delta.scrolled.len(), 2);
    assert!(
        delta.scrolled[0].wrapped,
        "the overflowing row continues below"
    );
    assert_eq!(runs_text(&delta.scrolled[0]), "abcdefgh");
    assert!(!delta.scrolled[1].wrapped, "a real newline ends the line");
    assert_eq!(runs_text(&delta.scrolled[1]), "ij");
}

/// A continuation row's trailing blanks are interior to the line, not the end of it.
/// Emacs rejoins a wrapped row onto the line above without a newline, so cutting them
/// pulls the continuation forward — and column-aligned output like `ps` is padded with
/// spaces at every boundary, so a wrap landing inside a run of them is the common case.
#[test]
fn a_wrapped_row_keeps_the_blanks_that_are_interior_to_its_line() {
    // Eight columns. "abc     def" wraps with the row boundary inside the spaces.
    let mut t = term(2, 8, b"abc     def\r\nsecond\r\nthird");
    let delta = t.drain();

    assert_eq!(delta.scrolled.len(), 2);
    assert!(delta.scrolled[0].wrapped);
    assert_eq!(
        runs_text(&delta.scrolled[0]),
        "abc     ",
        "all eight columns, or the line reassembles as `abcdef`"
    );
    assert_eq!(runs_text(&delta.scrolled[1]), "def");
}

/// The invariant [`Screen::carried`] rests on: every row that leaves for Emacs while
/// its line continues is exactly `cols` characters, so `carried * cols` measures the
/// head. A rewrap blank-pads its chunks out to the full width, so this is what keeps
/// the seam from drifting once a resize has evicted padded rows.
#[test]
fn every_wrapped_row_handed_over_is_exactly_a_full_row_wide() {
    let mut t = Term::new(4, 10);
    // Four space-padded lines, each reaching the right edge, filling the grid.
    for _ in 0..4 {
        t.feed(b"aa   bb   \r\n");
    }
    t.drain();
    t.resize(2, 4);
    let delta = t.drain();

    for line in &delta.scrolled {
        if line.wrapped {
            assert_eq!(
                runs_text(line).chars().count(),
                4,
                "a continuation row must fill its width: {:?}",
                runs_text(line)
            );
        }
    }
}

#[test]
fn alt_screen_output_never_reaches_scrollback() {
    let mut t = term(2, 8, b"keep\r\n");
    t.drain();
    t.feed(b"\x1b[?1049h");
    t.feed(b"a\r\nb\r\nc\r\nd\r\n");
    let delta = t.drain();
    assert!(
        delta.scrolled.is_empty(),
        "alt screen must not pollute history"
    );
    assert!(delta.levels.alt);

    t.feed(b"\x1b[?1049l");
    let back = t.drain();
    assert!(!back.levels.alt);
    assert_eq!(text(&t, 0), "keep");
}

#[test]
fn the_primary_keeps_its_head_through_the_alternate_screen() {
    // Two rows of `=` wrap onto a third and scroll the first away, so row 0 continues a
    // line whose head is in Emacs.
    let mut t = term(2, 4, b"==========");
    assert_eq!(t.drain().head, 4, "precondition: row 0 continues a line");

    // The alternate screen's row 0 begins a buffer line, and the primary's continues the
    // same line again once it is back.
    t.feed(b"\x1b[?1049h");
    assert_eq!(t.drain().head, 0);
    t.feed(b"\x1b[?1049l");
    assert_eq!(t.drain().head, 4, "the primary's row 0 continues its line");

    // The same through a drain that leaves the screen out, and through a switch there
    // and back that no drain saw.
    let mut t = term(2, 4, b"==========");
    t.drain();
    t.feed(b"\x1b[?1049h");
    assert_eq!(t.drain_hidden().head, 0);
    t.feed(b"\x1b[?1049l");
    assert_eq!(t.drain().head, 4);
    t.feed(b"\x1b[?1049h\x1b[?1049l");
    assert_eq!(t.drain().head, 4);
}

#[test]
fn a_resize_under_the_alternate_screen_carries_the_primarys_head_on() {
    // Shrunk to one row, the primary hands its wrapped row 0 to scrollback, which
    // joins it to the head above, and row 0 continues the longer line.
    let mut t = term(2, 4, b"==========");
    t.drain();
    t.feed(b"\x1b[?1049h");
    t.drain();
    t.resize(1, 4);
    let delta = t.drain();
    assert_eq!(delta.head, 0, "the alternate screen begins its own line");
    assert_eq!(
        delta
            .scrolled_lines(true)
            .map(|(_, ends)| ends)
            .collect::<Vec<_>>(),
        [false],
        "the row joins the primary's row 0 and not the alternate screen's"
    );
    t.feed(b"\x1b[?1049l");
    assert_eq!(t.drain().head, 8);
}

#[test]
fn a_switch_of_screens_sends_only_the_rows_they_do_not_share() {
    let sent = |t: &mut Term| {
        t.drain_promoting()
            .rows
            .iter()
            .map(|row| row.index)
            .collect::<Vec<_>>()
    };
    let mut t = term(3, 10, b"one\r\ntwo\r\nbar");
    sent(&mut t);
    // The alternate screen draws the first and last rows the primary holds.
    t.feed(b"\x1b[?1049h\x1b[1;1Hone\x1b[3;1Hbar");
    assert_eq!(sent(&mut t), [1]);
    t.feed(b"\x1b[?1049l");
    assert_eq!(sent(&mut t), [1]);
    // A switch there and back inside one drain changes no row at all.
    t.feed(b"\x1b[?1049h\x1b[1;1Hone\x1b[?1049l");
    assert_eq!(sent(&mut t), Vec::<usize>::new());
}

#[test]
fn erase_display_clears_below() {
    let mut t = term(3, 8, b"aaa\r\nbbb\r\nccc");
    t.feed(b"\x1b[2;1H\x1b[J");
    assert_eq!(text(&t, 0), "aaa");
    assert_eq!(text(&t, 1), "");
    assert_eq!(text(&t, 2), "");
}

#[test]
fn erase_scrollback_is_flagged_as_an_event_and_leaves_the_screen_alone() {
    // Unlike `CSI 2 J`, real xterm's `3 J` never touches the visible screen — only
    // the scrollback, which the grid does not hold, so it does nothing at all here.
    let mut t = term(3, 8, b"aaa\r\nbbb\r\nccc");
    t.drain();
    t.feed(b"\x1b[3J");
    let delta = t.drain();
    assert_eq!(delta.events, vec![Event::EraseScrollback]);
    assert!(delta.rows.is_empty(), "nothing on the grid changed");
    assert_eq!(text(&t, 0), "aaa");
    assert_eq!(text(&t, 1), "bbb");
    assert_eq!(text(&t, 2), "ccc");
}

#[test]
fn a_partial_erase_raises_neither_clearing_event() {
    // `0 J` and `1 J` are a child rewriting part of a screen it is still drawing on,
    // not finishing with one: no scrollback goes, and no viewport moves.
    let mut t = term(3, 8, b"aaa\r\nbbb\r\nccc");
    t.drain();
    t.feed(b"\x1b[0J\x1b[1J");
    assert!(t.drain().events.is_empty());
}

#[test]
fn clearing_the_display_asks_emacs_to_show_the_blank_screen() {
    // The rows are archived rather than lost, so nothing scrolls out of view on its
    // own: `2 J` looks like nothing happened unless Emacs moves the window, and this
    // event is what tells it to.
    let mut t = term(3, 8, b"aaa\r\nbbb\r\nccc");
    t.drain();
    t.feed(b"\x1b[2J");
    assert_eq!(t.drain().events, vec![Event::DisplayCleared]);
}

#[test]
fn a_reset_clears_the_display_like_any_other() {
    let mut t = term(3, 8, b"aaa\r\nbbb\r\nccc");
    t.drain();
    t.feed(b"\x1bc");
    assert!(t.drain().events.contains(&Event::DisplayCleared));
}

#[test]
fn a_reset_says_so_where_a_soft_reset_does_not() {
    // The event Emacs needs in order to drop the state it holds on the emulator's
    // behalf, which is why the distinction below is load-bearing rather than pedantic:
    // every `rs2` and `is2` sends DECSTR, so a soft reset firing this would clear a
    // running build's progress every time a full-screen program tidied up after itself.
    let mut t = term(3, 8, b"aaa");
    t.drain();
    t.feed(b"\x1b[!p");
    assert!(
        !t.drain().events.contains(&Event::Reset),
        "DECSTR is not RIS"
    );
    t.feed(b"\x1bc");
    assert!(t.drain().events.contains(&Event::Reset));
}

/// `cat` of a binary sends thousands of BELs, and each one queued is a trip through Lisp
/// that the bell's own rate limit then throws away. One per drain says all of it.
#[test]
fn a_burst_of_bells_is_one_event_per_drain() {
    let bells = |events: &[Event]| events.iter().filter(|e| **e == Event::Bell).count();
    let mut t = term(3, 8, b"");
    t.feed(&b"\x07a\x07\x1b]0;x\x07\x07".repeat(1000));
    assert_eq!(bells(&t.drain().events), 1);
    assert_eq!(bells(&t.drain().events), 0, "nothing rings twice");
    t.feed(b"\x07");
    assert_eq!(bells(&t.drain().events), 1, "the next drain rings again");
    // Lisp clears the bell's mark on RIS, so a BEL after one is news again.
    t.feed(b"\x07\x1bc\x07");
    let events = t.drain().events;
    let reset = events.iter().position(|e| *e == Event::Reset).unwrap();
    assert_eq!(bells(&events[..reset]), 1);
    assert_eq!(bells(&events[reset..]), 1);
}

/// `reset` from a shell whose full-screen program died without its `rmcup`: RIS has to
/// bring the user back to the primary screen, and say so on the drain's `alt` level,
/// which is the only way Lisp hears of any alt switch.
#[test]
fn a_reset_leaves_the_alternate_screen() {
    let mut t = term(3, 8, b"keep\r\n");
    t.feed(b"\x1b[?1049hfull");
    assert!(t.drain().levels.alt);
    t.feed(b"\x1bc");
    let delta = t.drain();
    assert!(!delta.levels.alt, "the drain carries the switch back");
    assert!(delta.events.contains(&Event::Reset));
    assert!(
        delta.events.contains(&Event::DisplayCleared),
        "the erase ran on the primary, where clearing is worth announcing"
    );
    assert!(
        delta.scrolled.iter().any(|line| runs_text(line) == "keep"),
        "the primary's text was archived by the erase, as on any RIS"
    );
    assert!(
        !delta.scrolled.iter().any(|line| runs_text(line) == "full"),
        "nothing from the alternate screen reached scrollback"
    );
    assert_eq!(text(&t, 0), "");
    assert_eq!((t.screen().cursor().row, t.screen().cursor().col), (0, 0));
    t.feed(b"\x1b[?1049$p");
    assert!(
        t.drain()
            .events
            .contains(&Event::Reply(b"\x1b[?1049;2$y".to_vec()))
    );
    // Nothing the program saved on the way in survives to be restored on a stray
    // `rmcup` afterwards.
    t.feed(b"ab\x1b[?1049l");
    assert_eq!(text(&t, 0), "ab");
    assert_eq!(t.screen().cursor().col, 2);
}

/// RIS puts the stops back on both screens; DECSTR, like xterm's, leaves them alone.
#[test]
fn a_reset_restores_the_tab_stops_on_both_screens() {
    let mut t = term(2, 30, b"\x1b[3g\x1b[?1049h\x1b[3g\x1b[?1049l\x1b[!p\tx");
    assert_eq!(
        t.screen().cursor().col,
        29,
        "a soft reset kept the cleared stops"
    );
    t.feed(b"\x1bc\tx");
    assert_eq!(text(&t, 0), "        x");
    t.feed(b"\x1b[?1049h\t\ty");
    assert_eq!(
        text(&t, 0),
        "                y",
        "the alternate screen's stops are back too"
    );
}

#[test]
fn the_alt_screen_never_reports_a_cleared_display() {
    // It archives nothing and is pinned to the top of the window already, so there is
    // no transcript for a window to scroll away from.
    let mut t = term(3, 8, b"aaa\r\nbbb");
    t.feed(b"\x1b[?1049h");
    t.drain();
    t.feed(b"\x1b[2J");
    assert!(t.drain().events.is_empty());
}

#[test]
fn leaving_the_alt_screen_restores_the_cursor_the_primary_saved() {
    // `restore_cursor' acts on whichever screen is showing, so the restore has to run
    // after the switch back. Run before it, it reads the alt screen's saved cursor
    // and leaves the primary's -- the one `1049h' saved -- untouched.
    // The saved position has to be one something later moves, or a restore that never
    // ran is indistinguishable from one that did. A rewrap is that something: it is
    // the one thing which relocates the primary's cursor while the alt screen is up.
    // So the line here is wrapped, and the resize below re-chunks it.
    let mut t = term(6, 4, b"aaaabb");
    assert_eq!((t.screen().cursor().row, t.screen().cursor().col), (1, 2));
    t.feed(b"\x1b[?1049h");
    t.feed(b"\x1b[1;1Hframe");
    // Widening rejoins the two rows into one, putting the primary's cursor at (0, 6).
    t.resize(6, 8);
    t.feed(b"\x1b[?1049l");
    assert_eq!(
        (t.screen().cursor().row, t.screen().cursor().col),
        (1, 2),
        "the primary's saved cursor is the one 1049 restores"
    );
}

#[test]
fn dec_graphics_draws_boxes() {
    let t = term(2, 8, b"\x1b(0lqk\x1b(B");
    assert_eq!(text(&t, 0), "┌─┐");
}

/// vttest's VT100 character-set screen, as a table: each set it names, designated into
/// G0 and invoked by SI, then into G1 and invoked by SO, drawing the same row of GL.
///
/// vttest is not installed here, so this stands in for its screen. The row it prints is
/// the one that tells the sets apart -- `#` is where UK differs, `` ` `` through `~` is
/// where graphics differ -- and each set has to come out the same from either slot, which
/// is exactly what a single graphics flag could not manage.
#[test]
fn every_designated_set_draws_the_same_from_g0_and_g1() {
    let probe = "#`jklmnqx~";
    let cases = [
        (b'B', "#`jklmnqx~"),
        (b'1', "#`jklmnqx~"),
        (b'A', "£`jklmnqx~"),
        (b'0', "#◆┘┐┌└┼─│·"),
        (b'2', "#◆┘┐┌└┼─│·"),
    ];
    for (set, drawn) in cases {
        for (slot, shift) in [(b'(', b'\x0f'), (b')', b'\x0e')] {
            let mut input = vec![0x1b, slot, set, shift];
            input.extend_from_slice(probe.as_bytes());
            let t = term(2, 20, &input);
            assert_eq!(
                text(&t, 0),
                drawn,
                "ESC {} {} then {}",
                slot as char,
                set as char,
                if shift == 0x0e { "SO" } else { "SI" }
            );
        }
    }
}

#[test]
fn shifts_choose_a_slot_and_designations_fill_one() {
    // Graphics in G1, ASCII in G0: SO and SI flip between them.
    let t = term(2, 10, b"\x1b)0q\x0eq\x0fq");
    assert_eq!(text(&t, 0), "q─q");
    // G1 powers on ASCII, so a bare SO draws letters, not boxes.
    let t = term(2, 10, b"\x0eq");
    assert_eq!(text(&t, 0), "q");
    // SI does not undo a G0 designation: the old flag cleared it here.
    let t = term(2, 10, b"\x1b(0\x0e\x0fq");
    assert_eq!(text(&t, 0), "─");
    // Redesignating the slot that is not in GL changes nothing on screen.
    let t = term(2, 10, b"\x1b(0\x1b)Bq");
    assert_eq!(text(&t, 0), "─");
}

#[test]
fn g2_and_g3_lock_and_single_shift() {
    // LS2 and LS3 lock; SI puts G0 back.
    let t = term(2, 10, b"\x1b*0\x1b+A\x1bnq\x1bo#\x0fq");
    assert_eq!(text(&t, 0), "─£q");
    // SS2 is spent on the next character only, whatever that character is.
    let t = term(2, 10, b"\x1b*0\x1bNqq");
    assert_eq!(text(&t, 0), "─q");
    let t = term(2, 10, "\x1b*0\x1bN\u{e9}q".as_bytes());
    assert_eq!(text(&t, 0), "\u{e9}q");
}

#[test]
fn a_96_character_designation_puts_ascii_in_its_slot() {
    // `ESC - A` is Latin-1 into G1, not UK: the final byte means another set under a
    // 96-character designator, and every such set designates ASCII here.
    for (designator, shift) in [(b'-', &b"\x0e"[..]), (b'.', b"\x1bn"), (b'/', b"\x1bo")] {
        let slot = designator - b',' + b'(';
        let mut input = vec![0x1b, slot, b'0', 0x1b, designator, b'A'];
        input.extend_from_slice(shift);
        input.extend_from_slice(b"q#");
        let t = term(2, 10, &input);
        assert_eq!(text(&t, 0), "q#", "ESC {}", designator as char);
    }
}

#[test]
fn charsets_are_reset_by_decstr_and_restored_by_decrc() {
    let t = term(2, 10, b"\x1b)0\x0e\x1b[!pq");
    assert_eq!(text(&t, 0), "q", "DECSTR puts G0 back in GL, holding ASCII");
    // DECSC saves the designation and the shift with the position.
    let t = term(2, 10, b"\x1b(0\x1b7\x1b(B\x1b)A\x0e\x1b8q");
    assert_eq!(text(&t, 0), "─");
    // And per screen: the primary's save is not the alternate screen's.
    let t = term(2, 10, b"\x1b(0\x1b[?1049h\x1b(B\x1b7\x1b[?1049lq");
    assert_eq!(text(&t, 0), "─", "1049 restores the primary's graphics set");
}

/// A DECRC keeps its save, so a second one goes back to the same place; with no save it
/// homes the cursor and puts the charsets back, as xterm and ghostty do.
#[test]
fn decrc_keeps_its_save_and_homes_without_one() {
    let t = term(4, 10, b"\x1b[2;3H\x1b7\x1b[4;4H\x1b8\x1b[4;4H\x1b8");
    assert_eq!((t.screen().cursor().row, t.screen().cursor().col), (1, 2));
    let t = term(4, 10, b"\x1b(0\x1b[3;3H\x1b8q");
    assert_eq!((t.screen().cursor().row, t.screen().cursor().col), (0, 1));
    assert_eq!(text(&t, 0), "q", "no save: G0 is ASCII again");
    // DECSTR forgets the save, so the DECRC after it homes too.
    let t = term(4, 10, b"\x1b[2;3H\x1b7\x1b[!p\x1b[4;4H\x1b8");
    assert_eq!((t.screen().cursor().row, t.screen().cursor().col), (0, 0));
}

/// `1049 l` restores the primary's cursor only when it leaves the alternate screen onto a
/// save. A stray one from a script must not send the shell's cursor back over its output.
#[test]
fn a_stray_1049_reset_leaves_the_primary_cursor_alone() {
    let t = term(
        6,
        10,
        b"\x1b[2;1H\x1b[?1049h\x1b[?1049l\x1b[5;4H\x1b[?1049l",
    );
    assert_eq!((t.screen().cursor().row, t.screen().cursor().col), (4, 3));
    // Nor home it when there is nothing saved to go back to.
    let t = term(6, 10, b"\x1b[?1049h\x1b[!p\x1b[5;4H\x1b[?1049l");
    assert_eq!(
        t.screen().cursor().row,
        0,
        "the primary's own cursor, not a restore"
    );
    let t = term(6, 10, b"\x1b[5;4H\x1b[?1049l");
    assert_eq!((t.screen().cursor().row, t.screen().cursor().col), (4, 3));
}

/// vttest's first screen draws its border onto DECALN's pattern, inside margins it has
/// set; the pattern has to fill every cell, reset those margins, home the cursor and
/// leave the pen out of it.
#[test]
fn decaln_fills_the_screen_with_e() {
    let mut t = term(4, 6, b"hi\r\nthere\x1b[3;4H\x1b[31;44m\x1b#8");
    for row in 0..4 {
        assert_eq!(text(&t, row), "EEEEEE");
        assert!(
            t.screen()
                .row(row)
                .unwrap()
                .cells()
                .iter()
                .all(|c| c.style == StyleId::DEFAULT),
            "row {row} is in the default rendition"
        );
    }
    assert_eq!((t.screen().cursor().row, t.screen().cursor().col), (0, 0));
    let delta = t.drain();
    let scrolled: Vec<_> = delta.scrolled.iter().map(runs_text).collect();
    assert_eq!(
        scrolled.iter().map(|s| s.trim_end()).collect::<Vec<_>>(),
        ["hi", "there"],
        "the screen went to history, as a clear would send it"
    );
    // vttest's frame, drawn over it: the pattern stays wherever the frame is not.
    t.feed(b"\x1b[2;2H*\x1b[3;5H+");
    assert_eq!(text(&t, 1), "E*EEEE");
    assert_eq!(text(&t, 2), "EEEE+E");

    // Margins go back to the whole screen. The erase still happens under the margins the
    // child set, exactly as `CSI 2J` would, so a partitioned screen archives nothing.
    let mut t = term(4, 6, b"hi\x1b[2;3r\x1b#8");
    assert_eq!(
        (t.screen().region().top, t.screen().region().bottom),
        (0, 3)
    );
    assert!(t.drain().scrolled.is_empty());

    // DECOM goes off and the pen back to plain, so the next cell drawn is at the screen's
    // own row 3 and in the default rendition.
    let t = term(4, 6, b"\x1b[2;3r\x1b[?6h\x1b[31m\x1b#8\x1b[3;1Hx");
    assert_eq!(text(&t, 2), "xEEEEE");
    assert_eq!(cell_style(&t, 2, 0), Style::default());
}

#[test]
fn decst8c_puts_the_stops_back_every_eight_columns() {
    let mut t = term(2, 30, b"\x1b[3g\x1b[?5W\tx");
    assert_eq!(text(&t, 0), "        x");
    t.feed(b"\r\x1b[3g\x1b[4G\x1bH\r\x1b[?5W\t\ty");
    assert_eq!(
        text(&t, 0),
        "        x       y",
        "the stop set at column 4 is gone"
    );
    // `CSI 5 W` without the `?` is CTC, which is not this.
    let t = term(2, 30, b"\x1b[3g\x1b[5W\tx");
    assert_eq!(
        t.screen().cursor().col,
        29,
        "no stops: the tab ran to the margin"
    );
    assert_eq!(text(&t, 0).trim_start(), "x");
}

/// TBC defines 0, the stop under the cursor, and 3, every stop. xterm ignores any other
/// parameter rather than reading it as 0.
#[test]
fn tbc_clears_one_stop_or_all_and_nothing_for_other_parameters() {
    let t = term(2, 30, b"\x1b[9G\x1b[g\r\tx");
    assert_eq!(text(&t, 0), "                x", "the stop at 8 is gone");
    let t = term(2, 30, b"\x1b[9G\x1b[2g\r\tx");
    assert_eq!(text(&t, 0), "        x", "2 is not a TBC parameter");
}

#[test]
fn scroll_region_then_linefeed_stays_off_scrollback() {
    let mut t = term(4, 8, b"a\r\nb\r\nc\r\nd");
    t.drain();
    t.feed(b"\x1b[2;3r\x1b[3;1H\n");
    assert!(t.drain().scrolled.is_empty());
}

/// A margin that starts at row 0 archives what leaves its top, as vte does. It is what
/// tmux sets for its pane above a status line on the bottom row, with `smcup@` keeping it
/// on the primary screen, and without it the pane's output never reached scrollback.
#[test]
fn a_scroll_region_from_the_top_row_archives_what_leaves_it() {
    let mut t = term(4, 8, b"\x1b[1;3r\x1b[4;1Hstatus\x1b[1;1Ha\r\nb\r\nc");
    t.drain();
    t.feed(b"\r\nd\r\ne");
    let delta = t.drain();
    let scrolled: Vec<String> = delta.scrolled.iter().map(runs_text).collect();
    assert_eq!(
        scrolled,
        ["a", "b"],
        "the rows the region scrolled off its top"
    );
    assert_eq!([text(&t, 0), text(&t, 1), text(&t, 2)], ["c", "d", "e"]);
    assert_eq!(text(&t, 3), "status", "the row below the region stays put");
}

#[test]
fn trailing_text_finds_a_password_prompt() {
    let t = term(4, 30, b"Warming up\r\nPassword: ");
    assert_eq!(t.trailing_text().as_deref(), Some("Password:"));
}

#[test]
fn damage_covers_only_touched_rows() {
    let mut t = term(4, 8, b"a\r\nb");
    t.drain();
    t.feed(b"\x1b[1;1Hz");
    let rows = t.drain().rows;
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].index, 0);
}

#[test]
fn resize_preserves_the_tail() {
    let mut t = term(3, 10, b"one\r\ntwo\r\nthree");
    t.drain();
    t.resize(2, 10);
    let delta = t.drain();
    assert_eq!(delta.scrolled.len(), 1);
    assert_eq!(runs_text(&delta.scrolled[0]), "one");
    assert_eq!(text(&t, 0), "two");
}

#[test]
fn box_drawing_bytes_produce_glyphs_in_the_drained_delta() {
    let mut t = term(2, 10, "\u{250C}\u{2500}\u{2500}\u{2510}".as_bytes());
    let delta = t.drain();
    let runs = &delta
        .rows
        .iter()
        .find(|r| r.index == 0)
        .expect("row 0 is damaged")
        .runs;
    assert_eq!(runs.len(), 1);
    let glyphs = runs.run(0).deco.expect("box-glyph run").glyphs();
    assert_eq!(glyphs.len(), 4, "one descriptor per character");
    assert_eq!(runs.run(0).text, "\u{250C}\u{2500}\u{2500}\u{2510}");
}

#[test]
fn a_box_glyph_carrying_a_combining_mark_draws_as_text() {
    // Four characters over three columns. Were the accented `\u{2500}` still a glyph,
    // its run would carry three records for four characters, and Emacs would draw the
    // last `\u{2500}` from the font with the accent under the image.
    let t = term(2, 8, "\u{2500}\u{300}\u{2500}\u{2500}".as_bytes());
    let runs = t.screen().row(0).unwrap().runs();
    let shapes: Vec<(&str, Option<usize>)> = runs
        .iter()
        .map(|run| (run.text, run.deco.map(Deco::len)))
        .collect();
    assert_eq!(
        shapes,
        [("\u{2500}\u{300}", None), ("\u{2500}\u{2500}", Some(2))]
    );
}

#[test]
fn diagonal_and_stub_bytes_also_produce_glyphs() {
    let mut t = term(2, 10, "\u{2571}\u{2572}\u{2573}\u{2574}".as_bytes());
    let delta = t.drain();
    let runs = &delta
        .rows
        .iter()
        .find(|r| r.index == 0)
        .expect("row 0 is damaged")
        .runs;
    assert_eq!(runs.len(), 1);
    let glyphs = runs.run(0).deco.expect("box-glyph run").glyphs();
    assert_eq!(glyphs.len(), 4);
    assert!(glyphs[0].is_diagonal());
    assert!(
        !glyphs[3].is_diagonal(),
        "the stub is edge-based, not a diagonal"
    );
}

/// The wire format's whole reason to exist: a border row is one decision repeated, and
/// saying so once is what lets `cooked--apply-glyph-deco' look the image spec up once
/// and hang one shared record over the run instead of doing both per character.
#[test]
fn a_run_of_identical_glyphs_packs_into_a_single_run_length_record() {
    let mut t = term(2, 10, "\u{2500}\u{2500}\u{2500}\u{2500}".as_bytes());
    let delta = t.drain();
    let runs = &delta
        .rows
        .iter()
        .find(|r| r.index == 0)
        .expect("row 0 is damaged")
        .runs;
    let packed = runs.run(0).deco.expect("box-glyph run").packed();
    assert_eq!(
        packed.len(),
        4,
        "four identical shapes, one record: {packed:?}"
    );
    // U+2500 ─ is a light horizontal: left and right edges at weight 1, 0x0050.
    assert_eq!(packed, vec![0x50, 0x00, 4, 0], "{packed:?}");
}

/// The other half of the same claim: only *adjacent equal* shapes collapse, so a run
/// whose shapes differ still arrives with every character accounted for. A corner, a
/// stretch of horizontal and the other corner is what a real border row looks like.
#[test]
fn a_run_of_differing_glyphs_packs_one_record_per_distinct_shape() {
    let mut t = term(2, 10, "\u{250C}\u{2500}\u{2500}\u{2510}".as_bytes());
    let delta = t.drain();
    let runs = &delta
        .rows
        .iter()
        .find(|r| r.index == 0)
        .expect("row 0 is damaged")
        .runs;
    let deco = runs.run(0).deco.expect("box-glyph run");
    let packed = deco.packed();
    assert_eq!(packed.len(), 12, "three records: {packed:?}");
    let counts: Vec<u16> = packed
        .chunks_exact(4)
        .map(|record| u16::from_le_bytes([record[2], record[3]]))
        .collect();
    assert_eq!(counts, vec![1, 2, 1]);
    assert_eq!(
        counts.iter().sum::<u16>() as usize,
        deco.glyphs().len(),
        "the counts must cover every character of the run"
    );
    // The middle record is the pair of horizontals, and it carries their bits.
    assert_eq!(
        u16::from_le_bytes([packed[4], packed[5]]),
        deco.glyphs()[1].bits()
    );
}

/// A shade dithers, so its phase depends on the column it lands in and Lisp has to
/// rebuild the `display' value per cell however the wire arrived. That is deliberately
/// *not* said in the record: the shapes are identical, so they collapse like any other
/// repeat, and `cooked--box-shade-p' asks once per record rather than once per cell.
/// Adding a flag bit would have saved one `logand' per run — see [`Deco::packed`].
#[test]
fn a_run_of_shades_collapses_like_any_other_repeat_and_is_not_flagged() {
    let mut t = term(2, 10, "\u{2592}\u{2592}\u{2592}".as_bytes());
    let delta = t.drain();
    let runs = &delta
        .rows
        .iter()
        .find(|r| r.index == 0)
        .expect("row 0 is damaged")
        .runs;
    let deco = runs.run(0).deco.expect("box-glyph run");
    let packed = deco.packed();
    // ▒ U+2592, medium shade: block kind, direction `Shade', density 2 -- 0x8015, the
    // same literal `cooked-box-glyph-bits-match-the-rust-side-encoding' mirrors.
    assert_eq!(packed, vec![0x15, 0x80, 3, 0], "{packed:?}");
    // Nothing in the count field but the count: no bit is reserved to say "dithers".
    assert_eq!(u16::from_le_bytes([packed[2], packed[3]]), 3);
}

/// The alt screen produces no history of its own, but the primary's rows are still
/// history — a resize while a full-screen program is up must not discard them.
#[test]
fn resize_on_the_alt_screen_still_archives_primary_rows() {
    let mut t = term(3, 10, b"one\r\ntwo\r\nthree");
    t.feed(b"\x1b[?1049h");
    t.drain();

    t.resize(2, 10);
    let delta = t.drain();

    assert_eq!(delta.scrolled.len(), 1, "primary history lost during alt");
    assert_eq!(runs_text(&delta.scrolled[0]), "one");
}

/// `clear` and the shell's `C-l` both end up here, and the screen they wipe is
/// transcript Emacs is holding — the grid does not get to drop it on their behalf.
#[test]
fn clearing_the_display_keeps_the_screen_as_history() {
    let mut t = term(4, 10, b"one\r\ntwo");
    t.drain();

    t.feed(b"\x1b[2J");
    let delta = t.drain();

    assert_eq!(delta.scrolled.len(), 2);
    assert_eq!(runs_text(&delta.scrolled[0]), "one");
    assert_eq!(runs_text(&delta.scrolled[1]), "two");
    assert_eq!(text(&t, 0), "");
}

#[test]
fn clearing_the_alt_screen_archives_nothing() {
    let mut t = term(4, 10, b"\x1b[?1049hframe");
    t.drain();

    t.feed(b"\x1b[2J");

    assert!(
        t.drain().scrolled.is_empty(),
        "the alt screen has no history to keep"
    );
}

#[test]
fn a_partial_erase_is_not_a_finished_screen() {
    let mut t = term(4, 10, b"one\r\ntwo");
    t.drain();

    t.feed(b"\x1b[J");

    assert!(
        t.drain().scrolled.is_empty(),
        "a partial erase is a redraw, not a screen being finished with"
    );
}

/// The primary is rewrapped even while a full-screen program is up, because its rows
/// are the transcript that program will hand back on exit.
#[test]
fn narrowing_mid_alt_rewraps_the_primary_underneath() {
    let mut t = term(4, 10, b"abcdefghijklmno");
    t.feed(b"\x1b[?1049h");
    t.drain();

    t.resize(4, 5);
    t.feed(b"\x1b[?1049l");
    let delta = t.drain();

    assert!(delta.scrolled.is_empty());
    assert_eq!(text(&t, 0), "abcde");
    assert_eq!(text(&t, 1), "fghij");
    assert_eq!(text(&t, 2), "klmno");
}

#[test]
fn backlog_counts_pending_events_as_well_as_scrollback() {
    let mut t = term(4, 10, b"");
    assert_eq!(t.backlog(), 0);

    t.feed(b"\x1b]0;a\x07\x1b]0;b\x07\x1b]0;c\x07");
    assert_eq!(
        t.backlog(),
        3,
        "OSC-only output scrolls nothing, so a scrollback-only measure misses it"
    );

    t.drain();
    assert_eq!(t.backlog(), 0, "draining clears the measure");
}

/// The batched print path must be indistinguishable from the per-character one.
///
/// The reference side sets `force_per_character_print`, which is the only way to make a
/// `Term` take the old path. Feeding a byte at a time does *not* do it -- `print_str`
/// still runs, with runs of length one -- so a test built that way compares the fast path
/// against itself; the first version of this test did exactly that and survived
/// deliberately breaking `write_run` twice.
///
/// The cases land on the seams: the last column, where `write_run` stops one short so the
/// deferred wrap is decided in one place; wide characters and combining marks, which it
/// declines; DEL, which is not a C0 control and so reaches `print_str` while having no
/// width; insert mode and a designated set or single shift, which disable it; and a scroll, so eviction is
/// compared too.
#[test]
fn batched_and_per_character_printing_agree() {
    let cases: &[(&str, &[u8])] = &[
        ("plain text", b"hello world"),
        ("exactly one row", b"0123456789"),
        ("one past the row", b"0123456789x"),
        ("two rows and a bit", b"0123456789abcdefghijQR"),
        ("wrap then newline", b"0123456789abc\r\ndef"),
        ("wide characters", "ab\u{6f22}\u{5b57}cd".as_bytes()),
        (
            "wide character across the margin",
            "012345678\u{6f22}z".as_bytes(),
        ),
        ("combining mark", "abe\u{301}f".as_bytes()),
        ("DEL is not a control", b"ab\x7fcd"),
        ("styled runs", b"a\x1b[31mred\x1b[0mb"),
        ("insert mode", b"abcdef\x1b[4D\x1b[4hXY"),
        ("dec graphics", b"\x1b(0qqq\x1b(Babc"),
        ("graphics shifted out of G1", b"a\x1b)0\x0eqqq\x0fqqq"),
        ("single shift spent on a run", b"\x1b*0\x1bNqqq"),
        (
            "hyperlink attaches per cell",
            b"a\x1b]8;;http://x\x07bcd\x1b]8;;\x07e",
        ),
        ("tabs and returns", b"ab\tcd\rZ"),
        (
            "scrolls off the top",
            b"aaa\r\nbbb\r\nccc\r\nddd\r\neee\r\nfff",
        ),
        ("REP after a run", b"abc\x1b[4b"),
        ("erase then refill", b"0123456789\x1b[H\x1b[2Jxy"),
    ];

    // The text on the grid, the runs it reduces to (which carry style, so a pen dropped
    // mid-run would show), the cursor, and what left for scrollback.
    /// Everything the two printing paths could disagree about.
    type Snapshot = (Vec<String>, Vec<Runs>, (usize, usize), Vec<String>);

    fn rendered(t: &mut Term) -> Snapshot {
        let scrolled = t
            .drain()
            .scrolled
            .iter()
            .map(|line| line.runs.text().to_owned())
            .collect();
        let screen = (0..4)
            .map(|i| {
                t.screen()
                    .row(i)
                    .map(|row| row.to_text())
                    .unwrap_or_default()
            })
            .collect();
        let runs = (0..4)
            .map(|i| t.screen().row(i).map(|row| row.runs()).unwrap_or_default())
            .collect();
        let cursor = (t.screen().cursor().row, t.screen().cursor().col);
        (screen, runs, cursor, scrolled)
    }

    for (name, input) in cases {
        let mut batched = Term::new(4, 10);
        batched.feed(input);

        let mut reference = Term::new(4, 10);
        reference.force_per_character_print();
        reference.feed(input);

        assert_eq!(
            rendered(&mut batched),
            rendered(&mut reference),
            "batched and per-character printing disagree on {name}"
        );
    }
}

/// The reader thread wakes Emacs on what [`Term::feed`] reports, so a read that changed
/// nothing must say so -- and a cursor move with no damage must not, which is the half
/// that is easy to get wrong and the half the flicker was made of.
#[test]
fn a_read_that_changes_nothing_reports_nothing() {
    let mut t = Term::new(4, 20);
    assert!(t.feed(b"hi"), "printed text is a change");
    t.drain();

    assert!(t.feed(b"\x1b[2;3H"), "a cursor move is a change on its own");
    t.drain();

    // A pen change: real, and invisible until something is printed with it.
    assert!(!t.feed(b"\x1b[1;31m"));
    // The middle of a kitty transfer, which is where a gif player spends nearly all of
    // its bytes: an APC string that will not touch the grid until its terminator.
    assert!(!t.feed(b"\x1b_Ga=T,f=100,i=1;iVBORw0KGgoAAAANSUhEU"));
    assert!(!t.feed(b"gAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4"));

    let delta = t.drain();
    assert!(delta.rows.is_empty(), "nothing was drawn on");
    assert!(delta.events.is_empty() && delta.images.is_empty());
    assert!(delta.scrolled.is_empty() && delta.marks.is_empty());
}

/// Emacs finds the cursor by counting characters along its row, which is not its column
/// once a wide character or a combining mark comes before it.
#[test]
fn the_drain_counts_the_cursor_in_characters_of_its_row() {
    // On `本`, which is the second character and columns 2 and 3.
    let mut t = term(2, 20, "\u{65e5}\u{672c}X\x1b[1;3H".as_bytes());
    let delta = t.drain();
    assert_eq!((delta.levels.cursor.col, delta.cursor_chars), (2, 1));
    // On its second column the cursor is still on `本`.
    t.feed(b"\x1b[1;4H");
    assert_eq!(t.drain().cursor_chars, 1);
    // Past a combining mark, which is a character of its own in the buffer.
    let mut t = term(2, 20, "e\u{301}x\x1b[1;2H".as_bytes());
    assert_eq!(t.drain().cursor_chars, 2);
}
