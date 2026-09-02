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
;; the same way `cooked--attr-*' in cooked.el mirrors `Attrs'.  Line glyphs: four
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

(defun cooked--box-edge-span (bitmap edge cx cy)
  "Where EDGE runs, as (AXIS ALONG0 ALONG1 CENTER), on BITMAP with centre CX, CY.

An edge runs from the middle of the cell out to one of its four sides, so the
axis and the centre line follow from whether it is vertical or horizontal, and
only which half of the cell it covers changes."
  (pcase edge
    ('up (list 'vertical 0 (1+ cy) cx))
    ('down (list 'vertical cy (cooked-bitmap-height bitmap) cx))
    ('left (list 'horizontal 0 (1+ cx) cy))
    ('right (list 'horizontal cx (cooked-bitmap-width bitmap) cy))))

(defun cooked--box-draw-edge (bitmap edge weight cx cy light heavy)
  "Draw EDGE of a line glyph on BITMAP, from the cell centre CX, CY outward.

WEIGHT is the descriptor's 2-bit field; LIGHT and HEAVY are the stroke
thicknesses derived from the cell size.  A double edge is two 1px strokes with
a 1px gap between them, which is the same stroke twice at a fixed offset rather
than a shape of its own."
  (unless (= weight cooked--box-weight-none)
    (pcase-let ((`(,axis ,from ,to ,center) (cooked--box-edge-span bitmap edge cx cy)))
      (if (= weight cooked--box-weight-double)
          (dolist (offset '(-2 1))
            (cooked--bitmap-stroke bitmap axis from to (+ center offset) 1))
        (cooked--bitmap-stroke bitmap axis from to center
                               (if (= weight cooked--box-weight-heavy) heavy light))))))

(defun cooked--box-draw-arc (bitmap cx cy thickness down-p right-p)
  "Draw into BITMAP a quarter-ellipse joining a rounded corner's two edges.

CX and CY place the centre, THICKNESS is the stroke width, and DOWN-P and
RIGHT-P name the two connected directions.

The centre sits at whichever cell corner combines the two connected directions
\(e.g. down+right puts it at the bottom-right corner), and the two radii are the
distances from that corner to the strokes this arc has to meet: horizontally to
the vertical stroke's column CX, vertically to the horizontal stroke's row CY.

Deliberately not a circle.  A single radius can satisfy only one axis unless the
cell is square, and terminal cells are roughly half as wide as they are tall — a
circle of radius (min CX CY) leaves the arc meeting the horizontal edge far from
CY, so a rounded corner fails to line up with the ─ beside it.

THICKNESS is applied by dividing the ellipse's implicit function by the gradient
magnitude, which approximates true distance to the curve; the naive |d - 1| on
the normalized radius would vary the stroke width around the sweep."
  (let* ((width (cooked-bitmap-width bitmap))
         (height (cooked-bitmap-height bitmap))
         (ccx (if right-p width 0))
         (ccy (if down-p height 0))
         (rx (float (max 1 (if right-p (- width cx) cx))))
         (ry (float (max 1 (if down-p (- height cy) cy))))
         (half (/ thickness 2.0)))
    (dotimes (y height)
      (dotimes (x width)
        (let* ((dx (/ (- x ccx) rx))
               (dy (/ (- y ccy) ry))
               (f (- (+ (* dx dx) (* dy dy)) 1.0))
               (gx (/ (* 2.0 dx) rx))
               (gy (/ (* 2.0 dy) ry))
               (g (sqrt (+ (* gx gx) (* gy gy)))))
          (when (and (> g 0.0) (<= (/ (abs f) g) half))
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
`cooked--box-draw-edge' gave it.

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
         (cx (/ width 2))
         (cy (/ height 2))
         (light (max 1 (/ (min width height) 8)))
         (heavy (max 2 (/ (min width height) 4))))
    (cond
     ((/= 0 (logand bits cooked--box-arc))
      (cooked--box-draw-arc bitmap cx cy light
                            (/= 0 (cooked--box-weight bits 'down))
                            (/= 0 (cooked--box-weight bits 'right))))
     ((/= 0 (logand bits (logior cooked--box-diag-forward cooked--box-diag-backward)))
      (cooked--box-draw-diagonal bitmap light
                                 (/= 0 (logand bits cooked--box-diag-forward))
                                 (/= 0 (logand bits cooked--box-diag-backward))))
     (t
      (dolist (edge '(up down left right))
        (cooked--box-draw-edge bitmap edge (cooked--box-weight bits edge)
                               cx cy light heavy))
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
         (hw (/ (1+ width) 2))
         (hh (/ (1+ height) 2)))
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
                   (extent (cooked--bitmap-extent bitmap axis))
                   (amount (round (* extent (/ fraction 8.0)))))
        (if (eq anchor 'start)
            (cooked--bitmap-band bitmap axis 0 amount)
          (cooked--bitmap-band bitmap axis (- extent amount) extent)))))))

;;;; Entry point

(defun cooked--render-box-glyph (bits width height &optional phase)
  "Raw XBM bitmap for glyph descriptor BITS at WIDTH x HEIGHT pixels.

PHASE, defaulting to 0, positions patterns that have to line up with the
neighbouring cell rather than with this one — see `cooked--box-draw-shade'."
  (let ((bitmap (cooked--bitmap-make width height)))
    (if (cooked--box-block-p bits)
        (cooked--box-draw-block bitmap bits (or phase 0))
      (cooked--box-draw-line bitmap bits))
    (cooked--bitmap-pack bitmap)))

(provide 'cooked-glyph)
;;; cooked-glyph.el ends here
