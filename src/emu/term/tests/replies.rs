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
        .filter(|e| matches!(e, Event::Reply(_) | Event::SizeReport(_)))
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
            Event::Reply(DA1.to_vec()),
            Event::SizeReport(b"\x1b[48;24;80;0;0t".to_vec()),
        ]
    );
    assert!(replies(&t.drain().events).is_empty());
}

#[test]
fn a_term_nobody_answers_for_keeps_every_reply_in_the_drain() {
    let mut t = term(24, 80, b"\x1b[c");
    assert!(t.take_outbound().is_empty());
    assert_eq!(replies(&t.drain().events), vec![Event::Reply(DA1.to_vec())]);
}

/// The background query with a deadline: a DA1 answer ahead of the colour would tell the
/// child the colour was never coming.
#[test]
fn a_reply_after_a_question_for_lisp_waits_behind_it() {
    let mut t = answering(b"\x1b[5n\x1b]11;?\x1b\\\x1b[c");
    assert_eq!(t.take_outbound(), vec![Event::Reply(b"\x1b[0n".to_vec())]);
    let events = t.drain().events;
    assert!(matches!(&events[0], Event::Osc(11, parts, _) if parts == &["?"]));
    assert_eq!(events[1], Event::Reply(DA1.to_vec()));

    // Lisp is answering the drain, so a reply composed meanwhile still waits.
    t.feed(b"\x1b[5n");
    assert!(t.take_outbound().is_empty());
    t.events_handled();
    assert_eq!(t.take_outbound(), vec![Event::Reply(b"\x1b[0n".to_vec())]);
    assert!(t.drain().events.is_empty());

    // And once handled, the next reply goes straight out again.
    t.feed(b"\x1b[c");
    assert_eq!(t.take_outbound(), vec![Event::Reply(DA1.to_vec())]);
}

#[test]
fn only_replies_ahead_of_an_undrained_question_are_released() {
    let mut t = answering(b"\x1b]10;?\x07");
    t.drain();
    t.feed(b"\x1b[5n\x1b[19t\x1b[c");
    t.events_handled();
    assert_eq!(t.take_outbound(), vec![Event::Reply(b"\x1b[0n".to_vec())]);
    assert_eq!(
        t.drain().events,
        vec![Event::FrameSize(Unit::Cells), Event::Reply(DA1.to_vec())]
    );
}

#[test]
fn an_osc_that_asks_nothing_holds_nothing_back() {
    let mut t = answering(b"\x1b]2;title\x07\x1b]7;file://host/tmp?x\x07\x1b[c");
    assert_eq!(t.take_outbound(), vec![Event::Reply(DA1.to_vec())]);
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
