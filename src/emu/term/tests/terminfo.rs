//! The terminfo audit: cooked.ti against what the emulator does.

use super::*;

/// The capabilities of every entry in `terminfo/cooked.ti`, as `(name, value)`, with
/// booleans and numbers carrying an empty value. One capability per line is the
/// file's own layout, which is what makes a parser this small enough to trust; a line
/// that does not start with a tab is an entry's name line, and `#` is a comment.
fn terminfo_capabilities() -> Vec<(&'static str, &'static str)> {
    include_str!("../../../../terminfo/cooked.ti")
        .lines()
        .filter(|line| line.starts_with('\t'))
        .map(|line| {
            let field = line.trim().trim_end_matches(',');
            field.split_once('=').unwrap_or((field, ""))
        })
        .collect()
}

/// A terminfo string with no `%` parameters, decoded to the bytes it sends.
fn terminfo_decode(value: &str) -> Vec<u8> {
    assert!(!value.contains('%'), "{value:?} is parametrised");
    let mut out = Vec::new();
    let mut chars = value.chars();
    while let Some(c) = chars.next() {
        match c {
            '\\' => match chars.next() {
                Some('E' | 'e') => out.push(0x1b),
                Some(escaped) => out.push(escaped as u8),
                None => panic!("{value:?} ends in a backslash"),
            },
            '^' => out.push(chars.next().expect("^ ends the string") as u8 & 0x1f),
            _ => out.push(c as u8),
        }
    }
    out
}

/// The modes a terminfo string sets or resets, as `(private, mode, sets)`.
///
/// A mode is a run of digits and semicolons after `\E[` or `\E[?`, ended by `h` or
/// `l`. A private run ended by `%` is a mode too -- that is how `XM` and `Sync` choose
/// between the two at run time, so it counts as setting -- but an ANSI one is not,
/// being `sgr`'s `\E[0%?...m`. Anything else ending the run (`\E[6n`, `\E[3g`) is
/// some other control.
fn terminfo_modes(value: &str) -> Vec<(bool, u16, bool)> {
    let mut modes = Vec::new();
    for (at, _) in value.match_indices("\\E[") {
        let rest = &value[at + 3..];
        let (private, rest) = match rest.strip_prefix('?') {
            Some(rest) => (true, rest),
            None => (false, rest),
        };
        let digits = rest
            .find(|c: char| !c.is_ascii_digit() && c != ';')
            .unwrap_or(rest.len());
        let sets = match rest[digits..].chars().next() {
            Some('h') => true,
            Some('%') if private => true,
            Some('l') => false,
            _ => continue,
        };
        for mode in rest[..digits].split(';').filter(|m| !m.is_empty()) {
            modes.push((private, mode.parse().unwrap(), sets));
        }
    }
    modes
}

/// One element of a POSIX extended regular expression, as `terminfo_ere` parses it.
enum Ere {
    Byte(u8),
    Any,
    /// A bracket expression: its ranges, and whether it was negated with `^`.
    Class(Vec<(u8, u8)>, bool),
    Group(Vec<(Ere, Repeat)>),
}

#[derive(Clone, Copy)]
enum Repeat {
    One,
    Optional,
    Star,
    Plus,
}

/// A response pattern such as `rv` or `xr`, decoded from terminfo's escapes and then
/// parsed as the POSIX ERE that `tset` and tmux hand to `regcomp`.
///
/// This is the subset those patterns use -- literals, backslash-escaped literals, `.`,
/// bracket expressions, groups and the `* + ?` quantifiers -- and not a regex engine.
/// Alternation and `{m,n}` panic rather than being read as literals, so a pattern that
/// outgrows the parser fails the audit loudly instead of matching the wrong thing.
fn terminfo_ere(value: &str) -> Vec<(Ere, Repeat)> {
    fn sequence(bytes: &[u8], at: &mut usize, nested: bool) -> Vec<(Ere, Repeat)> {
        let mut out = Vec::new();
        while let Some(&b) = bytes.get(*at) {
            *at += 1;
            let atom = match b {
                b')' if nested => return out,
                b'(' => Ere::Group(sequence(bytes, at, true)),
                b'.' => Ere::Any,
                b'\\' => {
                    *at += 1;
                    Ere::Byte(*bytes.get(*at - 1).expect("pattern ends in a backslash"))
                }
                b'[' => {
                    let negated = bytes.get(*at) == Some(&b'^');
                    *at += usize::from(negated);
                    let mut ranges = Vec::new();
                    // A `]` straight after the opening bracket is a member, not the end.
                    let first = *at;
                    while bytes[*at] != b']' || *at == first {
                        let lo = bytes[*at];
                        if bytes[*at + 1] == b'-' && bytes[*at + 2] != b']' {
                            ranges.push((lo, bytes[*at + 2]));
                            *at += 3;
                        } else {
                            ranges.push((lo, lo));
                            *at += 1;
                        }
                    }
                    *at += 1;
                    Ere::Class(ranges, negated)
                }
                b'|' | b'{' | b'^' | b'$' => {
                    panic!("`{}' is ERE syntax the audit does not parse", b as char)
                }
                _ => Ere::Byte(b),
            };
            let repeat = match bytes.get(*at) {
                Some(b'?') => Repeat::Optional,
                Some(b'*') => Repeat::Star,
                Some(b'+') => Repeat::Plus,
                _ => Repeat::One,
            };
            *at += usize::from(!matches!(repeat, Repeat::One));
            out.push((atom, repeat));
        }
        assert!(!nested, "unclosed group");
        out
    }
    sequence(&terminfo_decode(value), &mut 0, false)
}

/// Whether `pattern` matches all of `input`, anchored at both ends: a reply with
/// anything before or after the pattern is not the reply the entry describes.
///
/// Matching tracks the set of offsets a prefix of the pattern can end at, so a `.*`
/// costs a pass over the input rather than a backtrack per byte.
fn ere_matches_whole(pattern: &[(Ere, Repeat)], input: &[u8]) -> bool {
    fn atom(e: &Ere, input: &[u8], from: usize) -> Vec<usize> {
        match e {
            Ere::Group(inner) => sequence(inner, input, vec![from]),
            _ => match input.get(from) {
                Some(&b)
                    if match e {
                        Ere::Byte(want) => b == *want,
                        Ere::Any => true,
                        Ere::Class(ranges, negated) => {
                            ranges.iter().any(|&(lo, hi)| (lo..=hi).contains(&b)) != *negated
                        }
                        Ere::Group(_) => unreachable!(),
                    } =>
                {
                    vec![from + 1]
                }
                _ => Vec::new(),
            },
        }
    }
    fn sequence(pattern: &[(Ere, Repeat)], input: &[u8], mut ends: Vec<usize>) -> Vec<usize> {
        for (e, repeat) in pattern {
            let step = |from: &[usize]| {
                let mut next: Vec<usize> = from.iter().flat_map(|&f| atom(e, input, f)).collect();
                next.sort_unstable();
                next.dedup();
                next
            };
            let once = step(&ends);
            ends = match repeat {
                Repeat::One => once,
                Repeat::Optional => [ends, once].concat(),
                Repeat::Star | Repeat::Plus => {
                    let mut all = if matches!(repeat, Repeat::Star) {
                        ends
                    } else {
                        Vec::new()
                    };
                    let mut frontier = once;
                    while !frontier.is_empty() {
                        all.extend(&frontier);
                        all.sort_unstable();
                        all.dedup();
                        frontier = step(&frontier);
                        frontier.retain(|end| !all.contains(end));
                    }
                    all
                }
            };
            ends.sort_unstable();
            ends.dedup();
        }
        ends
    }
    sequence(pattern, input, vec![0]).contains(&input.len())
}

/// The matcher the audit relies on, held to the two patterns the entry used to carry.
/// Both were xterm's and neither matches what cooked sends, so a matcher that accepted
/// either would make the `rv`/`xr` half of the audit vacuous.
#[test]
fn the_audit_ere_matcher_tells_old_patterns_from_new() {
    let da2 = b"\x1b[>0;0;0c";
    let xtversion = b"\x1bP>|cooked(1.0.0)\x1b\\";
    assert!(ere_matches_whole(&terminfo_ere(r"\E\\[>0;0;0c"), da2));
    assert!(!ere_matches_whole(
        &terminfo_ere(r"\E\\[>41;[1-6][0-9][0-9];0c"),
        da2
    ));
    assert!(ere_matches_whole(
        &terminfo_ere(r"\E\\[>41;[1-6][0-9][0-9];0c"),
        b"\x1b[>41;390;0c"
    ));
    assert!(ere_matches_whole(
        &terminfo_ere(r"\EP>\\|cooked\\((.*)\\)\E\\\\"),
        xtversion
    ));
    assert!(!ere_matches_whole(
        &terminfo_ere(r"\EP>\\|XTerm\\((.*)\\)\E\\\\"),
        xtversion
    ));
    // Anchored: a trailing byte is not the reply the pattern describes.
    assert!(!ere_matches_whole(
        &terminfo_ere(r"\E\\[>0;0;0c"),
        b"\x1b[>0;0;0cx"
    ));
}

/// The header of `cooked.ti` argues that every capability has been checked against
/// the code. This is that check, so that the argument is no longer a person reading.
///
/// Three things are held together. A mode a capability names answers DECRQM with 1
/// or 2 -- never 0, which would mean the entry claims what the core has never heard
/// of. A mode on the `# declined-modes:` line answers 4, and no capability may set
/// one: re-adding `flash` without DECSCNM is the case in point. And a query the
/// entry declares gets a reply, since a query claimed and not answered is a child
/// waiting out its timeout. For `RV` and `XR` that reply must also match the entry's
/// own `rv` and `xr`, which is what the child compares it against.
#[test]
fn terminfo_entry_matches_what_decrqm_says() {
    let source = include_str!("../../../../terminfo/cooked.ti");
    let declined: Vec<u16> = source
        .lines()
        .find_map(|line| line.strip_prefix("# declined-modes:"))
        .expect("cooked.ti has lost its declined-modes line")
        .split_whitespace()
        .map(|mode| mode.parse().unwrap())
        .collect();
    let decrqm = |private: bool, mode: u16| -> u8 {
        let q = if private { "?" } else { "" };
        let mut t = term(4, 8, b"");
        t.feed(format!("\x1b[{q}{mode}$p").as_bytes());
        let prefix = format!("\x1b[{q}{mode};");
        t.drain()
            .events
            .iter()
            .find_map(|event| match event {
                Event::Reply(bytes) => bytes
                    .strip_prefix(prefix.as_bytes())
                    .and_then(|rest| rest.strip_suffix(b"$y"))
                    .map(|status| status[0] - b'0'),
                _ => None,
            })
            .unwrap_or_else(|| panic!("no DECRQM reply for mode {q}{mode}"))
    };

    for &mode in &declined {
        assert_eq!(
            decrqm(true, mode),
            4,
            "declined mode ?{mode} is not answered 4"
        );
    }

    let capabilities = terminfo_capabilities();
    for &(name, value) in &capabilities {
        for (private, mode, sets) in terminfo_modes(value) {
            let q = if private { "?" } else { "" };
            if private && declined.contains(&mode) {
                assert!(!sets, "`{name}' sets ?{mode}, which is declined");
                continue;
            }
            let status = decrqm(private, mode);
            assert!(
                status == 1 || status == 2,
                "`{name}' names mode {q}{mode}, and DECRQM answers {status}"
            );
        }
    }

    for query in ["u7", "u9", "RV", "XR"] {
        let (_, value) = capabilities
            .iter()
            .find(|(name, _)| *name == query)
            .unwrap_or_else(|| panic!("cooked.ti no longer declares `{query}'"));
        let mut t = term(4, 8, &terminfo_decode(value));
        assert!(
            t.drain()
                .events
                .iter()
                .any(|event| matches!(event, Event::Reply(_))),
            "`{query}' ({value}) gets no reply"
        );
    }

    // `tset` and tmux do not stop at a reply arriving: they match it against the
    // entry's own pattern, so a reply that drifts from `rv` or `xr` is as good as none.
    for (query, pattern) in [("RV", "rv"), ("XR", "xr")] {
        let value = |name: &str| {
            capabilities
                .iter()
                .find(|(n, _)| *n == name)
                .unwrap_or_else(|| panic!("cooked.ti no longer declares `{name}'"))
                .1
        };
        let mut t = term(4, 8, &terminfo_decode(value(query)));
        let replies: Vec<Vec<u8>> = t
            .drain()
            .events
            .into_iter()
            .filter_map(|event| match event {
                Event::Reply(bytes) => Some(bytes),
                _ => None,
            })
            .collect();
        let ere = terminfo_ere(value(pattern));
        assert!(
            replies.iter().any(|reply| ere_matches_whole(&ere, reply)),
            "`{query}' is answered {:?}, which `{pattern}' ({}) does not match",
            replies
                .iter()
                .map(|reply| String::from_utf8_lossy(reply))
                .collect::<Vec<_>>(),
            value(pattern)
        );
    }
}

/// The extended names tmux reads do what tmux will use them for.
///
/// The DECRQM check above already covers `Enfcs`, whose mode it can see. It cannot
/// see these two: modifyOtherKeys is not a mode, and OSC 8 is not a control sequence
/// at all. `Hls` is parametrised, so its value is pinned to tmux's own spelling in
/// `tty-features.c` and the two expansions tmux sends are fed by hand -- an open with
/// an `id=`, and the empty close it writes before every reset. `ol` is an SGR, which
/// no mode check sees either.
#[test]
fn the_extended_names_tmux_reads_do_what_they_say() {
    let capabilities = terminfo_capabilities();
    let value = |name: &str| {
        capabilities
            .iter()
            .find(|(n, _)| *n == name)
            .unwrap_or_else(|| panic!("cooked.ti does not declare `{name}'"))
            .1
    };

    let mut t = term(2, 20, &terminfo_decode(value("Eneks")));
    assert_eq!(
        t.keys(),
        KeyEncoding::ModifyOtherKeys(ModifyOtherKeys::Level2),
        "`Eneks'"
    );
    t.feed(&terminfo_decode(value("Dseks")));
    assert_eq!(t.keys(), KeyEncoding::Legacy, "`Dseks'");

    assert_eq!(value("Hls"), r"\E]8;%?%p1%l%tid=%p1%s%;;%p2%s\E\\");
    let t = term(
        2,
        30,
        b"\x1b]8;id=7;https://example.com/\x1b\\in\x1b]8;;\x1b\\out",
    );
    let runs = links(&t, 0);
    assert_eq!(runs.len(), 2, "{runs:?}");
    assert!(runs[0].1.is_some(), "an open with an id= links");
    assert_eq!(runs[1].1, None, "the empty close unlinks");

    // `ol' is tmux's name for SGR 59 and not ncurses', which has no `ol' at all, so
    // nothing but tmux's own `usstyle' check says what it should be. tmux sends it to
    // take a cell's underline colour back to the default.
    let mut reset = b"\x1b[4m\x1b[58;5;196m".to_vec();
    reset.extend(terminfo_decode(value("ol")));
    reset.push(b'x');
    let t = term(2, 8, &reset);
    assert_eq!(
        t.screen().row(0).unwrap().runs()[0].underline,
        Color::Default,
        "`ol'"
    );
}
