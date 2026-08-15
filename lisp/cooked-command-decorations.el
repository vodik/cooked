;;; cooked-command-decorations.el --- a fringe marker per finished command -*- lexical-binding: t; -*-

;;; Commentary:

;; Opt-in, and worth understanding before you do:
;;
;;   (use-package cooked
;;     :commands (cooked cooked-other-window)
;;     :config (require 'cooked-command-decorations))
;;
;; With this loaded, every command with a recorded OSC 133 exit code gets a bar
;; in the left fringe next to its prompt, coloured by whether it succeeded.
;; Click it, or put point in the command and press \\[cooked-command-decorations-menu],
;; for rerun / copy command / copy output.
;;
;; The reason it is a separate file is consistency rather than the argument the
;; `Completion integration' entry in bugs.org makes for that rule: that entry's
;; case for a separate file was specifically that a switch here cannot tell the
;; truth, because the shell-side half of completion runs whether or not Emacs is
;; listening.  Decorations have no shell-side half at all -- they are painted
;; from `cooked-command-finished-functions' and re-armed from
;; `cooked-row-rendered-function', both of which fire only inside this Emacs,
;; on cooked's own bookkeeping -- so there is no announcement that could go on
;; being sent to nobody.  This is a separate file because every other optional
;; layer in this codebase is one, not because loading it costs anything the way
;; loading `cooked-shell-completion' does.
;;
;; Without a shell that sends OSC 133, `cooked--commands' stays empty and
;; `cooked-command-finished-functions' is never called, so this does nothing --
;; silently and correctly.  There is nothing to opt out of in that case; there
;; is simply nothing to decorate.

;;; Code:

(require 'cooked)
(require 'cooked-mode)
(require 'seq)

(when (fboundp 'define-fringe-bitmap)
  ;; `224' is `#b11100000': three pixels at the left edge of the fringe, repeated
  ;; down every pixel row of the line, which is `diff-hl''s thin bar and vc-gutter
  ;; marks everywhere else.  A bar rather than one of Emacs' own round bitmaps
  ;; because `large-circle' is drawn to fill a fringe as wide as a character cell
  ;; and looks squashed in the 8 pixels a default fringe actually gives it; a bar
  ;; has no proportions to get wrong at any width, and reads as an edge marker
  ;; belonging to the row rather than as a glyph that lost a fight with the margin.
  (define-fringe-bitmap 'cooked-command-bar [224] nil nil '(center repeated)))

(defcustom cooked-command-decoration-bitmap 'cooked-command-bar
  "Fringe bitmap `cooked-command-decorations' draws per finished command.

Defaults to `cooked-command-bar', defined just above: a three-pixel bar down
the left edge of the fringe, coloured by
`cooked-command-decoration-success'/`-failure'.

Unlike `cooked--truncation-bitmap', which reads its bitmap out of
`fringe-indicator-alist' because truncation is an existing Emacs concept a
user may already have rebound, a coloured per-command marker has no standing
entry in that alist to defer to -- it is not a concept Emacs itself has an
opinion about -- so this is an ordinary `defcustom'.  Any bitmap works: the
ones `fringe-bitmaps' lists (\\[describe-variable] on that variable, or
`fringe-bitmap-p'), `large-circle' among them, or one of your own from
`define-fringe-bitmap'."
  :type 'symbol
  :group 'cooked)

(defface cooked-command-decoration-success '((t :inherit success))
  "Face for the fringe marker on a command that exited zero."
  :group 'cooked)

(defface cooked-command-decoration-failure '((t :inherit error))
  "Face for the fringe marker on a command that exited non-zero."
  :group 'cooked)

(defvar cooked-command-decorations--marker-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'cooked-command-decorations--click)
    (define-key map [left-fringe mouse-1] #'cooked-command-decorations--click)
    map)
  "Keymap on each fringe marker's `before-string'.

Both bindings name the same command because which event a fringe click
generates -- a plain `mouse-1' with `posn-area' reporting `left-fringe', or an
event already prefixed with the area -- is not settled by anything else in
this codebase; nothing here has read a click from the fringe before now.
Binding both is cheap insurance against picking the wrong one.")

(defun cooked-command-decorations--anchor (command)
  "Where to put COMMAND's fringe marker: its prompt marker, or its start marker.

The prompt marker names column 0 of the prompt's own first row and, per
`cooked-command''s docstring, is one a repaint cannot spoil -- a damaged row is
deleted whole and its markers collapse to the row's start, which is where this
one already sits.  Falls back to `start' for a command whose shell never sent
an `A' mark, which is the closest thing to a beginning there is for such a
command, same as `cooked--prompt-starts' falls back for navigation."
  (or (cooked-command-prompt command) (cooked-command-start command)))

(defun cooked-command-decorations--decoration-at (position command)
  "The overlay already decorating COMMAND at POSITION, if there is one.

Asked before painting, because both callers can arrive at a row that is already
decorated: `cooked-command-decorations--rearm\=' runs on every rewrite of a row,
and the rewrite that damaged the row may not have been one that emptied it."
  (seq-find (lambda (overlay)
              (eq (overlay-get overlay 'cooked-command-decoration) command))
            (overlays-at position)))

(defvar-local cooked-command-decorations--overlays nil
  "Weak table from a `cooked-command' to the one overlay decorating it.

A command has exactly one marker, and this is what says so.  Without it the
only way to ask whether a command is already decorated is to look at the
position it *should* be at, which answers the wrong question twice over: an
overlay that has drifted off its anchor is not found and a second one is made
beside it, and an overlay that has been stretched over half the buffer is found
at every position it now covers.  Both are states a drain really produces --
see `cooked-command-decorations--paint'.

Weak on its keys, so a command dropped from `cooked--commands' by the prune in
`cooked--discard-scrollback' takes its entry with it; nothing has to remember
to clean up after a session that has run for a day.")

(defvar-local cooked-command-decorations--floor 0
  "Buffer position below which every command is known to be decorated correctly.

Text below `cooked--screen-start' is never rendered again and its markers never
move again, so a command whose prompt row has settled into permanent scrollback
needs looking at exactly once more after it gets there -- and then never again.
This is how far the last sweep got: `cooked-command-decorations--rearm' walks
`cooked--commands' from the newest until it passes this, and then moves it up
to the screen it has just finished checking.

Zero rather than nil so the first sweep of a session walks the whole (short)
list, and clamped to `cooked--screen-start' on the way in rather than only
raised on the way out: `cooked--discard-scrollback' cuts text off the top of
the buffer, and every position left behind means less than it did.")

(defun cooked-command-decorations--decoration (command)
  "The live overlay decorating COMMAND, or nil if there is not one."
  (when-let* ((table cooked-command-decorations--overlays)
              (overlay (gethash command table))
              ((overlay-buffer overlay)))
    overlay))

(defun cooked-command-decorations--paint (command)
  "Put COMMAND\='s fringe marker on its prompt row, or move it back onto it.

Graphical frames only.  There is no sensible single-glyph substitute for a
coloured status marker, and spending a real column of every prompt line on one
is too high a tax, so a terminal frame gets no decoration -- an accepted gap in
the same spirit as the `fringe-mode\=' 0 gap `cooked--mark-truncation\=' has.

Uses an overlay\='s `before-string\=', never a `display\=' property on the
buffer\='s own text: `cooked--render-rows\=' deletes and reinserts whole rows, so
a text property dies with the row, and a `display\=' spec on a real character
costs that character a column.  `evaporate t\=' so `cooked--discard-scrollback\='
cleans the overlay up for free when the text it anchors to goes.

Idempotent, and that has to mean more than \"does not paint twice\": an overlay
is not a fact about a command, it is two markers, and a drain moves markers for
reasons having nothing to do with what they marked.  A drain that evicts rows
inserts their text at `cooked--screen-start\=', and an overlay sitting exactly
there swallows the insertion -- its start stays put while its end is carried to
the far side of the block.  So the check is not \"is something painted where I
want\" but \"is *this command\='s* overlay exactly where and how big it should
be\", and anything else is moved back into shape.

`cooked--commands\=' is the source of truth throughout: the colour is read from
the record\='s own exit code on every paint, so a marker re-armed a hundred
redraws later still says what the record says."
  (when (display-graphic-p)
    (when-let* ((anchor (cooked-command-decorations--anchor command))
                (pos (and (markerp anchor) (marker-position anchor)))
                ((< pos (point-max))))
      (let ((overlay (cooked-command-decorations--decoration command)))
        (cond
         ;; Already right: the overwhelming case, since every damaged row asks
         ;; about every command still on the screen.
         ((and overlay (= (overlay-start overlay) pos)
               (= (overlay-end overlay) (1+ pos))))
         ;; Right overlay, wrong span -- a scroll stretched or shifted it.
         (overlay (move-overlay overlay pos (1+ pos)))
         (t
          (setq overlay (make-overlay pos (1+ pos)))
          (overlay-put overlay 'evaporate t)
          (overlay-put overlay 'cooked-command-decoration command)
          (overlay-put overlay 'before-string
                       (propertize " "
                                   'display (list 'left-fringe
                                                 cooked-command-decoration-bitmap
                                                 (if (zerop (cooked-command-code command))
                                                     'cooked-command-decoration-success
                                                   'cooked-command-decoration-failure))
                                   'help-echo (cooked-command-decorations--help command)
                                   'pointer 'hand
                                   'keymap cooked-command-decorations--marker-map))
          (unless cooked-command-decorations--overlays
            (setq cooked-command-decorations--overlays
                  (make-hash-table :test #'eq :weakness 'key)))
          (puthash command overlay cooked-command-decorations--overlays)))))))

(defun cooked-command-decorations--add (command)
  "Paint COMMAND\='s marker, called from `cooked-command-finished-functions\='.

Only half the story, and the shorter half: this fires exactly once per command,
while the row it decorates can be rewritten any number of times afterwards.  See
`cooked-command-decorations--rearm\=', which is the other half and does not
replace this one -- a command that finishes on a row nothing damages again would
otherwise never be decorated at all."
  (cooked-command-decorations--paint command))

(defun cooked-command-decorations--rearm (_beg _end)
  "Re-paint the markers of every command this drain may have moved or unpainted.

The overlay a finished command gets carries `evaporate t\=' and rides on real
characters, and `cooked--render-rows\=' deletes a damaged row before rewriting
it -- so Emacs tears the overlay down, and since
`cooked-command-finished-functions\=' fires once per command, nothing would ever
put it back.  A resize damages every live row at once, so any command whose
prompt is still on screen loses its marker the first time the window changes
width.  Hence this, hung on `cooked-row-rendered-function\=': re-applied per
render rather than persisted, exactly as `cooked--fontify-links\=' re-runs
goto-addr over each freshly-rendered row.

The row it is called for is deliberately ignored, which fixes two bugs rather
than saving effort.  A drain inserts the evicted rows above the screen first,
and every overlay below that insertion is dragged along by it -- so on a scroll
the command needing attention is very often not the one just rendered.  Worse, a
prompt row that scrolls *off* the screen is rendered for the last time by the
drain that evicts it, while its marker is still stale, and the scrollback copy
that then owns the prompt is never rendered again.  Asking about the commands
rather than the row covers both, and is cheap: painting an already-correct
decoration is a hash lookup and two integer comparisons.

`cooked-command-decorations--floor\=' keeps that from walking the whole session.
`cooked--commands\=' is newest first and its anchors only increase, so the walk
stops at the first command already settled in permanent scrollback when the last
sweep ran.

Called after `cooked--relocate-marks\=', not during the render -- see
`cooked-row-rendered-function\=', which runs late for exactly this consumer."
  (let* ((screen (cooked--screen-start-position))
         (floor (if screen (min cooked-command-decorations--floor screen)
                  cooked-command-decorations--floor)))
    (catch 'done
      (dolist (command cooked--commands)
        (when-let* ((anchor (cooked-command-decorations--anchor command))
                    (pos (and (markerp anchor) (marker-position anchor))))
          (when (< pos floor)
            (throw 'done nil))
          (cooked-command-decorations--paint command))))
    (setq cooked-command-decorations--floor (or screen floor))))

(defun cooked-command-decorations--help (command)
  "Tooltip text for COMMAND's fringe marker."
  (format "%s\nexit %s -- mouse-1 for actions"
         (or (cooked-command-input command) "")
         (cooked-command-code command)))

(defun cooked-command-decorations--clear-live ()
  "Take the markers down while a full-screen program has the screen.

The alt screen is drawn over the same buffer positions the live primary rows
occupy, so a marker anchored to one of those rows would sit in the fringe beside
a running program\='s frame, saying something about a command that is nowhere on
it.  Scrollback markers are left alone: the buffer is narrowed to the alt screen
while it is up, so they are not on display to be wrong.

Nothing puts them back explicitly, and nothing needs to: restoring the primary
marks every row damaged, and `cooked-command-decorations--rearm\=' repaints from
that -- which is the whole reason the decoration is re-applied per render rather
than persisted."
  (when-let* ((screen (and cooked--alt (cooked--screen-start-position))))
    (dolist (overlay (overlays-in screen (point-max)))
      (when (overlay-get overlay 'cooked-command-decoration)
        (delete-overlay overlay)))))

(add-hook 'cooked-command-finished-functions #'cooked-command-decorations--add)
(setq cooked-row-rendered-function #'cooked-command-decorations--rearm)
(add-hook 'cooked-alt-change-hook #'cooked-command-decorations--clear-live)

;;;; The menu

(defun cooked-command-decorations--command-at (position)
  "The command a menu invoked at POSITION should act on.

Prefers a live decoration overlay's own record over
`cooked--command-around', since the overlay names the exact command the marker
was painted for even when more than one candidate could otherwise answer at
that position; falls back to `cooked--command-around' so the menu still works
from ordinary point rather than only from a click on a marker, which is what
makes \\[cooked-command-decorations-menu] keyboard-reachable rather than
mouse-only -- and what keeps it working on a terminal frame, where there is no
fringe and so no marker to aim at."
  (or (seq-some (lambda (overlay) (overlay-get overlay 'cooked-command-decoration))
                (overlays-at position))
      (cooked--command-around position)))

(defun cooked-command-decorations--rerun (command)
  "Resend COMMAND's input line through the ordinary submit path."
  (let ((input (cooked-command-input command)))
    (unless input
      (user-error "cooked: nothing to rerun"))
    (unless (and (cooked--input-state-p)
                (string-empty-p (or (cooked--pending-input) "")))
      (user-error "cooked: can only rerun at an empty prompt"))
    (cooked--history-record input)
    (cooked--send-input-string input)))

(defun cooked-command-decorations--copy-command (command)
  "Put COMMAND's input line on the kill ring."
  (if-let* ((input (cooked-command-input command)))
      (progn (kill-new input) (message "cooked: copied command"))
    (user-error "cooked: this command has no recorded input")))

(defun cooked-command-decorations--copy-output (command)
  "Put COMMAND's output region on the kill ring."
  (pcase-let ((`(,beg . ,end) (cooked--command-region command)))
    (kill-new (buffer-substring-no-properties beg end))
    (message "cooked: copied output")))

(defun cooked-command-decorations--act (command)
  "Offer the rerun / copy command / copy output menu for COMMAND."
  (pcase (read-multiple-choice
          (format "cooked command (exit %s)" (cooked-command-code command))
          '((?r "rerun" "resend the command line")
            (?c "copy command" "kill-ring the input line")
            (?o "copy output" "kill-ring the command's output")))
    (`(?r . ,_) (cooked-command-decorations--rerun command))
    (`(?c . ,_) (cooked-command-decorations--copy-command command))
    (`(?o . ,_) (cooked-command-decorations--copy-output command))))

(defun cooked-command-decorations-menu ()
  "Act on the command at point: rerun, copy command, or copy output.

Keyboard-reachable on purpose -- the click path below is the same menu with
the same three actions, not a second one only the mouse can reach.  Acts on
whatever `cooked-command-decorations--command-at' finds at point, which is the
command point is inside the output of, or whose prompt or input line point
sits on; see `cooked--command-around'."
  (interactive)
  (if-let* ((command (cooked-command-decorations--command-at (point))))
      (cooked-command-decorations--act command)
    (user-error "cooked: no command here")))

(defun cooked-command-decorations--click (event)
  "Act on the command whose fringe marker was clicked, from mouse EVENT."
  (interactive "e")
  (let ((position (posn-point (event-start event))))
    (if-let* ((command (and position (cooked-command-decorations--command-at position))))
        (cooked-command-decorations--act command)
      (user-error "cooked: no command here"))))

(define-key cooked-mode-map (kbd "C-c C-o") #'cooked-command-decorations-menu)

(provide 'cooked-command-decorations)
;;; cooked-command-decorations.el ends here
