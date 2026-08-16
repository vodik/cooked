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
;; Almost no state-specific key bindings, and for a reason.  RET reaches
;; `cooked-send-input' through `cooked-input-map' in insert state, and in normal
;; state RET stays `evil-ret' — a normal-state RET that submitted was more
;; surprising than useful.  `C-c C-c' needs nothing either, since evil's normal
;; state does not bind `C-c' and so already falls through to the local map.
;;
;; One binding earns its place: `p'.  A full-screen program's own paste key
;; pastes its own registers — `p' inside vim never sees anything Emacs copied —
;; so reaching the kill ring needs a key Emacs still owns, and normal state is
;; where one is going spare.  At a prompt it stays evil's own paste; see
;; `cooked-evil-normal-state-pastes'.
;;
;; `evil-collection' is the exception, and it needs one binding of our own.
;; `evil-collection-comint' binds RET for every comint buffer via `evil-define-key',
;; which does not edit `comint-mode-map' in place — it registers an auxiliary
;; keymap that evil consults *ahead of* every buffer's ordinary local map,
;; `cooked-input-map' included.  A plain `(define-key cooked-input-map ...)`
;; therefore never gets a look at RET at all; verified directly against a real
;; evil-collection install, an evil-collection auxiliary keymap shadowing
;; `cooked-input-map' in `current-active-maps' before it is ever reached.  And
;; `evil-collection-repl-submit-state' defaults to `normal', which hands
;; insert-state RET to `newline' — so Enter stops submitting and starts
;; inserting a line break.
;;
;; The fix has to answer evil on its own terms: register our own override the
;; same way, via `evil-collection-define-key' on `cooked-mode-map' rather than
;; `comint-mode-map'.  Evil resolves which auxiliary keymap wins by walking the
;; buffer's own local-map chain, most specific first, so the override tied to
;; `cooked-mode-map' — the derived, more specific mode — outranks the one tied
;; to `comint-mode-map', while everything else `evil-collection-comint' set up
;; — history on the arrow keys, prompt navigation — keeps working, since those
;; route through comint commands that `cooked-mode-map' already remaps onto
;; cooked's own.
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

(defcustom cooked-evil-insert-state-submits t
  "Whether Enter submits input even under `evil-collection'.

`evil-collection-comint' registers RET, <return> and C-m -- the spellings a
terminal, a GUI frame, and a literal control character each produce for the
same key -- on an evil auxiliary keymap tied to `comint-mode-map', which evil
consults ahead of any buffer's ordinary local map; a plain `define-key' on
`cooked-mode-map' or `cooked-input-map' cannot outrank it.  Its default state
for that binding is `normal', which hands insert-state Enter to `newline'
instead of submitting.

Non-nil answers on the same terms, via `evil-collection-define-key' on
`cooked-mode-map' rather than `comint-mode-map'.  Evil resolves competing
auxiliary keymaps by walking the buffer's own local-map chain most specific
first, so the override tied to `cooked-mode-map' -- the derived mode -- wins,
and everything else `evil-collection-comint' set up keeps working."
  :type 'boolean :group 'cooked)

(defcustom cooked-evil-normal-state-pastes t
  "Whether normal-state \\`p' and \\`P' paste into a full-screen program.

A program's own paste key pastes its own registers: `p' inside vim reaches vim's
clipboard, and nothing Emacs copied is in it.  Getting the kill ring — and so
the system clipboard — into that program needs a key Emacs still owns, and `p'
is the one a vim user's hand already reaches for.

Only while the child owns the keyboard.  At an input prompt the pending line is
being edited in the buffer like any other text, so `p' stays evil's own paste
and keeps its own semantics; the difference matters because `evil-paste-after'
pastes after the character under the cursor, which is what you want on a line
you are editing and meaningless on one you are not."
  :type 'boolean
  :group 'cooked)

(declare-function evil-paste-after "evil-commands")
(declare-function evil-paste-before "evil-commands")
(declare-function evil-define-key* "evil-core")

(defun cooked-evil-paste ()
  "Paste, as normal state should here.
While the child owns the keyboard this is `cooked-paste', which hands the kill
ring to the child.  At a prompt it is evil's own paste, since the pending line
is ordinary editable text.  See `cooked-evil-normal-state-pastes'."
  (interactive)
  (if (cooked--input-state-p)
      (call-interactively
       (if (eq last-command-event ?P) #'evil-paste-before #'evil-paste-after))
    (cooked-paste)))

(declare-function evil-collection-define-key "evil-collection")

(with-eval-after-load 'evil
  (when cooked-evil-normal-state-pastes
    ;; On `cooked-mode-map' for the reason RET is, below: an override registered
    ;; against the derived mode outranks anything `evil-collection' tied to
    ;; `comint-mode-map', and a plain `define-key' would not be consulted at all.
    (evil-define-key* 'normal cooked-mode-map
                      (kbd "p") #'cooked-evil-paste
                      (kbd "P") #'cooked-evil-paste)))

(with-eval-after-load 'evil-collection
  (when cooked-evil-insert-state-submits
    ;; All three spellings, matching `evil-collection's own `repl-newline'
    ;; binding: a GUI frame's Enter key is `<return>', not `RET' -- binding
    ;; only `RET' leaves `<return>' still resolving to `newline'.
    (evil-collection-define-key 'insert 'cooked-mode-map
      (kbd "RET") #'cooked-send-input
      (kbd "<return>") #'cooked-send-input
      (kbd "C-m") #'cooked-send-input)))

(provide 'cooked-evil)
;;; cooked-evil.el ends here
