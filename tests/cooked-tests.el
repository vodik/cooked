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
;; what it is guarding on -- `zsh', `bash', `fish', `evil', `tic' and so on --
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
(require 'cooked-tests-osc)
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
  (dolist (bad '("" "   " "0" "0.0" "-3" "wat" "4x" "1e3" "inf"))
    (should-not (cooked-tests--parse-timeout-scale bad)))
  ;; And the scale actually in force is a positive number whatever the
  ;; environment this run inherited says.
  (should (numberp cooked-tests-timeout-scale))
  (should (> cooked-tests-timeout-scale 0))
  (should (equal (* 5 cooked-tests-timeout-scale) (cooked-tests-timeout 5))))

(provide 'cooked-tests)
;;; cooked-tests.el ends here
