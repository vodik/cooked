//! Cells, styling, and the row representation the renderer consumes.

use std::ops::{BitAnd, BitOr, BitOrAssign, Not};
use unicode_width::UnicodeWidthChar;

use super::glyph::{self, BoxGlyph};
use super::image::Placement;
use super::link::LinkId;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Hash)]
pub enum Color {
    #[default]
    Default,
    Indexed(u8),
    Rgb(u8, u8, u8),
}

impl Color {
    /// This colour as the tagged `u32` a style span carries. `cooked--color-spec' in
    /// lisp/cooked-face.el is the only reader, and its docstring restates this layout.
    ///
    /// The tag is the *top* byte, which is the whole point of the arrangement rather
    /// than an arbitrary choice of where to put it. Records go over the boundary
    /// little-endian, so the tag lands at byte 3 of the field and Lisp can dispatch on a
    /// single `aref' — and for the two common variants it never has to assemble the
    /// other three bytes at all. `Default' reads one byte and stops; `Indexed' reads the
    /// tag and byte 0. Only `Rgb', which is rare in practice because the palette is what
    /// shells and TUIs actually emit, pays for three more.
    ///
    ///   tag 0  `Default' — the remaining bytes are zero, so the whole field is zero
    ///   tag 1  `Indexed' — the index in bits 0-7
    ///   tag 2  `Rgb'     — r in bits 16-23, g in 8-15, b in 0-7
    ///
    /// A fixed four bytes rather than a variable-length spelling, because the span
    /// record it sits in has to be steppable by a constant: Lisp walks the packed string
    /// by adding a stride, and a colour that changed the stride would force it to decode
    /// every field of every span merely to find the next one. Four bytes is also the
    /// narrowest fixed width that can hold all three variants — `Rgb' alone needs 24
    /// bits of value — so nothing is being spent here that a smaller field would save.
    ///
    /// `Default' encoding as all-zero is worth the byte ordering it costs: it is by far
    /// the commonest value, appearing as the underline colour of essentially every span
    /// and as the background of most, and it makes the Lisp fast path a comparison
    /// against a byte that is already in hand.
    pub fn packed(self) -> u32 {
        match self {
            Self::Default => 0,
            Self::Indexed(i) => (1 << 24) | u32::from(i),
            Self::Rgb(r, g, b) => {
                (2 << 24) | (u32::from(r) << 16) | (u32::from(g) << 8) | u32::from(b)
            }
        }
    }
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
    /// keeps its old meaning of "underlined at all", so every existing test of that bit
    /// still reads true regardless of style, and `SGR 4` alone is style 1.
    const UL_SHIFT: u16 = 8;
    const UL_MASK: u16 = 0b111 << Self::UL_SHIFT;

    pub const fn bits(self) -> u16 {
        self.0
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Hash)]
pub struct Style {
    pub fg: Color,
    pub bg: Color,
    pub attrs: Attrs,
}

impl Style {
    /// What an erase leaves behind: the background bar, and nothing else.
    ///
    /// This is `bce`, which terminfo advertises and which ncurses optimises on the
    /// strength of — it sets a background and erases rather than writing spaces, so
    /// dropping the pen here loses every coloured panel and status bar.
    ///
    /// Deliberately *not* the whole pen. `Row::content_len` counts a styled blank as
    /// content, so filling with a pen that merely has a foreground or an attribute set
    /// would make `SGR 31` followed by `EL` append trailing cells to the row — trailing
    /// whitespace in the scrollback of essentially every coloured shell prompt. Reducing
    /// to the background means that when no background is set the result is
    /// `Style::default()`, and the common case stays exactly as it was.
    ///
    /// Reverse video survives because it is resolved in `cooked--build-face`, where the
    /// bar's colour is then the foreground; dropping the flag would erase the drawing.
    pub fn erase(self) -> Self {
        if self.attrs.contains(Attrs::REVERSE) {
            // Every field named, so no `..Self::default()` tail: `Style` has exactly these
            // three, and a tail that updates nothing is a lint rather than a hedge against
            // a fourth arriving later.
            Self {
                fg: self.fg,
                bg: self.bg,
                attrs: Attrs::REVERSE,
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
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cell {
    pub ch: char,
    pub style: Style,
}

pub(crate) const CONTINUATION: char = '\0';
pub(crate) const BLANK: char = ' ';

impl Default for Cell {
    fn default() -> Self {
        Self {
            ch: BLANK,
            style: Style::default(),
        }
    }
}

impl Cell {
    pub fn blank(style: Style) -> Self {
        Self { ch: BLANK, style }
    }

    pub fn is_continuation(self) -> bool {
        self.ch == CONTINUATION
    }

    /// Columns occupied; wide characters claim two.
    pub fn width(self) -> usize {
        self.ch.width().unwrap_or(1).max(1)
    }
}

/// What one character displays in place of the glyph its font would draw.
///
/// The unit before grouping. A box-drawing character resolves to a shape Emacs
/// rasterizes; an image cell will resolve to a slice of a transmitted image. Both are
/// the same arrangement — Rust names a thing per character, Emacs renders it, caches it,
/// and hangs it on the text as a `display` property — which is why they share a type
/// rather than each growing one.
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
    /// there is nothing to keep on the row and nothing to maintain when the cell is
    /// overwritten. Attachments held in [`Extras`] are the other source, and they cannot
    /// work this way because no character stands for them.
    /// `#[inline]` because it is a one-line forwarder on the per-cell path; see
    /// [`glyph::classify`], which carries the fast path this hands through to.
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
    /// Packed rather than a list of Lisp objects because this is on the path every
    /// damaged row of every frame takes, and box drawing is what full-screen programs
    /// are made of. The two kinds pack differently, and the difference is not an
    /// accident of how each grew:
    ///
    /// **Glyphs** are `(bits: u16, count: u16)` per *run of identical shapes* — four
    /// bytes for a whole border row rather than two bytes eighty times. The saving that
    /// matters is not the bytes: it is that Rust already knows the shape repeats, and
    /// emitting it once per character threw that away and left `cooked--apply-glyph-deco'
    /// to rediscover it by comparison. Emacs is the bottleneck here — the parser runs at
    /// 74-422 MB/s while the apply path manages roughly 21 MB/s equivalent — so work the
    /// protocol leaves for Lisp to reconstruct is work in the wrong place. With the count
    /// in hand Lisp looks the image spec up once for the run and hangs one shared
    /// `cooked-deco' record over all of it, instead of once and one per cell.
    ///
    /// No flag rides along to say a shape dithers, though [`BoxGlyph`] knows: the only
    /// thing Lisp does with that answer is decide whether a cell's dither phase can vary
    /// down the run, and run-length encoding already demotes that question from once per
    /// character to once per record. A bit that saves one `logand` per eighty cells is
    /// not worth a field that has to mean the same thing on both sides of the boundary
    /// forever. `cooked--box-shade-p' keeps asking, and the count field stays a plain
    /// u16 with no reserved bits.
    ///
    /// **Images** stay one 12-byte record per character — `(id: u32, cell_row: u16,
    /// cell_col: u16, cols: u16, rows: u16)` — because the Lisp side genuinely needs one
    /// per character: each cell displays its own slice of the picture, named by that
    /// cell's row and column within it, and `cooked--apply-image-deco' explains why that
    /// per-cell model is what survives a scroll, an overwrite and a rewrap. A run-length
    /// record would compress the wire and buy nothing on the far side, which is the half
    /// that costs.
    ///
    /// A count is never zero, and is capped at [`u16::MAX`] by splitting the record —
    /// unreachable at any terminal width, since a run cannot outlast its row, but the
    /// format is total rather than merely adequate for the widths that exist.
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
                    packed.extend_from_slice(&place.id.0.to_le_bytes());
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
    /// Not derivable from `text` without redoing the width classification the grid
    /// already did: `text` holds one character per *cell*, so a wide character is one
    /// `char` standing on two columns and a combining mark is a `char` standing on none.
    /// Accumulated as the run is built, out of the cells being walked anyway — see
    /// [`Row::build_plain_runs`] — because the whole point is that nobody downstream
    /// should have to ask a width table a second time. `Block::push_runs` in the crate
    /// root sums it per row and hands the total to Emacs, which would otherwise call
    /// `string-width' on every rendered row of every frame; see `cooked--row-cells'.
    pub cols: usize,
    pub style: Style,
    /// One decoration per character in `text`, index-aligned with `text.chars()`;
    /// `None` for an ordinary text run. Never mixed with a `None` run, nor with a run
    /// of another kind, even when `style` matches — see [`Row::build_runs`].
    pub deco: Option<Deco>,
    /// `SGR 58`, the underline's own colour. Held on the run rather than in [`Style`]
    /// because it lives in a side table on the row — see [`Row::extras`].
    pub underline: Color,
    /// The `OSC 8` hyperlink these characters are part of, if any.
    ///
    /// A side-table attachment like the underline colour, and a run boundary in its own
    /// right — see [`Row::build_runs`] — so a destination that opens or closes without
    /// any style changing still splits the run. Nothing else can express that: the id
    /// is the only thing Lisp has to hang a keymap on the right characters with.
    pub link: Option<LinkId>,
}

/// How many semantic marks one row will hold before the oldest is dropped.
///
/// Eight covers the real shapes several times over -- a prompt row carries the previous
/// command's `D' and the new prompt's `A', `B' and `C', and a reprinted prompt can double
/// that -- while keeping the whole grid's worth bounded at a few hundred entries. See
/// [`Row::mark`] for why a bound is needed at all.
pub(crate) const MARKS_PER_ROW: usize = 8;

/// The wire name for one OSC 133 semantic mark, so Emacs can be told where a mark it
/// already holds a buffer marker for has *moved* to.
///
/// A dense counter rather than anything derived from the position, which is the whole
/// point: the position is what a rewrap changes. Handed out in [`super::term::State`],
/// stored only in [`Extra::Mark`], and never reused -- see the module docs on
/// `Delta::marks` for the round trip.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct MarkId(pub u32);

/// Something attached to one column that is too rare to live in a [`Cell`].
///
/// One enum rather than a side table per feature. The tables it replaces had drifted
/// apart — marks were pruned by [`Row::set`] while underline colours were repaired a
/// layer up, ICH and DCH dropped one and shifted neither, and the rewrap carried both
/// through four near-identical rebase loops. Every such divergence was a place a third
/// kind could be maintained wrongly without any test noticing, and images are that third
/// kind.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Extra {
    /// Zero-width characters — combining marks, variation selectors — riding the cell.
    Marks(Box<str>),
    /// `SGR 58`, the underline's own colour.
    Underline(Color),
    /// One cell of a transmitted image.
    Image(Placement),
    /// One cell of an `OSC 8` hyperlink, naming its destination.
    Link(LinkId),
    /// An OSC 133 semantic mark that fell on this cell.
    ///
    /// The odd one out, and deliberately: the other three describe how the cell is
    /// *drawn*, while this describes a position in the byte stream that happened to be
    /// here. It rides a cell for one reason -- so that everything which moves a cell
    /// moves the mark with it. A rewrap re-lays the grid at a new width and Emacs
    /// rebuilds every live row from it, which leaves the buffer markers it took from the
    /// original anchor pointing at text that has moved; the mark comes out of the rewrap
    /// on the cell it went in on, and the drain reports where that is now.
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
    /// A combining mark is text — dropping it loses a character. An underline colour is
    /// not, and must not be: [`Row::runs`] cannot see one either, and the two have to
    /// agree or a rewrap stops round-tripping what was on screen.
    pub fn is_content(&self) -> bool {
        match self {
            Self::Marks(_) => true,
            Self::Underline(_) => false,
            // An image cell is a blank in the default style, so without this the row it
            // sits on measures as empty: trimmed off the end by `Row::content_len`,
            // judged textless by `Row::has_text`, absorbed by `Row::is_blank`. This is
            // the case the whole `is_content` distinction exists for.
            Self::Image(_) => true,
            // Decoration, like an underline colour and for the same reason: a link is a
            // property *of* the characters under it, and a run of blanks inside one is
            // still a run of blanks. A row that carries nothing but a hyperlink's
            // trailing spaces must still measure as empty.
            Self::Link(_) => false,
            // Emphatically not content. A prompt mark lands on the cell the cursor was
            // on, which is routinely a blank one -- an `A' arrives before the prompt is
            // printed and a `D' after the last newline -- and a mark that made its row
            // measure as occupied would keep a screenful of blank rows alive across
            // every resize.
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

    /// Drop the attachments on `col` that `which` selects, keeping the rest.
    fn prune_kind(&mut self, col: usize, which: impl Fn(&Extra) -> bool) {
        self.entries
            .retain(|(at, extra)| usize::from(*at) != col || !which(extra));
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
/// The exception is not a corner case, which is why it is a parameter rather than a
/// second function: [`Marks::Keep`] is the path an erase takes, and a shell redraws its
/// prompt line with `CSI K` on every keystroke. A mark dropped there would be gone within
/// one character of being made. What is being erased is the *drawing*; the mark is a
/// position in the byte stream that happens to be at this column, and no amount of
/// redrawing over it moves it.
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

/// A single line of the terminal, with per-column rarities held in a side table.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Row {
    cells: Vec<Cell>,
    /// Marks, underline colours and anything else attached to a single column.
    ///
    /// All of it is rare — combining marks are, and an underline colour is essentially
    /// only an editor drawing LSP diagnostics — and none of it can go in [`Cell`]: a
    /// `Color` in [`Style`] would grow it from 16 bytes to 20, which measured as an
    /// 8-13% throughput loss across the whole grid for a feature almost nothing uses.
    ///
    /// Boxed, and one field rather than two, because the *inline* size of `Row` is what
    /// matters: rows are cloned on every scroll, and an inline `Vec` here measured as a
    /// 12% loss on the repaint benchmark before it was boxed away. `Option<Vec<_>>` is
    /// 24 bytes and `Option<Box<[_]>>` 16, while `Option<Box<Extras>>` is 8 — one
    /// null-optimised pointer. Collapsing the two tables into one took `Row` from 32
    /// bytes of side-table to 8.
    ///
    /// `None` whenever there is nothing attached, which is almost always, so
    /// [`Row::runs`] can specialise on a null check instead of asking per cell.
    extras: Option<Box<Extras>>,
    pub wrapped: bool,
}

impl Row {
    pub fn new(cols: usize) -> Self {
        Self {
            cells: vec![Cell::default(); cols],
            extras: None,
            wrapped: false,
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
            extras: (!extras.is_empty()).then(|| Box::new(Extras { entries: extras })),
            wrapped,
        }
    }

    pub fn extras(&self) -> &[(u16, Extra)] {
        self.extras.as_deref().map_or(&[], Extras::entries)
    }

    /// Attach EXTRA to COL, in addition to whatever is already there.
    fn attach(&mut self, col: usize, extra: Extra) {
        self.extras
            .get_or_insert_with(Default::default)
            .insert(col, extra);
    }

    /// Edit the side table, dropping it if the edit empties it.
    ///
    /// The single maintenance path, and the one statement of the invariant `Row` rests
    /// on: an empty table is spelled `None`, never `Some` of an empty `Extras`. Every
    /// mutator routes here rather than restating that by hand, because [`Row::runs`]
    /// specialises on the null check -- so a table left `Some` but empty is not merely
    /// untidy, it silently costs the fast path.
    fn edit_extras(&mut self, f: impl FnOnce(&mut Extras)) {
        if let Some(extras) = &mut self.extras {
            f(extras);
            if extras.entries.is_empty() {
                self.extras = None;
            }
        }
    }

    /// Drop the attachments on the columns in RANGE, `marks` deciding the exception.
    fn prune(&mut self, range: impl std::ops::RangeBounds<usize>, marks: Marks) {
        self.edit_extras(|extras| extras.prune(range, marks));
    }

    /// [`Row::prune`] for exactly one column, out of line and marked cold.
    ///
    /// Both of those matter, and neither is fussiness. `Row::set` is the per-character
    /// write path — one `movups` per cell, and the whole benchmark lives in it — so it
    /// has to stay straight-line code. Calling `prune` with a `RangeInclusive` instead
    /// cost ~4% of the full-screen repaint benchmark: the range is three words with an
    /// exhausted flag, and the optimiser built it on the stack *before* testing whether
    /// the row had any attachments at all, so every character written paid for it.
    /// A semantic mark is kept, and that exception is the whole of why marks work.
    /// `OSC 133;A' arrives *before* the shell prints its prompt, so the mark lands on a
    /// cell that is about to be written -- and a mark retired by the first character of
    /// the prompt would never survive to be moved by anything. The mark is a position in
    /// the stream, not a property of whatever character ends up standing there.
    #[cold]
    #[inline(never)]
    fn retire(&mut self, col: usize) {
        self.edit_extras(|extras| {
            extras
                .entries
                .retain(|(at, extra)| usize::from(*at) != col || matches!(extra, Extra::Mark(_)));
        });
    }

    /// Set or clear the underline colour at `col`.
    ///
    /// `Color::Default` only removes, so a row that has stopped being underlined returns
    /// to having no table at all rather than carrying an empty one for as long as it
    /// lives — which is what keeps [`Row::runs`] on its plain path.
    pub fn set_underline(&mut self, col: usize, color: Color) {
        self.edit_extras(|extras| extras.prune_kind(col, |e| matches!(e, Extra::Underline(_))));
        if color != Color::Default && col < self.cells.len() {
            self.attach(col, Extra::Underline(color));
        }
    }

    /// Set or clear the hyperlink at `col`.
    ///
    /// `None` only removes, so a row that has stopped being a link returns to having no
    /// table at all — the same discipline [`Row::set_underline`] keeps, and for the same
    /// reason: [`Row::runs`] specialises on the table being absent.
    pub fn set_link(&mut self, col: usize, link: Option<LinkId>) {
        self.edit_extras(|extras| extras.prune_kind(col, |e| matches!(e, Extra::Link(_))));
        if let Some(id) = link
            && col < self.cells.len()
        {
            self.attach(col, Extra::Link(id));
        }
    }

    /// Attach a semantic mark to `col`, without disturbing anything already there.
    ///
    /// No `prune_kind' counterpart to [`Row::set_link`]'s, and several marks on one cell
    /// is a state to design for rather than avoid: `OSC 133;B' and `;C' arrive at the
    /// same cell whenever the shell submits an empty line, and a prompt reprinted over
    /// the row it was already on legitimately carries the old command's marks and the new
    /// ones. Each names a different record in Emacs, and dropping one leaves that record
    /// unable to be moved.
    ///
    /// Bounded per row at [`MARKS_PER_ROW`], oldest first, because nothing else bounds
    /// it. Every other attachment is overwritten in place -- one underline colour per
    /// column, one link, one image -- while a mark is deliberately never retired by what
    /// is drawn over it, so a child that emits `OSC 133' without ever moving off the row
    /// grows this table without limit. That is not hypothetical: it is the `osc_dispatch'
    /// throughput benchmark, where it turned a linear feed quadratic and cost two orders
    /// of magnitude before this cap went in.
    pub fn mark(&mut self, col: usize, id: MarkId) {
        if col >= self.cells.len() {
            return;
        }
        // Guarded on the table's own length first, which is a load and a compare: there
        // cannot be `MARKS_PER_ROW` marks in fewer than that many entries, so an ordinary
        // row -- a prompt's four marks, an underline colour, a link -- never reaches the
        // scan below at all. Without the guard the count is paid per mark, and the
        // `osc_dispatch' benchmark is nothing but marks.
        if let Some(extras) = &mut self.extras
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
    /// Out of line and cold for the reason [`Row::retire`] is: the caller is on the OSC
    /// path, and an ordinary row -- a prompt's four marks, an underline colour, a link --
    /// never reaches it. Only a child emitting `OSC 133' over and over without moving the
    /// cursor does, which is what the bound exists for.
    ///
    /// The oldest goes, being the one whose record Emacs is least likely to still be
    /// holding: ids are handed out in stream order, while entries are kept in column
    /// order, so this asks for the smallest id rather than for the front of the table.
    /// When that entry is on this very column it is overwritten in place, which keeps the
    /// sort order and skips a remove and an insert -- and is exactly the runaway case, so
    /// the path that repeats is the cheap one.
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

    /// Every semantic mark on this row, in column order.
    pub fn marks(&self) -> impl Iterator<Item = (usize, MarkId)> + '_ {
        self.extras().iter().filter_map(|(at, extra)| match extra {
            Extra::Mark(id) => Some((usize::from(*at), *id)),
            _ => None,
        })
    }

    pub fn cells(&self) -> &[Cell] {
        &self.cells
    }

    pub fn len(&self) -> usize {
        self.cells.len()
    }

    pub fn is_empty(&self) -> bool {
        self.cells.is_empty()
    }

    pub fn get(&self, col: usize) -> Option<&Cell> {
        self.cells.get(col)
    }

    /// Write CELL at COL, retiring everything the old occupant had attached to it.
    ///
    /// One `Option` check on the write path. The obvious alternative -- an unconditional
    /// `Vec::retain` -- costs every write regardless of whether the row has attachments at
    /// all, and measured 5% of the repaint benchmark. A null test on a pointer the row
    /// already has in cache does not, so the retirement can happen here rather than being
    /// repaired a layer up behind a screen-wide latch.
    ///
    /// Returns whether the row now differs from what it was, which is what
    /// [`Screen::edit`](crate::emu::screen::Screen) turns into damage. A cell written over
    /// an identical cell is not a repaint: a TUI redrawing a frame that did not change
    /// would otherwise have Emacs delete, reinsert and re-propertize every row of it.
    ///
    /// A row carrying attachments answers `true` unconditionally, and that is the
    /// conservative half. The retirement below is itself a change -- an image placement or
    /// an underline colour goes when the character under it is rewritten, even to the same
    /// character -- and asking the side table which of its entries this column had would
    /// cost the write path exactly the scan the `Option` check exists to avoid. Rows with
    /// attachments are rare; rows repainted identically are not.
    pub fn set(&mut self, col: usize, cell: Cell) -> bool {
        let attached = self.extras.is_some();
        let Some(slot) = self.cells.get_mut(col) else {
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
    /// [`Row::set`] in bulk, and identical to calling it per character -- including the
    /// retirement of whatever the old occupants had attached. The `extras` test is
    /// hoisted out of the loop because it is a property of the row, not of the cell, and
    /// a row carrying attachments is the rare case; that hoist is the whole point of
    /// having this beside `set` rather than looping over it.
    ///
    /// Writes only as far as the row goes, so an over-long run is truncated rather than
    /// panicking. Callers size the run themselves; this is the backstop.
    ///
    /// Returns whether anything about the row changed, on [`Row::set`]'s terms and for
    /// its reasons -- the comparison per cell is one 16-byte test against a slot the
    /// store is about to write anyway, and it is what lets a repainted frame of
    /// unchanged text cost nothing on the Emacs side.
    pub fn fill_run(&mut self, col: usize, text: &str, style: Style) -> bool {
        let attached = self.extras.is_some();
        let Some(slots) = self.cells.get_mut(col..) else {
            return false;
        };
        // The comparison is a pass of its own, ahead of the stores, rather than a test
        // folded into the write loop. Both spellings answer the same question and the
        // costs are not close: `any` stops at the first cell that differs, which for a
        // frame that changed at all is almost always the first cell it writes, while the
        // folded form loads every slot it is about to store to and measured a 24%
        // throughput loss on the plain-text benchmark. A frame that did *not* change
        // pays one pass and skips the stores entirely, which is the case this is for.
        let changed = attached
            || slots
                .iter()
                .zip(text.chars())
                .any(|(slot, ch)| *slot != Cell { ch, style });
        if !changed {
            return false;
        }
        let mut placed = 0;
        for (slot, ch) in slots.iter_mut().zip(text.chars()) {
            *slot = Cell { ch, style };
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
    pub fn place(&mut self, col: usize, placement: Placement, style: Style) {
        if col >= self.cells.len() {
            return;
        }
        // `set` first, so it retires whatever the old occupant had attached before the
        // placement goes on; the other order would prune the placement just made.
        let _ = self.set(col, Cell::blank(style));
        self.attach(col, Extra::Image(placement));
    }

    /// Attach a zero-width character (combining mark, variation selector) to `col`.
    pub fn combine(&mut self, col: usize, mark: char) {
        if let Some(extras) = &mut self.extras
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
    pub fn fill(&mut self, range: impl IntoIterator<Item = usize>, style: Style) -> bool {
        // Not `set` per column. `fill` is the erase path — a full-screen program clears
        // rows every frame — and a per-cell side-table check in the loop stops this being
        // a bulk write. The tables are pruned once, outside it.
        let blank = Cell::blank(style);
        let mut lo = usize::MAX;
        let mut hi = 0;
        let mut changed = self.extras.is_some();
        for col in range {
            if let Some(slot) = self.cells.get_mut(col) {
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

    /// Whether the row holds any text, as opposed to only a background wash.
    ///
    /// Distinct from `is_blank`, and the distinction only exists because of `bce`: a row a
    /// full-screen program painted and then cleared is no longer blank — every cell
    /// carries a background — but it is not transcript either, and archiving it would push
    /// a screenful of pure colour into the scrollback.
    pub fn has_text(&self) -> bool {
        self.extras().iter().any(|(_, e)| e.is_content())
            || self.cells.iter().any(|c| c.ch != BLANK)
    }

    /// Whether the row holds nothing a resize would need to preserve.
    ///
    /// Stricter than [`Row::has_text`] on purpose: a resize must keep a background wash,
    /// so a washed row is not blank even though it holds no text.
    pub fn is_blank(&self) -> bool {
        !self.extras().iter().any(|(_, e)| e.is_content())
            && self
                .cells
                .iter()
                .all(|c| c.ch == BLANK && c.style == Style::default())
    }

    /// Blank the row and drop everything attached to it, semantic marks included.
    ///
    /// This is the row *ceasing to be what it was*: recycled at the bottom of a scroll,
    /// backfilled behind a removed row, wiped by an erase of the display. A mark left on
    /// a recycled row would be a second copy of one already archived with the row's own
    /// text -- which is how the relocation first went wrong, reporting one id twice in a
    /// drain and letting the later, blanker answer win.
    ///
    /// [`Row::erase_all`] is the other spelling, for `CSI 2K` alone.
    ///
    /// Returns nothing, where the other writers return whether they changed anything.
    /// This one is on the scroll path -- `Screen::scroll_up` clears every row it
    /// recycles, on every line of ordinary output -- and the comparison it would need is
    /// a scan of the whole row before the fill that overwrites it, which measured 22% of
    /// the plain-text benchmark for an answer that path throws away. The callers that
    /// want the answer are erasing a display, where a screen that is already blank is not
    /// the case worth optimising for.
    pub fn clear(&mut self, style: Style) {
        self.cells.fill(Cell::blank(style));
        self.extras = None;
        self.wrapped = false;
    }

    /// `CSI 2K`: blank every column, keeping semantic marks.
    ///
    /// The one whole-row erase that is not the row ending: a shell wipes its prompt line
    /// with this and immediately redraws it, on every keystroke of a completion or a
    /// history search. What goes is the drawing; the mark is a position in the stream and
    /// the prompt is about to be printed over it again. Same argument as [`Row::retire`]
    /// and [`Extras::prune`], which is the range-wise erase this is the whole-row form of.
    /// Returns whether that changed anything: a shell wiping a prompt line it is about to
    /// redraw identically is the single commonest thing a terminal is asked to do, and it
    /// need not cost a repaint. `wrapped` counts as content here — it decides where a
    /// logical line ends, which Emacs renders from.
    pub fn erase_all(&mut self, style: Style) -> bool {
        let blank = Cell::blank(style);
        let changed =
            self.extras.is_some() || self.wrapped || self.cells.iter().any(|c| *c != blank);
        self.cells.fill(blank);
        self.prune(0..self.cells.len(), Marks::Keep);
        self.wrapped = false;
        changed
    }

    /// The one place a mark is dropped by anything short of the row itself going: past
    /// `cols` there is no longer a cell for it to be attached to. Only the non-rewrapping
    /// paths reach here -- the alternate screen, and a `Resize::Clamp` -- and neither has
    /// buffer text under it for a mark to be describing.
    pub fn resize(&mut self, cols: usize, style: Style) {
        self.cells.resize(cols, Cell::blank(style));
        self.prune(cols.., Marks::Drop);
    }

    pub fn insert_blank(&mut self, col: usize, count: usize, style: Style) {
        let cols = self.cells.len();
        if col >= cols {
            return;
        }
        let n = count.min(cols - col);
        // In place, because `Cell` is `Copy` and the row's length does not change. The
        // `splice`-then-`truncate` this replaces grew `cells` past `cols` before cutting
        // it back, and the row's capacity is exactly `cols` -- so IRM cost a realloc per
        // character written in insert mode.
        self.cells.copy_within(col..cols - n, col + n);
        self.cells[col..col + n].fill(Cell::blank(style));
        // The cells from `col` on moved right; their attachments move with them, and
        // whatever was pushed off the end goes.
        self.edit_extras(|extras| extras.shift(col, n as isize, cols));
    }

    pub fn delete(&mut self, col: usize, count: usize, style: Style) {
        let cols = self.cells.len();
        if col >= cols {
            return;
        }
        let gone = (col + count).min(cols) - col;
        self.cells.drain(col..(col + count).min(cols));
        self.cells.resize(cols, Cell::blank(style));
        // The deleted columns take their attachments with them; everything to their
        // right closes the gap. Dropping the whole table here would be simpler and would
        // lose colours on columns DCH never touched.
        self.prune(col..col + gone, Marks::Keep);
        self.edit_extras(|extras| extras.shift(col + gone, -(gone as isize), cols));
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
            .cells
            .iter()
            .rposition(|c| c.ch != BLANK || c.style != Style::default())
            .map_or(0, |i| i + 1);
        // An attachment can be the last content on the row while its cell is a blank in
        // the default style — a combining mark on a space, and later an image cell, which
        // is *always* one. Guarded, so the ordinary row keeps the `rposition` alone.
        if self.extras.is_none() {
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
    /// Dispatches on whether the row has a side table at all: [`Row::build_plain_runs`]
    /// when it has none, which is nearly every row, and [`Row::build_runs`] when it has.
    /// Attachments are rare and looking one up per cell measured as ~2% of the
    /// full-screen repaint benchmark — this is the hottest read in the emulator, run
    /// over every damaged row of every frame, so the ordinary row is answered by a
    /// function with no side table in it at all rather than by a branch it retakes per
    /// cell.
    pub fn runs(&self) -> Vec<Run> {
        self.runs_to(self.content_len())
    }

    /// Runs for a row on its way into the buffer as part of a logical line.
    ///
    /// A continuation row contributes every column it has. Its trailing blanks are interior
    /// to the line — the text goes on below — and Emacs joins a wrapped row onto the line
    /// above without a newline, so trimming them would pull the continuation forward by
    /// however many columns the child left blank. [`Logical::push_row`](super::screen)
    /// measures the same rows the same way when a rewrap reassembles them; the two have to
    /// agree or a resize stops round-tripping.
    ///
    /// It also keeps every departed row exactly `cols` wide, which is the invariant
    /// [`Screen::carried`](super::screen::Screen) rests on to measure the head of the line
    /// straddling the seam.
    pub fn line_runs(&self) -> Vec<Run> {
        if self.wrapped {
            self.runs_to(self.len())
        } else {
            self.runs()
        }
    }

    /// The simplest correct statement of what [`Row::runs_to`] must produce.
    ///
    /// A reference implementation, for `runs_to_matches_the_reference` to check the fast
    /// one against. It exists because `build_runs` is the hottest read in the emulator and
    /// therefore the most tempting to optimise, while also being the thing every character
    /// Emacs renders passes through -- so an optimisation there needs something to be
    /// *equivalent to*, not merely a suite that happened to keep passing.
    ///
    /// Deliberately an independent formulation rather than a copy: the shipping version
    /// walks `entries` with a cursor and specialises on a const `EXTRAS`, and this one
    /// searches per column and branches at runtime. Two spellings of the same rules cannot
    /// share a mistake in the spelling.
    #[cfg(test)]
    pub(crate) fn runs_to_reference(&self, end: usize) -> Vec<Run> {
        let entries: &[(u16, Extra)] = self.extras.as_deref().map_or(&[], |e| &e.entries);
        let mut runs: Vec<Run> = Vec::new();
        for (col, cell) in self.cells[..end].iter().enumerate() {
            if cell.is_continuation() {
                // The column still belongs to the wide character before it, and so to
                // that character's run: `cols` counts columns, not characters.
                if let Some(run) = runs.last_mut() {
                    run.cols += 1;
                }
                continue;
            }
            let (mut underline, mut marks, mut placed, mut link) =
                (Color::Default, None, None, None);
            for (_, extra) in entries.iter().filter(|(at, _)| usize::from(*at) == col) {
                match extra {
                    Extra::Underline(color) => underline = *color,
                    Extra::Marks(text) => marks = Some(&**text),
                    Extra::Image(p) => placed = Some(*p),
                    Extra::Link(id) => link = Some(*id),
                    Extra::Mark(_) => {}
                }
            }
            let deco = placed
                .map(DecoCell::Image)
                .or_else(|| DecoCell::classify(cell.ch));
            let joins = runs.last().is_some_and(|run| {
                run.style == cell.style
                    && run.underline == underline
                    && run.link == link
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
                    underline,
                    link,
                });
            }
            if let (Some(marks), Some(run)) = (marks, runs.last_mut()) {
                run.text.push_str(marks);
            }
        }
        runs
    }

    fn runs_to(&self, end: usize) -> Vec<Run> {
        match self.extras.as_deref() {
            Some(extras) => self.build_runs(end, &extras.entries),
            None => self.build_plain_runs(end),
        }
    }

    /// [`Row::build_runs`] for a row with nothing attached, which is nearly every row.
    ///
    /// With no attachments there is no underline colour, no link and no image placement,
    /// so the only things that can end a run are the pen changing and a character that
    /// draws a shape. That collapses the per-cell decision the general form has to make
    /// into a scan for the end of the run, after which the whole span is appended at once
    /// -- one `runs.last_mut()`, one capacity check and one join test per *run* instead of
    /// per cell.
    ///
    /// It is worth having as its own function rather than another `EXTRAS` specialisation
    /// because it is a different shape, not a different constant: the general form walks
    /// cell by cell because an attachment can land on any one of them.
    ///
    /// `runs_to_matches_the_reference` is what keeps this honest -- it is checked against
    /// [`Row::runs_to_reference`] over randomised rows, including the wide characters and
    /// box glyphs that make the two disagree if the scan is wrong.
    fn build_plain_runs(&self, end: usize) -> Vec<Run> {
        let mut runs = Vec::<Run>::with_capacity(4);
        let cells = &self.cells[..end];
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
            let style = cell.style;
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
                        && (next.style != style || DecoCell::classify(next.ch).is_some())
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
                    if run.style == style
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
                        style,
                        deco: deco.map(Deco::start),
                        underline: Color::Default,
                        link: None,
                    });
                }
            }
        }
        runs
    }

    /// The row's cells as runs, for a row that has attachments to read.
    ///
    /// The attachment-free row does not come here at all: [`Row::build_plain_runs`]
    /// answers it, because it is a different shape rather than this one with the lookup
    /// switched off. That split replaced a `const EXTRAS: bool` parameter on this
    /// function, which had become dead once the plain form existed to take the `false`
    /// case -- so ENTRIES is never empty here in practice and the lookup is never
    /// skipped.
    ///
    /// ENTRIES is walked with a cursor rather than searched per column. Both sides
    /// advance through columns in order, so the whole row costs one pass over the table
    /// rather than a lookup per character — which the per-column form pays whether or not
    /// the row has a single mark on it.
    fn build_runs(&self, end: usize, entries: &[(u16, Extra)]) -> Vec<Run> {
        // Four, not `end`: the row's dominant shapes are one run of plain text and a
        // handful for a coloured prompt, so a capacity of one per column would be a far
        // bigger allocation than the growth it saves.
        let mut runs = Vec::<Run>::with_capacity(4);
        let mut at = 0;
        for (col, cell) in self.cells[..end].iter().enumerate() {
            if cell.is_continuation() {
                // A column of the wide character that opened it, hence of its run.
                if let Some(run) = runs.last_mut() {
                    run.cols += 1;
                }
                continue;
            }
            let mut underline = Color::Default;
            let mut marks = None;
            let mut placed = None;
            let mut link = None;
            while at < entries.len() && usize::from(entries[at].0) < col {
                at += 1;
            }
            for (_, extra) in entries[at..]
                .iter()
                .take_while(|(c, _)| usize::from(*c) == col)
            {
                match extra {
                    Extra::Underline(color) => underline = *color,
                    Extra::Marks(text) => marks = Some(&**text),
                    Extra::Image(p) => placed = Some(*p),
                    Extra::Link(id) => link = Some(*id),
                    // Nothing to draw and nothing to split a run on: a mark is a
                    // position, not a property of the characters. Silently skipping
                    // it here is what keeps `Row::runs' byte-identical to what it
                    // was before marks existed.
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
                        && run.underline == underline
                        // A link boundary splits a run even when nothing else changed,
                        // which is the whole point of carrying it here: a program that
                        // prints `see <link>foo</link> bar' in one colour gives Lisp one
                        // run of identical style, and only this tells it where the
                        // clickable part of it is.
                        && run.link == link
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
                    // The run cannot outgrow the columns left in the row, and for the
                    // ASCII that dominates, bytes and columns are the same number -- so
                    // this is one allocation where growing from `String::from(char)`'s
                    // capacity of 1 took roughly five. Over-allocates for a run that ends
                    // early, which the reallocation it replaces cost more than.
                    text: {
                        let mut text = String::with_capacity(end - col);
                        text.push(cell.ch);
                        text
                    },
                    cols: 1,
                    style: cell.style,
                    deco: deco.map(Deco::start),
                    underline,
                    link,
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runs_merge_by_style_and_trim_trailing_blanks() {
        let mut row = Row::new(10);
        let red = Style {
            fg: Color::Indexed(1),
            ..Style::default()
        };
        for (i, c) in "hi".chars().enumerate() {
            row.set(i, Cell { ch: c, style: red });
        }
        row.set(
            2,
            Cell {
                ch: '!',
                style: Style::default(),
            },
        );

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
        let style = Style::default();
        row.set(0, Cell { ch: 'a', style });
        row.set(
            1,
            Cell {
                ch: '\u{2500}',
                style,
            },
        ); // ─, same style as its neighbors
        row.set(2, Cell { ch: 'b', style });

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
        let style = Style::default();
        for (i, c) in "\u{250C}\u{2500}\u{2510}".chars().enumerate() {
            row.set(i, Cell { ch: c, style });
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
        let red = Style {
            fg: Color::Indexed(1),
            ..Style::default()
        };
        row.set(
            0,
            Cell {
                ch: '\u{2500}',
                style: Style::default(),
            },
        );
        row.set(
            1,
            Cell {
                ch: '\u{2500}',
                style: red,
            },
        );

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
        row.set(
            0,
            Cell {
                ch: 'e',
                style: Style::default(),
            },
        );
        row.combine(0, '\u{301}');
        assert_eq!(row.to_text(), "e\u{301}");
    }

    #[test]
    fn overwriting_a_cell_drops_its_marks() {
        let mut row = Row::new(4);
        row.set(
            0,
            Cell {
                ch: 'e',
                style: Style::default(),
            },
        );
        row.combine(0, '\u{301}');
        row.set(
            0,
            Cell {
                ch: 'x',
                style: Style::default(),
            },
        );
        assert_eq!(row.to_text(), "x");
    }

    #[test]
    fn wide_cells_skip_their_continuation() {
        let mut row = Row::new(4);
        row.set(
            0,
            Cell {
                ch: '漢',
                style: Style::default(),
            },
        );
        row.set(
            1,
            Cell {
                ch: CONTINUATION,
                style: Style::default(),
            },
        );
        assert_eq!(row.to_text(), "漢");
    }

    #[test]
    fn delete_shifts_left_and_backfills() {
        let mut row = Row::new(4);
        for (i, c) in "abcd".chars().enumerate() {
            row.set(
                i,
                Cell {
                    ch: c,
                    style: Style::default(),
                },
            );
        }
        row.delete(1, 2, Style::default());
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
    fn an_underline_colour_alone_is_not_content() {
        // The invariant `content_len`'s contract rests on: it and `runs` must agree about
        // where a line ends, and `runs` cannot see a colour on a cell with nothing in it.
        let mut row = Row::new(4);
        row.set_underline(1, Color::Indexed(196));
        assert_eq!(row.content_len(), 0);
        assert!(!row.has_text());
        assert!(row.is_blank());
    }

    #[test]
    fn ich_shifts_attachments_with_their_cells() {
        let mut row = Row::new(6);
        row.set(
            0,
            Cell {
                ch: 'a',
                style: Style::default(),
            },
        );
        row.set_underline(0, Color::Indexed(196));
        row.combine(0, '\u{0301}');

        row.insert_blank(0, 2, Style::default());

        assert_eq!(
            row.extras(),
            [
                (2, Extra::Underline(Color::Indexed(196))),
                (2, Extra::Marks("\u{0301}".into())),
            ]
        );
    }

    #[test]
    fn ich_drops_only_what_it_pushes_off_the_end() {
        let mut row = Row::new(4);
        row.set_underline(0, Color::Indexed(1));
        row.set_underline(3, Color::Indexed(2));

        row.insert_blank(0, 2, Style::default());

        // Column 0 moved to 2; column 3 went off the end at 5.
        assert_eq!(row.extras(), [(2, Extra::Underline(Color::Indexed(1)))]);
        assert!(
            row.extras()
                .iter()
                .all(|(at, _)| usize::from(*at) < row.len())
        );
    }

    #[test]
    fn dch_closes_the_gap_and_spares_the_columns_before_it() {
        let mut row = Row::new(6);
        row.set_underline(0, Color::Indexed(1));
        row.set_underline(3, Color::Indexed(2));
        row.set_underline(5, Color::Indexed(3));

        // Delete columns 3 and 4. Column 0 is untouched; column 5 closes up to 3.
        row.delete(3, 2, Style::default());

        assert_eq!(
            row.extras(),
            [
                (0, Extra::Underline(Color::Indexed(1))),
                (3, Extra::Underline(Color::Indexed(3))),
            ]
        );
    }

    #[test]
    fn a_row_that_loses_its_last_attachment_loses_its_table() {
        // The `None` is what keeps `runs` on the specialisation with no side table in it,
        // so returning to it matters as much as getting off it.
        let mut row = Row::new(4);
        row.set_underline(1, Color::Indexed(196));
        assert!(row.extras.is_some());
        row.set_underline(1, Color::Default);
        assert!(row.extras.is_none());
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
        let style = Style::default();
        for (col, ch) in [(0, 'a'), (1, '\u{6f22}'), (3, '\u{2500}'), (4, 'e')] {
            row.set(col, Cell { ch, style });
        }
        row.set(
            2,
            Cell {
                ch: CONTINUATION,
                style,
            },
        );
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
        let palette = [
            Color::Default,
            Color::Indexed(1),
            Color::Indexed(200),
            Color::Rgb(10, 20, 30),
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
                let style = Style {
                    fg: palette[((r >> 8) % 4) as usize],
                    bg: palette[((r >> 16) % 4) as usize],
                    attrs: if (r >> 24) % 3 == 0 {
                        Attrs::BOLD
                    } else {
                        Attrs::NONE
                    },
                };
                let width = if ch == '\u{6f22}' { 2 } else { 1 };
                if col + width > COLS {
                    break;
                }
                row.set(col, Cell { ch, style });
                if width == 2 {
                    row.set(
                        col + 1,
                        Cell {
                            ch: CONTINUATION,
                            style,
                        },
                    );
                }
                // Attachments, each rare enough that most cells carry none -- which is
                // also the distribution the real grid has.
                match if attachments {
                    (r >> 32) % 16
                } else {
                    u64::MAX
                } {
                    0 => row.set_underline(col, Color::Indexed(196)),
                    1 => row.set_link(col, Some(LinkId(((r >> 40) % 3) as u32))),
                    2 => row.combine(col, '\u{301}'),
                    3 => row.mark(col, MarkId(((r >> 40) % 4) as u32)),
                    4 => row.place(
                        col,
                        Placement {
                            id: crate::emu::image::ImageId(((r >> 40) % 2) as u32),
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

            if row.extras.is_some() {
                attached_rows += 1;
            } else {
                plain_rows += 1;
            }
            for end in 0..=COLS {
                assert_eq!(
                    row.runs_to(end),
                    row.runs_to_reference(end),
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
        let plain = |ch| Cell {
            ch,
            style: Style::default(),
        };
        let text = |row: &Row| row.cells().iter().map(|c| c.ch).collect::<String>();

        let mut row = Row::new(4);
        for (col, ch) in "abcd".chars().enumerate() {
            row.set(col, plain(ch));
        }

        // The ordinary shift: `d` falls off the end rather than widening the row.
        row.insert_blank(1, 1, Style::default());
        assert_eq!(row.len(), 4);
        assert_eq!(text(&row), "a bc");

        // The boundary the in-place rewrite has to get right: `count` at or past the
        // columns remaining leaves an empty copy range, so the tail is filled and nothing
        // is read from beyond the row.
        row.insert_blank(2, 99, Style::default());
        assert_eq!(row.len(), 4);
        assert_eq!(text(&row), "a   ");

        // Inserting at the last column touches exactly that column.
        let mut row = Row::new(4);
        for (col, ch) in "abcd".chars().enumerate() {
            row.set(col, plain(ch));
        }
        row.insert_blank(3, 1, Style::default());
        assert_eq!(text(&row), "abc ");
    }

    #[test]
    fn a_mark_outlives_what_is_drawn_over_it() {
        let mut row = Row::new(4);
        row.mark(1, MarkId(7));
        row.set_underline(1, Color::Indexed(196));
        row.set(
            1,
            Cell {
                ch: 'a',
                style: Style::default(),
            },
        );
        // The underline went with the character it decorated; the mark is a position in
        // the stream and stays. `OSC 133;A' arrives before the prompt is printed, so
        // without this every prompt mark would die to its own prompt's first character.
        assert_eq!(row.marks().collect::<Vec<_>>(), vec![(1, MarkId(7))]);
        assert!(
            !row.extras()
                .iter()
                .any(|(_, e)| matches!(e, Extra::Underline(_)))
        );

        // An erase is the same case reached the other way: a shell redrawing its prompt
        // line wipes it with `CSI K` on every keystroke.
        row.fill(0..4, Style::default());
        assert_eq!(row.marks().collect::<Vec<_>>(), vec![(1, MarkId(7))]);
        row.erase_all(Style::default());
        assert_eq!(row.marks().collect::<Vec<_>>(), vec![(1, MarkId(7))]);

        // The row ceasing to be what it was does take it: recycled at the bottom of a
        // scroll, or with the column it sat on gone.
        row.clear(Style::default());
        assert!(row.marks().next().is_none());
        row.mark(1, MarkId(8));
        row.resize(1, Style::default());
        assert!(row.marks().next().is_none());
    }

    #[test]
    fn marks_on_one_row_are_bounded() {
        let mut row = Row::new(4);
        for i in 0..(MARKS_PER_ROW as u32 * 3) {
            row.mark(1, MarkId(i));
        }
        let marks: Vec<_> = row.marks().collect();
        assert_eq!(marks.len(), MARKS_PER_ROW, "the bound holds");
        // The newest survive: a child that emits `OSC 133' without ever moving off the
        // row would otherwise grow this table without limit, and the records Emacs still
        // holds markers for are the recent ones.
        assert_eq!(
            marks.last().map(|(_, id)| *id),
            Some(MarkId(MARKS_PER_ROW as u32 * 3 - 1))
        );
        assert!(marks.iter().all(|(at, _)| *at == 1));
    }

    #[test]
    fn marks_at_different_columns_are_kept_apart() {
        let mut row = Row::new(4);
        // `OSC 133;B` and `;C` land on the same cell whenever an empty line is submitted,
        // and each names a different record in Emacs.
        row.mark(0, MarkId(1));
        row.mark(0, MarkId(2));
        row.mark(3, MarkId(3));
        assert_eq!(
            row.marks().collect::<Vec<_>>(),
            vec![(0, MarkId(1)), (0, MarkId(2)), (3, MarkId(3))]
        );
    }

    #[test]
    fn overwriting_a_cell_retires_everything_attached_to_it() {
        let mut row = Row::new(4);
        row.set(
            1,
            Cell {
                ch: 'a',
                style: Style::default(),
            },
        );
        row.set_underline(1, Color::Indexed(196));
        row.combine(1, '\u{0301}');

        row.set(
            1,
            Cell {
                ch: 'b',
                style: Style::default(),
            },
        );

        assert!(row.extras().is_empty());
        assert!(row.extras.is_none());
    }

    #[test]
    fn attachments_on_other_columns_survive_a_write() {
        let mut row = Row::new(4);
        row.set_underline(1, Color::Indexed(1));
        row.set_underline(2, Color::Indexed(2));
        row.set(
            1,
            Cell {
                ch: 'x',
                style: Style::default(),
            },
        );
        assert_eq!(row.extras(), [(2, Extra::Underline(Color::Indexed(2)))]);
    }
}
