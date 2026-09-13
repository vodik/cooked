;;; cooked.el --- A terminal that hands the keyboard back -*- lexical-binding: t; -*-

;; Author: Simon Gomizelj <simongmzlj@gmail.com>
;; Version: 1.0.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: terminals, processes
;; URL: https://github.com/vodik/cooked

;;; Commentary:

;; A terminal emulator whose input model follows what the child actually wants.
;; The kernel's line discipline says when a program is doing a canonical read;
;; OSC 133 says when the shell is at a prompt.  In either case Emacs owns the
;; line and you edit it as you would any buffer.  Otherwise keys are forwarded
;; verbatim and the emulator behaves as a terminal.
;;
;;   (use-package cooked
;;     :load-path "/path/to/cooked/lisp"
;;     :commands (cooked cooked-other-window
;;                cooked-project cooked-project-other-window
;;                cooked-here cooked-here-other-window)
;;     :custom (cooked-buffer-name "*cooked: %p*")
;;     :config
;;     (require 'cooked-evil)             ; opt in to evil state syncing
;;     (require 'cooked-osc-eval)         ; opt in to the OSC 51 command channel
;;     (require 'cooked-shell-completion) ; opt in to the shell's own completion
;;     (require 'cooked-project))         ; opt in to project-scoped sessions
;;
;; Emulation happens in a Rust module, built on first use with cargo.
;;
;; This file is the core: rendering, colours, and the OSC handlers that are inert
;; enough to be on by default.  `cooked-mode' has the interaction.  The layers above
;; it are separate because you should choose them, and choosing one is `require'ing
;; its file rather than setting a variable: `cooked-evil', `cooked-osc-eval',
;; `cooked-shell-completion', `cooked-project', `cooked-file-link',
;; `cooked-next-error', `cooked-command-decorations', `cooked-dnd' and
;; `cooked-user-var'.  The snippet above names only the four most people want; the
;; other five load the same way.

;; The buffer is the scrollback.  Rows that scroll off the emulator's screen are
;; handed over once and become ordinary buffer text; the lines after
;; `cooked--screen-start' are the live screen, rewritten from damage reports.
;;
;; Invariant: buffer text equals the grid, plus any pending input rendered at the
;; cursor.  Every redisplay lifts the pending input out, applies the grid, and puts
;; it back.
;;
;; The two ends therefore hold one structure between them, and the boundary is the
;; only place they can disagree.  So the geometry of it is reported rather than
;; re-derived: `cooked--grid' carries the emulator's own account of how tall the
;; grid is, how much of it is occupied, and how much of the line straddling the
;; boundary has already been handed over.  Emacs owns the buffer and makes every
;; edit; it just does not get a second opinion about the shape it is editing to.
;; `cooked--check-seam' is that boundary stated as an assertion.

;;; Code:

(require 'cl-lib)
(require 'jit-lock)
(require 'comint)
(require 'face-remap)
(require 'cooked-util)
(require 'cooked-state)
(require 'cooked-screen)
(require 'cooked-module)
(require 'cooked-command)
(require 'cooked-face)
(require 'cooked-deco)
(require 'cooked-link)

(cooked--declare-core)

;; `cooked-osc.el' requires this file, so what this file needs of it is declared
;; rather than required -- the same shape, and for the same reason, as the calls
;; upward into cooked-mode.el listed below.  Both are notifications: something
;; happened, and the layer that owns the meaning should react.
(declare-function cooked--sync-color-scheme "cooked-osc")

;; Everything this file calls in the layers above it, which is to say everything
;; it calls upward.  Each one is a notification that something changed and the
;; layer that owns keymaps, buffer names or the buffer's own life should react —
;; never a question asked of that layer, which is why the list is short and stays
;; short.  Anything cooked.el needs an *answer* to belongs at this level instead;
;; see "Who owns the keyboard" below, which is where that rule moved the policy.
;;
;; `cooked--on-wake' is owned by cooked-render.el and is the same shape read from
;; the other end: `cooked--start' installs the wake pipe's filter because the
;; pipe is part of spawning a child, and the filter's whole body is "the core has
;; something; draw it" -- a notification handed to the pipeline, not a question
;; put to it.  It is the only thing this file needs of that one.
(declare-function cooked--refresh-keymap "cooked-mode")
(declare-function cooked--update-mouse-grab "cooked-mouse")
(declare-function cooked--defer "cooked-mode")
(declare-function cooked--update-buffer-name "cooked-mode")
(declare-function cooked--on-wake "cooked-render")
(defvar cooked-rejoin-wrapped-lines)
(defvar cooked--last-size)

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

(defvar cooked-snap-commands
  '(self-insert-command
    cooked-newline newline newline-and-indent
    yank yank-pop cooked-paste cooked-evil-paste
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
  "Remove the pending input from the buffer and return it."
  (when-let* ((region (cooked--input-region))
              (text (buffer-substring-no-properties (car region) (cdr region))))
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
      (setq cooked--input-end (copy-marker (point) t)))))

(defun cooked--point-after-input ()
  "Where point belongs after a redisplay."
  (or (and cooked--input-end (marker-position cooked--input-end))
      (cooked--cursor-position)))

(defun cooked--register-mark (id at batch-start)
  "A marker at ANCHOR AT, remembered under mark id ID.

The one place a semantic mark becomes a buffer position, so the one place that
position can be registered for a later resize to correct.  Falls through to a
plain marker when the emulator gave no id, which no live core does -- the guard
is for a `cooked-mode' buffer driven from Lisp by a test."
  (let ((marker (copy-marker (cooked--anchor-position at batch-start))))
    (when id
      (unless cooked--marks
        (setq cooked--marks (make-hash-table :test #'eql)))
      (puthash id marker cooked--marks))
    marker))

(defun cooked--relocate-marks (marks batch-start)
  "Move the markers MARKS names, each `(ID . ANCHOR)', to where the mark now is.

BATCH-START is where this drain's scrollback landed, for a `scrolled' anchor.

The repair for a resize, and the reason the emulator carries a mark on a cell at
all.  A scroll never needs it: rows leave the top of the grid and the text above
them in the buffer grows by exactly what left, so a live buffer position means
what it did.  A rewrap re-lays every logical line at the new width and Emacs
rebuilds every live row from it, and then nothing about the old positions holds
-- so `Delta::marks' reports where each mark ended up and this moves the marker
to meet it.

Because the records share these marker objects rather than copying them, moving
one here fixes every consumer at once: `cooked--command-region' and so
`next-error' and evil's command text objects, `cooked--prompt-starts' and so
`cooked-previous-command', `cooked--command-around' and so sticky scroll, and
the fringe marker per command that made the drift visible.

Before the events of the same drain, not after: a resize and a fresh mark can
land in one drain, and there the event's own anchor is the newer statement."
  (when (and marks cooked--marks)
    (pcase-dolist (`(,id . ,at) marks)
      (when-let* ((marker (gethash id cooked--marks)))
        (set-marker marker (cooked--anchor-position at batch-start))))))

(defun cooked--handle-semantic (event batch-start)
  "Track OSC 133 EVENT and the buffer markers that come with it.

Each mark carries an anchor saying where in the output it actually fell, which
`cooked--anchor-position' turns into a buffer position given BATCH-START, this
drain's scrollback insertion point.  The cursor is emphatically not a
substitute: by the time a drain is applied it is where the *last* thing in that
drain left it, so a script running several commands between two redisplays
would file all of their output under one region ending wherever it stopped.

Each mark also carries an id, which is how it goes on being placeable after the
anchor stops being true: `cooked--register-mark' files the marker under it and
`cooked--relocate-marks' moves it when a resize rewraps the grid.  The `.  ,id'
tails rather than a fourth pattern element so that a `cooked-mode' buffer driven
from Lisp -- which is to say a test -- can still hand these events over in their
older three-element shape."
  (setq cooked--semantic-seen t)
  (pcase event
    (`(prompt-start ,at . ,id)
     (setq cooked--semantic 'prompt
           ;; A fresh prompt is a fresh line, and Emacs may have it back.
           cooked--delegated nil
           ;; Where the prompt is about to be drawn, which is what
           ;; `cooked-previous-command' moves between and where the outer half of
           ;; an `evil' command text object starts.  The mark arrives before the
           ;; prompt itself, so this is column 0 of its first row.
           cooked--prompt-start (cooked--register-mark (car id) at batch-start)
           ;; Whatever was being continued is over: this prompt is a new line.
           cooked--prompt-continued nil))
    ;; A continuation prompt -- `PS2' -- is the same command still being typed.  It
    ;; deliberately does *not* touch `cooked--prompt-start': that marker is where the
    ;; construct began, which is what the command record is filed under and what
    ;; `cooked-previous-command' lands on.  Moving it here would start the record at
    ;; the last continuation line.  The `B' that follows still arrives, so Emacs owns
    ;; the continuation line exactly as it owns the first one.
    (`(prompt-continuation ,_ . ,_)
     (setq cooked--semantic 'prompt
           ;; A fresh line, whoever it continues, and Emacs may have it back.
           cooked--delegated nil
           cooked--prompt-continued t))
    (`(prompt-end ,_ . ,_)
     (setq cooked--semantic 'input)
     (cooked--refresh-keymap))
    ;; A second `C' with no prompt since the first is ignored, rather than moving the
    ;; start of the output region down to it.  Two shells both emitting the marks --
    ;; the `no-marks' negotiation exists to prevent exactly this, and says nothing
    ;; about what happens when it fails -- would otherwise file the command's output
    ;; from the later mark, losing whatever fell between them, and attribute the exit
    ;; code the first mark opened the record for to a region it does not describe.
    ;; `cooked--prompt-start' is the test rather than a counter of our own: it is set
    ;; by every `A' and cleared by the `C' that consumes it, so nil here means no
    ;; prompt has begun since a command started.  A shell that drops its `D' therefore
    ;; still recovers at its next prompt instead of never opening a record again.
    (`(command-start ,cmdline ,at . ,id)
     ;; Nothing at all for the duplicate, not even a marker: the id names a mark no
     ;; record will hold, so registering it would only put an entry in
     ;; `cooked--marks' for a resize to move on nobody's behalf.
     (unless (and cooked--command-start (marker-position cooked--command-start)
                  (null cooked--prompt-start))
       (let* ((marker (cooked--register-mark (car id) at batch-start))
              (start (marker-position marker)))
         (setq cooked--semantic 'output
               ;; The announcement covered the line that just ended.  Anything the
               ;; command spawns -- an `ssh', a nested shell, a REPL -- announces
               ;; for itself or does not announce at all.
               cooked--completion-nonce nil
               cooked--completion-reply-capable nil
               ;; The delegated line has been submitted; it was the shell's, and
               ;; now it is neither's.
               cooked--delegated nil
               cooked--command-start marker
               cooked--command-started-at (float-time)
               ;; What the shell said it was about to run, and only failing that what
               ;; we last submitted.  The shell's account wins where both exist: ours
               ;; is the text Emacs *sent*, glued together across the lines of a
               ;; multi-line construct by `cooked--send-input-string', while the
               ;; shell's is what its parser actually made of it.  And it is the only
               ;; account at all in every case where the shell kept the line -- a
               ;; remote prompt, a program reading input of its own, a `no-input-mark'
               ;; session -- where `cooked--submitted-input' is nil and the record
               ;; used to carry nothing.  See `State::cmdline' on the Rust side.
               cooked--command-input (or cmdline
                                         (prog1 cooked--submitted-input
                                           (setq cooked--submitted-input nil)))
               cooked--submitted-input nil
               ;; The prompt this was typed at stops being the live one here, and
               ;; becomes the running command's.
               cooked--command-prompt (prog1 cooked--prompt-start
                                        (setq cooked--prompt-start nil))
               ;; The construct has been submitted in full; the next line submitted
               ;; starts a command of its own.
               cooked--prompt-continued nil)
         ;; Output begins here, so this is where the input ended.  `comint-delete-output',
         ;; `comint-show-output' and `comint-write-output' all measure from it; it sat at
         ;; `point-min' until now, which is why deleting output flushed the whole buffer.
         (set-marker comint-last-input-end start)
         (set-marker comint-last-output-start start)
         (run-hook-with-args 'cooked-command-started-functions
                             (cooked--running-anchor)))
       (cooked--refresh-keymap)))
    (`(command-end ,code ,at . ,id)
     (setq cooked--semantic nil)
     (cooked--mark-command-end code (cooked--register-mark (car id) at batch-start)))))

;;;; The child's cursor, while Emacs has wandered off it

(defcustom cooked-cursor-shapes
  '((block . t) (underline . hbar) (bar . (bar . 2)))
  "How DECSCUSR shapes map onto `cursor-type'.

The child names a shape with `CSI Ps SP q'; vim and fish's vi-mode use it to
show which mode they are in.  Only the shape is honoured — DECSCUSR also
distinguishes blinking from steady, and whether your cursor blinks is
`blink-cursor-mode', which is yours to set and not the child's."
  :type '(alist :key-type symbol :value-type sexp)
  :group 'cooked)

(defun cooked--cursor-type ()
  "The `cursor-type' for the shape the child last asked for."
  (alist-get (cooked-cursor-shape cooked--cursor) cooked-cursor-shapes t))

;; The ghost cursor below deliberately does not follow the shape.  It is hollow to
;; say "not receiving your keystrokes", and that reading comes from the hollowness
;; rather than from the outline — Emacs has no meaningful hollow bar to draw anyway.

(defface cooked-ghost-cursor
  '((t :box (:line-width (-1 . -1))))
  "Face marking where the child's cursor is while point is somewhere else.

Drawn hollow on purpose.  A terminal draws its cursor hollow when the window
is unfocused, so the shape already reads as \"this cursor is not receiving
your keystrokes\" — which is exactly what is true of the child's cursor while
you are navigating with Emacs' own motions."
  :group 'cooked)

(defvar-local cooked--ghost-cursor nil
  "Overlay drawing the child's cursor, or nil when it is not being drawn.")

(defvar-local cooked--wandered nil
  "Whether a command has moved point off the child's cursor.

Tracked as a state set by commands rather than inferred by comparing point to
the cursor on each drain.  The comparison is order-dependent — streaming output
lets the cursor overtake point for a single drain — and inferring from it would
strand point for every drain after that.  See `cooked--apply'.")

(defvar-local cooked--point nil
  "Where cooked itself last put point in this buffer.

Kept because Emacs remembers a *position* on cooked's behalf and cooked's
positions do not survive a redraw.  A window that stops showing this buffer
leaves a point marker for it in `window-prev-buffers\=', and
`cooked--render-rows\=' deletes and reinserts whole rows, so by the time it
comes back that
marker has been dragged off whatever it was pointing at -- to the end of the
rebuilt region, which at a prompt is the empty line below it.  Emacs restores it
over the top of the position the drain maintained meanwhile, so cooked has to
hold its own answer.  The same reasoning as `cooked--wandered\=' holding a screen
cell rather than a position, one level up: a cell survives a redraw, a marker
does not, and an unwatched marker is not evidence about anything.

Written by the drain and by `cooked--track-wandering\=', which between them are
every way point moves that cooked has an opinion about; read by
`cooked--restore-point\=' when the buffer comes back on screen.")

(defun cooked--restore-point (window)
  "Put point back where cooked last had it, over a marker Emacs restored.

Called when this buffer returns to WINDOW.  What Emacs restores is the window
point it recorded when the buffer left, and for a cooked buffer that is a marker
every drain since has been dragging -- see `cooked--point\='.  The drain's own
answer is the one that means something: it re-seats a wandered point on its
cell and follows the child's cursor otherwise, and it does that whether or not
anyone is looking.

Declines when the recorded position is not in the accessible portion -- the alt
screen narrows, and a position from before it did is not this screen's."
  (when (and cooked--point
             (<= (point-min) cooked--point (point-max))
             (/= (point) cooked--point))
    (goto-char cooked--point)
    (when (window-live-p window)
      (set-window-point window cooked--point))))

(defun cooked--sync-cursor-type ()
  "Make `cursor-type\=' say what the child last asked for.

Written only on an actual change: reassigning the same value on every drain
perturbs the cursor\='s blink phase, which is one more contributor to flicker on
a line the child rewrites rapidly.

Called at the end of a drain, after the block that scrolls windows, and again
from `post-command-hook\='.  `evil\=' refreshes its own cursor from
`window-configuration-change-hook\=' and on every state change, and it advises
`select-window\=' -- which the render used to call, once per window, to
`recenter\=' through `with-selected-window\='.  Setting the cursor any earlier
let evil get the last word inside the very drain that hid it, which showed up
as a cursor jumping around a progress bar the child had asked to draw without
one.  Scrolling no longer selects anything, so that particular door is shut;
the ordering stays because the other two ways in are still open.

A hidden cursor is honoured by default: every full-screen program drawing a
frame, `less\=', and any progress bar worth the name relies on that.  Two cases
override it, and both are cases where point is the only cursor there is.  The
user has stepped out, which the mode alone answers -- `still\=' or `frozen\='.
Or Emacs is editing the line, which `cooked--input-state-p\=' alone is too wide
to say, because `brew upgrade\=' hides the cursor and repaints progress bars
without ever leaving canonical mode.  Under a shell that sends OSC 133 we know
which of the two it is, and while a command is running the child\='s `CSI ?25l\='
is about the picture it is painting and is honoured."
  (let ((shape (cond ((and cooked--cursor (cooked-cursor-visible cooked--cursor))
                      (cooked--cursor-type))
                     ((memq cooked--input-mode '(still frozen)) t)
                     ((and (cooked--input-state-p)
                           (not (eq cooked--semantic 'output)))
                      t))))
    (unless (equal cursor-type shape)
      (setq-local cursor-type shape))))

(defun cooked--ghost-cursor-visible-p ()
  "Whether the child's cursor should be drawn separately from point.

Not an alt-screen thing: `raw', `command' and every suspended state -- `evil'
normal state included -- are all cases where the child owns the keyboard and
point may be somewhere else, and the ghost is what keeps the way back visible
in each of them.

Nothing is drawn for a cursor the child has hidden, which is also the case in
which `cooked--sync-cursor-type' gives point a visible cursor of its own: there
is exactly one cursor on screen either way, and it is the one that will act on
the next keystroke."
  (and cooked--wandered
       ;; Only where the child owns the keyboard and the screen is its drawing.
       ;; At a prompt, point being elsewhere is ordinary editing, not a divergence.
       (cooked--child-owns-keyboard-p)
       ;; A hidden cursor stays hidden; nvim hides it during some redraws, and a
       ;; box left behind would be a cursor the child does not think it has.
       (cooked-cursor-visible cooked--cursor)))

(defun cooked--update-ghost-cursor ()
  "Draw, move, or remove the overlay marking the child's cursor."
  (if (not (cooked--ghost-cursor-visible-p))
      (when cooked--ghost-cursor
        (delete-overlay cooked--ghost-cursor)
        (setq cooked--ghost-cursor nil))
    (let* ((beg (cooked--cursor-position))
           (eol (save-excursion (goto-char beg) (line-end-position)))
           ;; Past the last character of its row the cursor has nothing to cover,
           ;; so the box rides on a stand-in space instead.
           (empty (>= beg eol)))
      (unless cooked--ghost-cursor
        (setq cooked--ghost-cursor (make-overlay beg beg nil t nil))
        ;; Above `hl-line-mode' and the region, which would otherwise paint over
        ;; the one thing on screen the user is aiming at.
        (overlay-put cooked--ghost-cursor 'priority 100))
      (move-overlay cooked--ghost-cursor beg (if empty beg (1+ beg)))
      (overlay-put cooked--ghost-cursor 'face (unless empty 'cooked-ghost-cursor))
      (overlay-put cooked--ghost-cursor 'after-string
                   (when empty (propertize " " 'face 'cooked-ghost-cursor))))))

(defcustom cooked-alt-change-hook nil
  "Hook run in the buffer when the alternate screen goes up or comes down.

Read `cooked--alt' for which way it went.  Distinct from
`cooked-state-change-hook', which answers a different question -- who owns the
keyboard -- and misses this one whenever the child already owned it: a raw-mode
program opening a full-screen one changes the screen without changing hands.

For a layer that has drawn something on the *primary* screen and must take it
down while a full-screen program has the viewport.  `cooked-command-decorations'
is the case it exists for: its markers ride overlays on the live rows, and those
buffer positions are where the alt screen's own rows get rendered, so a marker
left up sits in the fringe beside a running program's frame claiming to be about
a command.  Coming back needs no hook -- restoring the primary marks every row
damaged, and a layer that re-applies per render is repainted by that."
  :type 'hook
  :group 'cooked)

(defun cooked--set-alt (on)
  "Adopt alternate-screen state ON, refreshing ownership when it changes.

The keymap has to follow this and not only the line discipline: a program can
take the screen while the shell's last OSC 133 mark still says `prompt-end',
and Emacs would otherwise keep editing an input region that no longer exists
and swallow the keys the program was waiting for.

This flag is read at eight places across five files, and they are one decision
rather than eight: the alternate screen is a rectangle the child owns, where the
primary screen is a transcript Emacs owns.  Narrowing, fitting, scrolling, the
sticky header, the fringe markers and the link guesses all follow from that.
See docs/DESIGN.md."
  (let ((on (and on t)))
    (unless (eq on cooked--alt)
      (setq cooked--alt on)
      (cooked--sync-fontification)
      (cooked--refresh-keymap)
      (run-hooks 'cooked-alt-change-hook))))

(defun cooked--sync-fontification ()
  "Register or drop the jit-lock pass, following whether it has work to do.

Registration is not free and the cost is not at redisplay, which is the part
worth knowing: jit-lock hangs `jit-lock-after-change\=' on
`after-change-functions\=', and that fires for every text property applied as
well as for every insertion.  A row of box drawing sets a `display\=' property
per cell, so a frame of it pays the hook some hundreds of times to be told
something it could have been told once.  Measured at +21% on plain rows, +55%
on box drawing, with `cooked--fontify-region\=' never once being called.

So the registration follows the work rather than the mode.  Two things can make
it worthless, and both are ordinary.  The alternate screen is one: that grid is
a rectangle the child owns, `cooked--fontify-region\=' declines it outright, and
a full-screen program repainting flat out is exactly the thing that would pay
the hook most and get nothing.  A session with the URL guess switched off and
no scan layer loaded is the other.

Idempotent, and cheap enough to call on any transition -- `jit-lock-register\='
and `jit-lock-unregister\=' both go through `add-hook\='/`remove-hook\=' on a
buffer-local hook.  What it must not do is run *between* a row being rewritten
and that row being displayed, because unregistering drops jit-lock's record of
what is still unfontified: the screen the alt flag has just turned off is
rewritten by the drain that turned it off, and rewriting is what marks text
unfontified again."
  (if (and (not cooked--alt)
           (or cooked-detect-links cooked-link-scan-functions))
      (jit-lock-register #'cooked--fontify-region)
    (jit-lock-unregister #'cooked--fontify-region)))

(defvar-local cooked--held-link-row nil
  "Bounds the URL guess last declined to scan, as a pair of markers, or nil.

Markers rather than positions because the buffer moves underneath them: the row
is by definition the one being rewritten, and scrollback eviction shifts
everything above it.

Both have the default insertion type.  Type t on the end marker is the obvious
thing to reach for -- the row grows as the spinner writes -- and is wrong: text
arriving after the row, which is every subsequent row, would be swallowed into
the held region and the cursor would appear never to leave it.  The row growing
to the right needs no marker help, because the extent is recomputed from the
line itself when the hold is released.")

(defun cooked--link-hold-bounds ()
  "The region the URL guess should decline to scan right now, or nil.

The cursor\='s row always, and the whole input region on top of it when the user
is typing -- the two are usually the same row and the `max\=' costs nothing when
they are.  Returns buffer positions, not markers.

This lives in cooked.el rather than cooked-link.el on purpose.  Where the cursor
is and whether input is being edited are session state, and cooked-link.el is
base tier: it was asking questions upward until recently and must not start
again.  The link layer is told what range to scan; it does not ask why."
  (when-let* ((cursor (cooked--cursor-position)))
    (let ((beg (save-excursion (goto-char cursor) (line-beginning-position)))
          (end (save-excursion (goto-char cursor) (line-end-position))))
      (when-let* (((cooked--input-state-p))
                  (start (cooked--input-start-position)))
        (setq beg (min beg (save-excursion
                             (goto-char start) (line-beginning-position)))
              end (max end (point-max))))
      (cons beg end))))

(defun cooked--hold-link-row (beg end)
  "Remember BEG..END as declined by the URL guess, for a later rescan."
  (let ((from (or (car cooked--held-link-row) (make-marker)))
        (to (or (cdr cooked--held-link-row) (make-marker))))
    (set-marker from beg)
    (set-marker to end)
    (setq cooked--held-link-row (cons from to))))

(defun cooked--release-held-link-row ()
  "Ask for the held row again once the cursor has left it.

Called from `cooked--apply\=', which is the moment the cursor can have moved.
`jit-lock-refontify\=' rather than a direct scan: the row may not be on screen,
and the whole point of the deferral is that an invisible row costs nothing."
  (when-let* ((held cooked--held-link-row)
              (from (car held))
              (to (cdr held))
              ((marker-position from))
              ((marker-position to))
              (cursor (cooked--cursor-position))
              ;; Still the cursor\='s row?  Then it is still being rewritten and
              ;; there is nothing to reconsider.
              ((not (and (<= from cursor) (<= cursor to)))))
    (let* ((beg (marker-position from))
           ;; Recomputed rather than taken from the marker: a spinner rewrites
           ;; its row by deleting and reinserting it, which collapses a pair of
           ;; plain markers onto the same position.  What is wanted is the row as
           ;; it now stands, so ask the line.
           (end (max (marker-position to)
                     (save-excursion (goto-char beg) (line-end-position)))))
      (setq cooked--held-link-row nil)
      (set-marker from nil)
      (set-marker to nil)
      (when (< beg end) (jit-lock-refontify beg end)))))

(defun cooked--fontify-region (beg end)
  "Run the cosmetic link passes over BEG..END.  cooked\\='s jit-lock entry point.

Registered by `cooked-mode\=' and called by redisplay, which is the whole point
of it.  Both passes here are guesses about text -- what looks like a URL, what
looks like a file name -- and a guess is only worth making about text somebody
is about to read.  Running them from the render path instead meant scanning
every damaged row whether or not that row was ever displayed, which for a child
painting faster than Emacs redraws is most of them.  `goto-address-mode\=' has
always worked this way; this is cooked wearing the same clothes, with the two
bindings `cooked--fontify-links\=' makes on top.

One entry point for two passes because they are one question asked twice, and
the order between them is the precedence `cooked-link--claimed-p\=' states: a
`goto-addr\=' match is settled before the file layer looks, so the file layer can
decline text already spoken for.

`inhibit-read-only\=' because scrollback carries `read-only\=', and the file layer
answers by adding text properties to it.  The render path had this for free from
`cooked--apply\='; redisplay does not.

Rounded out to whole lines.  jit-lock hands over chunks of
`jit-lock-chunk-size\=' characters and a chunk boundary falls wherever it falls,
so a candidate straddling one would be matched by neither half.  Rounded here
rather than in either pass, because neither does it for itself: the URL scan is
a reproduction of `goto-address-fontify-region\=' with the filtering added and
the rounding left out -- see `cooked--fontify-links\=' -- and the scan hook
never rounded.

Whole *logical* lines, which is a wider round than it used to be and has to be:
a soft-wrapped line is several buffer lines, so rounding to buffer lines alone
would let a chunk boundary fall between two rows of one line and split the very
candidate the joining exists to put back together.  See
`cooked-link-logical-line-bounds\=', which is bounded so this cannot round out to
a screenful.

Nothing at all on the alternate screen, which is what
`cooked-detect-links-on-alt-screen\=' asks for and is safe to answer by simply
returning: that grid is rewritten row by row on the way back to the primary
screen, and rewriting text is what marks it unfontified again, so nothing is
stranded by having been skipped here."
  (when (and cooked--session (not cooked--alt))
    (let* ((inhibit-read-only t)
           (lines (cooked-link-logical-line-bounds
                   (save-excursion (goto-char beg) (line-beginning-position))
                   (save-excursion (goto-char end) (line-end-position))))
           (from (car lines))
           (to (cdr lines))
           (held (cooked--link-hold-bounds)))
      ;; The one row worth declining, and why declining it is not a corner case.
      ;; A spinner or a progress bar rewrites the cursor's row tens to a hundred
      ;; times a second; each rewrite marks it unfontified, so the guess is made
      ;; again on every one of them, over text nobody has finished writing.  The
      ;; prompt is the same shape -- what is being typed there is not output, and
      ;; linkifying a half-typed URL under the cursor is worse than not.
      ;;
      ;; Split rather than shrunk: text on both sides of the held row is still
      ;; scanned, so a URL in the line above a spinner appears at once.
      (if (not held)
          (cooked--fontify-links from to)
        (when (< from (car held)) (cooked--fontify-links from (car held)))
        (when (> to (cdr held)) (cooked--fontify-links (cdr held) to))
        ;; jit-lock marks the whole chunk fontified regardless of what was
        ;; actually looked at, so the held part has to be remembered and asked
        ;; for again -- see `cooked--release-held-link-row'.  Without this a URL
        ;; printed on the cursor's own row, with no newline after it, would never
        ;; be linkified at all.
        (cooked--hold-link-row (car held) (cdr held)))
      ;; Only the settled half.  The live screen is rewritten from the next
      ;; drain's damage, so an answer about it that cost a `file-exists-p' would
      ;; be paid again at the next redraw -- which is the whole reason this hook
      ;; was never on the row path.  Scrollback is final, and one scan of it
      ;; stands.  No hold is needed here for the same reason: the cursor's row is
      ;; never settled.
      (when cooked-link-scan-functions
        (let ((settled (min to (or (cooked--screen-start-position) to))))
          (when (< from settled)
            (cooked--run-seam 'cooked-link-scan-functions from settled)))))))

;;;; Starting and stopping a session
;;
;; What it takes to get a child running in this buffer and to let go of one
;; again: the size to give it, the environment to hand it, the wake pipe the
;; native core rings, and the question of whether killing the buffer should ask
;; first.  Drawing what the child sends is cooked-render.el and capping how much
;; of it the buffer keeps is cooked-scrollback.el; both used to be filed here,
;; under a heading broad enough to have accepted them.

(defun cooked--set-tuning-option (symbol value)
  "Set SYMBOL to VALUE and hand the pair to every session already running.

The `:set' behind `cooked-min-redisplay-interval\=' and
`cooked-backlog-limit\='.

Two numbers, and only one of them is a pace.  That is what the name is being
careful about: `cooked-min-redisplay-interval\=' says how often the screen is
redrawn while the child is busy, and the frame ceiling derives from it, so it is
the whole of how fast a session draws.  `cooked-backlog-limit\=' sets no rate at
all.  It is backpressure -- how much may pile up while Emacs falls behind before
the reader stops taking bytes off the pty, at which point the pty's own buffer
fills and the child blocks in `write\='.  One paces, the other pauses; calling
the pair pacing would advertise a second pace mechanism that deliberately does
not exist.

Neither used to reach a session already running, which meant the obvious way to
tune the one knob with a taste question behind it was to kill the terminal you
were tuning it for.

Both are sent whichever one changed, because the core takes them together: they
are tuned as a pair, a longer interval leaving more to accumulate between drains
and so filling the queue sooner, and one call is what stops half a pair being
set.  `set-default\=' first, so what is sent is what the variables now say rather
than one new value and one stale one.

Sessions are walked rather than notified, for the reason
`cooked--dolist-buffers\=' exists: a buffer displayed nowhere still has a child
running at whatever rate it was last told."
  (set-default symbol value)
  (cooked--dolist-buffers
    (when cooked--session
      (cooked--set-tuning cooked--session
                          (round (* 1000 cooked-min-redisplay-interval))
                          cooked-backlog-limit))))

(defcustom cooked-min-redisplay-interval 0.008
  "Floor, in seconds, on how often a session triggers a redisplay.

Without one, a child that rewrites the same line rapidly -- a spinner, a
progress meter -- drives one full Emacs redisplay per write, far more than
any of them are actually meant to be seen at, which shows up as flicker.
Modelled on `eat-minimum-latency', though a matching ceiling on the other
end is not needed: the native core always holds the latest terminal state
regardless of whether a redisplay was requested for it, and retries a
throttled one on every read cycle, so nothing is ever stranded behind this.

A floor on the rate, and not the answer to a half-drawn frame: the core
already holds a frame back until the child stops writing it, which is what
keeps a picture's cursor move from being drawn without the picture.  Raising
this cannot improve on that and costs latency on every keystroke.

It bounds that hold from the other side as well, and is the only number that
does: a child writing continuously never falls quiet, so its frame is drawn
once this interval has passed rather than waiting for a gap that is not
coming.  One interval is therefore the whole answer to how often a busy child
redraws the buffer -- there is no second cap underneath it.

Measured against the redisplay rather than against the drain: the core sends
one wakeup and stays quiet until Emacs has finished drawing what the last one
brought, so a slow render (box drawing costs some 70 times what plain text
does) paces the child by itself and this interval is the floor beneath that
rather than a rate of its own.

A floor and never a clock: nothing in cooked draws faster than this, and no
urgent path bypasses it.  Four things can make a redraw *later* -- Emacs
not having finished the last one, DEC mode 2026, this interval, and the child
still writing -- and only the first is what usually decides the rate.  See
docs/DESIGN.md.

Lower it if the terminal feels less responsive than it should; raise it if a
program that rewrites one line very fast still flickers.  Takes effect at once,
on sessions already running as well as on the next one."
  :type 'number
  :set #'cooked--set-tuning-option
  :group 'cooked)

(defcustom cooked-backlog-limit 8000
  "Items awaiting collection before the child is left to block on its writes.

Counts scrolled-off lines plus undelivered events.  Raising it does not make
output render faster: throughput is bounded by how fast Emacs can insert text,
not by this queue.  What it changes is who waits.  Below the limit the child
runs ahead and finishes sooner while Emacs catches up; at the limit the reader
stops draining the pty, the pty's buffer fills, and the child blocks in `write'
exactly as it would against a slow terminal.  Nothing is ever dropped.

The cost of raising it is memory, and a larger worst-case pause when a big
backlog finally lands in one redisplay.  Tuned together with
`cooked-min-redisplay-interval': a longer interval leaves more to accumulate
between drains, so this fills sooner.  A static relationship between two
numbers you set once, not a rate that moves underneath the child -- what
actually paces a session is Emacs' own readiness to draw again, and the
interval is only a floor under that -- so size this against the slowest
cadence the pair allows and leave it alone.

Takes effect at once, on sessions already running as well as on the next one."
  :type 'natnum
  :set #'cooked--set-tuning-option
  :group 'cooked)

;;;; Whether a picture can be shown
;;
;; The core claims graphics in three answers -- the `4' in DA1, XTSMGRAPHICS and a
;; kitty `a=q' probe -- and a producer that believes them draws a picture.  Where
;; none can be shown, because `cooked-inline-images' is off or the buffer is only
;; on a terminal frame, that picture is a blank rectangle, while the same producer
;; told the truth would have drawn it in half blocks.  So the claim follows what
;; Emacs can display, and this is where Emacs says so.

(defvar-local cooked--graphics-shown nil
  "What this buffer's core was last told by `cooked--sync-graphics'.
Kept so the window hooks, which run on every buffer change in every frame, only
reach the module when the answer actually moves.")

(defvar-local cooked--graphics-displayable nil
  "Whether the windows last seen showing this buffer could display images.
The half of the answer that a buffer displayed nowhere keeps; see
`cooked--sync-graphics'.")

(defun cooked--frame-shows-images-p (frame)
  "Whether FRAME can display a picture the child transmits.

`display-images-p' rather than `display-graphic-p': a graphical build with no
image support leaves the rectangle blank as surely as a terminal frame does.
A function of its own so that a batch test, which has no graphical frame at
all, can say what one would answer."
  (display-images-p frame))

(defun cooked--sync-graphics (&optional frame inline)
  "Tell this buffer's child whether a picture it sends can be shown.

Shown when images are on and some window showing the buffer, on any frame,
can display them.  One such window is enough: that is where the picture will
be seen, and a terminal frame beside it shows the stashed characters instead,
which is the fallback decoration already has.  See `cooked--set-graphics-shown'
for what the core does with the answer.

A buffer displayed nowhere keeps what its windows last said, in
`cooked--graphics-displayable'.  Its pictures are held and render the moment a
window turns up, so being buried is no reason to tell the child it cannot
draw, and the window hooks report wherever it is shown next.  The preference
still applies while buried, since it needs no window to be true.

FRAME stands in for those windows at session start, when the buffer has not
been displayed yet: the frame the command ran from is where it is about to
appear.  Given FRAME the answer is sent even if it matches the cache, because
the core it goes to is new and has never been told anything.

INLINE, when given, is `(VALUE)\=' and stands in for `cooked-inline-images\=',
for the variable watcher, which runs before the new value is in place."
  (when-let* ((session (cooked--live-session)))
    (let ((frames (or (mapcar #'window-frame (get-buffer-window-list nil nil t))
                      (and frame (list frame)))))
      (when frames
        (setq cooked--graphics-displayable
              (and (cl-some #'cooked--frame-shows-images-p frames) t)))
      (let ((shown (and (if inline (car inline) cooked-inline-images)
                        cooked--graphics-displayable
                        t)))
        (when (or frame (not (eq shown cooked--graphics-shown)))
          (setq cooked--graphics-shown shown)
          (cooked--set-graphics-shown session shown))))))

(defun cooked--sync-graphics-everywhere (&rest _)
  "Run `cooked--sync-graphics' in every live session.

From `window-buffer-change-functions', whose global value runs once per frame
whenever a window on it was added, deleted or changed buffer -- which covers a
buffer appearing on a terminal frame and leaving the last graphical one -- and
from `after-delete-frame-functions', since deleting a whole frame is neither."
  (cooked--dolist-buffers
    (when cooked--session
      (cooked--sync-graphics))))

(defun cooked--sync-graphics-on-toggle (_symbol newval operation where)
  "Follow `cooked-inline-images' to NEWVAL, as a variable watcher.

WHERE is the buffer a buffer-local OPERATION applies to, and nil for the
default value, which reaches every session that has not made the variable
local.  Pushed directly rather than deferred: unlike a drain, telling the core
a flag touches nothing redisplay depends on."
  (unless (eq operation 'defvaralias)
    (if where
        (when (buffer-live-p where)
          (with-current-buffer where
            (when cooked--session
              (cooked--sync-graphics nil (list newval)))))
      (cooked--dolist-buffers
        (when (and cooked--session (not (local-variable-p 'cooked-inline-images)))
          (cooked--sync-graphics nil (list newval)))))))

(defun cooked--start (argv &optional directory extra-env)
  "Spawn ARGV in the current buffer, optionally in DIRECTORY.
EXTRA-ENV is an alist prepended to the child\\='s environment.

A remote DIRECTORY is refused and the child starts in the home directory
instead.  The pty is always a local one, so a TRAMP name here is not somewhere
the child can be put: it reaches the module verbatim, the `chdir\\=' fails, and
`child_exec\\=' in src/pty.rs is right to treat that as fatal rather than exec
from wherever Emacs happened to be.  What that left was a buffer reading
\"[exited 127]\" and nothing else, which is the correct behaviour reported as an
unexplained number -- and it is reached by nothing more unusual than
\\[cooked] from a buffer visiting a remote file.

`cooked--local-name\\=' is what refuses it, rather than a `file-remote-p\\=' of
our own, because that is the chokepoint every other path from a string to the
filesystem already goes through, and its message is the one the user is told.

Only when DIRECTORY is non-nil: nil keeps its own meaning of leaving the child
wherever Emacs is, and is not a request to be second-guessed."
  (cooked--load-module)
  (cooked--reset-images)
  ;; A layer that failed against the last child's output is worth hearing about
  ;; again for this one; see `cooked--seams-reported'.
  (setq cooked--seams-reported nil)
  (pcase-let ((`(,rows . ,cols) (cooked--window-size)))
    (setq cooked--rows rows cooked--cols cols
          ;; Matches `cooked--sync-size' having already run once at exactly
          ;; this size: nothing has diverged from it yet, so its very next
          ;; invocation -- on the first real window or font event -- must not
          ;; read a stale `nil' here and mistake "never synced" for "resized",
          ;; forcing a redraw against native-core state nothing has spawned
          ;; a window for yet.
          cooked--last-size (cons rows cols)))
  (cooked--with-child-edit
    (erase-buffer)
    (insert (make-string cooked--rows ?\n))
    (setq cooked--screen-start (copy-marker (point-min) nil)))
  ;; The previous session's entries describe text `erase-buffer' has just taken
  ;; away, and the anchor that vouches for them cannot notice: a buffer being
  ;; reused for a second session puts the new prompt at exactly the position the
  ;; old one held, which is the one thing `cooked--check-undo-anchor' reads as
  ;; nothing having moved.  Cleared here rather than inside the macro above, for
  ;; the reason given there.
  (setq cooked--undo-anchor nil)
  (cooked--discard-undo)
  ;; Attached to the buffer, unlike a plain doorbell would be: `get-buffer-process'
  ;; answering is the whole of what comint needs from a process, since every one of
  ;; its commands works through `process-mark' and none of them through the process
  ;; itself.  `shell-maker' buys the same thing by spawning a `hexl' it never speaks
  ;; to; we already had a process object and were only withholding it.
  ;;
  ;; Nothing may ever write here: the read end belongs to Rust, and a stray
  ;; `process-send-string' would land in the wakeup channel.  `comint-input-sender'
  ;; is overridden in `cooked-mode' so comint's own submission path cannot.  The
  ;; sentinel is silenced because the default one inserts "Process ... finished"
  ;; into the buffer it is attached to, which is now the terminal.
  (setq cooked--wake
        (make-pipe-process :name (format "cooked-wake<%s>" (buffer-name))
                           :buffer (current-buffer)
                           ;; This pipe is also the session's stand-in for the
                           ;; "active processes exist" warning, and whether it
                           ;; wants one depends on what the child is doing, so
                           ;; the flag is kept current by
                           ;; `cooked--sync-query-flag' rather than fixed here.
                           :noquery t
                           :sentinel #'ignore
                           :filter (let ((buffer (current-buffer)))
                                     (lambda (_proc _string) (cooked--on-wake buffer)))))
  (set-marker-insertion-type (process-mark cooked--wake) nil)
  (cooked--sync-query-flag)
  (cooked--set-input-mark nil)
  (setq cooked--session
        (cooked--spawn argv (cooked--child-environment extra-env) cooked--rows cooked--cols cooked--wake
                      (when directory
                        (expand-file-name (or (cooked--local-name directory) "~")))
                      (round (* 1000 cooked-min-redisplay-interval))
                      cooked-backlog-limit))
  ;; Once, at the start: the core answers `CSI ? 996 n' from what Emacs last reported,
  ;; and a session that outlives no theme change would otherwise answer with silence for
  ;; its whole life.  Here rather than in `cooked--start-session' so that the callers who
  ;; spawn directly -- the test fixture and the benchmark -- exercise the same path.
  ;;
  ;; Protected because the session is already started by this point and is correct
  ;; without it: the only thing lost is a courtesy answer to a query most children never
  ;; send, and failing the spawn over it would trade a terminal for a colour.  The seam
  ;; is real rather than theoretical -- `cooked--default-color' guards against
  ;; `color-values' returning nil, which is not the same as it signalling, and it does
  ;; signal on a frame that claims to be graphical without a window system behind it.
  (cooked--protect-seam 'cooked--sync-color-scheme
    (cooked--sync-color-scheme))
  ;; Before the child can have read much of its rc file, and with the frame the
  ;; buffer is about to appear on -- see `cooked--sync-graphics'.
  (cooked--sync-graphics (selected-frame))
  cooked--session)

(defun cooked--child-environment (&optional extra)
  "Environment alist for the child, with EXTRA taking precedence.

Every name this function sets is also stripped from the inherited environment,
so a value from whatever terminal started Emacs cannot shadow ours.  That is the
whole point of the exclusion list below: an inherited TERM_PROGRAM=iTerm.app
sitting beside our own TERM is worse than no answer at all, because the programs
that branch on it would take a path for a terminal that is not driving this pty.

TERMINFO is set to our own database and the inherited one is dropped with the
rest, which is the same rule and not an exception to it.  It names one directory
and we need it to name ours."
  (let* ((term (cooked--terminfo))
         ;; Only alongside our own entry: if we fell back to xterm-256color there is
         ;; nothing of ours to find and so nothing to say.
         (database (and (equal term cooked-term-name) (cooked--terminfo-database))))
    `(,@extra
      ("TERM" . ,term)
      ("COLORTERM" . "truecolor")
      ;; Identity, not capability -- what we can do is in the terminfo entry and
      ;; COLORTERM.  Nothing keys off "cooked" yet, so consumers fall through to
      ;; their defaults, which is the correct behaviour for a terminal they have
      ;; never heard of.  Set as a pair: they are read as one.
      ("TERM_PROGRAM" . "cooked")
      ("TERM_PROGRAM_VERSION" . ,(cooked-version))
      ,@(and database `(("TERMINFO" . ,database)))
      ;; LINES and COLUMNS are deliberately *not* set. ncurses treats them as
      ;; authoritative over the tty's own size (`use_env'), so a program started with
      ;; them pinned keeps its original geometry for life and ignores every SIGWINCH.
      ;; The winsize is the single source of truth; shells re-export these themselves.
      ,@(cl-loop with seen = nil
                 for entry in process-environment
                 for split = (string-search "=" entry)
                 for name = (and split (substring entry 0 split))
                 when (and name
                           (not (member name '("TERM" "COLORTERM" "TERM_PROGRAM"
                                               "TERM_PROGRAM_VERSION" "LINES"
                                               "COLUMNS" "TERMINFO")))
                           ;; First occurrence only, which is `getenv''s answer
                           ;; and so the one the caller meant.  `process-environment'
                           ;; is a list a caller shadows by consing onto the
                           ;; front -- the documented way to bind a variable for
                           ;; one process, and what `compilation-start' does to
                           ;; empty PAGER -- so a name appearing twice is
                           ;; ordinary rather than a mistake.
                           ;;
                           ;; Passing both on inverts it.  `execve' takes a plain
                           ;; array and POSIX leaves duplicate names unspecified,
                           ;; so the tie is broken by whatever reads it; measured
                           ;; here, a shell handed ("SHADOWED" . "wanted") ahead
                           ;; of ("SHADOWED" . "inherited") reports `inherited',
                           ;; the entry consed on to be overridden.  The shadow
                           ;; loses to the thing it was written to shadow, which
                           ;; is worse than not honouring it at all: nothing
                           ;; downstream does a lookup, so the loser has to be
                           ;; absent rather than merely second.
                           (not (member name seen)))
                 collect (cons name (substring entry (1+ split)))
                 and do (push name seen)))))

;;;; Entry points

;; Here rather than in cooked-mode.el, where the rest of the interaction lives,
;; because this is the file an installation names: `package.el' autoloads from it
;; and a `:load-path' install autoloads `cooked' from "cooked".  An autoload that
;; forwards to a second file does not chain -- Emacs signals rather than following
;; it -- so the commands themselves have to be reachable from here, and they pull
;; the interaction layer in when first called.

(declare-function cooked--display "cooked-mode")
(declare-function cooked--start-session "cooked-mode")
(declare-function cooked--live-buffers "cooked-mode")

(defcustom cooked-display-action '((display-buffer-same-window
                                    display-buffer-pop-up-window))
  "Action `\\[cooked]' passes to `pop-to-buffer\='.

The selected window first, the way `vterm\=' and `eat\=' do it: a terminal is
usually what you want to be looking at, whereas the fallback `display-buffer\='
uses -- reuse a window, else split -- would put it beside the buffer you
invoked it from as often as not.  Splitting is still the second choice, for
when the selected window will not take it (a dedicated or side window), and
`\\[cooked-other-window]\=' remains the way to ask for the split on purpose.

The extra pair of parentheses is load-bearing, and their absence was the bug
this docstring described its way around for a long time.  A `display-buffer\='
action is (FUNCTIONS . ALIST), so the flat list read as FUNCTIONS =
`display-buffer-same-window\=' and ALIST = (display-buffer-pop-up-window) -- an
alist entry `assq\=' never asks for and so silently drops.  The second choice
therefore did not exist: a window that would not take the buffer fell through to
`display-buffer-fallback-action\=', whose first entry is
`display-buffer-reuse-window\=' -- the behaviour named two paragraphs up as the
one to avoid.

Here rather than in cooked-mode.el with the other session options, because
every command that reads it is here or in cooked-project.el, and each reads it
as an *argument* -- evaluated before the callee\='s `require\=' of cooked-mode
could have run.  Defined beside its readers, an autoloaded `\\[cooked]\=' in an
Emacs that has never loaded the interaction layer finds a value rather than a
void variable."
  ;; `sexp' rather than a hand-written (FUNCTIONS . ALIST) type: Emacs has no
  ;; public widget for a display action, and the one thing a narrower type here
  ;; could have caught -- the missing parentheses above -- it would only have
  ;; caught for a value set through Customize, which this one never was.
  :type 'sexp :group 'cooked)

(defconst cooked-other-window-action '(display-buffer-pop-up-window)
  "Display action every `-other-window\=' command in cooked passes.

A constant rather than the literal written out at each of them: there are three
pairs of commands whose two halves differ in nothing else -- here, and the two
in cooked-project.el -- so the literal was the only thing saying they agree,
three times over.  Deliberately not a `defcustom\=': the customisable choice is
`cooked-display-action\=', and a command whose whole name is `other-window\='
has already been told what to do.")

(defun cooked--open-session (new command action)
  "Display a session using ACTION, starting one unless a live one may be reused.

The body `cooked\=' and `cooked-other-window\=' share; NEW and COMMAND mean what
they do there.  cooked-project.el has its own, which differs in looking for a
session already rooted at a particular directory rather than for any at all."
  (require 'cooked-mode)
  (cooked--display (or (unless new (car (cooked--live-buffers)))
                       (cooked--start-session command))
                   action))

;;;###autoload
(defun cooked (&optional new command)
  "Switch to a terminal session, starting one if needed.

With a prefix argument, or NEW non-nil, always start another session rather than
reusing a live one.  COMMAND overrides `cooked-shell'."
  (interactive "P")
  (cooked--open-session new command cooked-display-action))

;;;###autoload
(defun cooked-other-window (&optional new command)
  "Like `cooked', but display the session in another window.

NEW and COMMAND mean what they do there."
  (interactive "P")
  (cooked--open-session new command cooked-other-window-action))

(provide 'cooked)
;;; cooked.el ends here
