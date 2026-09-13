;;; bench-tree.el --- `tree' in a large directory, in a real frame  -*- lexical-binding: t; -*-

;; PLAN.org Wave 0, "Why `tree' in a large directory is slow".
;;
;; The workload a user reported and nobody had reproduced: `tree' over a
;; directory with tens of thousands of entries.  It is unlike every fixture in
;; `tests/cooked-bench.el' in four ways at once -- box drawing on every row,
;; non-uniform rows (the indent is U+2502 and U+00A0, neither of them one byte),
;; an SGR pair around every filename, and thirty thousand rows arriving as fast
;; as the pipe will carry them.
;;
;; Run it the way PLAN.org's "Measuring in a real graphical frame" says:
;;
;;     gamescope --backend headless -W 1920 -H 1080 -r 1000 --expose-wayland -- \
;;       emacs -Q -l scripts/bench-tree.el
;;
;; and `emacs -nw' under foot as the tty control.  It also runs in batch, where
;; the arms still separate -- the guard's per-cell walk runs on a terminal frame
;; too -- but nothing is rasterized, so batch is for iterating and the frame is
;; for the number you quote.
;;
;; Results go to COOKED_TREE_OUT (default /tmp/cooked-tree.out): nothing printed
;; to stdout survives gamescope's own logging.
;;
;; COOKED_TREE_DIR picks the directory (default /usr/include, ~30k entries) and
;; COOKED_TREE_REPS how many times each arm runs (default 3, medians quoted).

(setq debug-on-error t)

(let ((root (file-name-directory
             (directory-file-name
              (file-name-directory (or load-file-name buffer-file-name))))))
  (add-to-list 'load-path (expand-file-name "lisp" root)))
(require 'cooked)
(require 'cooked-mode)
(require 'cooked-link)

(defconst tree--out (or (getenv "COOKED_TREE_OUT") "/tmp/cooked-tree.out"))
(defconst tree--dir (or (getenv "COOKED_TREE_DIR") "/usr/include"))
(defconst tree--reps (string-to-number (or (getenv "COOKED_TREE_REPS") "3")))

(defvar tree--log nil)

;; The same session-wide pin `bench-scroll-ceiling.el' takes, and for the same
;; reason: a collection landing inside a timed drain is noise about the heap
;; rather than signal about the guard.  Collections are counted and reported
;; instead, so a run that gets slower by collecting more still says so.
(setq gc-cons-threshold (* 512 1024 1024) gc-cons-percentage 0.8)

(defun tree--median (samples)
  (let ((s (sort (copy-sequence samples) #'<)))
    (nth (/ (length s) 2) s)))

(defun tree--say (fmt &rest args)
  (push (apply #'format fmt args) tree--log))

;;;; One arm

(defvar tree--apply-s 0.0)
(defvar tree--drains 0)

(defun tree--charge (fn &rest args)
  "Advice around `cooked--drain-and-apply' that charges it to `tree--apply-s'."
  (let ((t0 (float-time)))
    (prog1 (apply fn args)
      (setq tree--apply-s (+ tree--apply-s (- (float-time) t0))
            tree--drains (1+ tree--drains)))))

(defun tree--run (label &rest bindings)
  "Run `tree' over `tree--dir' once per rep with BINDINGS in force.

BINDINGS is a plist of symbol/value pairs bound around the whole session, so an
arm is named by what it turns off and the difference against the baseline is
that one thing.

The pump is deliberately *not* the `accept-process-output' loop the other bench
scripts use, and that is the correction this file exists to make.  Draining in a
tight loop of our own hands the module a whole flood at once: the core coalesces
it, four enormous deltas come out, and the run finishes in a third of a second
while a real session is still drawing.  A real session is driven by the wake
pipe, which Rust rate-limits to `cooked-min-redisplay-interval' and
`cooked-backlog-limit' -- so the same output arrives as *hundreds* of drains,
each one followed by a real redisplay, and the per-drain fixed costs are paid
hundreds of times instead of four.  That ratio is the whole question here, so
the pump is `sit-for', which does nothing but let Emacs' own event loop run.

APPLY is charged inside `cooked--drain-and-apply' by advice, so it is all and
only cooked's Lisp.  WALL is the whole session including the child's own work,
which is the number the user was complaining about; WALL minus APPLY is
redisplay plus the child plus every wait on either."
  (let ((walls nil) (applies nil) (chars nil) (drains nil) (gcs nil))
    (dotimes (_ tree--reps)
      (let ((buffer (generate-new-buffer (format "*tree %s*" label))))
        (unwind-protect
            (with-current-buffer buffer
              (cl-progv (cl-loop for (k _) on bindings by #'cddr collect k)
                  (cl-loop for (_ v) on bindings by #'cddr collect v)
                (cooked-mode)
                ;; The window is load-bearing, not decoration:
                ;; `cooked--layout-window' answers nil without one and
                ;; `cooked--guard-row-width' -- the whole suspect -- skips every
                ;; row.  Same reason as `cooked-bench--with-session'.
                (set-window-buffer (selected-window) buffer)
                (setq tree--apply-s 0.0 tree--drains 0)
                (advice-add 'cooked--drain-and-apply :around #'tree--charge)
                (unwind-protect
                    (let ((gc0 gcs-done) (t-wall (float-time))
                          (deadline (+ (float-time) 300)))
                      (cooked--start
                       (list "/bin/sh" "-c"
                             (format "exec tree -C %s"
                                     (shell-quote-argument tree--dir))))
                      (cooked--refresh-keymap)
                      (while (and cooked--session (null cooked--exit)
                                  (< (float-time) deadline))
                        (sit-for 0.01))
                      (push (* 1000 (- (float-time) t-wall)) walls)
                      (push (* 1000 tree--apply-s) applies)
                      (push (buffer-size) chars)
                      (push tree--drains drains)
                      (push (- gcs-done gc0) gcs))
                  (advice-remove 'cooked--drain-and-apply #'tree--charge))))
          (with-current-buffer buffer (cooked--cleanup))
          (kill-buffer buffer))))
    (tree--say "%-34s wall=%8.1f  apply=%8.1f  drains=%5d  %6.3f ms/drain  gc=%3d  %d chars"
               label (tree--median walls) (tree--median applies)
               (tree--median drains)
               (/ (tree--median applies) (max 1 (tree--median drains)))
               (tree--median gcs) (tree--median chars))))

;;;; The arms
;;
;; Each one turns off exactly one thing, so the difference against the baseline
;; is that thing's cost and nothing else.  `all off' is the floor: what the same
;; thirty thousand rows cost with every cosmetic pass disabled.

(when (display-graphic-p)
  (set-frame-size (selected-frame)
                  (string-to-number (or (getenv "COOKED_TREE_COLS") "100"))
                  (string-to-number (or (getenv "COOKED_TREE_ROWS") "32"))))
(redisplay t)

(tree--say "load-average %s" (load-average))
(tree--say "frame %dx%d chars, window %dx%d, framep=%s graphic=%s, dir=%s"
           (frame-width) (frame-height)
           (window-body-width) (window-body-height)
           (framep (selected-frame)) (display-graphic-p) tree--dir)

(tree--run "baseline")
;; The standing suspect: a `tree' row is non-uniform, so it fails step 1 of
;; `cooked--guard-row-width' and reaches `cooked--scale-offenders''s per-cell
;; walk on every row.  nil disables that walk entirely.
(tree--run "glyph-scale-floor nil" 'cooked-glyph-scale-floor nil)
;; The URL scan over rows that are almost entirely punctuation.
(tree--run "detect-links nil" 'cooked-detect-links nil)
;; Rejoining decides whether the guard runs at all, and whether long lines exist.
(tree--run "rejoin nil" 'cooked-rejoin-wrapped-lines nil)
;; Scrollback trimming, which at 30k rows over a 10k limit runs constantly.
(tree--run "scrollback 100000" 'cooked-scrollback-lines 100000)
(tree--run "all off"
           'cooked-glyph-scale-floor nil 'cooked-detect-links nil
           'cooked-scrollback-lines 100000)


;;;; The gesture arms
;;
;; Arrival and scrollback are different questions and the arms above only answer
;; the first.  What a user feels scrolling *back* through settled `tree' output
;; is redisplay laying rows out again, and the passes that cost there are not
;; the passes that cost on the drain path.
;;
;; The child must stay alive for this to measure anything real.
;; `cooked--fontify-region' declines outright once `cooked--session' is nil, so
;; scrolling a buffer whose child has exited silently skips the link scan and
;; reports a clean bill of health -- the trap that made the first attempt at
;; this measure zero scans.  So the child is `tree' followed by `sleep', and the
;; settle test is the buffer size holding still rather than the process exiting.

(defvar tree--gesture-log nil)

(defun tree--pct (sorted p)
  (nth (min (1- (length sorted))
            (floor (* p (length sorted))))
       sorted))

(defun tree--gesture (label &rest bindings)
  "Scroll back through settled `tree' output with BINDINGS in force.

Timed per gesture around `scroll-down' plus a forced `redisplay', which is the
whole of what the viewport moving costs -- nothing drains while this runs."
  (let ((p50s nil) (p90s nil))
    (dotimes (_ tree--reps)
      (let ((buffer (generate-new-buffer (format "*tree-gesture %s*" label))))
        (unwind-protect
            (with-current-buffer buffer
              (cl-progv (cl-loop for (k _) on bindings by #'cddr collect k)
                  (cl-loop for (_ v) on bindings by #'cddr collect v)
                (cooked-mode)
                (set-window-buffer (selected-window) buffer)
                (cooked--start
                 (list "/bin/sh" "-c"
                       (format "tree -C %s; exec sleep 3600"
                               (shell-quote-argument tree--dir))))
                (cooked--refresh-keymap)
                ;; Settled = three consecutive polls at the same size.
                (let ((last -1) (still 0) (deadline (+ (float-time) 300)))
                  (while (and (< still 3) (< (float-time) deadline))
                    (sit-for 0.2)
                    (if (= (buffer-size) last)
                        (setq still (1+ still))
                      (setq still 0 last (buffer-size)))))
                (goto-char (point-max))
                (redisplay t)
                (let ((samples nil))
                  ;; Warmups discarded: the first gestures fault in fonts and
                  ;; fill every cache the later ones then hit.
                  (dotimes (_ 20) (ignore-errors (scroll-down 10)) (redisplay t))
                  (dotimes (_ 60)
                    (let ((t0 (float-time)))
                      (ignore-errors (scroll-down 10))
                      (redisplay t)
                      (push (* 1000 (- (float-time) t0)) samples)))
                  (let ((sorted (sort samples #'<)))
                    (push (tree--pct sorted 0.50) p50s)
                    (push (tree--pct sorted 0.90) p90s)))))
          (with-current-buffer buffer (cooked--cleanup))
          (kill-buffer buffer))))
    (tree--say "GESTURE %-28s p50=%7.3f  p90=%7.3f"
               label (tree--median p50s) (tree--median p90s))))

(tree--gesture "baseline")
;; The suspect this section exists for: every box glyph in a `tree' row is a run
;; of one, so the run-wide image coalescing has nothing to coalesce and each one
;; costs its own `display' interval at every redisplay.
(tree--gesture "box-drawing-images nil" 'cooked-box-drawing-images nil)
;; Measured at 21% of a scroll gesture while attributing the arrival slowness.
(tree--gesture "detect-links nil" 'cooked-detect-links nil)
(tree--gesture "glyph-scale-floor nil" 'cooked-glyph-scale-floor nil)
(tree--gesture "all off"
               'cooked-box-drawing-images nil 'cooked-detect-links nil
               'cooked-glyph-scale-floor nil)

(with-temp-file tree--out
  (insert (mapconcat #'identity (nreverse tree--log) "\n") "\n"))
(when noninteractive (princ (format "wrote %s\n" tree--out)))
(kill-emacs 0)
