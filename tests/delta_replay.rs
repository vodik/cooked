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

use cooked::emu::{
    Deco, Delta, Direction, Edit, ImageId, Levels, Run, Runs, Scrolled, Shift, StyleId, Term,
};
use proptest::prelude::*;
use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};

/// The upper bound on a generated grid, in both directions.
///
/// Small on purpose. A 1x1 grid and a 3x4 grid exercise every wrap, scroll and clamp
/// path that an 80x24 one does, they do it in a handful of cells that a failure message
/// can print whole, and proptest shrinks toward them anyway. The interesting sizes here
/// are the degenerate ones — see [`size`].
const MAX_ROWS: usize = 8;
const MAX_COLS: usize = 12;

/// How many renditions the replayed terminal holds before it collects the ids nothing
/// holds, where an ordinary one holds four thousand.
///
/// Small so that collections happen every few pens rather than never. Whether an id is
/// held is decided by a hand-kept list of roots, `State::collect_styles`, and a holder
/// left off the list has its id reused under it; at this size, removing any of the grids,
/// the copy of what Emacs shows, or the scrollback waiting to be drained from that list
/// fails a property within the default case count.
const STYLE_LIMIT: usize = 4;

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
    /// No window shows the buffer any more, so its drains leave the screen out; see
    /// `Term::drain_hidden`.
    Hide,
    /// A window shows the buffer again, which catches it up with a whole drain at once.
    Show,
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
/// a column stop being the same thing, and U+00A0 because it is the other blank a glyph run
/// absorbs: `tree` indents with it.
fn printable() -> impl Strategy<Value = char> {
    prop_oneof![
        6 => (0x20u32..0x7f).prop_map(|c| char::from_u32(c).unwrap()),
        1 => Just('\u{a0}'),
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
        // `SGR 58` is the underline colour, part of the rendition a run names by id. The
        // shadow compares renditions through what each drain announced its ids to mean,
        // so a colour lost on the way shows up as a different rendition.
        (0u8..255).prop_map(|n| format!("\x1b[58;5;{n}m")),
        // Overline on and off, the underline's styles, and the offs that clear them:
        // attributes a run's rendition carries and nothing else on the row shows.
        prop::sample::select(vec![
            "53", "55", "4:0", "4:1", "4:2", "4:3", "4:4", "4:5", "21", "24"
        ])
        .prop_map(|n| format!("\x1b[{n}m")),
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
        "\u{2502}\u{a0}\u{a0} \u{2514}\u{2500}\u{2500}",
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
        // Character sets: DEC special graphics designated into G0, G1 and G2, the shifts
        // that invoke them, and ASCII back. Under it `q` prints as a box glyph, so a byte
        // the row already holds can change what the row draws.
        prop::sample::select(vec![
            "\x1b(0", "\x1b(B", "\x1b)0", "\x1b)B", "\x1b*0", "\x0e", "\x0f", "\x1bN"
        ])
        .prop_map(str::to_string),
        // DECALN fills the screen with `E` and damages every row; DECSCNM inverts the whole
        // screen, a level with no row to carry it, and a set and reset in one write is
        // `flash`, which only the toggle count shows; XTPUSHSGR and XTPOPSGR stack the pen.
        prop::sample::select(vec![
            "\x1b#8",
            "\x1b[?5h",
            "\x1b[?5l",
            "\x1b[?5h\x1b[?5l",
            "\x1b[#{",
            "\x1b[1;31#{",
            "\x1b[#}"
        ])
        .prop_map(str::to_string),
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

/// A few characters, each under a pen of its own: a syntax-highlighted line, or a
/// gradient drawn a cell at a time.
///
/// Here for the rendition table rather than the grid. Every pen is a rendition the store
/// has to give an id, and the replayed terminals hold only [`STYLE_LIMIT`] before they
/// collect, so a line of these frees ids and hands them out again while rows, the copy of
/// what Emacs holds, and scrollback still name the old ones.
fn painted() -> impl Strategy<Value = Vec<u8>> {
    prop::collection::vec((sgr(), printable()), 1..8).prop_map(|cells| {
        let mut bytes = Vec::new();
        for (pen, ch) in cells {
            bytes.extend(pen);
            bytes.extend_from_slice(ch.to_string().as_bytes());
        }
        bytes
    })
}

/// Text whose width the child declares, with `OSC 66 ; w=N`, rather than leaves to the
/// width table: the one route by which a run's columns and its characters disagree
/// without a wide character or a combining mark in it.
fn sized() -> impl Strategy<Value = Vec<u8>> {
    (1u8..4, prop::collection::vec(printable(), 1..3)).prop_map(|(width, chars)| {
        let text: String = chars.into_iter().collect();
        format!("\x1b]66;w={width};{text}\x07").into_bytes()
    })
}

/// A picture laid into the grid at the cursor: a sixel, one cell without cell metrics, or
/// a kitty transmission that names its own rectangle.
///
/// A placement is a decoration per cell, like a box glyph, but one that breaks a run on
/// every change of picture, and a picture taller than one row scrolls as it is laid.
fn image() -> impl Strategy<Value = Vec<u8>> {
    prop_oneof![
        (1u8..20).prop_map(|n| format!("\x1bP0;0;0q#0;2;100;0;0!{n}~\x1b\\")),
        (1u8..4, 1u8..4, 0u8..3).prop_map(|(cols, rows, pixel)| {
            // Two by two pixels of RGB, in base64, one of three colours so that two
            // transmissions are sometimes the same picture and sometimes not.
            let data =
                ["AAAAAAAAAAAAAAAA", "////////////////", "AP8AAP8AAP8AAP8A"][usize::from(pixel)];
            format!("\x1b_Ga=T,f=24,s=2,v=2,c={cols},r={rows};{data}\x1b\\")
        }),
    ]
    .prop_map(String::into_bytes)
}

/// One write's worth of bytes.
fn payload() -> impl Strategy<Value = Vec<u8>> {
    prop_oneof![
        5 => text(),
        2 => sgr(),
        2 => painted(),
        3 => control(),
        3 => repaint(),
        3 => rewrite(),
        3 => poke(),
        2 => box_run(),
        1 => sized(),
        1 => image(),
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
///
/// Through each of the three modes that switch screens: 1049 saves the cursor and clears
/// the alt screen, 1047 clears it on the way out, and 47 does neither.
fn alt_cycle() -> impl Strategy<Value = Vec<Step>> {
    (alt_mode(), write_step(), resize_step(), write_step()).prop_map(
        |(mode, before, resize, after)| {
            vec![
                Step::Write {
                    bytes: format!("\x1b[?{mode}h").into_bytes(),
                    splits: vec![128],
                    drain: true,
                },
                before,
                resize,
                after,
                Step::Write {
                    bytes: format!("\x1b[?{mode}l").into_bytes(),
                    splits: Vec::new(),
                    drain: true,
                },
            ]
        },
    )
}

fn alt_mode() -> impl Strategy<Value = u16> {
    prop::sample::select(vec![47u16, 1047, 1049])
}

/// The alt screen left by a route other than resetting its mode.
///
/// RIS resets everything while the alt screen is up, which has to put the primary back on
/// display. XTRESTORE of a mode saved while it was off does the same through the mode
/// machinery instead of the mode's own reset, and one saved while it was on switches
/// back to the alt screen from the primary.
fn alt_exit() -> impl Strategy<Value = Vec<Step>> {
    (alt_mode(), 0u8..3, write_step()).prop_map(|(mode, exit, write)| {
        let bytes = |b: String| Step::Write {
            bytes: b.into_bytes(),
            splits: Vec::new(),
            drain: true,
        };
        match exit {
            0 => vec![
                bytes(format!("\x1b[?{mode}h")),
                write,
                bytes("\x1bc".into()),
            ],
            1 => vec![
                bytes(format!("\x1b[?{mode}s\x1b[?{mode}h")),
                write,
                bytes(format!("\x1b[?{mode}r")),
            ],
            _ => vec![
                bytes(format!("\x1b[?{mode}h\x1b[?{mode}s\x1b[?{mode}l")),
                write,
                bytes(format!("\x1b[?{mode}r")),
                bytes(format!("\x1b[?{mode}l")),
            ],
        }
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

/// A line drawn, drained, then erased and drawn again in another pen before the next drain:
/// a menu's selection moving, a status line changing colour.
///
/// The shape that reaches a collection of the rendition table while only the copy of what
/// Emacs shows still holds the old pen's id. The erase leaves the grid without it, so the
/// new pen can be handed the same id for the same characters in the same cells, and a
/// copy the collection did not mark then calls the row unchanged.
fn recolour() -> impl Strategy<Value = Vec<Step>> {
    let lines = vec!["abcdefgh", "hello", "x"];
    (sgr(), sgr(), prop::sample::select(lines)).prop_map(|(first, second, line)| {
        let draw = |prefix: &[u8], pen: Vec<u8>, drain| Step::Write {
            bytes: [prefix, &pen, line.as_bytes()].concat(),
            splits: Vec::new(),
            drain,
        };
        vec![
            draw(b"\x1b[H", first, true),
            draw(b"\x1b[H\x1b[2K", second, false),
        ]
    })
}

fn script() -> impl Strategy<Value = Vec<Step>> {
    let group = prop_oneof![
        10 => write_step().prop_map(|s| vec![s]),
        2 => resize_step().prop_map(|s| vec![s]),
        1 => alt_cycle(),
        1 => alt_exit(),
        1 => recolour(),
        1 => save_resize_restore(),
        1 => Just(vec![Step::ForgetHistory]),
        1 => (0u8..MAX_ROWS as u8).prop_map(|row| vec![Step::Trim { row }]),
        1 => Just(vec![Step::Hide]),
        1 => Just(vec![Step::Show]),
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

/// Every rendition any replay has seen, by its `Debug` spelling, numbered in the order
/// first seen and shared by every case, so that two replays of the same bytes agree.
///
/// A drain names renditions by the ids of the terminal that drained it, and two terminals
/// fed the same bytes need not hand out the same ids: a collection frees what each
/// terminal's own copy of the screen no longer holds, and the two copies differ. So every
/// run is renumbered here before it is compared, through the rendition the drain said its
/// id meant -- which also checks that every id a run names was announced.
static RENDITIONS: LazyLock<Mutex<HashMap<String, u32>>> =
    LazyLock::new(|| Mutex::new(HashMap::from([(String::from("default"), 0)])));

/// Every picture any replay has seen, by its format, size and bytes, numbered in the
/// order first seen and shared by every case, as [`RENDITIONS`] is for renditions.
///
/// Two terminals fed the same bytes can name one picture by different ids too, because
/// an id lasts only while the terminal believes Emacs holds the bytes. A hidden `term`
/// that drains while a picture is on its grid sends the bytes and keeps the id; the
/// reference, not drained while hidden, still holds them pending when an erase takes the
/// picture off, sheds them, and mints a new id when the same picture is sent again.
static PICTURES: LazyLock<Mutex<HashMap<String, u32>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// One terminal's ids, as its drains have announced them in `Delta::styles` and
/// `Delta::images`.
#[derive(Default)]
struct Announced {
    styles: HashMap<StyleId, String>,
    images: HashMap<ImageId, String>,
}

impl Announced {
    /// Learn DELTA's announcements, then renumber every run in it; see [`RENDITIONS`] and
    /// [`PICTURES`].
    fn canonical(&mut self, mut delta: Delta) -> Delta {
        for (id, style) in &delta.styles {
            self.styles.insert(*id, format!("{style:?}"));
        }
        for image in &delta.images {
            let picture = format!("{:?} {:?} {:?}", image.format, image.px, image.bytes);
            self.images.insert(image.id, picture);
        }
        let rows = delta.rows.iter_mut().flat_map(|row| {
            std::iter::once(&mut row.runs).chain(row.edit.as_mut().map(|edit| &mut edit.runs))
        });
        let scrolled = delta.scrolled.iter_mut().map(|line| &mut line.runs);
        for runs in rows.chain(scrolled) {
            for (style, deco) in runs.ids_mut() {
                *style = self.renumber(*style);
                if let Some(Deco::Images(places)) = deco {
                    for place in places {
                        place.id = self.rename(place.id);
                    }
                }
            }
        }
        delta
    }

    fn renumber(&self, id: StyleId) -> StyleId {
        let key = if id == StyleId::DEFAULT {
            "default"
        } else {
            self.styles
                .get(&id)
                .unwrap_or_else(|| panic!("a run names {id:?}, which no drain announced"))
        };
        let mut renditions = RENDITIONS.lock().unwrap();
        let next = renditions.len() as u32;
        StyleId::from_raw(*renditions.entry(key.to_owned()).or_insert(next))
    }

    /// The id every replay gives the picture this terminal calls ID, which also checks
    /// that a drain sent its bytes before any placement named it.
    fn rename(&self, id: ImageId) -> ImageId {
        let key = self
            .images
            .get(&id)
            .unwrap_or_else(|| panic!("a placement names {id:?}, whose bytes no drain sent"));
        let mut pictures = PICTURES.lock().unwrap();
        let next = pictures.len() as u32;
        ImageId::from_index(*pictures.entry(key.clone()).or_insert(next))
    }
}

/// A terminal being driven by a script, with the shadow grid the deltas built.
struct Replay {
    term: Term,
    /// The same terminal, told before every drain that Emacs has lost its copy of every
    /// row, so that it reports every damaged row whether or not Emacs already has it.
    ///
    /// What `term` leaves out of a drain is checked against this: every row it skips
    /// must be one the reference sent with exactly the runs the shadow already holds.
    ///
    /// Its rendition table is also the ordinary size, while `term`'s collects once
    /// [`STYLE_LIMIT`] renditions are live, so every row both send is a comparison of what
    /// a terminal that reuses ids draws against one that never does. An id freed while
    /// something still named it draws another rendition there, and shows up as a row the
    /// two sent differently.
    reference: Term,
    rows: usize,
    cols: usize,
    /// Every row Emacs would be holding, as the deltas described it.
    shadow: Vec<Runs>,
    /// The shadow rows a [`Step::Trim`] edited and no drain has rewritten since, which
    /// are expected to differ from the grid: that difference is what Lisp left there.
    trimmed: Vec<bool>,
    /// Each shadow row's wrap flag as last sent, which Lisp marks the row's newline by.
    wrapped: Vec<bool>,
    /// Each drain that carried scrollback, reduced to the scrollback and the levels
    /// [`Delta::scrolled_lines`] reads to decide where its lines end.
    scrollback: Vec<Delta>,
    /// What each of `term` and `reference` has announced its rendition and picture ids to
    /// mean.
    announced: [Announced; 2],
    /// Whether a feed since the last drain said it changed something Emacs would draw.
    ///
    /// A write drains only when this is set, as the reader thread wakes Emacs only then,
    /// so a change `Term::feed` fails to report is a change no drain shows: a row left
    /// stale in the shadow, or a level left behind in `levels`.
    woken: bool,
    /// The levels and the cursor's character offset as the last drain stated them, which
    /// is what Emacs is drawing from until the next.
    levels: (Levels, usize),
    /// Whether the buffer is hidden, so a drain is `Term::drain_hidden`'s.
    hidden: bool,
    /// Whether a hidden drain has left the screen out since the last whole one, which is
    /// what showing the buffer owes a drain for.
    withheld: bool,
}

impl Replay {
    /// A fresh terminal and a shadow that agrees with it.
    ///
    /// The rows agree by construction: a new grid is blank and undamaged, and a blank row's
    /// runs are empty, because trailing blanks are trimmed out of `Row::runs`. The levels
    /// are read by a first drain, as Emacs reads them when it starts the session.
    fn new(rows: usize, cols: usize) -> Self {
        let mut replay = Self {
            term: Term::with_style_limit(rows, cols, STYLE_LIMIT),
            reference: Term::new(rows, cols),
            rows,
            cols,
            shadow: vec![Runs::default(); rows],
            trimmed: vec![false; rows],
            wrapped: vec![false; rows],
            scrollback: Vec::new(),
            announced: Default::default(),
            woken: false,
            levels: Default::default(),
            hidden: false,
            withheld: false,
        };
        replay.drain();
        replay
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
        self.shadow.resize(delta.height, Runs::default());
        self.trimmed.resize(delta.height, false);
        self.wrapped.resize(delta.height, false);
        // Before the rows and after the resize, which is the order `cooked--apply' works
        // in and the order the contract requires: a scroll reports the rows it *moved*
        // rather than damaging them, and the damage indices that follow are in the
        // coordinates the moves leave behind. This is the half of the change the oracle
        // is actually watching — if `Screen::scroll_up' narrows its damage by one row too
        // many, the shadow keeps the row the grid recycled and property 1 fails.
        self.check_promoted(&delta);
        if let Some(shift) = promotion(&delta) {
            Self::shift(&mut self.shadow, shift);
            Self::shift(&mut self.trimmed, shift);
            Self::shift(&mut self.wrapped, shift);
        }
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
        self.levels = (delta.levels, delta.cursor_chars);
        if !delta.scrolled.is_empty() {
            self.scrollback.push(Delta {
                scrolled: delta.scrolled,
                levels: delta.levels,
                ..Delta::default()
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
        // A promotion and the scroll it is left with move the rows the scroll alone did.
        // Rows the reference sends whole are exempt, since after a scroll that turned the
        // screen over the reference moves nothing and rewrites everything.
        let resent: Vec<usize> = reference.rows.iter().map(|r| r.index).collect();
        let ours = moved(delta.height, promotion(delta).iter().chain(&delta.shifts));
        let theirs = moved(delta.height, reference.shifts.iter());
        for (index, (a, b)) in ours.iter().zip(&theirs).enumerate() {
            assert!(
                a == b || resent.contains(&index),
                "the two drains moved different rows to row {index}: \
                 promoted {:?} with {:?}, against {:?}",
                delta.promoted,
                delta.shifts,
                reference.shifts
            );
        }
        let mut shadow = self.shadow.clone();
        let mut wrapped = self.wrapped.clone();
        let mut trimmed = self.trimmed.clone();
        shadow.resize(delta.height, Runs::default());
        wrapped.resize(delta.height, false);
        trimmed.resize(delta.height, false);
        for shift in promotion(delta).iter().chain(&delta.shifts) {
            Self::shift(&mut shadow, *shift);
            Self::shift(&mut wrapped, *shift);
            Self::shift(&mut trimmed, *shift);
        }
        let sent: Vec<usize> = delta.rows.iter().map(|r| r.index).collect();
        for row in &delta.rows {
            // A row nothing wrote to is still sent when the cursor moves into or out of a
            // glyph run on it, which the reference, knowing no row, never asks about. Its
            // runs are then the ones Emacs already holds, unless Lisp trimmed the row, in
            // which case sending it is what mends it.
            let theirs = reference.rows.iter().find(|r| r.index == row.index);
            assert!(
                theirs.map_or(
                    shadow.get(row.index) == Some(&row.runs) || trimmed[row.index],
                    |r| r.runs == row.runs
                ),
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

    /// Check that every row DELTA promotes is what Emacs holds at the top of its screen,
    /// as `cooked--promote-rows' keeps it: the shadow's row, padded with plain spaces to
    /// the characters the scrolled row has, and wrapped as the scrolled row is.
    fn check_promoted(&self, delta: &Delta) {
        let space = drawn(&Runs::from_runs(&[Run {
            text: " ".into(),
            cols: 1,
            style: StyleId::DEFAULT,
            deco: None,
            link: None,
        }]));
        let promoted = delta.promoted.map_or(0, |shift| shift.count);
        for (index, line) in delta.scrolled.iter().take(promoted).enumerate() {
            let held = drawn(&self.shadow[index]);
            let kept = drawn(&line.runs);
            assert!(
                !self.trimmed[index],
                "row {index} was promoted, but Lisp trimmed it"
            );
            assert_eq!(
                self.wrapped[index], line.wrapped,
                "row {index} was promoted with a different wrap flag"
            );
            assert!(
                kept.starts_with(&held) && kept[held.len()..].iter().all(|c| *c == space[0]),
                "row {index} was promoted, but Emacs holds {:?} where scrollback gets {:?}",
                self.shadow[index],
                line.runs
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
    fn check_edit(index: usize, old: &Runs, edit: &Edit, full: &Runs) {
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
                let feed = |term: &mut Term| {
                    if !fragment {
                        return term.feed(bytes);
                    }
                    let mut at = 0;
                    let mut changed = false;
                    for cut in Step::cuts(bytes, splits) {
                        changed |= term.feed(&bytes[at..cut]);
                        at = cut;
                    }
                    changed | term.feed(&bytes[at..])
                };
                // Only `term`'s answer wakes the replay; the reference is a second opinion
                // on the rows, not a second reader.
                self.woken |= feed(&mut self.term);
                feed(&mut self.reference);
                if !(*drain && self.woken) {
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
            Step::Hide => {
                self.hidden = true;
                return;
            }
            Step::Show => {
                self.hidden = false;
                if !(self.woken || self.withheld) {
                    return;
                }
            }
            Step::Trim { row } => {
                // The guard runs as a drain is rendered, so the drain comes first.
                if self.woken {
                    self.drain();
                }
                let row = usize::from(*row);
                let Some(runs) = self.shadow.get_mut(row) else {
                    return;
                };
                if runs.pop_char().is_none() {
                    return;
                }
                self.trimmed[row] = true;
                self.term.forget_sent(Some(row));
                return;
            }
        }
        self.drain();
    }

    /// Drain both terminals and absorb what they said.
    ///
    /// While hidden, `term`'s drain may leave the screen out. Then only its scrollback is
    /// absorbed, as Lisp appends only that, and the reference is not drained at all, so the
    /// moves it logs keep accumulating alongside `term`'s for the whole drain that follows.
    fn drain(&mut self) {
        self.woken = false;
        let delta = if self.hidden {
            let delta = self.announced[0].canonical(self.term.drain_hidden());
            if delta.withheld {
                assert!(
                    delta.rows.is_empty() && delta.shifts.is_empty() && delta.promoted.is_none(),
                    "a hidden drain carried the screen"
                );
                self.withheld = true;
                if !delta.scrolled.is_empty() {
                    self.scrollback.push(Delta {
                        scrolled: delta.scrolled,
                        levels: delta.levels,
                        ..Delta::default()
                    });
                }
                return;
            }
            delta
        } else {
            self.announced[0].canonical(self.term.drain_promoting())
        };
        self.withheld = false;
        self.reference.forget_sent(None);
        let reference = self.announced[1].canonical(self.reference.drain());
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
        // wake, so the shadow is up to date before it is compared. A change no feed
        // reported woke nothing, and stays out of the shadow.
        self.hidden = false;
        if self.woken || self.withheld {
            self.drain();
        }
        self.term.touch_all();
        let full = self.term.drain();
        self.announced[0].canonical(full)
    }
}

/// The move a promotion makes of Emacs' screen: the promoted rows leave the top and as
/// many blank rows open at the bottom of their region, the scroll that took them off
/// without its deletion.
fn promotion(delta: &Delta) -> Option<Shift> {
    delta.promoted
}

/// Which row each row of a HEIGHT-row screen holds once SHIFTS are made, by the index it
/// held before them, or `None` for a blank row a shift opened.
fn moved<'a>(height: usize, shifts: impl Iterator<Item = &'a Shift>) -> Vec<Option<usize>> {
    let mut rows: Vec<Option<usize>> = (0..height).map(Some).collect();
    for shift in shifts {
        Replay::shift(&mut rows, *shift);
    }
    rows
}

/// RUNS as what Emacs draws for each character: the character, its rendition and link,
/// and its decoration.
fn drawn(runs: &Runs) -> Vec<String> {
    runs.iter()
        .flat_map(|run| {
            run.text.chars().enumerate().map(move |(i, c)| {
                format!("{c:?} {:?} {:?} {:?}", run.style, run.link, run.deco_at(i))
            })
        })
        .collect()
}

/// Whether character offset AT falls strictly inside a run of RUNS that carries box
/// glyphs.
fn inside_glyph_run(runs: &Runs, at: usize) -> bool {
    let mut start = 0;
    for run in runs {
        let len = run.chars;
        if run.deco_at(0).is_some() && start < at && at < start + len {
            return true;
        }
        start += len;
    }
    false
}

/// The scrollback as the text Emacs inserts, under one setting of
/// `cooked-rejoin-wrapped-lines`, with the lines ended where [`Delta::scrolled_lines`]
/// ends them for the module.
fn render(scrollback: &[Delta], rejoin: bool) -> String {
    let mut out = String::new();
    for batch in scrollback {
        for (line, ends) in batch.scrolled_lines(rejoin) {
            for run in &line.runs {
                out.push_str(run.text);
            }
            if ends {
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
/// A `assert_eq!` on the two `Vec<Runs>` prints both grids in full, which for an 8x12
/// grid of styled runs is several screens of `Debug` output with the one differing field
/// somewhere inside it. This is §9's first-difference visualization: say which row, which
/// run, and show only that pair.
fn difference(shadow: &[Runs], full: &[Runs], skip: &[bool]) -> Option<String> {
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
fn dense(delta: &Delta) -> Result<Vec<Runs>, TestCaseError> {
    let indices: Vec<usize> = delta.rows.iter().map(|r| r.index).collect();
    let expected: Vec<usize> = (0..delta.height).collect();
    prop_assert_eq!(
        indices,
        expected,
        "a drain after touch_all must report every row once, ascending"
    );
    Ok(delta.rows.iter().map(|r| r.runs.clone()).collect())
}

/// Property 1: the deltas said everything the grid would have said.
fn replays_the_whole_grid(rows: usize, cols: usize, steps: &[Step]) -> Result<(), TestCaseError> {
    let mut replay = Replay::new(rows, cols);
    for step in steps {
        replay.step(step, true);
    }
    let full = replay.full();
    let grid = dense(&full)?;
    if let Some(where_) = difference(&replay.shadow, &grid, &replay.trimmed) {
        return Err(TestCaseError::fail(format!(
            "replaying the deltas did not reproduce the grid — {where_}"
        )));
    }
    // The levels too: the cursor, DECSCNM's reverse video and its toggle count, the alt
    // screen and the key encoding are what Emacs draws and encodes from, and none of
    // them is in a row.
    prop_assert_eq!(
        replay.levels,
        (full.levels, full.cursor_chars),
        "the last drain left Emacs with levels the terminal no longer has"
    );
    Ok(())
}

/// Property 2: where the writes were cut did not matter.
fn fragmenting_changes_nothing(
    rows: usize,
    cols: usize,
    steps: &[Step],
    rejoin: bool,
) -> Result<(), TestCaseError> {
    let mut split = Replay::new(rows, cols);
    let mut whole = Replay::new(rows, cols);
    for step in steps {
        split.step(step, true);
        whole.step(step, false);
    }
    let (a, b) = (split.full(), whole.full());
    prop_assert_eq!(
        (a.levels, a.cursor_chars),
        (b.levels, b.cursor_chars),
        "the same bytes cut differently left different levels"
    );
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
    let runs = |batches: &[Delta]| -> Vec<Scrolled> {
        batches.iter().flat_map(|b| b.scrolled.clone()).collect()
    };
    prop_assert_eq!(runs(&split.scrollback), runs(&whole.scrollback));
    prop_assert_eq!(
        render(&split.scrollback, rejoin),
        render(&whole.scrollback, rejoin)
    );
    Ok(())
}

/// Property 3: hiding the buffer for a while changes nothing once it is shown again.
///
/// The same script run with its `Hide` and `Show` steps and without them must end on the
/// same grid and hand Emacs the same scrollback, row for row. Property 1 already holds the
/// hidden run's drains to the grid; this holds the scrollback, which a hidden drain
/// delivers in batches a visible one never would, to the rows a visible run delivered.
fn hiding_changes_nothing(rows: usize, cols: usize, steps: &[Step]) -> Result<(), TestCaseError> {
    let mut hidden = Replay::new(rows, cols);
    let mut shown = Replay::new(rows, cols);
    for step in steps {
        hidden.step(step, true);
        if !matches!(step, Step::Hide | Step::Show) {
            shown.step(step, true);
        }
    }
    let (a, b) = (hidden.full(), shown.full());
    prop_assert_eq!(
        (a.levels, a.cursor_chars),
        (b.levels, b.cursor_chars),
        "hiding the buffer left different levels"
    );
    let (a, b) = (dense(&a)?, dense(&b)?);
    if let Some(where_) = difference(&a, &b, &[]) {
        return Err(TestCaseError::fail(format!(
            "hiding the buffer produced a different grid — {where_}"
        )));
    }
    let runs = |batches: &[Delta]| -> Vec<Scrolled> {
        batches.iter().flat_map(|b| b.scrolled.clone()).collect()
    };
    prop_assert_eq!(runs(&hidden.scrollback), runs(&shown.scrollback));
    Ok(())
}

proptest! {
    // 1024 rather than proptest's default 256: a case is a few dozen cells and a few
    // hundred bytes, so the pair of properties still runs in about a second and
    // quadrupling the cases is the cheapest coverage on offer. `PROPTEST_CASES=100000`
    // in the environment is the long soak, for when something is suspected but not
    // reproducing.
    //
    // Nothing is persisted. proptest would store the RNG seed of a failure, and a seed
    // names a case only for the strategies that produced it: adding a motif to
    // `payload()` or changing a weight quietly turns it into some other random case. A
    // failure is written out instead, as a named test under "Regressions" below, from
    // the minimal input proptest prints.
    //
    // Read from the environment here because an explicit `cases` overrides proptest's
    // own reading of `PROPTEST_CASES`, which silently made the soak run 1024 cases too.
    #![proptest_config(ProptestConfig {
        cases: std::env::var("PROPTEST_CASES")
            .ok()
            .and_then(|cases| cases.parse().ok())
            .unwrap_or(1024),
        failure_persistence: None,
        ..ProptestConfig::default()
    })]

    #[test]
    fn deltas_replay_the_whole_grid(((rows, cols), steps) in (size(), script())) {
        replays_the_whole_grid(rows, cols, &steps)?;
    }

    #[test]
    fn fragmenting_the_writes_changes_nothing(
        ((rows, cols), steps, rejoin) in (size(), script(), any::<bool>())
    ) {
        fragmenting_changes_nothing(rows, cols, &steps, rejoin)?;
    }

    #[test]
    fn hiding_the_buffer_changes_nothing(((rows, cols), steps) in (size(), script())) {
        hiding_changes_nothing(rows, cols, &steps)?;
    }
}

// ---------------------------------------------------------------------------
// Regressions
// ---------------------------------------------------------------------------
//
// Cases the properties have failed on, each shrunk by proptest and written out, run through
// the property that found it. Most came from deliberately broken builds while the checks
// were being written -- a copy of Emacs' screen that was not shifted, a trim that was not
// forgotten, a glyph run cut by an edit -- and the rest from real bugs. The first two
// predate `Step::Write::drain`, when every write drained.

/// A write of TEXT, cut at SPLITS (fractions of its length in 256ths), and drained after if
/// DRAIN.
fn write(text: &str, splits: &[u8], drain: bool) -> Step {
    Step::Write {
        bytes: text.as_bytes().to_vec(),
        splits: splits.to_vec(),
        drain,
    }
}

#[test]
fn a_split_c1_control_between_a_cursor_save_and_restore() {
    let steps = [
        write("\x1b[s", &[100], true),
        Step::Resize { rows: 0, cols: 0 },
        write("\u{80}", &[128], true),
        write("\x1b[u", &[], true),
    ];
    fragmenting_changes_nothing(1, 1, &steps, false).unwrap();
}

#[test]
fn combining_marks_among_box_glyphs_on_a_one_cell_grid() {
    let steps = [write(
        "    \u{2500} \u{2500}\u{300} \u{300}        \u{2500}",
        &[114],
        true,
    )];
    fragmenting_changes_nothing(1, 1, &steps, false).unwrap();
}

#[test]
fn a_row_trimmed_before_it_was_drained() {
    let steps = [
        write("\x1b[H\x1b[0mabcdefgh", &[], false),
        Step::Trim { row: 0 },
    ];
    replays_the_whole_grid(1, 1, &steps).unwrap();
}

#[test]
fn a_trimmed_row_erased_and_written_back() {
    let steps = [
        write("", &[], false),
        write("\x1b[H\x1b[0mabcdefgh", &[], false),
        Step::Trim { row: 0 },
        write("\x1b[1;1H\x1b[2Kabcdefgh", &[], false),
    ];
    fragmenting_changes_nothing(1, 5, &steps, false).unwrap();
}

#[test]
fn a_trimmed_row_redrawn_by_a_screen_clear() {
    let steps = [
        write("\x1b[H\x1b[2Jabcdefgh\r\nabcdefgh", &[], false),
        Step::Trim { row: 0 },
        write("\x1b[H\x1b[2Jabcdefgh\r\nabcdefgh", &[], false),
    ];
    replays_the_whole_grid(1, 1, &steps).unwrap();
}

#[test]
fn a_box_row_under_a_row_with_a_background() {
    let steps = [
        write("\x1b[H\x1b[48;2;0;0;0mAA BB", &[], true),
        write("\x1b[2;1H\x1b[2K\u{2502} \u{2500}\u{2500}", &[], false),
    ];
    replays_the_whole_grid(4, 1, &steps).unwrap();
}

#[test]
fn a_row_rewritten_after_the_alt_screen_resized_back() {
    let steps = [
        Step::Resize { rows: 2, cols: 0 },
        write("\x1b[?1049h", &[128], true),
        write("", &[], false),
        Step::Resize { rows: 3, cols: 0 },
        write("", &[], false),
        write("\x1b[?1049l", &[], true),
        write("\x1b[H\x1b[0mabcdefgh", &[], true),
        write("\x1b[2;1H\x1b[2Kabcdefgh", &[], false),
    ];
    fragmenting_changes_nothing(3, 1, &steps, false).unwrap();
}

#[test]
fn a_row_written_below_the_grid_between_two_screen_clears() {
    let steps = [
        Step::Resize { rows: 4, cols: 0 },
        write("\x1b[H\x1b[2Jabcdefgh\r\nhello", &[], false),
        write("\x1b[6;1H\x1b[2K\u{2502} \u{2500}\u{2500}", &[], true),
        write("\x1b[H\x1b[2Jabcdefgh\r\nhello", &[], false),
    ];
    replays_the_whole_grid(3, 1, &steps).unwrap();
}

#[test]
fn text_redrawn_with_an_underline_colour_after_a_screen_clear() {
    let steps = [
        write("\x1b[H\x1b[2Jabcdefgh\r\nabcdefgh", &[], true),
        write("\x1b[H\x1b[58;5;0mabcdefgh", &[], false),
    ];
    fragmenting_changes_nothing(1, 1, &steps, false).unwrap();
}

#[test]
fn a_character_redrawn_with_an_underline_colour() {
    let steps = [
        write("\x1b[H\x1b[0mx", &[], true),
        write("\x1b[H\x1b[58;5;0mx", &[], false),
    ];
    replays_the_whole_grid(1, 1, &steps).unwrap();
}

#[test]
fn an_erase_below_after_a_nul() {
    let steps = [write(" \0!", &[], true), write("\x1b[0J", &[], false)];
    replays_the_whole_grid(1, 2, &steps).unwrap();
}

#[test]
fn history_forgotten_before_a_shrink_and_a_screen_clear() {
    let steps = [
        write("\x1b[1;1H\x1b[2Khello", &[], false),
        write("    \u{4e00}          !", &[], false),
        Step::ForgetHistory,
        Step::Resize { rows: 1, cols: 0 },
        write("\x1b[H\x1b[2Jabcdefgh\r\nhello", &[], false),
    ];
    fragmenting_changes_nothing(4, 5, &steps, false).unwrap();
}

#[test]
fn a_restore_after_narrowing_and_a_write() {
    let steps = [
        write("    \u{2500}\u{2500}", &[], false),
        write("\x1b[s", &[100], true),
        Step::Resize { rows: 0, cols: -5 },
        write(" ", &[], true),
        write("\x1b[u", &[], true),
        write("  ", &[], false),
    ];
    replays_the_whole_grid(8, 11, &steps).unwrap();
}

#[test]
fn a_combining_mark_on_a_box_glyph_under_a_background_pen() {
    let steps = [
        Step::Resize { rows: 1, cols: -1 },
        write("\x1b[48;2;0;0;0m", &[], false),
        write("     ", &[], true),
        write("       \u{2500}\u{300}", &[], false),
    ];
    fragmenting_changes_nothing(1, 3, &steps, false).unwrap();
}

#[test]
fn a_box_run_after_the_scroll_region_is_reset() {
    let steps = [
        write("\x1b[H\x1b[0m....", &[], false),
        write(" \u{4e00}!", &[], true),
        write("\x1b[r", &[], false),
        write(
            "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}",
            &[],
            false,
        ),
    ];
    replays_the_whole_grid(2, 4, &steps).unwrap();
}

#[test]
fn a_restore_after_wide_characters_rewrap() {
    let steps = [
        write("   \u{4e00}           \u{4e00}\u{4e00}\u{4e00}", &[], false),
        Step::Resize { rows: 0, cols: 3 },
        write("\x1b[H\x1b[0mx", &[], false),
        write("\x1b[s", &[100], true),
        Step::Resize { rows: 0, cols: 0 },
        write(
            "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}",
            &[],
            false,
        ),
        write("\x1b[u", &[], true),
    ];
    fragmenting_changes_nothing(6, 2, &steps, false).unwrap();
}

#[test]
fn two_save_resize_restore_cycles_over_wide_characters() {
    let steps = [
        write("\x1b[s", &[100], true),
        Step::Resize { rows: 0, cols: 3 },
        write("             ", &[], false),
        write("\x1b[u", &[], true),
        write("\x1b[s", &[100], true),
        Step::Resize { rows: 2, cols: 6 },
        write(" \u{4e00}\u{4e00}\u{2500}", &[], false),
        write("\x1b[u", &[], true),
        write("\u{2500}\u{2500}\u{2500}\u{2500}", &[], false),
    ];
    replays_the_whole_grid(1, 1, &steps).unwrap();
}

#[test]
fn wide_characters_and_a_mark_with_autowrap_off() {
    let steps = [
        write("         ", &[], false),
        write("\x1b[?7l", &[], false),
        write(" \u{4e00}\u{4e00}\u{300}", &[], true),
        write(" ", &[], false),
    ];
    replays_the_whole_grid(2, 7, &steps).unwrap();
}

#[test]
fn two_alt_screen_cycles_with_autowrap_off() {
    let steps = [
        write("\x1b[?7l", &[], false),
        write("\x1b[?1049h", &[128], true),
        write("", &[], false),
        Step::Resize { rows: 0, cols: 3 },
        write("", &[], false),
        write("\x1b[?1049l", &[], true),
        write("\x1b[?1049h", &[128], true),
        write("\u{2500}\u{2500}", &[], false),
        Step::Resize { rows: 0, cols: -2 },
        write("\x1b[0J", &[], true),
        write("\x1b[?1049l", &[], true),
    ];
    replays_the_whole_grid(1, 1, &steps).unwrap();
}

#[test]
fn a_scroll_region_set_after_a_restore_on_a_box_row() {
    let steps = [
        Step::Resize { rows: 0, cols: 0 },
        write("\x1b[s", &[100], true),
        Step::Resize { rows: 1, cols: 0 },
        write("  \u{2500}", &[], false),
        write("\x1b[u", &[], true),
        write("\u{2500}", &[], false),
        write("\x1b[1;2r", &[], false),
    ];
    fragmenting_changes_nothing(1, 5, &steps, false).unwrap();
}

#[test]
fn a_lone_combining_mark_after_a_resize() {
    let steps = [
        Step::Resize { rows: 0, cols: 3 },
        write("\u{300}", &[], false),
    ];
    fragmenting_changes_nothing(1, 1, &steps, false).unwrap();
}

#[test]
fn a_repaint_over_a_wide_character_carrying_a_mark() {
    let steps = [
        write("h\u{4e00}\u{300}  !", &[], true),
        write("\x1b[H\x1b[0mhello", &[], false),
    ];
    replays_the_whole_grid(5, 9, &steps).unwrap();
}

/// A pen with a background taken as it fills the rendition table: the collection for its
/// erase rendition freed its text rendition's id, and the text was written under an id no
/// drain announced.
#[test]
fn a_pen_whose_erase_rendition_fills_the_table() {
    let steps = [
        write("\x1b[1m", &[], false),
        write(" ", &[], false),
        write("\x1b[H\x1b[2mabcdefgh", &[], false),
        write("\x1b[48;2;0;0;0m", &[], false),
        write("\x1b[1;1H\x1b[2Kabcdefgh", &[], false),
        write("\x1b[?1049h", &[128], true),
        write("\x1b[H\x1b[40mabcdefgh", &[], false),
        Step::Resize { rows: 0, cols: 0 },
        write("", &[], false),
        write("\x1b[?1049l", &[], true),
        write("\x1b[H\x1b[41mabcdefgh", &[], false),
    ];
    replays_the_whole_grid(1, 1, &steps).unwrap();
}

/// Two overlapping scroll regions taking turns while the buffer is hidden: the top six
/// rows scrolled down, then the whole screen up. Nothing coalesces, so the log reaches the
/// screen's height and is emptied at a scroll of the small region. The rows below it that
/// the whole-screen scrolls moved, and no write touched, must still be repainted.
#[test]
fn two_scroll_regions_taking_turns_while_hidden() {
    let lines: Vec<String> = (0..8).map(|i| format!("row{i}")).collect();
    let mut steps = vec![write(&lines.join("\r\n"), &[], true), Step::Hide];
    for _ in 0..4 {
        steps.push(write(
            "\x1b[1;3r\x1b[1;1H\x1bM\x1b[r\x1b[8;1H\x1bD",
            &[],
            true,
        ));
    }
    steps.push(write("\x1b[1;3r\x1b[1;1H\x1bM\x1b[r", &[], true));
    steps.push(Step::Show);
    replays_the_whole_grid(8, 5, &steps).unwrap();
    hiding_changes_nothing(8, 5, &steps).unwrap();
}

/// A picture sent while hidden, erased, and sent again: the hidden drain sent the bytes
/// while the picture was on the grid, so `term` names it again by the same id, while the
/// reference, not drained while hidden, shed the bytes at the erase and minted another.
/// Both rows draw the same picture, and are compared as such.
#[test]
fn a_picture_sent_again_after_a_hidden_drain_sent_its_bytes() {
    let picture = "\x1b_Ga=T,f=24,s=2,v=2,c=1,r=1;AAAAAAAAAAAAAAAA\x1b\\";
    let steps = [
        Step::Hide,
        write(picture, &[], false),
        Step::Resize { rows: 0, cols: 2 },
        write("\x1b[1J", &[], false),
        Step::Show,
        write("\x1b[?47h", &[], false),
        write(picture, &[], true),
        write("\x1bc", &[], true),
    ];
    fragmenting_changes_nothing(1, 4, &steps, false).unwrap();
    replays_the_whole_grid(1, 4, &steps).unwrap();
    hiding_changes_nothing(1, 4, &steps).unwrap();
}
