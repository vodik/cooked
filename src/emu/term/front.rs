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

use super::super::cell::{BLANK, Cell, Extra, Row, RowRef, chars_before, draws_nothing};
use super::super::glyph;
use super::super::screen::{Departed, Direction, Shift};
use super::super::units::{Chars, Cols};

/// One row of Emacs' copy of the screen, besides its cells.
#[derive(Debug, Clone, Default)]
struct Known {
    /// Whether the rest of this means anything. A row that is not known always differs.
    known: bool,
    /// Whether Emacs trimmed this row off the bottom of the primary screen's region, so
    /// the buffer holds no line for it at all; see [`Front::trim_from`].
    trimmed: bool,
    wrapped: bool,
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
        self.unpromote(0);
    }

    /// Stop claiming to know the rows from FIRST down.
    pub(super) fn forget_from(&mut self, first: usize) {
        for row in self.rows.iter_mut().skip(first) {
            row.known = false;
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
        let cells = self.cells(index);
        let end = content_len(cells, self.rows[index].extras.iter());
        !departed.wrapped() || cells[end..].iter().all(|cell| *cell == Cell::default())
    }

    /// Note that Emacs has trimmed its screen region to the rows above FIRST, so it holds
    /// nothing for the rest.
    ///
    /// Forgotten, as rows whose text changed under the copy are, and marked as well: a row
    /// the guard edited is still in the buffer and only has to be sent when it is next
    /// damaged, while a trimmed row that holds a background wash has to be sent once the
    /// screen grows back over it, damaged or not.
    pub(super) fn trim_from(&mut self, first: usize) {
        for row in self.rows.iter_mut().skip(first) {
            row.known = false;
            row.trimmed = true;
        }
        self.unpromote(first);
    }

    /// Whether row INDEX was trimmed off the buffer and has not been sent since.
    pub(super) fn trimmed(&self, index: usize) -> bool {
        self.rows.get(index).is_some_and(|row| row.trimmed)
    }

    /// Stop claiming to know row INDEX.
    pub(super) fn forget(&mut self, index: usize) {
        if let Some(row) = self.rows.get_mut(index) {
            row.known = false;
        }
        self.unpromote(index);
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
        // A move of the whole region is followed too. The log never reports one, but a
        // promotion of every row of a region is one: its rows leave the top, and as many
        // blank rows open below, so every row of it is blank.
        if bottom >= self.rows.len() || count == 0 || count > bottom + 1 - top {
            // A shift this copy cannot follow. Forgetting sends each of these rows whole
            // the next time it is damaged, and a row drawn with the cursor cutting one
            // of its glyph runs is still asked about when the cursor leaves; see
            // [`Front::cursor_rows`].
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
            row.trimmed = false;
            row.wrapped = false;
            row.cursor = None;
            row.extras.clear();
        }
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
    pub(super) fn cursor_rows(&self) -> impl Iterator<Item = usize> + '_ {
        self.rows
            .iter()
            .enumerate()
            .filter(|(_, row)| row.cursor.is_some())
            .map(|(index, _)| index)
    }

    /// Whether Emacs' text for row INDEX is known.
    pub(super) fn knows(&self, index: usize) -> bool {
        self.rows.get(index).is_some_and(|row| row.known)
    }

    /// Note that row INDEX, which [`Front::matches`] has just said Emacs already shows,
    /// is drawn as it would be with the cursor at CURSOR.
    ///
    /// True of any row that matched, since a match with the cursor elsewhere means the
    /// cursor is in no glyph run of it either way, and it keeps a row the cursor left
    /// from being asked about again on every drain.
    pub(super) fn settle_cursor(&mut self, index: usize, cursor: Option<u16>) {
        if let Some(row) = self.rows.get_mut(index) {
            row.cursor = cursor;
        }
    }

    /// Whether ROW, rendered with the cursor at CURSOR, is what Emacs already shows at
    /// INDEX.
    pub(super) fn matches(&self, index: usize, row: RowRef<'_>, cursor: Option<u16>) -> bool {
        let Some(known) = self.rows.get(index) else {
            return false;
        };
        // The cursor question last: it walks the row looking for a glyph run around the
        // cursor, and a row whose cells changed has already answered no. A line just
        // scrolled into a region holds blanks in the copy, so asking it first walked
        // every blank column of every such row.
        known.known
            && known.wrapped == row.wrapped()
            && row.len() == self.cols
            && Cell::bytes(row.cells()) == Cell::bytes(self.cells(index))
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
        let new_extras = || drawn(row.extras());

        // The first and last columns whose cell or attachments differ. Past both rows'
        // content every cell is a default blank in both, whose bytes are the same, so the
        // cells are only compared up to there -- which on a wide screen leaves most of the
        // row unread -- and each cell is compared as one 128-bit word.
        let old_len = content_len(old, old_extras.iter());
        let new_len = content_len(new, new_extras());
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
        let (old, new) = (self.cells(index), row.cells());
        glyph_run_across(old, new, at).or_else(|| glyph_run_across(old, new, at + 1))
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
        known.trimmed = false;
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
        .rposition(|c| c.ch != BLANK || !c.is_default_style())
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

/// Whether CELL draws a box glyph, or would but for a combining mark on it.
///
/// The cell alone, without the row's attachments, so a `\u{2500}` carrying an accent
/// counts though the runs draw it as text. That only ever makes a glyph run look longer
/// than it is, which widens an edit and never cuts a run Lisp draws.
fn is_glyph(cell: Cell) -> bool {
    glyph::classify(cell.ch).is_some()
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
