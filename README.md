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

While the child owns the keyboard, `C-c` is the only reserved prefix — everything else,
ESC included, is forwarded, so `M-x` reaches the child exactly as in any terminal. That is
what you want inside vim and not at all what you want when you meant Emacs, so `C-c M-x`
is the way back out; it runs whatever you have bound `M-x` to.

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

At a prompt, where Emacs owns the line, Shift+RET does something more useful: it inserts
a newline into the pending input so you can compose a multi-line command, which is then
submitted as one bracketed paste rather than as several separate lines.

## Terminfo

We ship `terminfo/cooked.ti` and default `TERM` to `cooked-256color` — what alacritty,
wezterm, foot and Emacs' own `term.el` all do. Claiming to be xterm is a lie with
consequences in both directions: xterm-256color does not advertise direct colour, so
applications drop to 256 unless they happen to honour the `COLORTERM` convention, and it
*does* advertise capabilities we ignore. Our entry corrects both:

| Capability | Change | Why |
|---|---|---|
| `Tc`, `setrgbf`, `setrgbb` | added | we support direct colour; xterm-256color does not declare it |
| `ccc`, `initc` | removed | palette redefinition via OSC 4, which we do not parse |
| `flash` | removed | visual bell via DECSCNM, which we do not implement |

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
lisp/            cooked.el          core and rendering
                 cooked-mode.el     interaction
                 cooked-evil.el     opt-in
                 cooked-osc-eval.el opt-in
shell-integration/  bash, zsh, fish
```

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
secrets, and a real interactive `bash` for the OSC 133 path.

## Status

Working: emulator core (SGR/truecolor, scroll regions, alt screen, wide chars, combining
marks, DEC graphics, mouse mode tracking, OSC 0/2/7/8/10/11/12/133, modifyOtherKeys and the kitty
keyboard protocol), termios state machine, secret prompts, scrollback, resize,
per-command exit codes, read-only transcript, output folding, evil integration.

Not yet: sixel/kitty graphics, comint history integration, and `vttest`-level conformance
beyond the common paths.

## Talking back to Emacs

The shell can ask the Emacs that is running it to do things:

```sh
find_file src/main.rs        # opens it in the same Emacs
magit .                      # magit-status on the repo
echo hi | osc_copy           # onto the kill ring, works over ssh
clear                        # clears the scrollback too, not just the screen
```

That is OSC 51;E, vterm's protocol, so existing vterm shell configuration mostly
works — change the guard from `[[ "$INSIDE_EMACS" != vterm ]]` to
`[[ "$INSIDE_EMACS" != *cooked* ]]` and rename `osc_vterm_eval` to
`osc_emacs_eval`.

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
  theme that styles those wins; `cooked-color-names` is only a fallback. Both `face` and
  `font-lock-face` are set — comint leaves `font-lock-defaults` at `(nil t)`, so a bare
  `face` property is stripped the first time the buffer is fontified.
- **Evil.** With `cooked-evil-integration`, evil is put in Emacs state whenever the child
  owns the keyboard and returns to insert at a prompt; `RET` submits from normal state.
  comint commands are remapped, so `evil-collection`'s `repl-submit` binding reaches
  `cooked-send-input` without knowing cooked exists.
- **Commands are records.** `C-c C-p`/`C-c C-n` navigate them and `C-c TAB` folds output.
  A command that printed nothing still gets a record, which text properties alone cannot
  represent.
