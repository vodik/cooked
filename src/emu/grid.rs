//! Rows of cells addressed by screen position, with each row's storage separate from it.
//!
//! Both halves of the double buffer are one of these: the emulator's grid in
//! [`Screen`](super::screen::Screen), and the copy of what Emacs shows in
//! `Front`. They differ in what they hang off a row -- a
//! `RowMeta` of attachments and a wrap flag against a record of how Emacs last drew it --
//! and in nothing else, so the type is generic over that and the rest is written once.
//!
//! The cells are one flat allocation, `cols` to a slot, and `order` says which slot is
//! shown at which screen row. A row therefore moves for four bytes rather than for its
//! cells, which is what keeps a scroll cheap: holding a key in vim shifts a 48-row text
//! area by a line or two per redisplay, and moving the cells would be 150KB per drain at
//! 50x200. Both grids scroll by the same rotation, and [`Grid::rotate`] is it.

use std::ops::RangeInclusive;

use super::cell::Cell;
use super::screen::Direction;

/// One row of a grid: its cells and whatever its owner hangs off a row.
///
/// A name for the pair [`Grid::row`] hands back, so that a caller reads `row.cells` and
/// `row.meta` rather than destructuring a tuple whose halves are told apart by position.
#[derive(Debug, Clone, Copy)]
pub(crate) struct GridRow<'a, M> {
    pub(crate) cells: &'a [Cell],
    pub(crate) meta: &'a M,
}

/// One row of a grid, to write to; the twin of [`GridRow`].
#[derive(Debug)]
pub(crate) struct GridRowMut<'a, M> {
    pub(crate) cells: &'a mut [Cell],
    pub(crate) meta: &'a mut M,
}

/// Cells and per-row metadata, addressed by screen row; see the module comment.
#[derive(Debug, Clone, Default)]
pub(crate) struct Grid<M> {
    /// Every row's cells, `cols` to a slot, in no particular order; see `order`.
    cells: Vec<Cell>,
    /// What each slot's row carries besides its cells, indexed by slot like `cells`, so
    /// that a rotation of `order` moves it along with the cells it describes.
    meta: Vec<M>,
    /// The slot shown at each screen row, top to bottom. Its length is the grid's height.
    order: Vec<u32>,
    cols: usize,
}

impl<M: Default> Grid<M> {
    /// A ROWS by COLS grid of blank cells and default metadata.
    pub(crate) fn new(rows: usize, cols: usize) -> Self {
        let mut grid = Self::default();
        grid.reset(rows, cols);
        grid
    }

    /// Take the shape of a ROWS by COLS grid, keeping the rows if it already has that
    /// shape, and say whether it did.
    ///
    /// The shape is the question and the reset is the answer, so both are here rather than
    /// at a caller that asks and then acts: the copy of what Emacs shows reshapes itself
    /// this way on every drain, and a drain that did not reshape must keep the rows.
    pub(crate) fn ensure(&mut self, rows: usize, cols: usize) -> bool {
        if self.height() == rows && self.width() == cols {
            return true;
        }
        self.reset(rows, cols);
        false
    }

    /// Lay the grid out again as ROWS by COLS, keeping nothing.
    pub(crate) fn reset(&mut self, rows: usize, cols: usize) {
        self.cols = cols;
        self.cells.clear();
        self.cells.resize(rows * cols, Cell::default());
        self.meta.clear();
        self.meta.resize_with(rows, M::default);
        self.order.clear();
        self.order.extend(0..rows as u32);
    }
}

impl<M> Grid<M> {
    /// Blank the rows in RANGE, which a rotation has just recycled, to BLANK cells and the
    /// metadata FRESH gives.
    ///
    /// Separate from [`Grid::rotate`], which returns the range, because both are the
    /// caller's: a scroll recycles a row into the erase colour of the pen that scrolled it,
    /// and the copy of what Emacs shows into a plain empty line Emacs is already showing.
    pub(crate) fn fill_recycled(
        &mut self,
        range: RangeInclusive<usize>,
        blank: Cell,
        fresh: impl Fn() -> M,
    ) {
        for index in range {
            if let Some(row) = self.row_mut(index) {
                Cell::fill(row.cells, blank);
                *row.meta = fresh();
            }
        }
    }

    /// Rows, top to bottom.
    pub(crate) fn height(&self) -> usize {
        self.order.len()
    }

    /// Columns in every row.
    pub(crate) fn width(&self) -> usize {
        self.cols
    }

    /// Which slot holds screen row INDEX's cells.
    ///
    /// The number itself means nothing outside the grid; it is here so a test can assert
    /// that a scroll reordered slots rather than copying cells.
    pub(crate) fn slot(&self, index: usize) -> Option<usize> {
        Some(*self.order.get(index)? as usize)
    }

    /// Screen row INDEX's cells and metadata.
    pub(crate) fn row(&self, index: usize) -> Option<GridRow<'_, M>> {
        let slot = self.slot(index)?;
        let start = slot * self.cols;
        Some(GridRow {
            cells: &self.cells[start..start + self.cols],
            meta: &self.meta[slot],
        })
    }

    /// Screen row INDEX's cells and metadata, to write to.
    pub(crate) fn row_mut(&mut self, index: usize) -> Option<GridRowMut<'_, M>> {
        let slot = self.slot(index)?;
        let start = slot * self.cols;
        Some(GridRowMut {
            cells: &mut self.cells[start..start + self.cols],
            meta: &mut self.meta[slot],
        })
    }

    /// Screen row INDEX's metadata alone, for a caller with nothing to say about cells.
    pub(crate) fn meta(&self, index: usize) -> Option<&M> {
        self.meta.get(self.slot(index)?)
    }

    /// Screen row INDEX's metadata alone, to write to.
    pub(crate) fn meta_mut(&mut self, index: usize) -> Option<&mut M> {
        let slot = self.slot(index)?;
        self.meta.get_mut(slot)
    }

    /// Every cell, slots in storage order rather than screen order.
    ///
    /// For a walk that only asks what is live somewhere on the grid -- which renditions
    /// and links still have a cell referring to them -- where the order rows are shown in
    /// does not come into it.
    pub(crate) fn all_cells(&self) -> &[Cell] {
        &self.cells
    }

    /// Move the rows from TOP to BOTTOM by COUNT towards DIRECTION, returning the rows
    /// that came round the other end and now hold whatever the rows that left did.
    ///
    /// The one rotation over `order`, shared by the scrolls, the row removal and the copy
    /// of what Emacs shows following them. It moves indices and not cells, so the caller
    /// gets the recycled rows back to blank rather than blank rows moved into place; see
    /// [`Grid::fill_recycled`].
    ///
    /// COUNT is assumed to be within the region: `TOP..=BOTTOM` inclusive, at least one
    /// row and no more than the region's height. Every caller has already reduced it,
    /// since a move of the whole region is a case each of them decides about first.
    pub(crate) fn rotate(
        &mut self,
        top: usize,
        bottom: usize,
        count: usize,
        direction: Direction,
    ) -> RangeInclusive<usize> {
        let order = &mut self.order[top..=bottom];
        match direction {
            Direction::Up => {
                order.rotate_left(count);
                bottom + 1 - count..=bottom
            }
            Direction::Down => {
                order.rotate_right(count);
                top..=top + count - 1
            }
        }
    }

    /// Every row, top to bottom, as its own cells and metadata, consuming the grid.
    ///
    /// For a resize, which lays the rows out again at the new width and stores them back
    /// with [`Grid::store_rows`]. Consuming rather than emptying in place: the layout a
    /// resize walks away from is not a grid anyone should still be holding, and taking it
    /// by value says so without leaving a `cols` behind that no row is that wide.
    pub(crate) fn into_rows(self) -> impl Iterator<Item = (Vec<Cell>, M)>
    where
        M: Default,
    {
        let Self {
            cells,
            mut meta,
            order,
            cols,
        } = self;
        order.into_iter().map(move |slot| {
            let slot = slot as usize;
            (
                cells[slot * cols..(slot + 1) * cols].to_vec(),
                std::mem::take(&mut meta[slot]),
            )
        })
    }

    /// Lay ROWS out as the grid, each COLS wide, in screen order.
    pub(crate) fn store_rows(
        &mut self,
        rows: impl IntoIterator<Item = (Vec<Cell>, M)>,
        cols: usize,
    ) {
        self.cols = cols;
        self.cells.clear();
        self.meta.clear();
        self.order.clear();
        for (cells, meta) in rows {
            debug_assert_eq!(cells.len(), cols, "a grid row is exactly the grid's width");
            self.order.push(self.meta.len() as u32);
            self.cells.extend_from_slice(&cells);
            self.meta.push(meta);
        }
    }
}
