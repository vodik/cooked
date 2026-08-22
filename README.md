# cooked

A terminal emulator for Emacs that hands the keyboard back when the child wants a line.

`eat.el` emulates in Emacs Lisp (correct, slow). `vterm` is fast but is a dumb rectangle
with no idea where a command begins or ends. cooked is a Rust core plus a Lisp front end
that tracks *who should own the keyboard right now*, from two independent signals.

## The two signals

**1. The kernel's line discipline.** We allocate the pty ourselves, so `tcgetattr` on the
master reports the child's termios. Three states, exactly disjoint:

| ICANON | ECHO | Meaning | cooked does |
|---|---|---|---|
| on | on | canonical read (`cat`, `read` loops) | Emacs owns the input line |
| off | off | full-screen TUI (`vim`, `htop`) | keys pass straight through |
| **on** | **off** | `getpass(3)` — a secret | prompts in the minibuffer |

Linux gives no push notification for this — `TIOCPKT` reports only flow-control and
`EXTPROC` changes, not `ICANON`/`ECHO` (measured, not assumed). The mode is therefore
sampled on the reader thread's existing poll timeout and after every read; Emacs is woken
only when it actually changes.

**2. OSC 133 semantic prompts.** Interactive shells put the tty in raw mode the moment
readline/ZLE starts, so signal 1 cannot see a shell prompt. The shell tells us instead:
`133;A` prompt start, `133;B` input start, `133;C` output start, `133;D;<code>` done.
An explicit mark always beats the inferred termios state.

## Try it

```sh
cargo build --release
emacs -Q -L lisp -l cooked-mode -f cooked
```

Or, as you would actually install it:

```elisp
(use-package cooked
  :load-path "/path/to/cooked/lisp"
  :commands (cooked cooked-other-window)
  :config
  (require 'cooked-evil)        ; opt in to evil state syncing
  (require 'cooked-osc-eval))   ; opt in to the OSC 51 command channel
```

`M-x cooked` injects the OSC 133 snippet via generated startup files that source your own,
so your shell configuration is neither bypassed nor edited — for zsh that means a stub for
every startup file, not just `.zshrc`, because zsh reads `.zshenv` from `ZDOTDIR` too and a
lone `.zshrc` would silently skip yours. The generated files are deleted with the buffer,
and `ZDOTDIR` is handed back so nested shells and `exec zsh` see the real one. Set
`cooked-shell-integration` to nil to opt out.

While the child owns the keyboard, `C-c` is the only prefix cooked always reserves for
itself — everything else, ESC included, is forwarded, so `M-x` reaches the child exactly
as in any terminal. `C-c M-x` is the way back out regardless of what the child is doing;
it runs whatever you have bound `M-x` to. See [Keybindings](#keybindings) for the rest —
what else stays with Emacs, and how to reach an arbitrary command or `evil` normal state
without waiting for the child to give the keyboard back.

`cooked-password-function` can answer a password prompt from auth-source or `pass`. No
ordinary terminal can do that, because it never learns a password was being requested.

The secret never reaches the buffer, and the copies cooked makes of it are cleared — it
goes out as two writes rather than one concatenation, and the native core zeroes its byte
buffer afterwards. That is the honest limit. `read-passwd` builds the string in Emacs' own
heap, the garbage collector relocates and compacts small strings so earlier copies survive
in freed blocks that `clear-string` never sees, and an auth-source backend caches
plaintext by design. cooked cannot promise a password leaves no trace in Emacs' address
space, and does not claim to.

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
`0xff` on the BSDs, which is why it lives in `src/compat/`).

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

## Terminfo

We ship `terminfo/cooked.ti` and default `TERM` to `cooked-256color` — what alacritty,
wezterm, foot and Emacs' own `term.el` all do. Claiming to be xterm is a lie with
consequences in both directions: xterm-256color does not advertise direct colour, so
applications drop to 256 unless they happen to honour the `COLORTERM` convention, and it
*does* advertise capabilities we ignore. Our entry corrects both.

Inheriting `use=xterm-256color` and cancelling a few entries turned out to be the wrong
shape for that promise: it claims everything xterm has, and everything ncurses ever adds to
it, so the entry drifts out of true every time nobody looks. The entry is now written out
in full, and every capability in it has been checked against the code. `bce` is the one
that mattered — ncurses *optimises* on the strength of it, setting a background and erasing
rather than writing spaces, so ignoring it mis-drew every coloured panel and status bar.

**Was claimed, is now implemented:**

| Capability | Sequence | What was wrong |
|---|---|---|
| `bce` | — | erases filled with the default style, losing every background |
| `rep` | `CSI Ps b` | ncurses emits it for repeated characters; rules came out short |
| `smam`, `rmam` | `CSI ?7h/l` | autowrap could not be turned off, so painting the last column scrolled |
| `cbt`, `kcbt` | `CSI Z` | no back-tab |
| `smir`, `rmir` | `CSI 4h/l` | no insert mode — in fact no ANSI mode handling at all |
| `is2`, `rs2` | `CSI !p`, `ESC >` | the init string was mostly no-op, so a reset only looked like one |
| `smcup`, `rmcup` | `CSI 22;0;0t`, `CSI 23;0;0t` | the title stack was ignored, so vim left its title behind |
| `u8` | `CSI c` | the reply was malformed, and `CSI > c` went unanswered |
| `Ss`, `Se` | `CSI Ps SP q` | cursor shape, now mapped onto `cursor-type` |
| `fe`, `fd` | `CSI ?1004h/l` | focus reporting, now sending `CSI I`/`CSI O` |
| `Cr`, `Cs` | OSC 12, OSC 112 | cursor colour, which Lisp had handled all along |

**Added, being things xterm-256color does not declare:**

| Capability | Why |
|---|---|
| `Tc`, `setrgbf`, `setrgbb` | direct colour; `COLORTERM=truecolor` is a convention, not a capability |
| `Smulx`, `Setulc` | styled and coloured underlines, onto Emacs\' `:underline` |
| `Sync` | synchronized output, which suppresses the Emacs wakeup for a frame |

**Removed, being things we do not implement and do not intend to:**

| Capability | Why |
|---|---|
| `ccc`, `initc` | palette redefinition via OSC 4. Emacs owns colour; a per-buffer 256-entry palette is the wrong seam |
| `flash` | visual bell via DECSCNM |
| `mc0`, `mc4`, `mc5`, `mc5i` | printer control. There is no printer behind an Emacs buffer, and `mc5` is a child-driven exfiltration channel with nothing to show for it |
| `mgc`, `smglp`, `smglr`, `smgrp` | left/right margins. The grid, the reflow and the transcript model are all row-oriented — and `CSI s` is already save-cursor, so honouring these would corrupt it |
| `meml`, `memu` | HP-era memory lock |
| `smm`, `rmm`, `km` | meta-sends-escape. How Meta is spelled is negotiated through modifyOtherKeys or the kitty protocol, which is the mechanism that should own it |
| `cvvis` | cursor *blink* is `blink-cursor-mode`, yours to set and not the child\'s. `cnorm` covers visibility |

A child does not have to take our word for any of it. DECRQM (`CSI ? Ps $ p`) answers 1 or
2 for a mode we implement, 4 — "permanently reset" — for every one in that last table, and
0 for one we have never heard of.

Some requests are refused rather than merely unimplemented. `CSI 21t` reports the window
title *on the child\'s input stream*, which turns a title the child set itself into typed
input at your next prompt; `CSI 3t`, `4t` and `8t` move and resize the window, which is
Emacs\' business. The read-only `CSI 18t` is answered.

The entry installs itself into `~/.terminfo` on first use — no root needed — and falls
back to `xterm-256color` when `tic` is unavailable. Set `cooked-term-name` to nil to always
present as xterm.

Remote hosts are the real cost, and `M-x cooked-install-terminfo-remote` runs the usual
incantation:

```sh
infocmp -x cooked-256color | ssh host 'mkdir -p ~/.terminfo && tic -x -o ~/.terminfo -'
```

The names `eterm` and `eterm-color` were already taken by Emacs' `term.el`, and
`Eterm`/`Eterm-256color` by the X terminal Eterm — which is what this project was first
called, and why it no longer is.

## Layout

```
src/env.rs       hand-rolled emacs_env_28 bindings; catch_unwind at every boundary,
                 ABI size check at load, user-pointers tagged by finalizer
src/pty.rs       pty ownership via nix, setsid/TIOCSCTTY, termios -> Mode, bounded
                 reaping; child_exec stays raw libc and says why
src/emu/         cell/row/style, grid with damage tracking, vte-driven VT parser
src/session.rs   reader thread, coalesced wakeups, explicit idempotent shutdown
src/lib.rs       the Lisp-facing surface
lisp/            cooked-glyph.el      box-drawing rasterizer; no terminal in it
                 cooked.el            state, rendering, the drain, OSC handlers
                 cooked-completion.el both completion backends
                 cooked-mode.el       keymaps, commands, starting a shell
                 cooked-evil.el       opt-in
                 cooked-osc-eval.el   opt-in
shell-integration/  bash, zsh, fish
tests/           cooked-tests.el loads the suite; the rest are split by subject
```

The Lisp files stack in that order, and the direction is load-bearing: `cooked.el`
owns the state and the policy derived from it — including who owns the keyboard,
which rendering has to ask on every drain — while `cooked-mode.el` binds keys to
it. Everything `cooked.el` calls upward is a notification that something changed,
never a question, and the list of those is at the top of the file.

`cooked-glyph.el` sits below all of it and knows nothing about terminals: a shape
descriptor and a pixel size in, raw XBM bits out, which is why the pixel-level
tests can assert against it without starting a session.

Scrollback lives in the Emacs buffer, not in Rust: rows leaving the emulator's screen are
handed over once and become ordinary buffer text.

## Platforms

Linux and macOS. `src/compat/` holds one module per platform, and the rule there is that
each gets the best facility it actually has rather than everything being levelled down to
the intersection:

| | Linux | macOS |
|---|---|---|
| slave path | `ptsname_r`, reentrant | `ptsname`, copied out immediately |
| wake pipe | `pipe2`, close-on-exec atomically | `pipe` then `fcntl`, with the window that implies |
| `TIOCSCTTY`, `TIOCSWINSZ` | from `libc` | defined locally; neither libc nor nix has them for Apple |

PATH lookup happens in the parent rather than via `execvpe`, which is a glibc extension
with no macOS equivalent — and doing it before the fork turns "command not found" into an
error you can see instead of a session that appears and immediately exits 127.

A new platform is usually one short file in `src/compat/`; the build fails with a message
saying so rather than emitting forty confusing errors.

## Tests

```sh
cargo test
emacs -Q --batch -L lisp -L tests -l ert \
      -l cooked-tests.el -f ert-run-tests-batch-and-exit
```

The end-to-end suite drives real children: `cat` for the cooked path, `stty -echo` for
secrets, and a real interactive `bash` for the OSC 133 path. Each subject also loads
on its own, which is what you want while working on one — swap `cooked-tests.el` for
`cooked-tests-glyph.el`, `-render.el`, `-input.el`, `-osc.el`, `-completion.el` or
`-session.el`.

`-Q` is deliberate — the suite must not inherit your configuration — but that also means
an optional package it tests against is not on `load-path` just because you have it
installed. The helpers go looking in the usual install locations themselves, so the
command above covers the `evil` tests too rather than skipping them. If evil genuinely
cannot be found the run says so on the first line, because a suite that quietly tests
less than you think is worse than one that fails: these tests skipped silently for long
enough to let a broken one read as passing.

## Status

Working: emulator core (SGR/truecolor, styled and coloured underlines, scroll regions, alt
screen, wide chars, combining marks, DEC graphics, background colour erase, insert mode,
autowrap control, mouse mode tracking, alternate scroll, focus reporting, synchronized
output, cursor shape, OSC 0/2/7/8/10/11/12/99/133, modifyOtherKeys and the kitty keyboard
protocol, DECRQM), termios state machine, secret prompts, scrollback, resize, per-command
exit codes, read-only transcript, output folding, evil integration, mode-line indicator
for peeking, comint's command set and input ring.

Images: the kitty graphics protocol (including `o=z` compression), sixel, and iTerm2's
`OSC 1337` inline images. All three land as real Emacs images, one slice per cell, so
text can overwrite them and they survive scrolling and rewrap. Not implemented, and
declined out loud so a client can fall back: kitty's transmission by file, temp file or
shared memory (`t=f`/`t=t`/`t=s` — reading a path a child names is a decision about
trust, not a decode), unicode placeholders, animation and z-index.

Not yet: `vttest`-level conformance beyond the common paths.

## Completion

TAB at a prompt is `completion-at-point`, so corfu, cape, consult and friends work
here as they do anywhere else. What they are offered comes from zsh itself:

```sh
git checkout <TAB>      # branches, with their tip commits
ssh <TAB>               # hosts from your config and known_hosts
kill <TAB>              # processes, with their command lines
ls --<TAB>              # flags, with descriptions
```

The line being edited lives in Emacs and ZLE's buffer is empty, so this cannot work
by forwarding TAB. The shell integration binds a widget to a private key sequence;
Emacs sends the pending line with it, the widget runs the real completion system over
that line with `compadd` shadowed to capture what it would have offered, and answers
over OSC 51;C. Nothing is inserted and nothing is listed in the shell, and the ZLE
buffer is restored before the widget returns, so the prompt does not flicker.

The table is dynamic: each word typed into it asks the shell again rather than
filtering the first answer, because what the shell offers *changes* as the line grows
— `git checkout ` offers branches, and a `-` turns that into flags — and because a
long list arrives truncated, so a candidate can be past the end of it until you narrow
it. A query costs on the order of 20 ms.

Emacs sends a request only after the shell has announced — at every new ZLE line —
that its widget is bound and reading. A shell without the integration is never sent
anything, which matters: to bash, a nested `zsh -f`, or the far end of an ssh, the
request would just be a line of input.

Everything else falls back to completing in Emacs — programs on `PATH` for the first
word, file names after it — which is also what happens when a completer is slower than
`cooked-completion-timeout`. `cooked-completion-backend` picks between them: `shell`
(the default, falling back), `native`, or `both`.

## Talking back to Emacs

The shell can ask the Emacs that is running it to do things:

```sh
find_file src/main.rs        # opens it in the same Emacs
magit .                      # magit-status on the repo
echo hi | osc_copy           # onto the kill ring, works over ssh
```

That is OSC 51;E, vterm's protocol, so existing vterm shell configuration mostly
works — guard on `[[ "$TERM_PROGRAM" == cooked ]]`, which is how a shell tells it
is talking to us, and rename `osc_vterm_eval` to `osc_emacs_eval`. Children are
also handed `TERM_PROGRAM_VERSION`, straight from the version the native core was
built with.

**This is a command channel driven by bytes on the terminal**, so it is off until you
ask for it with `(require 'cooked-osc-eval)`. Anything that can write to the terminal
can pull the trigger: `cat` of a hostile file, output from a compromised host, a build
log quoting attacker-controlled text. Being a separate file is the point — you should
buy that risk deliberately rather than inherit it.

Once loaded, `cooked-eval-commands` maps names to functions and nothing outside it
runs — no `intern` of whatever arrived. `compile` and `recompile` are deliberately
absent, since they execute arbitrary shell commands; opt in only if you accept that:

```elisp
(add-to-list 'cooked-eval-commands '("compile" . compile))
```

`magit-status` is in the default list and deserves a second look: `git status` runs
`core.fsmonitor` from the target repository's own `.git/config`, so pointing it at a
repo somebody else chose is closer to `compile` than it looks.

OSC 52 puts text on the kill ring, up to `cooked-clipboard-max-size`. Clipboard *reads*
are never answered — replying to a query would hand your clipboard to whatever asked.
Set `cooked-clipboard-write` to nil to refuse writes too.

## Adding your own escape sequences

Every OSC except 133 is passed through verbatim, so teaching cooked a new sequence
is Lisp, not Rust:

```elisp
(add-to-list 'cooked-osc-handlers
             (cons 1337 (lambda (parts) (message "iTerm2 says %S" parts))))
```

The native core only interprets sequences that change the terminal itself — the
alternate screen, mouse and paste modes, device replies. What a sequence *means to
Emacs* is Emacs' business. OSC 133 is the one exception: it decides who owns the
keyboard, which is core behaviour rather than user-extensible policy.

A handler can *answer* as well as observe. `cooked--reply-osc` frames the reply, so no
Lisp splices control bytes by hand and no payload can close the sequence early:

```elisp
(add-to-list 'cooked-osc-handlers
             (cons 1337 (lambda (_parts)
                          (cooked--reply-osc cooked--session 1337 "hello"
                                             cooked--osc-bell-terminated))))
```

Pass `cooked--osc-bell-terminated` through rather than picking a terminator. xterm
echoes the one the query used, and a client that asked with BEL and scans its input for
BEL will hang on an ST-terminated answer — the whole failure mode being avoided.

The default colours work this way. Theme-aware programs ask for the background with OSC
11 before choosing a light or dark palette, and only Emacs can answer: the core has no
default foreground or background at all, since the real value is whatever the buffer's
`default` face resolves to under your theme. OSC 10, 11 and 12 are answered from there,
so the reply tracks your theme.

Requests that *set* a colour are refused unless you set `cooked-allow-color-set`;
anything that can write to the terminal can send one. When enabled the change is a
buffer-local face remapping — the child repaints its own terminal, not your whole
Emacs — and OSC 110/111/112 put the theme's colours back.

## UI notes

- **Transcript, not a rectangle.** Blank screen rows below the cursor are trimmed, so the
  buffer reads like a shell transcript rather than carrying two dozen empty lines.
- **Read-only above the input.** Scrollback and rendered screen carry `read-only` with
  `front-sticky`/`rear-nonsticky` chosen so the transcript refuses edits while typing at
  the start of the input line is still accepted.
- **Colours follow your theme.** ANSI 0–15 resolve through the `ansi-color-*` faces, so a
  theme that styles those wins; `cooked-color-names` is only a fallback. One `face`
  property carries a run: comint leaves `font-lock-defaults` at `(nil t)`, under which the
  first fontification strips a bare `face`, so `cooked-mode` clears it.
- **Evil.** With `cooked-evil-integration`, evil is put in Emacs state whenever the child
  owns the keyboard and returns to insert at a prompt; normal-state `RET` stays plain
  `evil-ret`, exactly as in any other buffer. comint commands are remapped, so
  `evil-collection`'s `repl-submit` and arrow-key history bindings reach
  `cooked-send-input` and the child's own history without knowing cooked exists. Stepping
  out of insert state gives point a visible cursor even where the child has hidden its
  own, since point is then the only cursor there is. `C-z` out of a full-screen program
  lands in normal state rather than in whatever state you were in when you started it —
  insert state, usually, which forwards, and so looked as though `C-z` had done nothing.
  `C-z` reaches Emacs from anywhere, same as in any other evil buffer — see
  [Keybindings](#keybindings).
- **Commands are records.** `C-c C-p`/`C-c C-n` move between prompts and `C-c TAB` folds
  output. A command that printed nothing still gets a record, which text properties alone
  cannot represent — and navigation lands on the *prompt* rather than on the output for
  exactly that reason: a quiet command's output begins where the next prompt does, so
  walking output starts stepped over every command that printed nothing, failures
  included.
- **`evil` command text objects.** In a cooked buffer `vic` selects a command's output and
  `vac` takes the prompt and the command line with it, both linewise; `[[`/`]]` move
  between prompts. The regions come from the OSC 133 marks, so `yac` on a build copies
  exactly what was run and what it printed, and works while it is still running. Scoped to
  `cooked-mode` through evil's own auxiliary keymaps, so `iw`, `ip` and `i"` keep meaning
  what they mean — see `cooked-evil-command-text-object` and `cooked-evil-section-motions`.
- **Peeking is read-only and look-only.** The mode line grows a `peek` tag; the buffer is
  read-only for the duration, so an edit command errors immediately instead of landing on
  text that goes nowhere; and typing, `RET`, or any of cooked's own commands that write to
  the child end it and forward what was pressed, rather than requiring a separate step back.

## Showing images

Commands that draw a picture in a cooked buffer. `--passthrough none` matters for chafa:
it otherwise wraps its output for tmux and screen, and cooked is neither.

```sh
# kitty graphics, sixel, and whichever chafa detects on its own
chafa -f kitty --passthrough none -s 60x20 kitty-test.png
chafa -f sixel --passthrough none -s 60x20 kitty-test.png
chafa          --passthrough none -s 60x20 kitty-test.png

# iTerm2 inline images -- no encoder needed, just base64
printf '\033]1337;File=inline=1:%s\a' "$(base64 -w0 kitty-test.png)"

# ...where width= and height= are counted in cells
printf '\033]1337;File=inline=1;width=20;height=6:%s\a' "$(base64 -w0 kitty-test.png)"

# an animation, one transmission per frame
chafa -f sixel --passthrough none -s 40x20 something.gif

# video, at whatever frame rate the terminal can keep up with
mpv --vo=sixel --profile=sw-fast clip.mp4
mpv --vo=kitty --profile=sw-fast clip.mp4
```

Running `chafa` with no `-f` is the one worth doing at least once: it asks the terminal
what it supports and picks. That covers the kitty capability probe (`a=q`) and the primary
DA, which is the part a terminal can get wrong while rendering perfectly — answer neither
and every well-behaved producer falls back to ASCII art.

A plot, which is the reason to want any of this:

```sh
python3 <<'EOF'
import io, sys, base64
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
fig, ax = plt.subplots(figsize=(6, 3))
ax.plot([1, 4, 2, 8, 5, 7]); ax.set_title("cooked")
buf = io.BytesIO(); fig.savefig(buf, format="png", dpi=100)
sys.stdout.write("\033]1337;File=inline=1:%s\a" % base64.b64encode(buf.getvalue()).decode())
EOF
```

`o=z`, the zlib-compressed kitty transmission that kitty's own `icat` sends by default,
has no producer installable here, so it takes a few lines. The 4096-byte chunking is the
protocol's rule rather than ours; one unchunked APC works too, up to the parser's 8MB.

```sh
python3 - kitty-test.png <<'EOF'
import sys, zlib, base64
data = base64.b64encode(zlib.compress(open(sys.argv[1], "rb").read(), 9)).decode()
first = True
while data:
    chunk, data = data[:4096], data[4096:]
    control = "a=T,f=100,o=z,i=1," if first else ""
    sys.stdout.write("\033_G%sm=%d;%s\033\\" % (control, 1 if data else 0, chunk))
    first = False
EOF
```

**When nothing appears.** These paths draw a whole picture or nothing at all, so the
useful question is whether the terminal refused *out loud* or dropped the transmission
silently — and the answer goes to the child, not the screen. Both of these should draw
nothing, reply, and not hang:

```sh
printf '\033_Ga=T,f=100,t=f,i=7;L3RtcC9mb28ucG5n\033\\'   # ENOTSUPPORTED:medium
printf '\033_Ga=T,f=24,s=65535,v=65535,i=8;AAAA\033\\'    # EINVAL:dimensions
```
