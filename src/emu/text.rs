//! How many cells a piece of text stands on, and where one piece ends and the next
//! begins.
//!
//! Both questions come from the same document: kitty's [text sizing protocol], whose
//! "algorithm for splitting text into cells" is the only written-down statement of what
//! a terminal is supposed to do here. It is worth having in one place because the two
//! halves are not separable — a width is a property of a *grapheme cluster*, not of a
//! code point. A ZWJ emoji family (`👨‍👩‍👧`) is five code points, three of which a
//! per-character table calls two columns wide, so asking one code point at a time would
//! put it on six cells instead of the two the child laid out for.
//!
//! ## Streaming, not batching
//!
//! The spec's algorithm is written per code point rather than per string, and that is
//! not an accident of presentation — a terminal receives bytes, and a cluster can be
//! split across two `read(2)`s with a scheduling gap in the middle. So [`Segmenter`]
//! holds the code points already on the cell under the cursor and answers, for each new
//! code point, one question: does a cluster boundary fall between them? No boundary
//! means the code point joins the cell before it and costs no columns of its own,
//! whatever a width table says about it in isolation. That single rule is what collapses
//! the family emoji back to two cells, and it is why nothing here iterates graphemes on
//! the hot path.
//!
//! The state is reset by anything that is not a print — see the `Perform` impl in
//! `term/perform.rs` — because "the cell before the cursor" only means something when
//! this side put it there. The spec's own phrasing is a previous cell "at x-1 on the
//! same line, or the last cell of the previous line, provided there is no line break";
//! a cursor address, an erase or a scroll in between makes that cell somebody else's.
//!
//! ## Where this leans on `unicode-width` and where it corrects it
//!
//! The spec's width classification — regional indicators two, East Asian `W`/`F` two,
//! the CJK ranges two unless `Ambiguous`, `Basic_Emoji` and emoji modifier sequences
//! two, marks and `Cf` zero, everything else one — is very nearly `unicode-width`'s own
//! model, which the crate already carried and the grid already applied. Reimplementing
//! it would mean vendoring `EastAsianWidth.txt` and `emoji-sequences.txt` and keeping
//! them current, to disagree with the shipped tables in one place. So this defers, and
//! states the two disagreements outright. The second, a cap of two columns on any one
//! cluster, is written up on [`cluster_cells`]. The first is a **lone regional
//! indicator**. `unicode-width` gives `U+1F1E6..=U+1F1FF` one column each, since their East Asian Width is Neutral;
//! the spec gives them two. A *pair* of them is one cluster either way and comes out at
//! two columns under both readings, so the correction only shows on an unpaired one —
//! half a flag, which is what a truncated line of output leaves behind.
//!
//! Variation selectors are `unicode-width`'s job too, and the reason [`cluster_cells`]
//! measures the whole cluster rather than its first code point: `U+FE0F` after a
//! `Basic_Emoji` code point widens it to two, `U+FE0E` narrows it to one, and both are
//! retroactive — the cell was already written when the selector arrives. `Screen::join`
//! is what carries that back onto the grid.
//!
//! ## Mode 2027
//!
//! Contour's [terminal-unicode-core] draft defines DEC private mode 2027 as a promise
//! that the terminal segments by grapheme cluster, which is what this module does
//! unconditionally, so `CSI ? 2027 $ p` answers 3, permanently set, and a set or reset
//! of it changes nothing. There is one place this module and that draft part company,
//! and it is on purpose: the draft says `U+FE0E` changes presentation and *not* width,
//! so `⌚︎` stays two columns. Kitty's spec narrows it to one, `unicode-width` does, and
//! ghostty — whose mode 2027 names the same draft — does too; contour is alone in the
//! literal reading. A child measuring with Rust's `unicode-width` gets the narrow
//! answer, and so does one written against kitty or ghostty; that column is the one
//! this has to match. The corpus that pins every rule the mode is about, and this divergence with it, is
//! `mode_2027_corpus` in `term/tests/text.rs`.
//!
//! [text sizing protocol]: https://sw.kovidgoyal.net/kitty/text-sizing-protocol/
//! [terminal-unicode-core]: https://github.com/contour-terminal/terminal-unicode-core

use unicode_segmentation::{GraphemeCursor, UnicodeSegmentation};
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

/// The regional indicators, `U+1F1E6..=U+1F1FF`: the 26 code points that pair up into
/// flags. Two columns each by the spec, one each by `unicode-width`; see the module
/// header for why this is the only override.
const REGIONAL: std::ops::RangeInclusive<char> = '\u{1F1E6}'..='\u{1F1FF}';

/// How far a single cell's cluster is allowed to grow before a boundary is forced.
///
/// A grapheme cluster has no length limit in Unicode, and a child can emit combining
/// marks forever; retaining all of them would be an unbounded allocation per cell driven
/// by the far end of a pipe, and every joining code point re-runs a boundary scan over
/// the retained text, so it would be quadratic as well. 512 bytes is far past any
/// cluster a writing system produces — the longest in the Unicode test data are a few
/// dozen — and what lies beyond it is a Zalgo bomb, for which "start a new cell" is a
/// perfectly good answer.
const MAX_CLUSTER: usize = 512;

/// How many of BYTES, from the start, are printable ASCII: `0x20..=0x7e`.
///
/// Exactly the characters that are one byte in the stream, one column on the grid, never
/// zero-width and never a control, which is what lets both printers write a run of them
/// without asking the segmenter about each. DEL is outside it: it is not a control to the
/// parser, and it has no width.
///
/// Eight bytes at a time, since this is the scan ordinary output spends its life in: the
/// decoder runs it to find every run a printer lays. `parser::text_len` is its sibling.
#[inline]
pub(crate) fn printable_ascii_len(bytes: &[u8]) -> usize {
    const ONES: u64 = u64::MAX / 255;
    const HIGH: u64 = ONES * 0x80;
    let mut chunks = bytes.chunks_exact(8);
    let mut len = 0;
    for chunk in &mut chunks {
        let word = u64::from_le_bytes(chunk.try_into().unwrap());
        // The classic zero-byte test, asked of `word - 0x20` for "below a space" and of
        // `word ^ 0x7f` for DEL, beside the high bits themselves. A borrow can raise a
        // false flag only in a byte *above* a true one, and the lowest flag is the only
        // one read, so the position is exact.
        let below = word.wrapping_sub(ONES * 0x20) & !word;
        let del = word ^ (ONES * 0x7f);
        let del = del.wrapping_sub(ONES) & !del;
        let stop = (word | below | del) & HIGH;
        if stop != 0 {
            return len + stop.trailing_zeros() as usize / 8;
        }
        len += 8;
    }
    len + chunks
        .remainder()
        .iter()
        .take_while(|&&b| (0x20..0x7f).contains(&b))
        .count()
}

/// Whether TEXT holds a control character: C0, DEL or C1.
///
/// The one test for text that is about to be framed into a reply or handed to Emacs to
/// act on, where any of the three can end a sequence early or start one of its own.
pub(crate) fn has_control(text: &str) -> bool {
    text.chars().any(char::is_control)
}

/// Whether C always opens a two-column cell of its own; see [`Segmenter::push`].
///
/// Kana and the two large blocks of unified ideographs. Drawn narrowly on purpose: the
/// blocks around them are where the exceptions are. The combining voicing marks `U+3099`
/// and `U+309A` sit inside the Hiragana block, `U+3030` and `U+303D` among the CJK symbols
/// are `Extended_Pictographic`, as are `U+3297` and `U+3299` among the enclosed ones, and
/// a precomposed Hangul syllable is `LV` or `LVT`, which a leading jamo joins. A test
/// holds every code point admitted here to what `unicode-width` and
/// `unicode-segmentation` say about it.
#[inline]
fn opens_wide_cell(c: char) -> bool {
    matches!(c,
        '\u{3041}'..='\u{3096}'       // Hiragana letters
        | '\u{30A0}'..='\u{30FF}'     // Katakana
        | '\u{3400}'..='\u{4DBF}'     // CJK Unified Ideographs Extension A
        | '\u{4E00}'..='\u{9FFF}'     // CJK Unified Ideographs
    )
}

/// Columns one code point stands on, in isolation.
///
/// "In isolation" is the caveat that matters: this is only the right answer for the
/// *first* code point of a cluster, which is the only place [`Segmenter`] calls it.
/// Everything after that joins the cell and costs nothing, however wide it would be on
/// its own.
pub(crate) fn char_cells(c: char) -> usize {
    if REGIONAL.contains(&c) {
        return 2;
    }
    c.width().unwrap_or(0)
}

/// Columns a whole grapheme cluster stands on.
///
/// `unicode-width`'s string form rather than a sum over the characters, because the
/// cases that differ are exactly the ones this module is for: a fully-qualified emoji
/// ZWJ sequence is two columns and not two per member, an emoji modifier sequence is
/// two and not four, and a variation selector moves its base between one and two.
///
/// The regional-indicator override applies to a cluster that *starts* with one, which
/// covers both a lone indicator and a well-formed flag pair — the pair already measures
/// two, so stating it this way costs nothing and keeps the two functions agreeing.
///
/// The result is capped at two, which is the second correction to `unicode-width`. Its
/// string form sums what it does not recognise as a sequence, so a cluster UAX#29 glues
/// together out of parts no emoji table lists comes out wider than any one cell can be:
/// `a` followed by an emoji modifier is a single cluster, since a modifier is `Extend`,
/// and it measured three, as did a wide ideograph followed by a spacing mark. No reading
/// of either spec gives a cell three columns. Contour's terminal-unicode-core puts a
/// whole cluster in one cell, and a cell is narrow or wide; ghostty, which implements
/// that spec's mode 2027, lands this exact case on two. Two rather than one because the
/// part that widened it is still drawn — a skin-tone swatch next to the `a` — and
/// a column short would put it on top of whatever follows.
pub(crate) fn cluster_cells(cluster: &str) -> usize {
    match cluster.chars().next() {
        Some(c) if REGIONAL.contains(&c) => 2,
        Some(_) => cluster.width().min(2),
        None => 0,
    }
}

/// Split TEXT into grapheme clusters, each with the columns it stands on.
///
/// The batch form, for a caller holding a whole string at once: the `OSC 66` payload,
/// which arrives complete and is a closed piece of text rather than a point in a stream.
/// The streaming path does not come through here — see [`Segmenter`].
pub(crate) fn clusters(text: &str) -> impl Iterator<Item = (&str, usize)> {
    text.graphemes(true).map(|g| (g, cluster_cells(g)))
}

/// What one code point does to the cell under the cursor.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Step {
    /// It starts a cell of its own, this many columns wide. Never zero.
    Cell(usize),
    /// It rides the cell before it, which stood on `before` columns and now stands on
    /// `after`. The two differ only for a variation selector, and `before` is zero when
    /// there is no cell before it to speak of at all — the first thing on a fresh row
    /// being a combining mark.
    Join { before: usize, after: usize },
}

/// How many columns a cell stands on, and on whose word.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Width {
    /// What the characters measure.
    Measured(usize),
    /// What `OSC 66 ; w=N` said, which a code point joining the cell must not re-measure.
    Declared(usize),
}

/// The code points already on the cell under the cursor, and how wide that cell is.
///
/// One per [`State`](crate::emu::term), reset by every dispatch that is not a print.
#[derive(Debug, Default)]
pub(crate) struct Segmenter {
    /// The cell's code points in stream order, which is the context UAX#29 needs: GB11
    /// looks back across a run of `Extend` for an emoji base, and GB12/GB13 count
    /// regional indicators for parity. Neither can be answered from the last code point
    /// alone.
    cluster: String,
    /// Columns the cell stands on *as the grid has it*, which is not always what
    /// [`cluster_cells`] says: a widening that ran out of row is declined, and a width
    /// declared by `OSC 66` overrides the measurement outright. [`Segmenter::settle`] is
    /// how the grid corrects this side.
    cells: usize,
    /// Whether `cells` is a *declaration* rather than a measurement.
    ///
    /// It stops a code point that joins the cell from re-measuring it. `OSC 66 ; w=3 ; x`
    /// puts an `x` on three cells; a combining mark arriving next belongs to that cell,
    /// and measuring `x` plus the mark gives one — so without this the mark would shrink
    /// a block the child stated the width of, which is the whole thing the child used
    /// this escape code to avoid.
    declared: bool,
}

impl Segmenter {
    /// Forget the cell before the cursor. Anything but a print invalidates it.
    pub(crate) fn reset(&mut self) {
        self.cluster.clear();
        self.cells = 0;
        self.declared = false;
    }

    /// Begin a cell holding exactly CLUSTER, standing on WIDTH columns.
    ///
    /// Two callers, both of which placed text without coming through [`Segmenter::push`]:
    /// the batched ASCII run in `print_ascii`, which seeds the last character it placed so
    /// that a combining mark arriving next still finds its base, and `OSC 66`, which
    /// seeds the block it just drew along with the width the child *declared* for it —
    /// so a mark following a declared-width block attaches to the block rather than
    /// splitting it.
    pub(crate) fn restart(&mut self, cluster: &str, width: Width) {
        self.cluster.clear();
        self.cluster.push_str(cluster);
        (self.cells, self.declared) = match width {
            Width::Measured(cells) => (cells, false),
            Width::Declared(cells) => (cells, true),
        };
    }

    /// Correct the recorded width to what the grid actually managed.
    pub(crate) fn settle(&mut self, cells: usize) {
        self.cells = cells;
    }

    /// Take the next code point and say where it goes.
    pub(crate) fn push(&mut self, c: char) -> Step {
        // Printable ASCII opens a cell, always, and does it without touching UAX#29.
        // Nothing in `0x20..=0x7e` is `Extend`, `ZWJ`, `SpacingMark` or a variation
        // selector, so no cluster can continue into one — bar `Prepend` × Any, declined
        // here for exactly the reason `print_ascii` declines it, which is written out
        // there. A range test in place of a boundary scan, on the characters that are
        // essentially all of what a session prints: without it, segmentation cost about
        // 3% of the plain-text benchmark, and with it the cost is not measurable.
        if c.is_ascii_graphic() || c == ' ' {
            self.cluster.clear();
            self.cluster.push(c);
            self.cells = 1;
            self.declared = false;
            return Step::Cell(1);
        }
        // The same again for the bulk of East Asian text, which is where the other large
        // body of output lives and where UAX#29 has as little to say. Every code point in
        // [`opens_wide_cell`] is `Grapheme_Cluster_Break=Other`, is neither
        // `Extended_Pictographic` nor an Indic conjunct consonant, and is East Asian Wide.
        // The only rule that can forbid a break before an `Other` is `GB9b`, a `Prepend`
        // before it, which is the exception already accepted above; so it opens a cell of
        // two columns whatever came before. Without this, each one cost two table
        // lookups -- its width from one crate, its break class from another -- and a
        // boundary scan, which between them were a fifth of the wide-text benchmark.
        if opens_wide_cell(c) {
            self.cluster.clear();
            self.cluster.push(c);
            self.cells = 2;
            self.declared = false;
            return Step::Cell(2);
        }
        // No previous cell. A code point with a width starts one; a zero-width one has
        // nothing to attach to, and `Join { before: 0 }` is how that is said — the grid
        // has its own long-standing answer for it and this does not second-guess it.
        if self.cluster.is_empty() || self.cluster.len() >= MAX_CLUSTER {
            let cells = char_cells(c);
            self.cluster.clear();
            self.cluster.push(c);
            self.cells = cells;
            self.declared = false;
            return if cells == 0 {
                Step::Join {
                    before: 0,
                    after: 0,
                }
            } else {
                Step::Cell(cells)
            };
        }
        // Appended before the question is asked, because the question is about the
        // string with it on the end: `is_boundary` is asked whether the offset the code
        // point starts at is a cluster break, and answering that needs the code point
        // itself as well as everything before it. Growing the buffer in place is what
        // keeps this allocation-free after the first few characters of a session.
        let at = self.cluster.len();
        self.cluster.push(c);
        let boundary = GraphemeCursor::new(at, self.cluster.len(), true)
            .is_boundary(&self.cluster, 0)
            // The chunk handed over is the whole string, so no context can be missing
            // and this cannot legitimately fail. Treating a failure as a boundary is the
            // conservative reading: it costs a cell rather than losing a character.
            .unwrap_or(true);
        let cells = char_cells(c);
        if boundary && cells > 0 {
            self.cluster.drain(..at);
            self.cells = cells;
            self.declared = false;
            return Step::Cell(cells);
        }
        let before = self.cells;
        // A boundary that a zero-width code point falls on still attaches it to the cell
        // before — the spec is explicit, and it is what keeps a stray combining mark from
        // consuming a column. The width cannot have changed in that case, since a code
        // point that starts its own cluster is not a variation selector on the old one.
        self.cells = if boundary || self.declared {
            before
        } else {
            cluster_cells(&self.cluster)
        };
        Step::Join {
            before,
            after: self.cells,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every code point the wide fast path admits, against the two crates it bypasses:
    /// two columns wide, and a cluster of its own after anything that is not a `Prepend`
    /// -- a letter, another ideograph, a combining mark, a ZWJ, a regional indicator, a
    /// leading Hangul jamo, an emoji, a Devanagari consonant and its virama.
    #[test]
    fn the_wide_fast_path_agrees_with_the_tables_it_bypasses() {
        let before = [
            "a",
            "\u{65e5}",
            "e\u{301}",
            "\u{1f468}\u{200d}",
            "\u{1f1e8}",
            "\u{1100}",
            "\u{1f600}",
            "\u{915}\u{94d}",
        ];
        let mut admitted = 0;
        for c in ('\u{3000}'..='\u{a000}').filter(|&c| opens_wide_cell(c)) {
            admitted += 1;
            assert_eq!(char_cells(c), 2, "{c:?}");
            for before in before {
                let text = format!("{before}{c}");
                let last = text.graphemes(true).next_back().unwrap();
                assert_eq!(last.chars().collect::<Vec<_>>(), [c], "{before:?} {c:?}");
            }
        }
        assert_eq!(admitted, 86 + 96 + 6592 + 20992);
    }

    /// The fast path and the path it bypasses leave the segmenter in the same state:
    /// what joins an ideograph afterwards still finds it.
    #[test]
    fn a_variation_selector_still_joins_an_ideograph() {
        assert_eq!(
            steps("\u{845b}\u{e0100}"),
            vec![
                Step::Cell(2),
                Step::Join {
                    before: 2,
                    after: 2
                }
            ]
        );
    }

    /// The word-at-a-time scan against the definition it replaced, for every pair of
    /// byte values at every pair of positions in a word, and for every single byte at
    /// every offset of a buffer long enough to have a word, a second word and a tail.
    ///
    /// Pairs, because the arithmetic has a borrow in it: a stopping byte can raise a
    /// false flag in the bytes above it, and what has to hold is that the *first* stop
    /// is still the one reported.
    #[test]
    fn the_word_scan_agrees_with_a_byte_at_a_time() {
        let ascii = |bytes: &[u8]| {
            let plain = |b: &&u8| (0x20..0x7f).contains(*b);
            bytes.iter().take_while(plain).count()
        };
        for (i, j) in (0..8).flat_map(|i| (i + 1..8).map(move |j| (i, j))) {
            for (a, b) in (0..=255).flat_map(|a| (0..=255).map(move |b| (a, b))) {
                let mut word = [b'x'; 8];
                (word[i], word[j]) = (a, b);
                assert_eq!(printable_ascii_len(&word), ascii(&word), "{word:?}");
            }
        }
        for at in 0..21 {
            for value in 0..=255 {
                let mut buffer = [b'x'; 21];
                buffer[at] = value;
                assert_eq!(printable_ascii_len(&buffer), ascii(&buffer), "{buffer:?}");
                assert_eq!(printable_ascii_len(&buffer[..at]), at);
            }
        }
    }

    /// Feed a string one code point at a time, as the parser does, and report the cells
    /// each one claimed — the shape the grid sees.
    fn steps(text: &str) -> Vec<Step> {
        let mut seg = Segmenter::default();
        text.chars().map(|c| seg.push(c)).collect()
    }

    /// Total columns a string occupies when streamed through the segmenter.
    fn streamed_cells(text: &str) -> usize {
        let mut seg = Segmenter::default();
        let mut cells = 0;
        for c in text.chars() {
            match seg.push(c) {
                Step::Cell(w) => cells += w,
                Step::Join { before, after } => cells = cells + after - before,
            }
        }
        cells
    }

    #[test]
    fn a_zwj_family_is_one_cell_block_and_not_one_per_member() {
        // The A9 gap, stated as a test. Per code point this is 2 + 0 + 2 + 0 + 2 = 6
        // columns; per grapheme cluster it is one two-column cell.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
        assert_eq!(streamed_cells(family), 2);
        assert_eq!(
            steps(family)[0],
            Step::Cell(2),
            "the base opens a two-column cell"
        );
        assert!(
            steps(family)[1..].iter().all(|s| matches!(
                s,
                Step::Join {
                    before: 2,
                    after: 2
                }
            )),
            "and everything after it rides that cell without widening it"
        );
    }

    #[test]
    fn an_emoji_modifier_rides_its_base() {
        assert_eq!(streamed_cells("\u{1F44D}\u{1F3FD}"), 2);
    }

    #[test]
    fn a_flag_is_two_columns_and_a_half_flag_is_still_two() {
        assert_eq!(streamed_cells("\u{1F1E6}\u{1F1FA}"), 2);
        // The override `unicode-width` alone would get wrong: a lone regional indicator
        // is two columns by the spec, not one.
        assert_eq!(streamed_cells("\u{1F1E6}"), 2);
        assert_eq!(char_cells('\u{1F1E6}'), 2);
    }

    #[test]
    fn variation_selectors_resize_the_cell_they_land_on() {
        // U+2714 HEAVY CHECK MARK is one column bare and two in emoji presentation.
        assert_eq!(streamed_cells("\u{2714}"), 1);
        assert_eq!(
            steps("\u{2714}\u{FE0F}")[1],
            Step::Join {
                before: 1,
                after: 2
            },
            "VS16 widens the cell already written"
        );
        assert_eq!(streamed_cells("\u{2714}\u{FE0F}"), 2);
    }

    #[test]
    fn a_combining_mark_costs_no_column() {
        assert_eq!(streamed_cells("e\u{301}"), 1);
        assert_eq!(
            steps("e\u{301}")[1],
            Step::Join {
                before: 1,
                after: 1
            }
        );
    }

    #[test]
    fn a_combining_mark_with_nothing_before_it_says_so() {
        assert_eq!(
            steps("\u{301}")[0],
            Step::Join {
                before: 0,
                after: 0
            },
            "there is no previous cell, and the grid decides what that means"
        );
    }

    #[test]
    fn ordinary_text_is_one_cell_per_character() {
        assert_eq!(streamed_cells("hello"), 5);
        assert!(steps("hello").iter().all(|s| *s == Step::Cell(1)));
    }

    #[test]
    fn east_asian_text_is_two_cells_per_character() {
        assert_eq!(streamed_cells("日本語"), 6);
    }

    #[test]
    fn the_context_a_cell_retains_is_bounded() {
        // A cell cannot be made to retain an arbitrary amount of a hostile stream. Past
        // `MAX_CLUSTER` the segmenter drops what it was holding and starts over, which
        // costs the correctness of a boundary nobody sane will ever ask about and buys a
        // bound on what a child can make this side allocate per cell.
        let mut seg = Segmenter::default();
        seg.push('a');
        for _ in 0..100_000 {
            seg.push('\u{301}');
        }
        assert!(
            seg.cluster.len() <= MAX_CLUSTER + 4,
            "retained {} bytes for one cell",
            seg.cluster.len()
        );
    }

    #[test]
    fn the_batch_form_agrees_with_the_streaming_one() {
        for text in [
            "hello",
            "日本語",
            "e\u{301}",
            "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}",
            "\u{1F1E6}\u{1F1FA}",
            "\u{2714}\u{FE0F}",
            "\u{1F44D}\u{1F3FD}",
            "a\u{1F600}b",
        ] {
            assert_eq!(
                clusters(text).map(|(_, w)| w).sum::<usize>(),
                streamed_cells(text),
                "{text:?} measures the same whether it arrives whole or a byte at a time"
            );
        }
    }
}
