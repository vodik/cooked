# Images: where this got to, and what is left

Working notes for whoever picks this up. Kitty graphics, sixel and iTerm2 inline images
all render end to end, and box drawing is intact alongside them. 328 Rust tests, 274 Lisp
tests, clippy clean.

## The shape of it, so you need not re-derive it

Five things, each with a commit that argues for it in full:

- **The parser is vendored** (`src/emu/parser/`, from vte 0.15). Upstream discards APC
  entirely, which is where kitty graphics lives, so this could not be reached at all.
  Adds `Perform::apc_dispatch` and makes DCS/APC payloads arrive as slices rather than a
  call per byte. Kept otherwise faithful, so a re-sync stays a diff. Two further
  departures since: APC and OSC both have a size bound, where upstream bounded neither.
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

**Three producers, one pipeline.** kitty (`src/emu/kitty.rs`, APC), sixel
(`src/emu/sixel.rs`, DCS) and iTerm2 `OSC 1337` (`Term::iterm_file`) all end at
`intern_image` + `lay_image` and share everything downstream of "here are some pixels".
Adding the second and third producer needed no change to placement, rewrap, scrollback or
the Lisp side at all, which is the payoff from the refactors above.

## What is left

1. **`t=f` / `t=t` / `t=s`** — kitty transmission by file, temp file and shared memory,
   declined with `ENOTSUPPORTED:medium`. Deliberately: reading a path a child names is a
   decision about trust, not a decode, and it deserves a real decision rather than a
   default. Sketch of the options, if you take it up: temp files only (`t=t`, where the
   protocol says the terminal deletes the file after reading) under the system temp dir;
   or all three behind a defcustom defaulting to off.
2. **Kitty extensions not attempted**: unicode placeholders (`U=`), animation, z-index,
   source rectangles (`x=`/`y=`/`w=`/`h=`), cell offsets (`X=`/`Y=`).
3. **Sixel gaps.** `Pu=1` (HLS colour) is ignored in favour of leaving the register
   alone — no encoder in circulation emits it. Background mode `P2` is ignored too, since
   untouched pixels are transparent whatever it says (see below). DECSDM is unimplemented.
4. **`ImageStore::retained` is dead weight.** The module keeps up to 64MB of transmitted
   bytes so an already-transmitted id can be placed again, but nothing outside its own
   tests ever reads it: re-placement needs only the geometry, because Lisp already holds
   the bytes. Either delete it and reclaim the memory, or make it the thing Lisp asks for
   after an eviction — but do not leave it as it is.

## Things to know before you trust a green suite

- **Batch Emacs draws nothing.** A run of box drawing rendered as a single glyph for one
  commit because the memoized image spec made adjacent `display` properties `eq`, and
  Emacs merges those into one image. Every character had a correct property throughout,
  so the suite was green. `cooked-adjacent-box-glyphs-do-not-share-a-display-property`
  guards it now. If you touch the decoration path, ask what the display engine does that
  a text property assertion cannot see.
- **Decoders were checked against other people's implementations, not their own tests.**
  Sixel decodes pixel-for-pixel identically to `sixel2png` on chafa's output across six
  colour and dither settings up to 2000x1000, alpha included. Format sniffing was checked
  against real PNG, GIF, and baseline and progressive JPEG files down to 1x1. This is
  worth redoing rather than trusting, if you change either: both were written to pass
  vectors that a subtly wrong decoder also passes.
  - A trap worth naming, because it cost an hour: the ST terminator's `\` is `0x5C`,
    which is inside sixel's own data range, so a harness that hands the decoder one byte
    too many silently paints an extra column. The real parser strips the terminator; test
    scaffolding has to as well.
- **Untouched sixel pixels are transparent**, whatever the introducer's background mode
  says. The spec calls them "the background colour" and expects the terminal to know what
  that is; here Emacs does, and alpha is how the buffer face shows through. If someone
  reports a picture with a transparent hole where another terminal draws grey, this is
  why, and it is deliberate.
- **One unresolved flake.** `cooked-delete-output-reaches-output-that-has-scrolled-off`
  fails roughly 1 run in 10 of the full suite, and never in isolation. It drives a live
  zsh with `settle` timeouts, so timing is the likely cause, but that is a suspicion and
  not a finding. Still present; still unexplained.

## Bounds, and why each is where it is

Images are the one place a child chooses how much memory we spend, so every path has a
limit and none of them is arbitrary:

| Bound | Where | What it stops |
| --- | --- | --- |
| `MAX_APC_RAW`, `MAX_OSC_RAW` (8MB) | parser | A string nobody terminates |
| `OSC_PAYLOAD_LIMIT` (1MB) | `osc_dispatch` | Everything that is not carrying a picture |
| `SIXEL_BODY_LIMIT` (8MB) | `Perform::put` | A sixel body that never ends |
| `MAX_PAYLOAD` (32MB) | `kitty.rs` | A transmission, compressed or not |
| `sixel::MAX_PIXELS` | `sixel::measure` | `!` as a compressor: 11 bytes name 4G pixels |
| geometry vs. payload | `Kitty::finish` | `s=65535,v=65535` with a four-byte payload |
| `MAX_RETAINED_BYTES`, `MAX_TRACKED_IMAGES` | `ImageStore` | A long session, module side |
| `cooked-image-cache-size` (64MB) | `cooked--evict-images` | A long session, Emacs side |

The last one is worth reading the docstring for before changing: eviction is two passes,
and the first only spends images with no live spec, which is free information rather than
a guess.

## Measuring

The benchmarks are the acceptance gate for anything touching the render or write paths.

```sh
cargo test --release --test throughput -- --ignored --nocapture   # the Rust core
emacs -Q --batch -L lisp -L tests -l cooked-bench.el -f cooked-bench
```

Compare interleaved against a worktree of the base commit, on a quiet machine, and never
alongside another benchmark run — a chunk of an earlier session was spent chasing a 4%
"regression" that was one benchmark loop contending with another.

Last measured: bounding the OSC buffer costs about 2% on the all-OSC benchmark, which is
one compare per payload byte, and nothing measurable on the others. Run-to-run noise on
these is 2-3%, so treat anything under 5% as needing more runs rather than a bisect.
