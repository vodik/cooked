;;; bench-scroll-ceiling.el --- rejoin on vs off, in a real frame  -*- lexical-binding: t; -*-

;; PLAN.org Wave 0, "Measure the scroll ceiling with rejoining off".
;;
;; Not part of `make bench'.  This needs a real graphical frame -- batch mode
;; measures spec construction and property application, never rasterization --
;; and it takes minutes.  Run it the way PLAN.org's "Measuring in a real
;; graphical frame" says:
;;
;;     gamescope --backend headless -W 1920 -H 1080 -r 1000 --expose-wayland -- \
;;       emacs -Q -l scripts/bench-scroll-ceiling.el
;;
;; `-r 1000' is not decoration.  At gamescope's default the compositor's frame
;; callback becomes the thing being measured: every `max' pins to ~33 ms and p90
;; runs three times p50, whatever the code does.  Raising the rate moves the tail
;; and leaves the median alone, which is the evidence that the median is the only
;; statistic here worth reading.
;;
;; Results are written to COOKED_CEILING_OUT (default /tmp/cooked-ceiling.out),
;; because nothing printed to stdout survives the compositor's own logging.

(setq debug-on-error t)

;; Resolved from this file so the script runs from any directory.
(let ((root (file-name-directory
             (directory-file-name
              (file-name-directory (or load-file-name buffer-file-name))))))
  (add-to-list 'load-path (expand-file-name "lisp" root)))
(require 'cooked)
(require 'cooked-mode)

(defconst ceil--out (or (getenv "COOKED_CEILING_OUT") "/tmp/cooked-ceiling.out"))

(defconst ceil--awk-program "\
BEGIN { L = \"\"; for (i = 0; i < WIDTH; i++) L = L substr(CHARS, (i % length(CHARS)) + 1, 1) }
{ for (i = 0; i < 10; i++) printf \"%s%04d\\r\\n\", substr(L, 1, WIDTH - 4), NR
  fflush() }
"
  "Ten lines of WIDTH columns per line read on stdin, so the burst is on demand.

Bursting on demand rather than flooding is what makes a per-scroll figure
possible at all: the pump below can charge Emacs' own work and nothing else,
where a flood would interleave the child's writes with the measurement.")

(defconst ceil--awk
  (let ((f (make-temp-file "cooked-burst" nil ".awk" ceil--awk-program))) f))

(defvar ceil--log nil)
(setq gc-cons-threshold (* 512 1024 1024) gc-cons-percentage 0.8)

(defun ceil--pct (sorted p)
  (nth (min (1- (length sorted))
            (floor (* p (length sorted))))
       sorted))

(defun ceil--report (label samples extra)
  (let* ((s (sort (copy-sequence samples) #'<))
         (n (length s))
         (mean (/ (apply #'+ s) (float n))))
    (push (format "%-38s n=%3d  p50=%7.3f  p90=%7.3f  p99=%7.3f  max=%8.3f  mean=%7.3f  %s"
                  label n (ceil--pct s 0.50) (ceil--pct s 0.90)
                  (ceil--pct s 0.99) (car (last s)) mean extra)
          ceil--log)))

(defun ceil--run (label rejoin width bursts warmup)
  "Time BURSTS ten-line scrolls at WIDTH columns of content, REJOIN in force."
  (let* ((cooked-rejoin-wrapped-lines rejoin)
         (buffer (generate-new-buffer (format "*ceil %s*" label)))
         (applies nil)
         (redisplays nil)
         (drains 0))
    (unwind-protect
        (with-current-buffer buffer
          (cooked-mode)
          ;; The window is the whole point: bottom anchoring, sticky scroll and
          ;; `cooked--guard-row-width' all short-circuit without one.
          (set-window-buffer (selected-window) buffer)
          ;; `stty raw' so the tty adds no translation of its own; the awk program
          ;; therefore has to write CR LF itself.
          (cooked--start
           (list "/bin/sh" "-c"
                 (format "stty raw -echo; exec awk -v WIDTH=%d -v CHARS=abcdefghijklmnopqrstuvwxyz0123456789 -f %s"
                         width (shell-quote-argument ceil--awk))))
          (cooked--refresh-keymap)
          (dotimes (_ 10) (accept-process-output nil 0.05)
            (when cooked--session
              (cooked--apply (cooked--drain cooked--session rejoin))))
          (redisplay t)
          (dotimes (i (+ warmup bursts))
            (let ((tick (buffer-chars-modified-tick))
                  (apply-ms 0.0)
                  (redisplay-ms 0.0)
                  (deadline (+ (float-time) 2.0)))
              (cooked--send-to-child "\n")
              ;; Pump until the burst has landed and been drawn, charging only
              ;; the work Emacs does -- never the wait on the child.  The two
              ;; halves are kept apart because only the first is cooked's: the
              ;; `redisplay' figure carries gamescope's frame callback, which is
              ;; why its tail pins to a refresh quantum no matter what the code
              ;; does.
              (let ((quiet 0))
                (while (and (< (float-time) deadline) (< quiet 3))
                  (accept-process-output nil 0.005)
                  (let ((t0 (float-time)))
                    (when cooked--session
                      (cooked--apply (cooked--drain cooked--session rejoin))
                      (setq drains (1+ drains)))
                    (let ((t1 (float-time)))
                      (redisplay t)
                      (setq apply-ms (+ apply-ms (- t1 t0))
                            redisplay-ms (+ redisplay-ms (- (float-time) t1)))))
                  (if (= tick (buffer-chars-modified-tick))
                      (setq quiet (1+ quiet))
                    (setq quiet 0 tick (buffer-chars-modified-tick)))))
              (when (>= i warmup)
                (push (* 1000 apply-ms) applies)
                (push (* 1000 redisplay-ms) redisplays))))
          (ceil--report (concat label "  [apply]") applies
                        (format "%dx%d term, %d cols content, %d chars, %d drains"
                                cooked--rows cooked--cols width (buffer-size) drains))
          (ceil--report (concat label "  [redisplay]") redisplays ""))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer))))

;; A tty frame is the terminal, so there is nothing to resize -- size the
;; emulator instead (foot -W 100x32).  Sizing it here anyway would ask Emacs to
;; resize a terminal it does not own, and the numbers would be taken at a size
;; the report then misstates.
(when (display-graphic-p)
  (set-frame-size (selected-frame)
                  (string-to-number (or (getenv "COOKED_CEILING_COLS") "100"))
                  (string-to-number (or (getenv "COOKED_CEILING_ROWS") "32"))))
(redisplay t)

(let ((cols (window-body-width))
      (rows (window-body-height)))
  (push (format "frame %dx%d chars, window %dx%d, framep=%s graphic=%s"
                (frame-width) (frame-height) cols rows
                (framep (selected-frame))
                (display-graphic-p))
        ceil--log)
  ;; Control: nothing wraps, so rejoining has nothing to do and the two rows
  ;; should agree.  If they do not, the harness is measuring something else.
  (ceil--run "short lines, rejoin=t"  t   (- cols 6) 200 30)
  (ceil--run "short lines, rejoin=nil" nil (- cols 6) 200 30)
  ;; The case the flag is about: each logical line is three screen rows, so
  ;; rejoin=t produces long buffer lines and forces `truncate-lines' nil.
  (ceil--run "3x-wrapped, rejoin=t"   t   (* 3 cols) 200 30)
  (ceil--run "3x-wrapped, rejoin=nil" nil (* 3 cols) 200 30)
  ;; Ten screen rows per logical line: Emacs' long-line paths in earnest.
  (ceil--run "10x-wrapped, rejoin=t"  t   (* 10 cols) 200 30)
  (ceil--run "10x-wrapped, rejoin=nil" nil (* 10 cols) 200 30))

(with-temp-file ceil--out
  (insert (format "load-average %s\n" (load-average))
          (mapconcat #'identity (nreverse ceil--log) "\n") "\n"))
(kill-emacs 0)
