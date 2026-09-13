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

use super::super::cell::{Cell, Extra, RowRef};
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
    /// Rendering depends on it for a row with box glyphs: a glyph run is split at the
    /// cursor's cell, because Emacs draws the cursor at the start of a `display` span
    /// however wide the span is. On such a row the column is part of what has to match;
    /// on any other row the cursor changes nothing about the text.
    cursor: Option<u16>,
    /// The row's attachments, less its semantic marks, which change nothing Emacs draws
    /// and reach it through the drain's `:marks` instead.
    extras: Vec<(u16, Extra)>,
}

/// Emacs' copy of the live screen; see the module comment.
#[derive(Debug, Default)]
pub(super) struct Front {
    cols: usize,
    /// Every known row's cells, `cols` to a row, in display order.
    cells: Vec<Cell>,
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
        let cells = &mut self.cells[top * cols..(bottom + 1) * cols];
        let rows = &mut self.rows[top..=bottom];
        let recycled = match direction {
            Direction::Up => {
                cells.rotate_left(count * cols);
                rows.rotate_left(count);
                rows.len() - count..rows.len()
            }
            Direction::Down => {
                cells.rotate_right(count * cols);
                rows.rotate_right(count);
                0..count
            }
        };
        for index in recycled {
            Cell::fill(
                &mut cells[index * cols..(index + 1) * cols],
                Cell::default(),
            );
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
            && (known.cursor == cursor || !has_glyphs(row))
            && row.len() == self.cols
            && Cell::bytes(row.cells())
                == Cell::bytes(&self.cells[index * self.cols..][..self.cols])
            && known.extras.iter().eq(drawn(row.extras()))
    }

    /// Note that Emacs now shows ROW at INDEX, rendered with the cursor at CURSOR.
    pub(super) fn record(&mut self, index: usize, row: RowRef<'_>, cursor: Option<u16>) {
        let cols = self.cols;
        let (Some(known), true) = (self.rows.get_mut(index), row.len() == cols) else {
            return;
        };
        self.cells[index * cols..][..cols].copy_from_slice(row.cells());
        known.known = true;
        known.wrapped = row.wrapped();
        known.cursor = cursor;
        known.extras.clear();
        known.extras.extend(drawn(row.extras()).cloned());
    }
}

/// The attachments that change what Emacs draws: everything but semantic marks.
fn drawn(extras: &[(u16, Extra)]) -> impl Iterator<Item = &(u16, Extra)> {
    extras
        .iter()
        .filter(|(_, extra)| !matches!(extra, Extra::Mark(_)))
}

/// Whether ROW has a cell drawn as a box glyph, which is the only kind of row whose
/// rendering depends on where the cursor is.
fn has_glyphs(row: RowRef<'_>) -> bool {
    row.cells()
        .iter()
        .any(|cell| glyph::classify(cell.ch).is_some())
}
