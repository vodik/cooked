//! Grid housekeeping: scrollback eviction, resize, drain and the alternate screen.

use super::*;

impl Levels {
    /// Read every level off the emulator as it stands.
    pub(super) fn of(state: &State) -> Self {
        let modes = &state.modes;
        Self {
            cursor: state.screen().cursor(),
            cursor_visible: modes.cursor_visible,
            cursor_shape: modes.cursor_shape,
            reverse_screen: modes.reverse_screen,
            reverse_screen_toggles: state.reverse_screen_toggles,
            alt: state.shown.is_alternate(),
            app_cursor: modes.app_cursor,
            keys: state.key_encoding(),
        }
    }
}

impl State {
    pub(super) fn new(rows: usize, cols: usize) -> Self {
        // Only the two grids need a size; everything else powers on at its zero value,
        // and `Modes` owns the one exception (a visible cursor). Spelled `..default()` so
        // a new field is initialised by construction rather than by remembering to.
        Self {
            screens: PerScreen {
                primary: Screen::new(rows, cols),
                // `scratch`, not `new`: the alt grid archives nothing, and saying so at
                // construction stops `scroll_up` building a departure record per line for
                // a transcript that does not exist. See `Screen::history`.
                alternate: Screen::scratch(rows, cols),
            },
            ..Self::default()
        }
    }

    /// The key encoding the child's negotiation settles on; see [`KeyEncoding::negotiate`].
    pub(super) fn key_encoding(&self) -> KeyEncoding {
        KeyEncoding::negotiate(self.kitty_stack().top(), self.modes.modify_other_keys)
    }

    /// The top of the shown screen's kitty flag stack, less what cooked does not honour.
    pub(super) fn kitty_flags(&self) -> KittyFlags {
        self.kitty_stack().top().honoured()
    }

    /// The kitty flag stack of the screen being shown; see [`Modes::kitty_keys`].
    pub(super) fn kitty_stack(&self) -> &KittyStack {
        &self.modes.kitty_keys[self.shown]
    }

    pub(super) fn kitty_stack_mut(&mut self) -> &mut KittyStack {
        &mut self.modes.kitty_keys[self.shown]
    }

    pub(super) fn screen(&self) -> &Screen {
        &self.screens[self.shown]
    }

    pub(super) fn screen_mut(&mut self) -> &mut Screen {
        &mut self.screens[self.shown]
    }

    /// Rows leaving the *current* screen: buffer text on the primary, discarded on the alt.
    ///
    /// The guard is about which screen produced the rows, so callers that already know the
    /// rows came from the primary must use [`State::archive`] instead — see `resize`.
    ///
    /// Growth is bounded by backpressure rather than by discarding: once [`Term::backlog`]
    /// is high the reader stops reading and the child blocks in `write`, as against a slow
    /// terminal. Losing the middle of a build log is worse than waiting.
    ///
    /// The alt screen contributes no scrollback and has a fixed-size grid, so there is
    /// nothing there to apply backpressure against.
    pub(super) fn evicted(&mut self, rows: Evicted) {
        if self.shown.is_alternate() {
            return;
        }
        self.archive(rows);
    }

    /// Run OP on the screen being shown, and send the rows it pushed off the top wherever
    /// that screen's departing rows go.
    pub(super) fn evicting(&mut self, op: impl FnOnce(&mut Screen) -> Evicted) {
        let evicted = op(self.screen_mut());
        self.evicted(evicted);
    }

    /// ED on the shown screen, with what erasing it all means beyond the cells: the rows
    /// go to history and Emacs is told the display was cleared. DECALN and RIS both erase
    /// this way before drawing, so a pattern or a reset never paints over a transcript
    /// that `CSI 2 J` would have kept.
    pub(super) fn erase_display(&mut self, how: Erase, pen: Pen) {
        self.evicting(|screen| screen.erase_display(how, pen));
        if how == Erase::All {
            self.cleared_display();
        }
    }

    /// The child cleared the whole display; see [`Event::DisplayCleared`].
    ///
    /// Silent on the alternate screen, which archives nothing and is pinned to the top of
    /// the window already: there is no transcript there to scroll out of view.
    pub(super) fn cleared_display(&mut self) {
        if !self.shown.is_alternate() {
            self.events.push(Event::DisplayCleared);
        }
    }

    /// Send rows to scrollback unconditionally, for callers holding primary rows.
    ///
    /// The single funnel for rows leaving the primary screen, which is why the absolute
    /// row counter is kept here rather than at each of its callers.
    pub(super) fn archive(&mut self, rows: Evicted) {
        // The empty case first, because it is the common one: every printed character's
        // result comes through here, and only the one that scrolls the bottom margin
        // brings a row. Returning early is worth about 10% on a full-screen repaint.
        if rows.is_empty() {
            return;
        }
        let base = self.evicted_total;
        // An eviction moves live marks too, if by less than a rewrap. The evicted row goes
        // in above as scrollback and renders differently there by the newline
        // `cooked-rejoin-wrapped-lines' withholds from a continuation row, so without a
        // repair a long-running command's marker walks away from its prompt.
        self.marks_dirty = true;
        self.evicted_total += rows.len();
        // A move, not a rebuild: `Screen` reduced these rows to runs as they left (see
        // `Departed`). `extend` on an empty iterator does not allocate, so a row carrying
        // no marks, the usual case, costs nothing for them.
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
        if self.shown.is_alternate() {
            return 0;
        }
        let cursor = self.screens.primary.cursor().row;
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
    /// not move, but every row *below* the cut slides up and an anchor pointing at one has
    /// to come down with it -- the same arithmetic [`Screen::remove_rows`] applies to the
    /// cursor.
    ///
    /// Every removal must go through here rather than [`State::screen_mut`]. A stale
    /// anchor after `cooked-delete-output` would make a later `clear_to_prompt` fall back
    /// to cutting at the cursor, which is wrong for a multi-line prompt.
    pub(super) fn remove_rows(&mut self, first: usize, count: usize) {
        self.screen_mut().remove_rows(first, count);
        // The rows below the cut moved on the grid and not in the buffer, and they are all
        // damaged; forgetting them sends them, as it did before there was a copy to consult.
        self.front.forget_from(first);
        // The alt grid holds a running program's frame, not a transcript; no anchor
        // points into it, and the primary's rows have not moved.
        if self.shown.is_alternate() {
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
        let cursor = self.screen().cursor();
        Anchor {
            row: self.evicted_total + cursor.row,
            col: cursor.col,
        }
    }

    pub(super) fn linefeed(&mut self) {
        let pen = self.pen();
        self.evicting(|screen| screen.linefeed(pen));
    }

    /// What a write with the pen as it stands puts in the cells it touches: the pen's
    /// rendition and open link, and the rendition an erase leaves.
    ///
    /// Asked per character on the print path, where it is a cached answer: the store is
    /// consulted only after [`PenState`] has dropped the ids because the pen changed.
    pub(super) fn pen(&mut self) -> Pen {
        if let Some(pen) = self.pen.ids() {
            return pen;
        }
        let (style, link) = (self.pen.style(), self.pen.link());
        let erase = style.erase();
        let text = self.style_id(style);
        let pen = Pen {
            style: text,
            link,
            // Most pens have no background, and erase to the default rendition, which
            // needs no lookup at all.
            erase: if erase == Style::default() {
                StyleId::DEFAULT
            } else {
                // Given an id without a collection, even on a full table. Nothing holds
                // TEXT until the pen is remembered, so a collection here would free it and
                // hand the slot to the erase: `SGR 1;41` on a full table wrote its text
                // under an id that meant the erase rendition. One id past the limit is
                // collected for by the next rendition instead.
                match self.styles.lookup(erase) {
                    Some(id) => id,
                    None => self.styles.insert(erase),
                }
            },
        };
        self.pen.remember(pen);
        pen
    }

    /// The id STYLE has, giving it one if it has none.
    fn style_id(&mut self, style: Style) -> StyleId {
        if let Some(id) = self.styles.lookup(style) {
            return id;
        }
        if self.styles.is_full() {
            self.collect_styles();
        }
        self.styles.insert(style)
    }

    /// Free the rendition ids nothing holds any more.
    ///
    /// Everything that can hold an id until the next drain is marked: every cell of both
    /// grids, the copy of what Emacs shows, and the rows waiting to reach it as
    /// scrollback. Emacs' own text holds faces rather than ids, so nothing already drawn
    /// can be recoloured by an id's reuse.
    fn collect_styles(&mut self) {
        // The pen's own ids may be among those freed, if nothing has been written with it.
        self.pen.forget_ids();
        let Self {
            screens,
            front,
            pending_scrollback,
            styles,
            ..
        } = self;
        styles.collect(|mark| {
            for screen in screens.each() {
                screen.all_cells().iter().for_each(|cell| mark(cell.style));
            }
            front.all_cells().iter().for_each(|cell| mark(cell.style));
            for scrolled in pending_scrollback.iter() {
                scrolled.runs.iter().for_each(|run| mark(run.style));
            }
        });
    }

    pub(super) fn resize(&mut self, rows: usize, cols: usize) {
        // Before the rewrap, so the rows it pushes off the top are archived with the flag
        // up. Every mark is reported, not only those a rewrap re-laid: a height-only change
        // evicts too, and re-anchoring a mark where it already was costs one `set-marker'.
        self.marks_dirty = true;
        // Every row is re-laid and sent whole, so nothing the copy holds is worth trusting.
        self.forget_sent(None);
        let evicted = self.screens.primary.resize(rows, cols, Resize::Rewrap);
        // The alt screen contributes no scrollback -- it is a fixed-size scratch grid,
        // never transcript -- so its rewrap has nothing to hand anyone.
        self.screens
            .alternate
            .resize(rows, cols, Resize::Clamp)
            .discard();
        // These rows came off the primary whichever screen is showing, so they are history
        // even mid-alt. Routing them through `evicted` would drop the top of the transcript
        // whenever the frame was resized with a full-screen program open.
        self.archive(evicted);
    }

    /// Drop the bytes of any image transmitted this drain that nothing is left showing.
    ///
    /// The frame-rate governor. Transmitting is not displaying: `viu` sends about 2MB a
    /// frame and draws each over the last, so a drain that lands two frames late holds
    /// three payloads of which one is on the grid. Emacs' readiness for a drain therefore
    /// decides how many frames cross, with no rate configured anywhere, and a child
    /// outrunning the display loses only frames nobody could have seen.
    ///
    /// Three things count as showing a picture, and the third is easy to miss:
    ///
    ///   - a cell of either grid, since a placement is per cell;
    ///   - a row scrolled off in *this* delta, whose runs Emacs is about to render;
    ///   - a client name bound by `i=`, because a later bare `a=p` can still ask for it,
    ///     and that transmission is the only chance those bytes have to cross.
    ///
    /// Shedding tells the store, because [`crate::emu::image::ImageStore`] tracks an id
    /// exactly when Emacs has its bytes. Left tracked, the next transmission of the same
    /// frame would be treated as already sent, and the placement would name a picture
    /// Emacs was never given.
    pub(super) fn shed_unplaced_images(&mut self) {
        if self.pending_images.is_empty() {
            return;
        }
        let mut live: HashSet<ImageId> = self.kitty.bound_images().collect();
        for screen in self.screens.each() {
            for row in screen.rows() {
                for (_, extra) in row.extras() {
                    if let Extra::Image(place) = extra {
                        live.insert(place.id);
                    }
                }
            }
        }
        for scrolled in &self.pending_scrollback {
            for run in &scrolled.runs {
                if let Some(Deco::Images(places)) = &run.deco {
                    live.extend(places.iter().map(|place| place.id));
                }
            }
        }
        let mut shed = Vec::new();
        self.pending_images.retain(|image| {
            let keep = live.contains(&image.id);
            if !keep {
                shed.push(image.id);
            }
            keep
        });
        for id in shed {
            self.forget_image(id);
        }
    }

    /// Stop tracking image ID everywhere the emulator hangs something off it: the store's
    /// ledger and geometry, and the kitty client's own name for the picture.
    pub(super) fn forget_image(&mut self, id: ImageId) {
        self.images.forget(id);
        self.kitty.forget(id);
    }

    pub(super) fn drain(&mut self) -> Delta {
        let damaged = self.screen_mut().drain_damage();
        // Taken together with the damage, because the damage indices are in the
        // coordinates the shifts leave behind.
        let shifts = self.screen_mut().drain_shifts();
        self.shed_unplaced_images();
        let images = std::mem::take(&mut self.pending_images);
        let links = std::mem::take(&mut self.pending_links);
        // `Vec::from` rather than `drain(..).collect()`: it hands the deque's ring buffer
        // over as the Vec's, with no second allocation and no element-wise copy.
        let scrolled = Vec::from(std::mem::take(&mut self.pending_scrollback));
        // Taken before the batch is handed over, so it names the first line *in* it.
        let scrolled_base = self.evicted_total - scrolled.len();
        // Read here, off the grid as it stands, rather than when the resize re-laid it:
        // the child is signalled on a resize and answers by redrawing, and anything it
        // scrolls in between moves every mark still on the grid with its row.
        let marks = self.take_marks();
        let mut events = std::mem::take(&mut self.events);
        self.bell_queued = false;
        for event in &mut events {
            if let Event::Mark(_, at, id) = event {
                *at = self.anchor_in_characters(*at, *id, &marks);
            }
        }
        let levels = Levels::of(self);
        let cursor_chars = self
            .screen()
            .row(levels.cursor.row)
            .map_or(levels.cursor.col, |row| row.chars_before(levels.cursor.col));
        let rows = self.damaged_rows(damaged, &shifts, levels.cursor);
        // Last, after everything that could have named a new id: the rows, edits and
        // scrollback above were all built from cells written before this drain began.
        let styles = self.styles.take_unsent();
        let fonts = self.styles.font_bits().to_vec();
        let screen = self.screen();
        Delta {
            images,
            links,
            styles,
            fonts,
            scrolled,
            scrolled_base,
            shifts,
            rows,
            height: screen.height(),
            used: screen.used(),
            // The seam is a property of the primary: the alt screen contributes no
            // scrollback, and its row 0 begins a buffer line of its own.
            head: if levels.alt { 0 } else { screen.head() },
            levels,
            cursor_chars,
            events,
            marks,
        }
    }

    /// AT, a mark's anchor as it was taken, with its column turned into characters of the
    /// row's text; see [`Delta::marks`].
    ///
    /// A row still on the grid is measured as it stands. A row that has scrolled away is
    /// no longer anywhere to measure, but the mark ID left on its cell was measured as the
    /// row departed, and MARKS, this drain's relocations, carry that measurement. A mark
    /// with neither -- its cell overwritten before the row went -- keeps its column,
    /// which is still right on a row with no wide character before it.
    fn anchor_in_characters(&self, at: Anchor, id: MarkId, marks: &[(MarkId, Anchor)]) -> Anchor {
        match at.row.checked_sub(self.evicted_total) {
            Some(index) => Anchor {
                col: self
                    .screen()
                    .row(index)
                    .map_or(at.col, |row| row.chars_before(at.col)),
                ..at
            },
            None => marks
                .iter()
                .find(|(mark, _)| *mark == id)
                .map_or(at, |(_, moved)| *moved),
        }
    }

    /// The damaged rows Emacs does not already have, recording them as sent.
    ///
    /// SHIFTS are applied to the copy first, as Emacs applies them to its text, because the
    /// damage indices are in the coordinates they leave behind. Then a damaged row that
    /// matches the copy is left out, which is a repaint that wrote the same thing back.
    ///
    /// A changed row with no changed neighbour whose change is small is sent as an
    /// [`Edit`] of the part that changed; see [`front::Front::edit`].
    ///
    /// On the primary screen, the rows below `used` are forgotten afterwards. Emacs trims
    /// its screen region to that many lines, so whatever it held for them is gone, and a
    /// background wash drawn there later must be sent rather than matched against a copy of
    /// text the buffer no longer has. A wash already there when the screen grows back over
    /// it is sent too, damaged or not.
    fn damaged_rows(
        &mut self,
        mut damaged: Vec<usize>,
        shifts: &[Shift],
        cursor: Cursor,
    ) -> Vec<DamagedRow> {
        let (height, width) = (self.screen().height(), self.screen().width());
        if !self.front.fits(height, width) {
            self.front.reset(height, width);
        }
        for shift in shifts {
            self.front.shift(*shift);
        }
        // A cursor move damages no row, and yet Lisp cuts a glyph run around the cursor's
        // cell, so the rows it left and the row it is on are asked about as if damaged.
        // Their cells are what the copy holds, so only the cursor can make them differ.
        let front = &self.front;
        let screen = &self.screens[self.shown];
        // A row Emacs trimmed off the bottom of the primary comes back as an empty line when
        // the screen grows over it, which a cursor moving down or a scroll does without
        // damaging it. An empty line is what a blank row renders to, but not a row the
        // child washed with a background, so that one is sent.
        let used = if self.shown.is_alternate() {
            0
        } else {
            screen.used()
        };
        let regrown = (0..used).filter(|&row| {
            front.trimmed(row) && screen.row(row).is_some_and(|row| !row.is_blank())
        });
        let moved: Vec<usize> = front
            .cursor_rows()
            .chain(Some(cursor.row).filter(|&row| front.knows(row)))
            .chain(regrown)
            .filter(|row| damaged.binary_search(row).is_err())
            .collect();
        if !moved.is_empty() {
            damaged.extend(moved);
            damaged.sort_unstable();
            damaged.dedup();
        }
        let screen = &self.screens[self.shown];
        // Row 0 of the primary screen continues the scrollback above it when the head is
        // not empty, so its text in the buffer begins mid-line.
        let seam = !self.shown.is_alternate() && screen.head() > 0;
        let front = &mut self.front;
        let at = |index: usize| (cursor.row == index).then_some(cursor.col as u16);
        let changed: Vec<usize> = damaged
            .into_iter()
            .filter(|&index| {
                let Some(row) = screen.row(index) else {
                    return false;
                };
                let same = front.matches(index, row, at(index));
                if same {
                    front.settle_cursor(index, at(index));
                }
                !same
            })
            .collect();
        let rows = changed
            .iter()
            .enumerate()
            .filter_map(|(i, &index)| {
                let row = screen.row(index)?;
                // Only a row with no changed neighbour is offered as an edit. Contiguous
                // rows coalesce into one block that Emacs rewrites with a single deletion
                // and insertion, and measured per frame that is several times cheaper than
                // an edit per row: 24 plain rows as a block took 0.025ms against 0.10ms as
                // 24 small edits. An isolated row -- the spinner, the clock, the bar --
                // has no block to join, and there the edit is the cheaper of the two.
                let isolated = (i == 0 || changed[i - 1] + 1 != index)
                    && changed.get(i + 1).is_none_or(|&next| next != index + 1);
                let edit = isolated
                    .then(|| front.edit(index, row, at(index), seam && index == 0))
                    .flatten()
                    .map(|span| Edit {
                        char_start: span.char_start,
                        char_end: span.char_end,
                        chars: span.length,
                        runs: row.runs_between(span.start, span.end),
                    });
                front.record(index, row, at(index));
                Some(DamagedRow {
                    index,
                    wrapped: row.wrapped(),
                    runs: row.runs(),
                    edit,
                })
            })
            .collect();
        if !self.shown.is_alternate() {
            self.front.trim_from(self.screen().used());
        }
        rows
    }

    /// Emacs has changed its own text for row INDEX, or for every row when INDEX is `None`,
    /// so the next time the row is damaged it has to be sent whatever it holds.
    pub(super) fn forget_sent(&mut self, index: Option<usize>) {
        match index {
            Some(index) => self.front.forget(index),
            None => self.front.forget_from(0),
        }
    }

    pub(super) fn set_alt(&mut self, on: bool) {
        let shown = if on {
            ScreenId::Alternate
        } else {
            ScreenId::Primary
        };
        if self.shown == shown {
            return;
        }
        self.shown = shown;
        if on {
            // Dropped rather than archived: this is the previous full-screen program's
            // leftover frame, which was never history to begin with.
            // The default pen, not the child's: a freshly entered alt screen is not the
            // outgoing program's background wash.
            let alternate = &mut self.screens.alternate;
            alternate
                .erase_display(Erase::All, Pen::default())
                .discard();
            alternate.goto(0, 0);
        }
        // No event to match: `Levels::alt` is the level, and Lisp acts on that. See the
        // note on `Event` about not sending the same state two ways.
        self.screen_mut().touch_all();
        self.forget_sent(None);
        // Both screens are drawn over the same buffer region, so a switch either way
        // replaces the text of every live row, and the markers Emacs holds on those rows
        // collapse to the region's start. The report on the way back is the one that
        // matters: without it, the four prompts run before `less` all came back naming
        // the first line. It is not withheld on the way in, because the rule stays "every
        // rewrite of the whole screen reports every mark", as for `Term::touch_all`.
        //
        // The markers are still wrong while the alternate screen is up, since its own
        // redraws collapse them again: sticky scroll or command search reading them in
        // that window sees one position for every prompt on screen until the program
        // exits. Keeping the primary's rows in the buffer would close that.
        self.marks_dirty = true;
    }
}
