;;; bench-hover-motion.el --- typing latency with hover motion on, in a real frame  -*- lexical-binding: t; -*-

;; TERM.org, "Hover motion (mode 1003 with no button held)": measure before
;; deciding the default of `cooked-mouse-hover-motion'.
;;
;; The worry is not the reports -- there is one per cell crossed -- but that
;; turning the option on leaves `track-mouse' on in the terminal for as long as
;; the child wants any-motion, and every `mouse-movement' event Emacs then makes
;; is a whole turn of the command loop.  So the keystroke here goes through the
;; command loop too, by `execute-kbd-macro', rather than straight to
;; `cooked--send-to-child' the way bench-typing-latency.el sends it: a key that
;; skipped `read-key-sequence' and the hooks would skip exactly the part the
;; option can change.  Otherwise it is that script's measurement, send to
;; drawn, and its numbers are comparable to its `plain' row only loosely.
;;
;; Three configurations, against a child on the alternate screen that asked for
;; 1003 and SGR:
;;
;;   off     the option nil, so `track-mouse' stays nil
;;   rest    the option t and the pointer at rest: no motion events at all,
;;           which is what a pointer resting over the window produces
;;   moving  the option t and four motion events ahead of every keystroke, each
;;           into a different cell, so every one is a report the child is sent
;;
;; `rest' against `off' is the figure TERM.org asks for.  `moving' is the bound
;; on what a user sweeping the pointer while typing pays, since a real pointer
;; cannot be driven headlessly; the events are synthesised from `posn-at-point'
;; and dispatched through the same keymap lookup a real one would be.
;;
;;     gamescope --backend headless -W 1920 -H 1080 -r 1000 --expose-wayland -- \
;;       emacs -Q -l scripts/bench-hover-motion.el
;;
;; Results go to COOKED_HOVER_OUT (default /tmp/cooked-hover.out).

(setq debug-on-error t)

;; Compiled, and refused on a busy machine: see bench-prelude.el.  Nothing below
;; the `cooked-bench-script-start' call runs interpreted.
(eval-and-compile
  (unless (featurep 'bench-prelude)
    (load (expand-file-name "bench-prelude"
                            (file-name-directory
                             (or load-file-name
                                 (bound-and-true-p byte-compile-current-file))))
          nil t)))
(defconst hover--out (or (getenv "COOKED_HOVER_OUT") "/tmp/cooked-hover.out"))
(cooked-bench-script-start hover--out)
(require 'cooked)
(require 'cooked-mode)


(defvar hover--log nil)

;; Pinned for the run, for bench-typing-latency.el's reason.
(setq gc-cons-threshold (* 512 1024 1024) gc-cons-percentage 0.8)

(defun hover--pct (sorted p)
  (nth (min (1- (length sorted)) (floor (* p (length sorted)))) sorted))

(defun hover--report (label samples extra)
  (let ((s (sort (copy-sequence samples) #'<)))
    (push (format "%-8s n=%4d  min=%7.3f  p50=%7.3f  p99=%7.3f  max=%7.3f  %s"
                  label (length s) (car s) (hover--pct s 0.50) (hover--pct s 0.99)
                  (car (last s)) extra)
          hover--log)))

(defun hover--pump ()
  (accept-process-output nil 0.001)
  (when cooked--session
    (cooked--apply (cooked--drain cooked--session cooked-rejoin-wrapped-lines))))

(defun hover--run (kind keystrokes warmup)
  "Time KEYSTROKES keystrokes through the command loop, configured as KIND."
  (let ((buffer (generate-new-buffer (format "*hover %s*" kind)))
        (samples nil)
        (reports 0))
    (unwind-protect
        (with-current-buffer buffer
          (cooked-mode)
          (set-window-buffer (selected-window) buffer)
          (cooked--start
           '("/bin/sh" "-c"
             "stty raw -echo; printf '\\033[?1049h\\033[?1003h\\033[?1006hREADY'; exec cat"))
          (cooked--refresh-keymap)
          (let ((deadline (+ (float-time) 5)))
            (while (and (< (float-time) deadline)
                        (not (and (string-search "READY" (buffer-string))
                                  (cooked-mouse-state-motion cooked--mouse-state))))
              (hover--pump)))
          (setq cooked-mouse-hover-motion (not (eq kind 'off)))
          (cooked--update-mouse-grab)
          (redisplay t)
          (let ((posns (list (posn-at-point (point-min))
                             (posn-at-point (1+ (point-min)))))
                (advice (lambda (string)
                          (when (string-search "[<35;" string)
                            (setq reports (1+ reports))))))
            (advice-add 'cooked--send-to-child :before advice)
            (unwind-protect
                (dotimes (i (+ warmup keystrokes))
                  (let ((keys (vconcat
                               (and (eq kind 'moving)
                                    (mapcar (lambda (n)
                                              (list 'mouse-movement
                                                    (nth (% (+ i n) 2) posns)))
                                            '(0 1 0 1)))
                               [?x]))
                        (tick (buffer-chars-modified-tick))
                        (deadline (+ (float-time) 2))
                        (t0 (float-time)))
                    (execute-kbd-macro keys)
                    (while (and (< (float-time) deadline)
                                (= tick (buffer-chars-modified-tick)))
                      (hover--pump))
                    (redisplay t)
                    (when (>= i warmup)
                      (push (* 1000 (- (float-time) t0)) samples))))
              (advice-remove 'cooked--send-to-child advice)))
          (hover--report
           (symbol-name kind) samples
           (format "track-mouse=%s local=%s hover-reports=%d %dx%d term"
                   track-mouse (local-variable-p 'track-mouse) reports
                   cooked--rows cooked--cols)))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer))))

(when (display-graphic-p)
  (set-frame-size (selected-frame) 100 32))
(redisplay t)

(push (cooked-bench-script-provenance) hover--log)
(push (format "frame %dx%d, framep=%s graphic=%s, load %s"
              (frame-width) (frame-height) (framep (selected-frame))
              (display-graphic-p) (load-average t))
      hover--log)

(dolist (kind '(off rest moving off rest moving))
  (hover--run kind 200 30))

(push (format "load after %s" (load-average t)) hover--log)

(with-temp-file hover--out
  (insert (mapconcat #'identity (nreverse hover--log) "\n") "\n"))
(kill-emacs 0)
