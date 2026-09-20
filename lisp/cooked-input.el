;;; cooked-input.el --- Editing, submitting and interrupting the line -*- lexical-binding: t; -*-

;;; Commentary:

;; The commands a user runs against the line: submitting the pending input,
;; composing a multi-line one, walking the history, sending EOF, and the job
;; control keys that write the tty's own characters.  Where Emacs owns the line
;; they edit the pending input; where the child does, most of them forward the
;; key a terminal would have sent.
;;
;; It sits on the key encoding and on peek, which every command writing out of
;; band resumes first, and is bound by the maps in cooked-keymaps.el.

;;; Code:

(require 'comint)
(require 'cooked-util)
(require 'cooked-state)
(require 'cooked-command)
(require 'cooked-pending)
(require 'cooked-cursor)
(require 'cooked-peek)
(require 'cooked-keys)

(cooked--declare-core)

(defvar-local cooked--history-stash nil
  "Input set aside while browsing history.
The one piece of history state that is cooked's: the ring, and the position in
it, are `comint-input-ring' and `comint-input-ring-index'.")

(defun cooked-send-input ()
  "Submit the pending input to the child.
The kernel echoes it back, so the emulator renders the line, not us.

Enter is sent as CR, which is what a terminal actually transmits: in canonical
mode `ICRNL' turns it into the newline the child expects, and in raw mode it is
what a shell's line editor is bound to.  Sending LF works for readline but not
for ZLE."
  (interactive)
  ;; Stripped here rather than left to `cooked--send-input-string', so the
  ;; history records the line the shell was sent: recalling it later gives back
  ;; the spaces a pasted ESC became, not an ESC that would now count as typed.
  (let ((text (cooked--strip-pasted-controls
               (if-let* ((region (cooked--input-region)))
                   (cooked--input-substring (car region) (cdr region))
                 ""))))
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
`cooked-line-prompt-continued'.

TEXT goes through `cooked--strip-pasted-controls' first, which strips control
bytes from the parts of it that were pasted, for the same reason a paste to the
child is stripped.  The input region holds whatever was yanked into it, so a
kill of \"ls ESC [ A\" would otherwise reach the shell as keystrokes on RET,
and an interrupt character in it would kill the line it was part of.  What the
user typed is sent as typed, so an ESC entered with \\[quoted-insert] still
reaches the shell as ESC.  A plain string, such as `comint-input-sender' hands
over, has no pasted parts and is sent unchanged.  This has to run over TEXT
before `cooked--send-line' ever sees it: a yank into the input region can
carry a literal `ESC [ 201 ~', the bracket's own end marker, and the core
cannot tell a pasted part from a typed one, having no text property to read.

The rest -- whether TEXT is bracketed, and the framing itself -- is
`cooked--send-line's, made together against the mode the child holds at the
moment of the write.  Composing it here instead, the way this used to, read
the mode with `cooked--bracketed-paste-p' and wrote the bytes as two later
calls, with the child free to change the mode in between."
  (setq text (cooked--strip-pasted-controls text))
  (let ((record (cooked--line)))
    (setf (cooked-line-submitted-input record)
          (let ((line (and (not (string-blank-p text)) text))
                (submitted (cooked-line-submitted-input record)))
            (if (and (cooked-line-prompt-continued record) submitted
                     ;; A continuation continues *something*.  Without this the flag
                     ;; has no path that clears it when the `A' and the `C' it expects
                     ;; never arrive -- a shell emitting `A;k=s' with the plain marks
                     ;; turned off does exactly that -- and every later line would be
                     ;; appended to the last, growing one record's input without bound.
                     cooked--prompt-start)
                (concat submitted "\n" (or line ""))
              line))))
  (cooked--send-line (cooked--require-session) text))

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
;; ring persistence, and the isearch that `comint-mode' installs.
;;
;; The *editing* stays cooked's, and that asymmetry is deliberate.
;; `comint-goto-input' deletes from the process mark to `point-max' on the
;; assumption that input is the last thing in the buffer, which is exactly the
;; assumption cooked breaks: there are rendered screen rows below the prompt, so
;; comint's own recall would take them with it.  `cooked--replace-input' works
;; between the two ends of the region instead -- see `cooked--input-end', which
;; is the half comint has no counterpart for.

(defun cooked--replace-input (text)
  "Replace the pending input with TEXT.
The prompt's word syntax goes on the new text at once; see
`cooked--mark-input-syntax'."
  (when-let* ((region (cooked--input-region)))
    (let ((inhibit-read-only t))
      (delete-region (car region) (cdr region))
      (save-excursion
        (goto-char (car region))
        (insert text)))
    (cooked--mark-input-syntax)
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
    ;; With the paste mark, so a yanked ESC put aside and handed back is still
    ;; stripped when the line is submitted.
    (setq cooked--history-stash
          (if-let* ((region (cooked--input-region)))
              (cooked--input-substring (car region) (cdr region))
            "")))
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
  (dotimes (_ (max 1 n)) (cooked--send-key-event key)))

(defun cooked-previous-input (&optional n)
  "Recall the Nth previous input.

At a prompt this is Emacs' own history, editing the pending line in the buffer.
Everywhere else the child is the one with a history, and this forwards \\`<up>'
to it -- which is what the key would have done in any terminal, and what it has
to do here: `evil-collection-comint' binds the arrow keys for insert state on
an auxiliary keymap that outranks the local map, so without this they reach
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

Read rather than assumed, for the reason `cooked--send-job-control' reads the
others: `stty eof ^X' is a thing people do.  Deliberately not routed through
that function, whose shape is \"the character if ISIG, else the signal\" --
neither half applies here.  EOF is not a signal, so there is nothing to fall
back to, and `ISIG' does not govern it: `ICANON' decides whether the line
discipline turns the byte into end-of-input, and a raw-mode program just reads
it.  Either way the byte is what a terminal sends.

`?\\C-d' when the character is disabled (`_POSIX_VDISABLE'), which is the one
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

(defconst cooked--job-control-keys
  '((:intr . ?\C-c) (:quit . ?\C-\\) (:susp . ?\C-z))
  "The key a keyboard has for each job-control character, by convention.

What `cooked--send-job-control' presses when the child has cleared ISIG.  The
tty's own `c_cc' is not consulted for that case: with ISIG off the line
discipline gives those characters no meaning, so the only meaning left is the
one the program reading the keyboard gives the key, and the key is this one.")

(defun cooked--send-job-control (session key signal)
  "Ask SESSION for job control the way a terminal does.

KEY is `:intr', `:quit' or `:susp'.  A terminal sends no signal of its own:
it writes the character the tty has in `c_cc' and lets the line discipline
decide.  Reading that character rather than assuming ^C/^\\/^Z is what makes
`stty intr ^X' work.

With ISIG off the line discipline decides nothing, and the child is a program
that cleared it so as to read the key itself.  It gets the key, from
`cooked--job-control-keys' and through `cooked--send-key-event', so that a child
which negotiated the kitty keyboard protocol reads it spelled that way.  This
branch used to send SIGNAL instead, which is precisely the signalling behind a
program's back that honouring ISIG exists to prevent, and it was not harmless.
A full-screen program that handles ^Z leaves raw mode, stops itself, and
re-enters raw mode on SIGCONT.  Stopped from outside it does none of that: the
shell restores its own termios when the job is resumed with `fg', the program
still believes the tty is raw, and from then on the kernel echoes every
keystroke and every focus report onto its screen.

SIGNAL is the fallback for the one case where there is nothing to write: ISIG
is on but the character is disabled (`_POSIX_VDISABLE').  It names the signal
rather than numbering it, because the numbers are not the same everywhere:
SIGTSTP is 20 on Linux and 18 on the BSDs, where 20 is SIGCHLD.  Written as
numbers here they were Linux's, so on macOS the suspend fallback sent a
SIGCHLD the child ignores.  The core links libc and can see which platform it
is; this side cannot, so this side spells the name."
  (let* ((jc (cooked--job-control session))
         (char (plist-get jc key)))
    (cond
     ((not (plist-get jc :isig))
      (let ((press (alist-get key cooked--job-control-keys)))
        (unless (cooked--send-key-event press)
          (cooked--send-to-child (string press)))))
     (char (cooked--send-to-child (string char)))
     (t (cooked--signal session signal)))))

(defun cooked-suspend ()
  "Suspend the foreground command.
Ends peek first when peeking, so the effect is seen right away rather than
held behind the freeze."
  (interactive)
  (cooked--resume-forwarding)
  (cooked--send-job-control (cooked--require-session) :susp 'sigtstp))

(defun cooked-quit ()
  "Quit the foreground command -- SIGQUIT, the harder sibling of \\[cooked-interrupt].

Sent the way a terminal sends it; see `cooked--send-job-control'.  Bound where
comint puts it, on \\`C-c C-\\\\', whose own `comint-quit-subjob' would
`quit-process' the wakeup pipe -- the only process this buffer has, and not the
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
`cooked--send-job-control': there is no tty character for this and no line
discipline to turn one into anything, so a signal is not the fallback here --
it is the only thing this could ever have been.  Written as one directly, so
the shape of the code says which kind of thing it is.

Where comint puts `comint-kill-subjob', which cannot be inherited: it calls
`kill-process' on the buffer's process, and this buffer's process is
`cooked--wake', the pipe the child rings when output is pending.  Left alone,
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
tty carries `intr', `quit' and `susp' in `c_cc' and nothing else, so
`cooked-interrupt', `cooked-quit' and `cooked-suspend' each have a byte to
write and this has none.  What resumes a stopped job is the shell's own `fg',
a piece of bookkeeping the terminal is not party to -- its part ended when it
wrote the `susp' character.

It exists because comint's `comint-continue-subjob' is inherited, and
inherited it calls `continue-process' on `cooked--wake'.  The remap is the
point of this function; anyone reaching for it directly almost certainly wants
`fg'.

Named rather than numbered for the reason `cooked--send-job-control' is, and
this was the worse of the two: 18 is SIGCONT on Linux and SIGTSTP on the BSDs,
so on macOS the continue stopped the job it was asked to restart."
  (interactive)
  (cooked--signal (cooked--require-session) 'sigcont))

(defun cooked-kill-input ()
  "Delete the pending input."
  (interactive)
  (when-let* ((region (cooked--input-region)))
    (delete-region (car region) (cdr region))))

(defcustom cooked-beginning-of-line-skips-prompt t
  "Whether a start-of-line motion stops at the command rather than the prompt.

Column 0 of the prompt row is inside the prompt, which is the child's text and
carries `read-only': a motion landing there has found the start of a *line*
and not the start of anything the user may edit, so the keystroke after it
either signals or is thrown away by `cooked--snap-to-input'.  The useful
position is where the pending input begins, and `cooked--input-start-position'
knows it exactly -- taken from the cursor cell at each drain, so it holds with
no shell integration at all and for a prompt that ends mid-row, neither of
which a line-oriented answer can manage.

A deliberate divergence, this.  comint has the same position and binds it to
\\`C-c C-a' (`comint-bol-or-process-mark'), leaving \\`C-a' at true column 0;
`eat' inherits that unchanged.  The argument for keeping the literal motion
reachable is a good one and it is kept -- pressing the key again from the input
start goes on to column 0, and evil's \\`0' and \\`gI' are left stock.  What
is not kept is which of the two the unmodified key gets, because in a terminal
the prompt is never a destination: it is not editable, not selectable as input,
and not where any subsequent command wants to act.

One knob for all of them: \\[cooked-beginning-of-line] and, where `cooked-evil'
is loaded, \\`^' and \\`I'.  Nil restores the stock behaviour of each."
  :type 'boolean :group 'cooked)

(defun cooked--input-line-start ()
  "Where the pending input begins, if point is on the line it begins on.

Nil everywhere else, which is how scrollback, a full-screen program's screen
and a session that has died all fall through to the stock command instead of
being dragged to a prompt that is elsewhere in the buffer.

Point's own line is the test, rather than the input state alone, because input
that has grown a second line through `cooked-newline' has ordinary line starts
below the first -- the prompt is on the first row only, so on every row after
it column 0 already is the start of the command."
  (when (and cooked-beginning-of-line-skips-prompt (cooked--input-state-p))
    (when-let* ((start (cooked--input-start-position)))
      (and (<= (line-beginning-position) start (line-end-position)) start))))

(defun cooked-beginning-of-line (&optional n)
  "Move point to the start of the command being typed, not of the prompt.

With N, or from the input start already, this is `move-beginning-of-line' --
which makes the key comint's double-tap read the other way round: the first
press leaves the prompt behind, and a second from there goes on to column 0 for
anyone who wanted the line.  See `cooked-beginning-of-line-skips-prompt'.

The interactive spec is `move-beginning-of-line''s own, `^' included, so
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

(provide 'cooked-input)
;;; cooked-input.el ends here
