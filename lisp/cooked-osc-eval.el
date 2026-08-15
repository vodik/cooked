;;; cooked-osc-eval.el --- the OSC 51 command channel for cooked -*- lexical-binding: t; -*-

;;; Commentary:

;; Opt-in, and worth understanding before you do:
;;
;;   (use-package cooked
;;     :commands (cooked cooked-other-window)
;;     :config (require 'cooked-osc-eval))
;;
;; This lets the shell ask the Emacs running it to do things:
;;
;;   find_file src/main.rs        # opens it in the same Emacs
;;   magit .                      # magit-status on the repo
;;
;; It is OSC 51;E, vterm's protocol, so existing vterm shell configuration mostly
;; works.
;;
;; The reason it is a separate file is that this is a command channel driven by
;; bytes on a terminal, and a terminal will happily print whatever it is given.
;; `cat' of a hostile file, output from a compromised host over ssh, a build log
;; quoting text somebody else chose — all of them can pull the trigger.  The
;; allowlist below is the entire defence, which is why it maps names to functions
;; rather than interning whatever arrived.  Loading this file is the moment you
;; accept that trade; leaving it unloaded is a real and reasonable answer.

;;; Code:

(require 'cooked)

(declare-function magit-status "magit-status")

(defcustom cooked-eval-commands
  '(("find-file" . find-file)
    ("find-file-other-window" . find-file-other-window)
    ("dired" . dired)
    ("magit-status" . magit-status)
    ("message" . message)
    ("update-pwd" . cooked-osc-eval-update-pwd)
    ("clear-scrollback" . cooked-clear-scrollback)
    ;; vterm spells this one differently; accept both so existing shell
    ;; configuration keeps working.
    ("vterm-clear-scrollback" . cooked-clear-scrollback))
  "Commands the child may invoke through OSC 51;E, by name.

Deliberately conservative.  `compile' and `recompile' are absent because
they run arbitrary shell commands: adding them turns any text that
reaches your terminal into remote code execution.  Add them only if you
accept that:

  (add-to-list \\='cooked-eval-commands \\='(\"compile\" . compile))

`magit-status' deserves a note of its own.  It looks like a viewer, but
running git against a repository someone else chose is closer to
`compile' than it appears: `git status' executes `core.fsmonitor' from
that repository's own .git/config, and other git operations honour
`core.pager' and `core.sshCommand' the same way.  It is here because it
is genuinely useful and you have already opted into this file; remove it
if that reasoning does not persuade you."
  :type '(alist :key-type string :value-type function)
  :group 'cooked)

(defun cooked-osc-eval-update-pwd (directory)
  "Set `default-directory' to DIRECTORY, as reported by the shell."
  (when (file-directory-p directory)
    (setq default-directory (file-name-as-directory directory))))

(defun cooked-osc-eval-request (payload)
  "Run the allowlisted command described by PAYLOAD, a quoted argument list."
  (let* ((args (ignore-errors (split-string-and-unquote payload)))
         (name (car args))
         (command (cdr (assoc name cooked-eval-commands))))
    (cond
     ((null args) nil)
     ((null command)
      (message "cooked: refused `%s' (not in `cooked-eval-commands')" name))
     (t (apply command (cdr args))))))

(setq cooked-osc-eval-function #'cooked-osc-eval-request)

(provide 'cooked-osc-eval)
;;; cooked-osc-eval.el ends here
