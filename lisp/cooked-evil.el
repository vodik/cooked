;;; cooked-evil.el --- evil integration for cooked -*- lexical-binding: t; -*-

;;; Commentary:

;; Opt-in.  Require it yourself:
;;
;;   (use-package cooked
;;     :commands (cooked cooked-other-window)
;;     :config (require 'cooked-evil))
;;
;; What it does is narrow, because it turns out very little is needed.  A
;; full-screen program wants every keystroke, so evil must not be sitting in
;; normal state swallowing them; at a prompt evil should behave as it does in any
;; other buffer.  Following that one distinction is the whole of the integration.
;;
;; Deliberately absent: state-specific key bindings.  RET reaches
;; `cooked-send-input' through `cooked-input-map' in insert state, and in normal
;; state RET stays `evil-ret' — a normal-state RET that submitted was more
;; surprising than useful.  `C-c C-c' needs nothing either, since evil's normal
;; state does not bind `C-c' and so already falls through to the local map.
;;
;; `evil-collection' is the exception, and it needs one binding of our own.
;; `evil-collection-comint' binds RET for every comint buffer, and because
;; `cooked-mode' derives from `comint-mode' that reaches us through the keymap
;; parent chain, where it outranks the plain local map.  Its default,
;; `evil-collection-repl-submit-state' = `normal', hands insert-state RET to
;; `newline' — so Enter stops submitting and starts inserting a line break.
;;
;; Rather than ask everyone to set a global variable, or to turn
;; `evil-collection-comint' off and lose the rest of it, `cooked-evil' binds RET
;; on `cooked-input-map' itself.  Evil layers auxiliary keymaps rather than
;; letting the nearest one shadow the rest, so this overrides exactly RET and
;; leaves the rest of `evil-collection-comint' — history on the arrow keys,
;; prompt navigation — working.  Those all route through comint commands, which
;; `cooked-mode-map' already remaps onto cooked's own.
;;
;; See `cooked-evil-insert-state-submits' to turn that off.

;;; Code:

(require 'cooked-mode)

(defvar evil-state)
(declare-function evil-insert-state "evil-states")
(declare-function evil-emacs-state "evil-states")

(defcustom cooked-evil-integration t
  "Whether to drive evil's state from who owns the keyboard.
While the child owns it, evil is put in Emacs state so keys are not intercepted;
in the input state evil returns to normal editing."
  :type 'boolean :group 'cooked)

(defun cooked-evil-sync ()
  "Match evil's state to who owns the keyboard.
A TUI needs every keystroke, so evil must not be interpreting them; at a prompt
evil should behave as in any other buffer."
  (when (and cooked-evil-integration (bound-and-true-p evil-local-mode))
    (let ((state (bound-and-true-p evil-state)))
      (if (cooked--input-state-p)
          (when (eq state 'emacs) (evil-insert-state))
        (unless (eq state 'emacs) (evil-emacs-state))))))

(add-hook 'cooked-state-change-hook #'cooked-evil-sync)

(provide 'cooked-evil)
;;; cooked-evil.el ends here
