;;; cooked-tests-helpers.el --- Shared fixtures for the cooked test suite -*- lexical-binding: t; -*-

;;; Commentary:

;; Every helper the suite uses, in one place rather than scattered through the
;; tests that first needed them.  The themed files all require this and nothing
;; else of each other, so a test can be moved between them freely.
;;
;; The suite is end-to-end by preference: `cooked-tests--with-session' drives a
;; real child through a real pty, and `cooked-tests--settle' pumps Emacs' event
;; loop until the thing being waited for is true or a deadline passes.  Tests that
;; assert on pure functions -- the rasterizer, the key encoder -- say so by not
;; opening a session at all.

;;; Code:

(require 'ert)
(require 'cooked)
(require 'cooked-mode)

(defmacro cooked-tests--with-session (argv &rest body)
  "Run BODY in a live cooked buffer running ARGV."
  (declare (indent 1))
  `(let ((buffer (generate-new-buffer "*cooked-test*")))
     (unwind-protect
         (with-current-buffer buffer
           (cooked-mode)
           (cooked--start ,argv)
           (cooked--refresh-keymap)
           ,@body)
       (with-current-buffer buffer (cooked--cleanup))
       (kill-buffer buffer))))

(defun cooked-tests--settle (predicate &optional seconds)
  "Pump the event loop until PREDICATE holds or SECONDS elapse."
  (let ((deadline (+ (float-time) (or seconds 5))))
    (while (and (< (float-time) deadline) (not (funcall predicate)))
      (accept-process-output nil 0.05)
      (when cooked--session (cooked--apply (cooked--drain cooked--session))))
    (funcall predicate)))

(defun cooked-tests--text ()
  "Visible buffer text with trailing blank lines removed."
  (string-trim-right (buffer-substring-no-properties (point-min) (point-max))))

(defmacro cooked-tests--with-fake-zdotdir (files &rest body)
  "Run BODY with ZDOTDIR pointing at a directory built from FILES.
FILES is an alist of (NAME . CONTENTS)."
  (declare (indent 1))
  `(let* ((home (make-temp-file "cooked-fake-zdot-" t))
          (process-environment (cons (concat "ZDOTDIR=" home) process-environment)))
     (unwind-protect
         (progn
           (pcase-dolist (`(,name . ,contents) ,files)
             (with-temp-file (expand-file-name name home) (insert contents)))
           ,@body)
       (delete-directory home t))))

(defmacro cooked-tests--with-echoing-child (setup &rest body)
  "Run BODY against a raw child that echoes what it receives, visibly.
SETUP is shell run before it, for turning bracketed paste on.  `cat -v' spells
control characters out, so what the child was actually sent can be read straight
off the buffer."
  (declare (indent 1))
  `(cooked-tests--with-session
       (list "/bin/sh" "-c" (concat ,setup "stty raw -echo; cat -v"))
     (should (cooked-tests--settle (lambda () (eq cooked--mode 'raw))))
     (should-not (cooked--input-state-p))
     ,@body))

(defmacro cooked-tests--with-kill (text &rest body)
  "Run BODY with TEXT as the most recent kill and no clipboard in the way."
  (declare (indent 1))
  `(let* ((interprogram-paste-function nil)
          (kill-ring (list ,text))
          (kill-ring-yank-pointer kill-ring))
     ,@body))

;; MARKER is pushed into real scrollback by the lines that follow it — the point
;; being that it is history, not screen content, which the alt screen hides anyway.
(defconst cooked-tests--scrollback-then-alt
  "printf 'MARKER\\n'; seq 1 60; printf '\\033[?1049h'; printf 'inalt\\n'; ")

(defun cooked-tests--run-until-dead (argv seconds)
  "Run ARGV in a cooked buffer and pump for up to SECONDS, killing it if alive.
Returns non-nil when the buffer killed itself along the way."
  (let ((buffer (generate-new-buffer "*cooked-test*")))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (cooked-mode)
            (cooked--start argv))
          (let ((deadline (+ (float-time) seconds)))
            (while (and (< (float-time) deadline) (buffer-live-p buffer))
              (accept-process-output nil 0.05)
              ;; Timers, so the deferred kill actually fires.
              (sit-for 0)
              (when (buffer-live-p buffer)
                (with-current-buffer buffer
                  (when cooked--session
                    (cooked--apply (cooked--drain cooked--session)))))))
          (not (buffer-live-p buffer)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (cooked--cleanup))
        (kill-buffer buffer)))))

;; Twelve rows of exactly twelve columns, `ps'-like: padded out to the right edge and
;; hard-newlined there rather than wrapped, with interior runs of spaces wide enough that
;; a narrower width has to break inside one.  Each row is tagged, so a duplicate is
;; countable rather than a judgement call.
(defconst cooked-tests--filled-screen
  "i=1; while [ $i -le 12 ]; do printf 'r%02d  aaa    bb  cc  \\n' $i; i=$((i+1)); done; exec cat"
  "Fill a 12x20 screen with space-padded lines that reach the right edge.")

(defmacro cooked-tests--with-filled-screen (&rest body)
  "Run BODY with a 12x20 session whose screen `cooked-tests--filled-screen' has filled."
  (declare (indent 0))
  `(let ((buffer (generate-new-buffer "*cooked-filled*")))
     (unwind-protect
         (with-current-buffer buffer
           (cooked-mode)
           (setq cooked--rows 12 cooked--cols 20 cooked--last-size '(12 . 20))
           (cooked--start (list "/bin/sh" "-c" cooked-tests--filled-screen))
           (cooked--refresh-keymap)
           (should (cooked-tests--settle
                    (lambda () (string-match-p "r12" (cooked-tests--text)))))
           ,@body)
       (with-current-buffer buffer (cooked--cleanup))
       (kill-buffer buffer))))

(defmacro cooked-tests--capturing-notifications (&rest body)
  "Run BODY with notifications captured into `seen\=' instead of raised."
  (declare (indent 0))
  `(let ((seen nil))
     (cl-letf (((symbol-function 'cooked--notify)
                (lambda (title body) (push (cons title body) seen))))
       ,@body
       (nreverse seen))))

(defun cooked-tests--reply-to (query out)
  "Shell that sends QUERY, then copies whatever comes back into OUT."
  (list "/bin/sh" "-c"
        (format "stty raw -echo; printf '%s'; cat > %s" query out)))

(defun cooked-tests--contents (file)
  "Contents of FILE, or the empty string if it has none yet."
  (with-temp-buffer
    (ignore-errors (insert-file-contents file))
    (buffer-string)))

(defconst cooked-tests--erase-scrollback-script
  "for i in $(seq 60); do printf 'line%s\\n' $i; done; sleep 1; printf '\\033[3J'; exec cat"
  "Print enough to fill scrollback, settle, then the child erases it.

The `sleep' matters: it lets a test observe the buffer in its pre-erase state
before the `CSI 3 J' this is testing for ever arrives, rather than racing to
read output that a fast child overwrites before the test gets a look at it.")

(defun cooked-tests--type (keys)
  "Run KEYS through the command loop, so `pre-command-hook' applies."
  (execute-kbd-macro (kbd keys)))

(defun cooked-tests--completion-reply (serial prefix records &optional truncated)
  "The OSC 51;C payload a shell would send for RECORDS, as the handler sees it."
  (concat (format "R;%d;%d;0;%d;" serial prefix (if truncated 1 0))
          (base64-encode-string
           (encode-coding-string
            (mapconcat (lambda (record) (concat (string-join record "\x1f") "\x1e"))
                       records "")
            'utf-8)
           t)))

(defmacro cooked-tests--with-stub-shell (answers count &rest body)
  "Run BODY with `cooked--shell-completions' answering from ANSWERS.

ANSWERS is an alist of LINE to the reply it produces; COUNT is a symbol bound to
the number of queries made, which is the point of the exercise: a round trip the
shell did not need is a stutter while typing."
  (declare (indent 2))
  `(let ((,count 0))
     (cl-letf (((symbol-function 'cooked--shell-completions)
                (lambda (line _offset)
                  (cl-incf ,count)
                  (cdr (assoc line ,answers)))))
       ,@body)))

(defconst cooked-tests--two-stage-output-script
  "for i in $(seq 40); do printf 'line%s\\n' $i; done; sleep 1; printf 'AFTER\\n'; exec cat"
  "Enough lines to build real scrollback, then more output after a pause a
test can settle across — see `cooked-tests--erase-scrollback-script'.")

(defmacro cooked-tests--with-straddling-line (&rest body)
  "Run BODY with a 4x10 session holding one 59-character line.
Six rows of one logical line through a four-row screen: two rows have gone to
Emacs while the rest is still on the grid, so the line spans the seam between
them — the arrangement every seam bug needs."
  (declare (indent 0))
  `(let ((buffer (generate-new-buffer "*cooked-seam*")))
     (unwind-protect
         (with-current-buffer buffer
           (cooked-mode)
           (setq cooked--rows 4 cooked--cols 10 cooked--last-size '(4 . 10))
           (cooked--start '("/bin/sh" "-c"
                            "printf '%s' 00000000001111111111222222222233333333334444444444555555555; \
                             sleep 5"))
           (cooked--refresh-keymap)
           (should (cooked-tests--settle
                    (lambda () (string-match-p "555555555" (cooked-tests--text)))))
           ,@body)
       (with-current-buffer buffer (cooked--cleanup))
       (kill-buffer buffer))))

(defun cooked-tests--resize (rows cols)
  "Resize the session to ROWS by COLS and let the redraw land."
  (setq cooked--last-size nil cooked--rows rows cooked--cols cols)
  (cooked--resize cooked--session rows cols)
  (cooked-tests--settle (lambda () nil) 0.3))

(defun cooked-tests--unwrapped ()
  "Buffer text with the line structure taken out."
  (string-replace "\n" "" (cooked-tests--text)))

;; The same arrangement with a padded line rather than a solid one.  Digits cannot catch a
;; trimming bug, because there is nothing about them to trim: every row of the solid line
;; is full to its last column whatever width it is chunked at.  Real column-aligned output
;; is padded with spaces at every boundary, so a wrap landing inside a run of them is the
;; ordinary case, and a continuation row that loses them shortens the buffer's copy of the
;; line — which is the seam drifting, silently, until the next rewrap resumes it a few
;; columns out.
(defconst cooked-tests--padded-seam-line
  "aa        bb        cc        dd        ee        ff       "
  "Fifty-nine characters, padded so that a chunk boundary lands inside the spaces.")

(defmacro cooked-tests--with-padded-straddling-line (&rest body)
  "Run BODY with a 4x10 session holding `cooked-tests--padded-seam-line'."
  (declare (indent 0))
  `(let ((buffer (generate-new-buffer "*cooked-padded-seam*")))
     (unwind-protect
         (with-current-buffer buffer
           (cooked-mode)
           (setq cooked--rows 4 cooked--cols 10 cooked--last-size '(4 . 10))
           (cooked--start (list "/bin/sh" "-c"
                                (format "printf '%%s' '%s'; sleep 5"
                                        cooked-tests--padded-seam-line)))
           (cooked--refresh-keymap)
           (should (cooked-tests--settle
                    (lambda () (string-match-p "ff" (cooked-tests--text)))))
           ,@body)
       (with-current-buffer buffer (cooked--cleanup))
       (kill-buffer buffer))))

(defmacro cooked-tests--with-mocked-wrap (limit &rest body)
  "Run BODY with `vertical-motion' reporting a wrap after LIMIT characters."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'vertical-motion)
              (lambda (&rest _) (goto-char (min (point-max) (+ (point) ,limit))))))
     ,@body))

(defun cooked-tests--glyph-grid (bits width height &optional phase)
  "The pixel bitmap `cooked--render-box-glyph' would pack, for BITS."
  (let ((bitmap (cooked--bitmap-make width height)))
    (if (cooked--box-block-p bits)
        (cooked--box-draw-block bitmap bits (or phase 0))
      (cooked--box-draw-line bitmap bits))
    bitmap))

(defun cooked-tests--line-bits (up down left right &optional dash)
  "A line descriptor, mirroring `BoxGlyph::line' in src/emu/glyph.rs.
DASH is the raw 2-bit code, not a dash count."
  (logior up (ash down 2) (ash left 4) (ash right 6)
          (ash (or dash 0) cooked--box-dash-shift)))

(defun cooked-tests--row-runs (grid y width)
  "Lengths of the set runs in row Y of GRID, left to right."
  (let ((runs nil) (run 0))
    (dotimes (x width)
      (if (cooked--bitmap-ref grid x y)
          (setq run (1+ run))
        (when (> run 0) (push run runs))
        (setq run 0)))
    (when (> run 0) (push run runs))
    (nreverse runs)))

(provide 'cooked-tests-helpers)
;;; cooked-tests-helpers.el ends here
