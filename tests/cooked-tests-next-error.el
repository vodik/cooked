;;; cooked-tests-next-error.el --- next-error over command output -*- lexical-binding: t; -*-

;;; Commentary:

;; `cooked-next-error-function' reparses from scratch on every call rather than
;; trusting anything cached from a previous one, so what these tests actually
;; exercise is that a fresh parse finds the right things twice in a row, that
;; stepping tracks a (FILE LINE COLUMN) tuple rather than an index, and that the
;; scrollback/live boundary is respected rather than guessed at.

;;; Code:

(require 'cooked-tests-helpers)
(require 'cooked-next-error)

(defun cooked-tests-next-error--gcc-line (file line col)
  "One line in the shape `compilation-error-regexp-alist' recognizes as a gcc error."
  (format "%s:%d:%d: error: something went wrong" file line col))

(defun cooked-tests-next-error--file-with-lines (n)
  "A temp file with N blank lines, so a real jump to line N in it lands there."
  (let ((file (make-temp-file "cooked-next-error-")))
    (with-temp-file file (dotimes (_ n) (insert "\n")))
    file))

(ert-deftest cooked-next-error-walks-a-finished-commands-output ()
  "The ordinary case: two errors in a finished command's output, both found and
walked in order, stepping back and forth by a (FILE LINE COLUMN) tuple rather
than a cached index.

Built directly rather than driven through a real child's output, the way
`cooked-delete-output-refuses-the-row-the-child-is-on' builds a
`cooked-command' by hand elsewhere in the suite: getting a command's own
output to genuinely scroll off the live screen and settle into protected
scrollback takes either a full screen of *further* output or real wall-clock
time (`cooked--render-scrolled' only protects a row once it is actually
evicted from the grid), neither of which this is about testing."
  (let ((one (cooked-tests-next-error--file-with-lines 5))
        (two (cooked-tests-next-error--file-with-lines 10)))
    (unwind-protect
        (cooked-tests--with-session (list "/bin/sh" "-c" "exec cat")
          (should (cooked-tests--settle #'cooked--screen-start-position))
          (let ((inhibit-read-only t))
            (goto-char (point-min))
            (let ((start (point-marker)))
              (insert (cooked-tests-next-error--gcc-line one 3 5) "\n"
                      (cooked-tests-next-error--gcc-line two 7 2) "\n")
              (setq cooked--commands
                    (list (cooked--command-make :start start :end (point-marker) :code 1)))
              ;; What makes this scrollback rather than live screen: the
              ;; predicate is a position comparison against
              ;; `cooked--screen-start', not anything about the command record.
              (set-marker cooked--screen-start (point))))
          (let ((buffer (current-buffer)))
            ;; `compilation-goto-locus' switches to the source buffer as a
            ;; side effect, which is what each check below inspects -- so the
            ;; buffer is switched back to explicitly (not via
            ;; `with-current-buffer', which would undo the very switch being
            ;; tested) before every call.
            (set-buffer buffer)
            (cooked-next-error-function 1 t)
            (should (equal (buffer-file-name) one))
            (should (= (line-number-at-pos) 3))
            (set-buffer buffer)
            (cooked-next-error-function 1 nil)
            (should (equal (buffer-file-name) two))
            (should (= (line-number-at-pos) 7))
            ;; Stepping back lands on the first error again, found by its
            ;; (FILE LINE COLUMN) tuple rather than a cached index.
            (set-buffer buffer)
            (cooked-next-error-function -1 nil)
            (should (equal (buffer-file-name) one))
            (should (= (line-number-at-pos) 3))
            ;; One past the last error refuses rather than wrapping.
            (set-buffer buffer)
            (cooked-next-error-function 1 nil)
            (set-buffer buffer)
            (should-error (cooked-next-error-function 1 nil) :type 'user-error)))
      (delete-file one)
      (delete-file two))))

(ert-deftest cooked-next-error-refuses-a-still-running-command ()
  "Parsing a command before it has finished would mean parsing a moving
target -- the region compiled.el itself assumes it can parse start..end of.
`cooked-next-error-function' refuses instead, the same way
`compilation-next-error-function' does when there is nothing to move to."
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-zsh
    (cooked--replace-input "sleep 5")
    (cooked-send-input)
    (should (cooked-tests--settle (lambda () cooked--command-start) 8))
    (should-not cooked--commands)
    (should-error (cooked-next-error-function 1 t) :type 'user-error)))

(ert-deftest cooked-next-error-clamps-to-the-scrollback-prefix ()
  "An error that is still on the live screen -- above
`cooked--screen-start-position' -- is not safe to jump to: a later drain can
still rewrite the row it sits in.  `cooked-next-error-function' clamps the
parse to the scrollback prefix rather than trusting the live tail, so a
command whose whole output is still live offers nothing to find yet."
  (skip-unless (executable-find "zsh"))
  (let ((file (make-temp-file "cooked-next-error-live")))
    (unwind-protect
        (cooked-tests--with-zsh
          (cooked--replace-input (format "printf '%s\\n'" (cooked-tests-next-error--gcc-line file 1 1)))
          (cooked-send-input)
          (should (cooked-tests--settle (lambda () cooked--commands) 8))
          ;; The output is finished but has not scrolled anywhere -- it is
          ;; still on the live grid, which is exactly the case the resize
          ;; corruption report's invariant is about.
          (should (>= (cooked--command-end-position (car cooked--commands))
                     (cooked--screen-start-position)))
          (should-error (cooked-next-error-function 1 t) :type 'user-error))
      (delete-file file))))

(provide 'cooked-tests-next-error)
;;; cooked-tests-next-error.el ends here
