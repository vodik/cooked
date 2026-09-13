//! XTGETTCAP, `DCS + q NAMES ST`: a capability asked for in band, answered from the
//! terminfo entry TERM names.
//!
//! The case it exists for is the one a terminfo database cannot serve. Over ssh the
//! remote host has never heard of `cooked-256color`, so a child there either falls back
//! to a guess or asks the terminal itself -- and neovim asks, for `Tc`, `RGB`,
//! `setrgbf` and `Ms`, and runs in 256 colours without OSC 52 when nobody answers.

use super::*;
use crate::emu::bytes::{extend_bounded, hex_byte};
use crate::emu::terminfo;

/// Longest XTGETTCAP request collected from one DCS string.
///
/// A name is a handful of hex digits, and neovim's whole startup query is under a
/// hundred bytes, so this is room for every capability in the entry asked for at once
/// with plenty over. Past it the request is cut back to the last whole name rather than
/// dropped, and the names cut off are answered with one miss: a reply stops at the first
/// miss anyway, so answering the names that fit and then saying no is the answer a
/// request whose next name the entry lacked would have had.
pub(crate) const XTGETTCAP_BODY_LIMIT: usize = 4096;

/// An XTGETTCAP request being collected.
#[derive(Debug, Default)]
pub(super) struct Request {
    body: Vec<u8>,
    overran: bool,
}

impl Request {
    /// A slice of the payload, kept up to the limit and remembered as overrun past it.
    pub(super) fn put(&mut self, bytes: &[u8]) {
        self.overran |= extend_bounded(&mut self.body, bytes, XTGETTCAP_BODY_LIMIT);
    }
}

impl State {
    /// The string ended: answer the request.
    ///
    /// One reply per name, `DCS 1 + r NAME = VALUE ST` for a hit and `DCS 0 + r NAME ST`
    /// for a miss, with NAME and VALUE hex-encoded. The first miss is the last reply,
    /// which is xterm's rule and the one clients are written against: they send their
    /// names in a batch and read replies until one says no, so answering past a miss
    /// would leave replies on the wire that nothing is waiting to read -- and those
    /// arrive at the shell as typed input.
    ///
    /// A request that overran the limit ends in a miss for the names that were cut off,
    /// so a client asking for more than fits still hears the no it is reading for. Without
    /// it a single 5 KB token, cut back to nothing, got no reply at all and the client sat
    /// out its timeout.
    pub(super) fn capability_report(&mut self, mut request: Request) {
        if request.overran {
            let whole = request.body.iter().rposition(|&b| b == b';').unwrap_or(0);
            request.body.truncate(whole);
        }
        let entry = self.terminfo.unwrap_or_else(terminfo::default_entry);
        for token in request.body.split(|&b| b == b';') {
            if token.is_empty() {
                continue;
            }
            let name = hex_decode(token);
            let value = name
                .as_deref()
                .and_then(|name| std::str::from_utf8(name).ok())
                .and_then(|name| entry.answer(name));
            match (name, value) {
                (Some(name), Some(value)) if value.is_empty() => {
                    self.dcs_reply(format_args!("1+r{}", hex_encode(&name)));
                }
                (Some(name), Some(value)) => {
                    self.dcs_reply(format_args!(
                        "1+r{}={}",
                        hex_encode(&name),
                        hex_encode(&value)
                    ));
                }
                (name, _) => {
                    // The name as we decoded it, re-encoded, and never the child's own
                    // spelling: a token need not be hex, and `\eP+qrm -rf ~\e\\` echoed
                    // verbatim would type `0+rrm -rf ~` at the prompt. A token that does
                    // not decode names nothing, so its miss is bare, which is the form
                    // ctlseqs gives.
                    let name = name.as_deref().map(hex_encode).unwrap_or_default();
                    self.dcs_reply(format_args!("0+r{name}"));
                    return;
                }
            }
        }
        if request.overran {
            self.dcs_reply(format_args!("0+r"));
        }
    }
}

fn hex_decode(hex: &[u8]) -> Option<Vec<u8>> {
    if hex.len() % 2 != 0 {
        return None;
    }
    hex.chunks_exact(2)
        .map(|pair| hex_byte(pair[0], pair[1]))
        .collect()
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02X}")).collect()
}

impl Term {
    /// Tell the emulator which terminfo entry TERM names, for XTGETTCAP to answer from.
    ///
    /// Read out of the environment the child was spawned with rather than passed
    /// separately, so it cannot disagree with what the child was told. A name that is
    /// not one of ours falls back to [`terminfo::default_entry`]; see there for why that
    /// beats answering nothing.
    pub fn set_terminfo(&mut self, term: &str) {
        self.state.terminfo = terminfo::entry(term);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The replies to asking for NAMES under TERM, as text so a failure reads.
    fn ask(term: &str, names: &[&str]) -> Vec<String> {
        let mut t = Term::new(2, 8);
        t.set_terminfo(term);
        let hex: Vec<String> = names.iter().map(|n| hex_encode(n.as_bytes())).collect();
        t.feed(format!("\x1bP+q{}\x1b\\", hex.join(";")).as_bytes());
        t.drain()
            .events
            .into_iter()
            .filter_map(|event| match event {
                Event::Reply(bytes) => Some(String::from_utf8(bytes).unwrap()),
                _ => None,
            })
            .collect()
    }

    /// The reply a hit should produce, spelled out rather than built by the code under
    /// test: `DCS 1 + r NAME [= VALUE] ST`.
    fn hit(name: &str, value: &[u8]) -> String {
        let value = match value {
            [] => String::new(),
            _ => format!("={}", hex_encode(value)),
        };
        format!("\x1bP1+r{}{value}\x1b\\", hex_encode(name.as_bytes()))
    }

    #[test]
    fn tc_round_trips() {
        // `printf '\eP+q5463\e\\'`, the request in the task, and its answer byte for byte.
        let mut t = Term::new(2, 8);
        t.feed(b"\x1bP+q5463\x1b\\");
        assert_eq!(
            t.drain().events,
            vec![Event::Reply(b"\x1bP1+r5463\x1b\\".to_vec())]
        );
    }

    #[test]
    fn a_string_without_parameters_is_sent_decoded() {
        assert_eq!(ask("cooked", &["kbs"]), vec![hit("kbs", b"\x7f")]);
        assert_eq!(ask("cooked", &["Cr"]), vec![hit("Cr", b"\x1b]112\x07")]);
    }

    #[test]
    fn a_delay_in_a_string_is_not_sent() {
        // `flash=\E[?5h$<100/>\E[?5l`: the pause is for `tputs` to take, and a client
        // replaying the answer would otherwise print `$<100/>` on a reversed screen.
        assert_eq!(
            ask("cooked", &["flash"]),
            vec![hit("flash", b"\x1b[?5h\x1b[?5l")]
        );
    }

    #[test]
    fn a_key_is_answered_under_its_termcap_name_too() {
        // As xterm answers them, and named in the reply as they were asked.
        assert_eq!(
            ask(
                "cooked",
                &["ku", "k1", "k;", "FP", "Fr", "kb", "kh", "#4", "K1", "@8"]
            ),
            vec![
                hit("ku", b"\x1bOA"),
                hit("k1", b"\x1bOP"),
                hit("k;", b"\x1b[21~"),
                hit("FP", b"\x1b[23;5~"),
                hit("Fr", b"\x1b[1;4R"),
                hit("kb", b"\x7f"),
                hit("kh", b"\x1bOH"),
                hit("#4", b"\x1b[1;2D"),
                hit("K1", b"\x1bOw"),
                hit("@8", b"\x1bOM"),
            ]
        );
        assert_eq!(ask("cooked", &["name"]), vec![hit("name", b"cooked")]);
        // A termcap-shaped name that is no key, and one past `kf63`, are still misses.
        for name in ["k0", "Fs", "kZ"] {
            assert_eq!(
                ask("cooked", &[name]),
                vec![format!("\x1bP0+r{}\x1b\\", hex_encode(name.as_bytes()))],
                "{name}"
            );
        }
    }

    #[test]
    fn a_string_with_parameters_is_sent_as_written() {
        let setrgbf = terminfo::default_entry().get("setrgbf");
        let Some(terminfo::Value::Str(source)) = setrgbf else {
            panic!("cooked.ti no longer declares setrgbf");
        };
        assert!(source.contains("\\E"), "{source}");
        assert_eq!(
            ask("cooked", &["setrgbf"]),
            vec![hit("setrgbf", source.as_bytes())]
        );
    }

    #[test]
    fn the_name_and_colour_count_answer_for_the_entry_term_named() {
        assert_eq!(ask("cooked", &["TN"]), vec![hit("TN", b"cooked")]);
        assert_eq!(ask("cooked-256color", &["Co"]), vec![hit("Co", b"256")]);
        assert_eq!(ask("cooked-direct", &["Co"]), vec![hit("Co", b"16777216")]);
        assert_eq!(ask("cooked-direct", &["RGB"]), vec![hit("RGB", b"")]);
    }

    #[test]
    fn a_term_that_is_not_ours_answers_from_the_first_entry() {
        let first = terminfo::default_entry().names[0];
        assert_eq!(
            ask("xterm-256color", &["TN"]),
            vec![hit("TN", first.as_bytes())]
        );
    }

    #[test]
    fn the_first_miss_ends_the_answer() {
        // `RGB` is declared on `cooked-direct` and deliberately not here; see
        // `Entry::answer`.
        assert_eq!(
            ask("cooked-256color", &["Tc", "RGB", "am"]),
            vec![
                hit("Tc", b""),
                format!("\x1bP0+r{}\x1b\\", hex_encode(b"RGB"))
            ]
        );
    }

    #[test]
    fn lowercase_hex_is_understood() {
        let mut t = Term::new(2, 8);
        t.feed(b"\x1bP+q5463;616d\x1b\\");
        let replies = t.drain().events;
        assert_eq!(replies.len(), 2, "{replies:?}");
        assert_eq!(replies[1], Event::Reply(hit("am", b"").into_bytes()));
    }

    #[test]
    fn a_name_that_is_not_hex_is_a_miss() {
        // The token is printable and would read as a command if it came back: the miss
        // names nothing rather than echo it.
        let mut t = Term::new(2, 8);
        t.feed(b"\x1bP+qrm -rf ~ x;5463\x1b\\");
        assert_eq!(
            t.drain().events,
            vec![Event::Reply(b"\x1bP0+r\x1b\\".to_vec())]
        );
    }

    #[test]
    fn a_miss_names_the_capability_in_hex_whatever_case_it_was_asked_in() {
        let mut t = Term::new(2, 8);
        t.feed(b"\x1bP+q7a7a\x1b\\");
        assert_eq!(
            t.drain().events,
            vec![Event::Reply(b"\x1bP0+r7A7A\x1b\\".to_vec())]
        );
    }

    #[test]
    fn a_single_token_past_the_limit_still_gets_a_miss() {
        let mut t = Term::new(2, 8);
        let token = "41".repeat(2500);
        t.feed(format!("\x1bP+q{token}\x1b\\").as_bytes());
        assert_eq!(
            t.drain().events,
            vec![Event::Reply(b"\x1bP0+r\x1b\\".to_vec())]
        );
    }

    #[test]
    fn other_dcs_families_are_not_answered() {
        for request in [&b"\x1bP$q5463\x1b\\"[..], b"\x1bPq5463\x1b\\"] {
            let mut t = Term::new(2, 8);
            t.feed(request);
            assert!(
                !t.drain()
                    .events
                    .iter()
                    .any(|e| matches!(e, Event::Reply(r) if r.starts_with(b"\x1bP1+r"))),
                "{request:?}"
            );
        }
    }

    #[test]
    fn an_overlong_request_answers_the_names_that_fit() {
        let name = hex_encode(b"am");
        let count = XTGETTCAP_BODY_LIMIT / (name.len() + 1) + 10;
        let body = vec![name; count].join(";");
        let mut t = Term::new(2, 8);
        t.feed(format!("\x1bP+q{body}\x1b\\").as_bytes());
        let mut replies = t.drain().events;
        // The names cut off are answered with the miss a client reads until.
        assert_eq!(
            replies.pop(),
            Some(Event::Reply(b"\x1bP0+r\x1b\\".to_vec()))
        );
        assert_eq!(replies.len(), XTGETTCAP_BODY_LIMIT / 5);
        assert!(
            replies
                .iter()
                .all(|r| *r == Event::Reply(hit("am", b"").into_bytes()))
        );
    }

    /// The entry and the reply cannot drift: every capability line of every entry in
    /// `cooked.ti`, read here line by line and not through the parser the core uses, is
    /// answered under that entry's name with the value the line gives it. A line the
    /// parser failed to pick up is a miss; a value it misread is a mismatch.
    ///
    /// An entry that says `use=` answers everything its parent answers, except what it
    /// declares itself -- which is how `cooked-direct` comes to answer its own `setaf`
    /// and every other capability `cooked-256color` has.
    #[test]
    fn terminfo_entry_is_answered_in_full() {
        let source = include_str!("../../../terminfo/cooked.ti");
        let mut entries: Vec<(&str, Vec<&str>)> = Vec::new();
        for line in source.lines() {
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            match line.strip_prefix('\t') {
                Some(field) => entries
                    .last_mut()
                    .expect("a capability before any name line")
                    .1
                    .push(field.trim_end_matches(',')),
                None => entries.push((line.split('|').next().unwrap(), Vec::new())),
            }
        }
        assert!(entries.len() >= 3, "only {} entries read", entries.len());

        let expected = |field: &str| -> (String, Vec<u8>) {
            if let Some((name, value)) = field.split_once('=') {
                let bytes = match value.contains('%') {
                    true => value.as_bytes().to_vec(),
                    false => terminfo::decode(value),
                };
                (name.to_owned(), bytes)
            } else if let Some((name, number)) = field.split_once('#') {
                let n = match number.strip_prefix("0x") {
                    Some(hex) => u32::from_str_radix(hex, 16).unwrap(),
                    None => number.parse().unwrap(),
                };
                (name.to_owned(), n.to_string().into_bytes())
            } else {
                (field.to_owned(), Vec::new())
            }
        };

        let mut answered = 0;
        for (entry, fields) in &entries {
            let own: Vec<(String, Vec<u8>)> = fields
                .iter()
                .filter(|f| !f.starts_with("use="))
                .map(|f| expected(f))
                .collect();
            for (name, value) in &own {
                assert_eq!(
                    ask(entry, &[name]),
                    vec![hit(name, value)],
                    "`{name}' under {entry}"
                );
                answered += 1;
            }
            for parent in fields.iter().filter_map(|f| f.strip_prefix("use=")) {
                let (_, inherited) = entries
                    .iter()
                    .find(|(e, _)| e == &parent)
                    .unwrap_or_else(|| panic!("{entry} uses {parent}, which is not here"));
                for field in inherited.iter().filter(|f| !f.starts_with("use=")) {
                    let (name, _) = expected(field);
                    if own.iter().any(|(n, _)| *n == name) {
                        continue;
                    }
                    assert_eq!(
                        ask(entry, &[&name]),
                        ask(parent, &[&name]),
                        "`{name}' under {entry}, inherited from {parent}"
                    );
                    answered += 1;
                }
            }
        }
        // A floor, not a count: the entry grows, and a test that had to be edited each
        // time it did would be the drift this test is here to prevent.
        assert!(answered > 200, "only {answered} capabilities checked");
    }
}
