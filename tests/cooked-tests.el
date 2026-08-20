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
;;   cooked-tests-osc.el         the sequences answered in Lisp
;;   cooked-tests-completion.el  both completion backends
;;   cooked-tests-glyph.el       the rasterizer, against pixels
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
;; The `evil' tests guard themselves with `(skip-unless (require \='evil nil t))',
;; and `-Q' means they will skip: nothing is on the load path but what is passed
;; in.  Skipping is silent enough to be mistaken for passing, and the evil
;; integration is where most of the keyboard-ownership logic actually shows, so
;; point the run at an installed copy to exercise it:
;;
;;   E=~/.config/emacs/straight/build      # or ~/.emacs.d/elpa/evil-*
;;   emacs -Q --batch -L lisp -L tests -L $E/evil -L $E/goto-chg -l ert \
;;         -l cooked-tests.el -f ert-run-tests-batch-and-exit
;;
;; `goto-chg' is evil\='s one hard dependency.  Check the tail of the run for a
;; SKIPPED list: with evil found there should be none.

;;; Code:

(require 'cooked-tests-helpers)
(require 'cooked-tests-session)
(require 'cooked-tests-render)
(require 'cooked-tests-input)
(require 'cooked-tests-osc)
(require 'cooked-tests-completion)
(require 'cooked-tests-glyph)

(provide 'cooked-tests)
;;; cooked-tests.el ends here
