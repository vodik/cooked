//! The addressable grid: cursor motion, scrolling regions, erasure, and damage tracking.

use super::cell::{CONTINUATION, Cell, Color, Extra, MarkId, Row, Run, Style};
use super::image::{ImageId, Placement};
use super::link::LinkId;
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
    /// `3` (xterm's "erase saved lines") is deliberately absent: unlike every other
    /// value here, it does not touch the grid at all, only the scrollback Emacs holds.
    /// See [`Event::EraseScrollback`](super::term::Event::EraseScrollback).
    pub fn from_param(n: u16) -> Option<Self> {
        match n {
            0 => Some(Self::ToEnd),
            1 => Some(Self::ToStart),
            2 => Some(Self::All),
            _ => None,
        }
    }
}

/// Rows that have left the top of a screen, on their way to the transcript.
///
/// A newtype rather than a bare `Vec<Row>` because dropping one is silent data loss: these
/// rows *are* the session's scrollback, and a caller that forgets to hand them to
/// [`State::archive`] loses that much history with nothing to show for it. `#[must_use]`
/// turns forgetting into a compiler warning.
///
/// Two callers discard deliberately -- a screen switch throwing away a full-screen
/// program's leftover frame, and `delete_lines` closing a gap -- and they say so with
/// [`Evicted::discard`], which is the point: the deliberate case reads differently from
/// the forgotten one.
#[must_use = "evicted rows are the session transcript; archive them or call `discard`"]
#[derive(Debug, Default)]
pub struct Evicted(Vec<Departed>);

/// One row on its way out of a grid, already reduced to what the transcript needs.
///
/// A [`Row`] owns a cell for every column, so carrying departing rows as rows kept
/// `cols * size_of::<Cell>()` alive per line for as long as the backlog held them --
/// and, worse, meant `scroll_up` had to *clone* the rows it was about to rotate away
/// just so the archiver could read them. Reducing here instead deletes both costs: the
/// clone has nothing to copy, and what is retained is trimmed to content.
///
/// The reduction is work that had to happen regardless; only its position moved.
#[derive(Debug)]
pub struct Departed {
    pub runs: Vec<Run>,
    pub wrapped: bool,
    /// Semantic marks still attached, as `(column, id)`.
    ///
    /// Empty for essentially every row, and an empty `Vec` does not allocate, so the
    /// ordinary line pays nothing to carry this.
    pub marks: Vec<(usize, MarkId)>,
}

impl Departed {
    /// `line_runs` rather than `runs`: these rows are becoming buffer text as part of a
    /// logical line, and a continuation row has to keep the blanks that are interior to
    /// it. See [`Row::line_runs`].
    fn from_row(row: &Row) -> Self {
        Self {
            runs: row.line_runs(),
            wrapped: row.wrapped,
            marks: row.marks().collect(),
        }
    }

    /// The row's text, for tests and diagnostics. Mirrors [`Row::to_text`], which is what
    /// the assertions on evicted rows used before they were reduced this early.
    pub fn to_text(&self) -> String {
        self.runs.iter().map(|run| run.text.as_str()).collect()
    }
}

impl Evicted {
    /// Nothing left the screen.
    ///
    /// `const` because it can be: this is the return on the overwhelming majority of
    /// writes -- every character that does not sit at the bottom margin -- so it is worth
    /// being a value the compiler can fold rather than a call.
    pub const fn none() -> Self {
        Self(Vec::new())
    }

    /// Reduce rows leaving a grid, for the producers that already own them.
    ///
    /// `scroll_up` deliberately does not use this: it reduces from the slice it is about
    /// to rotate, which is the whole point of reducing here rather than at drain time.
    /// The rest -- a resize shrinking, a rewrap overflowing, a full erase going to
    /// history -- construct their rows and have nothing to save by borrowing.
    fn from_rows(rows: &[Row]) -> Self {
        Self(rows.iter().map(Departed::from_row).collect())
    }

    /// These rows are not history. Says so out loud, so that a reader can tell this apart
    /// from a caller who simply forgot.
    pub fn discard(self) {}
}

/// Reading the rows is ordinary slice work; only *dropping* them needed a type.
impl std::ops::Deref for Evicted {
    type Target = [Departed];

    fn deref(&self) -> &[Departed] {
        &self.0
    }
}

/// By value, so `State::archive` can move each row's runs into the backlog rather than
/// rebuilding them. [`Evicted::discard`] and the `#[must_use]` above are unaffected:
/// consuming one deliberately still has to name the consumer.
impl IntoIterator for Evicted {
    type Item = Departed;
    type IntoIter = std::vec::IntoIter<Departed>;

    fn into_iter(self) -> Self::IntoIter {
        self.0.into_iter()
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
    /// Counted in rows rather than cells because a row that leaves mid-line is exactly
    /// `cols` wide — [`Row::line_runs`] keeps the trailing blanks that would otherwise cut
    /// it short — making `carried * cols` the head's exact width. The one row handed over
    /// narrower is the seam fragment [`Logical::take_front`] cuts, and that exists
    /// precisely to top the head up to a whole number of rows at the new width, so
    /// [`Screen::reflow`] restores the property before it returns and it holds
    /// unconditionally. [`Screen::head`] is the same quantity in characters.
    carried: usize,
    /// DECAWM, on by default as every terminal starts. See [`Screen::set_autowrap`].
    autowrap: bool,
    /// IRM. See [`Screen::set_insert_mode`].
    insert_mode: bool,
    /// Whether rows leaving the top of this grid are history worth building.
    ///
    /// False for the alternate grid, which is a running program's scratch frame and
    /// contributes no transcript. [`State::evicted`](super::term) already refuses to
    /// archive while `on_alt`, and this does not replace that: `evicted` is the funnel
    /// that owns the policy, and this only stops the *work* being done for rows nobody
    /// will read. Deleting either is wrong.
    ///
    /// It cannot be folded into [`Screen::archives`]'s region test. That test asks whether
    /// the scroll covers the whole grid, which is true of the alt screen as often as the
    /// primary — so before this flag existed, every full-region scroll under `less` or
    /// `vim` built a departure record per line and dropped it on the floor.
    history: bool,
}

impl Default for Screen {
    /// A 1x1 grid. Only [`State::new`] ever sees one, and it overwrites both screens with
    /// real sizes immediately; `Screen::new` floors both dimensions at 1 regardless.
    fn default() -> Self {
        Self::new(1, 1)
    }
}

impl Screen {
    /// `rows` is floored at 1 here, not merely by convention at the callers this
    /// binding happens to have. A zero-height screen has no last row for `arg()`'s
    /// callers to default a 1-based CSI parameter against — `CSI r` (DECSTBM) is the
    /// one place that default is the screen's own height rather than a literal — so
    /// this module keeping its own invariant is what makes that call site's
    /// `saturating_sub` a belt rather than the only strap.
    pub fn new(rows: usize, cols: usize) -> Self {
        let rows = rows.max(1);
        Self {
            rows: vec![Row::new(cols); rows],
            cols,
            cursor: Cursor::default(),
            region: Region::full(rows),
            saved: None,
            dirty: vec![true; rows],
            tabs: default_tabs(cols),
            carried: 0,
            autowrap: true,
            insert_mode: false,
            history: true,
        }
    }

    /// A grid whose departing rows are not history: the alternate screen.
    ///
    /// A constructor rather than a field left for the caller to clear, because the two
    /// grids are built side by side in [`State::new`](super::term) and a flag assigned
    /// after the fact is one a later edit can drop without anything failing — the symptom
    /// would be wasted work, which no test asserts the absence of. Saying it in the name
    /// makes it structural. See [`Screen::history`].
    pub fn scratch(rows: usize, cols: usize) -> Self {
        Self {
            history: false,
            ..Self::new(rows, cols)
        }
    }

    /// Drop the carry: nothing of the top row's line is in Emacs any more.
    pub fn forget_carry(&mut self) {
        self.carried = 0;
    }

    /// DECAWM. Off means the cursor pins to the last column and overwrites in place,
    /// which is how a program paints the bottom-right cell without scrolling the screen.
    pub fn set_autowrap(&mut self, on: bool) {
        self.autowrap = on;
        if !on {
            // A pending wrap is a wrap already decided on. Disarm it, or the next write
            // would honour a mode that is no longer set.
            self.cursor.wrap_pending = false;
        }
    }

    /// IRM. Held here rather than passed to [`Screen::write`] per character: the shift has
    /// to happen between the margin decision and the cell store, where the row and column
    /// invariants live, and threading a flag through the hottest call in the emulator to
    /// reach the same place would cost more than it explains.
    pub fn set_insert_mode(&mut self, on: bool) {
        self.insert_mode = on;
    }

    /// Account for `evicted` rows being handed to Emacs off the top of the grid.
    ///
    /// Only for rows that actually reached Emacs: a scroll region discards rows instead,
    /// and `reflow` refuses to run under one, so the carry is never read in that state.
    fn carry(&mut self, evicted: &[Departed]) {
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

    /// Put an OSC 133 mark on the cell at (`row`, `col`), if the grid has one.
    ///
    /// Not `touch`: a mark changes nothing about how the row is drawn, so damaging it
    /// would send Emacs a row it already has in order to say something the row does not
    /// carry.
    pub fn mark(&mut self, row: usize, col: usize, id: MarkId) {
        if let Some(row) = self.rows.get_mut(row) {
            row.mark(col, id);
        }
    }

    fn touch(&mut self, index: usize) -> Option<&mut Row> {
        *self.dirty.get_mut(index)? = true;
        self.rows.get_mut(index)
    }

    /// Mark every row in an inclusive range damaged.
    ///
    /// A slice fill rather than a loop of `dirty.get_mut(i)`: `scroll_up` calls this for
    /// the whole scroll region on *every* scrolled line, so the per-index bounds check was
    /// one branch per row per line of output. Clamping once and filling lets this be the
    /// memset it always was.
    fn touch_range(&mut self, range: std::ops::RangeInclusive<usize>) {
        let (first, last) = range.into_inner();
        let end = (last + 1).min(self.dirty.len());
        if let Some(span) = self.dirty.get_mut(first..end) {
            span.fill(true);
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
    pub fn write(&mut self, ch: char, style: Style) -> Evicted {
        let width = ch.width().unwrap_or(0);
        if width == 0 {
            let (row, col) = (self.cursor.row, self.cursor.col.saturating_sub(1));
            if let Some(r) = self.touch(row) {
                r.combine(col, ch);
            }
            return Evicted::none();
        }

        let cols = self.cols;
        // Read before `touch` borrows `self` mutably below.
        let insert_mode = self.insert_mode;
        let mut evicted = Evicted::none();
        // The margin decision, made once. Both new modes live inside the branch that was
        // already taken only at the edge of a row, so the common path is untouched.
        if self.cursor.wrap_pending || self.cursor.col + width > cols {
            if self.autowrap {
                if let Some(r) = self.touch(self.cursor.row) {
                    r.wrapped = true;
                }
                self.cursor.col = 0;
                evicted = self.linefeed(style);
            } else {
                // DECAWM off: the cursor never leaves the row. Back up far enough that a
                // wide character lands whole rather than half over the edge.
                self.cursor.col = cols.saturating_sub(width);
            }
        }

        let (row, col) = (self.cursor.row, self.cursor.col);
        // One `touch` for both edits. Two of them re-did the damage flag and the row
        // lookup for every character written in insert mode, and this is the hottest call
        // in the emulator -- so the insert lives inside the borrow rather than taking its
        // own.
        if let Some(r) = self.touch(row) {
            if insert_mode {
                // IRM shifts the rest of the row right by the character's full width, so a
                // wide character does not tear the cell it displaces.
                r.insert_blank(col, width, style);
            }
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
                // Only arm the deferred wrap when there is a wrap to defer.
                self.cursor.wrap_pending = self.autowrap;
            }
            next => self.cursor.col = next,
        }
        evicted
    }

    /// Place a run of one-column characters from the cursor, without leaving the row.
    ///
    /// Returns how many were placed, which may be fewer than offered and may be zero; the
    /// caller writes whatever is left through [`Screen::write`], one character at a time.
    /// That split is deliberate. Everything genuinely hard about placing a character --
    /// the deferred wrap, DECAWM, the scroll it can trigger, wide characters and the
    /// continuation cell they need, combining marks folding onto the cell to their left --
    /// stays in `write`, in one copy. This handles only the case where none of that
    /// applies, which is also the case that accounts for nearly all output.
    ///
    /// **The last column is left alone on purpose.** It is where `write` decides whether
    /// to arm the deferred wrap, and a second copy of that decision is how the two would
    /// drift apart. So the run stops one short and `write` places the character that
    /// lands there.
    ///
    /// Insert mode and a pending wrap both bail out entirely rather than being handled:
    /// IRM shifts the row per character, and a pending wrap means the next character
    /// scrolls.
    pub fn write_run(&mut self, text: &str, style: Style) -> usize {
        if self.insert_mode || self.cursor.wrap_pending {
            return 0;
        }
        let (row, col) = (self.cursor.row, self.cursor.col);
        let room = self.cols.saturating_sub(col + 1);
        let n = text.len().min(room);
        if n == 0 {
            return 0;
        }
        let Some(r) = self.touch(row) else {
            return 0;
        };
        r.fill_run(col, &text[..n], style);
        self.cursor.col = col + n;
        n
    }

    pub fn autowrap(&self) -> bool {
        self.autowrap
    }

    pub fn insert_mode(&self) -> bool {
        self.insert_mode
    }

    /// Record the pen's underline colour on the cell the cursor just wrote.
    ///
    /// Separate from [`Screen::write`] rather than a parameter to it: this is the rare
    /// path, and `write` is the hottest call in the emulator. Called after the write, so
    /// the column is the one the write settled on after any wrap.
    pub fn mark_underline(&mut self, color: Color, width: usize) {
        let (row, cols) = (self.cursor.row, self.cols);
        // The lead column of the character just written. The cursor has advanced past it
        // by its full width — or pinned at the last column, where the character ends
        // rather than begins. Taking the width into account is what keeps a colour off
        // the continuation cell of a wide character, which `Row::runs` skips, and where
        // it would therefore vanish.
        let col = if self.cursor.wrap_pending {
            cols.saturating_sub(width)
        } else {
            self.cursor.col.saturating_sub(width)
        };
        if let Some(r) = self.touch(row) {
            r.set_underline(col, color);
        }
    }

    /// Record the pen's open hyperlink on the cell the cursor just wrote.
    ///
    /// [`Screen::mark_underline`]'s twin, including the wide-character arithmetic: the
    /// id must land on the lead column, because [`Row::runs`] skips continuation cells
    /// and an attachment on one would simply vanish. Only the *reason* the pen holds a
    /// link differs from the underline colour's, and it differs sharply — see
    /// `Term`'s `link` field.
    pub fn mark_link(&mut self, link: Option<LinkId>, width: usize) {
        let (row, cols) = (self.cursor.row, self.cols);
        let col = if self.cursor.wrap_pending {
            cols.saturating_sub(width)
        } else {
            self.cursor.col.saturating_sub(width)
        };
        if let Some(r) = self.touch(row) {
            r.set_link(col, link);
        }
    }

    pub fn carriage_return(&mut self) {
        self.cursor.col = 0;
        self.cursor.wrap_pending = false;
    }

    /// Lay one row of image ID across the grid from the cursor, and say how wide it got.
    ///
    /// Clipped to the screen rather than wrapped: an image is a rectangle, and a row of
    /// it that continued on the next line would not be one. The caller moves down.
    pub fn place_image_row(&mut self, id: ImageId, cell_row: u16, cols: u16, pen: Style) -> u16 {
        let (row, start) = (self.cursor.row, self.cursor.col);
        let width = usize::from(cols).min(self.cols.saturating_sub(start));
        if let Some(r) = self.touch(row) {
            for i in 0..width {
                r.place(
                    start + i,
                    Placement {
                        id,
                        cell_row,
                        cell_col: i as u16,
                    },
                    pen,
                );
            }
        }
        width as u16
    }

    /// LF/IND: down one, scrolling the region if already at its bottom.
    pub fn linefeed(&mut self, pen: Style) -> Evicted {
        self.cursor.wrap_pending = false;
        match self.cursor.row {
            row if row == self.region.bottom => self.scroll_up(1, pen),
            row if row + 1 < self.rows.len() => {
                self.cursor.row = row + 1;
                Evicted::none()
            }
            _ => Evicted::none(),
        }
    }

    /// RI: up one, scrolling the region down if already at its top.
    pub fn reverse_index(&mut self, pen: Style) {
        self.cursor.wrap_pending = false;
        match self.cursor.row {
            row if row == self.region.top => self.scroll_down(1, pen),
            0 => {}
            row => self.cursor.row = row - 1,
        }
    }

    /// True when the scroll region is the whole screen, the only case in which rows
    /// leaving the top are history rather than discarded.
    fn archives(&self) -> bool {
        self.history && self.region == Region::full(self.rows.len())
    }

    /// Shift the region up by `n`, returning rows that became scrollback.
    pub fn scroll_up(&mut self, n: usize, pen: Style) -> Evicted {
        let Region { top, bottom } = self.region;
        let n = n.min(self.region.height());
        if n == 0 {
            return Evicted::none();
        }
        // Reduced here, from the rows still in place, rather than cloned across the
        // rotation below. `rotate_left` moves rows without touching their contents and
        // the `clear` after it is what the clone used to be protecting against, so
        // reading them first is trivially equivalent -- and it is the difference between
        // one `Vec<Cell>` copy per scrolled line and none.
        //
        // After the flag, not before: `Screen::write` marks the row above `wrapped` on a
        // write-wrap and only then calls `linefeed`, so the value `line_runs` reads here
        // is the settled one.
        let evicted = if self.archives() {
            Evicted::from_rows(&self.rows[top..top + n])
        } else {
            Evicted::none()
        };
        self.rows[top..=bottom].rotate_left(n);
        for row in &mut self.rows[bottom + 1 - n..=bottom] {
            row.clear(pen.erase());
        }
        self.touch_range(top..=bottom);
        self.carry(&evicted);
        evicted
    }

    /// Remove `count` rows starting at `first`, closing the gap from below.
    ///
    /// Not a scroll: the rows are discarded rather than archived, because the caller is
    /// deleting a finished command's output and archiving it would put it straight back
    /// into the buffer as scrollback. Rows below shift up, blanks come in at the bottom,
    /// and the whole affected span is marked damaged so the next drain repaints it.
    ///
    /// This is the only way the grid may be edited from outside, and it goes through the
    /// emulator for the same reason input does: rows have exactly one owner. Emacs asks;
    /// nothing above ever deletes buffer text the grid still holds, or the two ends stop
    /// agreeing about what the screen is.
    ///
    /// Removing from the very top clears [`Screen::carried`]. That count says how much of
    /// row 0's logical line has already been handed to Emacs, and once row 0 itself is
    /// gone the new top row continues nothing.
    ///
    /// The scroll region is deliberately left alone. The row count is unchanged, so its
    /// bounds stay valid, and resetting it here would clear a child's `DECSTBM` as a side
    /// effect of an unrelated edit — [`Screen::delete_lines`] saves and restores it around
    /// its own temporary change for the same reason, and [`Screen::reset_region`] exists
    /// for the callers that mean it.
    pub fn remove_rows(&mut self, first: usize, count: usize) {
        let height = self.rows.len();
        let first = first.min(height);
        let count = count.min(height - first);
        if count == 0 {
            return;
        }
        self.rows.drain(first..first + count);
        let pen = Style::default();
        self.rows.resize(height, Row::new(self.cols));
        for row in &mut self.rows[height - count..] {
            row.clear(pen.erase());
        }
        if first == 0 {
            self.carried = 0;
        }
        // The cursor rides with the text it was sitting on or below.
        self.cursor.row = if self.cursor.row >= first + count {
            self.cursor.row - count
        } else if self.cursor.row >= first {
            first
        } else {
            self.cursor.row
        };
        self.cursor.wrap_pending = false;
        self.touch_range(first..=height - 1);
    }

    pub fn scroll_down(&mut self, n: usize, pen: Style) {
        let Region { top, bottom } = self.region;
        let n = n.min(self.region.height());
        if n == 0 {
            return;
        }
        self.rows[top..=bottom].rotate_right(n);
        for row in &mut self.rows[top..top + n] {
            row.clear(pen.erase());
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
        let row = if self.region.contains(self.cursor.row) {
            row.clamp(self.region.top, self.region.bottom)
        } else {
            row
        };
        self.goto(row, col);
    }

    pub fn erase_line(&mut self, how: Erase, pen: Style) {
        let (col, cols) = (self.cursor.col, self.cols);
        let row = self.cursor.row;
        let style = pen.erase();
        if let Some(r) = self.touch(row) {
            match how {
                Erase::ToEnd => r.fill(col..cols, style),
                Erase::ToStart => r.fill(0..=col.min(cols - 1), style),
                // The one whole-row erase that keeps semantic marks: see `Row::erase_all`.
                Erase::All => r.erase_all(style),
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
    pub fn erase_display(&mut self, how: Erase, pen: Style) -> Evicted {
        let (row, last) = (self.cursor.row, self.rows.len());
        match how {
            Erase::ToEnd => {
                self.erase_line(Erase::ToEnd, pen);
                self.clear_rows(row + 1..last, pen);
                Evicted::none()
            }
            Erase::ToStart => {
                self.clear_rows(0..row, pen);
                self.erase_line(Erase::ToStart, pen);
                Evicted::none()
            }
            Erase::All => {
                // `has_text`, not `!is_blank`: with `bce` a screen the child painted and
                // then cleared has a background on every cell, and archiving that would
                // hand Emacs a screenful of pure colour with nothing written on it.
                let history = if self.archives() && self.rows.iter().any(Row::has_text) {
                    Evicted::from_rows(&self.rows[..=self.last_used_row()])
                } else {
                    Evicted::none()
                };
                self.clear_rows(0..last, pen);
                // Whatever was on screen has gone to history whole, so the next row 0
                // starts a line rather than continuing one.
                self.carried = 0;
                history
            }
        }
    }

    fn clear_rows(&mut self, range: std::ops::Range<usize>, pen: Style) {
        for i in range {
            if let Some(r) = self.touch(i) {
                r.clear(pen.erase());
            }
        }
    }

    pub fn erase_chars(&mut self, n: usize, pen: Style) {
        let (row, col, cols) = (self.cursor.row, self.cursor.col, self.cols);
        if let Some(r) = self.touch(row) {
            r.fill(col..(col + n).min(cols), pen.erase());
        }
    }

    pub fn insert_chars(&mut self, n: usize, pen: Style) {
        let (row, col) = (self.cursor.row, self.cursor.col);
        if let Some(r) = self.touch(row) {
            r.insert_blank(col, n, pen.erase());
        }
    }

    pub fn delete_chars(&mut self, n: usize, pen: Style) {
        let (row, col) = (self.cursor.row, self.cursor.col);
        if let Some(r) = self.touch(row) {
            r.delete(col, n, pen.erase());
        }
    }

    /// IL/DL operate on a temporary region starting at the cursor row. Lines deleted this
    /// way are destroyed, never archived.
    pub fn insert_lines(&mut self, n: usize, pen: Style) {
        if !self.region.contains(self.cursor.row) {
            return;
        }
        let saved = self.region;
        self.region = Region {
            top: self.cursor.row,
            bottom: saved.bottom,
        };
        self.scroll_down(n, pen);
        self.region = saved;
    }

    pub fn delete_lines(&mut self, n: usize, pen: Style) {
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
        self.scroll_up(n, pen).discard();
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

    /// CBT: back `count` tab stops, floored at column 0.
    pub fn back_tab(&mut self, count: usize) {
        let col = (0..count).fold(self.cursor.col, |col, _| {
            self.tabs
                .iter()
                .enumerate()
                .take(col)
                .rev()
                .find_map(|(i, stop)| stop.then_some(i))
                .unwrap_or(0)
        });
        self.cursor.col = col;
        self.cursor.wrap_pending = false;
    }

    pub fn set_tab(&mut self) {
        if let Some(stop) = self.tabs.get_mut(self.cursor.col) {
            *stop = true;
        }
    }

    pub fn clear_tabs(&mut self, all: bool) {
        if all {
            self.tabs.fill(false);
        } else if let Some(stop) = self.tabs.get_mut(self.cursor.col) {
            *stop = false;
        }
    }

    pub fn backspace(&mut self) {
        self.cursor.col = self.cursor.col.saturating_sub(1);
        self.cursor.wrap_pending = false;
    }

    /// Index of the last row holding anything, or 0.
    ///
    /// The last row worth archiving. Keyed on text, not on styling: a `bce` background
    /// wash below the last written line is not transcript.
    fn last_used_row(&self) -> usize {
        self.rows
            .iter()
            .rposition(|row| row.has_text())
            .unwrap_or(0)
    }

    /// Rows the screen occupies: everything down to the last one holding something, and
    /// never fewer than the cursor's own row.
    ///
    /// The bound a shrink may not eat into, and the same number Emacs shapes the buffer's
    /// screen region by — reported on the drain rather than re-derived there, since a
    /// buffer that disagrees keeps rendering rows the grid has stopped having.
    pub fn used(&self) -> usize {
        self.last_used_row().max(self.cursor.row) + 1
    }

    /// Characters of row 0's logical line that are already in Emacs.
    ///
    /// See [`Screen::carried`](Self#structfield.carried). Reported in characters rather
    /// than rows so the other end never has to reconstruct it from a width, and so it
    /// stays meaningful if a departed row is ever not exactly `cols` wide.
    pub fn head(&self) -> usize {
        self.carried * self.cols
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
    pub fn resize(&mut self, rows: usize, cols: usize, mode: Resize) -> Evicted {
        // Same floor as `Screen::new`, for the same reason: a zero-height screen has no
        // last row for `CSI r`'s default to fall back on.
        let rows = rows.max(1);
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

        let shed: Vec<Row> = match rows.cmp(&self.rows.len()) {
            std::cmp::Ordering::Less => {
                let excess = self.rows.len() - rows;
                let keep = self.used();
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
        let evicted = Evicted::from_rows(&shed);

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
    /// The live grid is a transcript Emacs has not been given yet, so truncating it to a
    /// narrower width destroys text outright: run `ps`, narrow the frame, and the columns
    /// past the new edge are simply gone. `Row::wrapped` records which rows are
    /// continuations rather than lines of their own, which is enough to recover the lines
    /// the child actually printed and chunk them again at the new width.
    ///
    /// Scrollback has always worked this way: it keeps one buffer line per logical line and
    /// lets Emacs re-wrap it for display. This gives the live screen the same property, and
    /// with it the round trip — narrowing and widening back returns the original layout,
    /// because the wrap provenance is preserved rather than destroyed.
    fn reflow(&mut self, rows: usize, cols: usize) -> Evicted {
        // Cells of the first line that are already in Emacs, measured at the width they
        // were chunked at — which is the one still in force as the grid is read.
        let mut head = self.carried * self.cols;

        // The same bound the shrink path uses, so the blank rows below the content are
        // still absorbed first rather than being rewrapped into a screenful of nothing.
        let keep = self.used();

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
            history.push(Departed::from_row(&lines[0].take_front(split, !ends_here)));
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
        let evicted = Evicted::from_rows(&evicted);
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
        Evicted(history)
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
/// The unit a rewrap preserves, reassembled from the rows a `wrapped` chain covers.
/// Attachments are keyed by offset within `cells` rather than by screen column, since the
/// column a cell will end up in is not known until it is chunked again.
#[derive(Debug, Default)]
struct Logical {
    cells: Vec<Cell>,
    extras: Vec<(usize, Extra)>,
    /// Semantic marks, held apart from `extras` because they are the one attachment
    /// allowed to sit past the end of the line's text.
    ///
    /// A `D' mark lands on the cell the cursor was on after the last newline, which is
    /// routinely a blank one; `extras` are filtered to the range a chunk actually covers,
    /// which would drop exactly those. This is the same problem the cursor has, and it is
    /// solved the same way: carried by offset, placed after chunking, and clamped onto
    /// the last row when the offset falls past every chunk. See [`Logical::chunk`].
    marks: Vec<(usize, MarkId)>,
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
        self.extras.extend(
            row.extras()
                .iter()
                .filter(|(at, extra)| usize::from(*at) < len && !matches!(extra, Extra::Mark(_)))
                .map(|(at, extra)| (base + usize::from(*at), extra.clone())),
        );
        // Unfiltered by `len`, unlike everything else on the row: a mark on a column past
        // the text is the common case rather than a corner one.
        self.marks
            .extend(row.marks().map(|(at, id)| (base + at, id)));
        base
    }

    /// Cut the line into rows of exactly `cols`, never splitting a wide character.
    ///
    /// Marks are placed by [`Logical::row`] along with everything else, except for the
    /// ones no chunk covers -- an offset at the very end of a line whose length is an
    /// exact multiple of `cols`, and anything past the cells the line has. Those land on
    /// the last column of the last row, which is the same resolution [`place`] reaches
    /// for the cursor in that position and the nearest cell a mark can still name.
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
        // The marks no chunk claimed, onto the end of the last one. `start` is the last
        // chunk's own first offset, so this is exactly the column range that row covers
        // rather than a count of rows times `cols` -- which the wide-character path above
        // can make untrue by resuming a chunk part way along.
        if let Some(last) = rows.last_mut() {
            let end = last.len().saturating_sub(1);
            for (_, id) in self.marks.iter().filter(|(at, _)| *at >= start + cols) {
                last.mark(end, *id);
            }
        }
        rows
    }

    /// Split the first `n` cells off the front as a row of their own, keeping their marks.
    ///
    /// Its width is `n` rather than the screen's, because this row is the *tail* of a
    /// visual row whose leading columns are already in Emacs — it completes one, it is not
    /// one. Padding it out to `cols` would hand over blanks belonging to no column and
    /// push the seam a whole row along, since `Row::line_runs` keeps a continuation row's
    /// trailing blanks on purpose.
    fn take_front(&mut self, n: usize, wrapped: bool) -> Row {
        let row = self.row(0, n, n, wrapped);
        self.cells.drain(..n);
        self.extras.retain_mut(|(at, _)| {
            let keep = *at >= n;
            if keep {
                *at -= n;
            }
            keep
        });
        // The marks inside the fragment went with it -- `row` above took them -- and the
        // fragment becomes buffer text this drain, where the drain reports them as an
        // offset into the scrollback batch rather than a cell on the grid.
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
        let taken = end.min(start + cols);
        let mut cells = self.cells[start..taken].to_vec();
        cells.resize(cols, Cell::default());
        // Bounded by `taken`, not by `end`: `chunk` hands this a range wider than the
        // screen for a character that fits nowhere, and filtering against the unclamped
        // range then built a row whose attachments indexed past its own cells.
        let mut extras: Vec<(u16, Extra)> = self
            .extras
            .iter()
            .filter(|(at, _)| (start..taken).contains(at))
            .map(|(at, extra)| ((at - start) as u16, extra.clone()))
            .collect();
        // Against the row's *columns*, not its text: the row is padded out to `cols`, and
        // a mark on a blank column of it is on this row however little text reaches that
        // far. `taken` is where the cells stop, `start + cols` is where the row does.
        extras.extend(
            self.marks
                .iter()
                .filter(|(at, _)| (start..start + cols).contains(at))
                .map(|(at, id)| ((at - start) as u16, Extra::Mark(*id))),
        );
        extras.sort_by_key(|(at, _)| *at);
        Row::from_parts(cells, extras, wrapped)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(screen: &mut Screen, text: &str) {
        for ch in text.chars() {
            screen.write(ch, Style::default()).discard();
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
        screen.linefeed(Style::default()).discard();
        write(&mut screen, "bb");
        let evicted = screen.linefeed(Style::default());

        assert_eq!(evicted.len(), 1);
        assert_eq!(evicted[0].to_text(), "aa");
        assert_eq!(screen.row(0).unwrap().to_text(), "bb");
    }

    fn lines(screen: &mut Screen, texts: &[&str]) {
        for (i, line) in texts.iter().enumerate() {
            screen.goto(i, 0);
            write(screen, line);
        }
    }

    #[test]
    fn removing_rows_closes_the_gap_from_below() {
        let mut screen = Screen::new(4, 4);
        lines(&mut screen, &["a", "b", "c", "d"]);

        screen.remove_rows(1, 2);

        assert_eq!(screen.row(0).unwrap().to_text(), "a");
        assert_eq!(screen.row(1).unwrap().to_text(), "d");
        assert_eq!(screen.row(2).unwrap().to_text(), "");
        assert_eq!(screen.row(3).unwrap().to_text(), "");
    }

    #[test]
    fn removed_rows_are_discarded_not_archived() {
        // Archiving would hand them straight back to Emacs as scrollback, which is the
        // opposite of deleting them.
        let mut screen = Screen::new(3, 4);
        lines(&mut screen, &["a", "b", "c"]);
        screen.drain_damage();

        screen.remove_rows(0, 1);

        assert_eq!(screen.row(0).unwrap().to_text(), "b");
        assert_eq!(
            screen.drain_damage(),
            vec![0, 1, 2],
            "everything below must repaint"
        );
    }

    #[test]
    fn removing_rows_carries_the_cursor_with_its_text() {
        let mut screen = Screen::new(4, 4);
        lines(&mut screen, &["a", "b", "c", "d"]);

        screen.goto(3, 1);
        screen.remove_rows(1, 2);
        assert_eq!(
            (screen.cursor.row, screen.cursor.col),
            (1, 1),
            "row 3 became row 1"
        );

        // A cursor inside the removed span has nothing left to sit on; it lands on the
        // first row that survived.
        lines(&mut screen, &["a", "b", "c", "d"]);
        screen.goto(2, 0);
        screen.remove_rows(1, 2);
        assert_eq!(screen.cursor.row, 1);

        // Above the removal, nothing moved.
        lines(&mut screen, &["a", "b", "c", "d"]);
        screen.goto(0, 0);
        screen.remove_rows(1, 2);
        assert_eq!(screen.cursor.row, 0);
    }

    #[test]
    fn removing_the_top_row_forgets_the_carried_head() {
        // `carried` says how much of row 0's logical line Emacs already holds; once row 0
        // is gone the new top row continues nothing.
        let mut screen = Screen::new(2, 4);
        write(&mut screen, "aaaa");
        write(&mut screen, "bb");
        screen.scroll_up(1, Style::default()).discard();
        assert_ne!(screen.head(), 0, "precondition: something was carried");

        screen.remove_rows(0, 1);
        assert_eq!(screen.head(), 0);
    }

    #[test]
    fn removing_rows_leaves_the_scroll_region_alone() {
        // Deleting a command's output must not clear a child's DECSTBM behind its back.
        let mut screen = Screen::new(4, 4);
        lines(&mut screen, &["a", "b", "c", "d"]);
        screen.set_region(1, 2);
        let region = screen.region;

        screen.remove_rows(2, 1);

        assert_eq!(screen.region, region);
    }

    #[test]
    fn removing_more_rows_than_there_are_is_clamped() {
        let mut screen = Screen::new(2, 4);
        lines(&mut screen, &["a", "b"]);
        screen.remove_rows(1, 99);
        assert_eq!(screen.row(0).unwrap().to_text(), "a");
        assert_eq!(screen.row(1).unwrap().to_text(), "");
        screen.remove_rows(9, 1); // entirely past the end
        assert_eq!(screen.row(0).unwrap().to_text(), "a");
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
        let evicted = screen.linefeed(Style::default());

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
        screen.erase_line(Erase::ToEnd, Style::default());
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
    fn a_scratch_grid_hands_nothing_to_history() {
        let mut primary = Screen::new(2, 10);
        let mut scratch = Screen::scratch(2, 10);
        for screen in [&mut primary, &mut scratch] {
            screen.goto(0, 0);
            write(screen, "top");
        }

        // Both scroll the full region, which is the only condition `archives' used to
        // test -- so before `history' this pair was indistinguishable and the scratch
        // grid built a departure record per line for a transcript that does not exist.
        assert_eq!(primary.scroll_up(1, Style::default()).len(), 1);
        assert!(scratch.scroll_up(1, Style::default()).is_empty());

        // The scroll itself still happened: this is about what leaves, not what moves.
        assert_eq!(scratch.row(0).unwrap().to_text(), "");
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

        screen.resize(4, 5, Resize::Rewrap).discard();
        screen.resize(4, 10, Resize::Rewrap).discard();

        assert_eq!(screen.row(0).unwrap().to_text(), "abcdefghij");
        assert_eq!(screen.row(1).unwrap().to_text(), "klmno");
        assert!(screen.row(0).unwrap().wrapped);
        assert!(!screen.row(1).unwrap().wrapped);
    }

    #[test]
    fn a_rewrap_never_splits_a_wide_character() {
        let mut screen = Screen::new(4, 10);
        write(&mut screen, "abcd漢");

        screen.resize(4, 5, Resize::Rewrap).discard();

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

        screen.resize(4, 3, Resize::Rewrap).discard();

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

        screen.resize(4, 6, Resize::Rewrap).discard();

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

        screen.resize(4, 3, Resize::Rewrap).discard();

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
        screen.linefeed(Style::default()).discard();
        assert_eq!(screen.carried, 2);

        write(&mut screen, "new");
        screen.carriage_return();
        screen.linefeed(Style::default()).discard();

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
        screen.delete_lines(1, Style::default());

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

        screen.erase_display(Erase::All, Style::default()).discard();

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

        screen.resize(4, 5, Resize::Rewrap).discard();

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

        screen.resize(4, 5, Resize::Clamp).discard();

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
            screen.linefeed(Style::default()).discard();
        }
        screen.goto(0, 0);
        screen.insert_lines(1, Style::default());
        assert_eq!(screen.row(0).unwrap().to_text(), "");
        assert_eq!(screen.row(1).unwrap().to_text(), "a");
        assert_eq!(screen.row(2).unwrap().to_text(), "b");
    }
}
