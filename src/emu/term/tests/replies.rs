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

/// The clipboard query with a deadline: a DA1 answer ahead of it would tell the child
/// the answer was never coming.
///
/// It used to be the background query, which is the shape a program really sends; that
/// one is now answered in the core and holds nothing back, so the rule is pinned with a
/// query Lisp still answers. `a_query_behind_a_set_waits_for_lisp_with_it` is the colour
/// case that remains.
#[test]
fn a_reply_after_a_question_for_lisp_waits_behind_it() {
    let mut t = answering(b"\x1b[5n\x1b]52;c;?\x1b\\\x1b[c");
    assert_eq!(t.take_outbound(), vec![Event::answer(b"\x1b[0n".to_vec())]);
    let events = t.drain().events;
    assert!(matches!(&events[0], Event::Osc(52, parts, _) if parts == &["c", "?"]));
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
    t.feed(b"\x1b[5n\x1b]52;c;?\x1b\\\x1b[c");
    t.events_handled();
    assert_eq!(t.take_outbound(), vec![Event::answer(b"\x1b[0n".to_vec())]);
    let events = t.drain().events;
    assert!(matches!(&events[0], Event::Osc(52, parts, _) if parts == &["c", "?"]));
    assert_eq!(events[1], Event::answer(DA1.to_vec()));
}

#[test]
fn an_osc_that_asks_nothing_holds_nothing_back() {
    let mut t = answering(b"\x1b]2;title\x07\x1b]7;file://host/tmp?x\x07\x1b[c");
    assert_eq!(t.take_outbound(), vec![Event::answer(DA1.to_vec())]);
    // A colour query is not here: the core answers it, so there is nothing for it to
    // hold back. See `a_query_behind_a_set_waits_for_lisp_with_it` for the one that is.
    for query in [&b"\x1b]52;c;?\x07"[..], b"\x1b]22;?pointer\x07"] {
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

/// A palette as Lisp pushes one: the ten defaults and every indexed entry.
///
/// The values are made up rather than xterm's, so a test asserting on one is reading the
/// table it was given and not a formula reimplemented here. Each default is its own
/// colour, so a swapped or mistaken slot shows up as the wrong answer rather than as the
/// same one.
fn palette() -> Palette {
    let gray = |value: u16| {
        Some(Rgb {
            r: value,
            g: value,
            b: value,
        })
    };
    Palette::new(
        // `OSC 10` is 0x0a00, `OSC 11` 0x0b00, and so on up to `OSC 19`, so the answer
        // names the code that should have produced it.
        (10..20).map(|code| gray(code << 8)),
        (0..256).map(|index| gray((index as u16) << 8)),
    )
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
            Event::answer(b"\x1b]11;rgb:0b00/0b00/0b00\x1b\\".to_vec()),
            Event::answer(b"\x1b]4;7;rgb:0700/0700/0700\x07".to_vec()),
            Event::answer(DA1.to_vec()),
        ],
        "each answer framed with the terminator its query used"
    );
    assert!(t.drain().events.is_empty(), "and nothing woke Lisp");
}

/// Every code from 10 to 19 is answered from its own slot, so a table read out of order
/// or one short would show up as the wrong colour rather than as a missing one.
#[test]
fn each_code_is_answered_from_its_own_slot() {
    let queries: Vec<u8> = (10..20)
        .flat_map(|code| format!("\x1b]{code};?\x07").into_bytes())
        .collect();
    let mut t = with_palette(&queries);
    let expected: Vec<Event> = (10..20)
        .map(|code| {
            Event::answer(
                format!("\x1b]{code};rgb:{code:02x}00/{code:02x}00/{code:02x}00\x07").into_bytes(),
            )
        })
        .collect();
    assert_eq!(t.take_outbound(), expected);
}

/// `ESC ] 10 ; ? ; ? ST` asks for the foreground and then the background, and a third
/// `?` asks about the cursor: one sequence, one reply per field, in field order.
///
/// A field past the last code names no colour and is answered with silence, which is
/// what `cooked--osc-color' has always done with it -- and the fields around it are
/// unaffected.
#[test]
fn a_chained_query_is_one_answer_per_field() {
    let mut t = with_palette(b"\x1b]10;?;?;?\x07");
    assert_eq!(
        t.take_outbound(),
        vec![Event::answer(
            [
                "\x1b]10;rgb:0a00/0a00/0a00\x07",
                "\x1b]11;rgb:0b00/0b00/0b00\x07",
                "\x1b]12;rgb:0c00/0c00/0c00\x07",
            ]
            .concat()
            .into_bytes()
        )]
    );

    let mut t = with_palette(b"\x1b]19;?;?\x07");
    assert_eq!(
        t.take_outbound(),
        vec![Event::answer(b"\x1b]19;rgb:1300/1300/1300\x07".to_vec())]
    );
}

/// DECSCNM draws the screen with the two defaults exchanged, and a child asking what it
/// is drawing on is owed the colour it can see -- which is why the swap is made at the
/// query and not when Lisp pushes the pair.
///
/// The Tektronix pair is not exchanged, as `cooked--child-color' does not exchange it.
#[test]
fn reverse_video_exchanges_the_two_defaults_in_the_answer() {
    let mut t = with_palette(b"\x1b[?5h\x1b]10;?\x07\x1b]11;?\x07\x1b]15;?\x07");
    assert_eq!(
        t.take_outbound(),
        vec![
            Event::answer(b"\x1b]10;rgb:0b00/0b00/0b00\x07".to_vec()),
            Event::answer(b"\x1b]11;rgb:0a00/0a00/0a00\x07".to_vec()),
            Event::answer(b"\x1b]15;rgb:0f00/0f00/0f00\x07".to_vec()),
        ]
    );
}

/// A set is policy -- `cooked-allow-color-set' -- so the sequence holding it is Lisp's,
/// and so is a query that follows it: Lisp may be about to honour the set, and a colour
/// answered from the palette in between would answer the colour being replaced.
///
/// Lisp comes back through `Term::color_answer`, so the bytes are the same walker's
/// either way; the Lisp half of this is
/// `cooked-a-colour-the-child-set-is-answered-from-what-it-left'.
#[test]
fn a_query_behind_a_set_waits_for_lisp_with_it() {
    let mut t = with_palette(b"\x1b]11;#ff0000;?\x07\x1b]11;?\x07");
    assert!(t.take_outbound().is_empty());
    let events = t.drain().events;
    assert!(matches!(&events[0], Event::Osc(11, parts, _) if parts == &["#ff0000", "?"]));
    assert!(matches!(&events[1], Event::Osc(11, parts, _) if parts == &["?"]));

    // The answer Lisp asks for once it has applied or refused the set: the query field
    // of that first sequence, which is a question about the *next* code along.
    assert_eq!(
        t.color_answer(
            11,
            ["#ff0000".as_bytes(), "?".as_bytes()].into_iter(),
            Terminator::Bel
        ),
        Some(b"\x1b]12;rgb:0c00/0c00/0c00\x07".to_vec())
    );

    // And the palette answers for itself again once Lisp says the drain is handled.
    t.events_handled();
    t.feed(b"\x1b]11;?\x07");
    assert_eq!(
        t.take_outbound(),
        vec![Event::answer(b"\x1b]11;rgb:0b00/0b00/0b00\x07".to_vec())]
    );
}

/// The indexed palette is answered even while a set is with Lisp, and that is not an
/// oversight: an `OSC 4` set is declined whatever the policy says, so nothing a child
/// sends can move an entry, and only a theme does -- which pushes the whole table.
#[test]
fn the_indexed_palette_is_answered_even_behind_a_set() {
    let mut t = with_palette(b"\x1b]11;#ff0000\x07\x1b]4;7;?\x07");
    assert_eq!(
        t.take_outbound(),
        vec![Event::answer(b"\x1b]4;7;rgb:0700/0700/0700\x07".to_vec())]
    );
}

/// A colour nobody has reported is answered with silence, not by asking Lisp: Lisp has
/// no colour to give that this was not told, and a query it cannot answer either would
/// only cost a wake. A `Term` with no session behind it has none of them.
#[test]
fn a_colour_nobody_reported_is_answered_with_silence() {
    let mut t = answering(b"\x1b]11;?\x07\x1b]4;7;?\x07\x1b[c");
    assert_eq!(t.take_outbound(), vec![Event::answer(DA1.to_vec())]);
    assert!(t.drain().events.is_empty());
}

/// A pair whose index is not a number, a pair with no specification, and a set: each
/// asks nothing, and none of them disturbs the pairs around it.
#[test]
fn a_malformed_palette_query_asks_nothing() {
    for query in [
        &b"\x1b]4;256;?\x07"[..],
        b"\x1b]4;x;?\x07",
        b"\x1b]4;1;#ff0000\x07",
        b"\x1b]4\x07",
    ] {
        let mut t = with_palette(query);
        assert!(t.take_outbound().is_empty(), "{query:?}");
        assert!(t.drain().events.is_empty(), "{query:?}");
    }
    // The unreadable pair is skipped and the one after it still answered.
    let mut t = with_palette(b"\x1b]4;x;?;7;?\x07");
    assert_eq!(
        t.take_outbound(),
        vec![Event::answer(b"\x1b]4;7;rgb:0700/0700/0700\x07".to_vec())]
    );
}
