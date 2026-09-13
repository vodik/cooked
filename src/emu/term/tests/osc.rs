//! OSC 8 hyperlinks, and the OSC sequences handed to Lisp verbatim.

use super::*;

// OSC 8 hyperlinks.
//
// The link is a field of every cell written while it is open, beside the rendition, so
// wrapping, rewrapping and scrolling carry it the way they carry colour. What these are
// for is the *lifetime* of the pen's open link, which is the one place OSC 8 is not
// shaped like an SGR attribute.

#[test]
fn a_hyperlink_marks_only_the_cells_it_covers() {
    let t = term(
        2,
        30,
        b"see \x1b]8;;https://example.com/\x1b\\here\x1b]8;;\x1b\\ ok",
    );
    let runs = links(&t, 0);
    assert_eq!(runs.len(), 3, "{runs:?}");
    assert_eq!(runs[0], ("see ".into(), None));
    assert_eq!(runs[1].0, "here");
    assert!(runs[1].1.is_some());
    assert_eq!(runs[2], (" ok".into(), None));
}

#[test]
fn an_sgr_reset_does_not_close_a_hyperlink() {
    // The trap, and the reason this test exists. `SGR 58`/`59` *are* SGR, so the
    // underline colour goes on `ESC[0m`; a hyperlink is not, and real terminals hold
    // it open across arbitrary rendition changes until an explicit `OSC 8 ; ; ST`.
    // Getting this backwards silently breaks every link a program colours as it
    // prints it, which is the common case — `ls --hyperlink` among them.
    let t = term(
        2,
        30,
        b"\x1b]8;;https://example.com/\x1b\\\x1b[31mred\x1b[0mplain",
    );
    let runs = links(&t, 0);
    assert_eq!(runs.len(), 2, "the colour splits the run, not the link");
    assert_eq!(runs[0].0, "red");
    assert_eq!(runs[1].0, "plain");
    assert!(runs[0].1.is_some());
    assert_eq!(
        runs[0].1, runs[1].1,
        "same destination either side of SGR 0"
    );
}

#[test]
fn an_empty_uri_closes_the_hyperlink() {
    let t = term(
        2,
        30,
        b"\x1b]8;;https://example.com/\x1b\\in\x1b]8;;\x1b\\out",
    );
    let runs = links(&t, 0);
    assert_eq!(runs.len(), 2, "{runs:?}");
    assert!(runs[0].1.is_some());
    assert_eq!(runs[1].1, None);
}

#[test]
fn a_reset_closes_the_hyperlink() {
    let t = term(2, 30, b"\x1b]8;;https://example.com/\x1b\\a\x1bcb");
    assert!(links(&t, 0).iter().all(|(_, id)| id.is_none()));
}

#[test]
fn the_id_parameter_is_ignored_and_the_uri_decides() {
    // Two spans of the same destination under different `id=` values are one link
    // here, which is what content-addressing buys — see `LinkStore::intern`.
    let mut t = term(
        2,
        40,
        b"\x1b]8;id=1;https://example.com/\x1b\\a\x1b]8;id=2;https://example.com/\x1b\\b",
    );
    let runs = links(&t, 0);
    assert_eq!(runs.len(), 1, "one run, one destination: {runs:?}");
    assert_eq!(t.drain().links.len(), 1, "and one URI across the boundary");
}

#[test]
fn a_uri_crosses_the_boundary_once() {
    let mut t = Term::new(4, 40);
    t.feed(b"\x1b]8;;https://example.com/\x1b\\one\x1b]8;;\x1b\\\r\n");
    assert_eq!(t.drain().links.len(), 1);
    // Same destination, second drain: the id is already Lisp's, so nothing crosses.
    t.feed(b"\x1b]8;;https://example.com/\x1b\\two\x1b]8;;\x1b\\\r\n");
    assert!(t.drain().links.is_empty());
    t.feed(b"\x1b]8;;https://example.org/\x1b\\three\x1b]8;;\x1b\\");
    assert_eq!(t.drain().links.len(), 1, "a new destination does");
}

#[test]
fn a_hyperlink_survives_a_wrap_and_the_scrollback() {
    // Both halves of "the id travels with the row": a rewrap rebases the side table
    // by column, and an evicted row reaches Lisp through the same `Row::runs` the
    // live grid does.
    let mut t = term(2, 4, b"ab\x1b]8;;https://example.com/\x1b\\cd");
    t.resize(2, 8);
    let runs = links(&t, 0);
    assert_eq!(runs.len(), 2, "{runs:?}");
    assert!(runs[0].1.is_none());
    assert!(runs[1].1.is_some(), "the link rebased with its characters");

    let id = runs[1].1;
    t.feed(b"\r\n\r\n\r\n\r\n");
    let delta = t.drain();
    let scrolled = delta
        .scrolled
        .iter()
        .find(|line| runs_text(line).starts_with("abcd"))
        .expect("the row was evicted");
    assert_eq!(
        scrolled.runs.iter().find_map(|r| r.link),
        id,
        "and again on the way out"
    );
}

#[test]
fn a_wide_character_keeps_its_hyperlink() {
    let t = term(2, 8, b"\x1b]8;;https://example.com/\x1b\\\xe5\xb9\xb8");
    let runs = links(&t, 0);
    assert_eq!(runs.len(), 1, "{runs:?}");
    assert!(
        runs[0].1.is_some(),
        "on the lead cell, not the continuation"
    );
}

#[test]
fn a_hostile_uri_is_refused_rather_than_trimmed() {
    // Both refusals leave the pen closed rather than opening a link that goes
    // somewhere else: a truncated URI is a different destination.
    let long = format!(
        "\x1b]8;;https://example.com/{}\x1b\\x",
        "a".repeat(crate::emu::link::MAX_URI_LEN)
    );
    assert!(links(&term(2, 8, long.as_bytes()), 0)[0].1.is_none());
}

#[test]
fn an_osc_8_never_reaches_lisp_as_an_event() {
    // The arm returns rather than falling through, so nothing up there can grow a
    // second opinion about what a hyperlink is.
    let mut t = term(2, 20, b"\x1b]8;;https://example.com/\x1b\\x");
    assert!(
        !t.drain()
            .events
            .iter()
            .any(|e| matches!(e, Event::Osc(8, ..)))
    );
}

#[test]
fn unhandled_osc_is_passed_through_verbatim() {
    let mut t = term(4, 20, b"\x1b]0;hi\x07\x1b]7;file://h/tmp\x07");
    assert_eq!(
        t.drain().events,
        vec![
            Event::Osc(0, vec!["hi".into()], Terminator::Bel),
            Event::Osc(7, vec!["file://h/tmp".into()], Terminator::Bel),
        ]
    );
}

#[test]
fn osc_payloads_keep_their_internal_separators() {
    // vterm's eval protocol embeds quoted arguments that may contain ';'.
    let mut t = term(4, 20, b"\x1b]51;E\"find-file\" \"/tmp/a;b\"\x1b\\");
    assert_eq!(
        t.drain().events,
        vec![Event::Osc(
            51,
            vec!["E\"find-file\" \"/tmp/a".into(), "b\"".into()],
            Terminator::St
        )]
    );
}

#[test]
fn osc_52_clipboard_is_passed_through() {
    let mut t = term(4, 20, b"\x1b]52;c;aGVsbG8=\x07");
    assert_eq!(
        t.drain().events,
        vec![Event::Osc(
            52,
            vec!["c".into(), "aGVsbG8=".into()],
            Terminator::Bel
        )]
    );
}

/// The terminator has to survive the trip to Lisp: a client that queried with BEL
/// will not recognise an ST-terminated answer, and vice versa.
#[test]
fn osc_terminator_travels_with_the_event() {
    let mut t = term(4, 20, b"\x1b]11;?\x07\x1b]11;?\x1b\\");
    assert_eq!(
        t.drain().events,
        vec![
            Event::Osc(11, vec!["?".into()], Terminator::Bel),
            Event::Osc(11, vec!["?".into()], Terminator::St),
        ]
    );
}
