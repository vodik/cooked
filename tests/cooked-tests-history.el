;;; cooked-tests-history.el --- the shell history layer  -*- lexical-binding: t; -*-

;;; Commentary:

;; `cooked-history.el' is an optional layer.  Most of what is under test is the
;; splitting, the ordering and where the chosen entry lands, and a test that depended on
;; the machine's own history would assert whatever happened to be in it.  The function
;; form of `cooked-history-commands' is the seam that makes that possible, and it is the
;; same seam atuin plugs into.
;;
;; The string form is tested through a real shell with command lines that stand in for
;; a history command, since what can go wrong there is stderr, the exit status and which
;; shell runs the line, none of which the seam goes near.

;;; Code:

(require 'ert)
(require 'cooked-tests-helpers)
(require 'cooked-history)

(defmacro cooked-tests--with-history (entries &rest body)
  "Run BODY with `cooked-history--entries' answering ENTRIES."
  (declare (indent 1))
  `(let ((cooked-history-shell 'test)
         (cooked-history-commands (list (cons 'test (lambda () ,entries)))))
     ,@body))

(ert-deftest cooked-history-splits-on-nul-when-there-is-one ()
  "fish entries can contain newlines, so splitting those on newlines halves them.

`history -z' is why fish is asked the way it is, and the split is decided per
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

`delete-dups' rather than a hash walk, because it keeps the first occurrence
-- which, the list being newest-first, is the most recent time you ran it."
  (cooked-tests--with-history '("newest" "middle" "newest" "oldest" "middle")
    (should (equal (cooked-history--entries) '("newest" "middle" "oldest")))))

(ert-deftest cooked-history-caps-the-oldest-away ()
  (let ((cooked-history-limit 2))
    (cooked-tests--with-history '("a" "b" "c" "d")
      (should (equal (cooked-history--entries) '("a" "b"))))))

(ert-deftest cooked-history-refuses-a-shell-it-has-no-command-for ()
  "A `user-error', not a silent empty list: an empty history and an unknown
shell look identical from the prompt, and only one of them is worth telling
somebody about."
  (let ((cooked-history-shell 'nosuchshell)
        (cooked-history-commands nil))
    (should-error (cooked-history--entries) :type 'user-error)))

(ert-deftest cooked-history-guesses-the-shell-from-cooked-shell ()
  "Including when `cooked-shell' carries arguments, which it is allowed to."
  (let ((cooked-history-shell nil))
    (dolist (case '(("/bin/zsh" . zsh) ("/usr/bin/fish" . fish) ("bash -l" . bash)))
      (let ((cooked-shell (car case)))
        (should (eq (cooked-history--shell) (cdr case)))))))

(ert-deftest cooked-history-asks-a-remote-host-for-its-shell ()
  "A remote session guesses its shell from the far host, not from `cooked-shell'.

A zsh user who ssh'd to a host whose shell is fish was asked for zsh's history
there.  The far host's `SHELL' is asked instead, over the same TRAMP connection
the history command uses.  The mock connection is a local shell, so the
variable is handed to it through `process-environment', which TRAMP passes on
as it would to a real host."
  :tags '(pty)
  (cooked-tests--with-mock-tramp remote
    (let ((cooked-history-shell nil)
          (cooked-shell "/bin/zsh")
          (shell-file-name "/bin/sh")
          (shell-command-switch "-c"))
      (should (eq (cooked-history--shell) 'zsh))
      (let ((default-directory remote)
            (process-environment (cons "SHELL=/usr/bin/fish" process-environment)))
        (should (eq (cooked-history--shell) 'fish))))))

(ert-deftest cooked-history-inserts-at-the-prompt-without-running-it ()
  "The chosen entry has to stop where it can still be edited.

Offering a list of past commands and running the chosen one on the spot is a
one-way door over somebody's shell history, and the entry you meant is one line
away from the entry you did not.  So: no newline, on either path."
  :tags '(pty)
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
                                    (point-min) (point-max))))
          ;; Marked as pasted, since a history file is not necessarily one you
          ;; wrote, so its control bytes are stripped when the line is sent.
          (should (get-text-property (1- (point-max)) 'cooked-pasted)))))))

(defmacro cooked-tests--with-history-command (command &rest body)
  "Run BODY with `cooked-history--entries' running the command line COMMAND."
  (declare (indent 1))
  `(let ((cooked-history-shell 'test)
         (cooked-history-commands (list (cons 'test ,command)))
         (shell-file-name "/bin/sh")
         (shell-command-switch "-c"))
     ,@body))

(ert-deftest cooked-history-does-not-offer-stderr-as-an-entry ()
  "What a shell writes to stderr is not history, even when it exits 0.

An interactive bash with no controlling terminal prints \"cannot set terminal
process group\" and \"no job control in this shell\" before the history, and
with stderr merged into the output those became the two newest candidates."
  (cooked-tests--with-history-command
      "echo 'bash: no job control in this shell' >&2; printf 'newest\\nolder\\n'"
    (should (equal (cooked-history--entries) '("newest" "older")))))

(ert-deftest cooked-history-reports-a-failed-command ()
  "A non-zero exit is a `user-error' naming stderr's first line, not a candidate.

zsh on an empty history prints \"zsh:fc:1: no such event: 1\" and exits 1, and
a missing shell prints \"not found\" and exits 127.  Both used to be offered as
the one entry in the history."
  (cooked-tests--with-history-command
      "echo 'zsh:fc:1: no such event: 1' >&2; echo second >&2; exit 1"
    (let ((err (should-error (cooked-history--entries) :type 'user-error)))
      (should (string-search "no such event" (cadr err)))
      (should-not (string-search "second" (cadr err))))))

(ert-deftest cooked-history-runs-the-remote-command-with-bin-sh ()
  "Over TRAMP the command line is run by /bin/sh, not by the local shell's path.

`shell-file-name' is an absolute path on this machine, and TRAMP runs a program
by that path on the far host.  Here it names a shell that exists nowhere, which
is what /opt/homebrew/bin/fish is to a Linux server."
  :tags '(pty)
  (cooked-tests--with-mock-tramp remote
    (cooked-tests--with-history-command "printf 'remote\\n'"
      (let ((default-directory remote)
            (shell-file-name "/nonexistent/bin/fish"))
        (should (equal (cooked-history--entries) '("remote")))))))

(ert-deftest cooked-history-is-refused-while-a-command-owns-the-keyboard ()
  "An entry would be pasted into vim, so the history is not even asked for.

The refusal comes before the shell is run, so a slow rc file is not waited on
for nothing, and again after the pick, since a command can start while the
minibuffer is open."
  :tags '(pty)
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (should (cooked-tests--settle (lambda () cooked--session)))
    (let* ((asked nil)
           (cooked-history-shell 'test)
           (cooked-history-commands
            (list (cons 'test (lambda () (setq asked t) '("ls"))))))
      (dolist (policy '(command alt))
        (cl-letf (((symbol-function 'cooked--policy) (lambda () policy)))
          (should-error (cooked-history) :type 'user-error)
          (should-not asked)))
      (let ((policy 'cooked) (inserted nil))
        (cl-letf (((symbol-function 'cooked--policy) (lambda () policy))
                  ((symbol-function 'completing-read)
                   (lambda (&rest _) (setq policy 'alt) "ls"))
                  ((symbol-function 'cooked-history--insert)
                   (lambda (text) (setq inserted text))))
          (should-error (cooked-history) :type 'user-error)
          (should asked)
          (should-not inserted))))))

(provide 'cooked-tests-history)
;;; cooked-tests-history.el ends here
