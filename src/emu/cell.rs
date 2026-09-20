//! Cells, styling, and the row representation the renderer consumes.

use std::borrow::{Borrow, BorrowMut};
use std::ops::{BitAnd, BitOr, BitOrAssign, Not};
use unicode_width::UnicodeWidthChar;

use super::glyph::{self, BoxGlyph};
use super::image::Placement;
use super::link::LinkId;
use super::style::StyleId;
use super::units::{Bytes, Chars, Cols};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Hash)]
pub enum Color {
    #[default]
    Default,
    Indexed(u8),
    Rgb(u8, u8, u8),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Hash)]
pub struct Attrs(u16);

impl Attrs {
    pub const NONE: Self = Self(0);
    pub const BOLD: Self = Self(1 << 0);
    pub const FAINT: Self = Self(1 << 1);
    pub const ITALIC: Self = Self(1 << 2);
    pub const UNDERLINE: Self = Self(1 << 3);
    pub const BLINK: Self = Self(1 << 4);
    pub const REVERSE: Self = Self(1 << 5);
    pub const CONCEAL: Self = Self(1 << 6);
    pub const STRIKE: Self = Self(1 << 7);

    /// Bits 8-10 hold the underline *style* — kitty's `SGR 4:1`-`4:5`. [`Attrs::UNDERLINE`]
    /// means "underlined at all", whatever the style, and `SGR 4` alone is style 1.
    const UL_SHIFT: u16 = 8;
    const UL_MASK: u16 = 0b111 << Self::UL_SHIFT;

    /// `SGR 53`, above the underline-style field rather than in the spare bits below it,
    /// which that field has already spent. `cooked--attr-overline` in
    /// lisp/cooked-face.el mirrors it.
    pub const OVERLINE: Self = Self(1 << 11);

    pub const fn bits(self) -> u16 {
        self.0
    }

    /// The set whose [`Attrs::bits`] are BITS, for a [`Cell`] reading its rendition back.
    pub const fn from_bits(bits: u16) -> Self {
        Self(bits)
    }

    /// 0 none, 1 single, 2 double, 3 curly, 4 dotted, 5 dashed.
    pub const fn underline_style(self) -> u8 {
        ((self.0 & Self::UL_MASK) >> Self::UL_SHIFT) as u8
    }

    /// Style 0 removes the underline entirely, which is what `SGR 4:0` means.
    pub fn set_underline_style(&mut self, style: u8) {
        self.0 &= !Self::UL_MASK;
        match style {
            0 => self.remove(Self::UNDERLINE),
            s => {
                self.0 |= (u16::from(s) << Self::UL_SHIFT) & Self::UL_MASK;
                *self |= Self::UNDERLINE;
            }
        }
    }

    pub const fn contains(self, other: Self) -> bool {
        self.0 & other.0 == other.0
    }

    pub fn remove(&mut self, other: Self) {
        self.0 &= !other.0;
    }
}

impl BitOr for Attrs {
    type Output = Self;
    fn bitor(self, rhs: Self) -> Self {
        Self(self.0 | rhs.0)
    }
}

impl BitOrAssign for Attrs {
    fn bitor_assign(&mut self, rhs: Self) {
        self.0 |= rhs.0;
    }
}

impl BitAnd for Attrs {
    type Output = Self;
    fn bitand(self, rhs: Self) -> Self {
        Self(self.0 & rhs.0)
    }
}

impl Not for Attrs {
    type Output = Self;
    fn not(self) -> Self {
        Self(!self.0)
    }
}

/// This module's half of `cooked--wire-layout': the [`Attrs`] bit values, mirrored by
/// `cooked--attr-*' in lisp/cooked-face.el, and the glyph and image record layouts
/// [`Deco::pack_into`] writes, mirrored in lisp/cooked-deco.el. `wire::wire_layout` in
/// wire.rs carries the style-record half, and `glyph::wire_layout` in glyph.rs the
/// box-glyph bit layout; `cooked--wire-layout' in lib.rs concatenates all three.
///
/// NAME matches the corresponding Lisp constant with its `cooked--' prefix removed,
/// so `("attr-bold", _)' here is `cooked--attr-bold' there.
pub(crate) fn wire_layout() -> Vec<(&'static str, u32)> {
    vec![
        ("attr-bold", u32::from(Attrs::BOLD.bits())),
        ("attr-faint", u32::from(Attrs::FAINT.bits())),
        ("attr-italic", u32::from(Attrs::ITALIC.bits())),
        ("attr-underline", u32::from(Attrs::UNDERLINE.bits())),
        ("attr-blink", u32::from(Attrs::BLINK.bits())),
        ("attr-reverse", u32::from(Attrs::REVERSE.bits())),
        ("attr-conceal", u32::from(Attrs::CONCEAL.bits())),
        ("attr-strike", u32::from(Attrs::STRIKE.bits())),
        ("attr-underline-shift", u32::from(Attrs::UL_SHIFT)),
        ("attr-underline-style", u32::from(Attrs::UL_MASK)),
        ("attr-overline", u32::from(Attrs::OVERLINE.bits())),
        ("glyph-record", Deco::GLYPH_RECORD as u32),
        ("glyph-bits", Deco::GLYPH_BITS as u32),
        ("glyph-count", Deco::GLYPH_COUNT as u32),
        ("image-record", Deco::IMAGE_RECORD as u32),
        ("image-id", Deco::IMAGE_ID as u32),
        ("image-row", Deco::IMAGE_ROW as u32),
        ("image-col", Deco::IMAGE_COL as u32),
        ("image-cols", Deco::IMAGE_COLS as u32),
        ("image-rows", Deco::IMAGE_ROWS as u32),
    ]
}

/// A rendition: everything SGR sets that decides how a character is drawn.
///
/// What the pen holds and what a [`StyleId`] names. The underline's own colour
/// (`SGR 58`) is part of it, like the foreground and background: a cell names one id for
/// all four, so none of them costs a cell more than another.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Hash)]
pub struct Style {
    pub fg: Color,
    pub bg: Color,
    pub attrs: Attrs,
    /// `SGR 58`, the underline's own colour.
    pub underline: Color,
}

impl Style {
    /// What an erase leaves behind: the background bar, and nothing else.
    ///
    /// This is `bce`, which terminfo advertises and which ncurses optimises on the
    /// strength of — it sets a background and erases rather than writing spaces, so
    /// dropping the pen here loses every coloured panel and status bar.
    ///
    /// Not the whole pen. `Row::content_len` counts a styled blank as content, so `SGR 31`
    /// followed by `EL` would otherwise leave trailing whitespace in the scrollback of every
    /// coloured shell prompt. With no background set the result is `Style::default()`.
    ///
    /// Reverse video survives because it is resolved in `cooked--face-build`, where the
    /// bar's colour is then the foreground; dropping the flag would erase the drawing.
    pub fn erase(self) -> Self {
        if self.attrs.contains(Attrs::REVERSE) {
            Self {
                fg: self.fg,
                bg: self.bg,
                attrs: Attrs::REVERSE,
                underline: Color::Default,
            }
        } else {
            Self {
                bg: self.bg,
                ..Self::default()
            }
        }
    }
}

/// One screen position. `ch() == CONTINUATION` marks the second half of a wide character.
///
/// One eight-byte word, carrying three things a cell has always carried: the character,
/// the [`StyleId`] of its rendition, and the `OSC 8` link it is part of. The rendition
/// and the link are ids, so a cell costs the same whatever it is drawn in and whether or
/// not it is linked: a coloured underline or a link is a field written with the character
/// rather than an entry in a side table found per column.
///
/// Packed rather than three fields because none of the three needs a whole word. A
/// `char` is a scalar value, so twenty-one bits hold every one of them; both ids are
/// handed out against what the grids hold and collected when nothing names them any more
/// -- [`StyleStore::collect`](super::style::StyleStore::collect) and
/// [`LinkStore::collect`](super::link::LinkStore::collect) -- so neither counts what a
/// session has seen, only what it is showing at once. The field widths below are two
/// million and four million against the eighty thousand cells of a 200x400 grid.
///
/// The character and the rendition are the low bits and the link the high ones, which is
/// what lets [`Cell::head`] drop the link with one mask: trailing-blank trimming ignores
/// links, and that mask is the whole of how.
///
/// Every bit of the word is part of the cell's value, so two rows compare equal exactly
/// when their words do -- see [`Cell::bytes`] -- and a comparison against the frame Emacs
/// already holds covers the character, the rendition and the link in one `memcmp`.
#[repr(transparent)]
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct Cell(u64);

/// The three fields rather than the word they are packed into: a failing assertion over
/// a row of cells has to be readable as characters and ids, which is what it was when
/// they were fields.
impl std::fmt::Debug for Cell {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Cell")
            .field("ch", &self.ch())
            .field("style", &self.style())
            .field("link", &self.link())
            .finish()
    }
}

const _: () = assert!(std::mem::size_of::<Cell>() == 8);

/// Bits for the character: every Unicode scalar value, which is what a `char` is.
const CH_BITS: u32 = 21;
/// Bits for the rendition id, and where it sits above the character.
const STYLE_BITS: u32 = 22;
const STYLE_SHIFT: u32 = CH_BITS;
/// Bits for the link id, above both, so that [`Cell::head`] is one mask.
const LINK_BITS: u32 = 21;
const LINK_SHIFT: u32 = CH_BITS + STYLE_BITS;

const _: () = assert!(CH_BITS + STYLE_BITS + LINK_BITS == u64::BITS);
const _: () = assert!(char::MAX as u64 >> CH_BITS == 0);

/// The word with the link masked away: the character and the rendition alone.
///
/// What [`Cell::head`] compares, and the reason for the field order.
const HEAD_MASK: u64 = (1 << LINK_SHIFT) - 1;

/// Highest id each field can hold. An id past it degrades rather than aliasing; see
/// [`Cell::linked`]. `pub(crate)` so [`StyleStore`](super::style::StyleStore) and
/// [`LinkStore`](super::link::LinkStore) can clamp their own growth to what a cell can
/// actually hold; see their `collect` methods.
pub(crate) const STYLE_MAX: u64 = (1 << STYLE_BITS) - 1;
pub(crate) const LINK_MAX: u64 = (1 << LINK_BITS) - 1;

pub(crate) const CONTINUATION: char = '\0';
pub(crate) const BLANK: char = ' ';
/// U+00A0, named because `tree` indents with it: its rows read
/// `\u{2502}\u{a0}\u{a0} \u{251c}\u{2500}\u{2500} `, and a rule that absorbed only U+0020 would leave each split at
/// the no-break spaces, defeating [`Row::absorb_blank_runs`].
pub(crate) const NO_BREAK_SPACE: char = '\u{a0}';

/// Whether CH occupies a cell without drawing anything in it.
///
/// The membership test for [`Row::absorb_blank_runs`], and deliberately a short closed
/// list rather than a Unicode property: what qualifies is a character the child used as
/// *spacing between box glyphs*, and baking anything else into a run's bitmap would hide
/// a character the child meant to be seen. `\u{a0}` is in because `tree` puts it there;
/// a tab never reaches a cell (the grid expands it) and a zero-width space is a
/// combining mark, which arrives as an attachment rather than as a cell.
pub(crate) fn draws_nothing(ch: char) -> bool {
    ch == BLANK || ch == NO_BREAK_SPACE
}

/// Characters Emacs holds for a row of CELLS and EXTRAS before the character at column
/// COLS: one per cell that is not the second half of a wide character, and one more per
/// combining mark riding a cell.
///
/// The one conversion from a grid column to a character offset into the row's text, so
/// that everything the core tells Emacs by offset agrees on it: the ends of a partial row
/// edit, the cursor, and an anchor. On `日本X` the cursor on either column of `本` is 1
/// character in; counting columns instead puts it on `X`. A column that is the second
/// half of a wide character counts from the character it belongs to, and COLS past the
/// row counts the cells there are.
pub(crate) fn chars_before<'a>(
    cells: &[Cell],
    extras: impl Iterator<Item = &'a (u16, Extra)>,
    cols: Cols,
) -> Chars {
    let mut cols = cols.get().min(cells.len());
    while cols < cells.len() && cols > 0 && cells[cols].is_continuation() {
        cols -= 1;
    }
    let base = cells[..cols]
        .iter()
        .filter(|c| !c.is_continuation())
        .count();
    // A mark on a continuation cell is not rendered -- the runs skip that cell whole --
    // so it is not counted either.
    let marks: usize = extras
        .filter(|(at, _)| usize::from(*at) < cols && !cells[usize::from(*at)].is_continuation())
        .map(|(_, extra)| match extra {
            Extra::Marks(text) => text.chars().count(),
            _ => 0,
        })
        .sum();
    Chars::new(base + marks)
}

impl Default for Cell {
    fn default() -> Self {
        Self::blank(StyleId::DEFAULT)
    }
}

impl Cell {
    pub const fn new(ch: char, style: StyleId) -> Self {
        Self::linked(ch, style, None)
    }

    /// CH in STYLE, part of LINK.
    ///
    /// The one place a cell is packed, and the one place the field widths can be
    /// exceeded. An id too big for its field is written as the default rendition or as
    /// no link, never as the low bits of itself: a truncated id would name *another*
    /// live rendition or another destination, which is the one failure that puts a
    /// child's own colours or its own URL on the wrong text. Reaching it needs a child
    /// that keeps four million distinct renditions or two million destinations alive at
    /// once, which is several hundred megabytes of table before it is a cell's problem.
    pub const fn linked(ch: char, style: StyleId, link: Option<LinkId>) -> Self {
        let style = style.get() as u64;
        let link = match link {
            Some(id) => id.get() as u64,
            None => 0,
        };
        let style = if style > STYLE_MAX { 0 } else { style };
        let link = if link > LINK_MAX { 0 } else { link };
        Self((ch as u64) | (style << STYLE_SHIFT) | (link << LINK_SHIFT))
    }

    pub const fn blank(style: StyleId) -> Self {
        Self::new(BLANK, style)
    }

    /// The character drawn here.
    pub const fn ch(self) -> char {
        // SAFETY: the field is `CH_BITS` wide and every value that reaches it came from
        // a `char`, so what comes out is the scalar value that went in.
        unsafe { char::from_u32_unchecked((self.0 & ((1 << CH_BITS) - 1)) as u32) }
    }

    /// The rendition this cell is drawn in.
    pub const fn style(self) -> StyleId {
        StyleId::from_raw(((self.0 >> STYLE_SHIFT) & STYLE_MAX) as u32)
    }

    /// The `OSC 8` link this cell is part of, if any.
    pub const fn link(self) -> Option<LinkId> {
        LinkId::from_wire((self.0 >> LINK_SHIFT) as u32)
    }

    /// The same rendition and link with CH in it.
    pub const fn with_char(self, ch: char) -> Self {
        Self((self.0 & !((1 << CH_BITS) - 1)) | ch as u64)
    }

    /// Whether this cell and OTHER are drawn alike: the same rendition and the same link.
    ///
    /// Both fields in one compare, which is what the run builders ask per cell.
    pub fn same_pen(self, other: Self) -> bool {
        (self.0 ^ other.0) >> STYLE_SHIFT == 0
    }

    /// Whether this cell is in the default rendition, the test trailing-blank trimming
    /// asks of every cell it walks. A link does not count: a run of blanks inside a link
    /// is still blanks, and trims like any other.
    pub fn is_default_style(self) -> bool {
        self.style().is_default()
    }

    /// Set every cell of CELLS to CELL.
    ///
    /// By doubling copies rather than `slice::fill`: a cell used to be four field stores
    /// that LLVM would not turn into `memset`, so a row of blanks was written a field at
    /// a time. Copying the filled prefix onto the rest is a handful of `memcpy`s however
    /// wide the row -- nine for a 400-column one -- and stays the cheaper shape now that
    /// a cell is one word, since `memcpy` of a growing prefix beats a word-at-a-time
    /// loop for any row worth filling.
    pub fn fill(cells: &mut [Cell], cell: Cell) {
        let Some(first) = cells.first_mut() else {
            return;
        };
        *first = cell;
        let mut filled = 1;
        while filled < cells.len() {
            let n = filled.min(cells.len() - filled);
            cells.copy_within(..n, filled);
            filled += n;
        }
    }

    /// CELLS as the bytes they are made of, for comparing whole rows.
    ///
    /// Compare rows through this rather than with `==` on the slices. A derived
    /// `PartialEq` is still a field-by-field walk, which the compiler does not merge into
    /// a `memcmp`: over a 200x400 grid the slice comparison took about 18 instructions a
    /// cell, and comparing the bytes about a tenth of that.
    ///
    /// Sound because `Cell` is a `repr(transparent)` `u64`: every bit of it is part of
    /// the value, there is no padding and nothing uninitialised, and the assert beside
    /// the type pins the size. So the bytes of a cell are a function of its value, and
    /// equal slices of bytes are equal cells.
    pub fn bytes(cells: &[Cell]) -> &[u8] {
        // SAFETY: see above -- `Cell` has no padding and no uninitialised bytes, and the
        // length is the slice's own size in bytes.
        unsafe { std::slice::from_raw_parts(cells.as_ptr().cast::<u8>(), size_of_val(cells)) }
    }

    /// Columns of CELLS up to the last one that is not a trailing blank, or zero.
    ///
    /// The scan behind [`Row::content_len`], and the hottest loop in the emulator: every
    /// row that scrolls off runs it over the full width of the screen, so a 400-column
    /// grid carrying a 54-character line walks 346 blanks before it finds anything.
    ///
    /// A cell is a trailing blank exactly when its character and its rendition are the
    /// blank ones, so the test is one masked compare of the whole word rather than a load
    /// and a compare per field; the mask is what drops the link, which trimming ignores.
    /// On the full-screen scroll benchmark that is about three instructions a blank
    /// rather than six.
    pub fn content_len(cells: &[Cell]) -> usize {
        let head = Self::blank(StyleId::DEFAULT).head();
        // Walked from the end, so the position reported counts the trailing blanks, and
        // the content ends that far short of the row's width.
        let blanks = cells.iter().rev().position(|cell| cell.head() != head);
        blanks.map_or(0, |blanks| cells.len() - blanks)
    }

    /// This cell's character and rendition, with its link masked away.
    const fn head(self) -> u64 {
        self.0 & HEAD_MASK
    }

    /// The whole cell as one integer, for a consumer comparing cells rather than reading
    /// them: `Front::edit` asks per column whether two cells differ at all.
    pub(crate) const fn word(self) -> u64 {
        self.0
    }

    /// The simplest correct statement of what [`Cell::content_len`] must produce.
    ///
    /// The rule that function encodes in a byte comparison, written out in its own terms
    /// for `content_len_matches_the_reference` to check it against: a cell is a trailing
    /// blank when it holds a blank in the default rendition, whatever link it is part of.
    #[cfg(test)]
    fn is_trailing_blank(self) -> bool {
        self.ch() == BLANK && self.is_default_style()
    }

    pub fn is_continuation(self) -> bool {
        self.ch() == CONTINUATION
    }

    /// Columns occupied; wide characters claim two.
    pub fn width(self) -> usize {
        self.ch().width().unwrap_or(1).max(1)
    }
}

/// What a writer puts in the cells it touches: the pen's rendition and open link for a
/// character, and the rendition an erase leaves behind.
///
/// Two renditions because `bce` erases in the pen's background and nothing else (see
/// [`Style::erase`]), and the grid never sees a [`Style`] to derive one from the other.
/// An erase leaves no link either: a hyperlink belongs to the characters written inside
/// it, not to the blanks a later `CSI K` paints.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Pen {
    pub style: StyleId,
    pub link: Option<LinkId>,
    pub erase: StyleId,
}

impl Pen {
    /// CH as this pen writes it.
    pub const fn cell(self, ch: char) -> Cell {
        Cell::linked(ch, self.style, self.link)
    }

    /// The blank an erase with this pen leaves.
    pub const fn blank(self) -> Cell {
        Cell::blank(self.erase)
    }
}

/// What one character displays in place of the glyph its font would draw.
///
/// The unit before grouping. A box-drawing character resolves to a shape Emacs
/// rasterizes, and an image cell to a slice of a transmitted image. Both work the same way
/// -- Rust names a thing per character and Emacs renders it as a `display` property -- so
/// they share a type.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DecoCell {
    Glyph(BoxGlyph),
    Image(Placement),
}

/// What CELL displays in place of its text, given the combining MARKS and the image
/// PLACED attached to it, for [`Row::build_runs`].
///
/// A placement wins over the character's own shape: it is state attached to this cell,
/// while the shape is derived from a character that an image cell keeps as a blank. In
/// practice they cannot both be here, since writing a character retires whatever was
/// attached, so this is an ordering, not a conflict resolution.
///
/// A cell carrying combining marks is not decorated at all, and draws from the font. A
/// decoration has one record per character of its run, and the marks are characters on
/// no column: `\u{2500}\u{300}\u{2500}\u{2500}` is four characters over three
/// columns, and three glyph records would leave Emacs drawing the last `\u{2500}` from
/// the font while the image covers the accent. A record per mark would widen the bitmap
/// instead. The font is the one thing that knows where an accent sits on a line, and a
/// picture cell with an accent on it is something only a confused child sends, so both
/// kinds give way to the text.
#[inline]
fn decoration(cell: &Cell, marks: Option<&str>, placed: Option<Placement>) -> Option<DecoCell> {
    if marks.is_some() {
        return None;
    }
    placed
        .map(DecoCell::Image)
        .or_else(|| DecoCell::classify(cell.ch()))
}

/// The decoration of a whole run, one entry per character of [`Run::text`].
///
/// A run is homogeneous in its kind: [`Row::build_runs`] will not merge characters
/// decorated differently into one run. That is what lets the wire format carry a single
/// kind tag plus fixed-width records, instead of tagging every character — see
/// [`Deco::pack_into`] for what those records are.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Deco {
    Glyphs(Vec<BoxGlyph>),
    Images(Vec<Placement>),
}

impl DecoCell {
    /// The shape this character resolves to from the character itself, if any.
    ///
    /// Derived rather than stored: a box-drawing character *is* its own descriptor, so
    /// nothing needs maintaining when the cell is overwritten. Images come from
    /// [`Extras`] instead, since no character stands for them.
    ///
    /// `#[inline]` because it is a forwarder on the per-cell path; see
    /// [`glyph::classify`].
    #[inline]
    fn classify(ch: char) -> Option<Self> {
        glyph::classify(ch).map(Self::Glyph)
    }
}

impl Deco {
    /// Bytes in one packed glyph-run record. See [`Deco::pack_into`] for the layout and
    /// `cooked--glyph-record' in lisp/cooked-deco.el for the mirror.
    const GLYPH_RECORD: usize = 4;
    /// Byte offset of the bit pattern within a glyph record; `cooked--glyph-bits'.
    const GLYPH_BITS: usize = 0;
    /// Byte offset of the run length within a glyph record; `cooked--glyph-count'.
    const GLYPH_COUNT: usize = 2;

    /// Bytes in one packed image-placement record; `cooked--image-record'.
    const IMAGE_RECORD: usize = 12;
    /// Byte offset of the image id within an image record; `cooked--image-id'.
    const IMAGE_ID: usize = 0;
    /// Byte offset of the cell row within an image record; `cooked--image-row'.
    const IMAGE_ROW: usize = 4;
    /// Byte offset of the cell column within an image record; `cooked--image-col'.
    const IMAGE_COL: usize = 6;
    /// Byte offset of the column span within an image record; `cooked--image-cols'.
    const IMAGE_COLS: usize = 8;
    /// Byte offset of the row span within an image record; `cooked--image-rows'.
    const IMAGE_ROWS: usize = 10;

    fn start(cell: DecoCell) -> Self {
        match cell {
            DecoCell::Glyph(g) => Self::Glyphs(vec![g]),
            DecoCell::Image(p) => Self::Images(vec![p]),
        }
    }

    /// Whether CELL is of this run's kind, and so may join it.
    fn accepts(&self, cell: DecoCell) -> bool {
        matches!(
            (self, cell),
            (Self::Glyphs(_), DecoCell::Glyph(_)) | (Self::Images(_), DecoCell::Image(_))
        )
    }

    /// Append CELL. The caller must have asked [`Deco::accepts`] first.
    fn push(&mut self, cell: DecoCell) {
        match (self, cell) {
            (Self::Glyphs(v), DecoCell::Glyph(g)) => v.push(g),
            (Self::Images(v), DecoCell::Image(p)) => v.push(p),
            // `accepts` is the guard; reaching here would mean a caller skipped it.
            _ => unreachable!("Deco::push without Deco::accepts"),
        }
    }

    pub fn len(&self) -> usize {
        match self {
            Self::Glyphs(v) => v.len(),
            Self::Images(v) => v.len(),
        }
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Append the run's decoration to OUT as the unibyte string Lisp decodes,
    /// little-endian throughout. `cooked--apply-deco' in lisp/cooked-deco.el is the only
    /// reader.
    ///
    /// Packed rather than a list of Lisp objects because every damaged row of every frame
    /// takes this path, and box drawing is what full-screen programs are made of. Emacs is
    /// the bottleneck -- the parser runs at 74-422 MB/s, the apply path at roughly 21 MB/s
    /// -- so nothing Rust already knows should be left for Lisp to rediscover. Appended
    /// rather than returned so that [`Block::push_deco`](crate::wire::Block::push_deco)
    /// can pack every decorated run of a frame into one reused buffer instead of
    /// allocating per run.
    ///
    /// **Glyphs** are `(bits: u16, count: u16)` per *run of identical shapes*: four bytes
    /// for a whole border row. The records of one run are its pattern, and Lisp bakes one
    /// bitmap for all of them -- `\u{251c}\u{2500}\u{2500}` is two records and one image three cells wide --
    /// so this string is also the key `cooked--box-glyph-image' is memoized on. That is
    /// why the encoding is canonical: a count is never zero and no two adjacent records
    /// share `bits`, so two runs that draw the same thing pack to the same bytes.
    ///
    /// [`BoxGlyph::BLANK`] draws nothing; [`Row::absorb_blank_runs`] puts it in the gaps
    /// of `\u{2502}   \u{2502}   \u{251c}\u{2500}\u{2500}`, so a `tree` row's whole indent is one run. It needs no
    /// tag of its own. No flag says a shape dithers either: run-length encoding already
    /// makes that a question per record rather than per character, and
    /// `cooked--box-shade-p' asks it.
    ///
    /// **Images** are one 12-byte record per character -- `(id: u32, cell_row: u16,
    /// cell_col: u16, cols: u16, rows: u16)`. Unlike a glyph run, a placement is not one
    /// decision repeated: every cell carries its own place in the picture, which is what
    /// lets per-cell addressing survive a scroll or a rewrap. Lisp coalesces the cells of a
    /// row into one `display' interval (see `cooked--apply-image-deco'), where the cost of
    /// `put-text-property' actually is, so a second run-shaped wire format would buy little.
    ///
    /// A glyph count is capped at [`u16::MAX`] by splitting the record, which no terminal
    /// width reaches, so the format is total.
    pub fn pack_into(&self, out: &mut Vec<u8>) {
        match self {
            Self::Glyphs(glyphs) => {
                out.reserve(glyphs.len().min(8) * Self::GLYPH_RECORD);
                let mut run: Option<(u16, u16)> = None;
                // Fields go in at [`Self::GLYPH_BITS`] then [`Self::GLYPH_COUNT`], which is
                // simply push order here; the offsets exist to be read back by
                // `cooked--wire-layout', not to steer this write.
                let flush = |out: &mut Vec<u8>, bits: u16, count: u16| {
                    out.extend_from_slice(&bits.to_le_bytes());
                    out.extend_from_slice(&count.to_le_bytes());
                    debug_assert_eq!(
                        out.len() % Self::GLYPH_RECORD,
                        0,
                        "a glyph record must be exactly {} bytes",
                        Self::GLYPH_RECORD
                    );
                };
                for glyph in glyphs {
                    let bits = glyph.bits();
                    run = match run {
                        Some((b, count)) if b == bits && count < u16::MAX => Some((b, count + 1)),
                        Some((b, count)) => {
                            flush(out, b, count);
                            Some((bits, 1))
                        }
                        None => Some((bits, 1)),
                    };
                }
                if let Some((bits, count)) = run {
                    flush(out, bits, count);
                }
            }
            Self::Images(places) => {
                out.reserve(places.len() * Self::IMAGE_RECORD);
                // Fields go in at [`Self::IMAGE_ID`], [`Self::IMAGE_ROW`],
                // [`Self::IMAGE_COL`], [`Self::IMAGE_COLS`] then [`Self::IMAGE_ROWS`], again
                // push order; see the glyph arm above.
                for place in places {
                    out.extend_from_slice(&place.id.get().to_le_bytes());
                    out.extend_from_slice(&place.cell_row.to_le_bytes());
                    out.extend_from_slice(&place.cell_col.to_le_bytes());
                    out.extend_from_slice(&place.cols.to_le_bytes());
                    out.extend_from_slice(&place.rows.to_le_bytes());
                    debug_assert_eq!(
                        out.len() % Self::IMAGE_RECORD,
                        0,
                        "an image record must be exactly {} bytes",
                        Self::IMAGE_RECORD
                    );
                }
            }
        }
    }

    /// [`Self::pack_into`], returned as an owned buffer for a test that wants to inspect
    /// or compare the bytes without a `Block` to hold the scratch space.
    #[cfg(test)]
    pub(crate) fn packed(&self) -> Vec<u8> {
        let mut out = Vec::new();
        self.pack_into(&mut out);
        out
    }

    /// A description of the decoration on character INDEX, for a test that compares what
    /// two sequences of runs draw character by character.
    #[doc(hidden)]
    pub fn at(&self, index: usize) -> Option<String> {
        match self {
            Self::Glyphs(glyphs) => glyphs.get(index).map(|g| format!("{g:?}")),
            Self::Images(places) => places.get(index).map(|p| format!("{p:?}")),
        }
    }

    /// The shapes, for tests that assert against the classifier's output.
    #[cfg(test)]
    pub(crate) fn glyphs(&self) -> &[BoxGlyph] {
        match self {
            Self::Glyphs(v) => v,
            other => panic!("expected a box-glyph run, got {other:?}"),
        }
    }
}

/// A styled run of text — the unit the Lisp side turns into propertized buffer text.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Run {
    pub text: String,
    /// Columns this run occupies on the grid, continuation cells included.
    ///
    /// Not derivable from `text` without redoing the grid's width classification: a wide
    /// character is one `char` on two columns and a combining mark a `char` on none.
    /// Accumulated as the run is built (see [`Row::build_plain_runs`]), and summed per row
    /// by `Block::push_runs` so Emacs need not call `string-width' on every rendered row;
    /// see `cooked--row-mismeasured-p'. It is also how an `OSC 66` declared width reaches
    /// Emacs.
    pub cols: Cols,
    /// The rendition, named in the store of whatever built the run.
    pub style: StyleId,
    /// One decoration per character in `text`, index-aligned with `text.chars()`;
    /// `None` for an ordinary text run. Never mixed with a `None` run, nor with a run
    /// of another kind, even when `style` matches — see [`Row::build_runs`].
    pub deco: Option<Deco>,
    /// The `OSC 8` hyperlink these characters are part of, if any.
    ///
    /// A run boundary in its own right, so a link opening without any change of rendition
    /// still splits the run. The id is what Lisp hangs a keymap on.
    pub link: Option<LinkId>,
}

impl Run {
    /// A description of the decoration on this run's character INDEX, for a test that
    /// compares what two sequences of runs draw character by character.
    #[doc(hidden)]
    pub fn deco_at(&self, index: usize) -> Option<String> {
        self.deco.as_ref().and_then(|deco| deco.at(index))
    }
}

/// A row's runs: every run's characters in one buffer, and one record per run.
///
/// What the drain builds per damaged row, per edited span and per row that scrolls off,
/// and what `Block::push_runs` copies into the text it hands Emacs. A `Vec<Run>` owned a
/// `String` per run, so a screen of `ls --color` cost an allocation per coloured word per
/// drain, and then a `chars().count()` scan per run on the way out, because nothing had
/// counted the characters while it had the cells. Here the characters are written once,
/// straight from the cells, and counted as they are written.
///
/// The spans tile the text in order and leave no gap, so a run's text is the stretch
/// between its own start and the next run's; see [`Runs::run`]. That is also what makes
/// merging two neighbouring runs free — the text of the merged run is already
/// contiguous — which [`Row::absorb_blank_runs`] does per glyph row.
///
/// [`Run`] is still the shape a test asserts against, and [`Runs::to_vec`] materialises
/// one per run.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Runs {
    /// Every run's characters, concatenated: the row's text.
    text: String,
    runs: Vec<Span>,
}

/// One run of a [`Runs`]: where its text begins, and what [`Run`] carries besides text.
///
/// Only a start, because a run ends where the next begins and the last ends at the text.
/// Storing the length instead would have to be maintained by a merge, which is otherwise
/// two removals and an addition.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Span {
    /// Byte offset into [`Runs::text`] of this run's first character.
    start: Bytes,
    /// Characters of this run's text, counted as they were pushed.
    ///
    /// The count `Block` needs for every style span and every offset it emits, which it
    /// used to rescan the string for.
    chars: Chars,
    /// Columns this run occupies on the grid; see [`Run::cols`].
    cols: Cols,
    style: StyleId,
    deco: Option<Deco>,
    link: Option<LinkId>,
}

/// One run of a [`Runs`], borrowed: what a [`Run`] says without owning its text.
///
/// `chars` is the field a [`Run`] has no room for, and the reason this is a struct rather
/// than a `&Run`: the count is a by-product of building the run, and every consumer of a
/// run wants it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RunRef<'a> {
    pub text: &'a str,
    /// Characters of `text`. Not `text.len()`, which counts bytes, nor `cols`, which
    /// counts grid columns: a wide character is one character on two columns and a
    /// combining mark one character on none.
    pub chars: Chars,
    pub cols: Cols,
    pub style: StyleId,
    pub deco: Option<&'a Deco>,
    pub link: Option<LinkId>,
}

impl RunRef<'_> {
    /// A description of the decoration on this run's character INDEX; see
    /// [`Run::deco_at`].
    #[doc(hidden)]
    pub fn deco_at(&self, index: usize) -> Option<String> {
        self.deco.and_then(|deco| deco.at(index))
    }

    /// Bytes `text` occupies, which is neither its characters nor its columns.
    pub fn bytes(&self) -> Bytes {
        Bytes::of(self.text)
    }

    /// Whether every character of this run stands on exactly one cell.
    ///
    /// Two units meet here, so it is a *question* about the run rather than arithmetic
    /// on it: false says the run holds a wide character, a combining mark, or an `OSC 66`
    /// declared width, any of which breaks a column-per-character reading of the text.
    /// `wire`'s `Uniformity` asks it of every run of a damaged row, and
    /// [`Row::absorb_blank_runs`] asks it of a gap it is about to swallow.
    pub fn one_cell_per_char(&self) -> bool {
        self.cols.get() == self.chars.get()
    }

    /// Whether every character of this run is a single byte, so that a byte offset into
    /// the text is also a character offset.
    ///
    /// The other side of the same question: it is what tells `wire`'s `Uniformity` that
    /// Emacs may read the row a byte per column.
    pub fn one_byte_per_char(&self) -> bool {
        self.bytes().get() == self.chars.get()
    }
}

impl Runs {
    /// Room for a row's text and the handful of runs a row usually has.
    ///
    /// COLS bytes, because for the ASCII a terminal mostly carries a column is a byte, and
    /// four runs for the reason [`Row::build_runs`] gives.
    fn with_cols(cols: usize) -> Self {
        Self {
            text: String::with_capacity(cols),
            runs: Vec::with_capacity(4),
        }
    }

    pub fn len(&self) -> usize {
        self.runs.len()
    }

    pub fn is_empty(&self) -> bool {
        self.runs.is_empty()
    }

    /// Every run's characters in order, which is the row's text; the equivalent of
    /// `runs.iter().map(|r| r.text).collect()` without the copy.
    pub fn text(&self) -> &str {
        &self.text
    }

    /// Characters over every run: what this puts in an Emacs buffer.
    pub fn chars(&self) -> Chars {
        self.runs.iter().map(|run| run.chars).sum()
    }

    /// Columns over every run: how much of the grid this covers, which is not its
    /// character count -- `日本` is four columns of two characters.
    pub fn cols(&self) -> Cols {
        self.runs.iter().map(|run| run.cols).sum()
    }

    /// Run INDEX, or `None` past the end.
    pub fn get(&self, index: usize) -> Option<RunRef<'_>> {
        let run = self.runs.get(index)?;
        Some(RunRef {
            text: self.text_between(run.start, self.end_of(index)),
            chars: run.chars,
            cols: run.cols,
            style: run.style,
            deco: run.deco.as_ref(),
            link: run.link,
        })
    }

    /// Run INDEX, which must be there; for a test naming a run by position.
    ///
    /// Panics rather than returning an `Option` because [`std::ops::Index`] cannot be
    /// implemented for a borrowed view, and `runs.run(0)` reads like the
    /// `runs[0]` it replaces.
    pub fn run(&self, index: usize) -> RunRef<'_> {
        self.get(index)
            .unwrap_or_else(|| panic!("run {index} of {} runs", self.runs.len()))
    }

    pub fn iter(&self) -> Iter<'_> {
        Iter {
            runs: self,
            at: 0,
            end: self.runs.len(),
        }
    }

    /// One owned [`Run`] per run, for a test asserting against run shapes.
    #[doc(hidden)]
    pub fn to_vec(&self) -> Vec<Run> {
        self.iter()
            .map(|run| Run {
                text: run.text.to_owned(),
                cols: run.cols,
                style: run.style,
                deco: run.deco.cloned(),
                link: run.link,
            })
            .collect()
    }

    /// These runs, from owned ones; for a test stating what it expects as [`Run`]s.
    #[doc(hidden)]
    pub fn from_runs(runs: &[Run]) -> Self {
        let mut built = Self::default();
        for run in runs {
            built.start(run.style, run.link, None);
            built.runs.last_mut().expect("just started").deco = run.deco.clone();
            built.push_str(&run.text);
            built.add_cols(run.cols);
        }
        built
    }

    /// Drop the last character of the last run that has one, and say what it was.
    ///
    /// For `delta_replay`, which stands in for Lisp trimming the trailing text of a row
    /// the cursor has left. The columns are left as they were, as they are in the buffer:
    /// what changed is the text, not how wide the grid said the row was.
    #[doc(hidden)]
    pub fn pop_char(&mut self) -> Option<char> {
        let ch = self.text.pop()?;
        let at = self
            .runs
            .iter()
            .rposition(|run| !run.chars.is_zero())
            .expect("text with no run holding it");
        self.runs[at].chars -= Chars::ONE;
        // Every run after it begins that many bytes earlier now.
        for run in &mut self.runs[at + 1..] {
            run.start -= Bytes::new(ch.len_utf8());
        }
        Some(ch)
    }

    /// Each run's rendition, link and decoration, to be rewritten in place.
    ///
    /// Not its text or its columns: those the builders own, and a consumer that needs
    /// other text builds other runs. `delta_replay` renumbers a delta's style, link and
    /// image ids into the ids the session it compares against handed out, which is what
    /// this is for -- all three are recycled, so two terminals fed the same bytes need
    /// not agree on any of them.
    #[doc(hidden)]
    pub fn ids_mut(
        &mut self,
    ) -> impl Iterator<Item = (&mut StyleId, &mut Option<LinkId>, Option<&mut Deco>)> {
        self.runs
            .iter_mut()
            .map(|run| (&mut run.style, &mut run.link, run.deco.as_mut()))
    }

    /// Where run INDEX's text ends: where the next begins, or the end of the text.
    fn end_of(&self, index: usize) -> Bytes {
        self.runs
            .get(index + 1)
            .map_or(Bytes::of(&self.text), |next| next.start)
    }

    /// The stretch of the text between two byte offsets, which are the only offsets that
    /// index it: the spans tile the text, so FROM and TO are always run boundaries and
    /// so always fall on character boundaries.
    fn text_between(&self, from: Bytes, to: Bytes) -> &str {
        &self.text[from.get()..to.get()]
    }

    /// Drop every run but keep the buffers, for a producer that fills one per round; see
    /// `Emission::clear`.
    pub(crate) fn clear(&mut self) {
        self.text.clear();
        self.runs.clear();
    }

    /// Whether the open run takes a cell of this pen and decoration, or a new run must
    /// begin.
    ///
    /// A link boundary splits a run even when nothing else changed: `see <link>foo</link>
    /// bar' in one colour is otherwise one run, with nothing to say which part is
    /// clickable. So does a change of decoration kind, which is what keeps a run's
    /// records one per character of one kind; see [`Deco`].
    fn joins(&self, style: StyleId, link: Option<LinkId>, deco: Option<DecoCell>) -> bool {
        self.runs.last().is_some_and(|run| {
            run.style == style
                && run.link == link
                && match (&run.deco, deco) {
                    (None, None) => true,
                    (Some(d), Some(c)) => d.accepts(c),
                    _ => false,
                }
        })
    }

    /// Begin a run in this pen, whatever the open one holds.
    ///
    /// For a producer that decides its own boundaries: the comint filter groups its
    /// columns before it pushes them, and keeps a newline in a run of its own whether or
    /// not the text before it was in the same rendition.
    pub(crate) fn start(&mut self, style: StyleId, link: Option<LinkId>, deco: Option<DecoCell>) {
        self.runs.push(Span {
            start: Bytes::of(&self.text),
            chars: Chars::ZERO,
            cols: Cols::ZERO,
            style,
            deco: deco.map(Deco::start),
            link,
        });
    }

    /// Append CH to the open run, counting it.
    pub(crate) fn push_char(&mut self, ch: char) {
        self.text.push(ch);
        if let Some(run) = self.runs.last_mut() {
            run.chars += Chars::ONE;
        }
    }

    /// Append TEXT to the open run, counting its characters as they are written.
    ///
    /// Zero-width characters ride here too -- the combining marks attached to a cell --
    /// which is why this adds no columns.
    pub(crate) fn push_str(&mut self, text: &str) {
        self.text.push_str(text);
        if let Some(run) = self.runs.last_mut() {
            run.chars += Chars::new(text.chars().count());
        }
    }

    /// Extend the open run with CHARS over COLS columns, or start one, for a stretch of
    /// undecorated cells.
    ///
    /// The characters are counted as they are written, which is the whole point: nothing
    /// downstream has to scan the text to learn how many there were.
    fn push_text(
        &mut self,
        chars: impl Iterator<Item = char>,
        cols: Cols,
        style: StyleId,
        link: Option<LinkId>,
    ) {
        if !self.joins(style, link, None) {
            self.start(style, link, None);
        }
        let Self { text, runs } = self;
        let run = runs.last_mut().expect("a run is open either way");
        for ch in chars {
            text.push(ch);
            run.chars += Chars::ONE;
        }
        run.cols += cols;
    }

    /// Credit COUNT columns to the open run without any text of their own.
    ///
    /// The continuation cells of a wide character, which belong to the column count of
    /// the run that owns the character; see [`Run::cols`].
    pub(crate) fn add_cols(&mut self, count: Cols) {
        if let Some(run) = self.runs.last_mut() {
            run.cols += count;
        }
    }

    /// One cell into the runs: its character, the combining MARKS riding it, and the DECO
    /// it draws instead of its glyph.
    ///
    /// One look at the open run for the whole cell rather than one per field it touches:
    /// this is the per-cell path, and it runs over as many cells as the grid is wide.
    /// DECO is this one character's, and its record joins the run here.
    fn push_cell(&mut self, cell: &Cell, marks: Option<&str>, deco: Option<DecoCell>) {
        let joined = self.joins(cell.style(), cell.link(), deco);
        if !joined {
            self.start(cell.style(), cell.link(), deco);
        }
        let Self { text, runs } = self;
        let run = runs.last_mut().expect("a run is open either way");
        // `start` already filed the first record; a run that was joined needs this one.
        if joined
            && let Some(cell) = deco
            && let Some(records) = &mut run.deco
        {
            records.push(cell);
        }
        text.push(cell.ch());
        run.chars += Chars::ONE;
        run.cols += Cols::ONE;
        // A cell carrying marks is undecorated (see `decoration`), so the marks never land
        // inside a decorated run, whose records are one per character.
        if let Some(marks) = marks {
            text.push_str(marks);
            run.chars += Chars::new(marks.chars().count());
        }
    }
}

/// Walks a [`Runs`] left to right, which is the only order anything reads runs in.
pub struct Iter<'a> {
    runs: &'a Runs,
    at: usize,
    end: usize,
}

impl<'a> Iterator for Iter<'a> {
    type Item = RunRef<'a>;

    fn next(&mut self) -> Option<Self::Item> {
        let run = self.runs.get(self.at).filter(|_| self.at < self.end)?;
        self.at += 1;
        Some(run)
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        let left = self.end - self.at;
        (left, Some(left))
    }
}

impl DoubleEndedIterator for Iter<'_> {
    fn next_back(&mut self) -> Option<Self::Item> {
        self.end = self.end.checked_sub(1).filter(|at| *at >= self.at)?;
        self.runs.get(self.end)
    }
}

impl ExactSizeIterator for Iter<'_> {}

impl<'a> IntoIterator for &'a Runs {
    type Item = RunRef<'a>;
    type IntoIter = Iter<'a>;

    fn into_iter(self) -> Self::IntoIter {
        self.iter()
    }
}

/// How many semantic marks one row will hold before the oldest is dropped.
///
/// Eight covers the real shapes several times over -- a prompt row carries the previous
/// command's `D' and the new prompt's `A', `B' and `C', and a reprinted prompt can double
/// that -- while keeping the whole grid's worth bounded at a few hundred entries. See
/// [`Row::mark`] for why a bound is needed at all.
pub(crate) const MARKS_PER_ROW: usize = 8;

super::intern::dense_id! {
    /// The wire name for one OSC 133 semantic mark, so Emacs can be told where a mark it
    /// already holds a buffer marker for has *moved* to.
    ///
    /// A counter rather than anything derived from the position, because the position is
    /// what a rewrap changes. Handed out in `term::State`, stored only in [`Extra::Mark`], and
    /// never reused; see `Delta::marks` for the round trip.
    pub struct MarkId;
}

/// Something attached to one column that is too rare to live in a [`Cell`].
///
/// One enum rather than a side table per feature, so that every edit -- an overwrite,
/// ICH and DCH, a rewrap -- maintains every kind of attachment through the same code.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Extra {
    /// Zero-width characters — combining marks, variation selectors — riding the cell.
    Marks(Box<str>),
    /// One cell of a transmitted image.
    Image(Placement),
    /// An OSC 133 semantic mark that fell on this cell.
    ///
    /// The others describe how the cell is *drawn*; this is a position in the byte stream
    /// that happened to fall here. It rides a cell so that everything which moves a cell
    /// moves the mark: after a rewrap the mark is still on its cell, and the drain reports
    /// where that cell is now.
    ///
    /// Never read by the renderer. [`Row::build_runs`] ignores it, `is_content` says no,
    /// and no [`Run`] carries it -- the only consumer is `State::marks_in`.
    Mark(MarkId),
}

/// Per-column attachments for one row, in column order.
///
/// Sorted because every consumer walks columns in order: [`Row::build_runs`] reads left
/// to right, a rewrap rebases a contiguous range, and an erase prunes one. A sorted
/// vector answers all three in a single pass, which an unsorted one cannot, and keeps
/// insertion an append for the common case of a row being filled left to right.
///
/// Empty is not representable: [`Row`] holds `Option<Box<Extras>>` and drops back to
/// `None` the moment the last entry goes, so "has this row any attachments at all" stays
/// a null check on a pointer already in cache.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct Extras {
    entries: Vec<(u16, Extra)>,
}

impl Extra {
    /// Whether this changes how its cell is drawn, and so whether the run builders have
    /// to read it.
    ///
    /// A semantic mark does not: it is a position in the byte stream that happened to
    /// fall on a cell, and no [`Run`] carries it. That matters because marks are the
    /// common attachment -- a prompt row carries four of them -- and a row whose only
    /// attachments are marks can take the fast builder; see [`Row::runs_from`].
    pub fn draws(&self) -> bool {
        match self {
            Self::Marks(_) | Self::Image(_) => true,
            Self::Mark(_) => false,
        }
    }

    /// Whether this makes its cell content, as opposed to decoration of a cell that
    /// would otherwise be blank.
    ///
    /// The distinction `content_len`, [`Row::has_text`] and [`Row::is_blank`] turn on.
    /// A combining mark is text — dropping it loses a character.
    pub fn is_content(&self) -> bool {
        match self {
            Self::Marks(_) => true,
            // An image cell is a blank in the default style, so without this the row it
            // sits on measures as empty: trimmed off the end by `Row::content_len`,
            // judged textless by `Row::has_text`, absorbed by `Row::is_blank`. This is
            // the case the whole `is_content` distinction exists for.
            Self::Image(_) => true,
            // Not content. A prompt mark routinely lands on a blank cell -- an `A' arrives
            // before the prompt is printed -- and counting it would keep blank rows alive
            // across every resize.
            Self::Mark(_) => false,
        }
    }
}

impl Extras {
    pub(crate) fn entries(&self) -> &[(u16, Extra)] {
        &self.entries
    }

    fn insert(&mut self, col: usize, extra: Extra) {
        let at = self
            .entries
            .partition_point(|(c, _)| usize::from(*c) <= col);
        self.entries.insert(at, (col as u16, extra));
    }

    /// Drop the attachments on the columns in `range`, `marks` deciding the exception.
    fn prune(&mut self, range: impl std::ops::RangeBounds<usize>, marks: Marks) {
        self.entries
            .retain(|(at, extra)| !range.contains(&usize::from(*at)) || marks.keeps(extra));
    }

    /// Move every attachment from `col` onward by `by`, dropping what falls off `cols`.
    ///
    /// The arithmetic ICH and DCH owe their attachments. Dropping the tables wholesale is
    /// the tempting shortcut and is wrong: DCH would lose colours on columns it never
    /// touched. `Logical::take_front` shifts the same way for the rewrap.
    fn shift(&mut self, from: usize, by: isize, cols: usize) {
        self.entries.retain_mut(|(at, _)| {
            let here = usize::from(*at);
            if here < from {
                return true;
            }
            match here.checked_add_signed(by) {
                Some(moved) if moved < cols => {
                    *at = moved as u16;
                    true
                }
                // Off the end of the row, or off the front of it.
                _ => false,
            }
        });
        // No re-sort: every entry from `col` on moves by the same amount and everything
        // below it stays put, so a sorted table comes out sorted.
    }
}

/// Whether a prune spares semantic marks.
///
/// [`Marks::Keep`] is the path an erase takes. A shell redraws its prompt line with
/// `CSI K` on every keystroke, and an erase removes the *drawing*, not a position in the
/// byte stream that happens to be at this column.
///
/// [`Marks::Drop`] is for the one case where the column itself ceases to exist.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Marks {
    Keep,
    Drop,
}

impl Marks {
    /// Whether EXTRA survives a prune of the column it is on.
    ///
    /// The one statement of the exception. [`Row::retire`] tests it inline rather than
    /// calling here, for the reason its own doc comment gives.
    fn keeps(self, extra: &Extra) -> bool {
        matches!(self, Self::Keep) && matches!(extra, Extra::Mark(_))
    }
}

/// Whether a row's logical line goes on below it, and if so how much of the row is text.
///
/// The row below continues the line in both wrapped cases; they differ in what the last
/// columns of *this* row hold. A row fills up and the next character starts the row below
/// ([`Wrap::Full`]), or a wide character will not fit in the columns left and moves down
/// whole, leaving them blank ([`Wrap::Early`]): `日本語` on a five-column screen puts
/// `語` on the row below and leaves column 4 untouched. That blank is padding and not a
/// space the child wrote, so [`Row::line_len`] leaves it out of the line, and a rewrap
/// nine columns wide reads `日本語` rather than `日本 語`.
///
/// A row that wrapped early cannot be told from one that did not by looking at its cells:
/// `abcd 語` at five columns is [`Wrap::Full`] and *its* trailing blank is the child's
/// own space, which must survive the same rewrap.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Wrap {
    /// The line ends here: the row below begins a new one.
    #[default]
    No,
    /// The line goes on below, and every column of this row belongs to it.
    Full,
    /// The line goes on below, and the last COLS columns are the room a wide character
    /// could not fit into. Always at least one column and always fewer than the width of
    /// the character that moved down.
    Early(Cols),
}

impl Wrap {
    /// A row whose line goes on below with PAD columns of padding at its end.
    ///
    /// Named rather than written out at each call site because no padding and a full row
    /// are the same row: a chunk that happens to end exactly at the last column is
    /// [`Wrap::Full`], and only a shorter one is [`Wrap::Early`].
    pub fn wrapping(pad: Cols) -> Self {
        if pad.is_zero() {
            Self::Full
        } else {
            Self::Early(pad)
        }
    }

    /// Whether the line continues on the row below, which is what most readers ask.
    pub const fn wraps(self) -> bool {
        !matches!(self, Self::No)
    }
}

/// What a row carries besides its cells: the rarities attached to single columns, and
/// whether its line goes on below.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct RowMeta {
    /// Combining marks, image placements and semantic marks: what is attached to a single
    /// column and cannot be a field of [`Cell`].
    ///
    /// All of it is rare, and each kind carries more than a cell has room for -- a string
    /// of marks, a placement's rectangle -- or, for a semantic mark, is not drawn at all.
    ///
    /// Boxed, because a row's metadata is small and fixed-size that way, which keeps the
    /// per-slot table in `Screen` dense: `Option<Box<Extras>>` is one null-optimised
    /// pointer, 8 bytes.
    ///
    /// `None` whenever there is nothing attached, which is almost always, so
    /// [`Row::runs`] can specialise on a null check instead of asking per cell.
    extras: Option<Box<Extras>>,
    /// Whether the row's logical line continues on the row below, and how much of the row
    /// that line covers.
    wrap: Wrap,
}

/// A single line of the terminal: cells, and the [`RowMeta`] that goes with them.
///
/// Generic over where the two live, because the grid does not keep rows as objects. A
/// `Screen` holds every cell of the screen in one contiguous buffer and every row's
/// metadata in a table beside it, and lends a row out as a [`RowRef`] or [`RowMut`]
/// borrowing a slice of each. [`Row`] is the owned form, for rows that are not on a grid:
/// the ones a rewrap re-chunks, and the tests. Every method is written once, against the
/// borrowed shapes, so all three behave identically by construction.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct RowOf<C, M> {
    cells: C,
    meta: M,
}

/// A row that owns its cells.
pub(crate) type Row = RowOf<Vec<Cell>, RowMeta>;
/// A row of a grid, read-only.
pub(crate) type RowRef<'a> = RowOf<&'a [Cell], &'a RowMeta>;
/// A row of a grid, for writing.
pub(crate) type RowMut<'a> = RowOf<&'a mut [Cell], &'a mut RowMeta>;

impl<'a> RowRef<'a> {
    pub(crate) fn from_slices(cells: &'a [Cell], meta: &'a RowMeta) -> Self {
        Self { cells, meta }
    }

    /// [`RowOf::marks`] for a borrowed grid row, living as long as the grid rather than
    /// as long as this view of it, so that an iterator over rows can yield them.
    pub fn into_marks(self) -> impl Iterator<Item = (Cols, MarkId)> + 'a {
        self.meta
            .extras
            .as_deref()
            .map_or(&[][..], Extras::entries)
            .iter()
            .filter_map(|(at, extra)| match extra {
                Extra::Mark(id) => Some((Cols::new(usize::from(*at)), *id)),
                _ => None,
            })
    }
}

impl<'a> RowMut<'a> {
    pub(crate) fn from_slices(cells: &'a mut [Cell], meta: &'a mut RowMeta) -> Self {
        Self { cells, meta }
    }
}

impl Row {
    pub fn new(cols: usize) -> Self {
        Self {
            cells: vec![Cell::default(); cols],
            meta: RowMeta::default(),
        }
    }

    /// Assemble a row from cells already laid out, for the reflow in `Screen::resize`.
    ///
    /// EXTRAS are keyed by column within CELLS, which is what a rewrap produces once a
    /// logical line has been re-chunked: the offsets are recomputed per chunk rather than
    /// carried from the row the cells came off. They must arrive in column order.
    pub fn from_parts(cells: Vec<Cell>, extras: Vec<(u16, Extra)>, wrap: Wrap) -> Self {
        Self {
            cells,
            meta: RowMeta {
                extras: (!extras.is_empty()).then(|| Box::new(Extras { entries: extras })),
                wrap,
            },
        }
    }

    /// The one place a mark is dropped by anything short of the row itself going: past
    /// `cols` there is no longer a cell for it to be attached to. Only the non-rewrapping
    /// paths reach here -- the alternate screen, and a `Resize::Clamp` -- and neither has
    /// buffer text under it for a mark to be describing.
    pub fn resize(&mut self, cols: usize, style: StyleId) {
        // A wide character across the new edge would keep its lead and lose the rest.
        self.clear_torn(cols, cols);
        self.cells.resize(cols, Cell::blank(style));
        self.prune(cols.., Marks::Drop);
    }

    /// A row from cells and the metadata that goes with them, for a grid handing its rows
    /// out whole.
    pub(crate) fn from_meta(cells: Vec<Cell>, meta: RowMeta) -> Self {
        Self { cells, meta }
    }

    /// This row, borrowed as a grid row would be.
    pub fn as_ref(&self) -> RowRef<'_> {
        RowRef::from_slices(&self.cells, &self.meta)
    }

    /// The parts of this row, for storing it into a grid.
    pub(crate) fn into_parts(self) -> (Vec<Cell>, RowMeta) {
        (self.cells, self.meta)
    }
}

impl<C: Borrow<[Cell]>, M: Borrow<RowMeta>> RowOf<C, M> {
    fn meta(&self) -> &RowMeta {
        self.meta.borrow()
    }

    /// Whether this row's logical line continues on the row below.
    pub fn wrapped(&self) -> bool {
        self.wrap().wraps()
    }

    /// How this row's line ends, padding included; see [`Wrap`].
    pub fn wrap(&self) -> Wrap {
        self.meta().wrap
    }

    pub fn extras(&self) -> &[(u16, Extra)] {
        self.meta().extras.as_deref().map_or(&[], Extras::entries)
    }

    /// Every semantic mark on this row, in column order.
    pub fn marks(&self) -> impl Iterator<Item = (Cols, MarkId)> + '_ {
        self.extras().iter().filter_map(|(at, extra)| match extra {
            Extra::Mark(id) => Some((Cols::new(usize::from(*at)), *id)),
            _ => None,
        })
    }

    pub fn cells(&self) -> &[Cell] {
        self.cells.borrow()
    }

    pub fn len(&self) -> usize {
        self.cells().len()
    }

    pub fn is_empty(&self) -> bool {
        self.cells().is_empty()
    }

    pub fn get(&self, col: usize) -> Option<&Cell> {
        self.cells().get(col)
    }

    /// Whether the row holds any text, as opposed to only a background wash.
    ///
    /// Distinct from `is_blank` because of `bce`: a row a full-screen program painted and
    /// cleared carries a background in every cell, but archiving it would push a screenful
    /// of pure colour into the scrollback.
    pub fn has_text(&self) -> bool {
        self.extras().iter().any(|(_, e)| e.is_content())
            || self.cells().iter().any(|c| c.ch() != BLANK)
    }

    /// Whether the row holds nothing a resize would need to preserve.
    ///
    /// Stricter than [`Row::has_text`] on purpose: a resize must keep a background wash,
    /// so a washed row is not blank even though it holds no text.
    pub fn is_blank(&self) -> bool {
        !self.extras().iter().any(|(_, e)| e.is_content())
            && self
                .cells()
                .iter()
                .all(|c| c.ch() == BLANK && c.is_default_style())
    }

    /// Columns up to the last one holding something, trailing default-styled blanks cut.
    ///
    /// The one definition of "trailing blank" in the crate: `runs` renders by it and
    /// `Screen::resize` measures logical lines by it, so a rewrap cannot disagree with
    /// what was on screen. A blank whose style is not the default is content — it is a
    /// coloured bar drawn to the edge, and trimming it would erase the drawing.
    ///
    /// It answers "where does this *line* end", which is why a continuation row is exempt:
    /// its trailing blanks are interior to a line that ends somewhere below. See
    /// [`Row::line_runs`].
    pub fn content_len(&self) -> usize {
        let cells = Cell::content_len(self.cells());
        // An attachment can be the last content on the row while its cell is a default
        // blank -- a combining mark on a space, or an image cell, which always is one.
        if self.meta().extras.is_none() {
            return cells;
        }
        self.extras()
            .iter()
            .rev()
            .find(|(_, e)| e.is_content())
            .map_or(cells, |(at, _)| cells.max(usize::from(*at) + 1))
    }

    /// Characters of this row's text before the character at column COL; see
    /// [`chars_before`].
    pub fn chars_before(&self, col: Cols) -> Chars {
        chars_before(self.cells(), self.extras().iter(), col)
    }

    /// Style-grouped runs with trailing default-styled blanks trimmed.
    ///
    /// Dispatches on whether the row has a side table: [`Row::build_plain_runs`] for
    /// nearly every row, [`Row::build_runs`] otherwise. This is the hottest read in the
    /// emulator, and a per-cell lookup cost about 2% of the full-screen repaint benchmark.
    pub fn runs(&self) -> Runs {
        self.runs_to(self.content_len())
    }

    /// Columns this row contributes to its logical line; see [`Row::line_runs`].
    ///
    /// The line ending here, it is the row's content, trailing blanks cut. A row that
    /// wrapped full contributes every column, including the blanks the child left before
    /// the line went on below. A row a wide character wrapped early stops short of the
    /// padding that character left — unless something was written there after the wrap, in
    /// which case those columns are content like any other and are kept: never fewer
    /// columns than [`Row::content_len`] holds.
    pub fn line_len(&self) -> usize {
        match self.wrap() {
            Wrap::No => self.content_len(),
            Wrap::Full => self.len(),
            Wrap::Early(pad) => self.content_len().max(self.len().saturating_sub(pad.get())),
        }
    }

    /// Runs for a row on its way into the buffer as part of a logical line.
    ///
    /// A continuation row contributes every column it holds: its trailing blanks are
    /// interior to a line that goes on below, and trimming them would pull the
    /// continuation forward. [`Logical::push_row`](super::screen) measures rows the same
    /// way during a rewrap, through [`Row::line_len`], and the two must agree for a resize
    /// to round-trip.
    pub fn line_runs(&self) -> Runs {
        self.runs_to(self.line_len())
    }

    /// The simplest correct statement of what [`Row::runs_to`] must produce.
    ///
    /// A reference implementation for `runs_to_matches_the_reference` to check the fast
    /// builders against. They are the hottest read in the emulator and so the most
    /// tempting to optimise, and an optimisation needs something to be equivalent to.
    ///
    /// An independent formulation rather than a copy -- it searches per column where the
    /// builders walk a cursor, and it materialises a [`Run`] where they write into one
    /// buffer -- so the two cannot share a mistake. It stops where the builders stop: the
    /// test composes [`Row::absorb_blank_runs`] onto it.
    #[cfg(test)]
    pub(crate) fn runs_to_reference(&self, end: usize) -> Vec<Run> {
        let entries: &[(u16, Extra)] = self.meta().extras.as_deref().map_or(&[], |e| &e.entries);
        let mut runs: Vec<Run> = Vec::new();
        for (col, cell) in self.cells()[..end].iter().enumerate() {
            if cell.is_continuation() {
                // The column still belongs to the wide character before it, and so to
                // that character's run: `cols` counts columns, not characters.
                if let Some(run) = runs.last_mut() {
                    run.cols += Cols::ONE;
                }
                continue;
            }
            let (mut marks, mut placed) = (None, None);
            for (_, extra) in entries.iter().filter(|(at, _)| usize::from(*at) == col) {
                match extra {
                    Extra::Marks(text) => marks = Some(&**text),
                    Extra::Image(p) => placed = Some(*p),
                    Extra::Mark(_) => {}
                }
            }
            let deco = match (marks, placed) {
                (Some(_), _) => None,
                (None, Some(placement)) => Some(DecoCell::Image(placement)),
                (None, None) => DecoCell::classify(cell.ch()),
            };
            let joins = runs.last().is_some_and(|run| {
                run.style == cell.style()
                    && run.link == cell.link()
                    && match (&run.deco, deco) {
                        (None, None) => true,
                        (Some(d), Some(c)) => d.accepts(c),
                        _ => false,
                    }
            });
            if joins {
                let run = runs.last_mut().expect("joins implies a last run");
                run.text.push(cell.ch());
                run.cols += Cols::ONE;
                if let (Some(d), Some(c)) = (&mut run.deco, deco) {
                    d.push(c);
                }
            } else {
                runs.push(Run {
                    text: String::from(cell.ch()),
                    cols: Cols::ONE,
                    style: cell.style(),
                    deco: deco.map(Deco::start),
                    link: cell.link(),
                });
            }
            if let (Some(marks), Some(run)) = (marks, runs.last_mut()) {
                run.text.push_str(marks);
            }
        }
        runs
    }

    /// Runs for the columns START..END alone, as they would render if the row began at
    /// START.
    ///
    /// What a span edit sends: the replacement for part of a row Emacs already holds. The
    /// caller chooses START and END on whole cells and outside any box-glyph run, so the
    /// runs here are the same characters, renditions and decorations the full row's runs
    /// carry over those columns; only where a run happens to be cut differs.
    pub(crate) fn runs_between(&self, start: Cols, end: Cols) -> Runs {
        let end = end.get().min(self.len());
        self.runs_from(start.get().min(end), end)
    }

    fn runs_to(&self, end: usize) -> Runs {
        self.runs_from(0, end)
    }

    /// The builders over the columns START..END, and the blank absorption they share.
    ///
    /// The range is a slice of the row's own cells and a slice of its own attachment
    /// table, rather than a row built out of copies of both: an edit sends a span of a
    /// row on every frame a spinner turns, and it was paying `cols` cells and a clone of
    /// every attachment for the privilege of numbering columns from zero.
    fn runs_from(&self, start: usize, end: usize) -> Runs {
        let cells = &self.cells()[start..end];
        // Sorted by column, so the attachments inside the range are a subslice of the
        // table; see [`Extras`].
        let entries: &[(u16, Extra)] = self.meta().extras.as_deref().map_or(&[], |extras| {
            let from = extras
                .entries
                .partition_point(|(at, _)| usize::from(*at) < start);
            let to = extras
                .entries
                .partition_point(|(at, _)| usize::from(*at) < end);
            &extras.entries[from..to]
        });
        let mut runs = if entries.iter().any(|(_, extra)| extra.draws()) {
            Self::build_runs(cells, entries, start)
        } else {
            // Nothing attached, or nothing attached that the builders would read: a row
            // carrying only semantic marks renders exactly as a bare row, and an `OSC 133`
            // prompt puts several on every prompt row.
            Self::build_plain_runs(cells)
        };
        Self::absorb_blank_runs(&mut runs);
        runs
    }

    /// Merge `GLYPHS BLANKS GLYPHS` into one box-glyph run, blanks and all.
    ///
    /// A run breaks on any undecorated cell and a space classifies to nothing, so
    /// `\u{2502}   \u{2502}   \u{251c}\u{2500}\u{2500}` would cost Emacs three `display` intervals for one `tree` row's
    /// indent -- 2.84 decoration records per row over `tree -C /usr/include`, where a row
    /// wants one. Absorbing the gap as [`BoxGlyph::BLANK`] cells makes it one run.
    ///
    /// **Only a gap between two glyph runs is absorbed.** A trailing blank run is never
    /// taken, because [`Row::line_runs`] hands a wrapped row its full width, and the
    /// padding would otherwise be baked into a bitmap nobody sees. The three runs must
    /// also agree on `style` and `link`, as adjacent glyph runs would.
    ///
    /// A post-pass rather than a rule inside each builder, because per cell it needs a
    /// variable-length lookahead, while over runs it is a window of three.
    fn absorb_blank_runs(runs: &mut Runs) {
        let blank_gap = |runs: &Runs, index: usize| {
            let run = runs.run(index);
            run.deco.is_none()
                // Combining marks push characters onto a run's text that stand on no
                // column, so a run with more characters than columns is carrying something
                // other than the blanks it looks like.
                && run.one_cell_per_char()
                && !run.chars.is_zero()
                && run.text.chars().all(draws_nothing)
        };
        let mut i = 0;
        while i + 2 < runs.len() {
            let joins = matches!(runs.runs[i].deco, Some(Deco::Glyphs(_)))
                && matches!(runs.runs[i + 2].deco, Some(Deco::Glyphs(_)))
                && blank_gap(runs, i + 1)
                && runs.runs[i].style == runs.runs[i + 1].style
                && runs.runs[i].style == runs.runs[i + 2].style
                && runs.runs[i].link == runs.runs[i + 1].link
                && runs.runs[i].link == runs.runs[i + 2].link;
            if !joins {
                i += 1;
                continue;
            }
            // Two at a time, and `i` does not advance: the run that just grew is the left
            // half of the next window, so `\u{2502}   \u{2502}   \u{251c}\u{2500}\u{2500}` collapses in one pass.
            //
            // The text is not touched. The three runs are already neighbours in it, so
            // dropping the records is the whole merge -- where a `Vec<Run>` had to copy
            // two strings into the first run's.
            let next = runs.runs.remove(i + 2);
            let tail = runs.runs.remove(i + 1);
            let run = &mut runs.runs[i];
            run.chars += tail.chars + next.chars;
            run.cols += tail.cols + next.cols;
            let (Some(Deco::Glyphs(glyphs)), Some(Deco::Glyphs(more))) = (&mut run.deco, next.deco)
            else {
                unreachable!("the match above admitted only two glyph runs");
            };
            glyphs.extend(std::iter::repeat_n(BoxGlyph::BLANK, tail.cols.get()));
            glyphs.extend(more);
        }
    }

    /// [`Row::build_runs`] for a row with nothing attached, which is nearly every row.
    ///
    /// With no attachments there are no combining marks and no image placements, so the
    /// only things that can end a run are the pen -- rendition or link -- changing and a
    /// character that draws a shape. That collapses the per-cell decision the general form has to make
    /// into a scan for the end of the run, after which the whole span is appended at once
    /// -- one join test and one column-count update per *run* instead of per cell.
    ///
    /// `runs_to_matches_the_reference` checks it against `Row::runs_to_reference` over
    /// randomised rows, including the wide characters and box glyphs a wrong scan would
    /// mishandle.
    fn build_plain_runs(cells: &[Cell]) -> Runs {
        let mut runs = Runs::with_cols(cells.len());
        let mut col = 0;
        while col < cells.len() {
            let cell = &cells[col];
            // A continuation cell belongs to the wide character before it and contributes
            // no text of its own, so it can neither start a run nor end one.
            if cell.is_continuation() {
                // Reachable only after a decorated cell, which is taken one at a time
                // and so does not absorb the continuations the bulk scan below does.
                // Credited to the run that owns the character regardless, so that this
                // and `Row::runs_to_reference` count the same columns.
                runs.add_cols(Cols::ONE);
                col += 1;
                continue;
            }
            let pen = *cell;
            let start = col;
            let deco = DecoCell::classify(cell.ch());
            col += 1;
            // A decorated cell is taken one at a time: consecutive box glyphs join only if
            // `Deco::accepts` says so, which is a per-character question the bulk path
            // cannot ask. Plain text -- the case this function exists for -- runs on.
            if deco.is_some() {
                runs.push_cell(cell, None, deco);
                continue;
            }
            while col < cells.len() {
                let next = &cells[col];
                if !next.is_continuation()
                    && (!next.same_pen(pen) || DecoCell::classify(next.ch()).is_some())
                {
                    break;
                }
                col += 1;
            }
            runs.push_text(
                cells[start..col]
                    .iter()
                    .filter(|c| !c.is_continuation())
                    .map(|c| c.ch()),
                // Every cell of the span, continuations included: the scan above ran to
                // `col` over columns, and that span is the run's width.
                Cols::new(col - start),
                pen.style(),
                pen.link(),
            );
        }
        runs
    }

    /// The row's cells as runs, for a row that has attachments to read.
    ///
    /// A row with nothing attached that draws goes to [`Row::build_plain_runs`] instead,
    /// so ENTRIES always holds something this has to read. It is walked with a cursor
    /// rather than searched per column, so the whole row costs one pass over the table.
    /// BASE is the column CELLS begins at, which the entries are still numbered from.
    fn build_runs(cells: &[Cell], entries: &[(u16, Extra)], base: usize) -> Runs {
        let mut runs = Runs::with_cols(cells.len());
        let mut at = 0;
        for (col, cell) in cells.iter().enumerate() {
            if cell.is_continuation() {
                // A column of the wide character that opened it, hence of its run.
                runs.add_cols(Cols::ONE);
                continue;
            }
            let mut marks = None;
            let mut placed = None;
            while at < entries.len() && usize::from(entries[at].0) - base < col {
                at += 1;
            }
            for (_, extra) in entries[at..]
                .iter()
                .take_while(|(c, _)| usize::from(*c) - base == col)
            {
                match extra {
                    Extra::Marks(text) => marks = Some(&**text),
                    Extra::Image(p) => placed = Some(*p),
                    // Nothing to draw and nothing to split a run on: a mark is a
                    // position, not a property of the characters.
                    Extra::Mark(_) => {}
                }
            }
            runs.push_cell(cell, marks, decoration(cell, marks, placed));
        }
        runs
    }

    pub fn to_text(&self) -> String {
        self.runs().text().to_owned()
    }
}

impl<C: BorrowMut<[Cell]>, M: BorrowMut<RowMeta>> RowOf<C, M> {
    fn cells_mut(&mut self) -> &mut [Cell] {
        self.cells.borrow_mut()
    }

    fn meta_mut(&mut self) -> &mut RowMeta {
        self.meta.borrow_mut()
    }

    /// Set how this row's line ends, returning what it was; see [`Wrap`].
    pub fn set_wrap(&mut self, wrap: Wrap) -> Wrap {
        std::mem::replace(&mut self.meta_mut().wrap, wrap)
    }

    /// Attach EXTRA to COL, in addition to whatever is already there.
    fn attach(&mut self, col: usize, extra: Extra) {
        self.meta_mut()
            .extras
            .get_or_insert_with(Default::default)
            .insert(col, extra);
    }

    /// Edit the side table, dropping it if the edit empties it.
    ///
    /// The one statement of the invariant `Row` rests on: an empty table is `None`, never
    /// `Some` of an empty `Extras`. [`Row::runs`] specialises on the null check, so a table
    /// left `Some` but empty would silently cost the fast path.
    fn edit_extras(&mut self, f: impl FnOnce(&mut Extras)) {
        if let Some(extras) = &mut self.meta_mut().extras {
            f(extras);
            if extras.entries.is_empty() {
                self.meta_mut().extras = None;
            }
        }
    }

    /// Drop the attachments on the columns in RANGE, `marks` deciding the exception.
    fn prune(&mut self, range: impl std::ops::RangeBounds<usize>, marks: Marks) {
        self.edit_extras(|extras| extras.prune(range, marks));
    }

    /// [`Row::prune`] for exactly one column, out of line and marked cold.
    ///
    /// `Row::set` is the per-character write path and has to stay straight-line code.
    /// Calling `prune` with a `RangeInclusive` cost about 4% of the full-screen repaint
    /// benchmark, because the optimiser built the range before testing whether the row had
    /// any attachments at all.
    ///
    /// A semantic mark is kept. `OSC 133;A' arrives *before* the shell prints its prompt,
    /// so the mark lands on a cell about to be written, and retiring it there would lose it
    /// at once.
    #[cold]
    #[inline(never)]
    fn retire(&mut self, col: usize) {
        self.edit_extras(|extras| {
            extras
                .entries
                .retain(|(at, extra)| usize::from(*at) != col || matches!(extra, Extra::Mark(_)));
        });
    }

    /// Attach a semantic mark to `col`, without disturbing anything already there.
    ///
    /// Several marks on one cell is normal: `OSC 133;B' and `;C' land on the same cell when
    /// the shell submits an empty line, and each names a different record in Emacs, so
    /// none replaces another.
    ///
    /// Bounded per row at [`MARKS_PER_ROW`], oldest first, because nothing else bounds it:
    /// a mark is never retired by what is drawn over it, so a child emitting `OSC 133'
    /// without moving off the row would grow the table without limit and turn a linear
    /// feed quadratic, as the `osc_dispatch' benchmark does.
    pub fn mark(&mut self, col: Cols, id: MarkId) {
        let col = col.get();
        if col >= self.cells().len() {
            return;
        }
        // Guarded on the table's own length first, which is a load and a compare: there
        // cannot be `MARKS_PER_ROW` marks in fewer than that many entries, so an ordinary
        // row -- a prompt's four marks, an underline colour, a link -- never reaches the
        // scan below at all. Without the guard the count is paid per mark, and the
        // `osc_dispatch' benchmark is nothing but marks.
        if let Some(extras) = &mut self.meta_mut().extras
            && extras.entries.len() >= MARKS_PER_ROW
            && Self::evict_oldest_mark(extras, col, id)
        {
            return;
        }
        self.attach(col, Extra::Mark(id));
    }

    /// Make room for one more mark on a row that is at [`MARKS_PER_ROW`], returning
    /// whether the new mark has already been written in place.
    ///
    /// Out of line and cold: an ordinary row never reaches it, only a child emitting
    /// `OSC 133' over and over without moving the cursor.
    ///
    /// The oldest goes, as the one whose record Emacs is least likely to still hold. Ids
    /// are in stream order while entries are in column order, so this looks for the
    /// smallest id. When that entry is on this very column -- the runaway case -- it is
    /// overwritten in place, keeping the sort order.
    #[cold]
    #[inline(never)]
    fn evict_oldest_mark(extras: &mut Extras, col: usize, id: MarkId) -> bool {
        let (mut marks, mut oldest) = (0usize, None::<(MarkId, usize, u16)>);
        for (index, (at, extra)) in extras.entries.iter().enumerate() {
            if let Extra::Mark(m) = extra {
                marks += 1;
                if oldest.is_none_or(|(seen, _, _)| *m < seen) {
                    oldest = Some((*m, index, *at));
                }
            }
        }
        if marks < MARKS_PER_ROW {
            return false;
        }
        let Some((_, index, at)) = oldest else {
            return false;
        };
        if usize::from(at) == col {
            extras.entries[index].1 = Extra::Mark(id);
            return true;
        }
        extras.entries.remove(index);
        false
    }

    /// Write CELL at COL, retiring everything the old occupant had attached to it.
    ///
    /// One `Option` check on the write path. An unconditional `Vec::retain` would cost
    /// every write about 5% of the repaint benchmark; a null test on a pointer already in
    /// cache does not.
    ///
    /// Returns whether the row now differs, which [`Screen::edit`](crate::emu::screen::Screen)
    /// turns into damage. A TUI redrawing an unchanged frame should not make Emacs rewrite
    /// every row of it.
    ///
    /// A row carrying attachments answers `true` unconditionally: the retirement is itself
    /// a change, and asking the side table what this column had would cost the scan the
    /// `Option` check avoids. Rows with attachments are rare; identical repaints are not.
    pub fn set(&mut self, col: usize, cell: Cell) -> bool {
        let attached = self.meta().extras.is_some();
        let Some(slot) = self.cells_mut().get_mut(col) else {
            return false;
        };
        let changed = attached || *slot != cell;
        *slot = cell;
        if attached {
            self.retire(col);
        }
        changed
    }

    /// Blank every wide character that straddles either end of START..END, the columns a
    /// writer is about to overwrite, and return whether there was one.
    ///
    /// A wide character is a lead cell and the continuations after it, and they go
    /// together or not at all. `a` printed over the second half of `日` would otherwise
    /// leave `日` on one column, which Emacs still draws two wide, so the row reaches the
    /// buffer a column long, the cursor is counted a character early and a glyph run is
    /// cut in the wrong place. Printed over the first half, it leaves a continuation with
    /// no character before it, which the runs skip. Like xterm and Ghostty, the writer
    /// blanks the half it does not overwrite. The blanks keep the character's rendition,
    /// so a torn `日` on a red background leaves a red blank rather than a hole.
    ///
    /// Called before the write rather than after it, because only the old cell at START
    /// can say whether START was inside a wide character. END is the first column not
    /// written, so a continuation there belongs to a character whose lead was just
    /// overwritten, whenever it is tested.
    ///
    /// Every writer that replaces part of a row calls this -- [`Row::fill_run`],
    /// [`Row::fill`], [`Row::place`], [`Row::insert_blank`], [`Row::delete`],
    /// [`Row::resize`], and the grid's single-character print, which writes a lead and its
    /// continuations cell by cell. [`Row::set`] does not, because a continuation written on
    /// its own is half of a character by design. The two edge tests are all an ordinary
    /// write pays; the blanking is out of line.
    #[inline]
    pub fn clear_torn(&mut self, start: usize, end: usize) -> bool {
        let cells = self.cells();
        let torn = |col: usize| cells.get(col).is_some_and(|cell| cell.is_continuation());
        if !torn(start) && !torn(end) {
            return false;
        }
        self.blank_wide(start);
        self.blank_wide(end);
        true
    }

    /// Blank the whole of the wide character COL is a continuation of, if it is one.
    ///
    /// [`Row::clear_torn`]'s slow half. A continuation with no lead before it, which only
    /// an older tear could have left, is blanked from the start of the row.
    #[cold]
    #[inline(never)]
    fn blank_wide(&mut self, col: usize) {
        let cells = self.cells();
        if !cells.get(col).is_some_and(|cell| cell.is_continuation()) {
            return;
        }
        let lead = cells[..col]
            .iter()
            .rposition(|cell| !cell.is_continuation())
            .unwrap_or(0);
        let end = cells[col..]
            .iter()
            .position(|cell| !cell.is_continuation())
            .map_or(cells.len(), |n| col + n);
        let blank = Cell::blank(cells[lead].style());
        Cell::fill(&mut self.cells_mut()[lead..end], blank);
        self.prune(lead..end, Marks::Keep);
    }

    /// Place a run of characters from COL, each one column wide.
    ///
    /// [`Row::set`] in bulk, with the same effect as calling it per character. The
    /// `extras` test is hoisted out of the loop, since it is a property of the row.
    ///
    /// Writes only as far as the row goes, so an over-long run is truncated rather than
    /// panicking.
    ///
    /// Returns whether anything changed, on [`Row::set`]'s terms.
    pub fn fill_run(&mut self, col: usize, text: &str, pen: Pen) -> bool {
        let attached = self.meta().extras.is_some();
        let pen = pen.cell(BLANK);
        let Some(slots) = self.cells_mut().get_mut(col..) else {
            return false;
        };
        // The comparison is a pass of its own rather than a test folded into the write
        // loop: `any` stops at the first differing cell, usually the first, while the
        // folded form cost 24% on the plain-text benchmark. An unchanged frame pays one
        // pass and skips the stores.
        let changed = attached
            || slots
                .iter()
                .zip(text.chars())
                .any(|(slot, ch)| *slot != pen.with_char(ch));
        if !changed {
            return false;
        }
        let end = col + slots.len().min(text.len());
        self.clear_torn(col, end);
        let slots = &mut self.cells_mut()[col..];
        let mut placed = 0;
        for (slot, ch) in slots.iter_mut().zip(text.chars()) {
            *slot = pen.with_char(ch);
            placed += 1;
        }
        if attached {
            for at in col..col + placed {
                self.retire(at);
            }
        }
        true
    }

    /// Make COL one cell of an image, blanking whatever was there.
    ///
    /// The cell keeps a blank character in the pen's style, so the row still copies,
    /// rewraps and yanks as text — a picture pasted out of the scrollback comes out as
    /// the whitespace it occupied, which is the only honest plain-text rendering of it.
    /// [`Extra::is_content`] is what stops that blank being trimmed away.
    pub fn place(&mut self, col: usize, placement: Placement, style: StyleId) {
        if col >= self.cells().len() {
            return;
        }
        self.clear_torn(col, col + 1);
        // `set` first, so it retires whatever the old occupant had attached before the
        // placement goes on; the other order would prune the placement just made.
        let _ = self.set(col, Cell::blank(style));
        self.attach(col, Extra::Image(placement));
    }

    /// Attach a zero-width character (combining mark, variation selector) to `col`.
    pub fn combine(&mut self, col: usize, mark: char) {
        if let Some(extras) = &mut self.meta_mut().extras
            && let Some((_, Extra::Marks(text))) = extras
                .entries
                .iter_mut()
                .find(|(at, extra)| usize::from(*at) == col && matches!(extra, Extra::Marks(_)))
        {
            let mut s = String::from(&**text);
            s.push(mark);
            *text = s.into_boxed_str();
            return;
        }
        self.attach(col, Extra::Marks(String::from(mark).into_boxed_str()));
    }

    /// Blank a span of columns, returning whether that changed anything; see [`Row::set`]
    /// for what the answer is for.
    pub fn fill(&mut self, range: std::ops::Range<usize>, style: StyleId) -> bool {
        // Not `set` per column. `fill` is the erase path — a full-screen program clears
        // rows every frame — and a per-cell side-table check in the loop stops this being
        // a bulk write. The tables are pruned once, outside it.
        let blank = Cell::blank(style);
        let mut lo = usize::MAX;
        let mut hi = 0;
        let mut changed = self.meta().extras.is_some();
        changed |= self.clear_torn(range.start, range.end);
        for col in range {
            if let Some(slot) = self.cells_mut().get_mut(col) {
                changed |= *slot != blank;
                *slot = blank;
                lo = lo.min(col);
                hi = hi.max(col);
            }
        }
        if lo > hi {
            return false;
        }
        self.prune(lo..hi + 1, Marks::Keep);
        changed
    }

    /// Blank the row and drop everything attached to it, semantic marks included.
    ///
    /// This is the row *ceasing to be what it was*: recycled at the bottom of a scroll,
    /// backfilled behind a removed row, wiped by an erase of the display. A mark left on a
    /// recycled row would duplicate one already archived with the row's text, and a drain
    /// would report its id twice. [`Row::erase_all`] is the spelling for `CSI 2K`.
    ///
    /// Returns nothing, unlike the other writers: `Screen::scroll_up` clears every row it
    /// recycles, and comparing first would scan the row before overwriting it, 22% of the
    /// plain-text benchmark for an answer that path discards.
    pub fn clear(&mut self, style: StyleId) {
        Cell::fill(self.cells_mut(), Cell::blank(style));
        self.meta_mut().extras = None;
        self.meta_mut().wrap = Wrap::No;
    }

    /// `CSI 2K`: blank every column, keeping semantic marks.
    ///
    /// The one whole-row erase that is not the row ending: a shell wipes its prompt line
    /// with this and redraws it on every keystroke of a history search, so the marks stay,
    /// as in [`Row::retire`].
    ///
    /// Returns whether that changed anything, so a prompt redrawn identically costs no
    /// repaint. `wrapped` counts as content here, since it decides where a logical line
    /// ends.
    pub fn erase_all(&mut self, style: StyleId) -> bool {
        let blank = Cell::blank(style);
        let changed = self.meta().extras.is_some()
            || self.meta().wrap.wraps()
            || self.cells().iter().any(|c| *c != blank);
        Cell::fill(self.cells_mut(), blank);
        self.prune(0..self.cells().len(), Marks::Keep);
        self.meta_mut().wrap = Wrap::No;
        changed
    }

    pub fn insert_blank(&mut self, col: usize, count: usize, style: StyleId) {
        let cols = self.cells().len();
        if col >= cols {
            return;
        }
        let n = count.min(cols - col);
        // A wide character split by the insertion, or by the end of the row where the
        // cells from `cols - n` fall off, would be left in halves.
        self.clear_torn(col, cols - n);
        // In place, because `Cell` is `Copy` and the row's length does not change: growing
        // past `cols` and truncating would realloc once per character in insert mode.
        self.cells_mut().copy_within(col..cols - n, col + n);
        Cell::fill(&mut self.cells_mut()[col..col + n], Cell::blank(style));
        // The cells from `col` on moved right; their attachments move with them, and
        // whatever was pushed off the end goes.
        self.edit_extras(|extras| extras.shift(col, n as isize, cols));
    }

    pub fn delete(&mut self, col: usize, count: usize, style: StyleId) {
        let cols = self.cells().len();
        if col >= cols {
            return;
        }
        let gone = (col + count).min(cols) - col;
        // A wide character across either edge of the gap would lose one half to it.
        self.clear_torn(col, col + gone);
        // In place, as `insert_blank` is: the row's length does not change, so the cells
        // right of the gap slide left over it and blanks fill in behind them.
        let cells = self.cells_mut();
        cells.copy_within(col + gone..cols, col);
        Cell::fill(&mut cells[cols - gone..], Cell::blank(style));
        // The deleted columns take their attachments with them; everything to their right
        // closes the gap.
        self.prune(col..col + gone, Marks::Keep);
        self.edit_extras(|extras| extras.shift(col + gone, -(gone as isize), cols));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every bit of a cell is part of its value, which is what [`Cell::bytes`] rests on.
    ///
    /// A spread of characters, rendition ids and links, including no link and both field
    /// maxima: what goes in comes back out, and two cells compare equal exactly when
    /// their bytes do.
    #[test]
    fn a_cell_is_eight_bytes_that_read_back_as_what_was_packed() {
        let pens = [
            (StyleId::DEFAULT, None),
            (StyleId::from_raw(STYLE_MAX as u32), None),
            (StyleId::from_raw(1), Some(LinkId::from_index(0))),
            (
                StyleId::DEFAULT,
                Some(LinkId::from_index(LINK_MAX as u32 - 1)),
            ),
        ];
        let cells: Vec<Cell> = pens
            .iter()
            .flat_map(|&(style, link)| {
                ['a', CONTINUATION, '\u{10ffff}'].map(|ch| Cell::linked(ch, style, link))
            })
            .collect();
        for (cell, &(style, link)) in cells.iter().zip(pens.iter().flat_map(|p| [p; 3])) {
            assert_eq!(Cell::bytes(std::slice::from_ref(cell)).len(), 8);
            assert_eq!((cell.style(), cell.link()), (style, link), "{cell:?}");
            // The link is the one part trailing-blank trimming ignores, so masking it
            // away must leave the character and the rendition untouched.
            assert_eq!(
                cell.head(),
                Cell::new(cell.ch(), cell.style()).head(),
                "{cell:?}"
            );
        }
        for a in &cells {
            for b in &cells {
                let same_bytes =
                    Cell::bytes(std::slice::from_ref(a)) == Cell::bytes(std::slice::from_ref(b));
                assert_eq!(a == b, same_bytes, "{a:?} vs {b:?}");
            }
        }
    }

    /// An id too wide for its field degrades to the default rather than to another id.
    ///
    /// The one failure a packed cell could introduce and the reason [`Cell::linked`]
    /// checks: truncation would name a *live* rendition or a live destination, putting
    /// the child's own colours or its own URL on text that never had them. Unreachable
    /// through the stores, which collect against the grids -- so this builds the ids by
    /// hand, as only a test can.
    #[test]
    fn an_id_too_wide_for_its_field_degrades_rather_than_aliasing() {
        let over = Cell::linked(
            'x',
            StyleId::from_raw(STYLE_MAX as u32 + 1),
            LinkId::from_wire(LINK_MAX as u32 + 1),
        );
        assert_eq!(over.ch(), 'x');
        assert_eq!(
            over.style(),
            StyleId::DEFAULT,
            "not rendition 0's neighbour"
        );
        assert_eq!(over.link(), None, "not destination 0");
        assert_eq!(over, Cell::new('x', StyleId::DEFAULT));
    }

    #[test]
    fn runs_merge_by_style_and_trim_trailing_blanks() {
        let mut row = Row::new(10);
        let red = StyleId::from_raw(1);
        for (i, c) in "hi".chars().enumerate() {
            row.set(i, Cell::new(c, red));
        }
        row.set(2, Cell::new('!', StyleId::DEFAULT));

        let runs = row.runs();
        assert_eq!(runs.len(), 2);
        assert_eq!(
            runs.run(0),
            RunRef {
                text: "hi",
                chars: Chars::new(2),
                cols: Cols::new(2),
                style: red,
                deco: None,
                link: None,
            }
        );
        assert_eq!(runs.run(1).text, "!");
    }

    #[test]
    fn box_glyphs_do_not_merge_with_adjacent_plain_text() {
        let mut row = Row::new(4);
        let style = StyleId::DEFAULT;
        row.set(0, Cell::new('a', style));
        row.set(1, Cell::new('\u{2500}', style)); // ─, same style as its neighbors
        row.set(2, Cell::new('b', style));

        let runs = row.runs();
        assert_eq!(
            runs.len(),
            3,
            "box-glyph run must split even though style matches"
        );
        assert!(runs.run(0).deco.is_none());
        assert!(runs.run(1).deco.is_some());
        assert!(runs.run(2).deco.is_none());
    }

    #[test]
    fn adjacent_box_glyphs_of_the_same_style_merge_into_one_run() {
        let mut row = Row::new(4);
        let style = StyleId::DEFAULT;
        for (i, c) in "\u{250C}\u{2500}\u{2510}".chars().enumerate() {
            row.set(i, Cell::new(c, style));
        }

        let runs = row.runs();
        assert_eq!(runs.len(), 1);
        assert_eq!(runs.run(0).text, "\u{250C}\u{2500}\u{2510}");
        let glyphs = runs.run(0).deco.expect("box-glyph run").glyphs();
        assert_eq!(
            glyphs.len(),
            3,
            "one descriptor per character, index-aligned"
        );
        assert_eq!(glyphs[0].kind(), glyph::Kind::Line);
        assert!(!glyphs[0].is_arc());
    }

    #[test]
    fn box_glyph_run_splits_on_style_change() {
        let mut row = Row::new(4);
        let red = StyleId::from_raw(1);
        row.set(0, Cell::new('\u{2500}', StyleId::DEFAULT));
        row.set(1, Cell::new('\u{2500}', red));

        let runs = row.runs();
        assert_eq!(
            runs.len(),
            2,
            "style change still splits runs within box-glyph content"
        );
    }

    #[test]
    fn combining_marks_ride_along_with_their_base() {
        let mut row = Row::new(4);
        row.set(0, Cell::new('e', StyleId::DEFAULT));
        row.combine(0, '\u{301}');
        assert_eq!(row.to_text(), "e\u{301}");
    }

    #[test]
    fn overwriting_a_cell_drops_its_marks() {
        let mut row = Row::new(4);
        row.set(0, Cell::new('e', StyleId::DEFAULT));
        row.combine(0, '\u{301}');
        row.set(0, Cell::new('x', StyleId::DEFAULT));
        assert_eq!(row.to_text(), "x");
    }

    #[test]
    fn wide_cells_skip_their_continuation() {
        let mut row = Row::new(4);
        row.set(0, Cell::new('漢', StyleId::DEFAULT));
        row.set(1, Cell::new(CONTINUATION, StyleId::DEFAULT));
        assert_eq!(row.to_text(), "漢");
    }

    #[test]
    fn delete_shifts_left_and_backfills() {
        let mut row = Row::new(4);
        for (i, c) in "abcd".chars().enumerate() {
            row.set(i, Cell::new(c, StyleId::DEFAULT));
        }
        row.delete(1, 2, StyleId::DEFAULT);
        assert_eq!(row.to_text(), "ad");
    }

    #[test]
    fn attrs_are_a_set() {
        let mut a = Attrs::BOLD | Attrs::ITALIC;
        assert!(a.contains(Attrs::BOLD));
        a.remove(Attrs::BOLD);
        assert!(!a.contains(Attrs::BOLD));
        assert!(a.contains(Attrs::ITALIC));
    }

    #[test]
    fn a_mark_on_a_blank_cell_counts_as_content() {
        // Otherwise `content_len` trims the column the mark is keyed to, and the mark
        // goes with it. The cell under a combining mark is very often a blank.
        let mut row = Row::new(4);
        row.combine(1, '\u{0301}');
        assert_eq!(row.content_len(), 2);
        assert!(row.has_text());
        assert!(!row.is_blank());
    }

    #[test]
    fn a_link_on_blanks_alone_is_not_content() {
        // The invariant `content_len`'s contract rests on: it and `runs` must agree about
        // where a line ends, and a run of blanks inside a link is still a run of blanks.
        let mut row = Row::new(4);
        row.set(
            1,
            Cell::linked(BLANK, StyleId::DEFAULT, Some(LinkId::from_index(0))),
        );
        assert_eq!(row.content_len(), 0);
        assert!(!row.has_text());
        assert!(row.is_blank());
    }

    #[test]
    fn ich_shifts_attachments_with_their_cells() {
        let mut row = Row::new(6);
        row.set(0, Cell::new('a', StyleId::DEFAULT));
        row.combine(0, '\u{0301}');
        row.mark(Cols::ZERO, MarkId::from_index(1));

        row.insert_blank(0, 2, StyleId::DEFAULT);

        assert_eq!(
            row.extras(),
            [
                (2, Extra::Marks("\u{0301}".into())),
                (2, Extra::Mark(MarkId::from_index(1))),
            ]
        );
    }

    #[test]
    fn ich_drops_only_what_it_pushes_off_the_end() {
        let mut row = Row::new(4);
        row.combine(0, '\u{301}');
        row.combine(3, '\u{302}');

        row.insert_blank(0, 2, StyleId::DEFAULT);

        // Column 0 moved to 2; column 3 went off the end at 5.
        assert_eq!(row.extras(), [(2, Extra::Marks("\u{301}".into()))]);
        assert!(
            row.extras()
                .iter()
                .all(|(at, _)| usize::from(*at) < row.len())
        );
    }

    #[test]
    fn dch_closes_the_gap_and_spares_the_columns_before_it() {
        let mut row = Row::new(6);
        row.combine(0, '\u{301}');
        row.combine(3, '\u{302}');
        row.combine(5, '\u{303}');

        // Delete columns 3 and 4. Column 0 is untouched; column 5 closes up to 3.
        row.delete(3, 2, StyleId::DEFAULT);

        assert_eq!(
            row.extras(),
            [
                (0, Extra::Marks("\u{301}".into())),
                (3, Extra::Marks("\u{303}".into())),
            ]
        );
    }

    /// `\u{2502}   \u{2502}   \u{251c}\u{2500}\u{2500} name` is what a `tree` row is. Without absorption it would be
    /// three decorated runs with blanks between; with it the indent is one run of eleven
    /// glyphs, six of them [`BoxGlyph::BLANK`], beside the filename.
    #[test]
    fn a_tree_indent_is_one_glyph_run() {
        let style = StyleId::DEFAULT;
        let mut row = Row::new(24);
        for (col, ch) in "\u{2502}   \u{2502}   \u{251c}\u{2500}\u{2500} f"
            .chars()
            .enumerate()
        {
            row.set(col, Cell::new(ch, style));
        }

        let runs = row.runs();
        assert_eq!(runs.len(), 2, "the indent, then the name: {runs:?}");
        assert_eq!(
            runs.run(0).text,
            "\u{2502}   \u{2502}   \u{251c}\u{2500}\u{2500}"
        );
        assert_eq!(runs.run(0).cols, Cols::new(11));
        assert_eq!(runs.run(0).deco.map(Deco::len), Some(11));
        assert_eq!(runs.run(1).text, " f");
        assert!(runs.run(1).deco.is_none());

        // The blanks are the reserved descriptor, not a repeat of the shape beside them:
        // a run whose gaps drew `\u{2502}` would be a solid ladder.
        let glyphs = runs.run(0).deco.expect("the indent is decorated").glyphs();
        for gap in [1, 2, 3, 5, 6, 7] {
            assert_eq!(glyphs[gap], BoxGlyph::BLANK, "column {gap}");
        }
        assert_ne!(glyphs[0], BoxGlyph::BLANK);
    }

    /// `tree`'s real indent, byte for byte, which is not the one anybody writes by hand.
    ///
    /// tree(1) 2.3.2 emits `\u{2502}\u{a0}\u{a0} ` -- U+2502 then two NO-BREAK SPACEs then an ordinary
    /// space -- so a rule admitting only U+0020 absorbs the third gap cell and splits on
    /// the first two, leaving the row exactly as expensive as it was. This is why
    /// [`draws_nothing`] is a list and not `ch == BLANK`.
    #[test]
    fn a_no_break_space_is_absorbed_as_a_blank() {
        let style = StyleId::DEFAULT;
        let mut row = Row::new(24);
        for (col, ch) in "\u{2502}\u{a0}\u{a0} \u{2514}\u{2500}\u{2500} f"
            .chars()
            .enumerate()
        {
            row.set(col, Cell::new(ch, style));
        }

        let runs = row.runs();
        assert_eq!(runs.len(), 2, "{runs:?}");
        assert_eq!(
            runs.run(0).text,
            "\u{2502}\u{a0}\u{a0} \u{2514}\u{2500}\u{2500}"
        );
        assert_eq!(runs.run(0).deco.map(Deco::len), Some(7));
    }

    /// The trim, and the case that makes it necessary rather than tidy.
    ///
    /// [`Row::line_runs`] hands a *wrapped* row its full width, trailing padding included
    /// -- so a row ending in box drawing would bake every blank column out to the right
    /// margin into its bitmap, an image nobody can see at a cache key per padding width.
    /// The gap-between-two-glyph-runs rule refuses it structurally, and the leading blanks
    /// of an indented row go the same way.
    #[test]
    fn leading_and_trailing_blanks_stay_out_of_the_run() {
        let style = StyleId::DEFAULT;
        let mut row = Row::new(12);
        for (col, ch) in "  \u{2500}\u{2500}  ".chars().enumerate() {
            row.set(col, Cell::new(ch, style));
        }
        row.set_wrap(Wrap::Full);

        let runs = row.line_runs();
        assert_eq!(
            runs.len(),
            3,
            "leading blanks, the glyphs, the padding: {runs:?}"
        );
        assert_eq!(runs.run(0).text, "  ");
        assert!(runs.run(0).deco.is_none());
        assert_eq!(runs.run(1).text, "\u{2500}\u{2500}");
        assert_eq!(runs.run(1).deco.map(Deco::len), Some(2));
        // Every column out to `cols`, which is what a wrapped row contributes.
        assert_eq!(runs.run(2).text, "        ");
        assert!(runs.run(2).deco.is_none());
    }

    /// A gap only joins what it is between, and only when nothing else changed.
    #[test]
    fn a_blank_gap_under_a_different_rendition_still_breaks_the_run() {
        let red = StyleId::from_raw(1);
        let mut row = Row::new(12);
        for (col, ch) in "\u{2500} \u{2500}".chars().enumerate() {
            // The gap alone is red, which is a visible rectangle if it is baked into a
            // neighbour's bitmap.
            let style = if col == 1 { red } else { StyleId::DEFAULT };
            row.set(col, Cell::new(ch, style));
        }
        assert_eq!(row.runs().len(), 3, "{:?}", row.runs());

        // And a link boundary, which is the one thing carried on a run with no other way
        // to reach Lisp.
        let mut row = Row::new(12);
        for (col, ch) in "\u{2500} \u{2500}".chars().enumerate() {
            let link = (col == 2).then(|| LinkId::from_index(7));
            row.set(col, Cell::linked(ch, StyleId::DEFAULT, link));
        }
        assert_eq!(row.runs().len(), 3, "{:?}", row.runs());
    }

    /// Plain text between two glyph runs is not a gap, however much of it is blank.
    #[test]
    fn text_between_two_glyph_runs_is_not_absorbed() {
        let style = StyleId::DEFAULT;
        let mut row = Row::new(12);
        for (col, ch) in "\u{2500} x \u{2500}".chars().enumerate() {
            row.set(col, Cell::new(ch, style));
        }
        let runs = row.runs();
        assert_eq!(runs.len(), 3, "{runs:?}");
        assert_eq!(runs.run(1).text, " x ");
    }

    #[test]
    fn a_row_that_loses_its_last_attachment_loses_its_table() {
        // The `None` is what keeps `runs` on the specialisation with no side table in it,
        // so returning to it matters as much as getting off it.
        let mut row = Row::new(4);
        row.combine(1, '\u{301}');
        assert!(row.meta.extras.is_some());
        row.set(1, Cell::new('a', StyleId::DEFAULT));
        assert!(row.meta.extras.is_none());
    }

    /// `build_runs` must agree with [`Row::runs_to_reference`] on every row shape.
    ///
    /// Randomised rather than enumerated: the interesting cases are *combinations* --
    /// a link opening mid-run under one style, a combining mark on a box glyph, an image
    /// cell between two runs of matching colour, a wide character's continuation cell
    /// splitting nothing -- and there are far more of those than anyone writes out by
    /// hand. A fixed seed keeps a failure reproducible.
    ///
    /// Every `end` is checked, not just `content_len`, because `line_runs` asks for the
    /// full width on a wrapped row and the trimmed width otherwise.
    #[test]
    fn run_columns_add_up_to_the_cells_the_row_occupies() {
        // One of every shape whose column count is not its character count: a wide
        // character standing on two cells, a combining mark standing on none, and a box
        // glyph, which splits a run without being wide. Emacs' `string-width' on the
        // text these runs carry has to reach the same number -- that is the whole
        // contract of `Run::cols`, and `cooked-carried-row-width-agrees-with-string-width'
        // in tests/cooked-tests-render.el is the same assertion made from the other side.
        let mut row = Row::new(10);
        let style = StyleId::DEFAULT;
        for (col, ch) in [(0, 'a'), (1, '\u{6f22}'), (3, '\u{2500}'), (4, 'e')] {
            row.set(col, Cell::new(ch, style));
        }
        row.set(2, Cell::new(CONTINUATION, style));
        // Zero-width, and attached to the `e`: it adds a character and no column.
        row.combine(4, '\u{301}');

        let runs = row.runs();
        assert_eq!(
            runs.iter().map(|r| r.cols).sum::<Cols>(),
            Cols::new(5),
            "a, a wide character on two cells, a box glyph, and an accented e"
        );
        assert_eq!(
            runs.iter().map(|r| r.text.chars().count()).sum::<usize>(),
            5,
            "and one more character than columns on one side, one fewer on the other"
        );
    }

    /// Check that ABSORBED is UNABSORBED with nothing changed but blank gaps taken into the
    /// glyph runs either side of them, which is all [`Row::absorb_blank_runs`] may do.
    ///
    /// Stated without the function, so that composing it onto the reference, as
    /// `runs_to_matches_the_reference` does, cannot hide a wrong merge: the same text and
    /// columns, one decoration per character, each character's rendition, link and
    /// decoration as it was, [`BoxGlyph::BLANK`] only on a character that
    /// [`draws_nothing`], and never a blank at either end of a glyph run, which would be
    /// padding baked into a bitmap rather than a gap between two glyphs.
    fn assert_absorbed_only_blanks(unabsorbed: &[Run], absorbed: &[Run], context: &str) {
        let text = |runs: &[Run]| runs.iter().map(|r| r.text.as_str()).collect::<String>();
        let cols = |runs: &[Run]| runs.iter().map(|r| r.cols).sum::<Cols>();
        assert_eq!(text(absorbed), text(unabsorbed), "{context}: text");
        assert_eq!(cols(absorbed), cols(unabsorbed), "{context}: columns");
        for run in absorbed {
            if let Some(deco) = &run.deco {
                assert_eq!(
                    deco.len(),
                    run.text.chars().count(),
                    "{context}: one decoration per character of {run:?}"
                );
            }
            if let Some(Deco::Glyphs(glyphs)) = &run.deco {
                assert!(
                    glyphs.first() != Some(&BoxGlyph::BLANK)
                        && glyphs.last() != Some(&BoxGlyph::BLANK),
                    "{context}: a blank absorbed at the end of {run:?}"
                );
            }
        }
        let cells = |runs: &[Run]| -> Vec<(char, StyleId, Option<LinkId>, Option<DecoCell>)> {
            runs.iter()
                .flat_map(|run| {
                    run.text.chars().enumerate().map(move |(i, ch)| {
                        let deco = match &run.deco {
                            Some(Deco::Glyphs(glyphs)) => {
                                glyphs.get(i).copied().map(DecoCell::Glyph)
                            }
                            Some(Deco::Images(places)) => {
                                places.get(i).copied().map(DecoCell::Image)
                            }
                            None => None,
                        };
                        (ch, run.style, run.link, deco)
                    })
                })
                .collect()
        };
        for (i, (after, before)) in cells(absorbed)
            .into_iter()
            .zip(cells(unabsorbed))
            .enumerate()
        {
            let blank = after.3 == Some(DecoCell::Glyph(BoxGlyph::BLANK));
            assert!(
                after == before || (blank && before.3.is_none() && draws_nothing(after.0)),
                "{context}: character {i} was {before:?} and is {after:?}"
            );
            assert!(
                after.1 == before.1 && after.2 == before.2,
                "{context}: character {i}"
            );
        }
    }

    #[test]
    fn content_len_matches_the_reference() {
        // xorshift, as in `runs_to_matches_the_reference': a deterministic sequence.
        let mut seed = 0x243F_6A88_85A3_08D3_u64;
        let mut next = move || {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed
        };

        const COLS: usize = 24;
        // A blank in the default rendition is the only cell that trims. The rest are
        // there for the ways a byte comparison could go wrong: a blank carrying a link
        // trims all the same, because trimming does not look at the link; a blank in a
        // rendition does not, because it is a coloured bar drawn to the edge; and the
        // second half of a wide character is a `\0`, which is not a blank.
        let cells = [
            Cell::blank(StyleId::DEFAULT),
            Cell::blank(StyleId::DEFAULT),
            Cell::blank(StyleId::DEFAULT),
            Cell::linked(BLANK, StyleId::DEFAULT, Some(LinkId::from_index(0))),
            Cell::blank(StyleId::from_raw(1)),
            Cell::new('a', StyleId::DEFAULT),
            Cell::linked('a', StyleId::from_raw(2), Some(LinkId::from_index(1))),
            Cell::new(CONTINUATION, StyleId::DEFAULT),
        ];

        let mut all_blank = 0;
        let mut full = 0;
        for _ in 0..4_000 {
            let width = (next() % (COLS as u64 + 1)) as usize;
            let row: Vec<Cell> = (0..width)
                .map(|_| cells[(next() % cells.len() as u64) as usize])
                .collect();
            let want = row
                .iter()
                .rposition(|c| !c.is_trailing_blank())
                .map_or(0, |at| at + 1);
            assert_eq!(Cell::content_len(&row), want, "over {row:?}");
            all_blank += usize::from(want == 0 && width > 0);
            full += usize::from(want == width && width > 0);
        }
        // Both ends of the scan, since one of them is the early return and the other the
        // walk off the front of the row.
        assert!(all_blank > 0 && full > 0, "{all_blank} blank, {full} full");
    }

    #[test]
    fn runs_to_matches_the_reference() {
        // xorshift: a deterministic sequence, and small enough to read.
        let mut seed = 0x9E37_79B9_7F4A_7C15_u64;
        let mut next = move || {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed
        };

        const COLS: usize = 24;
        let styles = [
            StyleId::DEFAULT,
            StyleId::from_raw(1),
            StyleId::from_raw(2),
            StyleId::from_raw(3),
        ];
        let links = [
            None,
            None,
            Some(LinkId::from_index(0)),
            Some(LinkId::from_index(1)),
        ];
        // Plain ASCII, both blanks a glyph run absorbs, a box glyph, a shade block, a wide
        // character and a zero-width mark -- every branch `DecoCell::classify`, the
        // absorption and the width logic can take.
        let chars = [
            'a', 'b', ' ', '\u{a0}', '\u{2500}', '\u{2503}', '\u{2591}', '\u{6f22}',
        ];

        // Both paths, deliberately. `runs_to` sends a row with attachments to
        // `build_runs` and a row without to `build_plain_runs`, and with attachments
        // sprinkled at 5 cells in 16 essentially every generated row has one -- so a
        // single pass would have left the plain path, the one this test was written for,
        // never executed once.
        let mut plain_rows = 0;
        let mut attached_rows = 0;
        let mut absorbed_rows = 0;
        for case in 0..4_000 {
            let attachments = case % 2 == 0;
            let mut row = Row::new(COLS);
            let mut col = 0;
            while col < COLS {
                let r = next();
                let ch = chars[(r % chars.len() as u64) as usize];
                let style = styles[((r >> 8) % 4) as usize];
                let link = links[((r >> 16) % 4) as usize];
                let width = if ch == '\u{6f22}' { 2 } else { 1 };
                if col + width > COLS {
                    break;
                }
                row.set(col, Cell::linked(ch, style, link));
                if width == 2 {
                    row.set(col + 1, Cell::linked(CONTINUATION, style, link));
                }
                // Attachments, each rare enough that most cells carry none -- which is
                // also the distribution the real grid has.
                match if attachments {
                    (r >> 32) % 16
                } else {
                    u64::MAX
                } {
                    0..=2 => row.combine(col, '\u{301}'),
                    3 => row.mark(Cols::new(col), MarkId::from_index(((r >> 40) % 4) as u32)),
                    4 => row.place(
                        col,
                        Placement {
                            id: crate::emu::image::ImageId::from_index(((r >> 40) % 2) as u32),
                            cell_row: 0,
                            cell_col: 0,
                            cols: 1,
                            rows: 1,
                        },
                        style,
                    ),
                    _ => {}
                }
                col += width;
            }

            // Which builder the row takes, which is not the same as whether it picked up
            // an attachment: a row carrying only semantic marks renders as a bare row and
            // goes to the plain builder. See `Row::runs_from`.
            if row.extras().iter().any(|(_, extra)| extra.draws()) {
                attached_rows += 1;
            } else {
                plain_rows += 1;
            }
            for end in 0..=COLS {
                // The reference states the builders' job and stops there; the blank
                // absorption is a shared post-pass and is composed on here rather than
                // called from inside the reference, so that this still compares two
                // independent formulations of everything the builders decide. See
                // `Row::absorb_blank_runs`.
                let unabsorbed = row.runs_to_reference(end);
                let mut expected = Runs::from_runs(&unabsorbed);
                Row::absorb_blank_runs(&mut expected);
                let runs = row.runs_to(end);
                assert_eq!(
                    runs, expected,
                    "case {case}, end {end}: runs disagree with the reference"
                );
                assert_absorbed_only_blanks(
                    &unabsorbed,
                    &runs.to_vec(),
                    &format!("case {case}, end {end}"),
                );
                absorbed_rows += usize::from(runs.len() < unabsorbed.len());
            }
        }

        // Asserted, not assumed: this test is only worth anything if both
        // implementations actually ran, and which one runs is decided by whether the row
        // happened to pick up an attachment.
        assert!(
            plain_rows > 1_000 && attached_rows > 1_000,
            "both run builders must be exercised: {plain_rows} plain, {attached_rows} attached"
        );
        assert!(
            absorbed_rows > 100,
            "the absorption must be exercised: {absorbed_rows} prefixes had a gap absorbed"
        );
    }

    #[test]
    fn insert_blank_keeps_the_row_exactly_cols_wide() {
        let plain = |ch| Cell::new(ch, StyleId::DEFAULT);
        let text = |row: &Row| row.cells().iter().map(|c| c.ch()).collect::<String>();

        let mut row = Row::new(4);
        for (col, ch) in "abcd".chars().enumerate() {
            row.set(col, plain(ch));
        }

        // The ordinary shift: `d` falls off the end rather than widening the row.
        row.insert_blank(1, 1, StyleId::DEFAULT);
        assert_eq!(row.len(), 4);
        assert_eq!(text(&row), "a bc");

        // The boundary the in-place rewrite has to get right: `count` at or past the
        // columns remaining leaves an empty copy range, so the tail is filled and nothing
        // is read from beyond the row.
        row.insert_blank(2, 99, StyleId::DEFAULT);
        assert_eq!(row.len(), 4);
        assert_eq!(text(&row), "a   ");

        // Inserting at the last column touches exactly that column.
        let mut row = Row::new(4);
        for (col, ch) in "abcd".chars().enumerate() {
            row.set(col, plain(ch));
        }
        row.insert_blank(3, 1, StyleId::DEFAULT);
        assert_eq!(text(&row), "abc ");
    }

    #[test]
    fn a_mark_outlives_what_is_drawn_over_it() {
        let mut row = Row::new(4);
        row.mark(Cols::ONE, MarkId::from_index(7));
        row.combine(1, '\u{301}');
        row.set(1, Cell::new('a', StyleId::DEFAULT));
        // The combining mark went with the character it rode; the semantic mark is a
        // position in the stream and stays. `OSC 133;A' arrives before the prompt is
        // printed, so without this every prompt mark would die to its own prompt's first
        // character.
        assert_eq!(
            row.marks().collect::<Vec<_>>(),
            vec![(Cols::ONE, MarkId::from_index(7))]
        );
        assert!(
            !row.extras()
                .iter()
                .any(|(_, e)| matches!(e, Extra::Marks(_)))
        );

        // An erase is the same case reached the other way: a shell redrawing its prompt
        // line wipes it with `CSI K` on every keystroke.
        row.fill(0..4, StyleId::DEFAULT);
        assert_eq!(
            row.marks().collect::<Vec<_>>(),
            vec![(Cols::ONE, MarkId::from_index(7))]
        );
        row.erase_all(StyleId::DEFAULT);
        assert_eq!(
            row.marks().collect::<Vec<_>>(),
            vec![(Cols::ONE, MarkId::from_index(7))]
        );

        // The row ceasing to be what it was does take it: recycled at the bottom of a
        // scroll, or with the column it sat on gone.
        row.clear(StyleId::DEFAULT);
        assert!(row.marks().next().is_none());
        row.mark(Cols::ONE, MarkId::from_index(8));
        row.resize(1, StyleId::DEFAULT);
        assert!(row.marks().next().is_none());
    }

    #[test]
    fn marks_on_one_row_are_bounded() {
        let mut row = Row::new(4);
        for i in 0..(MARKS_PER_ROW as u32 * 3) {
            row.mark(Cols::ONE, MarkId::from_index(i));
        }
        let marks: Vec<_> = row.marks().collect();
        assert_eq!(marks.len(), MARKS_PER_ROW, "the bound holds");
        // The newest survive: a child that emits `OSC 133' without ever moving off the
        // row would otherwise grow this table without limit, and the records Emacs still
        // holds markers for are the recent ones.
        assert_eq!(
            marks.last().map(|(_, id)| *id),
            Some(MarkId::from_index(MARKS_PER_ROW as u32 * 3 - 1))
        );
        assert!(marks.iter().all(|(at, _)| *at == Cols::ONE));
    }

    #[test]
    fn marks_at_different_columns_are_kept_apart() {
        let mut row = Row::new(4);
        // `OSC 133;B` and `;C` land on the same cell whenever an empty line is submitted,
        // and each names a different record in Emacs.
        row.mark(Cols::ZERO, MarkId::from_index(1));
        row.mark(Cols::ZERO, MarkId::from_index(2));
        row.mark(Cols::new(3), MarkId::from_index(3));
        assert_eq!(
            row.marks().collect::<Vec<_>>(),
            vec![
                (Cols::ZERO, MarkId::from_index(1)),
                (Cols::ZERO, MarkId::from_index(2)),
                (Cols::new(3), MarkId::from_index(3))
            ]
        );
    }

    #[test]
    fn overwriting_a_cell_retires_everything_attached_to_it() {
        let mut row = Row::new(4);
        row.set(1, Cell::new('a', StyleId::DEFAULT));
        row.combine(1, '\u{0301}');

        row.set(1, Cell::new('b', StyleId::DEFAULT));

        assert!(row.extras().is_empty());
        assert!(row.meta.extras.is_none());
    }

    #[test]
    fn attachments_on_other_columns_survive_a_write() {
        let mut row = Row::new(4);
        row.combine(1, '\u{301}');
        row.combine(2, '\u{302}');
        row.set(1, Cell::new('x', StyleId::DEFAULT));
        assert_eq!(row.extras(), [(2, Extra::Marks("\u{302}".into()))]);
    }
}
