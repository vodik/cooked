;;; bench-typing-latency.el --- send-to-drawn, in a real frame  -*- lexical-binding: t; -*-

;; PLAN.org Wave 0, "Typing latency benchmark, three configurations".
;;
;; The number this produces is *send to drawn*, not send to filter-fired, and that
;; distinction is the whole reason it is a separate script.  Each sample is the
;; round trip a keystroke actually makes: write to the pty, the child echoes, the
;; core wakes Emacs, the wake filter drains and applies, and Emacs paints.  A harness
;; that stopped at the process filter would report cooked's cheapest half and miss
;; the half REPORT.org §7 blames.
;;
;; The harness only waits.  Arrival is whatever the wake filter does inside
;; `accept-process-output', paced by the core's throttle and quiescence hold, which
;; is ghostel's `tap' shape.  It used to drain and apply for itself between waits,
;; so it raced the paced path with an unpaced one and could not see a pacing change
;; at all: whichever of the two took the bytes first won.
;;
;; Three figures per configuration.  `drawn' is send to painted.  `applied' is send
;; to the buffer changing, which is the core, the pacer and the filter.  `redisplay'
;; is the `(redisplay t)' that follows alone, which is the part a decorated buffer
;; can make dearer without cooked doing any more work.  A keystroke whose echo has
;; not arrived after 2 s is counted as a timeout and kept out of all three.
;;
;; Run it the way PLAN.org's "Measuring in a real graphical frame" says:
;;
;;     gamescope --backend headless -W 1920 -H 1080 -r 1000 --expose-wayland -- \
;;       emacs -Q -l scripts/bench-typing-latency.el
;;
;; and on a tty as the control, for example under `script', which gives Emacs a
;; pty and discards what it draws:
;;
;;     script -qfc 'stty rows 66 cols 115; emacs -nw -Q -l scripts/bench-typing-latency.el' /dev/null
;;
;; pgtk is among the slowest Emacs redraw backends, so a pgtk figure is an upper bound
;; and a tty one says how much of it is the backend.  Results go to
;; COOKED_LATENCY_OUT (default /tmp/cooked-latency.out), because nothing printed to
;; stdout survives the compositor's own logging.  COOKED_LATENCY_N sets the
;; keystrokes per configuration, 1000 by default, where the nearest-rank p99 is the
;; tenth-largest sample rather than the second.
;;
;; Keystrokes are COOKED_LATENCY_GAP seconds apart, 0.03 by default, waited out in
;; `accept-process-output' and not timed.  That is a fast typist, and the gap is
;; not decoration: sent back to back, every echo lands inside the core's
;; `cooked-min-redisplay-interval' of the previous one and waits the rest of it,
;; so the figure becomes that interval, 8 ms, whatever the buffer holds.  Set the
;; gap to 0 to see the throttle rather than the keystroke.

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
(defconst latency--out (or (getenv "COOKED_LATENCY_OUT") "/tmp/cooked-latency.out"))
(cooked-bench-script-start latency--out)
(require 'cooked)
(require 'cooked-mode)
(require 'cooked-bench)

(defconst latency--keystrokes
  (string-to-number (or (getenv "COOKED_LATENCY_N") "1000")))

(defconst latency--gap
  (string-to-number (or (getenv "COOKED_LATENCY_GAP") "0.03"))
  "Seconds between keystrokes, waited out untimed.")

(defconst latency--timeout 2.0
  "Seconds a keystroke's echo may take before it counts as a timeout.")

(defvar latency--log nil)

;; Pinned for the run, which is the one place §9 C is right to pin it: a collection
;; landing inside a measured keystroke is not a fact about cooked's latency, and
;; unlike the `cooked--apply' bracket refused in "Deliberately not doing" this is a
;; benchmark binding rather than a production one -- nothing here has to hand the
;; frame to a user afterwards.
(setq gc-cons-threshold (* 512 1024 1024) gc-cons-percentage 0.8)

(defun latency--say (fmt &rest args)
  (push (apply #'format fmt args) latency--log))

(defun latency--report (label samples extra)
  (if (null samples)
      (latency--say "%-22s no samples  %s" label extra)
    (let* ((s (sort (copy-sequence samples) #'<))
           (n (length s)))
      (latency--say "%-22s n=%5d  min=%7.3f  p50=%7.3f  p99=%7.3f  max=%8.3f  %s"
                    label n (car s)
                    (cooked-bench--pct s 0.50) (cooked-bench--pct s 0.99)
                    (car (last s)) extra))))

(defun latency--wait-for (predicate seconds)
  "Wait in `accept-process-output' until PREDICATE holds or SECONDS pass.
Return whether PREDICATE held."
  (let ((deadline (+ (float-time) seconds)))
    (while (and (< (float-time) deadline) (not (funcall predicate)))
      (accept-process-output nil 0.01))
    (funcall predicate)))

(defun latency--decorate (kind cols rows)
  "Fill the screen the way KIND asks, so the echo lands in that company.

The point of the three configurations is not that a keystroke is decorated -- it
is one character -- but that the *buffer it lands in* is.  A box-drawing screen
has a `display' property per run and a link screen a `mouse-face' per URL that
Emacs must reconsider on every redisplay, and both are paid again when one cell
changes.  That is the decorated-buffer risk §9 C is looking for.

Return a string the screen holds once the dressing has arrived."
  (pcase kind
    ('plain "READY")
    ('box (cooked--send-to-child
           (concat "\e[H"
                   (mapconcat (lambda (_) (make-string (1- cols) ?─))
                              (number-sequence 1 (1- rows)) "\r\n")))
           (make-string (1- cols) ?─))
    ('link (cooked--send-to-child
            (concat "\e[H"
                    (mapconcat (lambda (i) (format "see https://example.com/%d/x" i))
                               (number-sequence 1 (1- rows)) "\r\n")))
            (format "https://example.com/%d/x" (1- rows)))))

(defun latency--dressing (kind)
  "How many runs of the property KIND's dressing puts down, over the buffer.

The URL scan runs from jit-lock, so a link screen is dressed by the first
redisplay that shows it and not by the drain.  This is checked before the
first keystroke, so a configuration that measured an undressed screen says so
in its output instead of passing for a plain one."
  (pcase kind
    ('plain 0)
    ('box (cooked-bench--count-property-runs 'cooked-deco (point-min) (point-max)))
    ('link (cooked-bench--count-property-runs 'cooked-link-url (point-min) (point-max)))))

(defun latency--run (kind keystrokes warmup)
  "Time KEYSTROKES round trips with the screen dressed as KIND."
  (let* ((buffer (generate-new-buffer (format "*latency %s*" kind)))
         (drawn nil) (applied nil) (redisplays nil)
         (timeouts 0))
    (unwind-protect
        (with-current-buffer buffer
          (cooked-mode)
          (set-window-buffer (selected-window) buffer)
          ;; `cat' in raw mode with no echo of its own: the child echoes because
          ;; it is `cat', so exactly one write comes back for one byte sent, and
          ;; the tty adds nothing.  `printf READY' is the handshake -- without it
          ;; the first measured keystroke also pays for process startup.
          (cooked--start '("/bin/sh" "-c" "stty raw -echo; printf READY; exec cat"))
          (cooked--refresh-keymap)
          (latency--wait-for (lambda () (string-search "READY" (buffer-string))) 5)
          (let ((dressed (latency--decorate kind cooked--cols cooked--rows)))
            (latency--wait-for (lambda () (string-search dressed (buffer-string))) 5))
          (dotimes (_ 20) (accept-process-output nil 0.01))
          (redisplay t)
          (let ((dressing (latency--dressing kind)))
            (pcase-let
                ((`(,spent ,drains ,_applies)
                  (cooked-bench--charged
                   (lambda ()
                     (dotimes (i (+ warmup keystrokes))
                       ;; `buffer-chars-modified-tick' rather than searching for the
                       ;; echoed character: O(1) and unaffected by how much the buffer
                       ;; has grown, where a search is neither.
                       ;; A new line every sixty keystrokes, sent in the untimed
                       ;; gap.  Without it every echo lands on one logical line a
                       ;; thousand characters long, and the apply of a cell on a
                       ;; long soft-wrapped line grows with its length: 0.48 ms a
                       ;; keystroke over the first 200 and 3.3 ms over 1000, in a
                       ;; 115x66 pgtk frame.  That is a fact about long lines,
                       ;; not about typing at a prompt.
                       (when (and (> i 0) (zerop (% i 60)))
                         (cooked--send-to-child "\r\n"))
                       (let ((until (+ (float-time) latency--gap)))
                         (while (< (float-time) until)
                           (accept-process-output nil (max 0.001 (- until (float-time))))))
                       (let* ((tick (buffer-chars-modified-tick))
                              (t0 (float-time))
                              (deadline (+ t0 latency--timeout)))
                         (cooked--send-to-child "x")
                         (while (and (= tick (buffer-chars-modified-tick))
                                     (< (float-time) deadline))
                           (accept-process-output nil 0.001))
                         (let ((t1 (float-time))
                               (arrived (/= tick (buffer-chars-modified-tick))))
                           ;; Inside the sample, deliberately: send-to-*drawn*.
                           (redisplay t)
                           (let ((t2 (float-time)))
                             (when (>= i warmup)
                               (if (not arrived)
                                   (setq timeouts (1+ timeouts))
                                 (push (* 1000 (- t2 t0)) drawn)
                                 (push (* 1000 (- t1 t0)) applied)
                                 (push (* 1000 (- t2 t1)) redisplays)))))))))))
              (let ((extra (format "%dx%d term, %d chars, %d timeouts, %d drains for %d keys, drain+apply mean %.3f ms, dressing %d runs%s"
                                   cooked--rows cooked--cols (buffer-size) timeouts
                                   drains (+ warmup keystrokes)
                                   (/ (* 1000 spent) (max 1 drains))
                                   dressing
                                   (if (and (not (eq kind 'plain)) (zerop dressing))
                                       " -- NOT DRESSED" ""))))
                (latency--report (format "%s drawn" kind) drawn extra)
                (latency--report (format "%s applied" kind) applied "")
                (latency--report (format "%s redisplay" kind) redisplays "")))))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer))))

(when (display-graphic-p)
  (set-frame-size (selected-frame)
                  (string-to-number (or (getenv "COOKED_LATENCY_COLS") "100"))
                  (string-to-number (or (getenv "COOKED_LATENCY_ROWS") "32"))))
(redisplay t)

(push (cooked-bench-script-provenance) latency--log)
(push (format "frame %dx%d, framep=%s graphic=%s, %d keystrokes %.3f s apart"
              (frame-width) (frame-height) (framep (selected-frame))
              (display-graphic-p) latency--keystrokes latency--gap)
      latency--log)

(dolist (kind '(plain box link))
  (latency--run kind latency--keystrokes 30))

(latency--say "load after %s" (load-average t))

(with-temp-file latency--out
  (insert (mapconcat #'identity (nreverse latency--log) "\n") "\n"))
(kill-emacs 0)
