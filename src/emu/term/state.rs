//! Grid housekeeping: scrollback eviction, resize, drain and the alternate screen.

use super::*;

impl State {
    pub(super) fn new(rows: usize, cols: usize) -> Self {
        // Only the two grids need a size; everything else powers on at its zero value,
        // and `Modes` owns the one exception (a visible cursor). Spelled `..default()` so
        // a new field is initialised by construction rather than by remembering to.
        Self {
            primary: Screen::new(rows, cols),
            // `scratch`, not `new`: the alt grid archives nothing, and saying so at
            // construction is what stops `scroll_up` building a departure record per line
            // for a transcript that does not exist. See `Screen::history`.
            alt: Screen::scratch(rows, cols),
            ..Self::default()
        }
    }

    /// Kitty wins when both are on: a child that pushed kitty flags is speaking the newer
    /// protocol deliberately, and libraries that enable both expect kitty to take effect.
    pub(super) fn key_encoding(&self) -> KeyEncoding {
        match (
            self.modes.kitty_keys.last().copied().unwrap_or(0),
            self.modes.modify_other_keys,
        ) {
            (flags, _) if flags & 1 != 0 => KeyEncoding::Kitty,
            (_, 2) => KeyEncoding::ModifyOtherKeys,
            _ => KeyEncoding::Legacy,
        }
    }

    pub(super) fn screen(&self) -> &Screen {
        if self.on_alt {
            &self.alt
        } else {
            &self.primary
        }
    }

    pub(super) fn screen_mut(&mut self) -> &mut Screen {
        if self.on_alt {
            &mut self.alt
        } else {
            &mut self.primary
        }
    }

    /// Rows leaving the *current* screen: buffer text on the primary, discarded on the alt.
    ///
    /// The guard is about which screen produced the rows, so callers that already know the
    /// rows came from the primary must use [`State::archive`] instead — see `resize`.
    ///
    /// Growth is bounded by backpressure rather than by discarding: the reader stops
    /// reading once [`Term::backlog`] is high, the pty's own buffer fills, and the
    /// child blocks in `write` exactly as it would against a slow terminal. Dropping
    /// would be lossy, and losing the middle of a build log is worse than waiting.
    ///
    /// The alt screen is exempt from that measure by design. It contributes no scrollback,
    /// its grid is a fixed size, and `min_redisplay_interval` already bounds how often its
    /// frames are drawn — so intermediate frames of a repaint are genuinely discardable in
    /// a way log lines are not, and there is nothing to apply backpressure against.
    ///
    pub(super) fn evicted(&mut self, rows: Evicted) {
        if self.on_alt {
            return;
        }
        self.archive(rows);
    }

    /// The child cleared the whole display; see [`Event::DisplayCleared`].
    ///
    /// Silent on the alternate screen, which archives nothing and is pinned to the top of
    /// the window already: there is no transcript there to scroll out of view.
    pub(super) fn cleared_display(&mut self) {
        if !self.on_alt {
            self.events.push(Event::DisplayCleared);
        }
    }

    /// Send rows to scrollback unconditionally, for callers holding primary rows.
    ///
    /// The single funnel for rows leaving the primary screen, which is why the absolute
    /// row counter is kept here rather than at each of its callers.
    pub(super) fn archive(&mut self, rows: Evicted) {
        // An eviction moves live marks as surely as a rewrap does, if by less. The
        // buffer's live text is *rebuilt* around what left -- the evicted row goes in
        // above as scrollback while the rows below it move up a slot -- and the two
        // renderings of that row differ by exactly the newline `cooked-rejoin-wrapped-
        // lines' withholds from a continuation row. So every position below it slides by
        // one per wrapped row that leaves, which is the drift a long-running command
        // shows: its marker walks away from its prompt as its own output scrolls.
        // The empty case first, because it is not the rare one: `Perform::print` hands the
        // result of every single printed character to `evicted`, and only the character
        // that scrolls the bottom margin brings a row with it. Everything below is a
        // no-op for the rest -- but it is a no-op that still reads two fields, sets up an
        // iterator and drops a `Vec`, once per byte of output.
        //
        // Worth ~10%: the full-screen repaint benchmark, which never evicts a single row,
        // runs at 277ms with this return and 313ms without it, and `plain` at 203ms
        // against 224ms. Hoisting the same test up into `evicted`, or adding it again at
        // the `print` call site, both measured as no further gain -- so it belongs here,
        // once, at the funnel every eviction path already goes through.
        if rows.is_empty() {
            return;
        }
        let base = self.evicted_total;
        self.marks_dirty = true;
        self.evicted_total += rows.len();
        // A move, not a rebuild. `Screen` reduced these rows to runs as they left the
        // grid -- see `Departed` -- so everything here is already the shape the backlog
        // wants, and both halves of this loop hand it straight over.
        //
        // `extend` on an empty iterator neither allocates nor grows, which is what makes
        // the mark half free: a row carrying no marks is the overwhelming case, and it
        // used to cost a `Vec` per eviction here plus another per row inside `marks_in`.
        for (index, row) in rows.into_iter().enumerate() {
            self.evicted_marks
                .extend(row.marks.iter().map(|&(col, id)| {
                    (
                        id,
                        Anchor {
                            row: base + index,
                            col,
                        },
                    )
                }));
            self.pending_scrollback.push_back(Scrolled {
                runs: row.runs,
                wrapped: row.wrapped,
            });
        }
    }

    /// See [`Term::clear_to_prompt`].
    ///
    /// A no-op on the alternate screen: that grid is a running program's frame, not a
    /// transcript, and removing rows from under it would corrupt a redisplay we cannot
    /// repair. The scrollback Emacs deletes alongside is the primary's, and is untouched
    /// by whatever is on screen.
    pub(super) fn clear_to_prompt(&mut self) -> usize {
        if self.on_alt {
            return 0;
        }
        let cursor = self.primary.cursor.row;
        let keep = self
            .prompt_start
            .and_then(|at| at.row.checked_sub(self.evicted_total))
            .filter(|row| *row <= cursor)
            .unwrap_or(cursor);
        if keep == 0 {
            return 0;
        }
        self.remove_rows(0, keep);
        keep
    }

    /// The single funnel for rows being removed from the grid, which is what keeps
    /// [`State::prompt_start`] meaning what it says.
    ///
    /// Rows removed this way are discarded rather than archived, so `evicted_total` does
    /// not move and screen row 0 keeps its absolute number — but every row *below* the
    /// cut slides up, so an anchor pointing at one of them has to come down to meet it.
    /// The rebase is the same arithmetic [`Screen::remove_rows`] applies to the cursor,
    /// and for the same reason: both name a row by where it sits, and the rows moved.
    ///
    /// Going through here rather than reaching for [`State::screen_mut`] is not a style
    /// preference. `clear_to_prompt` rebased and `Term::remove_rows` did not, so
    /// `cooked-delete-output` — which removes rows above the prompt — left the anchor
    /// stale by exactly the count it dropped. A later `clear_to_prompt` then measured a
    /// prompt row past the cursor, failed its own sanity filter, and silently fell back
    /// to cutting at the cursor: right for a one-line prompt, and wrong for the
    /// multi-line case the anchor exists to get right.
    pub(super) fn remove_rows(&mut self, first: usize, count: usize) {
        self.screen_mut().remove_rows(first, count);
        // The alt grid holds a running program's frame, not a transcript; no anchor
        // points into it, and the primary's rows have not moved.
        if self.on_alt {
            return;
        }
        if let Some(at) = &mut self.prompt_start {
            let Some(row) = at.row.checked_sub(self.evicted_total) else {
                // Already below the screen's top edge, so nothing on the grid moved it.
                return;
            };
            let moved = match row {
                row if row >= first + count => row - count,
                // The anchored row itself went. The nearest row it can still name is
                // the one that closed the gap, exactly as the cursor is clamped.
                row if row >= first => first,
                row => row,
            };
            at.row = self.evicted_total + moved;
        }
    }

    /// Where the cursor is now, in the coordinates an [`Anchor`] keeps.
    pub(super) fn anchor(&self) -> Anchor {
        let cursor = self.screen().cursor;
        Anchor {
            row: self.evicted_total + cursor.row,
            col: cursor.col,
        }
    }

    pub(super) fn linefeed(&mut self) {
        let pen = self.pen;
        let evicted = self.screen_mut().linefeed(pen);
        self.evicted(evicted);
    }

    pub(super) fn resize(&mut self, rows: usize, cols: usize) {
        // Before the rewrap, so the rows it pushes off the top are archived with the flag
        // already up and their marks recorded on the way past. Every mark a resize could
        // have moved is reported, not only the ones a rewrap re-laid: a height-only change
        // evicts from the top too, and a mark re-anchored to where it already was costs
        // Emacs one `set-marker'.
        self.marks_dirty = true;
        let evicted = self.primary.resize(rows, cols, Resize::Rewrap);
        // The alt screen contributes no scrollback -- it is a fixed-size scratch grid,
        // never transcript -- so its rewrap has nothing to hand anyone.
        self.alt.resize(rows, cols, Resize::Clamp).discard();
        // These rows came off the primary whichever screen is showing, so they are history
        // even mid-alt. Routing them through `evicted` would drop the top of the transcript
        // whenever the frame was resized with a full-screen program open.
        self.archive(evicted);
    }

    pub(super) fn drain(&mut self) -> Delta {
        let damaged = self.screen_mut().drain_damage();
        let images = std::mem::take(&mut self.pending_images);
        let links = std::mem::take(&mut self.pending_links);
        // `Vec::from` rather than `drain(..).collect()`: this hands the deque's own ring
        // buffer over as the Vec's, so there is no second allocation and nothing is
        // copied element-wise. Draining to keep the deque's capacity across drains was
        // tried and measured as noise in both directions -- and it is strictly more
        // allocation, since the collect has to build a fresh Vec anyway.
        let scrolled = Vec::from(std::mem::take(&mut self.pending_scrollback));
        // Taken before the batch is handed over, so it names the first line *in* it.
        let scrolled_base = self.evicted_total - scrolled.len();
        let events = std::mem::take(&mut self.events);
        // Read here, off the grid as it stands, rather than when the resize re-laid it:
        // the child is signalled on a resize and answers by redrawing, and anything it
        // scrolls in between moves every mark still on the grid with its row.
        let marks = self.take_marks();
        let (cursor_visible, alt, app_cursor) = (
            self.modes.cursor_visible,
            self.on_alt,
            self.modes.app_cursor,
        );
        let cursor_shape = self.modes.cursor_shape;
        let keys = self.key_encoding();
        let screen = self.screen();
        Delta {
            images,
            links,
            scrolled,
            scrolled_base,
            rows: damaged
                .into_iter()
                .filter_map(|i| screen.row(i).map(|r| (i, r.runs())))
                .collect(),
            height: screen.height(),
            used: screen.used(),
            // The seam is a property of the primary: the alt screen contributes no
            // scrollback, and its row 0 begins a buffer line of its own.
            head: if alt { 0 } else { screen.head() },
            cursor: screen.cursor,
            cursor_visible,
            cursor_shape,
            alt,
            app_cursor,
            keys,
            events,
            marks,
        }
    }

    pub(super) fn set_alt(&mut self, on: bool) {
        if self.on_alt == on {
            return;
        }
        self.on_alt = on;
        if on {
            // Dropped rather than archived: this is the previous full-screen program's
            // leftover frame, which was never history to begin with.
            // `Style::default()`, not the pen: a freshly entered alt screen is not the
            // outgoing program's background wash.
            self.alt
                .erase_display(Erase::All, Style::default())
                .discard();
            self.alt.goto(0, 0);
        }
        // No event to match: `Delta::alt` is the level, and Lisp acts on that. See the
        // note on `Event` about not sending the same state two ways.
        self.screen_mut().touch_all();
    }
}
