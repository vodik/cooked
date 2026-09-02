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
;; Image lifetime is Emacs\=' and there is no release protocol.  `cooked--image-data\=' is
;; the only copy of the bytes, so it is strong; `cooked--image-specs\=' is rebuildable, so
;; it is weak on the value, and the buffer text displaying a spec is what keeps it alive.

;;; Code:

(require 'cooked-util)
(require 'cooked-face)
(require 'cooked-glyph)

;; The one thing decoration asks of the layer above: which window to measure a
;; cell against, when the buffer is not being rendered from the selected one.
(declare-function cooked--layout-window "cooked")

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
XBM image support or bitmap generation fails for a glyph."
  :type 'boolean
  :group 'cooked)

(defvar-local cooked--last-cell nil
  "The (WIDTH . HEIGHT) cell size in pixels last reported, or nil.

Written by `cooked--sync-size\=', which is the one place that notices the cell
moving, and tracked apart from `cooked--last-size\=' because it moves
independently of it: `text-scale-mode\=' changes the cell size and the row and
column count together, but a theme or font change can move the cell size while
the grid stays put, and the child has to hear about that too.

It lives here rather than beside `cooked--last-size\=' in cooked-mode.el because
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

(defvar-local cooked--box-glyph-cache nil
  "Descriptor+pixel-size -> raw XBM bitmap, memoized per buffer.

Colorless by construction: the cached value is a shape only, and stays one all
the way to the screen — Emacs colours the finished XBM from the face it is
displayed on.  So unlike `cooked--face-cache' this needs no theme-change
invalidation; only pixel-size changes (zoom, font change) miss the cache key,
naturally, with no extra plumbing.")

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
one end, and the far end is what `cooked--evict-images\=' spends.")

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
empties this on a theme change.")

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
A bitmap sized to the font leaves exactly `line-spacing' pixels of background
beneath every glyph, breaking the continuous vertical borders this exists to
produce — the same defect `indent-bars' documents for box characters."
  (cons (window-font-width window 'default)
        (window-default-line-height window)))

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
`cooked--apply-deco\='."
  (if-let* ((window (cooked--layout-window)))
      (cooked--cell-size window)
    (and (integerp (car-safe cooked--last-cell))
         (integerp (cdr cooked--last-cell))
         cooked--last-cell)))

(defun cooked--box-glyph-bits (bits size &optional phase)
  "Cached raw bitmap for glyph BITS at cell SIZE, from `cooked--cell-size'.

PHASE joins the cache key, since two cells of the same glyph at opposite phases
are genuinely different bitmaps.  It is non-zero only for shade glyphs at an odd
cell size, so in practice nothing else pays for the extra variant."
  (cooked--cached cooked--box-glyph-cache (list bits (car size) (cdr size) (or phase 0))
    (cooked--render-box-glyph bits (car size) (cdr size) (or phase 0))))

(defun cooked--box-glyph-ascent (window height)
  "Return the `:ascent' that places a bitmap on WINDOW's line box.

HEIGHT is the bitmap's height in pixels.

A percentage rather than `center' now that the bitmap spans the whole line box:
`center' balances the image around the text's midline, which splits any
`line-spacing' evenly above and below and lifts the glyph off the box it was
sized to fill.  Anchoring the font's own ascent instead keeps the extra space
where Emacs actually puts it — below the baseline.

Falls back to `center' if the font reports no metrics, which is the previous
behaviour and still correct whenever `line-spacing' is nil."
  (cooked--cached cooked--box-ascent-cache height
    (let ((base (ignore-errors
                  (aref (font-info (face-font 'default nil window)) 8))))
      (if (and (natnump base) (> height 0) (<= base height))
          (round (* 100 base) height)
        'center))))

(defun cooked--box-phase (bits size column row)
  "Dither phase for glyph BITS drawn at screen COLUMN and ROW, at cell SIZE.

Bit 0 is the parity of the cell's left edge in pixels, bit 1 the parity of its
top edge — which is all `cooked--box-draw-shade' needs, its patterns having
period 2 on both axes.  An even cell size makes the corresponding bit constantly
0, so the common case adds no cache variants at all.

Always 0 for anything but a shade, so no other glyph doubles its cached
variants, and 0 as well when COLUMN is unknown.  ROW may be nil where the caller
has no row index, which costs at most a horizontal seam on an odd line height.

Derived from the cell size at every call rather than remembered: the phase of a
given cell changes when the font does, so a value cached alongside the glyph
would be stale the moment the buffer is zoomed."
  (if (not (and column (cooked--box-shade-p bits)))
      0
    (logior (logand (* column (car size)) 1)
            (ash (logand (* (or row 0) (cdr size)) 1) 1))))

(defun cooked--deco-display (image)
  "Wrap IMAGE as a `display\=' value that stands for exactly one character.

Emacs merges a run of characters whose `display\=' properties are `eq\=' into a
single displayed image -- that is what makes (propertize \"xx\" \='display IMG)
show one image rather than two.  So sharing one memoized spec across adjacent
cells, which is otherwise exactly what you want, collapses a run of box drawing
to a single glyph.

A fresh one-element list per character is enough to keep them distinct, and is
a list of display specifications, which is a shape `display\=' already accepts.
One cons per character against rebuilding the spec: `create-image\=' allocates a
fourteen-element plist and searches Emacs\=' image cache, and skipping that is
worth roughly half the box-drawing frame time.

The image itself stays shared, so Emacs still decodes it once."
  (list image))

(defun cooked--box-glyph-image (bits window size phase)
  "Image spec for glyph BITS at cell SIZE.

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
  (cooked--cached cooked--deco-image-cache
      (list bits (car size) (cdr size) phase)
    (cooked--box-glyph-image-1 bits window size phase)))

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

(defun cooked--box-glyph-image-1 (bits window size phase)
  "Build the spec `cooked--box-glyph-image' memoizes.

BITS, WINDOW, SIZE and PHASE mean what they do there.

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
  (pcase-let ((`(,width ,height ,data) (cooked--box-glyph-bits bits size phase)))
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

DECO is `(KIND . PACKED)\=', what `deco_to_lisp\=' in src/lib.rs hands over: KIND
names what the run\='s characters display instead of themselves, and PACKED is a
unibyte string of fixed-width little-endian records, one per character.  Packed
rather than a list because this runs on every damaged row of every frame, and
box drawing is what full-screen programs are made of.

One property per character rather than one spanning the run: a decorated
character is always single-column, and a merged run can mix shapes.  Also
stashes `cooked-deco\=', the record plus its colors and its place on the screen,
so `cooked--rescale-deco\=' can regenerate at a new zoom level without asking the
native core for anything.

ORIGIN is the buffer position of screen column 0 on this row, and ROW the row\='s
index; together they place a shade glyph\='s dither in absolute screen space.
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
  (condition-case nil
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
           (cooked--apply-glyph-deco
            start packed (cooked--layout-window)
            (cooked--deco-cell-size) origin row))))
    ;; A cosmetic feature must never break rendering: any failure here leaves the
    ;; plain face-only text `cooked--render-block' already inserted.
    (error nil)))

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
        cooked--deco-cell nil))

(defun cooked--install-images (images)
  "Record IMAGES, a drain's `:images\=', before anything referring to them renders.

Each entry is (ID FORMAT DATA PX-WIDTH PX-HEIGHT COLS ROWS).  The module sends
one exactly once per distinct picture however often the child transmits or
places it, so this is where the only copy of the bytes lands -- and why the
table holding them is not weak.

Called ahead of both render passes, not from the event loop: an image is a
resource the rows of this very drain refer to by id, so it has to be here before
they are rendered.  Events are dispatched after rendering, so an image arriving
as one would arrive too late for the row that needed it."
  (dolist (image images)
    (pcase-let ((`(,id ,format ,data ,px-w ,px-h ,cols ,rows) image))
      (unless (gethash id cooked--image-data)
        (setq cooked--image-order (nconc cooked--image-order (list id)))
        (cl-incf cooked--image-bytes (length data)))
      (puthash id (list format data px-w px-h cols rows) cooked--image-data)))
  (cooked--evict-images))

(defcustom cooked-image-cache-size (* 64 1024 1024)
  "Bytes of transmitted image data one buffer retains, or nil for no limit.

`cooked--image-data\=' is strong and buffer-local, so it dies with the buffer
and a session that shows a few pictures never approaches this.  What it is for
is the session that shows thousands: ids are content-addressed, so a child
redrawing one picture costs nothing however long it runs, but a child drawing a
*different* picture each time -- a plotting TUI, an image browser paging
through a directory, a long `icat\=' loop -- adds one entry per frame and
nothing ever took them away.

64MB matches `MAX_RETAINED_BYTES\=' in the module, deliberately: both ends bound
the same pictures, and a single figure is easier to reason about than two.

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
entirely."
  :type '(choice (const :tag "No limit" nil) integer)
  :group 'cooked)

(defun cooked--evict-images ()
  "Spend oldest undisplayed images until `cooked--image-data\=' fits the cap.

The backstop `cooked-image-cache-size\=' documents, and the whole of it.  One
pass, and it will not touch an id anything is displaying: `cooked--image-specs\='
is weak on its values and the buffer text holding a spec in a `display\='
property is the strong reference, so a live spec means live text and its absence
means nothing is showing that picture.  The test errs the safe way -- a spec the
collector has not got to yet reads as displayed -- which under-evicts and never
blanks anything.

There is deliberately no second pass taking the oldest regardless.  That pass
was the bound, and it was also a bug: it evicted ids that were still on screen,
and `cooked--image-spec\=' answers nil for an id with no data, so the next resize
-- which damages every row of the grid, and only the grid -- rebuilt the on-grid
half of a picture as nothing while its scrollback half went on drawing.  A
guaranteed byte limit is not worth that, and it is no longer needed for the
common case: ordinary eviction is `cooked--release-images\='."
  (when (and cooked-image-cache-size
             (> cooked--image-bytes cooked-image-cache-size))
    (let ((kept nil))
      (while (and cooked--image-order
                  (> cooked--image-bytes cooked-image-cache-size))
        (let ((id (pop cooked--image-order)))
          (if (cooked--image-displayed-p id)
              (push id kept)
            (cooked--forget-image id))))
      ;; Whatever this declined to spend goes back on the front, still oldest
      ;; first, so the next call sees the same queue rather than a reversed one.
      (setq cooked--image-order (nconc (nreverse kept) cooked--image-order)))))

(defun cooked--image-displayed-p (id)
  "Whether any spec for image ID is still alive, and so still being shown."
  (catch 'found
    (maphash (lambda (key _spec)
               (when (eq (car key) id) (throw 'found t)))
             cooked--image-specs)
    nil))

(defun cooked--forget-image (id)
  "Drop image ID\='s transmitted bytes, and the bookkeeping that names them.

The specs are not touched: `cooked--image-specs\=' is weak on its values, so an
entry for a picture nothing displays is collected on its own, and one for a
picture something *does* display must outlive this -- forgetting the bytes does
not take a picture off the screen, it only takes away the ability to rebuild it
at a different cell size."
  (when-let* ((entry (gethash id cooked--image-data)))
    (cl-decf cooked--image-bytes (length (nth 1 entry)))
    (remhash id cooked--image-data)
    (setq cooked--image-order (delq id cooked--image-order))))

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

(defun cooked--image-spec (id size)
  "The `create-image\=' spec for image ID at cell SIZE, built once.

Shared deliberately: every cell of the picture displays a slice of one spec, so
Emacs decodes the image once rather than once per cell.  Nil when ID names
nothing this buffer has been told about, which is what a placement left over
from a session whose data has gone looks like.

Nil too when this Emacs cannot decode the format, which is asked here rather
than at the call site because the answer differs from image to image: a build
without libjpeg still shows PNGs.

Sized to the cell rectangle the emulator committed to, so the slices below tile
it exactly.  `:scale 1\=' for the same reason it is on a box glyph:
`image-scaling-factor\=' is `auto\=' and would resample what has already been
scaled to fit."
  (when-let* ((entry (gethash id cooked--image-data))
              ((image-type-available-p (car entry))))
    ;; Not `cooked--cached': this table is weak on its values by design -- see
    ;; `cooked--image-specs' -- and is cleared per session, so it is made by
    ;; `cooked--reset-images' rather than on first use.
    (with-memoization (gethash (list id (car size) (cdr size)) cooked--image-specs)
      (pcase-let ((`(,format ,data ,_px-w ,_px-h ,cols ,rows) entry))
        (create-image data format t
                      :width (* cols (car size))
                      :height (* rows (cdr size))
                      :scale 1
                      :ascent (cooked--box-glyph-ascent
                               (cooked--layout-window) (cdr size)))))))

(defun cooked--deco-display-value (deco size window)
  "The `display\=' value DECO should carry at cell SIZE, or nil for none.

DECO is the `cooked-deco\=' property: `(image ID CROW CCOL)\=' or
`(glyph BITS COLUMN ROW)\='.  WINDOW is only ever the ascent lookup\='s.  Nil
SIZE means there is no cell rectangle to draw against yet, and the caller
records the decoration without displaying anything.

The single answer to \"what does this decoration look like\", and both paths
that can ask it go through here: `cooked--apply-image-deco\' and
`cooked--apply-glyph-deco\' when a row is first rendered, and
`cooked--rescale-deco\' when the cell size moves under text already in the
buffer.  That was three derivations of the same two shapes, which is three
places for a new decoration kind to be added and two of them easy to miss --
the rescale path is the one that would silently go on painting the old size."
  (when size
    (pcase deco
      (`(image ,id ,crow ,ccol)
       (when-let* ((spec (cooked--image-spec id size)))
         (list (list 'slice (* ccol (car size)) (* crow (cdr size))
                     (car size) (cdr size))
               spec)))
      (`(glyph ,bits . ,where)
       (cooked--deco-display
        (cooked--box-glyph-image
         bits window size
         (cooked--box-phase bits size (car where) (cadr where))))))))

(defun cooked--apply-image-deco (start packed size)
  "Apply image decoration PACKED from START: eight bytes per character.

SIZE is the cell rectangle to cut slices to, or nil to record the placements
and display nothing -- see `cooked--apply-deco\='.

A `u32\=' image id, then the cell\='s row and column within that image as two
`u16\='s, all little-endian.  One `display\=' property per character, each a
slice of the shared spec, which is what makes the picture survive everything
the grid does to it: text written over one cell replaces that cell\='s slice and
leaves the rest, a scroll carries each row\='s slices into the scrollback
independently, and a rewrap moves them with their columns.  A single image
spanning the whole rectangle would have to be torn down and rebuilt for any of
that."
  (let ((pos start))
    (dotimes (i (/ (length packed) 8))
      (let* ((base (* 8 i))
             (id (logior (aref packed base)
                         (ash (aref packed (+ base 1)) 8)
                         (ash (aref packed (+ base 2)) 16)
                         (ash (aref packed (+ base 3)) 24)))
             (crow (logior (aref packed (+ base 4))
                           (ash (aref packed (+ base 5)) 8)))
             (ccol (logior (aref packed (+ base 6))
                           (ash (aref packed (+ base 7)) 8)))
             (deco (list 'image id crow ccol)))
        (put-text-property pos (1+ pos) 'cooked-deco deco)
        (when-let* ((display (cooked--deco-display-value deco size nil)))
          (put-text-property pos (1+ pos) 'display display)))
      (setq pos (1+ pos)))))

(defun cooked--apply-glyph-deco (start packed window size origin row)
  "Apply box-glyph decoration PACKED at START, two bytes per character.

PACKED is little-endian.  ORIGIN and ROW locate the shapes, as in
`cooked--apply-deco\='.  SIZE nil records them and displays nothing; WINDOW is
only ever the ascent lookup\='s, and is nil in the same case."
  (let ((pos start))
    (dotimes (i (/ (length packed) 2))
      (let* ((bits (logior (aref packed (* 2 i))
                           (ash (aref packed (1+ (* 2 i))) 8)))
             (column (and origin (- pos origin)))
             (deco (list 'glyph bits column row)))
        (put-text-property pos (1+ pos) 'cooked-deco deco)
        (when-let* ((display (cooked--deco-display-value deco size window)))
          (put-text-property pos (1+ pos) 'display display)))
      (setq pos (1+ pos)))))

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
               (buffer-undo-list t))
          (while (< (point) (point-max))
            (let ((deco (get-text-property (point) 'cooked-deco))
                  (next (or (next-single-property-change (point) 'cooked-deco)
                            (point-max))))
              ;; The slice geometry is in cells and a glyph's bitmap is rendered
              ;; at the cell size, so both shapes move; asking the one derivation
              ;; is what keeps this in step with how they were drawn originally.
              (when-let* ((display (cooked--deco-display-value deco size window)))
                (put-text-property (point) (1+ (point)) 'display display))
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
itself is the one thing every zoom entry point actually sets."
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
