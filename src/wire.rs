//! The shape everything the core reports takes on its way into Lisp.
//!
//! lib.rs registers the functions Emacs calls and unpacks their arguments; this module
//! owns the other direction. A drain's [`Update`] becomes the plist `cooked--drain'
//! returns, rows become [`Block`]s, events become tagged lists, and every enum that
//! crosses as a bare symbol is spelled once here.

use crate::emu::{
    self, Anchor, Color, CursorShape, DamagedRow, Deco, Event, ImageData, ImageFormat, ImageId,
    KeyEncoding, LinkId, Mark, MarkId, Run, Style,
};
use crate::env::{self, Env, Result, Value, lisp_enum, list, plist, sym};
use crate::pty::{Mode, Pid};
use crate::session::Update;

/// The crate's id newtypes, which are all one integer wide.
///
/// Without these every id crossed the boundary as `i64::from(id.0)`, which reached past
/// the newtype to the field it exists to hide.
macro_rules! into_lisp_id {
    ($($t:ty),* $(,)?) => {
        $(impl env::IntoLisp for $t {
            fn into_lisp(self, env: &Env) -> Result<Value> {
                self.0.into_lisp(env)
            }
        })*
    };
}

into_lisp_id!(MarkId, LinkId, ImageId);

// Every enum this module sends as a bare symbol, and the symbol each variant is. One
// list per type, so the drain's `:mode' and `cooked--sample-mode' cannot drift into
// disagreeing about what to call the same state -- they now reach the same table through
// the same impl, where before one went through an impl here and the other interned
// `Mode::as_str' on its own.
lisp_enum! {
    Mode {
        Cooked => "cooked",
        Raw => "raw",
        Secret => "secret",
    }
    /// `cooked.el' maps these onto `cursor-type'.
    CursorShape {
        Block => "block",
        Underline => "underline",
        Bar => "bar",
    }
    /// The type symbol handed to `create-image'.
    ImageFormat {
        Png => "png",
        Jpeg => "jpeg",
        Gif => "gif",
        Ppm => "pbm",
    }
}

/// What the child negotiated, as the symbol `:keys' carries. The flags or the level the
/// encoding holds cross beside it as `:kitty-flags' and `:modify-other-keys'.
impl env::IntoLisp for KeyEncoding {
    fn into_lisp(self, env: &Env) -> Result<Value> {
        match self {
            KeyEncoding::Legacy => sym!(env, "legacy"),
            KeyEncoding::ModifyOtherKeys(_) => sym!(env, "modify-other"),
            KeyEncoding::Kitty(_) => sym!(env, "kitty"),
        }
    }
}

impl env::IntoLisp for Pid {
    fn into_lisp(self, env: &Env) -> Result<Value> {
        self.get().into_lisp(env)
    }
}

/// The damaged rows split into maximal runs of *consecutive* indices.
///
/// The whole of the coalescing decision, kept as a pure function over the slice so that
/// it can be tested without an Emacs — everything else on this path needs an `Env` and
/// so can only be exercised by the Lisp suite.
///
/// Ascending order is what makes a run a run, and [`crate::emu::screen::Screen::drain_damage`] produces it
/// by construction: it walks the dirty flags by index. Nothing here *relies* on that,
/// which is deliberate. The condition is `next == this + 1` rather than "not known to be
/// clean", so a list that arrived out of order or with a repeat simply coalesces less;
/// it cannot merge rows that are not neighbours.
///
/// That condition is the whole hazard. ghostel's equivalent breaks a span only on a row
/// it knows to be clean, so a page-granularity false positive is amplified into one
/// giant reinsert — and a reinsert is `delete-region` then `insert`, which destroys
/// every marker and overlay anchored inside it. Coalescing runs of *genuinely damaged*
/// rows cannot do that: an undamaged row between two damaged ones is never inside a
/// block, so nothing anchored to it is touched.
fn contiguous_runs(rows: &[DamagedRow]) -> impl Iterator<Item = &[DamagedRow]> {
    rows.chunk_by(|this, next| next.index == this.index + 1)
}

/// `(:scrolled ROWS :rows ((FIRST . BLOCK)...) :height N :used N :head N
/// :cursor (ROW COL VISIBLE) :marks ((ID . ANCHOR)...) ...)`
pub(crate) fn update_to_lisp(env: Env, update: &Update, rejoin: bool) -> Result<Value> {
    // The scrollback is assembled first because the events are resolved against it: a
    // mark on a row that scrolled away during this very drain is spelled as an offset
    // into the text about to be inserted, which only exists once that text is built.
    let (scrolled, spans) = update.scrolled_rows(env, rejoin)?;
    // `(FIRST . BLOCK)`, the same [`Block`] scrollback arrives in, so one renderer in
    // Lisp handles both. FIRST is the index of the block's *first* row; its table says
    // how many follow it and where each begins.
    //
    // Newlines go *between* the rows of a run and never after the last one, which is the
    // same rule the old row-at-a-time shape stated as "a damaged row carries no
    // newline": a live row is written into a buffer line that already exists, so the
    // newline that ends the run's last row is the one already sitting there. Emacs pays
    // for every edit, so a 24-row repaint that was 24 `delete-region's and 24 `insert's
    // is one of each here.
    let rows = contiguous_runs(&update.delta.rows)
        .map(|run| {
            let mut block = Block::default();
            for (i, row) in run.iter().enumerate() {
                if i > 0 {
                    block.push_newline();
                }
                block.push_runs(env, &row.runs)?;
                block.end_row(row.wrapped);
            }
            env.cons(env.into_lisp(run[0].index)?, block.into_lisp(&env)?)
        })
        .collect::<Result<Vec<_>>>()?;
    // `(TOP BOTTOM COUNT UP)` per move, in the order they happened; see [`Shift`]. A list
    // per move rather than a packed record because there is at most a handful of them in
    // a drain and usually none: the packing idiom earns its keep at one record per
    // character, not at one per scroll region per frame.
    let shifts = update
        .delta
        .shifts
        .iter()
        .map(|s| {
            list!(
                env,
                [s.top, s.bottom, s.count, s.direction == emu::Direction::Up]
            )
        })
        .collect::<Result<Vec<_>>>()?;
    let levels = &update.delta.levels;
    let cursor = list!(
        env,
        [
            levels.cursor.row,
            levels.cursor.col,
            levels.cursor_visible,
            levels.cursor_shape,
        ]
    )?;
    let events = update
        .delta
        .events
        .iter()
        .map(|e| event_to_lisp(env, e, update, &spans))
        .collect::<Result<Vec<_>>>()?;
    // `(ID . ANCHOR)`, in the same coordinates a mark's own event carries, so Lisp
    // resolves both with `cooked--anchor-position'. Empty on every drain but a resize.
    let marks = update
        .delta
        .marks
        .iter()
        .map(|(id, at)| {
            env.cons(
                env.into_lisp(*id)?,
                update.anchor_to_lisp(env, *at, &spans)?,
            )
        })
        .collect::<Result<Vec<_>>>()?;

    plist!(env, {
        ":scrolled"    => scrolled,
        ":shifts"      => shifts,
        ":rows"        => rows,
        ":height"      => update.delta.height,
        ":used"        => update.delta.used,
        ":head"        => update.delta.head,
        ":cursor"      => cursor,
        ":reverse"     => levels.reverse_screen,
        ":marks"       => marks,
        ":alt"         => levels.alt,
        ":app-cursor"  => levels.app_cursor,
        ":keys"        => levels.keys,
        ":kitty-flags" => u32::from(levels.keys.kitty_flags().bits()),
        ":modify-other-keys" => u32::from(levels.keys.modify_other_keys_level()),
        ":mode"        => update.mode,
        ":images"      => images_to_lisp(env, &update.delta.images)?,
        ":links"       => links_to_lisp(env, &update.delta.links)?,
        ":events"      => events,
        ":exit"        => update.exit.map(i64::from),
    })
}

/// A run of buffer text with its styling and decoration held off to the side.
///
/// The one shape rendered text crosses in, for the live screen and for scrollback alike
/// — one encoder here and one renderer in Lisp, which is the point: a second shape means
/// every field has to be taught to both, and they drift.
///
/// Sparse rather than a run per damaged row, because Emacs pays for every `insert`. One
/// insert of one string, plus properties only where they depart from the default, beats
/// N inserts and N property calls, and it keeps roughly a million cons cells from
/// crossing the boundary on a flood. A plain unstyled row — the overwhelming majority on
/// the primary screen — pays for no spans at all, not even an empty string, and a row of
/// eight styled runs costs one insert rather than eight. Sparseness survived the move to
/// packed records precisely because it is the property the flood path rests on: an
/// unstyled block still allocates nothing, and the `plain` benchmark row is the control
/// that says so.
///
/// STYLE-SPANS is a unibyte string of fixed-width records rather than a list, and it is
/// the only one carrying a rendition — see [`Block::push_style`] for the layout and for
/// why the live-row path cannot afford the conses. DECO-SPANS is `(START DECO)` and
/// LINK-SPANS `(START END ID)`, both for the same reason: neither says anything about
/// how its characters are *coloured*.
/// Emacs draws a box glyph in the colours of the face at the position it sits on, which
/// STYLE-SPANS has already put there over exactly those characters, so a decoration
/// span repeating them would be handing Lisp a second, staler answer to a question it
/// has already had — see `cooked--box-glyph-image-1' for what reading that second copy
/// cost. A hyperlink is the same story: whatever style it has is in STYLE-SPANS, and
/// Lisp deliberately leaves it alone.
///
/// A row table rides at the end of the list, after the spans: one `(START WIDTH
/// UNIFORM)` per *screen row* the block covers, in order — where that row's text begins
/// as a character offset into TEXT, how many columns it occupies on the grid, and
/// whether every character of it is one byte standing on one cell. The last two are
/// by-products of work already done ([`Run::cols`] is accumulated as the run is built,
/// and uniformity falls out of the character count `push_runs` takes anyway), and both
/// replace a measurement Emacs was making per rendered row per drain — see
/// `cooked--guard-row-width'.
///
/// **A table rather than the two scalars it replaced, because a block is no longer one
/// row.** [`update_to_lisp`] coalesces a run of contiguous damaged rows into a single
/// block, so each of the guard's two questions has an answer per row rather than one
/// per block, and the offsets are what let `cooked--render-block' phase a shade glyph's
/// dither against the row it actually sits on rather than against the first row of the
/// run. The table's length is also how Lisp knows how many rows the block covers;
/// nothing counts newlines. It is a list of three-element lists rather than a packed
/// record for the reason the packing idiom itself gives: packing earns its keep where
/// the alternative is thousands of conses per frame, and a screenful of rows is at most
/// a hundred. The scrollback block carries no table at all — nothing guards or phases
/// scrollback, whose lines are Emacs' own reflowable text — so a flood of twenty
/// thousand lines pays nothing for this.
///
/// A decoration span needs no END either: its packed records account for every
/// character it covers, whether one apiece or one per run of them — see
/// `deco_to_lisp`. The link id is resolved against the `:links` table the same drain
/// carries.
#[derive(Default)]
pub(crate) struct Block {
    pub(crate) text: String,
    pub(crate) styles: Vec<u8>,
    decos: Vec<Value>,
    links: Vec<Value>,
    pub(crate) offset: usize,
    /// Columns `text` occupies on the grid, summed from [`Run::cols`].
    ///
    /// The measurement Emacs would otherwise take for itself. `cooked--guard-row-width'
    /// has to know how wide a rendered row *should* be before it can decide whether
    /// Emacs laid it out wider than that, and its only way of asking was `string-width',
    /// which is the same East Asian Width model the grid already applied when it placed
    /// the continuation cells — measured at 1.5us a row for ASCII, 59us for CJK and
    /// 100us for box drawing, per rendered row per drain, to recompute a number this
    /// side had already computed and thrown away.
    ///
    /// Carried rather than re-derived for a second reason that outlives the
    /// microseconds: it is the only route a *declared* width has to Emacs. Under kitty's
    /// Text Sizing Protocol (OSC 66 `w=N`) the child states how many cells a run
    /// occupies, and that statement can legitimately disagree with what a width table
    /// says about the same characters. While Emacs answers the question itself it can
    /// only ever give the Unicode answer, so the child's would have nowhere to go. This
    /// field is where it goes: see `State::text_size`, which honours `w=` by writing a
    /// block of the declared width onto the grid, from where it is counted here like any
    /// other run of cells.
    ///
    /// Accumulated for the row being built and banked by [`Block::end_row`], because a
    /// live block now holds a whole run of contiguous rows and the guard asks its
    /// question of each of them separately. Left to run on across the whole scrollback
    /// block, which never calls `end_row` and whose sum nothing reads.
    cols: usize,
    /// Whether any character in `text` took more than one byte or stands on more than
    /// one cell.
    ///
    /// Not "is this row ASCII": `OSC 66 ; w=1 ; Ha` is two ASCII characters declared to
    /// occupy one cell, and that breaks this exactly as a wide or multi-byte character
    /// would — see `push_runs`. What the flag actually promises is the one thing
    /// `cooked--guard-row-width' needs to skip a row outright: every character here
    /// occupies exactly the one cell a byte-per-column reading would assume, so nothing
    /// about it can disagree with the grid.
    ///
    /// Free, and the reason it is computed here rather than off the cells: `push_runs`
    /// already counts a run's characters, and a UTF-8 string's byte length equals that
    /// count exactly when every character in it is one byte. Lisp's own version of this
    /// question was a `string-match-p' over the row.
    ///
    /// Per row and reset by [`Block::end_row`], for the reason [`Block::cols`] gives:
    /// one nonuniform row in a coalesced run must not make the whole run take the slow
    /// path, and — the half that actually matters — must not be able to hide behind a
    /// neighbour either, since the flag is an *or* over what has been pushed.
    nonuniform: bool,
    /// Where the row currently being built begins in `text`, in characters.
    ///
    /// Moved by [`Block::end_row`] and by [`Block::push_newline`], which are the two
    /// ways a row can end: a damaged run puts a newline between its rows but not after
    /// the last one, so neither call alone can keep this right.
    row_start: usize,
    /// One entry per screen row closed with [`Block::end_row`], in order. Empty for
    /// scrollback, which closes none.
    rows: Vec<BlockRow>,
}

/// One screen row inside a [`Block`]: where its text starts, and the two things
/// `cooked--guard-row-width' has to be told about it.
///
/// Distinct from [`RowSpan`], which answers a different question for a different
/// consumer — where a *scrolled* row's text landed, so an [`Anchor`] can be spelled as
/// an offset into it. That one carries a length because a mark can point into the
/// middle of a row; this one carries the width and the uniformity flag because Emacs
/// has to decide whether its own layout of the row disagrees with the grid's.
#[derive(Clone, Copy)]
struct BlockRow {
    start: usize,
    cols: usize,
    uniform: bool,
    /// [`Row::wrapped`](crate::emu::cell::Row::wrapped): the row below continues this
    /// row's logical line, so the newline between them is a soft wrap the child never
    /// wrote.
    ///
    /// The only field here that is not the width guard's. It rides the same table
    /// because it is the same kind of fact -- something the core knows about a rendered
    /// row that Emacs cannot see for itself -- and a second per-row list to carry one
    /// bool would cost a cons per row per drain to say less clearly.
    wrapped: bool,
}

/// Bytes in one packed style span. See [`Block::push_style`] for the field layout.
const STYLE_RECORD: usize = 22;

impl Block {
    /// Pack one style span onto `styles`: the run's extent, its rendition, and its
    /// underline colour, as fixed-width little-endian fields.
    ///
    ///   0..4    START    `u32`, character offset into [`Block::text`]
    ///   4..8    END      `u32`, exclusive
    ///   8..12   FG       `u32`, tagged — see [`Color::packed`]
    ///   12..16  BG       `u32`, tagged
    ///   16..20  UNDERLINE `u32`, tagged; `SGR 58`, the underline's own colour
    ///   20..22  ATTRS    `u16`, the [`Attrs`](emu::cell::Attrs) bitmask
    ///
    /// A packed string rather than a list of lists, for the reason [`Deco::packed`]
    /// gives at greater length: Rust parses at 74-422 MB/s while the Emacs apply path
    /// manages roughly 21 MB/s equivalent, so anything the protocol declines to say
    /// outright is rediscovered on the slow side, on every damaged row of every frame.
    /// A span used to cross as `(START END FG BG ATTRS UNDERLINE)` — six conses, and up
    /// to twelve once an RGB colour spelled itself as a three-element list.
    ///
    /// Measured 1.20 -> 1.03 ms/frame on a 24x80 frame of eight-run rows, three runs
    /// either side at a background load of ~2. That is about 0.9us of the 6.5us a span
    /// cost, and it is worth writing down that the estimate which motivated this change
    /// was three times larger: attribution had put ~3.5us of the 6.5 in construction and
    /// marshalling, on the reasoning that `cooked--face' was 1.1us and
    /// `put-text-property' 1.8us. The missing three quarters are that the two of those
    /// dominate more of the remainder than subtracting them suggested, and that building
    /// a short list on the Rust side was never as expensive as the Lisp-side allocation
    /// it was grouped with. The saving is real and the direction was right; the size was
    /// not, and a microbenchmark also under-counts what it removes, since ~1500-2300
    /// fewer cons cells per frame is collector pressure that shows up later and
    /// elsewhere.
    ///
    /// **START and END are `u32`, and that is not over-provisioning.** A `u16` is the
    /// trap here and it fails silently. [`Update::scrolled_rows`] assembles a whole
    /// drain's scrollback into *one* `Block`, so offsets are not bounded by a row or
    /// even by a screen: the flood benchmark reaches 200k characters in a single block
    /// and a 20k-line paste goes past 600k. A `u16` start would wrap at 65536 and hand
    /// Lisp a span that styles the wrong characters, with no error anywhere to point at
    /// — the buffer would simply come out miscoloured somewhere far from the cause.
    ///
    /// A span whose offsets do not fit is dropped rather than truncated. It is not
    /// reachable — 4.29 billion characters would have to arrive between two drains —
    /// but the two failure modes are not equally bad, and the choice should be the
    /// deliberate one: dropping loses the colour of a run that is already off the far
    /// end of anything a user can see, while clamping would paint it over text that is
    /// on screen. Wrong-but-plausible is the expensive kind of wrong.
    ///
    /// The rendition is packed inline rather than interned behind an id minted through
    /// [`Ledger`](emu::intern::Ledger), the way `:links` and `:images` are. Interning
    /// would save Lisp about three `u32` decodes per span and cost it an id lifetime:
    /// ids are per-session, so Lisp would need a reset on session start — the hazard
    /// `cooked--cached' warns about — and the ledger's cap means eviction must either
    /// never reuse an id or announce when it does. A reused id read against a stale
    /// Lisp cache is wrong colours with no error, which is the same silent-miscolouring
    /// failure the `u32` offsets are chosen to avoid. Three decodes is not worth buying
    /// that.
    fn push_style(&mut self, chars: usize, style: Style, underline: Color) {
        let (Ok(start), Ok(end)) = (
            u32::try_from(self.offset),
            u32::try_from(self.offset + chars),
        ) else {
            return;
        };
        let Style { fg, bg, attrs } = style;
        self.styles.extend_from_slice(&start.to_le_bytes());
        self.styles.extend_from_slice(&end.to_le_bytes());
        self.styles.extend_from_slice(&fg.packed().to_le_bytes());
        self.styles.extend_from_slice(&bg.packed().to_le_bytes());
        self.styles
            .extend_from_slice(&underline.packed().to_le_bytes());
        self.styles.extend_from_slice(&attrs.bits().to_le_bytes());
        // The stride is the format: Lisp walks the packed string by adding
        // [`STYLE_RECORD`] and never by decoding a length, so a field added to the
        // record without widening the constant would desynchronise the two sides at the
        // second span of the first styled row.
        debug_assert_eq!(
            self.styles.len() % STYLE_RECORD,
            0,
            "a style record must be exactly {STYLE_RECORD} bytes"
        );
    }

    /// Append RUNS, emitting spans only where there is something to say.
    fn push_runs(&mut self, env: Env, runs: &[Run]) -> Result<()> {
        for run in runs {
            let chars = run.text.chars().count();
            // The two span kinds that need an `Env` to say anything, taken before
            // `push_run` advances the offset they are measured from. They go on vectors
            // of their own, so nothing turns on their being filled before the style
            // record rather than after it.
            if let Some(link) = run.link {
                self.links
                    .push(list!(env, [self.offset, self.offset + chars, link])?);
            }
            if run.deco.is_some() {
                let deco = env.into_lisp(run.deco.as_ref())?;
                self.decos.push(list!(env, [self.offset, deco])?);
            }
            self.push_run(run, chars);
        }
        Ok(())
    }

    /// The half of [`Block::push_runs`] that needs no Emacs: the text itself, its style
    /// span, and the two measurements [`Block::end_row`] banks into the row table.
    ///
    /// Split out for the tests at the foot of this file. Everything else on the path
    /// from a [`Run`] to the row table takes an `Env`, which only a loaded module has,
    /// and the row table is precisely the thing a coalesced block can get wrong.
    ///
    /// CHARS is `run.text`'s character count, taken by the caller because it needs it
    /// too and it is a scan of the string.
    pub(crate) fn push_run(&mut self, run: &Run, chars: usize) {
        self.cols += run.cols;
        // Two ways to fail the "uniform" test, and the second one is why this is not
        // simply a byte-length comparison. Lisp reads the flag as "this row is
        // `frame-char-width` per character, so there is nothing to measure" and skips
        // the guard outright on it. A run whose characters are all one byte but which
        // stands on a number of columns other than its character count breaks exactly
        // that assumption — `OSC 66 ; w=1 ; Ha` is two ASCII characters declared to
        // occupy one cell — so it is not uniform for this purpose whatever its bytes
        // say.
        self.nonuniform |= run.text.len() != chars || run.cols != chars;
        if run.style != Style::default() || run.underline != Color::Default {
            self.push_style(chars, run.style, run.underline);
        }
        self.text.push_str(&run.text);
        self.offset += chars;
    }

    fn push_newline(&mut self) {
        self.text.push('\n');
        self.offset += 1;
        // The text of whatever comes next starts after this newline. Bookkeeping the
        // scrollback path does not need and pays a store for, which is cheaper than a
        // second `push_newline` that differs only in keeping it.
        self.row_start = self.offset;
    }

    /// Close the screen row being built: bank where it began and what it measured, and
    /// start the next one.
    ///
    /// Called once per damaged row and never for scrollback, which is exactly the
    /// distinction the table encodes — a live row is a fixed-width slot on the grid
    /// whose layout Emacs can get wrong, while a scrollback line is ordinary buffer text
    /// that is allowed to wrap.
    fn end_row(&mut self, wrapped: bool) {
        self.rows.push(BlockRow {
            start: self.row_start,
            cols: self.cols,
            uniform: !self.nonuniform,
            wrapped,
        });
        self.cols = 0;
        self.nonuniform = false;
        self.row_start = self.offset;
    }

    fn into_lisp(self, env: &Env) -> Result<Value> {
        let rows = self
            .rows
            .iter()
            .map(|row| list!(*env, [row.start, row.cols, row.uniform, row.wrapped]))
            .collect::<Result<Vec<_>>>()?;
        list!(
            *env,
            [
                self.text.as_str(),
                self.styles.as_slice(),
                self.decos,
                self.links,
                rows
            ]
        )
    }
}

/// Where one scrolled row's text ended up in the assembled scrollback string: its start
/// offset in characters, and how many characters it contributed.
///
/// Per *row* rather than per line, so it stays right under `rejoin`, which appends a
/// wrapped row to the line above instead of starting a new one.
#[derive(Clone, Copy, Default)]
struct RowSpan {
    start: usize,
    chars: usize,
}

impl Update {
    /// This drain's scrollback as one [`Block`], plus where each row landed in it.
    ///
    /// Assembled here rather than handed over row by row, for the reason [`Block`]
    /// gives: a flood is tens of thousands of rows, and Emacs pays for every `insert`.
    fn scrolled_rows(&self, env: Env, rejoin: bool) -> Result<(Value, Vec<RowSpan>)> {
        if self.delta.scrolled.is_empty() {
            return Ok((env.nil(), Vec::new()));
        }
        let mut block = Block::default();
        let mut rows: Vec<RowSpan> = Vec::with_capacity(self.delta.scrolled.len());
        let last = self.delta.scrolled.len() - 1;

        for (i, line) in self.delta.scrolled.iter().enumerate() {
            let start = block.offset;
            block.push_runs(env, &line.runs)?;
            rows.push(RowSpan {
                start,
                chars: block.offset - start,
            });
            // A wrapped row is a continuation, so it joins the line above rather
            // than starting a new one — except when it is the batch's last row and
            // the alt screen is up. Then what follows at screen-start is the alt
            // grid's own row 0, not this row's continuation on the primary grid, and
            // joining onto it would permanently weld this frozen scrollback text to
            // the front of a live row that gets rewritten every redraw.
            if !(rejoin && line.wrapped && !(i == last && self.delta.levels.alt)) {
                block.push_newline();
            }
        }

        Ok((block.into_lisp(&env)?, rows))
    }

    /// Spell an [`Anchor`] in whichever coordinate system Emacs can address it in.
    ///
    /// `(scrolled . OFFSET)` — a character offset into this drain's scrollback text, for
    /// a row that scrolled away while this drain was accumulating. `(screen ROW . COL)`
    /// — a cell on the live grid, for one that did not. Resolved here rather than in
    /// Lisp because the arithmetic is over Rust's absolute row numbering, which is not
    /// something the Lisp side should have to hold a copy of.
    ///
    /// `nil` when neither applies. Unreachable as things stand — events and scrollback
    /// are taken by the same drain, so nothing can be older than the batch it arrives
    /// with — and Lisp falls back to the cursor, which is what it used before anchors.
    fn anchor_to_lisp(&self, env: Env, at: Anchor, rows: &[RowSpan]) -> Result<Value> {
        let base = self.delta.scrolled_base;
        let on_grid = base + self.delta.scrolled.len();
        if at.row >= on_grid {
            return env.cons(
                sym!(env, "screen")?,
                env.cons(env.into_lisp(at.row - on_grid)?, env.into_lisp(at.col)?)?,
            );
        }
        match at.row.checked_sub(base).and_then(|i| rows.get(i)) {
            // Trailing blanks are trimmed out of the runs, so a column past the end of
            // what the row actually kept is clamped rather than run off the line.
            Some(row) => env.cons(
                sym!(env, "scrolled")?,
                env.into_lisp(row.start + at.col.min(row.chars))?,
            ),
            None => Ok(env.nil()),
        }
    }
}

/// Images transmitted this drain, each as `(ID FORMAT DATA PX-WIDTH PX-HEIGHT)`.
///
/// The bytes cross exactly once per distinct image, however many times the child sends
/// them or places them: ids are content-addressed, so a program redrawing one picture
/// per frame pays for the transfer on the first frame and for placements thereafter.
/// DATA is unibyte and handed straight to `create-image`; FORMAT is its type symbol.
///
/// The record stops at the pixel size, and deliberately carries no cell rectangle. It
/// used to: the rectangle rode the picture, which is one answer to a question that has
/// one per *placement* — the same image can be on screen at two sizes at once, and a
/// `viu` reshape retransmits bytes we already have with nothing but a new `c=`/`r=`. It
/// lives on [`Placement`](crate::emu::image::Placement) now, repeated on every cell of
/// the rectangle, and reaches Lisp with the rows rather than with the payload.
fn images_to_lisp(env: Env, images: &[ImageData]) -> Result<Vec<Value>> {
    images
        .iter()
        .map(|image| {
            list!(
                env,
                [
                    image.id,
                    image.format,
                    image.bytes.as_slice(),
                    image.px.w,
                    image.px.h,
                ]
            )
        })
        .collect()
}

/// Hyperlink destinations first seen this drain, each as `(ID . URI)`.
///
/// [`images_to_lisp`]'s much smaller sibling, and for the same reason: ids are
/// content-addressed, so a URI crosses once however many cells name it, and Lisp
/// installs the table before rendering rows that refer to it.
fn links_to_lisp(env: Env, links: &[(LinkId, String)]) -> Result<Vec<Value>> {
    links
        .iter()
        .map(|(id, uri)| env.cons(env.into_lisp(*id)?, env.into_lisp(uri.as_str())?))
        .collect()
}

/// `nil`, or `(KIND . PACKED)` — what a run's characters display instead of themselves.
///
/// KIND is an interned symbol naming the decoration, and PACKED is a unibyte string of
/// fixed-width little-endian records covering the run's text. The kind is carried once
/// for the run rather than per character because a run is homogeneous in it — see
/// [`Deco`] — which is what keeps the record narrow:
///
///   `glyph`   four bytes per *run of identical shapes*: a `BoxGlyph` bit pattern and
///             the number of consecutive characters drawing it, both `u16`. A border
///             row is one record, not eighty.
///   `image`   twelve bytes per *character*: a `u32` image id, then the cell's row and
///             column within that image, then the rectangle that placement was laid at,
///             as `u16`s.
///
/// That the two kinds count differently is the point rather than an inconsistency, and
/// [`Deco::packed`] argues it: a glyph run is genuinely one decision repeated, while
/// every cell of a picture carries its own place within it and so needs its own record
/// whatever the wire says. What reaches the *buffer* is a run either way —
/// `cooked--apply-image-deco' coalesces the cells of a row back into one `display'
/// interval, which is where the redisplay cost was, and does it against the records it
/// has already decoded rather than against a second wire shape.
///
/// The rectangle is repeated on every image cell rather than carried once per image
/// because it belongs to the placement — see [`Placement`](emu::image::Placement). Four
/// bytes a cell against a picture's own megabytes, and it is what lets two placements of
/// one id at two sizes both draw correctly.
///
/// A packed string rather than a list because this is the live-row path: box drawing is
/// what full-screen programs are made of, so a list would cons per character of every
/// damaged row of every frame — the same cost `scrolled_rows` goes out of its way to
/// avoid on the flood path, paid on the one that redraws continuously. One allocation
/// per run instead, unibyte so Emacs neither decodes nor copies it again.
impl env::IntoLisp for Option<&Deco> {
    fn into_lisp(self, env: &Env) -> Result<Value> {
        let Some(deco) = self else {
            return Ok(env.nil());
        };
        // The bytes are [`Deco::packed`]'s, which is where the record layouts are
        // written down and where the tests that pin them can reach them; what belongs
        // here is only the kind tag, because `sym!' needs its literal at the call site
        // to do the lookup at compile time.
        let packed = env.into_lisp(deco.packed().as_slice())?;
        match deco {
            Deco::Glyphs(_) => env.cons(sym!(env, "glyph")?, packed),
            Deco::Images(_) => env.cons(sym!(env, "image")?, packed),
        }
    }
}

/// A single event, with any anchor it carries already resolved against `update`.
///
/// The semantic marks are lists of a uniform shape — `(prompt-start ANCHOR ID)`,
/// `(command-end CODE ANCHOR ID)` — rather than dotted pairs, so that one family of
/// events has one spelling however many fields a member carries. `(osc CODE BELL-P
/// PART...)` is variadic and stands outside that family.
///
/// ID names the mark for the rest of the session: the anchor resolves to a buffer
/// position once, here, and stops being true the next time a resize rewraps the grid, so
/// `:marks` reports the same id with a fresh anchor and Lisp moves the marker it made.
/// See `Delta::marks` and `cooked--relocate-marks'.
fn event_to_lisp(env: Env, event: &Event, update: &Update, rows: &[RowSpan]) -> Result<Value> {
    // The tag arrives already resolved, because `sym!` needs the literal at its own
    // call site to do the lookup at compile time -- which is the point of it.
    let mark = |name: Value, at: Anchor, id: MarkId| {
        list!(env, [name, update.anchor_to_lisp(env, at, rows)?, id])
    };
    match event {
        Event::Bell => list!(env, [sym!(env, "bell")?]),
        // (osc CODE BELL-P PART...) — Lisp decides what the code means. BELL-P is
        // opaque to the handler: it hands it back to `cooked--reply-osc' if it answers.
        Event::Osc(code, parts, terminator) => {
            let mut items = vec![
                sym!(env, "osc")?,
                env.into_lisp(*code)?,
                env.into_lisp(*terminator == emu::Terminator::Bel)?,
            ];
            for part in parts {
                items.push(env.into_lisp(part.as_str())?);
            }
            env.into_lisp(items)
        }
        Event::Mark(Mark::PromptStart, at, id) => mark(sym!(env, "prompt-start")?, *at, *id),
        Event::Mark(Mark::PromptContinuation, at, id) => {
            mark(sym!(env, "prompt-continuation")?, *at, *id)
        }
        Event::Mark(Mark::PromptEnd, at, id) => mark(sym!(env, "prompt-end")?, *at, *id),
        // (command-start CMDLINE ANCHOR ID), CMDLINE nil when the shell did not say.
        Event::Mark(Mark::CommandStart(cmdline), at, id) => list!(
            env,
            [
                sym!(env, "command-start")?,
                cmdline.as_deref(),
                update.anchor_to_lisp(env, *at, rows)?,
                *id,
            ]
        ),
        Event::Mark(Mark::CommandEnd(code), at, id) => list!(
            env,
            [
                sym!(env, "command-end")?,
                code.map(i64::from),
                update.anchor_to_lisp(env, *at, rows)?,
                *id,
            ]
        ),
        // (mouse ENABLED SGR DRAG MOTION PIXELS). Flattening this to a single "wants
        // the mouse" bit lost the reach of the request: 1002 and 1003 ask to be told
        // where the pointer went, not merely which cell it was pressed in, and the
        // sender cannot manufacture motion reports it was never told to send.
        //
        // The format goes as two booleans rather than a symbol: SGR says which frame the
        // report is written in and PIXELS which unit fills it, and the sender asks those
        // two questions in two different places.
        Event::Mouse(m) => list!(
            env,
            [
                sym!(env, "mouse")?,
                m.enabled(),
                m.sgr(),
                m.drag(),
                m.motion(),
                m.pixels(),
            ]
        ),
        Event::Reply(bytes) | Event::SizeReport(bytes) => {
            env.cons(sym!(env, "reply")?, env.into_lisp(bytes.as_slice())?)
        }
        Event::EraseScrollback => list!(env, [sym!(env, "erase-scrollback")?]),
        Event::DisplayCleared => list!(env, [sym!(env, "display-cleared")?]),
        Event::Reset => list!(env, [sym!(env, "reset")?]),
        // (title-stack PUSH-P)
        Event::TitleStack(op) => list!(env, [sym!(env, "title-stack")?, *op == emu::StackOp::Push]),
        // (resize-request ROWS COLS), nil for a dimension to leave alone.
        Event::ResizeRequest(rows, cols) => list!(
            env,
            [
                sym!(env, "resize-request")?,
                rows.map(i64::from),
                cols.map(i64::from),
            ]
        ),
        // (frame-size PIXELS-P)
        Event::FrameSize(unit) => {
            list!(env, [sym!(env, "frame-size")?, *unit == emu::Unit::Pixels])
        }
    }
}

/// [`Block::push_style`] needs no `Env`: it writes bytes into a `Vec`, and the format is
/// the whole of what it decides. So the layout both sides have to agree on forever is
/// pinned here, without an Emacs in the loop -- which is the same reason the rest of the
/// crate is testable, applied to the one file that usually is not.
#[cfg(test)]
mod tests {
    use super::*;
    use emu::cell::Attrs;
    use emu::{Color, Style};

    /// The trailing fields of a record, as a `Block` holding exactly one would have them.
    fn record(style: Style, underline: Color) -> Vec<u8> {
        let mut block = Block {
            offset: 0,
            ..Default::default()
        };
        block.push_style(1, style, underline);
        block.styles
    }

    fn u32_at(bytes: &[u8], at: usize) -> u32 {
        u32::from_le_bytes(bytes[at..at + 4].try_into().unwrap())
    }

    #[test]
    fn a_style_record_is_exactly_the_stride_lisp_steps_by() {
        let packed = record(Style::default(), Color::Default);
        assert_eq!(
            packed.len(),
            STYLE_RECORD,
            "`cooked--style-record' in cooked.el is this number: {packed:?}"
        );
    }

    #[test]
    fn each_colour_variant_survives_the_round_trip_through_a_record() {
        // The three tags `cooked--color-spec' in cooked-face.el decodes, in the layout
        // its docstring states: tag in the top byte, value in the low three.
        for (colour, expected) in [
            (Color::Default, 0u32),
            (Color::Indexed(0), 1 << 24),
            (Color::Indexed(255), (1 << 24) | 255),
            (Color::Rgb(0x12, 0x34, 0x56), (2 << 24) | 0x123456),
        ] {
            let packed = record(
                Style {
                    fg: colour,
                    ..Style::default()
                },
                Color::Default,
            );
            assert_eq!(u32_at(&packed, 8), expected, "fg {colour:?}: {packed:?}");
        }
    }

    #[test]
    fn the_underline_colour_has_its_own_field_and_does_not_alias_the_foreground() {
        // `SGR 58' is a colour of its own, and it shared a slot with nothing before the
        // record existed -- it rode a tail cons. A field that aliased fg would show up
        // only on text that is both coloured and underlined, which is rare enough to
        // ship.
        let packed = record(
            Style {
                fg: Color::Indexed(1),
                bg: Color::Indexed(2),
                attrs: Attrs::UNDERLINE,
            },
            Color::Indexed(3),
        );
        assert_eq!(u32_at(&packed, 8), (1 << 24) | 1, "fg");
        assert_eq!(u32_at(&packed, 12), (1 << 24) | 2, "bg");
        assert_eq!(u32_at(&packed, 16), (1 << 24) | 3, "underline");
        assert_eq!(
            u16::from_le_bytes([packed[20], packed[21]]),
            Attrs::UNDERLINE.bits(),
            "attrs"
        );
    }

    /// The `u16` trap the field widths exist to avoid, stated as a test rather than only
    /// as a comment. `Update::scrolled_rows` assembles a whole drain's scrollback into
    /// one `Block`, so an offset is bounded by the flood rather than by a row: a `u16`
    /// start would wrap at 65536 and style the wrong characters, with nothing anywhere
    /// to point at.
    #[test]
    fn an_offset_past_a_u16_packs_at_full_width_rather_than_wrapping() {
        let mut block = Block {
            offset: 70_000,
            ..Default::default()
        };
        block.push_style(5, Style::default(), Color::Default);
        assert_eq!(u32_at(&block.styles, 0), 70_000, "start");
        assert_eq!(u32_at(&block.styles, 4), 70_005, "end");
    }

    /// The indices of each run, which is all the grouping decision amounts to.
    fn runs_of(indices: &[usize]) -> Vec<Vec<usize>> {
        let rows: Vec<DamagedRow> = indices
            .iter()
            .map(|i| DamagedRow {
                index: *i,
                wrapped: false,
                runs: Vec::new(),
            })
            .collect();
        contiguous_runs(&rows)
            .map(|run| run.iter().map(|r| r.index).collect())
            .collect()
    }

    #[test]
    fn contiguous_damaged_rows_become_one_run() {
        assert_eq!(runs_of(&[0, 1, 2, 3]), vec![vec![0, 1, 2, 3]]);
        assert_eq!(runs_of(&[7]), vec![vec![7]]);
        assert!(runs_of(&[]).is_empty());
    }

    /// The ghostel hazard, pinned on the side that decides it. Their span breaks only on
    /// a row known to be *clean*, so a page-granularity false positive coalesces the
    /// whole viewport into one reinsert and takes every marker in it. A gap here must
    /// break the run, however small the gap and however plausible it is that the row in
    /// it is unchanged: an undamaged row is not ours to rewrite. The Lisp side pins the
    /// consequence -- see `cooked-an-undamaged-row-between-two-damaged-ones-is-not-
    /// rewritten'.
    #[test]
    fn a_gap_of_even_one_row_breaks_the_run() {
        assert_eq!(runs_of(&[0, 2]), vec![vec![0], vec![2]]);
        assert_eq!(
            runs_of(&[0, 1, 3, 4, 9]),
            vec![vec![0, 1], vec![3, 4], vec![9]]
        );
    }

    /// Ascending order is how the damage arrives and is not a precondition. A list that
    /// is not ascending coalesces less rather than wrongly -- the alternative, taking
    /// "adjacent in the list" for "adjacent on the grid", would put a block's rows on
    /// screen rows they do not belong to.
    #[test]
    fn out_of_order_or_repeated_indices_coalesce_nothing() {
        assert_eq!(runs_of(&[3, 1, 2]), vec![vec![3], vec![1, 2]]);
        assert_eq!(runs_of(&[1, 1]), vec![vec![1], vec![1]]);
    }

    /// One row's measurements must not leak into the next one's, which is the whole
    /// reason the two scalars became a table. A wide or multi-byte row makes the run's
    /// flag say "not uniform"; if that were still a per-block answer, every plain row
    /// beside it would take the guard's slow path -- and worse, a plain row's width
    /// would read as the sum of everything before it and the guard would compare Emacs'
    /// layout against a number several times too large.
    #[test]
    fn each_row_of_a_block_carries_its_own_width_and_uniformity() {
        let row = |text: &str, cols: usize| Run {
            text: text.to_string(),
            cols,
            ..Run::default()
        };
        let mut block = Block::default();
        block.push_run(&row("ab", 2), 2);
        block.end_row(false);
        block.push_newline();
        // Two characters of three bytes each standing on two cells apiece: neither
        // one-byte nor one-cell, so this row is the nonuniform one.
        block.push_run(&row("世界", 4), 2);
        // And the wrapped one: its logical line goes on below it. Per row like the other
        // two, and asserted alongside them, because a flag that leaked between rows would
        // have Emacs join a line the child ended.
        block.end_row(true);
        block.push_newline();
        block.push_run(&row("cd", 2), 2);
        block.end_row(false);

        let table: Vec<(usize, usize, bool, bool)> = block
            .rows
            .iter()
            .map(|r| (r.start, r.cols, r.uniform, r.wrapped))
            .collect();
        assert_eq!(
            table,
            vec![
                (0, 2, true, false),
                (3, 4, false, true),
                (6, 2, true, false)
            ],
            "text {:?}",
            block.text
        );
    }

    /// Dropped rather than truncated, which is the deliberate half of the choice: a lost
    /// colour is invisible off the far end of a flood, while a clamped one would paint
    /// over text that is on screen. Unreachable in practice -- it takes four billion
    /// characters between two drains -- so the only thing that can keep it right is this.
    #[test]
    fn a_span_whose_offsets_do_not_fit_is_dropped_and_never_clamped() {
        let mut block = Block {
            offset: usize::try_from(u32::MAX).unwrap(),
            ..Default::default()
        };
        block.push_style(2, Style::default(), Color::Default);
        assert!(
            block.styles.is_empty(),
            "an unrepresentable span leaves no record: {:?}",
            block.styles
        );
    }
}
