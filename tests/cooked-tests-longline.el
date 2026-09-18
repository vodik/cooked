;;; cooked-tests-longline.el --- Emacs' long-line shortcuts -*- lexical-binding: t; -*-

;;; Commentary:

;; `cooked--sync-long-line-threshold' opts a cooked buffer into the layout
;; narrowing Emacs 29 offers a buffer that holds a long line, which a rejoined
;; transcript is full of.  Two halves to cover, and they need two different
;; harnesses.
;;
;; The threshold itself is arithmetic over `cooked--cols' and can be asserted
;; anywhere.  Whether Emacs ever *notices* cannot: the flag is set inside
;; `redisplay_window', and batch Emacs never redisplays, so the tests that read
;; `long-line-optimizations-p' run in a real tty frame -- the same reason
;; `cooked-tests-display.el' uses one.  They are also the only place the
;; invariants can be checked under the narrowing rather than beside it: the seam,
;; the guard, a copy of a rejoined line and a link buried deep inside one.

;;; Code:

(require 'cooked-tests-helpers)

(defconst cooked-tests--long-line
  (let ((filler (mapconcat #'identity (make-list 70 "abcdefghij") "")))
    (concat filler " https://example.com/a/very/long/path " filler))
  "One logical line of 1438 characters, with a URL in the middle of it.

Eighteen rows of an 80-column terminal, so it is over the 640-character
threshold `cooked-long-line-rows' derives there, and the URL is 700 characters
from either end -- far enough in that a pass which looked only near the line's
edges would miss it.")

(defconst cooked-tests--long-line-script
  (format (concat "printf '%%s\\n' '%s';"
                  " for i in 1 2 3 4 5 6 7 8 9 10; do printf 'tail%%s\\n' $i; done;"
                  " sleep 0.3;"
                  " for i in 11 12 13 14 15 16 17 18 19 20; do printf 'tail%%s\\n' $i; done;"
                  " sleep 5")
          cooked-tests--long-line)
  "Print the long line, then enough rows to push every one of its rows off.

The rows have to *leave* the screen: rejoining happens as a row enters
scrollback, so a line still on the grid is one buffer line per row and is not
long at all.

A second batch after a pause, so a test can settle on the first one, get the
buffer displayed and the flag set, and only then ask what the *follow* does with
the narrowing in force -- which is the half a pre-display drain cannot show.")

(defmacro cooked-tests--with-long-line (&rest body)
  "Run BODY in a 6x80 session whose scrollback holds `cooked-tests--long-line'.

Displayed in a real tty frame and redisplayed, which is what gives Emacs the
chance to set the flag; `cooked-debug' throughout, so the seam assertion runs on
every drain rather than only where BODY asks for it."
  (declare (indent 0))
  `(cooked-tests--with-tty-frame
     (let ((buffer (generate-new-buffer "*cooked-longline*"))
           (cooked-debug t))
       (unwind-protect
           (with-current-buffer buffer
             (cooked-mode)
             (setq cooked--rows 6 cooked--cols 80 cooked--last-size '(6 . 80))
             (cooked--start (list "/bin/sh" "-c" cooked-tests--long-line-script))
             (cooked--refresh-keymap)
             (should (cooked-tests--settle
                      (lambda () (string-match-p "tail10" (cooked-tests--text)))))
             (set-window-buffer (frame-root-window) buffer)
             (redisplay t)
             ,@body)
         (with-current-buffer buffer (cooked--cleanup))
         (kill-buffer buffer)))))

(defun cooked-tests--long-line-bounds ()
  "Bounds of the buffer line holding `cooked-tests--long-line', or nil."
  (save-excursion
    (goto-char (point-min))
    (when (search-forward "https://example.com/a/very/long/path" nil t)
      (cons (line-beginning-position) (line-end-position)))))

;;;; The threshold

(ert-deftest cooked-long-line-threshold-is-the-terminals-width-in-rows ()
  "Counted in rows of this terminal, not in characters.

Emacs' own 50000 is six hundred rows of an 80-column terminal, which nothing a
child prints ever reaches -- so a buffer left at the default keeps the whole
cost of laying a rejoined line out and never gets the remedy."
  (skip-unless (boundp 'long-line-threshold))
  (with-temp-buffer
    (cooked-mode)
    (should (local-variable-p 'long-line-threshold))
    (should (= long-line-threshold (* cooked-long-line-rows cooked--cols)))
    ;; And derived again from a new width rather than kept.
    (let ((cooked-long-line-rows 4))
      (setq cooked--cols 120)
      (cooked--sync-long-line-threshold)
      (should (= long-line-threshold 480)))))

(ert-deftest cooked-long-line-threshold-is-left-alone-when-asked ()
  "nil is Emacs' own behaviour, which is the escape hatch the docstring names."
  (skip-unless (boundp 'long-line-threshold))
  (let ((cooked-long-line-rows nil))
    (with-temp-buffer
      (cooked-mode)
      (should-not (local-variable-p 'long-line-threshold)))))

(ert-deftest cooked-long-line-threshold-follows-a-resize ()
  "`cooked--sync-size' is where a new width is adopted, so it is where this is.

A narrower window makes a shorter line long, and nothing else in the session
re-derives the threshold: a buffer resized once and never again would otherwise
be measuring rows of a width it no longer has."
  (skip-unless (boundp 'long-line-threshold))
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (cl-letf (((symbol-function 'cooked--window-size) (lambda () (cons 24 100))))
      (cooked--sync-size)
      (should (= cooked--cols 100))
      (should (= long-line-threshold (* cooked-long-line-rows 100))))))

;;;; The flag, in a frame that really redisplays

(ert-deftest cooked-long-line-optimizations-engage-on-a-rejoined-line ()
  "The whole point: a rejoined transcript is a buffer Emacs will shorten layout
for, and it says so within one screenful of output rather than never.

`long-line-optimizations-p' is the only reader of the flag, and it is what says
the threshold was low enough to be reached."
  (skip-unless (boundp 'long-line-threshold))
  (cooked-tests--with-long-line
    (should (long-line-optimizations-p))))

(ert-deftest cooked-long-line-threshold-is-dropped-once-the-flag-is-set ()
  "The flag is sticky, so the threshold has nothing left to do -- and nil is
what stops `redisplay_window' rescanning the whole transcript for a long line
after every drain.  See `cooked--sync-long-line-threshold'."
  (skip-unless (boundp 'long-line-threshold))
  (cooked-tests--with-long-line
    (should (long-line-optimizations-p))
    ;; One more drain, which is where the threshold is re-derived.
    (should (cooked-tests--settle (lambda () (null long-line-threshold)) 1))
    ;; And the shortcuts stay, which is the sticky half.
    (should (long-line-optimizations-p))))

(ert-deftest cooked-a-short-lined-session-is-not-called-long ()
  "The control, and it is about the threshold being a claim rather than a switch:
a session whose lines fit is left as Emacs would have it, with no shortcuts and
no narrowing."
  (skip-unless (boundp 'long-line-threshold))
  (cooked-tests--with-tty-frame
    (let ((buffer (generate-new-buffer "*cooked-shortline*"))
          (cooked-debug t))
      (unwind-protect
          (with-current-buffer buffer
            (cooked-mode)
            (setq cooked--rows 6 cooked--cols 80 cooked--last-size '(6 . 80))
            (cooked--start '("/bin/sh" "-c" "for i in 1 2 3; do printf 'row%s\\n' $i; done; sleep 5"))
            (cooked--refresh-keymap)
            (should (cooked-tests--settle
                     (lambda () (string-match-p "row3" (cooked-tests--text)))))
            (set-window-buffer (frame-root-window) buffer)
            (redisplay t)
            (should-not (long-line-optimizations-p))
            (should (= long-line-threshold (* cooked-long-line-rows cooked--cols))))
        (with-current-buffer buffer (cooked--cleanup))
        (kill-buffer buffer)))))

;;;; The invariants, under the narrowing

(ert-deftest cooked-the-seam-still-agrees-under-long-line-optimizations ()
  "The narrowing is a display shortcut and the seam is a fact about text, so
these two should have nothing to say to each other.  Asserted rather than
assumed, because `cooked--check-seam' measures a whole line with
`line-beginning-position' -- which a narrowing *can* clip -- and because the
drains that built this buffer ran it under `cooked-debug' already."
  (skip-unless (boundp 'long-line-threshold))
  (cooked-tests--with-long-line
    (should (long-line-optimizations-p))
    (should-not (cooked--check-seam))))

(ert-deftest cooked-a-rejoined-line-is-still-one-line-to-copy ()
  "Yanking a wrapped line out of the scrollback picks up no newline nobody
typed, which is what `cooked-rejoin-wrapped-lines' is for and what the
narrowing must not have touched: the buffer's text is not what changed."
  (skip-unless (boundp 'long-line-threshold))
  (cooked-tests--with-long-line
    (should (long-line-optimizations-p))
    (let ((bounds (cooked-tests--long-line-bounds)))
      (should bounds)
      (should (equal (buffer-substring-no-properties (car bounds) (cdr bounds))
                     cooked-tests--long-line)))))

(ert-deftest cooked-a-link-deep-inside-a-long-line-is-still-found ()
  "jit-lock's own region is narrowed under the flag --
`long-line-optimizations-region-size' characters around point -- and
`cooked--fontify-region' rounds out to whole *logical* lines inside that.  A
URL 700 characters into a 1438-character line is the case where a threshold
close to that region size would have cut the line the rounding exists to keep."
  (skip-unless (boundp 'long-line-threshold))
  (cooked-tests--with-long-line
    (should (long-line-optimizations-p))
    (cooked-tests--fontify)
    (let ((at (save-excursion
                (goto-char (point-min))
                (search-forward "https://example.com/a/very/long/path" nil t)
                (match-beginning 0))))
      (should at)
      (should (equal (get-text-property at 'cooked-link-url)
                     "https://example.com/a/very/long/path")))))

(ert-deftest cooked-the-live-rows-are-still-whole-under-long-line-optimizations ()
  "`cooked--guard-row-width' measures a live row with `vertical-motion', which
is one of the calls the narrowing reaches.  A live row is one row long and so
nowhere near the narrowed window, and the rows arriving after the long line say
so: a trimmed row would be short a character and carry a truncation mark."
  (skip-unless (boundp 'long-line-threshold))
  (cooked-tests--with-long-line
    (should (long-line-optimizations-p))
    (let ((text (cooked-tests--text)))
      (dotimes (i 10)
        (should (string-match-p (format "^tail%d$" (1+ i)) text))))))

(ert-deftest cooked-the-view-still-follows-the-tail-under-long-line-optimizations ()
  "`cooked--pin-transcript-bottom' walks a window's height backwards with
`vertical-motion', and backward motion is where the narrowing actually bites:
`move_it_vertically_backward' is limited to three rows of the width behind
point.  A wrong answer there puts the window start somewhere other than a
screenful above the tail, and the child's newest output is off screen -- so the
assertion is the one the follow exists for."
  (skip-unless (boundp 'long-line-threshold))
  (cooked-tests--with-long-line
    (should (long-line-optimizations-p))
    (should (cooked-tests--settle
             (lambda () (string-match-p "tail20" (cooked-tests--text)))))
    (redisplay t)
    (should (pos-visible-in-window-p (point-max) (frame-root-window)))))

(provide 'cooked-tests-longline)
;;; cooked-tests-longline.el ends here
