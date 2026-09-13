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
| `Smol` | overline (`SGR 53`, cleared by `55`), onto `:overline`. The name is tmux\'s |
| `Sync` | synchronized output, which suppresses the Emacs wakeup for a frame |

**Removed, being things we do not implement and do not intend to:**

| Capability | Why |
|---|---|
| `ccc`, `initc` | palette redefinition via OSC 4. Emacs owns colour; a per-buffer 256-entry palette is the wrong seam. A query is still answered, from the colour each index is drawn in; a set is ignored |
| `flash` | visual bell via DECSCNM |
| `mc0`, `mc4`, `mc5`, `mc5i` | printer control. There is no printer behind an Emacs buffer, and `mc5` is a child-driven exfiltration channel with nothing to show for it |
| `mgc`, `smglp`, `smglr`, `smgrp` | left/right margins. The grid, the reflow and the transcript model are all row-oriented — and `CSI s` is already save-cursor, so honouring these would corrupt it |
| `meml`, `memu` | HP-era memory lock |
| `smm`, `rmm`, `km` | meta sets the eighth bit (mode 1034). How Meta is spelled is negotiated through modifyOtherKeys or the kitty protocol, which is the mechanism that should own it |
| `cvvis` | cursor *blink* is `blink-cursor-mode`, yours to set and not the child\'s. `cnorm` covers visibility |

A child does not have to take our word for any of it. DECRQM (`CSI ? Ps $ p`) answers 1 or
2 for a mode we implement, 4 — "permanently reset" — for every one in that last table, 3 —
"permanently set" — for 2027, grapheme clustering, which is always on, and 0 for one we
have never heard of. That includes 2031, the colour-scheme subscription,
which is the mode a child is most likely to probe before deciding whether to bother
asking. DECCOLM (3) and DECSCLM (4) answer 4 as well: `is2` and `rs2` reset them, and
nothing here sets them. So do modes no capability names but cooked has decided against,
since 4 saves a child the retry that 0 invites: reverse wraparound (45, 1045), the UTF-8
and urxvt mouse encodings (1005, 1015, superseded by 1006), DECBKM (67, fixed by
`kbs=^?`) and Alt-sends-escape (1039). Meta-sends-escape (1036) answers 3, "permanently
set", because Meta is spelled as a leading ESC whatever the child asks.

`CSI = c`, tertiary DA, answers `DCS ! | 00000000 ST`: a unit id of zero, as xterm's.

None of that rests on a reading of the file any more. The entry's header carries a
`# declined-modes:` line, and `terminfo_entry_matches_what_decrqm_says` in
`src/emu/term/tests.rs` reads `cooked.ti` at compile time and fails if a mode a
capability names answers 0, a declined mode answers anything but 4 or is set by a
capability, or one of the queries `u7`, `u9`, `RV` and `XR` goes unanswered. Re-adding
`flash` without DECSCNM is the change it exists to refuse.

Some requests are refused rather than merely unimplemented. `CSI 21t` reports the window
title *on the child\'s input stream*, which turns a title the child set itself into typed
input at your next prompt; `CSI 3t`, `4t`, `9t`, `10t` and `13t` move the frame, size it
in pixels, maximise it or report where it is, which is Emacs\' business. A resize
(`CSI 8t`, and DECSLPP\'s `CSI Ps t` with Ps of 24 or more) is refused too unless
`cooked-resize-requests` says otherwise, and even then it moves a window and never the
frame. The read-only reports are answered: `11t`, `14t`, `16t` and `18t` from the grid,
`15t` and `19t` from the frame. So is DEC mode 2048: a program that sets it is sent
`CSI 48 ; rows ; cols ; height px ; width px t` at once and again after every resize,
which is how a multiplexer on the far side of ssh, where SIGWINCH does not reach, learns
the size.

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

