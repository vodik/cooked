//! Grid housekeeping: scrollback eviction, resize, drain and the alternate screen.

use super::*;

/// Where each of this drain's marks has moved to, keyed by id, for resolving the anchor
/// an [`Event::Mark`] was queued with.
///
/// A scan of the relocations themselves for the ordinary drain, which carries a handful of
/// marks and usually no mark event at all, and a map once there are enough of both to pay
/// for building one. The pathological shape is a flood of prompts: the 800k-sequence
/// `osc_dispatch` benchmark brings about 5000 events and 5500 relocations to a single
/// drain, and one scan per event is 29 million comparisons -- three quarters of that
/// benchmark's time before the map existed.
///
/// The map keeps the first anchor filed under an id, which is the entry a scan would have
/// found. Ids are unique in practice -- an id is on one cell of one row -- so this only
/// says what happens if they ever are not.
enum MarkIndex<'a> {
    Scan(&'a [(MarkId, Anchor<Chars>)]),
    Map(HashMap<MarkId, Anchor<Chars>>),
}

impl<'a> MarkIndex<'a> {
    /// How to look MARKS up for EVENTS events, whichever way is cheaper.
    ///
    /// The threshold is a product rather than either length: the cost of scanning is one
    /// per pair, and the cost of the map is one per mark plus an allocation.
    fn of(marks: &'a [(MarkId, Anchor<Chars>)], events: usize) -> Self {
        if marks.len() * events <= 256 {
            return Self::Scan(marks);
        }
        let mut map = HashMap::with_capacity(marks.len());
        for &(id, at) in marks {
            map.entry(id).or_insert(at);
        }
        Self::Map(map)
    }

    fn get(&self, id: MarkId) -> Option<Anchor<Chars>> {
        match self {
            Self::Scan(marks) => marks
                .iter()
                .find(|(mark, _)| *mark == id)
                .map(|(_, at)| *at),
            Self::Map(map) => map.get(&id).copied(),
        }
    }
}

/// The cursor's column as characters of its row's text, which is [`Delta::cursor_chars`].
///
/// The one conversion the cursor needs, and it is written once here because the whole
/// drain and the hidden drain both want it and used to spell it out separately.
///
/// A cursor with no row under it does not happen: every move clamps it inside the grid
/// and a resize brings it down with the rows. There are then no cells to count, and the
/// column is the only number available -- the same answer for a row of single-cell
/// characters, which is what an empty grid's row would be.
fn cursor_chars(screen: &Screen, cursor: Cursor) -> Chars {
    screen.row(cursor.row).map_or_else(
        || Chars::new(cursor.col),
        |row| row.chars_before(Cols::new(cursor.col)),
    )
}

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
        &self.modes.kitty_keys[self.shown.id()]
    }

    pub(super) fn kitty_stack_mut(&mut self) -> &mut KittyStack {
        &mut self.modes.kitty_keys[self.shown.id()]
    }

    pub(super) fn screen(&self) -> &Screen {
        &self.screens[self.shown.id()]
    }

    pub(super) fn screen_mut(&mut self) -> &mut Screen {
        &mut self.screens[self.shown.id()]
    }

    /// Rows leaving the *current* screen: buffer text on the primary, discarded on the alt.
    ///
    /// The guard is about which screen produced the rows, so callers that already know the
    /// rows came from the primary must use [`State::archive`] instead — see `resize`.
    ///
    /// Asked of the screen the rows left rather than of [`State::shown`], so that whether a
    /// grid is a transcript has one owner: [`Screen::keeps_history`] is the same fact that
    /// stops the alternate grid building departure records in the first place, and the two
    /// cannot now disagree.
    ///
    /// Growth is bounded by backpressure rather than by discarding: once [`Term::backlog`]
    /// is high the reader stops reading and the child blocks in `write`, as against a slow
    /// terminal. Losing the middle of a build log is worse than waiting.
    ///
    /// The alt screen contributes no scrollback and has a fixed-size grid, so there is
    /// nothing there to apply backpressure against.
    pub(super) fn evicted(&mut self, rows: Evicted) {
        if !self.screen().keeps_history() {
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
            self.events.push(Event::DisplayCleared.into());
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
        // Whether Emacs can keep its own text for each row is decided now, while the
        // moves that took it off the grid are still in the log to be read. Once one row
        // could not be kept, no later row can, and the rest of a flood costs a test.
        let Self {
            shown,
            front,
            screens,
            ..
        } = self;
        let promotion = shown.promotion();
        if promotion.is_open() {
            let limit = screens.primary.scrolled_off();
            for row in rows.iter() {
                promotion.offer(limit, |index| front.holds(index, row));
            }
            if !promotion.is_open() {
                screens.primary.witness(0);
            }
        }
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
            .and_then(|id| self.screens.primary.mark_row(id))
            .filter(|row| *row <= cursor)
            .unwrap_or(cursor);
        if keep == 0 {
            return 0;
        }
        self.remove_rows(0, keep);
        keep
    }

    /// The single funnel for rows being removed from the grid, which is what keeps the
    /// front buffer agreeing with it.
    ///
    /// Rows removed this way are discarded rather than archived, so `evicted_total` does
    /// not move. Where the prompt has gone needs no repair here: [`State::prompt_start`]
    /// names a mark rather than a row, and [`Screen::remove_rows`] slides the surviving
    /// rows up whole, attachments included.
    pub(super) fn remove_rows(&mut self, first: usize, count: usize) {
        self.screen_mut().remove_rows(first, count);
        // The rows below the cut moved on the grid and not in the buffer, and they are all
        // damaged; forgetting them sends them, as it did before there was a copy to consult.
        self.front.forget_from(first);
        self.shown.promotion().close_from(first);
    }

    /// Where the cursor is now, in the coordinates an [`Anchor`] keeps: absolute row and
    /// grid column, which is the unit a mark is queued in.
    pub(super) fn anchor(&self) -> Anchor<Cols> {
        let cursor = self.screen().cursor();
        Anchor {
            row: self.evicted_total + cursor.row,
            col: Cols::new(cursor.col),
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
        self.resolve_pen()
    }

    /// Resolve the pen the child has set to the ids it writes with, and cache them.
    ///
    /// Kept out of line deliberately. It is reached once per `SGR`, while its caller is
    /// reached once per character, and everything the store does to reach an id --
    /// lookup, collection and insert -- is inlined into it. Let the inliner fold that
    /// into [`Self::pen`] and `pen` in turn stops being small enough to fold into
    /// `print_bytes`, which is the parser's hot loop: measured on `feed_only`, the
    /// difference is 0.19% on the plain row and 1.87% on the wide one, neither of which
    /// changes the pen at all after the first character.
    #[inline(never)]
    fn resolve_pen(&mut self) -> Pen {
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
    ///
    /// Should the table be full, the collection [`StyleStore::id_for`] then runs marks
    /// everything that can hold an id until the next drain: every cell of both grids, the
    /// copy of what Emacs shows, and the rows waiting to reach it as scrollback. Emacs'
    /// own text holds faces rather than ids, so nothing already drawn can be recoloured
    /// by an id's reuse.
    fn style_id(&mut self, style: Style) -> StyleId {
        let Self {
            screens,
            front,
            pending_scrollback,
            styles,
            pen,
            ..
        } = self;
        styles.id_for(style, || {
            // The pen's own ids may be among those freed, if nothing has been written
            // with it.
            pen.forget_ids();
            (
                screens
                    .each()
                    .into_iter()
                    .flat_map(Screen::all_cells)
                    .chain(front.all_cells()),
                pending_scrollback
                    .iter()
                    .flat_map(|scrolled| scrolled.runs.iter()),
            )
        })
    }

    /// The id URI has as an `OSC 8` destination, and whether Lisp has yet to see it.
    ///
    /// The mark list is [`Self::style_id`]'s with one addition and one difference. The
    /// addition is the pen's open link: a rendition the pen holds is re-resolved from the
    /// `Style` it keeps, while an `OSC 8` link is *only* an id, so an open link with
    /// nothing yet written under it has no other home. The difference is
    /// `pending_links`, the ids announced but not yet handed over: freeing one would put
    /// two definitions of the same id in a single drain, and while the second would win
    /// harmlessly -- nothing names the first, or it would have been marked -- keeping
    /// them live is one line and leaves nothing to reason about.
    ///
    /// Emacs' own text is not marked, and that is the point of the design rather than an
    /// omission: `cooked--render-link-spans' resolves an id to its URI as the text is
    /// inserted, so scrollback holds destinations and no id outlives the grids.
    ///
    /// `pending_scrollback` *is* marked, and it earns its place: `pending_links` only
    /// covers a link from the drain it is opened in to the drain that announces it, and
    /// `front` only covers a row from the drain that shows it onward. A link opened with
    /// nothing written under it yet is announced -- and dropped from `pending_links` --
    /// on the very next drain, whether or not anything was ever printed with it; if the
    /// child prints under it only after that drain, and the row scrolls off before a
    /// later one, the row reaches `pending_scrollback` having *never* been part of
    /// `front` at all, and `pending_links` has already forgotten it. See
    /// `a_link_only_ever_seen_in_scrollback_survives_a_collection_pressed_by_a_new_one`
    /// in `term::tests::collect` for exactly that sequence, constructed by hand: with
    /// this mark removed it reuses the id for a different destination.
    pub(super) fn link_id(&mut self, uri: &str) -> (LinkId, bool) {
        let Self {
            screens,
            front,
            pending_scrollback,
            pending_links,
            links,
            pen,
            ..
        } = self;
        links.id_for(uri, || {
            (
                pen.link()
                    .into_iter()
                    .chain(pending_links.iter().map(|(id, _)| *id)),
                screens
                    .each()
                    .into_iter()
                    .flat_map(Screen::all_cells)
                    .chain(front.all_cells()),
                pending_scrollback
                    .iter()
                    .flat_map(|scrolled| scrolled.runs.iter()),
            )
        })
    }

    pub(super) fn resize(&mut self, rows: usize, cols: usize) {
        // Before the rewrap, so the rows it pushes off the top are archived with the flag
        // up. Every mark is reported, not only those a rewrap re-laid: a height-only change
        // evicts too, and re-anchoring a mark where it already was costs one `set-marker'.
        self.marks_dirty = true;
        // Every row is re-laid and sent whole, so nothing the copy holds is worth trusting.
        self.forget_front(None);
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

    /// Everything that changed since the last drain, in the shape SHAPE asks for; see
    /// [`Delta`] and [`Drain`].
    pub(super) fn drain(&mut self, shape: Drain) -> Delta {
        if shape.carries_screen() {
            self.drain_whole(shape)
        } else {
            self.drain_screenless(shape)
        }
    }

    /// [`State::drain`] for a consumer that holds a copy of the screen and has it patched
    /// row by row; see [`Drain::carries_screen`].
    ///
    /// With [`Drain::promotes`], the rows that left the top of the screen as Emacs already
    /// holds them are promoted rather than sent: see [`Delta::promoted`]. Otherwise every
    /// scrolled row is text, for a consumer that reads the scrollback rather than keeping a
    /// screen.
    fn drain_whole(&mut self, shape: Drain) -> Delta {
        let promote = shape.promotes();
        let damaged = self.screen_mut().drain_damage();
        let promoted = self.shown.promotion().take();
        // The scroll the promoted rows left by, read before the log is taken, which drops a
        // scroll that turned its region over. `None` where the log cannot name it -- an
        // empty log, or one moves have been dropped from -- and the rows go as text instead.
        let scroll = self.screen().leading_scroll();
        let promoted = scroll
            .filter(|_| promote && promoted > 0 && !self.shown.is_alternate())
            .map(|scroll| Shift {
                count: promoted,
                ..scroll
            });
        // The rows that leave before the next drain are compared against the copy as this
        // drain leaves it, a screenful at most, and only for a consumer that promotes.
        let witness = if promote {
            self.screens.primary.height()
        } else {
            0
        };
        self.screens.primary.witness(witness);
        // Taken together with the damage, because the damage indices are in the
        // coordinates the shifts leave behind.
        let mut shifts = self.screen_mut().drain_shifts();
        // A promotion is its share of the scroll that took its rows off the top: Lisp keeps
        // the rows and opens as many blank ones at the bottom of the region, which is that
        // scroll by those rows without the deletion. So the scroll is left with the rest of
        // its rows. One that turned its region over is already gone from the log, every row
        // it covers being damaged, and has nothing left to move.
        if let (Some(promotion), Some(scroll)) = (promoted, scroll)
            && scroll.count < scroll.bottom + 1 - scroll.top
        {
            let first = &mut shifts[0];
            debug_assert!(*first == scroll && first.count >= promotion.count);
            first.count -= promotion.count;
            if first.count == 0 {
                shifts.remove(0);
            }
        }
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
        let events = self.settle_events(&marks);
        let levels = Levels::of(self);
        let cursor_chars = cursor_chars(self.screen(), levels.cursor);
        let Self {
            front,
            screens,
            shown,
            ..
        } = self;
        let rows = front.present(
            shown.id(),
            &screens[shown.id()],
            levels.cursor,
            promoted,
            &shifts,
            damaged,
        );
        // Last, after everything that could have named a new id: the rows, edits and
        // scrollback above were all built from cells written before this drain began.
        let styles = self.styles.take_unsent();
        // One byte per live rendition, and `Block::push_run` reads it for the rows and the
        // edits alone. A drain with neither -- a child that only scrolled, or only rang the
        // bell -- would be copying a table nothing looks at, and a truecolor gradient holds
        // thousands of renditions live. An empty table is what the block already takes to
        // mean "no run changes the font", which is the truth when there is no run to hash.
        let fonts = if rows.is_empty() {
            Vec::new()
        } else {
            self.styles.font_bits().to_vec()
        };
        let screen = self.screen();
        Delta {
            images,
            links,
            styles,
            fonts,
            scrolled,
            scrolled_base,
            promoted,
            shifts,
            rows,
            height: screen.height(),
            width: screen.width(),
            used: screen.used(),
            // The seam is a property of the primary: the alt screen contributes no
            // scrollback, and its row 0 begins a buffer line of its own.
            head: if levels.alt {
                Chars::ZERO
            } else {
                screen.head()
            },
            levels,
            cursor_chars,
            events,
            marks,
            withheld: false,
        }
    }

    /// [`State::drain`] less the screen, for [`Drain::Hidden`] and [`Drain::Scrolled`].
    ///
    /// No [`DamagedRow`] is built, and no damage is drained: the dirty rows, the shift log
    /// and the front buffer are left exactly as they stand, so the next [`Drain::Whole`]
    /// on this session brings the screen up to date in one go however many screenless
    /// drains went by. The two shapes differ only in [`Delta::withheld`]; see
    /// [`Drain::withholds`].
    ///
    /// The caller has already checked that no event needs the screen's text, where the
    /// shape it asked for cares; see [`Term::drain_as`].
    fn drain_screenless(&mut self, shape: Drain) -> Delta {
        self.shed_unplaced_images();
        let scrolled = Vec::from(std::mem::take(&mut self.pending_scrollback));
        let scrolled_base = self.evicted_total - scrolled.len();
        // Every row that scrolled away goes as text, and the scroll that took it off stays
        // in the log for the next whole drain, which deletes the row Emacs still shows for
        // it. So none of these rows is promoted, and no row after them can be: Emacs' top
        // rows are the ones just sent again, until that drain has moved them.
        if !scrolled.is_empty() {
            self.shown.promotion().close_from(0);
            self.screens.primary.witness(0);
        }
        // Only the marks that left the grid, whose rows are in `scrolled`. `marks_dirty`
        // stays up, so the next whole drain still reports the ones on the grid, against
        // rows it has sent by then.
        let marks = std::mem::take(&mut self.evicted_marks);
        let events = self.settle_events(&marks);
        let images = std::mem::take(&mut self.pending_images);
        let links = std::mem::take(&mut self.pending_links);
        let styles = self.styles.take_unsent();
        let levels = Levels::of(self);
        let screen = self.screen();
        let cursor_chars = cursor_chars(screen, levels.cursor);
        Delta {
            images,
            links,
            styles,
            // No `fonts`: the table is read for the rows and the edits, and this drain
            // builds neither. `..Delta::default()` below leaves it empty.
            height: screen.height(),
            width: screen.width(),
            used: screen.used(),
            head: if levels.alt {
                Chars::ZERO
            } else {
                screen.head()
            },
            scrolled,
            scrolled_base,
            levels,
            cursor_chars,
            events,
            marks,
            withheld: shape.withholds(),
            ..Delta::default()
        }
    }

    /// This drain's queued events as Emacs is handed them, every mark's anchor resolved
    /// against MARKS, the relocations the same drain reports.
    ///
    /// The one place a [`Queued`] becomes an [`Event`], and the only conversion in it is
    /// the anchor's: nothing else a drain carries changes between being queued and being
    /// sent. A drain with no events -- every drain of plain output -- allocates nothing
    /// here, since collecting an empty iterator does not.
    ///
    /// A drain that does carry events pays a move and a match for each, which is what
    /// having two types costs: about 14 instructions an event, or 0.4% of the
    /// `osc_dispatch` benchmark, where a single drain carries five thousand of them.
    /// Handing the queue's buffer back with `drain(..)` instead of moving it out was
    /// measured and is worse, the drop guard costing more than the reallocation saves.
    fn settle_events(&mut self, marks: &[(MarkId, Anchor<Chars>)]) -> Vec<Event> {
        let events = std::mem::take(&mut self.events);
        self.bell_queued = false;
        let moved = MarkIndex::of(marks, events.len());
        events
            .into_iter()
            .map(|queued| match queued {
                Queued::Mark(mark, at, id) => {
                    Event::Mark(mark, self.anchor_in_characters(at, id, &moved), id)
                }
                Queued::Reply(reply) => Event::Reply(reply),
                Queued::Settled(event) => event,
            })
            .collect()
    }

    /// AT, a mark's anchor as it was taken, with its column turned into characters of the
    /// row's text; see [`Delta::marks`].
    ///
    /// A row still on the grid is measured as it stands. A row that has scrolled away is
    /// no longer anywhere to measure, but the mark ID left on its cell was measured as the
    /// row departed, and MOVED, this drain's relocations, carry that measurement. A mark
    /// with neither -- its cell overwritten before the row went -- falls back on
    /// [`Anchor::unmeasured`].
    fn anchor_in_characters(
        &self,
        at: Anchor<Cols>,
        id: MarkId,
        moved: &MarkIndex<'_>,
    ) -> Anchor<Chars> {
        match at.row.checked_sub(self.evicted_total) {
            Some(index) => match self.screen().row(index) {
                Some(row) => Anchor {
                    row: at.row,
                    col: row.chars_before(at.col),
                },
                None => at.unmeasured(),
            },
            None => moved.get(id).unwrap_or_else(|| at.unmeasured()),
        }
    }

    /// Emacs has changed its own text for row INDEX, or for every row when INDEX is `None`,
    /// so the next time the row is damaged it has to be sent whatever it holds.
    pub(super) fn forget_front(&mut self, index: Option<usize>) {
        match index {
            Some(index) => self.front.forget(index),
            None => self.front.forget_all(),
        }
        // A row the front stops knowing may have left the grid already, so the prefix of
        // departing rows Emacs was going to keep ends at the first one forgotten.
        self.shown.promotion().close_from(index.unwrap_or(0));
    }

    pub(super) fn set_alt(&mut self, on: bool) {
        let screen = if on {
            ScreenId::Alternate
        } else {
            ScreenId::Primary
        };
        // The one door: `Shown::show` ends the promotion, so a switch cannot be spelled
        // without ending it. See `Shown` for why it must end here rather than at the next
        // drain.
        if !self.shown.show(screen) {
            return;
        }
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
        //
        // Every row is compared, and only against the copy of what Emacs holds, which is
        // the same buffer text whichever grid drew it. So a switch sends the rows that
        // differ between the two grids and nothing else: a blank row or a status line
        // both screens hold costs nothing, and the markers on it stay where they are.
        // The seam needs nothing here either. The primary keeps its head, and the drain
        // reports it again once the primary is shown; see `cooked--place-seam`.
        self.screen_mut().touch_all();
        // The primary's marks are reported on the way back, against its rows. Not on the
        // way in: an anchor names a row of the primary grid, and resolved against the
        // alternate screen's text it would move a marker that a row both screens hold had
        // kept in place.
        if !on {
            self.marks_dirty = true;
        }
    }
}
