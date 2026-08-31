# cooked

A terminal emulator for Emacs that knows who should own the keyboard, and hands it back
when the program you are running wants a line of text rather than keystrokes.

## What this is

Type a command at a shell prompt and you are editing a line: Emacs owns it, with your
keybindings, your kill ring, your `undo`, your completion UI. Run `htop` and every key
goes straight through, because that is what `htop` needs. Run `ssh` and get a password
prompt, and cooked asks for it in the minibuffer — where it can be answered from
auth-source instead of typed.

Nobody toggles a mode to make that happen. cooked works it out.

## Why you might care

Every other terminal in Emacs treats the child as an opaque rectangle of characters and
has to ask *you* which mode you are in. cooked reads two signals the terminal already
carries and answers the question itself:

**1. The kernel's line discipline.** cooked allocates the pty rather than letting Emacs
do it, so `tcgetattr` on the master reports the child's own termios. Three states,
exactly disjoint:

| ICANON | ECHO | What it means | What cooked does |
|---|---|---|---|
| on | on | a canonical read (`cat`, a `read` loop) | Emacs owns the input line |
| off | off | a full-screen program (`vim`, `htop`) | keys pass straight through |
| **on** | **off** | `getpass(3)` — a secret | prompt in the minibuffer |

Linux gives no push notification for this: `TIOCPKT` reports flow-control and `EXTPROC`
transitions only, not `ICANON`/`ECHO` (measured, not assumed). So the mode is sampled on
the reader thread's existing poll timeout and after every read, and Emacs is woken only
when it actually changes.

**2. OSC 133 semantic prompts.** An interactive shell puts the tty in raw mode the moment
readline or ZLE starts, so the first signal cannot see a shell prompt — the shell has to
say so itself: `133;A` prompt start, `133;B` input start, `133;C` output start,
`133;D;<code>` done. An explicit mark always beats the inferred termios state.

Between them, cooked knows which program is reading, in what mode, where each command
began and ended, how it exited, and which rows were wrapped rather than
newline-terminated. Most of what it can do that a terminal cannot is spending that
knowledge:

- **The input line is a buffer.** Your keybindings and your completion UI, on the line
  you are typing, with no forwarding involved.
- **Passwords land in the minibuffer**, so `cooked-password-function` can answer them
  from auth-source or `pass`. No ordinary terminal can do this, because it never learns
  a password was being asked for.
- **`next-error` over one command's output.** `M-g M-n` after a failed build walks *that*
  build's errors, scoped by its OSC 133 marks rather than by the whole scrollback.
- **Per-command records** — rerun, copy the command, copy just its output, jump between
  commands, a fringe marker coloured by exit code.
- **Real completion from your shell**, over a side channel, so `git checkout <TAB>` offers
  branches and `kill <TAB>` offers processes with their command lines.
- **Scrollback that rewraps**, because cooked knows which rows were continuations and can
  store them as one logical line for Emacs to wrap.

## Compared with vterm and eat

| | cooked | vterm | eat |
|---|---|---|---|
| Emulator | Rust module | C module (libvterm) | Emacs Lisp |
| Speed | fast | fast | slow on floods |
| Build | `cargo`, automatic on first use | `cmake` + libvterm | none, pure Lisp |
| Knows who owns the keyboard | termios + OSC 133 | no | no |
| Getting an Emacs keymap back | happens on its own at a prompt | `vterm-copy-mode`, by hand — and read-only | one of four modes, by hand |
| Peeking while a program runs | redraw pauses, the child keeps running | the child is stalled (`tcflow`) | the display keeps scrolling |
| Editing the command line | ordinary Emacs editing | forwarded to the shell | forwarded to the shell |
| Password prompts | minibuffer, answerable from auth-source | inline, like any terminal | inline, like any terminal |
| Per-command structure | OSC 133 records: extents, exit codes | no | no |
| Box-drawing glyphs | rasterized to tile the cell exactly | left to the font | left to the font |
| Letting the child drive Emacs | a closed set of verbs; arbitrary names need a second opt-in | any name in `vterm-eval-cmds`, on by default | a closed set of verbs |

The short version: **eat** is the most portable — pure Lisp, nothing to compile — and pays
for it in throughput. **vterm** is fast and mature, but is a rectangle of characters with
no idea where one command ends and the next begins, so every question about structure
becomes a prompt regexp. **cooked** is fast *and* structured, and costs you a Rust
toolchain.

The peeking row is the threading model showing through. vterm's emulator is a C module
called from Emacs' thread and eat's is Lisp, so in both, nothing parses while Emacs is
busy — which makes "freeze the display" and "keep consuming output" mutually exclusive,
and stopping the child the only safe way to freeze. cooked's reader thread parses into the
grid on its own, so Emacs can stop *applying* deltas while the emulator stays current: you
can read a scrolling build log without stalling the build. It is not unbounded — at
`BACKLOG_HIGH_WATER` the reader stops pulling and the child blocks on its own writes — but
that is a far larger buffer than the pty's, and only chatty children reach it.

The mode-switching difference is the one you feel hourly. vterm and eat forward almost
everything and give you a manual way out, because neither has a way to know who owns the
keyboard other than you telling it. cooked does know, so the common case — type a
command, read its output — never involves a mode switch at all. A manual peek
(`C-c C-v`) exists only for the case the signal genuinely cannot help with: a full-screen
program that has taken the whole keyboard.

## Installing

You need **Emacs 28.1+** built with dynamic module support, and a **Rust toolchain**
(1.85+, for edition 2024). Linux and macOS.

The native core is built with `cargo` on first use and rebuilt when the Rust sources are
newer than the artifact, so there is no separate build step to remember. The first
`M-x cooked` after installing will take a minute and say so.

### straight.el

```elisp
(use-package cooked
  :straight (cooked :type git :host github :repo "vodik/cooked"
                    :files ("lisp/*.el"))
  :commands (cooked cooked-other-window))
```

### elpaca

```elisp
(use-package cooked
  :ensure (cooked :host github :repo "vodik/cooked" :files ("lisp/*.el"))
  :commands (cooked cooked-other-window))
```

### package-vc (Emacs 29+)

```elisp
(use-package cooked
  :vc (:url "https://github.com/vodik/cooked" :lisp-dir "lisp" :rev :newest)
  :commands (cooked cooked-other-window))
```

### From a checkout

```elisp
(use-package cooked
  :load-path "/path/to/cooked/lisp"
  :commands (cooked cooked-other-window))
```

Every one of these keeps the whole repository on disk, which matters: the Lisp finds
`Cargo.toml`, `terminfo/` and `shell-integration/` by walking up from its own resolved
location, so a `:files` clause that ships only the Lisp is fine, but a hand-rolled
install that copies the `.el` files somewhere on their own is not. Point
`cooked-native-module` at a prebuilt artifact if you package cooked that way.

### Trying it without installing

```sh
cargo build --release
emacs -Q -L lisp -l cooked-mode -f cooked
```

### The optional layers

Seven things are separate files you `require`, not settings — because a setting that gates
code already loaded and running is a switch in name only:

```elisp
(use-package cooked
  :straight (cooked :type git :host github :repo "vodik/cooked"
                    :files ("lisp/*.el"))
  :commands (cooked cooked-other-window
             cooked-project cooked-project-other-window
             cooked-here cooked-here-other-window)
  :config
  (require 'cooked-evil)                 ; evil state syncing, command text objects
  (require 'cooked-osc-eval)             ; the OSC 51 command channel
  (require 'cooked-shell-completion)     ; zsh's own completion, over OSC 51;C
  (require 'cooked-file-link)            ; file names in output become links
  (require 'cooked-next-error)           ; M-g M-n through a command's output
  (require 'cooked-command-decorations)  ; a fringe marker per command, coloured by exit
  (require 'cooked-project))             ; a session scoped to the project root
```

`cooked-osc-eval` is the one to read before enabling: it lets the child ask Emacs to
do things, and a terminal will print whatever it is given — `cat` of a hostile file,
output from a compromised host over ssh. What it grants is a *closed set of verbs*
cooked implements itself — visit a file, open Dired, clear the scrollback — each of
which checks its own argument, because `find-file` is a reasonable thing to grant right
up until the name is `/ssh:attacker.example:/x` and visiting it dials out. Arbitrary
named commands live behind one further opt-in, `cooked-eval-commands`, which is empty
until you fill it. The shell half is separate again — `eval-helpers`, below — so
requiring this on its own gives you a channel with nothing yet calling it. See its
commentary and [docs/FEATURES.md](docs/FEATURES.md).

### Shell integration

cooked injects the snippet into the zsh and bash shells it starts, so a local session
needs no setup. Set `cooked-shell-integration` to `none` if you would rather it did
not, or name a shell to force a scheme the basename guess would have missed.

Injection reaches exactly the shell cooked spawned, and nothing else. Every `ssh`,
every `sudo -i`, every `docker exec`, every nested `zsh -f` and every `exec zsh` lands
outside it. That is the shape of the mechanism rather than a wart to be fixed, and it
is why the line in your own rc is the contract and injection is only the convenience:

```zsh
[[ $TERM_PROGRAM == cooked ]] && source /path/to/cooked/shell-integration/cooked.zsh
```

**The same line works at the far end of an `ssh`**, which is the whole reason it is a
line rather than something cooked arranges for you. Sourcing twice is a no-op, so
having the line *and* injection is the supported arrangement rather than a conflict.
Getting `TERM_PROGRAM` to the far end is `SendEnv`/`AcceptEnv`, and is yours to
configure. Where a shell stays unmarked cooked says `bare` in the mode line, and says
it once in words.

#### The marks, and what each one buys

If you would rather write the marks yourself — into a prompt you already maintain, or
on a host where there is no file to source — this is the whole of what cooked reads:

| Mark | Emitted | What it buys |
|---|---|---|
| `OSC 133;A` | from precmd, before the prompt is drawn | where the prompt began: prompt-to-prompt navigation, the outer half of the evil command text object, and a command record that starts at its prompt rather than at its output |
| `OSC 133;B` | **inside `PS1`**, at the end | the input line becomes an Emacs buffer — your keybindings, your kill ring, your completion UI. The one mark that changes who owns the keyboard |
| `OSC 133;A;k=s` | **inside `PS2`**, at the start, with a `B` after it | the same, for the continuation lines of a multi-line construct. `k=s` is what stops it being read as a fresh prompt, so the command record stays filed under the prompt the construct was typed at |
| `OSC 133;C` | from preexec | where the command's output begins. Without it there is no command record at all, and so no `next-error`, no rerun, no copy-just-the-output |
| `OSC 133;D;<code>` | from precmd, **first**, before `$?` is clobbered | the exit status: the fringe marker's colour, and telling a failed command from a successful one |
| `OSC 7;file://host/path` | from precmd | not a 133 mark, but the same hook: tracks `default-directory`, and tells cooked the shell is on this machine |

The two placement rules are the ones that fail silently. `B` has to live in `PS1`
rather than be printed from precmd, because precmd runs *before* the prompt is drawn
and a printed mark would land ahead of the prompt text — leaving Emacs to treat the
prompt itself as input. `D` has to come from the first precmd hook, or the status it
reports belongs to whichever hook ran before it. The shipped snippets handle both, and
re-append `B` every prompt because powerlevel10k, starship and most oh-my-zsh themes
rebuild `PS1` from their own precmd and would otherwise drop it.

`PS2` is where the marks have to travel *inside* the prompt string in both shells,
including the `A`: there is no hook that runs before a continuation prompt is drawn.
What cooked does with `k=`, and what it does with a mark sequence that is not the tidy
`A B C D` above, is in
[docs/FEATURES.md](docs/FEATURES.md#what-the-prompt-marks-are-read-to-mean).

One thing the marks do not buy on their own: a `B` at the far end of an `ssh` does not
hand Emacs the line by itself. A mark is a claim, and lifting the line out of a pty
that no line editor is reading is how keystrokes get eaten — so cooked wants the claim
corroborated, either by the shell being on this machine (which `OSC 7` establishes) or
by the per-line `OSC 51;CH` announcement the shipped snippets emit. Unlicensed, a
marked prompt keeps its own line editor and everything else the marks buy — extents,
exit codes, `next-error`, rerun — works unchanged.

#### Turning parts off

`cooked-shell-integration-features` says what a loaded snippet actually does, which is
a separate question from whether cooked put it there. It defaults to
`(marks input-mark cwd announce completion title)`; only `eval-helpers` is off, because
it is the one that reaches your editor rather than your prompt.

`input-mark` is `133;B` and is its own entry rather than part of `marks` because it is
the only one that changes who owns the keyboard. Dropping it keeps the extents, the
exit codes and `next-error` while leaving the line to the shell's own editor.

The list is handed to the shell verbatim in `COOKED_SHELL_INTEGRATION_FEATURES`, and your rc may
edit it before the snippet reads it — which is how a prompt that already emits its own
OSC 133 stands cooked's half down without giving up the rest:

```zsh
COOKED_SHELL_INTEGRATION_FEATURES="${COOKED_SHELL_INTEGRATION_FEATURES-} no-marks"
```

Subtraction wins over naming, so the append is always the last word. The snippet defers
its own setup to the first prompt so that your rc, which runs earlier, has somewhere to
stand. Because the variable is exported whether or not anything was injected, the same
list governs a shell you sourced the snippet in by hand.

#### The files

| File | What it is | How to get it |
|---|---|---|
| `shell-integration/cooked.{zsh,bash,fish}` | the marks, OSC 7, the announcement, and the optional helpers | injected for zsh and bash; source it anywhere else |
| `shell-integration/cooked-completion.{zsh,bash}` | the completion capture, answering `TAB` from the shell's own completion | injected beside the core when `completion` is in the feature list *and* `cooked-shell-completion` is loaded; source it after the core otherwise |

zsh and bash are exercised by the test suite. fish is written but unverified, which is
why it is not injected — see the known gaps in [docs/ROADMAP.md](docs/ROADMAP.md).

### The OSC 51 channels

One OSC number carries two unrelated things, and each needs a half in Emacs and a half
in the shell.

**Completion** is `OSC 51;C`. The shell announces `51;CH` at every new line — that is
in the core snippet, because Emacs reads it as a license to own the input line as much
as a completion token — and answers requests from the capture file. Load the Emacs half
with `(require 'cooked-shell-completion)` and TAB is answered by zsh's or bash's own
completion system rather than by Emacs' table. A shell that announces but cannot answer
keeps its editable line and is simply never asked.

**Commands** are `OSC 51;E`. This is a channel the child writes to, so it does nothing
until you ask for it with `(require 'cooked-osc-eval)` — anything that reaches your
terminal can pull the trigger, including `cat` of a hostile file or output from a
compromised host. With `eval-helpers` in the feature list the shell gets `find_file`,
`find_file_other_window`, `dired` and `osc_copy`, which are cooked's own code and check
their own arguments, plus one escape hatch:

```zsh
alias magit='cooked_send magit-status'
```

`cooked_send` names an arbitrary command, which Emacs looks up in `cooked-eval-commands`
and refuses unless you put it there:

```elisp
(add-to-list 'cooked-eval-commands '("magit-status" . magit-status))
```

Nothing is aliased for you, because an alias that shadows a real command reads very
differently as something you wrote than as something cooked put in your shell. The
allowlist is empty by default, and the reason to keep it small generalizes: naming a
command settles *which* function runs and can say nothing about *what it is pointed at*,
while the argument arrives from the byte stream — so anything you add must treat its
argument as attacker-chosen. `compile` is the honest example, since adding it turns any
text that reaches your terminal into remote code execution.

The helpers are local-only either way: the verbs carry paths, and Emacs resolves them
with no idea the shell is on another host, so `find_file ./notes.md` from behind an
`ssh` opens whatever local file bears that name. [docs/FEATURES.md](docs/FEATURES.md)
has the wire format and the full verb table.

## Terminal coverage

**Text and rendition.** SGR including truecolor, styled and coloured underlines (`SGR 4:x`
and `SGR 58`), insert mode, autowrap control, background colour erase, DEC line-drawing,
wide characters, combining marks, scroll regions, the alternate screen.

**Input.** modifyOtherKeys and the kitty keyboard protocol, bracketed paste, focus
reporting, mouse press/release/wheel with SGR encoding, alternate scroll.

**OSC.** 0 and 2 (title, with the title stack), 7 (working directory), 8 (hyperlinks),
10/11/12 (foreground, background and cursor colour, queried and set) with 110/111/112 to
reset them, 52 (clipboard), 99 and 777 (desktop notifications, both conventions), 133
(semantic prompts), 1337 (iTerm2, whose `File=` is handled and whose other verbs are
passed through), and 51 (the command and completion channels, both opt-in; the command
half is a closed set of verbs rather than a name to look up).

Everything but OSC 133 and OSC 8 reaches Lisp verbatim, so `cooked-osc-handlers` is a
documented extension point: teaching cooked a new sequence is an entry in an alist, not a
change to the native core.

**Links.** Two kinds, and they meet in `cooked-link.el`. OSC 8 is first-class — the core
attaches a link id to the covered cells and carries it through wraps, rewraps and
scrollback eviction the way it carries an underline colour, so nothing is guessed. Text
that merely *looks* like a URL is linkified by `goto-address` over freshly-rendered rows,
which brings `follow-link`, `help-echo` and your own `goto-address` customisations with
it. With `cooked-file-link` loaded, file names in output become links too.

**Other.** Synchronized output (mode 2026), cursor shape, DECRQM, DECSTR and RIS.

**Box drawing.** U+2500–U+259F — `─│┌┐└┘├┤┬┴┼`, the heavy, double, dashed and arc
variants, the diagonals, and the block and shade elements `▀▄█▌▐░▒▓` — are not left to
the font. Most monospace fonts draw them with glyph-to-glyph inconsistencies that are
invisible in prose and glaring in `htop`, `ranger` or `fzf`, where they are supposed to
form continuous borders. The core classifies each codepoint into a compact shape
descriptor and `cooked-glyph.el` rasterizes it to XBM at the current cell size, so the
pieces tile exactly and inherit the cell's colours.

VTE, kitty and alacritty all stopped trusting the font here for the same reason. cooked
appears to be the first Emacs terminal to do it: vterm and eat both hand these codepoints
to the font like any other character.

**Images.** The kitty graphics protocol (including `o=z` compression), sixel, and iTerm2's
`OSC 1337` inline images. All three become real Emacs images, one slice per cell, so text
can overwrite them and they survive scrolling and rewrap. Declined out loud, so a client
can fall back rather than hang: kitty's transmission by file, temp file or shared memory
(`t=f`/`t=t`/`t=s` — reading a path a child names is a decision about trust, not a
decode), unicode placeholders, animation, and z-index.

**Terminfo.** `terminfo/cooked.ti` is written out in full rather than derived with
`use=xterm-256color`, so it describes what cooked actually implements. `TERM` defaults to
`cooked-256color`. See [docs/TERMINFO.md](docs/TERMINFO.md).

**Reflow.** Narrowing the window rewraps rather than truncates, on the live screen as
well as in scrollback. `Row::wrapped` records which rows were continuations, so the lines
the child actually printed can be recovered and chunked again at the new width — which
makes the round trip work: narrow and widen back and you get the original layout, because
the wrap provenance was preserved rather than destroyed. Wide characters are never split,
the cursor keeps its place in the text, and marks and images move with it. Two deliberate
exceptions: a scroll region suppresses the rewrap, and the alternate screen is clamped
instead, since a full-screen program repaints itself anyway.

**Not implemented.** Mouse drag and motion reporting (modes 1002/1003 are tracked, but
Emacs drag events are not forwarded). `vttest`-level conformance beyond the common paths;
vim, htop, tmux and less work, and the long tail is untested. Full list in
[docs/ROADMAP.md](docs/ROADMAP.md).

## Keyboard

While the child owns the keyboard, `C-c` is the only prefix cooked always reserves for
itself. Everything else, ESC included, is forwarded, so `M-x` reaches the child exactly as
it would in any terminal. `C-c M-x` is the way back out regardless of what the child is
doing; it runs whatever you have bound `M-x` to.

At a prompt, where Emacs owns the line, ordinary editing applies and Shift+RET inserts a
newline into the pending input, so a multi-line command can be composed and submitted as
one bracketed paste.

[docs/KEYBOARD.md](docs/KEYBOARD.md) has the rest: what else stays with Emacs, how
modified keys are spelled, per-program overrides, and how to reach an arbitrary command or
`evil` normal state without waiting for the child to give the keyboard back.

## Compatibility and overrides

Two escape hatches, for the two ways a program can be wrong about what the terminal will
accept. Both are consulted only while the child owns the keyboard, and both lose to a real
negotiation — if a program actually asks, via `CSI ? u`, the answer it gets is the truth.

`cooked-key-overrides` re-spells one named key for one program. `cooked-key-protocol-overrides`
is the blanket version: it makes every key behave as though the child had negotiated a
protocol it never asked about.

cooked ships exactly one rule, and it is the second kind:

```elisp
(defcustom cooked-key-protocol-overrides '(("\\`claude\\'" . kitty)) ...)
```

Claude Code decides whether the kitty keyboard protocol is available by looking at `TERM`
and `TERM_PROGRAM` and matching them against terminals it knows, rather than by asking.
It never sends `CSI ? u` — the query cooked stands ready to answer. So cooked, which
refuses to assume a protocol nobody negotiated, keeps sending classical encodings; and in
those, modified Return, Tab, Escape and Backspace do not exist at all, leaving `S-RET`
and `C-TAB` indistinguishable from plain `RET` and `TAB`.

Nothing else is wrong. Claude decodes the kitty sequences perfectly well once they
arrive — it simply never established that it could expect them. The override is the
missing half of a negotiation that was never started.

The fix cooked does *not* use is lying about `TERM`. Claiming to be one of the terminals
on Claude's list would work, and would undo the entire argument for shipping a terminfo
entry that describes what cooked actually implements. Configuring your keyboard is the
honest version of the same fix: it is a statement about what one program accepts, not
about what cooked is.

Add your own the same way — a regexp against the foreground program, or a predicate:

```elisp
(add-to-list 'cooked-key-protocol-overrides '("\\`fancy-tui\\'" . modify-other))
```

### Terminfo

There is nothing to install by hand. `TERM` defaults to `cooked-256color`, and the entry
is compiled into `~/.terminfo` on first use — no root needed — falling back to
`xterm-256color` with a message if `tic` is missing. Set `cooked-term-name` to nil to
present as `xterm-256color` always.

`TERMINFO` is exported alongside it, naming that directory. ncurses looks in
`~/.terminfo` by default, so this matters only where the default is wrong — and it is
wrong wherever `HOME` changes: `sudo`, `su -`, a service manager, a container mounting a
different home. It is set only when the compiled entry is really there, and never over a
`TERMINFO` you set yourself, since that variable is searched *first* and pointing it at a
database holding one entry is the one way to break a lookup that would otherwise work.

The one case that needs a hand is ssh, where the remote host has never heard of the entry:

```
M-x cooked-install-terminfo-remote RET host RET
```

That pipes `infocmp` through ssh into the remote `~/.terminfo`.

## On passwords

The secret never reaches the buffer, and the copies cooked makes of it are cleared: it
goes out as two writes rather than one concatenation, and the native core zeroes its byte
buffer afterwards.

That is the honest limit, and it is worth stating plainly. `read-passwd` builds the string
in Emacs' own heap; the garbage collector relocates and compacts small strings, so earlier
copies survive in freed blocks that `clear-string` never sees, and an auth-source backend
caches plaintext by design. cooked cannot promise a password leaves no trace in Emacs'
address space, and does not claim to.

## Documentation

| | |
|---|---|
| [Keyboard](docs/KEYBOARD.md) | what stays with Emacs, how modified keys are spelled, per-program overrides |
| [Features](docs/FEATURES.md) | completion, the OSC 51 command channel, links, the UI conventions |
| [Shell](docs/SHELL.md) | the shipped helpers, and writing your own on top of them |
| [Terminfo](docs/TERMINFO.md) | why we ship an entry, and every capability in it |
| [Images](docs/IMAGES.md) | kitty graphics, sixel, iTerm2 inline images |
| [Design](docs/DESIGN.md) | the grid/buffer seam and the reasoning behind it |
| [Roadmap](docs/ROADMAP.md) | what is missing, and where this could go |

## Layout

```
src/env.rs       hand-rolled emacs_env_28 bindings; catch_unwind at every boundary,
                 ABI size check at load, user-pointers tagged by finalizer
src/pty.rs       pty ownership via nix, setsid/TIOCSCTTY, termios -> Mode, bounded
                 reaping; child_exec stays raw libc and says why
src/emu/         cell/row/style, grid with damage tracking, vte-driven VT parser
src/emu/term/    the VT front end: mod (types, Term), csi, osc, graphics, state
src/session.rs   reader thread, coalesced wakeups, explicit idempotent shutdown
src/lib.rs       the Lisp-facing surface
lisp/            cooked-util.el             macros, session handle, the group
                 cooked-face.el             SGR attributes and colours as faces
                 cooked-glyph.el            box-drawing rasterizer; no terminal in it
                 cooked-deco.el             box glyphs and images as `display' props
                 cooked-link.el             URLs and OSC 8 hyperlinks
                 cooked.el                  state, rendering, the drain
                 cooked-osc.el              what an OSC means to Emacs
                 cooked-completion.el       the CAPF and the Emacs table
                 cooked-mouse.el            clicks and the wheel, when the child asked
                 cooked-mode.el             keymaps, commands, starting a shell
                 cooked-evil.el                 opt-in
                 cooked-osc-eval.el             opt-in
                 cooked-shell-completion.el     opt-in
                 cooked-file-link.el            opt-in
                 cooked-next-error.el           opt-in
                 cooked-command-decorations.el  opt-in
                 cooked-project.el              opt-in
shell-integration/  bash, zsh, fish, plus zsh's completion capture
docs/            DESIGN, KEYBOARD, FEATURES, TERMINFO, IMAGES, ROADMAP
tests/           cooked-tests.el loads the suite; the rest are split by subject
```

The Lisp files stack in that order, and the direction is load-bearing. `cooked.el` owns
the state and the policy derived from it — including who owns the keyboard, which
rendering has to ask on every drain — while `cooked-mode.el` binds keys to it. Everything
`cooked.el` calls upward is a notification that something changed, never a question, and
the list of those is at the top of the file.

`cooked-util.el` is the floor. `cooked-face.el` and `cooked-deco.el` are required *by*
`cooked.el`, so they cannot require it back for a macro — which is what the base layer
exists to prevent, rather than each of them growing its own copy.

`cooked-glyph.el` sits below all of it and knows nothing about terminals: a shape
descriptor and a pixel size in, raw XBM bits out, which is why the pixel-level tests can
assert against it without starting a session.

Scrollback lives in the Emacs buffer, not in Rust: rows leaving the emulator's screen are
handed over once and become ordinary buffer text. `cooked-scrollback-lines` caps how much
is kept.

[docs/DESIGN.md](docs/DESIGN.md) has the reasoning behind the parts that are not obvious
from the code — the seam between the grid and the buffer, why `cooked--apply` runs in the
order it does, and a handful of traps that each cost an afternoon.

## Platforms

Linux and macOS. `src/platform/` holds one module per platform, and the rule there is that
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

A new platform is usually one short file in `src/platform/`; the build fails with a
message saying so rather than emitting forty confusing errors.

## Hacking

```sh
make test          # cargo test, the ERT suite, clippy, byte-compilation
make lisp-test     # just the Emacs half
make bench         # the acceptance gate for the render and write paths
```

The suite drives real children — `cat` for the cooked path, `stty -echo` for secrets, a
real zsh for the OSC 133 path — and each subject file also loads on its own, which is what
you want while working on one.

Two things about it are worth knowing before they surprise you. It runs `-Q`, so an
optional package it tests against is not on `load-path` just because you have it
installed; the helpers go looking for `evil` themselves, and say so on the first line if
they cannot find it. And the shells it starts are pointed at a `ZDOTDIR` the suite writes
rather than yours — cooked's shell integration works by sourcing the user's own startup
files, so without that every zsh test would run your prompt, and a `vcs_info` precmd
shelling out to git on every prompt is enough on its own to make the timing-sensitive
tests flake.

## Licence

GPL-3.0-or-later. `src/emu/parser/` is vte 0.15, vendored from
[alacritty/vte](https://github.com/alacritty/vte) under Apache-2.0 OR MIT; both licences
sit beside it, and `src/emu/parser/mod.rs` records what was changed and why.
