;;; cooked-mode-line.el --- What a cooked buffer reports about itself -*- lexical-binding: t; -*-

;;; Commentary:

;; Three ways a session says what it is doing without being asked: the mode line,
;; which is always there; sticky scroll, which is a header line naming the
;; command whose output a window is scrolled into; and the annotation beside its
;; name in a completion list, which is the mode line read from outside the buffer.
;;
;; All three read the command records, so this file sits above cooked-command.el
;; -- and the first two reach back into cooked-mode.el for three things the
;; interaction layer owns, declared below.  The direction is right: this is a
;; *reader* of state that layer maintains, which is the one shape a back-edge here
;; is allowed to have.

;;; Code:

(require 'cooked)
(require 'cooked-command)

;; Owned by the layer that requires this file: `cooked--foreground-label' by
;; cooked-keys.el, the rest by cooked-mode.el.  A label the foreground program
;; supplies, a record of who last held the keyboard, and the command the state
;; segment is a click away from.
(defvar cooked--foreground-label)
(defvar cooked--ownership)
;; And `cooked--progress' by cooked-osc.el, which parses OSC 9;4 down to the two
;; values `cooked-progress-function' is handed.  Declared rather than required
;; for the same reason as the two above: this file reads that state, it does not
;; keep it, and a `require' would only assert a load order cooked-mode.el
;; already fixes.
(defvar cooked--progress)
;; And `cooked-bell-pending' by cooked-mode.el, which sets it from the bell and
;; clears it when the buffer is looked at; both readers below only report it.
(defvar cooked-bell-pending)
(declare-function cooked-toggle-peek "cooked-peek")
(declare-function cooked--buffer-name-shows-title-p "cooked-osc")

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

(defface cooked-bell '((t :inherit warning))
  "Face for the `bell' mark on a session that rang while out of sight.

As loud as `cooked-peek', because it is the same kind of thing: a state that
wants the user to come and look, which is the whole of what it is for."
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

(defun cooked--mode-line-quote (text)
  "TEXT with every `%\=' doubled, so the mode line prints it and never reads it.

The result of a `:eval\=' is not text, it is another mode-line construct, so a
string handed back from one is scanned again for `%\='-specifiers before it is
displayed.  Almost everything this file puts in the mode line is therefore an
injection site, and two of them take the child\='s own bytes: `%b\=' in a window
title becomes the buffer name, and a `%\=' before the truncation cut can leave a
lone specifier character that swallows whatever the next segment starts with.
Neither is a security hole on its own -- the specifier set is a fixed list of
things about this frame -- but it is a child choosing what the mode line says,
and it is the same shape of mistake as an OSC 7 payload choosing a TRAMP host.

It also has to be applied to cooked\='s *own* text, which is the part that is
easy to miss: `cooked-progress-label\=' writes a literal percentage, and `%]\='
is a real specifier -- the one closing a nested group -- so an unescaped
`[42%]\=' displays as `[42\=', with nothing to say where the rest went.

`replace-regexp-in-string\=' rather than a hand-rolled walk because it carries
the text properties of the parts it keeps, and every caller here is passing
something already propertized with a face."
  (replace-regexp-in-string "%" "%%" text t t))

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
the better one.  The title also stands down when
`cooked--buffer-name-shows-title-p\=' says the buffer is already named after
it, so printing it again would only spend columns on a word already on
screen."
  (or (and (not (cooked--buffer-name-shows-title-p))
           cooked-title
           (not (string-empty-p cooked-title))
           cooked-title)
      cooked--foreground-label))

(defun cooked--mode-line-bell ()
  "The `bell\=' mark, while `cooked-bell-pending\=' says it is owed."
  (when cooked-bell-pending
    (propertize " bell" 'face 'cooked-bell
                'help-echo "cooked: this session rang while out of sight")))

(defun cooked--mode-line ()
  "Compact indicator: what is running, who owns the keyboard, how it went."
  ;; A dead session's buffer-locals do not decay -- they hold whatever they last
  ;; said, forever -- so reporting the state of a child that exited some minutes
  ;; ago is not stale information, it is wrong information wearing the same
  ;; clothes as the live kind.  The exit status is the only thing still true.
  ;; The bell is the exception: it says something happened, not what is going
  ;; on, so it stays true after the child is gone -- and a build that rang to
  ;; say it was done and then exited is the case it most exists for.
  (if cooked--exit
      (concat (propertize (format " exited %s" cooked--exit)
                          'face (if (eql cooked--exit 0) 'cooked-success 'cooked-failure))
              (cooked--mode-line-bell))
    (let ((state (cooked--mode-line-state))
          (subject (cooked--mode-line-subject))
          (code (cooked-last-exit-code)))
      (concat
       ;; Only when the child says it is somewhere else.  A local session is
       ;; the overwhelming majority and pays nothing; a remote one is where the
       ;; state word starts meaning something different, and saying which host
       ;; is what keeps that from reading as cooked being erratic across hosts.
       (when (cooked--foreign-host-p)
         (propertize (concat " @" (cooked--mode-line-quote
                                   (car (split-string cooked--host "\\."))))
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
       (cooked--mode-line-bell)
       ;; Quoted, not formatted: both of `cooked--mode-line-subject''s sources are
       ;; the child's own bytes -- a title it set, or the name of the program it
       ;; is running -- so a `%' in either is a specifier unless it is doubled
       ;; here.  Truncation happens first, so the two characters a doubled `%'
       ;; costs are not charged against the 24 columns the user asked for.
       (when subject
         (propertize (concat " " (cooked--mode-line-quote
                                  (truncate-string-to-width subject 24 nil nil t)))
                     'face 'shadow))
       (cooked--mode-line-progress)
       (when code
         (concat
          " "
          (apply #'propertize (number-to-string code)
                 'face (if (zerop code) 'cooked-success 'cooked-failure)
                 (cooked--mode-line-click
                  #'cooked-goto-last-command
                  "cooked: last exit status.  mouse-1: go to that command"))))))))

;;;; In a completion list
;;
;; What a picker says beside a session's name: the mode line's facts, asked of a
;; buffer that is not the current one.  Here and not in cooked-consult.el, because
;; nothing about it is consult's -- it is completion metadata, which vertico, the
;; default completion UI and anything else reading `completion-metadata' all
;; honour -- and a picker built on plain `completing-read' must get it without
;; loading a package it does not use.  Here and not in cooked-mode.el, because it
;; is the same report as `cooked--mode-line' in another place, and the faces that
;; say how a command went are already defined above.

(defun cooked--annotation-status ()
  "What this session is doing, in one or two words, for a completion annotation.

A running command first, named by its own line: the running command has no
record -- see `cooked--running-anchor' -- so it is read from
`cooked--command-input', which is live for exactly as long as the anchor is.
Otherwise the last command's exit status if it failed, and `idle' if it did
not or if there has been no command at all.  A zero status is not spelled out:
a list of sessions reading `exit 0' down one column is noise around the one
that says something else.

A dead session says how the child went and nothing more, for the reason
`cooked--mode-line' gives: its buffer-locals hold whatever they last said, and
reporting a command as running in a session that exited is wrong rather than
stale."
  (cond
   (cooked--exit
    (propertize (format "exited %s" cooked--exit)
                'face (if (eql cooked--exit 0) 'cooked-success 'cooked-failure)))
   ((cooked--running-anchor)
    (let ((input (and cooked--command-input
                      (string-trim (replace-regexp-in-string
                                    "[ \t\n]+" " " cooked--command-input))))
          (running (if cooked--command-started-at
                       (concat "running " (cooked--command-duration
                                           cooked--command-started-at))
                     "running")))
      (if (and input (not (string-empty-p input)))
          (concat running ": " (truncate-string-to-width input 32 nil nil t))
        running)))
   ((when-let* ((code (cooked-last-exit-code)))
      (and (not (eql code 0))
           (propertize (format "exit %s" code) 'face 'cooked-failure))))
   (t "idle")))

(defun cooked-buffer-annotation (buffer)
  "A one-line account of the cooked session in BUFFER, for a completion list.

BUFFER is a buffer or its name, since a completion table hands over the
candidate string and a consult source hands over the buffer itself.  Nil for
anything that is not a cooked buffer, so this can sit on a table that mixes
them.

Five fields, each left out when it has nothing to say: what the session is
doing (see `cooked--annotation-status'), `bell' when it rang while out of
sight (see `cooked-bell-pending'), the title the child set, the directory its
shell is in, and the input mode when it is anything but the ordinary one.
The bell sits second, beside the status, because a picker is where someone
goes looking for the session that wants them, and a mark further right is
easier to miss.
The directory is `default-directory', which OSC 7 keeps as a TRAMP name once the
shell is on another host, and it is abbreviated only when local: abbreviating a
remote name asks TRAMP for the home directory at the far end, and a completion
list redrawn per keystroke must not be what opens a connection.

The title is dropped when it only repeats the running command, which is what a
shell\\='s title hook usually sets it to."
  (when-let* ((buffer (get-buffer buffer))
              ((buffer-live-p buffer)))
    (with-current-buffer buffer
      (when (derived-mode-p 'cooked-mode)
        (let* ((status (cooked--annotation-status))
               (title (and cooked-title
                           (not (string-empty-p cooked-title))
                           (not (and cooked--command-input
                                     (equal (string-trim cooked-title)
                                            (string-trim cooked--command-input))))
                           (truncate-string-to-width cooked-title 32 nil nil t)))
               (directory (if (file-remote-p default-directory)
                              default-directory
                            (abbreviate-file-name default-directory)))
               (mode (unless cooked--exit
                       (pcase cooked--input-mode
                         ('semi (propertize "semi" 'face 'shadow))
                         ('still (propertize "still" 'face 'cooked-still))
                         ('frozen (propertize "frozen" 'face 'cooked-peek)))))
               (bell (and cooked-bell-pending (propertize "bell" 'face 'cooked-bell)))
               (fields (list status bell title directory mode))
               (text (concat "  " (string-join (delq nil fields) "  "))))
          ;; Appended, so the faces set on a field above win over the dim one the
          ;; completion UI gives an annotation as a whole.
          (add-face-text-property 0 (length text) 'completions-annotations t text)
          text)))))

(defun cooked--buffer-affixation (names)
  "NAMES with `cooked-buffer-annotation' as a suffix, in one aligned column.

An `affixation-function' rather than only the `annotation-function', because
an annotation is appended directly to its candidate and the names of cooked
buffers differ in length by as much as the directories in them do -- so four
fields read as a ragged edge unless something pads them to one column, and only
a function that sees every name at once can know how far."
  (let ((width (apply #'max 0 (mapcar #'string-width names))))
    (mapcar (lambda (name)
              (list name ""
                    (if-let* ((annotation (cooked-buffer-annotation name)))
                        (concat (make-string (- width (string-width name)) ?\s)
                                annotation)
                      "")))
            names)))

(defun cooked-buffer-completion-table ()
  "A completion table of cooked buffer names, annotated with what each is doing.

For `completing-read', and carrying its annotations as metadata so that every
completion UI shows them without anything else loaded.  Most recently used
first, as `buffer-list' has them, and left in that order: alphabetical is the
wrong order for switching.

The category is `cooked-buffer' rather than `buffer', and deliberately.
marginalia keeps an annotator of its own for `buffer' that takes precedence
over the table's, so under that category a marginalia user would see mode and
size where this table says what the session is doing -- the one thing the
table exists to say.  The cost is that a tool keyed on `buffer' does not
recognise these as buffers without being told: for embark that is
\(add-to-list \\='embark-keymap-alist \\='(cooked-buffer . embark-buffer-map))."
  (let (names)
    (cooked--dolist-buffers (push (buffer-name) names))
    (setq names (nreverse names))
    (lambda (string predicate action)
      (if (eq action 'metadata)
          `(metadata (category . cooked-buffer)
                     (annotation-function . cooked-buffer-annotation)
                     (affixation-function . cooked--buffer-affixation)
                     (display-sort-function . identity)
                     (cycle-sort-function . identity))
        (complete-with-action action names string predicate)))))

;;;; Progress
;;
;; What OSC 9;4 turns into on screen.  `cooked-osc.el' owns the parsing and the
;; state; this owns the only thing anybody sees, and it is a separate function
;; from the mode line proper so that swapping it out does not mean rewriting the
;; rest of the segment.

(defface cooked-progress '((t :inherit shadow))
  "Face for a running OSC 9;4 progress indicator in the mode line.

As quiet as the other things the mode line merely reports.  A progress bar is
already the most eye-catching thing a child can put on screen by sheer rate of
change, and colouring it as well would make an ordinary build look like a
warning.  `error\=' and `paused\=' do get their own faces, because those *are*
the states worth looking at."
  :group 'cooked)

(defcustom cooked-progress-function #'cooked-progress-label
  "Function rendering the child's progress, or nil to show none.

Called with two arguments, STATE and PERCENT -- see `cooked--progress\=' for
what each may be -- and returns a string for the mode line, or nil for nothing.
Called on *every* redisplay of a cooked buffer, including with STATE nil when
there is no progress to show, which is what gives an animated renderer somewhere
to stop itself.

The default needs nothing that is not already in Emacs, and that is the point of
the indirection rather than an accident of it: progress is exactly the sort of
thing a user already has a package for -- spinner.el, or a graphical bar built
out of `:align-to\=' -- and a terminal emulator that shipped one of those as a
hard dependency would be spending everybody's install on a garnish.  A
replacement is free to ignore the mode line entirely and return nil, having put
the state wherever it would rather have it.

Two obligations, both from being called out of redisplay.  It must not
`message\=', prompt, or otherwise take the echo area, and it must not depend on
being called a particular number of times: redisplay runs when Emacs feels like
it, several times for one change and not at all for the next.  Signalling is
survivable -- `cooked--mode-line-progress\=' catches it and shows nothing -- but
it is caught silently, so a renderer under development wants testing outside
redisplay first.

Any `%\=' in the returned string is escaped before it reaches the mode line, so
a renderer writes `42%\=' and means it."
  :type '(choice (const :tag "Plain text, no packages needed" cooked-progress-label)
                 (const :tag "Nothing" nil)
                 function)
  :group 'cooked)

(defun cooked-progress-label (state percent)
  "Render STATE and PERCENT as text: the default `cooked-progress-function\='.

Four states and one number between them, so the whole vocabulary is here:
`[42%]\=', `[...]\=', `[err 73%]\=', `[paused 25%]\='.  Bracketed because the
mode line is a row of unlabelled fragments and a bare `42%\=' beside an exit
status reads as one more of them; the brackets are what say the number belongs
to something still happening.

The percentage is optional on every state that can carry one at all, and the
word alone is the answer when it is missing -- `[err]\=' rather than `[err
0%]\=', which would claim the child had told us something it did not."
  (when state
    ;; Built as a word and a number joined by a space, rather than four format
    ;; strings, because the number is optional on three of the four states and
    ;; the alternative is either eight format strings or a `[err ]' with the gap
    ;; still in it.
    (let* ((word (pcase state
                   ('indeterminate "...")
                   ('error "err")
                   ('paused "paused")))
           (number (and percent
                        (not (eq state 'indeterminate))
                        (format "%d%%" percent)))
           (face (pcase state
                   ('error 'cooked-failure)
                   ('paused 'cooked-peek)
                   (_ 'cooked-progress))))
      (propertize (format "[%s]" (string-join (delq nil (list word number)) " "))
                  'face face))))

(defun cooked--mode-line-progress ()
  "The progress segment, or nil.

`cooked-progress-function\=' is a user-supplied function running inside
redisplay, which is the one place in Emacs where a failure is genuinely
expensive: the mode line is redrawn for every frame of every window showing this
buffer, so a renderer that signals once signals continuously.

Hence a bare `condition-case\=' and not `cooked--protect-seam\='.  The seam
wrapper is the right tool everywhere else and the wrong one here for its best
feature -- it `message\='s what went wrong -- and a `message\=' from redisplay
is a side effect in a function that is supposed to be a rendering, the same
objection `cooked--schedule-integration-hint\=' exists to answer.  A broken
renderer shows nothing, and `cooked-debug\=' is where you go to see why."
  (when cooked-progress-function
    (when-let* ((text (if cooked-debug
                          (funcall cooked-progress-function
                                   (car cooked--progress) (cdr cooked--progress))
                        (condition-case nil
                            (funcall cooked-progress-function
                                     (car cooked--progress) (cdr cooked--progress))
                          (error nil)))))
      (concat " " (cooked--mode-line-quote text)))))

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
