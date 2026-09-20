//! The shape everything the core reports takes on its way into Lisp.
//!
//! lib.rs registers the functions Emacs calls and unpacks their arguments; this module
//! owns the other direction. A drain's [`Update`] becomes the plist `cooked--drain'
//! returns, rows become [`Block`]s, events become tagged lists, and every enum that
//! crosses as a bare symbol is spelled once here.

use crate::emu::stream::Filter;
use crate::emu::style::{FontBits, StyleId};
use crate::emu::{
    self, Anchor, Bytes, Chars, Color, Cols, CursorShape, DamagedRow, Deco, Event, ImageData,
    ImageFormat, ImageId, KeyEncoding, LinkId, Mark, MarkId, RunRef, Runs, Style, Wrap,
};
use crate::env::{self, Env, Result, Value, lisp_enum, list, plist, sym};
use crate::pty::Mode;
use crate::session::{Exit, Update};
use nix::unistd::Pid;

/// The crate's id newtypes, which are all one integer wide.
///
/// So an id crosses the boundary without reaching past the newtype to its field.
macro_rules! into_lisp_id {
    ($($t:ty),* $(,)?) => {
        $(impl<'e> env::IntoLisp<'e> for $t {
            fn into_lisp(self, env: &Env<'e>) -> Result<Value<'e>> {
                self.get().into_lisp(env)
            }
        })*
    };
}

into_lisp_id!(MarkId, LinkId, ImageId);

/// What `:exit' says for a session whose reader gave up on the pty with the child still
/// unreapable: not an exit status, since there is none, but Lisp still needs the session
/// to end. `cooked--on-exit' spells it out. Negative because no `waitpid` status is.
///
/// The one place [`Exit::Lost`] becomes a number, so the core carries the distinction in
/// its type for as long as it is the core's.
const LOST: i64 = -1;

/// The child's status as `:exit' reports it; see [`LOST`].
fn exit_to_lisp(exit: Exit) -> i64 {
    match exit {
        Exit::Status(status) => status.into(),
        Exit::Lost => LOST,
    }
}

// Every enum this module sends as a bare symbol, and the symbol each variant is. One
// list per type, so the drain's `:mode' and `cooked--sample-mode' cannot disagree about
// what to call the same state.
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
impl<'e> env::IntoLisp<'e> for KeyEncoding {
    fn into_lisp(self, env: &Env<'e>) -> Result<Value<'e>> {
        match self {
            KeyEncoding::Legacy => sym!(env, "legacy"),
            KeyEncoding::ModifyOtherKeys(_) => sym!(env, "modify-other"),
            KeyEncoding::Kitty(_) => sym!(env, "kitty"),
        }
    }
}

impl<'e> env::IntoLisp<'e> for Pid {
    fn into_lisp(self, env: &Env<'e>) -> Result<Value<'e>> {
        self.as_raw().into_lisp(env)
    }
}

/// `(RETRACT TEXT STYLES LINKS DIRECTORY STYLE-TABLE)` for one chunk of a child's output.
///
/// TEXT and STYLES are the first two fields of the block shape the grid's renderer
/// already takes -- see [`Block::push_style`] for the packed layout -- and STYLE-TABLE is
/// the drain's `:styles` for the filter's own renditions, so Lisp resolves both through
/// the same face vector code.
///
/// LINKS carries the destination itself rather than a `LinkId`, and a record's LINK field
/// is left zero. An id resolves through a table local to a *session*, and a comint buffer
/// has no session to look it up in.
///
/// RETRACT is how many characters immediately before the insertion point the filter is
/// taking back, nonzero only when the caller said its provisional text was still there.
/// The reconciliation is [`Stream::flush`](emu::stream); the caller's half is
/// `cooked-comint--emit'.
pub(crate) fn emission_to_lisp<'e>(env: Env<'e>, filter: &Filter) -> Result<Value<'e>> {
    let emission = filter.emission();
    // Nothing to say, which is a real and common case rather than a defensive check: a
    // chunk can be nothing but escape sequences -- the bracketed-paste mode set that
    // brackets every prompt bash prints -- and nil lets Lisp return without touching the
    // buffer at all.
    if emission.is_empty() {
        return Ok(env.nil());
    }
    // No session holds a link table here, so the records carry no link ids and LINKS
    // carries the destinations instead.
    let mut block = Block {
        unlinked: true,
        ..Block::default()
    };
    let mut links = Vec::new();
    for run in &emission.runs {
        // Before `push_run`, which advances the offset the span is measured from.
        if let Some(id) = run.link
            && let Some(uri) = filter.uri(id)
        {
            links.push(list!(env, [block.offset, block.offset + run.chars, uri])?);
        }
        block.push_run(run);
    }
    let directory = match &emission.directory {
        Some(url) => env.into_lisp(url.as_str())?,
        None => env.nil(),
    };
    list!(
        env,
        [
            emission.retract,
            block.text.as_str(),
            block.styles.as_slice(),
            links,
            directory,
            styles_to_lisp(env, &emission.styles)?
        ]
    )
}

/// The whole screen as one [`Block`], its rows joined by newlines; see
/// `cooked--screen-text'.
///
/// The shape `:scrolled' arrives in rather than the shape `:rows' does, and for the same
/// reason scrollback has it: the caller renders one string and asks nothing about
/// individual rows, so there is no row table to build. `cooked--render-block' takes
/// either.
pub(crate) fn screen_to_lisp<'e>(env: Env<'e>, rows: &[Runs]) -> Result<Value<'e>> {
    let mut block = Block::default();
    for (index, runs) in rows.iter().enumerate() {
        if index > 0 {
            block.push_newline();
        }
        block.push_runs(env, runs)?;
    }
    block.into_lisp(&env)
}

/// The damaged rows split into maximal runs of *consecutive* indices.
///
/// A pure function over the slice so it can be tested without an Emacs.
///
/// [`crate::emu::screen::Screen::drain_damage`] produces ascending indices, but nothing
/// here relies on it: the condition is `next == this + 1` rather than "not known to be
/// clean", so an out-of-order list coalesces less rather than merging rows that are not
/// neighbours.
///
/// That condition is the whole hazard. ghostel breaks a span only on a row it knows to be
/// clean, so a false positive becomes one giant reinsert, and a reinsert destroys every
/// marker and overlay inside it. Here an undamaged row between two damaged ones is never
/// inside a block.
///
/// A row sent as an [`Edit`](emu::Edit) is not a whole row, so it belongs to no run: it
/// breaks the run it would have joined, and it goes out in `:edits` instead.
fn contiguous_runs(rows: &[DamagedRow]) -> impl Iterator<Item = &[DamagedRow]> {
    rows.chunk_by(|this, next| {
        next.index == this.index + 1 && this.edit.is_none() && next.edit.is_none()
    })
    .filter(|run| run[0].edit.is_none())
}

/// `(:scrolled ROWS :promoted (BOTTOM (CHARS . ENDS)...) :rows ((FIRST . BLOCK)...)
/// :height N :width N :used N :head N :cursor (ROW COL VISIBLE SHAPE CHARS)
/// :marks ((ID . ANCHOR)...) ...)`
pub(crate) fn update_to_lisp<'e>(env: Env<'e>, update: &Update, rejoin: bool) -> Result<Value<'e>> {
    // The scrollback is assembled first because the events are resolved against it: a
    // mark on a row that scrolled away during this very drain is spelled as an offset
    // into the text about to be inserted, which only exists once that text is built.
    let (promoted, scrolled, spans) = update.scrolled_rows(env, rejoin)?;
    // `(FIRST . BLOCK)`, the same [`Block`] scrollback arrives in, so one renderer in
    // Lisp handles both. FIRST is the index of the block's *first* row; its table says
    // how many follow it and where each begins.
    //
    // Newlines go *between* the rows of a run and never after the last one: a live row
    // is written into a buffer line that already exists, whose newline is already there.
    // A 24-row repaint is one `delete-region' and one `insert' rather than 24 of each.
    let rows = contiguous_runs(&update.delta.rows)
        .map(|run| {
            let mut block = Block::new(&update.delta.fonts);
            for (i, row) in run.iter().enumerate() {
                if i > 0 {
                    block.push_newline();
                }
                block.push_runs(env, &row.runs)?;
                block.end_row(row.wrap, update.delta.width);
            }
            env.cons(env.into_lisp(run[0].index)?, block.into_lisp(&env)?)
        })
        .collect::<Result<Vec<_>>>()?;
    // `(INDEX CHAR-START CHAR-END LENGTH . BLOCK)` per row sent as a replacement for part
    // of itself. The block holds only the replacement's text, while its row table
    // describes the whole row, since that is what the width guard and the wrap mark
    // measure. LENGTH is the whole row's characters afterwards; see `Edit::chars`.
    let edits = update
        .delta
        .rows
        .iter()
        .filter_map(|row| row.edit.as_ref().map(|edit| (row, edit)))
        .map(|(row, edit)| {
            let mut block = Block::new(&update.delta.fonts);
            block.push_runs(env, &edit.runs)?;
            block.rows.push(BlockRow {
                start: Chars::ZERO,
                ..Block::measure(&update.delta.fonts, &row.runs, row.wrap, update.delta.width)
            });
            env.cons(
                env.into_lisp(row.index)?,
                env.cons(
                    env.into_lisp(edit.char_start)?,
                    env.cons(
                        env.into_lisp(edit.char_end)?,
                        env.cons(env.into_lisp(edit.chars)?, block.into_lisp(&env)?)?,
                    )?,
                )?,
            )
        })
        .collect::<Result<Vec<_>>>()?;
    // `(TOP BOTTOM COUNT UP)` per move, in the order they happened; see [`Shift`]. A list
    // rather than a packed record, since a drain holds a handful at most.
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
            update.delta.cursor_chars,
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

    // `(PGRP . NAME)`: the process group holding the child's tty and the program its
    // leader is running, or nil while nothing holds it. NAME is nil on a platform that
    // declines to say; see `platform::process_name`.
    let foreground = update
        .foreground
        .as_ref()
        .map(|fg| {
            env.cons(
                env.into_lisp(fg.pgrp.as_raw())?,
                env.into_lisp(fg.name.as_deref())?,
            )
        })
        .transpose()?;

    plist!(env, {
        ":scrolled"    => scrolled,
        ":promoted"    => promoted,
        ":shifts"      => shifts,
        ":rows"        => rows,
        ":edits"       => edits,
        ":height"      => update.delta.height,
        ":width"       => update.delta.width,
        ":used"        => update.delta.used,
        ":head"        => update.delta.head,
        ":cursor"      => cursor,
        ":reverse"     => levels.reverse_screen,
        ":reverse-toggles" => levels.reverse_screen_toggles,
        ":marks"       => marks,
        ":alt"         => levels.alt,
        ":app-cursor"  => levels.app_cursor,
        ":keys"        => levels.keys,
        ":kitty-flags" => u32::from(levels.keys.kitty_flags().bits()),
        ":modify-other-keys" => u32::from(levels.keys.modify_other_keys_level()),
        ":mode"        => update.mode,
        ":foreground"  => foreground,
        ":images"      => images_to_lisp(env, &update.delta.images)?,
        ":links"       => links_to_lisp(env, &update.delta.links)?,
        ":styles"      => styles_to_lisp(env, &update.delta.styles)?,
        ":events"      => events,
        ":exit"        => update.exit.map(exit_to_lisp),
        ":withheld"    => update.delta.withheld,
    })
}

/// A run of buffer text with its styling and decoration held off to the side.
///
/// The one shape rendered text crosses in, for the live screen and scrollback alike, so
/// one encoder here and one renderer in Lisp share every field.
///
/// Sparse, because Emacs pays for every `insert`: one insert of one string, with
/// properties only where they depart from the default, keeps roughly a million cons
/// cells from crossing on a flood. A plain unstyled row, the usual case, pays for no spans
/// at all; the `plain` benchmark row is the control for that.
///
/// STYLE-SPANS is a unibyte string of fixed-width records naming each span's rendition
/// and link by id; see [`Block::push_style`]. DECO-SPANS is `(START DECO)`, and repeats
/// no colours: a box glyph is drawn in the face at its position, which STYLE-SPANS already
/// put there, and a second copy would be a staler answer (see
/// `cooked--box-glyph-image-1').
///
/// A row table rides at the end: one `(START WIDTH UNIFORM WRAPPED HASH)` per *screen row*
/// the block covers -- where the row's text begins in TEXT, how many columns it occupies,
/// how far a byte-per-column reading of it can be trusted (see [`Uniformity`]), whether
/// the row below continues its line and over what (see [`WrapMark`]), and a hash of what
/// decides the row's layout. WIDTH,
/// UNIFORM and HASH are by-products of work already done and spare Emacs a measurement
/// and a copy of the row per drain; see `cooked--guard-row-width'. Per row rather than per
/// block, because [`update_to_lisp`] coalesces contiguous damaged rows, and the offsets let
/// `cooked--render-block' phase a shade glyph's dither against its own row. Scrollback
/// carries no table, since nothing guards reflowable text.
///
/// A decoration span needs no END: its packed records account for every character it
/// covers.
#[derive(Default)]
pub(crate) struct Block<'a, 'e> {
    text: String,
    styles: Vec<u8>,
    decos: Vec<Value<'e>>,
    offset: Chars,
    /// The font bits of every rendition id the runs may name, indexed by id; see
    /// `StyleStore::font_bits`. Read only for the layout hash, which is why an empty
    /// table -- scrollback, the comint filter -- costs nothing but a hash that ignores
    /// fonts where nothing reads it.
    font_bits: &'a [FontBits],
    /// Leave the LINK field of every record zero, for an encoding whose consumer has no
    /// table to resolve an id through.
    unlinked: bool,
    /// Scratch space for [`Deco::pack_into`], reused across every decorated run in the
    /// block instead of a fresh `Vec` per run; see [`Block::push_deco`].
    deco_scratch: Vec<u8>,
    /// Columns `text` occupies on the grid, summed from [`RunRef::cols`].
    ///
    /// `cooked--guard-row-width' needs to know how wide a row *should* be, and asking
    /// `string-width' costs 59us a row for CJK and 100us for box drawing, to recompute
    /// what the grid already knew.
    ///
    /// It is also the only route a *declared* width has to Emacs: under `OSC 66 w=N` the
    /// child states how many cells a run occupies, which can disagree with any width table.
    /// See `State::text_size`.
    ///
    /// Accumulated for the row being built and banked by [`Block::end_row`]. Scrollback
    /// never calls `end_row`, and nothing reads its sum.
    cols: Cols,
    /// The worst [`Uniformity`] of any run pushed into the row being built.
    ///
    /// Per row and reset by [`Block::end_row`], so one mixed row neither slows a coalesced
    /// run nor hides behind a neighbour.
    uniformity: Uniformity,
    /// Where the row being built begins in `text`, in bytes, for hashing its text.
    row_start_byte: Bytes,
    /// The font-changing renditions pushed into the row being built, folded together with
    /// where they fall; see [`BlockRow::hash`].
    fonts: u64,
    /// Where the row currently being built begins in `text`, in characters.
    ///
    /// Moved by [`Block::end_row`] and by [`Block::push_newline`], which are the two
    /// ways a row can end: a damaged run puts a newline between its rows but not after
    /// the last one, so neither call alone can keep this right.
    row_start: Chars,
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
    start: Chars,
    cols: Cols,
    uniform: Uniformity,
    /// Whether the row below continues this row's logical line, so that the newline
    /// between them is a soft wrap the child never wrote, and whether blanks of the line
    /// stand between the two; see [`WrapMark`].
    ///
    /// It rides the width guard's table because it is the same kind of fact: something the
    /// core knows about a rendered row that Emacs cannot see.
    wrap: WrapMark,
    /// A hash of everything about the row that decides how Emacs lays it out: its text,
    /// and where the renditions that change the font fall (bold, faint and italic, the
    /// faces `cooked--ascii-fixed-pitch-p' probes). Colours and underlines are left out,
    /// because they move no glyph.
    ///
    /// The key `cooked--row-wraps-p' memoises on, which used to copy the row out of the
    /// buffer to have one: a full-screen program repainting a border paid a string per row
    /// per frame just to be told the row still fits. A collision can only make the memo
    /// answer "fits" for a row that wraps, which leaves a soft-wrapped row until something
    /// rewrites it; it can never delete a character.
    ///
    /// Masked to 60 bits so it crosses as a fixnum and costs Emacs no bignum.
    hash: u64,
}

/// The `cooked-wrap' mark for one row: what a rendered row's newline carries.
///
/// The values `cooked--mark-row-wrap' puts on a newline, decided here because the core
/// is what knows the difference. [`WrapMark::Blank`] says the row's line goes on below
/// over blanks its own text stops short of, which Emacs puts back as spaces when it
/// reads the line as one string — a URL split across the break, or a position carried
/// across a rewrap. A row a wide character wrapped early stops short of its line's end
/// too, but those extra columns are *not* blanks of the line: `日本語` at five columns
/// leaves column 4 to the `語` that moved down whole. Emacs cannot tell the two apart by
/// width alone, since both reach it as a row of four columns out of five — and a row can
/// be both at once, its own trailing blanks *and* a wide character's leftover room, as
/// `ab` followed by two blanks and a character with one column to spare is. `Blank`
/// therefore carries how many of the columns it stands for are the latter, so
/// `cooked--wrap-blanks` can leave them out of what it puts back: zero for an ordinary
/// wrap, the early wrap's own pad otherwise.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
enum WrapMark {
    /// The line ends with this row; its newline is the child's own.
    #[default]
    Ends,
    /// The line goes on below, and the row's text reaches the end of it.
    Wraps,
    /// The line goes on below over blanks the row was rendered without, PAD columns of
    /// which are a wide character's leftover room rather than blanks of the line.
    Blank(Cols),
}

impl WrapMark {
    /// How a row of COLS columns of text ends, on a screen WIDTH columns wide.
    fn of(wrap: Wrap, cols: Cols, width: usize) -> Self {
        let (line, pad) = match wrap {
            Wrap::No => return Self::Ends,
            Wrap::Full => (width, Cols::ZERO),
            // The padding belongs to no column of the line, so the line ends where it
            // begins. Saturating because a row is measured as Emacs will render it, and
            // the width guard can leave that shorter than the grid said.
            Wrap::Early(pad) => (width.saturating_sub(pad.get()), pad),
        };
        if cols.get() < line {
            Self::Blank(pad)
        } else {
            Self::Wraps
        }
    }
}

impl<'e> env::IntoLisp<'e> for WrapMark {
    /// nil, `t' and the early-wrap pad count (zero for an ordinary wrap), the values
    /// `cooked-wrap' takes.
    fn into_lisp(self, env: &Env<'e>) -> Result<Value<'e>> {
        match self {
            Self::Ends => false.into_lisp(env),
            Self::Wraps => true.into_lisp(env),
            Self::Blank(pad) => pad.into_lisp(env),
        }
    }
}

/// How much of a byte-per-column reading of a row Emacs can trust, worst case first last.
///
/// `cooked--guard-row-width' skips a row outright when nothing in it can render wider
/// than the grid said, and what it needs to know for that is not quite "is this ASCII".
///
/// - [`Uniformity::Ascii`]: every character is one byte on one cell. Not the same as
///   ASCII text: `OSC 66 ; w=1 ; Ha` is two ASCII characters declared onto one cell, and
///   is [`Uniformity::Mixed`].
/// - [`Uniformity::Glyphs`]: as `Ascii`, except that some one-cell characters are inside
///   box-glyph decoration runs. Those cells show a bitmap cooked draws at exactly the cell
///   size rather than the font's glyph, so the font cannot widen them -- but only when the
///   bitmaps are really drawn, which Lisp decides. A `tree` indent of `│` and NO-BREAK
///   SPACEs is this, since the absorbed blanks ride the glyph run.
/// - [`Uniformity::Mixed`]: anything else, which the guard has to measure.
///
/// Image placements need no case of their own: an image cell is a blank in the text, so
/// a row of pictures is already `Ascii`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord)]
enum Uniformity {
    #[default]
    Ascii,
    Glyphs,
    Mixed,
}

impl Uniformity {
    /// What one run contributes.
    fn of(run: RunRef<'_>) -> Self {
        if !run.one_cell_per_char() {
            Self::Mixed
        } else if run.one_byte_per_char() {
            Self::Ascii
        } else if matches!(run.deco, Some(Deco::Glyphs(_))) {
            Self::Glyphs
        } else {
            Self::Mixed
        }
    }
}

impl<'e> env::IntoLisp<'e> for Uniformity {
    /// `t`, `glyph` and nil, so that the `t` a byte-uniform row always carried reads the
    /// same to anything testing it for truth.
    fn into_lisp(self, env: &Env<'e>) -> Result<Value<'e>> {
        match self {
            Self::Ascii => true.into_lisp(env),
            Self::Glyphs => sym!(env, "glyph"),
            Self::Mixed => false.into_lisp(env),
        }
    }
}

/// Bytes in one packed style span. See [`Block::push_style`] for the field layout, and
/// `cooked--style-record' in lisp/cooked-face.el for the mirror.
const STYLE_RECORD: usize = 16;
/// Byte offset of START within a style record; `cooked--style-start'.
const STYLE_START: usize = 0;
/// Byte offset of END within a style record; `cooked--style-end'.
const STYLE_END: usize = 4;
/// Byte offset of STYLE within a style record; `cooked--style-id'.
const STYLE_ID: usize = 8;
/// Byte offset of LINK within a style record; `cooked--style-link'.
const STYLE_LINK: usize = 12;

/// One number both halves of the wire name, with the docstring the Lisp side shows.
///
/// The core owns the value and the prose about it; [`crate::wire_gen`] prints
/// lisp/cooked-wire.el from these, and `cooked--wire-layout' hands the same names and
/// values to a loaded session so `cooked--check-wire-drift' can tell a stale `.so' from
/// a fresh one. NAME is the Lisp constant with its `cooked--' prefix removed, so
/// `WireConst::new("attr-bold", ...)' is `cooked--attr-bold' there.
pub(crate) struct WireConst {
    pub(crate) name: &'static str,
    pub(crate) value: u32,
    pub(crate) doc: &'static str,
}

impl WireConst {
    /// NAME is the unprefixed Lisp name, DOC the docstring of the generated `defconst'.
    pub(crate) fn new(name: &'static str, value: u32, doc: &'static str) -> Self {
        Self { name, value, doc }
    }
}

/// This module's half of `cooked--wire-layout': the style-record layout above. See
/// [`crate::emu::cell::wire_layout`], [`crate::emu::glyph::wire_layout`] and
/// [`crate::session::wire_layout`] for the rest.
pub(crate) fn wire_layout() -> Vec<WireConst> {
    vec![
        WireConst::new(
            "style-record",
            STYLE_RECORD as u32,
            "Bytes in one packed style span.  See `Block::push_style' in src/wire.rs.\n\
             \n\
             The stride *is* the format: a reader finds the next span by adding this and\n\
             never by decoding a length.  The Rust side asserts the same number, so a field\n\
             added to the record on one side without widening it on both desynchronises the\n\
             two at the second span of the first styled row, where every later span reads\n\
             its neighbour's bytes and the buffer comes out miscoloured with nothing to\n\
             point at.\n\
             \n\
             The fields are `u32's at the offsets the constants below name: START and END\n\
             as character offsets, then the ids of the span's rendition and link.  They are\n\
             available at compile time so that `cooked--do-style-spans' adds literals rather\n\
             than look up variables on the render path.",
        ),
        WireConst::new(
            "style-start",
            STYLE_START as u32,
            "Offset of START in a style record.",
        ),
        WireConst::new(
            "style-end",
            STYLE_END as u32,
            "Offset of END in a style record.",
        ),
        WireConst::new(
            "style-id",
            STYLE_ID as u32,
            "Offset of the rendition id in a style record.",
        ),
        WireConst::new(
            "style-link",
            STYLE_LINK as u32,
            "Offset of the link id in a style record, 0 for none.",
        ),
    ]
}

impl<'a, 'e> Block<'a, 'e> {
    /// A block whose layout hashes read font bits from FONT_BITS.
    fn new(font_bits: &'a [FontBits]) -> Self {
        Self {
            font_bits,
            ..Self::default()
        }
    }

    /// Pack one style span onto `styles`: the run's extent, the id of its rendition and
    /// the id of its link, as little-endian `u32`s.
    ///
    ///   STYLE_START..STYLE_END    START  character offset into [`Block::text`]
    ///   STYLE_END..STYLE_ID       END    exclusive
    ///   STYLE_ID..STYLE_LINK      STYLE  a [`StyleId`], resolved through the drain's `:styles`
    ///   STYLE_LINK..STYLE_RECORD  LINK   a [`LinkId`], resolved through `:links`, or 0 for none
    ///
    /// The four pushes below are in that order, which is what makes it true; the
    /// constants exist so `cooked--wire-layout' can hand the same numbers to Lisp rather
    /// than have `cooked--style-start' &c. retype them.
    ///
    /// A packed string rather than a list of lists, for the reason [`Deco::pack_into`] gives:
    /// the Emacs apply path is the bottleneck, and a list costs conses a span on every
    /// damaged row of every frame. And ids rather than colours, so that resolving a span's
    /// face is an `aref' into a vector Lisp keeps per session, rather than a decode of
    /// three colour fields and a hash lookup per span.
    ///
    /// **START and END are `u32`.** [`Update::scrolled_rows`] assembles a whole drain's
    /// scrollback into *one* `Block`, so offsets are bounded by the flood rather than a row:
    /// the flood benchmark reaches 200k characters in one block and a 20k-line paste goes
    /// past 600k. A `u16` would wrap at 65536 and silently style the wrong characters.
    ///
    /// A span whose offsets do not fit is dropped rather than clamped. It takes 4.29
    /// billion characters between two drains, but dropping loses the colour of text far
    /// off screen, while clamping would paint it over text that is on screen.
    fn push_style(&mut self, chars: Chars, style: StyleId, link: Option<LinkId>) {
        let (Ok(start), Ok(end)) = (
            u32::try_from(self.offset.get()),
            u32::try_from((self.offset + chars).get()),
        ) else {
            return;
        };
        let link = if self.unlinked {
            0
        } else {
            link.map_or(0, LinkId::get)
        };
        self.styles.extend_from_slice(&start.to_le_bytes());
        self.styles.extend_from_slice(&end.to_le_bytes());
        self.styles.extend_from_slice(&style.get().to_le_bytes());
        self.styles.extend_from_slice(&link.to_le_bytes());
        // The stride is the format: Lisp walks the string by adding [`STYLE_RECORD`], so a
        // field added without widening the constant would desynchronise the two sides.
        debug_assert_eq!(
            self.styles.len() % STYLE_RECORD,
            0,
            "a style record must be exactly {STYLE_RECORD} bytes"
        );
    }

    /// Append RUNS, emitting spans only where there is something to say.
    fn push_runs(&mut self, env: Env<'e>, runs: &Runs) -> Result<()> {
        for run in runs {
            // Taken before `push_run` advances the offset it is measured from.
            if let Some(deco) = run.deco {
                self.push_deco(env, deco)?;
            }
            self.push_run(run);
        }
        Ok(())
    }

    /// `nil`, or `(KIND . PACKED)` — what a run's characters display instead of
    /// themselves — pushed onto `decos` as `(START . (KIND . PACKED))`.
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
    /// The two kinds count differently on purpose; [`Deco::pack_into`] explains why. The
    /// rectangle is repeated on every image cell because it belongs to the placement (see
    /// [`Placement`](emu::image::Placement)), four bytes a cell against a picture's megabytes.
    ///
    /// A method rather than an `IntoLisp` impl because the packing needs somewhere to
    /// keep its scratch buffer between calls, and a trait impl has nowhere to put one: see
    /// `deco_scratch`.
    fn push_deco(&mut self, env: Env<'e>, deco: &Deco) -> Result<()> {
        self.deco_scratch.clear();
        deco.pack_into(&mut self.deco_scratch);
        let packed = env.into_lisp(self.deco_scratch.as_slice())?;
        let tagged = match deco {
            Deco::Glyphs(_) => env.cons(sym!(env, "glyph")?, packed)?,
            Deco::Images(_) => env.cons(sym!(env, "image")?, packed)?,
        };
        self.decos.push(list!(env, [self.offset, tagged])?);
        Ok(())
    }

    /// The half of [`Block::push_runs`] that needs no Emacs: the text itself, its style
    /// span, and the two measurements [`Block::end_row`] banks into the row table.
    ///
    /// Split out for the tests at the foot of this file. Everything else on the path
    /// from a run to the row table takes an `Env`, which only a loaded module has,
    /// and the row table is precisely the thing a coalesced block can get wrong.
    ///
    /// `run.chars` was counted while the run was built, so nothing here scans the text:
    /// the characters are copied once, into `self.text`.
    fn push_run(&mut self, run: RunRef<'_>) {
        let chars = run.chars;
        self.cols += run.cols;
        self.uniformity = self.uniformity.max(Uniformity::of(run));
        let font = self
            .font_bits
            .get(run.style.get() as usize)
            .copied()
            .unwrap_or(FontBits::PLAIN);
        if let Some(mixed) = font.in_row(self.offset - self.row_start, chars) {
            self.fonts = emu::mix(self.fonts, mixed);
        }
        if !run.style.is_default() || run.link.is_some() {
            self.push_style(chars, run.style, run.link);
        }
        self.text.push_str(run.text);
        self.offset += chars;
    }

    /// The row table entry for RUNS, a whole row, without sending its text.
    ///
    /// For a row sent as an edit: the replacement is only part of the row, and the width
    /// guard and the wrap mark still need the measurements of all of it.
    fn measure(font_bits: &[FontBits], runs: &Runs, wrap: Wrap, width: usize) -> BlockRow {
        let mut block = Block::new(font_bits);
        for run in runs {
            block.push_run(run);
        }
        block.end_row(wrap, width);
        block.rows[0]
    }

    fn push_newline(&mut self) {
        self.text.push('\n');
        // The newline Emacs holds between two rows is a character of the block's text
        // like any other, and every offset after it counts it.
        self.offset += Chars::ONE;
        // The text of whatever comes next starts after this newline. Scrollback does not
        // need it, and one store is cheaper than a second `push_newline`.
        self.row_start = self.offset;
        self.row_start_byte = Bytes::of(&self.text);
    }

    /// Close the screen row being built: bank where it began and what it measured, and
    /// start the next one.
    ///
    /// Called once per damaged row and never for scrollback: a live row is a fixed-width
    /// slot whose layout Emacs can get wrong, while a scrollback line may wrap.
    fn end_row(&mut self, wrap: Wrap, width: usize) {
        let text = emu::fast_hash(&self.text.as_bytes()[self.row_start_byte.get()..]);
        self.rows.push(BlockRow {
            start: self.row_start,
            cols: self.cols,
            uniform: self.uniformity,
            wrap: WrapMark::of(wrap, self.cols, width),
            hash: emu::mix(text, self.fonts) & ((1 << 60) - 1),
        });
        self.cols = Cols::ZERO;
        self.uniformity = Uniformity::Ascii;
        self.fonts = 0;
        self.row_start = self.offset;
        self.row_start_byte = Bytes::of(&self.text);
    }

    fn into_lisp(self, env: &Env<'e>) -> Result<Value<'e>> {
        let rows = self
            .rows
            .iter()
            .map(|row| {
                list!(
                    *env,
                    [row.start, row.cols, row.uniform, row.wrap, row.hash as i64]
                )
            })
            .collect::<Result<Vec<_>>>()?;
        list!(
            *env,
            [self.text.as_str(), self.styles.as_slice(), self.decos, rows]
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
    start: Chars,
    chars: Chars,
}

impl Update {
    /// This drain's scrollback: the rows Emacs promotes as `(CHARS . ENDS)` each, the rest
    /// as one [`Block`], and where each row landed in the text the two make together.
    ///
    /// Assembled here rather than handed over row by row, for the reason [`Block`]
    /// gives: a flood is tens of thousands of rows, and Emacs pays for every `insert`.
    ///
    /// A promoted row is counted into the offsets as though its text were in the block,
    /// because once Emacs has promoted it the text is there, just above the block: a mark
    /// at column 5 of a promoted row is `(scrolled . 5)` from where the promoted rows
    /// begin, as it would be from where resent rows began.
    fn scrolled_rows<'e>(
        &self,
        env: Env<'e>,
        rejoin: bool,
    ) -> Result<(Value<'e>, Value<'e>, Vec<RowSpan>)> {
        if self.delta.scrolled.is_empty() {
            return Ok((env.nil(), env.nil(), Vec::new()));
        }
        let mut block = Block::default();
        let promotion = self.delta.promoted.map_or(0, |shift| shift.count);
        let mut promoted = Vec::with_capacity(promotion);
        let mut rows: Vec<RowSpan> = Vec::with_capacity(self.delta.scrolled.len());
        // Characters, newlines included, of the promoted rows before the block's text.
        let mut kept = Chars::ZERO;

        for (i, (line, ends)) in self.delta.scrolled_lines(rejoin).enumerate() {
            if i < promotion {
                let chars = line.runs.chars();
                rows.push(RowSpan { start: kept, chars });
                // The newline after a promoted row is a character of the buffer's text
                // too, so the next row starts one further along.
                kept += chars + Chars::new(usize::from(ends));
                promoted.push(env.cons(env.into_lisp(chars)?, env.into_lisp(ends)?)?);
                continue;
            }
            let start = block.offset;
            block.push_runs(env, &line.runs)?;
            rows.push(RowSpan {
                start: kept + start,
                chars: block.offset - start,
            });
            if ends {
                block.push_newline();
            }
        }

        let text = if promotion < self.delta.scrolled.len() {
            block.into_lisp(&env)?
        } else {
            env.nil()
        };
        // `(BOTTOM . ROWS)`, BOTTOM being the last row of the region the rows left.
        let promoted = match self.delta.promoted {
            Some(shift) => env.cons(env.into_lisp(shift.bottom)?, env.list(&promoted)?)?,
            None => env.nil(),
        };
        Ok((promoted, text, rows))
    }

    /// Spell an [`Anchor`] in whichever coordinate system Emacs can address it in.
    ///
    /// `(scrolled . OFFSET)` — a character offset into this drain's scrollback text, for
    /// a row that scrolled away while this drain was accumulating. `(screen ROW . CHARS)`
    /// — a row on the live grid and the characters of its text before the anchor, for one
    /// that did not. Taking an [`Anchor<Chars>`] is the whole of the unit question here:
    /// the drain turned the column into characters before building the [`Delta`](crate::emu::Delta), so this
    /// only has to name which of the two systems the offset belongs to. Resolved here
    /// rather than in Lisp because the arithmetic is over Rust's absolute row numbering,
    /// which is not something the Lisp side should have to hold a copy of.
    ///
    /// `nil` when neither applies, which cannot happen while events and scrollback are
    /// taken by the same drain; Lisp then falls back to the cursor.
    fn anchor_to_lisp<'e>(
        &self,
        env: Env<'e>,
        at: Anchor<Chars>,
        rows: &[RowSpan],
    ) -> Result<Value<'e>> {
        let base = self.delta.scrolled_base;
        let on_grid = base + self.delta.scrolled.len();
        if at.row >= on_grid {
            return env.cons(
                sym!(env, "screen")?,
                env.cons(env.into_lisp(at.row - on_grid)?, env.into_lisp(at.col)?)?,
            );
        }
        match at.row.checked_sub(base).and_then(|i| rows.get(i)) {
            // Trailing blanks are trimmed out of the runs, so an offset past the end of
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
/// No cell rectangle: that belongs to each *placement*, since the same image can be on
/// screen at two sizes. It rides [`Placement`](crate::emu::image::Placement) with the rows.
fn images_to_lisp<'e>(env: Env<'e>, images: &[ImageData]) -> Result<Vec<Value<'e>>> {
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
fn links_to_lisp<'e>(env: Env<'e>, links: &[(LinkId, String)]) -> Result<Vec<Value<'e>>> {
    links
        .iter()
        .map(|(id, uri)| env.cons(env.into_lisp(*id)?, env.into_lisp(uri.as_str())?))
        .collect()
}

/// Renditions first named this drain, each as `(ID FG BG UL ATTRS)`.
///
/// [`links_to_lisp`]'s sibling: the rows of the same drain name these by id, and Lisp
/// installs them before rendering. FG, BG and UL are in `cooked--color''s spelling --
/// nil for the terminal default, an integer for a palette index, `(R G B)` for a direct
/// colour -- so Lisp builds a face from them without decoding anything, and ATTRS is the
/// [`Attrs`] bitmask.
fn styles_to_lisp<'e>(env: Env<'e>, styles: &[(StyleId, Style)]) -> Result<Vec<Value<'e>>> {
    let color = |color: Color| -> Result<Value<'e>> {
        match color {
            Color::Default => Ok(env.nil()),
            Color::Indexed(index) => env.into_lisp(index),
            Color::Rgb(r, g, b) => list!(env, [r, g, b]),
        }
    };
    styles
        .iter()
        .map(|(id, style)| {
            list!(
                env,
                [
                    id.get(),
                    color(style.fg)?,
                    color(style.bg)?,
                    color(style.underline)?,
                    style.attrs.bits()
                ]
            )
        })
        .collect()
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
fn event_to_lisp<'e>(
    env: Env<'e>,
    event: &Event,
    update: &Update,
    rows: &[RowSpan],
) -> Result<Value<'e>> {
    // The tag arrives already resolved, because `sym!` needs the literal at its own
    // call site to do the lookup at compile time -- which is the point of it.
    let mark = |name: Value<'e>, at: Anchor<Chars>, id: MarkId| {
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
        // (mouse ENABLED DRAG MOTION). Not a single "wants the mouse" bit, because 1002
        // and 1003 ask to be told where the pointer went, which the sender cannot know
        // otherwise. The report's spelling -- X10, SGR or SGR in pixels -- used to ride
        // along as two more booleans here, but nothing in Lisp decided from them, so a
        // click landing between the child changing its mind and Emacs' next drain was
        // encoded against the stale answer. `cooked--send-mouse-report' now reads the
        // spelling fresh, under the lock, at the moment each report is built; see
        // `Mouse::report' in src/emu/term/mouse.rs.
        Event::Mouse(m) => list!(
            env,
            [sym!(env, "mouse")?, m.enabled(), m.drag(), m.motion()]
        ),
        Event::Reply(reply) => {
            env.cons(sym!(env, "reply")?, env.into_lisp(reply.bytes.as_slice())?)
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
    }
}

/// [`Block::push_style`] needs no `Env`: it writes bytes into a `Vec`, and the format is
/// the whole of what it decides. So the layout both sides have to agree on forever is
/// pinned here, without an Emacs in the loop -- which is the same reason the rest of the
/// crate is testable, applied to the one file that usually is not.
#[cfg(test)]
mod tests {
    use super::*;
    use crate::emu::Run;
    use crate::emu::cell::{Attrs, Color};

    /// The keys a plist literal in SOURCE starting at MARKER names, in order.
    fn plist_keys(source: &str, marker: &str) -> Vec<String> {
        let from = source.find(marker).expect("marker present");
        let body = &source[from..];
        let body = &body[..body.find("})").expect("plist closes")];
        body.lines()
            .filter_map(|line| line.trim().strip_prefix('"'))
            .filter_map(|rest| rest.split('"').next())
            .map(str::to_owned)
            .collect()
    }

    /// The `cooked--drain' docstring lists every key the drain emits, in the order it
    /// emits them. It is hand-written prose next to the defun, and a key added to
    /// `update_to_lisp` without it is a key `C-h f' never mentions.
    #[test]
    fn the_drain_docstring_names_every_key_the_drain_emits() {
        let emitted = plist_keys(
            include_str!("wire.rs"),
            "plist!(env, {\n        \":scrolled\"",
        );
        let lib = include_str!("lib.rs");
        let doc_start = lib.find("Returns a plist with").expect("drain docstring");
        let sentence = &lib[doc_start..];
        let sentence = &sentence[..sentence.find(".\n").expect("sentence ends")];
        let documented: Vec<String> = sentence
            .split(|c: char| !(c == ':' || c == '-' || c.is_ascii_alphanumeric()))
            .filter(|word| word.starts_with(':'))
            .map(str::to_owned)
            .collect();
        assert!(emitted.len() > 10, "found only {emitted:?}");
        assert_eq!(documented, emitted);
    }

    /// The record a `Block` holding exactly one span would have.
    fn record(style: StyleId, link: Option<LinkId>) -> Vec<u8> {
        let mut block = Block::default();
        block.push_style(Chars::ONE, style, link);
        block.styles
    }

    fn u32_at(bytes: &[u8], at: usize) -> u32 {
        u32::from_le_bytes(bytes[at..at + 4].try_into().unwrap())
    }

    #[test]
    fn a_style_record_is_exactly_the_stride_lisp_steps_by() {
        let packed = record(StyleId::DEFAULT, None);
        assert_eq!(
            packed.len(),
            STYLE_RECORD,
            "`cooked--style-record' in cooked-face.el is this number: {packed:?}"
        );
    }

    /// STYLE and LINK sit where `cooked--do-style-spans' reads them, and a missing link is
    /// the zero `LinkId`'s niche makes it.
    #[test]
    fn a_record_carries_the_rendition_and_the_link_by_id() {
        let packed = record(StyleId::from_raw(7), Some(LinkId::from_index(2)));
        assert_eq!(u32_at(&packed, 8), 7, "style");
        assert_eq!(u32_at(&packed, 12), 3, "link, which counts from 1");
        assert_eq!(
            u32_at(&record(StyleId::from_raw(7), None), 12),
            0,
            "no link"
        );

        // The comint filter's records name no link: its consumer has no table to find one
        // in, and gets the destinations beside the records instead.
        let mut block = Block {
            unlinked: true,
            ..Block::default()
        };
        block.push_style(
            Chars::ONE,
            StyleId::from_raw(7),
            Some(LinkId::from_index(2)),
        );
        assert_eq!(u32_at(&block.styles, 12), 0);
    }

    /// The `u16` trap the field widths exist to avoid, stated as a test rather than only
    /// as a comment. `Update::scrolled_rows` assembles a whole drain's scrollback into
    /// one `Block`, so an offset is bounded by the flood rather than by a row: a `u16`
    /// start would wrap at 65536 and style the wrong characters, with nothing anywhere
    /// to point at.
    #[test]
    fn an_offset_past_a_u16_packs_at_full_width_rather_than_wrapping() {
        let mut block = Block {
            offset: Chars::new(70_000),
            ..Default::default()
        };
        block.push_style(Chars::new(5), StyleId::DEFAULT, None);
        assert_eq!(u32_at(&block.styles, 0), 70_000, "start");
        assert_eq!(u32_at(&block.styles, 4), 70_005, "end");
    }

    /// The indices of each run, which is all the grouping decision amounts to.
    /// Push RUNS as one [`Runs`] would arrive from a row.
    ///
    /// Owned [`Run`]s are still how a test says what it means, so they are gathered into
    /// the borrowed form the block takes. `Runs::from_runs` keeps each one its own run,
    /// whatever the pen, which is what a test naming three runs is asking for.
    fn push(block: &mut Block<'_, '_>, runs: &[Run]) {
        for run in &Runs::from_runs(runs) {
            block.push_run(run);
        }
    }

    fn runs_of(indices: &[usize]) -> Vec<Vec<usize>> {
        let rows: Vec<DamagedRow> = indices
            .iter()
            .map(|i| DamagedRow {
                index: *i,
                wrap: Wrap::No,
                runs: Runs::default(),
                edit: None,
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

    /// A row can be blank for two reasons at once: `ab` followed by two of the child's
    /// own spaces, and then a two-column character with only one column of room left, is
    /// both a row with its own trailing blanks *and* one a wide character wrapped early.
    /// The mark has to carry the one column of padding separately from the two blanks
    /// the row's own width implies are missing, or a rewrap counts the wide character's
    /// leftover room as a third blank of the line that was never there.
    #[test]
    fn an_early_wrap_s_pad_is_reported_apart_from_the_row_s_own_blanks() {
        assert_eq!(
            WrapMark::of(Wrap::Early(Cols::new(1)), Cols::new(2), 5),
            WrapMark::Blank(Cols::new(1))
        );
    }

    /// The ordinary case this mark has always covered: a row with nothing but its own
    /// trailing blanks reports no padding to leave out of them.
    #[test]
    fn a_full_wrap_s_blanks_carry_no_pad() {
        assert_eq!(
            WrapMark::of(Wrap::Full, Cols::new(2), 5),
            WrapMark::Blank(Cols::ZERO)
        );
    }

    /// One row's measurements must not leak into the next one's. A shared answer would
    /// send every plain row beside a wide one down the guard's slow path, and make a plain
    /// row's width read as the sum of everything before it.
    #[test]
    fn each_row_of_a_block_carries_its_own_width_and_uniformity() {
        let row = |text: &str, cols: usize| Run {
            text: text.to_string(),
            cols: Cols::new(cols),
            ..Run::default()
        };
        let mut block = Block::default();
        push(&mut block, &[row("ab", 2)]);
        block.end_row(Wrap::No, 80);
        block.push_newline();
        // Two characters of three bytes each standing on two cells apiece: neither
        // one-byte nor one-cell, so this row is the nonuniform one.
        push(&mut block, &[row("世界", 4)]);
        // And the wrapped one: its logical line goes on below it. Per row like the other
        // two, and asserted alongside them, because a flag that leaked between rows would
        // have Emacs join a line the child ended. Four columns of text on a four-column
        // screen, so its line ends where its text does and it is a plain wrap.
        block.end_row(Wrap::Full, 4);
        block.push_newline();
        push(&mut block, &[row("cd", 2)]);
        block.end_row(Wrap::No, 80);

        let table: Vec<(usize, usize, Uniformity, WrapMark)> = block
            .rows
            .iter()
            .map(|r| (r.start.get(), r.cols.get(), r.uniform, r.wrap))
            .collect();
        assert_eq!(
            table,
            vec![
                (0, 2, Uniformity::Ascii, WrapMark::Ends),
                (3, 4, Uniformity::Mixed, WrapMark::Wraps),
                (6, 2, Uniformity::Ascii, WrapMark::Ends)
            ],
            "text {:?}",
            block.text
        );
    }

    /// A box-glyph run lifts a row to `Glyphs` and no further, a CJK run makes it `Mixed`
    /// whatever else it holds, and a row's class does not reach the next row.
    ///
    /// `Glyphs` is the class that lets Emacs skip measuring a border, so what matters is
    /// that it is never given to a row holding a font glyph that could be wider: here the
    /// second row has a border *and* a CJK character, and has to be measured.
    #[test]
    fn a_row_of_box_glyphs_is_uniform_only_while_nothing_else_needs_the_font() {
        let glyphs = |text: &str| Run {
            text: text.to_string(),
            cols: Cols::new(text.chars().count()),
            deco: Some(Deco::Glyphs(Vec::new())),
            ..Run::default()
        };
        let plain = |text: &str, cols: usize| Run {
            text: text.to_string(),
            cols: Cols::new(cols),
            ..Run::default()
        };
        let mut block = Block::default();
        push(
            &mut block,
            &[glyphs("┌──"), plain(" ok ", 4), glyphs("\u{a0}──┐")],
        );
        block.end_row(Wrap::No, 80);
        block.push_newline();
        push(&mut block, &[glyphs("│"), plain("世", 2)]);
        block.end_row(Wrap::No, 80);
        block.push_newline();
        push(&mut block, &[plain("ab", 2)]);
        block.end_row(Wrap::No, 80);

        let classes: Vec<Uniformity> = block.rows.iter().map(|r| r.uniform).collect();
        assert_eq!(
            classes,
            vec![Uniformity::Glyphs, Uniformity::Mixed, Uniformity::Ascii]
        );
    }

    /// The layout hash follows the text and the font-changing renditions, and nothing
    /// else: the same text in another colour lays out identically and must share a key,
    /// while the same text in bold may not.
    #[test]
    fn a_row_hash_changes_with_text_and_font_and_not_with_colour() {
        // Id 1 is bold and id 2 red, which is what the font table says of them.
        let (plain, bold, red) = (StyleId::DEFAULT, StyleId::from_raw(1), StyleId::from_raw(2));
        let fonts = [
            FontBits::PLAIN,
            Style {
                attrs: Attrs::BOLD,
                ..Style::default()
            }
            .into(),
            Style {
                fg: Color::Indexed(1),
                ..Style::default()
            }
            .into(),
        ];
        let hash = |runs: &[Run]| {
            let mut block = Block::new(&fonts);
            push(&mut block, runs);
            block.end_row(Wrap::No, 80);
            block.rows[0].hash
        };
        let run = |text: &str, style: StyleId| Run {
            text: text.to_string(),
            cols: Cols::new(text.chars().count()),
            style,
            ..Run::default()
        };
        let base = hash(&[run("hello", plain)]);
        assert_eq!(base, hash(&[run("hello", red)]));
        assert_ne!(base, hash(&[run("hellO", plain)]));
        assert_ne!(base, hash(&[run("hello", bold)]));
        assert_ne!(
            hash(&[run("he", bold), run("llo", plain)]),
            hash(&[run("hel", bold), run("lo", plain)])
        );
        assert!(base < 1 << 60, "the hash must cross as a fixnum");
    }

    /// Dropped rather than truncated, which is the deliberate half of the choice: a lost
    /// colour is invisible off the far end of a flood, while a clamped one would paint
    /// over text that is on screen. Unreachable in practice -- it takes four billion
    /// characters between two drains -- so the only thing that can keep it right is this.
    #[test]
    fn a_span_whose_offsets_do_not_fit_is_dropped_and_never_clamped() {
        let mut block = Block {
            offset: Chars::new(usize::try_from(u32::MAX).unwrap()),
            ..Default::default()
        };
        block.push_style(Chars::new(2), StyleId::DEFAULT, None);
        assert!(
            block.styles.is_empty(),
            "an unrepresentable span leaves no record: {:?}",
            block.styles
        );
    }
}
