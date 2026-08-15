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
        }
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

    pub fn erase_display(&mut self, how: Erase) {
        let (row, last) = (self.cursor.row, self.rows.len());
        match how {
            Erase::ToEnd => {
                self.erase_line(Erase::ToEnd);
                self.clear_rows(row + 1..last);
            }
            Erase::ToStart => {
                self.clear_rows(0..row);
                self.erase_line(Erase::ToStart);
            }
            Erase::All => self.clear_rows(0..last),
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
        drop(self.scroll_up(n));
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
    pub fn resize(&mut self, rows: usize, cols: usize) -> Vec<Row> {
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

        let evicted = screen.resize(10, 10);

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

        let evicted = screen.resize(4, 10);

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

        assert!(screen.resize(20, 10).is_empty());
        assert_eq!(screen.height(), 20);
        assert_eq!(screen.row(0).unwrap().to_text(), "top");
        assert_eq!(screen.cursor.row, 1);
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
