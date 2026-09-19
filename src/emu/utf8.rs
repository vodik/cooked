//! Bytes into text: the one place a terminal's output is read as UTF-8.
//!
//! The parser does not do this. What it knows about text is that it is not a control: a
//! run of bytes from `0x20` up is handed over as it arrived, cut wherever a read happened
//! to end, and the grammar of escape sequences is seven-bit and indifferent to what the
//! eighth bit means. That the bytes are UTF-8 is a fact about this terminal rather than
//! about terminals, so it lives with the two things that draw text -- the grid and the
//! comint filter -- and both read it through [`Decoder`], which is why they cannot
//! disagree about what an ill-formed sequence looks like.
//!
//! ## One pass
//!
//! Decoding a sequence *is* validating it: the same bytes are loaded and the same ranges
//! tested, and assembling the code point on the way costs a shift and an or. So nothing
//! here validates and then decodes. [`Decoder::next`] walks the bytes once and yields what a
//! printer wants in the shape it wants it: printable ASCII as a run, since a byte of it is
//! a cell and a printer can lay a run of them without looking at each, and anything else a
//! code point at a time, since every question asked of it -- how wide, does it join the
//! cell before -- is asked of a code point.
//!
//! ## What never comes out
//!
//! A control character. C0 never goes in, because the parser executes it. DEL is dropped,
//! as every VT since the VT100 has dropped it. The C1 controls `U+0080..=U+009F` are
//! dropped too: nothing here acts on one, the terminals a child is likely to have been
//! tested against (kitty, foot, ghostty) do not honour them in UTF-8 mode, and all of them
//! are zero width, so one that reached a printer would be folded onto the cell to its left
//! like a combining mark and a control character would be sitting in an Emacs buffer.
//!
//! ## Ill-formed input
//!
//! Each maximal ill-formed subsequence becomes one `U+FFFD`, which is the Unicode
//! recommendation and what [`String::from_utf8_lossy`] does -- the tests hold this to
//! exactly that function's answer, for every way of cutting the input into reads.

use super::text::printable_ascii_len;

/// What [`Decoder::next`] yields.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Piece<'a> {
    /// A run of printable ASCII, `0x20..=0x7e`: a byte is a character is a cell.
    Ascii(&'a [u8]),
    /// One code point that is not ASCII and not a control, or `U+FFFD` for bytes that
    /// were not one.
    Char(char),
}

/// A sequence the end of a read cut short, waiting for the rest.
///
/// Holds what reading it has established rather than the bytes that were read, so there
/// is nothing to read again when the rest arrives and no way to hold bytes that are not
/// the start of a sequence: a [`Partial`] can only be begun from a lead byte and only
/// grows by a byte that continues it.
#[derive(Debug, Default, Clone, Copy)]
pub(crate) struct Decoder(Option<Partial>);

impl Decoder {
    /// The next piece of REST, which is advanced past it, read as the text that follows
    /// whatever the last call read. `None` when REST is used up, which is also when a
    /// sequence it ends inside is taken in to wait.
    ///
    /// A call at a time rather than an iterator, so that the decoder is only borrowed
    /// while it is looking: the piece borrows from REST, and the caller is free to draw
    /// it through the same `self` the decoder lives in.
    #[inline]
    pub(crate) fn next<'b>(&mut self, rest: &mut &'b [u8]) -> Option<Piece<'b>> {
        loop {
            if let Some(partial) = self.0.take() {
                let Some((&byte, tail)) = rest.split_first() else {
                    self.0 = Some(partial);
                    return None;
                };
                match partial.push(byte) {
                    Pushed::Done(c) => {
                        *rest = tail;
                        if !is_c1(c) {
                            return Some(Piece::Char(c));
                        }
                    }
                    Pushed::More(partial) => {
                        *rest = tail;
                        self.0 = Some(partial);
                    }
                    // BYTE is not taken: it ended the sequence by not belonging to it,
                    // and is read afresh on the way round.
                    Pushed::Rejected => return Some(Piece::Char(char::REPLACEMENT_CHARACTER)),
                }
                continue;
            }
            let &first = rest.first()?;
            if first < 0x80 {
                let ascii = printable_ascii_len(rest);
                if ascii == 0 {
                    // DEL, or a C0 control the parser should have kept.
                    debug_assert_eq!(first, 0x7f);
                    *rest = &rest[1..];
                    continue;
                }
                let (run, tail) = rest.split_at(ascii);
                *rest = tail;
                return Some(Piece::Ascii(run));
            }
            if let Some((c, len)) = whole(rest) {
                *rest = &rest[len..];
                if !is_c1(c) {
                    return Some(Piece::Char(c));
                }
                continue;
            }
            *rest = &rest[1..];
            match Partial::begin(first) {
                Some(partial) => self.0 = Some(partial),
                // A continuation byte with nothing to continue, or a byte no sequence
                // contains.
                None => return Some(Piece::Char(char::REPLACEMENT_CHARACTER)),
            }
        }
    }

    /// Give up on a held sequence, because what followed it was not text and so cannot
    /// complete it. `U+FFFD` if there was one, for the caller to print.
    ///
    /// For every dispatch that is not a print, which is the rule
    /// [`Segmenter`](super::text::Segmenter) is reset by, and for the same reason.
    #[inline]
    pub(crate) fn flush(&mut self) -> Option<char> {
        self.0.take().map(|_| char::REPLACEMENT_CHARACTER)
    }
}

/// How many continuation bytes a sequence is still owed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Owed {
    One,
    Two,
    Three,
}

/// A multi-byte sequence that has begun well and is not finished.
///
/// Table 3-7 of the Unicode standard, "Well-Formed UTF-8 Byte Sequences", a byte at a
/// time. The range the *second* byte may fall in depends on the first, which is what
/// rules out overlong forms, the surrogates and everything past `U+10FFFF`; every byte
/// after it is a plain continuation. So a sequence in progress is its bits so far, the
/// bytes it is owed, and the range the next of them has to fall in.
#[derive(Debug, Clone, Copy)]
struct Partial {
    bits: u32,
    owed: Owed,
    next: (u8, u8),
}

/// What [`Partial::push`] made of a byte.
enum Pushed {
    /// The byte finished the sequence.
    Done(char),
    /// The byte continued it, and it is owed more.
    More(Partial),
    /// The byte does not continue it. What there was of the sequence is one maximal
    /// ill-formed subsequence, and the byte is somebody else's.
    Rejected,
}

impl Partial {
    /// The sequence LEAD opens, or `None` if no sequence opens with it.
    #[inline]
    fn begin(lead: u8) -> Option<Self> {
        let (owed, next, mask) = match lead {
            0xC2..=0xDF => (Owed::One, (0x80, 0xBF), 0x1F),
            0xE0 => (Owed::Two, (0xA0, 0xBF), 0x0F),
            0xE1..=0xEC | 0xEE..=0xEF => (Owed::Two, (0x80, 0xBF), 0x0F),
            0xED => (Owed::Two, (0x80, 0x9F), 0x0F),
            0xF0 => (Owed::Three, (0x90, 0xBF), 0x07),
            0xF1..=0xF3 => (Owed::Three, (0x80, 0xBF), 0x07),
            0xF4 => (Owed::Three, (0x80, 0x8F), 0x07),
            _ => return None,
        };
        let bits = u32::from(lead & mask);
        Some(Self { bits, owed, next })
    }

    /// The sequence with BYTE added to it, if BYTE is what it was owed.
    #[inline]
    fn push(self, byte: u8) -> Pushed {
        let (low, high) = self.next;
        if byte < low || byte > high {
            return Pushed::Rejected;
        }
        let bits = self.bits << 6 | u32::from(byte & 0x3F);
        let owed = match self.owed {
            // The ranges admit only scalar values, so this is never the fallback.
            Owed::One => {
                return Pushed::Done(char::from_u32(bits).unwrap_or(char::REPLACEMENT_CHARACTER));
            }
            Owed::Two => Owed::One,
            Owed::Three => Owed::Two,
        };
        let next = (0x80, 0xBF);
        Pushed::More(Self { bits, owed, next })
    }
}

/// The well-formed sequence BYTES opens with and how long it is, if it is one and there
/// are four bytes to look at.
///
/// The way nearly every character is read, and only a shortcut: what it declines --
/// ill formed, or within three bytes of the end -- goes a byte at a time through
/// [`Partial`], which is the definition. With the whole sequence in hand the table
/// collapses: every byte after the first is a plain continuation, and what the narrower
/// second-byte ranges exclude is exactly the values a sequence of that length must not
/// spell.
#[inline]
fn whole(bytes: &[u8]) -> Option<(char, usize)> {
    let [first, second, third, fourth, ..] = *bytes else {
        return None;
    };
    let continues = |byte: u8| (byte as i8) < -64;
    let bits = |byte: u8, mask: u8| u32::from(byte & mask);
    match first {
        0xC2..=0xDF if continues(second) => {
            let value = bits(first, 0x1F) << 6 | bits(second, 0x3F);
            char::from_u32(value).map(|c| (c, 2))
        }
        0xE0..=0xEF if continues(second) && continues(third) => {
            let value = bits(first, 0x0F) << 12 | bits(second, 0x3F) << 6 | bits(third, 0x3F);
            // `from_u32` refuses the surrogates; the bound refuses the overlong forms.
            char::from_u32(value)
                .filter(|_| value >= 0x800)
                .map(|c| (c, 3))
        }
        0xF0..=0xF4 if continues(second) && continues(third) && continues(fourth) => {
            let value = bits(first, 0x07) << 18
                | bits(second, 0x3F) << 12
                | bits(third, 0x3F) << 6
                | bits(fourth, 0x3F);
            // `from_u32` refuses what lies past U+10FFFF; the bound, the overlong forms.
            char::from_u32(value)
                .filter(|_| value >= 0x1_0000)
                .map(|c| (c, 4))
        }
        _ => None,
    }
}

/// Whether C is a C1 control; see the module comment.
#[inline]
fn is_c1(c: char) -> bool {
    matches!(c, '\u{80}'..='\u{9f}')
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    /// BYTES read in the pieces CUTS divide it into, then flushed, as one string.
    fn read(bytes: &[u8], cuts: &[usize]) -> String {
        let mut decoder = Decoder::default();
        let mut out = String::new();
        let mut from = 0;
        for end in cuts.iter().copied().chain([bytes.len()]) {
            let end = end.clamp(from, bytes.len());
            let mut rest = &bytes[from..end];
            while let Some(piece) = decoder.next(&mut rest) {
                match piece {
                    Piece::Ascii(run) => {
                        assert!(!run.is_empty());
                        assert!(run.iter().all(|b| (0x20..0x7f).contains(b)));
                        out.push_str(std::str::from_utf8(run).unwrap());
                    }
                    Piece::Char(c) => {
                        assert!(!c.is_ascii() && !c.is_control(), "{c:?}");
                        out.push(c);
                    }
                }
            }
            from = end;
        }
        out.extend(decoder.flush());
        out
    }

    /// What BYTES should read as: the standard library's lossy decoding, less the
    /// controls that are dropped.
    fn expected(bytes: &[u8]) -> String {
        String::from_utf8_lossy(bytes)
            .chars()
            .filter(|c| !c.is_control())
            .collect()
    }

    #[test]
    fn text_in_one_piece() {
        assert_eq!(read("plain".as_bytes(), &[]), "plain");
        assert_eq!(
            read("na\u{ef}ve \u{65e5}\u{672c} \u{1f600}!".as_bytes(), &[]),
            "na\u{ef}ve \u{65e5}\u{672c} \u{1f600}!"
        );
    }

    #[test]
    fn del_and_c1_are_dropped() {
        assert_eq!(read("a\x7fb\u{85}c\u{9b}d".as_bytes(), &[]), "abcd");
    }

    #[test]
    fn each_ill_formed_subsequence_is_one_replacement() {
        // A lone continuation, an overlong form, a surrogate, a truncated sequence that
        // ASCII interrupts, one past U+10FFFF, and one the input ends inside.
        for bytes in [
            &b"a\x80b"[..],
            b"\xC0\xAF",
            b"\xED\xA0\x80",
            b"\xE2\x82a",
            b"\xF4\x90\x80\x80",
            b"ok\xF0\x9F\x98",
        ] {
            assert_eq!(read(bytes, &[]), expected(bytes), "{bytes:?}");
        }
    }

    #[test]
    fn a_sequence_cut_anywhere_reads_the_same() {
        let bytes = "a\u{e9}\u{20ac}\u{1f600}\u{9b}z".as_bytes();
        for one in 0..=bytes.len() {
            for two in one..=bytes.len() {
                assert_eq!(
                    read(bytes, &[one, two]),
                    "a\u{e9}\u{20ac}\u{1f600}z",
                    "{one} {two}"
                );
            }
        }
    }

    /// Bytes weighted towards the interesting ones: leads, continuations, the edges of
    /// the second-byte ranges, DEL, and enough ASCII to make runs.
    fn bytes() -> impl Strategy<Value = Vec<u8>> {
        let byte = prop_oneof![
            4 => 0x20u8..0x7f,
            1 => Just(0x7fu8),
            3 => 0x80u8..=0xBF,
            3 => 0xC0u8..=0xF7,
            1 => prop::sample::select(vec![0x9F, 0xA0, 0x8F, 0x90, 0xED, 0xE0, 0xF0, 0xF4, 0xC2]),
            1 => 0xF8u8..=0xFF,
        ];
        prop::collection::vec(byte, 0..48)
    }

    proptest! {
        /// Whatever the bytes and wherever the reads fall, the answer is the standard
        /// library's.
        #[test]
        fn any_bytes_cut_anywhere_read_as_the_lossy_decoding(
            bytes in bytes(),
            cuts in prop::collection::vec(0usize..48, 0..6),
        ) {
            let mut cuts = cuts;
            cuts.sort_unstable();
            prop_assert_eq!(read(&bytes, &cuts), expected(&bytes));
        }
    }
}
