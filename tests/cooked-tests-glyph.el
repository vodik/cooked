;;; cooked-tests-glyph.el --- The box-drawing rasterizer, pixel by pixel -*- lexical-binding: t; -*-

;;; Commentary:

;; `cooked-glyph.el' is a pure function of a descriptor and a pixel size, so
;; these assert on the bitmap itself rather than going through a session and a
;; display property.  That is the only way to see any of this in batch: the
;; defects below -- a dash that is not dashed, a dither that steps at the cell
;; boundary, a diagonal that misses the corner its neighbour has to meet -- are
;; all invisible to a test that only checks a `display' property exists.

;;; Code:

(require 'cooked-tests-helpers)

(defun cooked-tests--glyph-image (pos)
  "The image spec inside the `display' property at POS.

A decorated character's `display' is a one-element list holding the image, not
the image itself -- see `cooked--deco-display' for why it has to be a fresh list
per character."
  (car-safe (get-text-property pos 'display)))

(ert-deftest cooked-adjacent-box-glyphs-do-not-share-a-display-property ()
  "Emacs merges a run of characters whose `display' properties are `eq' into one
displayed image.  Sharing a memoized spec across cells is otherwise exactly what
is wanted -- it is why the picture is decoded once -- but it made a run of box
drawing render as a single glyph.  The image may be shared; the property may not.

Not observable in batch, where nothing is drawn, which is how it got through:
every character still had a correct `display' property, and only the display
engine merged them."
  (cooked-tests--with-session
      ;; Four of the same character in a row, which is what a border is.
      '("/bin/sh" "-c" "printf '\\342\\224\\200\\342\\224\\200\\342\\224\\200\\342\\224\\200\\n'")
    (cooked-tests--cell)
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'display))))
    (let ((first (get-text-property (point-min) 'display))
          (second (get-text-property (1+ (point-min)) 'display)))
      (should first)
      (should second)
      (should-not (eq first second))
      ;; ...while the image underneath is shared, so it is rasterized once.
      (should (eq (cooked-tests--glyph-image (point-min))
                  (cooked-tests--glyph-image (1+ (point-min))))))))

(ert-deftest cooked-box-drawing-gets-a-display-property ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\342\\224\\214\\342\\224\\200\\342\\224\\220\\n'") ; ┌─┐
    (cooked-tests--cell)
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'display))))))

(ert-deftest cooked-box-drawing-images-disabled-falls-back-to-plain-text ()
  (let ((cooked-box-drawing-images nil))
    (cooked-tests--with-session
        '("/bin/sh" "-c" "printf '\\342\\224\\214\\342\\224\\200\\342\\224\\220\\n'") ; ┌─┐
      (should (cooked-tests--settle
               (lambda () (string-match-p "┌" (cooked-tests--text)))))
      (should-not (get-text-property (point-min) 'display)))))

(ert-deftest cooked-a-run-of-identical-glyphs-shares-one-deco-record ()
  "The point of the run-length wire format, seen from the buffer.

`Deco::packed\=' in src/emu/cell.rs sends `(BITS COUNT)\=' per run of one shape, so
`cooked--apply-glyph-deco\=' can look the image spec up once and put one
`cooked-deco\=' record over the whole run with a single `put-text-property\='.
What is asserted is the sharing itself -- `next-single-property-change\=' compares
with `eq\=', so a run that shares its record is one step of that walk -- because
that is the observable the saving is made of, and it is also exactly what
`cooked--rescale-deco\=' had to be taught to expect.

The `display\=' values must still be distinct objects, and that is not a separate
concern bolted on: sharing the record and sharing the display value look alike
in batch and only one of them is safe.  See
`cooked-adjacent-box-glyphs-do-not-share-a-display-property\='."
  (cooked-tests--with-session
      ;; Four of the same character in a row, which is what a border is.
      '("/bin/sh" "-c" "printf '\\342\\224\\200\\342\\224\\200\\342\\224\\200\\342\\224\\200\\n'")
    (cooked-tests--cell)
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'display))))
    (let ((beg (point-min)))
      (should (get-text-property beg 'cooked-deco))
      ;; One step of the walk covers all four cells: one record, not four.
      (should (>= (or (next-single-property-change beg 'cooked-deco) (point-max))
                  (+ beg 4)))
      (dotimes (i 4)
        (should (eq (get-text-property (+ beg i) 'cooked-deco)
                    (get-text-property beg 'cooked-deco))))
      ;; ...while every cell still owns its `display' value.
      (should-not (eq (get-text-property beg 'display)
                      (get-text-property (1+ beg) 'display))))))

(ert-deftest cooked-a-run-of-shades-keeps-a-record-per-cell ()
  "A shade dithers, so its phase is a function of the cell's own pixel origin --
see `cooked--box-phase\='.  The shapes are identical and so cross as one
run-length record like any other repeat, but `cooked--apply-glyph-deco\=' expands
that record per cell rather than sharing it: a shared record carries one column
for the whole run, and `cooked--rescale-deco\=' rebuilding from it would phase
every cell as though it sat where the first one does, drawing a doubled column
down each seam at an odd cell width.

The distinction is in the reader and not in the wire, which is the decision
`Deco::packed\=' argues: run-length encoding already moved the shade test from
once per character to once per record, so a flag bit would have bought one
`logand\=' per run."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\342\\226\\222\\342\\226\\222\\342\\226\\222\\n'") ; ▒▒▒
    (cooked-tests--cell 9 20)             ; odd width, where the phase can differ
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'cooked-deco))))
    (let ((beg (point-min)))
      (should (cooked--box-shade-p (nth 1 (get-text-property beg 'cooked-deco))))
      ;; Each cell its own record, so each carries its own column.
      (dotimes (i 3)
        (should (equal (nth 2 (get-text-property (+ beg i) 'cooked-deco)) i)))
      (should-not (eq (get-text-property beg 'cooked-deco)
                      (get-text-property (1+ beg) 'cooked-deco))))))

(ert-deftest cooked-a-rescale-rebuilds-every-cell-of-a-shared-glyph-run ()
  "`cooked--rescale-deco\=' walks with `next-single-property-change\=', which
compares values with `eq\=' -- so cells sharing one `cooked-deco\=' record are a
single step of that walk, and rebuilding only the step\='s first character would
leave the rest of the run drawn at the old cell size for as long as the buffer
lives.

That the walk reached every character was an accident of allocation rather than
anything the property promised: `cooked--apply-deco\=' consed a fresh record per
cell, so no two were ever `eq\=' and no run was ever longer than one.  A run of
identical glyphs is exactly what a border is made of, so sharing one record
across it is the obvious saving to make on the render path -- and making it
would have broken this silently, the buffer simply ceasing to track the font
with nothing to point at.  So the walk is pinned to the property\='s semantics
here rather than to that accident.

Glyphs and not an image placement, and the difference is the point: an image
record carries the cell\='s own row and column within the picture, so no two
cells of one placement can share it.  A glyph record for a shape that does not
dither carries nothing cell-specific at all."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\342\\224\\200\\342\\224\\200\\342\\224\\200\\n'") ; ───
    (cooked-tests--cell)
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'display))))
    (let* ((inhibit-read-only t)
           (buffer-undo-list t)
           (beg (point-min))
           (end (+ beg 3)))
      ;; One record across the run, which is what a run-length-encoded deco span
      ;; arrives as.  The three cells hold the same shape, so the record they
      ;; share is the record each already had.
      (put-text-property beg end 'cooked-deco (get-text-property beg 'cooked-deco))
      (should (equal (or (next-single-property-change beg 'cooked-deco) end) end))
      ;; Clobbered rather than compared afterwards, for the reason
      ;; `cooked-box-drawing-rescales-on-zoom' gives: batch Emacs reports one
      ;; cell size at every zoom level, so a regenerated spec is `equal' to the
      ;; one it replaced and neither identity nor value distinguishes them.
      (dotimes (i 3)
        (put-text-property (+ beg i) (+ beg i 1) 'display 'clobbered))
      (cooked-tests--cell 12 26)
      (cooked--rescale-deco)
      ;; Every cell of the run, not just the one the walk landed on.
      (dotimes (i 3)
        (should (eq (car-safe (cooked-tests--glyph-image (+ beg i))) 'image)))
      ;; And each cell's `display' is still its own object: Emacs merges a run of
      ;; `eq' display values into a single image, so a rescale that shared one
      ;; would collapse the border it just rebuilt.  See `cooked--deco-display'.
      (should-not (eq (get-text-property beg 'display)
                      (get-text-property (1+ beg) 'display))))))

(ert-deftest cooked-box-drawing-rescales-on-zoom ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\342\\224\\214\\342\\224\\200\\342\\224\\220\\n'") ; ┌─┐
    (cooked-tests--cell)
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'display))))
    ;; Zoom regenerates the image in place, purely from the `cooked-deco'
    ;; property already in the buffer — no round-trip to the native core, so this
    ;; holds regardless of whether batch Emacs' font backend reports a different
    ;; pixel size than the one it started with.
    ;;
    ;; Probed by clobbering the property and watching the sweep put it back, rather
    ;; than by watching for a fresh object: batch Emacs reports one cell size at
    ;; every zoom level, so the regenerated spec is `equal' to the one it replaced,
    ;; and object identity stopped distinguishing them once specs were memoized.
    (let ((inhibit-read-only t))
      (put-text-property (point-min) (1+ (point-min)) 'display 'clobbered))
    (text-scale-increase 1)
    (should (eq (car-safe (cooked-tests--glyph-image (point-min))) 'image))))

;; `image-scaling-factor' defaults to `auto', which scales images by cell-width/10
;; on most GUI font sizes.  These bitmaps are generated at exactly the cell size, so
;; any scaling breaks the pixel-exactness the whole feature exists for — the glyphs
;; stop meeting at cell boundaries and blur back into looking like font characters.
;; An inline `xbm' whose `:data' is raw bits is only a valid spec with
;; `:data-width', `:data-height' and `:stride' (see (elisp) XBM Images).  Get that
;; wrong and Emacs rejects the whole spec and silently falls back to drawing the
;; character with the font, so every other box-drawing test here still passes while
;; nothing renders.  Asserted on the spec rather than via `image-size' because that
;; needs a graphic display and this suite runs in batch.
(ert-deftest cooked-box-drawing-image-spec-is-a-valid-inline-xbm ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\342\\224\\214\\342\\224\\200\\342\\224\\220\\n'") ; ┌─┐
    (cooked-tests--cell)
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'display))))
    (let* ((image (cooked-tests--glyph-image (point-min)))
           (plist (cdr image))
           (width (plist-get plist :data-width)))
      (should (stringp (plist-get plist :data)))
      (should (natnump width))
      (should (natnump (plist-get plist :data-height)))
      ;; Stride is bits per row, rounded up to a whole number of bytes.
      (should (equal (plist-get plist :stride) (* 8 (ceiling width 8))))
      ;; The data must hold at least stride*height bits.
      (should (>= (* 8 (length (plist-get plist :data)))
                  (* (plist-get plist :stride) (plist-get plist :data-height)))))))

;; The colour model, and the one thing about it that is easy to get backwards.  A
;; glyph names neither colour, so Emacs draws the XBM in the colours of the face at
;; the position it sits on (`xbm_load' falls back to the face's own pair, and
;; `search_image_cache' keys the cached pixmap on it).  Naming them in the spec
;; instead looks right and is wrong for the background: it paints over the region,
;; `hl-line-mode', an `isearch' match and every other face Emacs composites on top,
;; so a selection over a screenful of `htop' highlighted everything but the borders.
;; The foreground hid that for as long as it lasted, being exactly the colour the
;; face already carries.
;;
;; Asserted on the spec because it is the whole of the mechanism: what is under test
;; is the *absence* of two properties, which no rendering test in batch could see.
(ert-deftest cooked-box-drawing-takes-its-colors-from-the-face ()
  (cooked-tests--with-session
      ;; A red-on-blue border, so a spec that colours itself has something to say.
      '("/bin/sh" "-c" "printf '\\033[31;44m\\342\\224\\214\\342\\224\\200\\033[0m\\n'") ; ┌─
    (cooked-tests--cell)
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'display))))
    (let ((plist (cdr (cooked-tests--glyph-image (point-min)))))
      (should-not (plist-member plist :foreground))
      (should-not (plist-member plist :background)))
    ;; ...and the rendition is not lost, it is on the text, which is where Emacs
    ;; reads it from.
    (should (equal (get-text-property (point-min) 'face)
                   '(:foreground "red3" :background "blue2")))))

;; One spec per shape and size, whatever colour the cells are drawn in.  This is the
;; payoff of the test above rather than a separate feature: once the colours are out
;; of the spec they are out of the cache key too, so a border that changes colour
;; part way along still rasterizes once.
(ert-deftest cooked-box-drawing-shares-one-spec-across-renditions ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\033[31m\\342\\224\\200\\033[44m\\342\\224\\200\\033[0m\\n'") ; ──
    (cooked-tests--cell)
    (should (cooked-tests--settle
             (lambda () (get-text-property (1+ (point-min)) 'display))))
    (should (eq (cooked-tests--glyph-image (point-min))
                (cooked-tests--glyph-image (1+ (point-min)))))))

;; A spec leaves `create-image' having passed through the user's advice on it,
;; and `solaire-mode' ships one that `plist-put's the background of
;; `solaire-default-face' onto every image made in a buffer where it is enabled.
;; That is right for an icon's transparent PNG and wrong for a bitmap whose
;; second colour is the cell it stands in: it pinned box drawing to solaire's
;; background, so a full-screen program repainting on a colourscheme change
;; recoloured its whole screen except the borders.  Reproduced here with the
;; same advice rather than with solaire, since what matters is the shape of the
;; interference and not who wrote it.
(ert-deftest cooked-box-drawing-resists-advice-that-colors-every-image ()
  (advice-add 'create-image :filter-return #'cooked-tests--stamp-background)
  (unwind-protect
      (cooked-tests--with-session
          '("/bin/sh" "-c" "printf '\\033[44m\\342\\224\\200\\033[0m\\n'") ; blue ─
        (cooked-tests--cell)
        (should (cooked-tests--settle
                 (lambda () (get-text-property (point-min) 'display))))
        (let ((plist (cdr (cooked-tests--glyph-image (point-min)))))
          (should-not (plist-member plist :background))
          (should-not (plist-member plist :foreground))
          ;; The rest of the spec is untouched -- this strips two keys, it does
          ;; not rebuild the image.
          (should (equal (plist-get plist :scale) 1))
          (should (stringp (plist-get plist :data)))))
    (advice-remove 'create-image #'cooked-tests--stamp-background)))

(ert-deftest cooked-box-drawing-images-opt-out-of-auto-scaling ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\342\\224\\214\\342\\224\\200\\342\\224\\220\\n'") ; ┌─┐
    (cooked-tests--cell)
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'display))))
    (let ((image (cooked-tests--glyph-image (point-min))))
      (should (eq (car image) 'image))
      (should (equal (plist-get (cdr image) :scale) 1)))))

;; The two features meet here: box glyphs live in the scrollback, and the alt pin
;; narrows the buffer away from it.  A zoom while a full-screen program is up must
;; still reach the glyphs above the restriction, or they stay at the old pixel size
;; and only reveal it — mismatched against their neighbours — once the pin lifts.
(ert-deftest cooked-box-drawing-rescales-above-the-alt-screen-pin ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\342\\224\\214\\342\\224\\200\\342\\224\\220\\n'") ; ┌─┐
    (cooked-tests--cell)
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'display))))
    (let ((glyph (point-min)))
      ;; Clobbered so the sweep reaching this position is observable; see
      ;; `cooked-box-drawing-rescales-on-zoom' for why identity will not do.
      (let ((inhibit-read-only t))
        (put-text-property glyph (1+ glyph) 'display 'clobbered))
      ;; Pin the buffer to a screen region starting below the glyph, as entering the
      ;; alt screen does.
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert "\n"))
      (setq cooked--screen-start (copy-marker (point-max)))
      (setq cooked--alt t)
      (cooked--apply-alt-pin)
      (should cooked--narrowed)
      (should (< glyph (point-min)))
      (text-scale-increase 1)
      (save-restriction
        (widen)
        (should (eq (car-safe (cooked-tests--glyph-image glyph)) 'image))))))

;; Distinct from the alt-pin test above: there, the glyph reaches "scrollback" by
;; the marker moving past it in place, never leaving the buffer.  Here it genuinely
;; scrolls off the top of the screen and round-trips through `scrolled_rows', the
;; flood path that used to flatten glyphs to plain styled text for cost reasons.
(ert-deftest cooked-box-drawing-survives-scrolling-into-history ()
  (cooked-tests--with-session
      (list "/bin/sh" "-c"
            (concat "printf '\\342\\224\\214\\342\\224\\200\\342\\224\\220\\n'" ; ┌─┐
                    "; for i in $(seq 40); do printf 'line%s\\n' $i; done; exec cat"))
    (cooked-tests--cell)
    (should (cooked-tests--settle
             (lambda () (string-match-p "line40" (cooked-tests--text)))))
    ;; More lines were printed than fit on screen, so the box-drawing row has
    ;; actually scrolled away rather than merely being relabeled in place.
    (should (< (point-min) (marker-position cooked--screen-start)))
    (save-excursion
      (goto-char (point-min))
      (should (search-forward "┌" (marker-position cooked--screen-start) t))
      (should (get-text-property (match-beginning 0) 'display)))))

;; The one test that crosses the boundary: the dash field is a hand-kept mirror
;; between `BoxGlyph' in src/emu/glyph.rs and the `cooked--box-dash-*' constants, and
;; nothing else here would notice the two drifting apart.  ┄ is U+2504, whose only
;; difference from a solid ─ is the dash count — exactly what used to be dropped.
(ert-deftest cooked-box-dash-descriptors-survive-the-round-trip ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\342\\224\\204\\n'") ; ┄
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'cooked-deco))))
    ;; `(KIND BITS FG BG ATTRS COLUMN ROW)' -- the descriptor is behind the kind.
    (let ((bits (cadr (get-text-property (point-min) 'cooked-deco))))
      (should (= 3 (cooked--box-dashes bits)))
      ;; ...and it is still a light horizontal line underneath.
      (should (= 1 (cooked--box-weight bits 'left)))
      (should (= 1 (cooked--box-weight bits 'right)))
      (should (= 0 (cooked--box-weight bits 'up))))))

;; Before this, every dashed codepoint was classified as its solid counterpart, so
;; ┄ and ─ produced byte-identical bitmaps and no amount of drawing could have told
;; them apart.
(ert-deftest cooked-box-dashed-lines-break-into-the-right-number-of-dashes ()
  (let ((width 9) (height 20))
    (let ((solid (cooked-tests--glyph-grid
                  (cooked-tests--line-bits 0 0 1 1) width height)))
      (should (equal (cooked-tests--row-runs solid (/ height 2) width) (list width))))
    ;; Dash codes 1/2/3 are 2, 3 and 4 dashes.
    (dolist (case '((1 . 2) (2 . 3) (3 . 4)))
      (let* ((grid (cooked-tests--glyph-grid
                    (cooked-tests--line-bits 0 0 1 1 (car case)) width height))
             (runs (cooked-tests--row-runs grid (/ height 2) width)))
        (should (equal (length runs) (cdr case)))
        ;; Every dash has to survive as at least one pixel.
        (should (cl-every (lambda (run) (>= run 1)) runs))))))

(ert-deftest cooked-box-dashed-lines-follow-the-stroke-axis ()
  (let* ((width 9) (height 20)
         (vertical (cooked-tests--glyph-grid
                    (cooked-tests--line-bits 1 1 0 0 2) width height))
         (column (/ width 2))
         (rows (let ((n 0))
                 (dotimes (y height) (when (cooked--bitmap-ref vertical column y) (setq n (1+ n))))
                 n)))
    ;; Gaps came out of the column, not out of nothing and not out of a row.
    (should (< rows height))
    (should (> rows 0))))

;; The gap has to straddle the cell boundary, or two dashed cells side by side fuse
;; their edge dashes into one double-length dash at every seam.
(ert-deftest cooked-box-dashes-tile-across-the-cell-boundary ()
  (let* ((width 9) (height 20)
         (grid (cooked-tests--glyph-grid
                (cooked-tests--line-bits 0 0 1 1 2) width height))
         (row (/ height 2)))
    ;; A cell that ends set and starts set would join across the seam.
    (should-not (and (cooked--bitmap-ref grid 0 row)
                     (cooked--bitmap-ref grid (1- width) row)))))

;; A 9-pixel cell is odd, so a dither phased from cell-local coordinates repeats a
;; column at every seam: the last column of one cell and the first of the next are
;; both set, drawing a doubled line down the join between two ▒ cells.
(ert-deftest cooked-box-shade-dither-tiles-across-an-odd-cell-width ()
  (let* ((width 9) (height 8)
         (medium (logior cooked--box-kind-block cooked--box-direction-shade (ash 2 3)))
         (unphased (cooked-tests--glyph-grid medium width height 0))
         ;; The phase the next cell along gets at this width.
         (phase (logand width 1))
         (phased (cooked-tests--glyph-grid medium width height phase)))
    (should (= phase 1))
    (should-not (equal unphased phased))
    ;; Walking off the right edge of one cell into the left edge of the next must
    ;; alternate exactly as it does inside a cell.
    (dotimes (y height)
      (should-not (eq (cooked--bitmap-ref unphased (1- width) y)
                      (cooked--bitmap-ref phased 0 y))))))

(ert-deftest cooked-box-shade-phase-is-zero-unless-it-can-matter ()
  (let ((window (selected-window))
        (medium (logior cooked--box-kind-block cooked--box-direction-shade (ash 2 3)))
        (solid (cooked-tests--line-bits 0 0 1 1)))
    ;; Nothing but a shade is phase-sensitive, so nothing else doubles its cache.
    (should (= 0 (cooked--box-phase solid window 3 5)))
    ;; Nor is a shade whose column is unknown.
    (should (= 0 (cooked--box-phase medium window nil 5)))))

;; A diagonal has to reach the two corners it shares with its neighbours, or a run
;; of ╱ breaks at every cell join — and it has to put a pixel on every scanline, or
;; the stroke itself comes apart at a cell's aspect ratio.
(ert-deftest cooked-box-diagonals-are-connected-and-reach-their-corners ()
  (let* ((width 9) (height 20)
         (forward (cooked-tests--glyph-grid cooked--box-diag-forward width height))
         (backward (cooked-tests--glyph-grid cooked--box-diag-backward width height)))
    (dotimes (y height)
      (should (cooked-tests--row-runs forward y width))
      (should (cooked-tests--row-runs backward y width)))
    ;; ╱ runs bottom-left to top-right, ╲ top-left to bottom-right.
    (should (cooked--bitmap-ref forward (1- width) 0))
    (should (cooked--bitmap-ref forward 0 (1- height)))
    (should (cooked--bitmap-ref backward 0 0))
    (should (cooked--bitmap-ref backward (1- width) (1- height)))))

(ert-deftest cooked-box-cross-is-the-union-of-both-diagonals ()
  (let* ((width 9) (height 20)
         (forward (cooked-tests--glyph-grid cooked--box-diag-forward width height))
         (backward (cooked-tests--glyph-grid cooked--box-diag-backward width height))
         (cross (cooked-tests--glyph-grid
                 (logior cooked--box-diag-forward cooked--box-diag-backward)
                 width height)))
    (dotimes (y height)
      (dotimes (x width)
        (should (eq (and (cooked--bitmap-ref cross x y) t)
                    (and (or (cooked--bitmap-ref forward x y)
                             (cooked--bitmap-ref backward x y))
                         t)))))))

;; Cells are not square and the font size moves, so the stroke has to stay connected
;; at any geometry, not just the one that happened to be tested.
(ert-deftest cooked-box-diagonals-stay-connected-at-any-cell-size ()
  (dolist (size '((4 . 3) (5 . 20) (9 . 20) (20 . 5) (16 . 32)))
    (let* ((width (car size)) (height (cdr size))
           (grid (cooked-tests--glyph-grid cooked--box-diag-forward width height)))
      (dotimes (y height)
        (should (cooked-tests--row-runs grid y width)))
      (dotimes (x width)
        (should (let ((set nil))
                  (dotimes (y height) (when (cooked--bitmap-ref grid x y) (setq set t)))
                  set))))))

(ert-deftest cooked-box-glyph-bits-match-the-rust-side-encoding ()
  "Descriptors mirror `BoxGlyph' in src/emu/glyph.rs by hand (see this file's own
\"Mirrors the bit layout\" commentary), and cross the wire as a raw `u16' (see
`Deco::Glyphs' in lib.rs) -- nothing enforces that the two ends agree on what a
bit means. These are the same twelve literals
`bit_pattern_matches_the_lisp_side_mirror' pins in glyph.rs, written here
independently rather than read across the boundary: a change to either side's
packing with no matching change to the other is exactly the bug this pair of
tests exists to catch."
  ;; ─ U+2500 light horizontal
  (let ((bits #x0050))
    (should (= (cooked--box-weight bits 'left) 1))
    (should (= (cooked--box-weight bits 'right) 1))
    (should (= (cooked--box-weight bits 'up) 0))
    (should (= (cooked--box-weight bits 'down) 0))
    (should (= (cooked--box-dashes bits) 0))
    (should-not (cooked--box-block-p bits)))
  ;; ┃ U+2503 heavy vertical
  (let ((bits #x000A))
    (should (= (cooked--box-weight bits 'up) 2))
    (should (= (cooked--box-weight bits 'down) 2))
    (should (= (cooked--box-weight bits 'left) 0))
    (should (= (cooked--box-weight bits 'right) 0)))
  ;; ╋ U+254B heavy cross
  (let ((bits #x00AA))
    (dolist (edge '(up down left right))
      (should (= (cooked--box-weight bits edge) 2))))
  ;; ═ U+2550 double horizontal
  (let ((bits #x00F0))
    (should (= (cooked--box-weight bits 'left) 3))
    (should (= (cooked--box-weight bits 'right) 3))
    (should (= (cooked--box-weight bits 'up) 0)))
  ;; ┄ U+2504 light horizontal, triple-dashed
  (let ((bits #x1050))
    (should (= (cooked--box-weight bits 'left) 1))
    (should (= (cooked--box-weight bits 'right) 1))
    (should (= (cooked--box-dashes bits) 3)))
  ;; ╭ U+256D light arc, down and right
  (let ((bits #x0144))
    (should (/= 0 (logand bits cooked--box-arc)))
    (should (= (cooked--box-weight bits 'down) 1))
    (should (= (cooked--box-weight bits 'right) 1))
    (should (= (cooked--box-weight bits 'up) 0))
    (should (= (cooked--box-weight bits 'left) 0)))
  ;; ╱ U+2571 diagonal, forward only
  (let ((bits #x0200))
    (should (/= 0 (logand bits cooked--box-diag-forward)))
    (should (= 0 (logand bits cooked--box-diag-backward))))
  ;; ╳ U+2573 diagonal, both directions
  (let ((bits #x0600))
    (should (/= 0 (logand bits cooked--box-diag-forward)))
    (should (/= 0 (logand bits cooked--box-diag-backward))))
  ;; █ U+2588 full block
  (let ((bits #x8044))
    (should (cooked--box-block-p bits))
    (should (= (logand bits 7) cooked--box-direction-full))
    (should (= (logand (ash bits -3) 15) 8)))
  ;; ▄ U+2584 lower half block
  (let ((bits #x8021))
    (should (cooked--box-block-p bits))
    (should (= (logand bits 7) cooked--box-direction-down))
    (should (= (logand (ash bits -3) 15) 4)))
  ;; ▒ U+2592 medium shade
  (let ((bits #x8015))
    (should (cooked--box-shade-p bits))
    (should (= (logand (ash bits -3) 15) 2)))
  ;; ▙ U+2599 quadrant: upper-left, lower-left, lower-right
  (let ((bits #x806E))
    (should (cooked--box-block-p bits))
    (should (= (logand bits 7) cooked--box-direction-quadrant))
    (should (= (logand (ash bits -3) 15) #b1101))))

(provide 'cooked-tests-glyph)
;;; cooked-tests-glyph.el ends here
