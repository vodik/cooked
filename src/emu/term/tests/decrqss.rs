//! DECRQSS: settings read back as the sequences that recreate them.

use super::*;

/// The DCS replies in T's pending events, drained, as strings.
fn dcs_replies(t: &mut Term) -> Vec<String> {
    t.drain()
        .events
        .into_iter()
        .filter_map(|e| match e {
            Event::Reply(bytes, ReplyKind::Answer) if bytes.starts_with(b"\x1bP") => {
                Some(String::from_utf8(bytes).unwrap())
            }
            _ => None,
        })
        .collect()
}

/// Ask T about NAME and return the single answer.
fn decrqss(t: &mut Term, name: &str) -> String {
    dcs_replies(t); // Whatever was pending belongs to someone else.
    t.feed(format!("\x1bP$q{name}\x1b\\").as_bytes());
    let mut replies = dcs_replies(t);
    assert_eq!(replies.len(), 1, "{name:?}: {replies:?}");
    replies.remove(0)
}

/// Set with SET, ask about NAME, and play the answer back into a fresh terminal: the
/// reply is only a description of the setting if it recreates it. Returns the sequence
/// the reply carried, for the caller to hold to a spelling.
fn decrqss_round_trip(rows: usize, cols: usize, set: &[u8], name: &str) -> String {
    let mut first = term(rows, cols, set);
    let reply = decrqss(&mut first, name);
    let body = reply
        .strip_prefix("\x1bP1$r")
        .and_then(|r| r.strip_suffix("\x1b\\"))
        .unwrap_or_else(|| panic!("{name:?} was refused: {reply:?}"));
    // Played back as the CSI it names, into a terminal that has seen nothing else.
    let mut second = term(rows, cols, format!("\x1b[{body}").as_bytes());
    assert_eq!(
        decrqss(&mut second, name),
        reply,
        "{set:?} did not survive replay"
    );
    assert_eq!(second.state.pen.style(), first.state.pen.style(), "{set:?}");
    assert_eq!(second.state.modes, first.state.modes, "{set:?}");
    assert_eq!(
        second.screen().region().top,
        first.screen().region().top,
        "{set:?}"
    );
    assert_eq!(
        second.screen().region().bottom,
        first.screen().region().bottom,
        "{set:?}"
    );
    body.to_owned()
}

/// Every one-bit attribute sets exactly its own bit, clears it again, and is answered with
/// the code that set it: the three readers of `sgr::FLAGS` agree about every entry.
#[test]
fn each_sgr_flag_sets_clears_and_describes_its_own_bit() {
    for flag in crate::emu::sgr::FLAGS {
        let mut t = term(1, 4, format!("\x1b[{}m", flag.set).as_bytes());
        assert_eq!(t.state.pen.style().attrs, flag.attr, "SGR {}", flag.set);
        assert_eq!(
            decrqss(&mut t, "m"),
            format!("\x1bP1$r0;{}m\x1b\\", flag.set)
        );
        t.feed(format!("\x1b[{}m", flag.reset).as_bytes());
        assert_eq!(
            t.state.pen.style().attrs,
            Attrs::default(),
            "SGR {} after {}",
            flag.reset,
            flag.set
        );
    }
}

/// Every single-parameter SGR code, applied to an empty pen, is answered with a reply that
/// recreates the pen. Walking `sgr::FLAGS` cannot say this: an attribute given a bit of
/// its own and an arm in `sgr::apply`, but no entry in the table, is invisible to a test
/// that starts from the table, and `describe` would leave it out of every answer. That
/// is how overline was once missed.
#[test]
fn every_sgr_code_is_described_back_to_the_pen_it_made() {
    for code in 0..=u16::from(u8::MAX) {
        decrqss_round_trip(1, 4, format!("\x1b[{code}m").as_bytes(), "m");
    }
}

#[test]
fn decrqss_answers_the_pen_as_the_sgr_that_recreates_it() {
    for (set, want) in [
        (&b""[..], "0m"),
        (b"\x1b[1;3m", "0;1;3m"),
        (b"\x1b[1;2;5;7;8;9m", "0;1;2;5;7;8;9m"),
        (b"\x1b[53;3m", "0;3;53m"),
        // Underline styles keep their colon form; single is plain `4`.
        (b"\x1b[4m", "0;4m"),
        (b"\x1b[4:3m", "0;4:3m"),
        (b"\x1b[4:5m", "0;4:5m"),
        // The palette answers in its shortest spelling, whichever one set it.
        (b"\x1b[31;42m", "0;31;42m"),
        (b"\x1b[38;5;1;48:5:9m", "0;31;101m"),
        (b"\x1b[97;100m", "0;97;100m"),
        (b"\x1b[38;5;200m", "0;38:5:200m"),
        // Direct colour, from either spelling, in the one colon form.
        (b"\x1b[38;2;10;20;30m", "0;38:2::10:20:30m"),
        (b"\x1b[48:2::1:2:3m", "0;48:2::1:2:3m"),
        (b"\x1b[48:2:1:2:3m", "0;48:2::1:2:3m"),
        // The underline colour has no short form to fall back on.
        (b"\x1b[4:3;58:5:3m", "0;4:3;58:5:3m"),
        (b"\x1b[58:2::255:0:0m", "0;58:2::255:0:0m"),
        // Everything at once, in the order the reply writes it.
        (
            b"\x1b[48;5;17;1;4:2;38:2::1:2:3;9;58;5;196m",
            "0;1;4:2;9;38:2::1:2:3;48:5:17;58:5:196m",
        ),
        // And what `SGR 0` and the off codes leave: nothing.
        (b"\x1b[1;4;31;58:5:3m\x1b[22;24;39;59m", "0m"),
    ] {
        assert_eq!(decrqss_round_trip(2, 8, set, "m"), want, "{set:?}");
    }
}

#[test]
fn decrqss_passes_neovims_truecolour_probe() {
    // Byte for byte what neovim sends when XTGETTCAP has not told it about `RGB`, and
    // the reply its pattern `^\eP1%$r([%d;:]+)m$` then accepts: a leading `0` and then
    // `48:2:` followed by an empty colour space and the three components.
    let mut t = Term::new(2, 8);
    t.feed(b"\x1b[0m\x1b[48;2;1;2;3m\x1bP$qm\x1b\\");
    assert_eq!(dcs_replies(&mut t), vec!["\x1bP1$r0;48:2::1:2:3m\x1b\\"]);
}

#[test]
fn decrqss_answers_the_scroll_region_one_based() {
    assert_eq!(decrqss_round_trip(24, 8, b"", "r"), "1;24r");
    assert_eq!(decrqss_round_trip(24, 8, b"\x1b[5;20r", "r"), "5;20r");
    // A bottom past the screen is clamped when set, so the answer is the clamp.
    assert_eq!(decrqss_round_trip(24, 8, b"\x1b[3;99r", "r"), "3;24r");
    // Each screen has its own region, and the question is about the one in use.
    let mut t = term(24, 8, b"\x1b[5;20r\x1b[?1049h\x1b[2;10r");
    assert_eq!(decrqss(&mut t, "r"), "\x1bP1$r2;10r\x1b\\");
    t.feed(b"\x1b[?1049l");
    assert_eq!(decrqss(&mut t, "r"), "\x1bP1$r5;20r\x1b\\");
}

#[test]
fn decrqss_answers_the_cursor_style_the_child_set() {
    // Blink is never rendered, but it is the child's setting and comes back as set.
    for (set, want) in [
        (&b""[..], "1 q"),
        (b"\x1b[0 q", "1 q"),
        (b"\x1b[1 q", "1 q"),
        (b"\x1b[2 q", "2 q"),
        (b"\x1b[3 q", "3 q"),
        (b"\x1b[4 q", "4 q"),
        (b"\x1b[5 q", "5 q"),
        (b"\x1b[6 q", "6 q"),
        // An unknown style changes nothing, blink included.
        (b"\x1b[4 q\x1b[9 q", "4 q"),
        // A soft reset puts both halves back.
        (b"\x1b[6 q\x1b[!p", "1 q"),
    ] {
        assert_eq!(decrqss_round_trip(2, 8, set, " q"), want, "{set:?}");
    }
}

#[test]
fn decrqss_answers_the_conformance_level_da1_claims() {
    // Not round-tripped: cooked does not act on DECSCL, so there is no setting for the
    // replay to recreate -- only the claim, which must agree with the primary DA.
    let mut t = Term::new(2, 8);
    assert_eq!(decrqss(&mut t, "\"p"), "\x1bP1$r62;1\"p\x1b\\");
    t.feed(b"\x1b[c");
    let da1 = t.drain().events;
    assert!(da1.contains(&Event::answer(b"\x1b[?62;4;22c".to_vec())));
}

#[test]
fn decrqss_refuses_what_it_does_not_answer_out_loud() {
    let mut t = Term::new(2, 8);
    // DECSLRM is declined, so its margins are not answered either; the rest are names
    // nothing here sets, or no name at all, or a valid name buried in a longer one.
    for name in ["s", "t", "$}", "", "mm", "rrrrrrrr"] {
        assert_eq!(decrqss(&mut t, name), "\x1bP0$r\x1b\\", "{name:?}");
    }
}

#[test]
fn decrqss_is_not_mistaken_for_a_sixel() {
    // Both end in `q`; only the intermediate says which. A status request collected as
    // a picture would decode to nothing, and a sixel answered as a status request would
    // put a refusal on the child's input.
    let mut t = with_metrics(10, 20);
    t.feed(b"\x1bP$qm\x1b\\");
    let delta = t.drain();
    assert!(delta.images.is_empty());
    assert_eq!(delta.events.len(), 1);
    t.feed(b"\x1bP0;0;0q#0;2;100;0;0~\x1b\\");
    let delta = t.drain();
    assert_eq!(delta.images.len(), 1);
    assert!(
        !delta
            .events
            .iter()
            .any(|e| matches!(e, Event::Reply(_, ReplyKind::Answer)))
    );
}

#[test]
fn a_decrqss_split_across_writes_is_one_request() {
    let mut t = Term::new(2, 8);
    t.feed(b"\x1b[5 q\x1bP$");
    t.feed(b"q ");
    t.feed(b"q\x1b");
    t.feed(b"\\");
    assert_eq!(dcs_replies(&mut t), vec!["\x1bP1$r5 q\x1b\\"]);
}
