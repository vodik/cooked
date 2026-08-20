;;; cooked-mode.el --- Interaction for cooked terminals -*- lexical-binding: t; -*-

;;; Commentary:

;; The interactive half of cooked: keymaps, key encoding, input submission,
;; history, secrets, and starting a shell.  Completion is its own file,
;; cooked-completion.el.  See cooked.el, the main file, for what this is and how
;; to install it.

;; Two signals decide who owns the keyboard.  The kernel's line discipline
;; (`cooked--mode') identifies programs doing canonical reads, and OSC 133 marks
;; identify the shell's own prompt, which is always raw and so invisible to the
;; first signal.  Either one puts us in `input' state, where keys are ordinary
;; Emacs editing against a pending-input region; otherwise keys go straight to
;; the child.

;;; Code:

(require 'cooked)
(require 'cooked-completion)
(require 'comint)

;; Defined by the native core at `module-load' time, so the byte-compiler cannot
;; see them; cooked.el declares the same set for its own use.
(declare-function cooked--send "cooked-core")
(declare-function cooked--resize "cooked-core")
(declare-function cooked--signal "cooked-core")
(declare-function cooked--prompt-text "cooked-core")
(declare-function cooked--bracketed-paste-p "cooked-core")
(declare-function cooked--focus-events-p "cooked-core")
(declare-function cooked--alt-scroll-p "cooked-core")
(declare-function cooked--live-p "cooked-core")
(declare-function cooked--kill "cooked-core")

(defcustom cooked-buffer-name "*cooked: %s*"
  "How session buffers are named.

A string is used as a format, with %s replaced by the abbreviated working
directory.  A function is called with that directory and should return a name.
Either way the result is uniquified, so several sessions can coexist."
  :type '(choice (string :tag "Format")
                 (function :tag "Function of the directory"))
  :group 'cooked)

(defcustom cooked-buffer-name-follows-title nil
  "Whether to rename the buffer as the child sets its title with OSC 2.

Off by default: a buffer whose name changes under you is hard to find again and
breaks anything holding on to the old name.  Turn it on for the vterm-like
behaviour of showing the running command in the buffer list."
  :type 'boolean :group 'cooked)

(defun cooked--buffer-name (&optional directory)
  "A fresh, unique buffer name for a session in DIRECTORY."
  (let* ((directory (abbreviate-file-name (or directory default-directory)))
         (name (if (functionp cooked-buffer-name)
                   (funcall cooked-buffer-name directory)
                 (format cooked-buffer-name directory))))
    (generate-new-buffer-name name)))

(defun cooked--rename-to-title ()
  "Rename the buffer after the child's title, when asked to."
  (when (and cooked-buffer-name-follows-title
             cooked--title
             (not (string-empty-p cooked--title)))
    (let ((name (if (functionp cooked-buffer-name)
                    (funcall cooked-buffer-name cooked--title)
                  (format cooked-buffer-name cooked--title))))
      (unless (equal name (buffer-name))
        (rename-buffer (generate-new-buffer-name name))))))

(defcustom cooked-rejoin-wrapped-lines t
  "Whether a line the terminal wrapped becomes one buffer line again.

The emulator knows which scrolled-off rows were continuations rather than new
lines, so history can be stored the way it was written.  Rejoining means yanking
from the scrollback does not pick up newlines nobody typed, and widening the
window re-wraps old output for free, because Emacs is doing the wrapping.

Set to nil for the literal thing a terminal shows: one buffer line per screen
row, hard-wrapped at whatever width was in force when it was printed."
  :type 'boolean :group 'cooked)

(defcustom cooked-shell (or (bound-and-true-p explicit-shell-file-name) shell-file-name)
  "Program run by \\[cooked]."
  :type 'string :group 'cooked)

(defcustom cooked-password-function nil
  "Function called with the prompt string to supply a password non-interactively.
Should return a string, or nil to fall back to `read-passwd'.  Lets auth-source
or `pass' answer a prompt no ordinary terminal could even detect."
  :type '(choice (const nil) function) :group 'cooked)

(defcustom cooked-secret-debounce 0.03
  "Seconds to wait before prompting for a secret.
Programs differ on whether they clear ECHO before or after printing the prompt;
this lets the prompt text arrive first."
  :type 'number :group 'cooked)

(defvar-local cooked--secret-timer nil)
(defvar-local cooked--history-stash nil
  "Input set aside while browsing history.
The one piece of history state that is cooked's: the ring, and the position in
it, are `comint-input-ring' and `comint-input-ring-index'.")
(defvar-local cooked--last-size nil)

;;;; Key encoding

(defconst cooked--special-keys
  '((up . "\e[A") (down . "\e[B") (right . "\e[C") (left . "\e[D")
    (home . "\e[H") (end . "\e[F") (prior . "\e[5~") (next . "\e[6~")
    (insert . "\e[2~") (deletechar . "\e[3~") (backspace . "\C-?")
    (tab . "\t") (return . "\r") (escape . "\e")
    ;; Shift+TAB is reported by Emacs as `backtab', not as `S-tab', so it needs its
    ;; own entry rather than falling out of the modifier logic.  Terminfo calls the
    ;; sequence `kcbt'.
    (backtab . "\e[Z")
    (f1 . "\eOP") (f2 . "\eOQ") (f3 . "\eOR") (f4 . "\eOS")
    (f5 . "\e[15~") (f6 . "\e[17~") (f7 . "\e[18~") (f8 . "\e[19~")
    (f9 . "\e[20~") (f10 . "\e[21~") (f11 . "\e[23~") (f12 . "\e[24~"))
  "Escape sequences for non-character keys, unmodified.
`cooked--encode-event' consults the tables below to modify these.")

(defconst cooked--csi-finals
  '((up . "A") (down . "B") (right . "C") (left . "D") (home . "H") (end . "F"))
  "Cursor keys, which take either a CSI or an SS3 prefix depending on DECCKM.
Modified, they become \\='ESC [ 1 ; MOD FINAL\\='.")

(defconst cooked--ss3-finals
  '((f1 . "P") (f2 . "Q") (f3 . "R") (f4 . "S"))
  "Keys sent as SS3 unmodified, and as \\='ESC [ 1 ; MOD FINAL\\=' otherwise.")

(defconst cooked--tilde-numbers
  '((prior . 5) (next . 6) (insert . 2) (deletechar . 3)
    (f5 . 15) (f6 . 17) (f7 . 18) (f8 . 19)
    (f9 . 20) (f10 . 21) (f11 . 23) (f12 . 24))
  "Keys spelled \\='ESC [ N ~\\=', which take a modifier as \\='ESC [ N ; MOD ~\\='.")

(defconst cooked--literal-codes
  '((return . 13) (tab . 9) (escape . 27) (backspace . 127))
  "Keys that are a single byte, and the character code standing in for each.

These are the awkward ones.  There is no classical encoding for
Shift+Return or Control+Tab: xterm and kitty each invented one, and both
are negotiated, because a terminal that volunteers \\='ESC [ 27;2;13 ~\\='
to a program that never asked for it has not sent Shift+Return, it has
sent six characters of rubbish.  So a modifier here is spelled out only
when `cooked--keys' says the child opted in.")

(defun cooked--modifier-param (mods)
  "xterm's modifier parameter for MODS: 1 plus a bit per held modifier."
  (+ 1
     (if (memq 'shift mods) 1 0)
     (if (memq 'meta mods) 2 0)
     (if (memq 'control mods) 4 0)))

(defun cooked--encode-literal (basic code param mods)
  "Encode a single-byte key BASIC, whose character is CODE, with modifiers.

PARAM is the xterm modifier parameter and MODS the modifier list.  Falls back to
the bare byte when the child has negotiated nothing, since that is what every
terminal has always sent and what every program still understands."
  (let ((seq (cdr (assq basic cooked--special-keys))))
    (cond
     ((= param 1) (if (memq 'meta mods) (concat "\e" seq) seq))
     ((eq cooked--keys 'modify-other) (format "\e[27;%d;%d~" param code))
     ((eq cooked--keys 'kitty) (format "\e[%d;%du" code param))
     ;; Nothing negotiated: meta has a classical spelling, the rest do not.
     ((memq 'meta mods) (concat "\e" seq))
     (t seq))))

(defun cooked--encode-event (event)
  "Bytes the child should receive for EVENT, or nil.

Note that Emacs reports a capital letter as shift plus the lowercase one, so the
shift modifier has to be applied here — reading `event-basic-type' alone turns
every capital into a lowercase letter."
  ;; `event-modifiers' first, and not merely for readability: on a symbolic event
  ;; such as `S-up' it is what parses and caches `event-symbol-elements', which
  ;; `event-basic-type' only reads.  Ask the other way round and the first press of
  ;; every modified key decodes as nil.
  ;; Each table is consulted once, through `if-let*', rather than being asked
  ;; whether it has the key and then asked again for the value.  The tables are
  ;; tried in order of how specific their spelling is, ending at a plain
  ;; character; a key in none of them encodes as nil and is not forwarded.
  (let* ((mods (event-modifiers event))
         (basic (event-basic-type event))
         (param (cooked--modifier-param mods))
         (modified (> param 1)))
    (cond
     ((if-let* ((final (alist-get basic cooked--csi-finals)))
          (cond (modified (format "\e[1;%d%s" param final))
                (cooked--app-cursor (concat "\eO" final))
                (t (concat "\e[" final)))))
     ;; F1-F4 leave SS3 behind the moment they are modified.
     ((if-let* ((final (alist-get basic cooked--ss3-finals)))
          (if modified (format "\e[1;%d%s" param final) (concat "\eO" final))))
     ((if-let* ((n (alist-get basic cooked--tilde-numbers)))
          (if modified (format "\e[%d;%d~" n param) (format "\e[%d~" n))))
     ((if-let* ((code (alist-get basic cooked--literal-codes)))
          (cooked--encode-literal basic code param mods)))
     ((if-let* ((seq (alist-get basic cooked--special-keys)))
          (if (memq 'meta mods) (concat "\e" seq) seq)))
     ((characterp basic)
      (let ((char (cond ((memq 'control mods) (logand (upcase basic) #x1f))
                        ((memq 'shift mods) (upcase basic))
                        (t basic))))
        (if (memq 'meta mods) (concat "\e" (string char)) (string char)))))))

(defun cooked--track-wandering ()
  "Notice a command moving point off the child's cursor, or back onto it.

Runs from `post-command-hook' because Emacs' own motions produce no output:
nothing is drained, so a redraw cannot be what discovers that point has moved."
  (setq cooked--wandered
        (and (memq (cooked--policy) '(alt raw))
             ;; Scrollback is the reading case, already handled by `follow'.
             (cooked--screen-cell)
             (not (cooked--at-child-cursor-p))))
  (cooked--update-ghost-cursor))

(defun cooked--snap-to-cursor ()
  "Return point to the child's cursor before handing it a key.

Typing is the moment the keyboard goes back, so it is the moment to stop
pretending point is anywhere else — the child will act at its own cursor
whatever Emacs is showing, and the ghost has been marking that spot."
  (when (and cooked--wandered (memq (cooked--policy) '(alt raw)))
    (goto-char (cooked--cursor-position))
    (setq cooked--wandered nil)
    (cooked--update-ghost-cursor)))

(defun cooked-send-key ()
  "Send the key that invoked this command straight to the child."
  (interactive)
  (when-let* ((bytes (cooked--encode-event last-command-event)))
    (cooked--snap-to-cursor)
    (cooked--send-to-child bytes)))

(defun cooked-send-string (string)
  "Send STRING to the child.

Bound on `cooked-mode-map', not just `cooked-raw-map'/`cooked-alt-map', so it
also reaches the child while peeking -- ending peek first, so the result is
seen immediately rather than held behind the freeze -- but refuses once Emacs
owns the line: a string sent out of band would arrive at the child ahead of
whatever pending input is still sitting unsent in the buffer."
  (interactive "sSend: ")
  (cooked--resume-forwarding)
  (when (cooked--input-state-p)
    (user-error "Emacs already owns the line; type directly instead"))
  (cooked--snap-to-cursor)
  (cooked--send-to-child string))

(defcustom cooked-paste-confirm-lines t
  "Whether to confirm a multi-line paste the child cannot tell is a paste.

A line editor reads an embedded newline as Enter, so several lines pasted into a
child that has not asked for bracketed paste run one after another, immediately,
with no chance to read them first.  Terminals have warned about this for years
and the hazard here is the same one.

A child that *has* asked for bracketed paste is never confirmed: it is told
where the paste begins and ends and inserts it as one edit, which is the whole
point of the protocol."
  :type 'boolean
  :group 'cooked)

(defun cooked--bracketed-paste (text)
  "TEXT wrapped in the bracketed-paste markers, made safe to wrap.

Any end marker inside TEXT is dropped.  One left in would close the bracket
early and hand whatever followed it to the child as if it had been typed —
which is how a copied line runs something you never read.  The child is told
where the paste ends; nothing in the middle gets to say otherwise."
  (concat "\e[200~" (string-replace "\e[201~" "" text) "\e[201~"))

(defun cooked--send-paste (text)
  "Hand TEXT to the child as a paste."
  (cond
   ((cooked--bracketed-paste-p cooked--session)
    (cooked--snap-to-cursor)
    (cooked--send-to-child (cooked--bracketed-paste text)))
   ((and cooked-paste-confirm-lines
         (string-search "\n" text)
         (not (y-or-n-p
               (format "Paste %d lines?  %s will run each as it arrives: "
                       (1+ (cl-count ?\n text))
                       (or cooked--title "The child")))))
    (message "Paste cancelled"))
   (t
    (cooked--snap-to-cursor)
    ;; Newlines go as carriage returns because that is what the Return key
    ;; transmits, and a line editor bound to CR is what is reading them.
    (cooked--send-to-child (string-replace "\n" "\r" text)))))

(defun cooked-paste ()
  "Paste the most recent kill.

At an input prompt this is `yank', because the pending line is being edited in
the buffer: the text lands there and can be corrected before it is submitted.

While the child owns the keyboard there is no buffer to yank into — the text is
the child's to receive, and goes to it directly.  Bracketed when the child asked
for bracketed paste, so its line editor treats the whole thing as one insertion
rather than as very fast typing; see `cooked-paste-confirm-lines' for what
happens when it did not ask.

This is the way to get Emacs' kill ring — and so the system clipboard, which
`current-kill' consults exactly as `yank' does — into a full-screen program.  A
program's own paste key pastes its own registers, which is a different thing
entirely and cannot reach anything Emacs copied.

Ends peek first when peeking, so the paste is seen landing rather than held
behind the freeze."
  (interactive)
  (cooked--resume-forwarding)
  (unless (cooked--live-session)
    (user-error "No live session"))
  (if (cooked--input-state-p)
      (call-interactively #'yank)
    (let ((text (current-kill 0)))
      (if (string-empty-p text)
          (message "Nothing to paste")
        (cooked--send-paste text)))))

(defconst cooked--escape-key ?\C-c
  "Prefix reserved for cooked's own commands while the child owns the keyboard.
Everything else, ESC included, is forwarded verbatim, so \\`M-x' reaches the
child as ESC x — exactly as in any other terminal.  \\`C-c M-x' is the way back
out; see `cooked-meta-x'.")

(defun cooked-meta-x ()
  "Run \\`M-x' in Emacs rather than sending it to the child.

While the child owns the keyboard every key is forwarded, ESC included, so plain
\\`M-x' arrives at the child as ESC x — which is what you want inside vim, and
not at all what you want when you meant Emacs.  \\`C-c M-x' is the escape hatch.

Whatever \\`M-x' is globally bound to is what runs, so `counsel-M-x', `helm-M-x'
and the rest keep working."
  (interactive)
  (let ((command (or (global-key-binding (kbd "M-x")) #'execute-extended-command)))
    (setq this-command command)
    (call-interactively command)))

;;;; Mouse
;;
;; Reports are only sent when the child asked for them; otherwise the click does
;; what it does in any Emacs buffer, so selecting text still works.

(defconst cooked--mouse-buttons
  '((mouse-1 . 0) (mouse-2 . 1) (mouse-3 . 2)
    ;; A GUI frame spells the wheel `wheel-up'; a terminal spells the same notch
    ;; `mouse-4', because that is what X10 numbered it.  Both reach here.
    (wheel-up . 64) (wheel-down . 65) (mouse-4 . 64) (mouse-5 . 65)
    (wheel-left . 66) (wheel-right . 67) (mouse-6 . 66) (mouse-7 . 67))
  "Terminal button numbers for Emacs mouse events.")

(defconst cooked--wheel-events
  '(wheel-up wheel-down wheel-left wheel-right mouse-4 mouse-5 mouse-6 mouse-7)
  "Events carrying a wheel notch rather than a button that can be held.")

(defconst cooked--mouse-map
  (let ((map (make-sparse-keymap)))
    (dolist (event (append '(down-mouse-1 mouse-1 down-mouse-2 mouse-2
                             down-mouse-3 mouse-3)
                           cooked--wheel-events))
      (define-key map (vector event) #'cooked-mouse-event))
    map)
  "Mouse bindings for when the child has asked to receive them.

Lives in `emulation-mode-map-alists' rather than in `cooked-raw-map' because a
major mode's local map is near the bottom of Emacs' lookup order, under every
enabled minor mode.  `pixel-scroll-precision-mode' binds `wheel-up' and
`wheel-down' in its own minor-mode map, so on a GUI frame it took the wheel
before the local map was ever consulted — and scrolled the buffer out from
under a program that had asked for those notches.  A terminal frame did not
show this, because there the wheel arrives as `mouse-4'/`mouse-5', which
pixel-scroll does not bind.

Modified variants are deliberately absent: `C-wheel-up' should keep scaling
text, and shift-scrolling should keep working, as they do in any other buffer.")

(defvar-local cooked--mouse-grab nil
  "Whether the child both wants the mouse and owns the keyboard.
Gates `cooked--mouse-map'; nil everywhere else, so the entry in
`emulation-mode-map-alists' is inert outside a session that asked for it.")

(defvar cooked--mouse-map-alist `((cooked--mouse-grab . ,cooked--mouse-map))
  "The `emulation-mode-map-alists' entry activating `cooked--mouse-map'.")

(defcustom cooked-alternate-scroll-lines 3
  "Cursor keys sent per wheel notch under alternate scroll (DEC mode 1007).
Three is xterm's figure."
  :type 'natnum
  :group 'cooked)

(defun cooked--alt-scroll-active-p ()
  "Whether a wheel notch should be sent to the child as cursor keys.

DEC mode 1007, which is what makes the wheel scroll in `less', `man' and
`git log' — programs that never ask for the mouse."
  (and cooked--session (cooked--alt-scroll-p cooked--session)))

(defun cooked--update-mouse-grab ()
  "Recompute whether `cooked--mouse-map' should be in force."
  ;; Alternate scroll has to be here as well as `cooked--mouse': it exists precisely
  ;; for children that did *not* ask for the mouse, so gating the keymap on
  ;; `cooked--mouse' alone would leave the whole feature unreachable.
  ;;
  ;; Suspended forwarding has to be here too: it hands the buffer back to
  ;; ordinary Emacs commands, and a click should select text like any other
  ;; buffer's, not get reinterpreted as a mouse report to a child that still
  ;; owns the keyboard as far as `cooked--input-state-p' alone can tell.  Both
  ;; `still' and `frozen' count -- the render being live in `still' says nothing
  ;; about who a click belongs to.
  (setq cooked--mouse-grab (and (or cooked--mouse (cooked--alt-scroll-active-p))
                                (not (cooked--input-state-p))
                                (not (cooked--suspended-p)))))

(defun cooked--mouse-cell (event)
  "Screen row and column of EVENT, or nil if it is outside the screen.

`cooked--screen-cell' rather than a count of lines and columns from the marker:
row 0 does not always begin its buffer line — when the row handed to scrollback
last was wrapped, `cooked--screen-start' sits mid-line — and a plain
`current-column' there counts the characters ahead of the marker, which are
scrollback and not on the screen at all.  Reporting those to the child puts
every click on row 0 to the right of where it was made."
  (when-let* ((posn (event-start event))
              (pos (posn-point posn)))
    (cooked--screen-cell pos)))

(defun cooked--mouse-report (button row col pressed)
  "Encode a mouse report, preferring SGR because X10 cannot count past 223."
  (if cooked--mouse-sgr
      (format "\e[<%d;%d;%d%s" button (1+ col) (1+ row) (if pressed "M" "m"))
    (format "\e[M%c%c%c" (+ 32 (if pressed button 3)) (+ 33 col) (+ 33 row))))

(defun cooked--alt-scroll-keys (button)
  "Cursor keys standing in for a wheel notch of BUTTON.

Only the vertical notches translate; a horizontal one has no cursor-key
spelling a pager would understand, so it sends nothing."
  (if-let* ((final (cond ((= button 64) "A") ((= button 65) "B"))))
      (let ((key (if cooked--app-cursor (concat "\eO" final) (concat "\e[" final))))
        (mapconcat #'identity (make-list cooked-alternate-scroll-lines key)))
    ""))

(defun cooked-mouse-event ()
  "Forward the mouse to the child, or fall back to Emacs' own behaviour."
  (interactive)
  (let* ((event last-input-event)
         (basic (event-basic-type event))
         (button (cdr (assq basic cooked--mouse-buttons)))
         (wheel (memq basic cooked--wheel-events))
         ;; A notch has nowhere to land when the pointer is over a part of the
         ;; window with no text under it.  Scrolling Emacs instead would move the
         ;; buffer out from under a program that asked to receive the wheel, so
         ;; the cursor's cell stands in — the child cares about the direction.
         (cell (and cooked--mouse button
                    (or (cooked--mouse-cell event)
                        (and wheel (cooked--cursor-cell))))))
    (cond
     ;; Checked before the mouse report: `cooked--alt-scroll-p' is already false
     ;; when the child asked for the mouse, so the two can never both apply.
     ((and wheel button (cooked--alt-scroll-active-p))
      (cooked--send-to-child (cooked--alt-scroll-keys button)))
     ((null cell)
      (cooked--mouse-fallback event))
      ;; A wheel notch is always a press.  Emacs reports it as a click, which the
      ;; usual `click' test would encode as a release — and a release of buttons
      ;; 64/65 is a report every application discards, so the scroll would vanish
      ;; on the way to a child that had asked for it.
     (t
      (let ((pressed (or wheel (not (memq 'click (event-modifiers event))))))
        (cooked--send-to-child
                      (cooked--mouse-report button (car cell) (cdr cell) pressed)))))))

(defun cooked--mouse-fallback (event)
  "Run whatever EVENT would do without cooked's binding."
  (let ((command (lookup-key global-map (this-command-keys-vector))))
    (when (commandp command)
      (setq last-command-event event
            this-command command)
      (call-interactively command))))

;;;; Suspending: peek, and what evil's states ask for
;;
;; While the child owns the keyboard there is, by design, almost no way back to
;; an ordinary Emacs command -- `C-c'-prefixed ones aside.  That is exactly
;; right for a full-screen program, which needs every other key for itself, but
;; it leaves no way to fire an arbitrary command, search the buffer, or just
;; navigate with `evil' normal state.  Suspending forwarding is that door: the
;; buffer goes read-only and is handed to `cooked-peek-map', so nothing
;; forwards and nothing can be edited into text that goes nowhere while the
;; user looks around.
;;
;; Whether the render *also* stops is a separate question, and used to be the
;; same one.  `cooked--input-mode' is `still' when the child should keep
;; drawing while the view stays put, and `frozen' when even that is too much
;; movement -- a visual selection, say, which means something only against text
;; that is not being rewritten underneath it.  `still' is what makes stepping
;; out cheap: `C-z' to look at something no longer stops the terminal, and
;; walking away to another window certainly does not.  `cooked--wandered' and
;; the ghost cursor already pin point to its screen cell across a redraw, which
;; is the machinery that makes a live render survivable to navigate.
;;
;; Leaving is not a separate step to remember: peek is look-only, so the
;; instant a key means anything other than looking -- typing a character, RET,
;; or any of cooked's own commands that write to the child -- it ends on its
;; own, forwards whatever was pressed, and the buffer catches up immediately.
;; `cooked-peek-map' covers the first two, by reusing `cooked-send-key''s own
;; snap-to-cursor so typing lands exactly where the ghost cursor was already
;; pointing (see `cooked--peek-resume-and-send'); `cooked--send-to-child' and
;; `cooked-interrupt'/`cooked-suspend' cover the rest.  `cooked-toggle-peek'
;; remains the way to leave without acting on anything.
;;
;; That auto-resume is the half `evil' cannot use, and the reason the mode is
;; recomputed from evil's state rather than latched by a hook on it: in normal
;; state a letter is a motion, not `self-insert-command', so nothing here would
;; ever fire -- a buffer suspended on the way out of emacs state and then put
;; into insert state stayed suspended forever.  Deriving the mode instead means
;; insert state selects `cooked-semi-map' and resumes on its own, whatever
;; route got you into normal state.  See `cooked-input-mode-function', which is
;; the seam `cooked-evil.el' fills in.

(defvar cooked-mode-map)                ; `define-derived-mode' below makes it

(defun cooked--peek-resume-and-send ()
  "End peek and forward the key that invoked this command to the child.

Bound in `cooked-peek-map' wherever a key would otherwise self-insert or
submit a line: typing while peeking can only mean one thing, so there is no
reason to make resuming forwarding a separate step from it.  `cooked-send-key'
already snaps point to the child's cursor before sending, which is also
exactly where the ghost cursor was pointing the whole time peek was frozen."
  (interactive)
  (cooked--resume-forwarding)
  (cooked-send-key))

(defvar cooked-peek-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap self-insert-command] #'cooked--peek-resume-and-send)
    (define-key map (kbd "RET") #'cooked--peek-resume-and-send)
    (define-key map (kbd "<return>") #'cooked--peek-resume-and-send)
    map)
  "Keymap while forwarding is suspended, in `still' or `frozen'.

A child of `cooked-mode-map', not `cooked-mode-map' itself: binding the
`self-insert-command' remap there would also reach `cooked-input-map', which
needs ordinary self-insertion to keep editing pending input at a real prompt.
Typing here can only mean the child is wanted back, so it ends peek and
forwards the key that was pressed instead, same as `cooked-raw-map'/
`cooked-alt-map' would have without the interruption -- see
`cooked--peek-resume-and-send'.  Everything else -- motion, search, yanking a
selection as a copy, `cooked-toggle-fold' -- falls through to `cooked-mode-map'
and `comint-mode-map' beneath it exactly as it always did.")

(defun cooked--resume-forwarding ()
  "Hand the keyboard back to the child, and catch the buffer up.

Called by every command that writes to the child out of band -- an interrupt,
a paste, a signal -- so the result is seen landing rather than held behind a
freeze.  Clears a deliberate `cooked-toggle-peek' and recomputes the mode,
which for an `evil' user in normal state may well be `still' again: the point
is that the effect becomes visible, not that the user is dragged back into
forwarding they did not ask to resume.  A drain is forced in that case, since
nothing else would deliver it.

Not gated on a live session: one that ended while suspended must not strand
the buffer read-only with no way back."
  (let ((was cooked--input-mode))
    (setq cooked--peek-explicit nil)
    (when cooked--input-mode
      (cooked--refresh-keymap))
    (when (and cooked--session (eq was 'frozen) (cooked--frozen-p))
      (cooked--drain-and-apply))))

(defun cooked-toggle-peek ()
  "Step out to a read-only, navigable Emacs buffer, or back to the child.

While the child owns the keyboard, `cooked-raw-map'/`cooked-alt-map' forward
almost everything to it, which leaves no way to fire an Emacs command, search
the buffer, or navigate with `evil' normal state.  This suspends forwarding --
freezing the render so the child's own output does not disturb the view, and
making the buffer read-only so nothing can be edited into text that goes
nowhere -- and installs `cooked-peek-map' instead.  Peek is look-only: typing
a character or RET ends it and forwards what was pressed, same as it would
have gone straight through without the interruption (see
`cooked--peek-resume-and-send'), and so does any of cooked's own commands
that write to the child (`C-c C-c', `C-c C-y', and the rest).  Calling this
again leaves without acting on anything, and either way the buffer catches up
on whatever the child produced meanwhile.

The freeze lifts on its own when this buffer's window stops being the selected
one -- see `cooked--frozen-p'.  Holding a picture still is only worth anything
while someone is looking at it, and a terminal that stopped because its window
lost focus is a bug wearing a feature's clothes.

`evil' users reach the same place through their own states, and do not need
this: `C-z' to emacs state and back, or simply normal state, which is `still'
by default -- read-only and navigable, with the render still live.  This is the
door for everyone else."
  (interactive)
  (when (cooked--input-state-p)
    (user-error "Already editable"))
  (if cooked--peek-explicit
      (cooked--resume-forwarding)
    (setq cooked--peek-explicit t)
    (cooked--refresh-keymap)
    (message "Peeking (read-only) -- type, RET, or C-c C-v to resume")))

(defun cooked-send-literal-key ()
  "Send the next key to the child exactly, regardless of what it is bound to.

`cooked-raw-exceptions' (and, always, `C-c') keep some keys for Emacs while
the child owns the keyboard; this is the way back the other direction, for a
child that wants one of those keys for itself -- a readline-based REPL's own
`C-u', say.  Reaches `C-c' too: \\`C-c C-q C-c' sends a literal `C-c' byte.

Bound on `cooked-mode-map', so it also reaches the child while peeking -- ending
peek first, so the result is seen immediately -- but refuses once Emacs owns
the line -- see `cooked-send-string', which shares the reasoning."
  (interactive)
  (cooked--resume-forwarding)
  (when (cooked--input-state-p)
    (user-error "Emacs already owns the line; type directly instead"))
  (when-let* ((bytes (cooked--encode-event (read-key "Send key: "))))
    (cooked--snap-to-cursor)
    (cooked--send-to-child bytes)))

(defun cooked--exception-code (key)
  "The character code KEY names, signalling an error if it does not name one.

Only a single, unmodified control character in the 0-127 range is meaningful
here: passthrough is a raw-byte forwarding loop over exactly that range, not a
general keymap, so a modified chord such as `M-x' would silently do nothing
even if accepted -- see `cooked-raw-exceptions' for why."
  (let ((keys (kbd key)))
    (unless (and (stringp keys) (= (length keys) 1) (< (aref keys 0) 128))
      (error "cooked: %S does not name a single unmodified control character" key))
    (aref keys 0)))

(defun cooked--build-passthrough-map (exceptions &optional reserve-meta)
  "A keymap that forwards to the child, except EXCEPTIONS and `C-c'.
EXCEPTIONS is a list of character codes, as from `cooked--exception-code';
each is simply left unbound here, so it falls through to whatever
`cooked-mode-map'/`comint-mode-map'/`global-map' -- or `evil', if it has
installed a higher-priority keymap of its own -- would otherwise do with it.

With RESERVE-META, ESC and every Meta-modified key are left unbound too.  That
is one exception expressed as a rule rather than a list, and it has to be:
`kbd' spells Meta as a modifier bit on a GUI frame and as a leading ESC on a
terminal, so no list of character codes can name `M-x' in both -- while leaving
ESC itself unbound makes Emacs' own `meta-prefix-char' handling the thing that
answers, in whichever spelling the frame produces.  The cost is the one thing
ESC is otherwise good for here: a forwarded ESC has no latency, and a prefix
key waits.  See `cooked-semi-map', which is where that trade is worth making."
  (let ((map (make-sparse-keymap)))
    (define-key map [remap self-insert-command] #'cooked-send-key)
    (dolist (code (number-sequence 0 127))
      (unless (or (eq code cooked--escape-key)
                  (and reserve-meta (eq code meta-prefix-char))
                  (memq code exceptions))
        (define-key map (vector code) #'cooked-send-key)))
    ;; Bind the modified variants explicitly, not for completeness but for
    ;; correctness: when `S-return' has no binding Emacs shift-translates it to
    ;; `return' and runs *that* binding, with `last-command-event' already flattened.
    ;; By the time `cooked-send-key' looks, the shift is gone and unrecoverable.
    (dolist (entry cooked--special-keys)
      (dolist (prefix '("" "S-" "C-" "M-" "C-S-" "M-S-" "C-M-"))
        (unless (and reserve-meta (string-search "M-" prefix))
          (define-key map (vector (intern (concat prefix (symbol-name (car entry)))))
                      #'cooked-send-key))))
    ;; Everything else cooked binds under `C-c' -- its own commands, and the
    ;; ones that write to the child out of band -- lives on `cooked-mode-map'
    ;; instead of here, so it survives peeking too; see the `set-keymap-parent'
    ;; block below `define-derived-mode'.
    (dolist (event '(down-mouse-1 mouse-1 down-mouse-2 mouse-2 down-mouse-3 mouse-3
                     wheel-up wheel-down mouse-4 mouse-5))
      (define-key map (vector event) #'cooked-mouse-event))
    map))

(defun cooked--set-passthrough-map (map exceptions &optional reserve-meta)
  "Replace MAP's own bindings with a fresh passthrough map for EXCEPTIONS.
Keeps MAP's identity, and so the keymap parent `cooked-mode' gives it, intact
-- used to rebuild `cooked-raw-map' when `cooked-raw-exceptions' changes.

`set-keymap-parent' stores the parent as the list's own terminating cdr
rather than in a separate slot, so a plain `(setcdr map (cdr fresh))' would
silently drop it; save and restore it around the replacement."
  (let ((parent (keymap-parent map)))
    (setcdr map (cdr (cooked--build-passthrough-map exceptions reserve-meta)))
    (set-keymap-parent map parent)))

(defcustom cooked-raw-exceptions '("C-g" "C-x" "C-h" "C-u" "C-l")
  "Keys left bound to their ordinary Emacs command during a raw, non-alt-screen
read (`cooked--policy' returns `raw'), instead of forwarding to the child.

Only in `raw', which is now the degraded state: with the OSC 133 integration
working the policy is `command' instead, and that keeps nothing back -- see
`cooked-command-map'.  This list is the hedge for a session where the shell
never spoke.

`raw' is treated less aggressively than `alt' (see `cooked-alt-map', which has
no equivalent list) because it is a fuzzier state: non-shell REPLs with their
own raw-mode line editors, single-keypress prompts, and -- the case that
matters most -- any shell session without cooked's OSC 133 integration wired
up, where `cooked--policy' cannot tell a raw program from a shell editing its
own prompt line and must guess `raw'.  In that last case the user is, from
their own point of view, just sitting at an ordinary prompt, so losing the
universal quit key outright is a worse trade than reserving a handful of
control characters most raw programs do not need for themselves.

Each entry names a single control character via `kbd', e.g. \"C-g\".  `C-y' is
deliberately not offered here even though it would otherwise be a plausible
candidate: it is both vim's scroll-up-a-line and readline's own yank, real
bindings a user relying on the child is actively using.  `M-x'/`M-o'/`M-y'
are not offerable at all, for a different reason -- they are Meta-modified
letters, which this list has no way to reach in the first place: a bare ESC
byte is forwarded the instant it is pressed, for the sake of a real
terminal's Escape key having no latency, so on a terminal frame `ESC' and the
letter that follows are two independently-forwarded bytes before Emacs' own
Meta-prefix logic ever runs.  `C-c M-x' remains the one escape hatch
guaranteed to work regardless of frame type.

`cooked-send-literal-key' (\\`C-c C-q') sends any one key through to the child
regardless of this list, for a raw program that wants one of these keys back."
  :type '(repeat string)
  :set (lambda (symbol value)
         (set-default symbol value)
         (when (and (boundp 'cooked-raw-map) (keymapp cooked-raw-map))
           (cooked--set-passthrough-map
            cooked-raw-map (mapcar #'cooked--exception-code value))))
  :group 'cooked)

(defvar cooked-raw-map
  (cooked--build-passthrough-map (mapcar #'cooked--exception-code cooked-raw-exceptions))
  "Keymap while the child is doing a raw, non-alt-screen read.")

(defvar cooked-command-map
  (cooked--build-passthrough-map nil)
  "Keymap while the shell has told us a command is running.

No exceptions, for the same reason `cooked-alt-map' has none: this is a
positive signal rather than a guess.  `cooked-raw-exceptions' exists to hedge
the case where cooked cannot tell a raw program from a shell editing its own
prompt line, and OSC 133 removes that doubt -- so `C-u' and `C-l' go to the
program that asked for them, as they would in any other terminal.  See
`cooked--policy'.")

(defvar cooked-alt-map
  (cooked--build-passthrough-map nil)
  "Keymap while the child holds the alternate screen.

Deliberately has no exceptions, customizable or otherwise, beyond `C-c': a
full-screen program can plausibly want any key for itself, including
`C-g'/`C-x'/`C-u'/`C-h' if the program happens to be `emacs -nw' or `vim'
itself.  `cooked-toggle-peek' (or, for `evil' users, the ordinary `C-z' escape
to `evil-emacs-state') is the way to reach Emacs here, rather than a static
list that would collide with whatever the program wants those keys for.")

(defcustom cooked-semi-exceptions '("C-g" "C-x" "C-h" "C-u" "C-l")
  "Control characters `cooked-semi-map' keeps for Emacs.

The same idea as `cooked-raw-exceptions', asked in a different place: that
list hedges a state cooked is unsure about, this one describes a state the
user has chosen.  ESC and the whole Meta space are held back as well, and are
not listed here -- see `cooked-semi-map'.

`cooked-send-literal-key' (\\`C-c C-q') sends any one of these through to the
child anyway, for the program that wants it back."
  :type '(repeat string)
  :set (lambda (symbol value)
         (set-default symbol value)
         (when (and (boundp 'cooked-semi-map) (keymapp cooked-semi-map))
           (cooked--set-passthrough-map
            cooked-semi-map (mapcar #'cooked--exception-code value) t)))
  :group 'cooked)

(defvar cooked-semi-map
  (cooked--build-passthrough-map
   (mapcar #'cooked--exception-code cooked-semi-exceptions) t)
  "Keymap for forwarding that stops short of taking Emacs away.

The other passthrough maps answer \"the child needs every key\" and reserve `C-c'
only, which is right for a full-screen program and wrong for the state an
`evil' user spends most of their time in.  Insert state is supposed to be a
state you can leave: if ESC forwards, the way out is gone, and if every Meta
chord forwards, so is `M-x' and so is the non-normal leader most `evil'
configurations put on `M-SPC'.

So this map holds back three things: `cooked-semi-exceptions', ESC, and --
because ESC unbound is what makes Emacs treat it as `meta-prefix-char' again
-- the entire Meta space, without naming a key of it.  Everything else still
goes to the child, `C-a'/`C-e'/`C-k'/`C-r' included, which is the half that
matters: those are readline's and vim's, and a rule of \"Emacs wins wherever
Emacs has a binding\" would have taken all of them, `global-map' binding
almost every control character.  That is the same conclusion `vterm' and
`eat' reached -- `vterm-keymap-exceptions' and `eat-semi-char-non-bound-keys'
are both explicit lists over an otherwise total map, for this reason.

The cost is ESC's latency: unbound here, it waits to see whether a Meta chord
follows.  That is why the full maps keep forwarding it instead, and why this
map is not the default anywhere.")

(defvar cooked-input-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'cooked-send-input)
    (define-key map (kbd "<S-return>") #'cooked-newline)
    (define-key map (kbd "C-d") #'cooked-delete-char-or-eof)
    (define-key map (kbd "TAB") #'completion-at-point)
    (define-key map (kbd "M-p") #'cooked-previous-input)
    (define-key map (kbd "M-n") #'cooked-next-input)
    map)
  "Keymap while Emacs owns the input line.

Cooked's own `C-c'-prefixed commands (interrupt, EOF, paste, and the rest)
are not repeated here -- they live on `cooked-mode-map', this map's parent,
so the same set reaches `cooked-raw-map'/`cooked-alt-map' and a bare peek
without being declared three times over.")

(defun cooked-send-input ()
  "Submit the pending input to the child.
The kernel echoes it back, so the emulator renders the line, not us.

Enter is sent as CR, which is what a terminal actually transmits: in canonical
mode `ICRNL' turns it into the newline the child expects, and in raw mode it is
what a shell's line editor is bound to.  Sending LF works for readline but not
for ZLE."
  (interactive)
  (let ((text (or (cooked--take-pending-input) "")))
    (cooked--clear-input-region)
    (cooked--history-record text)
    (cooked--send-input-string text)))

(defun cooked--send-input-string (text)
  "Submit TEXT to the child as one line of input.

Split out from `cooked-send-input' because `comint-input-sender' hands us the
string rather than the buffer region, and both must submit the same way."
  (setq cooked--submitted-input (and (not (string-blank-p text)) text))
  (cooked--send-to-child
   ;; A multi-line submission has to arrive as a paste, or the shell's line editor
   ;; treats every embedded newline as its own Enter and runs the fragments one at
   ;; a time.
   (if (and (string-search "\n" text)
            (cooked--bracketed-paste-p cooked--session))
       (concat "\e[200~" text "\e[201~\r")
     (concat text "\r"))))

(defun cooked-newline ()
  "Insert a newline in the pending input without submitting it.

Shift+RET, so a multi-line command can be composed as one edit.  The pending
input is lifted out and put back verbatim on every redisplay, so an embedded
newline survives until you submit."
  (interactive)
  (unless (cooked--input-state-p)
    (user-error "Not at an input prompt"))
  (unless (cooked--input-region)
    (cooked--restore-pending-input nil))
  (insert "\n"))

;;;; History
;;
;; Forwarding the arrow keys to the shell would desync, because the line being
;; edited lives in Emacs and the shell's line editor has never seen it.  So the
;; history is Emacs' own; the shell still records the same commands, since it
;; receives each one whole.
;;
;; `comint-input-ring' holds it -- not a private list.  It used to be private
;; because comint's ring navigates relative to a process mark cooked did not
;; maintain (`comint-previous-input' answering "Not at command line" was the
;; symptom), and `cooked--input-mark' settled that.  Everything hung off the
;; ring comes with it: `comint-input-ignoredups', `comint-input-ring-size',
;; ring persistence, and the isearch that `comint-mode' has been installing all
;; along and that had nothing to search until now.
;;
;; The *editing* stays cooked's, and that asymmetry is deliberate.
;; `comint-goto-input' deletes from the process mark to `point-max' on the
;; assumption that input is the last thing in the buffer, which is exactly the
;; assumption cooked breaks: there are rendered screen rows below the prompt, so
;; comint's own recall would take them with it.  `cooked--replace-input' works
;; between the two ends of the region instead -- see `cooked--input-end', which
;; is the half comint has no counterpart for.

(defun cooked--replace-input (text)
  "Replace the pending input with TEXT."
  (when-let* ((region (cooked--input-region)))
    (let ((inhibit-read-only t))
      (delete-region (car region) (cdr region))
      (save-excursion
        (goto-char (car region))
        (insert text)))
    (goto-char cooked--input-end)))

(defun cooked--history-record (text)
  "Add TEXT to the input history, unless it is blank.
`comint-input-ignoredups' is honoured, so a repeated command does not stack up."
  (unless (string-blank-p text)
    (when (or (not comint-input-ignoredups)
              (ring-empty-p comint-input-ring)
              (not (equal (ring-ref comint-input-ring 0) text)))
      (ring-insert comint-input-ring text)))
  (setq comint-input-ring-index nil
        cooked--history-stash nil))

(defun cooked--history-move (delta)
  "Step DELTA entries through the input history.
Positive DELTA moves towards older entries, as \[cooked-previous-input] does."
  (unless (cooked--input-state-p)
    (user-error "Not at an input prompt"))
  (when (ring-empty-p comint-input-ring)
    (user-error "No input history yet"))
  (unless (cooked--input-region)
    (cooked--restore-pending-input nil))
  ;; What was half-typed is put aside on the way out and handed back on the way
  ;; past the newest entry, so browsing history never costs you the line you were
  ;; writing.  comint has no equivalent; it simply loses it.
  (when (null comint-input-ring-index)
    (setq cooked--history-stash (or (cooked--pending-input) "")))
  (let ((next (max -1 (min (+ (or comint-input-ring-index -1) delta)
                           (1- (ring-length comint-input-ring))))))
    (setq comint-input-ring-index (and (>= next 0) next))
    (cooked--replace-input (if comint-input-ring-index
                               (ring-ref comint-input-ring comint-input-ring-index)
                             (or cooked--history-stash "")))))

(defun cooked-previous-input (&optional n)
  "Recall the Nth previous input."
  (interactive "p")
  (cooked--history-move (or n 1)))

(defun cooked-next-input (&optional n)
  "Recall the Nth next input."
  (interactive "p")
  (cooked--history-move (- (or n 1))))

(defun cooked-delete-char-or-eof ()
  "Delete forward, or send EOF when the input line is empty."
  (interactive)
  (if (string-empty-p (or (cooked--pending-input) ""))
      (cooked--send-to-child "\C-d")
    (delete-char 1)))

(defun cooked-send-eof ()
  "Send EOF to the child.

Unlike \\[cooked-interrupt] this is a byte, not a signal: in canonical mode the
line discipline turns it into end-of-input, and a raw-mode program reads it as
^D.  Bound explicitly because at a prompt plain \\[cooked-delete-char-or-eof]
deletes forward unless the line is already empty.  Ends peek first when
peeking, so the effect is seen right away."
  (interactive)
  (cooked--resume-forwarding)
  (cooked--send-to-child "\C-d"))

(declare-function cooked--job-control "cooked-core")
(declare-function cooked--remove-rows "cooked-core")

(defun cooked--send-job-control (session key signal)
  "Ask SESSION for job control the way a terminal does.

KEY is `:intr\=', `:quit\=' or `:susp\=', and SIGNAL the signal the line discipline
would raise for it.  A terminal sends no signal of its own: it writes the
character the tty has in `c_cc\=' and lets the line discipline decide.  Reading
that character rather than assuming ^C/^\\/^Z is what makes `stty intr ^X\='
work, and honouring ISIG is what keeps a program that deliberately cleared it
-- so as to read the byte itself -- from being signalled behind its own back.

SIGNAL is the fallback, for the two cases where writing cannot mean anything:
ISIG is off, so no byte would be turned into one; or the character is disabled
\=(`_POSIX_VDISABLE\='), so there is no byte to write."
  (let* ((jc (cooked--job-control session))
         (char (plist-get jc key)))
    (if (and (plist-get jc :isig) char)
        (cooked--send-to-child (string char))
      (cooked--signal session signal))))

(defun cooked-suspend ()
  "Suspend the foreground command.
Ends peek first when peeking, so the effect is seen right away rather than
held behind the freeze."
  (interactive)
  (cooked--resume-forwarding)
  (cooked--send-job-control (cooked--require-session) :susp 20))

(defun cooked-quit ()
  "Quit the foreground command -- SIGQUIT, the harder sibling of \\[cooked-interrupt].

Sent the way a terminal sends it; see `cooked--send-job-control\='.  Bound where
comint puts it, on \\`C-c C-\\\\', whose own `comint-quit-subjob\=' would
`quit-process\=' the wakeup pipe -- the only process this buffer has, and not the
child."
  (interactive)
  (cooked--resume-forwarding)
  (let ((session (cooked--require-session)))
    (cooked--clear-input-region)
    (cooked--send-job-control session :quit 3)))

(defun cooked-interrupt ()
  "Interrupt the foreground command.

The session is checked before the pending input is abandoned, so a C-c that
cannot be delivered leaves the line you were typing where it was.  Ends peek
first when peeking: a signal you cannot see land is not worth sending blind."
  (interactive)
  (cooked--resume-forwarding)
  (let ((session (cooked--require-session)))
    (cooked--clear-input-region)
    (cooked--send-job-control session :intr 2)))

;;;; State transitions

(defun cooked--set-mode (mode)
  "Adopt MODE, switching keymaps and handling secret prompts on a change."
  (unless (eq mode cooked--mode)
    (setq cooked--mode mode)
    (cooked--refresh-keymap)
    (if (eq mode 'secret)
        (cooked--schedule-secret)
      (cooked--cancel-secret))))

(defvar cooked-state-change-hook nil
  "Hook run in the session's buffer after who owns the keyboard changes.

Run once the keymap has been swapped, so `cooked--input-state-p' already reports
the new state.  This is the seam `cooked-evil' hangs off; anything else that has
to follow the input/raw switch can use it without cooked knowing about it.")

(defvar cooked-input-mode-function #'cooked--default-input-mode
  "Function returning the `cooked--input-mode' for a buffer, or nil for none.

Called with no arguments, in the session's buffer, whenever the state is
recomputed.  It is asked only while the child owns the keyboard: at a real
prompt Emacs owns the line outright and there is nothing to suspend, so the
answer is forced to nil rather than requested.

This is the seam that lets `cooked-evil.el' make the mode a function of evil's
state without cooked knowing evil exists.  A function, not a variable, because
the mode has to be *derived* on every state change rather than latched by a
hook -- see the commentary above `cooked-toggle-peek' for what latching it
cost.")

(defun cooked--default-input-mode ()
  "Suspend only when `cooked-toggle-peek' says so.
The answer for anyone not driving this from somewhere else."
  (and cooked--peek-explicit 'frozen))

(defun cooked--state-keymap (mode policy)
  "The local map for input mode MODE under policy POLICY."
  (pcase mode
    ((or 'still 'frozen) cooked-peek-map)
    ('semi cooked-semi-map)
    (_ (pcase policy
         ('cooked cooked-input-map)
         ('alt cooked-alt-map)
         ('command cooked-command-map)
         ('raw cooked-raw-map)))))

(defun cooked--refresh-keymap (&optional quiet)
  "Install the keymap and render mode the current state asks for.

Two axes meet here: `cooked--policy', which is what the child is doing, and
`cooked-input-mode-function', which is what the user is doing.  The child wins
where it must -- at a prompt Emacs owns the line, so no mode suspends anything
and a deliberate peek ends, there being no reason to stay frozen once there is
a genuine prompt to edit.  Everywhere else the mode decides, which is how a
peek survives a `raw'<->`alt' transition: it is recomputed to the same answer
rather than preserved.

With QUIET, `cooked-state-change-hook' is not run.  That hook means \"who owns
the keyboard changed\", and `cooked-evil-sync' acts on it by putting evil into
the state the child's ownership calls for -- so running it from a refresh that
evil itself triggered would have evil immediately undo the user's own `C-z'.

The hook runs last, after everything here has settled, so that a handler which
changes state and refreshes again nests cleanly: the inner refresh's decisions
are the ones left standing."
  (when (eq (cooked--policy) 'cooked)
    (setq cooked--peek-explicit nil))
  (let* ((policy (cooked--policy))
         (was cooked--input-mode)
         (mode (unless (eq policy 'cooked)
                 (funcall cooked-input-mode-function))))
    (setq cooked--input-mode mode)
    (let ((read-only (and (cooked--suspended-p) t)))
      (unless (eq buffer-read-only read-only)
        (setq buffer-read-only read-only)))
    (use-local-map (cooked--state-keymap mode policy))
    ;; After the mode is already set, so the drain's own `cooked--set-mode' does
    ;; not find a freeze still in force and recurse back into here.
    (when (and cooked--session (eq was 'frozen) (not (eq mode 'frozen)))
      (cooked--drain-and-apply))
    (unless (cooked--input-state-p)
      (cooked--clear-input-region))
    (cooked--update-mouse-grab)
    (unless quiet
      (run-hooks 'cooked-state-change-hook))))

(defun cooked-last-exit-code ()
  "Exit status of the most recently finished command, if any."
  (when-let* ((command (car cooked--commands)))
    (cooked-command-code command)))

(defun cooked--command-at (point)
  "The command record whose output contains POINT."
  (seq-find (lambda (command)
              (<= (cooked--command-start-position command)
                  point
                  (cooked--command-end-position command)))
            cooked--commands))

(defun cooked--command-starts ()
  "Where each recorded command's output begins, in buffer order.

`cooked--commands' is newest first, which is the order the records are pushed
in and the order `cooked-last-exit-code' wants; moving through the transcript
wants the other one."
  (nreverse (mapcar #'cooked--command-start-position cooked--commands)))

(defun cooked--goto-nth-command (n direction)
  "Move to the Nth command start in DIRECTION, `forward' or `backward'.

Stops at the far end of the buffer rather than erroring, so holding the key
down walks to the top or bottom and settles there."
  (let* ((starts (cooked--command-starts))
         (before (seq-filter (lambda (p) (< p (point))) starts))
         (after (seq-filter (lambda (p) (> p (point))) starts)))
    (goto-char (or (if (eq direction 'backward)
                       (car (last before n))
                     (nth (1- n) after))
                   (if (eq direction 'backward) (point-min) (point-max))))))

(defun cooked-previous-command (&optional n)
  "Move to the start of the Nth previous command's output."
  (interactive "p")
  (cooked--goto-nth-command (or n 1) 'backward))

(defun cooked-next-command (&optional n)
  "Move to the start of the Nth next command's output."
  (interactive "p")
  (cooked--goto-nth-command (or n 1) 'forward))

(defun cooked--get-old-input ()
  "The command line at point, for `comint-get-old-input\='.

comint\='s default scans backwards for a prompt it can recognise.  The OSC 133
records already know where the line began, so \\[comint-copy-old-input] recovers
exactly what was run rather than whatever a regexp happened to match."
  (or (when-let* ((command (cooked--command-at (point))))
        (cooked--command-input command))
      ""))

(defun cooked-delete-output ()
  "Delete the output of the command at point, keeping the command line.

Bound where comint puts `comint-delete-output\=', which cannot be reused: it puts
its \"*** output flushed ***\" notice back through `comint-output-filter\=', the
insertion path cooked replaced with the drain outright.

Nothing is deleted here.  The rows belong to the emulator, so this asks it to
remove them and lets the ordinary drain repaint what moved -- the same shape as
sending input, which also changes rows, and by the same rule: the grid has one
owner.  Deleting the buffer text instead would leave the two ends disagreeing
about what the screen is, since the grid would still hold every row.

Refuses when the output reaches the row the child is on.  Below that the shell
is editing its own prompt line and tracking where it sits, and moving it would
corrupt a redisplay cooked cannot see, let alone repair."
  (interactive)
  (let* ((command (or (cooked--command-at (point)) (car cooked--commands)))
         (beg (and command (cooked--command-start-position command)))
         (end (and command (cooked--command-end-position command))))
    (unless (and beg end (< beg end))
      (user-error "No command output here"))
    (pcase-let ((`(,first . ,_) (or (cooked--screen-cell beg)
                                    (user-error "That output has left the screen")))
                ;; END is one past the output, so it lands on whatever the child drew
                ;; next -- usually the following prompt.  The last row actually holding
                ;; output is the one the final character sits on.
                (`(,last . ,_) (or (cooked--screen-cell (max beg (1- end)))
                                   (user-error "That output has left the screen"))))
      (unless (< last (cooked-cursor-row cooked--cursor))
        (user-error "The child is still on that row"))
      (cooked--remove-rows (cooked--require-session) first (1+ (- last first)))
      (cooked--drain-and-apply))))

(defun cooked-toggle-fold ()
  "Hide or reveal the output of the command at point."
  (interactive)
  (let* ((command (or (cooked--command-at (point)) (car cooked--commands)))
         (beg (and command (cooked--command-start-position command)))
         (end (and command (cooked--command-end-position command))))
    (unless (and beg end (< beg end))
      (user-error "No command output here"))
    (if-let* ((existing (seq-find (lambda (o) (overlay-get o 'cooked-fold))
                                  (overlays-in beg end))))
        (delete-overlay existing)
      (let ((overlay (make-overlay beg end)))
        (overlay-put overlay 'cooked-fold t)
        (overlay-put overlay 'invisible t)
        (overlay-put overlay 'before-string
                     (propertize (format " [%d lines folded] "
                                         (count-lines beg end))
                                 'face 'shadow))))))

;;;; Secrets

(defun cooked--schedule-secret ()
  "Prompt for a secret once the prompt text has had time to arrive."
  (cooked--cancel-secret)
  (setq cooked--secret-timer
        (run-with-timer cooked-secret-debounce nil
                        (let ((buffer (current-buffer)))
                          (lambda () (cooked--prompt-secret buffer))))))

(defun cooked--cancel-secret ()
  "Abandon any pending secret prompt."
  (when cooked--secret-timer
    (cancel-timer cooked--secret-timer)
    (setq cooked--secret-timer nil)))

(defun cooked--prompt-secret (buffer)
  "Read a secret for BUFFER and send it, without it touching the buffer.

The secret never reaches the buffer, and the copies cooked itself makes
are cleared: it is sent as two writes rather than one `concat', which a
child reading canonically cannot distinguish, and the native core zeroes
its byte buffer after writing.

That is the honest limit of it.  `read-passwd' builds the string in
Emacs' own heap, the garbage collector relocates and compacts small
strings so earlier copies survive in freed blocks that `clear-string'
never sees, and an auth-source backend caches plaintext by design.
cooked cannot promise a password leaves no trace in Emacs' address
space, and does not."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq cooked--secret-timer nil)
      (when (eq cooked--mode 'secret)
        (let* ((prompt (or (cooked--prompt-text cooked--session) "Password"))
               (prompt (if (string-suffix-p ":" prompt) (concat prompt " ") (concat prompt ": "))))
          (condition-case nil
              (let ((secret (or (and cooked-password-function
                                     (funcall cooked-password-function prompt))
                                (read-passwd prompt))))
                (unwind-protect
                    (progn (cooked--send-to-child secret)
                           (cooked--send-to-child "\n"))
                  (clear-string secret)))
            ;; C-g at the prompt should interrupt the child's read rather than leave
            ;; it blocked on a `getpass' nobody is going to answer.
            (quit
             (cooked--send-if-live "\C-c")
             (signal 'quit nil))))))))

;;;; Size and lifecycle

(defun cooked--sync-size (&optional _frame)
  "Match the emulator and child to the window size.
The buffer needs no adjustment: a resize marks every row damaged, and rendering
extends or trims the screen region to suit."
  (when cooked--session
    (pcase-let ((`(,rows . ,cols) (cooked--window-size)))
      (unless (equal cooked--last-size (cons rows cols))
        (setq cooked--last-size (cons rows cols)
              cooked--rows rows
              cooked--cols cols)
        (cooked--resize cooked--session rows cols)))))

(defun cooked--frame-size-changed (frame)
  "Resync every live session displayed in FRAME.

`window-size-change-functions' runs once per frame rather than once per buffer,
so a buffer-local hook on it only fires when that buffer happens to be current —
which it usually is not.  Walk the frame's windows instead."
  (dolist (window (window-list frame 'no-minibuf))
    (with-current-buffer (window-buffer window)
      (when cooked--session
        (cooked--sync-size)))))

;; Added when the first session starts rather than at load time, so requiring the
;; package changes nothing about Emacs until you actually use it.  `add-hook' dedupes,
;; so calling this once per buffer is free.
(defun cooked--window-selection-changed (_frame)
  "Report focus when this buffer's window gains or loses selection."
  (cooked--report-focus))

(defun cooked--update-attention (&rest _)
  "Track, for every live session, whether the user is looking at it.

A freeze is only worth anything while someone is reading the picture it holds
still, so it lifts for as long as the buffer is not the selected window's --
see `cooked--frozen-p'.  Walking every session rather than running
buffer-locally is what catches the case a buffer-local hook cannot: switching
to another buffer *in the same window* leaves the cooked buffer displayed
nowhere, and nothing buffer-local runs in a buffer that is no longer shown.

Draining on the way out matters as much as the flag does: the wakes that
arrived while frozen were skipped, so without this the buffer would sit at
whatever it showed when the freeze began until something else asked."
  (cooked--dolist-buffers
    (when cooked--session
      (let ((state (cond ((eq (current-buffer) (window-buffer (selected-window)))
                          'here)
                         ;; Displayed elsewhere, or displayed nowhere having
                         ;; been somewhere a moment ago -- both are the user
                         ;; being elsewhere.  A buffer that has never been on
                         ;; screen stays nil and keeps its freeze.
                         ((or cooked--attention (get-buffer-window nil t))
                          'away))))
        (unless (or (null state) (eq state cooked--attention))
          (setq cooked--attention state)
          (when (and (eq state 'away) (eq cooked--input-mode 'frozen))
            (cooked--drain-and-apply)))))))

(defun cooked--install-global-hooks ()
  "Install the hooks that cannot be buffer-local."
  (add-hook 'window-size-change-functions #'cooked--frame-size-changed)
  ;; Both, because they answer different halves of "is the user looking at it":
  ;; selection moving to another window, and the window they are in showing
  ;; something else.
  (add-hook 'window-selection-change-functions #'cooked--update-attention)
  (add-hook 'window-buffer-change-functions #'cooked--update-attention)
  ;; Frame focus is not a per-buffer event, so this one walks live sessions.
  ;;
  ;; `after-focus-change-function' holds a *single function*, defaulting to `ignore',
  ;; and is not a hook despite reading like one.  `add-hook' on it conses onto
  ;; whatever is there — including another package's advice — and leaves a list where
  ;; Emacs expects something callable, so the next focus change signals
  ;; `Invalid function'.  `add-function' is the documented way in, and the name
  ;; property is what keeps installing it once per session idempotent.
  (add-function :after after-focus-change-function #'cooked--frame-focus-changed
                '((name . cooked--focus))))

;;;; Focus reporting — DEC mode 1004
;;
;; A child that asked for it is told when the window it is displayed in gains or
;; loses the keyboard: nvim's FocusGained/FocusLost autocmds, tmux's redraw, and
;; shells that re-check for externally modified files all hang off this.
;;
;; "Focused" here means this buffer's window is the selected one in a focused
;; frame.  That is stricter than frame focus alone and is the honest answer: a
;; cooked buffer in a background window is not receiving your keystrokes.

(defvar-local cooked--focused t
  "Whether the child last believed it had the keyboard.

Starts t so a session that begins focused sends nothing — the child's own
assumption on startup is that it has focus, and telling it so again is noise.")

(defun cooked--focused-p ()
  "Whether this buffer's window is selected in a frame that has focus."
  (and (eq (current-buffer) (window-buffer (selected-window)))
       (frame-focus-state (window-frame (selected-window)))
       t))

(defun cooked--report-focus ()
  "Tell the child about a focus change, when it asked to be told."
  (let ((focused (cooked--focused-p)))
    (unless (eq focused cooked--focused)
      (setq cooked--focused focused)
      (when-let* ((session (cooked--live-session)))
        (when (cooked--focus-events-p session)
          (cooked--send-if-live (if focused "\e[I" "\e[O")))))))

(defun cooked--frame-focus-changed (&rest _)
  "Report focus for every live session, from `after-focus-change-function'."
  (cooked--dolist-buffers
    (when cooked--session
      (cooked--report-focus))))

(defcustom cooked-kill-buffer-on-exit nil
  "Whether the session buffer is killed when the child exits.

nil keeps the buffer, exit status and all, which is the point of running the
terminal inside Emacs: the transcript outlives the command.  t kills it,
`on-success' kills it only for a zero status — the shell-in-a-window habit,
where a failure is the one case you still want to read.  A function is called
with the exit code and kills the buffer when it returns non-nil.

The buffer is killed from a timer rather than mid-redraw, so `kill-buffer-hook'
and anything watching the buffer list see an ordinary kill."
  :type '(choice (const :tag "Keep the buffer" nil)
                 (const :tag "Always kill it" t)
                 (const :tag "Kill it only on a zero exit status" on-success)
                 (function :tag "Function of the exit code"))
  :group 'cooked)

(defun cooked--kill-buffer-on-exit-p (code)
  "Whether `cooked-kill-buffer-on-exit' wants the buffer killed for CODE."
  (pcase cooked-kill-buffer-on-exit
    ('nil nil)
    ('on-success (eql code 0))
    ((and (pred functionp) f) (funcall f code))
    (_ t)))

(defun cooked--on-exit (code)
  "Report that the child exited with CODE and stop the session."
  ;; A child can die while still on the alt screen — killed from outside, or
  ;; crashed mid-redraw — and nothing later would widen the buffer for it.
  (setq cooked--alt nil)
  (cooked--release-alt-pin)
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-max))
      (insert (format "\n[exited %s]\n" code))))
  (when cooked--session (ignore-errors (cooked--kill cooked--session)))
  (when cooked--wake (delete-process cooked--wake))
  (setq cooked--session nil cooked--wake nil)
  ;; Deferred: this runs from inside the drain, which keeps working with the
  ;; buffer and its locals after we return.  Killing here would pull them out
  ;; from under it, and would run `kill-buffer-hook' — arbitrary user code —
  ;; halfway through a redraw.
  (when (cooked--kill-buffer-on-exit-p code)
    (let ((buffer (current-buffer)))
      (run-at-time 0 nil (lambda () (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(defface cooked-failure '((t :inherit error))
  "Face for a non-zero exit status in the mode line."
  :group 'cooked)

(defface cooked-success '((t :inherit success))
  "Face for a zero exit status in the mode line."
  :group 'cooked)

(defface cooked-still '((t :inherit shadow))
  "Face for the `still' indicator in the mode line.

Quieter than `cooked-peek', and deliberately: nothing is being held back in
`still' -- the child is drawing, the buffer is current, only the view is
staying where it was put.  It is worth saying, not worth warning about."
  :group 'cooked)

(defface cooked-peek '((t :inherit warning))
  "Face for the `frozen' indicator in the mode line.

Peeking used to have no mode-line indicator at all, which made it easy to
forget you had toggled out and wonder why keys had stopped reaching the
child; this is what makes it visible."
  :group 'cooked)

(defun cooked--mode-line ()
  "Compact indicator: what is running, who owns the keyboard, how it went."
  (let ((code (cooked-last-exit-code)))
    (concat
     ;; Echo state is an overlay on the policy, but it subsumes it in the indicator:
     ;; a password read always forwards keys, so " raw secret" says nothing " secret"
     ;; does not already imply.
     (if (cooked--secret-p)
         " secret"
       (pcase (cooked--policy)
         ('cooked " edit")
         ('alt " alt")
         (_ " raw")))
     (pcase cooked--input-mode
       ('semi (propertize " semi" 'face 'shadow))
       ('still (propertize " still" 'face 'cooked-still))
       ('frozen (propertize " frozen" 'face 'cooked-peek)))
     ;; The title is the shell's own summary of the running command.
     (when (and cooked--title (not (string-empty-p cooked--title)))
       (propertize (format " %s" (truncate-string-to-width cooked--title 24 nil nil t))
                   'face 'shadow))
     (when code
       (propertize (format " %s" code)
                   'face (if (zerop code) 'cooked-success 'cooked-failure))))))

(define-derived-mode cooked-mode comint-mode "cooked"
  "Major mode for a terminal that hands the keyboard back for line input.

In `cooked' and OSC 133 input states the buffer behaves like any editable Emacs
buffer and \\[cooked-send-input] submits the line.  Otherwise keys are forwarded
to the child verbatim."
  :interactive nil
  (setq-local scroll-conservatively 101
              truncate-lines (not cooked-rejoin-wrapped-lines)
              mode-line-process '(:eval (cooked--mode-line)))
  ;; comint would send the line to the process behind the buffer, which here is the
  ;; wakeup pipe.  Every submission goes to the child instead, so `comint-send-input'
  ;; is a working command rather than something to be remapped around -- and nothing
  ;; can reach the pipe by accident.
  (setq-local comint-input-sender (lambda (_proc input) (cooked--send-input-string input)))
  ;; The ring `comint-mode' just built is the history; it is at the default 500,
  ;; which is what cooked kept anyway.  Repeats are dropped, as a shell's own
  ;; history does by default and as cooked's private list used to.
  (setq-local comint-input-ignoredups t)
  ;; The OSC 133 records know where each command line began; comint would otherwise
  ;; scan backwards for a prompt regexp cooked deliberately never sets.
  (setq-local comint-get-old-input #'cooked--get-old-input)
  ;; comint leaves this at `(nil t)', under which the first fontification strips a
  ;; bare `face' property -- the reason the renderer used to set `font-lock-face'
  ;; alongside every `face' it applied.  Clearing it lets one property carry a run.
  (setq-local font-lock-defaults nil)
  ;; Above every minor mode, so a program that asked for the wheel gets it even
  ;; where `pixel-scroll-precision-mode' has claimed the same events.
  (add-to-list 'emulation-mode-map-alists 'cooked--mouse-map-alist)
  (cooked--install-global-hooks)
  (add-hook 'pre-command-hook #'cooked--snap-to-input nil t)
  (add-hook 'post-command-hook #'cooked--track-wandering nil t)
  (add-hook 'completion-at-point-functions #'cooked-completion-at-point nil t)
  ;; comint's own completion asks a process that is not the child.  Removed rather
  ;; than left sitting behind ours as a fallback that can only ever be wrong.
  (remove-hook 'completion-at-point-functions #'comint-completion-at-point t)
  (add-hook 'window-configuration-change-hook #'cooked--sync-size nil t)
  ;; `text-scale-increase' et al rescale the buffer's font without touching any
  ;; window's pixel dimensions, so neither `window-configuration-change-hook' nor
  ;; `window-size-change-functions' notices — `text-scale-mode-hook' is the one hook
  ;; that runs on every call, even repeated ones that leave the mode already on.
  (add-hook 'text-scale-mode-hook #'cooked--sync-size nil t)
  (add-hook 'window-selection-change-functions #'cooked--window-selection-changed nil t)
  (add-hook 'kill-buffer-hook #'cooked--cleanup nil t))

;; The state maps are installed with `use-local-map', which replaces the local map
;; outright. Reparenting them onto `cooked-mode-map' — itself a child of
;; `comint-mode-map' — keeps comint's bindings, and anything layered on them by
;; `evil-collection', reachable.
(set-keymap-parent cooked-input-map cooked-mode-map)
(set-keymap-parent cooked-semi-map cooked-mode-map)
(set-keymap-parent cooked-raw-map cooked-mode-map)
(set-keymap-parent cooked-command-map cooked-mode-map)
(set-keymap-parent cooked-alt-map cooked-mode-map)
(set-keymap-parent cooked-peek-map cooked-mode-map)

;; Cooked's own commands, on the shared parent rather than repeated in each of
;; the three state maps above: the binding should not evaporate depending on
;; what the child happens to be doing, or on whether the user has stepped out
;; to peek -- peeking installs this map directly, with none of the others'
;; forwarding, so this is the one place all of them are guaranteed to reach.
(define-key cooked-mode-map (kbd "C-c C-c") #'cooked-interrupt)
(define-key cooked-mode-map (kbd "C-c C-d") #'cooked-send-eof)
(define-key cooked-mode-map (kbd "C-c C-e") #'cooked-send-string)
(define-key cooked-mode-map (kbd "C-c M-x") #'cooked-meta-x)
(define-key cooked-mode-map (kbd "C-c C-z") #'cooked-suspend)
(define-key cooked-mode-map (kbd "C-c C-y") #'cooked-paste)
(define-key cooked-mode-map (kbd "C-c C-q") #'cooked-send-literal-key)
(define-key cooked-mode-map (kbd "C-c C-v") #'cooked-toggle-peek)
(define-key cooked-mode-map (kbd "C-c C-p") #'cooked-previous-command)
(define-key cooked-mode-map (kbd "C-c C-n") #'cooked-next-command)
(define-key cooked-mode-map (kbd "C-c TAB") #'cooked-toggle-fold)
(define-key cooked-mode-map (kbd "C-c C-l") #'cooked-refresh)

;; comint-shaped, cooked-implemented.  These keep comint's own positions, because
;; the concept behind each is one a terminal genuinely has -- it is only comint's
;; implementation, which reaches for a process that here is a wakeup pipe, that
;; cannot be used.  See `cooked--input-mark' for why the rest of comint's C-c map
;; needs nothing.
(define-key cooked-mode-map (kbd "C-c C-\\") #'cooked-quit)
(define-key cooked-mode-map (kbd "C-c M-o") #'cooked-clear-scrollback)
(define-key cooked-mode-map (kbd "C-c SPC") #'cooked-newline)

;; Whatever key a user has bound to comint's commands reaches ours, so
;; `evil-collection-comint' (which binds `repl-submit' to `comint-send-input')
;; works without knowing cooked exists.
(dolist (remap '((comint-send-input . cooked-send-input)
                 (comint-interrupt-subjob . cooked-interrupt)
                 (comint-quit-subjob . cooked-quit)
                 (comint-delete-output . cooked-delete-output)
                 (comint-stop-subjob . cooked-suspend)
                 (comint-delchar-or-maybe-eof . cooked-delete-char-or-eof)
                 (comint-kill-input . cooked-kill-input)
                 (comint-previous-input . cooked-previous-input)
                 (comint-next-input . cooked-next-input)
                 (comint-previous-prompt . cooked-previous-command)
                 (comint-next-prompt . cooked-next-command)))
  (define-key cooked-mode-map (vector 'remap (car remap)) (cdr remap)))

(defun cooked-kill-input ()
  "Delete the pending input."
  (interactive)
  (when-let* ((region (cooked--input-region)))
    (delete-region (car region) (cdr region))))

;; No evil state bindings here on purpose.
;;
;; RET reaches `cooked-send-input' through `cooked-input-map' in insert state, and in
;; normal state RET is `evil-ret', exactly as in any other buffer — the normal-state
;; special case was more surprising than useful.  `C-c C-c' needs nothing either: evil's
;; normal state does not bind `C-c', so it already falls through to the local map.

(defun cooked--cleanup ()
  "Tear down the session behind this buffer.

The child is killed here rather than left to the garbage collector:
clearing `cooked--session' only drops the last reference, and nothing
guarantees a collection ever runs, so the child would keep going long
after its buffer is gone.

Kill before closing the wake pipe.  The other order leaves the reader
thread writing into a closed pipe — harmless, since it blocks SIGPIPE —
but this order costs nothing."
  (cooked--cancel-secret)
  (when cooked--session (ignore-errors (cooked--kill cooked--session)))
  (when cooked--wake (delete-process cooked--wake))
  (cooked--remove-scratch)
  (setq cooked--session nil cooked--wake nil))

(defcustom cooked-shell-integration t
  "Whether to inject OSC 133 shell integration when starting a known shell.
Without it the shell prompt stays raw and only `cooked' programs get an Emacs
input region, since shells put the tty in raw mode for their own line editor."
  :type 'boolean :group 'cooked)

(defun cooked--integration-directory ()
  "Directory holding the shell integration snippets."
  (expand-file-name "shell-integration"
                    (file-name-directory (directory-file-name cooked--source-directory))))

(defvar-local cooked--scratch nil
  "Directory of generated shell startup files, deleted with the buffer.")

(defun cooked--scratch-directory ()
  "A fresh directory for this session's generated startup files."
  (make-temp-file "cooked-shell-" t))

(defun cooked--remove-scratch ()
  "Delete this buffer's generated startup files.

The prefix check is not decoration: this runs from `kill-buffer-hook', which
swallows errors, and a recursive delete of a path that got clobbered is not
something you get to undo."
  (when (and cooked--scratch
             (file-directory-p cooked--scratch)
             (string-prefix-p (file-name-as-directory (temporary-file-directory))
                              (file-name-as-directory cooked--scratch)))
    (ignore-errors (delete-directory cooked--scratch t)))
  (setq cooked--scratch nil))

(defun cooked--zsh-source-user (file)
  "Shell fragment sourcing the user's own FILE from their real ZDOTDIR."
  (concat "if [[ -n ${COOKED_USER_ZDOTDIR-} && -r $COOKED_USER_ZDOTDIR/" file " ]]; then\n"
          "  ZDOTDIR=$COOKED_USER_ZDOTDIR\n"
          "  source $COOKED_USER_ZDOTDIR/" file "\n"
          "  # The user's file is allowed to move ZDOTDIR; respect that downstream.\n"
          "  COOKED_USER_ZDOTDIR=$ZDOTDIR\n"
          "fi\n"))

(defun cooked--write-zsh-startup (scratch integration)
  "Generate zsh startup files in SCRATCH, sourcing INTEGRATION's snippet.

zsh reads every startup file from ZDOTDIR, so pointing it at a directory holding
only a .zshrc means the user's own ~/.zshenv is never read at all — a real and
silent loss, since .zshenv is where PATH and friends usually live.  Each stub
therefore hands the user's file the ZDOTDIR it expects and then takes it back."
  (let ((snippet (shell-quote-argument (expand-file-name "cooked.zsh" integration)))
        (here (shell-quote-argument scratch)))
    (dolist (file '(".zshenv" ".zprofile" ".zlogin"))
      (with-temp-file (expand-file-name file scratch)
        (insert "# Generated by cooked; deleted when the session's buffer is killed.\n"
                (cooked--zsh-source-user file)
                "ZDOTDIR=" here "\n")))
    (with-temp-file (expand-file-name ".zshrc" scratch)
      (insert "# Generated by cooked; deleted when the session's buffer is killed.\n"
              (cooked--zsh-source-user ".zshrc")
              "# After the user's config, so our hooks can order themselves against it.\n"
              "source " snippet "\n"
              "# Nested shells and `exec zsh' must not inherit the scratch directory,\n"
              "# which would also break them once it is deleted.\n"
              "if [[ -n ${COOKED_USER_ZDOTDIR_SET-} ]]; then\n"
              "  ZDOTDIR=$COOKED_USER_ZDOTDIR\n"
              "else\n"
              "  unset ZDOTDIR\n"
              "fi\n"
              "unset COOKED_USER_ZDOTDIR_SET\n"))))

(defun cooked--shell-invocation (shell)
  "Return (ARGV EXTRA-ENV SCRATCH) that starts SHELL with OSC 133 marks enabled.

Each shell gets the least invasive hook it offers: generated startup files that
source the user's own, so nobody's configuration is bypassed or edited.  SCRATCH
is the directory holding them, for `cooked--remove-scratch' to delete later, or
nil when none were generated."
  (let ((dir (cooked--integration-directory))
        (name (file-name-nondirectory shell)))
    (if (not cooked-shell-integration)
        (list (list shell) nil nil)
      (pcase name
        ("bash"
         (let* ((scratch (cooked--scratch-directory))
                (rc (expand-file-name "bashrc" scratch)))
           (with-temp-file rc
             (insert "[ -f ~/.bashrc ] && . ~/.bashrc\n"
                     ". " (shell-quote-argument (expand-file-name "cooked.bash" dir)) "\n"))
           (list (list shell "--rcfile" rc "-i") nil scratch)))
        ("zsh"
         (let ((scratch (cooked--scratch-directory))
               (user (or (getenv "ZDOTDIR") (expand-file-name "~"))))
           (cooked--write-zsh-startup scratch dir)
           (list (list shell "-i")
                 `(("ZDOTDIR" . ,scratch)
                   ("COOKED_USER_ZDOTDIR" . ,user)
                   ;; Distinguishes "put it back" from "there was none", so we do not
                   ;; leave every cooked child exporting ZDOTDIR=$HOME for life.
                   ,@(when (getenv "ZDOTDIR") '(("COOKED_USER_ZDOTDIR_SET" . "1"))))
                 scratch)))
        ("fish"
         (list (list shell "-C" (format "source %s"
                                        (shell-quote-argument (expand-file-name "cooked.fish" dir))))
               nil nil))
        (_ (list (list shell) nil nil))))))

(defun cooked--live-buffers ()
  "Session buffers with a running child, most recent first."
  (let (found)
    (cooked--dolist-buffers
      (when cooked--session (push (current-buffer) found)))
    (nreverse found)))

;;;###autoload
(defun cooked (&optional new command)
  "Switch to a terminal session, starting one if needed.

With a prefix argument, or NEW non-nil, always start another session rather than
reusing a live one.  COMMAND overrides `cooked-shell'."
  (interactive "P")
  (cooked--display (or (unless new (car (cooked--live-buffers)))
                       (cooked--start-session command))
                   nil))

;;;###autoload
(defun cooked-other-window (&optional new command)
  "Like `cooked', but display the session in another window."
  (interactive "P")
  (cooked--display (or (unless new (car (cooked--live-buffers)))
                       (cooked--start-session command))
                   '(display-buffer-pop-up-window)))

(defun cooked--display (buffer action)
  "Show BUFFER using ACTION and match the child to the window it landed in.

A session is started before it has a window, so it begins at a default size; the
size is only knowable once something is displaying it."
  (pop-to-buffer buffer action)
  (with-current-buffer buffer
    (cooked--sync-size))
  buffer)

(defun cooked--start-session (&optional command)
  "Create a buffer running COMMAND, or `cooked-shell', and return it."
  (let ((buffer (generate-new-buffer (cooked--buffer-name))))
    (with-current-buffer buffer
      (cooked-mode)
      (pcase-let ((`(,argv ,env ,scratch) (cooked--shell-invocation (or command cooked-shell))))
        (setq cooked--scratch scratch)
        (cooked--start argv default-directory env))
      (setq cooked--last-size (cons cooked--rows cooked--cols))
      (cooked--refresh-keymap))
    buffer))

(provide 'cooked-mode)
;;; cooked-mode.el ends here
