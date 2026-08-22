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
(defvar evil-previous-state)
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

Only ever called for the child's own ownership of the keyboard changing, which
is what makes a deliberate `C-z' survive: `cooked--refresh-keymap' suppresses
`cooked-state-change-hook' for a refresh evil itself triggered, and runs it at
all only when `cooked--input-state-p' has actually flipped -- not for the
`raw'<->`alt' transitions and termios polls a full-screen program produces by
the dozen, every one of which used to put the user back in emacs state."
  (when (and cooked-evil-integration (bound-and-true-p evil-local-mode))
    (let ((state (bound-and-true-p evil-state)))
      (cond ((cooked--input-state-p)
             (when (eq state 'emacs) (evil-insert-state)))
            ((null cooked-evil-child-state))
            ((eq cooked-evil-child-state 'insert)
             (unless (memq state '(insert emacs)) (evil-insert-state)))
            (t (unless (eq state 'emacs)
                 (evil-emacs-state)
                 (cooked-evil--come-back-to 'normal)))))))

(defun cooked-evil--come-back-to (state)
  "Make `C-z' out of emacs state land in STATE.

`C-z' is `evil-exit-emacs-state', which returns to `evil-previous-state' -- and
the previous state is whatever the user was in when the child took the
keyboard.  At a shell prompt that is insert state, routinely: you are typing,
you run a full-screen program, cooked hands it the keyboard by putting evil in
emacs state, and `C-z' then puts you back in *insert*.  Insert state forwards
through `cooked-semi-map', so every key still goes to the child -- \`V' among
them, which is why it looked like visual state had stopped working rather than
like the state had.

Normal state is the honest answer.  The insert state being remembered belonged
to a prompt that is no longer on screen, and nothing is lost by forgetting it:
when the child gives the keyboard back, `cooked-evil-sync' puts insert state
back on its own."
  (setq evil-previous-state state))

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
(declare-function evil-range "evil-common")
(declare-function cooked-evil-inner-command "cooked-evil")
(declare-function cooked-evil-outer-command "cooked-evil")

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

(declare-function evil-undo "evil-commands")
(declare-function evil-downcase "evil-commands")
(declare-function evil-upcase "evil-commands")
(declare-function evil-invert-char "evil-commands")
(declare-function evil-visual-range "evil-states")
(declare-function evil-range-beginning "evil-common")
(declare-function evil-range-end "evil-common")

(defun cooked-evil-undo (count)
  "Undo COUNT changes to the line being typed, there being nothing else to undo.

Undo in a cooked buffer is scoped to the pending input and kept there
deliberately -- see `cooked--check-undo-anchor\=' for why a terminal\='s own
redraws are neither recorded nor recoverable.  \\`u\=' therefore has an answer
everywhere except at a prompt, and it is the same answer undo itself gives for
an empty history; what it must not do is report the mechanism instead.  Plain
`evil-undo\=' is `(interactive \"*p\")\=', so with the render suspended -- evil
normal state at the default `cooked-evil-normal-state-render\=', a peek -- the
\\`u\=' a user presses over a full-screen program answers \"Buffer is read-only\",
which is true of the buffer and beside the point about the undo.

A session that has ended counts with the prompt, as it does in
`cooked--refresh-keymap\=': there is no child left to own the text, and whatever
is in the history is the user\='s own."
  (interactive "p")
  (if (or (null cooked--session) (cooked--input-state-p))
      (evil-undo count)
    (user-error "No further undo information")))

(defun cooked-evil--visual-writable-p ()
  "Whether every character the visual selection covers may be edited.

Asked of the text rather than of cooked\='s state, because the two disagree in
the case that matters: at a prompt the pending line is ordinary editable text
while the rows above it are the child\='s, and a selection is free to start in
one and end in the other.  `read-only\=' is the property `cooked--protect\=' puts
on everything the emulator owns, so the property is the question."
  (let ((range (evil-visual-range)))
    (and (not buffer-read-only)
         (not (text-property-not-all (evil-range-beginning range)
                                     (min (evil-range-end range) (point-max))
                                     'read-only nil)))))

(defun cooked-evil-visual-case ()
  "Change the case of the visual selection, unless it is the child\='s text.

\\`u\=', \\`U\=' and \\`~\=' are `evil-downcase\=', `evil-upcase\=' and
`evil-invert-char\=' in visual state, and all three end in `downcase-region\=' or
its neighbours over whatever is selected.  Over a rendered row that signals,
and a signal here is the failure `cooked-evil--command-range\=' documents at
length: Emacs runs no `post-command-hook\=' after a command that signalled, so
`evil-visual-post-command\=' never reconciles the selection and evil is left
believing in a visual state the user cannot see -- after which the next \\`v\='
*leaves* visual state rather than entering it.  The house rule that follows is
that anything reachable from visual state here reports and returns.

Returning also leaves the selection standing, which is the honest outcome: the
command did nothing, so nothing about the state should have changed either.

One command for the three keys, dispatching on the key that ran it, the way
`cooked-evil-paste\=' does for \\`p\=' and \\`P\='.  \\`gu\=' and its family in normal
state are left alone: they signal for the same reason, but a signal in normal
state costs a message rather than a state evil cannot see out of, and \"Buffer
is read-only\" over a program\='s screen is a true thing to say."
  (interactive)
  (if (cooked-evil--visual-writable-p)
      (call-interactively (pcase last-command-event
                            (?u #'evil-downcase)
                            (?U #'evil-upcase)
                            (_ #'evil-invert-char)))
    (message "cooked: %s"
             (if buffer-read-only
                 "the buffer is read-only while the render is suspended"
               "that is the child's text, not yours to edit"))))

(defcustom cooked-evil-command-text-object "c"
  "Key for the command text objects, under \\`i' and \\`a', or nil for none.

\\`vic' selects a command's output; \\`vac' takes the prompt and the command
line above it as well.  Bound only in `cooked-mode' -- through the same
auxiliary keymap `evil' resolves every other binding here with -- so \\`ic'
keeps whatever it means elsewhere, and the rest of the family (\\`iw',
\\`ip', \\`i\"') is untouched in a cooked buffer.

\\`c' for the command, which is what the record is: the prompt it was typed at,
the line, its output and its exit status."
  :type '(choice (string :tag "Key") (const :tag "Do not bind" nil))
  :group 'cooked)

(defcustom cooked-evil-section-motions t
  "Whether \\`[[' and \\`]]' move between prompts in a cooked buffer.

`evil-collection' already routes them here through `comint-previous-prompt',
which `cooked-mode-map' remaps -- but only if `evil-collection' is installed.
Binding them ourselves means a plain `evil' user gets them too, in place of
`evil-backward-section-begin', which has nothing to find in a transcript."
  :type 'boolean :group 'cooked)

(defun cooked-evil--command-at-point (outer)
  "The region of the command around point, as (BEG . END), or nil.
OUTER takes in the prompt and command line as well as the output."
  (when-let* ((command (cooked--command-around (point))))
    (cooked--command-region command outer)))

(defun cooked-evil--command-range (count outer)
  "An `evil-range' over COUNT commands from the one at point, or nil for none.
OUTER takes in each command's prompt and command line as well as its output.

Nil, and never a signal.  evil's contract for a text object body is to return a
range or nothing, and a signal from one is worse than the missing feedback it
buys: it aborts the command with evil still in visual state, and Emacs runs no
`post-command-hook' after a command that signalled -- so that
`evil-visual-post-command' never reconciles the selection, and
`cooked--track-wandering' never refreshes the ghost cursor or the cursor type.
The stale visual state is what makes the next \\`v' *leave* visual state rather
than enter it, after which \\`i' is `evil-insert-state' and the \\`c' goes to
the child as a keystroke.  Anything here that can fail while evil is in visual
state has to return or `message'."
  (when-let* ((region (cooked-evil--command-at-point outer)))
    (when (> (or count 1) 1)
      ;; Extend by stepping to each following prompt and taking that command
      ;; whole, which is what makes `2ac' two commands rather than two screens.
      (save-excursion
        (goto-char (cdr region))
        (dotimes (_ (1- count))
          (cooked-next-command)
          (when-let* ((next (cooked-evil--command-at-point outer)))
            (setcdr region (max (cdr region) (cdr next)))))))
    (if (= (car region) (cdr region))
        ;; A command that printed nothing has no inner half, so this is reached
        ;; only from `ic' -- `ac' always has the prompt and the line.  An empty
        ;; range is the answer Vim gives for an empty inner object, `ci"'
        ;; between two quotes being the familiar one.  Exclusive rather than
        ;; line, because an empty *line* range expands to the whole line the two
        ;; ends sit on, and that position is the following command's prompt:
        ;; `ic' on a silent command would quietly take its neighbour's.
        (evil-range (car region) (cdr region) 'exclusive)
      (evil-range (car region) (cdr region) 'line))))

(declare-function evil-collection-define-key "evil-collection")

(with-eval-after-load 'evil
  ;; `eval' at load time, quoted so the byte-compiler leaves it alone:
  ;; `evil-define-text-object' is a macro of evil's, and cooked is one package
  ;; -- package.el compiles this file for a user who has never installed evil,
  ;; where an unexpanded macro compiles to a call to a function that does not
  ;; exist.  Expanding here instead means it happens exactly when evil is known
  ;; to be there.  Each body is one call into compiled code.
  (eval '(progn
           (evil-define-text-object cooked-evil-inner-command
             (count &optional _beg _end _type)
             "Select the output of the command around point."
             (cooked-evil--command-range count nil))
           (evil-define-text-object cooked-evil-outer-command
             (count &optional _beg _end _type)
             "Select the command around point: its prompt, its line, and its output."
             (cooked-evil--command-range count t)))
        t)

  (when cooked-evil-command-text-object
    (evil-define-key* '(visual operator) cooked-mode-map
                      (kbd (concat "i " cooked-evil-command-text-object))
                      #'cooked-evil-inner-command
                      (kbd (concat "a " cooked-evil-command-text-object))
                      #'cooked-evil-outer-command))
  (when cooked-evil-section-motions
    (evil-define-key* '(normal visual motion) cooked-mode-map
                      (kbd "[[") #'cooked-previous-command
                      (kbd "]]") #'cooked-next-command))
  ;; Unconditional, both of them: they are the same commands evil would have
  ;; run, refusing where evil's own would have failed badly.  See
  ;; `cooked-evil-undo' and `cooked-evil-visual-case'.
  (evil-define-key* 'normal cooked-mode-map (kbd "u") #'cooked-evil-undo)
  (evil-define-key* 'visual cooked-mode-map
                    (kbd "u") #'cooked-evil-visual-case
                    (kbd "U") #'cooked-evil-visual-case
                    (kbd "~") #'cooked-evil-visual-case)
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
