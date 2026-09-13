//! What Emacs is showing of the live screen, so a drain can leave out what it already has.
//!
//! Damage says a row was written to since the last drain, and it is honest about that,
//! but it cannot say whether the row ended up different. A program that erases a line
//! and writes the same text back -- `watch`, htop and tmux all repaint this way --
//! changes every cell twice and none in the end, and each writer only ever compares the
//! cells it overwrites. So the grid keeps this: the cells, wrap flag and attachments of
//! every row as they were when Emacs last rendered it, in display order, and a damaged
//! row that still matches is not sent.
//!
//! The copy is only as good as the rules that keep it true, and they all say the same
//! thing: whenever Emacs' text for a row moves or changes other than by rendering what a
//! drain sent, the copy has to move with it or stop claiming to know. A shift moves rows
//! in both, a resize, a redraw and a switch of screens forget everything, and Lisp says
//! so itself when it edits a live row -- the width guard deleting characters off a row
//! that wrapped is the case that exists. A row that is not known is always sent.

use super::super::cell::{BLANK, Cell, Extra, RowRef, draws_nothing};
use super::super::glyph;
use super::super::screen::{Direction, Shift};

/// One row of Emacs' copy of the screen, besides its cells.
#[derive(Debug, Clone, Default)]
struct Known {
    /// Whether the rest of this means anything. A row that is not known always differs.
    known: bool,
    wrapped: bool,
    /// The cursor's column when the row was rendered, if the cursor was on it.
    ///
    /// Rendering depends on it when the cursor is inside a run of box glyphs: Lisp splits
    /// the run at the cursor's cell, because Emacs draws the cursor at the start of a
    /// `display` span however wide the span is. Anywhere else the cursor changes nothing
    /// about how the row is drawn.
    cursor: Option<u16>,
    /// The row's attachments, less its semantic marks, which change nothing Emacs draws
    /// and reach it through the drain's `:marks` instead.
    extras: Vec<(u16, Extra)>,
}

/// Emacs' copy of the live screen; see the module comment.
#[derive(Debug, Default)]
pub(super) struct Front {
    cols: usize,
    /// Every row's cells, `cols` to a slot, in no particular order; see `order`.
    cells: Vec<Cell>,
    /// The slot holding each display row's cells.
    ///
    /// A shift moves Emacs' text a few rows at a time, and following it by moving cells
    /// would copy the whole region for every drain that scrolls it: holding a key in vim
    /// shifts a 48-row text area by a line or two per redisplay, which is 150KB of cells
    /// per drain at 50x200. Rotating these indices follows the same shift for a few bytes,
    /// exactly as the grid itself scrolls.
    order: Vec<u32>,
    rows: Vec<Known>,
}

impl Front {
    /// Whether this copy has the shape of a ROWS by COLS screen.
    pub(super) fn fits(&self, rows: usize, cols: usize) -> bool {
        self.rows.len() == rows && self.cols == cols
    }

    /// Take the shape of a ROWS by COLS screen, knowing nothing about any of it.
    pub(super) fn reset(&mut self, rows: usize, cols: usize) {
        self.cols = cols;
        self.cells.clear();
        self.cells.resize(rows * cols, Cell::default());
        self.order.clear();
        self.order.extend(0..rows as u32);
        self.rows.clear();
        self.rows.resize(rows, Known::default());
    }

    /// Stop claiming to know the rows from FIRST down.
    pub(super) fn forget_from(&mut self, first: usize) {
        for row in self.rows.iter_mut().skip(first) {
            row.known = false;
        }
    }

    /// Stop claiming to know row INDEX.
    pub(super) fn forget(&mut self, index: usize) {
        if let Some(row) = self.rows.get_mut(index) {
            row.known = false;
        }
    }

    /// Move rows the way Emacs moves its text for SHIFT; see `cooked--apply-shift'.
    ///
    /// The rows rotated in at the far end are empty lines in the buffer, which is what a
    /// blank row renders to, so they are known to be blank rather than forgotten: a
    /// scroll that brings in a blank bottom row then costs Emacs nothing for it.
    pub(super) fn shift(&mut self, shift: Shift) {
        let Shift {
            top,
            bottom,
            count,
            direction,
        } = shift;
        if bottom >= self.rows.len() || count == 0 || count > bottom - top {
            // A shift this copy cannot follow; forgetting is always safe.
            self.forget_from(top);
            return;
        }
        let cols = self.cols;
        let order = &mut self.order[top..=bottom];
        let rows = &mut self.rows[top..=bottom];
        let recycled = match direction {
            Direction::Up => {
                order.rotate_left(count);
                rows.rotate_left(count);
                rows.len() - count..rows.len()
            }
            Direction::Down => {
                order.rotate_right(count);
                rows.rotate_right(count);
                0..count
            }
        };
        for index in recycled {
            let slot = order[index] as usize * cols;
            Cell::fill(&mut self.cells[slot..slot + cols], Cell::default());
            let row = &mut rows[index];
            row.known = true;
            row.wrapped = false;
            row.cursor = None;
            row.extras.clear();
        }
    }

    /// Whether ROW, rendered with the cursor at CURSOR, is what Emacs already shows at
    /// INDEX.
    pub(super) fn matches(&self, index: usize, row: RowRef<'_>, cursor: Option<u16>) -> bool {
        let Some(known) = self.rows.get(index) else {
            return false;
        };
        known.known
            && known.wrapped == row.wrapped()
            && (known.cursor == cursor
                || self.cursor_run(index, row, known.cursor).is_none()
                    && self.cursor_run(index, row, cursor).is_none())
            && row.len() == self.cols
            && Cell::bytes(row.cells()) == Cell::bytes(self.cells(index))
            && known.extras.iter().eq(drawn(row.extras()))
    }

    /// The part of ROW that differs from what Emacs shows at INDEX, as a replacement Emacs
    /// can make in place, or `None` when the whole row has to be sent.
    ///
    /// Asked of a row [`Front::matches`] has already said differs, and before
    /// [`Front::record`] overwrites the copy it is measured against.
    ///
    /// The differing columns are widened until a replacement of them is safe to render on
    /// its own: out to whole wide characters, and out to the ends of any run of box glyphs
    /// a boundary would cut, because Lisp draws a glyph run as one image over the whole run
    /// and a replacement that cut one would leave half an image behind. A glyph run the
    /// cursor has moved into or out of is included too, since Lisp splits a run at the
    /// cursor's cell. The row is sent whole instead when:
    ///
    /// - the copy is not known;
    /// - either version of the row carries an image, which Lisp lays per placement across
    ///   a run of cells;
    /// - SEAM says the row begins mid-line in the buffer, continuing the scrollback above
    ///   it, where character offsets from the row's start are not offsets Lisp can find;
    /// - the replacement would cover more than half the row, where two partial edits of
    ///   the text cost Emacs about what one rewrite does.
    pub(super) fn edit(
        &self,
        index: usize,
        row: RowRef<'_>,
        cursor: Option<u16>,
        seam: bool,
    ) -> Option<Span> {
        let known = self.rows.get(index)?;
        let cols = self.cols;
        if !known.known || seam || row.len() != cols {
            return None;
        }
        let image = |extras: &[(u16, Extra)]| {
            extras
                .iter()
                .any(|(_, extra)| matches!(extra, Extra::Image(_)))
        };
        if image(&known.extras) || image(row.extras()) {
            return None;
        }
        let (old, new) = (self.cells(index), row.cells());
        let old_extras = &known.extras;
        let new_extras: Vec<&(u16, Extra)> = drawn(row.extras()).collect();

        // The first and last columns whose cell or attachments differ. Past both rows'
        // content every cell is a default blank in both, whose bytes are the same, so the
        // cells are only compared up to there -- which on a wide screen leaves most of the
        // row unread -- and each cell is compared as one 128-bit word.
        let old_len = content_len(old, old_extras.iter());
        let new_len = content_len(new, new_extras.iter().copied());
        let bound = old_len.max(new_len).min(cols);
        let word = |c: &Cell| {
            u128::from_ne_bytes(
                Cell::bytes(std::slice::from_ref(c))
                    .try_into()
                    .expect("a cell is sixteen bytes"),
            )
        };
        let differs = |c: usize| word(&old[c]) != word(&new[c]);
        let mut span = (0..bound).find(|&c| differs(c)).map(|first| {
            let last = (first..bound).rev().find(|&c| differs(c)).unwrap_or(first);
            (first, last + 1)
        });
        if old_extras.len() != new_extras.len() || !old_extras.iter().eq(new_extras.iter().copied())
        {
            let column = |(at, _): &(u16, Extra)| usize::from(*at);
            let differing = old_extras
                .iter()
                .filter(|entry| !new_extras.contains(entry))
                .chain(
                    new_extras
                        .iter()
                        .copied()
                        .filter(|entry| !old_extras.contains(entry)),
                )
                .map(column);
            for col in differing {
                span = Some(span.map_or((col, col + 1), |(lo, hi)| (lo.min(col), hi.max(col + 1))));
            }
        }
        // Widening only ever grows the replacement, so a change already too wide to be
        // worth an edit is sent whole before any of the work below.
        if let Some((lo, hi)) = span
            && (hi.min(new_len.max(lo)) - lo) * 2 > cols
        {
            return None;
        }
        let glyphs = has_glyphs(row) || old.iter().any(|c| is_glyph(*c));
        // A glyph run the cursor sat inside, or now sits inside, is split at the cursor's
        // cell when Lisp draws it, so a move of the cursor redraws that run whole.
        if known.cursor != cursor && glyphs {
            let runs = [known.cursor, cursor].map(|at| self.cursor_run(index, row, at));
            for (first, last) in runs.into_iter().flatten() {
                span = Some(span.map_or((first, last + 1), |(lo, hi)| {
                    (lo.min(first), hi.max(last + 1))
                }));
            }
        }
        let length = chars(new, new_extras.iter().copied(), new_len);
        let Some((mut lo, mut hi)) = span else {
            // Nothing drawn differs, only the wrap flag: an empty replacement still has
            // Lisp mark the row's newline afresh.
            return Some(Span {
                start: 0,
                end: 0,
                char_start: 0,
                char_end: Some(0),
                length,
            });
        };
        // A change past the end of the buffer's text starts where that text ends, since
        // there are no characters out there to count up to.
        loop {
            let (before, after) = (lo, hi);
            // Whole wide characters: a continuation cell belongs to the one before it.
            while lo > 0 && (old[lo].is_continuation() || new[lo].is_continuation()) {
                lo -= 1;
            }
            while hi < cols && (old[hi].is_continuation() || new[hi].is_continuation()) {
                hi += 1;
            }
            // Whole runs of box glyphs: a boundary inside one moves out to its ends.
            if glyphs {
                if let Some((first, _)) = glyph_run_across(old, new, lo) {
                    lo = first;
                }
                if let Some((_, last)) = glyph_run_across(old, new, hi) {
                    hi = last + 1;
                }
            }
            lo = lo.min(old_len);
            if hi >= old_len {
                // The change runs to the end of the line, so the new row's trailing blanks
                // before it are trailing blanks of the new text, which Emacs does not hold.
                lo = lo.min(new_len);
            }
            if (lo, hi) == (before, after) {
                break;
            }
        }
        let (char_end, end) = if hi >= old_len {
            (None, new_len.max(lo))
        } else {
            (Some(chars(old, old_extras.iter(), hi)), hi)
        };
        if (end - lo) * 2 > cols {
            return None;
        }
        Some(Span {
            start: lo,
            end,
            char_start: chars(old, old_extras.iter(), lo),
            char_end,
            length,
        })
    }

    /// The glyph run of row INDEX, in the copy or in ROW, that the cursor at column AT
    /// sits inside, as its first and last columns.
    ///
    /// Lisp starts a new glyph segment at the cursor's cell, so a run the cursor is inside
    /// renders differently from the same run with the cursor elsewhere, and a run it is
    /// not inside renders the same wherever the cursor is.
    fn cursor_run(&self, index: usize, row: RowRef<'_>, at: Option<u16>) -> Option<(usize, usize)> {
        glyph_run_across(self.cells(index), row.cells(), usize::from(at?))
    }

    /// Every cell of the copy, known rows or not, in slot order; see [`Screen::all_cells`].
    ///
    /// [`Screen::all_cells`]: super::super::screen::Screen::all_cells
    pub(super) fn all_cells(&self) -> &[Cell] {
        &self.cells
    }

    /// Row INDEX's cells in the copy.
    fn cells(&self, index: usize) -> &[Cell] {
        let slot = self.order[index] as usize * self.cols;
        &self.cells[slot..slot + self.cols]
    }

    /// Note that Emacs now shows ROW at INDEX, rendered with the cursor at CURSOR.
    pub(super) fn record(&mut self, index: usize, row: RowRef<'_>, cursor: Option<u16>) {
        let cols = self.cols;
        let (Some(known), true) = (self.rows.get_mut(index), row.len() == cols) else {
            return;
        };
        let slot = self.order[index] as usize * cols;
        self.cells[slot..slot + cols].copy_from_slice(row.cells());
        known.known = true;
        known.wrapped = row.wrapped();
        known.cursor = cursor;
        known.extras.clear();
        known.extras.extend(drawn(row.extras()).cloned());
    }
}

/// Where a row changed, in the grid's columns and in the characters of the text Emacs
/// holds for it; see [`Front::edit`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct Span {
    /// The first column replaced.
    pub(super) start: usize,
    /// One past the last column the replacement is rendered from.
    pub(super) end: usize,
    /// Characters of the old text before the replacement.
    pub(super) char_start: usize,
    /// Where the replaced text ends, or `None` for the end of the line.
    pub(super) char_end: Option<usize>,
    /// Characters of the new text for the whole row.
    pub(super) length: usize,
}

/// Columns up to the last one holding something, for cells and EXTRAS that are not a
/// grid row: [`RowOf::content_len`](super::super::cell::RowOf::content_len) for the copy.
fn content_len<'a>(cells: &[Cell], extras: impl Iterator<Item = &'a (u16, Extra)>) -> usize {
    let text = cells
        .iter()
        .rposition(|c| c.ch != BLANK || !c.is_default_style())
        .map_or(0, |i| i + 1);
    extras
        .filter(|(_, extra)| extra.is_content())
        .map(|(at, _)| usize::from(*at) + 1)
        .fold(text, usize::max)
}

/// Characters Emacs holds for the first COLS columns of a row: one per cell that is not
/// the second half of a wide character, and one more per combining mark riding a cell.
fn chars<'a>(cells: &[Cell], extras: impl Iterator<Item = &'a (u16, Extra)>, cols: usize) -> usize {
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
    base + marks
}

/// The first and last columns of a run of box glyphs that a boundary before column AT
/// would cut, in either version of the row, or `None` if no run crosses it.
///
/// A run is box glyphs and the blanks between them, as `Row::absorb_blank_runs` joins
/// them, along with any continuation cell, which joins the run of the cell before it. So
/// it crosses the boundary when there is a glyph on each side of it with nothing
/// but glyphs and blanks in between. Blanks past the last glyph are not part of any run,
/// and a boundary among them cuts nothing.
fn glyph_run_across(old: &[Cell], new: &[Cell], at: usize) -> Option<(usize, usize)> {
    let cols = old.len();
    if at == 0 || at >= cols {
        return None;
    }
    let glyph = |c: usize| is_glyph(old[c]) || is_glyph(new[c]);
    let spacing = |c: usize| {
        glyph(c)
            || draws_nothing(old[c].ch)
            || draws_nothing(new[c].ch)
            // A continuation cell belongs to the run of the cell before it.
            || old[c].is_continuation()
            || new[c].is_continuation()
    };
    let left = (0..at)
        .rev()
        .take_while(|&c| spacing(c))
        .find(|&c| glyph(c))?;
    let right = (at..cols).take_while(|&c| spacing(c)).find(|&c| glyph(c))?;
    let first = (0..=left)
        .rev()
        .take_while(|&c| spacing(c))
        .filter(|&c| glyph(c))
        .last()?;
    let last = (right..cols)
        .take_while(|&c| spacing(c))
        .filter(|&c| glyph(c))
        .last()?;
    Some((first, last))
}

/// Whether CELL draws a box glyph.
fn is_glyph(cell: Cell) -> bool {
    glyph::classify(cell.ch).is_some()
}

/// The attachments that change what Emacs draws: everything but semantic marks.
fn drawn(extras: &[(u16, Extra)]) -> impl Iterator<Item = &(u16, Extra)> {
    extras
        .iter()
        .filter(|(_, extra)| !matches!(extra, Extra::Mark(_)))
}

/// Whether ROW has a cell drawn as a box glyph.
fn has_glyphs(row: RowRef<'_>) -> bool {
    row.cells().iter().any(|cell| is_glyph(*cell))
}
