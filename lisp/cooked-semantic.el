;;; cooked-semantic.el --- What the shell's OSC 133 marks do to a buffer -*- lexical-binding: t; -*-

;;; Commentary:

;; A shell running cooked's integration marks where each prompt starts, where
;; the user's input begins, where a command starts and where it ends.  The native
;; core anchors each mark where it fell in the output and hands it over with an
;; id; this file turns the anchor into a buffer marker, files the marker under
;; the id so a resize can move it, and advances `cooked--semantic' and the
;; command records in cooked-command.el from one mark to the next.
;;
;; It sits on cooked-screen.el, which resolves an anchor to a position, and below
;; the drain pipeline, which dispatches the marks to it.

;;; Code:

(require 'comint)
(require 'cooked-util)
(require 'cooked-state)
(require 'cooked-command)
(require 'cooked-screen)

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
           ;; Where the prompt is about to be drawn, which is what
           ;; `cooked-previous-command' moves between and where the outer half of
           ;; an `evil' command text object starts.  The mark arrives before the
           ;; prompt itself, so this is column 0 of its first row.
           cooked--prompt-start (cooked--register-mark (car id) at batch-start))
     ;; A fresh prompt is a fresh line: Emacs may have it back, and whatever was
     ;; being continued is over.
     (setf (cooked-line-delegated (cooked--line)) nil
           (cooked-line-prompt-continued (cooked--line)) nil))
    ;; A continuation prompt -- `PS2' -- is the same command still being typed.  It
    ;; deliberately does *not* touch `cooked--prompt-start': that marker is where the
    ;; construct began, which is what the command record is filed under and what
    ;; `cooked-previous-command' lands on.  Moving it here would start the record at
    ;; the last continuation line.  The `B' that follows still arrives, so Emacs owns
    ;; the continuation line exactly as it owns the first one.
    (`(prompt-continuation ,_ . ,_)
     (setq cooked--semantic 'prompt)
     ;; A fresh line, whoever it continues, and Emacs may have it back.
     (setf (cooked-line-delegated (cooked--line)) nil
           (cooked-line-prompt-continued (cooked--line)) t))
    (`(prompt-end ,_ . ,_)
     (setq cooked--semantic 'input)
     (cooked--request-refresh))
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
               cooked--command-start marker
               cooked--command-started-at (float-time)
               ;; What the shell said it was about to run, and only failing that what
               ;; we last submitted.  The shell's account wins where both exist: ours
               ;; is the text Emacs *sent*, glued together across the lines of a
               ;; multi-line construct by `cooked--send-input-string', while the
               ;; shell's is what its parser actually made of it.  And it is the only
               ;; account at all in every case where the shell kept the line -- a
               ;; remote prompt, a program reading input of its own, a `no-input-mark'
               ;; session -- where nothing was submitted from Emacs.  See
               ;; `State::cmdline' on the Rust side.
               cooked--command-input (or cmdline
                                         (cooked-line-submitted-input (cooked--line)))
               ;; The prompt this was typed at stops being the live one here, and
               ;; becomes the running command's.
               cooked--command-prompt (prog1 cooked--prompt-start
                                        (setq cooked--prompt-start nil))
               ;; The line is over, and everything said about it with it: the
               ;; announcement covered this line, and anything the command spawns
               ;; -- an `ssh', a nested shell, a REPL -- announces for itself or not
               ;; at all; the delegated line has been submitted; the construct has
               ;; been submitted in full, so the next line starts a command of its
               ;; own.
               cooked--line-record nil)
         ;; Output begins here, so this is where the input ended.  `comint-delete-output',
         ;; `comint-show-output' and `comint-write-output' all measure from it, and left
         ;; at `point-min' it would make deleting output flush the whole buffer.
         (set-marker comint-last-input-end start)
         (set-marker comint-last-output-start start)
         (run-hook-with-args 'cooked-command-started-functions
                             (cooked--running-anchor)))
       (cooked--request-refresh)))
    (`(command-end ,code ,at . ,id)
     (setq cooked--semantic nil)
     (cooked--mark-command-end code (cooked--register-mark (car id) at batch-start)))))

(provide 'cooked-semantic)
;;; cooked-semantic.el ends here
