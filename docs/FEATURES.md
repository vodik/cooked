# What you get

The feature tour: completion, the command channel, links, and the UI conventions a
cooked buffer follows. Each of these is reachable from a stock session; the ones that
need a `require` say so.

## Completion

TAB at a prompt is `completion-at-point`, so corfu, cape, consult and friends work
here as they do anywhere else. Out of the box what they are offered comes from Emacs:
programs on `PATH` for the first word, file names after it. Load the layer

```elisp
(require 'cooked-shell-completion)
```

and it comes from zsh itself instead:

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
`cooked-completion-timeout`.

It is a separate file rather than a setting because it is not free, and because a
setting that gates code which is loaded and running anyway is a switch in name only.
Asking the shell blocks Emacs for the length of the round trip, and the snippet
shadows the `compadd` builtin for the whole session — inert when nothing is capturing,
but every completion you run in that shell then goes through a shell function rather
than a builtin. Unloaded, none of that exists: `cooked-shell-completion-function` and
`cooked-osc-completion-function` are nil, the OSC 51;C arm drops what it is given, the
CAPF goes straight to the Emacs table, and the child is never told to install its half.

That last part is where the two halves come apart, and it is worth knowing. Requiring
the layer reaches Emacs immediately, but whether the *shell* installs its half is
decided when the shell starts, from `COOKED_COMPLETION` in its environment, because
the `compadd` shadow, the widget and its bindkeys cannot be usefully retracted from a
running zsh. So load it in your init file, or restart the shell after loading it. A
shell started with its half installed keeps announcing at every prompt whether or not
Emacs is listening; Emacs ignoring the announcement is the whole of the difference.

`cooked-completion-backend` chooses between the sources once the layer is loaded:
`shell` (the default, falling back to Emacs), `native`, or `both`. `native` is the
runtime pause — the widget stays installed and Emacs stops using it — which is the
setting to reach for while chasing a slow completer, not the way to turn the feature
off. Not having it at all is not requiring the file.

Not loading it is not turning completion off — TAB is still `completion-at-point`, and
the Emacs table answers. Making TAB drive *zsh's own* completion menu instead is a
different feature and not one of the two: at an integrated prompt ZLE's buffer is
empty, because the line lives in Emacs until you press RET, so forwarding TAB would
complete the empty line and offer every command on `PATH`. See the notes in bugs.org.


## Talking back to Emacs

The shell can ask the Emacs that is running it to do things:

```sh
find_file src/main.rs        # opens it in the same Emacs
dired .                      # the current directory, in Dired
echo hi | osc_copy           # onto the kill ring, works over ssh
```

The helpers are in `shell-integration/cooked.zsh`, and today they are zsh's alone:
the bash and fish snippets carry OSC 133 and nothing else, so nothing in this section
reaches Emacs from them. Children are handed `TERM_PROGRAM=cooked` and
`TERM_PROGRAM_VERSION`, straight from the version the native core was built with, which
is how a shell tells it is talking to us.

**This is a command channel driven by bytes on the terminal**, so it is off until you
ask for it with `(require 'cooked-osc-eval)`. Anything that can write to the terminal
can pull the trigger: `cat` of a hostile file, output from a compromised host, a build
log quoting attacker-controlled text. Being a separate file is the point — you should
buy that risk deliberately rather than inherit it.

### A closed set of verbs

The wire format is `OSC 51 ; E <version> ; <verb> [ ; <arg> ] ST`, and the verbs are
fixed:

| Wire | Shell helper | What it does |
|---|---|---|
| `51;E1;F;<path>` | `find_file` | visit a file |
| `51;E1;O;<path>` | `find_file_other_window` | visit it in another window |
| `51;E1;D;<path>` | `dired` | open Dired |
| `51;E1;K` | — | clear the scrollback |

There is no name to look up and nothing maps a string the child sent onto a function.
That is the point, and it is the design eat arrived at rather than vterm's: an
allowlist of names settles *which* function runs and can say nothing about what it is
pointed at, which is the half that bites. `find-file` looks like the safe end of the
range until the name handed to it is `/ssh:attacker.example:/etc/motd` — visiting that
is not a read, it is TRAMP opening a connection to a host the sender chose and running
that method's transport program to get there. `/sudo::` is the same move without
leaving the machine. A closed set has no such gap, because each verb is cooked's own
code and checks its own argument.

That check runs before anything looks at the file, `file-directory-p` included: asking
whether a remote file is there is already the connection. The same guard sits on OSC 7,
which sets `default-directory` and needs no `require` at all.

Every verb takes at most one argument, which is the rest of the payload verbatim. So
there are no quoting rules and a path containing `;` or `"` needs no escaping — it
simply arrives.

### The escape hatch

One verb is open-ended. `!` names an arbitrary command from `cooked-eval-commands`,
which is **empty by default**:

```sh
osc_emacs_eval compile "make -k"    # refused until you say otherwise
```

Empty costs nothing now that the fixed verbs cover the ordinary cases, which is what
makes deny-by-default worth having here. Filling it is a second decision on top of
loading the layer at all.

`compile` and `recompile` are the obvious candidates and the reason for the caution —
they execute arbitrary shell commands, so adding them turns any text that reaches your
terminal into remote code execution:

```elisp
(add-to-list 'cooked-eval-commands '("compile" . compile))
```

`magit-status` is worth spelling out separately because it looks like a viewer rather
than an executor: `git status` runs `core.fsmonitor` from the target repository's own
`.git/config`, so pointing it at a repo somebody else chose is closer to `compile` than
it looks. The `magit` shell helper is already there, waiting on the Emacs half:

```elisp
(add-to-list 'cooked-eval-commands '("magit-status" . magit-status))
```

Whatever goes in that list is called with the strings the child sent and nothing else
checks them — which the fixed verbs cannot say — so prefer a wrapper of your own over
the bare command when the argument is a path.

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
  [the keyboard page](KEYBOARD.md).
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


## Links

Two kinds, and they are not the same kind of thing.

A program can *say* a span of its output is a hyperlink, with `OSC 8` — what `ls
--hyperlink=auto`, `gcc -fdiagnostics-urls=always`, `delta` and `gh` emit. That half is
first-class and goes through the emulator: the cells carry a link id in the same sparse
side table an underline colour lives in, so a link survives wrapping, a reflow and
scrolling off into the transcript, and the URI itself crosses into Emacs exactly once
however many cells point at it. Try it:

```sh
printf '\033]8;;https://example.com/\033\\a link\033]8;;\033\\\n'
ls --hyperlink=auto
```

The `id=` parameter is ignored on purpose. Ids are content-addressed — the same URI is
always the same link — which already gives `id=` its whole purpose, grouping spans that
share a destination. And an `OSC 8` link is *not* an SGR attribute: `ESC[0m` does not
close one, only an explicit empty `OSC 8;;` or a terminal reset does, which is what makes
a link a program colours as it prints it work at all.

Anything else that merely *looks* like a URL is a guess, and the guess is Emacs' own:
`goto-address-fontify-region` runs over each row as it is rendered and each batch as it
settles into the scrollback, so you get goto-addr's regexps, its faces, its `help-echo`,
its context-menu entry and `mouse-1-click-follows-link` support without cooked
reimplementing any of it. `cooked-detect-links` turns it off; `cooked-detect-links-on-alt-screen`
turns it on for a full-screen program, which is off by default because that screen
repaints continuously and is usually where the child wants the mouse for itself.

One visible gap, and it is accepted rather than hidden: a URL the child *wrapped* across
a column boundary is not matched while it is on screen, because every live row is its own
buffer line and the regexp stops at a newline. It becomes matchable the moment the row
scrolls off, since `cooked-rejoin-wrapped-lines` joins a continuation row onto the line
above it in the transcript.

`mouse-2` and `RET` follow a link, `C-c RET` follows whatever is at point whether or not
it is highlighted, and `S-mouse-2`/`S-RET` follow one even while the child has grabbed the
mouse or the keyboard — because a plain click or `RET` in that state still belongs to the
child, exactly as it does everywhere else, with Shift as the escape.

File names are a separate, optional feature, because deciding that `src/lib.rs` is a file
rather than a word means asking the filesystem, and doing that per candidate per redraw is
a syscall on the render hot path. Load it on purpose:

```elisp
(require 'cooked-file-link)
```

Loading the file is the switch — there is no second setting to disagree with it, the same
shape `cooked-osc-eval` and `cooked-shell-completion` already use. It validates a path
against the child's own working directory and then the project root, resolves a trailing
`:LINE:COL` (and reads `compilation-error-regexp-alist`'s `gnu`/`gcc-include` entries for
the same numbers where a compiler wrote them beside the name), and does that lazily: on
demand when you follow a name, and once per batch of output that has settled into the
scrollback. Never on a live row.

