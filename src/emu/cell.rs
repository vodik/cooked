//! Cells, styling, and the row representation the renderer consumes.

use std::ops::{BitAnd, BitOr, BitOrAssign, Not};
use unicode_width::UnicodeWidthChar;

use super::glyph::{self, BoxGlyph};
use super::image::Placement;

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

pub const CONTINUATION: char = '\0';
pub const BLANK: char = ' ';

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
pub enum DecoCell {
    Glyph(BoxGlyph),
    Image(Placement),
}

/// The decoration of a whole run, one entry per character of [`Run::text`].
///
/// A run is homogeneous in its kind: [`Row::build_runs`] will not merge characters
/// decorated differently into one run. That is what lets the wire format carry a single
/// kind tag plus a fixed-width record per character, instead of tagging every character
/// — and it is why the box-drawing case still crosses at exactly two bytes each.
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
    pub style: Style,
    /// One decoration per character in `text`, index-aligned with `text.chars()`;
    /// `None` for an ordinary text run. Never mixed with a `None` run, nor with a run
    /// of another kind, even when `style` matches — see [`Row::build_runs`].
    pub deco: Option<Deco>,
    /// `SGR 58`, the underline's own colour. Held on the run rather than in [`Style`]
    /// because it lives in a side table on the row — see [`Row::extras`].
    pub underline: Color,
}

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
pub struct Extras {
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
        }
    }
}

impl Extras {
    pub fn entries(&self) -> &[(u16, Extra)] {
        &self.entries
    }

    fn insert(&mut self, col: usize, extra: Extra) {
        let at = self.entries.partition_point(|(c, _)| usize::from(*c) <= col);
        self.entries.insert(at, (col as u16, extra));
    }

    /// Drop every attachment on the columns in `range`.
    fn prune(&mut self, range: impl std::ops::RangeBounds<usize>) {
        self.entries.retain(|(at, _)| !range.contains(&usize::from(*at)));
    }

    /// Drop the attachments on `col` that `which` selects, keeping the rest.
    fn prune_kind(&mut self, col: usize, which: impl Fn(&Extra) -> bool) {
        self.entries
            .retain(|(at, extra)| usize::from(*at) != col || !which(extra));
    }

    /// Move every attachment from `col` onward by `by`, dropping what falls off `cols`.
    ///
    /// The arithmetic ICH and DCH used to skip. They dropped the tables instead — DCH
    /// losing colours on columns it never touched — while the rewrap had implemented the
    /// shift correctly all along, in `Logical::take_front`.
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

    /// Drop the attachments on the columns in RANGE, and the table itself if it empties.
    ///
    /// The single maintenance path. Every mutator routes here, which is what stops the
    /// kinds drifting apart the way `marks` and `underlines` had.
    fn prune(&mut self, range: impl std::ops::RangeBounds<usize>) {
        if let Some(extras) = &mut self.extras {
            extras.prune(range);
            if extras.entries.is_empty() {
                self.extras = None;
            }
        }
    }

    /// [`Row::prune`] for exactly one column, out of line and marked cold.
    ///
    /// Both of those matter, and neither is fussiness. `Row::set` is the per-character
    /// write path — one `movups` per cell, and the whole benchmark lives in it — so it
    /// has to stay straight-line code. Calling `prune` with a `RangeInclusive` instead
    /// cost ~4% of the full-screen repaint benchmark: the range is three words with an
    /// exhausted flag, and the optimiser built it on the stack *before* testing whether
    /// the row had any attachments at all, so every character written paid for it.
    #[cold]
    #[inline(never)]
    fn retire(&mut self, col: usize) {
        if let Some(extras) = &mut self.extras {
            extras.entries.retain(|(at, _)| usize::from(*at) != col);
            if extras.entries.is_empty() {
                self.extras = None;
            }
        }
    }

    /// Set or clear the underline colour at `col`.
    ///
    /// `Color::Default` only removes, so a row that has stopped being underlined returns
    /// to having no table at all rather than carrying an empty one for as long as it
    /// lives — which is what keeps [`Row::runs`] on its plain path.
    pub fn set_underline(&mut self, col: usize, color: Color) {
        if let Some(extras) = &mut self.extras {
            extras.prune_kind(col, |e| matches!(e, Extra::Underline(_)));
            if extras.entries.is_empty() {
                self.extras = None;
            }
        }
        if color != Color::Default && col < self.cells.len() {
            self.attach(col, Extra::Underline(color));
        }
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
    /// One `Option` check on the write path, where there used to be an unconditional
    /// `Vec::retain` for marks and, for underline colours, nothing at all — those were
    /// repaired a layer up by `Screen::mark_underline` behind a latch, because a branch
    /// here measured as 5% of the repaint benchmark. The latch is gone: this branch is a
    /// null test on a pointer the row already has in cache, and it replaces a call that
    /// every write was paying regardless.
    pub fn set(&mut self, col: usize, cell: Cell) {
        if let Some(slot) = self.cells.get_mut(col) {
            *slot = cell;
            if self.extras.is_some() {
                self.retire(col);
            }
        }
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
        self.set(col, Cell::blank(style));
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

    pub fn fill(&mut self, range: impl IntoIterator<Item = usize>, style: Style) {
        // Not `set` per column. `fill` is the erase path — a full-screen program clears
        // rows every frame — and a per-cell side-table check in the loop stops this being
        // a bulk write. The tables are pruned once, outside it.
        let mut lo = usize::MAX;
        let mut hi = 0;
        for col in range {
            if let Some(slot) = self.cells.get_mut(col) {
                *slot = Cell::blank(style);
                lo = lo.min(col);
                hi = hi.max(col);
            }
        }
        if lo > hi {
            return;
        }
        self.prune(lo..hi + 1);
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

    pub fn clear(&mut self, style: Style) {
        self.cells.fill(Cell::blank(style));
        self.extras = None;
        self.wrapped = false;
    }

    pub fn resize(&mut self, cols: usize, style: Style) {
        self.cells.resize(cols, Cell::blank(style));
        self.prune(cols..);
    }

    pub fn insert_blank(&mut self, col: usize, count: usize, style: Style) {
        let cols = self.cells.len();
        if col >= cols {
            return;
        }
        self.cells.splice(
            col..col,
            std::iter::repeat_n(Cell::blank(style), count.min(cols - col)),
        );
        self.cells.truncate(cols);
        // The cells from `col` on moved right; their attachments move with them, and
        // whatever was pushed off the end goes. Both used to be dropped wholesale here.
        if let Some(extras) = &mut self.extras {
            extras.shift(col, count.min(cols - col) as isize, cols);
            if extras.entries.is_empty() {
                self.extras = None;
            }
        }
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
        // right closes the gap. DCH used to drop the whole table, losing colours on
        // columns it never touched.
        self.prune(col..col + gone);
        if let Some(extras) = &mut self.extras {
            extras.shift(col + gone, -(gone as isize), cols);
            if extras.entries.is_empty() {
                self.extras = None;
            }
        }
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
    /// Dispatches to two specialisations of [`Row::build_runs`]. Underline colours live
    /// in a side table and are rare, and looking one up per cell measured as ~2% of the
    /// full-screen repaint benchmark — this is the hottest read in the emulator, run
    /// over every damaged row of every frame. Passing the lookup as a closure keeps one
    /// copy of the merge rules while letting the ordinary row compile down to a version
    /// with no side table in it at all.
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

    fn runs_to(&self, end: usize) -> Vec<Run> {
        match self.extras.as_deref() {
            Some(extras) => self.build_runs::<true>(end, &extras.entries),
            None => self.build_runs::<false>(end, &[]),
        }
    }

    /// The row's cells as runs, reading attachments only when there are any.
    ///
    /// `EXTRAS` is a const parameter rather than a runtime test because this is the
    /// hottest read in the emulator — every cell of every damaged row of every frame —
    /// and the row with no attachments is the overwhelming case. At `false` the whole
    /// lookup is compiled out, so that row pays literally nothing for a feature it is
    /// not using; a closure returning an empty slice was not enough, and measured ~4% of
    /// the full-screen repaint benchmark.
    ///
    /// ENTRIES is walked with a cursor rather than searched per column. Both sides
    /// advance through columns in order, so the whole row costs one pass over the table
    /// instead of one pass per cell — which is what `Row::marks_at` used to do, for every
    /// character, whether or not the row had a single mark on it.
    fn build_runs<const EXTRAS: bool>(&self, end: usize, entries: &[(u16, Extra)]) -> Vec<Run> {
        let mut runs = Vec::<Run>::new();
        let mut at = 0;
        for (col, cell) in self.cells[..end].iter().enumerate() {
            if cell.is_continuation() {
                continue;
            }
            let mut underline = Color::Default;
            let mut marks = None;
            let mut placed = None;
            if EXTRAS {
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
                    }
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
                        && match (&run.deco, deco) {
                            (None, None) => true,
                            (Some(d), Some(c)) => d.accepts(c),
                            _ => false,
                        } =>
                {
                    run.text.push(cell.ch);
                    if let (Some(d), Some(c)) = (&mut run.deco, deco) {
                        d.push(c);
                    }
                }
                _ => runs.push(Run {
                    text: String::from(cell.ch),
                    style: cell.style,
                    deco: deco.map(Deco::start),
                    underline,
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
        row.set(0, Cell { ch: 'a', style: Style::default() });
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
        assert!(row.extras().iter().all(|(at, _)| usize::from(*at) < row.len()));
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

    #[test]
    fn overwriting_a_cell_retires_everything_attached_to_it() {
        let mut row = Row::new(4);
        row.set(1, Cell { ch: 'a', style: Style::default() });
        row.set_underline(1, Color::Indexed(196));
        row.combine(1, '\u{0301}');

        row.set(1, Cell { ch: 'b', style: Style::default() });

        assert!(row.extras().is_empty());
        assert!(row.extras.is_none());
    }

    #[test]
    fn attachments_on_other_columns_survive_a_write() {
        let mut row = Row::new(4);
        row.set_underline(1, Color::Indexed(1));
        row.set_underline(2, Color::Indexed(2));
        row.set(1, Cell { ch: 'x', style: Style::default() });
        assert_eq!(row.extras(), [(2, Extra::Underline(Color::Indexed(2)))]);
    }
}
