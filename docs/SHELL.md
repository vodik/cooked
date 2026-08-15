# Shell integration

## The marks, and what each one buys

If you'd rather write the marks yourself — into a prompt you already maintain, or on a
host where there's no file to source — this is the whole of what cooked reads:

| Mark | Emitted | What it buys |
|---|---|---|
| `OSC 133;A` | **inside `PS1`**, at the start | where the prompt began: prompt-to-prompt navigation, the outer half of the evil command text object, and a command record that starts at its prompt rather than at its output |
| `OSC 133;B` | **inside `PS1`**, at the end | the input line becomes an Emacs buffer — your keybindings, your kill ring, your completion UI. The one mark that changes who owns the keyboard |
| `OSC 133;A;k=s` | **inside `PS2`**, at the start, with a `B` after it — and after each newline of a multi-line `PS1` | the same, for the continuation lines of a multi-line construct. `k=s` is what stops it being read as a fresh prompt, so the command record stays filed under the prompt the construct was typed at |
| `OSC 133;C;cmdline_url=<url-encoded>` | from `PS0` in bash, from preexec in zsh | where the command's output begins. Without it there is no command record at all, and so no `next-error`, no rerun, no copy-just-the-output. The command line on it is what the shell says it is about to run, and is the only account of it when the shell kept the line |
| `OSC 133;D;<code>` | from precmd, **first**, before `$?` is clobbered | the exit status: the fringe marker's colour, and telling a failed command from a successful one. A bare `D` closes a prompt that ran nothing |
| `OSC 7;file://host/path` | from precmd, and only when the directory changed | not a 133 mark, but the same hook: tracks `default-directory`, and tells cooked the shell is on this machine |

A bare `A`, with no `k=`, because absent means `k=i`. The proposal also spells this
mark `P`, and Ghostty sends that one from its prompt strings because `A` is defined to
imply a *fresh line* and a mark that lives in a prompt is re-emitted on every repaint —
Ctrl-L, a resize, a vi-mode switch, powerlevel10k filling in an async segment. cooked
implements no fresh-line behaviour, so the two would be the same mark to it, and it
reads only `A`: that is what the shipped snippets send and what fish 4 sends when it
marks its own prompts, so one spelling covers every emitter that can reach cooked.

Three placement rules fail silently. `B` has to live in `PS1` rather than be printed
from precmd, because precmd runs *before* the prompt is drawn and a printed mark would
land ahead of the prompt text — leaving Emacs to treat the prompt itself as input. `D`
has to come from the first precmd hook, or the status it reports belongs to whichever
hook ran before it — which is why the shipped snippets are *two* hooks, one at each end
of the prompt sequence, rather than the single hook kitty and Ghostty use. And the marks
have to be re-applied to `PS1` every prompt, because powerlevel10k, starship and most
oh-my-zsh themes rebuild it from their own precmd and would otherwise drop them; the
snippets keep a clean copy and a marked copy and compare, rather than searching `PS1`
for their own markers, which has both a false positive and a false negative.

`PS2` is where the marks have to travel *inside* the prompt string in both shells,
including the `A;k=s`: there is no hook that runs before a continuation prompt is drawn.

The path in `OSC 7` is percent-encoded, because it is a URL and cooked decodes it as
one — a directory called `100%20cake` has to arrive as `100%2520cake` or it decodes to
a different directory that does not exist. A fish 4 doing its own reporting encodes the
same way, so there is one encoding on the wire and one decoding at the far end.

What cooked does with `k=`, and what it does with a mark sequence that is not the tidy
`A B C D` above, is in
[FEATURES.md](FEATURES.md#what-the-prompt-marks-are-read-to-mean).

One thing the marks do not buy on their own: a `B` at the far end of an `ssh` does not
hand Emacs the line by itself. A mark is a claim, and lifting the line out of a pty
that no line editor is reading is how keystrokes get eaten — so cooked wants the claim
corroborated, either by the shell being on this machine (which `OSC 7` establishes) or
by the per-line `OSC 51;CH` announcement the shipped snippets emit. Unlicensed, a
marked prompt keeps its own line editor and everything else the marks buy — extents,
exit codes, `next-error`, rerun — works unchanged.

## Turning parts off

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

## The files

| File | What it is | How to get it |
|---|---|---|
| `shell-integration/cooked.{zsh,bash,fish}` | the marks, OSC 7, the announcement, and the optional helpers | injected for zsh and bash; source it anywhere else |
| `shell-integration/cooked-completion.{zsh,bash}` | the completion capture, answering `TAB` from the shell's own completion | injected beside the core when `completion` is in the feature list *and* `cooked-shell-completion` is loaded; source it after the core otherwise |

All three are exercised by the test suite. fish is not injected because it needs no
generated startup file — and on fish 4.0 and later it needs no snippet at all: fish
marks its own prompts with OSC 133, reports its directory with OSC 7 and sets its own
title, none of it needing configuration, so a fish session works here out of the box.
Sourcing `cooked.fish` anyway is safe: it detects that and stands down rather than
bracketing every prompt twice. It still does the work on fish 3.x, and on a fish 4 told
`no-mark-prompt`.

## The OSC 51 channels

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
their own arguments, plus one escape hatch — see below.

## Shell helpers

`shell-integration/cooked.zsh` carries the OSC 51;E helpers as well as the marks, but
they are off unless `eval-helpers` is in `cooked-shell-integration-features`, and they
do nothing at all until the Emacs half is loaded with `(require 'cooked-osc-eval)`.
Two switches for one feature is not belt and braces: one says whether the shell has
the functions, the other says whether Emacs answers them, and they are asked of
different machines.

What ships is the closed set of verbs and nothing else:

```zsh
find_file notes.md          # visit it in the Emacs running this shell
find_file_other_window x.c  # ...in another window
dired .                     # the current directory, in Dired
echo hi | osc_copy          # onto the kill ring, works over ssh
```

Each is cooked's own code on the Emacs side and checks its own argument before
anything touches the file — which is what makes them safe to define for you, and why
there is no shipped helper for anything outside the set.

**They are local-only, and that is the caveat worth reading twice.** The verbs carry
paths, and Emacs resolves them with no idea it is talking to another host: run
`find_file ./notes.md` from a shell behind an `ssh` and you open whatever local file
happens to bear that name. The marks are what goes on the far end; these are not.

## Reaching anything else

`cooked_send` is the one open-ended helper. It names a command, which Emacs looks up
in `cooked-eval-commands` and refuses unless you put it there:

```zsh
cooked_send magit-status /path/to/repo
```
```elisp
(add-to-list 'cooked-eval-commands '("magit-status" . magit-status))
```

Quoting lives in `cooked_send` and only there, because it is the one form that takes
more than one argument; the fixed verbs take exactly one, sent verbatim, so a path
containing `;` or `"` needs no escaping and simply arrives.

Aliases are yours to write, and deliberately not shipped:

```zsh
alias magit='cooked_send magit-status'
```

An alias that shadows a real command name — `magit` is one, if you have it installed —
reads very differently as a line in your own rc than as something cooked put in your
shell. That it takes an allowlist entry *and* an alias is the point: two deliberate
steps rather than a default you inherit.

Before adding anything to `cooked-eval-commands`, the rule from
[FEATURES.md](FEATURES.md) applies: naming a command settles which function runs and
says nothing about what it is pointed at, and the argument arrives from the byte
stream. Prefer a wrapper of your own over the bare command when the argument is a path.

## What you might still want to write

The snippet stops where preference begins. These are the usual additions; everything
below assumes `autoload -Uz add-zsh-hook`, which the core does.

**A different editor client.** `find_file` goes through the OSC verb, which is the
right answer when Emacs is the terminal's own — but if you already have a client you
prefer, write your own. Leave `eval-helpers` out of the feature list first: the snippet
installs its helpers from the first prompt, which is *after* your rc has run, so a
definition made there would lose to ours rather than replace it.

```zsh
find_file() {
    if (( $+commands[evt] )); then evt open "${${1:-.}:a}"
    else printf '\e]51;E1;F;%s\e\\' "${${1:-.}:a}"; fi
}
```

The verbs are one `printf` each — `F` visit, `O` other window, `D` Dired — so taking
the feature off costs you three lines, not a mechanism. Export `EDITOR` and `VISUAL` to
match, or the two disagree the first time something else opens a file.

**Prompt annotation.** `OSC 51;A` sets the text cooked shows against the prompt. It is
inert data rather than a command, so it needs no opt-in on either side — but it has no
shipped helper, because there is no sensible default for what it should say:

```zsh
osc_annotate() { printf '\e]51;A%s\e\\' "${1:-}" }
__cooked_annotate() { osc_annotate "$(print -Pn '%n@%m:%~')" }
add-zsh-hook precmd __cooked_annotate
```

**Titles** are on by default and are a feature rather than a helper, so there is
nothing to write — but if you have your own precmd writing `OSC 2` and prefer its
wording, append ` no-title`. Ours is registered later and would otherwise win, which is
last-write-wins working correctly rather than a conflict.

## What is deliberately absent

There is no `clear` override, and nothing left for one to fix: plain `clear` sends
`CSI 2 J` then `CSI 3 J`, which cooked answers by scrolling the screen it archived out
of view and then dropping it. Shadowing a standard command to reach into the editor
would be surprising and would break scripts that call it. From Emacs the same thing is
`M-x cooked-clear-scrollback`, and the channel spells it `E1;K` for anyone who wants it
from a script.
