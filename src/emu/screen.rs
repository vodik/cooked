//! The addressable grid: cursor motion, scrolling regions, erasure, and damage tracking.

use super::cell::{CONTINUATION, Cell, Row, Style};
use unicode_width::UnicodeWidthChar;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Cursor {
    pub row: usize,
    pub col: usize,
    /// Deferred wrap: the cursor sits on the last column having already printed there.
    pub wrap_pending: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Region {
    pub top: usize,
    pub bottom: usize,
}

impl Region {
    fn full(rows: usize) -> Self {
        Self {
            top: 0,
            bottom: rows.saturating_sub(1),
        }
    }

    fn contains(self, row: usize) -> bool {
        (self.top..=self.bottom).contains(&row)
    }

    fn height(self) -> usize {
        self.bottom + 1 - self.top
    }
}

/// What a width change does to the rows already on the grid.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Resize {
    /// Rewrap the logical lines to the new width, which is what the primary screen needs:
    /// its rows are a transcript, and cutting them destroys text Emacs has never seen.
    Rewrap,
    /// Leave the grid a plain rectangle, which is all the alternate screen can be. It holds
    /// one program's drawing rather than a history, that program redraws on SIGWINCH, and
    /// rewrapping a half-finished frame would only garble what it is about to replace.
    Clamp,
}

/// How much of a line or the display an erase touches.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Erase {
    ToEnd,
    ToStart,
    All,
}

impl Erase {
    pub fn from_param(n: u16) -> Option<Self> {
        match n {
            0 => Some(Self::ToEnd),
            1 => Some(Self::ToStart),
            2 | 3 => Some(Self::All),
            _ => None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct Screen {
    rows: Vec<Row>,
    cols: usize,
    pub cursor: Cursor,
    pub region: Region,
    pub saved: Option<Cursor>,
    dirty: Vec<bool>,
    tabs: Vec<bool>,
    /// Rows of row 0's logical line that have already left the grid for Emacs.
    ///
    /// [`Row::wrapped`] says a row is continued *below*. Nothing says a row is continued
    /// from *above*, and once the rows above have been handed over there is nothing left
    /// on the grid to ask — so a rewrap would chunk that leading fragment as though it
    /// began a line, and its hard breaks would land `cols` from the fragment's start
    /// rather than from the line's. The buffer then shows a row wider than the window.
    ///
    /// Counted in rows rather than cells because every row that leaves is exactly `cols`
    /// wide, making `carried * cols` the head's exact width. [`Screen::reflow`] restores
    /// that property at the new width before it returns, so it holds unconditionally.
    carried: usize,
}

impl Screen {
    pub fn new(rows: usize, cols: usize) -> Self {
        Self {
            rows: vec![Row::new(cols); rows],
            cols,
            cursor: Cursor::default(),
            region: Region::full(rows),
            saved: None,
            dirty: vec![true; rows],
            tabs: default_tabs(cols),
            carried: 0,
        }
    }

    /// Drop the carry: nothing of the top row's line is in Emacs any more.
    pub fn forget_carry(&mut self) {
        self.carried = 0;
    }

    /// Account for `evicted` rows being handed to Emacs off the top of the grid.
    ///
    /// Only for rows that actually reached Emacs: a scroll region discards rows instead,
    /// and `reflow` refuses to run under one, so the carry is never read in that state.
    fn carry(&mut self, evicted: &[Row]) {
        let Some(last) = evicted.last() else { return };
        if !last.wrapped {
            // The line ended with the rows that left, so row 0 starts a fresh one.
            self.carried = 0;
            return;
        }
        let run = evicted.iter().rev().take_while(|row| row.wrapped).count();
        self.carried = if run == evicted.len() {
            self.carried + run
        } else {
            run
        };
    }

    pub fn height(&self) -> usize {
        self.rows.len()
    }

    pub fn width(&self) -> usize {
        self.cols
    }

    pub fn row(&self, index: usize) -> Option<&Row> {
        self.rows.get(index)
    }

    pub fn rows(&self) -> impl Iterator<Item = &Row> {
        self.rows.iter()
    }

    fn touch(&mut self, index: usize) -> Option<&mut Row> {
        *self.dirty.get_mut(index)? = true;
        self.rows.get_mut(index)
    }

    fn touch_range(&mut self, range: impl IntoIterator<Item = usize>) {
        for i in range {
            if let Some(d) = self.dirty.get_mut(i) {
                *d = true;
            }
        }
    }

    pub fn touch_all(&mut self) {
        self.dirty.fill(true);
    }

    /// Indices of rows changed since the last drain.
    pub fn drain_damage(&mut self) -> Vec<usize> {
        let changed = self
            .dirty
            .iter()
            .enumerate()
            .filter(|(_, d)| **d)
            .map(|(i, _)| i)
            .collect();
        self.dirty.fill(false);
        changed
    }

    /// Print one character, returning any rows a wrap-induced scroll evicted.
    pub fn write(&mut self, ch: char, style: Style) -> Vec<Row> {
        let width = ch.width().unwrap_or(0);
        if width == 0 {
            let (row, col) = (self.cursor.row, self.cursor.col.saturating_sub(1));
            if let Some(r) = self.touch(row) {
                r.combine(col, ch);
            }
            return Vec::new();
        }

        let mut evicted = Vec::new();
        if self.cursor.wrap_pending || self.cursor.col + width > self.cols {
            if let Some(r) = self.touch(self.cursor.row) {
                r.wrapped = true;
            }
            self.cursor.col = 0;
            evicted = self.linefeed();
        }

        let (row, col) = (self.cursor.row, self.cursor.col);
        let cols = self.cols;
        if let Some(r) = self.touch(row) {
            r.set(col, Cell { ch, style });
            for offset in 1..width {
                r.set(
                    col + offset,
                    Cell {
                        ch: CONTINUATION,
                        style,
                    },
                );
            }
        }

        match col + width {
            next if next >= cols => {
                self.cursor.col = cols - 1;
                self.cursor.wrap_pending = true;
            }
            next => self.cursor.col = next,
        }
        evicted
    }

    pub fn carriage_return(&mut self) {
        self.cursor.col = 0;
        self.cursor.wrap_pending = false;
    }

    /// LF/IND: down one, scrolling the region if already at its bottom.
    pub fn linefeed(&mut self) -> Vec<Row> {
        self.cursor.wrap_pending = false;
        match self.cursor.row {
            row if row == self.region.bottom => self.scroll_up(1),
            row if row + 1 < self.rows.len() => {
                self.cursor.row = row + 1;
                Vec::new()
            }
            _ => Vec::new(),
        }
    }

    /// RI: up one, scrolling the region down if already at its top.
    pub fn reverse_index(&mut self) {
        self.cursor.wrap_pending = false;
        match self.cursor.row {
            row if row == self.region.top => self.scroll_down(1),
            0 => {}
            row => self.cursor.row = row - 1,
        }
    }

    /// True when the scroll region is the whole screen, the only case in which rows
    /// leaving the top are history rather than discarded.
    fn archives(&self) -> bool {
        self.region == Region::full(self.rows.len())
    }

    /// Shift the region up by `n`, returning rows that became scrollback.
    pub fn scroll_up(&mut self, n: usize) -> Vec<Row> {
        let Region { top, bottom } = self.region;
        let n = n.min(self.region.height());
        if n == 0 {
            return Vec::new();
        }
        let evicted = if self.archives() {
            self.rows[top..top + n].to_vec()
        } else {
            Vec::new()
        };
        self.rows[top..=bottom].rotate_left(n);
        for row in &mut self.rows[bottom + 1 - n..=bottom] {
            row.clear(Style::default());
        }
        self.touch_range(top..=bottom);
        self.carry(&evicted);
        evicted
    }

    pub fn scroll_down(&mut self, n: usize) {
        let Region { top, bottom } = self.region;
        let n = n.min(self.region.height());
        if n == 0 {
            return;
        }
        self.rows[top..=bottom].rotate_right(n);
        for row in &mut self.rows[top..top + n] {
            row.clear(Style::default());
        }
        self.touch_range(top..=bottom);
    }

    pub fn set_region(&mut self, top: usize, bottom: usize) {
        let bottom = bottom.min(self.rows.len().saturating_sub(1));
        if top < bottom {
            self.region = Region { top, bottom };
            self.goto(0, 0);
        }
    }

    pub fn reset_region(&mut self) {
        self.region = Region::full(self.rows.len());
    }

    /// Absolute positioning, clamped to the screen.
    pub fn goto(&mut self, row: usize, col: usize) {
        self.cursor.row = row.min(self.rows.len().saturating_sub(1));
        self.cursor.col = col.min(self.cols.saturating_sub(1));
        self.cursor.wrap_pending = false;
    }

    pub fn move_by(&mut self, rows: isize, cols: isize) {
        let row = self.cursor.row.saturating_add_signed(rows);
        let col = self.cursor.col.saturating_add_signed(cols);
        // Vertical motion stays inside the scroll region when the cursor starts there.
        let row = match self.region.contains(self.cursor.row) {
            true => row.clamp(self.region.top, self.region.bottom),
            false => row,
        };
        self.goto(row, col);
    }

    pub fn erase_line(&mut self, how: Erase) {
        let (col, cols) = (self.cursor.col, self.cols);
        let row = self.cursor.row;
        let style = Style::default();
        if let Some(r) = self.touch(row) {
            match how {
                Erase::ToEnd => r.fill(col..cols, style),
                Erase::ToStart => r.fill(0..=col.min(cols - 1), style),
                Erase::All => r.clear(style),
            }
        }
    }

    /// Erase, returning rows that became scrollback.
    ///
    /// Only `All` yields any, and only off an unpartitioned screen. Clearing the whole
    /// display is the child discarding a screen it has finished with — `clear` and the
    /// shell's `C-l` both arrive here — and blanking those rows in place deleted a
    /// screenful of transcript from the Emacs buffer with them. xterm loses it too, which
    /// is why `clear -x` exists; but history here belongs to Emacs, not to the grid, so
    /// the grid has no business dropping it.
    ///
    /// A partial erase archives nothing: the child is rewriting part of a screen it is
    /// still drawing on, not finishing with one.
    pub fn erase_display(&mut self, how: Erase) -> Vec<Row> {
        let (row, last) = (self.cursor.row, self.rows.len());
        match how {
            Erase::ToEnd => {
                self.erase_line(Erase::ToEnd);
                self.clear_rows(row + 1..last);
                Vec::new()
            }
            Erase::ToStart => {
                self.clear_rows(0..row);
                self.erase_line(Erase::ToStart);
                Vec::new()
            }
            Erase::All => {
                let history = match self.archives() && self.rows.iter().any(|r| !r.is_blank()) {
                    true => self.rows[..=self.last_used_row()].to_vec(),
                    false => Vec::new(),
                };
                self.clear_rows(0..last);
                // Whatever was on screen has gone to history whole, so the next row 0
                // starts a line rather than continuing one.
                self.carried = 0;
                history
            }
        }
    }

    fn clear_rows(&mut self, range: std::ops::Range<usize>) {
        for i in range {
            if let Some(r) = self.touch(i) {
                r.clear(Style::default());
            }
        }
    }

    pub fn erase_chars(&mut self, n: usize) {
        let (row, col, cols) = (self.cursor.row, self.cursor.col, self.cols);
        if let Some(r) = self.touch(row) {
            r.fill(col..(col + n).min(cols), Style::default());
        }
    }

    pub fn insert_chars(&mut self, n: usize) {
        let (row, col) = (self.cursor.row, self.cursor.col);
        if let Some(r) = self.touch(row) {
            r.insert_blank(col, n, Style::default());
        }
    }

    pub fn delete_chars(&mut self, n: usize) {
        let (row, col) = (self.cursor.row, self.cursor.col);
        if let Some(r) = self.touch(row) {
            r.delete(col, n, Style::default());
        }
    }

    /// IL/DL operate on a temporary region starting at the cursor row. Lines deleted this
    /// way are destroyed, never archived.
    pub fn insert_lines(&mut self, n: usize) {
        if !self.region.contains(self.cursor.row) {
            return;
        }
        let saved = self.region;
        self.region = Region {
            top: self.cursor.row,
            bottom: saved.bottom,
        };
        self.scroll_down(n);
        self.region = saved;
    }

    pub fn delete_lines(&mut self, n: usize) {
        if !self.region.contains(self.cursor.row) {
            return;
        }
        let saved = self.region;
        self.region = Region {
            top: self.cursor.row,
            bottom: saved.bottom,
        };
        // Deleting at row 0 of an unpartitioned screen looks to `scroll_up` exactly like
        // rows leaving the top, but these are discarded rather than handed to Emacs, so
        // what Emacs holds — and therefore where the buffer wraps the top line — has not
        // changed. Letting the carry advance here would have a later rewrap hand over
        // cells to complete a row that was already complete.
        let carried = self.carried;
        drop(self.scroll_up(n));
        self.carried = carried;
        self.region = saved;
    }

    pub fn tab(&mut self, count: usize) {
        let col = (0..count).fold(self.cursor.col, |col, _| {
            self.tabs
                .iter()
                .enumerate()
                .skip(col + 1)
                .find_map(|(i, stop)| stop.then_some(i))
                .unwrap_or(self.cols - 1)
        });
        self.cursor.col = col.min(self.cols - 1);
        self.cursor.wrap_pending = false;
    }

    pub fn set_tab(&mut self) {
        if let Some(stop) = self.tabs.get_mut(self.cursor.col) {
            *stop = true;
        }
    }

    pub fn clear_tabs(&mut self, all: bool) {
        match all {
            true => self.tabs.fill(false),
            false => {
                if let Some(stop) = self.tabs.get_mut(self.cursor.col) {
                    *stop = false;
                }
            }
        }
    }

    pub fn backspace(&mut self) {
        self.cursor.col = self.cursor.col.saturating_sub(1);
        self.cursor.wrap_pending = false;
    }

    /// Index of the last row holding anything, or 0.
    fn last_used_row(&self) -> usize {
        self.rows
            .iter()
            .rposition(|row| !row.is_blank())
            .unwrap_or(0)
    }

    /// Resize, returning rows that became scrollback.
    ///
    /// Shrinking absorbs the blank rows below the content first. Evicting from the top
    /// instead — the obvious implementation — pushes the visible prompt into scrollback
    /// while keeping the empty rows underneath it, so the transcript gains a duplicate of
    /// whatever was on screen.
    ///
    /// A width change under [`Resize::Rewrap`] re-lays the grid out instead of cutting it;
    /// see [`Screen::reflow`]. Not when a scroll region is set: the rows either side of the
    /// margins belong to different drawings, so there are no logical lines spanning the
    /// screen to recover, and `archives` already names exactly that condition.
    pub fn resize(&mut self, rows: usize, cols: usize, mode: Resize) -> Vec<Row> {
        if mode == Resize::Rewrap && cols != self.cols && self.archives() {
            return self.reflow(rows, cols);
        }

        if cols != self.cols {
            self.cols = cols;
            self.tabs = default_tabs(cols);
            for row in &mut self.rows {
                row.resize(cols, Style::default());
            }
        }

        let evicted = match rows.cmp(&self.rows.len()) {
            std::cmp::Ordering::Less => {
                let excess = self.rows.len() - rows;
                let keep = self.last_used_row().max(self.cursor.row) + 1;
                let spare = self.rows.len().saturating_sub(keep).min(excess);
                self.rows.truncate(self.rows.len() - spare);
                self.rows.drain(..excess - spare).collect()
            }
            std::cmp::Ordering::Greater => {
                self.rows.resize(rows, Row::new(cols));
                Vec::new()
            }
            std::cmp::Ordering::Equal => Vec::new(),
        };

        self.carry(&evicted);
        self.cursor.row = self
            .cursor
            .row
            .saturating_sub(evicted.len())
            .min(rows.saturating_sub(1));
        self.cursor.col = self.cursor.col.min(cols.saturating_sub(1));
        self.dirty = vec![true; rows];
        self.reset_region();
        evicted
    }

    /// Rewrap the grid to `rows` by `cols`, returning rows pushed off the top as history.
    ///
    /// The live grid is a transcript Emacs has not been given yet, so cutting it to a
    /// narrower width destroys text outright — which is what running `ps` and then
    /// narrowing the frame used to do. `Row::wrapped` records which rows are continuations
    /// rather than lines of their own, and that is enough to recover the lines the child
    /// actually printed and chunk them again at the new width.
    ///
    /// Scrollback has always worked this way: it keeps one buffer line per logical line and
    /// lets Emacs re-wrap it for display. This gives the live screen the same property, and
    /// with it the round trip — narrowing and widening back returns the original layout,
    /// because the wrap provenance is preserved rather than destroyed.
    fn reflow(&mut self, rows: usize, cols: usize) -> Vec<Row> {
        // Cells of the first line that are already in Emacs, measured at the width they
        // were chunked at — which is the one still in force as the grid is read.
        let mut head = self.carried * self.cols;

        // The same bound the shrink path uses, so the blank rows below the content are
        // still absorbed first rather than being rewrapped into a screenful of nothing.
        let keep = self.last_used_row().max(self.cursor.row) + 1;

        let mut lines: Vec<Logical> = Vec::new();
        let (mut cursor_line, mut cursor_offset) = (0, 0);
        let mut continuing = false;
        for (index, row) in self.rows[..keep].iter().enumerate() {
            if !continuing {
                lines.push(Logical::default());
            }
            let line = lines
                .last_mut()
                .expect("a line is opened before a row is pushed");
            let base = line.push_row(row);
            if index == self.cursor.row {
                cursor_line = lines.len() - 1;
                // A pending wrap is the cursor standing one past the last column, which is
                // exactly one past the last cell of the line so far.
                cursor_offset = base + self.cursor.col + usize::from(self.cursor.wrap_pending);
            }
            continuing = row.wrapped;
        }

        // The cursor is free to sit past the end of its line's text — on a blank row, or in
        // the gap a `goto` left. Chunking has to produce a row for wherever it is.
        if let Some(line) = lines.get_mut(cursor_line) {
            if line.cells.len() < cursor_offset {
                line.cells.resize(cursor_offset, Cell::default());
            }
        }

        // Re-align the seam. The head occupies whole visual rows at the old width but
        // seldom at the new one, and the cells completing its last row belong to the
        // buffer rather than the grid: left here they would start row 0 partway along a
        // visual row, putting every hard break below it in the wrong column.
        let mut history = Vec::new();
        if head % cols != 0 && !lines.is_empty() {
            let split = (cols - head % cols).min(lines[0].cells.len());
            let ends_here = split == lines[0].cells.len();
            history.push(lines[0].take_front(split, cols, !ends_here));
            head += split;
            if cursor_line == 0 {
                // Inside the fragment the cursor has left the grid; the nearest cell it
                // can still have is the start of what remains. Less than a row's travel,
                // and the child redraws on SIGWINCH anyway.
                cursor_offset = cursor_offset.saturating_sub(split);
            }
            if ends_here {
                lines.remove(0);
                cursor_line = cursor_line.saturating_sub(1);
                // The line ended inside the fragment, so a newline follows it and row 0
                // starts a buffer line of its own.
                head = 0;
            }
        }

        let mut grid: Vec<Row> = Vec::new();
        let mut cursor = Cursor::default();
        for (index, line) in lines.iter().enumerate() {
            let chunks = line.chunk(cols);
            if index == cursor_line {
                let (row, col, wrap_pending) = place(cursor_offset, cols, chunks.len());
                cursor = Cursor {
                    row: grid.len() + row,
                    col,
                    wrap_pending,
                };
            }
            grid.extend(chunks);
        }

        // Rewrapping narrower makes more rows than it consumed; the ones that no longer fit
        // leave the top, which is where history goes from.
        let overflow = grid.len().saturating_sub(rows);
        let evicted: Vec<Row> = grid.drain(..overflow).collect();
        grid.resize(rows, Row::new(cols));

        // Set from the re-aligned head first, so the eviction extends it rather than
        // measuring against the width the head was chunked at.
        self.carried = head / cols;
        self.carry(&evicted);
        history.extend(evicted);

        self.rows = grid;
        self.cols = cols;
        self.tabs = default_tabs(cols);
        self.cursor = Cursor {
            row: cursor
                .row
                .saturating_sub(overflow)
                .min(rows.saturating_sub(1)),
            ..cursor
        };
        self.dirty = vec![true; rows];
        self.reset_region();
        history
    }

    /// Text of the current line up to the cursor — the password prompt lives here.
    pub fn line_text(&self, row: usize) -> Option<String> {
        self.rows.get(row).map(Row::to_text)
    }

    pub fn last_nonblank_text(&self) -> Option<String> {
        (0..=self.cursor.row)
            .rev()
            .filter_map(|i| self.rows.get(i))
            .map(Row::to_text)
            .find(|t| !t.trim().is_empty())
    }
}

fn default_tabs(cols: usize) -> Vec<bool> {
    (0..cols).map(|i| i % 8 == 0 && i != 0).collect()
}

/// Where an offset into a chunked logical line lands: row within the chunks, column, and
/// whether the cursor is holding a deferred wrap there.
fn place(offset: usize, cols: usize, chunks: usize) -> (usize, usize, bool) {
    match (offset / cols, offset % cols) {
        // Exactly at the end of the last chunk. Rather than invent a row below it, express
        // it as `Screen::write` does: parked on the last column with the wrap deferred.
        (row, 0) if row > 0 && row >= chunks => (row - 1, cols - 1, true),
        (row, col) => (row.min(chunks.saturating_sub(1)), col, false),
    }
}

/// A line as the child printed it, before the grid cut it into rows.
///
/// The unit a rewrap preserves, reassembled from the rows a `wrapped` chain covers. Marks
/// are keyed by offset within `cells` rather than by screen column, since the column a
/// cell will end up in is not known until it is chunked again.
#[derive(Debug, Default)]
struct Logical {
    cells: Vec<Cell>,
    marks: Vec<(usize, Box<str>)>,
}

impl Logical {
    /// Append ROW's content, returning the offset its first cell landed at.
    ///
    /// A wrapped row contributes every column it has. Its trailing blanks are interior to
    /// the line — the text continues on the next row — so trimming them the way a line's
    /// final row is trimmed would pull the continuation forward by however many columns
    /// the child happened to leave blank.
    fn push_row(&mut self, row: &Row) -> usize {
        let base = self.cells.len();
        let len = if row.wrapped {
            row.len()
        } else {
            row.content_len()
        };
        self.cells.extend_from_slice(&row.cells()[..len]);
        self.marks.extend(
            row.marks()
                .iter()
                .filter(|(at, _)| usize::from(*at) < len)
                .map(|(at, text)| (base + usize::from(*at), text.clone())),
        );
        base
    }

    /// Cut the line into rows of exactly `cols`, never splitting a wide character.
    fn chunk(&self, cols: usize) -> Vec<Row> {
        let mut rows = Vec::new();
        let (mut start, mut at) = (0, 0);
        while at < self.cells.len() {
            // The whole character: its lead cell plus the continuation cells it claims.
            let mut next = at + 1;
            while next < self.cells.len() && self.cells[next].is_continuation() {
                next += 1;
            }
            if next - start > cols {
                // A character wider than the entire screen fits nowhere; place what there
                // is room for and carry on, rather than looping without progress.
                let (end, resume) = if at == start { (next, next) } else { (at, at) };
                rows.push(self.row(start, end, cols, true));
                start = resume;
            }
            at = next;
        }
        if start < self.cells.len() || rows.is_empty() {
            rows.push(self.row(start, self.cells.len(), cols, false));
        }
        rows
    }

    /// Split the first `n` cells off the front as a row of `cols`, keeping their marks.
    fn take_front(&mut self, n: usize, cols: usize, wrapped: bool) -> Row {
        let row = self.row(0, n, cols, wrapped);
        self.cells.drain(..n);
        self.marks.retain_mut(|(at, _)| {
            let keep = *at >= n;
            if keep {
                *at -= n;
            }
            keep
        });
        row
    }

    /// One row from `cells[start..end]`, blank-padded out to `cols`.
    fn row(&self, start: usize, end: usize, cols: usize, wrapped: bool) -> Row {
        let mut cells = self.cells[start..end.min(start + cols)].to_vec();
        cells.resize(cols, Cell::default());
        let marks = self
            .marks
            .iter()
            .filter(|(at, _)| (start..end).contains(at))
            .map(|(at, text)| ((at - start) as u16, text.clone()))
            .collect();
        Row::from_parts(cells, marks, wrapped)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(screen: &mut Screen, text: &str) {
        for ch in text.chars() {
            screen.write(ch, Style::default());
        }
    }

    #[test]
    fn deferred_wrap_only_fires_on_the_next_write() {
        let mut screen = Screen::new(3, 4);
        write(&mut screen, "abcd");
        assert_eq!((screen.cursor.row, screen.cursor.col), (0, 3));
        assert!(screen.cursor.wrap_pending);

        write(&mut screen, "e");
        assert_eq!((screen.cursor.row, screen.cursor.col), (1, 1));
        assert_eq!(screen.row(0).unwrap().to_text(), "abcd");
        assert_eq!(screen.row(1).unwrap().to_text(), "e");
    }

    #[test]
    fn scrolling_off_the_top_yields_rows_for_scrollback() {
        let mut screen = Screen::new(2, 4);
        write(&mut screen, "aa");
        screen.carriage_return();
        screen.linefeed();
        write(&mut screen, "bb");
        let evicted = screen.linefeed();

        assert_eq!(evicted.len(), 1);
        assert_eq!(evicted[0].to_text(), "aa");
        assert_eq!(screen.row(0).unwrap().to_text(), "bb");
    }

    #[test]
    fn scroll_region_confines_scrolling() {
        let mut screen = Screen::new(4, 4);
        for (i, line) in ["a", "b", "c", "d"].into_iter().enumerate() {
            screen.goto(i, 0);
            write(&mut screen, line);
        }
        screen.set_region(1, 2);
        screen.goto(2, 0);
        let evicted = screen.linefeed();

        assert!(
            evicted.is_empty(),
            "region scroll must not reach scrollback"
        );
        assert_eq!(screen.row(0).unwrap().to_text(), "a");
        assert_eq!(screen.row(1).unwrap().to_text(), "c");
        assert_eq!(screen.row(3).unwrap().to_text(), "d");
    }

    #[test]
    fn wide_characters_claim_two_columns() {
        let mut screen = Screen::new(2, 4);
        write(&mut screen, "漢字");
        assert_eq!(screen.cursor.col, 4 - 1);
        assert_eq!(screen.row(0).unwrap().to_text(), "漢字");
    }

    #[test]
    fn a_wide_character_wraps_rather_than_splitting() {
        let mut screen = Screen::new(2, 3);
        write(&mut screen, "ab漢");
        assert_eq!(screen.row(0).unwrap().to_text(), "ab");
        assert_eq!(screen.row(1).unwrap().to_text(), "漢");
    }

    #[test]
    fn erase_to_end_keeps_the_prefix() {
        let mut screen = Screen::new(2, 6);
        write(&mut screen, "abcdef");
        screen.goto(0, 3);
        screen.erase_line(Erase::ToEnd);
        assert_eq!(screen.row(0).unwrap().to_text(), "abc");
    }

    #[test]
    fn tabs_land_on_eight_column_stops() {
        let mut screen = Screen::new(2, 24);
        write(&mut screen, "ab");
        screen.tab(1);
        assert_eq!(screen.cursor.col, 8);
        screen.tab(2);
        assert_eq!(screen.cursor.col, 24 - 1);
    }

    #[test]
    fn shrinking_absorbs_blank_rows_before_touching_content() {
        let mut screen = Screen::new(24, 10);
        for (i, line) in ["one", "two", "three"].into_iter().enumerate() {
            screen.goto(i, 0);
            write(&mut screen, line);
        }
        screen.goto(3, 0);

        let evicted = screen.resize(10, 10, Resize::Rewrap);

        assert!(
            evicted.is_empty(),
            "blank rows should absorb the shrink, not the prompt"
        );
        assert_eq!(screen.row(0).unwrap().to_text(), "one");
        assert_eq!(screen.row(2).unwrap().to_text(), "three");
        assert_eq!(screen.cursor.row, 3);
    }

    #[test]
    fn shrinking_past_the_content_evicts_from_the_top() {
        let mut screen = Screen::new(6, 10);
        for i in 0..6 {
            screen.goto(i, 0);
            write(&mut screen, &format!("r{i}"));
        }
        screen.goto(5, 0);

        let evicted = screen.resize(4, 10, Resize::Rewrap);

        assert_eq!(evicted.len(), 2);
        assert_eq!(evicted[0].to_text(), "r0");
        assert_eq!(screen.row(0).unwrap().to_text(), "r2");
        assert_eq!(screen.cursor.row, 3);
    }

    #[test]
    fn growing_adds_rows_below_without_moving_content() {
        let mut screen = Screen::new(4, 10);
        screen.goto(0, 0);
        write(&mut screen, "top");
        screen.goto(1, 0);

        assert!(screen.resize(20, 10, Resize::Rewrap).is_empty());
        assert_eq!(screen.height(), 20);
        assert_eq!(screen.row(0).unwrap().to_text(), "top");
        assert_eq!(screen.cursor.row, 1);
    }

    #[test]
    fn narrowing_rewraps_the_grid_instead_of_cutting_it() {
        let mut screen = Screen::new(4, 10);
        write(&mut screen, "abcdefghijklmno");

        assert!(screen.resize(4, 5, Resize::Rewrap).is_empty());
        assert_eq!(screen.row(0).unwrap().to_text(), "abcde");
        assert_eq!(screen.row(1).unwrap().to_text(), "fghij");
        assert_eq!(screen.row(2).unwrap().to_text(), "klmno");
    }

    /// The point of rewrapping rather than cutting: the wrap provenance survives, so the
    /// old layout is still derivable. Truncation is one-way; this is not.
    #[test]
    fn a_width_round_trip_restores_the_original_layout() {
        let mut screen = Screen::new(4, 10);
        write(&mut screen, "abcdefghijklmno");

        screen.resize(4, 5, Resize::Rewrap);
        screen.resize(4, 10, Resize::Rewrap);

        assert_eq!(screen.row(0).unwrap().to_text(), "abcdefghij");
        assert_eq!(screen.row(1).unwrap().to_text(), "klmno");
        assert!(screen.row(0).unwrap().wrapped);
        assert!(!screen.row(1).unwrap().wrapped);
    }

    #[test]
    fn a_rewrap_never_splits_a_wide_character() {
        let mut screen = Screen::new(4, 10);
        write(&mut screen, "abcd漢");

        screen.resize(4, 5, Resize::Rewrap);

        assert_eq!(screen.row(0).unwrap().to_text(), "abcd");
        assert_eq!(
            screen.row(1).unwrap().to_text(),
            "漢",
            "the pair must move down whole rather than straddle the edge"
        );
    }

    #[test]
    fn combining_marks_ride_along_with_their_cell() {
        let mut screen = Screen::new(4, 10);
        write(&mut screen, "abcde\u{301}");

        screen.resize(4, 3, Resize::Rewrap);

        assert_eq!(screen.row(0).unwrap().to_text(), "abc");
        assert_eq!(screen.row(1).unwrap().to_text(), "de\u{301}");
    }

    #[test]
    fn a_rewrap_that_outgrows_the_screen_evicts_from_the_top() {
        let mut screen = Screen::new(2, 10);
        write(&mut screen, "abcdefghijklmno");

        let evicted = screen.resize(2, 5, Resize::Rewrap);

        assert_eq!(evicted.len(), 1);
        assert_eq!(evicted[0].to_text(), "abcde");
        assert_eq!(screen.row(0).unwrap().to_text(), "fghij");
        assert_eq!(screen.row(1).unwrap().to_text(), "klmno");
    }

    #[test]
    fn the_cursor_keeps_its_place_in_the_text_across_a_rewrap() {
        let mut screen = Screen::new(4, 10);
        write(&mut screen, "hello world");
        assert_eq!((screen.cursor.row, screen.cursor.col), (1, 1));

        screen.resize(4, 6, Resize::Rewrap);

        assert_eq!(screen.row(1).unwrap().to_text(), "world");
        assert_eq!(
            (screen.cursor.row, screen.cursor.col),
            (1, 5),
            "still one past the `d` it was one past before"
        );
    }

    /// A rewrap that lands the cursor exactly on the edge must express it the way `write`
    /// does — parked on the last column with the wrap deferred — not by inventing a row.
    #[test]
    fn a_rewrap_onto_the_edge_leaves_the_wrap_deferred() {
        let mut screen = Screen::new(4, 10);
        write(&mut screen, "abcdef");

        screen.resize(4, 3, Resize::Rewrap);

        assert_eq!((screen.cursor.row, screen.cursor.col), (1, 2));
        assert!(screen.cursor.wrap_pending);
    }

    #[test]
    fn the_carry_counts_the_rows_of_the_top_line_already_in_emacs() {
        let mut screen = Screen::new(2, 5);
        write(&mut screen, "aaaaabbbbbccccc");
        assert_eq!(screen.carried, 1, "one wrapped row has left for Emacs");

        write(&mut screen, "ddddd");
        assert_eq!(screen.carried, 2);
    }

    #[test]
    fn the_carry_resets_when_the_line_that_left_had_ended() {
        let mut screen = Screen::new(2, 5);
        write(&mut screen, "aaaaabbbbbccccc");
        screen.carriage_return();
        screen.linefeed();
        assert_eq!(screen.carried, 2);

        write(&mut screen, "new");
        screen.carriage_return();
        screen.linefeed();

        assert_eq!(
            screen.carried, 0,
            "the row that left ended its line, so the top row begins one"
        );
    }

    #[test]
    fn deleting_lines_at_the_top_leaves_the_carry_alone() {
        let mut screen = Screen::new(2, 5);
        write(&mut screen, "aaaaabbbbbccccc");
        assert_eq!(screen.carried, 1);

        screen.goto(0, 0);
        screen.delete_lines(1);

        assert_eq!(
            screen.carried, 1,
            "deleted rows are discarded, so Emacs still holds just the one"
        );
    }

    #[test]
    fn clearing_the_display_drops_the_carry() {
        let mut screen = Screen::new(2, 5);
        write(&mut screen, "aaaaabbbbbccccc");
        assert_eq!(screen.carried, 1);

        screen.erase_display(Erase::All);

        assert_eq!(screen.carried, 0);
    }

    /// The head occupies whole visual rows at the old width and seldom at the new one.
    /// The cells that finish its last row belong to the buffer, so they leave — otherwise
    /// row 0 would begin partway along a visual row and every break below it would be
    /// a column out.
    #[test]
    fn a_rewrap_hands_over_the_cells_that_complete_the_head() {
        let mut screen = Screen::new(4, 10);
        // 59 cells of one line through a 4x10 grid: two rows have left for Emacs.
        write(&mut screen, &"0".repeat(10));
        write(&mut screen, &"1".repeat(10));
        write(&mut screen, &"2".repeat(10));
        write(&mut screen, &"3".repeat(10));
        write(&mut screen, &"4".repeat(10));
        write(&mut screen, &"5".repeat(9));
        assert_eq!(screen.carried, 2);

        let history = screen.resize(4, 30, Resize::Rewrap);

        assert_eq!(history.len(), 1);
        assert_eq!(history[0].to_text(), "2".repeat(10));
        assert!(history[0].wrapped, "the line goes on below it");
        assert_eq!(
            screen.carried, 1,
            "the head is now exactly one visual row at the new width"
        );
        assert_eq!(
            screen.row(0).unwrap().to_text(),
            format!("{}{}{}", "3".repeat(10), "4".repeat(10), "5".repeat(9)),
            "row 0 begins a visual row of its own"
        );
    }

    #[test]
    fn a_rewrap_hands_over_nothing_when_the_head_already_fits_the_new_width() {
        let mut screen = Screen::new(4, 10);
        write(&mut screen, &"0".repeat(10));
        write(&mut screen, &"1".repeat(10));
        write(&mut screen, &"2".repeat(10));
        write(&mut screen, &"3".repeat(10));
        write(&mut screen, &"4".repeat(10));
        write(&mut screen, &"5".repeat(9));
        assert_eq!(screen.carried, 2);

        // Tall enough that the rewrap does not also have to evict for want of room, so
        // an empty history means no re-alignment rather than nothing having happened.
        let history = screen.resize(8, 5, Resize::Rewrap);

        assert!(
            history.is_empty(),
            "20 cells of head divide evenly into 5-column rows"
        );
        assert_eq!(screen.carried, 4);
        assert_eq!(screen.row(0).unwrap().to_text(), "22222");
    }

    #[test]
    fn a_scroll_region_suppresses_the_rewrap() {
        let mut screen = Screen::new(4, 10);
        write(&mut screen, "abcdefghij");
        screen.set_region(1, 2);

        screen.resize(4, 5, Resize::Rewrap);

        assert_eq!(
            screen.row(0).unwrap().to_text(),
            "abcde",
            "rows either side of the margins are different drawings, not one line"
        );
    }

    #[test]
    fn the_alt_screen_is_clamped_rather_than_rewrapped() {
        let mut screen = Screen::new(4, 10);
        write(&mut screen, "abcdefghijklmno");

        screen.resize(4, 5, Resize::Clamp);

        assert_eq!(screen.row(0).unwrap().to_text(), "abcde");
        assert_eq!(screen.row(1).unwrap().to_text(), "klmno");
    }

    #[test]
    fn damage_is_reported_once() {
        let mut screen = Screen::new(3, 4);
        screen.drain_damage();
        write(&mut screen, "x");
        assert_eq!(screen.drain_damage(), vec![0]);
        assert!(screen.drain_damage().is_empty());
    }

    #[test]
    fn insert_lines_pushes_the_rest_down() {
        let mut screen = Screen::new(3, 4);
        for line in ["a", "b"] {
            write(&mut screen, line);
            screen.carriage_return();
            screen.linefeed();
        }
        screen.goto(0, 0);
        screen.insert_lines(1);
        assert_eq!(screen.row(0).unwrap().to_text(), "");
        assert_eq!(screen.row(1).unwrap().to_text(), "a");
        assert_eq!(screen.row(2).unwrap().to_text(), "b");
    }
}
