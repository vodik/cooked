//! Cells, styling, and the row representation the renderer consumes.

use std::ops::{BitAnd, BitOr, BitOrAssign, Not};
use unicode_width::UnicodeWidthChar;

use super::glyph::{self, BoxGlyph};

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

/// A styled run of text — the unit the Lisp side turns into propertized buffer text.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Run {
    pub text: String,
    pub style: Style,
    /// One classified shape per character in `text`, index-aligned with
    /// `text.chars()`; `None` for an ordinary text run. Never mixed with a `None`
    /// run even when `style` matches — see `Row::runs`.
    pub glyphs: Option<Vec<BoxGlyph>>,
    /// `SGR 58`, the underline's own colour. Held on the run rather than in [`Style`]
    /// because it lives in a side table on the row — see [`Row::underlines`].
    pub underline: Color,
}

/// A single line of the terminal, with combining marks held in a rare-path side table.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Row {
    cells: Vec<Cell>,
    marks: Vec<(u16, Box<str>)>,
    /// Underline colours (`SGR 58`) by column.
    ///
    /// A side table for the same reason `marks` is one: this is rare — essentially only
    /// an editor drawing LSP diagnostics — and a `Color` in [`Style`] would grow [`Cell`]
    /// from 16 bytes to 20, which measured as an 8-13% throughput loss across the whole
    /// grid for a feature almost nothing uses. Empty is the overwhelming case, and
    /// [`Row::runs`] specialises on that once rather than asking per cell.
    ///
    /// Only non-default colours are stored, and the table is boxed: `None` is the
    /// overwhelming case, and an inline `Vec` put 24 bytes on every `Row` — rows are
    /// cloned on every scroll, and that alone measured as a 12% loss on the repaint
    /// benchmark before it was boxed away.
    ///
    /// `clippy::box_collection` reads this as a pointless second allocation, which it
    /// would be if the point were the heap. It is not: the point is the *inline* size of
    /// every `Row`, and only `Box` gets there. `Option<Vec<_>>` is 24 bytes and
    /// `Option<Box<[_]>>` 16, while `Option<Box<Vec<_>>>` is 8 — one null-optimised
    /// pointer — and the allocation the lint objects to only happens on the rare row that
    /// has an underline colour at all.
    #[allow(
        clippy::box_collection,
        reason = "8-byte niche beats one rare allocation"
    )]
    underlines: Option<Box<Vec<(u16, Color)>>>,
    pub wrapped: bool,
}

impl Row {
    pub fn new(cols: usize) -> Self {
        Self {
            cells: vec![Cell::default(); cols],
            marks: Vec::new(),
            underlines: None,
            wrapped: false,
        }
    }

    /// Assemble a row from cells already laid out, for the reflow in `Screen::resize`.
    ///
    /// MARKS are keyed by column within CELLS, which is what a rewrap produces once a
    /// logical line has been re-chunked: the offsets are recomputed per chunk rather than
    /// carried from the row the cells came off.
    pub fn from_parts(
        cells: Vec<Cell>,
        marks: Vec<(u16, Box<str>)>,
        underlines: Vec<(u16, Color)>,
        wrapped: bool,
    ) -> Self {
        Self {
            cells,
            marks,
            underlines: (!underlines.is_empty()).then(|| Box::new(underlines)),
            wrapped,
        }
    }

    pub fn underlines(&self) -> &[(u16, Color)] {
        self.underlines.as_deref().map_or(&[], Vec::as_slice)
    }

    /// Set or clear the underline colour at `col`. `Color::Default` removes the entry, so
    /// the table stays empty for the rows — almost all of them — that never carry one.
    pub fn set_underline(&mut self, col: usize, color: Color) {
        if let Some(table) = &mut self.underlines {
            table.retain(|(at, _)| usize::from(*at) != col);
        }
        if color != Color::Default && col < self.cells.len() {
            self.underlines
                .get_or_insert_with(Default::default)
                .push((col as u16, color));
        } else if self.underlines.as_ref().is_some_and(|t| t.is_empty()) {
            // Back to `None`, so `runs` returns to the plain path once an editor stops
            // underlining rather than staying off it for as long as the row lives.
            self.underlines = None;
        }
    }

    fn underline_at(&self, col: usize) -> Color {
        self.underlines()
            .iter()
            .find(|(at, _)| usize::from(*at) == col)
            .map_or(Color::Default, |(_, c)| *c)
    }

    pub fn cells(&self) -> &[Cell] {
        &self.cells
    }

    pub fn marks(&self) -> &[(u16, Box<str>)] {
        &self.marks
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

    pub fn set(&mut self, col: usize, cell: Cell) {
        if let Some(slot) = self.cells.get_mut(col) {
            *slot = cell;
            self.marks.retain(|(at, _)| usize::from(*at) != col);
        }
    }

    /// Attach a zero-width character (combining mark, variation selector) to `col`.
    pub fn combine(&mut self, col: usize, mark: char) {
        let Some(existing) = self
            .marks
            .iter_mut()
            .find(|(at, _)| usize::from(*at) == col)
        else {
            self.marks
                .push((col as u16, String::from(mark).into_boxed_str()));
            return;
        };
        let mut s = String::from(&*existing.1);
        s.push(mark);
        existing.1 = s.into_boxed_str();
    }

    fn marks_at(&self, col: usize) -> Option<&str> {
        self.marks
            .iter()
            .find(|(at, _)| usize::from(*at) == col)
            .map(|(_, s)| &**s)
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
        self.marks
            .retain(|(at, _)| !(lo..=hi).contains(&usize::from(*at)));
        if let Some(table) = &mut self.underlines {
            table.retain(|(at, _)| !(lo..=hi).contains(&usize::from(*at)));
            if table.is_empty() {
                self.underlines = None;
            }
        }
    }

    /// Whether the row holds any text, as opposed to only a background wash.
    ///
    /// Distinct from `is_blank`, and the distinction only exists because of `bce`: a row a
    /// full-screen program painted and then cleared is no longer blank — every cell
    /// carries a background — but it is not transcript either, and archiving it would push
    /// a screenful of pure colour into the scrollback.
    pub fn has_text(&self) -> bool {
        !self.marks.is_empty() || self.cells.iter().any(|c| c.ch != BLANK)
    }

    /// Whether the row holds nothing a resize would need to preserve.
    ///
    /// Stricter than [`Row::has_text`] on purpose: a resize must keep a background wash,
    /// so a washed row is not blank even though it holds no text.
    pub fn is_blank(&self) -> bool {
        self.marks.is_empty()
            && self
                .cells
                .iter()
                .all(|c| c.ch == BLANK && c.style == Style::default())
    }

    pub fn clear(&mut self, style: Style) {
        self.cells.fill(Cell::blank(style));
        self.marks.clear();
        self.underlines = None;
        self.wrapped = false;
    }

    pub fn resize(&mut self, cols: usize, style: Style) {
        self.cells.resize(cols, Cell::blank(style));
        self.marks.retain(|(at, _)| usize::from(*at) < cols);
        if let Some(table) = &mut self.underlines {
            table.retain(|(at, _)| usize::from(*at) < cols);
            if table.is_empty() {
                self.underlines = None;
            }
        }
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
        self.marks.retain(|(at, _)| usize::from(*at) < col);
        self.underlines = None;
    }

    pub fn delete(&mut self, col: usize, count: usize, style: Style) {
        let cols = self.cells.len();
        if col >= cols {
            return;
        }
        self.cells.drain(col..(col + count).min(cols));
        self.cells.resize(cols, Cell::blank(style));
        self.marks.retain(|(at, _)| usize::from(*at) < col);
        self.underlines = None;
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
        self.cells
            .iter()
            .rposition(|c| c.ch != BLANK || c.style != Style::default())
            .map_or(0, |i| i + 1)
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
        if self.underlines.is_some() {
            self.build_runs(end, |row, col| row.underline_at(col))
        } else {
            self.build_runs(end, |_, _| Color::Default)
        }
    }

    fn build_runs(&self, end: usize, underline_at: impl Fn(&Self, usize) -> Color) -> Vec<Run> {
        self.cells[..end]
            .iter()
            .enumerate()
            .filter(|(_, c)| !c.is_continuation())
            .fold(Vec::<Run>::new(), |mut runs, (col, cell)| {
                let shape = glyph::classify(cell.ch);
                let underline = underline_at(self, col);
                match runs.last_mut() {
                    Some(run)
                        if run.style == cell.style
                            && run.underline == underline
                            && run.glyphs.is_some() == shape.is_some() =>
                    {
                        run.text.push(cell.ch);
                        if let Some(glyphs) = &mut run.glyphs {
                            glyphs.push(shape.expect("glyphs.is_some() == shape.is_some()"));
                        }
                    }
                    _ => runs.push(Run {
                        text: String::from(cell.ch),
                        style: cell.style,
                        glyphs: shape.map(|g| vec![g]),
                        underline,
                    }),
                }
                // Combining marks never legitimately attach to a box-drawing base
                // character, so no glyph padding is needed to keep `glyphs` aligned.
                if let (Some(marks), Some(run)) = (self.marks_at(col), runs.last_mut()) {
                    run.text.push_str(marks);
                }
                runs
            })
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
        assert!(runs[0].glyphs.is_none());
        assert!(runs[1].glyphs.is_some());
        assert!(runs[2].glyphs.is_none());
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
        let glyphs = runs[0].glyphs.as_ref().expect("box-glyph run");
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
}
