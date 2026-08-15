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

---

## `cooked--pin-alt-windows`: why the alt screen needs a continuous invariant

`cooked--apply` pins the alternate screen to the top of its windows at the end of every
drain, and that is not enough: a drain is the child talking, and nothing the *user* does
to a window produces one. A full-screen program idle at its prompt draws nothing, so a
wheel notch — which reaches `mwheel-scroll` whenever the child has not asked for mouse
reports, or has but the keyboard is suspended for a peek — scrolled the picture off the
window and left it there. Run from a command hook, the pin becomes the continuous
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

**Two hooks, because `post-command-hook` alone leaves the wheel two ways out.** It runs
in the buffer of the *selected* window, and `mouse-wheel-follow-mouse` is on by default,
so a notch over an unselected terminal is a command that ends in a buffer where the hook
is not installed. And a notch from a mouse is animated:
`pixel-scroll-precision-interpolate` scrolls and redisplays a dozen times inside the one
command, so a pin waiting for the command to end is one the user watches the screen slide
away from and snap back to.

The second hook is `pre-redisplay-functions` rather than the `window-scroll-functions` it
used to be. That one announces a start redisplay is about to use, but only for a window it
displays without a vscroll: measured against `pixel-scroll-precision-scroll-down` on a
20-pixel line, it was called once every fourth event and the three in between moved the
picture unwatched. `pre-redisplay-functions` runs for every window about to be drawn,
whatever moved it.

The alt screen's other half is `cooked--pin-alt-screen`, inside the drain, which repairs
a different thing: a resize reaches the buffer in two steps — the window changes height
the instant Emacs notices, while the buffer is not re-fitted until the next drain's
`cooked--fit-screen`. Ordinary redisplay fills that gap by pushing `window-start` down to
keep point on screen, and nothing corrected that once the buffer caught up.

---

## `cooked-row-rendered-function`: why the bounds arrive late

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

## `cooked--sync-cursor-type`: why it runs last, twice

`evil` advises `select-window` to refresh its own cursor, and refreshes it again from
`window-configuration-change-hook` and on every state change. The render selects windows
in order to `recenter` them. So setting `cursor-type` any earlier in the drain lets evil
get the last word inside the very drain that hid the cursor — and because this writes
only on a change, the next drain computes the same value, skips the write, and never
repairs it. The visible result was a cursor jumping around a progress bar the child had
asked to draw without one.

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

## The three-file base layer

`cooked.el` requires `cooked-face.el` and `cooked-deco.el`, so neither can require it
back — which is why `cooked-util.el` exists. It holds the customization group, the
session handle and the four macros the layers above reach for often enough that
open-coding them was how they drifted apart.

The one coupling that crosses the other way is a cache: `cooked--flush-face-cache` has
to drop decoration specs that were coloured against the outgoing theme, and cannot name
them from below. `cooked-theme-change-hook` is how the upper layer says so instead.

## Vendored parser

`src/emu/parser/` is vte 0.15, vendored rather than depended on, because two things
cooked needs cannot be expressed through `Perform` as upstream defines it. Upstream
discards APC entirely, which is where the kitty graphics protocol lives, so an image
never reaches us at all; and DCS payloads arrive one byte at a time, which is the wrong
shape for a multi-megabyte transmission. Both are answered locally, and the module is
kept otherwise faithful so a re-sync stays a diff. Two further departures since: APC and
OSC both have a size bound, where upstream bounded neither.

## Measuring

The benchmarks are the acceptance gate for anything touching the render or write paths.

```sh
make bench
```

Compare interleaved against a worktree of the base commit, on a quiet machine, and never
alongside another benchmark run — a chunk of one session was spent chasing a 4%
"regression" that was one benchmark loop contending with another. Run-to-run noise is
2–3%, so treat anything under 5% as needing more runs rather than a bisect.
