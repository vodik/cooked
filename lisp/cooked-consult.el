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
;; `consult-cooked-command' is `cooked-command-search' through consult: every
;; buffer's commands, the running ones first, previewed as the selection moves,
;; with `f', `s' and `r' narrowing to the failed, the succeeded and the running.
;; It loads cooked-command-search when it runs, so the terminal picker alone
;; never does.
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

;;;; Commands

;; cooked-command-search is its own opt-in layer, and asking for this picker is
;; opting in: it is `require'd when the command runs rather than when this file
;; loads, so a user of the terminal picker alone never loads it.
(declare-function consult--read "ext:consult" (table &rest options))
(declare-function consult--jump-preview "ext:consult" ())
(defvar consult--narrow)
(declare-function cooked-command-search--candidates "cooked-command-search" (&optional filter))
(declare-function cooked-command-search--table "cooked-command-search" (candidates))
(declare-function cooked-command-search--lookup "cooked-command-search" (string candidates))
(declare-function cooked-command-search--buffer "cooked-command-search" (candidate))
(declare-function cooked-command-search--status "cooked-command-search" (candidate))
(declare-function cooked-command-search--running-p "cooked-command-search" (candidate))
(declare-function cooked-command-search--finished-command "cooked-command-search" (candidate))
(declare-function cooked-command-search-do "cooked-command-search" (candidate action))

(defconst cooked-consult--command-narrow
  '((?f failed "Failed") (?s succeeded "Succeeded") (?r running "Running"))
  "The narrow keys of `consult-cooked-command', as (KEY STATUS LABEL).
STATUS is what `cooked-command-search--status' answers for the candidates the
key keeps.")

(defun cooked-consult--command-matches-narrow-p (string)
  "Whether the candidate STRING belongs under the narrow key in force.

Reads the candidate off the string's `cooked-command-search' property, which
consult keeps where plain completion would not.  Called only while a key is in
force, so an unknown key keeps nothing rather than everything."
  (eq (nth 1 (assq consult--narrow cooked-consult--command-narrow))
      (cooked-command-search--status
       (get-text-property 0 'cooked-command-search string))))

(defun cooked-consult--command-preview ()
  "A consult state function previewing a command candidate in its own buffer.

`consult--jump-preview' wants a marker and the candidates carry none, so one is
made for the candidate under the selection and released when the next one is.
The candidate arrives as the object `:lookup' found, not as its string.  A
running command previews at its live tail, where the jump would land; a
finished one at its prompt."
  (let ((jump (consult--jump-preview))
        (marker nil))
    (lambda (action candidate)
      (when marker
        (set-marker marker nil)
        (setq marker nil))
      (when-let* (((eq action 'preview))
                  (candidate candidate)
                  (buffer (cooked-command-search--buffer candidate))
                  ((buffer-live-p buffer)))
        (setq marker
              (with-current-buffer buffer
                (copy-marker
                 (if (cooked-command-search--running-p candidate)
                     (point-max)
                   (let ((command (cooked-command-search--finished-command candidate)))
                     (or (cooked--command-prompt-position command)
                         (cooked--command-start-position command))))))))
      (funcall jump action marker))))

;;;###autoload
(defun consult-cooked-command ()
  "Jump to a command run in any cooked buffer, previewing each on the way.

`cooked-command-search' through consult: the same candidates, running commands
first, grouped by buffer and annotated alike, with \\`f', \\`s' and \\`r'
narrowing to the failed, the succeeded and the running.  A finished command is
jumped to at its prompt, a running one at its live tail."
  (interactive)
  (require 'consult)
  (require 'cooked-command-search)
  (let* ((candidates (or (cooked-command-search--candidates)
                         (user-error "cooked: no commands in any buffer")))
         (metadata (completion-metadata
                    "" (cooked-command-search--table candidates) nil)))
    ;; Nil when nothing matched under the narrowing in force.
    (when-let* ((candidate
                 (consult--read
                  candidates
                  :prompt "Command: "
                  :category 'cooked-command
                  :sort nil
                  :require-match t
                  :group (completion-metadata-get metadata 'group-function)
                  :annotate (completion-metadata-get metadata 'annotation-function)
                  :lookup (lambda (selected candidates &rest _)
                            (cooked-command-search--lookup selected candidates))
                  :narrow (list :predicate #'cooked-consult--command-matches-narrow-p
                                :keys (mapcar (lambda (entry)
                                                (cons (car entry) (nth 2 entry)))
                                              cooked-consult--command-narrow))
                  :state (cooked-consult--command-preview))))
      (cooked-command-search-do candidate 'jump))))

(provide 'cooked-consult)
;;; cooked-consult.el ends here
