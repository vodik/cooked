# Images: where this got to, and what is left

Working notes for whoever picks this up. Branch `images-deco`, eight commits off `main`.
Kitty graphics renders end to end — `chafa -f kitty` works in a real session — and box
drawing is intact alongside it. 286 Rust tests, 262 Lisp tests, clippy clean.

## The shape of it, so you need not re-derive it

Five things, each with a commit that argues for it in full:

- **The parser is vendored** (`src/emu/parser/`, from vte 0.15). Upstream discards APC
  entirely, which is where kitty graphics lives, so this could not be reached at all.
  Adds `Perform::apc_dispatch` and makes DCS/APC payloads arrive as slices rather than a
  call per byte. Kept otherwise faithful, so a re-sync stays a diff.
- **`Row` has one side table**, `Extra`, for everything keyed by column: combining
  marks, underline colours, image placements. One maintenance path — `Row::prune`,
  `Extras::shift` — that every mutator routes through.
- **`Deco` is one mechanism for box glyphs and image cells.** Both are "this character
  displays something other than itself, which Rust names and Emacs renders and caches".
  Glyphs are *derived* from the character; placements are *stored* in `Extra`. They
  converge at `Run::deco` and cross as `(KIND . PACKED)`, one fixed-width record per
  character.
- **One block shape crosses the boundary.** `(TEXT STYLE-SPANS DECO-SPANS)`, used for
  both `:rows` and `:scrolled`, rendered by one `cooked--render-block`. There used to be
  two shapes and they had already drifted.
- **Image lifetime is Emacs'.** Ids are content-addressed, so bytes cross once however
  often a child transmits or places a picture. Emacs holds the spec in the `display`
  property, so buffer text is the strong reference and the collector owns it — which is
  why there is no release protocol. `cooked--image-data` is strong (the only copy of the
  bytes); `cooked--image-specs` is weak on the value (rebuildable).

The payoff to trust: image tests for overwrite, scrollback, rewrap and trailing-blank
trimming pass with no special-casing, because the two refactors above got there first.

## What is left, roughly in order

1. **`o=z` (zlib) is declined with `ENOTSUPPORTED:compression`.** The biggest remaining
   hole in kitty coverage — chafa does not use it, kitty's own `icat` and others do.
   Needs an inflate, ~250 lines, no dependency wanted. `src/emu/kitty.rs`.
2. **`t=f` / `t=t` / `t=s`** — transmission by file, temp file and shared memory, also
   declined. Deliberately: reading a path a child names is a decision about trust, not a
   decode, and it deserves a real decision rather than a default.
3. **Sixel and iTerm2 `OSC 1337`**, as further producers of the same `ImageData` and
   `Placement`. Sixel rides the slice-based DCS the vendored parser already provides;
   `OSC 1337` needs a handler and a raised `OSC_PAYLOAD_LIMIT`.
4. **Nothing caps `cooked--image-data`.** Buffer-local and strong, so it dies with the
   buffer, but a long session sending many distinct pictures grows it. The same place a
   scrollback cap would go — see `cooked--discard-scrollback`'s docstring, which already
   nominates itself.
5. **Kitty extensions not attempted**: unicode placeholders (`U=`), animation, z-index,
   source rectangles (`x=`/`y=`/`w=`/`h=`), cell offsets (`X=`/`Y=`).

## Two things to know before you trust a green suite

- **Batch Emacs draws nothing.** A run of box drawing rendered as a single glyph for one
  commit because the memoized image spec made adjacent `display` properties `eq`, and
  Emacs merges those into one image. Every character had a correct property throughout,
  so the suite was green. `cooked-adjacent-box-glyphs-do-not-share-a-display-property`
  guards it now. If you touch the decoration path, ask what the display engine does that
  a text property assertion cannot see.
- **One unresolved flake.** `cooked-delete-output-reaches-output-that-has-scrolled-off`
  failed 1 run in ~10 of the full suite on this branch, 0 in 9 at `main`, and never in
  isolation. It drives a live zsh with `settle` timeouts, so timing is the likely cause,
  but that is a suspicion and not a finding.

## Measuring

The benchmarks are the acceptance gate for anything touching the render or write paths,
and both were broken and repaired during this work — `cooked-bench.el` had lost
`:height`/`:used`/`:head` and was erroring out rather than reporting.

```sh
cargo test --release --test throughput -- --ignored --nocapture   # the Rust core
emacs -Q --batch -L lisp -L tests -l cooked-bench.el -f cooked-bench
```

Compare interleaved against a worktree of the base commit, on a quiet machine, and never
alongside another benchmark run — a chunk of this session was spent chasing a 4%
"regression" that was one benchmark loop contending with another.
