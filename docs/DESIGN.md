# Design notes

Reasoning that a docstring should not have to carry. Each section is keyed by the
function or variable it explains, so `C-h f` can point here.

Most of this was learned the expensive way — from a bug that took a while to see. That
is why it is written down rather than left to be re-derived.

---

## The seam between the grid and the buffer

The buffer *is* the scrollback. Rows that leave the emulator's screen are handed over
once and become ordinary buffer text; the lines after `cooked--screen-start` are the
live screen, rewritten from damage reports.

The invariant: **buffer text equals the grid, plus any pending input rendered at the
cursor.** Every redisplay lifts the pending input out, applies the grid, puts it back.

The two ends therefore hold one structure between them, and the boundary is the only
place they can disagree. So the geometry is *reported* rather than re-derived:
`cooked--grid` carries the emulator's own account of how tall the grid is, how much of
it is occupied, and how much of the line straddling the boundary has already been
handed over. Emacs owns the buffer and makes every edit; it just does not get a second
opinion about the shape it is editing to. `cooked--check-seam` is that boundary stated
as an assertion, and runs under `cooked-debug`.

### `cooked--discard-scrollback`

The scrollback is the one piece of state the two ends co-own — and it is exactly one
number: how much of the emulator's top row's line has already left for Emacs. A wrapped
line can span the boundary being cut, so a deletion that does not say so leaves the
emulator continuing a line that is no longer there, and the desync is silent until the
next resize.

`cooked--discard-scrollback-region` is the narrower sibling: a cut finishing short of
`cooked--screen-start` cannot change that number — the text row 0 continues is still
there, still ending where it did — so it needs no bookkeeping at all. That is what makes
deleting one command's output out of the middle possible.

### `cooked--split-seam`: the continuation the buffer never took

The third case, and the odd one: nothing was deleted at all. With
`cooked-rejoin-wrapped-lines` off, every row handed over gets a newline of its own, so
Emacs holds no continuation — its half of the seam is zero — while the emulator goes on
carrying a number about text the buffer never joined up. Nothing on the other side
resets it. The two `cooked--forget-history` calls in the file are both *discards*, and
this mode discards nothing; it simply never continues anything.

Left standing, the claim is spent at the next rewrap. `Logical::take_front` cuts a
fragment off the front of row 0's line to top the head up to a whole number of rows at
the new width, and with rows staying split that fragment arrives as a line of its own —
a stub of a few characters, or of nothing but the padding a chunk boundary landed in,
wedged between the transcript and the live screen. One more at every resize, and the
head growing by the width of each.

**The test is the buffer's own head, not the flag alone**, which is what makes it safe
to run unconditionally: the carry is dropped only once `cooked--screen-start` sits at a
line beginning, which is the buffer saying it continues nothing. A mid-line seam left
behind by a toggle is therefore correctly left alone — that text *was* handed over as a
continuation while rejoining was on, and the emulator is right about it until the next
row handed over closes the line. Which is also why `cooked-toggle-rejoin-wrapped-lines`
needs nothing of its own.

**Where it runs is the part that was wrong.** It used to ride along in
`cooked--trim-scrollback`, at the foot of the drain, because that is the one thing in
cooked-scrollback.el the drain calls unconditionally — so the reset landed *after*
`cooked--apply` had returned, which is to say after `cooked--check-seam` had already
looked. The assertion had to exclude the split mode entirely, and the drift went
unwatched. It now runs inside `cooked--apply`, one line above the assertion, so the
claim is settled before the assertion reads it and the assertion covers both modes: with
rows rejoined the two halves must agree, and with rows split Emacs' half is always zero
and so the emulator's must be too.

The failure it catches is real, not hypothetical. With the reset suppressed, a
59-character line through a 4×10 screen signals

    seam desync: buffer holds 0 characters of row 0's line, emulator says 20

on the drain that evicts the first wrapped row.

### The transcript is read-only in two halves

Scrollback is protected once, where it is inserted (`cooked--render-scrolled`), because
it never changes again. The live screen is protected on every drain
(`cooked--protect`), because the boundary between it and the input region moves.
`cooked--read-only-props` is the one property list both write, and sharing it is worth
more than tidiness: the two regions are adjacent halves of one read-only transcript, so
a difference between them would show as a seam the user can type into.

Sharing the *object* matters as well as the value. `add-text-properties` compares with
`eq`, so two separately-written `(read-only)` lists read as a change and provoke an
interval rewrite over text that already carries exactly what is being asked for.

`cooked--protect`'s sweep is *not* narrowed to the rows the render rewrote, and the
temptation is real — `cooked--render-rows` returns those bounds. It is declined because
they are not the whole of what a drain inserts: `cooked--pad-to-cursor` extends the
cursor's row, which need not be the last one, and `cooked--fit-screen` and
`cooked--goto-screen-row` add the newlines that make a row exist. A sweep that misses
one of those leaves a hole in the transcript, and a hole in a read-only transcript is
not a failure any test would show — it is a place the user's next keystroke lands.

What *is* narrowed is the case where nothing was inserted at all. The property is lost
only where text is inserted, since an insertion carries no properties of its own, so a
drain that changed no characters can only have moved the boundary — and then the work
is the strip between the old boundary and the new one. `buffer-chars-modified-tick` is
what says a drain changed no characters, and it says it about *every* writer rather
than about the ones this file knows of.

Measured, the sweep over an already-protected 50×200 screen costs one to thirteen
microseconds depending on how many face runs it walks. The cost that matters is the
cold part — the text the drain actually wrote — and that has to be paid wherever it is
paid from.

---

## `cooked--apply`: the order is the algorithm

Every step depends on the one above it.

1. **Resources before rows.** `:images` and `:links` are the drain's third category —
   neither a level redisplay reads nor an occurrence to react to, but a resource the
   rows of this very drain refer to by id.
2. **Viewport before render.** Everything `cooked--capture-viewport` reads is destroyed
   by the render: the pending input is lifted out, the rows point and the mark name are
   deleted and reinserted, and which windows counted as following has already been
   decided by the deletion dragging their point along.
3. **Render before marks.** A mark's anchor resolves against text that has to be in the
   buffer before it can be pointed at.
4. **Marks before events.** A drain that both resizes and carries a fresh mark should
   end with the fresh mark's own anchor, not with the correction to the older one.
5. **Region shaped before anything measures it.**

`let*` rather than `let` is load-bearing: the initialisers delete and insert, and under
`let` they would run before `inhibit-read-only` and `buffer-undo-list` took effect — so
a protected buffer would abort the redisplay half-done from inside the process filter,
and lifting the pending input would land in the undo history.

`buffer-undo-list` survives the buffer switching in the window block because it is
permanently buffer-local: the binding is recorded against this buffer and restored into
it, rather than into whichever buffer happens to be current when it unwinds.

### Why point needs three different rescues

- **`editing`** is an *offset* into the pending input, not a position. The input is taken
  out and put back verbatim around the child's cursor on every drain, so a position
  cannot survive that but an offset can. Without it, anything that drains while the user
  is editing mid-line — a background job printing a line, a completion reply — yanks them
  to the end of what they were typing.
- **`wandered`** is a *screen cell*. A redraw deletes and reinserts whole rows, so a
  buffer position would be dragged to the start of whatever was rebuilt under it.
- **`follow`** asks the mode and where point is, never comparing point against the
  cursor. Output arriving in chunks lets the cursor overtake point for a single drain,
  which strands point at column 0 for every drain after it.

The mark gets no rescue at all, only a question asked in time: there is no cell to
re-find it by, only a claim about text that is about to stop being that text. See
`cooked-clear-selection-on-output`.

---

## `cooked--mark-truncation`: three traps, one column of text

A row that Emacs renders wider than Rust assumed is trimmed (`cooked--guard-row-width`)
and the cut marked. Where the marker goes decides whether it costs the user a column.

**Use the fringe on a graphical frame, and reach it through an overlay.** A fringe
`display` spec shows its bitmap *"instead of the characters that have the display
specification"* (Elisp manual, Other Display Specs), so putting one on a real character
silently costs the row one more character than the trim already did — while the point of
the fringe is that it sits outside the text area and costs nothing. The overlay
evaporates on its own, because `cooked--render-rows` deletes the row before rewriting it.

**Anchor it at the row's start as a `before-string`, never at the cut as an
`after-string`.** A fringe bitmap belongs to the screen line, not to the column it is
anchored in, and the row is one screen line — so either end draws the same picture. But
the string still has to be *placed*, and the trim loop leaves the row as wide as it can:
when the overflow was an exact multiple of the character width, the last cut lands the
row flush with the right edge, with no room for even a zero-width string. Redisplay then
opens a continuation line to put it on, and what you see is a correctly truncated row
followed by an empty second screen line carrying a continuation arrow. `vertical-motion`
does not agree the line takes two rows, so the trim loop cannot see this and another pass
would not cure it. Column zero is never full.

**A terminal frame has no fringe**, so there the marker must cost a column, exactly as
`truncate-lines` spends the last one on `$`.

*Known gap:* a graphical frame whose window has no right fringe (`fringe-mode` 0, or a
side window that gave it up) has nowhere to draw the bitmap, so the marker is invisible.
Emacs has the same problem with its own indicators and solves it per-window; this runs
per row during a drain, for a buffer that can be in several windows with different
fringes, so there is no one answer.

*Related:* `cooked--truncation-bitmap` reads `fringe-indicator-alist` rather than naming
a bitmap, so a user who rebound the indicator sees their own choice. It was
`right-truncation` for a long time, which is not a fringe bitmap and never was —
`truncation` names the *indicator*, `right-arrow` the bitmap it resolves to — so the
marker silently drew nothing at all.

### The window a row is measured in is a fact about the drain

`cooked--guard-row-width` needs `cooked--layout-window` — the narrowest window showing
the buffer, the one every row was written for. It used to ask for it itself, which
meant asking once per rendered row.

That is not the cheap accessor it looks like. `cooked--layout-window` walks
`get-buffer-window-list` and asks `window-max-chars-per-line` of the windows it finds,
and that subr does its measuring inside `with-selected-window` — so the guard was
paying two `select-window` round trips per displayed window per row, at a drain rate
whose floor is 125 Hz. A 50-row repaint was a hundred of them. `select-window` is
advised; the section on `cooked--pin-transcript-bottom` above spends a paragraph
getting rid of exactly this call for exactly this reason, and it had grown back one
level down.

So `cooked--render-rows` computes it once and threads it into the loop, and the guard
takes it as an argument. The multi-window case is answered as it always was, because
the answer cannot change *during* a render: nothing in the loop creates, deletes or
resizes a window, so one narrowest window chosen from one window list is what every
row of that drain would have got anyway. What the row still decides for itself is
everything the marker depends on — `cooked--mark-truncation` reads the frame of the
window it is handed, and the three traps above are untouched.

Two smaller economies came with it, and both are of the same kind — a measurement
taken twice where once would do. `cooked--layout-window` re-measured the incumbent
once per candidate, so the walk was quadratic in the number of windows; it now carries
the incumbent's width, and measures nothing at all until there is a second window to
compare against, which is the ordinary case. And `cooked--row-mismeasured-p` copied
the row out of the buffer twice to ask two questions of it.

### Three questions the guard used to ask per row, and asks no longer

Measured on a 248-column, 45-row pgtk frame, `cooked--guard-row-width` cost 49.5us per
row for ASCII, 113.5us for CJK and 545.0us for box drawing — 2.2ms, 5.1ms and **24.5ms**
per 45-row drain. The last of those is more than a whole 60Hz frame, on the apply path,
and every microsecond of it was spent concluding there was nothing to do: a probe
confirmed that `cooked--row-mismeasured-p` answered `t` for *every* live row on a
graphical frame, after which `cooked--trim-to-one-line` deleted nothing.

Two causes, and the second is the embarrassing one. `string-width` recomputed a number
the core already had. And the `display-graphic-p` arm was the *left* arm of an `or`, so
the check the docstring called "a fast path" made the predicate unconditionally true on
every graphical frame — the slow path, dressed as the fast one.

**The width is carried, not re-derived.** `Run::cols` counts the cells a run stands on as
the run is built, `Block::push_runs` sums it, and the block hands Emacs a WIDTH element
alongside its text. Nothing measures anything to produce it: the grid materialised the
answer when it placed the row's continuation cells, so counting cells *is* reading the
width back, and the count comes off a loop that was walking those cells anyway. The
by-product also settles an equivalence that was previously asserted in a docstring and
checked nowhere: `cooked-carried-row-width-agrees-with-string-width` compares the two
over CJK, combining marks and box drawing on a live drain.

*This is also the seam OSC 66 arrives on.* Under kitty's Text Sizing Protocol the child
*declares* how many cells a run occupies, and a declared width can legitimately disagree
with what a width table says about the same characters. While Emacs asked
`string-width`, a declaration had no route to it at all — Emacs would have kept
answering the Unicode question and disagreeing with the child. It now reads whatever the
grid says, and a declaration is a statement about how many cells to occupy, which is to
say about how many continuation cells to place. Nothing downstream of `Row::cols` needs
to learn a new concept. Nothing implements OSC 66 today.

**A ligature cannot make a monospace row wider, and that is measured.** The
`display-graphic-p` arm existed because a shaper can turn `->` into one glyph that no
per-character metric predicts. It can — but not into a *wider* one, and wider is the only
direction this guard acts on, since softwrapping is what "wider than the grid said"
looks like. Across Noto Sans Mono, Iosevka Fixed SS10, Adwaita Mono and the generic
`monospace`, with 27 ligature sequences (`->`, `=>`, `===`, `www`, `ffi`, …), under
Emacs' default composition and again with ligatures forced on the way ligature.el does
it: 0 of 27 rendered at anything but `frame-char-width` × length, in all eight
combinations. The control, quasi-proportional Iosevka Aile, got 26 of 27 wrong — `=>` at
20px where two cells are 18, `www` at 39px where three are 27 — so the probe is
sensitive to exactly the thing that matters.

Which is a *proportional face*, not a ligature: `buffer-face-mode`, a `:family` on the
default face, a fallback font for a character the primary font lacks. That is the hazard
vterm's README warns about, and it is a per-font question with a per-font answer.
`cooked--ascii-fixed-pitch-p` asks it by measuring — every printable ASCII character
plus the ligature pairs, in each of default, bold, light and italic, the whole of what
`cooked--attr-face-properties` can put a row into — and when it holds, a row the core
flagged as plain ASCII skips the guard outright. No width test, no `vertical-motion`, not
even a memo lookup. ASCII is the overwhelming majority of rows.

**What is left is memoized, because it is a question about a row and not about a
drain.** The residual is the `vertical-motion` probe, which catches what Rust cannot know
— composition, font substitution, and that substitute's metrics. Its answer is a pure
function of the row's text, the window's usable width and the font in force, all three
of which sit still for minutes at a time, while a full-screen program rewrites the same
248-character border 125 times a second and gets it re-measured every time. So
`cooked--wrap-cache` holds, per buffer, a table of rows already seen to fit.

Only the negative is stored, and that asymmetry is the safety argument. A wrong "this
wraps" costs one `vertical-motion` and deletes nothing, because `cooked--trim-to-one-line`
measures again for itself and stops immediately. A wrong "this does not wrap" costs a row
that softwraps until something rewrites it. **The memo cannot delete a character that
should have stayed** — which is the failure this guard exists to prevent, and the reason
it is allowed to trim text by hand at all. Keying on the text alone and letting the
styling out of the key is a decision that rests on that, and on `cooked-face` never
setting a family or a height.

Invalidation is a stamp, not a hook. `cooked--layout-stamp` is five values — window
body width in pixels, `frame-char-width`, `frame-char-height`, the `font` frame
parameter and `face-remapping-alist` — which `cooked--render-rows` reads once per drain
and threads in beside the layout window, for the same reason it threads that in. Width
in pixels rather than in columns, because the column form divides by the character
width, so a font change and a resize can cancel out in it and a fringe or margin change
does not move it at all.

**Four of the five are free and the font is not, and that is why the font arrived
late.** The four are accessors that select no window, half a microsecond apiece.
`(frame-parameter frame 'font)` measures 19–29us on pgtk, because the value is computed
from the frame's font object rather than stored — and on pgtk *every* frame parameter
reads at about 19us, so what is being paid for is `frame-parameter`, not the font. That
was the whole of the case against including it, and it held for exactly as long as the
stamp was built once per row: 20-odd microseconds a row is not a cost this guard may
carry, and the hole it left was cosmetic at worst. Built once per drain it is a single
read against a drain measured at 590us, and the trade turns over. A caller that has not
threaded the stamp in is still answered per row, correctly and slowly; no render takes
that path.

What the font buys is the one move the metrics cannot see. `frame-char-width` and
`frame-char-height` describe a font; they do not name one, so two fonts at the same size
have the same pair of numbers, and a swap between them leaves every row already seen to
fit carrying the outgoing font's verdict until something else moves. If the read ever
does start to matter there is a cheaper identity to hand — `(face-attribute 'default
:font frame)` at 0.20us — and nothing else about the stamp would have to change.

`cooked--rescale-deco` is the other place in the package that reacts to the font moving
and was the obvious thing to hang this off, and it is the wrong shape for it. A
notification only invalidates for the events somebody remembered to connect — a zoom and
a cell-size change reach `cooked--rescale-deco`; a window losing a fringe, gaining a
margin, or being dragged a pixel narrower does not, and all three move where a row
wraps. A stamp cannot miss an event it was not told about. It can only be too
conservative, and too conservative costs one rebuilt hash table. The table is cleared
outright past `cooked-wrap-cache-limit`, which is a bound on a buffer whose every row
is different — a log scrolling past, a file being catted — and not an eviction policy:
there is no ordering here to evict by.

---

## The buffer is a grid, so its paragraph direction is pinned

Three things in cooked assume that the COLth character of a row is at column COL:
`cooked--mouse-cell`, which turns a click's column back into a cell to report to the
child; the ghost cursor, which is placed by column; and `cooked--guard-row-width`, which
asks `vertical-motion` where a row ends.

Emacs' bidi reordering breaks that correspondence, and it decides per paragraph, from
the paragraph's own first strong character. So one line of Hebrew or Arabic in the
output — `ls` in a directory of them, a `git log` of someone's commit messages — flips
the visual order of that row, and all three are then naming a different cell than the
user is pointing at. `cooked-mode` sets `bidi-paragraph-direction` to `left-to-right`
buffer-locally. It costs nothing in the overwhelmingly common case and makes the
correspondence total.

`bidi-display-reordering` is deliberately left alone. Emacs documents it as internal and
not for Lisp to set, and it goes much further than this needs to: the character-level
shaping it also disables is not what is in the way. Pinning the *direction* is a
statement about the text's layout, which is exactly the claim being made.

---

## The alternate screen is a rectangle, not a transcript

One sentence, and the reason behind eight decisions spread across five files. It was
written out at each of them, in each one's own words, which is the expensive kind of
duplication in a tree where the reasoning *is* the artifact: eight places to correct if
the sentence ever changes, and nowhere that states it.

**The primary screen is a transcript Emacs owns.** It grows downward, rows leave the top
and become ordinary buffer text, and what is on screen is the live end of something with
a history behind it.

**The alternate screen is a rectangle the child owns.** It is exactly `height` rows,
always, whether or not the program has drawn on all of them. Nothing scrolls off it,
nothing accumulates, and there is no history behind it — the transcript is still there in
the buffer, but it belongs to the primary screen and the alt screen is drawn over the
same buffer positions the live primary rows occupied.

Everything below follows from that, and none of it is an independent decision:

| Where | What it does | Because |
|---|---|---|
| `cooked--apply-alt-pin` | narrows to the screen region | the rectangle is all there is to look at, and the transcript above it is not the child's |
| `cooked--fit-screen` | extends to `height`, not `used` | a rectangle is exactly that tall even where nothing was drawn; a transcript is trimmed to content |
| `cooked--scroll-windows` | pins to the window top rather than following the bottom | there is no bottom to follow; the whole rectangle is the viewport |
| `cooked--pin-alt-windows` | keeps that pin against the wheel | same, once per command — see the section below |
| `cooked--sticky-header` | renders nothing | a sticky header names the command a scrollback row belongs to, and there is no scrollback |
| `cooked-command-decorations--clear-live` | takes the fringe markers down | they name rows the program is now drawn over |
| `cooked--fontify-region` | declines outright | the guesses are cosmetic passes over text about to be overwritten, and the child very likely holds the mouse |
| `Term::clear_to_prompt` | returns 0 | there is no prompt on it, and no transcript to clear back to |

The one that is *not* on this list is worth naming too. `cooked--render-rows` takes `alt`
as an argument rather than reading `cooked--alt`, because `cooked--apply` adopts the
drain's levels *after* it renders — so during the render the variable still holds the
previous drain's answer. That is an ordering hazard rather than a consequence of the
rectangle, and it is why the frame that restores the primary screen would otherwise be
rendered as though the alt screen were still up. Every other site above runs outside that
window and reads the variable directly.

Reflow is the deliberate exception at the other end: the primary screen and its
scrollback rewrap on a width change, and the alternate screen is clamped instead. Not a
gap — a rewrap re-lays logical lines, and a rectangle has none to re-lay.

---

## `cooked--pin-alt-windows`: why the alt screen needs a continuous invariant

`cooked--apply` pins the alternate screen to the top of its windows at the end of every
drain, and that is not enough: a drain is the child talking, and nothing the *user* does
to a window produces one. A full-screen program idle at its prompt draws nothing, so a
wheel notch — which reaches `mwheel-scroll` whenever the child has not asked for mouse
reports, or has but the keyboard is suspended for a peek — scrolled the picture off the
window and left it there. Run from `post-command-hook`, the pin becomes the continuous
invariant it always meant to be. `eat` states it the same way, in
`eat--synchronize-scroll`.

**Forcing, unlike the drain's pin.** The wheel moves point along with the window, so
NOFORCE would let redisplay honour the point it left behind and scroll straight back.
Point is inside the region either way — the restriction is what makes that true.

**The vscroll goes with the start.** `pixel-scroll-precision-mode` moves a window by
whole lines and carries the remainder as a pixel offset, which survives being told where
the window starts. Pinning the start alone leaves the top row shaved by however far the
last event scrolled, and the offset grows event by event until it crosses a line and the
start jerks back. That, and not the pinning, is what a rubber band would be made of.

**One hook, where there were two.** The pin also ran from `pre-redisplay-functions`,
which named the window about to be drawn and so caught two things `post-command-hook`
cannot: a notch over a window the user has not selected — `mouse-wheel-follow-mouse` is
on by default, so that command begins and ends in another buffer, where the local hook is
not installed — and the frames of `pixel-scroll-precision-interpolate`, which scrolls and
redisplays a dozen times inside the one command.

It was removed anyway, because of what a pin costs where that hook runs it. A pin calls
`set-window-start`, and `Fset_window_start` clears `w->window_end_valid` unconditionally
(`window.c`, the Bug#15957 line), which is the flag `redisplay_window` reads into
`current_matrix_up_to_date_p` — so the window loses `try_cursor_movement` and
`try_window_id` and is laid out from scratch. Calling it *from inside* redisplay is worse
than paying that once: redisplay is entitled to start over for the move the pin just
made, which is what the old `cooked--pinning` re-entry guard existed to survive. And the
hook fired once per window per redisplay rather than once per event that could have moved
a window — so the cost scaled with how often the buffer was drawn rather than with how
often anything actually scrolled.

That asymmetry is what made the *selected* window cost about twice as much to draw as the
same window unselected: the pin only does work when the start has drifted, point is what
drags it, and point tracks the child's cursor only in the window that is selected.
Measured on one scroll through a full-screen program — `memory-report`'s profile of the
same gesture, focused: 202MB allocated under `redisplay_internal` with the hook, 28.7MB
without, and the focused/unfocused difference gone rather than merely smaller.
`vterm` never pins at all — point plus
`scroll-conservatively` 101 and `scroll-margin` 0, and a wheel notch scrolls the picture
away for good — and `eat` pins only from its own update and input paths, never from
redisplay. Neither of them runs anything on `pre-redisplay-functions`.

**The wheel is claimed rather than repaired.** Both cases the second hook caught are
wheel cases, and the alternate screen has an answer to them that no hook does:
`cooked--apply-alt-pin` narrows the buffer to exactly the rectangle the child is drawing,
so a notch there has nowhere to scroll *to*. `cooked--wheel-map` binds the four wheel
events for as long as that restriction stands and the child has not already claimed the
mouse, and `cooked-mouse-event` swallows them. Nothing scrolls, so nothing has to be
scrolled back — no slide, no snap, and no dependence on which buffer the command ended
in. `eat` has no such option: it binds the wheel only through
`eat--mouse-modifier-click-mode`, which is on when the child asked for mouse tracking,
exactly the condition `cooked--mouse-grab` uses — and it pays for that by leaving an idle
full-screen program scrolled away until its next output.

The restriction, and not `cooked--alt`, is the gate — in the keymap and in the pin alike.
A deliberate `widen` inside a peek is how the transcript behind a running program is read,
and at that moment there *is* somewhere to scroll to: the wheel goes back to Emacs and the
pin stops fighting it, both from one question, `cooked--screen-restricted-p`.

What remains uncovered is a notch that lands in another buffer while the wheel is not
cooked's, which now means a widened peek — where scrolling is the thing the user asked
for.

The alt screen's other half is `cooked--pin-alt-screen`, inside the drain, which repairs
a different thing: a resize reaches the buffer in two steps — the window changes height
the instant Emacs notices, while the buffer is not re-fitted until the next drain's
`cooked--fit-screen`. Ordinary redisplay fills that gap by pushing `window-start` down to
keep point on screen, and nothing corrected that once the buffer caught up.

---

## `cooked--pin-transcript-bottom`: monotone follow, not a two-way pin

The transcript's pin is the alt screen's opposite number and wants the opposite
discipline. The alt screen has a fixed anchor — the top of the screen region, which moves
only when the region does — so pinning it unconditionally on every drain is a no-op
whenever nothing changed. The transcript's anchor is the buffer's *end*, and that moves
under it: `cooked--fit-screen` trims the region to the number of rows the grid says are
used, so a child that draws a short screen and then a tall one moves `point-max` back and
forth between drains. Pinning a moving target to the foot of the window at a drain rate
whose floor is `cooked-min-redisplay-interval` — 125 Hz — is the whole of the jitter this
used to have.

So the follow is **monotone**: `window-start` is computed rather than recentred to, and
only ever moves *down*. A steady stream whose tail is the same length computes the start
the window already has and writes nothing, which is the common case; a tail that grew
scrolls; a tail that shrank moves nothing except under the guard below. Two-way motion at
drain rate becomes one-way motion when the child actually printed something, and there is
no second drain to undo it.

**Not `recenter`.** `recenter` sets a *forced* start, which redisplay is then free to
overrule through `make-cursor-line-fully-visible` — so the window landed where neither
had chosen. It also counts every screen line as the default font's height, which is a lie
on a row carrying an image slice or a Nerd Font prompt separator, and the correction for
that was a second pass paying for a few pixels of overflow with a whole screen line of
scroll, up to three times per window per drain. That pass is gone: pixels are
`make-cursor-line-fully-visible`'s business and always were, and it does the job after the
fact rather than by guessing ahead of it. The start is set NOFORCE, so it is a suggestion
redisplay may settle against instead of an instruction it will contradict.

Nor `with-selected-window`. Nothing in the pin needs a selected window, and
`select-window` is advised — see `cooked--sync-cursor-type` — so a pair of them per window
per drain was arbitrary code running in the middle of a render. vterm makes the same
distinction from the other side: it recenters only the selected window, and gives the rest
`set_window_point` and `scroll-conservatively`.

**The shrink direction, kept but rationed.** A pin that only ever scrolls down would leave
blank space under the last line when the tail gets shorter, which is exactly what
`comint-scroll-show-maximum-output` exists to prevent. So the upward correction is still
made — but only when the *last* redisplay had the buffer's end on screen, which is what
tells a grid that really has fewer used rows from `vertical-motion`'s whole-line count
merely disagreeing with what redisplay laid out in pixels. The second is permanent on a
window whose rows differ in height, and correcting for it once per drain is the
oscillation itself.

**`scroll-margin` and `hscroll-margin` are zeroed** in `cooked-mode`, as eat and vterm
both do. A terminal's viewport is the whole window: the child decides what is on the
bottom row and there is nothing below it to hold in reserve, so a user's margin only puts
redisplay in disagreement with the start the pin just computed.

---

## `cooked-row-rendered-functions`: why the bounds arrive late

The hook is called at the end of the drain, from `cooked--notify-rows-rendered`, rather
than from `cooked--render-rows` as each row is written. That delay is the difference
between a marker that means what it says and one that does not.

A drain that evicts rows inserts their text above the live screen, which pushes every
marker below it forward by exactly what was inserted — a whole row. So in the window
between that insertion and `cooked--relocate-marks`, every semantic mark on the screen
names the row *below* the one it belongs to. Rendering happens inside that window.

A layer painting from a mark while being called there painted the row below, once per
scroll; and because the correction that followed moved the marker and not the paint, the
mistake stuck. See `cooked-command-decorations--rearm`, the layer this was written for.

BEG and END are still exact: nothing between the render and the notification inserts or
deletes text.

The hook exists for decorations that must be *re-applied* rather than persisted. A
damaged row is deleted before it is rewritten, so anything anchored to its characters
dies with it — a text property outright, an overlay with `evaporate t` the moment its
span empties — and a row can be damaged long after whatever decorated it ran. A resize
damages every live row at once, which is the path that makes this more than theoretical.

`cooked--fontify-links` is the same shape one level down and needs no hook, links being
cooked's own business. This exists for the optional layers, which cannot reach into the
render path themselves.

---

## The running command's marker: a third state, not a third answer

`cooked-command-decorations` marks the command that is running right now as well as the
ones that have finished. Three states is where terminals with this feature land — VS
Code's `terminalCommandDecoration` has `successBackground`, `errorBackground` and a
`defaultBackground` for the command with no exit code yet; iTerm2 paints only the two,
blue turning red on failure — and the interesting part is the *colour* of the third.

It is dim (`shadow`), not an orange. Success and failure are the two answers to one
question, and a command that is still running has not answered it. A warning colour
would put a third answer on that axis, and in most themes would say something worse than
"unfinished". Dim also keeps the loud markers loud: on a screen full of prompts the one
that should catch the eye is the failure.

**No record exists while a command runs**, which is why this is not simply a third
branch in the paint. `cooked--commands` holds finished commands, and a `cooked-command`
is built at the `D` mark because that is what supplies its exit code. Pushing a half-built
one would give it `code` 0 — indistinguishable from success to every reader of that field,
which is the worst wrong answer available. So the running marker is a single buffer-local
overlay outside the weak table, keyed on nothing, and `cooked--running-anchor` is what
says where it goes. One command runs at a time, so a singleton is the honest shape.

**It is derived, not maintained.** `cooked-command-decorations--sync-running` puts it up
or takes it down from `cooked--running-anchor` on every render, so no code path has to
remember to clean up after itself: a `D` whose `C` was lost, an alt screen coming up
under it, a drain dragging the overlay off its row all correct themselves at the next
drain. The handover at the `D` mark is the one thing done eagerly, because both markers
want the same row and the exit code is what the finished colour is read from.

*Related:* the "already right" test in `cooked-command-decorations--place` names the face
as well as the span. It used to name the span alone, which was sufficient while the only
way a marker changed was moving; a marker repainted in place, in a new colour, would
otherwise have stayed grey for the rest of the session.

---

## `cooked--sync-cursor-type`: why it runs last, twice

`evil` advises `select-window` to refresh its own cursor, and refreshes it again from
`window-configuration-change-hook` and on every state change. The render used to select
windows in order to `recenter` them; `cooked--pin-transcript-bottom` no longer selects
anything, so that door is shut, but the other two are still open and the ordering earns
its keep on them. Setting `cursor-type` any earlier in the drain lets evil get the last
word inside the very drain that hid the cursor — and because this writes only on a
change, the next drain computes the same value, skips the write, and never repairs it.
The visible result was a cursor jumping around a progress bar the child had asked to
draw without one.

The second call, from `post-command-hook`, covers a state change that produced no output:
without it nothing would put a cursor back until the child next drew something.

The two overrides on "honour a hidden cursor" are both cases where point is the only
cursor there is. The first is the user having stepped out, which the mode alone answers.
The second is Emacs editing the line, and `cooked--input-state-p` alone is too wide to
say so: `cooked--policy` answers `cooked` the moment termios says canonical, and that
beats an OSC 133 `output` mark. `brew upgrade` hides the cursor and repaints progress
bars without ever leaving canonical mode, and so does anything else run from a shell that
does not put the tty in raw mode. Under a shell that sends OSC 133 we know which of the
two it is, and while a command is *running* the child's `CSI ?25l` is about the picture
it is painting and is honoured.

---

## The base layer, and why anything sits *below* cooked.el

`cooked.el` requires `cooked-face.el`, `cooked-deco.el`, `cooked-link.el` and
`cooked-command.el`, so none of them can require it back — which is why `cooked-util.el`
exists. It holds the customization group, the session handle, the seam runners, and the
macros the layers above reach for often enough that open-coding them was how they
drifted apart.

`cooked-command.el` is the one whose placement is worth stating, because it looks wrong:
almost all of its readers are in `cooked-mode.el`, one level *above* `cooked.el`, so
that is where it seems to belong. It sits below instead, and the test is what it
depends on rather than who depends on it — nothing in it reaches for anything above it,
so the drain can call `cooked--mark-command-end` and `cooked--running-anchor` directly.
Placed in the middle it would have needed four `declare-function`s pointing back down
into `cooked.el`, and the rule that block states about itself is that it carries
notifications upward, never questions.

`cooked-render.el` is the same test read the other way, and lands on the other side.
The redisplay pipeline — `cooked--drain-and-apply`, `cooked--apply` and the viewport
around it — reads `cooked--grid`, the input region, the marks and the screen region, and
calls down into the renderers, the decorations, the links and the OSC handlers. Nothing
below it needs anything it defines, so it sits *above* `cooked.el` and is required by
`cooked-mode.el`, exactly as `cooked-keys.el` is. `cooked-scrollback.el` sits between the
two: the drain calls it, it calls nothing in the drain but the repaint
`cooked-clear-scrollback` owes. What crosses back down into `cooked.el` is one
declaration, `cooked--on-wake` — the wake pipe's filter is installed by `cooked--start`,
because the pipe is part of spawning a child, and the filter's body is a notification
handed to the pipeline rather than a question put to it.

The one coupling that crosses the other way is a cache: `cooked--flush-face-cache` has
to drop decoration specs that were coloured against the outgoing theme, and cannot name
them from below. `cooked-theme-change-hook` is how the upper layer says so instead.

## `cooked-osc-eval-request`: why the verbs are a closed set

The command channel started as vterm's: a name off the wire, looked up in an alist, and
applied to the arguments that came with it. The allowlist was the whole defence, and it
was described that way.

It is the wrong shape, and the failure is instructive because the allowlist does exactly
what it claims. It settles *which* function runs. It says nothing about what that
function is pointed at, and for the entry everybody wants — `find-file` — the argument is
the whole of the danger: `/ssh:attacker.example:/etc/motd` is not a file to read, it is a
connection to a host the sender chose, opened by running that method's transport program.
`/sudo::` is the same move without leaving the machine. A list of approved *names* cannot
express "and only local ones", so every entry that takes a path needed a wrapper, and the
allowlist's own documentation had to warn that adding the obvious thing undoes it.

So the verbs are fixed instead. `F`, `O`, `D`, `K`, each cooked's own code, each checking
its own argument, and no string the child sends is ever resolved to a function. eat
arrived at the same answer from the other direction and its verb set is closed too; vterm
still ships the open one, enabled by default.

Two things fell out of it that were not the goal.

**Quoting disappeared.** Every verb takes at most one argument, so the argument is the
rest of the payload verbatim — no escaping, no `split-string-and-unquote`, and a path with
a `;` or a `"` in it just arrives. The old format needed rules for all three.

**Deny-by-default became free.** `cooked-eval-commands` governs only the `!` escape hatch
now, and defaults to empty. That was unaffordable while it was the mechanism: `find-file`
was the entire point of the channel, so an empty default meant a feature that did nothing
until configured, and everyone would have pasted the same list back in. Giving the common
cases verbs is what let the open-ended part start closed.

The cost is that a new capability is a code change rather than a line of config, which is
the trade eat makes and vterm does not. `!` is there for when that is the wrong answer.

### The bug class, not the bug

Fixing the channel did not fix the class. Anything that turns terminal bytes into a file
name has the same exposure, and the worst instance was not in the channel at all:
`cooked--set-directory` took a TRAMP name out of an OSC 7 URL and called `file-directory-p`
on it — and OSC 7 is always on, with no `require` in front of it. It was also upstream of
`cooked-file-link`, which resolves what it finds against `default-directory`, so one
poisoned value would have turned every settled batch of scrollback into remote stats.

That is why the guard is `cooked--local-name` in `cooked-util.el` rather than a wrapper in
the layer: two handlers need it, one of them is core, and the check has to happen *before*
`file-exists-p` or `file-directory-p` rather than after, because those calls are what
dispatch to the TRAMP handler. Asking whether the file is there is already the connection.

---

## `cooked--sync-color-scheme`: the terminal does not know the theme

A child asks `CSI ? 996 n` and is told dark or light; with DEC mode 2031 set it is told
again, unasked, whenever the answer changes. Neither is a question the emulator can
answer. The scheme resolves against the buffer's `default` face under whatever theme is
loaded, which is Emacs' business entirely — so the core holds a value Emacs reported, the
way it holds the cell size for `CSI 14t`, and the query is answered where it arrives
rather than by waking Lisp to ask about something it already said. Unreported, both are
answered with silence: an absence, not a claim. The colour scheme has the stronger case,
since the protocol has a number for dark and a number for light and none for "not yet".

**The push returns bytes instead of riding the drain.** Every other reply the core makes
is an `Event::Reply` collected at drain time, which works because a reply is provoked by
input and input is what runs a drain. A theme change is provoked by nothing the child did
and produces no child output at all, so no drain is coming: a subscribed nvim sitting idle
would learn about the new theme when the user next typed, which is the one moment the
notification was supposed to save. Nor does the core write the bytes itself. That path —
`reply_osc`'s — signals on a write error, which is correct for a query a child is blocking
on and wrong here, where this runs from a global hook over every session and a child that
exited a moment ago is an ordinary race. `cooked--send-if-live` already states that
policy, and the `996` answer leaves through it too: one report, one route, one error
policy.

**Field placement is what makes RIS mean the right thing.** The subscription is a mode the
child negotiated, so it sits on `Modes` and `Modes::default()` clears it — DECSTR and RIS
are defined as putting negotiated state back to power-on, and a subscription is exactly
that. The scheme is not negotiated: it is Emacs' report about its own theme, which a soft
reset has no business forgetting, so it sits on `State` beside `metrics`. Split the other
way, a child that soft-reset itself would be told nothing about a theme that had not
changed, and would have to ask again to find out what it already knew.

**The multi-frame gap, and why it is not patched here.** `cooked--default-color` reads the
`default` face and falls back to the selected frame's parameters, so a buffer displayed on
two frames with different backgrounds has one answer and it belongs to whichever frame
happened to be selected. That is a real limitation and the fix is not at the 997 site: a
rule applied to the colour scheme alone is precisely how the two reports come to disagree,
which is the failure this whole design is arranged to prevent. It belongs one level down,
in `cooked--default-color`, where it would improve OSC 10, 11 and 12 at the same time —
and it is its own change.

**A leaked subscription types at your prompt.** A TUI that sets 2031 and dies without
resetting it leaves the mode set, and the next theme flip sends `^[[?997;1n` to whatever
holds the terminal now — an ordinary shell, which will show it as typed input. Every
terminal implementing this has the same exposure, because nothing in the protocol says who
the subscription belonged to. Two cooked-only mitigations were considered and declined.
Gating the push on the input-ownership policy (`cooked--policy`) would silence the report
whenever the shell owns the keyboard, which is also when a shell that subscribed on its
own behalf is entitled to it. Clearing the mode at the OSC 133 `D` mark is the tighter
rule — a command has ended, so its subscription has too — and fails the same way: a shell
that subscribed for itself would lose it after every command it ran.

---

## `cooked-shell-integration`: why injection stops being the default

cooked currently generates startup files and points the shell at them —
`cooked--write-zsh-startup` builds a whole `ZDOTDIR` (all four startup files, because
zsh reads `.zshenv` from there too and a lone `.zshrc` would silently skip the user's
own), bash gets `--rcfile`, fish gets `-C`. It works, and it is the reason a fresh
`M-x cooked` behaves the way the README describes.

It is still the wrong default, and the argument is not about taste.

**The unmarked state is permanent and routine, not a first-run wart.** Every `ssh`,
every `sudo -i`, every `docker exec`, every nested `zsh -f` lands there, forever,
regardless of what is configured locally. Injection fixes exactly one host — the one
where configuring it by hand would have been easiest — and leaves every other one
degraded. The result is the worst available mental model: cooked is excellent locally
and inexplicably worse the moment you go remote, with nothing on screen explaining the
difference.

**Opt-in is composable; injection is not.** A generated `ZDOTDIR` cannot cross an ssh.
A line in a `.zshrc` can, and the same file works at both ends, which turns "remote
sessions are degraded" from a property of the design into a thing the user can fix by
installing the snippet where they want it. That is also the only way level 2 is
reachable remotely at all.

**Injection hides the path it most needs exercised.** `cooked-raw-exceptions` exists
precisely for "a shell session without cooked's OSC 133 integration wired up," and its
docstring says so. Making that path the local default means it is exercised where it can
be debugged, rather than only where it cannot.

The cost is the first run: a new user gets level 0 until they read far enough. That is
what vterm does and nobody calls vterm broken — but it is only acceptable if the level
is visible, which is why the mode-line work is a prerequisite for flipping the default
rather than a follow-up.

### What stays

The injection machinery does not get deleted; it moves behind the flag. It works, and
the test suite leans on the generated `ZDOTDIR` to get hermetic shells — without it
every zsh test would run the developer's own prompt and whatever `vcs_info` precmd came
with it.

The zsh snippet keeps earning its place even when sourced by hand, because two of the
things in it are exactly the ones a hand-written config gets wrong and then does not
notice:

- **`__cooked_first_precmd`.** `$?` in a late `precmd` is the *previous hook's* status,
  not the command's. A theme registering its own hook first is enough to make every
  reported exit code zero, and nothing says so.
- **the `PS1` re-append.** powerlevel10k, starship and most oh-my-zsh themes rebuild
  `PS1` from their own `precmd`, dropping a marker appended once at source time. Losing
  `133;B` costs the whole input-region feature, so it is re-appended every prompt from a
  hook that keeps itself last.

Shipping those is worth more than shipping the `find_file` helpers.

### The split

The snippet divides along the line the levels already draw:

- **Core** (`cooked.zsh`) — `133` A/B/C/D, OSC 7, *and the `OSC 51;CH` announcement*.
  This is what the tiers are keyed on, and the only thing a remote host is asked to
  source. The announcement is here rather than with the capture because it is an
  ownership signal that happens to be reused as a completion token, not the other way
  round: put it in the optional half and the recommended setup yields level 1, which
  is worse than the injection it replaced.
- **The capture** (`cooked-completion.zsh`) — the `compadd` shadow, the widget and its
  bindkeys. A separate file to source, because of what it costs rather than what it is:
  every completion in that shell then runs through a shell function, and zsh has no
  tidy way back. Nothing in it is a *preference*, though — it is the shell half of a
  wire protocol — so it ships as a file rather than as something to paste.
- **The helpers** (`docs/SHELL.md`) — `find_file` and the other closed verbs, `osc_copy`,
  and `cooked_send` for the allowlisted ones. In the snippet but off by default, behind
  `eval-helpers`, because what they reach is your editor rather than your prompt. What
  is *not* there is anything aliased over a real command name: which editor client
  `find_file` should prefer and whether `magit` may shadow a real binary are choices,
  and `cooked_send` exists so making them is one line in your rc. They are also
  local-only by construction — the verbs carry paths and Emacs resolves them with no
  idea the shell is elsewhere — which is a second reason they are not part of what goes
  on the far end of an ssh.

Two things fall out. `magit` shadowing a real command name, and `osc_copy` reaching the
kill ring from the far end of an ssh, read very differently as "cooked put this in your
shell" than as "I put this in my zshrc" — the OSC 51 surface is exactly the part that
should be chosen rather than inherited. And `COOKED_COMPLETION` disappears: it exists
only because injection had to decide at spawn time whether to install the capture, could
not revisit it, and needed a paragraph of apology in `cooked--shell-invocation` saying
so. When the user sources the extras themselves the decision is theirs at their own
source time, and the per-prompt announcement is already the entire handshake — Emacs
asks nothing until it sees one.

`fish` stops being a special case for free, which is the right outcome for a snippet
that has never been run against a real fish.

### Standing down cleanly

`COOKED_INTEGRATION_LOADED` already makes a second source a no-op, so a user who sources
the snippet from their own `.zshrc` gets it at their chosen point and the flag-enabled
stub costs nothing. That is true today and merely undocumented.

No new variable is needed for the guard. `TERM_PROGRAM=cooked` is already exported and
was already the conventional answer, so the line is
`[[ $TERM_PROGRAM == cooked ]] && source …` and the snippet repeats the same test as
its own first line — it now runs in every shell the user starts, including ones cooked
has never seen. Getting `TERM_PROGRAM` across an ssh is `SendEnv`/`AcceptEnv`. cooked
deliberately does *not* fall back to sniffing `$TERM`, which would survive by itself:
inventing a second detection path to paper over a configuration the user can make is
the same guessing this whole section is removing.

---

## `cooked--policy`: what each signal buys, and what it does not

cooked reads two signals, and the temptation is to treat them as one confidence score —
more signal, more features. They answer different questions, they are lost under
different conditions, and conflating them is what produces the failure this section
exists to rule out: a prompt where Emacs owns the line and cannot complete it.

**The termios state answers "is a line editor reading, right now?"** It is a fact about
the child, read from the master with `tcgetattr`, and it cannot be forged by output. It
is also the signal that vanishes first: run `ssh host` and the local ssh client puts
that pty in raw mode for the whole session, so what the *remote* shell is doing is
invisible. Not degraded — absent. The same is true of anything else that holds a raw
tty and speaks a protocol through it.

**The OSC 133 marks answer "where does each command begin and end?"** They are bytes in
the output stream, so they cross an ssh unchanged, and a remote shell with the snippet
installed reports its prompts as faithfully as a local one. What they cannot do is
corroborate themselves: a `133;B` is a claim, and after it arrives nothing says the
remote is still at a prompt rather than three seconds into a program that emitted no
mark.

**The completion announcement (`OSC 51;CH`) answers "is a widget bound and ready?"** It
is re-emitted at every prompt by `__cooked_complete_announce`, which makes it the one
signal that is both byte-transparent *and* self-corroborating: the shell is asserting
its own state, per prompt, rather than us inferring it. That combination is why it does
more work below than its name suggests.

### The levels

The level is derived per prompt, never configured, and it moves under you on purpose —
`ssh` drops 2 to 1, a nested `zsh -f` drops to 0, coming back restores it.

| Level | Signals | Input line | TAB | Status |
|---|---|---|---|---|
| **0** | none | shell | forwarded | works today |
| **1** | marks only | shell | forwarded | forwarding works; the ownership rule is new |
| **1.5** | marks + termios | Emacs | `completion-at-point`, native table | to build |
| **2** | marks + announcement | Emacs | `completion-at-point`, `OSC 51;C` | works today |

Level 1 is the one behaviour change in the table. Today "an explicit mark always beats
the inferred termios state" is unqualified, so a `133;B` arriving from a remote shell
hands Emacs the line on the strength of a claim nothing corroborates — which is the
state that produces a local-filesystem completion table for a remote host. Level 1 is
that rule given its missing qualifier.

Levels 0 and 1 need no code, and that is the point rather than an accident: `TAB` is not
in `cooked-raw-exceptions`, so it already forwards, and a shell that owns its own line
completes it with its own compsys. Level 1 is level 0 plus structure — extents, exit
codes, `next-error`, rerun, all of which come from A/C/D and none of which need the
keyboard.

### Two licenses for owning the input line

Emacs may own the line when *either* holds:

- **The child is ours** — the shell is on this machine, so the pty is one Emacs
  spawned and can sample, termios bounds what a mark can be wrong about, and every
  local path the line might name is really there. In practice this is the OSC 7 host,
  which arrives from the same snippet as the mark and is therefore present exactly
  when the mark is. Reading termios directly does *not* work here and is worth saying
  plainly: zsh holds the tty raw for ZLE, so a shell prompt never shows a canonical
  line discipline, and a rule keyed on that would take the editable line away locally
  too.
- **a live announcement** — the shell said this prompt has a widget bound, whatever
  host it is on.

Marks alone are not a license. That is the rule the rest of this section defends, and it
is what makes level 1 a real tier instead of a broken level 2.

The announcement is deliberately allowed to grant ownership *over ssh*, which looks like
a loophole and is not. Everything level 2 needs is byte-level — the nonce, the request,
the `OSC 51;CR` answer — so a remote host running the full snippet genuinely reaches
level 2, and refusing it on the grounds that "ssh means decay" would leave working
capability on the floor. What ssh costs is termios, and termios is an ownership signal,
not a completion one. Keying the decay to the transport confuses the two.

### Why TAB cannot simply be forwarded once Emacs owns the line

This is the constraint that generates everything above. When Emacs owns the line, the
keystrokes never reached the child, so ZLE's buffer is *empty*: forwarding `TAB` asks
the shell to complete the empty string, and zsh helpfully offers every command on PATH.
The shell cannot complete a line it has never seen.

So at any level where Emacs owns the line, completion must either be answered in Emacs
or the line must be handed over first. There is no third option, and no amount of
signal-strength reasoning produces one.

### Delegation is one primitive, not a completion feature

Handing the line over is: drop ownership, write the full line into the pty, send `\e[D`
once per character between point and end-of-line, then send the key. Ownership is
dropped *first*, or the line renders twice — once from Emacs and once from the shell's
echo.

Nothing in that is specific to `TAB`. Send `C-r` and you get fzf or atuin; send `\e[A`
and you get the shell's own history. So the thing to implement is `cooked-delegate-key`
plus a customizable set of keys that route to it, not a completion fallback that happens
to be reusable.

The whole line is sent rather than the text up to point. Sending the prefix alone would
silently truncate whatever followed the cursor, and the left-arrows that avoid it cost
nothing.

**Delegation is licensed by the same signals as ownership**, which is the reason it is
safe: writing a user's line into a pty is only defensible if something is known to be
reading it as a line. At level 1.5 termios bounds that. Remotely, nothing would, which
is precisely why level 1 does not own the line and therefore never needs to give it
back.

### Why history matters more here than completion

Completion has a channel; history does not, and no plausible one is designed. The Emacs
side is `comint-input-ring`, fed only by `cooked--history-record` from what was typed in
*this buffer*, so it starts empty every session and knows nothing of `share_history`,
`zsh-histdb`, or atuin's sync.

Owning the line means reimplementing the line editor, and the bill is larger than TAB:
autosuggestions, syntax highlighting, vi-mode, and every `bindkey` the user has
accumulated all go quiet. Delegation is the only mechanism that returns any of it, and
it returns whatever they configured without cooked having to know what that is.

### The one-way door, and what closes it

A delegated line stays with the shell until Enter. It is not frozen — ZLE is a line
editor, so `C-a`, `C-w` and the arrows all still work — but Emacs editing is gone for
the remainder of that line, which is exactly vterm's normal state.

For history that barely registers: the flow is search, accept, Enter. For `TAB` it is
worse, because you are mid-edit. Hence the default split — `TAB` stays
`completion-at-point` at every level, and delegation gets its own key, so losing the
input region is never a side effect of the key pressed fifty times an hour. Keeping
`TAB`'s meaning stable across levels is the same principle as never toggling a mode: the
tier changes what is available underneath, not what the keys mean.

What closes the door is reading the line back off the grid — cooked is the emulator, so
after the shell settles the completed line is sitting in its own cells between the
prompt mark and end of line. That restores ownership and makes the round trip invisible.
It is deferred rather than dismissed: the hard parts are deciding when the shell has
settled, wrapped and multi-line prompts, `RPROMPT`, and autosuggestions appending text
that is not the user's. Building the one-way door first gives it a safe failure mode —
a scrape that does not converge leaves you in the delegated state rather than with a
corrupted line.

### Consequences worth stating

- **The Emacs table lies over ssh.** `cooked--native-completion` offers local
  `exec-path` and local file names, which is honest at level 1.5 (local by construction)
  and wrong for a shell on another host. OSC 7 already carries `file://${HOST}${PWD}`;
  when `HOST` is not this machine, the file and PATH tables should decline rather than
  guess. This is worth fixing independently of everything else here.
- **The level must be legible.** Done. `cooked--mode-line` used to show `" raw"` for both
  "you are in htop" and "you are at an unmarked shell," which are one policy and two
  situations; and a level that moves when you ssh has to say so, or the difference reads
  as cooked being unreliable across hosts. Both are now said. `cooked--policy` tells five
  states apart and the indicator spells all five — `prompt` and `run` were the two hiding
  inside `raw` — `@host` prefixes a session the child says is elsewhere, and the
  foreground process group names the running program in exactly the unmarked session where
  there is no title to have. That last one is what separates the two situations above, and
  it needed no new signal: `cooked--foreground-program` was already there for the key
  overrides.
- **bash was the largest level-1.5 population, and it was the shortest-lived.**
  `cooked-completion.bash` answers over the same `OSC 51;C` framing with none of zsh's
  ZLE gymnastics — `complete -p` names the registered function and it can be invoked
  directly — so bash is level 2 as well. The one place bash is weaker: it has no
  `zle-line-init`, so the announcement goes out from `PROMPT_COMMAND`, before readline
  has taken the terminal. The gap closes before it matters, since Emacs sends nothing
  until the user asks to complete, but it is a gap rather than an impossibility.

---

## Images have one owner, and it is Emacs

An image's bytes cross the boundary once and live in `cooked--image-data`, a strong
buffer-local table. `ImageStore` in `src/emu/image.rs` keeps no payload: a geometry and a
128-bit digest per image, so that a child redrawing the same picture every frame
transmits it every frame and it crosses once. Two caches with two eviction policies is
what this replaced, and the way it failed is worth keeping written down.

`viu -w 40` on a 34-frame gif drew about twenty frames, then nothing at all until the gif
looped, forever, in an exactly periodic cycle. The placements were perfect and the cursor
was perfect; only the picture was missing. Ids are content-addressed, so on the second
loop the module recognised each frame and answered "you already have this one, it is id
N" — from its own ledger of 4096 entries. Emacs' cap is in bytes, and 64MB of
three-megabyte RGBA frames is twenty-one of them, so Emacs had thrown id N away twenty
frames ago. `cooked--image-spec` answers nil for an id with no data, so the cells carried
a `cooked-deco` placement and no `display` property. Neither end was wrong about anything
it could see. They were counting different things, three orders of magnitude apart, and
nothing connected them.

So there is one cache now, and one rule:

> **The module believes Emacs has an image's bytes only if `cooked--image-data` does.**

One direction, not both, and the asymmetry is deliberate: the module's belief is what a
retransmission is answered from, so it is the belief that must never outrun the table.
Emacs holding bytes the module has stopped recognising costs a retransmission; the
module claiming bytes Emacs has thrown away costs a hole, and that is the bug above.

Each side keeps its end without asking the other. The module decides "have you seen these
bytes?" from the digest alone. Emacs never guesses what the module holds — every path that
drops an image goes through `cooked--forget-image`, which calls `cooked--image-forget` and
takes the ledger entry, the digest, the geometry and the client's own name for the picture
with it. A retransmission of forgotten bytes is then a picture the module has never seen:
a fresh id, and the payload crosses again. That is what makes eviction cost a
retransmission instead of a hole.

Five consequences that are easy to get wrong separately:

- **`cooked-image-cache-size` is a backstop again, not the policy.** The policy is
  `cooked--release-images`/`cooked--collect-images`, driven by scrollback discard: an
  image dies with the last row displaying it. That never fires for an animation that
  never scrolls, which is why the cap was doing all the work when this broke.
- **A bare-id kitty placement (`a=p`) of a forgotten image is declined**, with
  `ENOENT:image` — the same answer as for an id never transmitted, because the client's
  remedy is the same one: send the picture again. Retaining payloads *only* so this case
  could be honoured is what put a second cache here in the first place.
- **The cell rectangle belongs to the placement, not to the picture.** Every
  `Placement` carries the `cols`/`rows` it was laid at, and it is repeated on each cell of
  the rectangle. That looks redundant and is the load-bearing part: ids are
  content-addressed, so one picture can be on screen at two sizes at once, and a single
  field against the image is one answer to two questions. `viu` is the case that proves
  it — it never rescales the pixels, sending every frame at full resolution and changing
  only `c=`/`r=` when the window is reshaped, so after a resize *every* frame is bytes the
  module already has and no payload crosses at all. Held against the image, the new
  rectangle reached Emacs by no route whatever and the animation drew at its original
  size, cropped, forever. The store keeps the pixel size and what the child asked for, and
  derives the rectangle per placement against the cell of the moment — so a font change
  needs no repair either, and `Term::set_cell_metrics` no longer drops anything.
- **A frame nobody could have seen does not cross.** Transmitting is not displaying. A
  child can draw far faster than Emacs redisplays, and the frames it drew over in between
  are frames no cell points at by the time a drain happens — so they are shed, and the
  store is told, which is what keeps "tracked iff Emacs has the bytes" true. Emacs'
  redisplay rate therefore sets how many frames cross, with no timer and no configured
  frame rate anywhere: a drain carries whatever is current when it happens. Shedding runs
  at drain time, where it decides what crosses, and again at transmission time once two
  payloads are queued, where it decides how much memory the queue can take. Three things
  count as showing a picture — a cell of either grid, a row scrolled off in this same
  delta, and a client name bound by `i=`, since a later bare `a=p` carries no bytes of its
  own. See `State::shed_unplaced_images`.
- **The digest is the last word on identity.** There is no payload left to compare a hash
  hit against, so `content_hash` is 128 bits wide; `src/emu/mod.rs` carries the argument
  for why that is enough here and why the hyperlink store, whose collisions a hostile
  child could actually profit from, still compares its URIs.

---

## The pace is a floor, not a clock

`cooked-min-redisplay-interval` is the one number in the tree that sets a rate, and the
thing most worth knowing about it is what it *cannot* do: nothing ever draws faster than
it. Every gate in `Notifier::flush` can only push a redraw later. There is no urgent
path, no bypass, no "this one matters, send it now" — the floor is absolute.

**What actually paces a session is Emacs, and the interval is the floor beneath that.**
The core sends one wake byte and then stays quiet until `cooked--ready` says the buffer
has been drawn, so a slow render paces the child by itself. Measured in a live frame,
`cooked--apply` runs 40 times against 91 redisplays while `yes` floods a buffer, and 155
against 215 for a spinner rewriting one line. Renders never outrun redisplays. The
interval is what stops a *fast* render from being asked for a thousand times a second;
it is not what decides the rate in the ordinary case.

Four things delay a redraw, and `flush` consults them in this order:

| Gate | Holds the frame while | Retired by |
|---|---|---|
| `notified` | a wake byte is already in flight | `Session::ready`, i.e. Emacs having drawn |
| `sync_until` | the child is mid-frame under **DEC mode 2026** (`CSI ? 2026 h`) | the child's own `2026 l`, or the deadline |
| `min_interval` | less than one interval has passed since the last wake | the clock |
| `hold(quiescence)` | the child wrote something under 0.5ms ago | the pty going quiet, or `frame_ceiling` |

The mode-2026 gate is a **DEC private mode**, not an OSC — it arrives through `csi.rs`
alongside the other `CSI ?` modes. Worth stating because the child has no OSC by which to
ask for this, and looking for one is a wasted afternoon.

**The one thing that looks like speeding up, and what it actually skips.**
`Notifier::announce` clears `last_read` and `ceiling_at` before flushing, which is the
quiescence gate stood down: a termios change, a full backlog and a child that has exited
are none of them things the child is going to finish writing, so waiting for it to stop
writing would wait forever. The case that earns this is `getpass` turning echo off a
fraction of a millisecond after printing its prompt — a secret read must not sit behind
the rest of an update. But `announce` goes *through* `flush`, so it clears two gates of
the four and passes the throttle like everything else. It never draws early; it only
declines to wait for a frame that is not coming. `sync_until` it does not touch at all —
the backlog-full path clears that separately, with `set_sync(None)`, because a child that
filled the backlog inside one frame would otherwise deadlock against its own blocked
write.

**`poll_wait` is not a speed-up either**, though it reads like one. It shortens the
reader's poll to whatever is left of the throttle window, so a notification deferred by
`min_interval` retires at the interval's own cadence instead of waiting out the coarser
`POLL_TIMEOUT_MS`. That is avoiding an accidental hundred milliseconds, not going faster
than the floor.

**Input is not a case the pace declines to special-case; it is not a category the pace
can see.** `Session::send` is one line — it writes the bytes to the pty and touches
nothing else. Every call into the notifier is on the reader thread or the drain. So a
wheel notch is bytes to the child, and whatever the child writes back arrives on the same
read loop as a build log: input to process, standard pace, process and draw. There is no
input path to give an exception to.

Which is why the mouse wheel appears in `poll_wait` as a *symptom* rather than as an
exception. Scrolling a full-screen program was simply the workload where an accidental
hundred milliseconds on the tail of a burst was noticeable — the throttle deferring a
notification, the child then falling quiet, and nothing waking the loop until the coarse
`POLL_TIMEOUT_MS` tick. That is a bug in the standard path, and it was fixed in the
standard path, for every workload at once.

Nor would an exception buy anything if one were written. The 8ms default is half a 60Hz
frame, so the most it could save is under one frame on any display anyone owns, and it
would fire exactly when a full-screen program is repainting hardest — the one moment the
throttle is earning its keep. What makes typing feel instant is not an exception but the
floor failing to bite where anyone would notice: a keystroke echoed after a quiet moment
passes every gate on the spot, the throttle having long since elapsed and quiescence
being half a millisecond. The interval only constrains a child that is already writing
continuously, which is the case where no single frame is worth anything.

**And the backlog limit is not part of any of this.** `cooked-backlog-limit` sets no rate.
It is backpressure: how much may pile up while Emacs falls behind before `read_loop`
stops taking bytes off the pty, at which point the pty's buffer fills and the child blocks
in its own `write`. One paces, the other pauses. They are tuned together — a longer
interval leaves more to accumulate between drains, so the queue fills sooner — which is
why `Session::set_tuning` takes them in one call, and why it is not called `set_pacing`.

---

## `Deco::packed`: the protocol coalesces so Lisp does not have to

Rust parses at 74–422 MB/s and the Emacs apply path manages roughly 21 MB/s equivalent.
The two halves are not close, and that asymmetry is what decides where a decoration is
allowed to be described. Anything the core knows and does not say, Lisp has to rediscover
— on the slow side, on every damaged row of every frame.

Box drawing is where that bill came due. A 24x80 frame of it cost 9.5 ms/frame against
0.21 ms for the same frame of plain text: 47x, for the character set htop, ranger, fzf
and lazygit are made of. Attribution on that frame put 46% in `cooked--deco-display-value`
— a third of it `cooked--box-phase`, a third `cooked--box-glyph-image`, the rest `pcase`
dispatch — and 23% in the two `put-text-property` calls per character.

Every one of those was asked once per character about a row that is one decision repeated.
The core already knew: a run is homogeneous in its kind, and a border row is eighty copies
of one `BoxGlyph`. It emitted one two-byte record per cell anyway and threw the repetition
away. So the glyph wire format now carries `(bits, count)` per *run of identical shapes*,
and `cooked--apply-glyph-deco` spends it: one image-spec lookup for the run, one
`put-text-property` putting one shared `cooked-deco` record over all of it, and only the
per-character `display` wrapper consed per cell — which must stay a fresh cons, or Emacs
merges the run into a single image. Measured 9.5 → 2.8 ms/frame, a 3.4x cut, with the
plain, styled and URL rows unmoved.

Three things fall out of that, and each is a place where the obvious next step is wrong:

- **No flag for "this shape dithers".** `BoxGlyph` knows, and a spare bit could say so.
  But the only use for the answer is deciding whether the phase can vary down the run,
  and run-length encoding already demotes that question from once per character to once
  per record. `cooked--box-shade-p` keeps asking, and the count field stays a plain `u16`.
  A field that has to mean the same thing on both sides of the boundary forever should buy
  more than one `logand` per eighty cells.

- **Images stay one record per character.** The same compression is available on the wire
  and was declined: every cell of a picture displays its own slice, named by that cell's
  row and column within it, so Lisp must cons a record and set a property per cell
  whatever arrives. Sharing one record across three image cells gives all three
  `(slice 0 0 ...)` where the second needs `(slice 12 0 ...)`, and a rewrap that split
  such a run would leave both halves claiming the same start column. Compressing a wire
  that has to be decompressed again immediately moves nothing off the side that is slow.
  What `cooked--apply-image-deco` hoists instead is the *spec*, which genuinely is one
  thing per placement — and that needed no protocol change at all.

- **Sharing a record made `cooked--rescale-deco` load-bearing.** It walks with
  `next-single-property-change`, which compares with `eq`, so a shared record is one step
  of that walk. That the walk had reached every character was an accident of allocation,
  not a promise, and coalescing would have broken the font tracking silently — the buffer
  simply ceasing to follow a zoom, with nothing to point at.
  `cooked-a-rescale-rebuilds-every-cell-of-a-shared-glyph-run` was written before the
  coalescing landed, for exactly that reason.

The derivation stayed single through all of it, which was the other constraint.
`cooked--deco-display-value` is still the one answer to "what does this decoration look
like", but it is now a composition of `cooked--deco-image` — the part adjacent cells may
share — and `cooked--deco-display` — the part they must not. The render paths call the two
halves, hoisting the first as far as the wire says they may; `cooked--rescale-deco`, which
holds a record and knows nothing about its neighbours, calls the composition. A kind added
to either half reaches all three callers, which is the property that mattered: this was
three separate derivations once, and the rescale one was the easy one to miss.

## A transcript has parts, and three subsystems ask for them in three different words

imenu, outline and bookmarks all want the same thing from a buffer — *what are the parts
of this, and where do they start* — and a transcript has an exact answer that no scan of
its own text could recover. The OSC 133 records in `cooked--commands` already know where
each command was typed, where its output began and ended, and how it went. A regexp over
the text is the alternative, and it is wrong in both directions at once: it misses every
prompt that does not look like the one whose regexp was written, and it claims every line
of output that does. So all three are answered from the records, each as one
buffer-local variable that `cooked-mode` sets and nobody reads until the subsystem that
owns it is used — a session that never calls `imenu` pays for none of it.

`cooked--imenu-index` is flat and in buffer order, with one entry per command and none
per line of output, landing on the prompt rather than on the output because a command
that printed nothing has no output to land in and is very often the one worth finding.
Positions rather than markers, since a marker here is a cost paid by every insertion the
child makes; `imenu-auto-rescan` rebuilds the index instead, which a buffer being
rewritten at 125Hz needs anyway. Repeated command lines get a `uniquify`-shaped suffix,
because imenu resolves the entry the user picked by looking its *name* back up, and five
`make`s under one name are four entries nobody can reach.

`cooked--outline-search` is the `outline-search-function` Emacs 29 added in front of
`outline-regexp` for exactly this case: what makes a line a heading here is not how it
looks but what the shell said about it. Every prompt is a heading and every heading is
level 1 — the transcript is a sequence, not a tree, and a nested level for a command's
output would fold nothing extra, since a heading already hides everything up to the next
one. An empty line is not offered as a heading: that is a real state (the live prompt of
a shell that has not drawn one yet), and an empty heading at `point-max` is one a
forward search finds without moving, which is an infinite loop in every caller that
walks with one. `cooked--outline-cache` memoizes the heading list on
`buffer-chars-modified-tick` and the newest record, because outline asks for the next
heading once per heading it walks past.

### Why `desktop` is deliberately not registered

A cooked buffer visits no file and sets no `desktop-save-buffer`, so it is *already*
absent from a desktop file and cannot break one. Registering is what would create the
hazard, not declining to. What a handler would buy is a restore, and the only restore
worth anything spawns a shell — while desktop restore is bulk, automatic, and sometimes
deferred onto an idle timer, which makes it the one moment where "start eight children
the user did not ask for" is a plausible outcome, possibly minutes after they stopped
thinking about it. The non-spawning alternative, a session-less placeholder buffer, is
litter: nothing turns such a buffer back into a session. The absence is asserted by a
test rather than left implicit, since an absence is the kind of decision a later change
reverses by accident.

### A bookmark is the same capability, chosen one at a time

Which is the shape this belongs in, and it is why the decline above is not a refusal of
the whole idea. `cooked--bookmark-record` records the working directory rather than a
position: the buffer is transient, the child outlives nothing, and by tomorrow the row a
position named has scrolled out of a session that has itself exited — a bookmark
resolving to "character 40122 of a buffer that no longer exists" is a broken link by
morning, every time. What survives is where the shell was, so that is what is stored,
and `cooked-bookmark-jump` spends it by putting a shell back there — reusing a live
session already in that directory, by the same rule `cooked-project` reuses one, so that
jumping repeatedly does not accumulate a shell per jump. The session being gone is the
ordinary case and degrades into starting one; the *directory* being gone is the failure,
and is said out loud rather than papered over by starting a shell somewhere else.

The command line is recorded and never re-run. It names the bookmark, so that a list of
them reads as the list of things they were set for, and re-running is
`cooked-rerun-command`, which the user presses themselves. A bookmark that executes
something on being opened is a stored side effect. Both `filename` and `directory` are
written, and they are not redundant: `filename` is what `bookmark-bmenu-list` prints and
what `bookmark-relocate` edits, `directory` is what the handler reads — so relocating a
bookmark does not silently move the column and leave the shell where it was.

---

## Leaving: a buffer kill is not the only way out

Killing a session buffer reaps its child correctly — `cooked--cleanup` is on
`kill-buffer-hook`, and `cooked--stop-session` from there reaches
`Session::shutdown` and its SIGHUP, short grace, SIGKILL escalation.

Exiting Emacs kills no buffers. So none of that ran, and the escalation is not
decoration: a child that ignores SIGHUP — `nohup`, `trap '' HUP`, a detached session
leader — is exactly what it exists for, and such a child simply outlived the Emacs that
started it. `Session::shutdown` says so in a comment; the Lisp side had no hook to say
it from. The shell startup files `cooked--shell-invocation` generates leaked the same
way, and they are named by a path only the buffer holds, so nothing could ever find them
again.

`cooked--kill-emacs`, on `kill-emacs-hook`, is that path. It is deliberately the same
two calls `cooked--cleanup` makes and not a third teardown of its own — the one
omission is `cooked--cancel-secret`, which exists to put the buffer and the echo area
back the way a `getpass` prompt found them, and there is no after to restore to.

It has to be bounded, because Emacs' exit waits on it. It is: a session with no child
returns at once, and one with a child pays the same tens of milliseconds a buffer kill
pays — the grace period is the emulator's, not the child's idea of when to leave.
`cooked--dolist-buffers` contains a failure to the buffer it happened in, which matters
more here than anywhere else it is used: this is the last code to run, and a session
that cannot be torn down must not take the ones after it in `buffer-list` with it.

---

## Vendored parser

`src/emu/parser/` is vte 0.15, vendored rather than depended on, because two things
cooked needs cannot be expressed through `Perform` as upstream defines it. Upstream
discards APC entirely, which is where the kitty graphics protocol lives, so an image
never reaches us at all; and DCS payloads arrive one byte at a time, which is the wrong
shape for a multi-megabyte transmission. Both are answered locally, and the module is
kept otherwise faithful so a re-sync stays a diff. Two further departures since: APC and
OSC both have a size bound, where upstream bounded neither.

## Source layout

```
src/env.rs       hand-rolled emacs_env_28 bindings; catch_unwind at every boundary,
                 ABI size check at load, user-pointers tagged by finalizer
src/pty.rs       pty ownership via nix, setsid/TIOCSCTTY, termios -> Mode, bounded
                 reaping; child_exec stays raw libc and says why
src/emu/         cell/row/style, grid with damage tracking, vte-driven VT parser
src/emu/term/    the VT front end: mod (types, Term), csi, osc, graphics, state
src/session.rs   reader thread, coalesced wakeups, explicit idempotent shutdown
src/lib.rs       the Lisp-facing surface
src/platform/    one module per OS; each gets the best facility it actually has rather
                 than levelling down to the intersection (see below)
lisp/            cooked-util.el is the floor everything else requires; cooked.el owns
                 the state and the policy derived from it; cooked-mode.el binds keys
                 to it and pulls in the rest. The opt-in files (cooked-evil,
                 cooked-osc-eval, cooked-shell-completion, cooked-file-link,
                 cooked-next-error, cooked-command-decorations, cooked-project) sit on
                 top and are `require`d, not toggled by a variable
shell-integration/  bash, zsh, fish, plus zsh's completion capture
docs/            this file, plus KEYBOARD, FEATURES, SHELL, TERMINFO, IMAGES, ROADMAP
tests/           cooked-tests.el loads the suite; the rest are split by subject
```

`cooked-util.el` cannot require `cooked.el` back for a macro, which is what the base
layer exists to prevent, rather than each file above it growing its own copy.
`cooked-glyph.el` sits below all of it and knows nothing about terminals — a shape
descriptor and a pixel size in, raw XBM bits out — which is why the pixel-level tests
can assert against it without starting a session. Scrollback lives in the Emacs buffer,
not in Rust: rows leaving the emulator's screen are handed over once and become
ordinary buffer text, capped by `cooked-scrollback-lines`.

### Platforms

Linux and macOS, and the rule in `src/platform/` is that each gets the best facility it
actually has:

| | Linux | macOS |
|---|---|---|
| slave path | `ptsname_r`, reentrant | `ptsname`, copied out immediately |
| wake pipe | `pipe2`, close-on-exec atomically | `pipe` then `fcntl`, with the window that implies |
| `TIOCSCTTY`, `TIOCSWINSZ` | from `libc` | defined locally; neither libc nor nix has them for Apple |

PATH lookup happens in the parent rather than via `execvpe`, a glibc extension with no
macOS equivalent — doing it before the fork turns "command not found" into an error you
can see instead of a session that appears and immediately exits 127. A new platform is
usually one short file here; the build fails with a message saying so rather than
emitting forty confusing errors.

## Measuring

The benchmarks are the acceptance gate for anything touching the render or write paths.

```sh
make bench
```

Compare interleaved against a worktree of the base commit, on a quiet machine, and never
alongside another benchmark run — a chunk of one session was spent chasing a 4%
"regression" that was one benchmark loop contending with another. Run-to-run noise is
2–3%, so treat anything under 5% as needing more runs rather than a bisect.
