//! The terminfo entries cooked ships, read from `terminfo/cooked.ti` so the core can
//! answer for them in band.
//!
//! The file is compiled into the module with `include_str!` and parsed once, the first
//! time a child asks. That is what "the reply is the entry" comes to: there is no second
//! list of capabilities anywhere in the core to fall out of step with the first, and a
//! rebuild after an edit to `cooked.ti` answers with the edit. A build script generating
//! a table would say the same thing at more cost -- the crate has none, and parsing three
//! hundred short lines once per process is not a cost worth adding one for.
//!
//! The parser is for this file and not for terminfo at large. It reads what `tic` reads
//! in the shapes the file uses -- one entry per name line, capabilities after it,
//! `use=` resolved, `@` cancellations honoured -- and leaves out what the file will never
//! contain, such as termcap-style `:` continuations. `terminfo_entry_is_answered_in_full`
//! in the terminal tests is what stops that from becoming a silent gap: every capability
//! line in the file must come back from a query.

use std::sync::OnceLock;

const SOURCE: &str = include_str!("../../terminfo/cooked.ti");

/// A capability's value, as the source spells it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Value {
    Bool,
    Number(u32),
    /// Undecoded: `\E` is still two characters here. See [`Value::reply`] for why the
    /// decision to decode waits until a reply is being built.
    Str(&'static str),
}

impl Value {
    /// The bytes XTGETTCAP sends for this value, before they are hex-encoded.
    ///
    /// A boolean has no value at all, and a number is sent in decimal whatever base the
    /// source wrote it in -- `colors#0x100` answers `256`. Strings follow the split
    /// ghostty adopted from what clients already expect (`src/terminfo/Source.zig`,
    /// `xtgettcapMap`): one with no `%` parameters is sent as the bytes it produces,
    /// because xterm's original answers were for keys and those are compared against
    /// what arrives on the wire; one with parameters is sent in source form, because
    /// there are no bytes until the parameters are known, and that is what kitty sends
    /// and what neovim parses. Decoding `setrgbf` would hand a client a string with the
    /// `%p1%d` already expanded into nothing.
    pub(crate) fn reply(self) -> Vec<u8> {
        match self {
            Value::Bool => Vec::new(),
            Value::Number(n) => n.to_string().into_bytes(),
            Value::Str(s) if s.contains('%') => s.as_bytes().to_vec(),
            Value::Str(s) => decode(s),
        }
    }
}

/// One entry of the file, with `use=` already folded in.
#[derive(Debug)]
pub(crate) struct Entry {
    /// Every name the entry answers to, the primary one first. The long description
    /// that ends a name line is not among them.
    pub(crate) names: Vec<&'static str>,
    /// In the order the source gives them, the entry's own before any it inherited.
    pub(crate) capabilities: Vec<(&'static str, Value)>,
}

impl Entry {
    pub(crate) fn get(&self, name: &str) -> Option<Value> {
        self.capabilities
            .iter()
            .find_map(|&(cap, value)| (cap == name).then_some(value))
    }

    /// What XTGETTCAP answers for NAME, or `None` for a miss.
    ///
    /// The entry first, and then the two names xterm answers that are not capabilities
    /// at all: `TN`, the terminal's name, and `Co`, termcap's spelling of `colors`, which
    /// is what older clients ask for. Both are the entry's own facts under another name
    /// rather than anything added, so an entry that ever declares either itself wins.
    ///
    /// `RGB` is deliberately not synthesised the way ghostty does. `cooked.ti` argues at
    /// length that `RGB` is a claim about `setaf`, true of `cooked-direct` and false of
    /// `cooked-256color`, and an in-band answer that claimed it for both would be the
    /// very falsehood the file refuses to write down. It is answered where it is
    /// declared, and a client wanting direct colour from the indexed entry finds `Tc`.
    pub(crate) fn answer(&self, name: &str) -> Option<Vec<u8>> {
        if let Some(value) = self.get(name) {
            return Some(value.reply());
        }
        match name {
            "TN" => Some(self.names[0].as_bytes().to_vec()),
            "Co" => self.get("colors").map(Value::reply),
            _ => None,
        }
    }
}

/// Every entry in the file.
pub(crate) fn entries() -> &'static [Entry] {
    static ENTRIES: OnceLock<Vec<Entry>> = OnceLock::new();
    ENTRIES.get_or_init(|| resolve(parse(SOURCE)))
}

/// The entry TERM names, if it names one of ours.
pub(crate) fn entry(name: &str) -> Option<&'static Entry> {
    entries().iter().find(|e| e.names.contains(&name))
}

/// The entry to answer from when TERM names none of ours: the first in the file, which
/// is the one `cooked-term-name` defaults to.
///
/// A child told `xterm-256color` -- because `cooked-term-name` is nil, or because it
/// crossed an ssh hop that rewrote TERM -- is still talking to cooked, and XTGETTCAP is
/// precisely the question asked by a child that cannot trust TERM. Answering from
/// xterm's entry would mean shipping xterm's claims, which is what `cooked.ti` exists not
/// to do; answering nothing would leave that child where it was without one.
pub(crate) fn default_entry() -> &'static Entry {
    &entries()[0]
}

/// An entry as written: names, then its fields in order, `use=` unexpanded.
struct Raw {
    names: Vec<&'static str>,
    fields: Vec<&'static str>,
}

fn parse(source: &'static str) -> Vec<Raw> {
    let mut entries: Vec<Raw> = Vec::new();
    for line in source.lines() {
        if line.trim().is_empty() || line.starts_with('#') {
            continue;
        }
        let continuation = line.starts_with([' ', '\t']);
        let mut fields = split_fields(line.trim());
        if !continuation {
            let header = fields.next().unwrap_or("");
            let mut names: Vec<&str> = header.split('|').collect();
            if names.len() > 1 {
                names.pop();
            }
            entries.push(Raw {
                names,
                fields: Vec::new(),
            });
        }
        if let Some(entry) = entries.last_mut() {
            entry.fields.extend(fields);
        }
    }
    entries
}

/// The comma-separated fields of LINE, a comma escaped by a backslash or a caret
/// being part of its value rather than the end of it.
fn split_fields(line: &'static str) -> impl Iterator<Item = &'static str> {
    let bytes = line.as_bytes();
    let mut start = 0;
    let mut at = 0;
    std::iter::from_fn(move || {
        while at < bytes.len() {
            match bytes[at] {
                b'\\' | b'^' => at += 2,
                b',' => {
                    let field = line[start..at].trim();
                    at += 1;
                    start = at;
                    if !field.is_empty() {
                        return Some(field);
                    }
                }
                _ => at += 1,
            }
        }
        let field = line.get(start..).unwrap_or("").trim();
        start = bytes.len();
        (!field.is_empty()).then_some(field)
    })
}

/// Fold each entry's `use=` into it, in the precedence `tic` gives it: a capability
/// already present, or cancelled with `@`, is not overwritten by one inherited.
fn resolve(raw: Vec<Raw>) -> Vec<Entry> {
    fn fill(
        raw: &[Raw],
        index: usize,
        depth: usize,
        out: &mut Vec<(&'static str, Value)>,
        cancelled: &mut Vec<&'static str>,
    ) {
        // `tic` refuses a loop; a file that had one would not have compiled, so this is
        // only a guard against hanging on it.
        if depth > 16 {
            return;
        }
        for &field in &raw[index].fields {
            if let Some(parent) = field.strip_prefix("use=") {
                if let Some(at) = raw.iter().position(|r| r.names.contains(&parent)) {
                    fill(raw, at, depth + 1, out, cancelled);
                }
                continue;
            }
            let (name, value) = field_value(field);
            if out.iter().any(|&(n, _)| n == name) || cancelled.contains(&name) {
                continue;
            }
            match value {
                Some(value) => out.push((name, value)),
                None => cancelled.push(name),
            }
        }
    }

    (0..raw.len())
        .map(|index| {
            let mut capabilities = Vec::new();
            fill(&raw, index, 0, &mut capabilities, &mut Vec::new());
            Entry {
                names: raw[index].names.clone(),
                capabilities,
            }
        })
        .collect()
}

/// A field's name and value, `None` for a cancellation.
fn field_value(field: &'static str) -> (&'static str, Option<Value>) {
    let Some(at) = field.find(['=', '#', '@']) else {
        return (field, Some(Value::Bool));
    };
    let (name, rest) = (&field[..at], &field[at + 1..]);
    let value = match field.as_bytes()[at] {
        b'=' => Some(Value::Str(rest)),
        b'#' => Some(Value::Number(parse_number(rest))),
        _ => None,
    };
    (name, value)
}

/// A numeric capability in any of the three bases `tic` accepts.
fn parse_number(s: &str) -> u32 {
    let parsed = if let Some(hex) = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
        u32::from_str_radix(hex, 16)
    } else if s.len() > 1 && s.starts_with('0') {
        u32::from_str_radix(&s[1..], 8)
    } else {
        s.parse()
    };
    parsed.unwrap_or(0)
}

/// The bytes a terminfo string with no parameters sends.
///
/// The escapes are terminfo(5)'s. One is not what it looks like: `\0` is stored as
/// `\200`, because terminfo strings are NUL-terminated and ncurses writes the high byte
/// out as a NUL. Nothing in the file uses it, and it is here so a later use is not
/// quietly mis-sent.
pub(crate) fn decode(value: &str) -> Vec<u8> {
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut at = 0;
    while at < bytes.len() {
        let b = bytes[at];
        at += 1;
        match b {
            b'\\' if at < bytes.len() => {
                let e = bytes[at];
                at += 1;
                out.push(match e {
                    b'E' | b'e' => 0x1b,
                    b'n' | b'l' => b'\n',
                    b'r' => b'\r',
                    b't' => b'\t',
                    b'b' => 0x08,
                    b'f' => 0x0c,
                    b's' => b' ',
                    b'a' => 0x07,
                    b'0'..=b'7' => {
                        let mut n = u32::from(e - b'0');
                        for _ in 0..2 {
                            match bytes.get(at) {
                                Some(&d @ b'0'..=b'7') => {
                                    n = n * 8 + u32::from(d - b'0');
                                    at += 1;
                                }
                                _ => break,
                            }
                        }
                        if n == 0 { 0x80 } else { n as u8 }
                    }
                    other => other,
                });
            }
            b'^' if at < bytes.len() => {
                let c = bytes[at];
                at += 1;
                out.push(if c == b'?' { 0x7f } else { c & 0x1f });
            }
            _ => out.push(b),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn escapes_decode_to_what_they_send() {
        assert_eq!(decode("^G"), b"\x07");
        assert_eq!(decode("^?"), b"\x7f");
        assert_eq!(decode("\\E]112\\007"), b"\x1b]112\x07");
        assert_eq!(decode("\\E\\\\[>0;0;0c"), b"\x1b\\[>0;0;0c");
        assert_eq!(decode("\\r\\n\\s\\,"), b"\r\n ,");
    }

    #[test]
    fn numbers_are_read_in_every_base() {
        assert_eq!(parse_number("0x100"), 256);
        assert_eq!(parse_number("010"), 8);
        assert_eq!(parse_number("80"), 80);
        assert_eq!(parse_number("0"), 0);
    }

    #[test]
    fn a_parametrised_string_is_sent_as_written() {
        assert_eq!(
            Value::Str("\\E[38:2::%p1%d:%p2%d:%p3%dm").reply(),
            b"\\E[38:2::%p1%d:%p2%d:%p3%dm"
        );
    }

    #[test]
    fn use_is_resolved_with_the_child_winning() {
        let direct = entry("cooked-direct").expect("cooked-direct is in the file");
        let indexed = entry("cooked-256color").expect("cooked-256color is in the file");
        assert_ne!(direct.get("setaf"), indexed.get("setaf"));
        assert_eq!(direct.get("Tc"), Some(Value::Bool));
        assert_eq!(direct.get("RGB"), Some(Value::Bool));
        assert_eq!(indexed.get("RGB"), None);
        assert_eq!(direct.answer("Co").as_deref(), Some(&b"16777216"[..]));
        assert_eq!(indexed.answer("Co").as_deref(), Some(&b"256"[..]));
        assert_eq!(
            entry("cooked").unwrap().answer("TN").as_deref(),
            Some(&b"cooked"[..])
        );
    }

    #[test]
    fn a_cancellation_stops_inheritance() {
        let raw = parse("parent|p,\n\tam,\n\tbel=^G,\nchild|c,\n\tam@,\n\tuse=parent,\n");
        let child = &resolve(raw)[1];
        assert_eq!(child.get("am"), None);
        assert_eq!(child.get("bel"), Some(Value::Str("^G")));
    }
}
