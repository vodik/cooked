;;; cooked-deco.el --- Box glyphs and images, as things a cell displays instead -*- lexical-binding: t; -*-

;;; Commentary:

;; A decoration is a cell that displays something other than the character it holds.
;; Two kinds arrive, and they are one mechanism on purpose: a box-drawing glyph is
;; *derived* from the character, an image placement is *stored* against the cell, and
;; both cross from Rust as `(KIND . PACKED)\=' and end as a `display\=' property here.
;;
;; The rasterizer is cooked-glyph.el, which knows nothing about terminals.  What is
;; here is everything buffer-shaped: caching a bitmap against the window\='s cell size,
;; slicing an image one cell at a time, and rebuilding all of it when the font moves
;; under it.  Colour is nobody\='s job here -- a glyph is drawn in the colours of the
;; face it lands on, which is what keeps it in step with the text beside it.
;;
;; Image lifetime is Emacs\='.  `cooked--image-data\=' is the only copy of the bytes, so it
;; is strong; `cooked--image-specs\=' is rebuildable, so it is weak on the value, and the
;; buffer text displaying a spec is what keeps it alive.  The module asks for nothing back
;; and never sends a picture twice -- but it does have to be *told* when we drop one, or
;; it goes on answering a retransmission with an id whose bytes we no longer have.  That
;; is `cooked--forget-image\=', and it is one-way: a report, not a protocol.

;;; Code:

(require 'cooked-util)
(require 'cooked-face)
(require 'cooked-color)
(require 'cooked-glyph)

(cooked--declare-core)

(defcustom cooked-inline-images t
  "Whether to display images the child transmits.

Images arrive through a terminal graphics protocol, are held for as long as the
buffer text showing them lives, and are rendered as one `display\=' slice per
cell they cover.  Setting this to nil leaves those cells as the blanks they
already are on the grid, so the layout is unchanged and only the picture is
missing.

Distinct from `cooked-box-drawing-images\=', which is about substituting a
generated bitmap for a character the font could draw itself."
  :type 'boolean
  :group 'cooked)

(defcustom cooked-box-drawing-images t
  "Whether to render box-drawing and block-element characters as generated bitmaps.

On by default: most monospace fonts draw ─│┌┐└┘├┤┬┴┼ and the block-shade
characters (▀▄█▌▐░▒▓ etc.) with glyph-to-glyph inconsistencies, highly visible
in full-screen programs like htop, ranger and fzf that rely on these
characters forming continuous borders.  Cooked classifies these characters in
its native core and renders them as small generated bitmaps sized to the
current font and colored from the active theme — the same approach VTE, Kitty
and Alacritty take.

Falls back to plain colored text, exactly as when this is nil, if Emacs lacks
XBM image support or bitmap generation fails for a glyph.

Setting it through `customize\=' or `setopt\=' redraws the screens already
running; see `cooked--set-rendering-option\='."
  :type 'boolean
  :set #'cooked--set-rendering-option
  :group 'cooked)

(defvar-local cooked--last-cell nil
  "The (WIDTH . HEIGHT) cell size in pixels last reported, or nil.

Written by `cooked--sync-size\=', which is the one place that notices the cell
moving, and tracked apart from `cooked--last-size\=' because it moves
independently of it: `text-scale-mode\=' changes the cell size and the row and
column count together, but a theme or font change can move the cell size while
the grid stays put, and the child has to hear about that too.

It lives here rather than beside `cooked--last-size\=' in cooked-state.el because
the renderer reads it: it is this buffer\='s own last known good measurement, and
`cooked--deco-cell-size\=' prefers it to any window that is not one of ours.
Either component is nil on a terminal frame, or when nothing has ever displayed
the buffer -- see `cooked--session-cell-size\='.")

(defvar-local cooked--box-ascent-cache nil
  "Line-box height -> the `:ascent' that lands a bitmap on it, per buffer.

Separate from `cooked--box-glyph-cache' because it memoizes a `font-info' call
rather than a bitmap, and that call is far too costly to repeat per character
on a full-screen repaint.  Keyed by height alone: the answer depends only on
the font's ascent relative to the line box.")

(defvar-local cooked--box-glyph-height-cache nil
  "Line-box height -> the height a box-drawing bitmap is drawn at, per buffer.

The other half of `cooked--box-ascent-cache\=', memoizing the same font lookup
for `cooked--box-glyph-height\='.")

(defvar-local cooked--box-glyph-cell-cache nil
  "Descriptor+pixel-size -> unpacked single-cell bitmap, per buffer.

Colorless by construction: the cached value is a shape only, and stays one all
the way to the screen — Emacs colours the finished XBM from the face it is
displayed on.  So unlike `cooked--face-cache' this needs no theme-change
invalidation; only pixel-size changes (zoom, font change) miss the cache key,
naturally, with no extra plumbing.

Deliberately unbounded, and safely so: the key has no run length in it, so its
whole range is a few dozen box-drawing bit patterns times a couple of cell
sizes -- at most a few hundred entries, ever, for the life of the buffer.
`cooked--box-glyph-cache\=' is the tier that varies with content
and needs a bound instead.")

(defcustom cooked-box-glyph-run-cache-limit 1024
  "How many run patterns `cooked--box-glyph-cache' and
`cooked--deco-image-cache' remember, per buffer, before each starts over.

Both are keyed in part by a box-drawing run\='s *pattern* -- the shapes it
draws and how many cells each of them covers -- which a border resizing, a
progress bar filling in, or `fzf\=' widening its highlight can hand a fresh
value on every drain.  Unlike the shape itself, a pattern has no bound of its
own.  Left unwatched, either cache would grow for as long as such a program
kept redrawing, which is most of a session running one.

The default is set from the largest listings measured, through the core and
`cooked--glyph-run-segments\=' as a session cuts them.  A `tree\=' indent is
one pattern per combination of depth, continuing levels and last entries, so
the count grows with how deep and how uneven a tree is rather than with its
length: `tree -C /usr/include\=' draws 62 distinct patterns over 30,000 rows,
`/usr/lib\=' 505 over 181,000, and the first 400,000 rows of a source
directory of forty repositories 611.  Under the old limit of 512 that last
listing cleared both tables once on arrival and again on every
`cooked--rescale-deco\=' of the transcript, which walks every pattern in it.
1024 holds each of them with room for the borders and progress bars of the
programs run beside it.

A btop shade plot, a fresh mix of densities across the row every frame, never
reaches these tables at all, because a shade is painted as a background rather
than drawn as a bitmap; see `cooked--apply-shade\='.  What mints keys without
end is a progress bar or a resizing border, one per width.

Raising this trades memory for fewer of the clears below buying back a shape
`cooked--box-glyph-cell-cache\=' already has for free; lowering it does the
opposite.  An entry is a bitmap as wide as its run, a kilobyte for a
forty-cell indent at a 10x20 cell, so the default costs a few megabytes at
most.  See `cooked--cached-bounded\='."
  :type 'natnum
  :group 'cooked)

(defvar-local cooked--box-glyph-cache nil
  "Run pattern+pixel-size -> packed XBM bitmap, per buffer.

Bounded by `cooked-box-glyph-run-cache-limit\=': see there and
`cooked--box-glyph-cell-cache\=' for why the pattern is the dimension worth
capping and the shape is not.  A miss here costs a tile and a pack --
`cooked--pack-box-glyph-run\=' -- never the trigonometry
`cooked--render-box-glyph-cell\=' does, which the cell cache still holds, once
per distinct shape in the pattern however many cells each covers.")

(defvar-local cooked--image-data nil
  "Image id -> (FORMAT DATA PX-WIDTH PX-HEIGHT COLS ROWS), as transmitted.

The resource itself, and the only copy of it: `cooked--drain' hands each
distinct image over exactly once -- ids are content-addressed, so a child
redrawing the same picture every frame transmits it every frame and the module
sends it once -- and will not send it again on request.  So this is a strong
table.  It is buffer-local, and dies with the buffer.

Deliberately not weak.  A placement is a reference to an id, and rows are
re-rendered constantly, so a collected entry would leave cells naming an image
nothing could rebuild.  `cooked--image-specs' is the weak half.")

(defvar-local cooked--image-bytes 0
  "Total length of the DATA strings in `cooked--image-data\='.

Kept alongside rather than recomputed, because the alternative is walking every
image on every transmission -- and a child that streams pictures is exactly the
case the cap exists for.")

(defvar-local cooked--image-order nil
  "Image ids in `cooked--image-data\=', oldest transmission first.

Insertion order rather than use order.  Emacs never reuses an id -- they are
content-addressed in the module -- so this is a queue that only ever grows at
one end, and the far end is what `cooked--evict-images\=' spends.

Maintained through `cooked--image-order-append\=' and
`cooked--image-order-set\=' rather than written to directly, because the tail
below has to move with it.")

(defvar-local cooked--image-order-tail nil
  "The last cons of `cooked--image-order\=', so an append costs nothing.

A queue whose oldest end is its head is the right shape for eviction and the
wrong one for insertion: appending to a list means walking it, so filling a
cache of N pictures would cost O(N^2).  N can be large, because the cap is in
bytes -- a child drawing 4KB icons holds sixteen thousand ids under the same
64MB that holds a few dozen multi-megabyte frames.  The module's `Ledger\=' in
src/emu/intern.rs keeps its order the same way, for the same reason.

A second copy of a fact can disagree with the first, which is why nothing sets
`cooked--image-order\=' in place.  The two writers are the append and the
wholesale replacement, and both live next to this.")

(defvar-local cooked--image-specs nil
  "(ID CELL-WIDTH CELL-HEIGHT) -> the `create-image' spec, weakly.

Weak on the value, which is safe precisely because it is rebuildable: a spec is
a pure function of `cooked--image-data' and the cell size, so losing one costs a
rebuild and nothing else.

What keeps a spec alive is the buffer text displaying it -- Emacs holds the spec
in the `display' property, so the text is the strong reference and the collector
frees only specs nothing is showing.  That is the whole lifetime story for
images, and the reason there is no release protocol between the module and this
file: Emacs already owns the question.")

(defvar-local cooked--deco-cell nil
  "The cell size `cooked--rescale-deco\=' last rebuilt the decorations at.

Only so that the walk can decline to run twice for one font change.  A zoom
reaches `cooked--rescale-deco\=' by both of its routes -- the
`text-scale-mode-amount\=' watcher, and `cooked--sync-size\=' off
`text-scale-mode-hook\=' -- and whichever of the two gets there after the face
remap has actually landed is the one that does the work; the other finds the
size already current and returns.  Every row written by `cooked--apply-deco\='
in between used the same `cooked--deco-cell-size\=', so agreement here is
agreement everywhere.")

(defvar-local cooked--deco-image-cache nil
  "Decoration + cell size -> the `create-image' spec, per buffer.

A second cache in front of `cooked--box-glyph-cache', which memoizes only the
raw bits.  Building the spec was still per character per frame: a fresh list
and a fresh image object for every box character of every damaged row, which on
a full-screen TUI is most of the screen many times a second.  Sharing one spec
across every cell that wants it also means Emacs' own image cache sees one
image rather than hundreds of identical ones.

Colour is no part of the key, because it is no part of the spec: a glyph is
drawn in the colours of the face it lands on, so one entry serves every
rendition of that shape at that size.  What the spec does hold that the bits do
not is `:ascent', measured from the default face's font -- which a theme can
move without moving the cell size, and is why `cooked--flush-deco-cache' still
empties this on a theme change.

Also bounded by `cooked-box-glyph-run-cache-limit', for the pattern reason
`cooked--box-glyph-cache' is: this sits in front of that cache rather than of
`cooked--box-glyph-cell-cache', so a miss here still costs no more than a
`create-image' call over bits the other two caches already have between
them.")

;;;; Box-drawing / block-element bitmaps
;;
;; The rasterizer itself is cooked-glyph.el, which knows nothing about terminals:
;; it turns a shape descriptor and a pixel size into raw XBM bits.  What is left
;; here is everything that depends on this buffer — caching a bitmap against the
;; window's current cell size, and hanging the result on buffer text.
;;
;; Nothing here colours anything.  An XBM with no `:foreground' and no
;; `:background' is drawn in the colours of the face it is displayed on, and
;; Emacs re-renders it when that face changes, so the shape stays shape data all
;; the way to the screen and a glyph tracks the region, `hl-line-mode' and an
;; `isearch' match exactly as the text beside it does.  Neither cache below needs
;; the theme-flush treatment `cooked--face-cache' gets for anything colour.

(defun cooked--cell-size (window)
  "WINDOW's cell size in pixels, as (WIDTH . HEIGHT).

Measured once per render pass and passed down, rather than asked per character.
Both calls are cheap but neither is free, and the callers below run over every
decorated character of every damaged row of every frame.

Sized from `window-font-width'/`window-default-line-height' rather than
`frame-char-width'/`frame-char-height': the latter ignore `text-scale-mode's
per-buffer face remapping, so zooming just this buffer would desync bitmap
size from font size — the very misalignment this feature exists to remove.

Height comes from `window-default-line-height', not `window-font-height', for
the reason `cooked--window-rows' already gives: the line box is what a row
actually occupies and includes `line-spacing', while the font height does not.
That is the cell a child is told about and a picture is sliced by.  A
box-drawing bitmap is drawn shorter than it under `line-spacing\=', for the
reason `cooked--box-glyph-height\=' gives."
  (cons (window-font-width window 'default)
        (window-default-line-height window)))

(defvar cooked--deco-cursor nil
  "The child\='s cursor as (ROW . CHARS), for the render pass.

CHARS counts the characters of the row\='s text before the cursor, as
`cooked-cursor-chars\=' does, so that it compares with a character offset from
the row\='s start: on `日本──\=' with the cursor on the first `─\=', column 4,
it is 2.

Bound by `cooked--apply\=' in cooked-render.el for exactly as long as the two
render passes run, and nil everywhere else -- including in a rescale, which
rebuilds from run boundaries the buffer already holds and so has no cursor
question to ask.

Not `cooked--cursor\=', which is the same fact one drain out of date at the
only moment this is read: `cooked--apply-levels\=' adopts the drain\='s levels
*after* `cooked--render-rows\=' has written the rows, and the rows have to be
split for the cursor this drain is putting there rather than the one the last
drain did. Reordering the apply to fix that is not available -- the render
depends on the outgoing grid -- so the one value the render needs is bound
across it instead.

Read by `cooked--glyph-run-segments\=', which says what it is for.")

(defvar cooked--deco-pass nil
  "This render pass\='s (WINDOW . CELL), computed at most once, or nil outside one.

`cooked--apply-deco\=' is called once per decoration record, and a record is a
run of one shape rather than a row.  A TUI border row is one record, but `tree'
in a large directory is not: its indent is `U+2502\=' separated by `U+00A0\=', so
it arrives as three runs per nesting level, and asking `cooked--layout-window\='
and the cell size per record meant tens of thousands of window measurements for
one listing.  `window-font-width\=' and `window-default-line-height\=' are each
far dearer than `frame-char-width\=', so the pass asks them once.

A box rather than a plain value because the answer is wanted lazily: a drain
that decorates nothing should not pay to measure a cell it never uses.
`unset\=' is the sentinel for \"this pass has not asked yet\", which nil cannot
be -- nil is the honest answer for a buffer displayed nowhere on a terminal
frame, and caching it as though it were a miss would re-measure every record on
exactly the sessions that can least afford it.

Bound in `cooked--apply\=', which is the render pass: nothing between its first
`cooked--render-scrolled\=' and its last `cooked--render-rows\=' creates, deletes
or resizes a window, or changes a font -- the argument `cooked--render-rows\='
makes for hoisting `cooked--layout-window\=' out of its loop.  Unbound, every
caller is answered per call, correctly and slowly.")

(defun cooked--deco-geometry ()
  "This buffer\='s (WINDOW . CELL) for decorating, from `cooked--deco-pass\=' if set.

The one place the two halves are computed, because they are one question asked
twice: WINDOW is the window a decoration is measured against and CELL is what
that window measures, so answering them separately means walking
`get-buffer-window-list\=' twice for a single record."
  (if (and cooked--deco-pass (not (eq (car cooked--deco-pass) 'unset)))
      (car cooked--deco-pass)
    (let* ((window (cooked--layout-window))
           (answer (cons window
                         (if window
                             (cooked--cell-size window)
                           (and (integerp (car-safe cooked--last-cell))
                                (integerp (cdr cooked--last-cell))
                                cooked--last-cell)))))
      (when cooked--deco-pass (setcar cooked--deco-pass answer))
      answer)))

(defun cooked--deco-window ()
  "The window this buffer\='s decorations are measured against, or nil.

`cooked--layout-window\=', by way of `cooked--deco-geometry\=' so that a render
pass asks for it once."
  (car (cooked--deco-geometry)))

(defun cooked--deco-cell-size ()
  "The cell size in pixels this buffer\='s decorations are drawn at, or nil.

A decoration is a picture cut to the size of a text cell, so getting the size
wrong is not a cosmetic error: an image slice taller than a line pushes the rows
below it down, and two halves of one picture built at two sizes stay visibly
mismatched for as long as the transcript lives, because nothing re-renders
scrollback.

`cooked--layout-window\=' first, and no `selected-window\=' fallback, for the
reason its own docstring gives at length -- the selected window is very often
not one of ours (the minibuffer while a completion session previews this buffer,
a neighbour while the frame is resized), and `window-font-width\=' and
`window-default-line-height\=' are per-window and honour that window\='s face
remapping and `text-scale-mode\='.  Measuring cooked\='s text against someone
else\='s window is not a weaker measurement, it is a meaningless one.

So when the buffer is displayed nowhere the answer comes from the buffer itself:
`cooked--last-cell\=', the size `cooked--sync-size\=' last reported to the child,
which is the last size this buffer\='s rows were genuinely laid out at.  A
picture drawn while the buffer is off screen then matches the one drawn before
it went, which is the whole point.

Nil when there is no honest answer at all -- a terminal frame, or a session
nothing has ever displayed.  Callers decorate nothing rather than guessing; see
`cooked--apply-deco\='.

Asked once per render pass rather than once per decoration record; see
`cooked--deco-pass\=' for what that was costing and why the pass is the scope."
  (cdr (cooked--deco-geometry)))

(defun cooked--box-glyph-cell (bits size)
  "Cached unpacked single-cell bitmap for glyph BITS at cell SIZE.

The tier `cooked--box-glyph-bits\=' tiles rather than redraws: see
`cooked--box-glyph-cell-cache\=' for why this one is safe to leave unbounded."
  (cooked--cached cooked--box-glyph-cell-cache (list bits (car size) (cdr size))
    (cooked--render-box-glyph-cell bits (car size) (cdr size))))

(defun cooked--glyph-pattern (bits count)
  "A one-record run pattern: COUNT adjacent cells drawing shape BITS.

The wire\='s own encoding, built by hand for the two callers that have a shape
and a width rather than a slice of `Deco::packed\=' to hand on -- see
`cooked--glyph-run-segments\=', which cuts a run into the parts that may share
an image, and `cooked--glyph-pattern-take\=', which cuts one down to the width
the buffer now holds."
  (unibyte-string (logand bits #xff) (logand (ash bits -8) #xff)
                  (logand count #xff) (logand (ash count -8) #xff)))

(defun cooked--glyph-pattern-records (pattern)
  "PATTERN decoded into a list of (BITS . COUNT), left to right.

PATTERN is a run\='s decoration as `Deco::packed\=' in src/emu/cell.rs writes
it: a unibyte string of four-byte little-endian (BITS COUNT) records.  A whole
run rather than one record, which is the unit an image is baked at -- see
`cooked--apply-glyph-deco\='."
  (let ((out nil)
        (i 0)
        (limit (length pattern)))
    (while (< i limit)
      (push (cons (cooked--u16 pattern i) (cooked--u16 pattern (+ i 2))) out)
      (setq i (+ i 4)))
    (nreverse out)))

(defun cooked--glyph-pattern-cells (pattern)
  "How many cells PATTERN covers: the sum of its records\=' counts."
  (let ((cells 0)
        (i 2)
        (limit (length pattern)))
    (while (< i limit)
      (setq cells (+ cells (cooked--u16 pattern i))
            i (+ i 4)))
    cells))

(defun cooked--glyph-pattern-blank-p (pattern)
  "Whether every record of PATTERN is the blank shape, so it draws nothing.

A blank between two shades is absorbed into their run on the wire -- see
`Row::absorb_blank_runs\=' in src/emu/cell.rs -- and once the shades are cut out
as segments of their own it is left as a segment of nothing but blanks.  An
image of it would be a picture of the background the spaces already show, so it
gets none, and `░ ░ ░ ░\=' costs the shades\=' intervals and no more."
  (let ((i 0)
        (limit (length pattern))
        (blank t))
    (while (and blank (< i limit))
      (setq blank (= 0 (cooked--u16 pattern i))
            i (+ i 4)))
    blank))

(defun cooked--glyph-pattern-head (pattern)
  "The shape PATTERN\='s first cell draws.

A shade is always a pattern of one record -- see
`cooked--glyph-run-segments\=' -- so this is also how a shade segment names
its density."
  (cooked--u16 pattern 0))

(defun cooked--glyph-pattern-take (pattern count)
  "PATTERN cut down to its first COUNT cells, or PATTERN itself if it is shorter.

For `cooked--deco-image\=', whose COUNT comes from the *buffer* rather than from
the wire: `cooked--rescale-deco\=' reads a run\='s width off the text it is
rebuilding, and a run the buffer has since shortened must be repaired to the
width it now has rather than to the one it was written at.  Identity when the
two agree, which is every call on the render path."
  (if (>= count (cooked--glyph-pattern-cells pattern))
      pattern
    (let ((out nil)
          (left count)
          (i 0))
      (while (> left 0)
        (let* ((bits (cooked--u16 pattern i))
               (take (min left (cooked--u16 pattern (+ i 2)))))
          (push (cooked--glyph-pattern bits take) out)
          (setq left (- left take)
                i (+ i 4))))
      (apply #'concat (nreverse out)))))

(defun cooked--box-glyph-bits (pattern size)
  "Cached packed bitmap for run PATTERN at cell SIZE.

PATTERN is a whole run\='s (BITS COUNT) records -- see
`cooked--glyph-pattern-records\=' -- and joins the key because two runs drawing
different shapes, or the same shapes over different widths, are genuinely
different bitmaps.  See `cooked--box-glyph-cache\=' for why that makes this tier
the one that needs a bound and `cooked--box-glyph-cell\=' the one that does not.
A miss here asks that tier for each distinct shape and only tiles and packs them
-- `cooked--pack-box-glyph-run\=' -- never redraws one.

The key is the packed string itself rather than a list of decoded records, and
that is not incidental: `sxhash-equal\=' walks only the first few elements of a
list, so an eleven-record `tree\=' indent keyed as a list would collide with
every other indent of the same depth and turn the lookup into a linear scan of
`equal\=' comparisons.  A string fares better but is not hashed whole either:
past 64 bytes, sixteen records, Emacs samples it.  So deep indents do share
hashes, and measured they share few: the 611 patterns of 400,000 `tree\=' rows
land on 548 hashes, at most five on one, which costs a lookup no more than five
`equal\=' comparisons of strings a hundred bytes long.  Hashing the whole string
in Lisp through `define-hash-table-test\=' would cost every lookup more than
those collisions cost the few that meet one.

The string is also canonical -- a count is never zero and no two adjacent
records share a shape -- so two runs that draw the same thing key the same."
  (cooked--cached-bounded cooked--box-glyph-cache cooked-box-glyph-run-cache-limit
      (list pattern (car size) (cdr size))
    (cooked--pack-box-glyph-run
     (mapcar (pcase-lambda (`(,bits . ,count))
               (cons (cooked--box-glyph-cell bits size) count))
             (cooked--glyph-pattern-records pattern)))))

(defun cooked--box-glyph-ascent (window height)
  "Return the `:ascent' that places a bitmap on WINDOW's line box.

HEIGHT is the bitmap's height in pixels.

A percentage rather than `center' now that the bitmap spans the whole line box:
`center' balances the image around the text's midline, which splits any
`line-spacing' evenly above and below and lifts the glyph off the box it was
sized to fill.  Anchoring the font's own ascent instead keeps the extra space
where Emacs actually puts it — below the baseline.

Falls back to `center' if the font reports no metrics, which is the previous
behaviour and still correct whenever `line-spacing' is nil.  That is always
the case on a terminal frame, which has no font to ask.

The font is `cooked--default-font\=''s, which follows a zoom, and a zoom moves
the line box with it, so HEIGHT is a new key for a zoomed font.  A font swapped
for one of the same line height and a different ascent is the case the key
does not see.

The percentage is the one Emacs turns back into exactly the font\='s ascent,
which `cooked--image-ascent-percent\=' explains."
  (cooked--cached cooked--box-ascent-cache height
    (let ((base (when-let* ((font (cooked--default-font window)))
                  (aref (query-font font) 4))))
      (if (and (natnump base) (> height 0) (<= base height))
          (cooked--image-ascent-percent base height)
        'center))))

(defun cooked--box-glyph-height (window line)
  "The height to draw a box-drawing bitmap at, in a LINE-pixel line box on WINDOW.

The font\='s ascent and descent together, which is LINE itself unless
`line-spacing\=' is set.  Emacs adds the spacing below every glyph on a row,
an image as much as a character, so a bitmap already as tall as the line box
gets it a second time.  With `line-spacing\=' 2 in a font of ascent 13 and
descent 4, a 19-pixel bitmap made its row 21 pixels tall, and a screen of box
drawing ran past the rows the child was told.  Drawn 17 pixels tall, a glyph
occupies what the text beside it does, and the spacing below it is background,
as it is below the text.  A vertical border then shows a gap of the spacing
between rows, which is the price of the grid fitting its window.

LINE when the font reports no metrics, as on a terminal frame, or reports
more than the line box holds.  Cached by LINE as `cooked--box-glyph-ascent\=' is,
and blind to the same font swap."
  (cooked--cached cooked--box-glyph-height-cache line
    (let* ((font (cooked--default-font window))
           (metrics (and font (query-font font)))
           (text (and metrics (+ (aref metrics 4) (aref metrics 5)))))
      (if (and text (< 0 text line))
          text
        line))))

(defun cooked--image-ascent-percent (ascent height)
  "The `:ascent\=' percentage that puts ASCENT of HEIGHT pixels above the baseline.

Emacs does not round the percentage back into pixels, it truncates: an image
HEIGHT tall with `:ascent\=' P gets an ascent of HEIGHT * (P / 100.0) cut down
to an integer.  The nearest percentage is therefore often a pixel short.  A
17-pixel bitmap in a font of ascent 13 and descent 4 rounds to 76, which is
12.92 pixels and so 12.  The image then hangs 5 pixels below the baseline where
the font hangs 4, and a row holding one is 18 pixels tall in a 17-pixel line
box.  A screen of box drawing, which is what htop and btop draw, then no longer
fits the rows the child was told, and every vertical border has a gap in it.

So this takes the smallest percentage whose truncation lands on ASCENT, worked
in the same floating point Emacs uses, since 100 * (29 / 100.0) comes out a
hair under 29.  Such a percentage almost always exists up to 100 pixels,
because consecutive percentages move the ascent by less than a pixel.  Where
none does, as for an ascent of 29 in 100 pixels, the least percentage that
reaches ASCENT in exact arithmetic is a pixel off, and nothing does better."
  (let ((least (ceiling (* 100 ascent) height)))
    (or (cl-loop for percent from least to 100
                 for pixels = (truncate (* height (/ percent 100.0)))
                 until (> pixels ascent)
                 when (= pixels ascent) return percent)
        (min least 100))))

(defun cooked--box-glyph-image (pattern window size)
  "Image spec for the run PATTERN draws at cell SIZE.

Memoized in `cooked--deco-image-cache'.  Not premature: the bits underneath were
already cached, but the spec was rebuilt for every box character of every
damaged row of every frame — and a fresh spec each time also denies Emacs' own
image cache the chance to notice that a screenful of box drawing is a handful of
distinct images.  WINDOW is needed only for the ascent's `font-info' lookup.

Colourless, so the key is the shape and the pixels alone: a spec is now shared
by every cell drawing this glyph at this size whatever rendition it is under,
and Emacs\=' own image cache does the per-face split — see
`cooked--box-glyph-image-1\='.

`:scale 1' is load-bearing, not a default being restated.
`image-scaling-factor' is `auto', which scales every image by cell-width/10
once a cell is wider than
10 pixels — true of most GUI font sizes.  These bitmaps are already generated
at exactly the cell size, so letting that apply would resample a pixel-exact
10x20 stroke up to 12x24 inside a 10x20 cell: borders stop meeting at the cell
edge and the strokes blur into something no better than the font glyphs this
replaces."
  (cooked--cached-bounded cooked--deco-image-cache cooked-box-glyph-run-cache-limit
      (list pattern (car size) (cdr size))
    (cooked--box-glyph-image-1 pattern window size)))

(defun cooked--uncolored (image)
  "IMAGE with any `:foreground\=' or `:background\=' removed.

Enforced rather than assumed, because a spec leaves `create-image\=' having
passed through whatever advice the user\='s configuration has put on it, and one
package in circulation colours every image unconditionally: `solaire-mode\='
installs a `:filter-return\=' advice that `plist-put\='s the background of
`solaire-default-face\=' onto anything created in a buffer where it is enabled.
That is right for the transparent PNG of an icon, which has no colour of its
own to lose, and wrong for a bitmap whose second colour is the terminal cell it
stands in: the glyph then keeps solaire\='s background whatever the child paints
behind it.  Which is the defect `cooked--box-glyph-image-1\=' exists to avoid,
reaching the spec from outside instead of from us.

Rebuilt rather than edited in place, because the pair is spliced onto a list
`create-image\=' has already returned and can sit anywhere in it -- and because
a spec we hand to a hash table should not be a list somebody else still holds a
tail of."
  (let ((out nil)
        (tail (cdr image)))
    (while tail
      (unless (memq (car tail) '(:foreground :background))
        (push (car tail) out)
        (push (cadr tail) out))
      (setq tail (cddr tail)))
    (cons (car image) (nreverse out))))

(defun cooked--box-glyph-image-1 (pattern window size)
  "Build the spec `cooked--box-glyph-image' memoizes.

PATTERN, WINDOW, SIZE and PHASE mean what they do there.

Carries no `:foreground' and no `:background', which is the whole colour model
rather than an omission.  An XBM given neither is drawn in the colours of the
face it is displayed *on*: `xbm_load' falls back to the face\='s own pair, and
`search_image_cache' keys the cached pixmap on it, so one spec renders
correctly under every face it lands on and re-renders by itself when that face
changes.

Naming the colours here instead pinned the glyph to the run\='s own rendition
and so defeated everything Emacs composites over it — the region, an active
`hl-line-mode\=', an `isearch\=' match, `mouse-face\=', and the buffer-local
remapping of `default\=' an OSC 11 background arrives as.  The foreground came
through all of that unharmed because a cell\='s foreground is exactly what the
face already carries; a background is not, being whatever ends up merged at the
position, so box drawing was the one run of text in the buffer that a selection
left unhighlighted.

The face is there to be read: `cooked--render-block' puts the run\='s style span
over exactly the characters its decoration span covers, so an explicit
background, reverse video and conceal all reach the bitmap through it — conceal
now hiding a box glyph as it always did the text beside it."
  ;; `:data-width'/`:data-height'/`:stride' are what an inline `xbm' actually
  ;; requires when `:data' is raw bits, per (elisp) XBM Images -- and they are not
  ;; interchangeable with `:width'/`:height', which scale an already-decoded image
  ;; rather than describe the bit layout.  Emacs accepts only three `:data' shapes:
  ;; a vector of per-row strings, a whole XBM *file* in a string, or bare bits with
  ;; these three properties.  A packed (WIDTH HEIGHT DATA) list is none of them.
  (pcase-let ((`(,width ,height ,data)
               (cooked--box-glyph-bits
                pattern
                (cons (car size) (cooked--box-glyph-height window (cdr size))))))
    (cooked--uncolored
     (create-image data 'xbm t
                   :data-width width :data-height height
                   :stride (* 8 (ceiling width 8)) ; bits per row, byte-aligned
                   :scale 1
                   ;; `image-transform-smoothing' defaults on, which interpolates
                   ;; edge pixels.  These bitmaps are pixel art meant to butt up
                   ;; against their neighbours, and a smoothed edge column reads
                   ;; as a faint seam between adjacent glyphs rather than a join.
                   :transform-smoothing nil
                   :ascent (cooked--box-glyph-ascent window height)))))

(defun cooked--apply-deco (start deco &optional origin row)
  "Hang DECO's per-character `display' properties on the text at START.

DECO is `(KIND . PACKED)\=', what the `Deco\=' conversion in src/wire.rs hands
over: KIND names what the run\='s characters display instead of themselves, and
PACKED is a unibyte string of fixed-width little-endian records.  Packed rather
than a list because this runs on every damaged row of every frame, and box
drawing is what full-screen programs are made of.

How much a record covers is the kind\='s own business, and the two kinds differ.
A glyph record covers a *run* of characters drawing one shape -- a border row is
one record -- because the core already knew the shape repeated and leaving Lisp
to rediscover it by comparison put the work on the slower side of the boundary.
An image record covers one character, because the grid addresses a picture one
cell at a time and that per-cell addressing is what survives an overwrite, a
scroll and a rewrap.  What reaches the *buffer* is a run either way:
`cooked--apply-image-deco\=' coalesces the records back into runs itself, the
comparison being far cheaper than the properties it saves.  Both functions
explain their end of that.

Also stashes `cooked-deco\=', the record and its place on the screen, so
`cooked--rescale-deco\=' can regenerate at a new zoom level without asking the
native core for anything.  One such property per run rather than per character,
for both kinds, and `cooked--rescale-deco\=' is written to expect it.

ORIGIN is the buffer position of screen column 0 on this row, and ROW the row\='s
index; together they say which cell the child\='s cursor is on, which is where
a glyph run is split -- see `cooked--glyph-run-segments\='.
ORIGIN is passed in rather than taken from `line-beginning-position\=' because
row 0 does not always start a buffer line -- it continues the wrapped row above
it.

No colours are passed, and none are wanted: a decoration is drawn in the
colours of the face `cooked--render-block\=' has already put on the very
characters it covers.  See `cooked--box-glyph-image-1\=' for why reading them a
second time here is not merely redundant but wrong.

With no cell size to be had (`cooked--deco-cell-size\=' nil: a terminal frame, or
a session nothing has ever displayed) the `cooked-deco\=' properties are still
stashed and no `display\=' property is put.  The characters then render as
themselves, which is strictly more information than a screenful of blanks -- the
child chose those mosaic characters as its own fallback -- and the stashed
records are exactly what `cooked--rescale-deco\=' needs the moment a window turns
up."
  ;; A cosmetic feature must never break rendering: any failure here leaves the
  ;; plain face-only text `cooked--render-block' already inserted.
  (cooked--protect-seam 'cooked--apply-deco
    (pcase deco
      (`(image . ,packed)
       ;; Its own preference, not `cooked-box-drawing-images': whether to
       ;; substitute a pixel-exact shape for a character the font can already
       ;; draw is a different question from whether to show a picture the child
       ;; sent.  Whether the *format* can be displayed is asked per image, in
       ;; `cooked--image-spec', since the answer differs between them.
       (when cooked-inline-images
         (cooked--apply-image-deco start packed (cooked--deco-cell-size))))
      (`(glyph . ,packed)
       ;; Each kind checks its own preconditions rather than the caller checking
       ;; for all of them: what a decoration needs in order to render is the
       ;; decoration's business, and the renderer should not have to grow a
       ;; condition every time a kind is added.
       (when (and cooked-box-drawing-images (image-type-available-p 'xbm))
         ;; `cooked--deco-window' rather than `cooked--layout-window' directly,
         ;; and the pair rather than either alone: the two are one lookup, and
         ;; taking them separately walked `get-buffer-window-list' twice per
         ;; record.  See `cooked--deco-pass'.
         (cooked--apply-glyph-deco
          start packed (cooked--deco-window)
          (cooked--deco-cell-size) origin row))))))

;;;; Shades
;;
;; ░▒▓ are the one part of the block that is not a shape.  A terminal that draws
;; them from the font gets a stipple the font designer chose; one that draws them
;; itself either dithers (kitty) or fills the cell with the foreground at 25, 50
;; or 75% coverage (ghostty).  A one-bit bitmap can only dither, and a dither
;; has to be phased against the cell's pixel origin to tile, which cost a
;; segment per cell, a phase in every cache key, and a seam on any row that
;; scrolled without being redrawn.  So a shade is painted as a background
;; instead: the cell's own two colours blended in linear light, over a stretch
;; of space as wide as the cells, and no image at all.

(defconst cooked--shade-coverage [0.0 0.25 0.5 0.75]
  "Foreground coverage of each shade density, indexed by its descriptor fraction.
░ is 1, ▒ 2 and ▓ 3; see `classify_block' in src/emu/glyph.rs.")

(defun cooked--shade-face (level face)
  "The face plist that paints shade LEVEL in the colours of FACE.

FACE is the rendition `cooked--render-block\=' put on the cells, or nil for the
default one.  Its foreground and background -- the buffer\='s defaults where it
names none, as the child sees them through OSC 10 and 11 and swapped under
DECSCNM, and exchanged if the cell is itself in reverse video -- are blended by
`cooked--blend\=', and the result is both the foreground and the background of
the plist.  The background is what a stretch of space shows; the foreground
matching it is what keeps the character invisible where there is no cell size
to draw a stretch against.

Concealed text has its foreground made the background, whether
`cooked--face-build\=' named that colour or left it to be inherited, and a
blend of one colour with itself is that colour.

Memoized in `cooked--face-cache\=', so a theme change forgets it with every
other colour resolved against the old theme."
  (let* ((plist (and (consp face) (keywordp (car face)) face))
         (screen-fg (cooked--screen-color
                     (if cooked--reverse-screen 'background 'foreground)))
         (screen-bg (cooked--screen-color
                     (if cooked--reverse-screen 'foreground 'background)))
         (fg (or (plist-get plist :foreground) screen-fg))
         (bg (or (plist-get plist :background) screen-bg)))
    ;; Concealed in a default colour, the cell names no colour to hide in and
    ;; inherits one; `cooked--face-build\=' says which.
    (pcase (plist-get plist :inherit)
      ('cooked--concealed (setq fg bg))
      ('cooked--concealed-reversed (setq bg fg)))
    (when (plist-get plist :inverse-video)
      (cl-rotatef fg bg))
    (cooked--cached cooked--face-cache (list 'shade level fg bg)
      (let ((color (cooked--blend fg bg (aref cooked--shade-coverage level))))
        (list :foreground color :background color)))))

(defun cooked--shade-faces (level face)
  "The `face\=' value for shade LEVEL over rendition FACE.
The blend first and the rendition after it, so the blend decides the colours
and everything else FACE says -- an underline, a blink box -- still applies."
  (let ((blend (cooked--shade-face level face)))
    (if face (list blend face) blend)))

(defun cooked--apply-shade (start end bits)
  "Paint the shade BITS names over START..END in the colours already there.

The rendition is read off the text, where `cooked--render-block\=' put it before
any decoration ran, and kept in the `cooked-shade\=' property alongside the
density, so that `cooked--reblend-shades\=' can blend it again when the colours
it was resolved against move.  One `cooked-shade\=' value per segment, so that
walk steps segment by segment."
  (let ((level (logand (ash bits -3) 15))
        (face (get-text-property start 'face)))
    (put-text-property start end 'cooked-shade (cons level face))
    (put-text-property start end 'face (cooked--shade-faces level face))))

(defun cooked--reblend-shades ()
  "Blend every shade in the buffer again, against the colours of the moment.

A shade in the default colours bakes the defaults in when it is drawn, which the
text beside it does not: that text names no colour and follows the buffer\='s
remapped `default\=' live.  So whatever moves the defaults -- a theme change, an
OSC 10 or 11 set or reset, DECSCNM -- calls this, and the shades follow too.

Walks by `cooked-shade\=' alone, so a buffer with none costs one search, and
under `widen\=' for the reason `cooked--rescale-deco\=' gives."
  (when (derived-mode-p 'cooked-mode)
    (save-excursion
      (save-restriction
        (widen)
        (let ((inhibit-read-only t)
              (buffer-undo-list t)
              (inhibit-modification-hooks t)
              (pos (point-min)))
          (while (setq pos (text-property-not-all pos (point-max) 'cooked-shade nil))
            (let ((shade (get-text-property pos 'cooked-shade))
                  (end (or (next-single-property-change pos 'cooked-shade)
                           (point-max))))
              (put-text-property pos end 'face
                                 (cooked--shade-faces (car shade) (cdr shade)))
              (setq pos end))))))))

(add-hook 'cooked-theme-change-hook #'cooked--reblend-shades)

(defun cooked--reset-images ()
  "Forget every image the previous session on this buffer transmitted.

Called from `cooked--start\=', and the one thing about decoration state that a
new session must not inherit.  Image ids come from the core and begin again at
one, so a spec left over from the last child answers for the next child\='s
first picture -- the same id naming different bytes.  The transmitted data goes
with them because nothing can reach it any more once the buffer has been
erased.

The colour and glyph caches deliberately do *not* reset here.  Their keys say
everything about their values -- a bit pattern, a pixel size, a pair of colours
-- so an entry made for the last session is still the right answer for this one,
and each is made on first use by `cooked--cached\=' rather than owned by any
session.  `cooked--deco-cell\=' is cleared because it records what the buffer was
last painted *at*, which a fresh buffer has no claim to."
  (setq cooked--image-data (make-hash-table :test #'eq)
        cooked--image-specs (make-hash-table :test #'equal :weakness 'value)
        cooked--image-bytes 0
        cooked--image-order nil
        cooked--image-order-tail nil
        cooked--deco-cell nil))

(defun cooked--image-order-append (id)
  "Record ID as the newest image this buffer holds, in constant time.

Splices onto `cooked--image-order-tail\=' rather than walking
`cooked--image-order\=' to its end; see that variable for what the walk cost."
  (let ((cell (list id)))
    (if cooked--image-order-tail
        (setcdr cooked--image-order-tail cell)
      (setq cooked--image-order cell))
    (setq cooked--image-order-tail cell)))

(defun cooked--image-order-set (order)
  "Replace `cooked--image-order\=' with ORDER, keeping the tail pointer true.

For the two callers that rebuild the queue rather than extend it -- a forget
taking an id out of the middle, and an eviction pass putting back what it
declined to spend.  Neither can leave the tail where it was: the cons it names
may be the one that just went."
  (setq cooked--image-order order
        cooked--image-order-tail (last order)))

(defun cooked--install-images (images)
  "Record IMAGES, a drain's `:images\=', before anything referring to them renders.

Each entry is (ID FORMAT DATA PX-WIDTH PX-HEIGHT).  The module sends one exactly
once per distinct picture however often the child transmits or places it, so
this is where the only copy of the bytes lands -- and why the table holding them
is not weak.

No cell rectangle among those fields, deliberately: the bytes cross once and the
same picture can be laid at any number of sizes afterwards, so a rectangle
recorded here would be the first placement\='s and would go stale the moment the
child redrew at another size.  It rides each placement instead, and reaches this
file through `cooked--apply-image-deco\='.

Called ahead of both render passes, not from the event loop: an image is a
resource the rows of this very drain refer to by id, so it has to be here before
they are rendered.  Events are dispatched after rendering, so an image arriving
as one would arrive too late for the row that needed it."
  (dolist (image images)
    (pcase-let ((`(,id ,format ,data ,px-w ,px-h) image))
      (unless (gethash id cooked--image-data)
        (cooked--image-order-append id)
        (cl-incf cooked--image-bytes (length data)))
      (puthash id (list format data px-w px-h) cooked--image-data)))
  ;; Exempt from the cap the very ids just installed: nothing displays them yet,
  ;; because the rows that will are rendered after this returns.
  (cooked--evict-images (mapcar #'car images)))

(defcustom cooked-image-cache-size (* 64 1024 1024)
  "Bytes of transmitted image data one buffer retains, or nil for no limit.

`cooked--image-data\=' is strong and buffer-local, so it dies with the buffer
and a session that shows a few pictures never approaches this.  What it is for
is the session that shows thousands: ids are content-addressed, so a child
redrawing one picture costs nothing however long it runs, but a child drawing a
*different* picture each time -- a plotting TUI, an image browser paging
through a directory, a long `icat\=' loop -- adds one entry per frame and
nothing ever took them away.

There is no figure to match on the module side any more, and that is the point.
It kept the payloads too, under a cap of its own three orders of magnitude
larger than what this one comes to for multi-megabyte frames, and an animation
drew nothing for half of every loop because the two disagreed.  It now keeps a
digest per picture and is told, through `cooked--forget-image\=', whenever this
table drops one.

This is a backstop and not the eviction policy.  An image\='s lifetime follows
the buffer text that displays it: it goes when the last row referencing it is
deleted, which is `cooked--release-images\=' driven from the scrollback discard
functions, the same way and in the same place `cooked--commands\=' is pruned.
That is the model the module states for its own half in src/emu/image.rs -- the
lifetime is Emacs\=' -- and under it a session\='s images cost exactly what its
transcript costs, with no sweep on any drain.

What this cap is for is the case the model does not bound on its own: a child
drawing a *different* picture every frame into a transcript nobody is trimming.
When the bytes go over, `cooked--evict-images\=' spends the oldest -- but only
ids nothing is displaying.  A displayed id is never evicted, so the cap is a
soft one, and deliberately: evicting under a picture that is on screen is what
made half a picture render at one size and the other half not at all, and no
bound is worth a corrupt buffer.  Set it to nil to switch the backstop off
entirely.

So what eviction costs is a retransmission rather than a hole: the next time the
child sends those bytes they arrive as a picture the module has never seen.  A
child that never sends them again was showing something nothing displays, which
is what made the id evictable in the first place."
  :type '(choice (const :tag "No limit" nil) integer)
  :group 'cooked)

(defvar cooked--displayed-images nil
  "Ids known to be displayed, as a set, or nil to read the spec table per id.

Bound by `cooked--evict-images\=' for the length of one pass, because that pass
asks the question once per candidate and the honest answer is a walk of every
spec in the buffer.  One walk answers all of them: the specs do not change while
the pass runs, since nothing in it renders anything.

Left nil everywhere else, so `cooked--image-displayed-p\=' remains a function of
the buffer rather than of whatever a caller last computed.  There is exactly one
pass that can afford to precompute, and it is the one that binds this.

A dynamic binding rather than an argument, for the reason
`cooked--seam-running\=' gives for the same shape: the predicate is stubbed by
name in the tests that pin the eviction rule, and widening its signature would
break them for no gain the callers can see.")

(defun cooked--displayed-image-table ()
  "The set of image ids some live spec still displays.

One walk of `cooked--image-specs\=' answering for every id at once, for
`cooked--displayed-images\=' to be bound to."
  (let ((displayed (make-hash-table :test #'eq)))
    (maphash (lambda (key _spec) (puthash (car key) t displayed))
             cooked--image-specs)
    displayed))

(defun cooked--evict-images (&optional arriving)
  "Spend oldest undisplayed images until `cooked--image-data\=' fits the cap.

ARRIVING is the ids this drain has just installed, which are exempt.  They have
to be: the rows that display them have not been rendered yet -- resources are
installed before both render passes -- so every one of them reads as undisplayed
and is the *most* evictable thing in the table.  Ordinarily the loop stops long
before reaching them, but it only stops when the bytes come down, and an id it
declines to spend does not bring them down.  A run of those walks it straight to
the far end and spends the picture the caller is about to draw, and
`cooked--image-spec\=' answers nil for an id with no data: the cells get a
`cooked-deco\=' and no `display\='.  Blank rectangle, right size, right place,
cursor exactly where it should be, and the animation recovers only when the
collector next runs.  Nothing above is hypothetical -- it is what a 2MB-a-frame
gif does to a 64MB cap.

The backstop `cooked-image-cache-size\=' documents, and the whole of it.  One
pass, and it will not touch an id anything is displaying: `cooked--image-specs\='
is weak on its values and the buffer text holding a spec in a `display\='
property is the strong reference, so a live spec means live text and its absence
means nothing is showing that picture.  The test errs the safe way -- a spec the
collector has not got to yet reads as displayed -- which under-evicts and never
blanks anything.

There is deliberately no second pass taking the oldest regardless, because it
would evict ids still on screen.  `cooked--image-spec\=' answers nil for an id
with no data, so the next resize -- which damages every row of the grid, and
only the grid -- would rebuild the on-grid half of a picture as nothing while
its scrollback half went on drawing.  A guaranteed byte limit is not worth
that, and ordinary eviction is `cooked--release-images\=' anyway."
  (when (and cooked-image-cache-size
             (> cooked--image-bytes cooked-image-cache-size))
    ;; Asked once for the whole pass rather than once per candidate.  Nothing
    ;; here renders, so no spec can come or go while it runs and the one answer
    ;; stays true throughout; see `cooked--displayed-images'.
    (let ((cooked--displayed-images (cooked--displayed-image-table))
          (order cooked--image-order)
          (kept nil))
      ;; Detached for the length of the pass, which owns it and puts it back
      ;; below.  `cooked--forget-image' takes its id out of the queue, and with
      ;; the queue still installed that would search the rest of the list for
      ;; something this loop has already popped, N^2 walks for N pictures.
      (setq cooked--image-order nil
            cooked--image-order-tail nil)
      (while (and order (> cooked--image-bytes cooked-image-cache-size))
        (let ((id (pop order)))
          (if (or (memq id arriving) (cooked--image-displayed-p id))
              (push id kept)
            (cooked--forget-image id))))
      ;; Whatever this declined to spend goes back on the front, still oldest
      ;; first, so the next call sees the same queue rather than a reversed one.
      (cooked--image-order-set (nconc (nreverse kept) order)))))

(defun cooked--image-displayed-p (id)
  "Whether any spec for image ID is still alive, and so still being shown."
  (if cooked--displayed-images
      (and (gethash id cooked--displayed-images) t)
    (catch 'found
      (maphash (lambda (key _spec)
                 (when (eq (car key) id) (throw 'found t)))
               cooked--image-specs)
      nil)))

(defun cooked--forget-image (id)
  "Drop image ID\='s transmitted bytes, and the bookkeeping that names them.

The spec table is not touched: `cooked--image-specs\=' is weak on its values, so
an entry for a picture nothing displays is collected on its own, and one for a
picture something *does* display must outlive this -- forgetting the bytes does
not take a picture off the screen, it only takes away the ability to rebuild it
at a different cell size.  What is dropped is the layer below that, Emacs\' own
raster of each spec, which nothing here holds a reference to and which would
otherwise sit in the display engine for `image-cache-eviction-delay\=' after we
had stopped counting it; see `cooked--flush-image-specs\='.

The module is told, and that is the half without which the rest is a bug.  It
has no cache of its own any more, only a note of which ids it has already sent;
a picture it still believes we have is one it will answer a retransmission of
with the id alone.  So an id in `cooked--image-data\=' iff the module thinks we
have it is the invariant, and this is the only place either end drops one.
Without it a child redrawing a picture we had evicted -- an animation looping,
which is the case that found this -- got placements with nothing behind them:
correct cells, correct cursor, no picture, until it happened to draw something
we had not evicted yet.

Every drop goes through here, which is why the call is here rather than in the
two callers.  Nothing is owed once the child is gone: no further transmission
can arrive, so a dead session is left alone."
  (when-let* ((entry (gethash id cooked--image-data)))
    (cl-decf cooked--image-bytes (length (nth 1 entry)))
    (remhash id cooked--image-data)
    (cooked--image-order-set (delq id cooked--image-order))
    (cooked--flush-image-specs id)
    (when-let* ((session (cooked--live-session)))
      (cooked--image-forget session id))))

(defun cooked--flush-image-specs (id)
  "Drop Emacs\=' rasterizations of image ID from the display engine's cache.

The half of forgetting a picture that `cooked--forget-image\=' cannot do by
letting go: the bytes it drops are the *encoded* ones, and Emacs keeps a
separate cache of what it decoded them into -- one bitmap per spec, which is to
say per cell rectangle the picture was ever laid at.  Nothing here holds a
reference to those.  They are keyed by the spec inside the display engine, and
they are evicted on a timer of their own, `image-cache-eviction-delay\=', which
is five minutes after the last redisplay that used one.

Five minutes is a long time at the scale this file is written for.  The case
src/emu/image.rs is written around -- `viu\=' on a 34-frame gif, three-megabyte
RGBA frames, looping -- retires a frame every few tens of milliseconds, and
without this the raster of every one of them stays resident for the whole delay.
The ledger says the memory is gone, `cooked--image-bytes\=' says the memory is
gone, and thousands of decoded bitmaps say otherwise.  It is the same shape of
disagreement DESIGN.md\='s \"Images have one owner\" section describes between the
module and Emacs, one layer further down: two caches counting different things,
with nothing connecting them.

Only ever from `cooked--forget-image\=', and that matters.  A flush of a spec
something still displays is not incorrect -- the spec carries its own copy of
the encoded bytes, so the next redisplay decodes them again -- but it is a
re-rasterization bought for nothing, so the flush belongs exactly where the
decision to forget has already been made and nowhere else.

`cooked--image-specs\=' is weak on its values, so an entry may have been
collected between the last placement and this call; `maphash\=' simply does not
see it, and that is the right answer -- a spec Emacs has let go of is a spec
nothing can be holding a raster for either.  The table is keyed by placement
rectangle as well as by id, so one picture on screen at two sizes has two specs
and both go.  Frame `t\=' rather than the selected one because the buffer may be
displayed on several, and a raster is cached per frame."
  (when cooked--image-specs
    (maphash (lambda (key spec)
               (when (eq (car key) id)
                 (image-flush spec t)))
             cooked--image-specs)))

(defun cooked--image-ids-between (beg end)
  "Image ids the `cooked-deco\=' properties between BEG and END refer to.

Walks property changes rather than characters, so a picture costs one step per
run and text with no decoration in it costs one step altogether."
  (let ((ids nil)
        (pos beg))
    (while (< pos end)
      (let ((deco (get-text-property pos 'cooked-deco)))
        (when (eq (car-safe deco) 'image)
          (cl-pushnew (nth 1 deco) ids :test #'eq)))
      (setq pos (or (next-single-property-change pos 'cooked-deco nil end) end)))
    ids))

(defun cooked--release-images (beg end)
  "The image ids between BEG and END, to hand to `cooked--collect-images\='.

Call this *before* deleting the region and the other one after, because the
question is not \"what was in the text that went\" but \"was that the last of
it\": a picture in the scrollback is very often the same id as the one still on
the grid, ids being content-addressed in the module."
  (and cooked--image-data (cooked--image-ids-between beg end)))

(defun cooked--collect-images (ids)
  "Forget any of IDS no longer referred to by any text in the buffer.

The eviction policy, and it is the same shape as the `cooked--commands\=' prune
that sits beside it in `cooked--discard-scrollback\=': an image is a resource
belonging to the rows that display it, so it dies exactly when the last of those
rows does.  Nothing here is a heuristic about age or budget -- src/emu/image.rs
says the lifetime is Emacs\=', and this is Emacs holding up that end.
`cooked--forget-image\=' tells the module about each one, which is the other half
of holding it up: the module must not go on believing we have a picture we have
just decided nothing refers to.

Costs a widened walk of the buffer\='s decoration runs, and only when the text
just deleted actually had a picture in it, which a scrollback trim of ordinary
output does not."
  (when ids
    (save-restriction
      (widen)
      (let ((live (cooked--image-ids-between (point-min) (point-max))))
        (dolist (id ids)
          (unless (memq id live)
            (cooked--forget-image id)))))))

(defun cooked--image-spec (id cells size)
  "The `create-image\=' spec for image ID laid at CELLS, one cell being SIZE.

Shared deliberately: every cell of the picture displays a slice of one spec, so
Emacs decodes the image once rather than once per cell.  Nil when ID names
nothing this buffer has been told about, which is what a placement left over
from a session whose data has gone looks like.

Nil too when this Emacs cannot decode the format, which is asked here rather
than at the call site because the answer differs from image to image: a build
without libjpeg still shows PNGs.

CELLS is `(COLS . ROWS)\=', the rectangle *this placement* was laid at, which
comes from the placement rather than from the image: one picture can be on
screen at two sizes at once, and sizing it from anything the image itself held
would draw one of them wrong.  See `cooked--apply-image-deco\='.  So the
rectangle is part of the memoization key too -- a reshape does not move the
cell, so keying on SIZE alone would answer a resized placement with the spec
built for the old one.

Shared across every cell of one placement, deliberately: they all display a
slice of one spec, so Emacs decodes the picture once rather than once per cell.
`:scale 1\=' for the same reason it is on a box glyph:
`image-scaling-factor\=' is `auto\=' and would resample what has already been
scaled to fit."
  (when-let* ((entry (gethash id cooked--image-data))
              ((image-type-available-p (car entry))))
    ;; Not `cooked--cached': this table is weak on its values by design -- see
    ;; `cooked--image-specs' -- and is cleared per session, so it is made by
    ;; `cooked--reset-images' rather than on first use.
    (with-memoization
        (gethash (list id (car cells) (cdr cells) (car size) (cdr size))
                 cooked--image-specs)
      (pcase-let ((`(,format ,data . ,_) entry))
        (create-image data format t
                      :width (* (car cells) (car size))
                      :height (* (cdr cells) (cdr size))
                      :scale 1
                      :ascent (cooked--box-glyph-ascent
                               (cooked--deco-window) (cdr size)))))))

(defun cooked--deco-image (deco size window &optional count)
  "The image DECO displays at cell SIZE, or nil if there is none to be had.

Half of `cooked--deco-display-value\=', split at the seam the render path cares
about: this is the part a whole run shares, and `cooked--deco-display\=' is the
wrapper that names how much of the buffer it stands for.  A box glyph\='s bitmap
is a function of the shape and the cell size alone, so a whole
border row wants one image; a picture\='s spec is shared by every cell of the
placement already, each cutting its own slice out of it.

COUNT is how many adjacent cells the answer has to cover, default the whole of
what DECO describes.  A glyph run is displayed as a single image as wide as its
pattern rather than as one image per cell or even one per shape, which is where
nearly all of the box-drawing redisplay cost went -- see
`cooked--apply-glyph-deco\='.  So on the glyph side COUNT is not a width to
build at, the pattern already being one: it *trims* the pattern, and only a
caller reading a run\='s width off the buffer rather than off the wire can hand
over one that trims anything.  `cooked--rescale-deco\=' is that caller and
`cooked--glyph-pattern-take\=' is the trim.

It is unread on the image side, and that is not because a picture is drawn per
cell: it is because the spec *is* the whole placement however much of it a span
covers, so a wider span cuts a wider slice out of the same spec rather than
wanting a different one.  `cooked--deco-display\=' is where an image run spends
its width.

Hoistable out of a per-character loop exactly where the `cooked-deco\=' record
itself is shareable, which is not a coincidence: both are shareable because
nothing in the answer depends on the column.

Both branches memoize underneath, and the hoist still pays: the memo key is a
freshly consed list and the lookup a hash of it, so eighty identical glyphs cost
eighty conses and eighty hashes to be told what they were told the first time.

WINDOW is only ever the ascent lookup\='s.  SIZE must be non-nil; a caller with
no cell size to draw against stops before here -- see `cooked--apply-deco\='."
  (pcase deco
    (`(image ,id ,_crow ,_ccol ,cols ,rows)
     (cooked--image-spec id (cons cols rows) size))
    (`(glyph ,pattern . ,_)
     (let ((pattern (if count (cooked--glyph-pattern-take pattern count) pattern)))
       (unless (cooked--glyph-pattern-blank-p pattern)
         (cooked--box-glyph-image pattern window size))))))

(defun cooked--deco-display (deco image size &optional count)
  "Wrap IMAGE as a `display\=' value standing for the text it is put on.

The other half of `cooked--deco-display-value\='.  Emacs merges a span of
characters whose `display\=' properties are `eq\=' into a *single* displayed
image, which is what makes (propertize \"xx\" \='display IMG) show one image
rather than two.  That is a hazard and an opportunity, and which one it is
depends entirely on how wide IMAGE is:

- A cell-wide image shared across adjacent cells collapses a border to one
  glyph, and the row loses the width of everything the merge swallowed.  Never
  do that; `cooked-adjacent-box-glyphs-share-only-a-run-wide-image\=' pins it.
- A *run-wide* image put over exactly the cells it was built for is the same
  merge used deliberately: one image, one interval, and the run occupies
  precisely the pixels it did before.  That is what
  `cooked--apply-glyph-deco\=' and `cooked--apply-image-deco\=' both do with a
  coalesced run.

So the wrapper is consed once per span rather than once per character, and the
span it is put over is the span its IMAGE was sized to.  Getting the two out of
step is the one way to be wrong here, and it is wrong in the direction of a
visibly short or long row rather than of anything subtle.

COUNT is how many adjacent cells the value is going to be put over, default one,
and it is the same COUNT `cooked--deco-image\=' took.  The two halves each need
the run\='s width and need it for opposite reasons, which is why it is asked of
both rather than of one: a glyph run has the width in its *pattern*, which COUNT
can only cut short, while a picture\='s spec is already the whole placement and
the width goes into the *slice* cut out of it.  So the glyph arm here ignores
COUNT and the image arm ignores it there, and neither can be sized correctly
without the other having been asked.

An image cell adds its own `slice\=' to the wrapper, which is why this takes
DECO and not just IMAGE: the slice names where in the picture the span begins.
DECO carries the *first* cell of the span -- its row and column within the
picture -- and COUNT says how far along that row the span runs, so the
rectangle cut is COUNT cells wide and one cell tall.  A COUNT of one is the
degenerate case and the shape the fallback path takes; see
`cooked--apply-image-deco\=' for when the grid forces it.  SIZE is what
converts those cell coordinates to pixels, and is unread on the glyph side.

Dispatches on the head with `eq\=' rather than by destructuring the record,
because a picture laid across cells that cannot share a span still pays this
once per cell: the glyph arm reads nothing out of DECO, and should not pay
a `pcase\=' to find that out."
  (if (eq (car deco) 'image)
      (pcase-let ((`(,_ ,_id ,crow ,ccol . ,_) deco))
        (list (list 'slice (* ccol (car size)) (* crow (cdr size))
                    (* (or count 1) (car size)) (cdr size))
              image))
    (list image)))

(defun cooked--deco-display-value (deco size window &optional count)
  "The `display\=' value DECO should carry at cell SIZE, or nil for none.

DECO is the `cooked-deco\=' property: `(image ID CROW CCOL COLS ROWS)\=' or
`(glyph PATTERN COLUMN ROW)\=', PATTERN being a whole run\='s (BITS COUNT) records
-- see `cooked--glyph-pattern-records\='.  WINDOW is only ever the ascent
lookup\='s.  Nil SIZE means there is no cell size to draw against yet, and the
caller records the decoration without displaying anything.

COUNT is how many adjacent cells the answer is going to be put over, default
one, and it is handed to *both* halves -- so the value handed back is sized to
exactly the span the caller means to cover, whichever kind it is.  Getting it
out of step with that span is the one way to be wrong here; see
`cooked--deco-display\=' for the two ways the width is spent.

COLS and ROWS are the rectangle the placement was laid at, carried on the
decoration itself so that this and `cooked--rescale-deco\=' size a picture the
same way however long ago its row was written.

The single answer to \"what does this decoration look like\", and every path
that can ask it goes through here or through the two halves it is composed of.
One derivation is one place to add a new decoration kind; separate ones would
leave the rescale path silently painting the old size.

The composition is what the halves are for rather than a second answer beside
them.  `cooked--rescale-deco\=' calls this, having only a record and no idea
which of its neighbours agree with it; the two render paths call
`cooked--deco-image\=' and `cooked--deco-display\=' once for as much of a run as
can share them, because the wire tells them what agrees and this does not know.
Neither derives anything the other does not: a kind added to one of the halves
reaches all three callers, which is the property that mattered."
  (when size
    (if (eq (car deco) 'shade)
        ;; A stretch as wide as the cells, painted in the face's background --
        ;; which `cooked--apply-shade' has made the blend -- so no font is asked
        ;; to draw the character at all, and none can stretch the line.
        (list 'space :width
              (list (* (or count (cooked--glyph-pattern-cells (nth 1 deco)))
                       (car size))))
      (when-let* ((image (cooked--deco-image deco size window count)))
        (cooked--deco-display deco image size count)))))

(defun cooked--apply-image-deco (start packed size)
  "Apply image decoration PACKED from START: twelve bytes per character.

SIZE is the pixel size of one cell, or nil to record the placements and display
nothing -- see `cooked--apply-deco\='.

A `u32\=' image id, then the cell\='s row and column within that image, then the
cell rectangle that placement was laid at, as four `u16\='s, all little-endian.

*Per cell on the wire, per run in the buffer*, and that split is the whole
design.  Cells are what the emulator knows: the grid addresses a picture one
cell at a time, which is what makes the picture survive everything the grid does
to it -- text written over one cell replaces that cell and leaves the rest, a
scroll carries each row\='s cells into the scrollback independently, and a rewrap
moves them with their columns.  Runs are what Emacs\=' redisplay wants: a
`display\=' property per character costs `find_interval\=' and
`parse_image_spec\=' once per column, and on a full-screen picture that is
nineteen hundred of each per frame with the pixels themselves rounding to
nothing beside it.

So this walks the per-cell records and coalesces a maximal run of cells that are
the same picture (ID), at the same rectangle (COLS x ROWS), on the same row of
it (CROW), in consecutive columns of it (CCOL rising by one) -- which is the
common case and very nearly the only one, a freshly drawn picture being exactly
that on every row.  The run gets one `cooked-deco\=' record and one `display\='
value, the latter slicing the shared spec at the run\='s own start column and
COUNT cells wide, so Emacs merges the run into a single displayed image
occupying precisely the pixels its characters did.  See `cooked--deco-display\='
for why that merge is asked for here rather than avoided.

*The fallback to per-cell is not a fallback path but the same path with a run
of one*, and it is reached wherever any of those four things breaks between
adjacent records:

- A cell of the picture overwritten by text is simply not in the wire\='s records
  at all, and the cells either side of it are two runs whose CCOLs skip.
- Two placements of the same id adjacent on one row have their own CCOL
  sequences, each restarting.
- A wide character standing on two columns is one character of `Run::text\=' and
  so one record, with the next record\='s CCOL two higher: the run breaks and
  both halves are drawn at their own start column, which is what the per-cell
  code did and remains right.
- Two rows of one picture are never one run, CROW differing, and would not be
  contiguous in the buffer anyway.

Coalescing here rather than on the wire, though `Deco::packed\=' could send a
run-length record and REPORT.org §2 expected it to: the detection is four
integer comparisons against values this loop has already decoded, against a
`put-text-property\=' and a freshly consed record per cell saved.  The expensive
half is entirely on this side, and it is on this side that the saving lands
whichever end does the counting.  A wire change would buy the decode loop and
nothing else, at the cost of a format both ends have to keep meaning the same
thing -- see `Deco::packed\=' in src/emu/cell.rs, which now says so.

The record is shared across the run for the same reason the glyph path shares
one, and with the same care: what a shared record must not do is outlive the run
it describes.  CCOL is the *run\='s* start column, so a fragment of a run would
claim a start column that is not its own -- but nothing splits a decorated run
in the buffer after it is written.  A damaged row is deleted whole and
re-rendered from the wire (`cooked--render-rows\='), which re-derives the runs
against the grid as it now is; the scrollback is only ever cut at a line
beginning (`cooked--discard-scrollback\='); and `cooked--guard-row-width\=' trims
from a row\='s *end*, which shortens the last run rather than splitting one.
`cooked--rescale-deco\=' takes the width from the run it finds in the buffer for
exactly this reason and so stays right even if that ever stops being true.

What is hoisted across runs is the spec, which genuinely is one thing per
placement: consecutive runs almost always name the same picture at the same
rectangle, and `cooked--image-spec\=' conses a five-element key and hashes it on
every ask.  The previous run\='s answer is kept and reused while the triple that
identifies it holds.

The rectangle rides every cell rather than being looked up from the image,
because it belongs to the placement and not to the picture.  Ids are
content-addressed, so a child that retransmits a frame at a new `c=\='/`r=\='
after a window reshape -- which is what `viu\=' does, never rescaling the pixels
itself -- names the id it named before.  Held against the image there was one
field for two answers, and whichever transmission wrote it last decided how the
other one\='s slices were cut."
  (let ((pos start)
        (records (/ (length packed) 12))
        (key nil)
        (image nil)
        (i 0))
    (while (< i records)
      (let* ((base (* 12 i))
             (id (cooked--u32 packed base))
             (crow (cooked--u16 packed (+ base 4)))
             (ccol (cooked--u16 packed (+ base 6)))
             (cols (cooked--u16 packed (+ base 8)))
             (rows (cooked--u16 packed (+ base 10)))
             (deco (list 'image id crow ccol cols rows))
             ;; How many cells this run has grown to, the first one included.
             ;; Looked ahead for rather than accumulated behind, so the run's
             ;; extent is known before either property is put and each goes on
             ;; in one call -- which is the saving, `put-text-property' being
             ;; what this function actually spends its time in.
             (run 1)
             (next (+ base 12)))
        (while (and (< (+ i run) records)
                    ;; The four things a cell must agree with its neighbour
                    ;; about to be drawn with it.  Compared in the order they
                    ;; are cheapest to disagree on: a run ends at a different
                    ;; column of the same picture far more often than it ends
                    ;; at a different picture.
                    (eq (+ ccol run) (cooked--u16 packed (+ next 6)))
                    (eq crow (cooked--u16 packed (+ next 4)))
                    (eq id (cooked--u32 packed next))
                    (eq cols (cooked--u16 packed (+ next 8)))
                    (eq rows (cooked--u16 packed (+ next 10))))
          (setq run (1+ run)
                next (+ next 12)))
        (let ((end (+ pos run)))
          (put-text-property pos end 'cooked-deco deco)
          (when size
            ;; The picture, not the cell: `cooked--deco-image' reads nothing but
            ;; the id and the rectangle, so the answer stands until one of them
            ;; moves.  Nil is cached too -- a format this Emacs cannot decode is
            ;; still nil for the next run of the same placement.
            (unless (and key
                         (eq id (car key))
                         (eq cols (nth 1 key))
                         (eq rows (nth 2 key)))
              (setq key (list id cols rows)
                    image (cooked--deco-image deco size nil)))
            (when image
              (put-text-property pos end 'display
                                 (cooked--deco-display deco image size run))))
          (setq pos end
                i (+ i run)))))))

(defun cooked--glyph-run-segments (packed column cursor)
  "PACKED cut into the parts that are each drawn as one thing, left to right.

PACKED is a whole decoration run\='s (BITS COUNT) records; COLUMN is how many
characters into its row the run\='s first cell is, or nil off the screen;
CURSOR is the same count for the child\='s cursor when it is on this row, or
nil.  Both are characters rather than grid columns, so that a wide character
earlier on the row moves them together.  The answer is a list of
\(KIND . PATTERN), KIND being `glyph\=' or `shade\=' and PATTERN in the form
`cooked--glyph-pattern-records\=' reads, whose cells add up to PACKED\='s.

Two things break a run here, and the other two never reach this function: a
style, underline or link change split the run on the *wire*, in
`Row::build_runs\=' (src/emu/cell.rs), and so arrived as separate PACKED
strings.

*A shade is a segment of its own.*  ░▒▓ are not drawn as a bitmap at all but
as a background blended from the run\='s two colours -- see
`cooked--apply-shade\=' -- so they cannot share an image with the shapes beside
them.  Each shade record is one segment, however many cells it covers: a record
is already one density, and a run of ▒ is one stretch of one colour.

*The cursor\='s cell is a segment of its own.*  Emacs draws a block cursor on a
`display\=' span as wide as the whole span, and at its start, and cooked puts
point wherever the child\='s cursor is on every drain.  So a span bridging the
cursor\='s cell draws the cursor as a box around the span: in an empty bordered
input field the cursor outlines the field.  Cutting before the cell only moved
that box\='s left edge to the right place.  The cut is on both sides, so the
cursor\='s segment is exactly one cell and the cursor exactly as wide:
`│ │ ├──\=' with the cursor on the second blank is `│ │\=', the blank, and
`├──\='.  This was invisible for as long as a run was identical box glyphs -- a
cursor does not sit in a border -- and became visible the moment runs learned to
bridge the blanks of an indent, which is exactly where a cursor does sit.
`cooked-the-cursors-cell-is-a-glyph-segment-of-its-own\=' is the pin.

The core decides by the same rule whether a cursor move changes how a row is
drawn, and resends the run when it does; see `Front::cursor_run\=' in
src/emu/term/front.rs.

Returns `((glyph . PACKED))\=' unsplit whenever neither applies, which is nearly
every run -- so the common case allocates two conses and shares the string the
drain already handed over, rather than rebuilding it."
  (let ((limit (length packed)))
    (if (and (not (cooked--glyph-run-shades-p packed))
             (or (null cursor) (null column)
                 (< cursor column)
                 (>= cursor (+ column (cooked--glyph-pattern-cells packed)))))
        (list (cons 'glyph packed))
      (let ((out nil)
            (pending nil)
            (pending-kind nil)
            (col (or column 0))
            (i 0))
        (cl-flet ((flush ()
                    (when pending
                      (push (cons pending-kind (apply #'concat (nreverse pending)))
                            out)
                      (setq pending nil))))
          (while (< i limit)
            (let* ((bits (cooked--u16 packed i))
                   (kind (if (cooked--box-shade-p bits) 'shade 'glyph))
                   (left (cooked--u16 packed (+ i 2))))
              ;; A shade record always starts afresh, and so does anything after
              ;; one: the two kinds never share a segment.
              (when (or (eq kind 'shade) (not (eq kind pending-kind)))
                (flush))
              (setq pending-kind kind)
              (while (> left 0)
                (when (and pending cursor
                           (or (eql col cursor) (eql col (1+ cursor))))
                  (flush))
                ;; Up to the next cut inside this record, the cursor's cell or the
                ;; one after it, and the loop retakes the test above there.
                (let* ((cut (cond ((and cursor (< col cursor (+ col left))) cursor)
                                  ((and cursor (< col (1+ cursor) (+ col left)))
                                   (1+ cursor))))
                       (take (if cut (- cut col) left)))
                  (push (cooked--glyph-pattern bits take) pending)
                  (setq col (+ col take)
                        left (- left take)))))
            (setq i (+ i 4)))
          (flush))
        (nreverse out)))))

(defun cooked--glyph-run-shades-p (packed)
  "Whether any record of PACKED names a shade, which is drawn as a background.

Separate from the walk in `cooked--glyph-run-segments\=' so that the answer can
be had without building anything: a run with no shade in it is handed straight
back as one segment, and that is every run a border, a box or a `tree\=' indent
is made of."
  (let ((i 0)
        (limit (length packed))
        (found nil))
    (while (and (not found) (< i limit))
      (setq found (cooked--box-shade-p (cooked--u16 packed i))
            i (+ i 4)))
    found))

(defun cooked--apply-glyph-deco (start packed window size origin row)
  "Apply box-glyph decoration PACKED at START: four bytes per run of one shape.

PACKED is `(BITS COUNT)\=' pairs of little-endian `u16\='s -- a `BoxGlyph\=' bit
pattern and how many consecutive characters draw it, so a border row arrives as
one record rather than eighty.  See `Deco::packed\=' in src/emu/cell.rs for why
the core counts them rather than leaving this to work it out again: it already
knew, and Emacs is the half with no time to spare.

ORIGIN and ROW locate the shapes, as in `cooked--apply-deco\='.  SIZE nil
records them and displays nothing; WINDOW is only ever the ascent lookup\='s,
and is nil in the same case.

*One image for the whole run, not one per record.*  The records of a run are
its pattern, and the bitmap is rasterized once across all of them -- `├──\=' is
two records and one image three cells wide -- so both properties go over the
entire run with one `put-text-property\=' each.  Emacs then merges the run into
a single displayed image, which is the intended reading rather than the hazard
it would be for a cell-wide bitmap: the image is exactly as wide as the span it
is put over, so the run occupies precisely the pixels its characters did.  See
`cooked--deco-display\=' for the two sides of that merge, and
`cooked-adjacent-box-glyphs-share-only-a-run-wide-image\=' for the pin.

That is where nearly all of the box-drawing redisplay cost went.  A 24x80 frame
of border drops from 1920 `display\=' intervals to 24, and Emacs\=' redisplay
pays `find_interval\=' and `parse_image_spec\=' once per interval rather than
once per column -- the same shape ghostel gets from a per-row image slice, and
the reason its scroll ceiling sits where cooked\='s did not.

The pattern is what reaches `tree\=', which the shape alone could not.  A run
breaks on any undecorated cell and a space classifies to nothing, so `│   │
├── \=' was three decorated runs -- 86,107 records for 30,326 rows, 2.84 per
row where a row wants one.  `Row::absorb_blank_runs\=' now hands the gaps over
as blank shapes inside one run, and this bakes the indent as one image;
`cooked-a-tree-indent-costs-one-display-interval\=' states it as the ratio it
is.

Sharing the record is safe because nothing in it is cell-specific: a box
glyph\='s bitmap is a function of its shapes and the cell size alone.
`cooked--rescale-deco\=' is written to that sharing rather than to the per-cell
allocation that preceded it, and
`cooked-a-rescale-rebuilds-every-cell-of-a-shared-glyph-run\=' pins it.

What does *not* share is decided by `cooked--glyph-run-segments\=', which is
where the shade rule and the cursor rule live and where both are argued.  A
shade segment is painted rather than pictured -- see `cooked--apply-shade\=' --
and carries a stretch of space as its `display\=' instead of an image."
  (let ((pos start)
        (cursor (and origin (integerp row)
                     (eq row (car cooked--deco-cursor))
                     (cdr cooked--deco-cursor))))
    (pcase-dolist (`(,kind . ,pattern)
                   (cooked--glyph-run-segments
                    packed (and origin (- start origin)) cursor))
      (let* ((cells (cooked--glyph-pattern-cells pattern))
             (end (+ pos cells))
             (deco (list kind pattern (and origin (- pos origin)) row)))
        (put-text-property pos end 'cooked-deco deco)
        (when (eq kind 'shade)
          (cooked--apply-shade pos end (cooked--glyph-pattern-head pattern)))
        (when-let* ((display (cooked--deco-display-value deco size window cells)))
          (put-text-property pos end 'display display))
        (setq pos end)))))

(defun cooked--rescale-deco ()
  "Rebuild every decoration in the buffer at the current cell size.
Reuses the `cooked-deco' property `cooked--apply-deco' stashed, so this never
needs the native core — the classified shape and its colors already survive in
the buffer.

This is the only thing that rewrites a decoration already in the scrollback, and
that makes it the whole repair mechanism rather than a zoom convenience.  A
picture is displayed as one `slice' per cell, so both the slice geometry and the
spec they cut from are functions of the cell size; rows written at one size and
rows written at another stay mismatched forever unless something walks the
buffer.  Hence the callers: `cooked--sync-size', which is the one place that
notices the cell actually moving, and `cooked--rescale-deco-on-zoom' for the
zoom that moves it without a window event.  Called only when the size really
changed, because this is a whole-buffer walk under `widen' and a long transcript
is not free.

Does nothing at all when there is no cell size to be had — see
`cooked--deco-cell-size'.  Stripping the decorations back to plain characters
would be the other option and is wrong: the records stay, the text goes on
showing what the child sent, and the next window brings both back.

Widens first: `cooked--apply-alt-pin' confines the buffer to the screen region
while a full-screen program is up, and a zoom during that would otherwise
rescale only the alt frame — leaving every glyph in the scrollback above it
stuck at the previous font size, visibly mismatched once the pin is released."
  (when-let* (((derived-mode-p 'cooked-mode))
              (size (cooked--deco-cell-size))
              ((not (equal size cooked--deco-cell))))
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (let* ((window (cooked--layout-window))
               ;; The pair `cooked--with-child-edit' binds, spelled out to keep
               ;; this in one `let*' with the sizes it needs.
               (inhibit-read-only t)
               (buffer-undo-list t)
               ;; And a third, for the same reason the other two are here: this
               ;; walk is not an edit.  It re-cuts the `display' slices of text
               ;; that has not changed and will not, so there is nothing for a
               ;; change hook to react to -- while `put-text-property' runs them
               ;; regardless, once per decorated run over the whole transcript.
               ;; With jit-lock registered that is `jit-lock-after-change'
               ;; marking settled scrollback unfontified so it can be rescanned
               ;; for links it already has, at +28% on the walk.
               (inhibit-modification-hooks t))
          (while (< (point) (point-max))
            (let ((deco (get-text-property (point) 'cooked-deco))
                  (next (or (next-single-property-change (point) 'cooked-deco)
                            (point-max))))
              ;; Every character of the run, not just the one the walk landed on.
              ;; `next-single-property-change' compares values with `eq', so a run
              ;; of cells sharing one `cooked-deco' object is a single step here --
              ;; and rebuilding only its first character would leave the rest of
              ;; the run displaying the old cell size for as long as the buffer
              ;; lives, which is the mismatch this whole function exists to repair.
              ;; The loop is written to the property's semantics, so it stays
              ;; right however the render path chooses to share records.
              ;;
              ;; The slice geometry is in cells and a glyph's bitmap is rendered
              ;; at the cell size, so both shapes move; asking the one derivation
              ;; is what keeps this in step with how they were drawn originally.
              ;;
              ;; The run's own length is the width to rebuild at, and taking it
              ;; from the buffer rather than from the wire is what makes this
              ;; agree with `cooked--apply-glyph-deco' where the two could
              ;; differ: a run whose middle cells have since been
              ;; overwritten is two shorter runs here, each wanting a bitmap
              ;; of its own width.  A `display' value repeated by `eq' across
              ;; adjacent characters is how Emacs is told they are one image, so
              ;; the value may be shared exactly as far as the image is wide --
              ;; which is this run and no further.  See `cooked--deco-display'.
              ;;
              ;; The same count answers for a picture, and answers a different
              ;; question with it: the record carries the run's *first* cell
              ;; within the picture, and the count says how far along that row
              ;; the run reaches, so the slice re-cut here is the run's own
              ;; rectangle rather than one cell's.  Both kinds therefore depend
              ;; on the run boundary being read from the buffer, and a rescale
              ;; of a run the buffer has since shortened repairs to what the
              ;; buffer now holds rather than to what the wire once said.
              (when-let* ((display (cooked--deco-display-value
                                    deco size window (- next (point)))))
                (put-text-property (point) next 'display display))
              (goto-char next)))
          (setq cooked--deco-cell size))))))

(defun cooked--rescale-deco-on-zoom (_symbol _newval operation where)
  "React to `text-scale-mode-amount' changing so bitmaps track the zoom level.

A `add-variable-watcher' function: OPERATION and WHERE are its own, and only a
`set' in one of our buffers does anything.

A variable watcher rather than advice on `text-scale-set' or
`text-scale-mode-hook': in current Emacs, `text-scale-increase'/`-decrease' are
native subrs that do not reliably dispatch back through the Lisp-visible
`text-scale-set' symbol, so advice on it can silently never fire, and a
`define-minor-mode' body is not guaranteed to re-run its hook on every amount
change once the mode is already active.  The buffer-local amount variable
itself is the one thing every zoom entry point actually sets.

Calls `cooked--rescale-deco' directly rather than `cooked--sync-size', even
though the two are usually run together from there: `cooked--sync-size' asks
`cooked--session-cell-size', which answers `(nil . nil)' off a graphical frame
on purpose -- it is stating what to tell the *child*, and a guessed pixel size
must never reach it as fact.  Routing this watcher through it would overwrite
`cooked--last-cell', the very fallback `cooked--deco-cell-size' exists to fall
back to for a buffer with no graphical window, with that nil pair -- breaking
decoration rescaling for exactly the buffers `cooked--deco-cell-size' was
written to still answer for."
  (when (eq operation 'set)
    (with-current-buffer (or where (current-buffer))
      (when (derived-mode-p 'cooked-mode)
        (cooked--rescale-deco)))))

(add-variable-watcher 'text-scale-mode-amount #'cooked--rescale-deco-on-zoom)

(defun cooked--flush-deco-cache ()
  "Drop decoration specs measured against the outgoing theme.
On `cooked-theme-change-hook\=', which runs with the buffer current.  Not the
colours, which a spec no longer holds, but the `:ascent\=' a theme moves whenever
it changes the default face\='s font -- see `cooked--deco-image-cache\='."
  (when (hash-table-p cooked--deco-image-cache)
    (clrhash cooked--deco-image-cache)))

(add-hook 'cooked-theme-change-hook #'cooked--flush-deco-cache)

(provide 'cooked-deco)
;;; cooked-deco.el ends here
