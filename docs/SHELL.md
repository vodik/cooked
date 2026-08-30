# Shell helpers

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
