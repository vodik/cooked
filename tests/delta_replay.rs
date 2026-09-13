//! The self-oracle over damage tracking: what the drains said must be the whole grid.
//!
//! Two properties, both over the same generated script, and neither needs an Emacs:
//!
//!   1. *Replay ≡ full grid.* Feed the script in fragments, drain after every write, and
//!      accumulate each delta's rows into a shadow grid. Then `touch_all()` and drain
//!      once more, which is the emulator reading its own grid out in full, and compare
//!      the two row by row and run by run. A writer that reports "nothing changed" when
//!      something did leaves the shadow holding the stale row, and this is what finds it.
//!      Everything cooked's redisplay story rests on is that report being honest — see
//!      `Screen::edit`, which is where a writer's `bool` becomes the dirty flag.
//!   2. *Fragmenting a write changes nothing.* The same script through a second term
//!      whose writes are not split, compared the same way, plus the scrollback both
//!      accumulated. cooked reads from the pty in `READ_CHUNK` pieces and an escape
//!      sequence does not know where those boundaries fall, so parser state carried
//!      across a `feed` call is a real hazard with a real failure mode: a split `CSI 3 8
//!      ; 5 ; 4 m` that loses half its parameters paints the wrong colour and nothing
//!      else notices.
//!
//! Property 1 alone would pass a parser that mangles split escapes — it compares the
//! grid against itself — and property 2 alone would pass a damage tracker that reports
//! nothing at all, since both terms would miss the same rows. They are complementary,
//! and the fragmented motif is why both are here.
//!
//! One generator ghostel's harness has is missing here and cannot be written: a
//! scrollback *limit* of zero or one. cooked keeps no scrollback in Rust at all — rows
//! leave the grid on the next `Delta` and Emacs' buffer is the transcript, which is the
//! architectural difference the whole comparison turns on — so there is no bound to set
//! to zero. `Step::ForgetHistory` stands where it would have gone: it is the one thing
//! that tells the emulator its history is gone, which is what a zero-length scrollback
//! amounts to from the grid's side.
//!
//! **The comparison includes styles**, which is the point of doing this in Rust rather
//! than over a buffer snapshot: `Run` carries the pen, the underline colour, the box
//! decoration and the link id, and a stale face over correct characters is exactly the
//! class of miss a text-only oracle waves through.

use cooked::emu::{Delta, Direction, Edit, Run, Scrolled, Shift, Term};
use proptest::prelude::*;

/// The upper bound on a generated grid, in both directions.
///
/// Small on purpose. A 1x1 grid and a 3x4 grid exercise every wrap, scroll and clamp
/// path that an 80x24 one does, they do it in a handful of cells that a failure message
/// can print whole, and proptest shrinks toward them anyway. The interesting sizes here
/// are the degenerate ones — see [`size`].
const MAX_ROWS: usize = 8;
const MAX_COLS: usize = 12;

// ---------------------------------------------------------------------------
// The script
// ---------------------------------------------------------------------------

/// One thing done to the terminal, in the order the generated script does them.
///
/// Deliberately not "one escape sequence": a resize is not something the child can write,
/// and neither is Emacs dropping the scrollback, yet both are ordinary events in the
/// middle of a stream of bytes and both are where the grid and the damage flags are most
/// likely to fall out of step.
#[derive(Debug, Clone)]
enum Step {
    /// Bytes for the child to have written, and where the writes are cut.
    ///
    /// `splits` holds fractions of the byte length rather than offsets, so that a shrunk
    /// case keeps splitting somewhere sensible after proptest has shortened `bytes` — the
    /// same reason the resize below is a delta rather than an absolute size.
    ///
    /// `drain` says whether Emacs drains after this write or lets the next step's output
    /// pile up behind it, which is how several writes come to share one drain -- and one
    /// drain can then see a row both changed and changed back.
    Write {
        bytes: Vec<u8>,
        splits: Vec<u8>,
        drain: bool,
    },
    /// A resize, as a signed delta on each axis, clamped to at least one row and column.
    ///
    /// Relative rather than absolute so that shrinking the *initial* size cannot turn a
    /// resize into a no-op or a growth into a shrink, which is what makes a shrunk case
    /// still reproduce the failure it was shrunk from.
    Resize { rows: i8, cols: i8 },
    /// Emacs discarded its transcript, so the grid's top row continues nothing.
    ForgetHistory,
    /// The width guard deleted a character off the end of screen row `row` after
    /// rendering it, and said so with `forget_sent`.
    ///
    /// The one edit Lisp makes to a live row's text by itself. The shadow takes the edit,
    /// so a later drain that leaves the row out on the strength of the core's copy -- a
    /// copy the edit made wrong -- shows up as a shadow row that no longer matches.
    Trim { row: u8 },
}

impl Step {
    /// Byte offsets to cut `bytes` at, ascending and within bounds.
    fn cuts(bytes: &[u8], splits: &[u8]) -> Vec<usize> {
        let mut cuts: Vec<usize> = splits
            .iter()
            .map(|f| (usize::from(*f) * bytes.len()) / 256)
            .collect();
        cuts.sort_unstable();
        cuts
    }
}

/// Characters worth putting on a grid, weighted by how much of the machinery they reach.
///
/// Box-drawing and block elements are here because they are the only thing that produces
/// a `Deco`, and a decoration is a run boundary in its own right — a `Run` vector for a
/// row of `+-|` and one for the same row of `┌─┐` differ in structure, not only in text.
/// The wide characters and the combining marks are here for the other two ways a cell and
/// a column stop being the same thing.
fn printable() -> impl Strategy<Value = char> {
    prop_oneof![
        6 => (0x20u32..0x7f).prop_map(|c| char::from_u32(c).unwrap()),
        3 => (0x2500u32..0x25a0).prop_map(|c| char::from_u32(c).unwrap()),
        1 => (0x4e00u32..0x4e40).prop_map(|c| char::from_u32(c).unwrap()),
        1 => (0x0300u32..0x0310).prop_map(|c| char::from_u32(c).unwrap()),
    ]
}

/// A stretch of text, as the child would have written it.
fn text() -> impl Strategy<Value = Vec<u8>> {
    prop::collection::vec(printable(), 0..24)
        .prop_map(|chars| chars.into_iter().collect::<String>().into_bytes())
}

/// An unbroken run of box-drawing characters, which is what a full-screen program's
/// borders actually look like: one `Deco` covering the whole run rather than one
/// character of decoration between two of text.
fn box_run() -> impl Strategy<Value = Vec<u8>> {
    (0x2500u32..0x2580, 1usize..12).prop_map(|(c, n)| {
        std::iter::repeat_n(char::from_u32(c).unwrap(), n)
            .collect::<String>()
            .into_bytes()
    })
}

/// `SGR`, in all four of the shapes the pen can be set by.
///
/// The 256-colour and truecolour forms are the long ones, and length is what makes them
/// interesting here: `CSI 38 ; 2 ; R ; G ; B m` is up to nineteen bytes of parameters for
/// the fragmenting generator to cut in half.
fn sgr() -> impl Strategy<Value = Vec<u8>> {
    prop_oneof![
        (0u8..10).prop_map(|n| format!("\x1b[{n}m")),
        (30u8..48).prop_map(|n| format!("\x1b[{n}m")),
        (0u8..255).prop_map(|n| format!("\x1b[38;5;{n}m")),
        (0u8..255, 0u8..255, 0u8..255).prop_map(|(r, g, b)| format!("\x1b[48;2;{r};{g};{b}m")),
        // `SGR 58` is the underline colour, which lives in the row's side table rather
        // than in `Style` and rides the `Run` separately. A shadow grid comparing only
        // `Style` would miss it; comparing whole `Run`s does not.
        (0u8..255).prop_map(|n| format!("\x1b[58;5;{n}m")),
        Just("\x1b[0m".to_string()),
    ]
    .prop_map(String::into_bytes)
}

/// A line erased and written back as it was, and a whole screen cleared and redrawn.
///
/// The repaint `watch`, htop and tmux do, and the case the core's copy of what Emacs holds
/// exists for: every cell of the row changes twice and none in the end, so the row is
/// damaged and can be left out of the drain. The lines are fixed so that the rewrite
/// really does put back what the erase took away.
fn rewrite() -> impl Strategy<Value = Vec<u8>> {
    let lines = vec![
        "abcdefgh",
        "hello",
        "\u{2502} \u{2500}\u{2500}",
        "\u{4e00}x",
    ];
    prop_oneof![
        (1usize..9, prop::sample::select(lines.clone()))
            .prop_map(|(row, line)| format!("\x1b[{row};1H\x1b[2K{line}")),
        (
            prop::sample::select(lines.clone()),
            prop::sample::select(lines)
        )
            .prop_map(|(first, second)| format!("\x1b[H\x1b[2J{first}\r\n{second}")),
    ]
    .prop_map(String::into_bytes)
}

/// A few cells of one row changed where they stand: a spinner turning, a digit of a
/// clock, a tail erased.
///
/// What a drain sends as an edit rather than a whole row, which it does only for a row
/// whose neighbours did not change, so this touches one row and nothing either side of it.
/// The replacements are the shapes that make character offsets and columns disagree -- a
/// blank, a box glyph, a wide character, a combining mark -- and an erase to the end of
/// the line, which shortens the row.
fn poke() -> impl Strategy<Value = Vec<u8>> {
    let pieces = vec![
        " ", "x", "\u{2500}", "\u{4e00}", "e\u{301}", "\x1b[K", "  ", "ab",
    ];
    (1usize..9, 1usize..13, prop::sample::select(pieces))
        .prop_map(|(row, col, piece)| format!("\x1b[{row};{col}H{piece}").into_bytes())
}

/// Cursor motion, erasure and the line/character editing operators.
///
/// Every parameter is small, because the grids are small and a `CUP` to row 4000 is the
/// same clamp as a `CUP` to row 9. What the small parameters buy is that most of these
/// land *inside* the grid, where they can actually disturb a cell, rather than all
/// piling up against the same edge.
fn control() -> impl Strategy<Value = Vec<u8>> {
    prop_oneof![
        // Motion, absolute and relative.
        (1usize..10, 1usize..14).prop_map(|(r, c)| format!("\x1b[{r};{c}H")),
        (
            1usize..6,
            prop::sample::select(vec!['A', 'B', 'C', 'D', 'G', 'd'])
        )
            .prop_map(|(n, verb)| format!("\x1b[{n}{verb}")),
        // Erasure: display, line, and a count of characters.
        (0usize..3, prop::sample::select(vec!['J', 'K']))
            .prop_map(|(n, verb)| format!("\x1b[{n}{verb}")),
        (
            1usize..6,
            prop::sample::select(vec!['X', 'P', '@', 'L', 'M', 'S', 'T'])
        )
            .prop_map(|(n, verb)| format!("\x1b[{n}{verb}")),
        // A scroll region, and the reset that removes it. `DECSTBM` also homes the
        // cursor, so it is a motion as well as a mode.
        (1usize..5, 2usize..9).prop_map(|(top, bottom)| format!("\x1b[{top};{bottom}r")),
        Just("\x1b[r".to_string()),
        // Modes that change what a write *does*: autowrap, insert, origin.
        prop::sample::select(vec![
            "\x1b[?7h", "\x1b[?7l", "\x1b[4h", "\x1b[4l", "\x1b[?6h", "\x1b[?6l"
        ])
        .prop_map(str::to_string),
        // The C0 controls, which are how a real stream moves between lines at all.
        prop::sample::select(vec![
            "\r", "\n", "\r\n", "\x08", "\t", "\x1bM", "\x1bD", "\x1bE"
        ])
        .prop_map(str::to_string),
        // A hyperlink opened and closed around nothing: the id is a run boundary the
        // style cannot express, so an empty one still has to survive the round trip.
        (0usize..4).prop_map(|n| format!("\x1b]8;;https://example.invalid/{n}\x07")),
        Just("\x1b]8;;\x07".to_string()),
    ]
    .prop_map(String::into_bytes)
}

/// A repaint: home the cursor, set a pen, and write one of a handful of fixed lines.
///
/// The lines are fixed, and that is the whole point of having this beside [`text`]. What
/// this is for is the *same characters arriving again under a different pen* — a status
/// bar that changes colour, a spinner, a selection moving down a menu — which is the one
/// case where a writer comparing characters and forgetting the style still reports "no
/// change", and the one an oracle over text alone cannot see. Two independently generated
/// random strings essentially never collide, so a generator that only produced [`text`]
/// would never reach it: dropping the style from `Row::fill_run`'s comparison passed a
/// thousand cases of everything else in this file.
fn repaint() -> impl Strategy<Value = Vec<u8>> {
    let lines = vec!["abcdefgh", "hello", "AA BB", "....", "x"];
    (sgr(), prop::sample::select(lines)).prop_map(|(pen, line)| {
        let mut bytes = b"\x1b[H".to_vec();
        bytes.extend(pen);
        bytes.extend_from_slice(line.as_bytes());
        bytes
    })
}

/// Bytes with no structure at all, including invalid UTF-8 and stray control characters.
///
/// The floor under every other generator: whatever the motifs above fail to think of, a
/// child is entitled to write, and the parser has to survive it. This is also the only
/// generator that can produce a lone continuation byte, which is the other half of the
/// read-boundary problem — a multi-byte character split across two `feed` calls.
fn noise() -> impl Strategy<Value = Vec<u8>> {
    prop::collection::vec(any::<u8>(), 0..12)
}

/// One write's worth of bytes.
fn payload() -> impl Strategy<Value = Vec<u8>> {
    prop_oneof![
        5 => text(),
        2 => sgr(),
        3 => control(),
        3 => repaint(),
        3 => rewrite(),
        3 => poke(),
        2 => box_run(),
        1 => noise(),
    ]
}

/// A write, cut into one to four pieces at random offsets.
///
/// *The* motif to have, per §9: cooked drains on a wake byte and reads in `READ_CHUNK`
/// pieces, so the boundary this simulates is one the emulator meets on every large
/// paste and every flood, and a naive fuzzer that hands whole sequences over never
/// reaches the states behind it.
fn write_step() -> impl Strategy<Value = Step> {
    (
        payload(),
        prop::collection::vec(any::<u8>(), 0..3),
        prop::bool::weighted(0.75),
    )
        .prop_map(|(bytes, splits, drain)| Step::Write {
            bytes,
            splits,
            drain,
        })
}

fn resize_step() -> impl Strategy<Value = Step> {
    (-4i8..5, -6i8..7).prop_map(|(rows, cols)| Step::Resize { rows, cols })
}

/// Enter the alt screen, write on it, resize while it is up, and leave.
///
/// Notorious, and for a reason cooked shares: the two grids are resized together but only
/// the primary rewraps, the alt screen is cleared on entry and its rows are damaged
/// wholesale by the switch, and the scrollback the resize evicts comes off the primary
/// while the alt screen is the one on display. Four things that each rewrite the damage
/// flags, in one sequence.
fn alt_cycle() -> impl Strategy<Value = Vec<Step>> {
    (write_step(), resize_step(), write_step()).prop_map(|(before, resize, after)| {
        vec![
            Step::Write {
                bytes: b"\x1b[?1049h".to_vec(),
                splits: vec![128],
                drain: true,
            },
            before,
            resize,
            after,
            Step::Write {
                bytes: b"\x1b[?1049l".to_vec(),
                splits: Vec::new(),
                drain: true,
            },
        ]
    })
}

/// Save the cursor, resize, write, restore.
///
/// The saved cursor is a position remembered against a geometry that no longer exists by
/// the time it is restored, and a rewrap has moved the text it pointed at as well. The
/// restore has to land somewhere on the new grid whatever happened in between.
fn save_resize_restore() -> impl Strategy<Value = Vec<Step>> {
    (resize_step(), write_step()).prop_map(|(resize, write)| {
        vec![
            Step::Write {
                bytes: b"\x1b[s".to_vec(),
                splits: vec![100],
                drain: true,
            },
            resize,
            write,
            Step::Write {
                bytes: b"\x1b[u".to_vec(),
                splits: Vec::new(),
                drain: true,
            },
        ]
    })
}

fn script() -> impl Strategy<Value = Vec<Step>> {
    let group = prop_oneof![
        10 => write_step().prop_map(|s| vec![s]),
        2 => resize_step().prop_map(|s| vec![s]),
        1 => alt_cycle(),
        1 => save_resize_restore(),
        1 => Just(vec![Step::ForgetHistory]),
        1 => (0u8..MAX_ROWS as u8).prop_map(|row| vec![Step::Trim { row }]),
    ];
    prop::collection::vec(group, 1..14).prop_map(|groups| groups.concat())
}

/// A starting geometry, with the degenerate ones over-represented.
///
/// A one-row grid has no room to scroll into, so every line feed is an eviction; a
/// one-column grid wraps on every character and cannot hold a wide one at all. Both are
/// reachable in Emacs by dragging a window edge, both are where the arithmetic that
/// assumes a second row or a second column shows, and neither is likely to come out of a
/// uniform range often enough to matter.
fn size() -> impl Strategy<Value = (usize, usize)> {
    (
        prop_oneof![2 => Just(1usize), 5 => 2usize..=MAX_ROWS],
        prop_oneof![2 => Just(1usize), 1 => Just(2usize), 5 => 3usize..=MAX_COLS],
    )
}

// ---------------------------------------------------------------------------
// Running a script
// ---------------------------------------------------------------------------

/// One drain's worth of scrollback, kept with the flag that decides how it is rendered.
///
/// `alt` is here because `Update::scrolled_rows` in the crate root consults it for the
/// batch's *last* row: a wrapped row at the end of a batch taken while the alt screen is
/// up must not be joined onto what follows, because what follows is the alt grid's row 0
/// rather than this row's continuation. Rendering scrollback without that flag would be
/// rendering something the Lisp side never sees.
struct Batch {
    lines: Vec<Scrolled>,
    alt: bool,
}

/// A terminal being driven by a script, with the shadow grid the deltas built.
struct Replay {
    term: Term,
    /// The same terminal, told before every drain that Emacs has lost its copy of every
    /// row, so that it reports every damaged row whether or not Emacs already has it.
    ///
    /// What `term` leaves out of a drain is checked against this: every row it skips
    /// must be one the reference sent with exactly the runs the shadow already holds.
    reference: Term,
    rows: usize,
    cols: usize,
    /// Every row Emacs would be holding, as the deltas described it.
    shadow: Vec<Vec<Run>>,
    /// The shadow rows a [`Step::Trim`] edited and no drain has rewritten since, which
    /// are expected to differ from the grid: that difference is what Lisp left there.
    trimmed: Vec<bool>,
    /// Each shadow row's wrap flag as last sent, which Lisp marks the row's newline by.
    wrapped: Vec<bool>,
    scrollback: Vec<Batch>,
}

impl Replay {
    /// A fresh terminal and a shadow that agrees with it.
    ///
    /// The agreement is by construction rather than by a first drain: a new grid is blank
    /// and undamaged, and a blank row's runs are empty, because trailing blanks are
    /// trimmed out of `Row::runs`.
    fn new(rows: usize, cols: usize) -> Self {
        Self {
            term: Term::new(rows, cols),
            reference: Term::new(rows, cols),
            rows,
            cols,
            shadow: vec![Vec::new(); rows],
            trimmed: vec![false; rows],
            wrapped: vec![false; rows],
            scrollback: Vec::new(),
        }
    }

    /// Apply one delta to the shadow, exactly as `cooked--apply' does: rewrite the rows it
    /// names and leave every other row alone.
    ///
    /// The height is taken from the delta rather than tracked here for the same reason
    /// Lisp takes it from there — a resize can evict rows, and the delta is the one place
    /// that reports the shape the rows in it were read at. Growth needs no filling in
    /// beyond the blank vectors: `Screen::resize` damages the whole grid, so every row of
    /// the new shape arrives in this same delta.
    fn absorb(&mut self, delta: Delta, reference: Delta) {
        self.check_skipped(&delta, &reference);
        self.shadow.resize(delta.height, Vec::new());
        self.trimmed.resize(delta.height, false);
        self.wrapped.resize(delta.height, false);
        // Before the rows and after the resize, which is the order `cooked--apply' works
        // in and the order the contract requires: a scroll reports the rows it *moved*
        // rather than damaging them, and the damage indices that follow are in the
        // coordinates the moves leave behind. This is the half of the change the oracle
        // is actually watching — if `Screen::scroll_up' narrows its damage by one row too
        // many, the shadow keeps the row the grid recycled and property 1 fails.
        for shift in delta.shifts {
            Self::shift(&mut self.shadow, shift);
            Self::shift(&mut self.trimmed, shift);
            Self::shift(&mut self.wrapped, shift);
        }
        for damaged in delta.rows {
            if let (Some(edit), Some(row)) = (&damaged.edit, self.shadow.get(damaged.index)) {
                Self::check_edit(damaged.index, row, edit, &damaged.runs);
            }
            if let Some(row) = self.shadow.get_mut(damaged.index) {
                *row = damaged.runs;
                self.trimmed[damaged.index] = false;
                self.wrapped[damaged.index] = damaged.wrapped;
            }
        }
        if !delta.scrolled.is_empty() {
            self.scrollback.push(Batch {
                lines: delta.scrolled,
                alt: delta.levels.alt,
            });
        }
    }

    /// Check that every row DELTA left out is one Emacs already had.
    ///
    /// REFERENCE is the same drain with nothing left out. Its rows are a superset of
    /// DELTA's, and each row only it names must already sit in the shadow, once the
    /// drain's shifts have moved the shadow's rows, with exactly the runs the reference
    /// would have sent. A row the core's copy wrongly matched -- one Lisp trimmed, one a
    /// shift moved without the copy following, one left behind by a resize -- differs
    /// from the shadow here, and this is where it is caught rather than in the whole-grid
    /// comparison at the end, which a later write over the same row could hide.
    fn check_skipped(&self, delta: &Delta, reference: &Delta) {
        assert_eq!(
            delta.shifts, reference.shifts,
            "the two drains moved different rows"
        );
        let mut shadow = self.shadow.clone();
        let mut wrapped = self.wrapped.clone();
        shadow.resize(delta.height, Vec::new());
        wrapped.resize(delta.height, false);
        for shift in &delta.shifts {
            Self::shift(&mut shadow, *shift);
            Self::shift(&mut wrapped, *shift);
        }
        let sent: Vec<usize> = delta.rows.iter().map(|r| r.index).collect();
        for row in &delta.rows {
            let theirs = reference.rows.iter().find(|r| r.index == row.index);
            assert!(
                theirs.is_some_and(|r| r.runs == row.runs),
                "row {} was sent without the reference sending it the same way",
                row.index
            );
        }
        for row in reference.rows.iter().filter(|r| !sent.contains(&r.index)) {
            assert_eq!(
                shadow.get(row.index),
                Some(&row.runs),
                "row {} was left out of the drain, but Emacs does not have it",
                row.index
            );
            assert_eq!(
                wrapped.get(row.index),
                Some(&row.wrapped),
                "row {} was left out of the drain with a different wrap flag",
                row.index
            );
        }
    }

    /// Check that applying EDIT to the shadow's row INDEX, OLD, by character offsets, as
    /// `cooked--render-rows' applies it to the buffer, gives what the whole row FULL
    /// draws, character by character: the same text, renditions, links and decorations.
    ///
    /// Also that neither boundary cuts a run of box glyphs in the old row or the new one,
    /// since Lisp draws such a run as one image and half of one left behind is wrong
    /// however right the characters are.
    fn check_edit(index: usize, old: &[Run], edit: &Edit, full: &[Run]) {
        let before = drawn(old);
        let start = edit.char_start;
        assert!(
            start <= before.len(),
            "row {index}: an edit from character {start} of a {}-character row",
            before.len()
        );
        let mut after = before[..start].to_vec();
        after.extend(drawn(&edit.runs));
        if let Some(end) = edit.char_end {
            assert!(
                (start..=before.len()).contains(&end),
                "row {index}: an edit of characters {start}..{end} of {}",
                before.len()
            );
            after.extend_from_slice(&before[end..]);
        }
        after.truncate(edit.chars);
        assert_eq!(
            after,
            drawn(full),
            "row {index}: the edit {edit:?} does not reproduce the row"
        );
        // The old text is cut at START and END, the new text at START and wherever the
        // replacement ends in it.
        let replaced = drawn(&edit.runs).len();
        let cuts = [
            (old, Some(start)),
            (old, edit.char_end),
            (full, Some(start)),
            (full, edit.char_end.map(|_| start + replaced)),
        ];
        for (runs, cut) in cuts {
            if let Some(cut) = cut {
                assert!(
                    !inside_glyph_run(runs, cut),
                    "row {index}: an edit boundary at character {cut} cuts a glyph run"
                );
            }
        }
    }

    /// Move a block of shadow rows, as `cooked--apply-shifts' moves the buffer text.
    ///
    /// The rows rotated *out* are blanked rather than left holding what they held, which
    /// is what Emacs does: it deletes those buffer lines and inserts empty ones in their
    /// place, and only then renders whatever damage the delta reported over the top. A
    /// recycled row the emulator forgot to damage therefore shows up as an empty shadow
    /// row against a grid row with text in it, which is precisely the failure worth
    /// catching — leaving the stale text here would hide it whenever the scroll happened
    /// to recycle a row that was already blank.
    ///
    /// Asserted rather than clamped, which is the difference between an oracle and a
    /// second implementation quietly agreeing to skip the same case: a move naming a row
    /// the delta's own height does not have would leave the shadow untouched and every
    /// comparison after it meaningless. It cannot arise — a resize is the only thing that
    /// changes the row count, and it clears the log — so say so here.
    fn shift<T: Default>(shadow: &mut [T], shift: Shift) {
        assert!(
            shift.bottom < shadow.len(),
            "shift past the grid: {shift:?}"
        );
        assert!(
            (1..=shift.bottom + 1 - shift.top).contains(&shift.count),
            "shift of {} in a region {} tall",
            shift.count,
            shift.bottom + 1 - shift.top
        );
        let span = &mut shadow[shift.top..=shift.bottom];
        let recycled = match shift.direction {
            Direction::Up => {
                span.rotate_left(shift.count);
                span.len() - shift.count..span.len()
            }
            Direction::Down => {
                span.rotate_right(shift.count);
                0..shift.count
            }
        };
        for row in &mut span[recycled] {
            *row = T::default();
        }
    }

    /// Run one step, draining afterwards the way the reader thread does.
    ///
    /// `fragment` is what tells the two runs apart: with it, a write is cut into pieces
    /// at the step's own offsets; without it, the same bytes go over in one call. Nothing
    /// else differs, which is what makes the comparison between them mean "the read
    /// boundary did not matter".
    fn step(&mut self, step: &Step, fragment: bool) {
        match step {
            Step::Write {
                bytes,
                splits,
                drain,
            } => {
                for term in [&mut self.term, &mut self.reference] {
                    if fragment {
                        let mut at = 0;
                        for cut in Step::cuts(bytes, splits) {
                            term.feed(&bytes[at..cut]);
                            at = cut;
                        }
                        term.feed(&bytes[at..]);
                    } else {
                        term.feed(bytes);
                    }
                }
                if !drain {
                    return;
                }
            }
            Step::Resize { rows, cols } => {
                // Clamped rather than rejected: the emulator floors both axes at one
                // itself, and a script that walks the size down to the floor and back up
                // is a script worth running. The ceiling only keeps a long run of
                // growths from making the grids big enough to slow the suite down.
                self.rows =
                    (self.rows as i32 + i32::from(*rows)).clamp(1, MAX_ROWS as i32) as usize;
                self.cols =
                    (self.cols as i32 + i32::from(*cols)).clamp(1, MAX_COLS as i32) as usize;
                self.term.resize(self.rows, self.cols);
                self.reference.resize(self.rows, self.cols);
            }
            Step::ForgetHistory => {
                self.term.forget_history();
                self.reference.forget_history();
            }
            Step::Trim { row } => {
                // The guard runs as a drain is rendered, so the drain comes first.
                self.drain();
                let row = usize::from(*row);
                let Some(runs) = self.shadow.get_mut(row) else {
                    return;
                };
                let Some(run) = runs.iter_mut().rev().find(|run| !run.text.is_empty()) else {
                    return;
                };
                run.text.pop();
                self.trimmed[row] = true;
                self.term.forget_sent(Some(row));
                return;
            }
        }
        self.drain();
    }

    /// Drain both terminals and absorb what they said.
    fn drain(&mut self) {
        let delta = self.term.drain();
        self.reference.forget_sent(None);
        let reference = self.reference.drain();
        self.absorb(delta, reference);
    }

    /// The grid as the emulator itself reads it: everything damaged, one drain.
    ///
    /// This is the oracle. It goes through exactly the path a `cooked-refresh' takes, so
    /// what it produces is not a second formulation of the grid that could be wrong in
    /// its own way — it is the same `Row::runs` the incremental path uses, asked for every
    /// row instead of for the rows something claimed to have changed.
    fn full(&mut self) -> Delta {
        // Whatever the script left undrained is drained first, as it would be by the next
        // wake, so the shadow is up to date before it is compared.
        self.drain();
        self.term.touch_all();
        self.term.drain()
    }
}

/// RUNS as what Emacs draws for each character: the character, its rendition, underline
/// colour and link, and its decoration.
fn drawn(runs: &[Run]) -> Vec<String> {
    runs.iter()
        .flat_map(|run| {
            run.text.chars().enumerate().map(move |(i, c)| {
                format!(
                    "{c:?} {:?} {:?} {:?} {:?}",
                    run.style,
                    run.underline,
                    run.link,
                    run.deco_at(i)
                )
            })
        })
        .collect()
}

/// Whether character offset AT falls strictly inside a run of RUNS that carries box
/// glyphs.
fn inside_glyph_run(runs: &[Run], at: usize) -> bool {
    let mut start = 0;
    for run in runs {
        let len = run.text.chars().count();
        if run.deco_at(0).is_some() && start < at && at < start + len {
            return true;
        }
        start += len;
    }
    false
}

/// The scrollback as one string, under one setting of `cooked-rejoin-wrapped-lines`.
///
/// A transcription of `Update::scrolled_rows`, which is where the Lisp side's copy of
/// this rule lives — it cannot be called from here, because assembling the block needs an
/// `Env` and there is no Emacs in this test. The duplication is the cost of testing the
/// rule at all without one, and it is small enough to read against the original.
fn render(scrollback: &[Batch], rejoin: bool) -> String {
    let mut out = String::new();
    for batch in scrollback {
        let last = batch.lines.len() - 1;
        for (i, line) in batch.lines.iter().enumerate() {
            for run in &line.runs {
                out.push_str(&run.text);
            }
            if !(rejoin && line.wrapped && !(i == last && batch.alt)) {
                out.push('\n');
            }
        }
    }
    out
}

// ---------------------------------------------------------------------------
// Comparison
// ---------------------------------------------------------------------------

/// The first place two grids disagree, spelled out.
///
/// A `assert_eq!` on the two `Vec<Vec<Run>>` prints both grids in full, which for an 8x12
/// grid of styled runs is several screens of `Debug` output with the one differing field
/// somewhere inside it. This is §9's first-difference visualization: say which row, which
/// run, and show only that pair.
fn difference(shadow: &[Vec<Run>], full: &[Vec<Run>], skip: &[bool]) -> Option<String> {
    if shadow.len() != full.len() {
        return Some(format!(
            "row count: replayed {} rows, the grid has {}",
            shadow.len(),
            full.len()
        ));
    }
    for (row, (mine, theirs)) in shadow.iter().zip(full).enumerate() {
        if mine == theirs || skip.get(row).copied().unwrap_or(false) {
            continue;
        }
        let at = mine
            .iter()
            .zip(theirs)
            .position(|(a, b)| a != b)
            .unwrap_or(mine.len().min(theirs.len()));
        return Some(format!(
            "row {row}, run {at}:\n  replayed: {:?}\n  grid:     {:?}\n\
             \n  whole row, replayed: {mine:?}\n  whole row, grid:     {theirs:?}",
            mine.get(at),
            theirs.get(at),
        ));
    }
    None
}

/// The delta's rows as a dense grid, checking on the way that it really is one.
///
/// A drain after `touch_all` must report every row of the grid, once, in ascending order.
/// That `drain_damage` is ascending by construction is relied on elsewhere — it is what
/// lets damaged rows be coalesced into spans at all — so it is worth asserting where a
/// property test can see it.
fn dense(delta: &Delta) -> Result<Vec<Vec<Run>>, TestCaseError> {
    let indices: Vec<usize> = delta.rows.iter().map(|r| r.index).collect();
    let expected: Vec<usize> = (0..delta.height).collect();
    prop_assert_eq!(
        indices,
        expected,
        "a drain after touch_all must report every row once, ascending"
    );
    Ok(delta.rows.iter().map(|r| r.runs.clone()).collect())
}

proptest! {
    // 1024 rather than proptest's default 256: a case is a few dozen cells and a few
    // hundred bytes, so the pair of properties still runs in under a second and
    // quadrupling the cases is the cheapest coverage on offer. `PROPTEST_CASES=100000`
    // in the environment is the long soak, for when something is suspected but not
    // reproducing.
    //
    // The persistence file has to be named outright: proptest's default looks for the
    // `lib.rs` or `main.rs` of the crate it belongs to and an integration test has
    // neither, so the failing case would be printed and then lost. Named, it is written
    // beside this file and *committed* -- §9's shrunk corpus, replayed ahead of the
    // random cases on every run, which is what stops a fixed bug from coming back
    // quietly.
    #![proptest_config(ProptestConfig {
        cases: 1024,
        failure_persistence: Some(Box::new(proptest::test_runner::FileFailurePersistence::Direct(
            "tests/delta_replay.regressions",
        ))),
        ..ProptestConfig::default()
    })]

    /// Property 1: the deltas said everything the grid would have said.
    #[test]
    fn deltas_replay_the_whole_grid(((rows, cols), steps) in (size(), script())) {
        let mut replay = Replay::new(rows, cols);
        for step in &steps {
            replay.step(step, true);
        }
        let full = replay.full();
        let grid = dense(&full)?;
        if let Some(where_) = difference(&replay.shadow, &grid, &replay.trimmed) {
            return Err(TestCaseError::fail(format!(
                "replaying the deltas did not reproduce the grid — {where_}"
            )));
        }
    }

    /// Property 2: where the writes were cut did not matter.
    #[test]
    fn fragmenting_the_writes_changes_nothing(
        ((rows, cols), steps, rejoin) in (size(), script(), any::<bool>())
    ) {
        let mut split = Replay::new(rows, cols);
        let mut whole = Replay::new(rows, cols);
        for step in &steps {
            split.step(step, true);
            whole.step(step, false);
        }
        let (a, b) = (split.full(), whole.full());
        let (a, b) = (dense(&a)?, dense(&b)?);
        if let Some(where_) = difference(&a, &b, &[]) {
            return Err(TestCaseError::fail(format!(
                "the same bytes cut differently produced different grids — {where_}"
            )));
        }
        // The scrollback is compared as runs first, so a divergence in styles or in the
        // wrap provenance is caught with its own message, and then as the text Emacs
        // would actually insert under each setting of `cooked-rejoin-wrapped-lines' —
        // which is a text-identity transformation of the wrap flags, and so exactly the
        // kind of thing a consistency property can check without an expected output.
        let runs = |batches: &[Batch]| -> Vec<Scrolled> {
            batches.iter().flat_map(|b| b.lines.clone()).collect()
        };
        prop_assert_eq!(runs(&split.scrollback), runs(&whole.scrollback));
        prop_assert_eq!(
            render(&split.scrollback, rejoin),
            render(&whole.scrollback, rejoin)
        );
    }
}
