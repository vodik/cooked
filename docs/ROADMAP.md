# Roadmap

Where cooked could go

Ordered roughly by value, with honest effort and risk. Nothing here is committed to;
several ideas are speculative and labelled as such. Items marked **shipped** are kept
rather than deleted, because the design argument for them is still the explanation of
what is there.

The through-line: `cooked` knows things a terminal cannot — which program is reading, in
what mode, where each command started and ended, how it exited, and which rows were
wrapped rather than newline-terminated. Most of what follows is spending that knowledge.

---

## 1. Completion parity with the shell

**zsh is done** — see `lisp/cooked-completion.el` and the completion section of
`shell-integration/cooked.zsh`. What follows is what the design turned out to be, and
what is left.

**The problem was.** Our `completion-at-point-functions` entry offered programs on `PATH`
and file names. zsh's compsys knows `git checkout <branch>`, ssh hosts, flags with
descriptions, PIDs for `kill` — thousands of hand-written specs. Calling ours
"Emacs-native completion" did not disguise that it was a downgrade. This was the one
place a user gave something up.

**The fix is to borrow the shell's completion, not reimplement it.** The two shells need
different mechanisms, and bash is much the easier.

### bash — largely a solved problem

bash's model is introspectable by design. `complete -p CMD` reveals the registered
function, and it can be invoked directly by setting the environment it expects:

```bash
COMP_LINE="git chec" COMP_POINT=8 COMP_WORDS=(git chec) COMP_CWORD=1
__git_wrap__git_main            # populates COMPREPLY
printf '%s\n' "${COMPREPLY[@]}"
```

Two routes, both viable:

- **Reuse `bash-completion.el`** (szermatt, MELPA). It already drives a bash process this
  way and exposes `bash-completion-dynamic-complete-nocomint`, an entry point built for
  buffers that are not comint-driven — which is exactly our situation. Wiring it into our
  CAPF is plausibly an afternoon. *Verify the function signature before relying on it.*
- **Do it ourselves over the OSC eval channel**, asking the *live* shell rather than a
  subprocess, so the user's actual `complete` registrations and shell state apply.

No ZLE-style gymnastics needed either way. If we ship one shell's real completion first,
it should be bash.

### zsh — shipped, via the capture trick

zsh has no equivalent of `compgen`; completion only runs inside ZLE. The established
approach — used by `fzf-tab` and `zsh-autocomplete` — wraps `compadd` so it *collects*
candidates instead of displaying them. What we ended up with:

1. A ZLE widget bound to a private sequence, plus `zle -C` over `.complete-word` so
   `_main_complete` runs exactly as TAB would.
2. Emacs sends the sequence followed by the percent-encoded line; the widget reads it
   with `read -k -s`, so it never enters `BUFFER` and is never echoed. `BUFFER` is set,
   completion runs, and it is restored before the widget returns — the redraw is a
   no-op, so nothing flickers and no echo frame needs suppressing.
3. `compadd` is shadowed for the capture: the real add happens first (completers branch
   on whether matches landed), then a shadow `compadd -O`/`-D` pair collects the matches
   and their descriptions in step. Candidates come back base64'd over `OSC 51;C`.
4. The CAPF blocks on the wake pipe for `cooked-completion-timeout` — no callback needed,
   because that is the process whose filter delivers the reply.
5. The table is dynamic, but re-queries only when the answer in hand cannot cover the
   keystroke: when the shell reported hitting its candidate cap (`pacman` was missing
   from a blank-line completion that included `pacman-key`), or when nothing in the list
   matches any more, which means the completion changed kind rather than narrowed —
   `git checkout ` offers branches until a `-` makes it flags. Everything else filters
   in Emacs. Unconditional re-querying works but stutters against a 140 ms completer.

Four things were not obvious up front, and all four are load-bearing:

- **`compstate[insert]` and `compstate[list]` have to be cleared *after*
  `_main_complete`**, not before: it writes both on the way out, and a `menu select`
  style then starts an interactive menu the moment the widget returns, which eats the
  next request.
- **Probes must be skipped.** `_git` calls `compadd -O` itself to ask what would match;
  capturing those is how every candidate arrived twice.
- **Options cluster** — `-ld array` is how `_describe` passes descriptions — so only the
  last letter of a cluster decides whether the next word is a value.
- **Bounds are `${#PREFIX}`, not the word.** `IPREFIX` is what compsys has already
  decided stays on the line, and matches carry `-P`/`-p` prefixes that are part of the
  insertion but not of the body.

Announcing capability per prompt (from `zle-line-init`, once ZLE actually owns the
keyboard) is what keeps the trigger from being typed into a shell that has no widget
bound to it.

**Left:** bash, which reuses the same `OSC 51;C` framing and needs no ZLE gymnastics —
`complete -p` and `COMPREPLY`, above. And insertion is still verbatim: a candidate with
a space in it is not shell-quoted on the way in, exactly as the Emacs-native table
already behaved.

---

## 2. next-error over command output — **shipped**

`(require 'cooked-next-error)`. `M-g M-n` walks the errors in the most recently
finished command's output, scoped by its OSC 133 marks rather than by the whole
scrollback, so `next-error` after a failed build goes to *that* build's first error.

What is left: nothing structural. `compilation-shell-minor-mode` was tried first and
was the wrong shape — it scans the whole buffer, which is exactly the scoping this
feature exists to provide.

## 3. Embark

Once file:line references carry text properties, `embark-act` becomes the natural verb
layer, and much of it is small:

- **File at point** → open, open other window, dired the containing directory.
- **URL at point** → browse, copy. *The gap this used to name is closed:* OSC 8
  hyperlinks now carry a link id through the emulator and land as text properties over
  the linked text, so `browse-url` and `mouse-2` already work. What is left is the
  embark target finder itself.
- **Command record at point** → re-run, edit and re-run, copy just this output, send the
  output to its own buffer, narrow to it. `cooked-command-decorations` already offers
  rerun / copy command / copy output from its fringe marker's menu; embark would make
  the same verbs reachable from point without the fringe.
- **Exit code** → explain, or search the error text.

This is mostly `embark-target-finders` entries plus a keymap. It composes with everything
above: with compilation properties in place, embark on an error already does the right
thing.

---

## 4. Notifications when a long command finishes

We know when a command ends and how it exited. If its buffer is not visible and it ran
longer than some threshold, notify — with the command name from the OSC 2 title and the
exit code.

`cooked-command-finished-functions` is the seam, and it is a proper hook now rather
than the single-listener variable it started as. A consumer needs the command's own
record (start, end, exit code) and `cooked--attention` to tell whether anyone is
looking, both of which already exist.

**Effort:** an hour. **Risk:** none. Probably the best value-per-line item on this list.

---

## 5. TRAMP bridging over ssh

OSC 7 already tells us the child's working directory. If we can also tell we are inside
`ssh` — the title, the annotation, or an explicit marker from the remote shell — then
`find_file foo` could open `/ssh:host:/path/foo` in the *local* Emacs.

You would ssh somewhere, type `find_file config.rs`, and get a real buffer with your LSP,
your keybindings, your everything — editing a remote file from a remote shell.

**Effort:** medium. **Risk:** medium; detecting "we are remote" reliably is the crux, and
the remote shell needs our integration installed. **Payoff:** this is a genuinely new
capability rather than a nicer terminal.

---

## 6. Structured output

We own a command channel. A shell wrapper could emit results as JSON tagged over OSC, and
Emacs could render a real table — sortable, embark-able — instead of columns of text.
Start narrow: one wrapper for one command (`ls`, `docker ps`, `kubectl get`) to see
whether it feels good before generalising.

**Effort:** medium. **Risk:** easy to over-engineer into a shell of its own.

---

## 7. Detach and reattach

Rust owns the pty, not Emacs. Move the reader into a daemon and a session could outlive an
Emacs restart: tmux, where the client is your editor. The architecture is most of the way
there already — the module boundary is a session handle and a wakeup pipe.

**Effort:** large. **Risk:** large; it changes the process model and the security surface.
**Payoff:** large. Worth a design sketch before any code.

---

## 8. Speculative

- **Predictive echo, mosh-style.** We know cooked versus raw and we own the pty. Over a
  laggy ssh, echo keystrokes locally and reconcile when the real bytes arrive.
- **Sixel / kitty graphics** rendered as Emacs images.
- **Prompt inference without shell integration**, for remote hosts where the snippet is
  not installed — heuristics over termios transitions and cursor movement.
- **`consult-cooked-history`** across every session.
- **Auto-answer** sudo and ssh prompts from auth-source, keyed on the host parsed from the
  prompt text. The hook (`cooked-password-function`) already exists.

---

## Known gaps

Things that are missing rather than ideas:

- **Mouse drag and motion.** Press, release and wheel work; modes 1002/1003 are tracked but
  Emacs drag events are not forwarded.
- **Reflow under a scroll region.** Both scrollback and the live screen rewrap on a width
  change now — `Screen::reflow` recovers the logical lines from `Row::wrapped` and chunks
  them again, preserving the round trip. A set scroll region still falls back to clamping,
  because the rows either side of it are not the caller's to rewrap; the alternate screen
  is clamped on purpose and is not a gap.
- **fish integration is unverified.** The snippet is written but has never been
  executed against a real fish. The `exit`-should-be-`return` bug found by inspection has
  since been fixed, but it was found by reading rather than by running, which is the
  point: `$status` inside a `fish_postexec` handler is the next thing to check.
- **`vttest`-level conformance.** vim, htop, tmux and less work; the long tail of escape
  sequences is untested.
- **powerlevel10k's instant prompt** renders before `.zshrc` finishes, so the first prompt
  of a session can miss its OSC 133 marks. Every prompt after it is fine, because the mark
  is re-appended from a precmd hook that keeps itself last.
- **The eval channel's allowlist is fixed at load time.** No per-command prompting, no
  remembering a decision, no way to scope a command to a directory. `cooked-osc-eval` is
  opt-in now, which buys the room to grow that without changing the default posture.
