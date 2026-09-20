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
//!
//! The copy also says which rows leaving the top of the screen Emacs already holds. A line
//! feed at the bottom of a `tail -f` hands row 0 to scrollback, and when that row is the
//! one the copy has at index 0, Emacs can keep the text it has and call it history rather
//! than be sent it again; see [`Front::promote`].

use super::super::cell::{BLANK, Cell, Extra, Row, RowRef, Wrap, chars_before, draws_nothing};
use super::super::glyph;
use super::super::grid::Grid;
use super::super::screen::{Departed, Screen, Shift};
use super::super::units::{Chars, Cols};
use super::screens::ScreenId;
use super::{Cursor, DamagedRow, Edit};

/// One row of Emacs' copy of the screen, besides its cells.
#[derive(Debug, Clone, Default)]
struct Known {
    /// Whether the rest of this means anything. A row that is not known always differs.
    known: bool,
    /// Whether Emacs trimmed this row off the bottom of the primary screen's region, so
    /// the buffer holds no line for it at all; see [`Front::trim_from`].
    trimmed: bool,
    /// How the row's line ended when it was rendered. The whole of it and not just
    /// whether it wrapped: two rows with the same cells can end differently -- `abcd `
    /// and `abcd` at five columns both leave column 4 a default blank, but the first
    /// filled up and the second was wrapped early by a wide character -- and Emacs marks
    /// the newline between them differently for it. See `WrapMark' in wire.rs.
    wrap: Wrap,
    /// The cursor's column when the row was rendered, if the cursor was on it.
    ///
    /// Rendering depends on it when the cursor is inside a run of box glyphs: Lisp cuts
    /// the run on both sides of the cursor's cell, because Emacs draws the cursor as wide
    /// as the `display` span it sits on. Anywhere else the cursor changes nothing about
    /// how the row is drawn, and a row that matched with the cursor elsewhere takes the
    /// new column without being sent; see [`Front::cursor_rows`].
    cursor: Option<u16>,
    /// The row's attachments, less its semantic marks, which change nothing Emacs draws
    /// and reach it through the drain's `:marks` instead.
    extras: Vec<(u16, Extra)>,
}

impl Known {
    /// A blank row rotated in at the far end of a shift, which Emacs shows as an empty
    /// line: known rather than forgotten, so a scroll that brings one in costs nothing.
    fn recycled() -> Self {
        Self {
            known: true,
            ..Self::default()
        }
    }
}

/// Emacs' copy of the live screen; see the module comment.
#[derive(Debug, Default)]
pub(super) struct Front {
    /// The cells Emacs last rendered and what each row was drawn as, in the same shape the
    /// emulator's own grid has; see [`Grid`], which is the other half of the double buffer.
    grid: Grid<Known>,
    /// How many of the rows handed to scrollback since the last drain are the copy's rows
    /// 0, 1, 2 and so on, exactly as Emacs holds them; see [`Front::promote`].
    promoted: usize,
    /// Whether the next row to leave the top can still be the copy's row `promoted`.
    ///
    /// Promotion is a prefix: once one departing row is not what Emacs holds, every row
    /// after it goes as text, since Emacs can only keep text that is at the top of its
    /// screen.
    promoting: bool,
}

impl Front {
    /// Show BACK, the grid of screen OF, and hand back the rows Emacs does not already
    /// have, recording them as sent.
    ///
    /// The whole delta, in the order its steps depend on each other:
    ///
    /// 1. the copy takes the screen's shape, keeping every row when it already had it;
    /// 2. PROMOTED rows leave the top of the copy, and then SHIFTS are applied to it, as
    ///    Emacs does both to its text -- before any row is compared, because the damage
    ///    indices are in the coordinates the moves leave behind;
    /// 3. the rows a cursor move alone can leave drawn wrong, and the rows Emacs trimmed
    ///    that the screen has grown back over, join DAMAGED;
    /// 4. a damaged row that matches the copy is left out, which is a repaint that wrote
    ///    the same thing back;
    /// 5. each row that is left is measured against the copy as an [`Edit`] of the part
    ///    that changed, and only then recorded -- the copy it is measured against is the
    ///    one the record overwrites;
    /// 6. the copy stops claiming the rows Emacs trims off the bottom of its region.
    ///
    /// A changed row whose change is small is sent as an edit on the primary screen, and
    /// on the alternate screen only when it has no changed neighbour; see [`Front::edit`].
    pub(super) fn present(
        &mut self,
        of: ScreenId,
        back: &Screen,
        cursor: Cursor,
        promoted: Option<Shift>,
        shifts: &[Shift],
        mut damaged: Vec<usize>,
    ) -> Vec<DamagedRow> {
        self.grid.ensure(back.height(), back.width());
        for shift in promoted.iter().chain(shifts) {
            self.shift(*shift);
        }
        // A cursor move damages no row, and yet Lisp cuts a glyph run around the cursor's
        // cell, so the rows it left and the row it is on are asked about as if damaged.
        // Their cells are what the copy holds, so only the cursor can make them differ.
        //
        // A row Emacs trimmed off the bottom of the primary comes back as an empty line
        // when the screen grows over it, which a cursor moving down or a scroll does
        // without damaging it. An empty line is what a blank row renders to, but not a row
        // the child washed with a background, so that one is sent.
        //
        // A wrapped row is sent too, blank or not, and this is the only route by which a
        // wrap flag below the content ever reaches Emacs. An empty line carries a newline
        // and a wrapped row must not, so a row whose line goes on has to be rendered
        // rather than left to the trim's blank -- `CSI 1K` on the continuation of a
        // wrapped row leaves exactly that, a line of blanks continued into blanks, and
        // the flag comes back with the row when the cursor moves down again or a scroll
        // brings it up. Emacs cannot be told by clearing the flag on the grid instead: a
        // drain would then be changing the rows a later rewrap re-lays and a later scroll
        // hands to scrollback, and two consumers draining the same terminal at different
        // moments -- a buffer no window shows drains without the screen for minutes --
        // would end up with different transcripts of the same bytes.
        let used = if of.is_alternate() { 0 } else { back.used() };
        let regrown = (0..used).filter(|&row| {
            self.trimmed(row)
                && back
                    .row(row)
                    .is_some_and(|row| !row.is_blank() || row.wrapped())
        });
        let moved: Vec<usize> = self
            .cursor_rows()
            .chain(Some(cursor.row).filter(|&row| self.knows(row)))
            .chain(regrown)
            .filter(|row| damaged.binary_search(row).is_err())
            .collect();
        if !moved.is_empty() {
            damaged.extend(moved);
            damaged.sort_unstable();
            damaged.dedup();
        }
        // Row 0 of the primary screen continues the scrollback above it when the head is
        // not empty, so its text in the buffer begins mid-line.
        let seam = !of.is_alternate() && !back.head().is_zero();
        let at = |index: usize| (cursor.row == index).then_some(cursor.col as u16);
        let changed: Vec<usize> = damaged
            .into_iter()
            .filter(|&index| {
                let Some(row) = back.row(index) else {
                    return false;
                };
                let same = self.matches(index, row, at(index));
                if same {
                    self.settle_cursor(index, at(index));
                }
                !same
            })
            .collect();
        let rows = changed
            .iter()
            .enumerate()
            .filter_map(|(i, &index)| {
                let row = back.row(index)?;
                // On the primary screen every changed row is offered as an edit, and on
                // the alternate screen only a row with no changed neighbour.
                //
                // Contiguous rows sent whole coalesce into one block that Emacs rewrites
                // with a single deletion and insertion, and that destroys every marker,
                // overlay and property on the rows' unchanged cells: a prompt's semantic
                // marks, a bookmark, an overlay a mode put on a line of output. On the
                // primary screen those are the transcript's, so the rows that changed a
                // little are edited in place and keep them. The price is Emacs' per-edit
                // cost. Measured in instructions per frame for 24 80-column rows each
                // changing one cell, 24 edits cost 1.7M against 0.38M for one block of
                // plain rows, and 1.9M against 2.8M for rows of eight styled spans, whose
                // properties the block writes again. The alternate screen is a full-screen
                // program's picture, repainted at its frame rate and carrying none of those
                // marks, so it keeps the block. An isolated row -- the spinner, the clock,
                // the bar -- has no block to join, and there the edit is the cheaper of the
                // two on either screen.
                let isolated = (i == 0 || changed[i - 1] + 1 != index)
                    && changed.get(i + 1).is_none_or(|&next| next != index + 1);
                let edit = (isolated || !of.is_alternate())
                    .then(|| self.edit(index, row, at(index), seam && index == 0))
                    .flatten()
                    .map(|span| Edit {
                        char_start: span.char_start,
                        char_end: span.char_end,
                        chars: span.length,
                        runs: row.runs_between(span.start, span.end),
                    });
                self.record(index, row, at(index));
                Some(DamagedRow {
                    index,
                    wrap: row.wrap(),
                    runs: row.runs(),
                    edit,
                })
            })
            .collect();
        // Emacs trims its screen region to the rows the emulator says are in use, so
        // whatever it held below them is gone; see `cooked--fit-screen'.
        if !of.is_alternate() {
            self.trim_from(back.used());
        }
        rows
    }

    /// Stop claiming to know the rows from FIRST down.
    pub(super) fn forget_from(&mut self, first: usize) {
        for index in first..self.grid.height() {
            self.known_mut(index).known = false;
        }
        self.unpromote(first);
    }

    /// Stop claiming that the rows from FIRST down, already handed to scrollback, are what
    /// Emacs holds.
    ///
    /// Rows the copy stops knowing may have left the grid already. Emacs' text for them
    /// has changed under the copy, or is about to be replaced wholesale, so they go as
    /// text after all, and so does every row that departed after them.
    pub(super) fn unpromote(&mut self, first: usize) {
        if first < self.promoted {
            self.promoted = first;
            self.promoting = false;
        }
    }

    /// Promote no row that leaves before the next drain, and none of those that left since
    /// the last.
    ///
    /// For a switch of screens: the rows that left the primary before it are not at the
    /// top of what the next drain draws, and a row that leaves after it would be matched
    /// against rows the other grid may have drawn.
    pub(super) fn stop_promoting(&mut self) {
        self.promoted = 0;
        self.promoting = false;
    }

    /// Note that ROW has just left the top of the screen for scrollback, and whether Emacs
    /// can keep the text it holds for it rather than be sent the row again.
    ///
    /// It can when the rows that departed before it since the last drain all could, the
    /// row is the copy's next row, and Emacs' text for that row is what scrollback would
    /// get. LIMIT is how many rows the screen's moves since the last drain have taken off
    /// the top, or `None` when anything but one scroll of a region from the top row has
    /// moved a row: a row past LIMIT left some other way, such as a screen clear, and a
    /// scroll lower down or an inserted line leaves the copy's rows out of step with the
    /// grid's.
    ///
    /// What scrollback would get is what ROW's cells draw. Emacs holds that when the copy
    /// has the same cells, and drew them without a cut in a glyph run for the cursor,
    /// which scrollback does not have. A row that left without a copy of its cells is not
    /// compared and goes as text. A wrapped row goes to scrollback with its trailing
    /// blanks, which the live row trimmed, so those have to be blanks Lisp can add back as
    /// plain spaces: a linked blank left at the end of a wrapped row is sent.
    pub(super) fn promote(&mut self, row: &Departed, limit: Option<usize>) {
        let index = self.promoted;
        if self.promoting && limit.is_some_and(|limit| index < limit) && self.holds(index, row) {
            self.promoted += 1;
        } else {
            self.promoting = false;
        }
    }

    /// How many rows handed to scrollback since the last drain Emacs holds already, as
    /// [`Front::promote`] counted them, starting the count again for the next drain.
    pub(super) fn take_promoted(&mut self) -> usize {
        self.promoting = true;
        std::mem::take(&mut self.promoted)
    }

    /// Whether the next row to leave the top can still be promoted, which is what decides
    /// whether a departing row is worth copying to compare; see [`Departed::row`].
    pub(super) fn promoting(&self) -> bool {
        self.promoting
    }

    /// Whether Emacs' text for row INDEX is what ROW, leaving the screen, puts in
    /// scrollback, give or take trailing spaces; see [`Front::promote`].
    fn holds(&self, index: usize, row: &Departed) -> bool {
        let Some(departed) = &row.row else {
            return false;
        };
        let departed = Row::as_ref(departed);
        // With the cursor nowhere, which is how scrollback draws the row: the same cells
        // drawn with the cursor in a glyph run on them were cut around it.
        if !self.matches(index, departed, None) {
            return false;
        }
        let (cells, known) = self.row(index);
        let end = content_len(cells, known.extras.iter());
        !departed.wrapped() || cells[end..].iter().all(|cell| *cell == Cell::default())
    }

    /// Note that Emacs has trimmed its screen region to the rows above FIRST, so it holds
    /// nothing for the rest.
    ///
    /// Forgotten, as rows whose text changed under the copy are, and marked as well: a row
    /// the guard edited is still in the buffer and only has to be sent when it is next
    /// damaged, while a trimmed row that holds a background wash has to be sent once the
    /// screen grows back over it, damaged or not.
    fn trim_from(&mut self, first: usize) {
        for index in first..self.grid.height() {
            let known = self.known_mut(index);
            known.known = false;
            known.trimmed = true;
        }
        self.unpromote(first);
    }

    /// Whether row INDEX was trimmed off the buffer and has not been sent since.
    fn trimmed(&self, index: usize) -> bool {
        self.grid.meta(index).is_some_and(|known| known.trimmed)
    }

    /// Stop claiming to know row INDEX.
    pub(super) fn forget(&mut self, index: usize) {
        if let Some(known) = self.grid.meta_mut(index) {
            known.known = false;
        }
        self.unpromote(index);
    }

    /// Move rows the way Emacs moves its text for SHIFT; see `cooked--apply-shift'.
    ///
    /// The rows rotated in at the far end are empty lines in the buffer, which is what a
    /// blank row renders to, so they are known to be blank rather than forgotten: a
    /// scroll that brings in a blank bottom row then costs Emacs nothing for it.
    fn shift(&mut self, shift: Shift) {
        let Shift {
            top,
            bottom,
            count,
            direction,
        } = shift;
        // A move of the whole region is followed too. The log never reports one, but a
        // promotion of every row of a region is one: its rows leave the top, and as many
        // blank rows open below, so every row of it is blank.
        if bottom >= self.grid.height() || count == 0 || count > bottom + 1 - top {
            // A shift this copy cannot follow. Forgetting sends each of these rows whole
            // the next time it is damaged, and a row drawn with the cursor cutting one
            // of its glyph runs is still asked about when the cursor leaves; see
            // [`Front::cursor_rows`].
            self.forget_from(top);
            return;
        }
        let recycled = self.grid.rotate(top, bottom, count, direction);
        self.grid
            .fill_recycled(recycled, Cell::default(), Known::recycled);
    }

    /// The known rows that were rendered with the cursor on them, which a cursor move
    /// alone can leave drawn wrong.
    ///
    /// A move damages no row, so without asking these again a run cut for the cursor
    /// stays cut after it leaves: a border drained while the cursor sat on its second
    /// column shows `┌` as one image and the rest as another for as long as nothing
    /// writes to the row. [`Front::settle_cursor`] keeps this to the row or two the
    /// cursor has actually been on since.
    ///
    /// A row the copy has forgotten is among them if it was drawn with the cursor on it.
    /// Forgetting says the buffer's text for the row may differ, not that the cut is
    /// gone: the width guard trims a row after it is drawn, and a shift the copy cannot
    /// follow forgets rows the buffer still holds as they were cut. Such a row matches
    /// nothing, so asking about it sends it whole, once.
    fn cursor_rows(&self) -> impl Iterator<Item = usize> + '_ {
        (0..self.grid.height()).filter(|&index| {
            self.grid
                .meta(index)
                .is_some_and(|known| known.cursor.is_some())
        })
    }

    /// Whether Emacs' text for row INDEX is known.
    fn knows(&self, index: usize) -> bool {
        self.grid.meta(index).is_some_and(|known| known.known)
    }

    /// Note that row INDEX, which [`Front::matches`] has just said Emacs already shows,
    /// is drawn as it would be with the cursor at CURSOR.
    ///
    /// True of any row that matched, since a match with the cursor elsewhere means the
    /// cursor is in no glyph run of it either way, and it keeps a row the cursor left
    /// from being asked about again on every drain.
    fn settle_cursor(&mut self, index: usize, cursor: Option<u16>) {
        if let Some(known) = self.grid.meta_mut(index) {
            known.cursor = cursor;
        }
    }

    /// Whether ROW, rendered with the cursor at CURSOR, is what Emacs already shows at
    /// INDEX.
    fn matches(&self, index: usize, row: RowRef<'_>, cursor: Option<u16>) -> bool {
        let Some(row_shown) = self.grid.row(index) else {
            return false;
        };
        let (cells, known) = (row_shown.cells, row_shown.meta);
        // The cursor question last: it walks the row looking for a glyph run around the
        // cursor, and a row whose cells changed has already answered no. A line just
        // scrolled into a region holds blanks in the copy, so asking it first walked
        // every blank column of every such row.
        known.known
            && known.wrap == row.wrap()
            && row.len() == self.grid.width()
            && Cell::bytes(row.cells()) == Cell::bytes(cells)
            && known.extras.iter().eq(drawn(row.extras()))
            && (known.cursor == cursor
                || self.cursor_run(index, row, known.cursor).is_none()
                    && self.cursor_run(index, row, cursor).is_none())
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
    /// cursor has moved into or out of is included too, since Lisp cuts a run around the
    /// cursor's cell. The row is sent whole instead when:
    ///
    /// - the copy is not known;
    /// - either version of the row carries an image, which Lisp lays per placement across
    ///   a run of cells;
    /// - SEAM says the row begins mid-line in the buffer, continuing the scrollback above
    ///   it, where character offsets from the row's start are not offsets Lisp can find;
    /// - the replacement would cover more than half the row, where two partial edits of
    ///   the text cost Emacs about what one rewrite does.
    fn edit(&self, index: usize, row: RowRef<'_>, cursor: Option<u16>, seam: bool) -> Option<Span> {
        let old_row = self.grid.row(index)?;
        let (old, known) = (old_row.cells, old_row.meta);
        let cols = self.grid.width();
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
        let new = row.cells();
        let old_extras = &known.extras;
        let new_extras = || drawn(row.extras());

        // The first and last columns whose cell or attachments differ. Past both rows'
        // content every cell is a default blank in both, whose bytes are the same, so the
        // cells are only compared up to there -- which on a wide screen leaves most of the
        // row unread -- and each cell is one machine word, character, rendition and link
        // together.
        let old_len = content_len(old, old_extras.iter());
        let new_len = content_len(new, new_extras());
        let bound = old_len.max(new_len).min(cols);
        let differs = |c: usize| old[c].word() != new[c].word();
        let mut span = (0..bound).find(|&c| differs(c)).map(|first| {
            let last = (first..bound).rev().find(|&c| differs(c)).unwrap_or(first);
            (first, last + 1)
        });
        if !old_extras.iter().eq(new_extras()) {
            for col in differing_columns(old_extras.iter(), new_extras()) {
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
        // A glyph run the cursor sat inside, or now sits inside, is cut around the
        // cursor's cell when Lisp draws it, so a move of the cursor redraws that run whole.
        if known.cursor != cursor && glyphs {
            let runs = [known.cursor, cursor].map(|at| self.cursor_run(index, row, at));
            for (first, last) in runs.into_iter().flatten() {
                span = Some(span.map_or((first, last + 1), |(lo, hi)| {
                    (lo.min(first), hi.max(last + 1))
                }));
            }
        }
        let length = chars_before(new, new_extras(), Cols::new(new_len));
        let Some((mut lo, mut hi)) = span else {
            // Nothing drawn differs, only the wrap flag: an empty replacement still has
            // Lisp mark the row's newline afresh.
            return Some(Span {
                start: Cols::ZERO,
                end: Cols::ZERO,
                char_start: Chars::ZERO,
                char_end: Some(Chars::ZERO),
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
            (
                Some(chars_before(old, old_extras.iter(), Cols::new(hi))),
                hi,
            )
        };
        if (end - lo) * 2 > cols {
            return None;
        }
        Some(Span {
            start: Cols::new(lo),
            end: Cols::new(end),
            char_start: chars_before(old, old_extras.iter(), Cols::new(lo)),
            char_end,
            length,
        })
    }

    /// The glyph run of row INDEX, in the copy or in ROW, that the cursor at column AT
    /// sits inside, as its first and last columns.
    ///
    /// Lisp cuts a glyph run before and after the cursor's cell, so a run the cursor is
    /// inside renders differently from the same run with the cursor elsewhere, and a run
    /// it is not inside renders the same wherever the cursor is. Inside means either cut
    /// falls within the run: on the first cell of `┌──┐` only the cut after it does, and
    /// on a lone `┌` neither does, since cutting a one-cell run leaves it as it was.
    fn cursor_run(&self, index: usize, row: RowRef<'_>, at: Option<u16>) -> Option<(usize, usize)> {
        let at = usize::from(at?);
        let (old, new) = (self.row(index).0, row.cells());
        glyph_run_across(old, new, at).or_else(|| glyph_run_across(old, new, at + 1))
    }

    /// Every cell of the copy, known rows or not, in slot order; see [`Screen::all_cells`].
    ///
    /// [`Screen::all_cells`]: super::super::screen::Screen::all_cells
    pub(super) fn all_cells(&self) -> &[Cell] {
        self.grid.all_cells()
    }

    /// Row INDEX's cells and record in the copy, which every caller has already found.
    fn row(&self, index: usize) -> (&[Cell], &Known) {
        let row = self.grid.row(index).expect("a row the copy has");
        (row.cells, row.meta)
    }

    /// Row INDEX's record in the copy, to write to; likewise.
    fn known_mut(&mut self, index: usize) -> &mut Known {
        self.grid.meta_mut(index).expect("a row the copy has")
    }

    /// Note that Emacs now shows ROW at INDEX, rendered with the cursor at CURSOR.
    fn record(&mut self, index: usize, row: RowRef<'_>, cursor: Option<u16>) {
        let cols = self.grid.width();
        let (Some(front), true) = (self.grid.row_mut(index), row.len() == cols) else {
            return;
        };
        let (cells, known) = (front.cells, front.meta);
        cells.copy_from_slice(row.cells());
        known.known = true;
        known.trimmed = false;
        known.wrap = row.wrap();
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
    pub(super) start: Cols,
    /// One past the last column the replacement is rendered from.
    pub(super) end: Cols,
    /// Characters of the old text before the replacement.
    pub(super) char_start: Chars,
    /// Where the replaced text ends, or `None` for the end of the line.
    pub(super) char_end: Option<Chars>,
    /// Characters of the new text for the whole row.
    pub(super) length: Chars,
}

/// Columns up to the last one holding something, for cells and EXTRAS that are not a
/// grid row: [`RowOf::content_len`](super::super::cell::RowOf::content_len) for the copy.
fn content_len<'a>(cells: &[Cell], extras: impl Iterator<Item = &'a (u16, Extra)>) -> usize {
    let text = cells
        .iter()
        .rposition(|c| c.ch() != BLANK || !c.is_default_style())
        .map_or(0, |i| i + 1);
    extras
        .filter(|(_, extra)| extra.is_content())
        .map(|(at, _)| usize::from(*at) + 1)
        .fold(text, usize::max)
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
            || draws_nothing(old[c].ch())
            || draws_nothing(new[c].ch())
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

/// Whether CELL draws a box glyph, or would but for a combining mark on it.
///
/// The cell alone, without the row's attachments, so a `\u{2500}` carrying an accent
/// counts though the runs draw it as text. That only ever makes a glyph run look longer
/// than it is, which widens an edit and never cuts a run Lisp draws.
fn is_glyph(cell: Cell) -> bool {
    glyph::classify(cell.ch()).is_some()
}

/// The attachments that change what Emacs draws: everything but semantic marks.
/// The columns whose attachments differ between OLD and NEW, each in column order.
///
/// A merge over the two lists, one column at a time, rather than asking of every entry
/// whether the other row holds it, which was quadratic in the attachments. A column's
/// entries are compared in order, so the same attachments added in a different order read
/// as a change. That can only widen an edit by the column, never hide one, and it counts
/// what membership could not: `e` with two acute accents and `e` with one hold the same
/// entries.
fn differing_columns<'a>(
    old: impl Iterator<Item = &'a (u16, Extra)>,
    new: impl Iterator<Item = &'a (u16, Extra)>,
) -> impl Iterator<Item = usize> {
    let (mut old, mut new) = (old.peekable(), new.peekable());
    std::iter::from_fn(move || {
        loop {
            let col = match (old.peek(), new.peek()) {
                (None, None) => return None,
                (Some((a, _)), None) => *a,
                (None, Some((b, _))) => *b,
                (Some((a, _)), Some((b, _))) => (*a).min(*b),
            };
            let at = |(c, _): &&(u16, Extra)| *c == col;
            let mut same = true;
            loop {
                match (old.next_if(at), new.next_if(at)) {
                    (None, None) => break,
                    (Some(a), Some(b)) => same &= a == b,
                    _ => same = false,
                }
            }
            if !same {
                return Some(usize::from(col));
            }
        }
    })
}

fn drawn(extras: &[(u16, Extra)]) -> impl Iterator<Item = &(u16, Extra)> {
    extras
        .iter()
        .filter(|(_, extra)| !matches!(extra, Extra::Mark(_)))
}

/// Whether ROW has a cell drawn as a box glyph.
fn has_glyphs(row: RowRef<'_>) -> bool {
    row.cells().iter().any(|cell| is_glyph(*cell))
}
