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
