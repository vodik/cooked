# Images

Commands that draw a picture in a cooked buffer. `--passthrough none` matters for chafa:
it otherwise wraps its output for tmux and screen, and cooked is neither.

```sh
# kitty graphics, sixel, and whichever chafa detects on its own
chafa -f kitty --passthrough none -s 60x20 kitty-test.png
chafa -f sixel --passthrough none -s 60x20 kitty-test.png
chafa          --passthrough none -s 60x20 kitty-test.png

# iTerm2 inline images -- no encoder needed, just base64
printf '\033]1337;File=inline=1:%s\a' "$(base64 -w0 kitty-test.png)"

# ...where width= and height= are counted in cells
printf '\033]1337;File=inline=1;width=20;height=6:%s\a' "$(base64 -w0 kitty-test.png)"

# an animation, one transmission per frame
chafa -f sixel --passthrough none -s 40x20 something.gif

# video, at whatever frame rate the terminal can keep up with
mpv --vo=sixel --profile=sw-fast clip.mp4
mpv --vo=kitty --profile=sw-fast clip.mp4
```

Running `chafa` with no `-f` is the one worth doing at least once: it asks the terminal
what it supports and picks. That covers the kitty capability probe (`a=q`) and the primary
DA, which is the part a terminal can get wrong while rendering perfectly — answer neither
and every well-behaved producer falls back to ASCII art.

A plot, which is the reason to want any of this:

```sh
python3 <<'EOF'
import io, sys, base64
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
fig, ax = plt.subplots(figsize=(6, 3))
ax.plot([1, 4, 2, 8, 5, 7]); ax.set_title("cooked")
buf = io.BytesIO(); fig.savefig(buf, format="png", dpi=100)
sys.stdout.write("\033]1337;File=inline=1:%s\a" % base64.b64encode(buf.getvalue()).decode())
EOF
```

`o=z`, the zlib-compressed kitty transmission that kitty's own `icat` sends by default,
has no producer installable here, so it takes a few lines. The 4096-byte chunking is the
protocol's rule rather than ours; one unchunked APC works too, up to the parser's 8MB.

```sh
python3 - kitty-test.png <<'EOF'
import sys, zlib, base64
data = base64.b64encode(zlib.compress(open(sys.argv[1], "rb").read(), 9)).decode()
first = True
while data:
    chunk, data = data[:4096], data[4096:]
    control = "a=T,f=100,o=z,i=1," if first else ""
    sys.stdout.write("\033_G%sm=%d;%s\033\\" % (control, 1 if data else 0, chunk))
    first = False
EOF
```

**When nothing appears.** These paths draw a whole picture or nothing at all, so the
useful question is whether the terminal refused *out loud* or dropped the transmission
silently — and the answer goes to the child, not the screen. Both of these should draw
nothing, reply, and not hang:

```sh
printf '\033_Ga=T,f=100,t=f,i=7;L3RtcC9mb28ucG5n\033\\'   # ENOTSUPPORTED:medium
printf '\033_Ga=T,f=24,s=65535,v=65535,i=8;AAAA\033\\'    # EINVAL:dimensions
```

---

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
| `MAX_TRACKED_IMAGES` (4096) | `ImageStore` | A long session's bookkeeping |
| `cooked-image-cache-size` (64MB) | `cooked--evict-images` | A long session's pictures |

Those two bound different things, and only the second bounds any pixels. The module
keeps no payload at all — a geometry and a 128-bit digest per image, some forty bytes —
so its cap is on how many pictures it can still *recognise*, not on how much it holds.
`cooked-image-cache-size` is worth reading the docstring for before changing: eviction
spends only images with no live spec, which is free information rather than a guess.

Neither cap is what a *font* change spends. That drops the module's store whole, because
the geometry it keeps is a count of cells measured against the old one, and answering a
retransmission with it is what makes a looping gif alternate between two sizes. See
`Term::set_cell_metrics`.

It used to keep the payloads too, under a 64MB cap of its own, so that a kitty client
could place an image it had transmitted earlier by bare id. That is what
[the single-owner invariant](DESIGN.md#images-have-one-owner-and-it-is-emacs) replaced:
Emacs holds the only copy, the module is told when Emacs drops one, and a bare-id
placement of a picture that has gone is answered `ENOENT:image` rather than drawn from a
second cache with a policy of its own.

## What is not implemented, and why

**Kitty transmission by file** (`t=f`, `t=t`, `t=s`) is declined with
`ENOTSUPPORTED:medium`. Deliberately: reading a path a child names is a decision about
trust, not a decode, and it deserves a real decision rather than a default. If you take
it up, the options are temp files only — `t=t`, where the protocol says the terminal
deletes the file after reading — under the system temp dir; or all three behind a
defcustom defaulting to off.

**Kitty extensions not attempted:** unicode placeholders (`U=`), animation, z-index,
source rectangles (`x=`/`y=`/`w=`/`h=`), cell offsets (`X=`/`Y=`).

**Sixel gaps.** `Pu=1` (HLS colour) is ignored in favour of leaving the register alone,
no encoder in circulation emitting it. Background mode `P2` is ignored too, since
untouched pixels are transparent whatever it says. DECSDM is unimplemented.

## Things to know before you trust a green suite

**Batch Emacs draws nothing.** A run of box drawing rendered as a single glyph for one
commit because the memoized image spec made adjacent `display` properties `eq`, and
Emacs merges those into one image. Every character had a correct property throughout, so
the suite was green. `cooked-adjacent-box-glyphs-do-not-share-a-display-property` guards
it now. If you touch the decoration path, ask what the display engine does that a text
property assertion cannot see.

**The decoders were checked against other people's implementations, not their own
tests.** Sixel decodes pixel-for-pixel identically to `sixel2png` on chafa's output
across six colour and dither settings up to 2000x1000, alpha included. Format sniffing
was checked against real PNG, GIF, and baseline and progressive JPEG files down to 1x1.
This is worth redoing rather than trusting if you change either: both were written to
pass vectors that a subtly wrong decoder also passes.

A trap worth naming, because it cost an hour: the ST terminator's `\` is `0x5C`, which
is inside sixel's own data range, so a harness that hands the decoder one byte too many
silently paints an extra column. The real parser strips the terminator; test scaffolding
has to as well.

**The terminal's own echo lands inside pictures.** Ctrl-C in `viu` was losing all but
the first row of the animation, and neither end of that is where it looks. `ECHOCTL`
writes `^C` into the pty's *output* the moment the key is pressed, and a child part-way
through a four-megabyte frame is blocked in `write`, so the echo goes in between two
pieces of that write — inside the payload — and the rest of the write is never made. So
the frame arrives with two bytes nobody sent and several kilobytes missing. Refusing it
over either costs far more than the frame: `viu` parks the cursor at the picture's *top*
row between frames, so a frame that places nothing leaves it there for the newline after
it to move one row *into* the picture, and for the shell's `ED` on the way to a new
prompt to erase everything below. Both are repaired in `decode_base64` and `Kitty::finish`
rather than papered over at the cursor, and the reasoning is in those two docstrings.

**Untouched sixel pixels are transparent**, whatever the introducer's background mode
says. The spec calls them "the background colour" and expects the terminal to know what
that is; here Emacs does, and alpha is how the buffer face shows through. If someone
reports a picture with a transparent hole where another terminal draws grey, this is
why, and it is deliberate.
