;;; cooked-evil.el --- evil integration for cooked -*- lexical-binding: t; -*-

;;; Commentary:

;; Opt-in.  Require it yourself:
;;
;;   (use-package cooked
;;     :commands (cooked cooked-other-window)
;;     :config (require 'cooked-evil))
;;
;; What it does is decide, from evil's own state, how much of the keyboard the
;; child gets.  That is the whole integration, and it is more than it used to
;; be for one reason: evil's states already mean exactly this.  Normal state
;; means "I am navigating"; insert state means "I am typing, but I still expect
;; to be able to leave"; emacs state means "get out of the way entirely".  A
;; terminal wants all three, and used to offer only the last.
;;
;;   emacs state   Everything but `C-c' forwards -- `cooked-alt-map' and the
;;                 rest, unchanged.  This is what a full-screen program needs,
;;                 ESC included, and it is where `cooked-evil-sync' puts you
;;                 when the child takes the keyboard.
;;   insert state  `cooked-semi-map': forwards, but keeps ESC, the Meta space
;;                 and `cooked-semi-exceptions' for Emacs, so `M-x', a
;;                 non-normal leader on `M-SPC', and ESC-to-normal-state all
;;                 still work while typing at the child.
;;   normal state  `cooked-evil-normal-state-render', `still' by default: no
;;                 forwarding, read-only, and the child keeps drawing while the
;;                 view stays put.
;;   visual state  `cooked-evil-visual-state-render', `frozen' by default: a
;;                 selection means nothing against text being rewritten
;;                 underneath it.
;;
;; The predecessor of all this was a single pair of hooks that froze the buffer
;; on the way out of emacs state and thawed it on the way back.  It made `C-z'
;; -- the key an evil user presses to do anything at all -- stop the terminal
;; dead, kept it stopped while they were off in another window, and had a hole
;; besides: nothing thawed a buffer left in insert state, because the thaw hung
;; on entering emacs state and the auto-resume needed `self-insert-command',
;; which is not what a letter runs in normal state.  Deriving the mode from the
;; state on every transition has no such hole, and costs one function.
;;
;; Two bindings still earn their place.  `p' in normal state: a full-screen
;; program's own paste key pastes its own registers -- `p' inside vim never
;; sees anything Emacs copied -- so reaching the kill ring needs a key Emacs
;; still owns, and normal state is where one is going spare.  At a prompt it
;; stays evil's own paste; see `cooked-evil-normal-state-pastes'.
;;
;; `evil-collection' is the other, and it needs one binding of our own.
;; `evil-collection-comint' binds RET for every comint buffer via `evil-define-key',
;; which does not edit `comint-mode-map' in place -- it registers an auxiliary
;; keymap that evil consults *ahead of* every buffer's ordinary local map,
;; `cooked-input-map' included.  A plain `(define-key cooked-input-map ...)`
;; therefore never gets a look at RET at all; verified directly against a real
;; evil-collection install, an evil-collection auxiliary keymap shadowing
;; `cooked-input-map' in `current-active-maps' before it is ever reached.  And
;; `evil-collection-repl-submit-state' defaults to `normal', which hands
;; insert-state RET to `newline' -- so Enter stops submitting and starts
;; inserting a line break.
;;
;; The fix has to answer evil on its own terms: register our own override the
;; same way, via `evil-collection-define-key' on `cooked-mode-map' rather than
;; `comint-mode-map'.  Evil resolves which auxiliary keymap wins by walking the
;; buffer's own local-map chain, most specific first, so the override tied to
;; `cooked-mode-map' -- the derived, more specific mode -- outranks the one tied
;; to `comint-mode-map', while everything else `evil-collection-comint' set up
;; -- history on the arrow keys, prompt navigation -- keeps working, since those
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
While the child owns it, evil is put in `cooked-evil-child-state' so keys are
not intercepted; in the input state evil returns to normal editing."
  :type 'boolean :group 'cooked)

(defcustom cooked-evil-child-state 'emacs
  "The evil state to adopt when the child takes the keyboard.

`emacs' is the default because it is the only state that gives a full-screen
program literally every key, ESC included, which is what one needs and what a
terminal has always done.

`insert' hands it `cooked-semi-map' instead, keeping ESC, the Meta space and
`cooked-semi-exceptions' for Emacs.  That is a friendlier default at a shell
than in vim -- ESC leaving insert state costs nothing at a prompt and costs
everything inside a modal editor -- so it is offered rather than chosen.

nil leaves evil's state alone entirely; whatever state you are in is the one
that decides, and cooked never moves you."
  :type '(choice (const :tag "Emacs state: forward everything" emacs)
                 (const :tag "Insert state: forward, but keep Emacs reachable" insert)
                 (const :tag "Leave evil alone" nil))
  :group 'cooked)

(defcustom cooked-evil-normal-state-render 'still
  "What the render does while evil is in normal, motion or operator state.

`still' keeps the child drawing while nothing moves the view: point stays
where it was put, and `cooked--wandered' pins it to its screen cell across
each redraw.  This is the default because normal state is somewhere an evil
user passes through constantly -- to reach a leader key, to scroll, to get to
another window -- and none of that is a reason to stop the terminal.

`frozen' defers the render as well, for reading a screen that will not hold
still on its own.  nil keeps following the cursor, so the view chases output
as it always does; navigation still works, it just may not stay put."
  :type '(choice (const :tag "Live, but the view stays put" still)
                 (const :tag "Defer the render" frozen)
                 (const :tag "Keep following the cursor" nil))
  :group 'cooked)

(defcustom cooked-evil-visual-state-render 'frozen
  "What the render does while evil is in visual state.

`frozen' by default, where `cooked-evil-normal-state-render' is not: a
selection is a claim about a region of text, and text being rewritten
underneath it makes the claim into a lie.  The freeze lifts as soon as the
window stops being the selected one, so this cannot strand a buffer."
  :type '(choice (const :tag "Defer the render" frozen)
                 (const :tag "Live, but the view stays put" still)
                 (const :tag "Keep following the cursor" nil))
  :group 'cooked)

(defcustom cooked-evil-hybrid-insert t
  "Whether insert state forwards through `cooked-semi-map'.

Non-nil is the point of the integration: typing reaches the child, while ESC,
`M-x' and a non-normal leader still reach Emacs.  nil forwards everything the
policy's own map does, making insert state indistinguishable from emacs state."
  :type 'boolean :group 'cooked)

(defun cooked-evil-sync ()
  "Match evil's state to who owns the keyboard.
A TUI needs every keystroke, so evil must not be interpreting them; at a prompt
evil should behave as in any other buffer.

Only ever called for the child's own state changing -- `cooked--refresh-keymap'
suppresses `cooked-state-change-hook' for a refresh evil itself triggered, so
this cannot end up undoing a deliberate `C-z' a keystroke after it was pressed."
  (when (and cooked-evil-integration (bound-and-true-p evil-local-mode))
    (let ((state (bound-and-true-p evil-state)))
      (cond ((cooked--input-state-p)
             (when (eq state 'emacs) (evil-insert-state)))
            ((null cooked-evil-child-state))
            ((eq cooked-evil-child-state 'insert)
             (unless (memq state '(insert emacs)) (evil-insert-state)))
            (t (unless (eq state 'emacs) (evil-emacs-state)))))))

(add-hook 'cooked-state-change-hook #'cooked-evil-sync)

(defun cooked-evil--input-mode ()
  "The `cooked--input-mode' evil's current state asks for.

Derived on every transition rather than latched by a hook, which is what makes
`i' out of normal state resume forwarding on its own -- see the commentary in
cooked-mode.el above `cooked-toggle-peek' for the bug latching it caused."
  (if (not (and cooked-evil-integration (bound-and-true-p evil-local-mode)))
      (cooked--default-input-mode)
    (or (and cooked--peek-explicit 'frozen)
        (pcase (bound-and-true-p evil-state)
          ((or 'normal 'motion 'operator) cooked-evil-normal-state-render)
          ('visual cooked-evil-visual-state-render)
          ((or 'insert 'replace) (and cooked-evil-hybrid-insert 'semi))
          (_ nil)))))

;; Only if nobody else has claimed the seam: `cooked-input-mode-function' is a
;; public hook point, and a user who set their own answer before loading this
;; meant it.
(when (eq cooked-input-mode-function #'cooked--default-input-mode)
  (setq cooked-input-mode-function #'cooked-evil--input-mode))

(defun cooked-evil--state-changed ()
  "Recompute cooked's input mode for the state evil has just entered.

Quiet, because `cooked-state-change-hook' means the *child's* ownership
changed; running it here would call `cooked-evil-sync', which would put evil
straight back into `cooked-evil-child-state' and make `C-z' unusable.

Guarded on the mode rather than on `cooked--session', this being on evil's
global state hooks and so running in every buffer there is: a session that has
ended is exactly the buffer that still needs its keymap recomputed, since it is
the one left read-only when the child died under a freeze."
  (when (derived-mode-p 'cooked-mode)
    (cooked--refresh-keymap t)))

(dolist (state '(normal insert visual emacs motion operator replace))
  (add-hook (intern (format "evil-%s-state-entry-hook" state))
            #'cooked-evil--state-changed))

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
