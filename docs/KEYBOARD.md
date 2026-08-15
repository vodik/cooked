# The keyboard

How much of the keyboard the child gets, how modified keys are spelled on the way to
it, and how to reach Emacs anyway. See the [README](../README.org) for the two signals
that decide who owns the keyboard in the first place.

## Modified keys

Arrows, Home/End and the function keys carry their modifiers the usual xterm way, and
Shift+TAB is `kcbt`. Return, Tab, Escape and Backspace are the awkward ones: there is no
classical encoding for Shift+Return, so xterm and kitty each invented one, and both have
to be negotiated. cooked tracks `CSI > 4 ; 2 m` (modifyOtherKeys) and the kitty keyboard
protocol, and sends the extended form **only** to a child that asked for it — sending
`ESC [ 27;2;13 ~` to a program that did not is not a Shift+Return, it is six characters
of rubbish in its input.

Some programs never ask. Claude Code enables the kitty protocol from a list of terminal
*names* it recognises in the environment — `iTerm.app`, `kitty`, `WezTerm`, `ghostty`,
`tmux`, `windows-terminal`, `WarpTerminal` — and never sends the `CSI ? u` query cooked
stands ready to answer. It reads kitty-formatted input regardless of whether it made that
decision, though: what the name check gates is only whether *it* relies on the protocol
for its own keybindings, not whether its parser understands a sequence that arrives
anyway. Cooked will not claim to be one of those terminals itself — it reports what it
actually implements, which is the whole point of shipping a terminfo entry — so the way
through is `cooked-key-protocol-overrides`, where it is your keyboard being configured
rather than cooked's identity being misreported:

```elisp
(setq cooked-key-protocol-overrides
      '(("\\`claude\\'" . kitty)))
```

That is the default. The condition matches the name of the program in the child's
**foreground process group**, so it catches a `claude` typed at a cooked shell, not just
one started as the session's command; a function of no arguments works too, for a test the
process name cannot express. With it matching, cooked spells *every* modified key in
the `literal` keys of `cooked--key-encodings` — Return, Tab, Escape, Backspace, Shift+Tab
among them — exactly as
if PROTOCOL had actually been negotiated, so nothing has to be named one key at a time; a
real negotiation is still believed over the guess whenever one actually happens.

For the narrower case a blanket protocol guess can't cover — a specific byte a program
wants regardless of protocol, or a key with no negotiated encoding to re-spell at all —
`cooked-key-overrides` does one key at a time instead, the equivalent of kitty's
`map --when-focus-on title:claude shift+enter send_text`:

```elisp
(setq cooked-key-overrides
      '(("\\`claude\\'" . (("<S-return>" . :newline)))))
```

The action is a named byte (`:newline`, `:return`, `:meta-return`, `:tab`, `:escape`), a
protocol to re-spell the key in (`:kitty`, `:modify-other` — so nobody writes
`ESC [ 13;2 u` by hand), a literal string, or a command. It is empty by default, and wins
over `cooked-key-protocol-overrides` wherever the two overlap, so the two compose rather
than fight over the same key.

Both apply only while the child owns the keyboard, and neither touches `cooked--keys`:
what cooked sends of its own accord still follows the negotiation and nothing else.


## Keybindings

How much stays with Emacs while the child owns the keyboard depends on what it's doing,
not just on the one `C-c` prefix cooked always keeps:

| | Reserved for Emacs | Reach it anyway |
|---|---|---|
| Shell ran a command (OSC 133 live) | `C-c` only | `cooked-toggle-peek` (`C-c C-v`), or `evil`'s own `C-z` |
| Raw read, no OSC 133 seen | `C-c`, plus `cooked-raw-exceptions` (`C-g C-x C-h C-u C-l` by default) | `cooked-send-literal-key` (`C-c C-q`) |
| Alternate screen | `C-c` only | `cooked-toggle-peek` (`C-c C-v`), or `evil`'s own `C-z` |

The first row is the common case, and it keeps nothing back. `cooked-raw-exceptions`
hedges a state cooked cannot read — a raw program and a shell editing its own prompt line
look identical — and OSC 133 removes that doubt: once the shell has spoken at all, a raw
read that isn't a prompt means it is running something, and it said so. That is as
positive a signal as the alternate screen. So with the shipped integration `C-u` and `C-l`
— readline's kill-line and every shell's clear-screen — reach the child, as they would in
any other terminal. The hedge applies only to a session where the shell never spoke.

The states get different defaults because they mean different things. A raw read with no
OSC 133 in evidence is often a shell prompt cooked cannot positively tell apart from a
program that wants the whole keyboard — a bare `ssh`, or a shell without cooked's
integration — so `cooked-raw-exceptions` keeps a handful of keys most raw programs don't need for
themselves: the universal quit, the two most common prefix commands, and a prefix
argument. The alternate screen means a full-screen program has unambiguously taken over,
possibly `emacs -nw` or `vim` itself, which can plausibly want any of those same keys —
so nothing beyond `C-c` is reserved there by default. Set `cooked-raw-exceptions` to `nil`
for `raw` to behave exactly like the alternate screen does; add to it for more of the
usual Emacs bindings back. `C-y` is deliberately never offered as an exception even
though it would otherwise be a plausible candidate — plain `C-y` is both vim's
scroll-up-a-line and readline's own yank. `M-x`/`M-o`/`M-y` are not offerable at all,
for a different reason: they're Meta-modified letters, and a bare `ESC` byte is forwarded
the instant it's pressed (so a real terminal's Escape key has no latency), which leaves
nothing for a Meta chord to land on before the child sees it. `C-c M-x` is unaffected
either way.

That last sentence is a fact about *terminal* frames, where a Meta chord arrives as two
bytes and both are forwarded. On a graphical frame `M-t` is a single event, and Emacs
stores a Meta character under an `ESC` prefix and nowhere else — so binding the Meta
space and forwarding `ESC` as a key of its own cannot both happen in one keymap. The
three maps that forward everything are therefore worn through a child keymap on a
graphical frame: `ESC` becomes the prefix there, and the Escape key keeps its
zero-latency spelling through the `escape` event a graphical frame actually sends.
`vterm` and `eat` both resolve it the same way, unconditionally; cooked's variant is
chosen at the moment the map is installed, so terminal frames never pay for it.

`cooked-send-literal-key` is the escape hatch in the other direction: it sends the very
next key to the child exactly as typed, regardless of what's reserved — including `C-c`
itself (`C-c C-q C-c` sends a literal `C-c` byte).

**Middle-click pastes**, as it does in every other terminal: `mouse-2` sends the head of
the kill ring to the child. comint binds that key to `comint-insert-input`, which looks
for the input field under the click and, finding none, fell through to the global binding
and inserted the X selection *into the buffer* — text that goes nowhere, above a prompt
that is read-only, at a position the next repaint may overwrite. The new binding takes
nothing from the two claims that outrank it, which is the correct order: a link span
carries its own keymap as a text property, consulted before any of this, so clicking a
link still follows it; and a child that asked for the mouse is served from
`emulation-mode-map-alists`, above the local map, so it gets the click untouched.

The mouse has an escape hatch of its own, and it's the one every terminal uses: hold
**shift**. A child that asked for mouse reports gets the whole gesture — press, the
motion between, release — and a click that reaches it clears any Emacs region, because
the click was the child's and a region left behind it is one nothing can get rid of.
`S-down-mouse-1` is deliberately not bound, so it falls through to `mouse-drag-region`
and selects text out of a program that has grabbed the pointer, exactly as it does in
xterm. Modified wheel notches fall through the same way, so `C-wheel-up` still scales
text.

### The `C-c` map is comint-shaped, cooked-implemented

`cooked-mode` derives from `comint-mode`, but the buffer has no Emacs process object for
the child — it belongs to a Rust session handle. Comint's entire command set navigates by
`process-mark`, so for a long time none of it worked here: `C-c SPC` inserted a stray
newline into the terminal, `C-c C-o` raised `wrong-type-argument`, `C-c C-\` reported
"Current buffer has no process".

The fix was not to unbind them. `cooked--wake` — the pipe the child rings when output is
pending — is now attached to the buffer, so `get-buffer-process` answers and its mark is
the near edge of the input region. There is no second marker kept in step with it; the
process mark *is* where pending input begins. (`shell-maker` buys the same thing by
spawning a `hexl` it never speaks to; we already had a process object and were only
withholding it.)

So comint's own commands work, and where a concept needed cooked's implementation it kept
comint's key:

| Key | comint | cooked does |
|---|---|---|
| `C-c C-\` | `comint-quit-subjob` | SIGQUIT to the child, not `quit-process` on the wakeup pipe |
| `C-c M-o` | `comint-clear-buffer` | everything above the prompt goes, whether it is scrollback or still on the grid |
| `C-c C-o` | `comint-delete-output` | asks the *emulator* to drop those rows; see below |
| `C-c SPC` | `comint-accumulate` | `cooked-newline`, which is also how a TTY frame composes multi-line input |
| `C-c C-r`, `C-M-l` | `comint-show-output` | scrolls *this* command's output to the top, found from the OSC 133 records |
| `C-c C-s` | `comint-write-output` | writes the output of the command at point, not only the last one; a prefix saves the whole record |
| `C-c C-d` | `comint-send-eof` | the tty's EOF byte to the child, not `process-send-eof` on the wakeup pipe |
| `C-c C->` | *(new)* | `cooked-goto-last-command`, which had no key at all — only the mode line's exit status was a click away from it |

The three that had been missed are the interesting half of that table, because they were
not failing. **They were succeeding, against the wrong process.** A process object that
answers `get-buffer-process` is what makes the rest of comint work here, and it is also
what turns an un-remapped command into something that runs: the Signals menu's `Kill` was
`kill-process` on `cooked--wake` — it killed the doorbell and left the child running
behind a buffer that had stopped hearing from it, with nothing on screen to say so. `EOF`
and `CONT` were the same shape. `cooked-kill-session` and `cooked-continue` now stand
where those two landed; a terminal has no continue *character*, so the second exists only
to be remapped onto, and what resumes a stopped job is still the shell's `fg`.

The other two were wrong in the quieter way. `comint-show-output` and the `Matching
Input…` motions find the input and output groups by walking `field` text properties, and
cooked sets none anywhere — it marks the prompt read-only instead, because the transcript
is one continuous thing the emulator rewrites in place. With no fields `field-beginning`
answers `point-min`, so `C-c C-r` scrolled to the top of the *scrollback* and the two
motions always reported "Not found". `cooked-show-output` answers from the command records
instead, which is better than the field walk in the way that matters: it works pressed
from the prompt below a command as well as from inside its output. The motions are simply
gone — `C-c C-p`/`C-c C-n` already walk prompts, and isearch is the better tool over a
transcript that is all one field.

`C-c C-o` is the interesting one. The rows belong to the emulator, so cooked deletes no
buffer text: it asks the core to remove the rows and lets the ordinary drain repaint what
moved — the same shape as sending input, which also changes rows, and by the same rule
that the grid has exactly one owner. Deleting the text instead would leave the buffer and
the grid disagreeing about what the screen is, and the next repaint would put it back. It
refuses when the output reaches the row the child is on, because the shell is editing its
own prompt line there and tracking where it sits.

Clearing splits along the same seam, and all three ways of asking end where a terminal
user expects — the prompt at the top, nothing above it. The shell's `C-l` sends `CSI 2J`,
which cooked *archives* rather than drops, because a screenful of transcript is Emacs' to
keep; the window then scrolls so the live screen sits at its top, which is exactly what a
terminal's viewport does with the screen it just cleared, and the transcript is one scroll
up. `clear` sends `CSI 3J` after that, and that one really does delete the scrollback —
honoured unconditionally, since it is only reachable by a program already holding the
terminal and it is what you typed `clear` to get. `C-c M-o` reaches the same state with no
help from the child: the emulator drops the rows above the prompt (from the OSC 133 mark
when the shell sends one, from the cursor's row when it does not) and Emacs deletes the
scrollback, each side asked for the half it owns.

### The menu is comint-shaped too, and for the same reasons

`cooked-mode` inherits comint's three menus along with its keymap — In/Out, Signals and
Complete — and every one of the faults above had a menu entry sitting on top of it. So the
same rule applies: cooked defines one `Cooked` menu and shadows those three, keeping the
concepts a terminal genuinely has and dropping the ones that only ever meant comint's
process.

It is the same menu in all three places it can be reached: the menu bar, `mouse-1` on
`cooked` in the mode line, and — under `context-menu-mode` — right-click. Every item is
guarded by the predicates the mode line already reports in words, so what is greyed out
matches what the state word says: with the child holding the keyboard the input group goes
dim, after `exited 0` everything that writes to a child does, and the command verbs need a
command at point. Greyed rather than hidden, deliberately — which state the terminal is in
is exactly what someone reaching for a menu is unsure of, and an item that vanishes
answers nothing. Right-click adds one thing the menu bar cannot: the command verbs there
are resolved from the *click*, not from point.

### Job control comes from the tty

`C-c C-c`, `C-c C-z` and `C-c C-\` do not send a hardcoded signal. A terminal writes the
character in the tty's `c_cc` and lets the line discipline decide what it means, so cooked
reads it — which is what makes `stty intr ^X` work. `ISIG` is the other half: a program
that cleared it did so to read the byte itself, and signalling it behind its own back
would be wrong. The signal is the fallback for the two cases where writing cannot mean
anything: `ISIG` off, or the character disabled (`_POSIX_VDISABLE` — zero on Linux,
`0xff` on the BSDs, which is why it lives in `src/platform/`). The fallback signal is
named rather than numbered for the same reason: `SIGTSTP` is 20 on Linux and 18 on the
BSDs, where 20 is `SIGCHLD`, so the Lisp says `sigtstp` and the core — which links libc
and can see which platform it is on — turns that into a number.

For anything that needs more than one key — an arbitrary command, `isearch`, or just
moving around with `evil` normal state — `cooked-toggle-peek` freezes the screen (the
child keeps running; cooked just stops redrawing), makes the buffer read-only, and hands
it to ordinary Emacs keymaps. Peek is look-only, though, so leaving is not a separate step
to remember: the instant a key means anything other than looking — typing a character,
`RET`, or any of cooked's own commands that write to the child (`C-c C-c`, `C-c C-y`, and
the rest) — it ends on its own, forwards whatever was pressed, and the buffer catches up
on whatever it missed immediately. `cooked-toggle-peek` still works as a manual toggle for
leaving without acting on anything. `evil` users already have their own way in and don't
need to learn this one: `C-z` (`evil-toggle-key`) reaches `evil-emacs-state` ahead of any
binding cooked makes regardless, because evil's state keymaps take priority over a
buffer's local map — `cooked-evil.el` freezes and thaws the screen around that transition
the same way `cooked-toggle-peek` does, so the two doors lead to the same place. Normal-
and visual-state motions and operators (`d`, `y`, a visual selection, and the rest) never
trigger the auto-resume, because none of them are `self-insert-command` or `RET` — only
actually typing is.

This is a different shape than `vterm`/`eat`'s own designs, and worth being explicit
about why. Both forward almost everything and give you a manually toggled way out —
`vterm-copy-mode`, `eat`'s four hand-toggled modes — because neither has a way to know
who owns the keyboard other than the user telling it. cooked does know, from termios and
OSC 133, so the common case — type a command, read its output — never needs a mode
switch at all; peeking exists only for the one case that signal can't help with, a
full-screen program that has taken the whole keyboard.

That same signal is why the evil integration above needs so little code: cooked never
puts evil in insert state against a program that owns the keyboard, so there is nothing
to reclaim from evil's insert map and no second ESC-routing toggle to add on top of it —
`evil-collection`'s own vterm/eat modules need both, because they lack this signal and
have to guess. The result is a real asymmetry, not just a difference in polish: an evil
user's "step out to Emacs" is exactly the `C-z` they already know, free. A non-evil user
still has to learn `C-c C-v` specifically, same as they would `vterm-copy-mode` or
`eat-emacs-mode` — this design does not make that easier, it only makes the evil case
free. Coming back is symmetric either way, and free for both: nobody has to remember a
resume key, because typing already means "give it back."

At a prompt, where Emacs owns the line, Shift+RET does something more useful: it inserts
a newline into the pending input so you can compose a multi-line command, which is then
submitted as one bracketed paste rather than as several separate lines.


## evil

Opt-in — `(require 'cooked-evil)` — and the whole of it is one idea: **evil's states
already mean exactly what a terminal needs to know**, so cooked reads the state instead
of asking you to set a mode.

Normal state means "I am navigating." Insert state means "I am typing, but I still
expect to be able to leave." Emacs state means "get out of the way entirely." A terminal
wants all three, and a terminal pinned to emacs state — the usual arrangement — offers
only the last.

| evil state | What the child gets | What the render does |
|---|---|---|
| emacs | everything but `C-c`, ESC included — `cooked-alt-map` unchanged | follows the cursor, as always |
| insert | `cooked-semi-map`: forwards, but keeps ESC, the Meta space and `cooked-semi-exceptions` for Emacs | follows the cursor |
| normal, motion, operator | nothing; the buffer is read-only | `still` — the child keeps drawing, the view stays put |
| visual | nothing; read-only | `frozen` — the render is deferred |

Insert state is the interesting row. It forwards your typing to the child while `M-x`, a
non-normal leader on `M-SPC`, and ESC-back-to-normal all still reach Emacs, so you can
type at a shell without giving up the editor. That is `cooked-evil-hybrid-insert`; turn
it off and insert state becomes indistinguishable from emacs state.

### The state moves on its own

You do not switch to emacs state when a full-screen program starts — cooked does it for
you, and puts you back at the prompt. That is the entire integration
(`cooked-evil-integration`), and it is what makes ESC reach vim rather than evil without
anyone configuring anything.

`cooked-evil-child-state` chooses what "the child has the keyboard" means:

- `emacs`, the default, because it is the only state that gives a full-screen program
  literally every key, ESC included, which is what one needs and what a terminal has
  always done.
- `insert` hands it `cooked-semi-map` instead. That is a friendlier default at a shell
  than in vim — ESC leaving insert state costs nothing at a prompt and costs everything
  inside a modal editor — so it is offered rather than chosen.
- `nil` leaves evil alone entirely; whatever state you are in is the one that decides,
  and cooked never moves you.

### Visual freezes, normal doesn't

Both halves catch people out, and in both directions, so: normal state does **not** stop
the terminal. `cooked-evil-normal-state-render` is `still` — the child goes on drawing
and point stays where you put it, pinned to its screen cell across each redraw. Normal
state is somewhere an evil user passes through constantly — to reach a leader key, to
scroll, to get to another window — and none of that is a reason to stop a running
program.

Visual state *is* `frozen`, and the asymmetry is the point: a selection is a claim about
a region of text, and text rewritten underneath it turns the claim into a lie. The
freeze lifts as soon as the window stops being the selected one, so it cannot strand a
buffer.

If you want the tmux-copy-mode behaviour — normal state stops the world — set
`cooked-evil-normal-state-render` to `frozen`. `nil` goes the other way and keeps
following the cursor, so the view chases output while you navigate.

### The bindings

- **`[[` and `]]`** move between prompts. `evil-collection` already routes these here
  through `comint-previous-prompt`, which `cooked-mode-map` remaps — but only if
  `evil-collection` is installed, so cooked binds them itself and a plain evil user gets
  them too, in place of `evil-backward-section-begin`, which has nothing to find in a
  transcript. See `cooked-evil-section-motions`.
- **`vic` and `vac`** are the command text objects: `vic` selects a command's output,
  `vac` takes the prompt and the command line above it as well, both linewise. So `yac`
  on a build copies exactly what was run and what it printed, and works while it is
  still running. The regions come from the OSC 133 marks. Bound only in `cooked-mode`,
  through the same auxiliary keymap evil resolves everything else with, so `iw`, `ip`
  and `i"` keep meaning what they mean — see `cooked-evil-command-text-object`.
- **`p` and `P` in normal state** paste into a full-screen program. A program's own paste
  key pastes its own registers — `p` inside vim never sees anything Emacs copied — so
  reaching the kill ring, and through it the system clipboard, needs a key Emacs still
  owns. Only while the child has the keyboard; at a prompt it stays evil's own paste,
  because `evil-paste-after` pastes after the character under the cursor, which is right
  on a line you are editing and meaningless on one you are not. See
  `cooked-evil-normal-state-pastes`.
- **`RET` still submits** in insert state, even under `evil-collection`, whose comint
  module registers Enter on an auxiliary keymap evil consults ahead of any buffer's local
  map — and defaults it to normal state, which hands insert-state Enter to `newline`.
  cooked answers on the same terms rather than with a `define-key` that could never
  outrank it; `cooked-evil-insert-state-submits` turns that off.

Stepping out of insert state also gives point a visible cursor even where the child has
hidden its own, since point is then the only cursor there is.
