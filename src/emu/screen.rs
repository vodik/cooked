//! The addressable grid: cursor motion, scrolling regions, erasure, and damage tracking.

use super::cell::{CONTINUATION, Cell, Extra, MarkId, Pen, Row, RowMeta, RowMut, RowRef, Runs};
use super::image::{CellSize, ImageId, Placement};
use super::style::StyleId;
use super::units::{Chars, Cols};

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

/// Rows moved wholesale to a different index, so Emacs can move its own text rather than
/// be handed all of it again.
///
/// After a scroll every index in the region holds different text, but the text only moved,
/// and the buffer can move it with two edits while keeping every marker, overlay and
/// fontification in the surviving rows. So the region is reported as a shift, and only the
/// recycled rows at the far end are damaged.
///
/// A shift is what makes the *undamaged* rows correct, so it may never be dropped in favour
/// of nothing -- only in favour of damaging every row it covers, as [`Screen::touch_all`]
/// does.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Shift {
    /// The scroll region the rows moved within, inclusive at both ends.
    pub top: usize,
    pub bottom: usize,
    /// How far they moved. As reported to Emacs, always at least one and always *less*
    /// than the region's height: at the height the region turned over completely, every
    /// row in it is damaged anyway, and a shift would be a whole-region delete and insert
    /// bought for nothing. See [`Screen::drain_shifts`], which is where such an entry is
    /// dropped, and [`Screen::shift`] for why it is kept in the log until then.
    pub count: usize,
    pub direction: Direction,
}

/// The row moves since the last drain, and whether the log of them is complete.
///
/// One value rather than a `Vec<Shift>` beside a `bool`, which let a reader consult one
/// and not the other: whether anything is missing from the log decides whether its first
/// entry may be read as the scroll that took a promoted row off the top, so the two are
/// one question and [`Shifts::leading_scroll`] is where it is asked.
///
/// A field rather than the payload of two enum variants, because dropping is not a
/// terminal state a fresh value would represent just as well: [`Shifts::record`] still
/// has to answer every later call this same drain window, it just answers `false` without
/// touching the log, and [`Shifts::take`] still has to hand the (empty) log back and put
/// tracking to rights for the next window.
#[derive(Debug, Clone, Default)]
struct Shifts {
    /// The moves in the order they happened; see [`Shift`]. Written only by
    /// [`Shifts::record`]. Empty whenever `tracking` is [`Tracking::Dropped`]: nothing
    /// recorded while dropped would reach Emacs, since [`Screen::drain_shifts`] hands the
    /// log over regardless of `tracking`, so [`Shifts::record`] never lets one in.
    log: Vec<Shift>,
    /// Whether [`Shifts::log`] covers the whole window since the last drain.
    tracking: Tracking,
}

/// Whether a [`Shifts`] log has a hole in it; see [`Shifts::record`], which is the one
/// place a hole is made, and why it is safe there.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
enum Tracking {
    /// Every move since the last drain is in the log.
    #[default]
    Tracked,
    /// The log grew as long as the screen is tall and was thrown away: every row was
    /// damaged on the spot, so every move from here to the next drain is redundant and
    /// none of them are recorded.
    Dropped,
}

impl Shifts {
    /// The move the drain window opened with, or `None` if the log cannot say.
    ///
    /// The one question a promotion turns on: the rows handed to scrollback left by this
    /// scroll, so Emacs may keep its own text for them and be told to open blanks at the
    /// bottom of the region instead -- see `Front::promote`. A log with a hole in it
    /// cannot answer it. A 2-row screen that scrolls up twice, down twice and up twice
    /// more in one drain records the first two moves and drops them at the fifth, and
    /// every move after that goes unrecorded too, so rows promoted by the first scroll
    /// would be taken out of a scroll that never happened.
    fn leading_scroll(&self) -> Option<Shift> {
        match self.tracking {
            Tracking::Tracked => self.log.first().copied(),
            Tracking::Dropped => None,
        }
    }

    /// How many rows the moves since the last drain have taken off the top of the screen,
    /// or `None` when the log holds a move other than one scroll of a region from the top
    /// row, or cannot account for them all.
    fn scrolled_off(&self) -> Option<usize> {
        match (self.tracking, self.log.as_slice()) {
            (Tracking::Tracked, []) => Some(0),
            (Tracking::Tracked, [shift]) if shift.top == 0 && shift.direction == Direction::Up => {
                Some(shift.count)
            }
            _ => None,
        }
    }

    /// Forget the moves without claiming the log is complete again; see
    /// [`Screen::touch_all`], whose caller is about to send every row whole.
    fn forget(&mut self) {
        self.log.clear();
    }

    /// Record that `n` rows moved within `top..=bottom`, returning whether it was worth
    /// recording; see [`Shift`] and [`Screen::shift`], its only caller.
    ///
    /// Coalescing is by identity of the region and direction, and only against the
    /// preceding entry: two moves of the same rows the same way compose into one, which is
    /// the only composition a flood produces. Anything else stays a separate entry.
    ///
    /// **False once the accumulated move reaches the region's height.** A `cat` of a
    /// thousand lines turns a 24-row screen over forty times, recycling every row, so a
    /// shift on top would be a whole-region delete and insert bought for nothing. The
    /// caller damages the whole region instead, and [`Shifts::take`] drops the entry.
    ///
    /// The entry is *kept*, saturated at the height, rather than removed. Removed, the next
    /// line feed would push a fresh entry that climbs back to the height, and a flood would
    /// hand Emacs buffer edits per drain for rows it is about to rewrite. Kept, every later
    /// scroll answers false in two comparisons.
    ///
    /// **False, and the log dropped, once it holds as many entries as the screen has
    /// rows.** A drain normally takes the log every frame, so it never gets there; a
    /// buffer no window shows is drained without it, and a child scrolling two regions in
    /// turn would grow it by an entry per scroll for as long as nobody looks. Replaying
    /// more moves than there are rows costs more than rewriting every row, so `rows`
    /// (the caller's height) is marked damaged instead. Dropping the moves already logged
    /// is safe because Emacs has applied none of them: its text and the core's copy of
    /// that text still agree row for row, so the rows that match the copy are still left
    /// out. A promotion is one of those moves, so the drain drops it too; see
    /// [`Shifts::leading_scroll`].
    ///
    /// **False, and nothing recorded, for every call once dropped.** Every row is already
    /// damaged for the rest of this drain window, and a later move over the same interval
    /// only rearranges rows Emacs is about to be sent whole -- recording it would have
    /// `cooked--apply-shifts` replay a rotation on top of text `cooked--render-rows` is
    /// about to overwrite. Tracking resumes at the next drain; see [`Shifts::take`].
    fn record(
        &mut self,
        top: usize,
        bottom: usize,
        n: usize,
        direction: Direction,
        rows: usize,
    ) -> Recorded {
        if self.tracking == Tracking::Dropped {
            return Recorded::Redundant;
        }
        let height = bottom + 1 - top;
        if let Some(last) = self.log.last_mut() {
            if last.top == top && last.bottom == bottom && last.direction == direction {
                last.count = (last.count + n).min(height);
                return if last.count < height {
                    Recorded::Kept
                } else {
                    Recorded::Saturated
                };
            }
        }
        if self.log.len() >= rows {
            self.log.clear();
            self.tracking = Tracking::Dropped;
            return Recorded::JustDropped;
        }
        self.log.push(Shift {
            top,
            bottom,
            count: n.min(height),
            direction,
        });
        if n < height {
            Recorded::Kept
        } else {
            Recorded::Saturated
        }
    }

    /// The moves, for a drain that hands them to Emacs, and a complete log again.
    ///
    /// Saturated entries are dropped here, since a region that turned over completely has
    /// every row damaged; see [`Shifts::record`] for why they stay in the log until then.
    /// The log is already empty when `tracking` is [`Tracking::Dropped`] -- see
    /// [`Shifts::record`] -- so there is nothing here to filter for that case.
    fn take(&mut self) -> Vec<Shift> {
        debug_assert!(self.tracking == Tracking::Tracked || self.log.is_empty());
        self.tracking = Tracking::Tracked;
        let mut shifts = std::mem::take(&mut self.log);
        shifts.retain(|s| s.count < s.bottom + 1 - s.top);
        shifts
    }
}

/// What [`Shifts::record`] did with a move, and how much of the screen the caller must
/// mark damaged for it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Recorded {
    /// Stayed in the log below the region's height. Only the rows the move recycled need
    /// to be marked damaged.
    Kept,
    /// Turned the region over completely, or repeated a region already saturated. The
    /// whole region needs to be marked damaged.
    Saturated,
    /// The log just reached the height of the screen and was thrown away. The whole
    /// screen needs to be marked damaged, once, by the caller.
    JustDropped,
    /// The log dropped before this call, and every row is already damaged. Nothing was
    /// recorded and there is nothing left for the caller to damage.
    Redundant,
}

/// Which way a [`Shift`] moved its rows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    /// Towards the region's top: `IND`, `SU`, `DL`, and the ordinary line feed.
    Up,
    /// Towards the region's bottom: `RI`, `SD`, `IL`.
    Down,
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
/// `State::archive` loses that much history with nothing to show for it. `#[must_use]`
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
/// A [`Row`] owns a cell for every column, so the backlog holding rows would keep
/// `cols * size_of::<Cell>()` alive per line, and `scroll_up` would have to clone rows it
/// is about to rotate away. Reducing them to runs as they leave avoids both.
#[derive(Debug)]
pub struct Departed {
    pub runs: Runs,
    pub wrapped: bool,
    /// Semantic marks still attached, as `(offset, id)`, the offset counting the
    /// characters of the row's text before the mark rather than its columns: this is the
    /// last moment the cells are there to count, and a scrolled row is addressed in Emacs
    /// by character. See [`chars_before`](super::cell::chars_before).
    ///
    /// Empty for essentially every row, and an empty `Vec` does not allocate, so the
    /// ordinary line pays nothing to carry this.
    pub marks: Vec<(Chars, MarkId)>,
    /// The row itself, cells and attachments, for the few rows that leave while
    /// [`Screen::witness`] asks for them.
    ///
    /// The copy of what Emacs holds compares these with its own cells to decide whether
    /// Emacs can keep its text for the row; see `Front::promote`. Comparing cells is a
    /// `memcmp`, where rebuilding the copy's runs to compare with `runs` cost more than
    /// the row's own reduction did.
    pub row: Option<Box<Row>>,
}

impl Departed {
    /// Characters this row puts in the buffer, which is what a head is counted in.
    fn chars(&self) -> Chars {
        self.runs.chars()
    }

    /// `line_runs` rather than `runs`: these rows are becoming buffer text as part of a
    /// logical line, and a continuation row has to keep the blanks that are interior to
    /// it. See [`Row::line_runs`].
    fn from_row(row: RowRef<'_>) -> Self {
        Self {
            runs: row.line_runs(),
            wrapped: row.wrapped(),
            marks: row
                .marks()
                .map(|(col, id)| (row.chars_before(col), id))
                .collect(),
            row: None,
        }
    }

    /// The row's text, for tests and diagnostics; the equivalent of [`Row::to_text`].
    pub fn to_text(&self) -> String {
        self.runs.text().to_owned()
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
    fn from_rows<'a>(rows: impl IntoIterator<Item = RowRef<'a>>) -> Self {
        Self(rows.into_iter().map(Departed::from_row).collect())
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
    /// Every cell of the grid, `cols` to a slot, in one contiguous buffer.
    ///
    /// A slot is a row's storage and not its position: [`Screen::order`] says which slot
    /// is shown at each screen row. Keeping the cells flat puts a whole screen in one
    /// allocation that is read and compared sequentially, and keeping the order separate
    /// is what lets a scroll stay cheap. Rotating `order` moves a row whatever the width,
    /// where moving the cells of a 400-column scroll region would copy all of them on
    /// every linefeed.
    cells: Vec<Cell>,
    /// What each slot's row carries besides its cells, indexed by slot like `cells`.
    meta: Vec<RowMeta>,
    /// The slot shown at each screen row, top to bottom. Its length is the grid's height.
    order: Vec<u32>,
    cols: usize,
    /// Private so that every move goes through a method that keeps [`Cursor::wrap_pending`]
    /// honest: a pending wrap only means something on the last column, and a caller
    /// writing `col` directly could leave one armed anywhere.
    cursor: Cursor,
    region: Region,
    /// What DECSC saved, for DECRC to put back.
    saved: Option<Cursor>,
    dirty: Vec<bool>,
    /// Row moves since the last drain, in the order they happened; see [`Shift`] and
    /// [`Shifts`].
    ///
    /// A log rather than one accumulated move, because a TUI with a `DECSTBM` status area
    /// can scroll two different regions in one drain, and the buffer has to replay them in
    /// order. Consecutive moves of the same rows the same way coalesce, so a thousand-line
    /// `cat` is not a thousand pairs of buffer edits.
    shifts: Shifts,
    /// How many times a row has been marked damaged; see [`Screen::touches`].
    touches: u64,
    tabs: Vec<bool>,
    /// Rows of row 0's logical line that have already left the grid for Emacs.
    ///
    /// [`Row::wrapped`] says a row is continued *below*; nothing on the grid says row 0 is
    /// continued from *above* once those rows have been handed over. Without this, a rewrap
    /// would chunk the leading fragment as though it began a line, and the buffer would show
    /// a row wider than the window.
    ///
    /// Counted in rows because a row that leaves mid-line is exactly `cols` wide
    /// ([`Row::line_runs`] keeps its trailing blanks), so `carried * cols` is the head's
    /// width. The seam fragment [`Logical::take_front`] cuts is narrower, but it exists to
    /// top the head up to whole rows at the new width, so [`Screen::reflow`] restores the
    /// property.
    carried: usize,
    /// The same head in characters of the text Emacs holds, which is what
    /// [`Screen::head`] reports.
    ///
    /// Not `carried * cols`: a wide character is one character on two columns and a
    /// combining mark a character on none, so `日本` handed over as a row of four columns
    /// is two characters in the buffer, and `e\u{301}` on one column is two.
    carried_chars: Chars,
    /// How many more rows leaving the top keep a copy of themselves in [`Departed::row`].
    ///
    /// Set at a drain to as many rows as Emacs holds, and cleared once a row that leaves
    /// is not one of them, so a flood copies a screenful per drain rather than a row per
    /// line.
    witness: usize,
    /// DECAWM, on by default as every terminal starts. See [`Screen::set_autowrap`].
    autowrap: bool,
    /// IRM. See [`Screen::set_insert_mode`].
    insert_mode: bool,
    /// Whether rows leaving the top of this grid are history worth building.
    ///
    /// False for the alternate grid, which contributes no transcript.
    /// [`State::evicted`](super::term) owns the policy of not archiving while the alternate
    /// screen is shown; this only stops the *work* of building departure records nobody
    /// will read. It cannot be folded into [`Screen::archives`], whose full-region test is
    /// as true under `less` as on the primary.
    history: bool,
}

impl Default for Screen {
    /// A 1x1 grid. Only `State::new` ever sees one, and it overwrites both screens with
    /// real sizes immediately; `Screen::new` floors both dimensions at 1 regardless.
    fn default() -> Self {
        Self::new(1, 1)
    }
}

impl Screen {
    /// Both dimensions are floored at 1 here rather than trusting callers. A zero-height
    /// screen has no last row for `CSI r` to default to, and a zero width would panic on
    /// the first character, since `Screen::write` and four other sites subtract one from
    /// `cols`. `lib.rs` clamps what Emacs reports, but this module keeps its own invariant.
    pub fn new(rows: usize, cols: usize) -> Self {
        let rows = rows.max(1);
        let cols = cols.max(1);
        Self {
            cells: vec![Cell::default(); rows * cols],
            meta: vec![RowMeta::default(); rows],
            order: identity(rows),
            cols,
            cursor: Cursor::default(),
            region: Region::full(rows),
            saved: None,
            dirty: vec![true; rows],
            shifts: Shifts::default(),
            touches: 0,
            tabs: default_tabs(cols),
            carried: 0,
            carried_chars: Chars::ZERO,
            witness: 0,
            autowrap: true,
            insert_mode: false,
            history: true,
        }
    }

    /// A grid whose departing rows are not history: the alternate screen.
    ///
    /// A constructor rather than a flag for the caller to clear, because dropping such an
    /// assignment would only waste work, which no test would notice. See
    /// [`Screen::history`].
    pub fn scratch(rows: usize, cols: usize) -> Self {
        Self {
            history: false,
            ..Self::new(rows, cols)
        }
    }

    /// Keep a copy of the next COUNT rows to leave the top; see [`Departed::row`].
    pub fn witness(&mut self, count: usize) {
        self.witness = count;
    }

    /// Drop the carry: nothing of the top row's line is in Emacs any more.
    pub fn forget_carry(&mut self) {
        self.carried = 0;
        self.carried_chars = Chars::ZERO;
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
            self.forget_carry();
            return;
        }
        let run = evicted.iter().rev().take_while(|row| row.wrapped).count();
        let chars: Chars = evicted[evicted.len() - run..]
            .iter()
            .map(Departed::chars)
            .sum();
        if run == evicted.len() {
            self.carried += run;
            self.carried_chars += chars;
        } else {
            self.carried = run;
            self.carried_chars = chars;
        }
    }

    pub fn height(&self) -> usize {
        self.order.len()
    }

    pub fn width(&self) -> usize {
        self.cols
    }

    pub fn row(&self, index: usize) -> Option<RowRef<'_>> {
        let slot = *self.order.get(index)? as usize;
        let start = slot * self.cols;
        Some(RowRef::from_slices(
            &self.cells[start..start + self.cols],
            &self.meta[slot],
        ))
    }

    fn row_mut(&mut self, index: usize) -> Option<RowMut<'_>> {
        let slot = *self.order.get(index)? as usize;
        let start = slot * self.cols;
        Some(RowMut::from_slices(
            &mut self.cells[start..start + self.cols],
            &mut self.meta[slot],
        ))
    }

    pub fn rows(&self) -> impl Iterator<Item = RowRef<'_>> {
        (0..self.height()).filter_map(|index| self.row(index))
    }

    /// Every row, top to bottom, as owned rows, leaving the grid empty -- for a resize,
    /// which lays the rows out again and stores them back with [`Screen::store_rows`].
    fn take_rows(&mut self) -> Vec<Row> {
        let cols = self.cols;
        let order = std::mem::take(&mut self.order);
        let cells = std::mem::take(&mut self.cells);
        let mut meta = std::mem::take(&mut self.meta);
        order
            .iter()
            .map(|&slot| {
                let slot = slot as usize;
                Row::from_meta(
                    cells[slot * cols..(slot + 1) * cols].to_vec(),
                    std::mem::take(&mut meta[slot]),
                )
            })
            .collect()
    }

    /// Store ROWS as the grid, each `cols` wide, in screen order.
    fn store_rows(&mut self, rows: Vec<Row>, cols: usize) {
        self.cols = cols;
        self.order = identity(rows.len());
        self.cells = Vec::with_capacity(rows.len() * cols);
        self.meta = Vec::with_capacity(rows.len());
        for row in rows {
            let (cells, meta) = row.into_parts();
            debug_assert_eq!(cells.len(), cols, "a grid row is exactly the grid's width");
            self.cells.extend_from_slice(&cells);
            self.meta.push(meta);
        }
    }

    /// Put an OSC 133 mark on the cell at (`row`, `col`), if the grid has one.
    ///
    /// Not `touch`: a mark changes nothing about how the row is drawn, so damaging it
    /// would send Emacs a row it already has in order to say something the row does not
    /// carry.
    pub fn mark(&mut self, row: usize, col: Cols, id: MarkId) {
        if let Some(mut row) = self.row_mut(row) {
            row.mark(col, id);
        }
    }

    /// Which row carries the mark named ID, or nothing if no row does any longer.
    ///
    /// The row is the answer rather than the column because the callers ask about lines:
    /// `State::clear_to_prompt` wants the row the prompt begins on, and nothing finer.
    /// Nothing means the marked row has left the grid -- scrolled
    /// into scrollback, removed by `cooked-delete-output`, or blanked by an erase that
    /// ended the row rather than its drawing -- and the caller falls back.
    ///
    /// A walk of the grid, which is what an attachment table per row costs to search. The
    /// callers are user commands, one per keystroke at the very most, and the walk skips a
    /// row with no attachments on a null check.
    pub fn mark_row(&self, id: MarkId) -> Option<usize> {
        (0..self.height()).find(|&index| {
            self.row(index)
                .is_some_and(|row| row.marks().any(|(_, on_row)| on_row == id))
        })
    }

    fn touch(&mut self, index: usize) -> Option<RowMut<'_>> {
        *self.dirty.get_mut(index)? = true;
        self.touches += 1;
        self.row_mut(index)
    }

    /// Hand row INDEX to EDIT, and damage it only if EDIT says it changed something.
    ///
    /// [`Screen::touch`]'s conditional twin. Damage is the unit Emacs pays in -- a damaged
    /// row is deleted, reinserted and re-propertized -- so a full-screen program repainting
    /// an identical frame should cost nothing. The writers ([`Row::set`], [`Row::fill_run`],
    /// [`Row::fill`], [`Row::erase_all`]) report whether the cells they wrote differ, and
    /// this turns that answer into the flag.
    ///
    /// **It is not a general equality check on the row.** There is no copy of the previous
    /// frame; each writer compares only the cells it overwrites. Paths where damage means
    /// something else keep `touch`: [`Screen::touch_all`], because Emacs asked for the screen
    /// back; the row-moving operations, which put new text at an index without writing
    /// cells (the scrolls report the moved rows as a [`Shift`]); [`Screen::clear_rows`], for
    /// the reason [`Row::clear`] gives; the image and attachment writers; and the
    /// combining-mark path.
    ///
    /// Returns whether there was a row at INDEX at all, which is not the same question as
    /// whether anything changed — [`Screen::write_run`] has to tell the two apart to say
    /// how much it placed.
    fn edit(&mut self, index: usize, edit: impl FnOnce(&mut RowMut<'_>) -> bool) -> bool {
        let Some(mut row) = self.row_mut(index) else {
            return false;
        };
        if edit(&mut row) {
            self.damage(index);
        }
        true
    }

    /// Mark row INDEX damaged without touching it, for a caller that has already written.
    fn damage(&mut self, index: usize) {
        if let Some(dirty) = self.dirty.get_mut(index) {
            *dirty = true;
        }
        self.touches += 1;
    }

    /// Mark every row in an inclusive range damaged.
    ///
    /// A slice fill rather than a loop of `dirty.get_mut(i)`: `scroll_up` calls this on
    /// every scrolled line, and clamping once lets it be a memset.
    fn touch_range(&mut self, range: std::ops::RangeInclusive<usize>) {
        let (first, last) = range.into_inner();
        let end = (last + 1).min(self.dirty.len());
        if let Some(span) = self.dirty.get_mut(first..end) {
            span.fill(true);
            self.touches += 1;
        }
    }

    pub fn touch_all(&mut self) {
        self.dirty.fill(true);
        self.touches += 1;
        // Every row is about to be sent whole, so pending shifts can go -- and must, after
        // a resize, since a shift naming a `bottom` the grid no longer has cannot be
        // applied.
        self.shifts.forget();
    }

    /// The move the drain window opened with, as far as the log can say; see
    /// [`Shifts::leading_scroll`].
    pub fn leading_scroll(&self) -> Option<Shift> {
        self.shifts.leading_scroll()
    }

    /// How many rows the moves since the last drain have taken off the top of the screen;
    /// see [`Shifts::scrolled_off`].
    ///
    /// Only when they are one scroll from the top row are the rows handed to scrollback
    /// the rows the screen held at its top, in order, with nothing else moved, so a row
    /// leaving can be matched against what Emacs holds; see `Front::promote`. Saturates at
    /// the region's height, as the log does.
    pub fn scrolled_off(&self) -> Option<usize> {
        self.shifts.scrolled_off()
    }

    /// Row moves since the last drain, taken with the damage they go with.
    ///
    /// Ordered, and Lisp must apply them in this order and *before* it renders the
    /// damaged rows: the damage indices are in post-shift coordinates, because the dirty
    /// flags travel with their rows through every move (see [`Screen::scroll_up`]).
    pub fn drain_shifts(&mut self) -> Vec<Shift> {
        self.shifts.take()
    }

    /// Record that `n` rows moved within `top..=bottom`, marking the right amount of the
    /// screen damaged for what [`Shifts::record`] did with it, and returning whether the
    /// entry survives as a shift the caller may still touch only the recycled rows for.
    ///
    /// The whole-screen fill on a fresh drop belongs here rather than in [`Shifts::record`]:
    /// `dirty` and `touches` are this screen's, not the log's, and [`Shifts`] has no reason
    /// to know either exists.
    fn shift(&mut self, top: usize, bottom: usize, n: usize, direction: Direction) -> bool {
        match self.shifts.record(top, bottom, n, direction, self.height()) {
            Recorded::Kept => true,
            Recorded::Saturated | Recorded::Redundant => false,
            Recorded::JustDropped => {
                self.dirty.fill(true);
                self.touches += 1;
                false
            }
        }
    }

    /// Every cell of the grid, slots in storage order rather than screen order, for a walk
    /// that only needs to see each cell once -- collecting rendition ids no cell names.
    pub(crate) fn all_cells(&self) -> &[Cell] {
        &self.cells
    }

    /// How many times a row has been marked damaged over this screen's life.
    ///
    /// The question [`Screen::drain_damage`] answers, asked without the answer being
    /// destructive and by a caller who only wants to know whether anything happened --
    /// see `Term::feed`, which compares two readings of it.
    ///
    /// A running count rather than "is any row dirty": damage stays up until Emacs drains,
    /// so for a program repainting flat out the flag would say `true` on both sides of a
    /// read and the read would look like it did nothing.
    pub fn touches(&self) -> u64 {
        self.touches
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

    /// Print one character at the width a width table gives it.
    ///
    /// The unsegmented form, for callers with one character and no stream around it: `REP`
    /// and the tests. Ordinary printing goes through [`Screen::place`] and [`Screen::join`]
    /// with a width the [`Segmenter`](crate::emu::text::Segmenter) measured, because width
    /// belongs to a grapheme cluster rather than a code point.
    pub fn write(&mut self, ch: char, pen: Pen) -> Evicted {
        match crate::emu::text::char_cells(ch) {
            Cols::ZERO => {
                self.join(ch, Cols::ZERO, Cols::ZERO);
                Evicted::none()
            }
            width => self.place(ch, width, pen),
        }
    }

    /// Attach MARK to the cell the cursor last wrote, and resize that cell if the mark
    /// changed how wide it is.
    ///
    /// BEFORE is how many columns that cell stood on, which is what locates it: the
    /// cursor has moved past it by exactly that much, or is pinned at the last column
    /// with a deferred wrap armed, in which case the cell ends at the right edge. The lead
    /// cell and not its continuation, because a mark on a continuation cell is one
    /// [`Row::runs`] skips. A BEFORE of zero means there was no such cell (a combining
    /// mark first thing on a row), and the mark folds onto the cell to the left.
    ///
    /// AFTER differs from BEFORE only for a variation selector -- `U+FE0F` promoting a
    /// character to a two-column emoji, `U+FE0E` demoting it. A widening at the right edge
    /// has nowhere to go and is declined rather than wrapped, since moving a character
    /// already drawn to the next row would be worse than being a column narrow.
    ///
    /// Returns the columns the cell ended up standing on, which is AFTER unless the
    /// widening was declined. The caller records it, because from then on it is that
    /// number and not the measurement that says where the cell begins.
    pub fn join(&mut self, mark: char, before: Cols, after: Cols) -> Cols {
        let (row, cols) = (self.cursor.row, self.cols);
        let (before, after) = (before.get(), after.get());
        let lead = if self.cursor.wrap_pending {
            cols.saturating_sub(before.max(1))
        } else {
            self.cursor.col.saturating_sub(before.max(1))
        };
        if let Some(mut r) = self.touch(row) {
            r.combine(lead, mark);
        }
        // Nothing to resize: the overwhelming case, since almost every mark that joins a
        // cell leaves its width alone.
        if after == before || before == 0 {
            return Cols::new(before);
        }
        if after > before && lead + after > cols {
            return Cols::new(before);
        }
        // The resized columns take the lead cell's own rendition and link, so a widened
        // emoji does not leave a differently-coloured half behind it.
        let lead_cell = self
            .row(row)
            .and_then(|r| r.get(lead).copied())
            .unwrap_or_default();
        let cell = if after > before {
            lead_cell.with_char(CONTINUATION)
        } else {
            Cell::blank(lead_cell.style())
        };
        self.edit(row, |r| {
            // A widening writes continuations over the columns after the cell, and the
            // character standing there may be wide itself.
            let mut changed = after > before && r.clear_torn(lead + before, lead + after);
            for col in lead + after.min(before)..lead + after.max(before) {
                changed |= r.set(col, cell);
            }
            changed
        });
        // The cursor follows the cell's new right edge, on exactly [`Screen::place`]'s
        // terms — including re-deciding the deferred wrap, which a narrowing has to
        // disarm: the cell no longer reaches the edge, so the next character does not
        // wrap.
        self.settle_cursor(lead + after);
        Cols::new(after)
    }

    /// Place one character standing on WIDTH columns, whatever a width table would say.
    ///
    /// The width is a parameter rather than a lookup because the two callers know
    /// something this cannot: the segmenter has measured a whole grapheme cluster, and
    /// `OSC 66` carries a width the *child* declared. Everything else here — the
    /// deferred wrap, DECAWM, the scroll a wrap can trigger, the continuation cells, the
    /// insert-mode shift — is unchanged and is the only copy of it.
    pub fn place(&mut self, ch: char, width: Cols, pen: Pen) -> Evicted {
        let (cols, width) = (self.cols, width.get());
        // Read before `touch` borrows `self` mutably below.
        let insert_mode = self.insert_mode;
        let mut evicted = Evicted::none();
        // The margin decision, made once. Both new modes live inside the branch that was
        // already taken only at the edge of a row, so the common path is untouched.
        if self.cursor.wrap_pending || self.cursor.col + width > cols {
            if self.autowrap {
                // Only damage if the flag was not already up. Where the line ends is
                // something Emacs renders from, so setting it is a change -- setting it
                // twice is not, and a program parked at the last column reaches here
                // again on every character it prints there.
                self.edit(self.cursor.row, |r| !r.set_wrapped(true));
                self.cursor.col = 0;
                evicted = self.linefeed(pen);
            } else {
                // DECAWM off: the cursor never leaves the row. Back up far enough that a
                // wide character lands whole rather than half over the edge.
                self.cursor.col = cols.saturating_sub(width);
            }
        }

        let (row, col) = (self.cursor.row, self.cursor.col);
        // One `touch` for both edits, so insert mode does not pay for the damage flag and
        // row lookup twice on the hottest call in the emulator.
        self.edit(row, |r| {
            // `|=` and not `||`: every write has to happen, so none of these may be
            // short-circuited away by an earlier one having already reported damage.
            let mut changed = false;
            if insert_mode {
                // IRM shifts the rest of the row right by the character's full width, so a
                // wide character does not tear the cell it displaces. Unconditional damage:
                // the shift moves every cell from `col` on, so what a comparison at `col`
                // would say is not the question.
                r.insert_blank(col, width, pen.erase);
                changed = true;
            }
            changed |= r.clear_torn(col, col + width);
            changed |= r.set(col, pen.cell(ch));
            for offset in 1..width {
                changed |= r.set(col + offset, pen.cell(CONTINUATION));
            }
            changed
        });

        self.settle_cursor(col + width);
        evicted
    }

    /// Leave the cursor at column END, or pinned at the last column with the deferred
    /// wrap armed if END is off the row.
    ///
    /// One copy for the three writers that finish a character -- the ordinary print, a
    /// variation selector resizing its cell, and an `OSC 66` block -- because the deferred
    /// wrap is the subtlest thing in this file and `OSC 66` clients detect support by
    /// reading the cursor back.
    fn settle_cursor(&mut self, end: usize) {
        if end >= self.cols {
            self.cursor.col = self.cols - 1;
            // Only arm the deferred wrap when there is a wrap to defer.
            self.cursor.wrap_pending = self.autowrap;
        } else {
            self.cursor.col = end;
            self.cursor.wrap_pending = false;
        }
    }

    /// Draw one grapheme cluster as a single block of WIDTH columns.
    ///
    /// [`Screen::place`] for the cluster's first code point, then everything after it
    /// attached to that same cell — which is what makes the block one thing the grid can
    /// overwrite, wrap and hand to Emacs whole. `OSC 66 w=N` is the caller that matters:
    /// there, WIDTH is the child's declaration and may disagree with any width table,
    /// and TEXT need not be a single cluster at all — the spec has all the text in one
    /// escape rendered in `s * w` cells, so `w=1` with `Ha` is two characters sharing
    /// one column, on purpose.
    ///
    /// A WIDTH of zero folds the whole thing onto the cell before, which is the honest
    /// reading of a cluster that begins with a combining mark.
    pub fn write_cluster(&mut self, text: &str, width: Cols, pen: Pen) -> Evicted {
        let mut chars = text.chars();
        let Some(base) = chars.next() else {
            return Evicted::none();
        };
        let evicted = if width.is_zero() {
            self.join(base, Cols::ZERO, Cols::ZERO);
            Evicted::none()
        } else {
            self.place(base, width, pen)
        };
        for mark in chars {
            // `width` and not the measurement: `join` locates the cell by how wide it
            // is, and after a declared width that is what the child said, not what
            // `unicode-width` would say about the character sitting in it.
            self.join(mark, width, width);
        }
        evicted
    }

    /// Place a run of one-column characters from the cursor, without leaving the row.
    ///
    /// Returns how many were placed, which may be fewer than offered and may be zero; the
    /// caller writes whatever is left through [`Screen::write`], one character at a time.
    /// Everything hard about placing a character -- the deferred wrap, DECAWM, scrolling,
    /// wide characters, combining marks -- stays in `write`, in one copy. This handles only
    /// the case where none of it applies, which is nearly all output.
    ///
    /// **The last column is left alone**, because that is where `write` decides whether to
    /// arm the deferred wrap, and a second copy of that decision could drift.
    ///
    /// Insert mode and a pending wrap both bail out entirely rather than being handled:
    /// IRM shifts the row per character, and a pending wrap means the next character
    /// scrolls.
    pub fn write_run(&mut self, text: &str, pen: Pen) -> usize {
        if self.insert_mode || self.cursor.wrap_pending {
            return 0;
        }
        let (row, col) = (self.cursor.row, self.cursor.col);
        let room = self.cols.saturating_sub(col + 1);
        let n = text.len().min(room);
        if n == 0 {
            return 0;
        }
        if !self.edit(row, |r| r.fill_run(col, &text[..n], pen)) {
            return 0;
        }
        self.cursor.col = col + n;
        n
    }

    pub fn autowrap(&self) -> bool {
        self.autowrap
    }

    pub fn insert_mode(&self) -> bool {
        self.insert_mode
    }

    pub fn cursor(&self) -> Cursor {
        self.cursor
    }

    /// The scroll region DECSTBM set, inclusive at both ends.
    pub fn region(&self) -> Region {
        self.region
    }

    /// Put the cursor back exactly as CURSOR describes it, clamped to the grid.
    ///
    /// For a caller that took [`Screen::cursor`] and has since moved it, such as a kitty
    /// placement with `C=1`. The pending wrap survives only where it can mean something,
    /// on the last column.
    pub fn put_cursor(&mut self, cursor: Cursor) {
        let wrap_pending = cursor.wrap_pending;
        self.goto(cursor.row, cursor.col);
        self.cursor.wrap_pending = wrap_pending && self.cursor.col + 1 == self.cols;
    }

    /// DECSC's half of the cursor: remember where it is.
    pub fn save_cursor(&mut self) {
        self.saved = Some(self.cursor);
    }

    /// DECRC's half: go back to the saved position, or home if nothing was saved.
    ///
    /// The save is kept, so a second DECRC goes back to the same place, and a DECRC with
    /// no save behind it homes the cursor. Both are xterm's reading, which restores from a
    /// saved-cursor record that starts out zeroed and that nothing but DECSTR clears.
    pub fn restore_cursor(&mut self) {
        let saved = self.saved.unwrap_or_default();
        self.goto(saved.row, saved.col);
    }

    /// Whether DECSC has saved a position on this screen since DECSTR.
    pub fn has_saved_cursor(&self) -> bool {
        self.saved.is_some()
    }

    /// DECSTR and RIS: nothing is saved any more.
    pub fn forget_saved_cursor(&mut self) {
        self.saved = None;
    }

    pub fn carriage_return(&mut self) {
        self.cursor.col = 0;
        self.cursor.wrap_pending = false;
    }

    /// Lay one row of image ID across the grid from the cursor, and say how wide it got.
    ///
    /// Clipped to the screen rather than wrapped: an image is a rectangle, and a row of
    /// it that continued on the next line would not be one. The caller moves down.
    ///
    /// CELLS is the whole rectangle, not just this row's width: every cell records it,
    /// because the rectangle is the placement's and not the image's. See [`Placement`].
    /// The clipping above is why it cannot be recovered from the cells themselves --
    /// a picture laid at the right edge writes fewer columns than it was laid at, and
    /// Emacs still has to cut its slices against the full width.
    pub fn place_image_row(
        &mut self,
        id: ImageId,
        cell_row: u16,
        cells: CellSize,
        style: StyleId,
    ) -> u16 {
        let (row, start) = (self.cursor.row, self.cursor.col);
        let width = usize::from(cells.cols).min(self.cols.saturating_sub(start));
        if let Some(mut r) = self.touch(row) {
            for i in 0..width {
                r.place(
                    start + i,
                    Placement {
                        id,
                        cell_row,
                        cell_col: i as u16,
                        cols: cells.cols,
                        rows: cells.rows,
                    },
                    style,
                );
            }
        }
        width as u16
    }

    /// LF/IND: down one, scrolling the region if already at its bottom.
    pub fn linefeed(&mut self, pen: Pen) -> Evicted {
        self.cursor.wrap_pending = false;
        match self.cursor.row {
            row if row == self.region.bottom => self.scroll_up(1, pen),
            row if row + 1 < self.height() => {
                self.cursor.row = row + 1;
                Evicted::none()
            }
            _ => Evicted::none(),
        }
    }

    /// RI: up one, scrolling the region down if already at its top.
    pub fn reverse_index(&mut self, pen: Pen) {
        self.cursor.wrap_pending = false;
        match self.cursor.row {
            row if row == self.region.top => self.scroll_down(1, pen),
            0 => {}
            row => self.cursor.row = row - 1,
        }
    }

    /// True when the scroll region is the whole screen, which is when a clear or a rewrap
    /// may hand the whole screen to history. A scroll asks less; see
    /// [`Screen::scroll_up`].
    fn archives(&self) -> bool {
        self.history && self.region == Region::full(self.height())
    }

    /// Shift the region up by `n`, returning rows that became scrollback.
    pub fn scroll_up(&mut self, n: usize, pen: Pen) -> Evicted {
        let Region { top, bottom } = self.region;
        let n = n.min(self.region.height());
        if n == 0 {
            return Evicted::none();
        }
        // Rows leaving a region that starts at the top of the screen are history, whatever
        // the region leaves fixed below it, as in vte. That is tmux under `smcup@` with a
        // status line on the bottom row: its pane is rows 1 to 23, and `self.archives()`
        // would have discarded every line the pane scrolled.
        //
        // Reduced here, from the rows still in place, so no row is cloned across the
        // rotation below. `Screen::write` marks the row above `wrapped` before calling
        // `linefeed`, so the flag `line_runs` reads is already settled.
        let evicted = if self.history && top == 0 {
            let witnessed = std::mem::take(&mut self.witness);
            self.witness = witnessed.saturating_sub(n);
            let mut evicted =
                Evicted::from_rows((top..top + n).filter_map(|index| self.row(index)));
            for (index, departed) in evicted.0.iter_mut().take(witnessed).enumerate() {
                departed.row = self.row(top + index).map(|row| {
                    Box::new(Row::from_parts(
                        row.cells().to_vec(),
                        row.extras().to_vec(),
                        row.wrapped(),
                    ))
                });
            }
            evicted
        } else {
            Evicted::none()
        };
        self.order[top..=bottom].rotate_left(n);
        // The dirty flags rotate with their rows, so the damage reported is in post-shift
        // coordinates; otherwise a row written before the scroll would be repainted at the
        // index it used to have.
        self.dirty[top..=bottom].rotate_left(n);
        self.clear_recycled(bottom + 1 - n..=bottom, pen);
        // The rows above the recycled ones hold the text they already held at another
        // index, which Emacs can move cheaply while keeping its markers and overlays; only
        // the blanks rotated in are new. The `else` is the region having turned over
        // completely; see [`Screen::shift`].
        if self.shift(top, bottom, n, Direction::Up) {
            self.touch_range(bottom + 1 - n..=bottom);
        } else {
            self.touch_range(top..=bottom);
        }
        self.unwrap_above(top);
        self.carry(&evicted);
        evicted
    }

    /// End the line of the row above TOP, whose continuation a scroll of the region
    /// starting at TOP has just moved away.
    ///
    /// A row's wrap flag says its line goes on in the row below, and a region scroll or
    /// an `IL`/`DL` at TOP puts a different row there: `abcdefghij` wrapped over two
    /// rows, then `DL` on the second, leaves `abcde` joined to whatever came up from
    /// below, in the buffer, in a URL scanned across the wrap, and in the next rewrap.
    /// Row 0 has no row above it, and what continues into it is the carry's business.
    fn unwrap_above(&mut self, top: usize) {
        if let Some(above) = top.checked_sub(1) {
            self.edit(above, |r| r.set_wrapped(false));
        }
    }

    /// End the line of row INDEX, whose continuation below it an `IL` or `DL` has taken.
    fn unwrap(&mut self, index: usize) {
        self.edit(index, |r| r.set_wrapped(false));
    }

    /// Remove `count` rows starting at `first`, closing the gap from below.
    ///
    /// Not a scroll: the rows are discarded rather than archived, because the caller is
    /// deleting a finished command's output and archiving it would put it straight back
    /// into the buffer as scrollback. Rows below shift up, blanks come in at the bottom,
    /// and the whole affected span is marked damaged so the next drain repaints it.
    ///
    /// Rows have one owner, so Emacs asks rather than deleting buffer text the grid still
    /// holds.
    ///
    /// Removing from the very top clears [`Screen::carried`]: once row 0 is gone, the new
    /// top row continues nothing.
    ///
    /// The scroll region is left alone. The row count is unchanged, so its bounds stay
    /// valid, and resetting it would clear a child's `DECSTBM` as a side effect.
    pub fn remove_rows(&mut self, first: usize, count: usize) {
        let height = self.height();
        let first = first.min(height);
        let count = count.min(height - first);
        if count == 0 {
            return;
        }
        // No [`Shift`] and no rotation of the dirty flags, unlike the scrolls: every row
        // from `first` down is damaged unconditionally below, so there is nothing to keep
        // correct by moving. A shift logged earlier in the drain is still right to apply.
        // The removed rows' slots go to the bottom and are blanked there, which is the
        // same grid as removing them and appending blanks.
        self.order[first..].rotate_left(count);
        self.clear_recycled(height - count..=height - 1, Pen::default());
        if first == 0 {
            self.forget_carry();
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

    pub fn scroll_down(&mut self, n: usize, pen: Pen) {
        let Region { top, bottom } = self.region;
        let n = n.min(self.region.height());
        if n == 0 {
            return;
        }
        self.order[top..=bottom].rotate_right(n);
        // With the rows, for the reason spelled out in `scroll_up`.
        self.dirty[top..=bottom].rotate_right(n);
        self.clear_recycled(top..=top + n - 1, pen);
        if self.shift(top, bottom, n, Direction::Down) {
            self.touch_range(top..=top + n - 1);
        } else {
            self.touch_range(top..=bottom);
        }
        self.unwrap_above(top);
        // The row pushed down to the bottom of the region went on in a row that has
        // fallen off it. Not so for `scroll_up`, whose bottom row is followed by the blank
        // a wrapping linefeed is about to write the continuation into.
        self.unwrap(bottom);
    }

    pub fn set_region(&mut self, top: usize, bottom: usize) {
        let bottom = bottom.min(self.height().saturating_sub(1));
        if top < bottom {
            self.region = Region { top, bottom };
            self.goto(0, 0);
        }
    }

    pub fn reset_region(&mut self) {
        self.region = Region::full(self.height());
    }

    /// Absolute positioning, clamped to the screen.
    pub fn goto(&mut self, row: usize, col: usize) {
        self.cursor.row = row.min(self.height().saturating_sub(1));
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

    pub fn erase_line(&mut self, how: Erase, pen: Pen) {
        let (col, cols) = (self.cursor.col, self.cols);
        let row = self.cursor.row;
        let style = pen.erase;
        self.edit(row, |r| match how {
            Erase::ToEnd => r.fill(col..cols, style),
            Erase::ToStart => r.fill(0..col.min(cols - 1) + 1, style),
            // The one whole-row erase that keeps semantic marks: see `Row::erase_all`.
            Erase::All => r.erase_all(style),
        });
    }

    /// Erase, returning rows that became scrollback.
    ///
    /// Only `All` yields any, and only off an unpartitioned screen. Clearing the display is
    /// the child finishing with a screen -- `clear` and the shell's `C-l` both arrive here --
    /// and history belongs to Emacs, so the rows are archived rather than blanked away.
    ///
    /// A partial erase archives nothing: the child is rewriting part of a screen it is
    /// still drawing on, not finishing with one.
    pub fn erase_display(&mut self, how: Erase, pen: Pen) -> Evicted {
        let (row, last) = (self.cursor.row, self.height());
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
                let history = if self.archives() && self.rows().any(|row| row.has_text()) {
                    let used = self.last_used_row();
                    let mut history = Evicted::from_rows(self.rows().take(used + 1));
                    // The last row archived ends its line, whatever its wrap flag says. The
                    // flag can point at a row with nothing on it: `CSI 2K` on the
                    // continuation blanks it and leaves the row above wrapped, and the blank
                    // is not archived. Handed over as wrapped, the row would reach the buffer with
                    // no newline, leaving the new row 0 appended to it while the carry
                    // below says row 0 begins a line.
                    if let (Some(last), Some(row)) = (history.0.last_mut(), self.row(used))
                        && last.wrapped
                    {
                        last.wrapped = false;
                        last.runs = row.runs();
                    }
                    // Whatever was on screen has gone to history whole, so the next row 0
                    // starts a line rather than continuing one.
                    self.forget_carry();
                    history
                } else {
                    // Nothing went to history, so the head of row 0's line is still in the
                    // buffer just above the screen, and the blank row 0 still follows it
                    // there: a scroll region is set, or the rows that continued a wrapped
                    // line scrolled away hold no text.
                    Evicted::none()
                };
                self.clear_rows(0..last, pen);
                history
            }
        }
    }

    /// Unconditionally damaged, unlike the other erase paths: see [`Row::clear`] for why
    /// it does not answer the question [`Screen::edit`] would ask it.
    fn clear_rows(&mut self, range: std::ops::Range<usize>, pen: Pen) {
        let style = pen.erase;
        for i in range {
            if let Some(mut r) = self.touch(i) {
                r.clear(style);
            }
        }
    }

    /// Blank the rows in RANGE for reuse, without damaging them: a scroll that recycles
    /// rows damages them itself, with the shift it reports.
    fn clear_recycled(&mut self, range: std::ops::RangeInclusive<usize>, pen: Pen) {
        let style = pen.erase;
        for index in range {
            if let Some(mut row) = self.row_mut(index) {
                row.clear(style);
            }
        }
    }

    pub fn erase_chars(&mut self, n: usize, pen: Pen) {
        let (row, col, cols) = (self.cursor.row, self.cursor.col, self.cols);
        let style = pen.erase;
        self.edit(row, |r| r.fill(col..(col + n).min(cols), style));
    }

    pub fn insert_chars(&mut self, n: usize, pen: Pen) {
        let (row, col) = (self.cursor.row, self.cursor.col);
        if let Some(mut r) = self.touch(row) {
            r.insert_blank(col, n, pen.erase);
        }
    }

    pub fn delete_chars(&mut self, n: usize, pen: Pen) {
        let (row, col) = (self.cursor.row, self.cursor.col);
        if let Some(mut r) = self.touch(row) {
            r.delete(col, n, pen.erase);
        }
    }

    /// IL/DL operate on a temporary region starting at the cursor row. Lines deleted this
    /// way are destroyed, never archived.
    pub fn insert_lines(&mut self, n: usize, pen: Pen) {
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

    pub fn delete_lines(&mut self, n: usize, pen: Pen) {
        if !self.region.contains(self.cursor.row) {
            return;
        }
        let saved = self.region;
        self.region = Region {
            top: self.cursor.row,
            bottom: saved.bottom,
        };
        // Deleting at row 0 looks to `scroll_up` like rows leaving the top, but these are
        // discarded, so what Emacs holds has not changed and the carry must not advance.
        let carried = (self.carried, self.carried_chars);
        self.scroll_up(n, pen).discard();
        (self.carried, self.carried_chars) = carried;
        // What was the bottom row of the region now has blanks below it, where a wrapping
        // linefeed's scroll would have left the blank its continuation goes into.
        let moved = saved.bottom + 1 - n.min(saved.bottom + 1 - self.cursor.row);
        if moved > self.cursor.row {
            self.unwrap(moved - 1);
        }
        self.region = saved;
    }

    /// HT/CHT: forward `count` tab stops, pinned at the last column.
    ///
    /// `count` is clamped to the width, as REP is clamped to the screen: the parameter is a
    /// `u16` off the wire, and every iteration past `cols` is a no-op. Unclamped, `CSI 65535
    /// I` took a 24x200 grid from 45.8 MB/s to 0.29 MB/s -- a denial of service in five
    /// bytes.
    pub fn tab(&mut self, count: usize) {
        let count = count.min(self.cols);
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
    ///
    /// Clamped to the width exactly as [`Screen::tab`] is, and for the same reason read
    /// in the other direction: the cursor cannot move left of column 0, so a count past
    /// `cols` is asking for work whose answer is already settled.
    pub fn back_tab(&mut self, count: usize) {
        let count = count.min(self.cols);
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

    /// TBC 0: clear the stop at the cursor's column.
    pub fn clear_tab(&mut self) {
        if let Some(stop) = self.tabs.get_mut(self.cursor.col) {
            *stop = false;
        }
    }

    /// TBC 3: clear every stop.
    pub fn clear_all_tabs(&mut self) {
        self.tabs.fill(false);
    }

    /// DECST8C: back to a stop every eighth column, the table a screen powers on with.
    pub fn reset_tabs(&mut self) {
        self.tabs = default_tabs(self.cols);
    }

    /// DECALN: the margins reset, the cursor home and every cell an `E`.
    ///
    /// The alignment pattern vttest draws against. The caller erases the display first,
    /// through the `CSI 2J` path, so a primary screen's contents go to history. The cells
    /// go down in the default rendition whatever the pen holds, as in xterm.
    pub fn align(&mut self) {
        let pattern = "E".repeat(self.cols);
        for i in 0..self.height() {
            self.edit(i, |row| row.fill_run(0, &pattern, Pen::default()));
        }
        self.reset_region();
        self.goto(0, 0);
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
        (0..self.height())
            .rev()
            .find(|&index| self.row(index).is_some_and(|row| row.has_text()))
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
    pub fn head(&self) -> Chars {
        self.carried_chars
    }

    /// Resize, returning rows that became scrollback.
    ///
    /// Shrinking absorbs the blank rows below the content first. Evicting from the top
    /// instead would push the visible prompt into scrollback while keeping the empty rows
    /// under it.
    ///
    /// A width change under [`Resize::Rewrap`] re-lays the grid out instead of cutting it;
    /// see [`Screen::reflow`]. Not when a scroll region is set: the rows either side of the
    /// margins belong to different drawings, so there are no logical lines spanning the
    /// screen to recover, and `archives` already names exactly that condition.
    pub fn resize(&mut self, rows: usize, cols: usize, mode: Resize) -> Evicted {
        // Same floors as `Screen::new`, for the same reasons: a zero-height screen has no
        // last row for `CSI r`'s default to fall back on, and a zero-width one panics on
        // the first character printed to it.
        let rows = rows.max(1);
        let cols = cols.max(1);
        if mode == Resize::Rewrap && cols != self.cols && self.archives() {
            return self.reflow(rows, cols);
        }

        // Laid out as owned rows and stored back: a resize is rare, and every row may
        // change width, so there is nothing to gain from editing the flat buffer in place.
        let keep = self.used();
        let mut grid = self.take_rows();
        if cols != self.cols {
            self.tabs = default_tabs(cols);
            for row in &mut grid {
                row.resize(cols, StyleId::DEFAULT);
            }
        }

        let shed: Vec<Row> = match rows.cmp(&grid.len()) {
            std::cmp::Ordering::Less => {
                let excess = grid.len() - rows;
                let spare = grid.len().saturating_sub(keep).min(excess);
                grid.truncate(grid.len() - spare);
                grid.drain(..excess - spare).collect()
            }
            std::cmp::Ordering::Greater => {
                grid.resize(rows, Row::new(cols));
                Vec::new()
            }
            std::cmp::Ordering::Equal => Vec::new(),
        };
        self.store_rows(grid, cols);
        let evicted = Evicted::from_rows(shed.iter().map(Row::as_ref));

        self.carry(&evicted);
        self.cursor.row = self
            .cursor
            .row
            .saturating_sub(evicted.len())
            .min(rows.saturating_sub(1));
        self.cursor.col = self.cursor.col.min(cols.saturating_sub(1));
        self.dirty = vec![true; rows];
        // Every row is damaged, and the row count has just changed under any pending
        // shift's indices; see `Screen::touch_all`, which drops the log for the same
        // two reasons.
        self.shifts.forget();
        self.reset_region();
        evicted
    }

    /// Rewrap the grid to `rows` by `cols`, returning rows pushed off the top as history.
    ///
    /// The live grid is transcript Emacs has not been given yet, so truncating it would
    /// destroy text: run `ps`, narrow the frame, and the columns past the edge are gone.
    /// `Row::wrapped` is enough to recover the lines the child printed and chunk them again,
    /// so narrowing and widening back returns the original layout, as scrollback already
    /// does.
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
        for (index, row) in self.rows().take(keep).enumerate() {
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
            continuing = row.wrapped();
        }

        // Re-align the seam. The head occupies whole visual rows at the old width but
        // seldom at the new one, and the cells completing its last row belong to the
        // buffer rather than the grid: left here they would start row 0 partway along a
        // visual row, putting every hard break below it in the wrong column.
        let mut history = Vec::new();
        if head % cols != 0 && !lines.is_empty() {
            let split = (cols - head % cols).min(lines[0].cells.len());
            let ends_here = split == lines[0].cells.len();
            let fragment = Departed::from_row(lines[0].take_front(split, !ends_here).as_ref());
            self.carried_chars += fragment.chars();
            history.push(fragment);
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
                self.carried_chars = Chars::ZERO;
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
        let evicted = Evicted::from_rows(evicted.iter().map(Row::as_ref));
        self.carry(&evicted);
        history.extend(evicted);

        self.store_rows(grid, cols);
        self.tabs = default_tabs(cols);
        self.cursor = Cursor {
            row: cursor
                .row
                .saturating_sub(overflow)
                .min(rows.saturating_sub(1)),
            ..cursor
        };
        self.dirty = vec![true; rows];
        // Every row is damaged, and the row count has just changed under any pending
        // shift's indices; see `Screen::touch_all`, which drops the log for the same
        // two reasons.
        self.shifts.forget();
        self.reset_region();
        Evicted(history)
    }

    /// Text of the current line up to the cursor — the password prompt lives here.
    pub fn line_text(&self, row: usize) -> Option<String> {
        self.row(row).map(|row| row.to_text())
    }

    pub fn last_nonblank_text(&self) -> Option<String> {
        (0..=self.cursor.row)
            .rev()
            .filter_map(|i| self.row(i))
            .map(|row| row.to_text())
            .find(|t| !t.trim().is_empty())
    }
}

/// The order a freshly laid-out grid shows its slots in: slot N at row N.
fn identity(rows: usize) -> Vec<u32> {
    (0..rows as u32).collect()
}

fn default_tabs(cols: usize) -> Vec<bool> {
    (0..cols).map(|i| i % 8 == 0 && i != 0).collect()
}

/// Where an offset into a chunked logical line lands: row within the chunks, column, and
/// whether the cursor is holding a deferred wrap there.
///
/// The offset can fall past every chunk, because the cursor is free to sit past the end of
/// its line's text — on a blank row, or in the gap a `goto` left — and a gap is not
/// content: chunking it into rows of its own would turn blanks nobody wrote into a wrapped
/// line. So it is clamped onto the last column of the last chunk instead, which is the
/// nearest cell the line still has and the same resolution [`Logical::chunk`] reaches for
/// a mark in that position. The child redraws on `SIGWINCH` anyway.
fn place(offset: usize, cols: usize, chunks: usize) -> (usize, usize, bool) {
    let last = chunks.saturating_sub(1);
    match (offset / cols, offset % cols) {
        // Exactly at the end of the last chunk. Rather than invent a row below it, express
        // it as `Screen::write` does: parked on the last column with the wrap deferred.
        (row, 0) if row > 0 && row == chunks => (row - 1, cols - 1, true),
        // Past it: clamped, and without the deferred wrap, which is a claim about what the
        // next character does rather than about where the cursor is.
        (row, _) if row > last => (last, cols - 1, false),
        (row, col) => (row, col, false),
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
    fn push_row(&mut self, row: RowRef<'_>) -> usize {
        let base = self.cells.len();
        let len = if row.wrapped() {
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
            .extend(row.marks().map(|(at, id)| (base + at.get(), id)));
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
                last.mark(Cols::new(end), *id);
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
        // screen for a character that fits nowhere, and the attachments must not index
        // past the row's own cells.
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
            screen.write(ch, Pen::default()).discard();
        }
    }

    /// A scroll moves rows by reordering slots, never by copying cells.
    ///
    /// The rows that survive a scroll inside a region keep their bytes exactly where they
    /// were in the flat buffer; only the slot recycled at the bottom is rewritten. This is
    /// the property that keeps a 400-column region scroll as cheap as a 40-column one.
    #[test]
    fn a_region_scroll_reorders_slots_and_moves_no_cells() {
        let mut screen = Screen::new(6, 40);
        for (row, text) in ["top", "one", "two", "three", "four", "bottom"]
            .iter()
            .enumerate()
        {
            screen.goto(row, 0);
            write(&mut screen, text);
        }
        screen.set_region(1, 4);
        let before = screen.cells.clone();
        let recycled = screen.order[1] as usize;
        screen.scroll_up(1, Pen::default()).discard();

        let texts: Vec<String> = screen.rows().map(|row| row.to_text()).collect();
        assert_eq!(texts, ["top", "two", "three", "four", "", "bottom"]);
        for slot in (0..6).filter(|&slot| slot != recycled) {
            let span = slot * 40..(slot + 1) * 40;
            assert_eq!(
                Cell::bytes(&screen.cells[span.clone()]),
                Cell::bytes(&before[span]),
                "slot {slot} was rewritten"
            );
        }
        assert_eq!(screen.order, [0, 2, 3, 4, 1, 5]);
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
        screen.linefeed(Pen::default()).discard();
        write(&mut screen, "bb");
        let evicted = screen.linefeed(Pen::default());

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
        screen.scroll_up(1, Pen::default()).discard();
        assert_ne!(
            screen.head(),
            Chars::ZERO,
            "precondition: something was carried"
        );

        screen.remove_rows(0, 1);
        assert_eq!(screen.head(), Chars::ZERO);
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
        let evicted = screen.linefeed(Pen::default());

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
        screen.erase_line(Erase::ToEnd, Pen::default());
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
    fn a_tab_count_costs_no_more_than_the_screen_is_wide() {
        // `usize::MAX` rather than the 65535 a `u16` parameter can carry: the point is
        // that the fold is bounded by the grid and not by what was asked for, and an
        // unclamped fold would not finish this test in the lifetime of the machine.
        let mut screen = Screen::new(2, 24);
        screen.tab(usize::MAX);
        assert_eq!(screen.cursor.col, 23, "a tab cannot pass the last column");
        screen.back_tab(usize::MAX);
        assert_eq!(screen.cursor.col, 0, "a back-tab cannot pass column zero");
    }

    #[test]
    fn a_zero_width_screen_is_one_column_wide_rather_than_a_panic() {
        // `Screen::write` finishes with `cols - 1`. Nothing reaches here with a zero
        // width today, and the floor is what keeps that a property of this module rather
        // than of the two callers that happen to clamp.
        let mut screen = Screen::new(0, 0);
        assert_eq!((screen.height(), screen.width()), (1, 1));
        write(&mut screen, "ab");
        assert_eq!(screen.row(0).unwrap().to_text(), "b");

        screen.resize(4, 0, Resize::Clamp).discard();
        assert_eq!((screen.height(), screen.width()), (4, 1));
        write(&mut screen, "c");
    }

    #[test]
    fn rewriting_a_row_with_what_it_already_says_damages_nothing() {
        let mut screen = Screen::new(3, 20);
        screen.goto(0, 0);
        write(&mut screen, "hello");
        screen.goto(1, 0);
        write(&mut screen, "world");
        screen.drain_damage();

        // The frame a full-screen program redraws when nothing has changed: address each
        // row and print over it what it already says.
        let before = screen.touches();
        for (row, line) in ["hello", "world"].into_iter().enumerate() {
            screen.goto(row, 0);
            write(&mut screen, line);
        }
        assert_eq!(screen.touches(), before, "an identical frame is not damage");
        assert!(
            screen.drain_damage().is_empty(),
            "and so nothing is sent to Emacs"
        );

        // An erase of a row that is already blank is not damage either, which is the
        // same rule read from the other end. What this does *not* buy is the erase and
        // the reprint together: the erase really does blank the row, so the reprint is
        // a change against what is there. Seeing through that needs a copy of the
        // previous frame to compare against, and there is deliberately none here.
        screen.goto(2, 0);
        let before = screen.touches();
        screen.erase_line(Erase::All, Pen::default());
        assert_eq!(
            screen.touches(),
            before,
            "clearing a blank row changes nothing"
        );

        // One character differs, and that row alone comes back.
        screen.goto(1, 0);
        write(&mut screen, "worlds");
        assert_eq!(screen.drain_damage(), vec![1]);
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

        // Both scroll the full region, so `archives' alone cannot tell them apart;
        // `history' is what stops the scratch grid building departure records.
        assert_eq!(primary.scroll_up(1, Pen::default()).len(), 1);
        assert!(scratch.scroll_up(1, Pen::default()).is_empty());

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
        assert!(screen.row(0).unwrap().wrapped());
        assert!(!screen.row(1).unwrap().wrapped());
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
        screen.linefeed(Pen::default()).discard();
        assert_eq!(screen.carried, 2);

        write(&mut screen, "new");
        screen.carriage_return();
        screen.linefeed(Pen::default()).discard();

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
        screen.delete_lines(1, Pen::default());

        assert_eq!(
            screen.carried, 1,
            "deleted rows are discarded, so Emacs still holds just the one"
        );
    }

    #[test]
    fn the_head_counts_the_characters_emacs_holds_rather_than_columns() {
        // `e` and a combining acute on one column, twice, then `日` on two and `ab`: a row
        // of six columns that reaches the buffer as seven characters, and wraps onto `x`.
        let mut screen = Screen::new(2, 6);
        write(&mut screen, "e\u{301}e\u{301}日abx");
        screen.linefeed(Pen::default()).discard();
        assert_eq!(screen.carried, 1);
        assert_eq!(screen.head(), Chars::new(7));
    }

    #[test]
    fn clearing_the_display_ends_the_line_it_archives() {
        let mut screen = Screen::new(4, 5);
        write(&mut screen, "aaaaabb");
        // The continuation is erased, and row 0 still says it wraps onto the blank row,
        // which is below the last row holding anything.
        screen.goto(1, 0);
        screen.erase_line(Erase::All, Pen::default());
        assert!(screen.row(0).is_some_and(|row| row.wrapped()));

        let history = screen.erase_display(Erase::All, Pen::default());

        assert_eq!(history.len(), 1);
        assert!(
            !history[0].wrapped,
            "a wrapped row archived last would join the next row 0 onto its line"
        );
        assert_eq!(screen.carried, 0);
    }

    #[test]
    fn clearing_a_display_that_archives_nothing_keeps_the_carry() {
        // A wrapped row has left for Emacs, and a scroll region keeps the clear from
        // archiving anything, so the head it left is still above the screen.
        let mut screen = Screen::new(2, 5);
        write(&mut screen, "aaaaabbbbbccccc");
        assert_eq!(screen.carried, 1);
        screen.resize(3, 5, Resize::Rewrap).discard();
        screen.set_region(0, 1);

        screen.erase_display(Erase::All, Pen::default()).discard();

        assert_eq!(screen.carried, 1);
    }

    #[test]
    fn clearing_the_display_drops_the_carry() {
        let mut screen = Screen::new(2, 5);
        write(&mut screen, "aaaaabbbbbccccc");
        assert_eq!(screen.carried, 1);

        screen.erase_display(Erase::All, Pen::default()).discard();

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
            screen.linefeed(Pen::default()).discard();
        }
        screen.goto(0, 0);
        screen.insert_lines(1, Pen::default());
        assert_eq!(screen.row(0).unwrap().to_text(), "");
        assert_eq!(screen.row(1).unwrap().to_text(), "a");
        assert_eq!(screen.row(2).unwrap().to_text(), "b");
    }

    /// The wrap flags down a screen, top first.
    fn wraps(screen: &Screen) -> Vec<bool> {
        screen.rows().map(|row| row.wrapped()).collect()
    }

    #[test]
    fn deleting_a_continuation_ends_the_line_above_it() {
        // `abcdefgh` over rows 0 and 1, then `ijklmnop` over rows 2 and 3.
        let mut screen = Screen::new(5, 4);
        write(&mut screen, "abcdefgh");
        screen.carriage_return();
        screen.linefeed(Pen::default()).discard();
        write(&mut screen, "ijklmnop");
        assert_eq!(wraps(&screen), [true, false, true, false, false]);

        // `DL` on row 1 brings `ijkl` up under `abcd`, which must not join it.
        screen.goto(1, 0);
        screen.delete_lines(1, Pen::default());
        assert_eq!(wraps(&screen), [false, true, false, false, false]);

        // In a region of rows 0 and 1, `DL` brings `ijkl` up from the bottom of the
        // region with a blank under it, and `mnop` stays outside.
        screen.set_region(0, 1);
        screen.delete_lines(1, Pen::default());
        assert_eq!(screen.row(0).unwrap().to_text(), "ijkl");
        assert_eq!(wraps(&screen), [false, false, false, false, false]);
    }

    /// A rewrap places the cursor on a row its line has, rather than chunking the blanks
    /// between the text and the cursor into rows of their own.
    #[test]
    fn a_rewrap_clamps_a_cursor_past_the_end_of_its_line() {
        // `日本語` on row 0 and the cursor on the blank row under it, six columns along:
        // where `IND` leaves it, since an index keeps the column. Narrowed to four, row
        // 0's line takes two rows and the cursor's own line still has only the one.
        let mut screen = Screen::new(3, 11);
        write(&mut screen, "日本語");
        screen.goto(1, 6);

        screen.resize(4, 4, Resize::Rewrap).discard();

        assert_eq!(
            wraps(&screen),
            [true, false, false, false],
            "the blanks the cursor sits past are not a line that wrapped"
        );
        assert_eq!(
            (screen.cursor.row, screen.cursor.col),
            (2, 3),
            "on the last column of the one row its line has"
        );
        assert_eq!(
            screen.used(),
            3,
            "and the screen is no taller than its rows"
        );
    }

    #[test]
    fn inserting_lines_ends_the_lines_they_come_between() {
        let mut screen = Screen::new(3, 4);
        write(&mut screen, "abcdefgh");
        assert_eq!(wraps(&screen), [true, false, false]);
        // A blank row now follows `abcd`.
        screen.goto(1, 0);
        screen.insert_lines(1, Pen::default());
        assert_eq!(wraps(&screen), [false, false, false]);

        // `abcd` pushed to the bottom row loses `efgh` off the end.
        let mut screen = Screen::new(3, 4);
        screen.goto(1, 0);
        write(&mut screen, "abcdefgh");
        screen.goto(0, 0);
        screen.insert_lines(1, Pen::default());
        assert_eq!(screen.row(2).unwrap().to_text(), "abcd");
        assert_eq!(wraps(&screen), [false, false, false]);
    }

    /// Once the log has dropped, a later move in the same drain window is not recorded:
    /// every row is already damaged and will be sent whole, so replaying the move in Lisp
    /// first would only rotate text `cooked--render-rows` is about to overwrite.
    #[test]
    fn a_shift_after_a_drop_is_not_recorded() {
        let mut screen = Screen::new(4, 4);
        // Alternating direction defeats coalescing, so each call is a distinct log entry:
        // the screen is 4 rows tall, so the fifth call finds the log full and drops it.
        for i in 0..5 {
            if i % 2 == 0 {
                screen.scroll_up(1, Pen::default()).discard();
            } else {
                screen.scroll_down(1, Pen::default());
            }
        }
        // A further move in the same window, after the drop.
        screen.scroll_up(1, Pen::default()).discard();

        assert!(
            screen.drain_shifts().is_empty(),
            "a move recorded after a drop would be replayed in Lisp over rows the same \
             drain sends whole"
        );
    }
}
