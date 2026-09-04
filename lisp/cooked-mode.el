;;; cooked-mode.el --- Interaction for cooked terminals -*- lexical-binding: t; -*-

;;; Commentary:

;; The interactive half of cooked: which keymap the buffer wears when, input
;; submission, history, and the mode itself.  Five things that used to live here
;; have their own files, each named for what it is -- cooked-keys.el,
;; cooked-completion.el, cooked-secret.el, cooked-shell-integration.el and
;; cooked-mode-line.el -- and the command records everything here navigates by
;; are cooked-command.el.  See cooked.el, the main file, for what this is and
;; how to install it.
;;
;; Key encoding and the keymaps themselves are cooked-keys.el's: it says what a
;; key becomes and builds the maps, this file says which map is installed and
;; when.  `cooked--refresh-keymap' is the join.

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
(require 'cooked-render)
(require 'cooked-scrollback)
(require 'cooked-keys)
(require 'cooked-completion)
(require 'cooked-mouse)
(require 'cooked-shell-integration)
(require 'cooked-mode-line)
(require 'cooked-secret)
(require 'comint)

;; Defined by the native core at `module-load' time, so the byte-compiler cannot
;; see them; cooked.el declares the same set for its own use.
(declare-function cooked--send "ext:cooked-core")
(declare-function cooked--sample-mode "ext:cooked-core")
(declare-function cooked--set-attended "ext:cooked-core")
(declare-function cooked--resize "ext:cooked-core")
(declare-function cooked--cell-size "cooked-deco")
(declare-function cooked--signal "ext:cooked-core")
(declare-function cooked--prompt-text "ext:cooked-core")
(declare-function cooked--bracketed-paste-p "ext:cooked-core")
(declare-function cooked--focus-events-p "ext:cooked-core")
(declare-function cooked--live-p "ext:cooked-core")
(declare-function cooked--foreground-pid "ext:cooked-core")
(declare-function cooked--pid "ext:cooked-core")
(declare-function cooked--kill "ext:cooked-core")

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

;;;; Where point is while the child has the keyboard
;;
;; Two halves of one idea, and the reason they are here rather than in
;; cooked-keys.el: neither is about what a key means, both are about the buffer
;; the key is pressed in.  A command may move point off the cell the child is
;; drawing its cursor on, and the ghost cursor keeps saying where that cell is;
;; then the next key sent puts point back, because the child was always going to
;; act at its own cursor whatever Emacs was showing.

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

(declare-function cooked--job-control "ext:cooked-core")
(declare-function cooked--remove-rows "ext:cooked-core")

(defun cooked--send-job-control (session key signal)
  "Ask SESSION for job control the way a terminal does.

KEY is `:intr\=', `:quit\=' or `:susp\='.  A terminal sends no signal of its own:
it writes the character the tty has in `c_cc\=' and lets the line discipline
decide.  Reading that character rather than assuming ^C/^\\/^Z is what makes
`stty intr ^X\=' work, and honouring ISIG is what keeps a program that
deliberately cleared it -- so as to read the byte itself -- from being
signalled behind its own back.

SIGNAL is the fallback, for the two cases where writing cannot mean anything:
ISIG is off, so no byte would be turned into one; or the character is disabled
\=(`_POSIX_VDISABLE\='), so there is no byte to write.  It names the signal
rather than numbering it, because the numbers are not the same everywhere:
SIGTSTP is 20 on Linux and 18 on the BSDs, where 20 is SIGCHLD.  Written as
numbers here they were Linux\='s, so on macOS the suspend fallback sent a
SIGCHLD the child ignores -- the whole of why \\[cooked-suspend] did nothing to
a program that had cleared ISIG.  The core links libc and can see which
platform it is; this side cannot, so this side spells the name."
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
  (cooked--send-job-control (cooked--require-session) :susp 'sigtstp))

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
    (cooked--send-job-control session :quit 'sigquit)))

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
    (cooked--send-job-control session :intr 'sigint)))

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
`fg\='.

Named rather than numbered for the reason `cooked--send-job-control\=' is, and
this was the worse of the two: 18 is SIGCONT on Linux and SIGTSTP on the BSDs,
so on macOS the continue stopped the job it was asked to restart."
  (interactive)
  (cooked--signal (cooked--require-session) 'sigcont))

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
              ;; Both margins to zero, as eat and vterm also set them.  A
              ;; terminal's viewport is the whole window: the child decides what
              ;; is on the bottom row and there is nothing below it to keep in
              ;; reserve, so a margin only puts redisplay in disagreement with
              ;; `cooked--pin-transcript-bottom' about where the start belongs
              ;; -- redisplay enforcing the margin against the start the pin
              ;; just computed, once per drain.
              scroll-margin 0
              hscroll-margin 0
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
