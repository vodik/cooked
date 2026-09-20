//! Which rows leaving the top of the screen Emacs already holds.
//!
//! A line feed at the bottom of a `tail -f` hands row 0 to scrollback. Emacs is showing
//! that row already, at the top of its screen region, so rather than be sent the row again
//! as history it can keep the text it has and call it history -- markers, overlays and all.
//! See [`Delta::promoted`](super::Delta::promoted) for what it is told.
//!
//! Promotion is a prefix of the rows that left since the last drain, because Emacs can only
//! keep text that is at the top of its screen: once one departing row is not what it holds,
//! every row after it goes as text. What "what it holds" means is the front buffer's
//! question, and [`Front::holds`] answers it; this only counts.

/// The rows handed to scrollback since the last drain that Emacs can keep as its own text.
///
/// Kept beside the front buffer rather than in it: the front is the previous frame, and
/// this is a running count over the rows that have left since it was drawn.
#[derive(Debug, Default)]
pub(super) struct Promotion {
    /// How many there are, which are the front's rows 0, 1, 2 and so on, in that order.
    rows: usize,
    /// Whether the next row to leave the top can still be the front's row `rows`.
    open: bool,
}

impl Promotion {
    /// Whether a row leaving the top now could still be promoted, which is what decides
    /// whether a departing row is worth copying to compare; see [`Departed::row`].
    ///
    /// [`Departed::row`]: super::super::screen::Departed::row
    pub(super) fn is_open(&self) -> bool {
        self.open
    }

    /// Note that a row has just left the top of the screen, and whether Emacs can keep the
    /// text it holds for it rather than be sent the row again.
    ///
    /// It can when the rows that departed before it since the last drain all could, and
    /// HOLDS says Emacs' text for the front's next row is what scrollback would get. LIMIT
    /// is how many rows the screen's moves since the last drain have taken off the top, or
    /// `None` when anything but one scroll of a region from the top row has moved a row: a
    /// row past LIMIT left some other way, such as a screen clear, and a scroll lower down
    /// or an inserted line leaves the front's rows out of step with the grid's.
    pub(super) fn offer(&mut self, limit: Option<usize>, holds: impl FnOnce(usize) -> bool) {
        if self.open && limit.is_some_and(|limit| self.rows < limit) && holds(self.rows) {
            self.rows += 1;
        } else {
            self.open = false;
        }
    }

    /// How many rows this drain promotes, starting the count again for the next one.
    pub(super) fn take(&mut self) -> usize {
        self.open = true;
        std::mem::take(&mut self.rows)
    }

    /// Stop claiming that the rows from FIRST down, already handed to scrollback, are what
    /// Emacs holds.
    ///
    /// Rows the front stops knowing may have left the grid already. Emacs' text for them
    /// has changed under the front, or is about to be replaced wholesale, so they go as
    /// text after all, and so does every row that departed after them.
    pub(super) fn close_from(&mut self, first: usize) {
        if first < self.rows {
            self.rows = first;
            self.open = false;
        }
    }
}
