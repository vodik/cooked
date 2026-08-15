;;; cooked-project.el --- Project-scoped cooked sessions -*- lexical-binding: t; -*-

;;; Commentary:

;; Opt-in, like cooked-evil and cooked-osc-eval:
;;
;;   (use-package cooked
;;     :commands (cooked cooked-other-window
;;                cooked-project cooked-project-other-window
;;                cooked-here cooked-here-other-window)
;;     :config (require 'cooked-project))
;;
;; `cooked-project' is to `cooked' what `project-shell' is to `shell': a session
;; scoped to the current project's root instead of wherever `default-directory'
;; happens to be.  `cooked-here' is the lenient sibling, for buffers that are
;; not in a recognized project (a scratch buffer, a stray directory) -- it
;; uses the project root when there is one, `default-directory' otherwise,
;; and never prompts to pick or create a project the way `(project-current t)'
;; does.
;;
;; Reuse is decided by where a live session's shell actually is right now --
;; OSC 7 keeps `default-directory' in sync with the child, so a session that
;; has since `cd'd out of the target directory is not reused, and one that
;; has `cd'd into it is, even if it did not start there.

;;; Code:

(require 'project)
(require 'cooked)

(declare-function cooked--display "cooked-mode")
(declare-function cooked--start-session "cooked-mode")
;; The reuse rule described in the commentary above, and not a second copy of
;; it: `cooked--session-in-directory' is the same question `cooked-bookmark-jump'
;; asks, so the two ask it of the one function.  Reached only from
;; `cooked-project--session', which requires cooked-mode first.
(declare-function cooked--session-in-directory "cooked-mode")

(defun cooked-project--session (root new display-action)
  "Display a cooked session rooted at ROOT, reusing one unless NEW.

Passes DISPLAY-ACTION to `cooked--display'."
  (require 'cooked-mode)
  (let ((default-directory root))
    (cooked--display (or (unless new (cooked--session-in-directory root))
                         (cooked--start-session))
                     display-action)))

(defun cooked-project--here-root ()
  "The current project's root, or `default-directory' if there is none."
  (if-let* ((proj (project-current)))
      (project-root proj)
    default-directory))

;;;###autoload
(defun cooked-project (&optional new)
  "Switch to a cooked session in the current project's root.

Reuses a live session already there; with a prefix argument, or NEW non-nil,
always start another one instead.  Prompts to pick or create a project if
the current buffer is not already in one -- see `cooked-here' for a variant
that does not."
  (interactive "P")
  (cooked-project--session (project-root (project-current t)) new
                           cooked-display-action))

;;;###autoload
(defun cooked-project-other-window (&optional new)
  "Like `cooked-project', but display the session in another window.

NEW means what it does there."
  (interactive "P")
  (cooked-project--session (project-root (project-current t)) new
                           cooked-other-window-action))

;;;###autoload
(defun cooked-here (&optional new)
  "Switch to a cooked session rooted at the current project, or here.

Like `cooked-project', but never prompts: falls back to `default-directory'
when the current buffer is not in a recognized project.  NEW means what it
does there."
  (interactive "P")
  (cooked-project--session (cooked-project--here-root) new
                           cooked-display-action))

;;;###autoload
(defun cooked-here-other-window (&optional new)
  "Like `cooked-here', but display the session in another window.

NEW means what it does there."
  (interactive "P")
  (cooked-project--session (cooked-project--here-root) new
                           cooked-other-window-action))

;;;; The project dispatch menu
;;
;; `project-switch-project' (`C-x p p') offers whatever is in
;; `project-switch-commands', and a terminal in the project you have just
;; switched to is one of the two or three things anyone wants from that menu.
;; Registering is the whole of the integration: the dispatch binds
;; `default-directory' to the chosen root before it runs the command, so
;; `cooked-project' finds the project it was chosen for without being told.
;;
;; The key is given explicitly rather than left to be looked up.  A nil KEY
;; means `project-switch-commands' reads it out of `project-prefix-map', which
;; would make registering here imply taking `t' out of that map as well -- and
;; `project-prefix-map' is a shared global whose bindings are the user's to
;; spend.  Users who do want `C-x p t' can spend it themselves:
;;
;;   (keymap-set project-prefix-map "t" #'cooked-project)
;;
;; Idempotent, because this file is `require'd from a `:config' block and
;; those get re-evaluated.  Checked by command rather than by whole entry so
;; that a label or key the user has since edited is left as they left it.

(defconst cooked-project--switch-entry '(cooked-project "Terminal" ?t)
  "The `project-switch-commands\=' entry `cooked-project.el\=' installs.")

(unless (assq 'cooked-project project-switch-commands)
  (add-to-list 'project-switch-commands cooked-project--switch-entry t))

;; `project-prefixed-buffer-name' is what `project-shell' and `project-eshell'
;; name their buffers with, and it is deliberately not used here.  Two reasons,
;; and the second is the one that decides it.
;;
;; The name of a cooked buffer is `cooked-buffer-name''s to say, from the
;; moment the buffer is made and again on every OSC 7 and OSC 0/2 that
;; `cooked-buffer-name-auto-update' lets through.  A name imposed from out here
;; would therefore last exactly until the child first announced a directory or a
;; title, and then revert -- so the two schemes cannot both be in force, and the
;; one the user configured should win.  The default template prints the
;; abbreviated working directory anyway, which for a session started here is the
;; project root: the project is already in the name.
;;
;; And the prefixed name is load-bearing for `project-shell' in a way it would
;; not be here.  That command finds its existing buffer *by* the name, so the
;; name has to be a fixed function of the project.  Reuse in this file is
;; decided by where a live session's shell actually is right now -- see the
;; commentary -- which follows a `cd' and does not care what the buffer is
;; called.  Nothing would read the prefix, so it would buy a naming
;; inconsistency and no lookup.

(provide 'cooked-project)
;;; cooked-project.el ends here
