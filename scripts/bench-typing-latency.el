;;; bench-typing-latency.el --- send-to-drawn, in a real frame  -*- lexical-binding: t; -*-

;; PLAN.org Wave 0, "Typing latency benchmark, three configurations".
;;
;; The number this produces is *send to drawn*, not send to filter-fired, and that
;; distinction is the whole reason it is a separate script.  The spin loop drains and
;; applies and then calls `(redisplay t)', so what is timed is the round trip a
;; keystroke actually makes: write to the pty, the child echoes, cooked drains, applies
;; and Emacs paints.  A harness that stopped at the process filter would report cooked's
;; cheapest half and miss the half REPORT.org §7 blames.
;;
;; Run it the way PLAN.org's "Measuring in a real graphical frame" says:
;;
;;     gamescope --backend headless -W 1920 -H 1080 -r 1000 --expose-wayland -- \
;;       emacs -Q -l scripts/bench-typing-latency.el
;;
;; and run it under foot as the control:
;;
;;     foot -W 100x32 -- emacs -nw -Q -l scripts/bench-typing-latency.el
;;
;; pgtk is among the slowest Emacs redraw backends, so a pgtk figure is an upper bound
;; and a tty one says how much of it is the backend.  Results go to
;; COOKED_LATENCY_OUT (default /tmp/cooked-latency.out), because nothing printed to
;; stdout survives the compositor's own logging.

(setq debug-on-error t)

(let ((root (file-name-directory
             (directory-file-name
              (file-name-directory (or load-file-name buffer-file-name))))))
  (add-to-list 'load-path (expand-file-name "lisp" root)))
(require 'cooked)
(require 'cooked-mode)

(defconst latency--out (or (getenv "COOKED_LATENCY_OUT") "/tmp/cooked-latency.out"))

(defvar latency--log nil)

;; Pinned for the run, which is the one place §9 C is right to pin it: a collection
;; landing inside a measured keystroke is not a fact about cooked's latency, and
;; unlike the `cooked--apply' bracket refused in "Deliberately not doing" this is a
;; benchmark binding rather than a production one -- nothing here has to hand the
;; frame to a user afterwards.
(setq gc-cons-threshold (* 512 1024 1024) gc-cons-percentage 0.8)

(defun latency--pct (sorted p)
  (nth (min (1- (length sorted)) (floor (* p (length sorted)))) sorted))

(defun latency--report (label samples extra)
  (let* ((s (sort (copy-sequence samples) #'<))
         (n (length s)))
    (push (format "%-34s n=%4d  min=%7.3f  p50=%7.3f  p99=%7.3f  max=%7.3f  %s"
                  label n (car s) (latency--pct s 0.50) (latency--pct s 0.99)
                  (car (last s)) extra)
          latency--log)))

(defun latency--decorate (kind cols rows)
  "Fill the screen the way KIND asks, so the echo lands in that company.

The point of the three configurations is not that a keystroke is decorated -- it
is one character -- but that the *buffer it lands in* is.  A box-drawing screen
has a `display' property per run and a `mouse-face' screen has a highlight
Emacs must reconsider on every redisplay, and both are paid again when one cell
changes.  That is the decorated-buffer risk §9 C is looking for."
  (pcase kind
    ('plain nil)
    ('box (cooked--send-to-child
           (concat (make-string 1 ?\e) "[H"
                   (mapconcat (lambda (_) (make-string (1- cols) ?─))
                              (number-sequence 1 (1- rows)) "\r\n"))))
    ('link (cooked--send-to-child
            (concat (make-string 1 ?\e) "[H"
                    (mapconcat (lambda (i) (format "see https://example.com/%d/x" i))
                               (number-sequence 1 (1- rows)) "\r\n"))))))

(defun latency--run (kind keystrokes warmup)
  "Time KEYSTROKES round trips with the screen dressed as KIND."
  (let* ((buffer (generate-new-buffer (format "*latency %s*" kind)))
         (samples nil))
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
          (let ((deadline (+ (float-time) 5)))
            (while (and (< (float-time) deadline)
                        (not (string-search "READY" (buffer-string))))
              (accept-process-output nil 0.01)
              (when cooked--session
                (cooked--apply (cooked--drain cooked--session
                                              cooked-rejoin-wrapped-lines)))))
          (latency--decorate kind cooked--cols cooked--rows)
          (dotimes (_ 20) (accept-process-output nil 0.01)
            (when cooked--session
              (cooked--apply (cooked--drain cooked--session
                                            cooked-rejoin-wrapped-lines))))
          (redisplay t)
          (dotimes (i (+ warmup keystrokes))
            ;; `buffer-chars-modified-tick' rather than searching for the echoed
            ;; character: O(1) and unaffected by how much the buffer has grown,
            ;; where a search is neither and would charge the measurement for the
            ;; scrollback the earlier keystrokes produced.
            (let ((tick (buffer-chars-modified-tick))
                  (deadline (+ (float-time) 2))
                  (t0 nil))
              (setq t0 (float-time))
              (cooked--send-to-child "x")
              (while (and (< (float-time) deadline)
                          (= tick (buffer-chars-modified-tick)))
                (accept-process-output nil 0.001)
                (when cooked--session
                  (cooked--apply (cooked--drain cooked--session
                                                cooked-rejoin-wrapped-lines))))
              ;; Inside the sample, deliberately: send-to-*drawn*.
              (redisplay t)
              (when (>= i warmup)
                (push (* 1000 (- (float-time) t0)) samples))))
          (latency--report (format "%s" kind) samples
                           (format "%dx%d term, %d chars"
                                   cooked--rows cooked--cols (buffer-size))))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer))))

(when (display-graphic-p)
  (set-frame-size (selected-frame)
                  (string-to-number (or (getenv "COOKED_LATENCY_COLS") "100"))
                  (string-to-number (or (getenv "COOKED_LATENCY_ROWS") "32"))))
(redisplay t)

(push (format "frame %dx%d, framep=%s graphic=%s, load %s"
              (frame-width) (frame-height) (framep (selected-frame))
              (display-graphic-p) (car (load-average)))
      latency--log)

(latency--run 'plain 200 30)
(latency--run 'box   200 30)
(latency--run 'link  200 30)

(with-temp-file latency--out
  (insert (mapconcat #'identity (nreverse latency--log) "\n") "\n"))
(kill-emacs 0)
