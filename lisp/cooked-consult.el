;;; cooked-consult.el --- A terminal picker, through consult -*- lexical-binding: t; -*-

;;; Commentary:

;; Opt-in, like cooked-evil and cooked-project:
;;
;;   (use-package cooked
;;     :commands (cooked cooked-other-window consult-cooked)
;;     :config (require 'cooked-consult))
;;
;; `consult-buffer' already reaches cooked buffers, among every other buffer
;; there is.  `consult-cooked' is a picker for terminals only: this project's
;; first, then the rest, each previewed in the window as the selection moves over
;; it, and each annotated with what the session is doing -- the running command,
;; or the last one's failure, the title, the directory and the input mode.  A name
;; that matches no terminal starts a session called that, so the picker is also
;; how a named terminal is made.  With a prefix argument it is `cooked' itself.
;;
;; Requiring this also puts a hidden source into `consult-buffer' and
;; `consult-project-buffer', summoned by the `t' narrow key, so that a picker
;; already bound to a key can be asked for terminals without a second key.
;; Opt out by taking it back out:
;;
;;   (setq consult-buffer-sources
;;         (delq 'cooked-consult-source-hidden consult-buffer-sources))
;;
;; The annotations are not this file's.  They are completion metadata defined
;; beside the mode line -- see `cooked-buffer-annotation' -- and reach vertico,
;; the default completion UI and anything else through
;; `cooked-buffer-completion-table' with consult nowhere in sight.  This file is
;; the only one in the tree that knows consult exists, and it keeps that
;; knowledge to itself: nothing below it names consult, and consult itself is not
;; required until it is used, which is also what lets this file compile on a
;; machine that does not have it.
;;
;; Candidates carry the `cooked-buffer' category rather than `buffer'; the table's
;; docstring says why, and what that costs.

;;; Code:

(require 'cooked-mode)

;; consult is `require'd by the commands below and the sources register once it is
;; loaded, never at this file's load: a top-level `require' would be evaluated by
;; the byte-compiler too, and `make compile' runs under -Q, where consult is not on
;; `load-path'.  cooked-evil.el stands in the same relation to evil.
(defvar consult-buffer-sources)
(defvar consult-project-buffer-sources)
(defvar consult-project-function)
(defvar consult--buffer-display)
(declare-function consult--multi "ext:consult" (sources &rest options))
(declare-function consult--buffer-query "ext:consult" (&rest args))
(declare-function consult--buffer-pair "ext:consult" (buffer))
(declare-function consult--buffer-state "ext:consult" ())
(declare-function consult--project-root "ext:consult" (&optional may-prompt))

(defvar cooked-consult--history nil
  "Minibuffer history for `consult-cooked'.")

(defun cooked-consult--pairs (&optional root outside)
  "Cooked buffers as consult (NAME . BUFFER) pairs, in switching order.

Those whose shell is under ROOT when it is non-nil, and with OUTSIDE those
whose shell is not.  Under means `default-directory', which OSC 7 keeps where
the shell is *now*: a session that has `cd'd out of the project is not one of
its terminals any more, which is the rule `cooked-project' reuses a session
by.  Through `consult--buffer-query', so `consult-buffer-filter' and the
visibility sort apply here as they do in `consult-buffer'."
  (let ((inside (and root
                     (mapcar #'cdr (consult--buffer-query :mode 'cooked-mode
                                                          :directory root
                                                          :as #'consult--buffer-pair)))))
    (consult--buffer-query
     :mode 'cooked-mode
     :sort 'visibility
     :directory (and root (not outside) root)
     :predicate (and outside (lambda (buffer) (not (memq buffer inside))))
     :as #'consult--buffer-pair)))

(defun cooked-consult--new (name &optional directory)
  "Start a session named NAME in DIRECTORY, or here, and display it.

The create half of create-on-miss.  A blank NAME, which is what submitting an
empty prompt with nothing to default to sends, gets the name
`cooked-buffer-name' gives every session.  A NAME given here lasts only until
the shell reports a directory if `cooked-buffer-name-auto-update' is on, for the
reason cooked-project.el gives about imposed names: the template is the
user's, and it wins.

Displayed through `consult--buffer-display', so
`consult-cooked-other-window' places a new session where it would have placed
a picked one, and then sized: a session is started before it has a window,
which is what `cooked--display' does the same thing for."
  (let* ((default-directory (or directory default-directory))
         (buffer (cooked--start-session)))
    (unless (string-blank-p name)
      (with-current-buffer buffer
        (rename-buffer (generate-new-buffer-name name))))
    (funcall consult--buffer-display buffer)
    (with-current-buffer buffer
      (cooked--sync-size))
    buffer))

(defvar cooked-consult-source-project
  `( :name     "Project Terminal"
     :narrow   ?p
     :category cooked-buffer
     :face     consult-buffer
     :history  buffer-name-history
     :annotate ,#'cooked-buffer-annotation
     :state    ,#'consult--buffer-state
     ;; The root rather than `consult-project-function', which is what consult's
     ;; own project source asks: that says only that projects can be found, and
     ;; an enabled source is the one a miss is created from, so outside a
     ;; project the miss would prompt for one instead of starting a session here.
     :enabled  ,(lambda () (consult--project-root))
     :new      ,(lambda (name)
                  (cooked-consult--new name (consult--project-root)))
     :items    ,(lambda ()
                  (when-let* ((root (consult--project-root)))
                    (cooked-consult--pairs root))))
  "A consult source for the cooked sessions whose shell is in this project.

A name that matches nothing starts a session at the project root.")

(defvar cooked-consult-source-other
  `( :name     "Terminal"
     :narrow   ?o
     :category cooked-buffer
     :face     consult-buffer
     :history  buffer-name-history
     :annotate ,#'cooked-buffer-annotation
     :state    ,#'consult--buffer-state
     :new      ,#'cooked-consult--new
     :items    ,(lambda ()
                  (cooked-consult--pairs (consult--project-root) t)))
  "A consult source for the cooked sessions not in this project.

All of them outside a project.  The complement of
`cooked-consult-source-project' rather than every terminal, so that the two
groups of `consult-cooked' list each session once.  A name that matches
nothing starts a session in `default-directory'; consult creates a miss from
this source only outside a project or when narrowed to it.")

(defvar cooked-consult-source
  `( :name     "Terminal"
     :narrow   ?t
     :category cooked-buffer
     :face     consult-buffer
     :history  buffer-name-history
     :annotate ,#'cooked-buffer-annotation
     :state    ,#'consult--buffer-state
     :new      ,#'cooked-consult--new
     :items    ,(lambda () (cooked-consult--pairs)))
  "A consult source for every cooked session.")

;; `copy-sequence', or the spliced tail would be shared structure with the source
;; it was copied from, and `consult-customize' on one would change the other.
;; The leading keys win because `plist-get' stops at the first match.
(defvar cooked-consult-source-hidden
  `( :hidden t :narrow (?t . "Terminal")
     ,@(copy-sequence cooked-consult-source))
  "Like `cooked-consult-source', but hidden until narrowed to.
Registered in `consult-buffer-sources' when consult loads.")

(defvar cooked-consult-source-project-hidden
  `( :hidden t :narrow (?t . "Terminal")
     ,@(copy-sequence cooked-consult-source-project))
  "Like `cooked-consult-source-project', but hidden until narrowed to.
Registered in `consult-project-buffer-sources' when consult loads.")

;; Idempotent, because this file is `require'd from a `:config' block and those
;; get re-evaluated; and appended, so a terminal source never displaces one the
;; user put first.
(with-eval-after-load 'consult
  (add-to-list 'consult-buffer-sources 'cooked-consult-source-hidden t)
  (add-to-list 'consult-project-buffer-sources 'cooked-consult-source-project-hidden t))

(defun cooked-consult--pick (display)
  "Pick a terminal through `consult--multi', switching to it with DISPLAY.

DISPLAY is bound as `consult--buffer-display' for the preview, the switch and a
session created on a miss alike.  With no terminals at all the picker still
opens, unlike `cooked-project' refusing outside a project: an empty list is
the ordinary way to make the first one, by typing its name."
  (require 'consult)
  (let ((consult--buffer-display display))
    (consult--multi '(cooked-consult-source-project cooked-consult-source-other)
                    :require-match (confirm-nonexistent-file-or-buffer)
                    :prompt "Terminal: "
                    :history 'cooked-consult--history
                    :sort nil)))

;;;###autoload
(defun consult-cooked (&optional new)
  "Switch to a terminal, previewing each as the selection moves over it.

This project's sessions first, then the rest; `p' and `o' narrow to either
group.  A name that matches no session starts one called that -- at the
project root when there is a project, otherwise in `default-directory'.

With a prefix argument, or NEW non-nil, this is `cooked' instead: always start
another session, with no picker."
  (interactive "P")
  (if new
      (cooked new)
    (cooked-consult--pick #'switch-to-buffer)))

;;;###autoload
(defun consult-cooked-other-window (&optional new)
  "Like `consult-cooked', but display the terminal in another window.

NEW means what it does there, and makes this `cooked-other-window'."
  (interactive "P")
  (if new
      (cooked-other-window new)
    (cooked-consult--pick #'switch-to-buffer-other-window)))

(provide 'cooked-consult)
;;; cooked-consult.el ends here
