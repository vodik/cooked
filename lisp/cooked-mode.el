;;; cooked-mode.el --- Interaction for cooked terminals -*- lexical-binding: t; -*-

;;; Commentary:

;; The interactive half of cooked: keymaps, key encoding, input submission,
;; history, and the mode itself.  Four things that used to live here have their
;; own files, each named for what it is -- cooked-completion.el,
;; cooked-secret.el, cooked-shell-integration.el and cooked-mode-line.el -- and
;; the command records everything here navigates by are cooked-command.el.  See
;; cooked.el, the main file, for what this is and how to install it.

;; Two signals decide who owns the keyboard.  The kernel's line discipline
;; (`cooked--mode') identifies programs doing canonical reads, and OSC 133 marks
;; identify the shell's own prompt, which is always raw and so invisible to the
;; first signal.  Either one puts us in `input' state, where keys are ordinary
;; Emacs editing against a pending-input region; otherwise keys go straight to
;; the child.

;;; Code:

(require 'cl-lib)
(require 'cooked)
(require 'cooked-osc)
(require 'cooked-completion)
(require 'cooked-mouse)
(require 'cooked-shell-integration)
(require 'cooked-mode-line)
(require 'cooked-secret)
(require 'comint)

;; Defined by the native core at `module-load' time, so the byte-compiler cannot
;; see them; cooked.el declares the same set for its own use.
(declare-function cooked--send "cooked-core")
(declare-function cooked--sample-mode "cooked-core")
(declare-function cooked--set-attended "cooked-core")
(declare-function cooked--resize "cooked-core")
(declare-function cooked--cell-size "cooked")
(declare-function cooked--signal "cooked-core")
(declare-function cooked--prompt-text "cooked-core")
(declare-function cooked--bracketed-paste-p "cooked-core")
(declare-function cooked--focus-events-p "cooked-core")
(declare-function cooked--live-p "cooked-core")
(declare-function cooked--foreground-pid "cooked-core")
(declare-function cooked--pid "cooked-core")
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

(defun cooked--format-buffer-name (subject)
  "Apply `cooked-buffer-name\=' to SUBJECT, whichever kind of setting it is.

SUBJECT is the directory for a new session and the child\='s title for a rename,
which is the whole of the difference between this option\='s two readers: the
option itself does not care which it is given, and neither does a user who set
it to a function."
  (if (functionp cooked-buffer-name)
      (funcall cooked-buffer-name subject)
    (format cooked-buffer-name subject)))

(defun cooked--buffer-name (&optional directory)
  "A fresh, unique buffer name for a session in DIRECTORY."
  (generate-new-buffer-name
   (cooked--format-buffer-name
    (abbreviate-file-name (or directory default-directory)))))

(defun cooked--rename-to-title ()
  "Rename the buffer after the child's title, when asked to."
  (when (and cooked-buffer-name-follows-title
             cooked--title
             (not (string-empty-p cooked--title)))
    (let ((name (cooked--format-buffer-name cooked--title)))
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

(defun cooked-toggle-rejoin-wrapped-lines ()
  "Flip `cooked-rejoin-wrapped-lines\=', here and for buffers made after this.

A command rather than a menu item that sets the variable, because the variable
is only half of what has to move: `cooked-mode\=' derives `truncate-lines\=' from
it, and every drain since is asked with the value in force, so a bare `setq\='
would change what happens to output arriving from now on and leave this
buffer's own wrapping set the way it was.  The two would then disagree, quietly,
which is exactly what a switch on a menu must not do.

Only this buffer's `truncate-lines\=' is touched.  Another live session keeps the
answer it was started with until its next `cooked-mode\=', and saying so is
better than walking every cooked buffer to impose a setting the user changed
from inside one of them."
  (interactive)
  (setq cooked-rejoin-wrapped-lines (not cooked-rejoin-wrapped-lines))
  (setq-local truncate-lines (not cooked-rejoin-wrapped-lines))
  (message "cooked: wrapped lines %s"
           (if cooked-rejoin-wrapped-lines "rejoin" "stay split")))

(defcustom cooked-shell (or (bound-and-true-p explicit-shell-file-name) shell-file-name)
  "Program run by \\[cooked]."
  :type 'string :group 'cooked)

(defvar-local cooked--history-stash nil
  "Input set aside while browsing history.
The one piece of history state that is cooked's: the ring, and the position in
it, are `comint-input-ring' and `comint-input-ring-index'.")
(defvar-local cooked--last-size nil
  "The (ROWS . COLS) last reported to the emulator, or nil.")

;;;; Key encoding

(defconst cooked--special-keys
  '((up . "\e[A") (down . "\e[B") (right . "\e[C") (left . "\e[D")
    (home . "\e[H") (end . "\e[F") (prior . "\e[5~") (next . "\e[6~")
    (insert . "\e[2~") (deletechar . "\e[3~") (backspace . "\C-?")
    (tab . "\t") (return . "\r") (escape . "\e")
    ;; Shift+TAB is reported by Emacs as `backtab', not as `S-tab' -- see
    ;; `cooked--encode-event', which restores the shift `event-modifiers' leaves
    ;; out so this falls out of the ordinary modifier logic after all.  This entry
    ;; is the classical, un-negotiated spelling; terminfo calls it `kcbt'.
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
  '((return . 13) (tab . 9) (escape . 27) (backspace . 127) (backtab . 9))
  "Keys with a code point for the negotiated encodings, and their fallback.

There is no classical encoding for Shift+Return or Control+Tab: xterm and
kitty each invented one, and both are negotiated, because a terminal that
volunteers \\='ESC [ 27;2;13 ~\\=' to a program that never asked for it has not
sent Shift+Return, it has sent six characters of rubbish.  So a modifier here
is spelled out only when `cooked--keys' says the child opted in; the fallback
`cooked--encode-literal' reaches for otherwise is `cooked--special-keys', which
for most of these is a single byte -- except `backtab', whose fallback is the
three-byte `kcbt' sequence, because unlike the others it already has a
classical spelling that just doesn't fit the single-byte-plus-negotiation
shape everything else here follows.")

(defun cooked--modifier-param (mods)
  "Return xterm's modifier parameter for MODS: 1 plus a bit per held modifier."
  (+ 1
     (if (memq 'shift mods) 1 0)
     (if (memq 'meta mods) 2 0)
     (if (memq 'control mods) 4 0)))

(defun cooked--encode-literal (basic code param mods)
  "Encode key BASIC with modifiers, given its code point CODE.

CODE is the kitty/modifyOtherKeys code point for BASIC.

PARAM is the xterm modifier parameter and MODS the modifier list.  Falls back to
`cooked--special-keys' when the child has negotiated nothing, since that is
what every terminal has always sent and what every program still understands
-- a bare byte for most keys here, but `backtab' falls back to its own
classical, three-byte spelling instead."
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
  ;; Each table is consulted once, through `when-let*', rather than being asked
  ;; whether it has the key and then asked again for the value.  The tables are
  ;; tried in order of how specific their spelling is, ending at a plain
  ;; character; a key in none of them falls off the end and encodes as nil, which
  ;; is not forwarded.
  ;;
  ;; `cl-block' rather than a `cond' whose clauses are the lookups themselves.
  ;; Written that way the `cond' returns its own test, so a table that *hit* but
  ;; whose body produced nil would fall through to the next table and encode as
  ;; something else entirely -- a key spelled as a different key, silently.
  ;; Nothing reachable does that today, every branch below yielding a non-empty
  ;; string, but that is a property of the five tables' contents rather than of
  ;; anything stating it.  Returning on a hit makes "the first table holding this
  ;; key is the one that answers for it" true by construction, which is the rule
  ;; the ordering above is only meaningful under.
  (let* ((mods (event-modifiers event))
         (basic (event-basic-type event))
         ;; `backtab' is the mirror image of the capital-letter case above: Emacs
         ;; bakes its shift into the base symbol and reports none in `mods' at
         ;; all, for `backtab' alone or with other modifiers held alongside it
         ;; (`C-backtab' still reports only `(control)').  Restore it before
         ;; `param' is computed, or `cooked--literal-codes' has a code point for
         ;; `backtab' that no modifier ever reaches.
         (mods (if (eq basic 'backtab) (cons 'shift mods) mods))
         (param (cooked--modifier-param mods))
         (modified (> param 1)))
    (cl-block nil
      (when-let* ((final (alist-get basic cooked--csi-finals)))
        (cl-return (cond (modified (format "\e[1;%d%s" param final))
                         (cooked--app-cursor (concat "\eO" final))
                         (t (concat "\e[" final)))))
      ;; F1-F4 leave SS3 behind the moment they are modified.
      (when-let* ((final (alist-get basic cooked--ss3-finals)))
        (cl-return (if modified (format "\e[1;%d%s" param final) (concat "\eO" final))))
      (when-let* ((n (alist-get basic cooked--tilde-numbers)))
        (cl-return (if modified (format "\e[%d;%d~" n param) (format "\e[%d~" n))))
      (when-let* ((code (alist-get basic cooked--literal-codes)))
        (cl-return (cooked--encode-literal basic code param mods)))
      (when-let* ((seq (alist-get basic cooked--special-keys)))
        (cl-return (if (memq 'meta mods) (concat "\e" seq) seq)))
      (when (characterp basic)
        (let ((char (cond ((memq 'control mods) (logand (upcase basic) #x1f))
                          ((memq 'shift mods) (upcase basic))
                          (t basic))))
          (cl-return (if (memq 'meta mods) (concat "\e" (string char)) (string char)))))
      nil)))

(defun cooked--track-wandering ()
  "Notice a command moving point off the child's cursor, or back onto it.

Runs from `post-command-hook' because Emacs' own motions produce no output:
nothing is drained, so a redraw cannot be what discovers that point has moved."
  (cooked--protect-hook
    (setq cooked--wandered
          (and
           ;; Not "the child owns the keyboard", which is the same test wherever
           ;; there is no pending input -- and the wrong one at a prompt, where a
           ;; `still' render still has to pin a point the user parked out in the
           ;; screen against `cooked--render-rows' deleting the row under it.
           ;; Point inside the input has not wandered off anything: it is in the
           ;; text Emacs is holding for the child, which is rebuilt around the
           ;; child's cursor on every drain and so has no cell to be pinned to.
           ;;
           ;; With no region at all, though, there is nothing for point to be
           ;; inside of, and the question falls back to who owns the keyboard.
           ;; A prompt without a region is a line in flight -- before the first
           ;; drain has built one, or in the gap `cooked-send-input' opens by
           ;; unmarking the text it submitted -- and the row under point is about
           ;; to be redrawn by the echo, so there is no view being held for the
           ;; user to protect.  Pinning there strands point on the old cell: the
           ;; `wandered' arm of `cooked--apply' outranks `follow'.
           (if-let* ((region (cooked--input-region)))
               (not (<= (car region) (point) (cdr region)))
             (cooked--child-owns-keyboard-p))
           ;; Scrollback is the reading case, already handled by `follow'.
           (cooked--screen-cell)
           (not (cooked--at-child-cursor-p))))
    ;; Not only on a drain: `evil' refreshes its cursor from
    ;; `window-configuration-change-hook' and on every state change, neither of
    ;; which produces output, so there would be no drain to put it back.
    ;; The other half of `cooked--point': a command moving point is the second way
    ;; it moves, and a buffer the user leaves without a drain in between must
    ;; remember where they left it rather than where the last drain did.
    (setq cooked--point (point))
    (cooked--sync-cursor-type)
    (cooked--update-ghost-cursor)))

(defun cooked--snap-to-cursor ()
  "Return point to the child's cursor before handing it a key.

Typing is the moment the keyboard goes back, so it is the moment to stop
pretending point is anywhere else — the child will act at its own cursor
whatever Emacs is showing, and the ghost has been marking that spot."
  (when (and cooked--wandered (cooked--child-owns-keyboard-p))
    (goto-char (cooked--cursor-position))
    (setq cooked--wandered nil)
    (cooked--update-ghost-cursor)))

(defun cooked-send-key ()
  "Send the key that invoked this command straight to the child.

Bound under whatever `cooked--keys' says was actually negotiated, unless
`cooked-key-protocol-overrides' has a program-wide guess to stand in for a
negotiation that never happened -- see `cooked--assumed-key-protocol'."
  (interactive)
  (let ((cooked--keys (or (cooked--assumed-key-protocol) cooked--keys)))
    (when-let* ((bytes (cooked--encode-event last-command-event)))
      (cooked--snap-to-cursor)
      (cooked--send-to-child bytes))))

(defvar cooked-send-string-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map minibuffer-local-map)
    (define-key map (kbd "S-<return>") #'newline)
    (define-key map (kbd "M-RET") #'newline)
    map)
  "Minibuffer map for `cooked-send-string\='.

`RET\=' sends what has been typed, so the newline a here-document or a
multi-line send needs has nowhere else to come from; `S-RET\=' inserts one, the
same split every chat client makes.

Both spellings, unconditionally, because nothing here can tell whether the
first will arrive.  This is Emacs\=' own keyboard, not the child\='s: what
`cooked--keys\=' negotiated says what the program *inside* the terminal may
send us, and has no bearing on whether the terminal Emacs is itself running in
reports a shift modifier on `RET\='.  A GUI frame does; a terminal one does
only if it speaks a protocol that can, which is between Emacs and its own
terminal.  So `M-RET\=' is bound alongside as the spelling that always
survives.  `C-j\=' is not: `minibuffer-local-map\=' binds it to
`exit-minibuffer\=', and taking that away would be a worse trade than the one
it fixes.  `C-q C-j\=' inserts a newline anywhere and is unaffected by either.")

(defun cooked-send-string (string)
  "Send STRING to the child.

Bound on `cooked-mode-map', not just `cooked-raw-map'/`cooked-alt-map', so it
also reaches the child while peeking -- ending peek first, so the result is
seen immediately rather than held behind the freeze -- but refuses once Emacs
owns the line: a string sent out of band would arrive at the child ahead of
whatever pending input is still sitting unsent in the buffer."
  (interactive (list (read-from-minibuffer "Send: " nil cooked-send-string-map)))
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
               (format "Paste %d lines, which %s will run as each arrives?"
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

;;;; Per-program key overrides

(defconst cooked--override-bytes
  '((:newline . "\n") (:return . "\r") (:meta-return . "\e\r")
    (:tab . "\t") (:escape . "\e"))
  "Bytes each named `cooked-key-overrides' action stands for.
Names rather than literals so an override can be written without anyone having
to know that Meta+Return is spelled ESC CR.")

(defconst cooked--override-encodings
  '((:kitty . kitty) (:modify-other . modify-other))
  "Protocols a `cooked-key-overrides' action can name.

Maps each to the `cooked--keys' value it stands for.

These re-spell the key that was pressed, so `<S-return>' with `:kitty' sends
`ESC [ 13;2 u' without anyone writing that out.  Unlike everything else cooked
sends, this is not backed by a negotiation -- see `cooked-key-overrides'.")

(defcustom cooked-key-overrides nil
  "Keys that mean something particular to a particular program.

An alist of (CONDITION . BINDINGS), consulted only while the child owns the
keyboard -- at a prompt Emacs owns the line, and `cooked-newline' already binds
Shift+Return there.

CONDITION is either a regexp matched against the name of the program in the
child's foreground process group -- `claude' matches whether it was started as
the session's command or typed at the session's shell -- or a function of no
arguments called in the buffer, for a test the process name cannot express
\(`cooked--title', `cooked--alt', `default-directory').

BINDINGS is an alist of (KEY . ACTION), KEY as `kbd' spells it.  ACTION is:

  a keyword naming bytes  `:newline', `:return', `:meta-return', `:tab',
                          `:escape' -- see `cooked--override-bytes'
  a protocol keyword      `:kitty' or `:modify-other', which re-spell the
                          key that was pressed in that protocol
  a string                sent to the child verbatim
  a symbol                run as an ordinary command, e.g. `cooked-newline'

Where several entries match, the first one to bind a key wins.

This exists for a program that never negotiates a keyboard protocol it still
expects -- see `cooked-key-protocol-overrides' for the reasoning, and for
Claude Code, whose Shift+Return and Shift+Tab are the reason this and it both
exist.  Empty by default now that Claude Code's own needs are covered there
instead: it takes every key it binds through the one protocol it assumes, so
nothing here has to name them one at a time.  What is left for this alist is
the narrower case a blanket protocol guess cannot cover -- a specific byte a
program wants regardless of protocol, or a key with no negotiated encoding at
all to re-spell in the first place.

Nothing here changes `cooked--keys': what cooked sends of its own accord still
follows the negotiation and nothing else, as with
`cooked-key-protocol-overrides'
-- and the same as a real one, a `:kitty' or `:modify-other' action here sends a
sequence the child never negotiated, on your say-so that it understands one
anyway."
  :type '(alist :key-type (choice (regexp :tag "Foreground program matching")
                                  (function :tag "Predicate"))
                :value-type
                (alist :key-type (string :tag "Key")
                       :value-type (choice (const :tag "Newline (LF)" :newline)
                                           (const :tag "Return (CR)" :return)
                                           (const :tag "Meta+Return (ESC CR)" :meta-return)
                                           (const :tag "Tab" :tab)
                                           (const :tag "Escape" :escape)
                                           (const :tag "Re-spell as kitty" :kitty)
                                           (const :tag "Re-spell as modifyOtherKeys"
                                                  :modify-other)
                                           (string :tag "Literal bytes")
                                           (function :tag "Command"))))
  :group 'cooked)

(defvar-local cooked--override-map nil
  "Keymap for the overrides that apply to what is running right now.")

(defvar-local cooked--override-map-alist nil
  "The `emulation-mode-map-alists' entry activating `cooked--override-map'.

Buffer-local, unlike `cooked--mouse-map-alist': the mouse map is one keymap
shared by every session and switched on with a variable, while this one is built
from whatever this buffer's child happens to be running.  nil deactivates it,
which is also how the whole feature stays inert in a buffer with no overrides.")

(defvar-local cooked--override-actions nil
  "What `cooked-send-override' should send, keyed by the key that invoked it.

The bindings could have been closures over their own bytes, but a keymap full of
anonymous functions describes itself badly: \\[describe-key] on an overridden key
should name a command you can look up.")

(defvar-local cooked--foreground-name nil
  "Cached (PID . NAME) for the child's foreground process group.
`process-attributes' is not free, and the pid is what says whether it is stale.")

(defun cooked--foreground-program ()
  "Name of the program in the child's foreground process group, or nil.

Not the session's own command: that is usually a shell, and what the user is
looking at is whatever the shell put in the foreground.  So a `claude' typed at
a cooked shell answers `claude' here, which is the case an override has to be
able to name."
  (when-let* ((session (cooked--live-session))
              (pid (cooked--foreground-pid session)))
    (if (eq pid (car cooked--foreground-name))
        (cdr cooked--foreground-name)
      (cdr (setq cooked--foreground-name
                 (cons pid (alist-get 'comm (process-attributes pid))))))))

(defvar-local cooked--foreground-label nil
  "Name of the program the child last had in the foreground, for the mode line.

Maintained from `cooked--refresh-keymap\=' rather than read when the mode line
asks, for the same reason `cooked--attention\=' is: `cooked--mode-line\=' runs
from an `:eval\=' on every redisplay, and the answer costs a `tcgetpgrp\=' and,
on a miss, a `process-attributes\=' -- which its own cache exists because it is
not free.  Recomputing that per frame to render one word would be paying a
syscall for a string that changes when the policy does.

Every transition worth naming already passes through that refresh: termios
flipping as a full-screen program takes the tty, and an OSC 133 `C\=' as a
marked command starts.  What it misses is one quiet command following another
at an unmarked shell, where nothing changes state -- so the label is a
best-effort hint, and is allowed to be.")

(defun cooked--update-foreground-label ()
  "Refresh `cooked--foreground-label\=' for what the child is running now.

Nil when the foreground process group is the session\='s own child -- the shell
cooked spawned, sitting at its prompt.  Naming it there would put `zsh\=' in the
mode line for the whole life of every session, which is a word that is always
true and never news.

Deliberately *not* keyed on who owns the line.  A canonical tty is not a shell
prompt: `cat\=' and `sleep\=' hold one too, and cooked reads those as `edit\='
because they genuinely are a line being edited.  Those are exactly the cases
where the program\='s name is the only thing on screen saying what the line will
be read by -- so the test is which process, not which policy."
  (setq cooked--foreground-label
        (and cooked--session
             (let ((foreground (cooked--foreground-pid cooked--session)))
               (and foreground
                    (not (eql foreground (cooked--pid cooked--session)))
                    (cooked--foreground-program))))))

(defun cooked--override-applies-p (condition)
  "Whether CONDITION selects what the child is running now."
  (if (functionp condition)
      (funcall condition)
    (when-let* ((program (cooked--foreground-program)))
      (string-match-p condition program))))

(defun cooked--override-bytes-for (action event)
  "Bytes ACTION sends for EVENT, or nil if it sends none.

A protocol keyword re-spells EVENT itself, which is what saves an override from
having to write `ESC [ 13;2 u' out by hand.  `cooked--keys' is bound rather than
consulted: the override is a statement about this one program, and must not
become cooked's idea of what the child negotiated."
  (cond
   ((stringp action) action)
   ((alist-get action cooked--override-bytes))
   ((when-let* ((encoding (alist-get action cooked--override-encodings)))
      (let ((cooked--keys encoding))
        (cooked--encode-event event))))))

(defun cooked-send-override ()
  "Send the bytes `cooked-key-overrides' gives for the key that invoked this."
  (interactive)
  (when-let* ((action (alist-get (this-command-keys-vector)
                                 cooked--override-actions nil nil #'equal))
              (bytes (cooked--override-bytes-for action last-command-event)))
    (cooked--snap-to-cursor)
    (cooked--send-to-child bytes)))

(defun cooked--build-override-map ()
  "Keymap and action table for the overrides matching what is running.
Returns nil when nothing matches, which is the common case."
  (let ((map (make-sparse-keymap))
        (actions nil)
        (any nil))
    (dolist (entry cooked-key-overrides)
      (when (cooked--override-applies-p (car entry))
        (pcase-dolist (`(,key . ,action) (cdr entry))
          (let ((keys (kbd key)))
            ;; An earlier entry wins, so a general rule can be written under a
            ;; specific one without quietly taking it over.
            (unless (lookup-key map keys)
              (setq any t)
              (if (and (symbolp action) (not (keywordp action)))
                  (define-key map keys action)
                ;; `vconcat' because `kbd' answers a string for an ASCII chord and
                ;; a vector for a symbolic key, while the lookup side is always a
                ;; vector -- and `key-parse', which would say this directly, is
                ;; newer than the Emacs this package supports.
                (push (cons (vconcat keys) action) actions)
                (define-key map keys #'cooked-send-override)))))))
    (when any (cons map actions))))

(defun cooked--update-key-overrides ()
  "Rebuild the override map for what the child is running now.

Gated exactly as `cooked--update-mouse-grab' gates the mouse, and for the same
reason: these are keys being taken away from Emacs, so they may only apply while
the child owns the keyboard.  Without that, an override on `<S-return>' would
follow the buffer to its own prompt and displace `cooked-newline'."
  (let ((live (and cooked-key-overrides
                   (not (cooked--input-state-p))
                   (not (cooked--suspended-p)))))
    (pcase (and live (cooked--build-override-map))
      (`(,map . ,actions)
       (setq cooked--override-map map
             cooked--override-actions actions
             cooked--override-map-alist `((cooked--override-map . ,map))))
      (_
       (setq cooked--override-map nil
             cooked--override-actions nil
             cooked--override-map-alist nil)))))

(defcustom cooked-key-protocol-overrides '(("\\`claude\\'" . kitty))
  "Protocol to assume a program speaks, for one that never negotiates one.

An alist of (CONDITION . PROTOCOL).  CONDITION is as in `cooked-key-overrides'.
PROTOCOL is `kitty' or `modify-other' -- one of the values `cooked--keys' takes
when a child negotiates one of them for real, via `CSI ? u'.

This is the blanket version of `cooked-key-overrides': rather than re-spelling
one named key, it makes `cooked-send-key' behave, for every key in
`cooked--literal-codes', exactly as if the child had negotiated PROTOCOL --
the right tool once a whole program is known to accept a protocol it simply
never asks for, rather than one specific key found to need nudging around its
absence.  Consulted only while the child owns the keyboard, and only when
`cooked--keys' is still `legacy': a real negotiation is always believed over a
guess about what a program probably wants, never overridden by one.

A `cooked-key-overrides' entry for the same key still wins over this: it is
consulted first, from a keymap that sits above the ordinary passthrough map
this only ever adjusts.

The default covers Claude Code, which decides whether the kitty protocol is
available by matching TERM and TERM_PROGRAM against terminals it knows rather
than by asking: it never sends the `CSI ? u' query cooked stands ready to
answer.  So `cooked--keys' stays `legacy' and the modified forms of the keys in
`cooked--literal-codes' are never sent -- although Claude decodes them without
difficulty once they arrive, having only ever needed to expect them, not to
have negotiated them.

The override is therefore the missing half of a negotiation nobody started.
The other way through would be to answer the sniff -- report a TERM from
Claude's list -- and cooked will not: it reports what it actually implements,
which is the whole point of shipping a terminfo entry.  This configures your
keyboard rather than misreporting cooked's identity."
  :type '(alist :key-type (choice (regexp :tag "Foreground program matching")
                                  (function :tag "Predicate"))
                :value-type (choice (const :tag "Kitty keyboard protocol" kitty)
                                    (const :tag "xterm modifyOtherKeys" modify-other)))
  :group 'cooked)

(defun cooked--assumed-key-protocol ()
  "Protocol `cooked-key-protocol-overrides' assumes for what is running now.

nil when nothing matches, when the child owns nothing right now to assume it
for, or when `cooked--keys' says a real negotiation already answered the
question -- see `cooked-key-protocol-overrides'."
  (and cooked-key-protocol-overrides
       (eq cooked--keys 'legacy)
       (not (cooked--input-state-p))
       (not (cooked--suspended-p))
       (cdr (seq-find (lambda (entry) (cooked--override-applies-p (car entry)))
                      cooked-key-protocol-overrides))))

(defconst cooked--escape-key ?\C-c
  "Prefix reserved for cooked's own commands while the child owns the keyboard.
Everything `cooked-raw-map' and `cooked-alt-map' cover is otherwise forwarded
verbatim, ESC included, so \\`M-x' reaches the child as ESC x — exactly as in
any other terminal.  \\`C-c M-x' is the way back out; see `cooked-meta-x'.

`cooked-semi-map' is the exception, and deliberately so: it keeps ESC and the
whole Meta space for Emacs, which is what makes evil's insert state a state you
can leave.  See `cooked-semi-exceptions'.")

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
;; Whether the render *also* stops is a separate question, and collapsing the two
;; is what makes stepping out expensive.  `cooked--input-mode' is `still' when the
;; child should keep
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
;; route got you into normal state.  See `cooked-input-mode-functions', which is
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
the buffer read-only with no way back.  `cooked--refresh-keymap' now answers
that at the source -- a buffer with no session has no input mode at all, and
`cooked--on-exit' refreshes on the way out -- so this is the second lock on the
same door rather than the only one."
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
that write to the child (\\`C-c C-c\=', \\`C-c C-y\=', and the rest).  Calling this
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
\\`C-u\=', say.  Reaches \\`C-c\=' too: \\`C-c C-q C-c\=' sends a literal \\`C-c\=' byte.

Bound on `cooked-mode-map', so it also reaches the child while peeking -- ending
peek first, so the result is seen immediately -- but refuses once Emacs owns
the line -- see `cooked-send-string', which shares the reasoning."
  (interactive)
  (cooked--resume-forwarding)
  (when (cooked--input-state-p)
    (user-error "Emacs already owns the line; type directly instead"))
  (let* ((cooked--keys (or (cooked--assumed-key-protocol) cooked--keys))
         (bytes (cooked--encode-event (read-key "Send key: "))))
    (when bytes
      (cooked--snap-to-cursor)
      (cooked--send-to-child bytes))))

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
    (dolist (event cooked--mouse-events)
      (define-key map (vector event) #'cooked-mouse-event))
    map))

(defun cooked--replace-keymap (map fresh)
  "Give MAP the bindings of FRESH, keeping MAP\='s own identity.

Every map in this file is reachable from a variable that other maps have as
their parent and that `cooked--state-keymap\=' hands to `use-local-map\=', so a
`:set\=' that rebuilt one by assigning a new keymap would leave every one of
those pointing at the old object.  Replacing the bindings in place is what lets
`cooked-raw-exceptions\=' and friends be customised in a running session.

`set-keymap-parent\=' stores the parent as the list\='s own terminating cdr
rather than in a separate slot, so a plain `(setcdr map (cdr fresh))\=' would
silently drop it; save and restore it around the replacement."
  (let ((parent (keymap-parent map)))
    (setcdr map (cdr fresh))
    (set-keymap-parent map parent)))

(defun cooked--passthrough-setter (map &optional reserve-meta)
  "A `defcustom\=' `:set\=' rebuilding MAP as a passthrough map for its value.

The value is a list of key strings naming the control characters to keep for
Emacs; RESERVE-META means what it does in `cooked--build-passthrough-map\='.
MAP is named rather than passed, and checked for at call time, because the maps
are defined below the options that configure them -- the option has to exist
first for the `defvar\=' to read it."
  (lambda (symbol value)
    (set-default symbol value)
    (when (and (boundp map) (keymapp (symbol-value map)))
      (cooked--replace-keymap
       (symbol-value map)
       (cooked--build-passthrough-map (mapcar #'cooked--exception-code value)
                                      reserve-meta)))))

(defcustom cooked-raw-exceptions '("C-g" "C-x" "C-h" "C-u" "C-l")
  "Keys kept for Emacs during a raw read outside the alternate screen.

During such a read -- `cooked--policy' returns `raw' -- these stay bound to
their ordinary Emacs command instead of forwarding to the child.

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

Each entry names a single control character via `kbd', e.g. \"C-g\".  \\`C-y\=' is
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
  :set (cooked--passthrough-setter 'cooked-raw-map)
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
  :set (cooked--passthrough-setter 'cooked-semi-map t)
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

(defun cooked--build-input-map (delegated)
  "A fresh input-line keymap, with DELEGATED keys handed to the child.

Spelled as a builder rather than a literal for the same reason
`cooked--build-passthrough-map\=' is: `cooked-delegate-keys\=' can change at any
time, and rebuilding is the only way to put a key back that used to be
delegated.  Unbinding it instead would leave `TAB\=' bound to nothing rather
than to `completion-at-point\='."
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'cooked-send-input)
    (define-key map (kbd "<S-return>") #'cooked-newline)
    (define-key map (kbd "C-d") #'cooked-delete-char-or-eof)
    (define-key map (kbd "TAB") #'completion-at-point)
    (define-key map (kbd "M-p") #'cooked-previous-input)
    (define-key map (kbd "M-n") #'cooked-next-input)
    ;; The remap rather than `C-a' itself, so that whatever key a user has put
    ;; start-of-line on reaches it, and so that nothing is claimed in the maps
    ;; the child is being forwarded through -- `C-a' there is readline's own
    ;; start-of-line, or tmux's prefix, and it must arrive untouched.
    (define-key map [remap move-beginning-of-line] #'cooked-beginning-of-line)
    ;; Last, so a delegated key wins over the binding it replaces -- which is the
    ;; point of naming it.
    (dolist (key delegated)
      (define-key map (kbd key) #'cooked-delegate-this-key))
    map))

(defvar cooked-input-map
  ;; `cooked-delegate-keys' is defined below and cannot be read here; its `:set'
  ;; is what keeps the two in step from load onwards.
  (cooked--build-input-map '("C-r"))
  "Keymap while Emacs owns the input line.

Cooked's own `C-c'-prefixed commands (interrupt, EOF, paste, and the rest)
are not repeated here -- they live on `cooked-mode-map', this map's parent,
so the same set reaches `cooked-raw-map'/`cooked-alt-map' and a bare peek
without being declared three times over.")

(defun cooked-delegate-key (key)
  "Hand the pending input to the child\='s line editor, then send KEY to it.

The primitive behind `cooked-delegate-keys\=', and deliberately not a completion
feature: nothing here knows what KEY means.  Send `C-r\=' and you get fzf or
atuin; send the up arrow and you get the shell\='s own history, with
`share_history\=', `zsh-histdb\=' and every `bindkey\=' the user has
accumulated.  That is worth more than any of it could be reimplemented for,
because `comint-input-ring\=' here is fed only by `cooked--history-record\='
from what was typed in *this* buffer and so starts empty every session.

Three things have to happen in this order.

Ownership is dropped *first*.  The line is about to be echoed by the shell, and
a buffer that still believes it owns an input region would render it a second
time on top.  The text is left in place rather than deleted, for the reason
`cooked-send-input\=' leaves it: the echo redraws identical characters over the
same cells and nothing moves, where deleting it would empty the row for the one
redisplay it takes to come back.

The *whole* line is sent, not the part before point.  Sending the prefix would
silently drop whatever followed the cursor, and the left-arrows that avoid it
cost one byte each.

Then KEY, once the shell\='s cursor is back where the user\='s was."
  (unless (cooked--input-state-p)
    (user-error "The child already owns the line"))
  (pcase-let* ((`(,start . ,end) (cooked--input-region))
               (text (buffer-substring-no-properties start end))
               (after (- end (max start (min (point) end)))))
    (cooked--clear-input-region)
    (setq cooked--delegated t)
    (cooked--refresh-keymap)
    (cooked--send-to-child
     (concat text (apply #'concat (make-list after "\e[D")) key))))

(defun cooked-delegate-this-key ()
  "Delegate the pending input and send the key that invoked this command.
See `cooked-delegate-key\=' and `cooked-delegate-keys\='."
  (interactive)
  (let ((cooked--keys (or (cooked--assumed-key-protocol) cooked--keys)))
    (when-let* ((bytes (cooked--encode-event last-command-event)))
      (cooked-delegate-key bytes))))

(defcustom cooked-delegate-keys '("C-r")
  "Keys that hand the line to the child\='s line editor before being sent.

Each is a `kbd\=' string, bound in `cooked-input-map\=' -- so they apply only
where Emacs owns the line, which is the only place there is anything to hand
over.

`C-r\=' is the default because reverse history search is the clearest case for
delegating: the flow is search, accept, Enter, so the line goes back to the
shell at a point where Emacs editing was not going to be wanted again anyway,
and the alternative is a history ring that knows nothing of the shell\='s.

`TAB\=' is deliberately *not* here.  Delegation is a one-way door for the rest
of the line, and losing the Emacs input region must never be a side effect of a
key pressed fifty times an hour; `TAB\=' stays `completion-at-point\=' at every
level, and what answers it changes with the tier while what it means does not.
Putting it here is supported and reasonable -- it is how a shell with marks but
no completion channel reaches `git checkout <TAB>\=' -- but it should be chosen."
  :type '(repeat string)
  :set (lambda (symbol value)
         (set-default symbol value)
         (when (and (boundp 'cooked-input-map) (keymapp cooked-input-map))
           (cooked--replace-keymap cooked-input-map
                                   (cooked--build-input-map value))))
  :group 'cooked)

(defun cooked-send-input ()
  "Submit the pending input to the child.
The kernel echoes it back, so the emulator renders the line, not us.

Enter is sent as CR, which is what a terminal actually transmits: in canonical
mode `ICRNL' turns it into the newline the child expects, and in raw mode it is
what a shell's line editor is bound to.  Sending LF works for readline but not
for ZLE."
  (interactive)
  (let ((text (or (cooked--pending-input) "")))
    ;; The text is left in the buffer rather than deleted, and that is the whole
    ;; of the fix for a flicker on Enter: deleting it emptied the line here and
    ;; now, while the echo that puts it back is a round trip through the child
    ;; away -- one redisplay in between with the prompt bare, which reads as the
    ;; line vanishing and coming back.  Left where it is, the echo redraws that
    ;; row over the top of identical text and nothing moves.  Only the region
    ;; goes, so the text stops being editable the moment it is submitted.
    (cooked--clear-input-region)
    (cooked--history-record text)
    (cooked--send-input-string text)))

(defun cooked--send-input-string (text)
  "Submit TEXT to the child as one line of input.

Split out from `cooked-send-input' because `comint-input-sender' hands us the
string rather than the buffer region, and both must submit the same way.

At a continuation prompt this *appends* rather than replaces.  A multi-line
construct reaches the shell one line at a time -- Emacs owns each `PS2' line
the same way it owns the first -- so the record for
\"for x in 1 2; do ... done\" would otherwise say only `done', which is the
line submitted last rather than the command that ran.  See
`cooked--prompt-continued'."
  (setq cooked--submitted-input
        (let ((line (and (not (string-blank-p text)) text)))
          (if (and cooked--prompt-continued cooked--submitted-input
                   ;; A continuation continues *something*.  Without this the flag has
                   ;; no path that clears it when the `A' and the `C' it expects never
                   ;; arrive -- a shell emitting `A;k=s' with the plain marks turned
                   ;; off does exactly that -- and every later line was appended to the
                   ;; last, growing one record's input without bound.
                   cooked--prompt-start)
              (concat cooked--submitted-input "\n" (or line ""))
            line)))
  (cooked--send-to-child
   ;; A multi-line submission has to arrive as a paste, or the shell's line editor
   ;; treats every embedded newline as its own Enter and runs the fragments one at
   ;; a time.
   ;;
   ;; Through `cooked--bracketed-paste' rather than bracketing it here, because
   ;; the end marker has to be stripped out of TEXT first and this path used to
   ;; spell the wrapping itself and forget to.  TEXT is not ours: it is whatever
   ;; is in the input region, and a paste into that region can carry a literal
   ;; `ESC [ 201 ~' -- which closed the bracket early and handed the shell the
   ;; rest as keystrokes.
   (concat (if (and (string-search "\n" text)
                    (cooked--bracketed-paste-p cooked--session))
               (cooked--bracketed-paste text)
             text)
           "\r")))

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
;; `comint-input-ring' holds it -- not a private list.  The one thing standing in
;; the way was that comint's ring navigates relative to a process mark, which
;; cooked has to maintain or `comint-previous-input' answers "Not at command
;; line"; `cooked--input-mark' is that mark.  Everything hung off the
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
Positive DELTA moves towards older entries, as \\[cooked-previous-input] does."
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

(defun cooked--history-key (key n)
  "Send KEY, a cursor key symbol, to the child N times.

What \"previous input\" means once the child owns the keyboard: the history is
the shell's, or readline's, or fzf's, and the way to ask for it is the cursor
key a terminal would have sent.  Sent as the key rather than as
`last-command-event', so \\[cooked-previous-input] on `M-p' asks for the same
thing \\`<up>' does instead of forwarding a Meta chord the child never asked
for."
  (cooked--resume-forwarding)
  (when-let* ((bytes (cooked--encode-event key)))
    (cooked--snap-to-cursor)
    (dotimes (_ (max 1 n)) (cooked--send-to-child bytes))))

(defun cooked-previous-input (&optional n)
  "Recall the Nth previous input.

At a prompt this is Emacs' own history, editing the pending line in the buffer.
Everywhere else the child is the one with a history, and this forwards \\`<up>'
to it -- which is what the key would have done in any terminal, and what it has
to do here: `evil-collection-comint' binds the arrow keys for insert state on
an auxiliary keymap that outranks `cooked-semi-map', so without this they reach
`cooked--history-move' at a shell that is editing its own line and are answered
with \"Not at an input prompt\"."
  (interactive "p")
  (if (cooked--input-state-p)
      (cooked--history-move (or n 1))
    (cooked--history-key 'up (or n 1))))

(defun cooked-next-input (&optional n)
  "Recall the Nth next input.
Forwards \\`<down>' while the child owns the keyboard; see
`cooked-previous-input'."
  (interactive "p")
  (if (cooked--input-state-p)
      (cooked--history-move (- (or n 1)))
    (cooked--history-key 'down (or n 1))))

(defun cooked--eof-byte ()
  "The character this tty means by end-of-file.

Read rather than assumed, for the reason `cooked--send-job-control\=' reads the
others: `stty eof ^X\=' is a thing people do.  Deliberately not routed through
that function, whose shape is \"the character if ISIG, else the signal\" --
neither half applies here.  EOF is not a signal, so there is nothing to fall
back to, and `ISIG\=' does not govern it: `ICANON\=' decides whether the line
discipline turns the byte into end-of-input, and a raw-mode program just reads
it.  Either way the byte is what a terminal sends.

`?\\C-d\=' when the character is disabled (`_POSIX_VDISABLE\='), which is the one
case with nothing to read -- the conventional value beats sending nothing."
  (or (and cooked--session (plist-get (cooked--job-control cooked--session) :eof))
      ?\C-d))

(defun cooked-delete-char-or-eof ()
  "Delete forward, or send EOF when the input line is empty."
  (interactive)
  (if (string-empty-p (or (cooked--pending-input) ""))
      (cooked--send-to-child (string (cooked--eof-byte)))
    (delete-char 1)))

(defun cooked-send-eof ()
  "Send EOF to the child.

Unlike \\[cooked-interrupt] this is a byte, not a signal: in canonical mode the
line discipline turns it into end-of-input, and a raw-mode program reads it as
^D.  Bound explicitly because at a prompt plain \\[cooked-delete-char-or-eof]
deletes forward unless the line is already empty.  Ends peek first when
peeking, so the effect is seen right away.

Which byte that is comes from the tty -- see `cooked--eof-byte'."
  (interactive)
  (cooked--resume-forwarding)
  (cooked--send-to-child (string (cooked--eof-byte))))

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

The session is checked before the pending input is abandoned, so an interrupt
that
cannot be delivered leaves the line you were typing where it was.  Ends peek
first when peeking: a signal you cannot see land is not worth sending blind."
  (interactive)
  (cooked--resume-forwarding)
  (let ((session (cooked--require-session)))
    (cooked--clear-input-region)
    (cooked--send-job-control session :intr 2)))

(defun cooked-kill-session ()
  "Kill the child outright, leaving the transcript behind.

Not job control, and deliberately not routed through
`cooked--send-job-control\=': there is no tty character for this and no line
discipline to turn one into anything, so a signal is not the fallback here --
it is the only thing this could ever have been.  Written as one directly, so
the shape of the code says which kind of thing it is.

Where comint puts `comint-kill-subjob\=', which cannot be inherited: it calls
`kill-process\=' on the buffer\='s process, and this buffer\='s process is
`cooked--wake\=', the pipe the child rings when output is pending.  Left alone,
that menu entry killed the doorbell and left the child running behind a buffer
that had stopped hearing from it.

Asks first, because it is the one thing on that menu with no softer form: the
rest write a character the child is free to ignore, and this is not deliverable
to anything that could decline it."
  (interactive)
  (let ((session (cooked--require-session)))
    (when (yes-or-no-p "cooked: kill the child? ")
      (cooked--kill session))))

(defun cooked-continue ()
  "Send SIGCONT to the child.

Deliberately absent from the menu, which is worth saying here rather than
leaving to look like an oversight.  A terminal has no continue character: the
tty carries `intr\=', `quit\=' and `susp\=' in `c_cc\=' and nothing else, so
`cooked-interrupt\=', `cooked-quit\=' and `cooked-suspend\=' each have a byte to
write and this has none.  What resumes a stopped job is the shell\='s own `fg\=',
a piece of bookkeeping the terminal is not party to -- its part ended when it
wrote the `susp\=' character.

It exists because comint\='s `comint-continue-subjob\=' is inherited, and
inherited it calls `continue-process\=' on `cooked--wake\='.  The remap is the
point of this function; anyone reaching for it directly almost certainly wants
`fg\='."
  (interactive)
  (cooked--signal (cooked--require-session) 18))

;;;; State transitions

(defun cooked--resample-mode ()
  "Re-read the child's termios and adopt what it says, right now.

The drain's `:mode\=' is whatever the reader thread last sampled, and the poll
interval is the whole of how fresh that is.  For redisplay that is exactly
right: a drain describes a moment that has already gone by.  For a keystroke it
is not, because one kind of mode change reaches the pty as nothing at all.

A child that turns echo off *without printing anything* -- `read -s\=' with no
prompt, a bare `stty -echo\=' -- moves the tty and writes no byte, so nothing
wakes the reader and nothing schedules a drain.  Until the next timer tick
`cooked--mode\=' still says `cooked\=', Emacs still believes it owns the line, and
the password the user has already started typing is being rendered into the
buffer, sent on RET, and left behind in the scrollback and the undo history.

Closing that costs one `tcgetattr\=' on the command that would have leaked --
paid only when something is about to put text on an editable line, against a
timer that otherwise pays it ten times a second forever.  See
`cooked--guard-insertion\=', which is the only caller and the only place the
answer can be spent."
  (when cooked--session
    (cooked--set-mode (cooked--sample-mode cooked--session))))

(defvar cooked--child-equivalents
  '((yank                     . cooked-paste)
    (yank-pop                 . cooked-paste)
    (evil-paste-before        . cooked-paste)
    (evil-paste-after         . cooked-paste)
    (evil-paste-from-register . cooked-paste)
    (newline                  . cooked-send-key)
    (newline-and-indent       . cooked-send-key)
    (self-insert-command      . cooked-send-key))
  "What each foreign insertion command means once the child owns the line.

The division this encodes is the whole shape of the guard.  Cooked\\='s own
insertion commands already ask `cooked--input-state-p\\=' and do the right thing
on either answer -- `cooked-paste\\=' yanks or hands the kill to the child,
`cooked-newline\\=' and `cooked--history-move\\=' refuse -- so all they ever needed
was for that answer to be current, which `cooked--guard-insertion\\=' gives them.

These are the ones that cannot: `yank\\=', `newline\\=', `self-insert-command\\='
and evil\\='s paste commands know nothing about cooked and will insert wherever
point happens to be.  `self-insert-command\\=' earns its place twice over: the
substitution it gets here is the one `cooked--build-passthrough-map\\=' already
makes for it as a remap, so a keystroke arriving a moment early on the sample
reaches the child exactly as it would have a moment later.  For
them the guard substitutes the command that does the same job through the
child, so the user\\='s intent survives being answered by the other half of the
terminal.  A paste is still a paste; it just reaches the password read instead
of the buffer.

Substituting rather than refusing, because refusing is what the user cannot
act on: a paste that errors leaves them to work out that pressing it again
would have worked, and a password manager\\='s clipboard entry is often
single-use.  `cooked-evil-paste\\=' already makes exactly this mapping by hand,
so this generalises a choice the tree had already made.")

(defun cooked--guard-insertion ()
  "Re-read the tty before a command that would insert into the input region.

The whole of the point-of-use termios sample.  Everything that can put text on
the input line passes through here first -- a typed character, a paste, a yank
from a package that has never heard of cooked -- in one place rather than by
each one remembering to ask.

It was briefly two mechanisms: a `self-insert-command\\=' remap for the typed
character, and this hook for the rest.  One is enough, and the remap was the
half worth losing.  A remap *replaces* `this-command\\=' rather than layering
over it, so it silently took every ordinary keystroke out of
`cooked-snap-commands\\=' and broke the snap until the replacement was named
there too.  That trap is re-armed by any later remap and cannot be designed
away while one exists, and the substitution below does the same job without
it.

Keyed on `cooked-snap-commands\\=', which is not an approximation of \"commands
that insert\" but the very list the tree already maintains for that -- a new
insertion path has to join it for the snap to work at all, and so is enrolled
here by construction rather than by anyone thinking of it.  That is the point
of reusing it: the failure mode being designed out is a future command that
inserts and nobody remembers to guard.

The cost is one `tcgetattr\\=' on commands that were about to edit the buffer
anyway, and none at all on the cursor motions and window commands that make up
most of what runs here.  Sampling from `pre-command-hook\\=' unconditionally was
rejected for the typed case for exactly that reason and is rejected again here.

What the sample buys is that every `cooked--input-state-p\\=' asked during the
command that follows is answered against the tty as it is now, rather than as
the last poll left it -- which is the window a child\\='s silent `tcsetattr\\='
opens and the whole reason any of this exists.  See
`cooked--child-equivalents\\=' for the commands that cannot ask for themselves.

Runs ahead of `cooked--snap-to-input\\=', so a substituted command is snapped
against the state it will actually run in."
  (cooked--protect-hook
    (when (and cooked--session
               (memq this-command cooked-snap-commands)
               (cooked--input-state-p))
      (cooked--resample-mode)
      (unless (cooked--input-state-p)
        (when-let* ((equivalent (alist-get this-command cooked--child-equivalents)))
          (setq this-command equivalent))))))

(defun cooked--set-mode (mode)
  "Adopt MODE, switching keymaps and handling secret prompts on a change."
  (unless (eq mode cooked--mode)
    (setq cooked--mode mode)
    (cooked--refresh-keymap)
    (if (eq mode 'secret)
        (cooked--schedule-secret)
      (cooked--cancel-secret))))

(defcustom cooked-state-change-hook nil
  "Hook run in the session's buffer after who owns the keyboard changes.

Run once the keymap has been swapped, so `cooked--input-state-p' already reports
the new state.  This is the seam `cooked-evil' hangs off; anything else that has
to follow the input/raw switch can use it without cooked knowing about it.

On a change of ownership and on nothing else -- not on every refresh.  The
distinction is the whole meaning of the hook: `cooked--refresh-keymap' also runs
for a `raw'<->`alt' transition, for a termios poll that moved `cooked--mode'
between two states the child owns either way, and for a deliberate peek, none of
which change whose keyboard it is.  `cooked-evil-sync' answers this hook by
putting evil into `cooked-evil-child-state', so running it for those was how a
program that touched its termios settings -- which a full-screen program does
routinely -- dragged the user out of normal state a keystroke after they pressed
`C-z', leaving \`V' forwarded to the child instead of starting a selection."
  :type 'hook
  :group 'cooked)

(defvar-local cooked--ownership 'unset
  "Who owned the keyboard as of the last `cooked-state-change-hook' decision.
`unset' until the first refresh, so a session starting against a child that
already owns the keyboard still counts as a change and is announced.")

(defvar cooked-input-mode-functions nil
  "Abnormal hook deciding the `cooked--input-mode' for a buffer.

Each entry is called with no arguments, in the session's buffer, whenever
the state is recomputed, and the first non-nil answer wins.  The hook is run
for every live session, prompt included: Emacs owning the line takes the
keyboard half of the answer away, but not the half about the render -- a
child repainting a canonical tty is exactly the case `still' and `frozen'
are worth having.  `cooked--suspended-p' is where the keyboard half is
dropped; nothing is dropped here.

This is the seam that lets `cooked-evil.el' make the mode a function of evil's
state without cooked knowing evil exists.  Derived on every recomputation
rather than latched -- see the commentary above `cooked-toggle-peek' for what
latching it cost -- which is a property of *when* the hook is run and survives
it having more than one entry.

`cooked--default-input-mode' sits on it at depth 90, so an entry added
ordinarily is asked first and falls through to the default by answering nil.
Overriding the default outright, rather than pre-empting it, means
`remove-hook'.")

(defun cooked--default-input-mode ()
  "Suspend only when `cooked-toggle-peek' says so.
The answer for anyone not driving this from somewhere else."
  (and cooked--peek-explicit 'frozen))

;; Last, so anything added ordinarily is asked first and this answers only for
;; what nothing else claimed.
(add-hook 'cooked-input-mode-functions #'cooked--default-input-mode 90)

(defun cooked--state-keymap (mode policy)
  "The local map for input mode MODE under policy POLICY.

The policy is asked first when it is `cooked\=', and the mode only otherwise.
A mode that suspends forwarding is a claim about keys on their way to the
child, and at a prompt there are none: `cooked-peek-map\=' would take a line the
user is editing and make it unusable -- read-only through
`cooked--refresh-keymap\=', with `self-insert-command\=' remapped to send raw
bytes straight past cooked\='s own line editor.  What survives the prompt is the
render half of the mode, which no keymap carries."
  (pcase (and (not (eq policy 'cooked)) mode)
    ((or 'still 'frozen) cooked-peek-map)
    ('semi cooked-semi-map)
    (_ (pcase policy
         ('cooked cooked-input-map)
         ('alt cooked-alt-map)
         ;; A marked prompt with no license reads exactly like a running command
         ;; as far as the keyboard is concerned: the shell said where it is, so
         ;; there is nothing left to hedge and `cooked-raw-exceptions' would only
         ;; take keys away from a line editor that wants them.
         ((or 'command 'prompt) cooked-command-map)
         (_ cooked-raw-map)))))

(defvar cooked--quiet-refresh nil
  "Whether the refresh under way was asked for quietly.
Bound for the dynamic extent by `cooked--refresh-keymap', so a nested refresh
inherits it; see the QUIET argument there.")

(defun cooked--refresh-keymap (&optional quiet)
  "Install the keymap and render mode the current state asks for.

Two axes meet here: `cooked--policy', which is what the child is doing, and
`cooked-input-mode-functions', which is what the user is doing.  Both are always
asked; where they disagree, the policy wins over the keyboard and the mode wins
over the render.  At a prompt that means the line stays editable however the
mode reads -- `cooked--suspended-p' and `cooked--state-keymap' each drop the
mode's claim on the keys -- while a `still' or `frozen' still holds the view,
which is what a child repainting a canonical tty needs and what a single
combined flag cannot express.  A deliberate peek ends there all the same: it is
the door out of
forwarding, and at a prompt there is no forwarding for it to be the door out
of.  Everywhere else the mode decides outright, which is how a peek survives a
`raw'<->`alt' transition: it is recomputed to the same answer rather than
preserved.

With QUIET, `cooked-state-change-hook' is not run.  That hook means \"who owns
the keyboard changed\", and `cooked-evil-sync' acts on it by putting evil into
the state the child's ownership calls for -- so running it from a refresh that
evil itself triggered would have evil immediately undo the user's own `C-z'.
QUIET holds for the dynamic extent rather than for this frame alone: a refresh
nested inside a quiet one -- reached through the catch-up drain below and its
own `cooked--set-mode' -- was otherwise loud, and ran the hook on news of the
child that predates the keystroke being answered.

The hook runs last, after everything here has settled, so that a handler which
changes state and refreshes again nests cleanly: the inner refresh's decisions
are the ones left standing."
  (let* ((policy (cooked--policy))
         ;; Where a deliberate peek has nothing left to mean.  A dead session
         ;; counts with the prompt: there is no child to keep keys from and
         ;; nothing to defer, so a buffer left suspended when the child exited
         ;; must not stay read-only with no way back.  Cleared rather than
         ;; merely ignored, so that `cooked-toggle-peek' answers "Already
         ;; editable" at a prompt instead of toggling a flag nothing reads.
         (settled (or (eq policy 'cooked) (not cooked--session)))
         (was cooked--input-mode)
         (cooked--quiet-refresh (or quiet cooked--quiet-refresh))
         ;; The clearing has to happen before the mode is computed, not after:
         ;; `cooked--default-input-mode' -- and `cooked-evil--input-mode' ahead
         ;; of it -- read the flag, so clearing it afterwards would leave one
         ;; refresh's worth of freeze standing at a prompt.  A dead session is
         ;; asked nothing at all; there is no state left for a mode to describe.
         (mode (progn (when settled (setq cooked--peek-explicit nil))
                      (and cooked--session
                           (cooked--run-seam-until-success
                            'cooked-input-mode-functions)))))
    (setq cooked--input-mode mode)
    ;; Only ever undoes its own protection; see `cooked--read-only'.
    (cond ((cooked--suspended-p)
           (setq cooked--read-only t
                 buffer-read-only t))
          (cooked--read-only
           (setq cooked--read-only nil
                 buffer-read-only nil)))
    (use-local-map (cooked--state-keymap mode policy))
    ;; After the mode is already set, so the drain's own `cooked--set-mode' does
    ;; not find a freeze still in force and recurse back into here.
    (when (and cooked--session (eq was 'frozen) (not (eq mode 'frozen)))
      (cooked--drain-and-apply))
    ;; No `cooked--check-undo-anchor' after this on purpose: every site that can
    ;; make it do something -- move the tracked start from a real position to
    ;; nowhere -- runs inside `cooked--apply', which brackets its own
    ;; `cooked--with-child-edit' with exactly one such check after it unwinds.
    ;; The catch-up drain just above is the one place that transition becomes
    ;; visible outside that bracket, since a frozen peek defers rather than
    ;; drops the drain reporting it -- but `cooked--drain-and-apply' pays for
    ;; that deferral with the same guarantee, run before this line.  So by the
    ;; time it runs, either nothing moved (this is a no-op) or the move has
    ;; already been reconciled; see
    ;; `cooked-thawing-a-frozen-alt-exit-leaves-the-undo-anchor-honest'.
    (unless (cooked--input-state-p)
      (cooked--clear-input-region))
    (cooked--update-mouse-grab)
    ;; Here rather than on a drain: this asks what the child is running, and a
    ;; program starting or exiting is exactly what moves the policy that brought
    ;; us here.
    (cooked--update-key-overrides)
    ;; Same question, same moment, different consumer: the mode line names the
    ;; program too, and this is the one place that already knows the answer has
    ;; had a chance to change.
    (cooked--update-foreground-label)
    ;; And for the same reason: under `auto' the answer to "is this session
    ;; worth a warning before it is killed" is the policy that just changed.
    (cooked--sync-query-flag)
    ;; The state that decides whether a hidden cursor is honoured has just
    ;; changed, and a state change produces no output -- so without this nothing
    ;; would put a cursor back until the child next drew something.
    (cooked--sync-cursor-type)
    (cooked--update-ghost-cursor)
    (let ((owner (cooked--input-state-p)))
      ;; Recorded even for a quiet refresh, which is a refresh evil asked for and
      ;; must not be told about: what it changed is still the state the next
      ;; comparison is against.
      (unless (eq owner cooked--ownership)
        (setq cooked--ownership owner)
        (unless cooked--quiet-refresh
          (run-hooks 'cooked-state-change-hook))))))

(defun cooked--get-old-input ()
  "The command line at point, for `comint-get-old-input\='.

comint\='s default scans backwards for a prompt it can recognise.  The OSC 133
records already know where the line began, so \\[comint-copy-old-input] recovers
exactly what was run rather than whatever a regexp happened to match."
  (or (when-let* ((command (cooked--command-at (point))))
        (cooked-command-input command))
      ""))

(defun cooked-delete-output ()
  "Delete the output of the command at point, keeping the command line.

Bound where comint puts `comint-delete-output\=', which cannot be reused: it
puts its \"*** output flushed ***\" notice back through `comint-output-filter\=',
the insertion path cooked replaced with the drain outright.

Output can be in two places at once, and each half has one owner.  Whatever is
still on the grid belongs to the emulator, so this asks it to remove those rows
and lets the ordinary drain repaint what moved -- the same shape as sending
input, which also changes rows.  Deleting that text directly would leave the two
ends disagreeing about what the screen is, since the grid would still hold every
row.  Whatever has scrolled off is ordinary buffer text that Emacs owns
outright, and goes through `cooked--discard-scrollback-region'.

Refuses when the output reaches the row the child is on.  Below that the shell
is editing its own prompt line and tracking where it sits, and moving it would
corrupt a redisplay cooked cannot see, let alone repair."
  (interactive)
  (pcase-let ((`(,beg . ,end) (cooked--output-region-at-point)))
    ;; END is one past the output, so it lands on whatever the child drew next --
    ;; usually the following prompt.  The last character of the output is the one
    ;; whose row should go.
    (let* ((last-char (max beg (1- end)))
           (screen (cooked--screen-start-position))
           ;; Rows first, while positions still mean what they say: deleting the
           ;; scrollback half shifts everything after it.
           (first-row (car (cooked--screen-cell (max beg (or screen beg)))))
           (last-row (car (cooked--screen-cell last-char))))
      (when (and last-row (not (< last-row (cooked-cursor-row cooked--cursor))))
        (user-error "The child is still on that row"))
      (cooked--discard-scrollback-region beg end)
      (when (and first-row last-row (<= first-row last-row))
        (cooked--remove-rows (cooked--require-session)
                             first-row (1+ (- last-row first-row))))
      (cooked--drain-and-apply))))

(defun cooked-toggle-fold ()
  "Hide or reveal the output of the command at point."
  (interactive)
  (pcase-let ((`(,beg . ,end) (cooked--output-region-at-point)))
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

(defun cooked-rerun-command (&optional command)
  "Resend COMMAND's input line through the ordinary submit path.

The one verb of the three that cannot live beside the other two in
cooked-command.el: `cooked-copy-command\=' and `cooked-copy-output\=' ask the
records a question, and this one writes to the child, which is a direction that
file deliberately does not face.

Refuses anywhere but an empty prompt, and the two halves of that are separate
refusals rather than one.  With the child owning the line there is nothing to
submit *to* -- the text would be typed into whatever program is reading, which
is not what a rerun means.  With a line already half-typed the submission would
run that line with this one appended, which is worse than doing nothing because
it looks like it worked."
  (interactive)
  (let ((input (cooked-command-input (cooked--command-here command))))
    (unless input
      (user-error "cooked: nothing to rerun"))
    (unless (and (cooked--input-state-p)
                 (string-empty-p (or (cooked--pending-input) "")))
      (user-error "cooked: can only rerun at an empty prompt"))
    (cooked--history-record input)
    (cooked--send-input-string input)))

;;;; Size and lifecycle

(defun cooked--sync-size (&optional _frame)
  "Match the emulator and child to the window size.

The buffer text is not adjusted here directly: a resize marks every row damaged,
and the drain this triggers below extends or trims the screen region to suit.

That drain is forced rather than left to the next wakeup whenever the row or
column count changed, because it cannot wait for the child.  `cooked--resize\='
rewraps the native core\='s grid synchronously, but nothing carries that into the
buffer until something drains -- ordinarily the wake pipe, which only fires when
the child writes.  A child that does not immediately repaint on SIGWINCH, such
as an idle prompt, leaves the buffer showing rows sized for the old width
against a window already the new one, and Emacs soft-wraps whatever no longer
fits with no truncation marker.  Draining here closes that gap.

Not forced for a cell-only move, an ordinary `text-scale\=' zoom that leaves the
column count alone: nothing about the grid\='s content is stale then, only its
pixel size, which `cooked--rescale-deco\=' below brings into agreement without a
real drain.

The cell size in pixels goes along with the rows and columns, because the child
needs it: an image protocol sizes a transmission in pixels, and tools ask
XTWINOPS how big a cell is before deciding whether to draw at all.  A terminal
frame has no such thing and reports nil, which reaches the child as \"not
reported\" rather than as a claim about zero.

This is also the one place that notices the cell moving at all, which makes it
the trigger for `cooked--rescale-deco\='."
  (when cooked--session
    (pcase-let* ((`(,rows . ,cols) (cooked--window-size))
                 (cell (cooked--session-cell-size))
                 (moved (not (equal cooked--last-cell cell)))
                 (resized (not (equal cooked--last-size (cons rows cols)))))
      (unless (and (not resized) (not moved))
        (setq cooked--last-size (cons rows cols)
              cooked--last-cell cell
              cooked--rows rows
              cooked--cols cols)
        (cooked--resize cooked--session rows cols (car cell) (cdr cell))
        (when resized (cooked--drain-and-apply))
        ;; Decorations are cut to the cell, and nothing else in the codebase
        ;; re-renders scrollback, so this is where a transcript full of pictures
        ;; and box drawing is brought back into agreement with the font.  Gated
        ;; on the cell really having moved: `cooked--rescale-deco' is a
        ;; whole-buffer walk under `widen', and an ordinary reshape that leaves
        ;; the font alone must not pay for one.  After the drain above, so it
        ;; also covers whatever rows the resize itself just rewrapped in.
        (when moved (cooked--rescale-deco))))))

(defun cooked--session-cell-size ()
  "This buffer's cell size in pixels as (WIDTH . HEIGHT), or (nil . nil).

Nil on a terminal frame, where a cell has no pixel size to report, and nil as
well when the buffer is displayed nowhere — a guessed cell size would reach the
child as fact and outlive the guess."
  (let ((window (cooked--layout-window)))
    (if (and window (display-graphic-p (window-frame window)))
        (cooked--cell-size window)
      (cons nil nil))))

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

(defun cooked--user-window ()
  "The window the user is working in, looking past an active minibuffer.

Reading the minibuffer as \"the user has left\" is wrong in both directions:
it ends a deliberate peek the moment they reach for `M-x', `C-x b' or evil's
`:', and it tells a child that asked for focus events that it lost the
keyboard to a prompt that is about to hand it straight back."
  (or (and (window-minibuffer-p (selected-window))
           (minibuffer-selected-window))
      (selected-window)))

(defun cooked--defer (function)
  "Call FUNCTION with no arguments, later, in the current buffer if it lives.

The window hooks run during redisplay, and a drain is not a redisplay-safe
thing to do from one: it inserts text, swaps the local map, recenters windows
and runs `cooked-state-change-hook', which is arbitrary user code."
  (let ((buffer (current-buffer)))
    (run-at-time 0 nil
                 (lambda ()
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer (funcall function)))))))

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
      (let ((state (cond ((eq (current-buffer) (window-buffer (cooked--user-window)))
                          'here)
                         ;; Displayed elsewhere, or displayed nowhere having
                         ;; been somewhere a moment ago -- both are the user
                         ;; being elsewhere.  A buffer that has never been on
                         ;; screen stays nil and keeps its freeze.
                         ((or cooked--attention (get-buffer-window nil t))
                          'away))))
        (unless (or (null state) (eq state cooked--attention))
          (setq cooked--attention state)
          ;; The native core polls the child's termios on a tick, and the tick is
          ;; only ever for somebody watching -- so it stretches while nobody is.
          ;; Told before anything below acts on the new state, because coming back
          ;; is the one direction that needs the eager tick restored *first*.
          (cooked--set-attended cooked--session (eq state 'here))
          ;; Coming back is where Emacs hands the buffer a point it recorded
          ;; before every drain since, and a cooked position does not keep that
          ;; long.  See `cooked--restore-point'.
          (when (eq state 'here)
            (cooked--restore-point (cooked--user-window))
            ;; The mode is as stale as the tick that was running while the buffer
            ;; sat off screen, so it is read again here rather than inherited: a
            ;; child that went into a secret read silently would otherwise not be
            ;; noticed for up to a second after the user is already looking at it.
            ;; This is also what raises the prompt in the ordinary case, by way of
            ;; `cooked--set-mode'; `cooked--resume-secret' is for the other one,
            ;; where the mode was already `secret' before the buffer was left and
            ;; so nothing changes for `cooked--set-mode' to notice.
            (cooked--resample-mode)
            (cooked--resume-secret))
          (when (and (eq state 'away) (eq cooked--input-mode 'frozen))
            (cooked--defer
             (lambda ()
               (when cooked--session (cooked--drain-and-apply))))))))))

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
  (let ((window (cooked--user-window)))
    (and (eq (current-buffer) (window-buffer window))
         (frame-focus-state (window-frame window))
         t)))

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

;;;; What happens when the child exits

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

(defun cooked--stop-session ()
  "Kill the child and close the wake pipe, leaving the buffer sessionless.

Kill before closing the pipe.  The other order leaves the reader thread writing
into a closed pipe -- harmless, since it blocks SIGPIPE -- but this order costs
nothing.

The child is killed rather than left to the garbage collector: clearing
`cooked--session\=' only drops the last reference, and nothing guarantees a
collection ever runs, so the child would keep going long after whatever reason
there was to stop it.

Idempotent, and both callers rely on that -- `cooked--on-exit\=' runs when the
child reports its own exit and `cooked--cleanup\=' when the buffer is killed,
and a session that exits and is then killed goes through both."
  (when cooked--session (ignore-errors (cooked--kill cooked--session)))
  (when cooked--wake (delete-process cooked--wake))
  (setq cooked--session nil cooked--wake nil))

(defun cooked--on-exit (code)
  "Report that the child exited with CODE and stop the session."
  ;; A child can die while still on the alt screen — killed from outside, or
  ;; crashed mid-redraw — and nothing later would widen the buffer for it.
  (setq cooked--alt nil)
  (cooked--release-alt-pin)
  ;; `cooked--scroll-windows' already ran for this drain and pinned whatever was
  ;; then the buffer's true end to the bottom of every window that was following
  ;; it -- this call is what appends past that end, from entirely outside that
  ;; machinery, and stranding the line it adds is the same bug
  ;; `cooked--pin-transcript-bottom' exists to prevent. Captured before the
  ;; insert, and compared with the same slack-of-one `cooked--scroll-transcript'
  ;; uses: a window whose point was already at the old end was following, and
  ;; is owed the new one; a window scrolled up into history is left alone.
  (let ((old-end (point-max)))
    (cooked--with-child-edit
      (save-excursion
        (goto-char (point-max))
        (insert (format "\n[exited %s]\n" code))))
    (cooked--dolist-windows w (get-buffer-window-list nil nil t)
      (when (>= (window-point w) (1- old-end))
        (cooked--pin-transcript-bottom (list w)))))
  ;; A child that dies mid-`getpass' -- interrupted from the buffer, killed from
  ;; outside -- leaves a password prompt with nothing behind it.
  (cooked--cancel-secret)
  (cooked--stop-session)
  ;; After the session is gone, so the mode is recomputed as nil: a child that
  ;; exited while the buffer was suspended -- evil in normal state, or a
  ;; deliberate peek -- would otherwise leave it read-only under `cooked-peek-map'
  ;; with nothing left to thaw it.
  (cooked--refresh-keymap)
  ;; Deferred: this runs from inside the drain, which keeps working with the
  ;; buffer and its locals after we return.  Killing here would pull them out
  ;; from under it, and would run `kill-buffer-hook' — arbitrary user code —
  ;; halfway through a redraw.
  (when (cooked--kill-buffer-on-exit-p code)
    (let ((buffer (current-buffer)))
      (run-at-time 0 nil (lambda () (when (buffer-live-p buffer) (kill-buffer buffer)))))))

;;;; The mode

(define-derived-mode cooked-mode comint-mode "cooked"
  "Major mode for a terminal that hands the keyboard back for line input.

In `cooked' and OSC 133 input states the buffer behaves like any editable Emacs
buffer and \\[cooked-send-input] submits the line.  Otherwise keys are forwarded
to the child verbatim."
  :interactive nil
  (setq-local scroll-conservatively 101
              truncate-lines (not cooked-rejoin-wrapped-lines)
              mode-line-process '(:eval (cooked--mode-line))
              ;; Read once here and never toggled afterwards -- see
              ;; `cooked-sticky-scroll' for why toggling it would be its own PTY
              ;; resize.  Left alone entirely when the feature is off, so a
              ;; cooked buffer has no header line unless it was asked for.
              header-line-format (and cooked-sticky-scroll
                                      '(:eval (cooked--sticky-header))))
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
  ;; bare `face' property -- which would force the renderer to set `font-lock-face'
  ;; alongside every `face' it applies.  Clearing it lets one property carry a run.
  (setq-local font-lock-defaults nil)
  ;; Above every minor mode, so a program that asked for the wheel gets it even
  ;; where `pixel-scroll-precision-mode' has claimed the same events.
  (add-to-list 'emulation-mode-map-alists 'cooked--mouse-map-alist)
  ;; Above the state maps for the same reason, and above `cooked--mouse-map-alist'
  ;; only incidentally -- the two never bind the same event.
  (add-to-list 'emulation-mode-map-alists 'cooked--override-map-alist)
  (cooked--install-global-hooks)
  ;; Negative depth so it runs ahead of the snap: the guard can substitute
  ;; `this-command', and the snap reads `this-command' to decide whether to move
  ;; point at all.  Run the other way round, a substituted command would be
  ;; snapped against the command it replaced.
  (add-hook 'pre-command-hook #'cooked--guard-insertion -50 t)
  (add-hook 'pre-command-hook #'cooked--snap-to-input nil t)
  (add-hook 'post-command-hook #'cooked--track-wandering nil t)
  ;; From the same hook and for the same reason: the user's own commands produce
  ;; no output, so a drain is never what discovers that one of them scrolled the
  ;; alt screen out of the window.
  (add-hook 'post-command-hook #'cooked--pin-alt-windows nil t)
  ;; And again from redisplay, which is the only one of the two that sees a wheel
  ;; notch over a window the user has not selected, or a frame of the animation
  ;; `pixel-scroll-precision-interpolate' runs inside a single command.
  (add-hook 'pre-redisplay-functions #'cooked--pin-alt-windows nil t)
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
  (add-hook 'context-menu-functions #'cooked--context-menu nil t)
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
;; Reads the way \\`M->' does for the end of a buffer, and for the same reason:
;; the newest command is the one end of the transcript that keeps moving.  It had
;; no key at all until now -- only the mode line's exit status was a click away
;; from it, which is a control a keyboard cannot reach and a terminal frame does
;; not draw.
(define-key cooked-mode-map (kbd "C-c C->") #'cooked-goto-last-command)
;; goto-addr's own advertised key, and the entry point that does not need point to
;; be inside a highlighted span -- see `cooked-follow-link-at-point'.  Here rather
;; than in a `keymap' text property because `C-c' is forwarded to the child as the
;; interrupt character, and a `C-c' prefix in a property at point would make Emacs
;; wait for a second key before letting SIGINT through.
(define-key cooked-mode-map (kbd "C-c RET") #'cooked-follow-link-at-point)

;; comint-shaped, cooked-implemented.  These keep comint's own positions, because
;; the concept behind each is one a terminal genuinely has -- it is only comint's
;; implementation, which reaches for a process that here is a wakeup pipe, that
;; cannot be used.  See `cooked--input-mark' for why the rest of comint's C-c map
;; needs nothing.
(define-key cooked-mode-map (kbd "C-c C-\\") #'cooked-quit)
(define-key cooked-mode-map (kbd "C-c M-o") #'cooked-clear-scrollback)
(define-key cooked-mode-map (kbd "C-c SPC") #'cooked-newline)

;; Middle-click pastes to the child, which is what it does in every other
;; terminal.  comint binds it to `comint-insert-input', which looks for the input
;; field under the click; cooked sets no `field' properties, so it fell through to
;; the global `mouse-2' -- `mouse-yank-primary', which inserts the X selection
;; into the buffer.  Text that goes nowhere, in a transcript that is read-only
;; above the prompt, at a position the next repaint may overwrite.
;;
;; It composes with the two other claims on `mouse-2' by outranking neither,
;; which is the correct order rather than an accident.  A link span carries
;; `cooked-link-map' as a `keymap' text property, and a property keymap is
;; consulted before any keymap here, so clicking a link still follows it --
;; `cooked-follow-link' then makes the same decision this binding would have.
;; `cooked--mouse-map' lives in `emulation-mode-map-alists', which outranks the
;; local map, so a child that asked for the mouse gets the click and this is
;; never reached.  `S-mouse-2' is left alone in both directions.
;;
;; No `down-mouse-2' to go with it: nothing binds it globally, so there is no
;; earlier command to head off.
(define-key cooked-mode-map [mouse-2] #'cooked-paste)

;; Whatever key a user has bound to comint's commands reaches ours, so
;; `evil-collection-comint' (which binds `repl-submit' to `comint-send-input')
;; works without knowing cooked exists.
(dolist (remap '((comint-send-input . cooked-send-input)
                 (comint-interrupt-subjob . cooked-interrupt)
                 (comint-quit-subjob . cooked-quit)
                 (comint-delete-output . cooked-delete-output)
                 (comint-stop-subjob . cooked-suspend)
                 (comint-delchar-or-maybe-eof . cooked-delete-char-or-eof)
                 ;; The three that were left out, and the reason this list is
                 ;; worth auditing rather than adding to as commands appear.
                 ;; comint's own implementations do not fail here -- they
                 ;; *succeed*, against `cooked--wake': `comint-kill-subjob'
                 ;; kills the pipe the child rings when output is pending, and
                 ;; the buffer stops hearing from a child that is still
                 ;; running.  `cooked-continue' exists for no other reason than
                 ;; to stand here; see its docstring for why a terminal has no
                 ;; continue of its own.
                 (comint-send-eof . cooked-send-eof)
                 (comint-kill-subjob . cooked-kill-session)
                 (comint-continue-subjob . cooked-continue)
                 ;; And the two that read comint's input fields, which cooked
                 ;; does not set, so they answered from `point-min' and from
                 ;; nowhere respectively.  `comint-append-output-to-file' is
                 ;; deliberately not here: it misreads positions like these two
                 ;; but touches no process, so it is wrong rather than
                 ;; dangerous, and the menu simply stops offering it.
                 (comint-show-output . cooked-show-output)
                 (comint-write-output . cooked-write-output)
                 (comint-kill-input . cooked-kill-input)
                 (comint-previous-input . cooked-previous-input)
                 (comint-next-input . cooked-next-input)
                 (comint-previous-prompt . cooked-previous-command)
                 (comint-next-prompt . cooked-next-command)
                 ;; `C-c C-a', which cooked inherits live from `comint-mode-map'.
                 ;; Left alone it half-works by coincidence: `comint-bol' reads
                 ;; comint's input fields, which cooked does not set -- it marks
                 ;; the prompt read-only instead -- so the first press lands at
                 ;; column 0 inside the prompt, and only the repeat reaches the
                 ;; command, that arm asking for the process mark and cooked's
                 ;; input mark being that same marker.  comint's two presses in
                 ;; the other order, in other words, and resting on a coincidence.
                 ;; `cooked-beginning-of-line' gives both positions in comint's
                 ;; order and needs no repeat to be recognised.
                 (comint-bol-or-process-mark . cooked-beginning-of-line)))
  (define-key cooked-mode-map (vector 'remap (car remap)) (cdr remap)))

;;;; The menu

;; comint's three menus arrive with the parent keymap, and each is wrong here in
;; its own way.
;;
;; In/Out is mostly right, and that is the problem: three of its twenty-one
;; entries are not, and nothing on it says which three.  "Show Current Output
;; Group" walks `field' text properties, which cooked sets nowhere -- it marks
;; the prompt read-only instead -- so `field-beginning' answers `point-min' and
;; it scrolls to the top of the scrollback.  The two "Matching Input..." motions
;; count a hit only where `(get-char-property (point) 'field)' is non-nil, so
;; they search to the end of the buffer and report "Not found", every time.
;;
;; Signals offers EOF, KILL and CONT against the buffer's process, which is the
;; wakeup pipe; see the remap table above for where those three went.
;;
;; Complete asks a process that is not the child for filename completion -- the
;; same reason `cooked-mode' takes `comint-completion-at-point' out of
;; `completion-at-point-functions'.  Its one honest entry survives below,
;; running cooked's own capf.
;;
;; Deleted per entry rather than by giving `cooked-mode-map' a menu bar of its
;; own: a child keymap that binds `[menu-bar]' outright does not shadow the
;; parent's, because Emacs composes the two for the same prefix -- tried, and
;; `[menu-bar inout]' still resolved through it to comint's submenu.  An explicit
;; nil does shadow, and keeps shadowing through `cooked-input-map' and the rest,
;; which are installed with `use-local-map' and reach this map only as a parent.
;; `keymap-set' refuses a nil definition, so `define-key' is the tool here and
;; not a modernisation someone has yet to do.
;;
;; `menu-bar-final-items', which comint mutated globally when it loaded, is left
;; alone: with these three shadowed there is nothing left for those names to
;; order, and un-mutating a global another package set is not ours to do.
(define-key cooked-mode-map [menu-bar inout] nil)
(define-key cooked-mode-map [menu-bar signals] nil)
(define-key cooked-mode-map [menu-bar completion] nil)

(easy-menu-define cooked-mode-menu cooked-mode-map
  "Menu for `cooked-mode\='.

On `cooked-mode-map\=' rather than on each state map, for the reason cooked\='s
own commands are bound there: it should not evaporate because the child took the
keyboard, and every state map reaches this one as a parent -- peek included.
One menu rather than comint\='s three or `term.el\='s four, because four items of
job control and one of completion do not each earn a place on the menu bar, and
because this is the whole of what \\`mouse-1' on the mode name and a right-click
under `context-menu-mode\=' will show.

Every item is guarded rather than left to signal when it is chosen.  A menu is
the one interface that says what is possible *before* you commit to it, so an
item that would answer \"No live session\" is one that should have been greyed
out -- and cooked has the predicates already, because the mode line has been
reporting the same facts in words all along.  Greyed rather than hidden, too:
which state the terminal is in is exactly what someone reaching for the menu is
unsure of, and an item that vanishes answers nothing.

The guard forms are data.  The byte-compiler never looks inside them, so `make
lint\=' cannot catch a misspelled predicate or a command that does not exist the
way it catches one anywhere else in this file.  That is what the menu tests are
for, and why they walk this whole structure and evaluate every guard in every
state rather than merely checking that it parses."
  '("Cooked"
    ;; `cooked--input-state-p' alone is not the guard these want, and finding
    ;; that out is what the menu tests are for: with no session at all it
    ;; answers t -- the policy falls through to `cooked', Emacs owning a line
    ;; there is nobody to send -- so a buffer whose child has exited would have
    ;; offered every one of these.  A live child and an editable line are two
    ;; conditions, and the mode line has always said so: `exited 0' replaces the
    ;; state word rather than qualifying it.
    ["Send Input" cooked-send-input :enable (and (cooked--live-session)
                                                 (cooked--input-state-p))
     :help "Submit the pending line to the child"]
    ["Insert Newline" cooked-newline :enable (and (cooked--live-session)
                                                  (cooked--input-state-p))
     :help "Continue on a second line without submitting"]
    ["Kill Input" cooked-kill-input :enable (cooked--input-region)
     :help "Delete what has been typed but not sent"]
    ["Previous Input" cooked-previous-input :enable (and (cooked--live-session)
                                                         (cooked--input-state-p))
     :help "Recall the previous line from the history"]
    ["Next Input" cooked-next-input :enable (and (cooked--live-session)
                                                 (cooked--input-state-p))
     :help "Recall the next line from the history"]
    ["Complete at Point" completion-at-point :enable (and (cooked--live-session)
                                                          (cooked--input-state-p))
     :help "Complete the word at point, through the shell where it can"]
    "--"
    ["Paste to Terminal" cooked-paste :enable (cooked--live-session)
     :help "Send the head of the kill ring, bracketed if the child asked"]
    ["Send String..." cooked-send-string :enable (cooked--live-session)
     :help "Send text of your own to the child"]
    ["Send Next Key Literally" cooked-send-literal-key :enable (cooked--live-session)
     :help "Send the next key even where Emacs would have bound it"]
    ["Send M-x to the Child" cooked-meta-x :enable (cooked--live-session)
     :help "For a child that has its own M-x, rather than reading one here"]
    "--"
    ("Signals"
     ["Interrupt" cooked-interrupt :enable (cooked--live-session)
      :help "Write the tty's interrupt character, or SIGINT where ISIG is off"]
     ["Quit" cooked-quit :enable (cooked--live-session)
      :help "Write the tty's quit character, or SIGQUIT where ISIG is off"]
     ["Suspend" cooked-suspend :enable (cooked--live-session)
      :help "Write the tty's suspend character, or SIGTSTP where ISIG is off"]
     ["End of File" cooked-send-eof :enable (cooked--live-session)
      :help "Send the tty's EOF byte -- a byte, not a signal"]
     "--"
     ["Kill the Child" cooked-kill-session :enable (cooked--live-session)
      :help "SIGKILL, with the transcript left behind"])
    ("This Command"
     ["Show Its Output" cooked-show-output :enable (cooked--command-around (point))
      :help "Put the start of this command's output at the top of the window"]
     ["Fold Its Output" cooked-toggle-fold :enable (cooked--command-around (point))
      :help "Hide or reveal the output of the command at point"]
     ["Delete Its Output" cooked-delete-output :enable (cooked--command-around (point))
      :help "Ask the emulator to drop those rows"]
     ["Write Its Output to File..." cooked-write-output
      :enable (cooked--command-around (point))
      :help "Save this command's output, or with a prefix its whole record"]
     "--"
     ["Rerun It" cooked-rerun-command
      :enable (and (cooked--live-session)
                   (cooked--input-state-p)
                   (cooked--command-around (point)))
      :help "Resend this command's line, at an empty prompt"]
     ["Copy Its Command Line" cooked-copy-command
      :enable (cooked--command-around (point))
      :help "Put the line that was run on the kill ring"]
     ["Copy Its Output" cooked-copy-output :enable (cooked--command-around (point))
      :help "Put the output on the kill ring"])
    ["Previous Command" cooked-previous-command :enable cooked--commands
     :help "Move to the previous prompt"]
    ["Next Command" cooked-next-command :enable cooked--commands
     :help "Move to the next prompt"]
    ["Last Command" cooked-goto-last-command :enable cooked--commands
     :help "Move to the prompt of the most recently finished command"]
    ["Scroll to the Bottom" comint-show-maximum-output
     :help "Put the end of the transcript at the bottom of the window"]
    ["List Input History" comint-dynamic-list-input-ring
     :help "Show the input ring in a buffer of its own"]
    "--"
    ["Peek" cooked-toggle-peek
     :style toggle :selected cooked--peek-explicit
     :enable (or cooked--peek-explicit (not (cooked--input-state-p)))
     :help "Stop redrawing and hand the buffer to ordinary Emacs keys"]
    ["Refresh the Screen" cooked-refresh :enable (cooked--live-session)
     :help "Repaint from the emulator's own grid"]
    ["Clear Scrollback" cooked-clear-scrollback
     :help "Everything above the prompt goes, grid rows and scrollback alike"]
    ["Follow Link at Point" cooked-follow-link-at-point
     :help "Open the URL or file name at point"]
    "--"
    ("Options"
     ["Detect Links" (setq cooked-detect-links (not cooked-detect-links))
      :style toggle :selected cooked-detect-links
      :help "Highlight things that look like URLs as output is rendered"]
     ["Detect Links on the Alt Screen"
      (setq cooked-detect-links-on-alt-screen (not cooked-detect-links-on-alt-screen))
      :style toggle :selected cooked-detect-links-on-alt-screen
      :enable cooked-detect-links
      :help "A full-screen program usually wants the mouse for itself"]
     ["Inline Images" (setq cooked-inline-images (not cooked-inline-images))
      :style toggle :selected cooked-inline-images
      :help "Show images the child sends rather than their placeholder cells"]
     ["Rejoin Wrapped Lines" cooked-toggle-rejoin-wrapped-lines
      :style toggle :selected cooked-rejoin-wrapped-lines
      :help "Store a wrapped row as part of the line it belongs to"]
     ["Buffer Name Follows the Title"
      (setq cooked-buffer-name-follows-title (not cooked-buffer-name-follows-title))
      :style toggle :selected cooked-buffer-name-follows-title
      :help "Rename the buffer as the child sets its title"]
     ["Home Skips the Prompt"
      (setq cooked-beginning-of-line-skips-prompt
            (not cooked-beginning-of-line-skips-prompt))
      :style toggle :selected cooked-beginning-of-line-skips-prompt
      :help "Start-of-line lands on the command rather than inside the prompt"]
     "--"
     ;; Not a toggle, and it cannot be one: the header line it adds takes a row
     ;; of the window body, which is a row off the PTY, which is why
     ;; `cooked-mode' reads it once and never again.  Offered here as a switch it
     ;; would appear to do nothing; sent to Customize it says plainly that the
     ;; answer applies to the next cooked buffer.
     ["Sticky Scroll..." (customize-variable 'cooked-sticky-scroll)
      :help "Takes effect in new cooked buffers -- it resizes the PTY"]
     ["Customize Cooked" (customize-group 'cooked)])
    "--"
    ["Describe Mode" describe-mode]
    ["Install terminfo on a Host..." cooked-install-terminfo-remote]
    ;; A form rather than the function: `cooked-version' returns the string the
    ;; core was built with and is not a command, having been written for callers
    ;; rather than for a keystroke.
    ["Cooked Version" (message "cooked %s" (cooked-version))]))

(defun cooked--context-menu (menu click)
  "Add the command under CLICK to MENU, and return it.

`context-menu-local\=' already copies the menu above into every right-click, so
this is not where the verbs first appear -- it is where they are asked about
the right command.  Everything on that menu resolves its record from point, and
for a right-click point is wrong by exactly the distance the mouse travelled;
the three verbs that name a command are therefore worth a second copy up here,
each closed over the record `posn-point\=' found.

Nothing here has to consult `cooked--mouse-grab\='.  A child that asked for the
mouse gets `down-mouse-3' from `cooked--mouse-map\=', which lives in
`emulation-mode-map-alists\=' and so outranks the binding `context-menu-mode\='
installs globally -- meaning this is never reached in that state at all, and
Shift is the way in, exactly as it is everywhere else the child holds the
pointer."
  (when-let* ((position (posn-point (event-start click)))
              (command (cooked--command-around position)))
    (define-key-after menu [cooked-command-separator] menu-bar-separator)
    (define-key-after menu [cooked-context-copy-command]
      `(menu-item "Copy This Command Line"
                  ,(lambda () (interactive) (cooked-copy-command command))
                  :help "Put the line that was run on the kill ring"))
    (define-key-after menu [cooked-context-copy-output]
      `(menu-item "Copy This Output"
                  ,(lambda () (interactive) (cooked-copy-output command))
                  :help "Put this command's output on the kill ring"))
    (define-key-after menu [cooked-context-rerun]
      `(menu-item "Rerun This Command"
                  ,(lambda () (interactive) (cooked-rerun-command command))
                  :enable (cooked--input-state-p)
                  :help "Resend this command's line, at an empty prompt"))
    (define-key-after menu [cooked-context-fold]
      `(menu-item "Fold This Output"
                  ,(lambda ()
                     (interactive)
                     (save-excursion (goto-char position) (cooked-toggle-fold)))
                  :help "Hide or reveal this command's output")))
  menu)

(defun cooked-kill-input ()
  "Delete the pending input."
  (interactive)
  (when-let* ((region (cooked--input-region)))
    (delete-region (car region) (cdr region))))

(defcustom cooked-beginning-of-line-skips-prompt t
  "Whether a start-of-line motion stops at the command rather than the prompt.

Column 0 of the prompt row is inside the prompt, which is the child\='s text and
carries `read-only\=': a motion landing there has found the start of a *line*
and not the start of anything the user may edit, so the keystroke after it
either signals or is thrown away by `cooked--snap-to-input\='.  The useful
position is where the pending input begins, and `cooked--input-start-position\='
knows it exactly -- taken from the cursor cell at each drain, so it holds with
no shell integration at all and for a prompt that ends mid-row, neither of
which a line-oriented answer can manage.

A deliberate divergence, this.  comint has the same position and binds it to
\\`C-c C-a\=' (`comint-bol-or-process-mark\='), leaving \\`C-a\=' at true column 0;
`eat\=' inherits that unchanged.  The argument for keeping the literal motion
reachable is a good one and it is kept -- pressing the key again from the input
start goes on to column 0, and evil\='s \\`0\=' and \\`gI\=' are left stock.  What
is not kept is which of the two the unmodified key gets, because in a terminal
the prompt is never a destination: it is not editable, not selectable as input,
and not where any subsequent command wants to act.

One knob for all of them: \\[cooked-beginning-of-line] and, where `cooked-evil\='
is loaded, \\`^\=' and \\`I\='.  Nil restores the stock behaviour of each."
  :type 'boolean :group 'cooked)

(defun cooked--input-line-start ()
  "Where the pending input begins, if point is on the line it begins on.

Nil everywhere else, which is how scrollback, a full-screen program\='s screen
and a session that has died all fall through to the stock command instead of
being dragged to a prompt that is elsewhere in the buffer.

Point\='s own line is the test, rather than the input state alone, because input
that has grown a second line through `cooked-newline\=' has ordinary line starts
below the first -- the prompt is on the first row only, so on every row after
it column 0 already is the start of the command."
  (when (and cooked-beginning-of-line-skips-prompt (cooked--input-state-p))
    (when-let* ((start (cooked--input-start-position)))
      (and (<= (line-beginning-position) start (line-end-position)) start))))

(defun cooked-beginning-of-line (&optional n)
  "Move point to the start of the command being typed, not of the prompt.

With N, or from the input start already, this is `move-beginning-of-line\=' --
which makes the key comint\='s double-tap read the other way round: the first
press leaves the prompt behind, and a second from there goes on to column 0 for
anyone who wanted the line.  See `cooked-beginning-of-line-skips-prompt\='.

The interactive spec is `move-beginning-of-line\=''s own, `^\=' included, so
shift-selection extends from here exactly as it would from the command this
replaces."
  (interactive "^p")
  (let ((start (and (eql (or n 1) 1) (cooked--input-line-start))))
    (if (and start (> (point) start))
        (goto-char start)
      (move-beginning-of-line n))))

;; No evil state bindings here on purpose.
;;
;; RET reaches `cooked-send-input' through `cooked-input-map' in insert state, and in
;; normal state RET is `evil-ret', exactly as in any other buffer — the normal-state
;; special case was more surprising than useful.  `C-c C-c' needs nothing either: evil's
;; normal state does not bind `C-c', so it already falls through to the local map.

(defun cooked--cleanup ()
  "Tear down the session behind this buffer, and the files it generated.

On `kill-buffer-hook\='.  `cooked--stop-session\=' is the half shared with
`cooked--on-exit\='; the generated startup files are removed only here, since
they are named by a path the buffer holds and nothing else can reach them."
  (cooked--cancel-secret)
  (cooked--stop-session)
  (cooked--remove-scratch))

(defun cooked--live-buffers ()
  "Session buffers with a running child, most recent first."
  (let (found)
    (cooked--dolist-buffers
      (when cooked--session (push (current-buffer) found)))
    (nreverse found)))

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
      (cooked--refresh-keymap)
      (cooked--schedule-integration-hint buffer))
    buffer))

(provide 'cooked-mode)
;;; cooked-mode.el ends here
