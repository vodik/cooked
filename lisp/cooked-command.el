;;; cooked-command.el --- The command records OSC 133 delimits -*- lexical-binding: t; -*-

;;; Commentary:

;; What a shell that speaks OSC 133 tells cooked about the commands it runs, and
;; everything built on that: the record itself, the markers that outlive a rewrap,
;; the list of finished ones, the two hooks, and the queries the rest of the tree
;; asks of them.
;;
;; It sits *below* cooked.el rather than beside cooked-mode.el, which is where most
;; of its readers are, and the placement is the interesting part.  Nothing here
;; depends on anything above it: the struct, the accessors, the buffer-locals and
;; every query call only each other and stock Emacs.  So the drain can reach
;; `cooked--mark-command-end\=' and `cooked--running-anchor\=' as ordinary downward
;; calls, where a file between cooked.el and cooked-mode.el would have needed four
;; `declare-function\='s pointing back up into it -- and cooked.el\='s own rule for
;; that block is that it carries notifications upward, never questions.
;;
;; Every consumer reaches these through `cooked\=' or `cooked-mode\=', so nothing
;; had to change its `require\='s.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'cooked-util)

;;;; The record

(cl-defstruct (cooked-command (:constructor cooked--command-make) (:copier nil))
  "One command the shell ran, as delimited by its OSC 133 marks.

A record rather than only text properties: a command that printed nothing spans
an empty region, which no text property can describe, and the records are what
folding and navigation walk."
  (start nil :documentation "Marker where the command's output began.")
  (end nil :documentation "Marker where it ended.")
  (code 0 :documentation "Exit status.")
  (prompt nil :documentation "Marker where the prompt that ran this command began.

From the OSC 133 `A' prompt mark, which cooked's own snippets carry inside the
prompt string rather than printing from a hook -- so the marker names column 0
of the prompt's first row.  That is a position a repaint cannot spoil -- a
damaged row is deleted whole and its markers collapse to the row's start, which
is where this one already is -- unlike a marker inside the input row; see
`input' below.

Nil for a shell that never sent a prompt mark, in which case the output start is
the closest thing to a beginning there is.")
  (input nil :documentation "The command line itself, or nil if we never saw it.

What the shell said it was about to run, from `cmdline_url=' on the `C' mark,
and failing that the text cooked submitted.  Not a position recovered
afterwards: a marker would not survive, because the input row is repainted on
every keystroke and again when the shell echoes the line, and
`cooked--render-rows' deletes a damaged row whole, so any marker inside it
collapses to the row's start -- taking the prompt with it.

Nil only when neither account exists: a shell that sends no `cmdline_url=' and a
command Emacs did not submit, such as one typed while the child owned the
keyboard or one the shell ran itself."))

(defun cooked--command-start-position (command)
  "Buffer position where COMMAND's output begins."
  (marker-position (cooked-command-start command)))

(defun cooked--command-end-position (command)
  "Buffer position where COMMAND's output ends."
  (marker-position (cooked-command-end command)))

(defun cooked--command-prompt-position (command)
  "Buffer position where the prompt that ran COMMAND begins, if it is known."
  (when-let* ((marker (cooked-command-prompt command)))
    (marker-position marker)))

(defvar-local cooked--prompt-start nil
  "Marker where the prompt now on screen began, from the OSC 133 `A' mark.
Moved into `cooked--command-prompt' when a command starts, the way
`cooked--submitted-input' is moved into `cooked--command-input'.")

(defvar-local cooked--command-prompt nil
  "Marker where the prompt that ran the current command began.")

(defvar-local cooked--command-start nil
  "Marker where the running command's output began.")

(defvar-local cooked--command-input nil
  "The running command's own line, as cooked submitted it.")

(defvar-local cooked--commands nil
  "Finished `cooked-command' records, newest first.")

(defcustom cooked-command-started-functions nil
  "Functions called each time a command starts, with its anchor marker.

The `C\=' half of the pair `cooked-command-finished-functions\=' is the `D\='
half of, and nil by default for the same reason: a session nothing is listening
to pays only the `run-hook\='.

Called from the `command-start\=' branch of `cooked--handle-semantic\=', once
the makings of the record are in place, with one argument --
`cooked--running-anchor\='.

There is no `cooked-command\=' to pass, and that is not an oversight to be fixed
by building one early: a record exists because a `D\=' mark supplied an exit
code, and a half-built one would carry `code\=' 0, which every reader of that
field has always been entitled to read as success.  A consumer wanting more
than the anchor reads `cooked--command-input\=' and `cooked--command-start\=',
both of which are live at the moment this fires.

Command decorations use it to put a marker up in the running colour that the
`D\=' mark then repaints; a notifier for long-running commands wants this same
moment to start its clock."
  :type 'hook
  :group 'cooked)

(defun cooked--running-anchor ()
  "Marker naming the row the running command was typed at, or nil.

Its prompt where the shell sent an `A\=' mark and the start of its output
otherwise -- the same fallback `cooked-command-decorations--anchor\=' makes for
a finished record, made here for the command that does not have one yet.

Nil between a `D\=' mark and the next `C\=', which is to say exactly when
nothing is running: that is the question most callers are really asking."
  (when-let* ((marker (or cooked--command-prompt cooked--command-start))
              ((marker-position marker)))
    marker))

(defcustom cooked-command-finished-functions nil
  "Functions called with a `cooked-command\=' each time one finishes.

Nil by default -- a session nothing is listening to pays only the `run-hook\='.
This is the seam for anything that wants \"a command just finished\" without
growing its own copy of `cooked--mark-command-end\='s bookkeeping: command
decorations paint an indicator from it, and a notifier for long-running
commands is the other obvious consumer.

Called from `cooked--mark-command-end\=', after the record has been pushed onto
`cooked--commands\=', with that same record.  `cooked-command-start\=' and
`cooked-command-end\=' are markers by then; `cooked-command-prompt\=' is a marker
too when the shell sent an `A\=' mark and nil otherwise.

An abnormal hook rather than a single function, because two layers already want
this moment and a plain variable would let the second silently replace the
first.  Unlike `cooked-osc-eval-functions\=' this gates no
channel the child can reach -- it fires only on cooked\='s own bookkeeping -- so
it is ordinary hook plumbing rather than a deliberate opt-in."
  :type 'hook
  :group 'cooked)

(defun cooked--mark-command-end (code end)
  "Record exit CODE for the command that just finished, whose output ends at END.

END is the marker `cooked--register-mark' made for the `D' mark, and the record
is built on that marker itself rather than on a copy of it -- as it is on
`cooked--command-start' and `cooked--command-prompt', which are the markers made
for the `C' and `A' marks.  That sharing is the whole of how a resize is
repaired: `cooked--relocate-marks' moves the marker the emulator named, and
every record holding it moves with it.  A `copy-marker' here would have left
each record with a private copy nothing could reach."
  (when (and cooked--command-start (marker-position cooked--command-start))
    (let* ((beg (marker-position cooked--command-start))
           (code (or code 0))
           ;; Clamped by moving the marker, not by measuring past it: the marker is
           ;; the record's own and has to say the truth after this, not only here.
           (end (set-marker end (min (point-max) (marker-position end)))))
      (when (< beg end)
        (put-text-property beg end 'cooked-exit-code code))
      (let ((command (cooked--command-make :start cooked--command-start :end end
                                           :code code :input cooked--command-input
                                           :prompt cooked--command-prompt)))
        (push command cooked--commands)
        (run-hook-with-args 'cooked-command-finished-functions command))))
  (setq cooked--command-start nil cooked--command-input nil cooked--command-prompt nil))

;;;; Asking after the records

(defun cooked-last-exit-code ()
  "Exit status of the most recently finished command, if any."
  (when-let* ((command (car cooked--commands)))
    (cooked-command-code command)))

(defun cooked-goto-last-command ()
  "Move to the prompt of the most recently finished command.

What the mode line\='s exit status is a click away from, and the reason it is a
command rather than a closure: the status answers \"how did it go\" and the
obvious next question is \"which one, and what did it print\", which is a
position.  Lands on the prompt rather than the output for the reason
`cooked-previous-command\=' does -- a command that printed nothing has no output
to land in, and its exit status is exactly the one worth chasing."
  (interactive)
  (if-let* ((command (car cooked--commands)))
      (goto-char (or (cooked--command-prompt-position command)
                     (cooked--command-start-position command)))
    (user-error "cooked: no command has finished yet")))

(defun cooked--command-at (point)
  "The command record whose output contains POINT."
  (seq-find (lambda (command)
              (<= (cooked--command-start-position command)
                  point
                  (cooked--command-end-position command)))
            cooked--commands))

(defun cooked--prompt-starts ()
  "Where each command's prompt begins, in buffer order.

What navigation moves between, and deliberately not the list of where each
command's *output* began: a command that printed nothing has its output start
and end at the *next* prompt, so walking output starts steps straight over it
and reads as though the command -- very often a quiet one, or a failing one --
were never recorded at all.  It was; only the place to stand was missing.

Falls back to the output start for a record with no `A' mark, which is the
best a session without the full integration can do and is exactly what this
did before.  The live prompt comes last, so there is somewhere for
`cooked-next-command' to land at the bottom."
  (let ((starts (mapcar (lambda (command)
                          (or (cooked--command-prompt-position command)
                              (cooked--command-start-position command)))
                        cooked--commands)))
    (when-let* ((live (or cooked--command-prompt cooked--prompt-start))
                (at (marker-position live)))
      (unless (memql at starts) (push at starts)))
    (sort starts #'<)))

(defun cooked--command-region (command &optional outer)
  "The region COMMAND occupies, as a cons of positions.

The output alone, or with OUTER the prompt and the command line above it as
well.  The end is pulled back off the following prompt's first column, since
`cooked--command-end-position' is one past the output: without that a linewise
selection of one command's output reaches down into the next command's prompt
line."
  (let* ((beg (if outer
                  (or (cooked--command-prompt-position command)
                      (cooked--command-start-position command))
                (cooked--command-start-position command)))
         (end (cooked--command-end-position command))
         (end (if (and (> end beg)
                       (= end (save-excursion (goto-char end) (line-beginning-position))))
                  (1- end)
                end)))
    (cons beg (max beg end))))

(defun cooked--command-around (position)
  "The command whose prompt, line and output surround POSITION.

Wider than `cooked--command-at', which answers for the output alone because
that is what folding and `cooked-delete-output' act on: after
`cooked-previous-command' point is on the *prompt*, which is outside every
output region there is, and a text object asked for there still means the
command being looked at.

Half-open on purpose.  A command that printed nothing ends exactly where the
next command's prompt begins, so both records claim that position; the later
one is the honest answer, since that is the prompt the user is looking at.

The command still running has no record yet -- it gets one at `command-end' --
so it is answered from the live markers, its output reaching as far as has been
drawn.  The same branch answers for the prompt being typed at, where there is
no output at all and only the outer half means anything."
  (or (seq-find (lambda (command)
                  (let ((beg (or (cooked--command-prompt-position command)
                                 (cooked--command-start-position command)))
                        (end (cooked--command-end-position command)))
                    (and (<= beg position) (< position end))))
                cooked--commands)
      (let* ((prompt (or cooked--command-prompt cooked--prompt-start))
             (start (or cooked--command-start prompt)))
        (when-let* ((beg (and prompt (marker-position prompt)))
                    ((<= beg position)))
          (cooked--command-make
           ;; No output start means nothing has been printed yet -- the prompt
           ;; being typed at -- so the inner half is empty and says so.
           :start (copy-marker (if cooked--command-start
                                   (marker-position start)
                                 (point-max)))
           :end (copy-marker (point-max))
           :code 0
           :input cooked--command-input
           :prompt (copy-marker beg))))))

(defun cooked--goto-nth-command (n direction)
  "Move to the Nth prompt in DIRECTION, `forward' or `backward'.

Stops at the far end of the buffer rather than erroring, so holding the key
down walks to the top or bottom and settles there."
  (let* ((starts (cooked--prompt-starts))
         (before (seq-filter (lambda (p) (< p (point))) starts))
         (after (seq-filter (lambda (p) (> p (point))) starts)))
    (goto-char (or (if (eq direction 'backward)
                       (car (last before n))
                     (nth (1- n) after))
                   (if (eq direction 'backward) (point-min) (point-max))))))

(defun cooked-previous-command (&optional n)
  "Move to the prompt of the Nth previous command.

The prompt rather than the output, which is what `comint-previous-prompt' --
the command this stands in for, and what `evil-collection' binds \`[[' to --
has always meant, and the only landing place that does not step over a command
that printed nothing.  See `cooked--prompt-starts'."
  (interactive "p")
  (cooked--goto-nth-command (or n 1) 'backward))

(defun cooked-next-command (&optional n)
  "Move to the prompt of the Nth next command.
See `cooked-previous-command'."
  (interactive "p")
  (cooked--goto-nth-command (or n 1) 'forward))

(defun cooked--output-region-at-point ()
  "The output region of the command at point, as (BEG . END).

The command point is inside, falling back to the most recent one -- which is
what makes both callers work from the prompt below a command as well as from
inside its output, and is the reading a user invoking either from where they
are typing expects.

Refuses rather than returns nil for an empty region: a command that printed
nothing has a start and an end that coincide, and there is nothing to fold or
delete there.  Signalling here rather than at each call site is the point; the
two commands used to carry a copy of this each."
  (let* ((command (or (cooked--command-at (point)) (car cooked--commands)))
         (beg (and command (cooked--command-start-position command)))
         (end (and command (cooked--command-end-position command))))
    (unless (and beg end (< beg end))
      (user-error "No command output here"))
    (cons beg end)))

;;;; Acting on one record

(defun cooked--command-here (&optional command)
  "COMMAND if it was given, and otherwise the one point is in or under.

The argument is what lets the fringe marker and the menu share these commands
without sharing their idea of *which* record is meant: a click on a marker
knows exactly, from the overlay it was painted on, and a keystroke has only
point to go on.  `cooked--command-around\=' is what answers for point, so the
prompt below a command counts as that command -- see there for why that is the
reading a user expects rather than a convenience.

Signals rather than returning nil, since every caller would otherwise open with
the same check."
  (or command
      (cooked--command-around (point))
      (user-error "cooked: no command here")))

(defun cooked-show-output (&optional command)
  "Scroll so COMMAND's output starts at the top of the window.

Where comint puts `comint-show-output\=', and for the concept comint means by
it -- but not its implementation.  `comint-show-output\=' finds the output group
by walking `field\=' text properties, and cooked sets none anywhere: it marks
the prompt read-only instead, because the transcript is one continuous thing
the emulator rewrites in place, and fields over rows still being redrawn would
have to be maintained on every render for the sake of two commands.  With no
fields `field-beginning\=' answers `point-min\=', so the inherited command
scrolls to the top of the *scrollback* -- silently, which is the worst way for
it to be wrong, and the reason this exists rather than the menu entry simply
being dropped.

`cooked--command-here\=' is better than the field walk in the way that matters:
it answers from the prompt and the input line as well as from inside the
output, so this does the right thing pressed from where the user is typing.

Puts the start at the top rather than recentring, which is what the name asks
for: the interesting end of a long output is its beginning, and recentring
would spend half a window on the command before it."
  (interactive)
  (goto-char (car (cooked--command-region (cooked--command-here command))))
  (recenter 0))

(defun cooked-write-output (file &optional outer command)
  "Write COMMAND's output to FILE, or with OUTER its whole record.

Where comint puts `comint-write-output\=', which writes from
`comint-last-input-end\=' to the process mark -- here the input mark.  At a
prompt that is the last command's output and works by coincidence; midway
through a command the input mark points nowhere and it raises rather than
writing anything.  This asks for the command at point, which is both the honest
reading of \"the current output group\" and the one that can save the output of
something four screens up.

With a prefix argument the region is the whole record -- the prompt, the
command line and the output -- which is the form worth pasting into a bug
report, and the one `cooked--command-region\=' already has an argument for."
  (interactive (list (read-file-name (if current-prefix-arg
                                         "Write command and output to file: "
                                       "Write output to file: "))
                     current-prefix-arg))
  (pcase-let ((`(,beg . ,end) (cooked--command-region (cooked--command-here command) outer)))
    (write-region beg end file)))

(defun cooked-copy-command (&optional command)
  "Put COMMAND's input line on the kill ring."
  (interactive)
  (if-let* ((input (cooked-command-input (cooked--command-here command))))
      (progn (kill-new input) (message "cooked: copied command"))
    (user-error "cooked: this command has no recorded input")))

(defun cooked-copy-output (&optional command)
  "Put COMMAND's output region on the kill ring."
  (interactive)
  (pcase-let ((`(,beg . ,end) (cooked--command-region (cooked--command-here command))))
    (kill-new (buffer-substring-no-properties beg end))
    (message "cooked: copied output")))

(provide 'cooked-command)
;;; cooked-command.el ends here
