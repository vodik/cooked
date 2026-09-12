;;; cooked-tests-history.el --- the shell history layer  -*- lexical-binding: t; -*-

;;; Commentary:

;; `cooked-history.el' is an optional layer.  Nothing here shells out to a real shell:
;; what is under test is the splitting, the ordering and where the chosen entry lands,
;; and a test that depended on the machine's own history would assert whatever happened
;; to be in it.  The function form of `cooked-history-commands' is the seam that makes
;; that possible, and it is the same seam atuin plugs into.

;;; Code:

(require 'ert)
(require 'cooked-tests-helpers)
(require 'cooked-history)

(defmacro cooked-tests--with-history (entries &rest body)
  "Run BODY with `cooked-history--entries\=' answering ENTRIES."
  (declare (indent 1))
  `(let ((cooked-history-shell 'test)
         (cooked-history-commands (list (cons 'test (lambda () ,entries)))))
     ,@body))

(ert-deftest cooked-history-splits-on-nul-when-there-is-one ()
  "fish entries can contain newlines, so splitting those on newlines halves them.

`history -z\=' is why fish is asked the way it is, and the split is decided per
call rather than per shell: an unlisted shell works if it can do either, and a
wrapper could reasonably emit NULs from anything."
  (should (equal (cooked-history--split "one\0two\nlines\0three\0")
                 '("one" "two\nlines" "three")))
  ;; No NUL anywhere, so newlines are the separator after all.
  (should (equal (cooked-history--split "one\ntwo\nthree\n")
                 '("one" "two" "three")))
  ;; Blank entries are dropped rather than offered as empty candidates.
  (should (equal (cooked-history--split "one\n\n\ntwo\n") '("one" "two"))))

(ert-deftest cooked-history-keeps-newest-first-and-drops-duplicates ()
  "The shells are asked for a *reversed* history, so order is the answer.

`delete-dups\=' rather than a hash walk, because it keeps the first occurrence
-- which, the list being newest-first, is the most recent time you ran it."
  (cooked-tests--with-history '("newest" "middle" "newest" "oldest" "middle")
    (should (equal (cooked-history--entries) '("newest" "middle" "oldest")))))

(ert-deftest cooked-history-caps-the-oldest-away ()
  (let ((cooked-history-limit 2))
    (cooked-tests--with-history '("a" "b" "c" "d")
      (should (equal (cooked-history--entries) '("a" "b"))))))

(ert-deftest cooked-history-refuses-a-shell-it-has-no-command-for ()
  "A `user-error\=', not a silent empty list: an empty history and an unknown
shell look identical from the prompt, and only one of them is worth telling
somebody about."
  (let ((cooked-history-shell 'nosuchshell)
        (cooked-history-commands nil))
    (should-error (cooked-history--entries) :type 'user-error)))

(ert-deftest cooked-history-guesses-the-shell-from-cooked-shell ()
  "Including when `cooked-shell\=' carries arguments, which it is allowed to."
  (let ((cooked-history-shell nil))
    (dolist (case '(("/bin/zsh" . zsh) ("/usr/bin/fish" . fish) ("bash -l" . bash)))
      (let ((cooked-shell (car case)))
        (should (eq (cooked-history--shell) (cdr case)))))))

(ert-deftest cooked-history-inserts-at-the-prompt-without-running-it ()
  "The chosen entry has to stop where it can still be edited.

Offering a list of past commands and running the chosen one on the spot is a
one-way door over somebody's shell history, and the entry you meant is one line
away from the entry you did not.  So: no newline, on either path."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (should (cooked-tests--settle (lambda () cooked--session)))
    (let ((sent nil))
      (cl-letf (((symbol-function 'cooked--send-paste)
                 (lambda (text) (push text sent))))
        ;; Forwarding: the child owns the line editor, so it goes over the wire
        ;; -- through the paste path, which strips control bytes, because a
        ;; history file is not necessarily one you wrote.
        (cl-letf (((symbol-function 'cooked--input-state-p) (lambda () nil)))
          (cooked-history--insert "echo hello")
          (should (equal sent '("echo hello")))
          (should-not (string-search "\n" (car sent))))
        ;; Input state: the buffer is Emacs' own, so it is simply inserted and
        ;; `cooked-send-input' is what runs it.
        (setq sent nil)
        (cl-letf (((symbol-function 'cooked--input-state-p) (lambda () t))
                  ((symbol-function 'cooked--input-start-position)
                   (lambda () (point-max))))
          (goto-char (point-max))
          (cooked-history--insert "echo edited")
          (should-not sent)
          (should (string-suffix-p "echo edited"
                                   (buffer-substring-no-properties
                                    (point-min) (point-max)))))))))

(provide 'cooked-tests-history)
;;; cooked-tests-history.el ends here
