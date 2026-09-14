;;; cooked-pending.el --- The input Emacs holds for the child -*- lexical-binding: t; -*-

;;; Commentary:

;; At a prompt Emacs owns the line: what the user types sits in the buffer as a
;; region between the process mark and `cooked--input-end', and is sent only when
;; it is submitted.  Every drain lifts that text out, rewrites the screen under it
;; and puts it back at the child's cursor.  This file is the region itself -- its
;; two ends, taking it out and putting it back, keeping point inside it before an
;; insertion, and throwing away undo history the rewrite has made untrue.
;;
;; It sits on cooked-screen.el, which says where the child's cursor is, and below
;; the drain pipeline and the commands that edit and submit the line.

;;; Code:

(require 'comint)
(require 'cooked-util)
(require 'cooked-state)
(require 'cooked-screen)

(defvar-local cooked--input-end nil
  "Marker after the pending input.

The far edge only.  The near edge is the buffer's process mark -- see
`cooked--input-mark' -- and this is the half comint has no counterpart for:
comint's input runs to `point-max', while cooked's has rendered screen rows
below it.")
(defvar-local cooked--undo-anchor nil
  "Where the pending input began when the undo history was last known good.
See `cooked--check-undo-anchor'.")
(defun cooked--input-mark ()
  "The marker where the pending input begins, or nil before a session.

This is the buffer\='s process mark, not a variable of our own.  comint\='s
entire command set navigates relative to `process-mark\=', so keeping the near
edge of the input region anywhere else is what made `comint-previous-input\='
answer \"Not at command line\" -- the mark it consults was one cooked never
maintained.  Storing it here rather than copying it into a private marker means
there is no second opinion to drift.

`cooked--wake\=' carries it.  The pipe is a doorbell the child rings and owns no
text, so its mark is free for this, and attaching it to the buffer is what
makes `get-buffer-process\=' answer at all.  The mark points nowhere whenever
the child owns the keyboard, so `cooked--input-region\=' is the guard callers
should go through."
  (and cooked--wake (process-mark cooked--wake)))

(defun cooked--set-input-mark (position)
  "Point the input mark at POSITION, or nowhere when POSITION is nil."
  (when-let* ((mark (cooked--input-mark)))
    (set-marker mark position)))

(defun cooked--clear-input-region ()
  "Forget the pending input region, leaving its text alone."
  (cooked--set-input-mark nil)
  (setq cooked--input-end nil))

(defun cooked--input-region ()
  "The pending input\='s bounds as (START . END), or nil when there is no region.

Both ends are set together by `cooked--restore-pending-input\=' and cleared
together by `cooked--clear-input-region\=', but either can also be left pointing
nowhere when its buffer text goes, so both have to be checked.  Callers that
want one end of a region that exists should take it from here rather than
repeating the pair of nil tests."
  (when-let* ((mark (cooked--input-mark))
              (start (marker-position mark))
              (end (and cooked--input-end (marker-position cooked--input-end))))
    (cons start end)))

(defun cooked--check-undo-anchor ()
  "Discard the undo history if the input line is no longer where it was.

Undo records exactly one thing in a cooked buffer: what the user has typed at
the prompt.  Everything else the buffer contains is written on the child\='s
behalf and kept out of the history by `cooked--with-child-edit\='.

What is left still has to be true, and undo entries name buffer positions.  Any
output at all rewrites the rows around the prompt and so moves the input line;
the entries recorded against the old position then describe screen text, which
undo would damage as readily as it would repair a typo.  The line\='s start is
therefore the whole validity condition -- while it holds still every entry
recorded against it is good, and the moment it moves they are worthless
together.

Cheap and idempotent by design, so every caller that can move the line calls it
without coordinating: the drain, `cooked--drain-and-apply\=' once more on the way
out in case the drain signalled partway, the two scrollback deletions, and
`cooked-refresh\='."
  (let ((start (cooked--input-start-position)))
    (unless (eql start cooked--undo-anchor)
      (setq cooked--undo-anchor start)
      (cooked--discard-undo))))

;; Read and assigned only under a guard that another package defined them, and
;; declared here so the byte-compiler reads those references as what they are
;; rather than as free variables; see `cooked--discard-undo'.
(defvar evil-undo-list-pointer)
(defvar undo-tree-mode)
(defvar buffer-undo-tree)

(defun cooked--discard-undo ()
  "Throw away the undo history, and everything else holding a piece of it.

`buffer-undo-list\=' is only the half of it, because undo is not a function of
the list alone.  A run of undos in progress is carried in `pending-undo-list\=',
a cons *inside* that list, and `undo-more\=' walks it without consulting the list
again; whether a run is in progress is decided by `last-command\=', which a drain
does not touch.  So: \\`u\=', a background job prints, and the next \\`u\=' undoes
conses describing text that has since moved -- in a buffer whose history is
supposedly empty, which is worse than the stale entries this was called to get
rid of.  Locally, because that variable is global: a drain runs from a process
filter, and clearing it outright would cut short an undo run in whatever other
buffer the user was actually in.

evil holds a cons of the list as well (`evil-undo-list-pointer\=', taken on
entering insert state so the whole insertion undoes as one step), and undo-tree
keeps a tree beside the list, treating the list as its staging area.  Neither
is ours to maintain and both are unreachable once the list they were taken from
is gone, so each is put back to the value its own package uses for nothing
recorded yet -- the state both are written to cope with, being the one they
start in.  Left alone they are a pointer into a list nobody holds any more and
a tree that goes on growing against positions that have moved.

Nothing at all where the user turned undo off themselves: nil would be
switching it back on for them, and there is nothing pointing into a list that
was never built."
  (unless (eq buffer-undo-list t)
    (setq buffer-undo-list nil)
    (setq-local pending-undo-list nil)
    (when (boundp 'evil-undo-list-pointer)
      (setq evil-undo-list-pointer nil))
    (when (bound-and-true-p undo-tree-mode)
      (setq buffer-undo-tree nil))))

(defun cooked--input-start-position ()
  "Where the pending input begins, or nil if there is no input region."
  (car (cooked--input-region)))

(defun cooked--pending-input ()
  "The text the user has typed but not yet submitted."
  (when-let* ((region (cooked--input-region)))
    (buffer-substring-no-properties (car region) (cdr region))))

(defun cooked--mark-pasted (text)
  "TEXT with every character marked as having arrived by paste.

The mark is the `cooked-pasted\=' text property, and what reads it is
`cooked--strip-pasted-controls\=', which strips control bytes from marked text
only.  That is where a terminal draws the line: xterm\='s
`disallowedPasteControls\=' filters what was pasted and never what was typed, so
an ESC yanked into the line goes to the shell as a space while one typed with
\\[quoted-insert] goes as ESC.

Buffer-locally on `yank-transform-functions\=', which sees every string
`insert-for-yank\=' inserts: `yank\=', `yank-pop\=', evil\='s paste commands, the
`xterm-paste\=' a terminal frame delivers, and `mouse-yank-primary\='.  A drop
and a history entry are marked where they are inserted.  Two insertions go
unmarked: an evil block paste, whose handler inserts its own copy of the lines,
and any yank under a `yank-excluded-properties\=' of t, which removes every
property from the text, this one included."
  (propertize text 'cooked-pasted t))

(defun cooked--input-substring (start end)
  "The text between START and END, keeping only the paste mark.

The drain lifts the pending input out and puts it back on every redraw, and
submitting or delegating the line reads it once more.  Each of those has to keep
`cooked-pasted\=' or a yanked ESC is typing again by the time it is sent, and
none should keep anything else: a face or a link property left over from the
row the line sits on is the screen\='s, not the line\='s."
  (let ((text (buffer-substring-no-properties start end))
        (from start))
    (while (< from end)
      (let ((to (next-single-property-change from 'cooked-pasted nil end)))
        (when (get-text-property from 'cooked-pasted)
          (put-text-property (- from start) (- to start) 'cooked-pasted t text))
        (setq from to)))
    text))

(defvar cooked-input-syntax-table)      ; cooked-mode.el, with the buffer's own.

(defun cooked--mark-input-syntax ()
  "Give the pending input the prompt\='s word syntax.

The buffer\='s own table, `cooked-mode-syntax-table\=', makes `?#@&+=\=' word
constituents for the output, so a double-click takes `simon@example.com\=' whole.
At the prompt that same table made \\[backward-kill-word] after
`git log --author=simon\=' kill the whole flag where a shell\='s line editor
kills `simon\='.  So the input region carries `cooked-input-syntax-table\=' as a
`syntax-table\=' property, which `parse-sexp-lookup-properties\=' makes every
word motion and every syntax-aware regexp honour.

Put back from three places, because each of them can leave text in the region
without it.  `cooked--restore-pending-input\=' re-creates the region on every
drain, `cooked--replace-input\=' fills it from history, and
`cooked--mark-input-syntax-before-command\=' covers whatever the last command
inserted: a character typed at the very start of the line inherits nothing, and
a yank inherits nothing anywhere."
  (when-let* ((region (cooked--input-region)))
    (when (< (car region) (cdr region))
      (with-silent-modifications
        (put-text-property (car region) (cdr region)
                           'syntax-table cooked-input-syntax-table)))))

(defun cooked--mark-input-syntax-before-command ()
  "Run `cooked--mark-input-syntax\=' before a command reads the words.
On `pre-command-hook\=', so \\[backward-kill-word] or evil\='s `dw\=' sees the
narrow words over the text the previous command typed."
  (cooked--protect-hook
    (cooked--mark-input-syntax)))

(defvar cooked-snap-commands
  '(self-insert-command
    cooked-newline newline newline-and-indent
    yank yank-pop cooked-paste cooked-xterm-paste cooked-evil-paste
    evil-paste-before evil-paste-after evil-paste-from-register)
  "Commands that should act on the input region even if point drifted out of it.
See `cooked--snap-to-input'.

Plain `newline' is here because `evil-collection' binds S-RET to it directly
rather than to `cooked-newline', so it needs the same protection.

A remap would need its target named here too, and that is easy to miss: this
list is matched against `this-command', and a remap replaces `this-command'
outright rather than layering over it.  A `self-insert-command' remap once took
every ordinary keystroke out of this list, and what broke was not the feature
the remap was added for but the snap -- typing on the blank line below the
prompt silently landed outside the input markers again.  There is no such remap
now, and `cooked--guard-insertion' substitutes rather than remaps for exactly
this reason.

This list has a second reader, and adding to it now buys two things rather than
one.  `cooked--guard-insertion' keys the point-of-use termios sample off it, on
the reasoning that \"commands that act on the input region\" and \"commands that
could insert under a mode the child has already left\" are the same set -- so a
new insertion path is guarded by joining the list it had to join anyway.  Keep
it that way: a command that inserts and is left out of this list loses the snap
and the sample together, and the second failure is a password in the buffer
rather than a misplaced character.")

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
  (cooked--protect-hook
    (when (and (memq this-command cooked-snap-commands)
               (cooked--input-state-p))
      (when-let* ((region (cooked--input-region)))
        (cond ((< (point) (car region)) (goto-char (car region)))
              ((> (point) (cdr region)) (goto-char (cdr region))))))))

(defun cooked--take-pending-input ()
  "Remove the pending input from the buffer and return it.
The paste mark comes with it; see `cooked--input-substring\='."
  (when-let* ((region (cooked--input-region))
              (text (cooked--input-substring (car region) (cdr region))))
    (delete-region (car region) (cdr region))
    text))

(defun cooked--restore-pending-input (text)
  "Re-insert TEXT at the cursor, re-establishing the input region.

The near edge goes on the process mark, whose insertion type stays nil so that
typing at the very start of the prompt lands inside the region rather than
pushing it along."
  (when (cooked--input-state-p)
    (save-excursion
      (goto-char (cooked--cursor-position))
      (cooked--set-input-mark (point))
      ;; comint brackets the last input with `comint-last-input-start'/`-end'.  The near
      ;; edge is this same position -- the OSC 133 `prompt-end' anchor names the row, but
      ;; only the input mark knows the column the prompt actually ended at.
      ;;
      ;; Re-set on every drain, and it has to be: this marker sits mid-row, and
      ;; `cooked--render-rows' deletes a damaged row from its start to end of line, so
      ;; anything inside collapses to the row's beginning.  `comint-last-input-end' does
      ;; not have the problem, sitting at the start of the output row -- a row boundary,
      ;; which survives -- and it is the one comint's output family actually measures
      ;; from.  `comint-last-input-start' is read only by `comint-output-filter's
      ;; echo suppression, which is comint's insertion path and never runs here.  If that
      ;; ever changes, this marker needs a cell rather than a position behind it.
      (set-marker comint-last-input-start (point))
      (when text (insert text))
      (setq cooked--input-end (copy-marker (point) t))
      (cooked--mark-input-syntax))))

(defun cooked--point-after-input ()
  "Where point belongs after a redisplay."
  (or (and cooked--input-end (marker-position cooked--input-end))
      (cooked--cursor-position)))

(provide 'cooked-pending)
;;; cooked-pending.el ends here
