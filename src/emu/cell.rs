//! Cells, styling, and the row representation the renderer consumes.

use std::borrow::{Borrow, BorrowMut};
use std::ops::{BitAnd, BitOr, BitOrAssign, Not};
use unicode_width::UnicodeWidthChar;

use super::glyph::{self, BoxGlyph};
use super::image::Placement;
use super::link::LinkId;
use super::style::StyleId;

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

/// One screen position. `ch == CONTINUATION` marks the second half of a wide character.
///
/// Sixteen bytes of plain data with no padding: the character, the [`StyleId`] of its
/// rendition, the `OSC 8` link it is part of, and a spare word that is always zero. The
/// rendition and the link are ids, so a cell costs the same whatever it is drawn in and
/// whether or not it is linked: a coloured underline or a link is a field written with
/// the character rather than an entry in a side table found per column.
///
/// Every byte of a cell is meaningful, so two rows compare equal exactly when their bytes
/// do -- see [`Cell::bytes`] -- and a comparison against the frame Emacs already holds
/// covers the character, the rendition and the link in one `memcmp`.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cell {
    pub ch: char,
    pub style: StyleId,
    pub link: Option<LinkId>,
    /// Always zero. Private so that nothing can set it, which is what lets
    /// [`Cell::bytes`] treat a cell as bytes.
    zero: u32,
}

const _: () = assert!(std::mem::size_of::<Cell>() == 16);
const _: () = assert!(std::mem::align_of::<Cell>() == 4);

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
    pub const fn linked(ch: char, style: StyleId, link: Option<LinkId>) -> Self {
        Self {
            ch,
            style,
            link,
            zero: 0,
        }
    }

    pub const fn blank(style: StyleId) -> Self {
        Self::new(BLANK, style)
    }

    /// The same rendition and link with CH in it.
    pub const fn with_char(self, ch: char) -> Self {
        Self { ch, ..self }
    }

    /// Whether this cell and OTHER are drawn alike: the same rendition and the same link.
    pub fn same_pen(self, other: Self) -> bool {
        self.style == other.style && self.link == other.link
    }

    /// Whether this cell is in the default rendition, the test trailing-blank trimming
    /// asks of every cell it walks. A link does not count: a run of blanks inside a link
    /// is still blanks, and trims like any other.
    pub fn is_default_style(self) -> bool {
        self.style.is_default()
    }

    /// Set every cell of CELLS to CELL.
    ///
    /// By doubling copies rather than `slice::fill`: a store of a sixteen-byte struct is
    /// four field stores, which LLVM does not turn into `memset`, so a row of blanks was
    /// written a field at a time. Copying the filled prefix onto the rest is a handful of
    /// `memcpy`s however wide the row -- nine for a 400-column one.
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
    /// Sound because `Cell` is `repr(C)` with four four-byte fields and so no padding (the
    /// asserts beside the type pin its size and alignment); `Option<LinkId>` is guaranteed
    /// the layout of a `u32` with `None` as zero; and the spare field is private and
    /// always zero. So the bytes of a cell are a function of its value, and equal slices of
    /// bytes are equal cells.
    pub fn bytes(cells: &[Cell]) -> &[u8] {
        // SAFETY: see above -- `Cell` has no padding and no uninitialised bytes, and the
        // length is the slice's own size in bytes.
        unsafe { std::slice::from_raw_parts(cells.as_ptr().cast::<u8>(), size_of_val(cells)) }
    }

    pub fn is_continuation(self) -> bool {
        self.ch == CONTINUATION
    }

    /// Columns occupied; wide characters claim two.
    pub fn width(self) -> usize {
        self.ch.width().unwrap_or(1).max(1)
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

/// The decoration of a whole run, one entry per character of [`Run::text`].
///
/// A run is homogeneous in its kind: [`Row::build_runs`] will not merge characters
/// decorated differently into one run. That is what lets the wire format carry a single
/// kind tag plus fixed-width records, instead of tagging every character — see
/// [`Deco::packed`] for what those records are.
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

    /// The run's decoration as the unibyte string Lisp decodes, little-endian
    /// throughout. `cooked--apply-deco' in lisp/cooked-deco.el is the only reader.
    ///
    /// Packed rather than a list of Lisp objects because every damaged row of every frame
    /// takes this path, and box drawing is what full-screen programs are made of. Emacs is
    /// the bottleneck -- the parser runs at 74-422 MB/s, the apply path at roughly 21 MB/s
    /// -- so nothing Rust already knows should be left for Lisp to rediscover.
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
    pub fn packed(&self) -> Vec<u8> {
        match self {
            Self::Glyphs(glyphs) => {
                let mut packed = Vec::with_capacity(glyphs.len().min(8) * 4);
                let mut run: Option<(u16, u16)> = None;
                let flush = |packed: &mut Vec<u8>, bits: u16, count: u16| {
                    packed.extend_from_slice(&bits.to_le_bytes());
                    packed.extend_from_slice(&count.to_le_bytes());
                };
                for glyph in glyphs {
                    let bits = glyph.bits();
                    run = match run {
                        Some((b, count)) if b == bits && count < u16::MAX => Some((b, count + 1)),
                        Some((b, count)) => {
                            flush(&mut packed, b, count);
                            Some((bits, 1))
                        }
                        None => Some((bits, 1)),
                    };
                }
                if let Some((bits, count)) = run {
                    flush(&mut packed, bits, count);
                }
                packed
            }
            Self::Images(places) => {
                let mut packed = Vec::with_capacity(places.len() * 12);
                for place in places {
                    packed.extend_from_slice(&place.id.get().to_le_bytes());
                    packed.extend_from_slice(&place.cell_row.to_le_bytes());
                    packed.extend_from_slice(&place.cell_col.to_le_bytes());
                    packed.extend_from_slice(&place.cols.to_le_bytes());
                    packed.extend_from_slice(&place.rows.to_le_bytes());
                }
                packed
            }
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
    pub cols: usize,
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
        match &self.deco {
            Some(Deco::Glyphs(glyphs)) => glyphs.get(index).map(|g| format!("{g:?}")),
            Some(Deco::Images(places)) => places.get(index).map(|p| format!("{p:?}")),
            None => None,
        }
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
    /// The row's logical line continues on the row below.
    wrapped: bool,
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
    pub fn into_marks(self) -> impl Iterator<Item = (usize, MarkId)> + 'a {
        self.meta
            .extras
            .as_deref()
            .map_or(&[][..], Extras::entries)
            .iter()
            .filter_map(|(at, extra)| match extra {
                Extra::Mark(id) => Some((usize::from(*at), *id)),
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
    pub fn from_parts(cells: Vec<Cell>, extras: Vec<(u16, Extra)>, wrapped: bool) -> Self {
        Self {
            cells,
            meta: RowMeta {
                extras: (!extras.is_empty()).then(|| Box::new(Extras { entries: extras })),
                wrapped,
            },
        }
    }

    /// The one place a mark is dropped by anything short of the row itself going: past
    /// `cols` there is no longer a cell for it to be attached to. Only the non-rewrapping
    /// paths reach here -- the alternate screen, and a `Resize::Clamp` -- and neither has
    /// buffer text under it for a mark to be describing.
    pub fn resize(&mut self, cols: usize, style: StyleId) {
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
        self.meta().wrapped
    }

    pub fn extras(&self) -> &[(u16, Extra)] {
        self.meta().extras.as_deref().map_or(&[], Extras::entries)
    }

    /// Every semantic mark on this row, in column order.
    pub fn marks(&self) -> impl Iterator<Item = (usize, MarkId)> + '_ {
        self.extras().iter().filter_map(|(at, extra)| match extra {
            Extra::Mark(id) => Some((usize::from(*at), *id)),
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
            || self.cells().iter().any(|c| c.ch != BLANK)
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
                .all(|c| c.ch == BLANK && c.is_default_style())
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
        let cells = self
            .cells()
            .iter()
            .rposition(|c| c.ch != BLANK || !c.is_default_style())
            .map_or(0, |i| i + 1);
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

    /// Style-grouped runs with trailing default-styled blanks trimmed.
    ///
    /// Dispatches on whether the row has a side table: [`Row::build_plain_runs`] for
    /// nearly every row, [`Row::build_runs`] otherwise. This is the hottest read in the
    /// emulator, and a per-cell lookup cost about 2% of the full-screen repaint benchmark.
    pub fn runs(&self) -> Vec<Run> {
        self.runs_to(self.content_len())
    }

    /// Runs for a row on its way into the buffer as part of a logical line.
    ///
    /// A continuation row contributes every column: its trailing blanks are interior to a
    /// line that goes on below, and trimming them would pull the continuation forward.
    /// [`Logical::push_row`](super::screen) measures rows the same way during a rewrap, and
    /// the two must agree for a resize to round-trip. It also keeps every departed row
    /// exactly `cols` wide, which [`Screen::carried`](super::screen::Screen) relies on.
    pub fn line_runs(&self) -> Vec<Run> {
        if self.meta().wrapped {
            self.runs_to(self.len())
        } else {
            self.runs()
        }
    }

    /// The simplest correct statement of what [`Row::runs_to`] must produce.
    ///
    /// A reference implementation for `runs_to_matches_the_reference` to check the fast
    /// builders against. They are the hottest read in the emulator and so the most
    /// tempting to optimise, and an optimisation needs something to be equivalent to.
    ///
    /// An independent formulation rather than a copy -- it searches per column where the
    /// builders walk a cursor -- so the two cannot share a mistake. It stops where the
    /// builders stop: the test composes [`Row::absorb_blank_runs`] onto it.
    #[cfg(test)]
    pub(crate) fn runs_to_reference(&self, end: usize) -> Vec<Run> {
        let entries: &[(u16, Extra)] = self.meta().extras.as_deref().map_or(&[], |e| &e.entries);
        let mut runs: Vec<Run> = Vec::new();
        for (col, cell) in self.cells()[..end].iter().enumerate() {
            if cell.is_continuation() {
                // The column still belongs to the wide character before it, and so to
                // that character's run: `cols` counts columns, not characters.
                if let Some(run) = runs.last_mut() {
                    run.cols += 1;
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
            let deco = placed
                .map(DecoCell::Image)
                .or_else(|| DecoCell::classify(cell.ch));
            let joins = runs.last().is_some_and(|run| {
                run.style == cell.style
                    && run.link == cell.link
                    && match (&run.deco, deco) {
                        (None, None) => true,
                        (Some(d), Some(c)) => d.accepts(c),
                        _ => false,
                    }
            });
            if joins {
                let run = runs.last_mut().expect("joins implies a last run");
                run.text.push(cell.ch);
                run.cols += 1;
                if let (Some(d), Some(c)) = (&mut run.deco, deco) {
                    d.push(c);
                }
            } else {
                runs.push(Run {
                    text: String::from(cell.ch),
                    cols: 1,
                    style: cell.style,
                    deco: deco.map(Deco::start),
                    link: cell.link,
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
    pub(crate) fn runs_between(&self, start: usize, end: usize) -> Vec<Run> {
        let end = end.min(self.len());
        let start = start.min(end);
        if start == 0 {
            return self.runs_to(end);
        }
        let extras = self
            .extras()
            .iter()
            .filter(|(at, _)| (start..end).contains(&usize::from(*at)))
            .map(|(at, extra)| (*at - start as u16, extra.clone()))
            .collect();
        Row::from_parts(self.cells()[start..end].to_vec(), extras, false).runs_to(end - start)
    }

    fn runs_to(&self, end: usize) -> Vec<Run> {
        let mut runs = match self.meta().extras.as_deref() {
            Some(extras) => self.build_runs(end, &extras.entries),
            None => self.build_plain_runs(end),
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
    fn absorb_blank_runs(runs: &mut Vec<Run>) {
        let blank_gap = |run: &Run| {
            run.deco.is_none()
                // Combining marks push characters onto `text` that stand on no column, so
                // a run whose text is longer than its columns is carrying something other
                // than the blanks it looks like.
                && run.text.chars().count() == run.cols
                && !run.text.is_empty()
                && run.text.chars().all(draws_nothing)
        };
        let mut i = 0;
        while i + 2 < runs.len() {
            let joins = matches!(runs[i].deco, Some(Deco::Glyphs(_)))
                && matches!(runs[i + 2].deco, Some(Deco::Glyphs(_)))
                && blank_gap(&runs[i + 1])
                && runs[i].style == runs[i + 1].style
                && runs[i].style == runs[i + 2].style
                && runs[i].link == runs[i + 1].link
                && runs[i].link == runs[i + 2].link;
            if !joins {
                i += 1;
                continue;
            }
            // Two at a time, and `i` does not advance: the run that just grew is the left
            // half of the next window, so `\u{2502}   \u{2502}   \u{251c}\u{2500}\u{2500}` collapses in one pass.
            let tail = runs.remove(i + 1);
            let next = runs.remove(i + 1);
            let run = &mut runs[i];
            run.text.push_str(&tail.text);
            run.text.push_str(&next.text);
            run.cols += tail.cols + next.cols;
            let (Some(Deco::Glyphs(glyphs)), Some(Deco::Glyphs(more))) = (&mut run.deco, next.deco)
            else {
                unreachable!("the match above admitted only two glyph runs");
            };
            glyphs.extend(std::iter::repeat_n(BoxGlyph::BLANK, tail.cols));
            glyphs.extend(more);
        }
    }

    /// [`Row::build_runs`] for a row with nothing attached, which is nearly every row.
    ///
    /// With no attachments there are no combining marks and no image placements, so the
    /// only things that can end a run are the pen -- rendition or link -- changing and a
    /// character that draws a shape. That collapses the per-cell decision the general form has to make
    /// into a scan for the end of the run, after which the whole span is appended at once
    /// -- one `runs.last_mut()`, one capacity check and one join test per *run* instead of
    /// per cell.
    ///
    /// `runs_to_matches_the_reference` checks it against `Row::runs_to_reference` over
    /// randomised rows, including the wide characters and box glyphs a wrong scan would
    /// mishandle.
    fn build_plain_runs(&self, end: usize) -> Vec<Run> {
        let mut runs = Vec::<Run>::with_capacity(4);
        let cells = &self.cells()[..end];
        let mut col = 0;
        while col < end {
            let cell = &cells[col];
            // A continuation cell belongs to the wide character before it and contributes
            // no text of its own, so it can neither start a run nor end one.
            if cell.is_continuation() {
                // Reachable only after a decorated cell, which is taken one at a time
                // and so does not absorb the continuations the bulk scan below does.
                // Credited to the run that owns the character regardless, so that this
                // and `Row::runs_to_reference` count the same columns.
                if let Some(run) = runs.last_mut() {
                    run.cols += 1;
                }
                col += 1;
                continue;
            }
            let pen = *cell;
            let start = col;
            let deco = DecoCell::classify(cell.ch);
            col += 1;
            // A decorated cell is taken one at a time: consecutive box glyphs join only if
            // `Deco::accepts` says so, which is a per-character question the bulk path
            // cannot ask. Plain text -- the case this function exists for -- runs on.
            if deco.is_none() {
                while col < end {
                    let next = &cells[col];
                    if !next.is_continuation()
                        && (!next.same_pen(pen) || DecoCell::classify(next.ch).is_some())
                    {
                        break;
                    }
                    col += 1;
                }
            }
            let text = cells[start..col]
                .iter()
                .filter(|c| !c.is_continuation())
                .map(|c| c.ch);
            match runs.last_mut() {
                Some(run)
                    if run.style == pen.style
                        && run.link == pen.link
                        && match (&run.deco, deco) {
                            (None, None) => true,
                            (Some(d), Some(c)) => d.accepts(c),
                            _ => false,
                        } =>
                {
                    run.text.extend(text);
                    run.cols += col - start;
                    if let (Some(d), Some(c)) = (&mut run.deco, deco) {
                        d.push(c);
                    }
                }
                _ => {
                    // Sized to the columns left, for the same reason `build_runs` does it:
                    // the row's dominant shape is one run spanning it.
                    let mut buffer = String::with_capacity(end - start);
                    buffer.extend(text);
                    runs.push(Run {
                        text: buffer,
                        // Every cell of the span, continuations included: the scan above
                        // ran to `col` over columns, and that span is the run's width.
                        cols: col - start,
                        style: pen.style,
                        deco: deco.map(Deco::start),
                        link: pen.link,
                    });
                }
            }
        }
        runs
    }

    /// The row's cells as runs, for a row that has attachments to read.
    ///
    /// The attachment-free row goes to [`Row::build_plain_runs`] instead, so ENTRIES is
    /// never empty here in practice. It is walked with a cursor rather than searched per
    /// column, so the whole row costs one pass over the table.
    fn build_runs(&self, end: usize, entries: &[(u16, Extra)]) -> Vec<Run> {
        // Four, not `end`: the row's dominant shapes are one run of plain text and a
        // handful for a coloured prompt, so a capacity of one per column would be a far
        // bigger allocation than the growth it saves.
        let mut runs = Vec::<Run>::with_capacity(4);
        let mut at = 0;
        for (col, cell) in self.cells()[..end].iter().enumerate() {
            if cell.is_continuation() {
                // A column of the wide character that opened it, hence of its run.
                if let Some(run) = runs.last_mut() {
                    run.cols += 1;
                }
                continue;
            }
            let mut marks = None;
            let mut placed = None;
            while at < entries.len() && usize::from(entries[at].0) < col {
                at += 1;
            }
            for (_, extra) in entries[at..]
                .iter()
                .take_while(|(c, _)| usize::from(*c) == col)
            {
                match extra {
                    Extra::Marks(text) => marks = Some(&**text),
                    Extra::Image(p) => placed = Some(*p),
                    // Nothing to draw and nothing to split a run on: a mark is a
                    // position, not a property of the characters.
                    Extra::Mark(_) => {}
                }
            }
            // A placement wins over the character's own shape: it is state attached to
            // this cell, while the shape is derived from a character that an image cell
            // keeps as a blank. In practice they cannot both be here — writing a
            // character retires whatever was attached — so this is an ordering, not a
            // conflict resolution.
            let deco = placed
                .map(DecoCell::Image)
                .or_else(|| DecoCell::classify(cell.ch));
            match runs.last_mut() {
                Some(run)
                    if run.style == cell.style
                        // A link boundary splits a run even when nothing else changed:
                        // `see <link>foo</link> bar' in one colour is otherwise one run,
                        // with nothing to say which part is clickable.
                        && run.link == cell.link
                        && match (&run.deco, deco) {
                            (None, None) => true,
                            (Some(d), Some(c)) => d.accepts(c),
                            _ => false,
                        } =>
                {
                    run.text.push(cell.ch);
                    run.cols += 1;
                    if let (Some(d), Some(c)) = (&mut run.deco, deco) {
                        d.push(c);
                    }
                }
                _ => runs.push(Run {
                    // A run cannot outgrow the columns left, and for ASCII bytes and
                    // columns are the same, so this is one allocation where growing from
                    // a capacity of 1 took about five.
                    text: {
                        let mut text = String::with_capacity(end - col);
                        text.push(cell.ch);
                        text
                    },
                    cols: 1,
                    style: cell.style,
                    deco: deco.map(Deco::start),
                    link: cell.link,
                }),
            }
            // Combining marks never legitimately attach to a box-drawing base
            // character, so no padding is needed to keep the decoration aligned.
            if let (Some(marks), Some(run)) = (marks, runs.last_mut()) {
                run.text.push_str(marks);
            }
        }
        runs
    }

    pub fn to_text(&self) -> String {
        self.runs().into_iter().map(|r| r.text).collect()
    }
}

impl<C: BorrowMut<[Cell]>, M: BorrowMut<RowMeta>> RowOf<C, M> {
    fn cells_mut(&mut self) -> &mut [Cell] {
        self.cells.borrow_mut()
    }

    fn meta_mut(&mut self) -> &mut RowMeta {
        self.meta.borrow_mut()
    }

    /// Set whether this row's line continues below, returning what it was.
    pub fn set_wrapped(&mut self, wrapped: bool) -> bool {
        std::mem::replace(&mut self.meta_mut().wrapped, wrapped)
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
    pub fn mark(&mut self, col: usize, id: MarkId) {
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
    pub fn fill(&mut self, range: impl IntoIterator<Item = usize>, style: StyleId) -> bool {
        // Not `set` per column. `fill` is the erase path — a full-screen program clears
        // rows every frame — and a per-cell side-table check in the loop stops this being
        // a bulk write. The tables are pruned once, outside it.
        let blank = Cell::blank(style);
        let mut lo = usize::MAX;
        let mut hi = 0;
        let mut changed = self.meta().extras.is_some();
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
        self.meta_mut().wrapped = false;
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
            || self.meta().wrapped
            || self.cells().iter().any(|c| *c != blank);
        Cell::fill(self.cells_mut(), blank);
        self.prune(0..self.cells().len(), Marks::Keep);
        self.meta_mut().wrapped = false;
        changed
    }

    pub fn insert_blank(&mut self, col: usize, count: usize, style: StyleId) {
        let cols = self.cells().len();
        if col >= cols {
            return;
        }
        let n = count.min(cols - col);
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

    /// Every byte of a cell is part of its value, which is what [`Cell::bytes`] rests on.
    ///
    /// A spread of characters, rendition ids and links, including no link, which is the
    /// niche: the spare word reads back zero, and two cells compare equal exactly when
    /// their bytes do.
    #[test]
    fn a_cell_is_sixteen_bytes_with_nothing_undefined_in_them() {
        let pens = [
            (StyleId::DEFAULT, None),
            (StyleId::from_raw(u32::MAX), None),
            (StyleId::from_raw(1), Some(LinkId::from_index(0))),
            (StyleId::DEFAULT, Some(LinkId::from_index(u32::MAX - 1))),
        ];
        let cells: Vec<Cell> = pens
            .iter()
            .flat_map(|&(style, link)| {
                ['a', CONTINUATION, '\u{10ffff}'].map(|ch| Cell::linked(ch, style, link))
            })
            .collect();
        for cell in &cells {
            let bytes = Cell::bytes(std::slice::from_ref(cell));
            assert_eq!(bytes.len(), 16);
            assert_eq!(&bytes[12..], &[0, 0, 0, 0], "{cell:?}");
            let link = u32::from_ne_bytes(bytes[8..12].try_into().unwrap());
            assert_eq!(link, cell.link.map_or(0, LinkId::get), "{cell:?}");
        }
        for a in &cells {
            for b in &cells {
                let same_bytes =
                    Cell::bytes(std::slice::from_ref(a)) == Cell::bytes(std::slice::from_ref(b));
                assert_eq!(a == b, same_bytes, "{a:?} vs {b:?}");
            }
        }
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
            runs[0],
            Run {
                text: "hi".into(),
                cols: 2,
                style: red,
                ..Default::default()
            }
        );
        assert_eq!(runs[1].text, "!");
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
        assert!(runs[0].deco.is_none());
        assert!(runs[1].deco.is_some());
        assert!(runs[2].deco.is_none());
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
        assert_eq!(runs[0].text, "\u{250C}\u{2500}\u{2510}");
        let glyphs = runs[0].deco.as_ref().expect("box-glyph run").glyphs();
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
        row.mark(0, MarkId::from_index(1));

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
            runs[0].text,
            "\u{2502}   \u{2502}   \u{251c}\u{2500}\u{2500}"
        );
        assert_eq!(runs[0].cols, 11);
        assert_eq!(runs[0].deco.as_ref().map(Deco::len), Some(11));
        assert_eq!(runs[1].text, " f");
        assert!(runs[1].deco.is_none());

        // The blanks are the reserved descriptor, not a repeat of the shape beside them:
        // a run whose gaps drew `\u{2502}` would be a solid ladder.
        let glyphs = runs[0]
            .deco
            .as_ref()
            .expect("the indent is decorated")
            .glyphs();
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
            runs[0].text,
            "\u{2502}\u{a0}\u{a0} \u{2514}\u{2500}\u{2500}"
        );
        assert_eq!(runs[0].deco.as_ref().map(Deco::len), Some(7));
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
        row.set_wrapped(true);

        let runs = row.line_runs();
        assert_eq!(
            runs.len(),
            3,
            "leading blanks, the glyphs, the padding: {runs:?}"
        );
        assert_eq!(runs[0].text, "  ");
        assert!(runs[0].deco.is_none());
        assert_eq!(runs[1].text, "\u{2500}\u{2500}");
        assert_eq!(runs[1].deco.as_ref().map(Deco::len), Some(2));
        // Every column out to `cols`, which is what a wrapped row contributes.
        assert_eq!(runs[2].text, "        ");
        assert!(runs[2].deco.is_none());
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
        assert_eq!(runs[1].text, " x ");
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
            runs.iter().map(|r| r.cols).sum::<usize>(),
            5,
            "a, a wide character on two cells, a box glyph, and an accented e"
        );
        assert_eq!(
            runs.iter().map(|r| r.text.chars().count()).sum::<usize>(),
            5,
            "and one more character than columns on one side, one fewer on the other"
        );
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
        // Plain ASCII, a box glyph, a shade block, a wide character and a zero-width
        // mark -- every branch `DecoCell::classify` and the width logic can take.
        let chars = [
            'a', 'b', ' ', '\u{2500}', '\u{2503}', '\u{2591}', '\u{6f22}',
        ];

        // Both paths, deliberately. `runs_to` sends a row with attachments to
        // `build_runs` and a row without to `build_plain_runs`, and with attachments
        // sprinkled at 5 cells in 16 essentially every generated row has one -- so a
        // single pass would have left the plain path, the one this test was written for,
        // never executed once.
        let mut plain_rows = 0;
        let mut attached_rows = 0;
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
                    3 => row.mark(col, MarkId::from_index(((r >> 40) % 4) as u32)),
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

            if row.meta.extras.is_some() {
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
                let mut expected = row.runs_to_reference(end);
                Row::absorb_blank_runs(&mut expected);
                assert_eq!(
                    row.runs_to(end),
                    expected,
                    "case {case}, end {end}: runs disagree with the reference"
                );
            }
        }

        // Asserted, not assumed: this test is only worth anything if both
        // implementations actually ran, and which one runs is decided by whether the row
        // happened to pick up an attachment.
        assert!(
            plain_rows > 1_000 && attached_rows > 1_000,
            "both run builders must be exercised: {plain_rows} plain, {attached_rows} attached"
        );
    }

    #[test]
    fn insert_blank_keeps_the_row_exactly_cols_wide() {
        let plain = |ch| Cell::new(ch, StyleId::DEFAULT);
        let text = |row: &Row| row.cells().iter().map(|c| c.ch).collect::<String>();

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
        row.mark(1, MarkId::from_index(7));
        row.combine(1, '\u{301}');
        row.set(1, Cell::new('a', StyleId::DEFAULT));
        // The combining mark went with the character it rode; the semantic mark is a
        // position in the stream and stays. `OSC 133;A' arrives before the prompt is
        // printed, so without this every prompt mark would die to its own prompt's first
        // character.
        assert_eq!(
            row.marks().collect::<Vec<_>>(),
            vec![(1, MarkId::from_index(7))]
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
            vec![(1, MarkId::from_index(7))]
        );
        row.erase_all(StyleId::DEFAULT);
        assert_eq!(
            row.marks().collect::<Vec<_>>(),
            vec![(1, MarkId::from_index(7))]
        );

        // The row ceasing to be what it was does take it: recycled at the bottom of a
        // scroll, or with the column it sat on gone.
        row.clear(StyleId::DEFAULT);
        assert!(row.marks().next().is_none());
        row.mark(1, MarkId::from_index(8));
        row.resize(1, StyleId::DEFAULT);
        assert!(row.marks().next().is_none());
    }

    #[test]
    fn marks_on_one_row_are_bounded() {
        let mut row = Row::new(4);
        for i in 0..(MARKS_PER_ROW as u32 * 3) {
            row.mark(1, MarkId::from_index(i));
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
        assert!(marks.iter().all(|(at, _)| *at == 1));
    }

    #[test]
    fn marks_at_different_columns_are_kept_apart() {
        let mut row = Row::new(4);
        // `OSC 133;B` and `;C` land on the same cell whenever an empty line is submitted,
        // and each names a different record in Emacs.
        row.mark(0, MarkId::from_index(1));
        row.mark(0, MarkId::from_index(2));
        row.mark(3, MarkId::from_index(3));
        assert_eq!(
            row.marks().collect::<Vec<_>>(),
            vec![
                (0, MarkId::from_index(1)),
                (0, MarkId::from_index(2)),
                (3, MarkId::from_index(3))
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
