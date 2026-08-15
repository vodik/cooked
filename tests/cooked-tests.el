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
;;   cooked-tests-link.el        URLs, OSC 8 hyperlinks, the optional file layer
;;   cooked-tests-completion.el  both completion backends
;;   cooked-tests-glyph.el       the rasterizer, against pixels
;;   cooked-tests-next-error.el  next-error over a command's output
;;   cooked-tests-sticky-scroll.el       the sticky-scroll header line
;;   cooked-tests-command-decorations.el the fringe dot per command
;;   cooked-tests-menu.el        the menu, and the commands it names
;;   cooked-tests-display.el     where a session lands, and the Emacs
;;                               subsystems `cooked-mode' answers for
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

;;; Code:

(require 'cooked-tests-helpers)
(require 'cooked-tests-session)
(require 'cooked-tests-render)
(require 'cooked-tests-input)
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
(require 'cooked-tests-bench)

(provide 'cooked-tests)
;;; cooked-tests.el ends here
