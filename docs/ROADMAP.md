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

**All three shells are done** — see `lisp/cooked-shell-completion.el` and
`shell-integration/cooked-completion.{zsh,bash,fish}`. What follows is what the design turned
out to be.

**The problem was.** Our `completion-at-point-functions` entry offered programs on `PATH`
and file names. zsh's compsys knows `git checkout <branch>`, ssh hosts, flags with
descriptions, PIDs for `kill` — thousands of hand-written specs. Calling ours
"Emacs-native completion" did not disguise that it was a downgrade. This was the one
place a user gave something up.

**The fix is to borrow the shell's completion, not reimplement it.** The two shells need
different mechanisms, and bash is much the easier.

### bash — shipped, by asking the live shell

bash's model is introspectable by design. `complete -p CMD` reveals the registered
function, and it can be invoked directly by setting the environment it expects:

```bash
COMP_LINE="git chec" COMP_POINT=8 COMP_WORDS=(git chec) COMP_CWORD=1
__git_wrap__git_main            # populates COMPREPLY
printf '%s\n' "${COMPREPLY[@]}"
```

Of the two routes considered — reusing `bash-completion.el`, which drives a *subprocess*,
or asking the live shell over the same channel zsh already uses — the second won, and not
narrowly. A subprocess has the user's `complete` registrations only if it re-reads their
rc, and never has the shell state: the variables, the `cd`, the functions defined at the
prompt five minutes ago. Asking the shell you are typing at has all of it by
construction. It also meant one wire protocol and one Emacs-side parser for both shells
rather than two of each.

`shell-integration/cooked-completion.bash` is the result, and it is bookkeeping rather
than cleverness — none of zsh's `compadd` shadowing, because `compgen` exists. Three
cases, in the order bash itself takes them: a registered `-F` function, a registered set
of `compgen` options, or nothing registered, where the first word is a command and the
rest are file names.

Two things it does not do, both deliberate. It splits the line on whitespace rather than
on `COMP_WORDBREAKS`, because Emacs is told the *length* of what the matches replace and
a finer split would make the two disagree about `host:path`. And it sends no descriptions
or groups — bash has none; that is compsys's alone — so those fields go back empty rather
than being collapsed, which keeps one parser reading both shells.

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

### fish — shipped, because `complete --do-complete` exists

fish needs neither shell's trick. `complete --do-complete "git checkout ma"` takes the
line as a string, completes it from any context, and prints `main\tLocal Branch` — the
two fields the wire already carries. The candidate is the whole token, so the span is
the token, which is the split the bash half makes anyway.

One thing was not obvious, and it is the whole of why the file reads the way it does:
**`read --null` is how you take fish's `read` out of interactive mode.** Without it,
`read` in a `bind` function hands the job to fish's own line editor, which draws a
`read>` prompt over the screen Emacs is rendering and interprets the request's bytes as
key bindings. With `--null --nchars 1` each call is one character and nothing is drawn,
which is zsh's `read -k 1` by another spelling. Forking a `head` or an `sh` to read the
line instead does not work at all: fish has drained the terminal into its own input
queue before the binding runs, so the child reads nothing. The one thing fish cannot
match is the other shells' `read -t 2`; it has no timeout, so the length cap is the only
bound on a request that arrives truncated.

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

**Half shipped.** Telling that the shell is on another host is done: OSC 7 carries the
host, `cooked--foreign-host-p` compares it with this one, and with `cooked-remote-directory`
at its default the reported path becomes a TRAMP name. So after `ssh prod` and `cd /srv`,
`C-x C-f` in the buffer starts at a name such as `/ssh:prod:/srv/`, and a multi-hop prefix the session
already had is kept rather than flattened. That needs only the far shell to report its
directory, which the shipped snippets do and fish 4 does on its own.

What is left is the other half: typing `find_file config.rs` at that remote prompt and
getting `/ssh:prod:/srv/config.rs` in the local Emacs, with your LSP and your keybindings.
The `OSC 51;E` verbs carry a path and no host, and resolve it through
`cooked--local-name`, so today they open a same-named local file or refuse a remote name.
Routing them through `cooked--remote-prefix` when the host is foreign is the change, and
it has to keep that function's rule that the byte stream can choose the path but never the
host or the method.

The other direction exists: `M-x cooked` in a `/ssh:host:` directory starts the shell on
that host with `ssh -t` in cooked's own pty (`cooked-remote.el`). Starting over TRAMP's own
`make-process`, as vterm, eat and ghostel do for every method, is declined: it would be a
second kind of session without the reader thread or backpressure. Methods that do not log
in with ssh are refused.

**Effort:** small. **Risk:** low, provided the verbs reuse the OSC 7 guards rather than
growing their own; the remote shell still needs our integration installed. **Payoff:**
this is a genuinely new capability rather than a nicer terminal.

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
- **Sixel / kitty graphics** rendered as Emacs images — **shipped**; see the Images
  section of `docs/FEATURES.md` and `docs/IMAGES.md`.
- **Prompt inference without shell integration**, for remote hosts where the snippet is
  not installed — heuristics over termios transitions and cursor movement.
- **Auto-answer** sudo and ssh prompts from auth-source, keyed on the host parsed from the
  prompt text. The hook (`cooked-password-functions`) already exists, and composes, so an
  auth-source entry can sit in front of `read-passwd`.

---

## Known gaps

Things that are missing rather than ideas:

- **Pointer motion with no button held is opt-in.** Drags reach the child whatever the
  setting: `cooked--mouse-track` runs `track-mouse` from inside the press command for as
  long as the gesture lasts, which is mode 1002 in full and the half of 1003 every 1003
  client also gets from 1002. Hover, the other half, is behind
  `cooked-mouse-hover-motion`, off by default, because it means leaving `track-mouse` on
  in the terminal for as long as the child asks and paying a command-loop turn per glyph
  the pointer crosses. Measured in a headless pgtk frame, a resting pointer costs nothing
  measurable and a sweeping one under a millisecond per keystroke (TERM.org has the
  figures) — but that harness dispatches synthetic motion without the redisplay a real
  pointer would add per event, so the default stays off until a real pointer has been
  timed. A drag that
  wanders into another window still reports nothing while it is away, on purpose: the
  cells under it belong to somebody else's buffer.
- **Reflow under a scroll region.** Both scrollback and the live screen rewrap on a width
  change now — `Screen::reflow` recovers the logical lines from `Row::wrapped` and chunks
  them again, preserving the round trip. A set scroll region still falls back to clamping,
  because the rows either side of it are not the caller's to rewrap; the alternate screen
  is clamped on purpose and is not a gap.
- **fish needs no snippet, and the announcement is what it is missing.** Verified
  against fish 4.8.1: fish emits the OSC 133 marks, OSC 7 and the title itself and
  without needing configuration, since 4.0.0, so `cooked.fish` now stands down there
  rather than bracketing every prompt twice — reading fish's resolved `status features`
  to decide, since `$fish_features` is the request rather than the state and misses two
  of the three ways the flag can be set. Its own path — the one fish 3.x and a `no-mark-prompt`
  fish take — now has a test that forces fish to be quiet so there is something of
  ours to assert, `$status` inside `fish_postexec` included. What fish has no equivalent of is the `OSC 51;CH`
  announcement, so a fish at the far end of an `ssh` keeps its own line editor where
  zsh and bash would not.
- **`vttest`-level conformance.** vim, htop, tmux and less work; the long tail of escape
  sequences is untested.
- **powerlevel10k's instant prompt** renders before `.zshrc` finishes, so the first prompt
  of a session can miss its OSC 133 marks. Every prompt after it is fine, because the mark
  is re-appended from a precmd hook that keeps itself last.
- **The eval channel's allowlist is fixed at load time.** No per-command prompting, no
  remembering a decision, no way to scope a command to a directory. `cooked-osc-eval` is
  opt-in now, which buys the room to grow that without changing the default posture.
