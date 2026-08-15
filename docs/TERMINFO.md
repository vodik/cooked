# Terminfo

Why cooked ships its own entry, and what is in it. Every capability below has been
checked against the code.


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

