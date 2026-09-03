;;; cooked-mode-line.el --- What a cooked buffer reports about itself -*- lexical-binding: t; -*-

;;; Commentary:

;; Two ways a session says what it is doing without being asked: the mode line,
;; which is always there, and sticky scroll, which is a header line naming the
;; command whose output a window is scrolled into.
;;
;; Both read the command records, so this file sits above cooked-command.el --
;; and both reach back into cooked-mode.el for three things the interaction layer
;; owns, declared below.  The direction is right: this is a *reader* of state that
;; layer maintains, which is the one shape a back-edge here is allowed to have.

;;; Code:

(require 'cooked)
(require 'cooked-command)

;; Owned by cooked-mode.el, which requires this file.  A label the foreground
;; program supplies, a record of who last held the keyboard, and the command the
;; state segment is a click away from.
(defvar cooked--foreground-label)
(defvar cooked--ownership)
(declare-function cooked-toggle-peek "cooked-mode")

(defface cooked-failure '((t :inherit error))
  "Face for a non-zero exit status in the mode line."
  :group 'cooked)

(defface cooked-success '((t :inherit success))
  "Face for a zero exit status in the mode line."
  :group 'cooked)

(defface cooked-still '((t :inherit shadow))
  "Face for the `still' indicator in the mode line.

Quieter than `cooked-peek', and deliberately: nothing is being held back in
`still' -- the child is drawing, the buffer is current, only the view is
staying where it was put.  It is worth saying, not worth warning about."
  :group 'cooked)

(defface cooked-peek '((t :inherit warning))
  "Face for the `frozen' indicator in the mode line.

Peeking is otherwise invisible, and a user who has forgotten they toggled out
has no way to tell that from a wedged child: keys simply stop reaching it.  This
is what makes the state visible."
  :group 'cooked)

;;;; The mode line
;;
;; What the mode line says about a session: the faces above colour it, and the
;; hint is the one thing it volunteers rather than reports.

(defcustom cooked-integration-hint t
  "Whether to say once, per session, that no shell integration is loaded.

The mode line grows a `bare\=' tag the moment a session turns out to be
unmarked, which is enough for anyone who already knows what it means and
nothing at all for anyone who does not.  This is the sentence that closes that
gap, and it fires once: the state is permanent for the life of the child, so
repeating it would only ever be noise."
  :type 'boolean :group 'cooked)

(defcustom cooked-integration-hint-delay 3
  "Seconds to wait for a first OSC 133 mark before saying there is none.

A grace period rather than a guess at what is slow: the marks arrive with the
first prompt, so the only thing being waited out is the child\='s own startup --
a `.zshrc\=' that compiles its completion dump, a shell behind an `ssh\=' that
has not connected yet.  Long enough that a working setup is never accused, short
enough that a broken one is not left to be discovered."
  :type 'number :group 'cooked)

(defconst cooked--integration-hint
  "no shell integration in this session; source shell-integration/cooked.zsh \
from your shell\='s rc"
  "What the `bare\=' tag means, in a sentence.

One string with two readers -- `cooked--mode-line-bare\=' hangs it off the tag
as a `help-echo\=' and `cooked--schedule-integration-hint\=' says it once in the
echo area -- because a tag and a message that explain the same state must not be
able to drift apart.")

(defun cooked--mode-line-bare (state)
  "The `bare\=' tag beside STATE, when no OSC 133 mark has ever arrived.

Not shown beside `raw\='.  That *word* -- not the policy behind it, which a
password read also reaches -- is printed only where `cooked--policy\=' fell
through to its own default, which is exactly this condition, so the tag there
would restate the word next to it.  Beside `alt\=' and `secret\=' it still earns
its place: those are positive readings of the child that say nothing at all
about the shell, and the tag is what explains why no record will be filed for
what is happening.

It is a fact about the host rather than a guess about the child, which is what
makes it worth saying at all -- it is the thing that explains why the buffer
behaves differently here than it does at home.  Latched through
`cooked--semantic-seen\=', so a marked session midway through a command does not
blink the tag on and off."
  (unless (or cooked--semantic-seen (equal state "raw"))
    (propertize " bare" 'face 'shadow 'help-echo cooked--integration-hint)))

(defun cooked--schedule-integration-hint (buffer)
  "Say once, in BUFFER, that no OSC 133 mark ever arrived.

On a timer rather than from the mode line, because the mode line is the wrong
place to learn it from twice over: `:eval\=' runs during redisplay, where a
`message\=' is a side effect in a function that is supposed to be a rendering,
and it runs from the first frame -- before the child has started, when every
session on earth is momentarily unmarked.  Waiting is what makes the answer
mean anything.

Not rescheduled afterwards.  A shell that sources the snippet later starts being
believed at once, because everything downstream reads `cooked--semantic-seen\='
directly; it is only this sentence that does not come back, and a second copy of
it would be worth less than the silence.  What does come back is the `bare\='
tag\='s `help-echo\=', which carries this same `cooked--integration-hint\=' for
as long as the state lasts."
  (run-at-time
   cooked-integration-hint-delay nil
   (lambda ()
     (when (buffer-live-p buffer)
       (with-current-buffer buffer
         (when (and cooked-integration-hint
                    cooked--session
                    (not cooked--semantic-seen))
           (message "cooked: %s" cooked--integration-hint)))))))

(defun cooked--mode-line-click (command help)
  "Property list making mode-line text run COMMAND on a click, described by HELP.

`down-mouse-1\=' rather than `mouse-1\=' so the action fires on the press, as
term.el and eat both do -- a mode-line indicator that waits for the release
feels broken next to every other one in the frame."
  (list 'mouse-face 'mode-line-highlight
        'help-echo help
        'local-map (make-mode-line-mouse-map 'down-mouse-1 command)))

(defun cooked--mode-line-state ()
  "The state word: who owns the keyboard, and how well that is known.

`cooked--policy\=' tells five situations apart and this says all five, because
the three it used to spell `raw\=' are not one state told badly -- they are a
marked prompt the shell is editing itself, a marked command the shell announced,
and a genuine unknown.  Spelling them alike is what made a session read as
unreliable the moment it went remote: `prompt\=' is where a bare shell at the far
end of an `ssh\=' sits, and it is doing exactly what it should.

Echo state is an overlay on the policy rather than one of its values, but it
subsumes it here: a password read always forwards keys, so `raw secret\=' says
nothing `secret\=' does not already imply."
  (if (cooked--secret-p)
      "secret"
    (pcase (cooked--policy)
      ('cooked "edit")
      ('prompt "prompt")
      ('command "run")
      ('alt "alt")
      (_ "raw"))))

(defun cooked--mode-line-subject ()
  "What the child is running, in as many words as are known.

The title first: it is the shell\='s own summary, and a shell that sets one is
saying something `comm\=' cannot -- arguments, an `ssh\=' destination, a `make\='
target.  `cooked--foreground-label\=' is the fallback, and it is the one that
matters, because it needs no shell integration at all and so answers in exactly
the `bare\=' session where there is no title to have.  That is what tells `htop\='
from a shell editing its own line, which the state word alone cannot.

Never both.  They are two accounts of one thing, and the mode line has room for
the better one.  The title also stands down entirely under
`cooked-buffer-name-follows-title\=', where the buffer is already named after it
and printing it again spends columns on a word already on screen."
  (or (and (not cooked-buffer-name-follows-title)
           cooked--title
           (not (string-empty-p cooked--title))
           cooked--title)
      cooked--foreground-label))

(defun cooked--mode-line ()
  "Compact indicator: what is running, who owns the keyboard, how it went."
  ;; A dead session's buffer-locals do not decay -- they hold whatever they last
  ;; said, forever -- so reporting the state of a child that exited some minutes
  ;; ago is not stale information, it is wrong information wearing the same
  ;; clothes as the live kind.  The exit status is the only thing still true.
  (if cooked--exit
      (propertize (format " exited %s" cooked--exit)
                  'face (if (eql cooked--exit 0) 'cooked-success 'cooked-failure))
    (let ((state (cooked--mode-line-state))
          (subject (cooked--mode-line-subject))
          (code (cooked-last-exit-code)))
      (concat
       ;; Only when the child says it is somewhere else.  A local session is
       ;; the overwhelming majority and pays nothing; a remote one is where the
       ;; state word starts meaning something different, and saying which host
       ;; is what keeps that from reading as cooked being erratic across hosts.
       (when (cooked--foreign-host-p)
         (propertize (format " @%s" (car (split-string cooked--host "\\.")))
                     'face 'shadow))
       ;; The separator space stays outside the `propertize', so the
       ;; `mouse-face' run covers the word and not the gap before it -- the
       ;; mode line's own clickable segments pad from the outside for the same
       ;; reason, and a highlight that starts a column early reads as sloppy.
       " "
       (apply #'propertize state
              (cooked--mode-line-click
               #'cooked-toggle-peek
               "cooked: who owns the keyboard.  mouse-1: peek (C-c C-v)"))
       (cooked--mode-line-bare state)
       (pcase cooked--input-mode
         ('semi (propertize " semi" 'face 'shadow))
         ('still (propertize " still" 'face 'cooked-still))
         ('frozen (propertize " frozen" 'face 'cooked-peek)))
       (when subject
         (propertize (format " %s" (truncate-string-to-width subject 24 nil nil t))
                     'face 'shadow))
       (when code
         (concat
          " "
          (apply #'propertize (number-to-string code)
                 'face (if (zerop code) 'cooked-success 'cooked-failure)
                 (cooked--mode-line-click
                  #'cooked-goto-last-command
                  "cooked: last exit status.  mouse-1: go to that command"))))))))

;;;; Sticky scroll
;;
;; VS Code pins the command whose output is on screen to the top of the
;; viewport, so scrolling through a long log never loses sight of which
;; command produced it.  `cooked--command-region' and `cooked--command-around'
;; already know exactly where each command's output begins and ends, so this
;; is a header line, not new bookkeeping.

(defcustom cooked-sticky-scroll nil
  "Whether to pin the command whose output is on screen to a header line.

Off by default, and read once, in `cooked-mode', rather than consulted per
redisplay: a header line occupies a row of the window body, and
`cooked--window-rows' folds the window body height straight into a PTY resize
-- so this is a decision about how tall the child's screen is, taken when the
buffer is set up, not a display toggle.  Setting it in an existing buffer does
nothing until the next `cooked-mode'.

Off rather than merely optional because what it currently pins is wrong, and
knowingly so: `cooked--sticky-command' resolves the command at the window's
`window-start', so a session short enough that its whole history is on screen
shows the *first* command it ever ran and keeps showing it.  The header should
name the most recent command whose output the window is looking at.  That is a
fix to `cooked--sticky-command', not to this switch, and it has not been made
-- so the feature is here, tested, and off."
  :type 'boolean
  :group 'cooked)

(defcustom cooked-sticky-scroll-style 'window
  "What sticky scroll's header line pins to.

Only consulted when `cooked-sticky-scroll' is on.

`window' -- VS Code's own behaviour, and the default -- pins whichever
command this window's `window-start' currently sits inside: scroll up into an
old command's output and its command line takes the header; sit at the live
bottom with something running and the running command takes it.  Each window
answers separately, since each has its own `window-start'.

`running' ignores scroll position entirely and pins only the command actually
executing, so scrolling back through history never surfaces anything in the
header -- it reads empty whenever nothing is running, no matter where the
window is scrolled to."
  :type '(choice (const :tag "Whichever command you are scrolled into" window)
                 (const :tag "Only the currently running command" running))
  :group 'cooked)

(defface cooked-sticky-header '((t :inherit header-line))
  "Face for the pinned command line in sticky scroll's header."
  :group 'cooked)

(defun cooked--sticky-command (window)
  "The command `cooked--sticky-header' should pin WINDOW's header to, or nil.

Under `cooked-sticky-scroll-style' `window' this is whatever
`cooked--command-around' finds at WINDOW's `window-start' -- point
deliberately never enters into it, so moving point elsewhere in the buffer,
in a window that is not the one being redisplayed, cannot flicker this one's
header.  Under `running' it is always resolved at `(point-max)', which is
`cooked--command-around''s own way of naming \"whatever is live right now\":
the command still running, or the empty prompt being typed at if nothing is,
regardless of where WINDOW happens to be scrolled."
  (cooked--command-around (if (eq cooked-sticky-scroll-style 'running)
                              (point-max)
                            (window-start window))))

(defun cooked--sticky-label (input width)
  "Render INPUT, a submitted command line, to fit in WIDTH columns.

Multi-line input is collapsed to its first line plus an explicit ellipsis
rather than left to wrap or to however `truncate-string-to-width' would cut a
literal embedded newline -- a header line is one row, and the later lines of
a pasted command are not what a passer-by scrolled into its output needs."
  (let* ((first-line (car (split-string input "\n")))
         (label (if (string-search "\n" input) (concat first-line " …") first-line)))
    (truncate-string-to-width label (max 1 width) nil nil t)))

(defun cooked--sticky-header ()
  "Header line: the command whose output this window is scrolled into.

Installed once, in `cooked-mode' and only under `cooked-sticky-scroll', and
never removed for the rest of the buffer's life.  Always returns a string
rather than nil, because once the header line exists what changes is what gets
drawn in it, never whether it is there: toggling existence would change the
window's body height, which `cooked--window-rows' folds straight into a PTY
resize, and doing that on every scroll into and out of sticky territory would
churn the child for nothing the user asked for.

Needs no hook of its own: redisplay re-evaluates a `:eval' header-line
construct whenever the window it belongs to is invalidated, and scrolling
already is that.  `selected-window' is temporarily the window actually being
redisplayed for exactly the duration of this call -- `display_mode_lines' in
xdisp.c swaps it in and restores it after -- which is what lets `window-start'
below name the right window without one being threaded through explicitly.

Suppressed on the alt screen (`cooked--alt'): it is a fixed rectangle the
child owns entirely, with no scrollback to pin against.  Suppressed too when
no command is found at all (scrolled above the first prompt, or a dead
session whose buffer-locals simply hold their last values, the same as
`cooked--mode-line'), and when the resolved command's `input' is nil, which
covers both a bare live prompt with nothing running yet and a command the
shell ran without cooked ever submitting it -- typed while the child owned
the keyboard.  Neither has a command line worth pinning."
  (if cooked--alt
      ""
    (let* ((window (selected-window))
           (command (cooked--sticky-command window))
           (input (and command (cooked-command-input command))))
      (if (and input (not (string-empty-p input)))
          (propertize (cooked--sticky-label input (window-max-chars-per-line window))
                      'face 'cooked-sticky-header)
        ""))))

(provide 'cooked-mode-line)
;;; cooked-mode-line.el ends here
