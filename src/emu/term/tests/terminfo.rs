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
    terminfo_unescape(value)
}

/// A terminfo string's escapes decoded, with any `%` left for [`terminfo_expand`].
///
/// All of terminfo(5)'s escapes: `\E`, `^X`, the named ones, and octal, which the
/// entry uses for BEL in `dsl`, `Cr` and `Cs`. Read as `\0` and two literal digits,
/// `\007` used to decode to the text "007". Padding, `$<100/>` in `flash`, is a delay
/// for the terminal's benefit and sends nothing, so it is dropped.
fn terminfo_unescape(value: &str) -> Vec<u8> {
    let bytes = value.as_bytes();
    let mut out = Vec::new();
    let mut at = 0;
    while let Some(&b) = bytes.get(at) {
        at += 1;
        match b {
            b'\\' => {
                let escaped = *bytes.get(at).expect("ends in a backslash");
                at += 1;
                out.push(match escaped {
                    b'E' | b'e' => 0x1b,
                    b'n' | b'l' => b'\n',
                    b'r' => b'\r',
                    b't' => b'\t',
                    b'b' => 0x08,
                    b'f' => 0x0c,
                    b's' => b' ',
                    b'0'..=b'7' => {
                        let digits = bytes[at - 1..]
                            .iter()
                            .take(3)
                            .take_while(|d| d.is_ascii_digit())
                            .count();
                        at += digits - 1;
                        let code = std::str::from_utf8(&bytes[at - digits..at]).unwrap();
                        // `\0` alone is terminfo's way of writing a NUL it can store.
                        u8::from_str_radix(code, 8).map_or(0x80, |n| if n == 0 { 0x80 } else { n })
                    }
                    other => other,
                });
            }
            b'^' => {
                out.push(bytes.get(at).expect("^ ends the string") & 0x1f);
                at += 1;
            }
            b'$' if bytes.get(at) == Some(&b'<') => {
                at += bytes[at..]
                    .iter()
                    .position(|&c| c == b'>')
                    .expect("unclosed padding")
                    + 1;
            }
            _ => out.push(b),
        }
    }
    out
}

/// A `%p` argument to a parametrised capability: a number or a string.
#[derive(Clone, Copy)]
enum Arg {
    N(i64),
    S(&'static str),
}

/// A parametrised capability expanded with ARGS, as ncurses' `tparm` would.
///
/// terminfo(5)'s whole stack language but `%P`/`%g` variables and the `%x`/`%o`
/// formats, none of which the entry uses, and each of which panics rather than
/// being read as something else.
fn terminfo_expand(value: &str, args: &[Arg]) -> Vec<u8> {
    let code = terminfo_unescape(value);
    let mut params: Vec<Arg> = args.to_vec();
    params.resize(9, Arg::N(0));
    let mut stack: Vec<Arg> = Vec::new();
    let mut out = Vec::new();
    let int = |arg: Option<Arg>| match arg {
        Some(Arg::N(n)) => n,
        Some(Arg::S(s)) => panic!("{value:?} uses the string {s:?} as a number"),
        None => panic!("{value:?} pops an empty stack"),
    };
    // Skip from just after a `%t` or `%e` to past the `%e` or `%;` that answers it at
    // this depth, stopping at an `%e` only when STOP_AT_ELSE.
    let skip = |at: &mut usize, stop_at_else: bool| {
        let mut depth = 0;
        while *at + 1 < code.len() {
            if code[*at] == b'%' {
                match code[*at + 1] {
                    b'?' => depth += 1,
                    b';' if depth == 0 => return *at += 2,
                    b';' => depth -= 1,
                    b'e' if depth == 0 && stop_at_else => return *at += 2,
                    _ => {}
                }
                *at += 2;
            } else {
                *at += 1;
            }
        }
        panic!("{value:?} has an unclosed conditional");
    };
    let mut at = 0;
    while at < code.len() {
        if code[at] != b'%' {
            out.push(code[at]);
            at += 1;
            continue;
        }
        let op = code[at + 1];
        at += 2;
        match op {
            b'%' => out.push(b'%'),
            b'c' => out.push(int(stack.pop()) as u8),
            b'd' => out.extend(int(stack.pop()).to_string().bytes()),
            b's' => match stack.pop() {
                Some(Arg::S(s)) => out.extend(s.bytes()),
                _ => panic!("{value:?} prints a non-string with %s"),
            },
            b'l' => match stack.pop() {
                Some(Arg::S(s)) => stack.push(Arg::N(s.len() as i64)),
                _ => panic!("{value:?} takes the length of a non-string"),
            },
            b'p' => {
                stack.push(params[usize::from(code[at] - b'1')]);
                at += 1;
            }
            b'i' => {
                for param in &mut params[..2] {
                    if let Arg::N(n) = param {
                        *n += 1;
                    }
                }
            }
            b'{' => {
                let end = at + code[at..].iter().position(|&c| c == b'}').unwrap();
                stack.push(Arg::N(
                    std::str::from_utf8(&code[at..end])
                        .unwrap()
                        .parse()
                        .unwrap(),
                ));
                at = end + 1;
            }
            b'\'' => {
                stack.push(Arg::N(i64::from(code[at])));
                at += 2;
            }
            b'+' | b'-' | b'*' | b'/' | b'm' | b'&' | b'|' | b'^' | b'=' | b'<' | b'>' | b'A'
            | b'O' => {
                let (b, a) = (int(stack.pop()), int(stack.pop()));
                stack.push(Arg::N(match op {
                    b'+' => a + b,
                    b'-' => a - b,
                    b'*' => a * b,
                    b'/' => a / b,
                    b'm' => a % b,
                    b'&' => a & b,
                    b'|' => a | b,
                    b'^' => a ^ b,
                    b'=' => i64::from(a == b),
                    b'<' => i64::from(a < b),
                    b'>' => i64::from(a > b),
                    b'A' => i64::from(a != 0 && b != 0),
                    _ => i64::from(a != 0 || b != 0),
                }));
            }
            b'!' => {
                let a = int(stack.pop());
                stack.push(Arg::N(i64::from(a == 0)));
            }
            b'~' => {
                let a = int(stack.pop());
                stack.push(Arg::N(!a));
            }
            b'?' | b';' => {}
            b't' => {
                if int(stack.pop()) == 0 {
                    skip(&mut at, true);
                }
            }
            // Reached only by running the true branch to its end.
            b'e' => skip(&mut at, false),
            other => panic!(
                "{value:?} uses %{}, which the audit does not expand",
                other as char
            ),
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

/// Whether REPLY is what the ncurses response pattern PATTERN describes.
///
/// `u6` and `u8` are written in `tparm`'s own language rather than as an ERE: `%d` is
/// a number, `%[...]` a run of the characters in the brackets, and `%i` says the
/// numbers are one-based, which a match does not need to know.
fn terminfo_response_matches(pattern: &str, reply: &[u8]) -> bool {
    let pattern = terminfo_unescape(pattern);
    let (mut p, mut r) = (0, 0);
    while p < pattern.len() {
        if pattern[p] != b'%' {
            if reply.get(r) != Some(&pattern[p]) {
                return false;
            }
            (p, r) = (p + 1, r + 1);
            continue;
        }
        let run = |r: usize, accept: &dyn Fn(u8) -> bool| {
            r + reply[r..].iter().take_while(|&&b| accept(b)).count()
        };
        match pattern[p + 1] {
            b'i' => p += 2,
            b'd' => {
                let end = run(r, &|b| b.is_ascii_digit());
                if end == r {
                    return false;
                }
                (p, r) = (p + 2, end);
            }
            b'[' => {
                let close = p + pattern[p..].iter().position(|&b| b == b']').unwrap();
                let set = &pattern[p + 2..close];
                let end = run(r, &|b| set.contains(&b));
                if end == r {
                    return false;
                }
                (p, r) = (close + 1, end);
            }
            other => panic!("`%{}' in a response pattern", other as char),
        }
    }
    r == reply.len()
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
/// parsed as the POSIX ERE terminfo writes it in, for a reader to hand to `regcomp`.
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
/// of. A mode on the `# declined-modes:` line answers 4, a mode answering 4 is on the
/// line, and no capability may set one: re-adding `flash` without DECSCNM is the case in point. And a query the
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
    // And the other way: a mode answered 4 and missing from the line is one the entry's
    // header has not been told about.
    for mode in (0..=u16::MAX).filter(|&n| crate::emu::term::modes::DecMode::try_from(n).is_ok()) {
        if decrqm(true, mode) == 4 {
            assert!(
                declined.contains(&mode),
                "?{mode} is answered 4 and is not on the declined-modes line"
            );
        }
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

    // A query the entry declares gets a reply, and the reply is the one the entry says
    // to expect in `rv` and `xr`. No reader is known to match against them (tmux parses
    // DA2 and XTVERSION replies itself), so what a drifting reply breaks is the entry's
    // own description of the terminal, which is still worth holding. Which capabilities
    // are queries is not a list kept here: `terminfo_sequences_are_all_recognised` fails
    // for any capability that is answered and has no pattern in `TERMINFO_QUERIES`.
    for &(query, pattern) in TERMINFO_QUERIES {
        let value = |name: &str| {
            capabilities
                .iter()
                .find(|(n, _)| *n == name)
                .unwrap_or_else(|| panic!("cooked.ti no longer declares `{name}'"))
                .1
        };
        let mut t = term(4, 8, &terminfo_decode(value(query)));
        let replies = reply_strings(&mut t);
        assert!(
            !replies.is_empty(),
            "`{query}' ({}) gets no reply",
            value(query)
        );
        let matches = |reply: &String| match pattern {
            "rv" | "xr" => ere_matches_whole(&terminfo_ere(value(pattern)), reply.as_bytes()),
            _ => terminfo_response_matches(value(pattern), reply.as_bytes()),
        };
        assert!(
            replies.iter().any(matches),
            "`{query}' is answered {:?}, which `{pattern}' ({}) does not match",
            replies,
            value(pattern)
        );
    }
}

/// Every capability that asks the terminal something, with the capability that says
/// what the answer looks like.
const TERMINFO_QUERIES: &[(&str, &str)] = &[("u7", "u6"), ("u9", "u8"), ("RV", "rv"), ("XR", "xr")];

/// The arguments the audit expands each parametrised capability with, one list per
/// expansion.
///
/// Chosen so that every branch of a conditional is taken by some expansion: `setaf`
/// at 1, 9 and 100 goes through its `3x`, `9x` and `38;5` arms. A parametrised
/// capability that is not listed here fails the audit, which is how a new one gets
/// arguments rather than going unchecked.
fn terminfo_arguments(name: &str) -> &'static [&'static [Arg]] {
    use Arg::{N, S};
    match name {
        "cub" | "cud" | "cuf" | "cuu" | "dch" | "dl" | "ech" | "hpa" | "ich" | "il" | "indn"
        | "rin" | "vpa" => &[&[N(2)]],
        "csr" | "cup" => &[&[N(1), N(3)]],
        // `%c`, so the character to repeat is given as its code.
        "rep" => &[&[N(b'x' as i64), N(3)]],
        "setaf" | "setab" => &[&[N(1)], &[N(9)], &[N(100)], &[N(0x12_34_56)]],
        "sgr" => &[
            &[],
            &[N(1), N(1), N(1), N(1), N(1), N(1), N(1), N(0), N(1)],
            &[N(0), N(0), N(0), N(0), N(0), N(0), N(1)],
        ],
        "setrgbf" | "setrgbb" => &[&[N(1), N(2), N(3)]],
        "Smulx" => &[&[N(3)]],
        "Setulc" => &[&[N(0x12_34_56)]],
        "Setulc1" => &[&[N(5)]],
        "Ss" => &[&[N(4)]],
        "XM" | "Sync" => &[&[N(1)], &[N(0)]],
        "Cs" => &[&[S("red")]],
        // The write, and the read form: `?` asks for the clipboard back.
        "Ms" => &[&[S("c"), S("aGk=")], &[S("c"), S("?")]],
        "Hls" => &[&[S("7"), S("https://example.com/")], &[S(""), S("")]],
        // A percentage, and tmux's -1 for a report that had none.
        "Spb" => &[&[N(1), N(42)], &[N(3), N(-1)]],
        _ => panic!("`{name}' is parametrised and the audit has no arguments for it"),
    }
}

/// The style the first cell of row 0 is drawn in after INPUT and an `x`.
fn style_after(input: &[u8]) -> Style {
    let mut t = term(2, 8, input);
    t.feed(b"x");
    run_style_at(&t, 0, 0)
}

/// Every sequence the entry says cooked understands is one cooked recognises.
///
/// The DECRQM audit above sees modes and a handful of queries. This feeds every other
/// string capability, parametrised ones expanded by [`terminfo_expand`], and asks the
/// core's count of sequences no arm recognised: `rep` with the `CSI b` arm deleted,
/// `indn` without `CSI S`, `E3` without `CSI 3 J`, all used to pass.
///
/// Recognised is not the same as acted on, for two families. An SGR the decoder
/// ignores is still a recognised `CSI m`, so each one must change the pen, either from
/// the default or from a pen with everything on, which is how a reset shows. And an
/// OSC is recognised by being handed to Lisp, so each one must at least arrive there.
///
/// Keys are what cooked sends rather than what it reads, and so are `PS` and `PE`, the
/// bracketed-paste markers; those are `cooked-terminfo-keys-are-what-cooked-sends`.
/// `rv`, `xr`, `u6`, `u8` and `xm` describe replies, and `acsc` is a table rather
/// than a sequence; see `terminfo_alternate_charset_draws_every_pair`.
#[test]
fn terminfo_sequences_are_all_recognised() {
    let replies_expected: Vec<&str> = TERMINFO_QUERIES.iter().map(|&(query, _)| query).collect();
    let full = b"\x1b[1;2;3;4;5;7;8;9;53;38;5;1;48;5;2;58;5;3m";
    let capabilities = terminfo_capabilities();
    let fsl = capabilities
        .iter()
        .find(|(name, _)| *name == "fsl")
        .expect("no `fsl'")
        .1;
    for &(name, value) in &capabilities {
        let not_a_sequence = value.is_empty()
            || name.starts_with('k')
            || ["PS", "PE", "rv", "xr", "u6", "u8", "xm", "acsc"].contains(&name);
        if not_a_sequence {
            continue;
        }
        let expansions: Vec<Vec<u8>> = if value.contains('%') {
            terminfo_arguments(name)
                .iter()
                .map(|args| terminfo_expand(value, args))
                .collect()
        } else {
            vec![terminfo_decode(value)]
        };
        for mut bytes in expansions {
            // `tsl' and `TS' open the status line and the title is written after them,
            // and `Swd' opens OSC 7 for a directory, so they are fed as a program uses
            // them: closed by `fsl'.
            if ["tsl", "TS", "Swd"].contains(&name) {
                bytes.extend(if name == "Swd" {
                    &b"file://host/tmp"[..]
                } else {
                    b"title"
                });
                bytes.extend(terminfo_decode(fsl));
            }
            let shown = String::from_utf8_lossy(&bytes).escape_debug().to_string();
            let mut t = term(4, 20, b"");
            t.feed(&bytes);
            assert_eq!(
                t.unrecognised(),
                0,
                "`{name}' sends {shown}, which nothing recognises"
            );

            let events = t.drain().events;
            if events.iter().any(|event| matches!(event, Event::Reply(_))) {
                assert!(
                    replies_expected.contains(&name),
                    "`{name}' ({shown}) is answered, and TERMINFO_QUERIES has no pattern for it"
                );
            }
            if bytes.starts_with(b"\x1b]") {
                assert!(
                    events.iter().any(|event| matches!(event, Event::Osc(..)))
                        || bytes.starts_with(b"\x1b]8;"),
                    "`{name}' sends {shown}, and nothing reaches Lisp"
                );
            }

            let sgr = bytes.starts_with(b"\x1b[")
                && bytes.ends_with(b"m")
                && !matches!(bytes.get(2), Some(b'>' | b'?'));
            if sgr {
                let changed_from_default = style_after(&bytes) != style_after(b"");
                let changed_from_full =
                    style_after(&[&full[..], &bytes].concat()) != style_after(full);
                assert!(
                    changed_from_default || changed_from_full,
                    "`{name}' sends {shown}, which changes nothing about the pen"
                );
            }
        }
    }
}

/// `acsc` pairs each VT100 line-drawing character with the one `smacs` makes of it, and
/// cooked draws every pair it lists: under `smacs` none of them is printed as itself.
#[test]
fn terminfo_alternate_charset_draws_every_pair() {
    let capabilities = terminfo_capabilities();
    let value = |name: &str| {
        capabilities
            .iter()
            .find(|(n, _)| *n == name)
            .unwrap_or_else(|| panic!("cooked.ti does not declare `{name}'"))
            .1
    };
    let keys: Vec<u8> = terminfo_decode(value("acsc"))
        .into_iter()
        .step_by(2)
        .collect();
    let mut input = terminfo_decode(value("smacs"));
    input.extend(&keys);
    let t = term(1, keys.len() + 1, &input);
    for (key, drawn) in keys.iter().zip(text(&t, 0).chars()) {
        assert_ne!(
            drawn, *key as char,
            "`acsc' lists `{}', and `smacs' prints it as itself",
            *key as char
        );
    }
}

/// The extended names tmux reads do what tmux will use them for.
///
/// The DECRQM check above already covers `Enfcs`, whose mode it can see. It cannot
/// see these four: modifyOtherKeys is not a mode, and OSC 8, OSC 7 and OSC 9;4 are not
/// control sequences at all. `Hls` is parametrised, so its value is pinned to tmux's own spelling in
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

    // `Swd' and `fsl' are what tmux's osc7 feature writes around the active pane's
    // path, and together they must be the OSC 7 the Lisp side tracks, with the
    // terminator tmux actually sends.
    assert_eq!(value("Swd"), r"\E]7;");
    let mut path = terminfo_decode(value("Swd"));
    path.extend_from_slice(b"file://h/tmp");
    path.extend(terminfo_decode(value("fsl")));
    let mut t = term(2, 8, &path);
    assert_eq!(
        t.drain().events,
        vec![Event::Osc(7, vec!["file://h/tmp".into()], Terminator::Bel)],
        "`Swd'"
    );

    // `Spb' is what tmux's progressbar feature writes the active pane's OSC 9;4 report
    // with, always as a state and a percentage, so a report with no percentage goes out
    // with -1. Both must reach Lisp as the parts `cooked--osc-progress' reads, and the
    // Lisp side's reading of -1 is `cooked-progress-arrives-through-tmux-spb'.
    assert_eq!(value("Spb"), r"\E]9;4;%p1%d;%p2%d\E\\");
    let mut t = term(
        2,
        8,
        &terminfo_expand(value("Spb"), &[Arg::N(3), Arg::N(-1)]),
    );
    assert_eq!(
        t.drain().events,
        vec![Event::Osc(
            9,
            vec!["4".into(), "3".into(), "-1".into()],
            Terminator::St
        )],
        "`Spb'"
    );

    // `ol' is tmux's name for SGR 59 and not ncurses', which has no `ol' at all, so
    // nothing but tmux's own `usstyle' check says what it should be. tmux sends it to
    // take a cell's underline colour back to the default.
    let mut reset = b"\x1b[4m\x1b[58;5;196m".to_vec();
    reset.extend(terminfo_decode(value("ol")));
    reset.push(b'x');
    let t = term(2, 8, &reset);
    assert_eq!(run_style_at(&t, 0, 0).underline, Color::Default, "`ol'");
}
