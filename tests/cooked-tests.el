;;; cooked-tests.el --- The cooked test suite -*- lexical-binding: t; -*-

;;; Commentary:

;; Loading this loads the whole suite.  It is split by subject, so that finding
;; the tests for a change means opening one file rather than searching three
;; thousand lines:
;;
;;   cooked-tests-helpers.el     fixtures every other file uses
;;   cooked-tests-session.el     spawning, shell integration, sizing, exit
;;   cooked-tests-render.el      the grid becoming buffer text, and the seam
;;   cooked-tests-input.el       keys, mouse, paste, keyboard ownership
;;   cooked-tests-dnd.el         drops and yank-media, the optional layer
;;   cooked-tests-history.el     the optional shell-history layer
;;   cooked-tests-consult.el     the optional terminal picker, and the
;;                               annotations it shares with plain completion
;;   cooked-tests-command-search.el  the optional search over every buffer's
;;                               commands
;;   cooked-tests-osc.el         the sequences answered in Lisp
;;   cooked-tests-link.el        URLs, OSC 8 hyperlinks, the optional file layer
;;   cooked-tests-completion.el  both completion backends
;;   cooked-tests-glyph.el       the rasterizer, against pixels
;;   cooked-tests-next-error.el  next-error over a command's output
;;   cooked-tests-sticky-scroll.el       the sticky-scroll header line
;;   cooked-tests-command-decorations.el the fringe dot per command
;;   cooked-tests-menu.el        the menu, and the commands it names
;;   cooked-tests-display.el     where a session lands, and the Emacs
;;                               subsystems `cooked-mode' answers for
;;   cooked-tests-comint.el      the VT filter on somebody else's comint buffer
;;   cooked-tests-module.el      provisioning the native core: digests, the
;;                               sidecar, and what is refused before it is mapped
;;   cooked-tests-bench.el       the benchmark's fixtures, against the protocol
;;
;; Run them all:
;;
;;   emacs -Q --batch -L lisp -L tests -l ert \
;;         -l cooked-tests.el -f ert-run-tests-batch-and-exit
;;
;; Or one subject, which is what you want while working on it:
;;
;;   emacs -Q --batch -L lisp -L tests -l ert \
;;         -l cooked-tests-glyph.el -f ert-run-tests-batch-and-exit
;;
;; Some tests guard themselves with `skip-unless' on an optional package -- `evil'
;; and `evil-collection', where most of the keyboard-ownership logic actually
;; shows.  Skipping is silent enough to be mistaken for passing, so the helpers go
;; looking for those in the usual install locations and say at load which, if any,
;; they could not find; `cooked-tests--optional-packages' is the list.  Nothing has
;; to be passed on the command line for them to run.
;;
;; Check the tail of the run for a SKIPPED list all the same: on a machine with
;; the packages installed there should be none.  For an install somewhere the
;; search does not reach, name it yourself:
;;
;;   E=~/.config/emacs/straight/build      # or ~/.emacs.d/elpa/evil-*
;;   emacs -Q --batch -L lisp -L tests -L $E/evil -L $E/goto-chg -l ert \
;;         -l cooked-tests.el -f ert-run-tests-batch-and-exit
;;
;; `goto-chg' is evil\='s one hard dependency.
;;
;; Every test that guards itself with a `skip-unless' also carries a `:tags' for
;; what it is guarding on -- `zsh', `bash', `fish', `evil', `consult', `tic' and so on --
;; so the platform axis can be selected on rather than discovered by reading a
;; hundred `skip-unless' forms.  A tag names a *dependency*, not a subject: what
;; a test is about is already answered by which file it lives in, and a second
;; taxonomy over the same tests would only drift from the first.  So:
;;
;;   make lisp-test SELECTOR='(not (tag zsh))'      # no zsh on this machine
;;   make lisp-test SELECTOR='(tag evil)'           # just the evil layer
;;
;; That is worth having because skipping is silent: on a machine without zsh,
;; fifty-odd tests skip and the run still says it passed.  Selecting them out
;; deliberately makes the absence a decision rather than a surprise.

;;; Code:

(require 'cooked-tests-helpers)
(require 'cooked-tests-session)
(require 'cooked-tests-render)
(require 'cooked-tests-input)
(require 'cooked-tests-dnd)
(require 'cooked-tests-history)
(require 'cooked-tests-consult)
(require 'cooked-tests-command-search)
(require 'cooked-tests-osc)
(require 'cooked-tests-osc-context)
(require 'cooked-tests-link)
(require 'cooked-tests-completion)
(require 'cooked-tests-glyph)
(require 'cooked-tests-next-error)
(require 'cooked-tests-sticky-scroll)
(require 'cooked-tests-command-decorations)
(require 'cooked-tests-menu)
(require 'cooked-tests-display)
(require 'cooked-tests-process)
(require 'cooked-tests-comint)
(require 'cooked-tests-module)
(require 'cooked-tests-bench)

;; Running one file's tests without loading only that file.
;;
;; Loading a single test file works and is documented above, but it is not what
;; a per-file `make' target can do: several files share fixtures through
;; `cooked-tests-helpers', and the set that does is not written down anywhere
;; that a makefile could read.  So the whole suite is loaded and the selector
;; does the narrowing, using the file ERT itself recorded when the test was
;; defined.  The cost is the load, which is a fraction of a second; the benefit
;; is that a per-file target cannot go stale as fixtures move between files.

(defun cooked-tests-run-file (file)
  "Run the tests defined in FILE and exit with their status.
Truenames on both sides, because ERT stores the path the file was loaded from
and a caller naming the same file through a symlink or a relative path is
naming the same tests."
  (let ((wanted (file-truename file)))
    (ert-run-tests-batch-and-exit
     `(satisfies
       ,(lambda (test)
          (let ((defined-in (ert-test-file-name test)))
            (and defined-in (equal (file-truename defined-in) wanted))))))))

;; The one test that is about the harness rather than about cooked.  It lives
;; here, beside the runner, because that is what it is part of; there is no
;; separate file for it because one test does not need a file.
(ert-deftest cooked-the-test-timeout-scale-only-accepts-a-positive-number ()
  "COOKED_TEST_TIMEOUT_SCALE multiplies every deadline in the suite, so a value
that parses to zero does not slow the suite down -- it expires every wait before
it is taken, fails every test that needs a child, and says nothing about why.
`string-to-number\=' reads both \"\" and \"wat\" as 0, and an empty value is the
ordinary accident: a CI configuration that declares the name without giving it
one, or a makefile that exports a variable it never set.  So the parser rejects
everything that is not a positive number and the caller falls back to 1."
  (should (equal 4 (cooked-tests--parse-timeout-scale "4")))
  (should (equal 2.5 (cooked-tests--parse-timeout-scale " 2.5 ")))
  (should-not (cooked-tests--parse-timeout-scale nil))
  (dolist (bad '("" "   " "0" "0.0" "-3" "wat" "4x" "1e3" "+4" ".5" "5." "inf"))
    (should-not (cooked-tests--parse-timeout-scale bad)))
  ;; And the scale actually in force is a positive number whatever the
  ;; environment this run inherited says.
  (should (numberp cooked-tests-timeout-scale))
  (should (> cooked-tests-timeout-scale 0))
  (should (equal (* 5 cooked-tests-timeout-scale) (cooked-tests-timeout 5))))

(ert-deftest cooked-the-test-suite-refuses-to-read-the-terminal ()
  "A batch read that would take its answer from stdin signals instead.

Under a pipe that is open and silent such a read blocks, and under `</dev/null'
`read-key\=' blocks too, so the suite stops with nothing on screen to say where.
A pushed event answers the event readers and is let through, but it does not
answer `read-from-minibuffer\=', which in batch reads stdin whatever is queued.
A refusal raised from a timer only prints, so it is recorded as well, and the
session fixtures fail the test that left one behind."
  (let ((cooked-tests--refused-reads nil))
    (let ((unread-command-events (list ?a ?\r)))
      (should-error (read-from-minibuffer "Name: ") :type 'cooked-tests-terminal-read))
    (should-error (read-string "Name: ") :type 'cooked-tests-terminal-read)
    (should-error (read-passwd "Password: ") :type 'cooked-tests-terminal-read)
    (should-error (read-key "Send key: ") :type 'cooked-tests-terminal-read)
    (should-error (read-event) :type 'cooked-tests-terminal-read)
    (let ((unread-command-events (list ?a)))
      (should (eq ?a (read-event))))
    (should (equal (mapcar #'car cooked-tests--refused-reads)
                   '(read-event read-key read-string read-string read-from-minibuffer))))
  ;; From a timer, inside a session: the error is swallowed where it is raised,
  ;; and the fixture still fails the test.
  (should-error
   (cooked-tests--with-session '("/bin/sh" "-c" "exec cat")
     (run-at-time 0 nil (lambda () (ignore-errors (read-passwd "Password: "))))
     (cooked-tests--pump 0.2))
   :type 'ert-test-failed))

(ert-deftest cooked-the-test-timeout-scale-reaches-every-wait ()
  "Each wait loop in the suite stretches its deadline by the scale.

A loop that reads its SECONDS raw keeps the idle-laptop bet the scale exists to
correct, and three did: `cooked-tests--run-until-dead\=',
`cooked-tests--pump-wakes\=' and `cooked-tests--split-settle\='.  Each is given
a tenth of a second that nothing will cut short under a scale of four, and has
to take at least four tenths."
  (let ((cooked-tests-timeout-scale 4))
    (dolist (wait (list (lambda () (cooked-tests--settle #'ignore 0.1))
                        (lambda () (cooked-tests--pump 0.1))
                        (lambda () (cooked-tests--pump-wakes #'ignore 0.1))
                        (lambda ()
                          (cooked-tests--with-session '("/bin/sh" "-c" "exec cat")
                            (cooked-tests--split-settle #'ignore 0.1)))
                        (lambda ()
                          (cooked-tests--run-until-dead '("/bin/sh" "-c" "exec cat") 0.1))))
      (let ((start (float-time)))
        (funcall wait)
        (should (>= (- (float-time) start) 0.4))))))

;; What a `skip-unless' is waiting for, read off its condition.  Only the
;; spellings that name a dependency count; a skip on `display-graphic-p' or on a
;; file the checkout may lack describes the run rather than the machine, and
;; carries no tag.
(defun cooked-tests--skip-dependencies (form)
  "Return the dependencies the `skip-unless' forms inside FORM wait for.
Each is the symbol its tag would be: (skip-unless (executable-find \"zsh\"))
gives `zsh', and (skip-unless (require \\='evil nil t)) gives `evil'."
  (let ((found nil))
    (cl-labels ((condition (form)
                  (pcase form
                    (`(executable-find ,(and (pred stringp) name))
                     (push (intern name) found))
                    (`(,(or 'require 'featurep) (quote ,feature) . ,_)
                     (push feature found))
                    ('(cooked-tests--tmux) (push 'tmux found))
                    ('(cooked--terminfo-database) (push 'terminfo found))
                    ((pred proper-list-p) (mapc #'condition form))))
                (walk (form)
                  (pcase form
                    (`(skip-unless ,guard) (condition guard))
                    ((pred consp)
                     (while (consp form) (walk (pop form)))))))
      (walk form))
    (delete-dups found)))

(ert-deftest cooked-every-dependency-skip-carries-its-tag ()
  "A test that skips without some dependency is tagged with it.

The tags are how a run selects out what a machine lacks, and a skip reads as a
pass, so an untagged one is coverage nobody can see is missing.  The convention
had no check and eroded twice: the fish tests added with vendor injection, and
`cooked-evil-does-not-blank-a-row-of-spaces\=', which also asked `featurep\='
rather than requiring evil and so skipped whenever it ran alone.  The walk reads
every test file the suite loaded and expands its macros, so a skip hidden
inside a fixture counts too.

Each dependency must also be one the helpers name at load when it is missing,
`cooked-tests--optional-programs\=' or `cooked-tests--optional-packages\=', so
a new kind of skip cannot arrive silent."
  (let ((files (delete-dups (delq nil (mapcar #'ert-test-file-name
                                              (ert-select-tests t t)))))
        ;; Leave `skip-unless' itself unexpanded, so the walk can still see it.
        (environment (cons '(skip-unless) macroexpand-all-environment))
        ;; What the helpers name at load when it is missing.  The terminfo
        ;; database is this checkout's own, and says so itself.
        (announced (append cooked-tests--optional-programs
                           cooked-tests--optional-packages))
        (skips 0)
        (untagged nil))
    (dolist (file files)
      (with-temp-buffer
        (insert-file-contents file)
        (condition-case nil
            (while t
              (pcase (read (current-buffer))
                (`(ert-deftest ,name ,_ . ,body)
                 (let ((tags (ert-test-tags (ert-get-test name))))
                   (dolist (dependency (cooked-tests--skip-dependencies
                                        (macroexpand-all (cons 'progn body)
                                                         environment)))
                     (setq skips (1+ skips))
                     (unless (and (memq dependency tags)
                                  (or (eq dependency 'terminfo)
                                      (member (symbol-name dependency) announced)))
                       (push (list name dependency) untagged)))))))
          (end-of-file nil))))
    ;; A walk that found nothing would pass as well; there are over a hundred.
    (should (> skips 100))
    (should-not untagged)))

(provide 'cooked-tests)
;;; cooked-tests.el ends here
