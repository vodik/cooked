;;; cooked-mode.el --- Interaction for cooked terminals -*- lexical-binding: t; -*-

;;; Commentary:

;; The interactive half of cooked: keymaps, key encoding, input submission,
;; history, completion, secrets, and starting a shell.  See cooked.el, the main
;; file, for what this is and how to install it.

;; Two signals decide who owns the keyboard.  The kernel's line discipline
;; (`cooked--mode') identifies programs doing canonical reads, and OSC 133 marks
;; identify the shell's own prompt, which is always raw and so invisible to the
;; first signal.  Either one puts us in `input' state, where keys are ordinary
;; Emacs editing against a pending-input region; otherwise keys go straight to
;; the child.

;;; Code:

(require 'cooked)
(require 'comint)

;; Defined by the native core at `module-load' time, so the byte-compiler cannot
;; see them; cooked.el declares the same set for its own use.
(declare-function cooked--send "cooked-core")
(declare-function cooked--resize "cooked-core")
(declare-function cooked--signal "cooked-core")
(declare-function cooked--prompt-text "cooked-core")
(declare-function cooked--bracketed-paste-p "cooked-core")
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

(defvar-local cooked--input-start nil "Marker before the pending input.")
(defvar-local cooked--input-end nil "Marker after the pending input.")
(defvar-local cooked--semantic nil "OSC 133 state: nil, `prompt', `input' or `output'.")
(defvar-local cooked--secret-timer nil)
(defvar-local cooked--command-start nil "Marker where the running command's output began.")
(defvar-local cooked--commands nil
  "Finished command records, newest first: (:start MARKER :end MARKER :code N).")
(defvar-local cooked--history nil "Submitted input lines, newest first.")
(defvar-local cooked--history-index nil "Position in `cooked--history', or nil.")
(defvar-local cooked--history-stash nil "Input set aside while browsing history.")
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
  (let* ((mods (event-modifiers event))
         (basic (event-basic-type event))
         (param (cooked--modifier-param mods)))
    (cond
     ((assq basic cooked--csi-finals)
      (let ((final (cdr (assq basic cooked--csi-finals))))
        (cond ((> param 1) (format "\e[1;%d%s" param final))
              (cooked--app-cursor (concat "\eO" final))
              (t (concat "\e[" final)))))
     ;; F1-F4 leave SS3 behind the moment they are modified.
     ((assq basic cooked--ss3-finals)
      (let ((final (cdr (assq basic cooked--ss3-finals))))
        (if (> param 1) (format "\e[1;%d%s" param final) (concat "\eO" final))))
     ((assq basic cooked--tilde-numbers)
      (let ((n (cdr (assq basic cooked--tilde-numbers))))
        (if (> param 1) (format "\e[%d;%d~" n param) (format "\e[%d~" n))))
     ((assq basic cooked--literal-codes)
      (cooked--encode-literal basic (cdr (assq basic cooked--literal-codes)) param mods))
     ((assq basic cooked--special-keys)
      (let ((seq (cdr (assq basic cooked--special-keys))))
        (if (memq 'meta mods) (concat "\e" seq) seq)))
     ((characterp basic)
      (let ((char (cond ((memq 'control mods) (logand (upcase basic) #x1f))
                        ((memq 'shift mods) (upcase basic))
                        (t basic))))
        (if (memq 'meta mods) (concat "\e" (string char)) (string char)))))))

(defun cooked-send-key ()
  "Send the key that invoked this command straight to the child."
  (interactive)
  (when-let* ((bytes (cooked--encode-event last-command-event)))
    (cooked--send cooked--session bytes)))

(defun cooked-send-string (string)
  "Send STRING to the child."
  (interactive "sSend: ")
  (cooked--send cooked--session string))

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
    (wheel-up . 64) (wheel-down . 65) (mouse-4 . 64) (mouse-5 . 65))
  "Terminal button numbers for Emacs mouse events.")

(defun cooked--mouse-cell (event)
  "Screen row and column of EVENT, or nil if it is outside the screen."
  (when-let* ((posn (event-start event))
              (pos (posn-point posn)))
    (when (and cooked--screen-start (>= pos (marker-position cooked--screen-start)))
      (save-excursion
        (goto-char pos)
        (cons (count-lines (marker-position cooked--screen-start) (line-beginning-position))
              (current-column))))))

(defun cooked--mouse-report (button row col pressed)
  "Encode a mouse report, preferring SGR because X10 cannot count past 223."
  (if cooked--mouse-sgr
      (format "\e[<%d;%d;%d%s" button (1+ col) (1+ row) (if pressed "M" "m"))
    (format "\e[M%c%c%c" (+ 32 (if pressed button 3)) (+ 33 col) (+ 33 row))))

(defun cooked-mouse-event ()
  "Forward the mouse to the child, or fall back to Emacs' own behaviour."
  (interactive)
  (let* ((event last-input-event)
         (button (cdr (assq (event-basic-type event) cooked--mouse-buttons)))
         (cell (and cooked--mouse button (cooked--mouse-cell event))))
    (if (null cell)
        (cooked--mouse-fallback event)
      (let ((pressed (not (memq 'click (event-modifiers event)))))
        (cooked--send cooked--session
                      (cooked--mouse-report button (car cell) (cdr cell) pressed))))))

(defun cooked--mouse-fallback (event)
  "Run whatever EVENT would do without eterm's binding."
  (let ((command (lookup-key global-map (this-command-keys-vector))))
    (when (commandp command)
      (setq last-command-event event
            this-command command)
      (call-interactively command))))

(defvar cooked-raw-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap self-insert-command] #'cooked-send-key)
    (dolist (code (number-sequence 0 127))
      (unless (eq code cooked--escape-key)
        (define-key map (vector code) #'cooked-send-key)))
    ;; Bind the modified variants explicitly, not for completeness but for
    ;; correctness: when `S-return' has no binding Emacs shift-translates it to
    ;; `return' and runs *that* binding, with `last-command-event' already flattened.
    ;; By the time `cooked-send-key' looks, the shift is gone and unrecoverable.
    (dolist (entry cooked--special-keys)
      (dolist (prefix '("" "S-" "C-" "M-" "C-S-" "M-S-" "C-M-"))
        (define-key map (vector (intern (concat prefix (symbol-name (car entry)))))
                    #'cooked-send-key)))
    (define-key map (kbd "C-c C-c") #'cooked-interrupt)
    (define-key map (kbd "C-c C-d") #'cooked-send-eof)
    (define-key map (kbd "C-c C-e") #'cooked-send-string)
    (define-key map (kbd "C-c M-x") #'cooked-meta-x)
    (define-key map (kbd "C-c C-z") #'cooked-suspend)
    ;; Navigating and folding the transcript sends nothing to the child, so it
    ;; belongs here too: you want it most while a command is still running.
    (define-key map (kbd "C-c C-p") #'cooked-previous-command)
    (define-key map (kbd "C-c C-n") #'cooked-next-command)
    (define-key map (kbd "C-c TAB") #'cooked-toggle-fold)
    (dolist (event '(down-mouse-1 mouse-1 down-mouse-2 mouse-2 down-mouse-3 mouse-3
                     wheel-up wheel-down mouse-4 mouse-5))
      (define-key map (vector event) #'cooked-mouse-event))
    map)
  "Keymap while the child owns the keyboard.")

(defvar cooked-input-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'cooked-send-input)
    (define-key map (kbd "<S-return>") #'cooked-newline)
    (define-key map (kbd "C-c C-c") #'cooked-interrupt)
    ;; Redundant here — plain M-x already reaches Emacs in the input state — but the
    ;; binding should not evaporate depending on what the child happens to be doing.
    (define-key map (kbd "C-c M-x") #'cooked-meta-x)
    (define-key map (kbd "C-c C-d") #'cooked-send-eof)
    (define-key map (kbd "C-c C-z") #'cooked-suspend)
    (define-key map (kbd "C-d") #'cooked-delete-char-or-eof)
    (define-key map (kbd "C-c C-p") #'cooked-previous-command)
    (define-key map (kbd "C-c C-n") #'cooked-next-command)
    (define-key map (kbd "C-c TAB") #'cooked-toggle-fold)
    (define-key map (kbd "TAB") #'completion-at-point)
    (define-key map (kbd "M-p") #'cooked-previous-input)
    (define-key map (kbd "M-n") #'cooked-next-input)
    map)
  "Keymap while Emacs owns the input line.")

;;;; Pending input

(defun cooked--input-state-p ()
  "Whether Emacs should be editing rather than passing keys through."
  (or (eq cooked--mode 'cooked) (eq cooked--semantic 'input)))

(defun cooked--pending-input ()
  "The text the user has typed but not yet submitted."
  (when (and cooked--input-start cooked--input-end
             (marker-position cooked--input-start)
             (marker-position cooked--input-end))
    (buffer-substring-no-properties cooked--input-start cooked--input-end)))

(defvar cooked-snap-commands
  '(self-insert-command cooked-newline newline newline-and-indent
    yank yank-pop
    evil-paste-before evil-paste-after evil-paste-from-register)
  "Commands that should act on the input region even if point drifted out of it.
See `cooked--snap-to-input'.

Plain `newline' is here because `evil-collection' binds S-RET to it directly
rather than to `cooked-newline', so it needs the same protection.")

(defun cooked--snap-to-input ()
  "Move point into the pending-input region before an insertion command.

Point leaves the input line far more easily than it looks.  The screen is
rendered with a newline after the last row, so there is a blank line below the
prompt to sit on; and evil's normal state pulls the cursor back off the end of a
line, which at an empty prompt lands it on the last character of the prompt
itself.  Both are one keystroke away from the prompt at all times.

Typing from either place goes wrong quietly.  Before the region the prompt is
read-only, so the insert signals \"Text is read-only\"; after it the text lands
outside the markers `cooked-send-input' reads, so it sits in the buffer looking
submitted while the child is sent an empty line."
  (when (and (memq this-command cooked-snap-commands)
             (cooked--input-state-p)
             cooked--input-start
             (marker-position cooked--input-start))
    (let ((start (marker-position cooked--input-start))
          (end (and cooked--input-end (marker-position cooked--input-end))))
      (cond ((< (point) start) (goto-char start))
            ((and end (> (point) end)) (goto-char end))))))

(defun cooked--take-pending-input ()
  "Remove the pending input from the buffer and return it."
  (when-let* ((text (cooked--pending-input)))
    (delete-region cooked--input-start cooked--input-end)
    text))

(defun cooked--restore-pending-input (text)
  "Re-insert TEXT at the cursor, re-establishing the input markers."
  (when (cooked--input-state-p)
    (save-excursion
      (goto-char (cooked--cursor-position))
      (setq cooked--input-start (copy-marker (point) nil))
      (when text (insert text))
      (setq cooked--input-end (copy-marker (point) t)))))

(defun cooked--point-after-input ()
  "Where point belongs after a redisplay."
  (or (and cooked--input-end (marker-position cooked--input-end))
      (cooked--cursor-position)))

(defun cooked-send-input ()
  "Submit the pending input to the child.
The kernel echoes it back, so the emulator renders the line, not us.

Enter is sent as CR, which is what a terminal actually transmits: in canonical
mode `ICRNL' turns it into the newline the child expects, and in raw mode it is
what a shell's line editor is bound to.  Sending LF works for readline but not
for ZLE."
  (interactive)
  (let ((text (or (cooked--take-pending-input) "")))
    (setq cooked--input-start nil cooked--input-end nil)
    (unless (string-blank-p text)
      (setq cooked--history (cons text (delete text cooked--history))))
    (setq cooked--history-index nil cooked--history-stash nil)
    (cooked--send cooked--session
                  ;; A multi-line submission has to arrive as a paste, or the shell's
                  ;; line editor treats every embedded newline as its own Enter and runs
                  ;; the fragments one at a time.
                  (if (and (string-search "\n" text)
                           (cooked--bracketed-paste-p cooked--session))
                      (concat "\e[200~" text "\e[201~\r")
                    (concat text "\r")))))

(defun cooked-newline ()
  "Insert a newline in the pending input without submitting it.

Shift+RET, so a multi-line command can be composed as one edit.  The pending
input is lifted out and put back verbatim on every redisplay, so an embedded
newline survives until you submit."
  (interactive)
  (unless (cooked--input-state-p)
    (user-error "Not at an input prompt"))
  (unless cooked--input-start
    (cooked--restore-pending-input nil))
  (insert "\n"))

;;;; History
;;
;; comint's ring is unusable here: it navigates relative to a process mark we do
;; not maintain, which is what makes `comint-previous-input' report "Not at
;; command line".  Forwarding the arrow keys to the shell instead would desync,
;; because the line being edited lives in Emacs and the shell's line editor has
;; never seen it.  So we keep our own ring; the shell still records the same
;; commands, since it receives each one whole.

(defun cooked--replace-input (text)
  "Replace the pending input with TEXT."
  (when (and cooked--input-start cooked--input-end)
    (let ((inhibit-read-only t))
      (delete-region cooked--input-start cooked--input-end)
      (save-excursion
        (goto-char cooked--input-start)
        (insert text)))
    (goto-char cooked--input-end)))

(defun cooked--history-move (delta)
  "Step DELTA entries through the input history."
  (unless (cooked--input-state-p)
    (user-error "Not at an input prompt"))
  (unless cooked--history
    (user-error "No input history yet"))
  (unless cooked--input-start
    (cooked--restore-pending-input nil))
  (when (null cooked--history-index)
    (setq cooked--history-stash (or (cooked--pending-input) "")))
  (let ((next (max -1 (min (+ (or cooked--history-index -1) delta)
                           (1- (length cooked--history))))))
    (setq cooked--history-index (and (>= next 0) next))
    (cooked--replace-input (if cooked--history-index
                               (nth cooked--history-index cooked--history)
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
      (cooked--send cooked--session "\C-d")
    (delete-char 1)))

(defun cooked-send-eof ()
  "Send EOF to the child.

Unlike \\[cooked-interrupt] this is a byte, not a signal: in canonical mode the
line discipline turns it into end-of-input, and a raw-mode program reads it as
^D.  Bound explicitly because at a prompt plain \\[cooked-delete-char-or-eof]
deletes forward unless the line is already empty."
  (interactive)
  (cooked--send cooked--session "\C-d"))

(defun cooked-suspend ()
  "Suspend the foreground command."
  (interactive)
  (cooked--signal cooked--session 20))

(defun cooked-interrupt ()
  "Interrupt the foreground command."
  (interactive)
  (setq cooked--input-start nil cooked--input-end nil)
  (cooked--signal cooked--session 2))

;;;; Completion
;;
;; The shell cannot complete for us: the line being edited lives in Emacs and the
;; shell's line editor has never seen it, so forwarding TAB would complete against
;; an empty buffer.  Completing in Emacs is the honest option and the better one —
;; it is an ordinary `completion-at-point-functions' entry, so corfu, cape,
;; consult and friends work here exactly as they do anywhere else.

(defvar cooked--executables nil "Cached PATH lookup, see `cooked--executable-table'.")

(defun cooked--executable-table ()
  "Names of programs on PATH, cached for the session."
  (or cooked--executables
      (setq cooked--executables
            (delete-dups
             (mapcan (lambda (dir)
                       (when (file-accessible-directory-p dir)
                         (ignore-errors (directory-files dir nil "\\`[^.]" t))))
                     exec-path)))))

(defun cooked-flush-executables ()
  "Forget the cached list of programs on PATH."
  (interactive)
  (setq cooked--executables nil))

(defun cooked--completion-bounds ()
  "Bounds of the word before point, clamped to the pending input."
  (let ((limit (marker-position cooked--input-start)))
    (save-excursion
      (let ((end (point)))
        (skip-chars-backward "^ \t" limit)
        (cons (point) end)))))

(defun cooked-completion-at-point ()
  "Complete the pending input: a program name first, file names after it."
  (when (and (cooked--input-state-p)
             cooked--input-start
             (marker-position cooked--input-start)
             (>= (point) (marker-position cooked--input-start)))
    (pcase-let ((`(,start . ,end) (cooked--completion-bounds)))
      (list start end
            (if (= start (marker-position cooked--input-start))
                (completion-table-in-turn (cooked--executable-table)
                                          #'completion-file-name-table)
              #'completion-file-name-table)
            :exclusive 'no
            :annotation-function
            (lambda (_) (when (= start (marker-position cooked--input-start)) " program"))))))

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

(defun cooked--refresh-keymap ()
  "Install the keymap matching the current ownership of the keyboard."
  (use-local-map (if (cooked--input-state-p) cooked-input-map cooked-raw-map))
  (unless (cooked--input-state-p)
    (setq cooked--input-start nil cooked--input-end nil))
  (run-hooks 'cooked-state-change-hook))

(defun cooked--semantic (event)
  "Track OSC 133 EVENT and the buffer markers that come with it."
  (pcase event
    (`(prompt-start) (setq cooked--semantic 'prompt))
    (`(prompt-end)
     (setq cooked--semantic 'input)
     (cooked--refresh-keymap))
    (`(command-start)
     (setq cooked--semantic 'output
           cooked--command-start (copy-marker (cooked--cursor-position)))
     (cooked--refresh-keymap))
    (`(command-end . ,code)
     (setq cooked--semantic nil)
     (cooked--mark-command-end code))))

(defun cooked--mark-command-end (code)
  "Record exit CODE for the command that just finished.

Kept as a record rather than only a text property: a command that printed
nothing spans an empty region, which no text property can describe, and the
records are what folding and navigation walk."
  (when (and cooked--command-start (marker-position cooked--command-start))
    (let ((beg (marker-position cooked--command-start))
          (end (min (point-max) (cooked--cursor-position)))
          (code (or code 0)))
      (when (< beg end)
        (put-text-property beg end 'cooked-exit-code code))
      (push (list :start (copy-marker beg) :end (copy-marker end) :code code)
            cooked--commands)))
  (setq cooked--command-start nil))

(defun cooked-last-exit-code ()
  "Exit status of the most recently finished command, if any."
  (plist-get (car cooked--commands) :code))

(defun cooked--command-at (point)
  "The command record whose output contains POINT."
  (seq-find (lambda (record)
              (<= (marker-position (plist-get record :start))
                  point
                  (marker-position (plist-get record :end))))
            cooked--commands))

(defun cooked-previous-command (&optional n)
  "Move to the start of the Nth previous command's output."
  (interactive "p")
  (let ((starts (sort (mapcar (lambda (r) (marker-position (plist-get r :start)))
                              cooked--commands)
                      #'<)))
    (goto-char (or (car (last (seq-filter (lambda (p) (< p (point))) starts) (or n 1)))
                   (point-min)))))

(defun cooked-next-command (&optional n)
  "Move to the start of the Nth next command's output."
  (interactive "p")
  (let ((starts (sort (mapcar (lambda (r) (marker-position (plist-get r :start)))
                              cooked--commands)
                      #'<)))
    (goto-char (or (nth (1- (or n 1)) (seq-filter (lambda (p) (> p (point))) starts))
                   (point-max)))))

(defun cooked-toggle-fold ()
  "Hide or reveal the output of the command at point."
  (interactive)
  (let* ((record (or (cooked--command-at (point)) (car cooked--commands))
                 )
         (beg (and record (marker-position (plist-get record :start))))
         (end (and record (marker-position (plist-get record :end)))))
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
                    (progn (cooked--send cooked--session secret)
                           (cooked--send cooked--session "\n"))
                  (clear-string secret)))
            ;; C-g at the prompt should interrupt the child's read rather than leave
            ;; it blocked on a `getpass' nobody is going to answer.
            (quit
             (cooked--send cooked--session "\C-c")
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
(defun cooked--install-global-hooks ()
  "Install the hooks that cannot be buffer-local."
  (add-hook 'window-size-change-functions #'cooked--frame-size-changed))

(defun cooked--on-exit (code)
  "Report that the child exited with CODE and stop the session."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-max))
      (insert (format "\n[exited %s]\n" code))))
  (when cooked--session (ignore-errors (cooked--kill cooked--session)))
  (when cooked--wake (delete-process cooked--wake))
  (setq cooked--session nil cooked--wake nil))

(defface cooked-failure '((t :inherit error))
  "Face for a non-zero exit status in the mode line."
  :group 'cooked)

(defface cooked-success '((t :inherit success))
  "Face for a zero exit status in the mode line."
  :group 'cooked)

(defun cooked--mode-line ()
  "Compact indicator: what is running, who owns the keyboard, how it went."
  (let ((code (cooked-last-exit-code)))
    (concat
     (pcase cooked--mode
       ('cooked " edit")
       ('secret " secret")
       (_ (if (eq cooked--semantic 'input) " edit" " raw")))
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
              comint-input-ring-size 500
              truncate-lines (not cooked-rejoin-wrapped-lines)
              mode-line-process '(:eval (cooked--mode-line)))
  (cooked--install-global-hooks)
  (add-hook 'pre-command-hook #'cooked--snap-to-input nil t)
  (add-hook 'completion-at-point-functions #'cooked-completion-at-point nil t)
  (add-hook 'window-configuration-change-hook #'cooked--sync-size nil t)
  (add-hook 'kill-buffer-hook #'cooked--cleanup nil t))

;; The state maps are installed with `use-local-map', which replaces the local map
;; outright. Reparenting them onto `cooked-mode-map' — itself a child of
;; `comint-mode-map' — keeps comint's bindings, and anything layered on them by
;; `evil-collection', reachable.
(set-keymap-parent cooked-input-map cooked-mode-map)
(set-keymap-parent cooked-raw-map cooked-mode-map)

;; Whatever key a user has bound to comint's commands reaches ours, so
;; `evil-collection-comint' (which binds `repl-submit' to `comint-send-input')
;; works without knowing cooked exists.
(dolist (remap '((comint-send-input . cooked-send-input)
                 (comint-interrupt-subjob . cooked-interrupt)
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
  (when (cooked--pending-input)
    (delete-region cooked--input-start cooked--input-end)))

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
  (seq-filter (lambda (buffer)
                (with-current-buffer buffer
                  (and (derived-mode-p 'cooked-mode) cooked--session)))
              (buffer-list)))

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
