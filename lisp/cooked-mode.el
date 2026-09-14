;;; cooked-mode.el --- Interaction for cooked terminals -*- lexical-binding: t; -*-

;;; Commentary:

;; The top of the interaction layer: `cooked-mode' itself, which keymap the
;; buffer wears when, keeping the child sized to its windows, attention and focus,
;; and what imenu, outline and bookmarks find in a transcript.  See cooked.el,
;; the main file, for what cooked is and how to install it.
;;
;; What a key becomes is cooked-keys.el, the maps are cooked-keymaps.el, and the
;; line's commands are cooked-input.el; this file says which map is installed and
;; when.  `cooked--refresh-keymap' is the join, and the layers below ask for it
;; through `cooked--refresh-hook'.

;; Two signals decide who owns the keyboard.  The kernel's line discipline
;; (`cooked--mode') identifies programs doing canonical reads, and OSC 133 marks
;; identify the shell's own prompt, which is always raw and so invisible to the
;; first signal.  Either one puts us in `input' state, where keys are ordinary
;; Emacs editing against a pending-input region; otherwise keys go straight to
;; the child.

;;; Code:

(require 'cl-lib)
(require 'format-spec)
(require 'seq)
(require 'comint)
(require 'cooked-util)
(require 'cooked-state)
(require 'cooked-deco)
(require 'cooked-command)
(require 'cooked-screen)
(require 'cooked-pending)
(require 'cooked-cursor)
(require 'cooked-graphics)
(require 'cooked-osc)
(require 'cooked-color)
(require 'cooked-mouse)
(require 'cooked-secret)
(require 'cooked-bell)
(require 'cooked-scrollback)
(require 'cooked-render)
(require 'cooked-session)
(require 'cooked-peek)
(require 'cooked-keys)
(require 'cooked-input)
(require 'cooked-keymaps)
(require 'cooked-completion)
(require 'cooked-shell-integration)
(require 'cooked-mode-line)

(cooked--declare-core)

(defvar cooked-mode-syntax-table (make-syntax-table comint-mode-syntax-table)
  "Syntax table for `cooked-mode\='.

Realized from `cooked-word-constituent-string\=' and
`cooked-word-boundary-string\=' by `cooked--realize-syntax-table\=', and realized
*into this very object* rather than rebuilt, so a customize reaches buffers that
already exist.  A rebuilt table would only be picked up by the next
`cooked-mode\=', which is not what changing a preference should mean.

Made with `comint-mode-syntax-table\=' as its *parent* rather than as a copy, and
that is what makes re-realizing possible at all: a character this file has not
spoken about is `nil\=' here and inherits, so undoing a previous realization is
setting those characters back to `nil\=' rather than trying to remember what
class they had before.")

(defvar cooked--syntax-overridden nil
  "Characters `cooked--realize-syntax-table\=' has given a class of their own.

Kept so the next realization can hand them back to the parent table.  Without
it, removing a character from `cooked-word-boundary-string\=' would leave it a
boundary forever.")

;; Defined by the two `defcustom's below, whose setters call this function and
;; so need it to exist first.
(defvar cooked-word-constituent-string)
(defvar cooked-word-boundary-string)

(defun cooked--realize-syntax-table ()
  "Put the two boundary customs into `cooked-mode-syntax-table\=', in place."
  (let ((table cooked-mode-syntax-table))
    ;; Hand back everything the last realization claimed.  `nil' means "ask the
    ;; parent", which is exactly the state these characters were in before.
    (dolist (ch cooked--syntax-overridden) (aset table ch nil))
    (setq cooked--syntax-overridden nil)
    (dolist (ch (string-to-list cooked-word-constituent-string))
      (modify-syntax-entry ch "w" table)
      (push ch cooked--syntax-overridden))
    (dolist (ch (string-to-list cooked-word-boundary-string))
      ;; Punctuation, not whitespace.  Both end a word, but whitespace is a
      ;; claim about layout that `skip-syntax-forward' users act on, and a box
      ;; corner is not a space.  Characters that already *are* whitespace are
      ;; left to the parent -- overriding them would be a no-op that this
      ;; function would then have to remember to undo.
      (unless (eq (char-syntax ch) ?\s)
        (modify-syntax-entry ch "." table)
        (push ch cooked--syntax-overridden)))))

(defcustom cooked-word-constituent-string "./~-_?#@&+="
  "Characters a word may run through in a cooked buffer.

Terminal output is mostly paths, URLs and identifiers, and Emacs' defaults cut
all three up: without this a double-click on `~/src/foo/bar.txt\=' takes `foo\=',
one on `items?id=42#top\=' takes `items\=', and one on `simon@example.com\='
takes `example.com\='.  The whole name is almost always the thing being pointed
at.  `%\=' needs no entry, being a word constituent already, so `a%20b\=' is one
word as it stands.

A colon is not here, and stays a boundary through
`cooked-word-boundary-string\=': it ends `main.c\=' in `main.c:42:\=' and
separates the entries of a PATH.  So a double-click on
`https://example.com/a?b=1\=' takes `//example.com/a?b=1\=', without its scheme;
a link is followed whole through `cooked-link\=' instead.

The same table edits the line at cooked\='s own prompt, which is Emacs text, so
\\[backward-kill-word] and evil\='s `dw\=' move by these words too: after
`git log --author=simon\=' one \\[backward-kill-word] kills `--author=simon\=',
where a shell\='s own line editor would kill `simon\='.

Set through customize and it reaches live buffers; see
`cooked-mode-syntax-table\='."
  :type 'string
  :group 'cooked
  :set (lambda (symbol value)
         (set-default symbol value)
         ;; `custom-declare-variable' calls the setter to establish the default
         ;; when the variable is not already bound, so this runs once at load
         ;; *before* its sibling below exists.  Guard on the variables rather
         ;; than on the function: the function is defined first and being
         ;; `fboundp' says nothing about whether it can run yet.  The explicit
         ;; call after both defcustoms does the first real realization.
         (when (and (boundp 'cooked-word-constituent-string)
                    (boundp 'cooked-word-boundary-string))
           (cooked--realize-syntax-table))))

(defcustom cooked-word-boundary-string "\"'`|:;,()[]{}<>$│─┌┐└┘├┤┬┴┼"
  "Characters that end a word in a cooked buffer, whatever else says otherwise.

Applied *after* `cooked-word-constituent-string\=', so a character named in both
is a boundary.  That ordering is the whole job of this variable, and it is worth
being plain about what the default does and does not buy.

Every character in the default is *already* a boundary in Emacs\=' own table --
the box-drawing ones are symbol constituents, not word constituents, so
\\[forward-word] and a double-click stop at them without help.  The list is
therefore belt-and-braces, and it earns its place in two ways rather than one:
it keeps them boundaries when someone widens
`cooked-word-constituent-string\=', and it says in one readable place which
characters a terminal buffer treats as furniture.  A double-click in a TUI with
two panes side by side stops at the border between them, because U+2502 is
furniture, not text.  That is all a syntax table can do: a region copied with
\\[kill-ring-save] holds every character between point and mark, and one
spanning both panes still takes the border with it.

One further reason the box-drawing entries cannot do harm and cannot do much
good: \\[forward-word] consults `find-word-boundary-function-table\\=' as well as
the syntax table, and that puts a boundary wherever the *script* changes.  A
box-drawing character is a different script from Latin text, so it ends a word
even when its syntax class says `w\\='.  Syntax is not the whole story for
anything non-ASCII, which is worth knowing before adding a character here and
expecting it to be load-bearing.

Whitespace characters are ignored: they already end a word, and claiming them
would be a no-op this then has to remember to undo.  Set through customize and
it reaches live buffers; see `cooked-mode-syntax-table\='."
  :type 'string
  :group 'cooked
  :set (lambda (symbol value)
         (set-default symbol value)
         ;; `custom-declare-variable' calls the setter to establish the default
         ;; when the variable is not already bound, so this runs once at load
         ;; *before* its sibling below exists.  Guard on the variables rather
         ;; than on the function: the function is defined first and being
         ;; `fboundp' says nothing about whether it can run yet.  The explicit
         ;; call after both defcustoms does the first real realization.
         (when (and (boundp 'cooked-word-constituent-string)
                    (boundp 'cooked-word-boundary-string))
           (cooked--realize-syntax-table))))

(cooked--realize-syntax-table)

(defun cooked-toggle-rejoin-wrapped-lines ()
  "Flip `cooked-rejoin-wrapped-lines\=', here and for buffers made after this.

A command rather than a menu item that sets the variable, because the variable
is only half of what has to move: `cooked-mode\=' derives `truncate-lines\=' from
it, and every drain since is asked with the value in force, so a bare `setq\='
would change what happens to output arriving from now on and leave this
buffer's own wrapping set the way it was.  The two would then disagree, quietly,
which is exactly what a switch on a menu must not do.

The seam is a third half that needs nothing here, and `cooked--split-seam\='
says why: at the moment the flag flips, whatever head the buffer holds is one
the emulator is right about, so a rewrap arriving before the next drain still
resumes the line where the buffer wraps it.  What the emulator must stop
counting is the head the *next* rows are handed over without, and that is the
drain's to notice.

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

(defvar cooked-mode-map)                ; `define-derived-mode' below makes it

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

There is deliberately no `self-insert-command\\=' remap beside it.  A remap
*replaces* `this-command\\=' rather than layering over it, so it would take every
ordinary keystroke out of `cooked-snap-commands\\=' and break the snap until the
replacement was named there too.  The substitution below does the same job
without that trap.

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
`C-z', leaving \`V' forwarded to the child instead of starting a selection.

*A handler here usually runs inside the drain*, and the drain has bound
`inhibit-read-only' and `buffer-undo-list' so that the emulator can rewrite rows
the user may not -- an OSC 133 `prompt-end' or the alternate screen going up
reaches `cooked--refresh-keymap' without ever leaving `cooked--apply'.  A
handler that edits the buffer there is therefore neither refused by the
`read-only' property nor recorded in the history, which makes a wrong edit
silent and unrecoverable rather than a visible error.  Do not edit buffer text
from this hook, and be careful what you call that might: it is how evil's own
insert-state tidying came to blank a screen row, and why `cooked-evil' now
switches that tidying off rather than trusting the protection.  See
`cooked-evil--no-unbidden-edit' and
`cooked-state-change-hook-runs-inside-the-childs-edit', which pins the premise."
  :type 'hook
  :group 'cooked)

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
(defcustom cooked-selection-render 'frozen
  "What the render does while an ordinary Emacs selection is active.

The same claim `cooked-evil-visual-state-render\=' makes, for everyone who is
not running evil: a selection says something about a region of text, and text
being rewritten underneath it turns the claim into a lie.  Without it a plain
\\[set-mark-command] or a mouse drag is clobbered by the next drain.  A jump that
only moves point, like `consult-line\=', makes no selection and so freezes
nothing; point stays where the jump put it as it does after any motion off the
child\='s cursor, see `cooked--wandered\='.

nil is a reasonable choice for anyone who selects in a terminal only to copy
something that has already finished printing.

The freeze cannot strand a buffer: it lifts when the selection goes away, and a
drain that invalidates the region deactivates the mark anyway -- see
`cooked--deactivate-mark\='."
  :type '(choice (const :tag "Defer the render" frozen)
                 (const :tag "Live, but the view stays put" still)
                 (const :tag "Keep following the cursor" nil))
  :group 'cooked)

(defun cooked--selection-input-mode ()
  "Freeze while a plain Emacs selection is active.  `cooked-selection-render\='.

`use-region-p\=' rather than `mark-active\=': it is the question every command
that acts on a region asks, so this freezes exactly when something would have
been operated on.  Under `transient-mark-mode\=' off it answers nil, which is
right -- a permanently active mark is not a selection anyone is looking at."
  (and cooked-selection-render
       (use-region-p)
       cooked-selection-render))

(defvar-local cooked--selection-active nil
  "Whether `use-region-p\=' was true after the last command.")

(defun cooked--track-selection ()
  "Recompute the input mode when a selection appears or goes away.

The input mode is *derived* rather than latched -- see
`cooked-input-mode-functions\=' -- so it is only right as often as something
recomputes it, and nothing recomputed it for a selection.

`activate-mark-hook\=' is the obvious place and it is not enough:
\\[set-mark-command] activates the mark while point is still on it, so the
region is empty and `use-region-p\=' is nil at exactly the moment the hook
runs.  Everything that makes it a selection happens afterwards, as ordinary
motion, with no hook of its own.  So the question is asked once per command and
the answer cached, which also covers a mouse drag.  It does not cover
`consult-line\=' or any other jump, since those push the mark without
activating it and so leave no region.

One `use-region-p\=' per command, and a refresh only on a *change* -- the
refresh rebuilds a keymap and must not run on every keystroke."
  (let ((active (use-region-p)))
    (unless (eq active cooked--selection-active)
      (setq cooked--selection-active active)
      (cooked--refresh-keymap))))

;; At 50: behind `cooked-evil--input-mode' at the default depth and ahead of
;; `cooked--default-input-mode' at 90.  Under evil the visual-state answer is
;; the more specific one and should win -- it distinguishes visual from normal,
;; where this cannot -- and evil's own selection makes `use-region-p' true too,
;; so without the ordering the two would answer the same question twice.
(add-hook 'cooked-input-mode-functions #'cooked--selection-input-mode 50)

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
  ;; Cleared before the choice, and set again by `cooked--forwarding-map' in
  ;; the arms that consult the frame -- so a map worn without asking about one
  ;; leaves nothing behind for `cooked--window-selection-changed' to think is
  ;; stale.  See `cooked--keymap-frame-type'.
  (setq cooked--keymap-frame-type nil
        ;; Likewise, so the forwarding evil wears above its insert state is
        ;; switched off by any refresh that chooses another map.
        cooked--semi-map-worn nil)
  (pcase (and (not (eq policy 'cooked)) mode)
    ((or 'still 'frozen) cooked-peek-map)
    ('semi (setq cooked--semi-map-worn t)
           cooked-semi-map)
    ;; The three that forward everything go through `cooked--forwarding-map',
    ;; which is where the frame gets a say: on a graphical frame a Meta chord is
    ;; one event that no list of character codes can name, and the map worn there
    ;; is a child that binds it.  `cooked-input-map' is not asked -- Emacs owns
    ;; the line, so there is nothing to forward -- and neither is
    ;; `cooked-semi-map', which holds the Meta space back on purpose.
    (_ (pcase policy
         ('cooked cooked-input-map)
         ('alt (cooked--forwarding-map cooked-alt-map))
         ;; A marked prompt with no license reads exactly like a running command
         ;; as far as the keyboard is concerned: the shell said where it is, so
         ;; there is nothing left to hedge and `cooked-raw-exceptions' would only
         ;; take keys away from a line editor that wants them.
         ((or 'command 'prompt) (cooked--forwarding-map cooked-command-map))
         (_ (cooked--forwarding-map cooked-raw-map))))))

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

;; The layers below report a change through `cooked--request-refresh' rather
;; than calling this, since they sit under the file that defines it.
(add-hook 'cooked--refresh-hook #'cooked--refresh-keymap)

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

(defun cooked-clear-scrollback ()
  "Delete everything above the current prompt.

comint's \\[cooked-clear-scrollback] read literally, and the seam between the emulator's grid
and Emacs\=' scrollback is not the user's business: whether what is above the
prompt has scrolled off the grid yet or is still on it, it goes.  Clearing
scrollback alone would look inert at exactly the moment it is reached for -- a
few commands into a session nothing has scrolled off at all, and every line on
screen is a row the emulator still holds.

Each side is asked for its own half.  `cooked--clear-to-prompt\=' removes the
rows, because rows have one owner and only the emulator knows which of them are
above the prompt; the scrollback is buffer text, so Emacs deletes that itself;
and the drain repaints what moved -- the shape of `cooked-delete-output\='.

The prompt line and anything typed at it stay, and end up at the top.  comint
deletes its prompt because there it is only text; here it is a row the shell is
still drawing on, and taking it would corrupt a redisplay cooked cannot repair.

On the alternate screen the grid belongs to a running program rather than to a
transcript, so only the scrollback goes -- see `cooked--clear-to-prompt\='."
  (interactive)
  (when cooked--session
    (cooked--clear-to-prompt cooked--session))
  (cooked--discard-scrollback (cooked--screen-start-position))
  (when cooked--session
    (cooked--drain-and-apply)))

(defun cooked-toggle-fold ()
  "Hide or reveal the output of the command at point.

A fold is opened by isearch as well as by hand.  Without
`isearch-open-invisible\=' on the overlay, isearch treats folded output as text
that cannot be shown and skips every match inside it -- so a search for
something you can see in the transcript, on a command whose output you happened
to fold, silently finds nothing.  The two entry points do different things by
design: stepping *through* a fold opens it for the duration
\(`isearch-open-invisible-temporary\='), and stopping inside one unfolds it for
good, which is the same act as \[cooked-toggle-fold] and so is
`delete-overlay\='.

The invisibility spec is the symbol `cooked-fold\=' rather than a bare t, and is
registered here.  A bare t is invisible only while `buffer-invisibility-spec\='
is itself t, which is merely its default -- any layer that narrows the spec to a
list of its own would have made every fold in the buffer spring open."
  (interactive)
  (pcase-let ((`(,beg . ,end) (cooked--output-region-at-point)))
    (if-let* ((existing (seq-find (lambda (o) (overlay-get o 'cooked-fold))
                                  (overlays-in beg end))))
        (delete-overlay existing)
      (add-to-invisibility-spec 'cooked-fold)
      (let ((overlay (make-overlay beg end)))
        (overlay-put overlay 'cooked-fold t)
        (overlay-put overlay 'invisible 'cooked-fold)
        (overlay-put overlay 'isearch-open-invisible #'delete-overlay)
        (overlay-put overlay 'isearch-open-invisible-temporary
                     (lambda (overlay hide)
                       (overlay-put overlay 'invisible (and hide 'cooked-fold))))
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

(defun cooked--font-scale-resync (&optional only)
  "Resize sessions whose font may just have moved.  ONLY limits it to one buffer.

`:after\=' advice rather than ghostel\='s `:around\=', and the difference is a
property of cooked rather than a shortcut.  ghostel snapshots which windows were
anchored before the font moves and re-anchors them afterwards, because its
anchoring is *latched*.  cooked\='s is computed: `cooked--pin-transcript-bottom\='
works the view out from the buffer on every drain, and the resize below causes
one.  There is nothing to save and put back.

The cache needs no telling either, for the same kind of reason:
`cooked--layout-stamp\=' names the font, so `cooked--wrap-cache\=' and the glyph
metrics in it are thrown away by comparison the next time they are asked for.
What is genuinely missing without this is the *child* being told, since a font
change alters how many rows and columns the window holds and nothing else
notices."
  ;; ONLY rather than BUFFER: `cooked--dolist-buffers' binds `buffer' itself, and
  ;; a parameter of that name is shadowed inside the body without a word said.
  (cooked--dolist-buffers
   (when (or (null only) (eq (current-buffer) only))
     (cooked--sync-size))))

(defun cooked--font-scale-local (&rest _)
  "Resync this buffer after a buffer-local font change."
  (cooked--font-scale-resync (current-buffer)))

(defun cooked--advise-font-scale ()
  "Notice the font changes `text-scale-mode-hook\=' does not report.

Idempotent, and called from `cooked-mode\=' rather than at load: advice on a
global function is a cost every Emacs pays, and a configuration that loads
cooked but never starts a session should not pay it.

`buffer-face-mode\=' is the one that matters -- `buffer-face-set\=',
`buffer-face-toggle\=' and `variable-pitch-mode\=' all rescale through it, and it
runs no hook.  `global-text-scale-adjust\=' is the other, and is advised only
where it exists, being newer than the Emacs cooked still supports."
  (unless (advice-member-p #'cooked--font-scale-local 'buffer-face-mode)
    (advice-add 'buffer-face-mode :after #'cooked--font-scale-local))
  (when (and (fboundp 'global-text-scale-adjust)
             (not (advice-member-p #'cooked--font-scale-resync
                                   'global-text-scale-adjust)))
    (advice-add 'global-text-scale-adjust :after #'cooked--font-scale-resync)))

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
                 (resized (not (equal cooked--last-size (cons rows cols))))
                 ;; A minibuffer opening and closing changes the *rows* every
                 ;; window on the frame has and nothing else, and every one of
                 ;; those is a SIGWINCH the child answers.  fish clears and
                 ;; re-emits its prompt on each one, so an `M-x' cycle -- grow
                 ;; then shrink -- produces two prompt repaints for a gesture
                 ;; that never touched this window's width.  A visible flicker
                 ;; for nothing.
                 ;;
                 ;; Only where the *width* is unchanged, which is what makes
                 ;; this safe rather than a guess: a rewrap is what a child
                 ;; actually needs to be told about, and the height it will be
                 ;; told at the next real resize.  And not on the alternate
                 ;; screen, where a full-screen program has laid itself out
                 ;; against a row count and would draw into rows that are no
                 ;; longer there.
                 (deferred (and (active-minibuffer-window)
                                (eql cols (cdr cooked--last-size))
                                (not cooked--alt))))
      (unless (or (and (not resized) (not moved))
                  (and deferred (not moved)))
        (setq cooked--last-size (cons rows cols)
              cooked--last-cell cell
              cooked--rows rows
              cooked--cols cols)
        (cooked--resize cooked--session rows cols (car cell) (cdr cell))
        ;; Before the drain, not after: `cooked--flush-pending-repaint' runs
        ;; from inside `cooked--apply' and only pays for a `force-window-update'
        ;; when this is already set when it gets there.  A window displaying
        ;; this buffer but not selected and not following the cursor is outside
        ;; everything `cooked--scroll-windows' touches, and a resize rewrapping
        ;; every row under it is exactly the case seen to leave such a window's
        ;; glyph matrix stale -- see `cooked--repaint-pending'.  Set on every
        ;; call a drag-resize makes rather than only the last one, since there
        ;; is no way to tell here which call that will be; the flag is cheap and
        ;; the drain it rides is not made any more frequent by it.
        (when resized
          (cooked--schedule-repaint)
          (cooked--drain-and-apply))
        ;; Decorations are cut to the cell, and nothing else in the codebase
        ;; re-renders scrollback, so this is where a transcript full of pictures
        ;; and box drawing is brought back into agreement with the font.  Gated
        ;; on the cell really having moved: `cooked--rescale-deco' is a
        ;; whole-buffer walk under `widen', and an ordinary reshape that leaves
        ;; the font alone must not pay for one.  After the drain above, so it
        ;; also covers whatever rows the resize itself just rewrapped in.
        (when moved
          (cooked--rescale-deco)
          ;; `cooked--rescale-deco' rewrites `display' properties in place
          ;; rather than going through a drain, so there is no `cooked--apply'
          ;; coming later to carry a flag set here -- flush directly instead of
          ;; only scheduling.  A second flush when `resized' also fired above is
          ;; correct rather than redundant: that one ran inside the drain,
          ;; before this rescale touched anything, so it cannot have been a
          ;; repaint for what this just changed.
          (cooked--schedule-repaint)
          (cooked--flush-pending-repaint))))))

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
(defun cooked--keymap-frame-stale-p (&optional frame)
  "Whether the local map was built for a frame type other than FRAME\='s.

Nil unless the buffer is wearing one of the maps that forwards to the child,
those being the only ones that depend on a frame at all -- see
`cooked--keymap-frame-type\='.  Two buffer-local reads and one
`display-graphic-p\=', which is why this is cheap enough to ask on every
window selection."
  (and cooked--keymap-frame-type
       (not (eq cooked--keymap-frame-type (cooked--frame-keymap-type frame)))))

(defun cooked--window-selection-changed (frame)
  "Report focus, and re-wear the keymap if FRAME spells Meta differently.

Two things that want the same moment.  Focus is the reason this hook was
installed; the keymap is here because nothing else runs when a buffer moves
between a graphical frame and a terminal frame.  `cooked--forwarding-map\='
decides between the two at `use-local-map\=' time, and on a daemon serving one
of each the answer it reached can outlive the frame it was reached on --
leaving `M-x\=' either eaten by the child on a graphical frame or answered by
Emacs on a terminal one, until some unrelated state change happens to install
a map again.

The cost on the ordinary selection change is `cooked--keymap-frame-stale-p\=',
which for a buffer at a prompt is one buffer-local read that answers nil, and
otherwise two reads and a `display-graphic-p\='.  Nothing is rebuilt: the two
overlays a session can want are cached in `cooked--meta-overlays\=' for the
life of Emacs, so even the refresh is a lookup.

Only when the buffer has *gained* the selection, which is what the
`frame-selected-window\=' test says -- this hook also runs in the buffer being
left, and the map belongs to the frame being typed into.  And deferred, like
every other reaction to a window hook: this runs inside redisplay, and
`cooked--refresh-keymap\=' swaps the local map, can drain, and runs
`cooked-state-change-hook\=', which is arbitrary user code.  The question is
asked again on the other side of the deferral, since by then the user may have
moved back."
  (cooked--report-focus)
  (when (and (cooked--keymap-frame-stale-p frame)
             (eq (window-buffer (frame-selected-window frame)) (current-buffer)))
    (cooked--defer (lambda ()
                     (when (cooked--keymap-frame-stale-p)
                       (cooked--refresh-keymap))))))

(defun cooked--user-window ()
  "The window the user is working in, looking past an active minibuffer.

Reading the minibuffer as \"the user has left\" is wrong in both directions:
it ends a deliberate peek the moment they reach for `M-x', `C-x b' or evil's
`:', and it tells a child that asked for focus events that it lost the
keyboard to a prompt that is about to hand it straight back."
  (or (and (window-minibuffer-p (selected-window))
           (minibuffer-selected-window))
      (selected-window)))

(defun cooked--update-attention (&rest _)
  "Track, for every live session, whether the user is looking at it.
From `window-selection-change-functions'; see `cooked--update-buffer-attention'."
  (cooked--dolist-buffers
    (cooked--update-buffer-attention)))

(defun cooked--window-buffers-changed (&rest _)
  "Update attention and graphics in every session, in one walk of the sessions.

From `window-buffer-change-functions', whose global value runs once per frame
that changed.  Both questions are about which windows show a buffer, so one
walk answers both rather than each walking the sessions for itself."
  (cooked--dolist-buffers
    ;; Protected apart, so a failure in one still lets the other run.
    (cooked--protect-hook (cooked--update-buffer-attention))
    (when cooked--session
      (cooked--sync-graphics))))

(defun cooked--update-buffer-attention ()
  "Track whether the user is looking at the current buffer's session.

A freeze is only worth anything while someone is reading the picture it holds
still, so it lifts for as long as the buffer is not the selected window's --
see `cooked--frozen-p'.  Walking every session rather than running
buffer-locally is what catches the case a buffer-local hook cannot: switching
to another buffer *in the same window* leaves the cooked buffer displayed
nowhere, and nothing buffer-local runs in a buffer that is no longer shown.

Draining on the way out matters as much as the flag does: the wakes that
arrived while frozen were skipped, so without this the buffer would sit at
whatever it showed when the freeze began until something else asked.

A pending bell is cleared here too, and ahead of the session test: a build
that rang to say it was done and then took its shell with it has left a mark
that still wants seeing, and a dead session is still a buffer the user comes
back to.  See `cooked-bell-pending'."
  (when (and cooked-bell-pending
             (eq (current-buffer) (window-buffer (cooked--user-window))))
    (setq cooked-bell-pending nil)
    (force-mode-line-update))
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
             (when cooked--session (cooked--drain-and-apply)))))))))

(defun cooked--install-global-hooks ()
  "Install the hooks that cannot be buffer-local."
  (add-hook 'window-size-change-functions #'cooked--frame-size-changed)
  ;; Exiting Emacs kills no buffers, so `kill-buffer-hook' -- where every other
  ;; teardown hangs -- never runs.  See `cooked--kill-emacs'.
  (add-hook 'kill-emacs-hook #'cooked--kill-emacs)
  ;; Both, because they answer different halves of "is the user looking at it":
  ;; selection moving to another window, and the window they are in showing
  ;; something else.
  (add-hook 'window-selection-change-functions #'cooked--update-attention)
  ;; One function for both halves on the buffer side, since graphics below asks
  ;; about the same windows: see `cooked--window-buffers-changed'.
  (add-hook 'window-buffer-change-functions #'cooked--window-buffers-changed)
  ;; The same two halves decide which buffer's OSC 12 colour a frame's cursor
  ;; wears, and the global values are the ones that still run when the window
  ;; being left shows a buffer that is no longer cooked, or no longer live.
  (add-hook 'window-selection-change-functions #'cooked--sync-cursor-color)
  (add-hook 'window-buffer-change-functions #'cooked--sync-cursor-color)
  ;; Whether a picture can be shown is a question about every frame the buffer
  ;; is on, so it is asked by walking sessions too; see `cooked--sync-graphics'.
  ;; On a window change `cooked--window-buffers-changed' asks it.
  (add-hook 'after-delete-frame-functions #'cooked--sync-graphics-everywhere)
  (add-variable-watcher 'cooked-inline-images #'cooked--sync-graphics-on-toggle)
  (add-variable-watcher 'cooked-allow-pointer-shape #'cooked--sync-pointer-shape-on-toggle)
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
          (cooked--reply-if-live (cooked--csi (if focused "I" "O"))))))))

(defun cooked--frame-focus-changed (&rest _)
  "Report focus for every live session, from `after-focus-change-function'."
  (cooked--dolist-buffers
    (when cooked--session
      (cooked--report-focus))))

;;;; Where the rest of Emacs goes looking for structure
;;
;; imenu, outline and bookmarks all want the same thing from a buffer -- "what
;; are the parts of this, and where do they start" -- and a transcript has an
;; exact answer that no scan of its text could recover: the OSC 133 records in
;; `cooked--commands', which already know where each command was typed, where
;; its output began and ended, and how it went.  Each of the three is a
;; buffer-local variable set in `cooked-mode' and read by nobody until the
;; subsystem that owns it is used, so a session that never calls `imenu' pays
;; for none of this.
;;
;; Nothing here registers with `desktop'.  A cooked buffer visits no file and
;; sets no `desktop-save-buffer', so it is already left out of the desktop file
;; and cannot break one; what registering would buy is a restore, and the only
;; restore worth anything spawns a shell.  Desktop restore is bulk, automatic
;; and sometimes deferred onto an idle timer, which makes it the one moment
;; where "start eight children the user did not ask for" is a plausible
;; outcome, and the alternative -- a session-less placeholder buffer -- is
;; litter, since nothing turns such a buffer back into a session.  A bookmark
;; is the same capability chosen one at a time, by hand, which is the shape
;; this belongs in.

;; imenu and bookmark do not preload the variables they are configured through,
;; so the compiler is told about them here rather than by requiring two
;; libraries a session may never use.  Every one of them is read only from
;; inside the subsystem that defines it, by which point it is bound for real.
(defvar imenu-auto-rescan)
(defvar imenu-max-item-length)
(defvar bookmark-make-record-function)
(declare-function bookmark-prop-get "bookmark" (bookmark prop))

(defconst cooked--imenu-unnamed "(no command line)"
  "What an `imenu' entry is called when nothing names the command.
Both accounts can be missing at once -- a shell that sends no `cmdline_url=',
a command Emacs did not submit, and a prompt line that has since been
repainted to nothing -- and an entry with an empty name is one the completing
read cannot be pointed at.")

(defun cooked--imenu-prompt-line (position)
  "The line at POSITION, the prompt a command was typed at, as it stands now.

The fallback for a command with no `input'.  One line rather than a scan: the
record says where the prompt is, so this is a `buffer-substring' of known
bounds and the index stays O(commands)."
  (when position
    (save-excursion
      (goto-char position)
      (buffer-substring-no-properties (pos-bol) (pos-eol)))))

(defun cooked--command-name (input anchor)
  "A command's line as one line of text, or nil if nothing names it.

INPUT is the command line the shell said it was about to run, and ANCHOR the
position of the prompt it was typed at -- or of its output, for a shell that
sent no prompt mark.  The two halves rather than a record, because the command
still running has no record and must be named the same way.

INPUT with whitespace collapsed, so that a `for' loop typed over three lines is
one name rather than a string with newlines in it.  Failing that the line at
ANCHOR as it stands in the buffer, which is the same string with the prompt
still on the front of it -- the best a session whose shell sends no
`cmdline_url=' can do, and much better than nothing, since that is exactly the
session where the user is reading the prompt line anyway.

Shared by the `imenu' index and `cooked-command-search', which name commands
for the same reader and must not drift into naming them differently.  A name
only: copying and rerunning read `cooked-command-input' itself, so the
newlines this drops are never lost to anything that sends the line."
  (let* ((text (or input (cooked--imenu-prompt-line anchor) ""))
         (line (string-trim (replace-regexp-in-string "[ \t\n]+" " " text))))
    (unless (string-empty-p line) line)))

(defun cooked--imenu-label (command)
  "What COMMAND is called in the `imenu' index, before it is made unique.

`cooked--command-name', or `cooked--imenu-unnamed' when that is nil.

A non-zero exit is spelled out rather than coloured.  An index entry is data
as much as it is display: `which-function-mode' puts this string in the mode
line, speedbar and consult each render it their own way, and none of them can
read a face -- while a face named `error' in the mode line would be a claim
about the present rather than about a command that failed an hour ago.

Elided to leave room for the suffix and for the disambiguator
`cooked--imenu-index' may add.  imenu truncates the finished name to
`imenu-max-item-length' itself, and it does so last, so a long command line
would otherwise take the exit status and the `<2>' with it -- which is the one
way this index can lose an entry, two failures of the same long command
becoming one name that points at the first."
  (let* ((line (cooked--command-name
                (cooked-command-input command)
                (or (cooked--command-prompt-position command)
                    (cooked--command-start-position command))))
         (code (cooked-command-code command))
         (suffix (if (eql code 0) "" (format " [exit %s]" code)))
         ;; Four characters is `<9>' and the ellipsis the elision itself costs.
         ;; `bound-and-true-p' because nothing here requires imenu: nil is both
         ;; "not loaded" and imenu's own spelling of "no limit", and the two
         ;; want the same answer, which is to elide nothing.
         (limit (bound-and-true-p imenu-max-item-length))
         (room (if (numberp limit)
                   (max 8 (- limit (length suffix) 4))
                 most-positive-fixnum)))
    (if (null line)
        cooked--imenu-unnamed
      (concat (truncate-string-to-width line room nil nil t) suffix))))

(defun cooked--imenu-index ()
  "An index of the commands this session has run, for `imenu'.

The value of `imenu-create-index-function' in a cooked buffer, so this runs
when the user asks for `imenu', `consult-imenu' or speedbar and at no other
time.  O(commands), with one line of `buffer-substring' for each command whose
line was never reported and none at all for the rest.

Flat, and in buffer order.  Nesting was considered and declined at each of the
groupings available: by exit status, which is two buckets that hide the
ordering that makes a transcript navigable; by working directory, which no
record carries; and by the first word of the command line, which reads well in
a menu and badly everywhere else, since it puts `git' between the user and
every `git' they ran.  `imenu-flatten' exists for people who want the other
answer, and no equivalent puts an order back.

Each entry lands on the prompt rather than on the output, for the reason
`cooked-previous-command' does: a command that printed nothing has no output
to land in, and it is very often the one worth finding.

Positions rather than markers, deliberately.  A marker in this buffer is a
cost paid by every insertion the child makes for as long as the index exists,
and `cooked-mode' sets `imenu-auto-rescan' so that the index is rebuilt on
each use instead -- which a buffer being rewritten at 125Hz needs anyway.

Repeated command lines are disambiguated the way `uniquify' does it, because
`imenu' looks an entry back up by name: running `make' five times must not
produce five entries of which only the first can be reached."
  (let ((seen (make-hash-table :test #'equal))
        index)
    (dolist (command (reverse cooked--commands) (nreverse index))
      (let* ((label (cooked--imenu-label command))
             (n (1+ (gethash label seen 0))))
        (puthash label n seen)
        (push (cons (if (= n 1) label (format "%s<%d>" label n))
                    (or (cooked--command-prompt-position command)
                        (cooked--command-start-position command)))
              index)))))

(defvar-local cooked--outline-cache nil
  "Memo behind `cooked--outline-headings', as (TICK NEWEST HEADINGS).

Outline asks for the next heading once per heading it walks past, and a walk
over the whole buffer would otherwise rebuild the list of them once per step.
The key is `buffer-chars-modified-tick' and the newest record: text moving is
what moves a heading, and a `D' mark can push a record without changing a
character.  Neither can happen between two calls made inside one outline
command -- a drain runs from the process filter and nothing here pumps it --
so the memo holds for exactly as long as it is honest.")

(defun cooked--outline-heading-list ()
  "Line starts of every prompt in the buffer, in order, without repeats.

`cooked--prompt-starts' answers in positions, and a heading is a line, so each
is pulled back to the start of the line it is on -- which is where an `A' mark
already puts it, and where the fallback to an output start need not be.

A line with nothing on it is not offered as a heading.  That is a real
transcript state -- the live prompt of a shell that has not drawn one yet --
and an empty heading at `point-max' is a heading a forward search finds
without moving, which is an infinite loop in every caller that walks with
one."
  (let (headings)
    (save-excursion
      (dolist (position (cooked--prompt-starts))
        (goto-char position)
        (let ((bol (pos-bol)))
          (unless (or (eql bol (car headings)) (eql bol (pos-eol)))
            (push bol headings)))))
    (nreverse headings)))

(defun cooked--outline-headings ()
  "`cooked--outline-heading-list', memoized; see `cooked--outline-cache'."
  (let ((tick (buffer-chars-modified-tick))
        (newest (car cooked--commands)))
    (unless (and (eql tick (nth 0 cooked--outline-cache))
                 (eq newest (nth 1 cooked--outline-cache)))
      (setq cooked--outline-cache (list tick newest (cooked--outline-heading-list))))
    (nth 2 cooked--outline-cache)))

(defun cooked--outline-search (&optional bound move backward looking-at)
  "Find the next prompt line, for `outline-search-function'.

Emacs 29 added this in front of `outline-regexp' for exactly this case: what
makes a line a heading here is not how it looks but what the shell said about
it, and a regexp over a transcript can only guess at a prompt -- the guess
being wrong for every prompt that does not look like the one whose regexp was
written, and for every line of output that does.

The contract is `re-search-forward's, restated for whole lines: find a heading
at or after point going forward and strictly before it going backward, set the
match to the heading's line, and return non-nil.  With BOUND the heading's line
must fall inside it; with MOVE a failure leaves point at BOUND, or at the end
of the buffer it was heading for, rather than where it started.  LOOKING-AT
asks about the line point is on and moves nothing, which is what
`outline-on-heading-p' is made of.

Every command's prompt is a heading and they are all level 1: the transcript is
a sequence, not a tree, and `cooked-mode' sets `outline-level' to say so.  A
nested structure was available -- a command's output could be a level below its
prompt -- and it would fold exactly nothing extra, since a heading already
hides everything under it up to the next one."
  (let ((headings (cooked--outline-headings)))
    (if looking-at
        (when (memql (pos-bol) headings)
          (set-match-data (list (pos-bol) (pos-eol)))
          t)
      (let* ((point (point))
             (found (if backward
                        (car (last (seq-take-while (lambda (h) (< h point)) headings)))
                      (seq-find (lambda (h) (>= h point)) headings)))
             (end (and found (save-excursion (goto-char found) (pos-eol)))))
        (cond ((and found (or (null bound)
                              (if backward (>= found bound) (<= end bound))))
               (goto-char (if backward found end))
               (set-match-data (list found end))
               t)
              (t
               (when move
                 (goto-char (or bound (if backward (point-min) (point-max)))))
               nil))))))

(defun cooked--outline-level ()
  "The level of the heading point is on, which is always 1.
See `cooked--outline-search' for why the transcript is flat."
  1)

(defun cooked--session-in-directory (directory)
  "The most recently used live session whose shell is in DIRECTORY, if any.

Where the shell is *now*, which OSC 7 keeps in `default-directory': a session
that has since `cd'd out is not this one, and one that has `cd'd in is, which
is the same rule `cooked-project' reuses a session by."
  (seq-find (lambda (buffer)
              (with-current-buffer buffer
                (ignore-errors (file-equal-p default-directory directory))))
            (cooked--live-buffers)))

(defun cooked--bookmark-record ()
  "A bookmark naming this session's working directory, for `bookmark'.

The value of `bookmark-make-record-function' in a cooked buffer, so this runs
only when \\[bookmark-set] is pressed in one.

What a bookmark into a terminal can mean is the whole of the design here.  A
position cannot be it: the buffer is transient, the child outlives nothing,
and by tomorrow the row this was set on has scrolled out of a session that has
itself exited -- a bookmark that resolved to \"character 40122 of a buffer
that no longer exists\" would be a broken link by morning, every time.  What
does survive is where the shell was and what was being run there, so that is
what is recorded, and `cooked-bookmark-jump' spends it by putting a shell back
in that directory.

The command line is recorded but never re-run.  A bookmark that executed
something on being opened would be a stored side effect, and the honest place
for that is `cooked-rerun-command', which the user presses themselves; here it
names the bookmark, so that a list of them reads as the list of things they
were set for."
  (let* ((directory default-directory)
         (command (cooked--command-around (point)))
         (input (and command (cooked-command-input command))))
    `(,(format "cooked %s%s" (abbreviate-file-name directory)
               (if input (concat ": " input) ""))
      ;; Both, and they are not redundant: `filename' is what `bookmark-bmenu-list'
      ;; prints in its second column and what `bookmark-relocate' edits, while
      ;; `directory' is what the handler reads -- so a user who relocates the
      ;; bookmark does not silently move the column and leave the shell where it
      ;; was.
      (filename . ,directory)
      (directory . ,directory)
      (command . ,input)
      (handler . cooked-bookmark-jump))))

;;;###autoload
(defun cooked-bookmark-jump (bookmark)
  "Put a shell back in the directory BOOKMARK was set in.

The handler for the records `cooked--bookmark-record' makes.  A live session
whose shell is already there is reused -- the same rule `cooked-project' uses,
and the answer that does not accumulate a shell per jump -- and otherwise a
fresh one is started.  Nothing is re-run: see `cooked--bookmark-record'.

The session being gone is the ordinary case rather than the failure, which is
what makes this degrade well; the failure is the *directory* being gone, and
that is said out loud rather than papered over by starting a shell somewhere
else."
  (let ((directory (or (bookmark-prop-get bookmark 'directory)
                       (bookmark-prop-get bookmark 'filename))))
    (unless (and directory (file-directory-p directory))
      (user-error "cooked: %s is not there any more"
                  (abbreviate-file-name (or directory "the bookmarked directory"))))
    (set-buffer (or (cooked--session-in-directory directory)
                    (let ((default-directory directory))
                      (cooked--start-session))))))

;;;; The mode

(defconst cooked--thing-at-point-things '(url filename existing-filename)
  "Every `thing-at-point' kind a cooked layer can ever answer.

Fixed rather than derived from `cooked-thing-at-point-providers', and that is
what makes late loading work: cooked-file-link.el is `require'-to-enable, so a
user may load it long after their first cooked buffer exists, and a list read
at mode time would have missed it forever.  A thing nothing contributes an
answer for returns nil, which is exactly the \"no provider\" signal thingatpt
wants -- so claiming all three up front costs nothing and displaces nothing.")

(defun cooked--thing-at-point (thing)
  "Ask each layer's provider for THING at point, first answer winning.

Resolved at call time against `cooked-thing-at-point-providers', never
snapshotted -- see `cooked--thing-at-point-things'."
  (cl-loop for (kind . function) in cooked-thing-at-point-providers
           when (eq kind thing)
           thereis (funcall function)))

(defun cooked--bounds-of-thing-at-point (thing)
  "Bounds for THING at point from the layer that claims it, or nil.

Kept separate from `cooked--thing-at-point' rather than derived, because the
two alists are consulted independently: embark asks only for bounds when it
highlights a target, and must not fall back to thingatpt's idea of where a
thing ends when a layer here knows better."
  (cl-loop for (kind . function) in cooked-bounds-of-thing-at-point-providers
           when (eq kind thing)
           thereis (funcall function)))

(defun cooked--install-thing-at-point-providers ()
  "Install cooked's `thing-at-point' providers in this buffer.

The contribution point straddles a tier boundary on purpose.  `url' comes from
cooked-link.el, which is base tier; `filename' and `existing-filename' come
from cooked-file-link.el, which is an optional layer the user `require's.
Neither file can install the other's, and the base layer must not name a
provider only an upper layer can supply -- so both merely contribute, and this
function, in the mode that sits above both, installs a dispatcher that asks
whoever is present at the moment of the question.

Buffer-locally, because these alists are global and a cooked provider answering
elsewhere would be wrong: `cooked-link-uri' reads a table that exists only here.

What it buys is out of proportion to its size.  ROADMAP §3 asked for
`embark-target-finders' entries; embark's own file and URL finders go through
`thing-at-point', so this answers `embark-act' without cooked depending on
embark at all -- and answers `browse-url-at-point', ffap and `find-file's
`M-n' in the same stroke, in an Emacs that has never heard of embark."
  (setq-local thing-at-point-provider-alist
              (append (mapcar (lambda (thing)
                                (cons thing (lambda () (cooked--thing-at-point thing))))
                              cooked--thing-at-point-things)
                      thing-at-point-provider-alist))
  (setq-local bounds-of-thing-at-point-provider-alist
              (append (mapcar (lambda (thing)
                                (cons thing
                                      (lambda () (cooked--bounds-of-thing-at-point thing))))
                              cooked--thing-at-point-things)
                      bounds-of-thing-at-point-provider-alist))
  (add-hook 'file-name-at-point-functions #'cooked--file-name-at-point nil t))

(defun cooked--file-name-at-point ()
  "Entry on `file-name-at-point-functions', dispatching to whichever layer answers.

What `find-file' offers as its `M-n' default and what ffap consults.  Empty
unless cooked-file-link.el is loaded, naming a file being that layer's job."
  (run-hook-with-args-until-success 'cooked-file-name-at-point-functions))

(define-derived-mode cooked-mode comint-mode "cooked"
  "Major mode for a terminal that hands the keyboard back for line input.

In `cooked' and OSC 133 input states the buffer behaves like any editable Emacs
buffer and \\[cooked-send-input] submits the line.  Otherwise keys are forwarded
to the child verbatim."
  :interactive nil
  ;; Before anything below sets `truncate-lines', and before the mode hooks
  ;; that would otherwise turn this on for us.  `global-visual-line-mode' is
  ;; installed from `after-change-major-mode-hook', so it runs *after* this
  ;; body and would overrule the `truncate-lines' the next form derives from
  ;; `cooked-rejoin-wrapped-lines' -- wrapping rows the emulator laid out as a
  ;; grid, and taking the width guard's assumption with it, since
  ;; `cooked--guard-row-width' asks `vertical-motion' where a row ends and a
  ;; soft-wrapped row ends somewhere else.  Turning the minor mode off here
  ;; rather than fighting the variable is what makes it stay off: the call
  ;; leaves the buffer marked as having decided for itself, which is the flag
  ;; the globalized mode consults before enabling anywhere.  Ordering is
  ;; load-bearing in the other direction too -- switching it off kills the local
  ;; `truncate-lines', so it has to happen before the value cooked wants is
  ;; written.  This is the shape the mode already uses on the other global that
  ;; would answer for a cooked buffer: see the `comint-completion-at-point'
  ;; removal below.
  (visual-line-mode -1)
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
              ;; Nothing may slide the grid sideways.  With `truncate-lines'
              ;; on, Emacs hscrolls a window to keep point visible, and point
              ;; here is put wherever the child's cursor is on every drain --
              ;; so a cursor at column 200 of a 190-column row would scroll the
              ;; whole viewport, and column 0 would stop being the left edge.
              ;; Every place that turns a pixel or a column back into a cell
              ;; (`cooked--mouse-cell', the ghost cursor, `cooked--guard-row-width')
              ;; would then be naming a cell the user is not pointing at, and
              ;; the child would never be told, because a horizontal scroll is
              ;; Emacs' idea and not part of any terminal protocol.
              auto-hscroll-mode nil
              ;; `default-text-properties' is a *global* fallback consulted for
              ;; every character that does not carry the property itself, so a
              ;; user who put `line-spacing' or `line-height' in it has silently
              ;; made every row in this buffer taller than the default line
              ;; height.  `cooked--window-rows' divides the window's pixel
              ;; height by `window-default-line-height', which reads the
              ;; `line-spacing' *variable* and the default face and cannot see
              ;; that fallback -- so cooked would tell the child more rows than
              ;; the window can show, and the child would draw its bottom rows
              ;; off screen with nothing anywhere reporting an error.  Cleared
              ;; buffer-locally rather than worked around: a terminal grid has
              ;; no use for a default text property of any kind.
              default-text-properties nil
              ;; U+00A0 is a character the child asked for, not a typo in
              ;; prose.  With `nobreak-char-display' at its default, redisplay
              ;; paints every no-break space in the `nobreak-space' face --
              ;; `escape-glyph' plus an underline, so blue and underlined -- and
              ;; it does so at *display* time, carrying no text property, which
              ;; is why the artifact this fixes survived a property dump and an
              ;; A/B against both link passes.  A TUI that pads with U+00A0
              ;; (Claude Code's prompt, `tree''s indent) then draws a row of
              ;; blue underlined gaps that no program asked for and nothing in
              ;; the buffer records.  Emacs highlights it to warn a writer about
              ;; whitespace that will not break a line; a grid has no lines to
              ;; break and no writer to warn.
              nobreak-char-display nil
              ;; SGR 53 is a line along the top of the cell, not a taller cell.
              ;; Emacs adds `overline-margin\=' pixels to the ascent of any glyph
              ;; with an overline, 2 by default, so every overlined row came out
              ;; that much taller than `window-default-line-height\=', which
              ;; `cooked--window-rows\=' counts in.  A screen with a few such
              ;; rows then no longer fits the rows the child was told, and the
              ;; bottom one is clipped.  At 0 the line is drawn over the top
              ;; pixel row of the cell instead, as a terminal draws it.  Local
              ;; here, since redisplay reads the value with the window\='s
              ;; buffer current, so prose elsewhere keeps its margin.
              overline-margin 0
              ;; A terminal grid has no space between its rows, and box
              ;; drawing cannot have it either.  Emacs adds `line-spacing\='
              ;; below every glyph on a row, a bitmap as much as a character,
              ;; so a box-drawing bitmap as tall as the line box gets the
              ;; spacing twice: with a global `line-spacing\=' of 2 in a font
              ;; of ascent 13 and descent 4, a row of borders was 21 pixels in
              ;; a 19-pixel line box, and htop ran three rows past its window.
              ;; A bitmap drawn at the text\='s height fits, but leaves a gap
              ;; the size of the spacing between the strokes of a vertical
              ;; border, which is the defect drawing borders as bitmaps exists
              ;; to remove.  No `:ascent\=' and no `line-height\=' property avoids
              ;; both, so the spacing goes.
              ;;
              ;; 0 rather than nil: nil falls back to the frame\='s
              ;; `line-spacing\=' parameter, and 0 does not.  A value set again
              ;; from `cooked-mode-hook\=' is left alone, as every other
              ;; variable here is: the hook runs after this body so that a user
              ;; can have the last word, and watching the variable to take it
              ;; back would be a fight the user started on purpose.  It costs
              ;; what it did before this line existed.  With 2 in that font,
              ;; a screen of borders draws rows of 21 pixels in a 19-pixel line
              ;; box, and the last three of 31 rows fall below the window.
              line-spacing 0
              ;; A grid, not prose.  Cell (ROW . COL) is the COLth character of
              ;; the ROWth line and nothing may make it otherwise: `cooked--mouse-cell'
              ;; turns a click's column back into a cell, the ghost cursor is
              ;; placed by column, and `cooked--guard-row-width' asks
              ;; `vertical-motion' where a row ends.  Emacs' bidi reordering is a
              ;; per-paragraph decision made from the text's own first strong
              ;; character, so a single line of Hebrew or Arabic output would
              ;; flip the visual order of that row -- and every one of those three
              ;; would then be naming a different cell than the user is pointing
              ;; at.  Fixing the direction costs nothing for the overwhelmingly
              ;; common case and keeps the correspondence total.
              ;;
              ;; Deliberately *not* `bidi-display-reordering', which switches
              ;; reordering off outright: Emacs documents that one as internal
              ;; and not for Lisp to set, and the character-level shaping it
              ;; would also disable is not what is in the way here.
              bidi-paragraph-direction 'left-to-right
              truncate-lines (not cooked-rejoin-wrapped-lines)
              mode-line-process '(:eval (cooked--mode-line))
              ;; Read once here and never toggled afterwards -- see
              ;; `cooked-sticky-scroll' for why toggling it would be its own PTY
              ;; resize.  Left alone entirely when the feature is off, so a
              ;; cooked buffer has no header line unless it was asked for.
              header-line-format (and cooked-sticky-scroll
                                      '(:eval (cooked--sticky-header)))
              ;; The transcript's own structure, offered to the three
              ;; subsystems that ask for it in three different words.  All
              ;; three are inert until something reads them, which is what
              ;; makes registering here rather than in an opt-in file safe --
              ;; see the commentary above `cooked--imenu-index'.
              imenu-create-index-function #'cooked--imenu-index
              ;; A cached index of a buffer being rewritten at 125Hz is a list
              ;; of positions that were true once.  Rebuilding is O(commands)
              ;; and happens only when the user asks for the index.
              imenu-auto-rescan t
              outline-search-function #'cooked--outline-search
              outline-level #'cooked--outline-level
              bookmark-make-record-function #'cooked--bookmark-record)
  ;; comint would send the line to the process behind the buffer, which here is the
  ;; wakeup pipe.  Every submission goes to the child instead, so `comint-send-input'
  ;; is a working command rather than something to be remapped around -- and nothing
  ;; can reach the pipe by accident.
  (setq-local comint-input-sender (lambda (_proc input) (cooked--send-input-string input)))
  ;; `revert-buffer' has no file to re-read here and signals rather than doing
  ;; nothing, which for a buffer bound to \[revert-buffer] in most people's
  ;; hands is a worse answer than the obvious one.  Repainting the screen from
  ;; the emulator's own grid is what reverting means for a terminal, and
  ;; `cooked-refresh' already is that.  The two arguments `revert-buffer' passes
  ;; -- ignore-auto and noconfirm -- are both about a file on disk, so neither
  ;; has anything to say to it.
  (setq-local revert-buffer-function (lambda (&rest _) (cooked-refresh)))
  ;; What `C-x C-b' and ibuffer print in the directory column for a buffer with
  ;; no file.  cooked tracks the child's own working directory in
  ;; `default-directory' from OSC 7, so the honest value is there for the asking
  ;; -- and without this the column is simply blank.  Kept in step by
  ;; `cooked--update-buffer-name', which every OSC 7 already ends with.
  (setq-local list-buffers-directory default-directory)
  ;; The ring `comint-mode' just built is the history; it is at the default 500,
  ;; which is enough.  Repeats are dropped, as a shell's own history does by
  ;; default.
  (setq-local comint-input-ignoredups t)
  ;; The OSC 133 records know where each command line began; comint would otherwise
  ;; scan backwards for a prompt regexp cooked deliberately never sets.
  (setq-local comint-get-old-input #'cooked--get-old-input)
  ;; comint leaves this at `(nil t)', under which the first fontification strips a
  ;; bare `face' property -- which would force the renderer to set `font-lock-face'
  ;; alongside every `face' it applies.  Clearing it lets one property carry a run.
  (setq-local font-lock-defaults nil)
  ;; Which leaves jit-lock free to carry the cosmetic passes on its own.  It is
  ;; not font-lock and does not need it: `jit-lock-register' turns jit-lock on by
  ;; itself, and with `font-lock-defaults' nil the only entry in
  ;; `jit-lock-functions' is ours, so nothing runs a fontification that would
  ;; strip the bare `face' the line above exists to protect.
  ;;
  ;; Through `cooked--sync-fontification' rather than registered outright: the
  ;; hook jit-lock installs costs real time on the render path even when nothing
  ;; is ever scanned, so it follows whether there is anything to scan.  See there.
  (cooked--sync-fontification)
  ;; Above every minor mode, so a program that asked for the wheel gets it even
  ;; where `pixel-scroll-precision-mode' has claimed the same events.
  (add-to-list 'emulation-mode-map-alists 'cooked--mouse-map-alist)
  ;; Above the state maps for the same reason, and above `cooked--mouse-map-alist'
  ;; only incidentally -- the two never bind the same event.
  (add-to-list 'emulation-mode-map-alists 'cooked--override-map-alist)
  (add-hook 'post-command-hook #'cooked--track-selection nil t)
  ;; Per *terminal*, not per buffer, and re-checked when the buffer appears on
  ;; another frame -- an `emacsclient -t' opened after this session started has
  ;; a terminal of its own that has never been through here.
  (cooked--tty-esc-init)
  (add-hook 'window-buffer-change-functions
            (lambda (window)
              (when (windowp window) (cooked--tty-esc-init (window-frame window))))
            nil t)
  (cooked--install-thing-at-point-providers)
  (cooked--register-buffer)
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
  ;; `text-scale-mode-hook' is not the whole story, and the gap is the case
  ;; cooked already knows how to detect: `buffer-face-set',
  ;; `variable-pitch-mode' and `buffer-face-toggle' all rescale the font through
  ;; `buffer-face-mode', which runs no hook of its own -- so a session put into
  ;; a proportional face was never told to re-measure, even though
  ;; `cooked--ascii-fixed-pitch-p' exists precisely to notice one.  See
  ;; `cooked--advise-font-scale'.
  (cooked--advise-font-scale)
  (add-hook 'window-selection-change-functions #'cooked--window-selection-changed nil t)
  (add-hook 'context-menu-functions #'cooked--context-menu nil t)
  (add-hook 'kill-buffer-hook #'cooked--cleanup nil t))

;; A buffer of the child's rows, not text to edit, which is what `special' tells
;; every globalized tidier that asks: `ws-butler-global-mode' skips such a mode,
;; and would otherwise trim the child's rows on the first save.  Put here rather
;; than inherited, because `define-derived-mode' copies `comint-mode''s class
;; only when the mode function first runs, and not at all once the parent is
;; something else.
(put 'cooked-mode 'mode-class 'special)

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
;; the newest command is the one end of the transcript that keeps moving.  The mode
;; line's exit status is a click away from it too, but a keyboard cannot reach that
;; and a terminal frame does not draw it.
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

;; A paste in a terminal frame's host terminal arrives as an event of its own,
;; not as the key `yank' is bound to; see `cooked-xterm-paste'.  It is bound on
;; the shared parent because the passthrough maps bind characters and function
;; keys but never this event, so every state reaches it.
(define-key cooked-mode-map [xterm-paste] #'cooked-xterm-paste)

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
     ["Detect Links" (customize-set-variable 'cooked-detect-links
                                            (not cooked-detect-links))
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
     ["Auto-update Buffer Name"
      (setq cooked-buffer-name-auto-update (not cooked-buffer-name-auto-update))
      :style toggle :selected cooked-buffer-name-auto-update
      :help "Rename the buffer as the child's directory or title changes"]
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

(defun cooked--cleanup ()
  "Tear down the session behind this buffer, and the files it generated.

On `kill-buffer-hook\='.  `cooked--stop-session\=' is the half shared with
`cooked--on-exit\='; the generated startup files are removed only here, since
they are named by a path the buffer holds and nothing else can reach them."
  (cooked--cancel-secret)
  (cooked--stop-session)
  (cooked--remove-scratch))

(defun cooked--kill-emacs ()
  "Tear every session down on the way out of Emacs.

On `kill-emacs-hook\='.  Killing a session *buffer* reaps its child correctly --
`cooked--cleanup\=' is on `kill-buffer-hook\=' -- but exiting Emacs kills no
buffers, so without this the escalation in `Session::shutdown\=' never runs and
a child that ignores SIGHUP (`nohup\=', `trap \='\=' HUP\=', a detached session
leader) simply outlives the Emacs that started it.  The generated shell startup
files go the same way, and they are named by a path only the buffer holds, so
nothing else could ever find them again.

Cheap, and bounded.  A session with no child returns immediately; one with a
child pays the same SIGHUP, short grace, SIGKILL escalation a buffer kill pays,
which is tens of milliseconds and cannot wait on the child\='s own idea of when
to leave.  `cooked--dolist-buffers\=' contains a failure to the buffer it
happened in, which matters more here than anywhere else it is used: this is the
last code to run, and a session that cannot be torn down must not take the
sessions after it in `buffer-list\=' with it.

`cooked--cancel-secret\=' is deliberately not called, unlike in
`cooked--cleanup\='.  It exists to put the buffer and the echo area back the way
a `getpass\=' prompt found them, and there is no after for it to restore to."
  (cooked--dolist-buffers
    (cooked--stop-session)
    (cooked--remove-scratch)))

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
