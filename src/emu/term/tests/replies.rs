//! Which replies go straight to the child, and which wait behind a question for Lisp.

use super::*;

/// A term whose session takes replies directly, as `Session::spawn` sets it up.
fn answering(input: &[u8]) -> Term {
    let mut t = Term::new(24, 80);
    t.answer_directly();
    t.feed(input);
    t
}

fn replies(events: &[Event]) -> Vec<Event> {
    events
        .iter()
        .filter(|e| matches!(e, Event::Reply(..)))
        .cloned()
        .collect()
}

const DA1: &[u8] = b"\x1b[?62;4;22c";

#[test]
fn a_reply_needing_nothing_from_lisp_skips_the_drain() {
    let mut t = answering(b"\x1b[c\x1b[?2048h");
    assert_eq!(
        t.take_outbound(),
        vec![
            Event::answer(DA1.to_vec()),
            Event::size_report(b"\x1b[48;24;80;0;0t".to_vec()),
        ]
    );
    assert!(replies(&t.drain().events).is_empty());
}

#[test]
fn a_term_nobody_answers_for_keeps_every_reply_in_the_drain() {
    let mut t = term(24, 80, b"\x1b[c");
    assert!(t.take_outbound().is_empty());
    assert_eq!(
        replies(&t.drain().events),
        vec![Event::answer(DA1.to_vec())]
    );
}

/// The background query with a deadline: a DA1 answer ahead of the colour would tell the
/// child the colour was never coming.
#[test]
fn a_reply_after_a_question_for_lisp_waits_behind_it() {
    let mut t = answering(b"\x1b[5n\x1b]11;?\x1b\\\x1b[c");
    assert_eq!(t.take_outbound(), vec![Event::answer(b"\x1b[0n".to_vec())]);
    let events = t.drain().events;
    assert!(matches!(&events[0], Event::Osc(11, parts, _) if parts == &["?"]));
    assert_eq!(events[1], Event::answer(DA1.to_vec()));

    // Lisp is answering the drain, so a reply composed meanwhile still waits.
    t.feed(b"\x1b[5n");
    assert!(t.take_outbound().is_empty());
    t.events_handled();
    assert_eq!(t.take_outbound(), vec![Event::answer(b"\x1b[0n".to_vec())]);
    assert!(t.drain().events.is_empty());

    // And once handled, the next reply goes straight out again.
    t.feed(b"\x1b[c");
    assert_eq!(t.take_outbound(), vec![Event::answer(DA1.to_vec())]);
}

#[test]
fn only_replies_ahead_of_an_undrained_question_are_released() {
    let mut t = answering(b"\x1b]10;?\x07");
    t.drain();
    t.feed(b"\x1b[5n\x1b[19t\x1b[c");
    t.events_handled();
    assert_eq!(t.take_outbound(), vec![Event::answer(b"\x1b[0n".to_vec())]);
    assert_eq!(
        t.drain().events,
        vec![Event::FrameSize(Unit::Cells), Event::answer(DA1.to_vec())]
    );
}

#[test]
fn an_osc_that_asks_nothing_holds_nothing_back() {
    let mut t = answering(b"\x1b]2;title\x07\x1b]7;file://host/tmp?x\x07\x1b[c");
    assert_eq!(t.take_outbound(), vec![Event::answer(DA1.to_vec())]);
    for query in [
        &b"\x1b]4;1;?\x07"[..],
        b"\x1b]52;c;?\x07",
        b"\x1b]22;?pointer\x07",
    ] {
        let mut t = answering(query);
        t.feed(b"\x1b[c");
        assert!(t.take_outbound().is_empty(), "{query:?}");
    }
}

#[test]
fn a_resize_supersedes_a_size_report_not_yet_taken() {
    let mut t = answering(b"\x1b[?2048h");
    assert_eq!(
        t.set_size(30, 100, None).as_deref(),
        Some(&b"\x1b[48;30;100;0;0t"[..])
    );
    assert!(t.take_outbound().is_empty());
}

#[test]
fn a_reply_that_skips_the_drain_wakes_nobody() {
    let mut t = answering(b"");
    assert!(!t.feed(b"\x1b[c"), "nothing for Emacs to draw");
}

/// A palette as Lisp pushes one: the two defaults and every indexed entry.
///
/// The indexed values are made up rather than xterm's, so a test asserting on one is
/// reading the table and not a formula reimplemented here.
fn palette() -> Palette {
    let mut palette = Palette {
        foreground: Some(Rgb {
            r: 0x1111,
            g: 0x2222,
            b: 0x3333,
        }),
        background: Some(Rgb {
            r: 0xffff,
            g: 0xeeee,
            b: 0xdddd,
        }),
        ..Palette::default()
    };
    for (index, entry) in palette.indexed.iter_mut().enumerate() {
        let channel = (index as u16) << 8;
        *entry = Some(Rgb {
            r: channel,
            g: channel,
            b: channel,
        });
    }
    palette
}

fn with_palette(input: &[u8]) -> Term {
    let mut t = Term::new(24, 80);
    t.answer_directly();
    t.set_palette(palette());
    t.feed(input);
    t
}

/// The point of holding the palette: the probe a theme-aware program opens with is
/// answered where it arrives, so it costs no wake, no drain and no reply batch.
#[test]
fn a_colour_query_the_palette_answers_never_reaches_lisp() {
    let mut t = with_palette(b"\x1b]11;?\x1b\\\x1b]4;7;?\x07\x1b[c");
    assert_eq!(
        t.take_outbound(),
        vec![
            Event::answer(b"\x1b]11;rgb:ffff/eeee/dddd\x1b\\".to_vec()),
            Event::answer(b"\x1b]4;7;rgb:0700/0700/0700\x07".to_vec()),
            Event::answer(DA1.to_vec()),
        ],
        "each answer framed with the terminator its query used"
    );
    assert!(t.drain().events.is_empty(), "and nothing woke Lisp");
}

/// `ESC ] 10 ; ? ; ? ST` asks for the foreground and then the background; one more `?`
/// asks about the cursor, which is the frame's colour and not the palette's, so the whole
/// sequence goes to Lisp rather than half of it being answered here.
#[test]
fn a_chained_query_is_answered_here_only_if_every_field_can_be() {
    let mut t = with_palette(b"\x1b]10;?;?\x07");
    assert_eq!(
        t.take_outbound(),
        vec![
            Event::answer(b"\x1b]10;rgb:1111/2222/3333\x07".to_vec()),
            Event::answer(b"\x1b]11;rgb:ffff/eeee/dddd\x07".to_vec()),
        ]
    );

    let mut t = with_palette(b"\x1b]10;?;?;?\x07");
    assert!(t.take_outbound().is_empty());
    let events = t.drain().events;
    assert!(matches!(&events[0], Event::Osc(10, parts, _) if parts == &["?", "?", "?"]));
}

/// DECSCNM draws the screen with the two defaults exchanged, and a child asking what it
/// is drawing on is owed the colour it can see -- which is why the swap is made at the
/// query and not when Lisp pushes the pair.
#[test]
fn reverse_video_exchanges_the_two_defaults_in_the_answer() {
    let mut t = with_palette(b"\x1b[?5h\x1b]10;?\x07\x1b]11;?\x07");
    assert_eq!(
        t.take_outbound(),
        vec![
            Event::answer(b"\x1b]10;rgb:ffff/eeee/dddd\x07".to_vec()),
            Event::answer(b"\x1b]11;rgb:1111/2222/3333\x07".to_vec()),
        ]
    );
}

/// A set is policy -- `cooked-allow-color-set' -- so it is Lisp's, and the query behind
/// it has to be Lisp's too: Lisp may be about to honour the set, and a colour answered
/// from the palette in between would answer the colour being replaced.
#[test]
fn a_query_behind_a_set_waits_for_lisp_with_it() {
    let mut t = with_palette(b"\x1b]11;#ff0000\x07\x1b]11;?\x07");
    assert!(t.take_outbound().is_empty());
    let events = t.drain().events;
    assert!(matches!(&events[0], Event::Osc(11, parts, _) if parts == &["#ff0000"]));
    assert!(matches!(&events[1], Event::Osc(11, parts, _) if parts == &["?"]));

    // Answered again once Lisp says it has handled the drain and pushed what it made of
    // the set.
    t.events_handled();
    t.feed(b"\x1b]11;?\x07");
    assert_eq!(
        t.take_outbound(),
        vec![Event::answer(b"\x1b]11;rgb:ffff/eeee/dddd\x07".to_vec())]
    );
}

/// A palette entry nothing has reported is a query Lisp answers, as every colour query
/// was before the palette existed. The default `Term` holds none.
#[test]
fn a_colour_nobody_reported_is_still_asked_of_lisp() {
    let mut t = answering(b"\x1b]11;?\x07\x1b]4;7;?\x07");
    assert!(t.take_outbound().is_empty());
    let events = t.drain().events;
    assert!(matches!(&events[0], Event::Osc(11, _, _)));
    assert!(matches!(&events[1], Event::Osc(4, _, _)));
}

/// An index the pairs cannot be read as, and an odd field count: both are malformed
/// queries whose reading is `cooked--osc-palette''s, so they reach it unchanged.
#[test]
fn a_malformed_palette_query_is_left_to_lisp() {
    for query in [
        &b"\x1b]4;256;?\x07"[..],
        b"\x1b]4;x;?\x07",
        b"\x1b]4;1;?;196\x07",
        b"\x1b]4;1;#ff0000\x07",
        b"\x1b]4\x07",
    ] {
        let mut t = with_palette(query);
        assert!(t.take_outbound().is_empty(), "{query:?}");
    }
}
