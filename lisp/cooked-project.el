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

(require 'seq)
(require 'project)
(require 'cooked)

(declare-function cooked--display "cooked-mode")
(declare-function cooked--start-session "cooked-mode")
(declare-function cooked--live-buffers "cooked-mode")

(defun cooked-project--buffer (root)
  "The most recently used live session whose shell is in ROOT, if any."
  (seq-find (lambda (buffer)
              (with-current-buffer buffer
                (file-equal-p default-directory root)))
            (cooked--live-buffers)))

(defun cooked-project--session (root new display-action)
  "Display a cooked session rooted at ROOT, reusing one unless NEW.

Passes DISPLAY-ACTION to `cooked--display'."
  (require 'cooked-mode)
  (let ((default-directory root))
    (cooked--display (or (unless new (cooked-project--buffer root))
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

(provide 'cooked-project)
;;; cooked-project.el ends here
