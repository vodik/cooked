;;; cooked-command-search.el --- every buffer's commands, to jump to -*- lexical-binding: t; -*-

;;; Commentary:

;; Opt-in:
;;
;;   (use-package cooked
;;     :commands (cooked cooked-other-window)
;;     :config (require 'cooked-command-search))
;;
;; \\[cooked-command-search] offers every command every cooked buffer has run,
;; and jumps to the one you pick.  \\[cooked-command-search-act] picks one and
;; asks what to do with it instead: copy its line, copy its output, rerun it,
;; or -- for one still running -- interrupt it.
;;
;; Not shell history, and the contrast with `cooked-history' is the whole of
;; what this file is for.  That one reads the shell's history file and *types*
;; the pick; this reads the transcript's records and *goes to* it.  History
;; says what you typed.  This says where you ran it, how it went and what it
;; printed -- which neither the shell nor any other emulator's history can
;; answer, since only the buffer still holds the output.
;;
;; `consult-imenu' over `cooked--imenu-index' already gives one entry per
;; command for the buffer you are in.  What this adds is every buffer at once,
;; grouped by buffer; an exit status and an output size beside each; narrowing
;; to the failed, the succeeded or the running (a prefix argument asks which);
;; and the command that is still going, which the index cannot offer because it
;; has no record.
;;
;; Three decisions worth stating before reading the code.
;;
;; *The running command is not a record.*  `cooked--commands' holds finished
;; commands, and a `cooked-command' is built at the `D' mark because that is
;; what supplies its exit code; one built early would carry `code' 0, which
;; every reader of that field is entitled to read as success.  So the running
;; command is its own type, `cooked-command-search--running', built from the
;; live markers -- one per buffer at most, since one command runs at a time --
;; and no action written for a record can be handed it by accident.
;;
;; *A candidate goes stale by construction*, because the command can finish
;; between building the list and acting on the pick.  So nothing is decided
;; from the list: `cooked-command-search--resolve' asks the buffer again at
;; action time, and a running candidate whose anchor is no longer running
;; becomes the record that was built on that very marker.
;;
;; *A multiline command is named with its whitespace collapsed*, which is what
;; `cooked--command-name' already does for `imenu'.  The alternative -- joining
;; lines with a visible separator and capping a heredoc at its first line plus
;; "(+N lines)" -- shows where the lines broke, but it cannot match what it
;; does not show: the text behind the cap would have to be in the candidate
;; string and hidden, and every completion UI honours `invisible' differently,
;; if at all.  Collapsed, what matches is exactly what is displayed, in every
;; UI, and a word on the second line of a `for' loop is a word in the name.
;; The name is only ever a name: copying and rerunning read
;; `cooked-command-input', the original string, so nothing that sends a line
;; ever sees the collapsed form.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'cooked)
(require 'cooked-mode)

;;;; Candidates

(cl-defstruct (cooked-command-search--running
               (:constructor cooked-command-search--running-make) (:copier nil))
  "The command running in BUFFER when the list was built.

Deliberately not a `cooked-command'; see the commentary.  ANCHOR is the marker
`cooked--running-anchor' answered, held rather than copied: it is the marker the
finished record will be built on, so `eq' against it is how a candidate that has
gone stale finds its record, where a position would have been moved by any
scrollback trimmed in between.  Holding a marker that already exists costs
nothing; it is *making* markers per candidate that would."
  buffer anchor input started)

(cl-defstruct (cooked-command-search--finished
               (:constructor cooked-command-search--finished-make) (:copier nil))
  "The finished COMMAND record, in BUFFER."
  buffer command)

(defun cooked-command-search--buffer (candidate)
  "The buffer CANDIDATE belongs to."
  (if (cooked-command-search--running-p candidate)
      (cooked-command-search--running-buffer candidate)
    (cooked-command-search--finished-buffer candidate)))

(defun cooked-command-search--status (candidate)
  "Whether CANDIDATE is `running', `failed' or `succeeded'.
Those three are what narrowing chooses between."
  (cond ((cooked-command-search--running-p candidate) 'running)
        ((eql 0 (cooked-command-code (cooked-command-search--finished-command candidate)))
         'succeeded)
        (t 'failed)))

(defun cooked-command-search--collect ()
  "Every command in every cooked buffer, as (NAME . CANDIDATE) conses.

In display order: running commands first, then each buffer's finished ones
newest first, with the buffers in `buffer-list' order -- which puts the buffer
you were just in first.
There is no ordering *across* buffers by age to be had: a record carries no
time.  Grouping by buffer does the rest, since a completion UI orders its groups
by their first candidate, so every buffer with something running comes before
every buffer without.

NAME is computed here, in the candidate's own buffer, because the fallback for a
command with no recorded line is its prompt line, which is text in that buffer."
  (let (running finished)
    (cooked--dolist-buffers
      ;; Widened, since a full-screen program narrows its buffer to the alt
      ;; screen and the prompt a fallback name is read from lies above it.
      (save-restriction
        (widen)
        ;; Not in a session that has exited: its buffer-locals keep whatever
        ;; they last said, and a command reported running in a dead session
        ;; is wrong rather than stale.  The records it left are still offered.
        (when-let* (((not cooked--exit))
                    (anchor (cooked--running-anchor)))
          (push (cons (cooked--command-name cooked--command-input
                                            (marker-position anchor))
                      (cooked-command-search--running-make
                       :buffer (current-buffer) :anchor anchor
                       :input cooked--command-input
                       :started cooked--command-started-at))
                running))
        (dolist (command cooked--commands)
          (push (cons (cooked--command-name
                       (cooked-command-input command)
                       (or (cooked--command-prompt-position command)
                           (cooked--command-start-position command)))
                      (cooked-command-search--finished-make
                       :buffer (current-buffer) :command command))
                finished))))
    (nconc (nreverse running) (nreverse finished))))

(defun cooked-command-search--candidates (&optional filter)
  "Candidate strings for every command, keeping only FILTER's status if given.

Each string carries its candidate on the `cooked-command-search' property, which
is what a UI that keeps properties -- consult's -- reads directly.  Plain
`completing-read' hands back a string without them, so
`cooked-command-search--lookup' finds the original by name.

Names are made unique the way `cooked--imenu-index' makes them, for the
same reason: the pick is looked up by name, and five `make's under one
name are four commands nobody can reach.  The newest keeps the bare
name, being the one reached for.  Rebuilt on every invocation, like the
index: the buffers are rewritten at drain rate, and nothing here is
worth keeping current between two uses."
  (let ((seen (make-hash-table :test #'equal))
        candidates)
    (pcase-dolist (`(,name . ,candidate) (cooked-command-search--collect))
      (when (or (null filter) (eq filter (cooked-command-search--status candidate)))
        (let* ((name (or name cooked--imenu-unnamed))
               (n (1+ (gethash name seen 0))))
          (puthash name n seen)
          (push (propertize (if (= n 1) name (format "%s<%d>" name n))
                            'cooked-command-search candidate)
                candidates))))
    (nreverse candidates)))

(defun cooked-command-search--lookup (string candidates)
  "The candidate object named by STRING among CANDIDATES, or nil."
  (when-let* ((found (car (member string candidates))))
    (get-text-property 0 'cooked-command-search found)))

;;;; Describing one

(defun cooked-command-search--lines (beg end)
  "How many lines of output lie between BEG and END, spelled for an annotation."
  (let ((n (count-lines beg end)))
    (format "%d line%s" n (if (= n 1) "" "s"))))

(defun cooked-command-search--describe (candidate)
  "The annotation for CANDIDATE: how it went, and how much it printed.

An exit status for a finished command and `running' with how long for the one
that is not -- never an exit status for that, which is the claim its type exists
to keep it from making.  The output size is counted when the annotation is asked
for rather than when the list is built, so only the candidates a UI actually
shows are paid for."
  (let ((buffer (cooked-command-search--buffer candidate)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (save-restriction
          (widen)
          (if (cooked-command-search--running-p candidate)
              (let ((started (cooked-command-search--running-started candidate)))
                (concat
                 (if started
                     (format "running %s"
                             (format-seconds "%dd %hh %mm %z%ss"
                                             (- (float-time) started)))
                   "running")
                 (when-let* ((start cooked--command-start)
                             ((marker-position start)))
                   (concat "  " (cooked-command-search--lines start (point-max))))))
            (let* ((command (cooked-command-search--finished-command candidate))
                   (code (cooked-command-code command)))
              (concat
               (propertize (format "exit %s" code)
                           'face (unless (eql code 0) 'cooked-failure))
               (when (and (marker-position (cooked-command-start command))
                          (marker-position (cooked-command-end command)))
                 (pcase-let ((`(,beg . ,end) (cooked--command-region command)))
                   (concat "  " (cooked-command-search--lines beg end))))))))))))

(defun cooked-command-search--table (candidates)
  "A completion table over CANDIDATES that keeps their order and their groups.

`display-sort-function' is `identity' for the reason `cooked-history'
gives: left to itself `completing-read' sorts alphabetically, and
running-first, newest-first is the order that makes the list worth
reading.  The category is what embark and marginalia key on, should
anyone want to give these actions of their own."
  (let ((describe (lambda (string)
                    (when-let* ((candidate (cooked-command-search--lookup string candidates))
                                (text (cooked-command-search--describe candidate)))
                      (concat "  " text))))
        (group (lambda (string transform)
                 (if transform
                     string
                   (when-let* ((candidate (cooked-command-search--lookup string candidates))
                               (buffer (cooked-command-search--buffer candidate)))
                     (if (buffer-live-p buffer) (buffer-name buffer) "(killed)"))))))
    (lambda (string predicate action)
      (if (eq action 'metadata)
          `(metadata (category . cooked-command)
                     (group-function . ,group)
                     (annotation-function . ,describe)
                     (display-sort-function . identity)
                     (cycle-sort-function . identity))
        (complete-with-action action candidates string predicate)))))

;;;; Resolving and acting

(defun cooked-command-search--resolve (candidate)
  "CANDIDATE as it stands now, which need not be what it was when listed.

A running candidate still running is itself.  One whose anchor is no longer
the running command's has finished since, and becomes the record built on that
same marker -- `cooked--mark-command-end' builds the record on the markers the
`A' and `C' marks made, never on copies, so `eq' finds it exactly.  A finished
record is itself while its buffer still holds it; `cooked--discard-scrollback'
drops a record whose text it cut, and acting on one would act on text that is
not there.

Signals when there is nothing left to act on, rather than returning nil."
  (let ((buffer (cooked-command-search--buffer candidate)))
    (unless (buffer-live-p buffer)
      (user-error "cooked: that command's buffer has been killed"))
    (with-current-buffer buffer
      (if (cooked-command-search--running-p candidate)
          (let ((anchor (cooked-command-search--running-anchor candidate)))
            (if (eq anchor (cooked--running-anchor))
                candidate
              (if-let* ((command (seq-find (lambda (command)
                                             (or (eq anchor (cooked-command-prompt command))
                                                 (eq anchor (cooked-command-start command))))
                                           cooked--commands)))
                  (cooked-command-search--finished-make :buffer buffer :command command)
                (user-error "cooked: that command is no longer in its buffer"))))
        (unless (memq (cooked-command-search--finished-command candidate) cooked--commands)
          (user-error "cooked: that command is no longer in its buffer"))
        candidate))))

(defun cooked-command-search--show (buffer)
  "Select a window showing BUFFER, reusing one that already does."
  (pop-to-buffer buffer '((display-buffer-reuse-window display-buffer-same-window))))

(defun cooked-command-search--follow ()
  "Put point on the live tail of this buffer, following the child.

What coming back to a running server means: reading what it has printed since,
and going on reading.  The render's own answer for where a following point
goes, `cooked--point-after-input', rather than `point-max'; a peek ended the way
`cooked-interrupt' ends one; and the window pinned to the bottom the way a
drain pins it, since a server that has gone quiet sends no drain to do it."
  (cooked--resume-forwarding)
  (setq cooked--wandered nil)
  (let ((target (cooked--point-after-input)))
    (goto-char target)
    (cooked--pin-transcript-bottom (list (selected-window)) target (point-max)))
  (cooked--update-ghost-cursor))

(defconst cooked-command-search--actions
  '((jump        ?j "jump"        "go to it")
    (copy-input  ?c "copy command" "kill-ring its command line")
    (copy-output ?o "copy output"  "kill-ring what it printed")
    (rerun       ?r "rerun"        "resend its command line")
    (interrupt   ?i "interrupt"    "send it C-c"))
  "Every action, as (ACTION KEY NAME DESCRIPTION).")

(defun cooked-command-search--actions-for (candidate)
  "The actions that make sense for CANDIDATE.

A running command cannot be rerun, having not finished, and has no output to
copy that would not be however much has arrived so far; a finished one cannot be
interrupted."
  (if (cooked-command-search--running-p candidate)
      '(jump interrupt copy-input)
    '(jump copy-input copy-output rerun)))

(defun cooked-command-search-do (candidate action)
  "Do ACTION to CANDIDATE, after resolving it against the buffer as it is now.

ACTION is one of `jump', `copy-input', `copy-output', `rerun' and `interrupt'.
Every one of them is an existing verb: `cooked-copy-command',
`cooked-copy-output', `cooked-rerun-command' and `cooked-interrupt' each take
the record or act in the current buffer, and this only chooses the buffer.

Jumping to a finished command lands on its prompt, as `imenu' does, for the
reason `cooked-previous-command' gives.  Jumping to a running one lands on the
live tail instead, following.  Interrupting and rerunning show the buffer first:
a signal you cannot see land is not worth sending blind, which is
`cooked-interrupt's own rule, and a rerun is the same bargain."
  (let* ((candidate (cooked-command-search--resolve candidate))
         (buffer (cooked-command-search--buffer candidate)))
    (unless (memq action (cooked-command-search--actions-for candidate))
      (user-error (if (cooked-command-search--running-p candidate)
                      "cooked: cannot %s a command that is still running"
                    "cooked: cannot %s a command that has finished")
                  (nth 2 (assq action cooked-command-search--actions))))
    (if (cooked-command-search--running-p candidate)
        (pcase action
          ('jump (cooked-command-search--show buffer)
                 (cooked-command-search--follow))
          ('interrupt (cooked-command-search--show buffer)
                      (cooked-command-search--follow)
                      (cooked-interrupt))
          ('copy-input
           (if-let* ((input (cooked-command-search--running-input candidate)))
               (progn (kill-new input) (message "cooked: copied command"))
             (user-error "cooked: this command has no recorded input"))))
      (let ((command (cooked-command-search--finished-command candidate)))
        (pcase action
          ('jump (cooked-command-search--show buffer)
                 (goto-char (or (cooked--command-prompt-position command)
                                (cooked--command-start-position command))))
          ('copy-input (with-current-buffer buffer (cooked-copy-command command)))
          ('copy-output (with-current-buffer buffer (cooked-copy-output command)))
          ('rerun (cooked-command-search--show buffer)
                  (cooked-rerun-command command)))))))

;;;; Reading one

(defun cooked-command-search--read-filter ()
  "Ask which commands to offer: failed, succeeded or running."
  (pcase (car (read-multiple-choice
               "Offer only"
               '((?f "failed" "commands that exited non-zero")
                 (?s "succeeded" "commands that exited zero")
                 (?r "running" "the command still going in each buffer"))))
    (?f 'failed) (?s 'succeeded) (?r 'running)))

(defun cooked-command-search-read (&optional filter)
  "Read a command from every cooked buffer, and return its candidate.

FILTER, when non-nil, is `failed', `succeeded' or `running', and keeps
only those.  Narrowing is a prefix argument to the commands rather than
something typed into the minibuffer, because plain `completing-read' has
no narrowing of its own and a magic prefix in the input would be matched
as text by every completion style there is.  consult has real narrowing
keys, and the consult source uses them."
  (let ((candidates (cooked-command-search--candidates filter)))
    (unless candidates
      (user-error "cooked: no %scommands in any buffer"
                  (if filter (format "%s " filter) "")))
    (let ((choice (completing-read
                   (if filter (format "Command (%s): " filter) "Command: ")
                   (cooked-command-search--table candidates) nil t)))
      (or (cooked-command-search--lookup choice candidates)
          (user-error "cooked: no such command")))))

;;;###autoload
(defun cooked-command-search (&optional filter)
  "Jump to a command run in any cooked buffer.

A finished command is jumped to at its prompt; the one still running in
a buffer is jumped to at its live tail, following.  With a prefix
argument, ask whether to offer only the failed, the succeeded or the
running ones; from Lisp, FILTER is one of those symbols.  See
\\[cooked-command-search-act] for the other actions."
  (interactive (list (and current-prefix-arg (cooked-command-search--read-filter))))
  (cooked-command-search-do (cooked-command-search-read filter) 'jump))

;;;###autoload
(defun cooked-command-search-act (&optional filter)
  "Pick a command run in any cooked buffer, then choose what to do with it.

Jump, copy its command line, copy its output or rerun it -- or, for one still
running, jump, copy its line or interrupt it.  FILTER and the prefix argument
are as for `cooked-command-search'."
  (interactive (list (and current-prefix-arg (cooked-command-search--read-filter))))
  (let* ((candidate (cooked-command-search-read filter))
         (choices (mapcar (lambda (action)
                            (cdr (assq action cooked-command-search--actions)))
                          (cooked-command-search--actions-for candidate)))
         (key (car (read-multiple-choice "cooked command" choices))))
    (cooked-command-search-do
     candidate (car (seq-find (lambda (entry) (eq (nth 1 entry) key))
                              cooked-command-search--actions)))))

(provide 'cooked-command-search)
;;; cooked-command-search.el ends here
