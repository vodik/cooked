# The keyboard

How much of the keyboard the child gets, how modified keys are spelled on the way to
it, and how to reach Emacs anyway. See the [README](../README.md) for the two signals
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
`cooked--literal-codes` — Return, Tab, Escape, Backspace, Shift+Tab among them — exactly as
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

`cooked-send-literal-key` is the escape hatch in the other direction: it sends the very
next key to the child exactly as typed, regardless of what's reserved — including `C-c`
itself (`C-c C-q C-c` sends a literal `C-c` byte).

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

### Job control comes from the tty

`C-c C-c`, `C-c C-z` and `C-c C-\` do not send a hardcoded signal. A terminal writes the
character in the tty's `c_cc` and lets the line discipline decide what it means, so cooked
reads it — which is what makes `stty intr ^X` work. `ISIG` is the other half: a program
that cleared it did so to read the byte itself, and signalling it behind its own back
would be wrong. The signal is the fallback for the two cases where writing cannot mean
anything: `ISIG` off, or the character disabled (`_POSIX_VDISABLE` — zero on Linux,
`0xff` on the BSDs, which is why it lives in `src/platform/`).

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

