//! OSC 133 semantic marks, their anchors, and clearing to the prompt.

use super::*;

#[test]
fn osc_133_becomes_semantic_events() {
    let mut t = term(
        4,
        20,
        b"\x1b]133;A\x07$ \x1b]133;B\x07ls\x1b]133;C\x07out\x1b]133;D;3\x07",
    );
    let events = t.drain().events;
    let at = anchor;
    assert_eq!(
        events,
        vec![
            // Anchored where each mark actually fell on the one row this writes:
            // column 0, then after "$ ", then after "ls", then after "out".
            // The ids are the order the marks were parsed in, which is what pairs
            // each one back up with the marker Emacs makes for it.
            Event::Mark(Mark::PromptStart, at(0, 0), MarkId::from_index(0)),
            Event::Mark(Mark::PromptEnd, at(0, 2), MarkId::from_index(1)),
            Event::Mark(Mark::CommandStart(None), at(0, 4), MarkId::from_index(2)),
            Event::Mark(Mark::CommandEnd(Some(3)), at(0, 7), MarkId::from_index(3)),
        ]
    );
}

/// PS2. The mark the shell puts on a continuation prompt has to reach Emacs as
/// something other than a fresh prompt, or the command record for a multi-line
/// construct begins at its last line instead of at the prompt it was typed at.
#[test]
fn osc_133_marks_a_continuation_prompt() {
    let mut t = term(4, 20, b"\x1b]133;A\x07> \x1b]133;A;k=s\x07\x1b]133;B\x07");
    let events = t.drain().events;
    let at = anchor;
    assert_eq!(
        events,
        vec![
            Event::Mark(Mark::PromptStart, at(0, 0), MarkId::from_index(0)),
            Event::Mark(Mark::PromptContinuation, at(0, 2), MarkId::from_index(1)),
            Event::Mark(Mark::PromptEnd, at(0, 2), MarkId::from_index(2)),
        ]
    );
}

/// The proposal hangs `k=` off `P` and calls `A` shorthand for `P;k=i`, and Ghostty
/// emits `P` from its prompt strings to dodge `A`'s implied fresh line. cooked has no
/// fresh-line behaviour, so `P` would be the same mark under a second name -- and
/// nothing that sends it can reach this parser, since the shipped snippets are gated on
/// `TERM_PROGRAM=cooked` and write `A`, as does a fish 4 marking its own prompts. So a
/// `P` is a kind this parser has never heard of, and is dropped whole like any other:
/// no event, no mark id spent, and in particular no prompt start, which is the one
/// outcome that would move state on a mark nobody here meant to send.
#[test]
fn osc_133_ignores_the_other_spelling_of_the_prompt_mark() {
    let mut t = term(4, 20, b"\x1b]133;P;k=s\x07\x1b]133;P\x07\x1b]133;A\x07");
    assert_eq!(
        t.drain().events,
        vec![Event::Mark(
            Mark::PromptStart,
            anchor(0, 0),
            MarkId::from_index(0)
        )]
    );
}

/// `k=r` is the prompt drawn to the *right* of the input line, not a continuation. No `B`
/// follows one, so reading it as a `PS2` would leave Emacs in `prompt` for the rest of the
/// session with the input line gone.
///
/// A kind nobody here has heard of joins it: the safe answer for an unknown mark is to
/// move no state, and both of the other answers move some.
#[test]
fn osc_133_drops_a_prompt_kind_that_is_neither_initial_nor_a_continuation() {
    for kind in [&b"r"[..], b"z", b"unheard-of"] {
        let mut t = Term::new(4, 20);
        t.feed(b"\x1b]133;A\x07");
        t.feed(format!("\x1b]133;A;k={}\x07", String::from_utf8_lossy(kind)).as_bytes());
        assert_eq!(
            t.drain().events,
            vec![Event::Mark(
                Mark::PromptStart,
                anchor(0, 0),
                MarkId::from_index(0)
            )],
            "k={} should have been dropped whole",
            String::from_utf8_lossy(kind)
        );
    }
}

/// `c` is the proposal's spelling of the same thing kitty calls `s`.
#[test]
fn osc_133_reads_both_spellings_of_a_continuation() {
    let mut t = term(4, 20, b"\x1b]133;A;k=c\x07\x1b]133;A;k=s\x07");
    let at = anchor;
    assert_eq!(
        t.drain().events,
        vec![
            Event::Mark(Mark::PromptContinuation, at(0, 0), MarkId::from_index(0)),
            Event::Mark(Mark::PromptContinuation, at(0, 0), MarkId::from_index(1)),
        ]
    );
}

/// The proposal gives the kind a default of `i`, so `k=` with nothing after it is an
/// emitter saying nothing rather than an emitter naming a kind we have never heard of.
#[test]
fn osc_133_treats_an_empty_prompt_kind_as_initial() {
    let mut t = term(4, 20, b"\x1b]133;A;k=\x07");
    assert_eq!(
        t.drain().events,
        vec![Event::Mark(
            Mark::PromptStart,
            anchor(0, 0),
            MarkId::from_index(0)
        )]
    );
}

/// The options real terminals actually send, none of which is a `k=`: kitty's
/// `click_events=` (which is what fish 4 emits), Ghostty's `redraw=` and `cl=`, and
/// ble.sh's `aid=`. Every one of them is an ordinary prompt start.
#[test]
fn osc_133_ignores_the_options_that_are_not_a_prompt_kind() {
    for opts in [
        &b"click_events=1"[..],
        b"redraw=last;cl=line;aid=123",
        b"cl=line",
    ] {
        let mut t = Term::new(4, 20);
        t.feed(&[b"\x1b]133;A;", opts, b"\x07"].concat());
        assert_eq!(
            t.drain().events,
            vec![Event::Mark(
                Mark::PromptStart,
                anchor(0, 0),
                MarkId::from_index(0)
            )],
            "{} should have been an initial prompt",
            String::from_utf8_lossy(opts)
        );
    }
}

/// The kind field is matched whole. Reading only its first byte had `Dfoo` agreeing to
/// be a `D`, which is the parser inventing consent from a sender that meant something
/// else. The examples are spelled with kinds this parser *does* accept, because those
/// are the ones a prefix match would wrongly swallow -- a suffix on a kind nobody reads
/// is dropped either way and would prove nothing.
#[test]
fn osc_133_matches_the_kind_field_exactly() {
    let mut t = term(4, 20, b"\x1b]133;Dfoo\x07\x1b]133;Az\x07\x1b]133;\x07");
    assert!(t.drain().events.is_empty());
}

/// `clear_to_prompt` cuts at the prompt the construct began at, so a continuation
/// must leave that anchor alone -- the whole reason `k=` is parsed rather than dropped.
#[test]
fn a_continuation_prompt_does_not_move_the_clear_anchor() {
    let mut t = Term::new(6, 20);
    t.feed(b"noise\r\n\x1b]133;A\x07$ for x in 1 2; do\r\n");
    t.feed(b"\x1b]133;A;k=s\x07> echo $x\r\n");
    t.drain();
    // Two rows kept: the prompt row and the continuation under it. Had the
    // continuation moved the anchor, only the second would have survived.
    assert_eq!(t.clear_to_prompt(), 1);
    assert_eq!(text(&t, 0), "$ for x in 1 2; do");
}

#[test]
fn osc_133_d_without_a_status() {
    let mut t = term(4, 20, b"\x1b]133;D\x07");
    assert_eq!(
        t.drain().events,
        vec![Event::Mark(
            Mark::CommandEnd(None),
            anchor(0, 0),
            MarkId::from_index(0)
        )]
    );
}

#[test]
fn osc_133_stays_typed() {
    let mut t = term(4, 20, b"\x1b]133;A\x07");
    assert_eq!(
        t.drain().events,
        vec![Event::Mark(
            Mark::PromptStart,
            anchor(0, 0),
            MarkId::from_index(0)
        )]
    );
}

/// The bug anchors exist for: two commands inside one drain must not collapse onto
/// the end-of-drain cursor, which is where the *second* one ended.
#[test]
fn marks_in_one_drain_keep_their_own_positions() {
    let mut t = term(
        8,
        20,
        b"\x1b]133;C\x07one\r\n\x1b]133;D;0\x07\x1b]133;C\x07two\r\n\x1b]133;D;0\x07",
    );
    let starts: Vec<Anchor<Chars>> = t
        .drain()
        .events
        .into_iter()
        .filter_map(|e| match e {
            Event::Mark(Mark::CommandStart(_), at, _) => Some(at),
            _ => None,
        })
        .collect();
    assert_eq!(starts, vec![anchor(0, 0), anchor(1, 0)]);
}

/// The exception in `Row::retire`, and the whole reason marks can be moved at all:
/// `OSC 133;A` arrives before the shell prints its prompt, so the very first
/// character of that prompt is written over the cell the mark landed on.
#[test]
fn a_mark_survives_the_prompt_printed_over_it() {
    let t = term(4, 20, b"\x1b]133;A\x07$ ");
    let marks: Vec<_> = t.screen().row(0).unwrap().marks().collect();
    assert_eq!(
        marks,
        vec![(Cols::ZERO, MarkId::from_index(0))],
        "the mark is still on column 0"
    );
    assert_eq!(text(&t, 0), "$", "and the prompt is still drawn");
}

/// The reported bug: a resize rewraps the grid, Emacs rebuilds every live row from
/// it, and the buffer markers it took from the original anchors are left pointing at
/// text that has moved. The mark comes through the rewrap on the cell it went in on,
/// so the drain can say where that cell is now.
#[test]
fn a_rewrap_reports_where_each_mark_moved_to() {
    // Twelve cells of one logical line at ten columns: row 0 wrapped, row 1 holding
    // "ab", and the mark on the cell after them.
    let mut t = term(4, 10, b"0123456789ab\x1b]133;A\x07");
    t.drain();
    assert!(
        t.screen()
            .row(1)
            .unwrap()
            .marks()
            .any(|(col, _)| col == Cols::new(2)),
        "the mark starts on row 1, column 2"
    );

    t.resize(4, 7);
    let delta = t.drain();
    // Offset 12 into the line, re-chunked at seven columns: row 1, column 5.
    assert_eq!(delta.marks, vec![(MarkId::from_index(0), anchor(1, 5))]);
}

/// The other half of the same drain: a rewrap narrow enough pushes rows off the top,
/// and a mark on one of them is in text Emacs is about to *insert* rather than on a
/// row it is about to rewrite. Both spellings are what `anchor_to_lisp` exists for.
#[test]
fn a_mark_evicted_by_a_rewrap_is_reported_in_the_batch() {
    // Two rows of one logical line at ten columns, with the mark at the top of it.
    // Re-chunked at four columns that line needs five rows, and the grid has four.
    let mut t = term(4, 10, b"\x1b]133;A\x070123456789abcdefghij");
    t.drain();
    t.resize(4, 4);
    let delta = t.drain();
    let (_, at) = delta
        .marks
        .iter()
        .find(|(id, _)| *id == MarkId::from_index(0))
        .expect("the mark is still accounted for");
    assert!(
        at.row < delta.scrolled_base + delta.scrolled.len(),
        "its row is in this drain's scrollback batch, not on the grid: {at:?}"
    );
}

/// A scroll re-anchors too, and the difference from a rewrap is only one of degree.
/// Emacs rebuilds its live text around every row that leaves -- the row goes in above
/// as scrollback while the rows below move up a slot -- and the two renderings of that
/// row are not the same length, because `cooked-rejoin-wrapped-lines' withholds the
/// newline from a continuation row. One character per wrapped row that leaves is
/// enough for a long-running command's marker to walk off its own prompt.
#[test]
fn a_scroll_reports_the_marks_it_moved() {
    let mut t = term(3, 10, b"\x1b]133;A\x07one\r\n");
    t.drain();
    t.feed(b"two\r\nthree\r\nfour\r\n");
    let delta = t.drain();
    let (id, at) = delta
        .marks
        .first()
        .copied()
        .expect("the mark is accounted for");
    assert_eq!(id, MarkId::from_index(0));
    assert!(
        at.row < delta.scrolled_base + delta.scrolled.len(),
        "it left with its row, so it is spelled into the batch: {at:?}"
    );
}

/// And a drain that moved nothing says nothing, which is what keeps this off the
/// ordinary path: a screen with room left scrolls no rows and re-anchors no marks.
#[test]
fn a_drain_that_moves_nothing_reports_no_marks() {
    let mut t = term(8, 10, b"\x1b]133;A\x07one\r\n");
    t.drain();
    t.feed(b"two\r\n");
    assert!(t.drain().marks.is_empty());
}

/// Leaving the alternate screen re-sends every primary row over text the alternate
/// frame had replaced, so the markers Emacs held there have collapsed and every mark
/// on the grid is reported, just as for a resize. Each way in is checked, since 47
/// and 1047 switch screens without the cursor save that 1049 adds.
#[test]
fn leaving_the_alternate_screen_reports_every_mark() {
    for mode in ["47", "1047", "1049"] {
        let mut t = term(4, 10, b"\x1b]133;A\x07one\r\n\x1b]133;A\x07two\r\n");
        t.drain();
        t.feed(format!("\x1b[?{mode}hALT").as_bytes());
        t.drain();
        t.feed(format!("\x1b[?{mode}l").as_bytes());
        let marks = t.drain().marks;
        assert_eq!(
            marks,
            vec![
                (MarkId::from_index(0), anchor(0, 0)),
                (MarkId::from_index(1), anchor(1, 0)),
            ],
            "mode {mode}"
        );
    }
}

/// A mark sent while the alternate screen is up is dropped, whichever of the three ways
/// in put it there, and the primary screen's marks are untouched by it. A shell inside
/// tmux is the case: tmux draws on the alternate screen and scrolls it with no
/// scrollback, so the mark's row would name output a moment later.
#[test]
fn a_mark_on_the_alternate_screen_is_dropped() {
    for mode in ["47", "1047", "1049"] {
        let mut t = term(4, 10, b"\x1b]133;A\x07one\r\n");
        t.drain();
        t.feed(
            format!(
                "\x1b[?{mode}h\x1b]133;A\x07$ \x1b]133;B\x07\x1b]133;C\x07\r\n\x1b]133;D;0\x07"
            )
            .as_bytes(),
        );
        let delta = t.drain();
        assert!(
            !delta.events.iter().any(|e| matches!(e, Event::Mark(..))),
            "mode {mode}: {:?}",
            delta.events
        );
        t.feed(format!("\x1b[?{mode}l\x1b]133;A\x07").as_bytes());
        // Back on the primary screen, the mark from before the switch is where it was,
        // and the next one takes the next id, the dropped ones having taken none.
        assert_eq!(
            t.drain().marks,
            vec![
                (MarkId::from_index(0), anchor(0, 0)),
                (MarkId::from_index(1), anchor(1, 0)),
            ],
            "mode {mode}"
        );
    }
}

/// An anchor outlives the row it was taken from: once the marked row has scrolled
/// away, its absolute row is below the base of the batch still on the grid.
#[test]
fn an_anchor_survives_the_row_scrolling_off() {
    let mut t = term(3, 20, b"\x1b]133;C\x07start\r\n");
    t.feed(b"a\r\nb\r\nc\r\nd\r\n");
    let delta = t.drain();
    let Some(Event::Mark(Mark::CommandStart(_), at, _)) = delta.events.first() else {
        panic!("no command-start: {:?}", delta.events);
    };
    assert_eq!(at.row, 0, "the mark fell on the first row written");
    assert!(
        at.row < delta.scrolled_base + delta.scrolled.len(),
        "the marked row is in this batch of scrollback, not on the grid"
    );
    assert_eq!(delta.scrolled_base, 0, "nothing scrolled before this drain");
}

#[test]
fn clearing_to_the_prompt_keeps_the_prompt_and_drops_what_is_above_it() {
    let mut t = term(4, 8, b"one\r\ntwo\r\n\x1b]133;A\x1b\\$ ls");
    t.drain();
    assert_eq!(t.clear_to_prompt(), 2);
    assert_eq!(text(&t, 0), "$ ls");
    assert_eq!(text(&t, 1), "");
    assert_eq!(
        t.screen().cursor().row,
        0,
        "the cursor rides up with its row"
    );
}

#[test]
fn clearing_to_the_prompt_falls_back_to_the_cursor_row() {
    // No OSC 133 to go on: whatever the child is on now is the line being looked at.
    let mut t = term(4, 8, b"one\r\ntwo\r\nthree");
    t.drain();
    assert_eq!(t.clear_to_prompt(), 2);
    assert_eq!(text(&t, 0), "three");
}

#[test]
fn clearing_to_the_prompt_twice_still_knows_where_the_prompt_is() {
    // Rows removed this way are discarded rather than archived, so `evicted_total` does
    // not move and nothing outside the grid records the removal: it is the mark riding
    // up with its own row that keeps the second call from cutting at the cursor and
    // eating the prompt.
    let mut t = term(4, 8, b"one\r\ntwo\r\n\x1b]133;A\x1b\\$ ls");
    t.drain();
    t.clear_to_prompt();
    t.feed(b"\r\nout");
    t.drain();
    assert_eq!(t.clear_to_prompt(), 0, "the prompt is already on row 0");
    assert_eq!(text(&t, 0), "$ ls");
    assert_eq!(text(&t, 1), "out");
}

#[test]
fn removing_rows_brings_the_prompt_mark_down_with_them() {
    // `cooked-delete-output' removes a finished command's rows, which sit above the
    // prompt. The rows below the cut slide up carrying their attachments, the prompt's
    // mark among them, which is the whole of the repair: a position recorded elsewhere
    // would name a row past the cursor, fail `clear_to_prompt's own sanity filter, and
    // silently fall back to cutting at the cursor -- eating the first line of a
    // two-line prompt.
    let mut t = term(6, 8, b"out1\r\nout2\r\n\x1b]133;A\x1b\\user\r\n$ ");
    t.drain();
    // The two output rows above the prompt.
    t.remove_rows(0, 2);
    assert_eq!(text(&t, 0), "user");
    assert_eq!(text(&t, 1), "$");
    // The prompt is two rows tall and now starts at row 0, so there is nothing above
    // it left to clear. Without the rebase this cuts one row, taking `user' with it.
    assert_eq!(t.clear_to_prompt(), 0);
    assert_eq!(text(&t, 0), "user", "the prompt's first line must survive");
    assert_eq!(text(&t, 1), "$");
}

#[test]
fn removing_the_prompts_own_row_falls_back_to_the_cursor() {
    let mut t = term(6, 8, b"out\r\n\x1b]133;A\x1b\\$ ls");
    t.drain();
    // Takes the output row and the prompt row with it.
    t.remove_rows(0, 2);
    // The prompt's mark went with the row it was on, so there is no live prompt left to
    // find and the cursor stands in -- and `Screen::remove_rows' has clamped that to the
    // row which closed the gap, so there is nothing above it to clear.
    assert_eq!(t.clear_to_prompt(), 0);
    assert_eq!(text(&t, 0), "", "both rows went, prompt included");
}

/// The other path a recorded row would have had to be corrected on, and never was: `CSI
/// L` pushes every row below the cursor down without archiving anything, so the prompt
/// changes rows while nothing outside the grid hears about it. Reading the row off the
/// mark costs no correction here at all -- `Screen::insert_lines` moves the rows, and a
/// row's attachments are part of the row.
#[test]
fn inserting_lines_above_the_prompt_carries_its_mark_down() {
    let mut t = term(6, 8, b"out\r\n\x1b]133;A\x1b\\$ ls");
    t.drain();
    // Two blank lines at the top, then the cursor back below the prompt, where a shell
    // redrawing this way would leave it.
    t.feed(b"\x1b[H\x1b[2L\x1b[5;1H");
    t.drain();
    assert_eq!(text(&t, 3), "$ ls", "the prompt really is two rows lower");
    assert_eq!(
        t.clear_to_prompt(),
        3,
        "the blank rows and the output row above the prompt all go"
    );
    assert_eq!(text(&t, 0), "$ ls");
}

#[test]
fn removing_rows_below_the_prompt_leaves_the_mark_where_it_is() {
    let mut t = term(6, 8, b"\x1b]133;A\x1b\\$ ls\r\nout1\r\nout2\r\ntail");
    t.drain();
    t.remove_rows(2, 1);
    assert_eq!(text(&t, 0), "$ ls");
    assert_eq!(text(&t, 1), "out1");
    assert_eq!(text(&t, 2), "tail");
    assert_eq!(t.clear_to_prompt(), 0, "the prompt is still on row 0");
}

#[test]
fn removing_alt_screen_rows_does_not_move_the_primarys_prompt_mark() {
    let mut t = term(6, 8, b"out\r\n\x1b]133;A\x1b\\$ ls");
    t.drain();
    t.feed(b"\x1b[?1049h\x1b[1;1Haaa\r\nbbb");
    t.drain();
    t.remove_rows(0, 1);
    t.feed(b"\x1b[?1049l");
    t.drain();
    // The primary's rows never moved, so the mark must still name row 1.
    assert_eq!(t.clear_to_prompt(), 1);
    assert_eq!(text(&t, 0), "$ ls");
}

#[test]
fn clearing_to_the_prompt_leaves_the_alt_screen_alone() {
    let mut t = term(3, 8, b"aaa");
    t.feed(b"\x1b[?1049h\x1b[2;1Hbbb");
    t.drain();
    assert_eq!(t.clear_to_prompt(), 0);
    assert_eq!(text(&t, 1), "bbb");
}

/// Emacs turns an anchor into a buffer position by counting characters along the row,
/// so the drain counts them for it: a prompt of `日本 ` ends at column 5, and the mark
/// after it is 3 characters in. Counted as columns it lands two characters past the
/// end of the prompt.
#[test]
fn a_mark_after_a_wide_character_is_anchored_by_characters() {
    let mut t = term(4, 20, "\u{65e5}\u{672c} \x1b]133;B\x07".as_bytes());
    let events = t.drain().events;
    assert_eq!(
        events,
        vec![Event::Mark(
            Mark::PromptEnd,
            anchor(0, 3),
            MarkId::from_index(0)
        )]
    );
}

/// The same count for a mark whose row scrolls away in the drain it was made in. The
/// row's cells are gone by the time the drain is taken, so the count is the one made
/// as the row departed, and the event and the relocation agree on it.
#[test]
fn a_mark_scrolled_away_after_a_wide_character_is_anchored_by_characters() {
    let mut t = term(
        2,
        20,
        "\u{65e5}\u{672c} \x1b]133;B\x07\r\n\r\n\r\n".as_bytes(),
    );
    let delta = t.drain();
    let anchor = anchor(0, 3);
    assert!(anchor.row < delta.scrolled_base + delta.scrolled.len());
    assert_eq!(
        delta.events,
        vec![Event::Mark(Mark::PromptEnd, anchor, MarkId::from_index(0))]
    );
    assert_eq!(delta.marks, vec![(MarkId::from_index(0), anchor)]);
}

/// The same agreement when there are enough marks and events for the drain to index its
/// relocations rather than scan them; see `MarkIndex`.
///
/// A flood of prompts is the shape that made scanning quadratic, and the two ways of
/// looking a mark up must give the same answer or a marker lands on the wrong line.
#[test]
fn many_marks_scrolled_away_are_anchored_the_same_way_as_a_few() {
    let mut input = Vec::new();
    for _ in 0..20 {
        input.extend_from_slice("\u{65e5}\u{672c} \x1b]133;B\x07\r\n".as_bytes());
    }
    let mut t = term(2, 20, &input);
    let delta = t.drain();
    let marks: Vec<(MarkId, Anchor<Chars>)> = delta.marks.clone();
    assert!(
        marks.len() * delta.events.len() > 256,
        "this must be big enough to take the indexed path: {} marks, {} events",
        marks.len(),
        delta.events.len()
    );
    let anchors: Vec<(MarkId, Anchor<Chars>)> = delta
        .events
        .iter()
        .map(|event| match event {
            Event::Mark(Mark::PromptEnd, at, id) => (*id, *at),
            other => panic!("only prompt ends were written: {other:?}"),
        })
        .collect();
    assert_eq!(anchors.len(), 20);
    // Every event carries the relocation of its own mark, and each is three characters
    // along its row rather than the five columns the wide prompt occupies.
    assert_eq!(anchors, marks);
    assert!(
        anchors.iter().all(|(_, at)| at.col == Chars::new(3)),
        "every mark is three characters in: {anchors:?}"
    );
}

// A command's input modes, handed over at `C` and taken back at `D`.

/// Every mode [`Handover`] covers, as the `h` that sets it, with the DECRQM number that
/// reads it back. The keyboard pair has no DECRQM number and is read through `keys`.
const HANDED_OVER: &[(&str, u16)] = &[
    ("\x1b[?1003h", 1003),
    ("\x1b[?1006h", 1006),
    ("\x1b[?1004h", 1004),
    ("\x1b[?2031h", 2031),
    ("\x1b[?2048h", 2048),
    ("\x1b[?1007h", 1007),
    ("\x1b[?1h", 1),
    ("\x1b=", 66),
];

fn mode_set(t: &Term, number: u16) -> bool {
    t.state.dec_mode_report(number) == crate::emu::term::modes::ModeReport::Set
}

/// The crash the handover exists for: a command sets every input mode, pushes kitty
/// flags on the primary screen, and dies without undoing any of it. The shell's `D`
/// puts all of it back, and tells Emacs the mouse is off.
#[test]
fn a_dead_command_leaves_the_shell_the_input_modes_it_handed_over() {
    let mut t = term(4, 40, b"\x1b]133;C\x07");
    for (set, _) in HANDED_OVER {
        t.feed(set.as_bytes());
    }
    t.feed(b"\x1b[>4;2m\x1b[>1u");
    for (_, number) in HANDED_OVER {
        assert!(mode_set(&t, *number), "{number} took");
    }
    assert!(matches!(t.keys(), KeyEncoding::Kitty(_)));
    t.drain();

    t.feed(b"\x1b]133;D;139\x07");
    for (_, number) in HANDED_OVER {
        assert!(!mode_set(&t, *number), "{number} is the shell's again");
    }
    assert_eq!(
        t.keys(),
        KeyEncoding::Legacy,
        "kitty flags and modifyOtherKeys both"
    );
    assert_eq!(t.mouse(), Mouse::default());
    let events = t.drain().events;
    assert!(
        events.contains(&Event::Mouse(Mouse::default())),
        "{events:?}"
    );
}

/// Restored, not reset: a mode the shell had on when it ran the command is on again
/// afterwards even though the command turned it off, and a `D` with no `C` before it
/// touches nothing.
#[test]
fn the_shell_gets_back_its_own_modes_and_a_bare_d_moves_none() {
    let mut t = term(4, 40, b"\x1b[?1004h\x1b[>1u\x1b]133;D\x07");
    assert!(mode_set(&t, 1004), "zsh's first prompt sends a D with no C");
    assert_eq!(t.kitty_flags().bits(), 1);

    t.feed(b"\x1b]133;C\x07\x1b[?1004l\x1b[<u\x1b[?2048h\x1b]133;D\x07");
    assert!(mode_set(&t, 1004));
    assert_eq!(t.kitty_flags().bits(), 1);
    assert!(!mode_set(&t, 2048));

    t.feed(b"\x1b[?2048h\x1b]133;D\x07");
    assert!(
        mode_set(&t, 2048),
        "the handover is spent by the D that used it"
    );
}

/// A command that hid the cursor, changed its shape and reversed the screen, and died,
/// leaves the prompt drawn as the shell had it at `C`: the cursor visible, in the bar the
/// shell had set for itself, blinking as it asked, on a screen the right way round.
#[test]
fn a_dead_command_leaves_the_prompt_the_cursor_and_screen_it_handed_over() {
    let mut t = term(4, 40, b"\x1b[5 q\x1b]133;C\x07");
    t.drain();
    t.feed(b"\x1b[?25l\x1b[2 q\x1b[?5h");
    let levels = t.drain().levels;
    assert!(!levels.cursor_visible && levels.reverse_screen);
    assert_eq!(levels.cursor_shape, CursorShape::Block);

    t.feed(b"\x1b]133;D;130\x07");
    let levels = t.drain().levels;
    assert!(levels.cursor_visible, "DECTCEM");
    assert_eq!(levels.cursor_shape, CursorShape::Bar, "DECSCUSR");
    assert!(t.state.modes.cursor_blink, "5 q is the blinking bar");
    assert!(!levels.reverse_screen, "DECSCNM");
    assert_eq!(
        levels.reverse_screen_toggles, 2,
        "the restore counts as a change of DECSCNM"
    );
}

/// bash, zsh and fish each set bracketed paste before the prompt that carries `A`, so
/// neither mark may touch it. The sequence is bash 5.3's, as recorded on a pty.
#[test]
fn bracketed_paste_is_left_to_the_shell() {
    let mut t = term(
        4,
        40,
        b"\x1b[?2004h\x1b]133;A\x07$ \x1b]133;B\x07\x1b[?2004l\r\n\x1b]133;C\x07\
          \x1b[?2004h\x1b]133;D;1\x07",
    );
    assert!(
        t.bracketed_paste(),
        "a command's stale set is the shell's to clear"
    );
    t.feed(b"\x1b[?2004h\x1b]133;A\x07$ ");
    assert!(t.bracketed_paste());
}

/// A program that leaves the alternate screen without popping its kitty flags hands them
/// to the next one that does not push its own. After a `D` nothing is alive there.
#[test]
fn a_command_end_empties_the_alternate_kitty_stack() {
    let mut t = term(4, 40, b"\x1b]133;C\x07\x1b[?1049h\x1b[>5u\x1b[?1049l");
    t.feed(b"\x1b]133;D\x07\x1b]133;C\x07\x1b[?1049h");
    assert_eq!(t.keys(), KeyEncoding::Legacy);
}

/// tmux passes its panes' marks through while it holds the mouse and the size reports
/// on the alternate screen. A `C` or `D` there is not the outer shell's and moves nothing.
#[test]
fn marks_on_the_alternate_screen_leave_the_modes_alone() {
    let mut t = term(
        4,
        40,
        b"\x1b]133;C\x07\x1b[?1049h\x1b[?1002h\x1b[?2048h\x1b[>1u",
    );
    t.feed(b"\x1b]133;D;0\x07\x1b]133;A\x07$ \x1b]133;C\x07\x1b]133;D;0\x07");
    assert!(mode_set(&t, 1002));
    assert!(mode_set(&t, 2048));
    assert_eq!(t.kitty_flags().bits(), 1);

    // tmux exits, and the outer shell's `D` still has the handover from before it.
    t.feed(b"\x1b[?1049l\x1b]133;D;0\x07");
    assert!(!mode_set(&t, 1002));
    assert!(!mode_set(&t, 2048));
}

/// Found by the review3 split-brain probe (`cooked--clear-to-prompt` vs
/// `cooked--prompt-start`), back when `State::prompt_start` was an absolute row snapshot
/// taken as `133;A` was parsed. It was corrected in two places only: `State::remove_rows`
/// slid it down when rows above it were explicitly deleted, and `State::archive` left it
/// alone while advancing `evicted_total`, which is what the row was read relative to. A
/// rewrap went through neither -- [`Screen::reflow`] rebuilds the live grid from the
/// logical lines, and [`State::resize`] archives only the rows that overflowed off the
/// top -- so a rewrap that changed how many rows the content *above* the prompt takes,
/// without evicting enough to compensate, moved the prompt to a different live row while
/// the snapshot stood still.
///
/// `prompt_start` now names the mark rather than the row, which is the mechanism Lisp's
/// own copy always used: `cooked--prompt-start` is a buffer marker keyed on the mark's
/// id, and `State::take_marks`/`Delta::marks` report where that id's cell ended up after
/// every rewrap (see `a_rewrap_reports_where_each_mark_moved_to` above).
///
/// Six rows at ten columns: two ten-character padding lines, then `133;A` and `PROMPT` on
/// row 2 -- three rows of content, so `Screen::reflow`'s `used()` bound takes exactly
/// these three logical lines into the rewrap. At five columns each line needs two rows,
/// six in total, so the grid holds them all with nothing evicted: `evicted_total` never
/// moves, and the divergence is not hidden behind the "no live prompt" fallback
/// `clear_to_prompt` has for an evicted one (see `a_mark_evicted_by_a_rewrap_is_reported_in_the_batch`).
#[test]
fn a_non_evicting_rewrap_leaves_prompt_start_naming_the_wrong_row() {
    let mut t = term(6, 10, b"0123456789\r\nabcdefghij\r\n\x1b]133;A\x07PROMPT");
    t.drain();
    assert_eq!(
        text(&t, 2),
        "PROMPT",
        "the prompt sits at grid row 2 before the resize"
    );

    // Narrower still holds the three logical lines exactly: two rows apiece, six in
    // total, so nothing is evicted and `evicted_total` does not move.
    t.resize(6, 5);
    t.drain();
    assert_eq!(
        text(&t, 4) + &text(&t, 5),
        "PROMPT",
        "the prompt is really on rows 4 and 5 now, pushed down by the rewrapped padding"
    );

    let kept = t.clear_to_prompt();
    assert_eq!(
        kept, 4,
        "clear_to_prompt should remove exactly the four rows above the real prompt"
    );
    assert_eq!(
        text(&t, 0) + &text(&t, 1),
        "PROMPT",
        "the prompt should now be the top two rows of the grid"
    );
}

/// A position Emacs asked to have carried rides the rewrap on a cell of its own, goes
/// on riding it through a scroll that takes the row off the grid, and is reported once.
///
/// The whole of what a transient anchor is for. Emacs measured `b' on screen row 1 and
/// the core answers where `b' is, whatever has happened to it in between -- which here is
/// a rewrap that put it on row 2 and three linefeeds that pushed that row into the
/// scrollback this drain is carrying, so the answer is spelled into the batch rather than
/// onto the grid.
#[test]
fn a_carried_position_survives_a_rewrap_and_the_scroll_that_evicts_it() {
    // Thirteen cells of one logical line at ten columns: row 0 full and wrapped, row 1
    // holding "abc". Emacs is given that, so its screen row 1 is the grid's.
    let mut t = term(4, 10, b"0123456789abc");
    t.drain();
    t.carry(&[(CarryKey(7), 1, Chars::new(1))]);
    t.resize(4, 4);
    t.feed(b"\r\n\r\n\r\n");

    let delta = t.drain();
    let (key, at) = delta
        .carried
        .first()
        .copied()
        .expect("the carry is answered");
    assert_eq!(key, CarryKey(7));
    assert!(
        at.row < delta.scrolled_base + delta.scrolled.len(),
        "the row left with the scroll, so the anchor is in this drain's batch: {at:?}"
    );
    assert_eq!(
        runs_text(&delta.scrolled[at.row - delta.scrolled_base]),
        "89ab",
        "and it names the row `b' ended up on once the line was re-chunked at four"
    );
    assert_eq!(at.col, Chars::new(3), "`b' is three characters into it");
    assert!(
        delta.marks.is_empty(),
        "the id the core minted for the carry is not a mark Emacs holds: {:?}",
        delta.marks
    );

    // Reported once. The next drain has nothing to say about it, and neither has the
    // next resize -- which would report the mark all over again had the cell kept it.
    assert!(t.drain().carried.is_empty());
    t.resize(4, 6);
    let after = t.drain();
    assert!(after.carried.is_empty() && after.marks.is_empty());
}

/// The id the core mints for a carried position comes off its cell as the answer is
/// taken, which is what bounds its life to the one rewrap. Left on the grid it would be
/// reported as a semantic mark on every later resize -- an id Emacs holds no marker for,
/// naming a position nobody asked about.
#[test]
fn a_carried_position_that_stays_on_the_grid_leaves_no_mark_behind() {
    let mut t = term(4, 10, b"0123456789abc");
    t.drain();
    t.carry(&[(CarryKey(0), 1, Chars::new(1))]);
    t.resize(4, 4);
    assert_eq!(t.drain().carried.len(), 1, "the carry is answered");

    t.resize(4, 8);
    let after = t.drain();
    assert!(after.carried.is_empty());
    assert!(
        after.marks.is_empty(),
        "nothing is left on the grid to report: {:?}",
        after.marks
    );
}

/// The case the carry exists to answer: between Emacs' last drain and the resize the
/// reader thread has gone on feeding the grid, so the row Emacs names is not the row the
/// grid has at that index -- it may not be on the grid at all.
///
/// `State::drained_at` is what closes it. Emacs reports screen row 1 while the grid has
/// scrolled five rows past it, and the answer still names the text that was on row 1.
#[test]
fn a_carried_position_is_read_in_the_screen_emacs_was_last_given() {
    // Five lines on a four-row grid, so `zero' is already history when Emacs drains:
    // its screen row 1 is the grid's row 1 and absolute row 2, which is `MARK'.
    let mut t = term(4, 10, b"zero\r\none\r\nMARK\r\ntwo\r\nthree");
    t.drain();
    // Fed and not drained: the grid moves on, the buffer does not.
    t.feed(b"\r\nA\r\nB\r\nC\r\nD\r\nE");
    t.carry(&[(CarryKey(0), 1, Chars::new(0))]);
    t.resize(4, 6);

    let delta = t.drain();
    let (_, at) = delta
        .carried
        .first()
        .copied()
        .expect("the carry is answered");
    let row = &delta.scrolled[at.row - delta.scrolled_base];
    assert_eq!(runs_text(row), "MARK", "the row Emacs was pointing at");
    assert_eq!(at.col, Chars::new(0));
}

/// A screenless drain hands Emacs no rows for an anchor to be resolved against, so it
/// settles the carry and keeps it. Without that, a row evicted while the buffer was
/// hidden would take the measurement into a drain that could not report it.
#[test]
fn a_hidden_drain_holds_a_carried_position_for_the_next_whole_one() {
    let mut t = term(3, 10, b"one\r\nMARK\r\ntwo");
    t.drain();
    t.carry(&[(CarryKey(0), 1, Chars::new(0))]);
    t.resize(3, 6);
    t.feed(b"\r\n\r\n\r\n");
    assert!(
        t.drain_hidden().carried.is_empty(),
        "a hidden drain reports no carry"
    );
    let delta = t.drain();
    let (_, at) = delta.carried.first().copied().expect("the carry survived");
    assert!(
        at.row < delta.scrolled_base + delta.scrolled.len(),
        "measured as its row departed, and spelled into the batch that carries it"
    );
}
