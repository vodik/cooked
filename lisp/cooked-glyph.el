;;; cooked-glyph.el --- Box-drawing and block-element bitmaps -*- lexical-binding: t; -*-

;;; Commentary:

;; Most monospace fonts draw ─│┌┐└┘├┤┬┴┼ and the block-shade characters (▀▄█▌▐░▒▓)
;; with glyph-to-glyph inconsistencies, highly visible in full-screen programs like
;; htop, ranger and fzf that rely on these characters forming continuous borders.
;; So the font is not trusted for U+2500-U+259F: the native core classifies those
;; codepoints into a compact shape descriptor (see `BoxGlyph' in src/emu/glyph.rs)
;; and this file rasterizes the descriptor at the current cell size.  VTE, Kitty and
;; Alacritty all stopped trusting the font here for the same reason.
;;
;; Nothing in this file knows about terminals, buffers, windows or colour.  It takes
;; a descriptor and a pixel size and returns raw XBM bits; caching the result and
;; hanging it on buffer text are cooked-deco.el's business, and colouring it is
;; Emacs' -- an XBM naming neither colour is drawn in those of the face it lands on.
;; That split is what makes the geometry testable on its own — see cooked-tests-glyph.el, which
;; asserts against pixel grids without starting a session.
;;
;; The one idea worth having before reading the drawing code: a cell is not square
;; (roughly 9x20 pixels), and almost every shape here is one of two orientations of
;; the same rectangle.  An edge running up is a vertical band centred on the cell's
;; middle column; an edge running left is a horizontal band centred on its middle
;; row.  The upper half-block is a vertical band spanning the full width; the gaps in
;; a dashed line are horizontal bands spanning the full height.  Writing all of those
;; out in x/y terms means writing each one four times and getting the aspect ratio
;; wrong in at least one of them.  So the primitives below are stated in terms of an
;; axis — an extent *along* it and a thickness *across* it — and each shape is
;; written once, with the axis as data.

;;; Code:

(require 'cl-lib)

;;;; The descriptor
;;
;; Mirrors the bit layout of `BoxGlyph' in src/emu/glyph.rs — kept in sync by hand,
;; the same way `cooked--attr-*' in cooked-face.el mirrors `Attrs'.  Line glyphs: four
;; 2-bit edge-weight fields (up/down/left/right, 0=none 1=light 2=heavy 3=double)
;; packed into bits 0-7, an arc flag at bit 8, forward/backward diagonal flags at
;; bits 9-10 (mutually exclusive with the edge fields on any real codepoint), and a
;; 2-bit dash code in bits 11-12.  Block glyphs: bit 15 set, a 3-bit direction in
;; bits 0-2, a 4-bit fill amount in bits 3-6.

(defconst cooked--box-kind-block (ash 1 15))
(defconst cooked--box-arc (ash 1 8))
(defconst cooked--box-diag-forward (ash 1 9))
(defconst cooked--box-diag-backward (ash 1 10))
(defconst cooked--box-dash-shift 11)
(defconst cooked--box-dash-mask (ash 3 11))
(defconst cooked--box-dash-counts [0 2 3 4]
  "Dash code (bits 11-12 of a line descriptor) to the number of dashes it means.
Unicode defines only 2-, 3- and 4-dash lines, so the count does not fit the
two bits the layout has left; `BoxGlyph::dashes' in src/emu/glyph.rs decodes
the same table on the Rust side.")

(defconst cooked--box-weight-none 0)
(defconst cooked--box-weight-heavy 2)
(defconst cooked--box-weight-double 3)

(defconst cooked--box-direction-up 0)
(defconst cooked--box-direction-down 1)
(defconst cooked--box-direction-left 2)
(defconst cooked--box-direction-right 3)
(defconst cooked--box-direction-full 4)
(defconst cooked--box-direction-shade 5)
(defconst cooked--box-direction-quadrant 6)

(defun cooked--box-block-p (bits)
  "Whether descriptor BITS names a block element rather than a line glyph."
  (/= 0 (logand bits cooked--box-kind-block)))

(defun cooked--box-shade-p (bits)
  "Whether descriptor BITS names one of the three shade densities (░▒▓)."
  (and (cooked--box-block-p bits)
       (= (logand bits 7) cooked--box-direction-shade)))

(defun cooked--box-weight (bits edge)
  "Weight of EDGE in line descriptor BITS: 0 none, 1 light, 2 heavy, 3 double."
  (logand (ash bits (- (pcase edge ('up 0) ('down 2) ('left 4) ('right 6)))) 3))

(defun cooked--box-dashes (bits)
  "Number of dashes line descriptor BITS asks for, or 0 for a solid stroke."
  (aref cooked--box-dash-counts (ash (logand bits cooked--box-dash-mask)
                                     (- cooked--box-dash-shift))))

;;;; The raster
;;
;; One bit per pixel in a flat `bool-vector', row-major.  Flat rather than a vector
;; of row vectors because the only two things ever done with it are setting a
;; rectangle and packing the whole thing out, and both are simpler against one
;; contiguous array than against `height' separately allocated ones.

(cl-defstruct (cooked-bitmap (:constructor cooked--bitmap-create) (:copier nil))
  "A one-bit-per-pixel raster, normally exactly one terminal cell in size."
  (width 0 :documentation "Pixels across.")
  (height 0 :documentation "Pixels down.")
  (bits nil :documentation "`bool-vector' of WIDTH * HEIGHT pixels, row-major."))

(defun cooked--bitmap-make (width height)
  "A WIDTH x HEIGHT bitmap with every pixel unset."
  (cooked--bitmap-create :width width :height height
                         :bits (make-bool-vector (* width height) nil)))

(defsubst cooked--bitmap-set (bitmap x y value)
  "Set the pixel at X, Y of BITMAP to VALUE, ignoring anything off the edge."
  (when (and (>= x 0) (>= y 0)
             (< x (cooked-bitmap-width bitmap))
             (< y (cooked-bitmap-height bitmap)))
    (aset (cooked-bitmap-bits bitmap)
          (+ x (* y (cooked-bitmap-width bitmap)))
          value)))

(defsubst cooked--bitmap-ref (bitmap x y)
  "Whether the pixel at X, Y of BITMAP is set."
  (aref (cooked-bitmap-bits bitmap) (+ x (* y (cooked-bitmap-width bitmap)))))

(defun cooked--bitmap-fill (bitmap x0 y0 x1 y1 &optional clear)
  "Set every pixel of BITMAP in [X0,X1) x [Y0,Y1), clamped to its bounds.

With CLEAR, unset the span instead, which is how `cooked--box-draw-dashes'
punches gaps out of an already-drawn stroke."
  (let ((x0 (max 0 x0))
        (y0 (max 0 y0))
        (x1 (min (cooked-bitmap-width bitmap) x1))
        (y1 (min (cooked-bitmap-height bitmap) y1))
        (bits (cooked-bitmap-bits bitmap))
        (stride (cooked-bitmap-width bitmap))
        (value (not clear)))
    (let ((y y0))
      (while (< y y1)
        (let ((i (+ (* y stride) x0))
              (end (+ (* y stride) x1)))
          (while (< i end)
            (aset bits i value)
            (setq i (1+ i))))
        (setq y (1+ y))))))

;;;; Axis-relative drawing
;;
;; AXIS is `horizontal' or `vertical' and names the direction a span runs in.
;; "Along" is the extent in that direction, "across" the thickness perpendicular to
;; it.  Every function below is written once and used in both orientations.

(defun cooked--bitmap-extent (bitmap axis)
  "How many pixels BITMAP spans along AXIS."
  (if (eq axis 'horizontal)
      (cooked-bitmap-width bitmap)
    (cooked-bitmap-height bitmap)))

(defun cooked--bitmap-fill-axis (bitmap axis along0 along1 across0 across1 &optional clear)
  "Fill BITMAP's rectangle ALONG0..ALONG1 by ACROSS0..ACROSS1, oriented by AXIS.
CLEAR unsets instead, as in `cooked--bitmap-fill'."
  (if (eq axis 'horizontal)
      (cooked--bitmap-fill bitmap along0 across0 along1 across1 clear)
    (cooked--bitmap-fill bitmap across0 along0 across1 along1 clear)))

(defun cooked--bitmap-set-axis (bitmap axis along across)
  "Set the single pixel at ALONG, ACROSS of BITMAP, oriented by AXIS."
  (if (eq axis 'horizontal)
      (cooked--bitmap-set bitmap along across t)
    (cooked--bitmap-set bitmap across along t)))

(defun cooked--bitmap-stroke (bitmap axis along0 along1 center thickness)
  "Draw into BITMAP a band along AXIS, from ALONG0 to ALONG1.

The band is THICKNESS pixels wide and centred on CENTER.

The centre is biased the same way for every stroke — half the thickness before
CENTER, the remainder after — so that a light and a heavy stroke on the same
axis share a centre line and meet cleanly at a junction."
  (let ((half (/ thickness 2)))
    (cooked--bitmap-fill-axis bitmap axis along0 along1
                              (- center half) (+ center (- thickness half)))))

(defun cooked--bitmap-band (bitmap axis along0 along1 &optional clear)
  "Fill ALONG0..ALONG1 of BITMAP along AXIS, spanning its full width across.

The half-block fills and the gaps in a dashed stroke are the same shape in
opposite senses: a band of the cell that is entirely set, or entirely not."
  (cooked--bitmap-fill-axis bitmap axis along0 along1
                            0 (cooked--bitmap-extent
                               bitmap (if (eq axis 'horizontal) 'vertical 'horizontal))
                            clear))

;;;; Packing

(defun cooked--bitmap-pack (bitmap)
  "Pack BITMAP into (WIDTH HEIGHT DATA) for `create-image'.

DATA is a unibyte string with each row byte-aligned, LSB first.  This triple is
this file's own shape, not an image spec: `create-image' takes DATA as `:data'
and needs WIDTH and HEIGHT restated as `:data-width'/`:data-height' alongside a
`:stride'.  Handing it the triple instead yields an invalid spec, which Emacs
resolves by drawing the underlying character with the font — leaving the
feature looking switched off rather than broken."
  (let* ((width (cooked-bitmap-width bitmap))
         (height (cooked-bitmap-height bitmap))
         (bits (cooked-bitmap-bits bitmap))
         (row-bytes (ceiling width 8))
         (data (make-string (* row-bytes height) 0)))
    (dotimes (y height)
      (let ((row (* y width))
            (out (* y row-bytes)))
        (dotimes (x width)
          (when (aref bits (+ row x))
            (let ((i (+ out (/ x 8))))
              (aset data i (logior (aref data i) (ash 1 (mod x 8)))))))))
    (list width height data)))

;;;; Line glyphs

(defun cooked--box-bands (weight center light heavy)
  "Where a stroke of WEIGHT sits across its axis, as a list of (LO . HI).

CENTER is the cell's middle pixel on that axis, LIGHT and HEAVY the stroke
thicknesses.  Every stroke is biased the same way -- half its thickness before
CENTER and the rest from it on -- so that a light and a heavy stroke on the same
axis share a centre line.

A double line is two light strokes whose gap is exactly the light stroke's own
band.  That is what puts ═ on the same centre line as ─, so a double border
meets a single one level, and makes the gap one light stroke wide at every size
rather than a fixed pixel offset that drifted off centre."
  (let ((a (- center (/ light 2))))
    (pcase weight
      (1 (list (cons a (+ a light))))
      (2 (let ((b (- center (/ heavy 2))))
           (list (cons b (+ b heavy)))))
      (3 (list (cons (- a light) a)
               (cons (+ a light) (+ a light light)))))))

(defconst cooked--box-edge-geometry
  '((up vertical left right down t)
    (down vertical left right up nil)
    (left horizontal up down right t)
    (right horizontal up down left nil))
  "Each edge as (EDGE AXIS LOW-SIDE HIGH-SIDE OPPOSITE FROM-START).

AXIS is the direction the edge's strokes run in.  LOW-SIDE and HIGH-SIDE are the
two perpendicular edges, on the side of the edge's lower and higher coordinates
across AXIS -- so the left stroke of a double `up' is on the `left' side.
FROM-START says the edge runs from coordinate 0 inward, rather than from the
far side of the cell.")

(defun cooked--box-band-end (bands from-start near)
  "Where a stroke coming in from one border stops against BANDS.

FROM-START says the stroke comes from coordinate 0.  NEAR picks the band nearest
that border rather than the farthest.  The stroke covers the chosen band
completely, so it ends at the band's far side coming from 0 and begins at its
near side coming from the other border."
  (let ((band (car bands)))
    (dolist (candidate (cdr bands))
      (when (if (eq near from-start)
                (< (car candidate) (car band))
              (> (car candidate) (car band)))
        (setq band candidate)))
    (if from-start (cdr band) (car band))))

(defun cooked--box-draw-edges (bitmap bits light heavy)
  "Draw every edge of line descriptor BITS on BITMAP, joined at the centre.

LIGHT and HEAVY are the stroke thicknesses.  Each stroke runs from its border
to an end chosen from the bands of the two perpendicular edges, because where
a stroke has to stop is a property of the junction and not of the edge: the
same left stroke of a double line is an outer corner in ╚, an inner corner in
╝, and part of an unbroken line in ╩.

For a stroke of a double edge, on side S of it:
- if the edge on side S exists, stop at the nearer of that edge's strokes -- an
  inner corner, or the inner line of a tee (╝, and ╩'s upper strokes);
- otherwise, if the other perpendicular edge exists, run on to its farther
  stroke -- the outer corner (╚), or the outer line of a tee (╦'s top);
- otherwise meet the opposite edge at the centre (║).

For a single stroke, light or heavy:
- with no perpendicular edge, meet the opposite edge at the centre (│, ╿);
- with the opposite edge present, or a perpendicular edge on one side only, run
  to the farthest perpendicular stroke -- a cross (╪) or a corner (╒);
- otherwise it is the stem of a tee, and stops at the nearest (╤).

Drawn one stroke at a time into the same bitmap, so strokes that meet simply
overlap: nothing has to know which pixel a junction belongs to."
  (let* ((width (cooked-bitmap-width bitmap))
         (height (cooked-bitmap-height bitmap))
         (cx (/ width 2))
         (cy (/ height 2)))
    (pcase-dolist (`(,edge ,axis ,low ,high ,opposite ,from-start)
                   cooked--box-edge-geometry)
      (let ((weight (cooked--box-weight bits edge)))
        (unless (= weight cooked--box-weight-none)
          (let* ((vertical (eq axis 'vertical))
                 (across-center (if vertical cx cy))
                 (along-center (if vertical cy cx))
                 (extent (cooked--bitmap-extent bitmap axis))
                 (side-bands
                  (lambda (side)
                    (cooked--box-bands (cooked--box-weight bits side)
                                       along-center light heavy)))
                 (low-bands (funcall side-bands low))
                 (high-bands (funcall side-bands high))
                 (centre (cooked--box-band-end
                          (cooked--box-bands weight along-center light heavy)
                          from-start nil))
                 (bands (cooked--box-bands weight across-center light heavy)))
            (cl-loop
             for (lo . hi) in bands
             for index from 0
             do (let* ((end
                        (if (= weight cooked--box-weight-double)
                            (let* ((own (if (= index 0) low-bands high-bands))
                                   (other (if (= index 0) high-bands low-bands)))
                              (cond (own (cooked--box-band-end own from-start t))
                                    (other (cooked--box-band-end other from-start nil))
                                    (t centre)))
                          (let ((all (append low-bands high-bands)))
                            (cond ((null all) centre)
                                  ((or (/= 0 (cooked--box-weight bits opposite))
                                       (null low-bands) (null high-bands))
                                   (cooked--box-band-end all from-start nil))
                                  (t (cooked--box-band-end all from-start t))))))
                       (from (if from-start 0 end))
                       (to (if from-start end extent)))
                  (cooked--bitmap-fill-axis bitmap axis from to lo hi)))))))))

(defun cooked--box-draw-arc (bitmap light down-p right-p)
  "Draw into BITMAP a rounded corner joining two light edges.

LIGHT is the stroke thickness, and DOWN-P and RIGHT-P name the two connected
directions.

The corner is the shape kitty and ghostty draw: the │ stroke runs straight in
from its border, turns through a quarter circle, and leaves as the ─ stroke.
The circle's radius is the shorter of the two distances from the strokes' centre
lines to the borders they reach, which at a cell's usual aspect is about half
its width -- so the turn is in the corner and the long axis stays straight.

It replaced a quarter-ellipse spanning the whole quadrant.  That did meet both
lines, but a cell is twice as tall as it is wide, so the stroke left │'s column
almost as soon as it entered the cell and the corner read as a slanted line
rather than a rounded one.

Which pixels belong to the stroke is decided by coverage: a pixel is set when at
least half of an 8x8 grid of samples inside it lies within LIGHT/2 of the path.
Testing only the pixel's centre against the curve, as the ellipse did, sets a
pixel or not on a hair's difference, which is what made its steps uneven.
Everything is in pixel-centre coordinates, as in `cooked--box-draw-diagonal':
a straight stretch then covers exactly the columns of `cooked--box-bands' and
nothing beside them, so the ends of the arc are indistinguishable from the
straight lines they meet."
  (let* ((width (cooked-bitmap-width bitmap))
         (height (cooked-bitmap-height bitmap))
         (half (/ light 2.0))
         ;; Centre lines of the │ and ─ bands the corner joins.
         (ax (+ (car (car (cooked--box-bands 1 (/ width 2) light light))) half))
         (ay (+ (car (car (cooked--box-bands 1 (/ height 2) light light))) half))
         (radius (min (if right-p (- width ax) ax)
                      (if down-p (- height ay) ay)))
         ;; The circle's centre, towards the two borders the corner reaches.
         (ox (if right-p (+ ax radius) (- ax radius)))
         (oy (if down-p (+ ay radius) (- ay radius)))
         (samples 8)
         (needed (/ (* samples samples) 2)))
    (dotimes (y height)
      (dotimes (x width)
        (let ((hits 0))
          (dotimes (j samples)
            (let ((py (+ y (/ (+ j 0.5) samples))))
              (dotimes (i samples)
                (let* ((px (+ x (/ (+ i 0.5) samples)))
                       ;; Past the circle towards a border, the path is the
                       ;; straight stroke; within the corner's quadrant, the arc.
                       (beyond-y (if down-p (>= py oy) (<= py oy)))
                       (beyond-x (if right-p (>= px ox) (<= px ox)))
                       (distance
                        (cond (beyond-y (abs (- px ax)))
                              (beyond-x (abs (- py ay)))
                              (t (abs (- (sqrt (+ (* (- px ox) (- px ox))
                                                  (* (- py oy) (- py oy))))
                                         radius))))))
                  (when (<= distance half)
                    (setq hits (1+ hits)))))))
          (when (>= hits needed)
            (cooked--bitmap-set bitmap x y t)))))))

(defun cooked--box-draw-diagonal (bitmap thickness forward backward)
  "Draw into BITMAP a THICKNESS-wide stroke corner-to-corner.

FORWARD is ╱, BACKWARD is ╲, both is ╳.

Scans the longer axis and fills a span across the shorter one, rather than
testing every pixel's perpendicular distance to the line.  The distance test is
right for a curve, where `cooked--box-draw-arc' still uses it, but wrong here
for two reasons that both show up at the aspect ratio of a cell (about 9x20).

A perpendicular half-width of half a pixel spans barely one pixel horizontally
on a stroke that steep, so whether a row got one pixel or none came down to
rounding, and the stroke came out ragged and broken.  Scanning rows instead
guarantees exactly one span per row, so the line is connected by construction at
any aspect ratio.

The stroke also has to reach the cell's corner pixels, or a run of ╱ breaks at
every cell join — the same continuity requirement the arc has against the ─
beside it.  Pixel (X,Y) covers [X,X+1) x [Y,Y+1), so its centre is at
\(X+0.5, Y+0.5); measuring from centres is what puts a pixel in the corner,
where measuring from integer coordinates against a line drawn to (WIDTH,0) —
one column past the last pixel — left the top-right corner permanently unset.

THICKNESS is still perpendicular to the stroke, converted to a span along the
scanned axis by the ratio of the diagonal's length to that axis'."
  (let* ((width (cooked-bitmap-width bitmap))
         (height (cooked-bitmap-height bitmap))
         (w (float width))
         (h (float height))
         (norm (sqrt (+ (* w w) (* h h))))
         (half (/ thickness 2.0))
         ;; Scan whichever axis is longer, so the span is always across the
         ;; shorter one and every step of the scan advances the stroke.  The span
         ;; therefore runs along the *other* axis, which is the one named here.
         (tall (>= height width))
         (axis (if tall 'horizontal 'vertical))
         (steps (if tall height width))
         (span (cooked--bitmap-extent bitmap axis))
         ;; Perpendicular half-thickness, projected onto the scanned axis.
         (reach (/ (* half norm) (if tall h w))))
    (dotimes (i steps)
      (let ((at (/ (+ i 0.5) steps)))
        (dolist (center (delq nil
                              (list (and forward (* span (- 1.0 at)))
                                    (and backward (* span at)))))
          (let ((lo (max 0 (floor (- center reach))))
                (hi (min span (ceiling (+ center reach))))
                ;; The span can round to nothing on a very thin stroke; the pixel
                ;; the centre falls in always belongs to the line, so it anchors
                ;; the row and keeps the stroke connected.
                (anchor (min (1- span) (max 0 (floor center)))))
            (cooked--bitmap-fill-axis bitmap axis lo hi i (1+ i))
            (cooked--bitmap-set-axis bitmap axis anchor i)))))))

(defun cooked--box-draw-dashes (bitmap axis count)
  "Break BITMAP's already-drawn stroke along AXIS into COUNT dashes.

Runs as a post-pass over the solid line rather than drawing the segments
directly: Unicode only ever dashes a plain horizontal or vertical stroke, never
a junction or corner, so nothing else is in the cell for a full-width clear to
damage — and the stroke keeps the exact thickness and centering
`cooked--box-draw-edges' gave it.

Every measurement comes from the cell, never a fixed pixel count, or the dashes
drift out of phase with the solid lines they join as the font size changes.

The gap straddles the period boundary rather than sitting inside it, which is
what makes the pattern tile: a cell loses part of a gap off its leading edge and
the rest off its trailing one, so the gap that appears at a seam between two
dashed cells is exactly the gap that appears inside one.  Anchoring the gaps
inside the cell instead would leave the two half-dashes either side of a seam
fusing into a double-length dash.  That is also why the loop runs to COUNT
inclusive: the last iteration is the half-gap the next cell continues.

Each gap is positioned by its low edge and then given a fixed width, rather than
rounding both edges independently.  `round' breaks ties to even on some builds
and towards zero on others, and every gap here lands on an exact half whenever
the period is a whole number of pixels — rounding both ends turned a run of
three even dashes into one 2px gap and two that vanished."
  (let* ((length (cooked--bitmap-extent bitmap axis))
         (period (/ (float length) count))
         ;; Enough gap to read as a gap, but never so much that the dash it
         ;; leaves behind rounds away to nothing.
         (gap (max 1 (min (floor (1- period)) (round (* period 0.35))))))
    (dotimes (i (1+ count))
      (let ((lo (floor (- (* i period) (/ gap 2.0)))))
        (cooked--bitmap-band bitmap axis lo (+ lo gap) 'clear)))))

(defun cooked--box-draw-line (bitmap bits)
  "Draw line-glyph descriptor BITS on BITMAP."
  (let* ((width (cooked-bitmap-width bitmap))
         (height (cooked-bitmap-height bitmap))
         (light (max 1 (/ (min width height) 8)))
         (heavy (max 2 (/ (min width height) 4))))
    (cond
     ((/= 0 (logand bits cooked--box-arc))
      (cooked--box-draw-arc bitmap light
                            (/= 0 (cooked--box-weight bits 'down))
                            (/= 0 (cooked--box-weight bits 'right))))
     ((/= 0 (logand bits (logior cooked--box-diag-forward cooked--box-diag-backward)))
      (cooked--box-draw-diagonal bitmap light
                                 (/= 0 (logand bits cooked--box-diag-forward))
                                 (/= 0 (logand bits cooked--box-diag-backward))))
     (t
      (cooked--box-draw-edges bitmap bits light heavy)
      ;; Dashes only ever appear on a plain horizontal or vertical line, so which
      ;; edges are set is enough to name the axis the stroke runs along.
      (let ((dashes (cooked--box-dashes bits)))
        (when (/= 0 dashes)
          (cooked--box-draw-dashes
           bitmap
           (if (or (/= 0 (cooked--box-weight bits 'left))
                   (/= 0 (cooked--box-weight bits 'right)))
               'horizontal
             'vertical)
           dashes)))))))

;;;; Block elements

(defun cooked--box-split (extent eighths)
  "Where the cut EIGHTHS of the way along EXTENT pixels falls, as a pixel index.

The one place a block element's edge is placed, so that shapes cut from opposite
sides agree on it: ▀ fills up to the cut at four eighths and ▄ from it, and the
quadrants use the same cut, so ▀ ▄ tile a cell exactly and ▌ lines up with ▙.
Each shape used to round its own size instead, and `round' breaks 8.5 to 8, so
at a 17-pixel line ▀ and ▄ were both 8 rows with a blank one between them.
Halves round up, the way the quadrants always did."
  (/ (+ (* extent eighths) 4) 8))

(defconst cooked--box-block-fills
  `((,cooked--box-direction-up vertical start)
    (,cooked--box-direction-down vertical end)
    (,cooked--box-direction-left horizontal start)
    (,cooked--box-direction-right horizontal end))
  "Partial block fills, as (DIRECTION AXIS ANCHOR).

▀ ▄ ▌ ▐ and their eighth-steps are one shape in four orientations: a band
covering some fraction of one axis, anchored at that axis' start or end.")

(defun cooked--box-draw-shade (bitmap level phase)
  "Fill BITMAP with an ordered dither at LEVEL, one of the shades ░▒▓.

PHASE positions the pattern in absolute screen space: bit 0 offsets the columns,
bit 1 the rows, as `cooked--box-phase' computes them.  Without it the dither
restarts at every cell, which tiles only when the cell is even-sized — and a
cell is very often 9 pixels wide.  At an odd width the last column of one cell
and the first of the next are both set, drawing a doubled column down every seam
between adjacent shade cells; an odd line-box height (which `line-spacing' can
easily produce) does the same horizontally.

All three patterns have period 2 on both axes, so one bit per axis is the whole
phase — there is no third alignment to represent."
  (let ((dx (logand phase 1))
        (dy (logand (ash phase -1) 1)))
    (dotimes (y (cooked-bitmap-height bitmap))
      (dotimes (x (cooked-bitmap-width bitmap))
        ;; The shifted coordinates choose the pattern; the plain ones address the
        ;; bitmap, which is always cell-local.
        (let ((px (+ x dx)) (py (+ y dy)))
          (when (pcase level
                  (1 (and (cl-evenp px) (cl-evenp py)))
                  (2 (cl-evenp (+ px py)))
                  (_ (not (and (cl-evenp px) (cl-evenp py)))))
            (cooked--bitmap-set bitmap x y t)))))))

(defun cooked--box-draw-quadrant (bitmap mask)
  "Fill whichever quarters of BITMAP MASK selects, for the ten 2x2 quadrant glyphs.
Bit 0 is the upper left, 1 the upper right, 2 the lower left, 3 the lower right."
  (let* ((width (cooked-bitmap-width bitmap))
         (height (cooked-bitmap-height bitmap))
         (hw (cooked--box-split width 4))
         (hh (cooked--box-split height 4)))
    (pcase-dolist (`(,bit ,x0 ,y0 ,x1 ,y1)
                   `((1 0 0 ,hw ,hh) (2 ,hw 0 ,width ,hh)
                     (4 0 ,hh ,hw ,height) (8 ,hw ,hh ,width ,height)))
      (when (/= 0 (logand mask bit))
        (cooked--bitmap-fill bitmap x0 y0 x1 y1)))))

(defun cooked--box-draw-block (bitmap bits phase)
  "Draw block-element descriptor BITS on BITMAP, dithered at PHASE."
  (let ((direction (logand bits 7))
        (fraction (logand (ash bits -3) 15)))
    (cond
     ((= direction cooked--box-direction-full)
      (cooked--bitmap-fill bitmap 0 0 (cooked-bitmap-width bitmap)
                           (cooked-bitmap-height bitmap)))
     ((= direction cooked--box-direction-shade)
      (cooked--box-draw-shade bitmap fraction phase))
     ((= direction cooked--box-direction-quadrant)
      (cooked--box-draw-quadrant bitmap fraction))
     ((alist-get direction cooked--box-block-fills)
      (pcase-let* ((`(,axis ,anchor) (alist-get direction cooked--box-block-fills))
                   (extent (cooked--bitmap-extent bitmap axis)))
        (if (eq anchor 'start)
            (cooked--bitmap-band bitmap axis 0 (cooked--box-split extent fraction))
          (cooked--bitmap-band bitmap axis
                               (cooked--box-split extent (- 8 fraction)) extent)))))))

;;;; Repetition

(defun cooked--bitmap-tile (segments)
  "SEGMENTS laid side by side, as one bitmap as wide as all of them together.

SEGMENTS is a list of (BITMAP . COUNT): COUNT adjacent cells drawing BITMAP's
shape, in the order they appear across the run.  Every BITMAP must be the same
size, which is the cell size -- these are cells of one terminal row.

Pixel-for-pixel what those cells draw, which is the whole requirement: a run of
box drawing is displayed as a single wide image, and that image has to be
indistinguishable from the row of cell-sized ones it replaces -- see
`cooked--apply-glyph-deco'.

A list rather than one shape and a count, because the shapes a run wants to
share an image are not all the same one.  `├──' is two shapes over three cells
and a `tree' indent is five shapes over eleven, blanks among them, and each of
those is one image here rather than one per shape -- which is the difference
between a `display' interval per nesting level and one for the row.

Stretching one cell to a run's width would be cheaper and is wrong for every
shape that is not constant along the x axis: ─ survives it, │ becomes one thick
stroke in the middle of the run, and ┌ becomes nothing recognisable.  Tiling is
the only construction that is correct for an arbitrary shape.

Iterates each source's set pixels rather than the destination's, so the cost is
the ink in the run rather than the whole rectangle -- and a blank cell, which is
what a `tree' indent is mostly made of, costs nothing at all."
  (let* ((first (caar segments))
         (width (cooked-bitmap-width first))
         (height (cooked-bitmap-height first))
         (stride (* width (apply #'+ (mapcar #'cdr segments))))
         (out (cooked--bitmap-make stride height))
         (bits (cooked-bitmap-bits out))
         (offset 0))
    (pcase-dolist (`(,bitmap . ,count) segments)
      (let ((source (cooked-bitmap-bits bitmap)))
        (dotimes (y height)
          (let ((row (* y width))
                (base (+ offset (* y stride))))
            (dotimes (x width)
              (when (aref source (+ row x))
                (let ((i (+ base x)))
                  (dotimes (_ count)
                    (aset bits i t)
                    (setq i (+ i width)))))))))
      (setq offset (+ offset (* width count))))
    out))

(defun cooked--bitmap-repeat (bitmap count)
  "COUNT copies of BITMAP side by side, as one bitmap COUNT times as wide.

The one-shape case of `cooked--bitmap-tile', which is what a border row is."
  (cooked--bitmap-tile (list (cons bitmap count))))

;;;; Entry point

(defun cooked--render-box-glyph-cell (bits width height &optional phase)
  "Unpacked single-cell bitmap for glyph descriptor BITS at WIDTH x HEIGHT.

PHASE, defaulting to 0, positions patterns that have to line up with the
neighbouring cell rather than with this one — see `cooked--box-draw-shade'.

The shape math -- `cooked--box-draw-arc\='s per-pixel trigonometry among it --
lives entirely here and nowhere else, which is what makes this the one half of
`cooked--render-box-glyph\=' worth caching without a run length in the key: a
shape at a given size and phase is drawn exactly once no matter how many
adjacent cells later tile it.  See `cooked--pack-box-glyph-cell\=' for the other
half."
  (let ((bitmap (cooked--bitmap-make width height)))
    (if (cooked--box-block-p bits)
        (cooked--box-draw-block bitmap bits (or phase 0))
      (cooked--box-draw-line bitmap bits))
    bitmap))

(defun cooked--pack-box-glyph-run (segments)
  "SEGMENTS -- a list of (BITMAP . COUNT) -- tiled and packed for `create-image'.

Cheap next to `cooked--render-box-glyph-cell': no shape math, just copying set
pixels (`cooked--bitmap-tile') and packing bytes (`cooked--bitmap-pack').  A
run's pattern varies with content and so has no natural bound the way a shape
descriptor does, which is what makes it safe for a cache keyed on the pattern to
throw entries away under memory pressure -- rebuilding one costs this, not the
trigonometry behind any of the BITMAPs."
  (cooked--bitmap-pack (if (and (null (cdr segments)) (= (cdar segments) 1))
                           (caar segments)
                         (cooked--bitmap-tile segments))))

(defun cooked--pack-box-glyph-cell (bitmap count)
  "COUNT adjacent copies of single-cell BITMAP, packed for `create-image'.

The one-shape case of `cooked--pack-box-glyph-run'."
  (cooked--pack-box-glyph-run (list (cons bitmap (or count 1)))))

(defun cooked--render-box-glyph (bits width height &optional phase count)
  "Raw XBM bitmap for glyph descriptor BITS at WIDTH x HEIGHT pixels.

COUNT, defaulting to 1, is how many adjacent cells draw this shape: the bitmap
comes back COUNT cells wide, holding COUNT copies of it, so that a whole run can
be displayed as one image.  A thin wrapper over `cooked--render-box-glyph-cell'
and `cooked--pack-box-glyph-cell\=' kept for callers -- tests among them -- that
want the raw pixels in one call and have no reason to cache the two halves
separately; `cooked--box-glyph-bits\=' in cooked-deco.el is the caller that does."
  (cooked--pack-box-glyph-cell
   (cooked--render-box-glyph-cell bits width height phase) count))

(provide 'cooked-glyph)
;;; cooked-glyph.el ends here
