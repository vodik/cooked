;;; cooked-bench.el --- Where does the time go on the Emacs side? -*- lexical-binding: t; -*-

;;; Commentary:

;; tests/throughput.rs measures the emulator core and stops at `Term::drain'.
;; That is the half that was already fast: a real session also pays to marshal
;; the delta across the module boundary and to apply it to the buffer, and
;; neither was measured by anything.  This is the other half.
;;
;;   emacs -Q --batch -L lisp -L tests -l cooked-bench.el -f cooked-bench
;;
;; Batch mode has no window system, so the box-drawing figures here measure spec
;; construction and property application, not rasterization.  That is the part
;; that scales per cell, which is what makes it worth watching.

;;; Code:

(require 'cl-lib)
(require 'cooked)
(require 'cooked-mode)

(defvar cooked-bench-results nil
  "Accumulated (LABEL SECONDS DETAIL) rows, for `cooked-bench--report'.")

(defmacro cooked-bench--with-session (argv &rest body)
  "Run BODY in a live cooked buffer running ARGV."
  (declare (indent 1))
  `(let ((buffer (generate-new-buffer "*cooked-bench*")))
     (unwind-protect
         (with-current-buffer buffer
           (cooked-mode)
           (cooked--start ,argv)
           (cooked--refresh-keymap)
           ;; No window in batch, so `cooked--deco-cell-size' would decline to
           ;; guess a cell and nothing would take the bitmap path at all -- see
           ;; there.  A buffer-local size is what it asks for, and 10x20 is the
           ;; one every other batch fixture uses.
           (setq cooked--last-cell '(10 . 20))
           ,@body)
       (with-current-buffer buffer (cooked--cleanup))
       (kill-buffer buffer))))

(defun cooked-bench--record (label seconds &optional detail)
  (push (list label seconds detail) cooked-bench-results)
  (message "  %-42s %8.1f ms   %s" label (* 1000 seconds) (or detail "")))

(defun cooked-bench--drain-until-exit (label &optional seconds)
  "Pump ARGV's session to completion, timing only drain and apply.

The child runs on its own while we wait in `accept-process-output', so the
elapsed time of the whole loop is mostly the child's.  Only the work Emacs does
per wakeup is accumulated, which is the number this file exists to produce."
  (let ((deadline (+ (float-time) (or seconds 30)))
        (spent 0.0)
        (drains 0))
    (while (and cooked--session (< (float-time) deadline) (null cooked--exit))
      (accept-process-output nil 0.02)
      (when cooked--session
        (let ((t0 (float-time)))
          (cooked--apply (cooked--drain cooked--session cooked-rejoin-wrapped-lines))
          (setq spent (+ spent (- (float-time) t0))
                drains (1+ drains)))))
    (cooked-bench--record label spent
                          (format "%d drains, %d buffer chars" drains (buffer-size)))
    spent))

(defun cooked-bench-flood ()
  "Plain output scrolling into the buffer: the `cat a big file' case."
  (cooked-bench--with-session
      '("/bin/sh" "-c" "i=0; while [ $i -lt 20000 ]; do \
echo \"line $i the quick brown fox jumps over the lazy dog\"; i=$((i+1)); done")
    (cooked-bench--drain-until-exit "flood, 20k plain lines")))

(defun cooked-bench-styled ()
  "Heavily coloured output: the `ls --color' / build-log case.

This is the one the face cache is for — every line carries several styled runs,
so it is the shape that turns a per-run cost into a visible one."
  (cooked-bench--with-session
      '("/bin/sh" "-c" "i=0; while [ $i -lt 20000 ]; do \
printf '\\033[1;32mword\\033[0m \\033[38;2;10;20;30mrgb\\033[0m plain %s\\n' $i; \
i=$((i+1)); done")
    (cooked-bench--drain-until-exit "flood, 20k styled lines")))

(defun cooked-bench-repaint ()
  "Full-screen repaint over the alternate screen: the `htop' case.

Nothing scrolls, so this isolates the damaged-row path — every frame rewrites
every row in place and the buffer never grows."
  (cooked-bench--with-session
      '("/bin/sh" "-c" "printf '\\033[?1049h'; f=0; while [ $f -lt 400 ]; do \
r=1; while [ $r -le 24 ]; do printf '\\033[%s;1H\\033[4%sm' $r $((f%8)); \
printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; r=$((r+1)); done; \
f=$((f+1)); done; printf '\\033[?1049l'")
    (cooked-bench--drain-until-exit "repaint, 400 frames x 24 rows")))

(defun cooked-bench-box-drawing ()
  "A repaint made of box-drawing characters, which take the bitmap path.

The reason this is separate from `cooked-bench-repaint': every cell here gets a
`display' property and an image spec of its own, so it is the workload that
tells you whether `cooked--box-image-cache' is earning its keep.  Compare the
two figures — the gap is what box drawing costs over plain text."
  (cooked-bench--with-session
      '("/bin/sh" "-c" "printf '\\033[?1049h'; f=0; while [ $f -lt 400 ]; do \
r=1; while [ $r -le 24 ]; do printf '\\033[%s;1H' $r; \
printf '\\342\\224\\200%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; \
r=$((r+1)); done; f=$((f+1)); done; printf '\\033[?1049l'")
    (cooked-bench--drain-until-exit "repaint, 400 frames of box drawing")))

(defun cooked-bench-marshalling ()
  "Cost of `cooked--drain' alone, with nothing applied to the buffer.

Isolates the module boundary: the same delta is built and converted to Lisp,
but never rendered.  Subtract this from the figures above to see how much of a
drain is marshalling rather than redisplay."
  (cooked-bench--with-session
      '("/bin/sh" "-c" "i=0; while [ $i -lt 20000 ]; do \
echo \"line $i the quick brown fox jumps over the lazy dog\"; i=$((i+1)); done")
    (let ((deadline (+ (float-time) 30))
          (spent 0.0)
          (drains 0))
      (while (and cooked--session (< (float-time) deadline)
                  (null (plist-get (cooked--drain cooked--session) :exit)))
        (accept-process-output nil 0.02)
        (when cooked--session
          (let ((t0 (float-time)))
            (cooked--drain cooked--session cooked-rejoin-wrapped-lines)
            (setq spent (+ spent (- (float-time) t0))
                  drains (1+ drains)))))
      (cooked-bench--record "drain only, 20k plain lines" spent
                            (format "%d drains, nothing rendered" drains)))))

;;;; Per-frame rendering, driven synthetically
;;
;; The benchmarks above are honest about a real session and therefore say very
;; little about per-frame cost: damage coalescing means 400 frames of repaint
;; reach Emacs as four drains, and the 396 that were superseded are never
;; rendered at all.  That is the design working, but it is not the number you
;; want when the child paints at a rate Emacs *can* keep up with — htop at 1Hz
;; renders every frame, and then the per-frame cost is the whole story.
;;
;; So these hand `cooked--apply' the same plist shape the module produces, one
;; frame at a time, against a child that is asleep and sending nothing.  No
;; scheduling noise, no coalescing, and reproducible run to run.

(defun cooked-bench--update (rows &optional alt)
  "An update plist of ROWS, shaped exactly as `cooked--drain' returns one.

`:height', `:used' and `:head' are not optional: `cooked--apply' builds a
`cooked-grid' from them and `cooked--fit-screen' does arithmetic on it, so a
plist without them fails on a nil rather than benchmarking anything.  They were
missing here from the moment the drain grew them, which is how
`cooked-bench-per-frame' came to error out instead of reporting."
  (let ((height (length rows)))
    (list :scrolled nil :rows rows
          :height height :used height :head 0
          :cursor '(0 0 t block) :alt alt
          :app-cursor nil :keys 'legacy :mode 'raw :events nil :exit nil)))

(defun cooked-bench--plain-rows (count cols)
  "COUNT damaged rows of unstyled text, the cheapest thing to render.

A row is (INDEX . BLOCK), and a block is (TEXT STYLE-SPANS DECO-SPANS LINK-SPANS)
with
offsets in characters -- see `cooked--render-block'.  Unstyled text carries
no span list at all, which is the case the sparse shape is built around."
  (let ((text (make-string cols ?x)))
    (cl-loop for i below count collect (cons i (list text nil nil nil)))))

(defun cooked-bench--styled-rows (count cols)
  "COUNT damaged rows split into eight differently-styled spans."
  (let ((width (/ cols 8)))
    (cl-loop for i below count
             collect (cons i (list (make-string (* 8 width) ?x)
                                   (cl-loop for r below 8
                                            collect (list (* r width)
                                                          (* (1+ r) width)
                                                          (mod (+ i r) 8) nil
                                                          (if (cl-evenp r) 1 0) nil))
                                   nil nil)))))

(defun cooked-bench--box-rows (count cols)
  "COUNT damaged rows of box drawing, every cell taking the bitmap path.

The decoration is `(glyph . PACKED)\=' as the module hands it over, PACKED being
two little-endian bytes per character.  0x0050 is a plain light horizontal —
left and right edges at weight 1 — which is what a border is made of."
  (let* ((text (make-string cols ?─))
         (deco (cons 'glyph (apply #'unibyte-string
                                   (cl-loop repeat cols append (list #x50 #x00)))))
         (spans (list (list 0 deco))))
    (cl-loop for i below count collect (cons i (list text nil spans)))))

(defun cooked-bench--frames (label rows frames)
  "Apply ROWS as a damaged-row update FRAMES times, timing the lot."
  (cooked-bench--with-session '("/bin/sh" "-c" "sleep 300")
    (cooked-tests--settle-briefly)
    (let ((update (cooked-bench--update rows t))
          (t0 (float-time)))
      (dotimes (_ frames) (cooked--apply update))
      (cooked-bench--record
       label (- (float-time) t0)
       (format "%d frames x %d rows, %.2f ms/frame"
               frames (length rows)
               (/ (* 1000 (- (float-time) t0)) frames))))))

(defun cooked-tests--settle-briefly ()
  "Let the child start and the first drain land."
  (dotimes (_ 5) (accept-process-output nil 0.02))
  (when cooked--session
    (cooked--apply (cooked--drain cooked--session cooked-rejoin-wrapped-lines))))

(defun cooked-bench-per-frame ()
  "Per-frame render cost by run shape, with coalescing taken out of the picture."
  (cooked-bench--frames "per-frame, 24x80 plain"
                        (cooked-bench--plain-rows 24 80) 200)
  (cooked-bench--frames "per-frame, 24x80 styled (8 runs/row)"
                        (cooked-bench--styled-rows 24 80) 200)
  (cooked-bench--frames "per-frame, 24x80 box drawing"
                        (cooked-bench--box-rows 24 80) 200))

(defun cooked-bench-rescale ()
  "Cost of `cooked--rescale-deco\=', the walk a cell-size change runs.

The one thing in cooked that rewrites decoration already in the scrollback, and
so the only thing that can bring a transcript back into agreement with the font.
It is a whole-buffer walk under `widen\=', paid per cell-size change -- a font
change, a `text-scale-adjust\=', a frame dragged to a different-DPI monitor --
and never per drain, which is what `cooked--sync-size\=''s gate is for.  What it
scales with is the length of the transcript, so the figure to watch is the
per-row one.

The transcript is grown by copying rendered text, properties and all, rather
than by driving forty thousand cells through the module: what is under test here
is the walk, and the walk reads nothing but the `cooked-deco\=' property."
  (cooked-bench--with-session '("/bin/sh" "-c" "sleep 300")
    (cooked-tests--settle-briefly)
    (cooked--apply (cooked-bench--update (cooked-bench--box-rows 24 80)))
    (let ((inhibit-read-only t)
          (buffer-undo-list t)
          (chunk (buffer-substring (point-min) (point-max))))
      (goto-char (point-max))
      (dotimes (_ 40) (insert chunk)))
    (dolist (cell '((12 . 26) (10 . 20)))
      (setq cooked--last-cell cell)
      (let ((t0 (float-time)))
        (cooked--rescale-deco)
        (let ((elapsed (- (float-time) t0)))
          (cooked-bench--record
           (format "rescale-deco, %d rows of box drawing"
                   (count-lines (point-min) (point-max)))
           elapsed
           (format "%d cells, %.4f ms/row"
                   (buffer-size)
                   (/ (* 1000 elapsed)
                      (max 1 (count-lines (point-min) (point-max)))))))))
    ;; The gate the whole design rests on: asked for a size it is already at, it
    ;; does not walk anything.
    (let ((t0 (float-time)))
      (cooked--rescale-deco)
      (cooked-bench--record "rescale-deco, cell unchanged" (- (float-time) t0)
                            "the gate `cooked--sync-size' relies on"))))

(defun cooked-bench--report ()
  (message "\n%-42s %11s" "total" "")
  (message "  %-40s %8.1f ms"
           "all benchmarks"
           (* 1000 (apply #'+ (mapcar #'cadr cooked-bench-results)))))

(defun cooked-bench ()
  "Run every benchmark in this file."
  (setq cooked-bench-results nil)
  (message "cooked: Emacs-side cost per workload (drain + apply only)\n")
  (cooked-bench-marshalling)
  (cooked-bench-flood)
  (cooked-bench-styled)
  (cooked-bench-repaint)
  (cooked-bench-box-drawing)
  (message "")
  (cooked-bench-per-frame)
  (message "")
  (cooked-bench-rescale)
  (cooked-bench--report))

(provide 'cooked-bench)
;;; cooked-bench.el ends here
