;;; cooked-state.el --- A session's state, and who owns the keyboard -*- lexical-binding: t; -*-

;;; Commentary:

;; What a cooked buffer knows about its child between drains: the cursor and the
;; grid as the native core last described them, the modes the child negotiated,
;; what OSC 133 has said about the line, and `cooked-ownership', which is who
;; owns the keyboard, whether the render runs and whether the view follows,
;; derived from all of it in one place.
;;
;; This file sits directly on cooked-util.el and below everything that renders,
;; forwards or binds a key, because all of those ask these questions.  It calls
;; nothing above it.

;;; Code:

(require 'cl-lib)
(require 'cooked-util)

(cooked--declare-core)

;;;; What the two ends exchange
;;
;; The native core reports its cursor as a five-element list and its geometry as
;; three keys of the drain's plist, both of which are the cheapest thing to build
;; across the module boundary.  Neither is a good thing to *read*: `(nth 3
;; cooked--cursor)' says nothing about what it holds, and a positional decode
;; repeated at twenty call sites is twenty chances to count wrong.  So the shapes
;; are decoded once, at the boundary in `cooked--apply', and everything above it
;; works in terms the reader can check.

(cl-defstruct (cooked-cursor (:constructor cooked--cursor-make) (:copier nil))
  "The child's cursor: where it is, and what it should look like."
  (row 0 :documentation "Screen row, zero-based.")
  (col 0 :documentation "Screen column, zero-based.")
  (chars 0 :documentation "\
Characters of its row's text before it, which is where it is in the buffer.
Not COL once a wide character or a combining mark comes before it: on `日本X'
with the cursor on `本' COL is 2 and this is 1.  The core counts it, by the
rule its row edits are measured by.")
  (visible t :documentation "Whether the child has asked for it to be shown.")
  (shape 'block :documentation "`block', `underline' or `bar', from DECSCUSR."))

(defvar-local cooked--cursor (cooked--cursor-make)
  "The child's cursor as of the last drain, a `cooked-cursor'.")

(defun cooked--cursor-decode (spec)
  "Decode SPEC, the (ROW COL VISIBLE SHAPE CHARS) list the native core reports."
  (pcase-let ((`(,row ,col ,visible ,shape ,chars) spec))
    (cooked--cursor-make :row (or row 0) :col (or col 0) :chars (or chars col 0)
                         :visible visible :shape (or shape 'block))))

(defun cooked--cursor-cell ()
  "The child's cursor as a (ROW . COL) screen cell."
  (cons (cooked-cursor-row cooked--cursor) (cooked-cursor-col cooked--cursor)))

(cl-defstruct (cooked-grid (:constructor cooked--grid-make) (:copier nil))
  "The emulator's own account of its grid, as of the last drain.

`cooked--rows' and `cooked--cols' are what Emacs *asked* the child for, which is
a different thing and can differ for as long as it takes a resize to land.  This
is what the grid actually is, so the buffer is shaped by the emulator rather
than by a second opinion of it."
  (height 24 :documentation "Rows the grid has.")
  (width nil :documentation "\
Columns the grid has, or nil before the first drain.  A drain reporting another
width has rewrapped the rows; see `cooked--apply'.")
  (used 1 :documentation "Rows of it that are occupied — see `cooked--fit-screen'.")
  (head 0 :documentation "\
Characters of screen row 0's logical line that are already in the buffer, above
`cooked--screen-start'.  Non-zero exactly when the last row handed to scrollback
was wrapped and row 0 continues it, which is why the marker then sits mid-line.
See `cooked--check-seam'."))

(defvar-local cooked--wake nil "Pipe process Rust pokes when output is pending.")
(defvar-local cooked--rows 24
  "Rows Emacs last asked the child for.
The grid's own height is in `cooked--grid'.")
(defvar-local cooked--cols 80
  "Columns Emacs last asked the child for.  Not a measurement of the grid.")
(defvar-local cooked--screen-start nil
  "Marker at the first line of the live screen; everything before is scrollback.")

(defun cooked--screen-start-position ()
  "Where the live screen begins, or nil before a session has started one.

The marker is nil until `cooked--start' makes it and can outlive its buffer
text, so both have to be checked; doing that here keeps the check from being the
loudest thing at every call site."
  (and cooked--screen-start (marker-position cooked--screen-start)))

(defvar-local cooked--grid (cooked--grid-make)
  "The grid as the emulator last described it, a `cooked-grid'.")
(defvar-local cooked--alt nil)
(defvar-local cooked--pin-screen-top nil
  "Non-nil while the live screen belongs at the top of the window.

Set when the child clears the display, and held until the screen scrolls again
-- which is when the grid has filled the window, and pinning its top is the same
view as following its bottom.  A single drain would not be enough: the cleared
screen holds one row, so the very next drain's ordinary recentring would put
that row at the foot of the window and pull the transcript straight back into
view, undoing the clear a keystroke later.")
(defvar-local cooked--input-mode nil
  "How this buffer is treating the keyboard and the render right now.

One of:

  nil      Forward everything the policy's map forwards, render live, follow
           the child's cursor.  The ordinary case, and the only one a
           non-`evil' user reaches without asking.
  `semi'   Forward, but hold back the keys that change what Emacs is doing --
           see `cooked-semi-map'.  Render live, follow the cursor.
  `still'  Forward nothing; the buffer is read-only and ordinary Emacs
           commands reach it.  The render stays live, but nothing moves the
           view: the child keeps drawing under a point that stays where the
           user put it.
  `frozen' As `still', and the render is deferred as well, so the picture
           being navigated cannot change at all.

These are three independent questions -- does a key forward, does the buffer
render, does the view follow -- and one flag cannot answer all three: collapse
them and stepping out to `evil' normal state stops the terminal dead.  See
`cooked--suspended-p', `cooked--frozen-p' and `cooked--follow-p', which are
what the rest of the code asks.

The mode is computed for a prompt too, and there the first question has no
content: Emacs owns the line, so the keyboard half of `still' and `frozen'
simply does not apply and only their claims about the render survive.  A child
can repaint a canonical tty for minutes on end -- `brew upgrade' does -- and
the view being held still while that happens is the whole point of the two
states.  `cooked--suspended-p' is where that exception lives, and it is the
only place it lives.")

(defvar-local cooked--peek-explicit nil
  "Whether `cooked-toggle-peek' was used to step out deliberately.
Kept apart from `cooked--input-mode' because the mode is recomputed from
scratch on every state change: a deliberate peek has to survive a `raw'<->`alt'
transition, and nothing else about the mode does.")

(defvar-local cooked--read-only nil
  "Whether the `buffer-read-only' in force is ours, from a suspended state.

Kept for the same reason `cooked--narrowed' is: a refresh that finds the buffer
no longer suspended should undo its own protection and nothing else.  Without
it, a `read-only-mode' the user turned on themselves was cleared by the next
state change that happened along.")

(defun cooked--suspended-p ()
  "Whether keys are being kept from the child rather than forwarded.

Both halves: the mode says to withhold, and there is a child holding the
keyboard to withhold from.  At a prompt there is not.  Emacs owns the line
outright, so nothing is being forwarded for a mode to suspend -- and the two
things this predicate gates besides the keymap, `buffer-read-only' and
`cooked-peek-map', would each break the line being edited rather than protect
it: one refuses the user's own typing outright, the other remaps
`self-insert-command' to raw bytes that go past cooked's line editor entirely.

So this stays the narrow question of who the keyboard belongs to.  The two that
generalise past it -- does the render run, does the view follow -- are the
RENDER and FOLLOW fields, which the input mode answers on its own; see
`cooked--frozen-p' and `cooked--follow-p'."
  (cooked-ownership-suspended (cooked--ownership)))

(defvar-local cooked--attention nil
  "Whether the user is looking at this buffer: nil, `here' or `away'.

nil until it has been on screen at all.  A buffer that has never been
displayed has no attention to lose -- one driven from Lisp, or a test -- and
counting it as abandoned would freeze nothing and thaw everything.

Maintained by `cooked--update-attention' from the window hooks rather than
computed on demand, because the interesting case cannot be seen from the
buffer afterwards: once another buffer takes over its window, a cooked buffer
is displayed nowhere, which is indistinguishable from never having been shown
except by having watched it happen.")

;;;; Whether the screen is being drawn, and whether it is owed a drain
;;
;; Two questions, and until now four flags for them.  A drain may leave the live
;; screen out -- it is the expensive half, and nobody is looking -- and doing so
;; leaves a debt: the rows below `cooked--screen-start' are then whatever the
;; buffer held when the screen was last drawn, and anything that reads them has
;; to call one whole drain first.  Two different things ask for the screen to be
;; left out, for two different reasons, and one of them used to do it by `setq'
;; from another file, which its own docstring called a bargain.
;;
;; So the asking is `cooked--withhold-screen' and `cooked--release-screen', one
;; claim each, and what every reader asks is `cooked--screen-debt' -- plus, for
;; the readers that would pay the debt, `cooked--screen-kept-still-p', which is
;; the one place the two claims want different things.

(defvar-local cooked--screen-held-by nil
  "The claims for which drains are leaving this buffer's screen out.

A list, because the two claims are independent and neither knows about the
other.  `hidden' is the observed one: no window on a visible frame shows the
buffer, so drawing its screen would be work nobody can see, and the core does
not even wake Emacs for output that only changes it.  `completion' is asked
for, by `cooked--shell-completions', and is the case where the child is drawing
something that is not the child's answer: the shell puts the line Emacs is
holding into ZLE's own buffer to run compsys over it, and compsys refreshes the
display on its way to a message or a beep -- which draws that buffer, on a
screen whose own line is empty, so a second copy of the command appears exactly
where the completion would have gone.  The shell repairs it before replying,
but a drain landing in between renders the copy and the user sees the command
flicker doubled.

Withholding is what closes that window rather than another repair, because the
repair can only ever run after the fact and the flicker is the interval itself.
Events are still handled while it is held, which is the whole reason this is
not `cooked-inhibit-redraw-functions': the reply being waited for arrives as an
event, so a drain that never ran would deadlock the request it was protecting.

Never read outside the questions below; `cooked--screen-debt' is what a
reader of the rows asks, and `cooked--screen-kept-still-p' is what it asks
next if it means to pay.")

(defvar-local cooked--screen-owed nil
  "Whether a whole drain is owed this buffer's screen.

Set when a drain leaves the screen out and when a claim is taken, since the
core holds output back for a hidden buffer without waking anyone; cleared by
the next whole drain.  Meanwhile the rows below `cooked--screen-start' are
whatever the buffer held when it was last drawn: a hidden `make -j' has
appended its output above a screen that still reads as it did an hour ago.
Anything that reads those rows catches them up first with `cooked--sync', and
showing the buffer does the same.

Separate from `cooked--screen-held-by' because the two come apart in both
directions: a hidden buffer that `cooked--sync' has just drained whole owes
nothing and is still hidden, and a buffer shown again after an hour owes a
drain and is held by nothing.")

(defun cooked--screen-debt ()
  "What this buffer's live screen is owed: nil, `hidden' or `withheld'.

`hidden' is a screen being left out of drains right now, whoever asked for
that; `withheld' is one that was left out and has not been caught up since.
Both mean the rows below `cooked--screen-start' may be stale, which is all a
reader of the text has to know, so `cooked--sync' and
`cooked--sync-before-redisplay' ask this and then ask
`cooked--screen-kept-still-p' whether paying the debt is allowed.
`cooked--on-wake' asks this alone, because it is deciding what *this* drain
should do rather than whether the rows can be trusted, and a drain runs under
either claim."
  (cond (cooked--screen-held-by 'hidden)
        (cooked--screen-owed 'withheld)))

(defun cooked--screen-kept-still-p ()
  "Whether a claim wants this buffer's rows left exactly as they are.

The two claims differ here, and only here.  A `hidden' screen pays its debt
gladly: a redisplay of a buffer that was hidden means somebody is looking
again, and the rows they would otherwise read are an hour old.  A `completion'
screen must not, because what a drain would render mid-request is the shell's
own copy of the command line rather than anything the user asked for -- the
flicker the claim exists to prevent -- and `accept-process-output', which the
request blocks in, redisplays while it waits.  So the debt is refused for as
long as the request holds it.

What that costs is bounded by the request: a reader asking meanwhile gets rows
one drain stale, and `cooked--shell-completions' drains whole the moment it
releases."
  (and (memq 'completion cooked--screen-held-by) t))

(defun cooked--withhold-screen (claim)
  "Have drains leave this buffer's live screen out, on behalf of CLAIM.

CLAIM is `hidden' or `completion'; see `cooked--screen-held-by' for what each
one is.  Taking a claim owes the screen a drain from that moment, whether or
not one has run since: for `hidden' the core wakes nobody for output that only
changes a screen nobody is looking at, so there is no later drain to notice it.

Idempotent, so a window hook that fires twice for one change costs nothing."
  (cl-pushnew claim cooked--screen-held-by)
  (setq cooked--screen-owed t))

(defun cooked--release-screen (claim)
  "Stop leaving this buffer's screen out on behalf of CLAIM.

The debt stays behind: releasing the last claim leaves `cooked--screen-debt'
answering `withheld' until a whole drain pays it, which is what
`cooked--shell-completions' and `cooked--update-buffer-visibility' each arrange
on their way out.  Releasing one of two claims changes nothing, which is the
reason the claims are a list and not a flag."
  (setq cooked--screen-held-by (delq claim cooked--screen-held-by)))

(defun cooked--buffer-hidden-p ()
  "Whether no window on any visible frame shows the current buffer.

Only a buffer that has been on screen can be hidden, which `cooked--attention'
is what knows: a buffer driven from Lisp, or a test, has no window to lose, and
calling it hidden would leave every drain it takes without its screen.  A
buffer started in the background and never shown is therefore rendered in
full, as it always was."
  (and cooked--attention (not (get-buffer-window nil 'visible)) t))

(defun cooked--frozen-p ()
  "Whether the render is being deferred.

Only while this buffer is the one under the user's eyes.  Freezing exists to
keep a picture still while it is being read; a buffer the user has left is not
being read, and a terminal that stopped updating because its window lost
selection is the complaint this whole distinction exists to answer.  The child
never stopped running either way -- the freeze only ever deferred the drain."
  (eq (cooked-ownership-render (cooked--ownership)) 'deferred))

(defun cooked--follow-p ()
  "Whether point and the window should track the child's cursor.

The mode alone, deliberately, and not `cooked--suspended-p': whether keys are
being withheld is a question about the child's keyboard, and a child that never
took the keyboard can still be repainting.  `brew upgrade' draws its progress
bars over a tty that stays canonical throughout, which leaves the policy at
`cooked' -- so gating the freeze on forwarding made `still' and `frozen'
structurally unreachable in exactly the case a held view is worth most.

Point inside the pending input is the one thing this does not speak for; see
the `editing' binding in `cooked--apply'."
  (cooked-ownership-follow (cooked--ownership)))

(defvar-local cooked--narrowed nil
  "Whether the restriction in force is ours, from `cooked--apply-alt-pin'.")
(defvar-local cooked--app-cursor nil
  "DECCKM: send cursor keys as SS3, which is what `smkx' asks for.")
(defvar-local cooked--keys 'legacy
  "How to spell modified keys for this child.

One of `legacy', `modify-other' or `kitty', as negotiated by the child itself —
see `cooked--key-encodings' for why this cannot simply be assumed.  Which keys a
protocol covers is a second question, answered by `cooked--kitty-flags' and
`cooked--modify-other-keys'.")
(defvar-local cooked--kitty-flags 0
  "The kitty keyboard flags the child pushed, masked to what cooked honours.

A bit field, as the protocol defines it: 1 disambiguates escape codes, 4 adds
the shifted key, 8 sends every key as an escape code and 16 adds the text a key
produces.  Read only while `cooked--keys' is `kitty', and not enough on its own
even then: with neither 1 nor 8 set, kitty was assumed rather than negotiated --
see `cooked-key-protocol-overrides' -- and only the `literal' keys are
re-spelled.  See `cooked--kitty-negotiated-p'.")
(defvar-local cooked--modify-other-keys 0
  "The modifyOtherKeys level the child set with `CSI > 4 ; LEVEL m', or 0.

1 or 2; the core reports anything else as 0.  Read only while `cooked--keys'
is `modify-other', and the difference between 0 and a level there is the
difference between a guess and a negotiation -- see
`cooked--modify-other-level'.")
(defvar-local cooked-title nil
  "Title the child last set, via OSC 0 or 2, or nil if it never set one.

Public, unlike the rest of the session state beside it, because it is the one
piece a reader outside the tree has an obvious use for -- a buffer switcher, a
tab line, a `frame-title-format' -- and it has a reader in five files inside
it.  The child's own bytes: anything that puts it in a mode line has to
escape `%' first, as `cooked--mode-line-quote' does.")
(defvar-local cooked--title-stack nil
  "Titles saved by XTWINOPS 22, newest first.  See `cooked--handle-title-stack'.")
(defvar-local cooked--host nil
  "Host the child last reported over OSC 7, or nil for this machine.

The authority half of `file://HOST/PATH'.  Keeping it is what stops every
path-shaped thing in the buffer being answered locally: after an `ssh', the
remote shell goes on reporting its directory faithfully and the names it sends
are real -- on the other host.  A local `/home/you/src/thing' that happens to
exist here is the failure case, and it is the common one, because the layouts
people ssh between are the ones they keep in step.

Set by `cooked--set-directory' and read through `cooked--foreign-host-p';
see it for what declines and why.")
(defvar-local cooked--mode 'cooked)
(defvar-local cooked--exit nil)

(defun cooked--foreign-host-p ()
  "Whether the child last said it was somewhere other than this machine.

Nil until a shell says otherwise, which is the right default twice over: a
child that never sends OSC 7 is overwhelmingly a local one, and a hostile
stream cannot reach *more* of the buffer by staying quiet.

Which names count as this machine is `cooked--local-host-p', shared with the
comint filter's own OSC 7 tracking and, through `cooked--same-host-p', with
the TRAMP prefix in `cooked--remote-directory'.  One deciding a host has
changed while another decides it has not is exactly how a path ends up sent
down the wrong connection."
  (and cooked--host
       (not (cooked--local-host-p cooked--host))))

(defun cooked--csi (final &rest params)
  "The control sequence `ESC [ PARAMS FINAL', with PARAMS joined by `;'.

Every escape sequence cooked sends the child that is not an OSC is framed here
or in `cooked--ss3', and for the same reason an OSC handler calls
`cooked--reply-osc' rather than writing the brackets out itself: the framing is
the part that is identical every time, so it is the part that has no business
being respelled at each call site, across the keyboard, the mouse, the focus
reports and the completion channel.  What actually differs between those sites
is the parameters and the final byte, and that is all they say.

FINAL is a string rather than a character because that is what it already is at
both of the sites that have one to hand: `cooked--key-encodings' stores the
final byte of a `csi' key as a string, and `cooked--mouse-report' chooses
between \"M\" and \"m\" for a press and a release.

PARAMS are numbers, so `(cooked--csi \"~\" 5 2)' is `ESC [ 5 ; 2 ~', the
modified spelling of `prior'.  None of them at all is the unparameterised
sequence `ESC [ FINAL', which is what an unmodified cursor key and the DEC 1004
focus notifications are.  A string is taken as the parameter verbatim, which is
for the kitty keyboard protocol: its fields carry colon-separated sub-fields and
may be empty, `ESC [ 97 : 65 ; ; 65 u', and neither is a number.

See `cooked--csi-private' for the two sequences that carry a private-parameter
prefix, and `cooked--cursor-key' for the one choice between CSI and SS3 that
depends on what the child has asked for."
  (apply #'cooked--csi-private nil final params))

(defun cooked--csi-private (prefix final &rest params)
  "The control sequence `ESC [ PREFIX PARAMS FINAL'.

PREFIX is the byte ECMA-48 sets aside ahead of the parameters for private use,
as a string, or nil for the ordinary sequence `cooked--csi' builds.  Cooked
sends two of them.  `<' introduces an SGR mouse report, and is the whole of
what tells the child it is reading one rather than an X10 report; see
`cooked--mouse-report'.  `>' introduces the completion request in
`cooked--shell-completions', which is private in the stronger sense that
nothing but cooked's own shell integration will ever recognise it, and
which is why it may take a free-form payload after the final byte that no other
sequence here would.

A second function rather than an optional argument in front of FINAL, because
the prefix is the rare case: reading a nil through every ordinary call site
would bury the two things a reader wants from one of these, which are the
parameters and the final byte."
  (concat "\e[" prefix
          (mapconcat (lambda (p) (if (stringp p) p (number-to-string p))) params ";")
          final))

(defun cooked--ss3 (final)
  "The single-shift-three sequence `ESC O FINAL'.

The application-keypad spelling of a cursor or function key: what the child
receives for `up' once `smkx' has asked for it, and the unmodified spelling of
F1 through F4 whatever mode it is in.

Not `cooked--csi' with a different introducer, because SS3 shifts exactly one
character and so can carry no parameters at all.  That is not a limitation this
has to work around -- a key with a modifier to report leaves SS3 behind and is
spelled as a CSI instead, which `cooked--encode-event' does for both of the
cases above."
  (concat "\eO" final))

(defun cooked--meta-prefixed (mods seq)
  "SEQ as a key held with MODS sends it where no protocol spells the modifier.

That is SEQ with an ESC in front when MODS holds `meta', and SEQ unchanged
otherwise: `M-x' is `ESC x', which is xterm's `metaSendsEscape' and the
only spelling of Meta a child that negotiated nothing can read.  Control and
Shift are not this function's to apply, having already been folded into SEQ."
  (if (memq 'meta mods) (concat "\e" seq) seq))

(defun cooked--cursor-key (final)
  "Cursor key FINAL spelled the way the child last asked for it.

`ESC O FINAL' while DECCKM is set -- see `cooked--app-cursor' -- and
`ESC [ FINAL' otherwise.

Here rather than in cooked-keys.el because the choice is made twice and from
two different subjects: `cooked--encode-event' makes it for an arrow the user
pressed, and `cooked--alt-scroll-keys' for the arrows a wheel notch stands in
for on the alternate screen.  Those had the conditional written out once each,
which is the shape that lets a child in application mode be sent one spelling
by the keyboard and the other by the mouse."
  (if cooked--app-cursor (cooked--ss3 final) (cooked--csi final)))

;;;; Who owns the keyboard
;;
;; The question the whole package turns on, and the reason this is here rather than
;; in cooked-mode.el with the keymaps it selects: rendering has to ask it.  Applying
;; a drain means lifting the pending input out of the buffer, rewriting the screen
;; underneath it and putting it back — which is a question about ownership, asked
;; from inside the process filter, long before any key is pressed.
;;
;; So the state and the policy derived from it live at this level, and the layers
;; above bind keys to them.  A lower file that changes something the policy reads
;; says so with `cooked--request-refresh', and `cooked--refresh-keymap' answers it
;; from the top; that refresh is the seam `cooked-state-change-hook' hangs off.

(defvar-local cooked--semantic nil
  "OSC 133 state: nil, `prompt', `input' or `output'.")
(defvar-local cooked--semantic-seen nil
  "Whether any OSC 133 mark has arrived in this session.

Latched, because `cooked--semantic' goes back to nil between `command-end' and
the next `prompt-start' and so cannot answer \"is the integration working?\".
Once a shell has spoken at all, it will keep speaking, and everything it does
not say becomes informative -- see `cooked--policy'.")
(cl-defstruct (cooked-line (:constructor cooked--line-make) (:copier nil))
  "What the shell has said about the line being typed, and what Emacs did with it.

Every one of these is a claim about one line, so all of them end when a command
starts: `cooked--handle-semantic' drops the whole record at `command-start',
and a field added here is cleared there without anyone remembering to.  A fresh
prompt ends two of them sooner, as their slots say.

Read and written through `cooked--line', which makes the record on first use."
  (delegated nil :documentation "\
Whether this line has been handed to the child's own line editor.

Set by `cooked-delegate-key'.  Delegation is a state rather than a send: once
the line is in the pty the shell is echoing and editing it, so Emacs going on
believing it owns an input region would render the line twice and edit a copy
the child never sees.  Cleared at a fresh prompt as well as at a command, so it
lasts exactly as long as the line it was about.  ZLE is still a line editor, so
`C-a', `C-w' and the arrows keep working; they are the shell's now.")
  (completion-nonce nil :documentation "\
Nonce from the prompt's OSC 51;CH announcement, or nil if it did not announce.

Two signals wearing one name.  To `cooked-shell-completion' it is the token a
request must carry.  To `cooked--policy' it is a license to own the input line:
the shell asserting, for this line, that a widget is bound and reading, which is
the only corroboration left once termios has gone dark behind an `ssh'.  So the
announcement is believed whether or not the completion layer is loaded.

Dropped at `command-start' with the rest of the record, which keeps it a claim
about the present: without that, `ssh host' would leave the local shell's
nonce standing and the bare remote prompt would inherit a license nothing on
that host ever issued.")
  (completion-reply-capable nil :documentation "\
Whether the announcing shell can also answer completion requests.

Separate from the nonce because framing a reply needs `base64' and owning the
line does not.  A shell without it announces anyway and says so here, keeping
its editable line with nothing to offer `completion-at-point'.")
  (prompt-continued nil :documentation "\
Whether the prompt on screen continues the line already submitted.

Set by the OSC 133 `A;k=s' mark a shell puts on its `PS2' and cleared at the
next real prompt.  `cooked--send-input-string' reads it: without it the record
for \"for x in 1 2; do ... done\" would say only `done', because each
continuation line is submitted separately and would overwrite the one before.")
  (submitted-input nil :documentation "\
The line last submitted, waiting for the OSC 133 mark that says it started."))

(defvar-local cooked--line-record nil
  "This buffer's `cooked-line', or nil before anything has been said.
Go through `cooked--line', which makes one when there is none.")

(defun cooked--line ()
  "The `cooked-line' for the line being typed in this buffer, made on first use."
  (or cooked--line-record
      (setq cooked--line-record (cooked--line-make))))

(defvar-local cooked--marks nil
  "Hash of OSC 133 mark id to the buffer marker made for it.

The index a resize is repaired through, and nothing else reads it.  A mark
arrives with an anchor that resolves to a buffer position exactly once; a
*rewrap* then re-lays every live row at the new width and Emacs rebuilds them,
which leaves that position naming text that has moved.  The emulator keeps the
mark on the cell it landed on -- see `Extra::Mark' in src/emu/cell.rs -- and
reports the ones that moved as the drain's `:marks', so this is what pairs an id
back up with the marker to move.

The markers here are the *same objects* the command records hold, not copies:
`cooked--relocate-marks' moves one and every record built on it follows, which
is why `cooked-command' needed no new fields for any of this.

Pruned in `cooked--render-scrolled', where entries stop being reachable: a mark
below `cooked--screen-start' is in settled text the emulator will never speak
about again.")

(cl-defstruct (cooked-ownership (:constructor cooked--ownership-make) (:copier nil))
  "Who owns the keyboard, whether the render runs, and whether the view follows.

Those are three independent questions -- see `cooked--input-mode' for what
happens to a terminal when they are collapsed into one flag -- and each of them
used to be recombined from the raw state at its own call site.  That shape is
what left `command' out of three separate checks when it was added, and what
kept the freeze unreachable at a prompt until the follow question was split off
from the forwarding one.  Neither was caught by the shape of the code: it was
right because the tests pinned the combinations, not because a wrong one could
not be written.

So the recombination happens exactly once, in `cooked--derive-ownership', and
every field here is a function of the ten inputs `cooked--ownership' collects
for it.  A new state is then a row in that function rather than a grep across
seven files, and `cooked-ownership-is-derived-from-its-inputs' enumerates the
combinations so a row that answers wrongly fails before anyone runs a shell
under it.

Read through `cooked--ownership', which derives a fresh record from the buffer's
state as it is now.  The named predicates below -- `cooked--policy' and its
eight neighbours -- are field reads of that record and are what most callers
should still use; they are the vocabulary the rest of the tree is written in."
  (policy 'cooked :documentation "\
`cooked', `prompt', `command', `raw' or `alt'; see `cooked--policy'.
Kept as a value of its own rather than folded into KEYBOARD because the mode
line names it and the keymap choice distinguishes four of the five.")
  (keyboard 'emacs :documentation "\
`emacs' or `child': who the keys being pressed are for.
`emacs' is the `cooked' policy and nothing else -- said that way round on
purpose, so a state arriving cannot be forgotten by a list of the states that
qualify.  See `cooked--child-owns-keyboard-p'.")
  (render 'live :documentation "\
`live' or `deferred': whether a drain is applied or held back.
`deferred' only while the user is looking; see `cooked--frozen-p'.")
  (follow t :documentation "\
Whether point and the window should track the child's cursor.
The input mode alone, and deliberately not KEYBOARD; see `cooked--follow-p'.")
  (suspended nil :documentation "\
Whether keys are being kept from a child that has the keyboard.
Both halves, which is what keeps a mode's claim on the keys away from a line
Emacs is editing; see `cooked--suspended-p'.")
  (secret nil :documentation "\
Whether the child is reading with echo off; see `cooked--secret-p'.")
  (license nil :documentation "\
Whether a marked prompt was corroborated; see `cooked--ownership-license'.
Recorded rather than recomputed so the reason for a `cooked' policy at a
marked prompt is legible in the record itself.")
  (peek nil :documentation "\
Whether a deliberate `cooked-toggle-peek' is still in force.
The flag survives a `raw'<->`alt' transition and does not survive a prompt or
the child exiting, which is the whole of the difference between it and the
input mode; see `cooked--peek-explicit'.")
  (keymap 'input :documentation "\
Which map the buffer should wear: `input', `peek', `semi', `alt', `command'
or `raw'.  A name and not a keymap, because the maps are built two layers
above this file and because a name is what a table test can assert on;
`cooked--state-keymap' is what turns it into an object."))

(cl-defun cooked--derive-ownership
    (&key (mode 'cooked) alt semantic semantic-seen delegated (license t)
          input-mode peek-explicit attention (session t))
  "The `cooked-ownership' that the state described by the arguments comes to.

Pure, and that is the point of it: it reads no buffer-local and calls nothing
that does, so every combination of its arguments can be put to it directly.
`cooked--ownership' is the one caller that knows where the real values live.

The arguments are the ten inputs, defaulted to a buffer that has just started
against a local shell: MODE is `cooked--mode', ALT `cooked--alt', SEMANTIC and
SEMANTIC-SEEN the OSC 133 state, DELEGATED `cooked-line-delegated', LICENSE
`cooked--ownership-license', INPUT-MODE `cooked--input-mode', PEEK-EXPLICIT
`cooked--peek-explicit', ATTENTION `cooked--attention', and SESSION whether
there is a live session at all.

The policy is derived rather than reported, because no single source knows the
answer; `cooked--policy' is where that argument is written out.  What is only
visible from here is how the rest hangs off it.  A deliberate peek is dropped
wherever it has nothing left to mean -- at a prompt, and after the child has
gone -- rather than merely ignored, so that `cooked-toggle-peek' answers
\"Already editable\" instead of toggling a flag nothing reads.  A dead session
settles for the same reason a prompt does: there is no child to keep keys from
and nothing to defer, and a buffer left suspended when its child exited must
not stay read-only with no way back.

The keymap follows the policy where the two disagree and the mode only
otherwise, which is the same precedence `cooked--suspended-p' states: a mode
that suspends forwarding is a claim about keys on their way to the child, and
at a prompt there are none."
  (let* ((policy
          (cond (alt 'alt)
                ;; A password read forwards keys too; the minibuffer collects
                ;; them.
                ((eq mode 'secret) 'raw)
                ;; OSC 133 before termios: MODE is poll-sampled and
                ;; approximate, SEMANTIC is exact and in-band.  But a mark is
                ;; only a claim, so it takes the keyboard only with a license
                ;; behind it.
                ((and (eq semantic 'input) (not delegated) license) 'cooked)
                ((eq mode 'cooked) 'cooked)
                ((eq semantic 'input) 'prompt)
                (semantic-seen 'command)
                (t 'raw)))
         (keyboard (if (eq policy 'cooked) 'emacs 'child))
         (held (and (memq input-mode '(still frozen)) t))
         (suspended (and held (eq keyboard 'child)))
         ;; Where a deliberate peek, and the mode's claim on the keys with it,
         ;; has nothing left to mean.
         (settled (or (eq policy 'cooked) (not session))))
    (cooked--ownership-make
     :policy policy
     :keyboard keyboard
     ;; Freezing exists to keep a picture still while it is being read, and a
     ;; buffer the user has left is not being read.
     :render (if (and (eq input-mode 'frozen) (not (eq attention 'away)))
                 'deferred
               'live)
     :follow (not held)
     :suspended suspended
     :secret (eq mode 'secret)
     :license (and license t)
     :peek (and peek-explicit (not settled) t)
     :keymap (cond
              (suspended 'peek)
              ((and (eq input-mode 'semi) (eq keyboard 'child)) 'semi)
              ;; The three that forward everything are told apart here and
              ;; given their maps in `cooked--state-keymap'.  A marked prompt
              ;; with no license reads exactly like a running command as far as
              ;; the keyboard is concerned: the shell said where it is, so
              ;; there is nothing left for `cooked-raw-exceptions' to hedge and
              ;; it would only take keys away from a line editor that wants
              ;; them.
              ((eq policy 'cooked) 'input)
              ((eq policy 'alt) 'alt)
              ((memq policy '(command prompt)) 'command)
              (t 'raw)))))

(defun cooked--ownership ()
  "This buffer's `cooked-ownership', derived from its state as it stands now.

Derived on every call rather than latched, because the inputs move in nine
different files and on their own schedules -- a termios poll, an OSC 133 mark,
the alternate screen going up mid-drain -- and a latch would need every one of
them to remember to invalidate it.  The record is small and the derivation is a
`cond'; what a latch would buy is not worth a stale answer about who the next
keystroke belongs to.

`cooked--refresh-keymap' is the one caller that derives it once and acts on
several fields at a time, and it stores what it decided in
`cooked--announced-ownership'."
  (cooked--derive-ownership
   :mode cooked--mode
   :alt cooked--alt
   :semantic cooked--semantic
   :semantic-seen cooked--semantic-seen
   :delegated (cooked-line-delegated (cooked--line))
   :license (cooked--ownership-license)
   :input-mode cooked--input-mode
   :peek-explicit cooked--peek-explicit
   :attention cooked--attention
   :session (and cooked--session t)))

(defun cooked--policy ()
  "How the buffer should behave right now.

One of `cooked', `prompt', `command', `raw' or `alt'.

Derived rather than reported, because no single source knows the answer.  The
alt screen comes from the child's own output, the line discipline is sampled
from termios, and the prompt state comes from OSC 133 -- and the three disagree
routinely.  A shell sits in termios raw mode at every prompt, because readline
does its own editing; a full-screen program can start while the last OSC 133
mark still says `prompt-end'.

Alt wins over everything.  It is the one state in which the child has taken the
screen over completely, so Emacs owns neither the keyboard nor the viewport --
and it is in-band, arriving at an exact position in the byte stream, where the
termios mode is sampled on a poll.

`prompt', `command' and `raw' are the same situation -- the child owns the
keyboard -- told apart by how well we know it.  With OSC 133 working, a raw read
that is not a prompt means the shell is running something, and it said so; that
is as positive a signal as the alt screen, so `command' keeps nothing back.
Without it, `raw' is a guess covering both a real full-screen program and a
shell editing its own prompt line, and `cooked-raw-exceptions' hedges against
the second.

`prompt' is a marked prompt with nothing corroborating the mark -- see
`cooked--ownership-license'.  It keeps nothing back either, for the same
reason `command' does not: the shell said where it was, and a shell at its own
prompt wants every key.  It is the state a bare shell at the far end of an
`ssh' sits in, and everything the marks buy other than the keyboard --
extents, exit codes, `next-error', rerun -- works there unchanged.

The derivation is `cooked--derive-ownership', which answers this and the rest of
`cooked-ownership' from the same inputs at the same moment.  This is the field
read, and the name the rest of the tree asks the question by."
  (cooked-ownership-policy (cooked--ownership)))

(defun cooked--ownership-license ()
  "Whether something corroborates the marked prompt enough to hand Emacs the line.

An OSC 133 `B' says a prompt is reading, and it says so in bytes, which is
what makes it survive an `ssh' -- and also what stops it corroborating itself.
After it arrives nothing says the far end is still at a prompt rather than three
seconds into a program that emitted no mark, and lifting the line out of a pty
that no line editor is reading is how keystrokes get eaten.

Two things corroborate it, and they are different in kind:

- *The child is ours.*  When the shell is on this machine, the pty is one Emacs
  spawned and can sample; termios bounds what a mark can be wrong about, and
  every local path the line might name is a path that is really there.
  `cooked--host' is how that is known, and it comes from the same snippet as
  the mark, so it is present exactly when the mark is.
- *A live announcement.*  `cooked-line-completion-nonce' is re-emitted per ZLE
  line from `zle-line-init' -- after the widget is bound and the keyboard is
  ZLE's, which is precisely the condition being claimed -- and cleared when a
  command starts.  It is the one signal that is both byte-transparent and
  self-corroborating, which is why it can license ownership from the far end of
  an `ssh' without the loophole it looks like.

What is deliberately *not* a license is the transport.  Keying decay to \"is
this remote\" would refuse a remote host running the full snippet, which reaches
the same certainty a local one does by the same bytes.  What `ssh' costs is
termios, and termios is an ownership signal, not a completion one.

Unlicensed, a marked prompt is not a broken state: the shell keeps its own line,
its own history and its own completion, and cooked keeps the extents, exit codes
and rerun that the marks were always the point of."
  (or (not (cooked--foreign-host-p))
      (and (cooked-line-completion-nonce (cooked--line)) t)))

(defun cooked--secret-p ()
  "Whether the child is reading with echo off.
An overlay on the policy rather than one of its values: it says how input is
collected, not who owns the screen."
  (cooked-ownership-secret (cooked--ownership)))

(defun cooked--input-state-p ()
  "Whether Emacs should be editing rather than passing keys through."
  (eq (cooked-ownership-keyboard (cooked--ownership)) 'emacs))

(defun cooked--child-owns-keyboard-p ()
  "Whether the child, rather than Emacs, is the one being typed at.

Every policy but `cooked', which is to say `alt', `prompt', `command' and
`raw' -- said that way round on purpose.  Spelling it as a list of the states
that qualify is what left `command' out of three separate checks when it was
added: the answer is a property of not being at a prompt, so asking that
directly cannot go stale when another state arrives."
  (eq (cooked-ownership-keyboard (cooked--ownership)) 'child))

(defvar-local cooked--announced-ownership nil
  "The `cooked-ownership' the last `cooked-state-change-hook' was run for.

Nil until the first refresh, so a session starting against a child that already
owns the keyboard still counts as a change and is announced.  Only the keyboard
field is compared against it: the hook means \"who owns the keyboard changed\",
and a render or a keymap moving is not news `cooked-evil-sync' can act on.

The one record that is kept rather than derived again -- see `cooked--ownership'
for why that is the exception -- because what it holds is not the state now but
the state the last announcement was made about.")

(defvar cooked--refresh-hook nil
  "Normal hook run when something a buffer's keymap is derived from changes.

The alternate screen going up, the tty's mode moving, a shell mark arriving,
a peek beginning or ending, the child exiting: each changes what
`cooked--policy' or the input mode would answer, and each is noticed in a
file below the one that installs the keymap.  Those files run this hook through
`cooked--request-refresh' rather than naming that function, and
cooked-mode.el puts `cooked--refresh-keymap' on it.")

(defun cooked--request-refresh ()
  "Have this buffer's keymap and input mode derived again.
See `cooked--refresh-hook'."
  (run-hooks 'cooked--refresh-hook))

(defcustom cooked-rejoin-wrapped-lines t
  "Whether a line the terminal wrapped becomes one buffer line again.

The emulator knows which scrolled-off rows were continuations rather than new
lines, so history can be stored the way it was written.  Rejoining means yanking
from the scrollback does not pick up newlines nobody typed, and widening the
window re-wraps old output for free, because Emacs is doing the wrapping.

Set to nil for the literal thing a terminal shows: one buffer line per screen
row, hard-wrapped at whatever width was in force when it was printed.

Turning it off also shrinks the scrollback, which is not obvious and is not
small: `cooked-scrollback-lines' counts *buffer* lines, so hard-splitting
multiplies the line count by the wrap factor and the same cap then retains far
less text -- about a ninth as much on 800-column output.  See there."
  :type 'boolean :group 'cooked)

(defcustom cooked-long-line-rows 8
  "Screen rows a rejoined line fills before Emacs may shorten its layout.

Emacs lays a soft-wrapped line out from the line's own beginning, so a window
scrolled into the middle of a line ten screen rows long pays for all ten rows at
every redisplay, and the bill grows with the window's width.  That is the cost
`cooked-rejoin-wrapped-lines' buys a rejoined transcript with, and the one this
exists to cap: Emacs 29 narrows layout to a window-sized piece of text either
side of point once the buffer is known to hold a long line -- whether or not
lines are truncated, which the other long-line shortcuts require.

So the question is what counts as long, and the answer here is counted in rows
of *this terminal* rather than in characters: `long-line-threshold' is set to
this many times `cooked--cols', re-derived wherever the width is adopted.
Eight rows of an 80-column terminal is 640 characters, where Emacs' own default
of 50000 is six hundred rows of it and so is never reached by anything a
terminal prints -- a rejoined transcript would keep the whole cost and get none
of the remedy.  Eight because the measured effect is nothing at three rows per
line and a doubled p90 at ten; a line just over the threshold still lays out
whole, since the window Emacs narrows to is itself several rows of the width.

The flag this sets is sticky.  A buffer that has held one long line keeps the
shortened layout for the rest of its life -- `long-line-optimizations-p' reads
it and nothing can clear it -- which is why the threshold is dropped to nil
once it is set rather than maintained forever; see
`cooked--sync-long-line-threshold', and docs/DESIGN.md for what the wait costs
a session whose lines never get that long.

What Emacs documents as less accurate under the flag, none of which is buffer
text: `recenter' counts every screen line as one default-height line instead of
asking the display code, so recentring a transcript of image slices lands
approximately; the scroll bar's idea of the last visible position is
approximated; automatic character composition is looked up only within a
window's worth of text either side of point; and `pre-command-hook' and
`post-command-hook' run narrowed to
`long-line-optimizations-region-size' characters around point, which none of
cooked's own hooks can tell apart from a widened buffer.  Copying, searching,
links, reflow, marks and the seam are the same text either way, because this
changes nothing about the text.

nil leaves `long-line-threshold' alone at Emacs' own value, which for a
terminal means the shortcuts never engage."
  :type '(choice (const :tag "Leave Emacs' threshold alone" nil)
                 (natnum :tag "Rows of the terminal's width"))
  :group 'cooked)

(defun cooked--sync-long-line-threshold ()
  "Derive this buffer's `long-line-threshold' from `cooked-long-line-rows'.

Called from `cooked-mode', from `cooked--sync-size' where a new width is
adopted, and from the foot of every drain -- because the right value moves
twice: with the width, and once Emacs has noticed.

Two values, and the second is the one worth the call.  While the flag is off the
threshold is `cooked-long-line-rows' rows of `cooked--cols', which is what
makes an ordinary wrapped command's output count as a long line at all.  Once
`long-line-optimizations-p' answers t the threshold has done its whole job: the
flag is sticky, so no later value can take the shortcuts away, and nil then
stops `redisplay_window' rescanning the transcript for a long line after every
drain -- 0.2 ms per redisplay over a megabyte of scrollback, 0.7 ms over five --
and takes `current-column' off its long-line approximation with it.

Guarded on the variable being bound, which is the Emacs 29 check: the threshold,
the reader and the narrowing all arrived together."
  (when (and (boundp 'long-line-threshold) cooked-long-line-rows)
    (setq-local long-line-threshold
                (and (not (long-line-optimizations-p))
                     (* cooked-long-line-rows cooked--cols)))))

(defvar-local cooked--last-size nil
  "The (ROWS . COLS) last reported to the emulator, or nil.")

(defvar-local cooked--foreground-name nil
  "Cached (PID . NAME) for the child's foreground process group.
`process-attributes' is not free, and the pid is what says whether it is stale.")

(defun cooked--foreground-program ()
  "Name of the program in the child's foreground process group, or nil.

Not the session's own command: that is usually a shell, and what the user is
looking at is whatever the shell put in the foreground.  So a `claude' typed at
a cooked shell answers `claude' here, which is the case an override has to be
able to name."
  (when-let* ((session (cooked--live-session))
              (pid (cooked--foreground-pid session)))
    (if (eq pid (car cooked--foreground-name))
        (cdr cooked--foreground-name)
      (cdr (setq cooked--foreground-name
                 (cons pid (alist-get 'comm (process-attributes pid))))))))

(defvar-local cooked--foreground-label nil
  "Name of the program the child last had in the foreground, for the mode line.

Maintained from `cooked--refresh-keymap' rather than read when the mode line
asks, for the same reason `cooked--attention' is: `cooked--mode-line' runs
from an `:eval' on every redisplay, and the answer costs a `tcgetpgrp' and,
on a miss, a `process-attributes' -- which its own cache exists because it is
not free.  Recomputing that per frame to render one word would be paying a
syscall for a string that changes when the policy does.

Every transition worth naming already passes through that refresh: termios
flipping as a full-screen program takes the tty, and an OSC 133 `C' as a
marked command starts.  What it misses is one quiet command following another
at an unmarked shell, where nothing changes state -- so the label is a
best-effort hint, and is allowed to be.")

(defun cooked--update-foreground-label ()
  "Refresh `cooked--foreground-label' for what the child is running now.

Nil when the foreground process group is the session's own child -- the shell
cooked spawned, sitting at its prompt.  Naming it there would put `zsh' in the
mode line for the whole life of every session, which is a word that is always
true and never news.

Deliberately *not* keyed on who owns the line.  A canonical tty is not a shell
prompt: `cat' and `sleep' hold one too, and cooked reads those as `edit'
because they genuinely are a line being edited.  Those are exactly the cases
where the program's name is the only thing on screen saying what the line will
be read by -- so the test is which process, not which policy."
  (setq cooked--foreground-label
        (and cooked--session
             (let ((foreground (cooked--foreground-pid cooked--session)))
               (and foreground
                    (not (eql foreground (cooked--pid cooked--session)))
                    (cooked--foreground-program))))))

(defcustom cooked-confirm-kill 'auto
  "Whether killing a live session asks first.

t makes both of the prompts a terminal buffer ought to have: killing the buffer
asks \"Buffer *cooked* has a running process; kill it?\", and
\\[save-buffers-kill-emacs] counts the session among the active processes it
warns about before exiting.  nil kills the child without a word.  `auto', the
default, asks only while something other than the shell's own prompt is on the
other end -- which is the case the warning exists for, and the one an idle shell
buffer is not.

Neither prompt is written here.  Both are Emacs' own -- `kill-buffer' runs
`kill-buffer-query-functions', whose default member is
`process-kill-buffer-query-function', and `save-buffers-kill-emacs' walks
`process-list' -- and each asks a *process* whether it minds being killed, via
`process-query-on-exit-flag'.  So this is spelt as the flag on `cooked--wake',
which is what puts the session in front of the machinery the user already has:
`confirm-kill-processes' still turns the exit prompt off globally, the session
still appears in the `*Process List*' that prompt pops up, and a
`kill-buffer-query-functions' entry of the user's own still gets its say.

vterm and term.el get this for free and never mention it: their child *is* an
Emacs process, and `make-process' leaves the flag t, so both always ask.  eat
has the same three answers under `eat-query-before-killing-running-terminal',
also defaulting to `auto', and drives them the same way -- clearing the flag
from its OSC 133 prompt handler and setting it again before a command runs.
Cooked's child is neither vterm's nor eat's: it belongs to the native core, and
the only process object Emacs has for it is the wakeup pipe, which was created
`:noquery' back when it was purely a doorbell.  Nothing was suppressing the
warning; there was simply no process standing for the session for Emacs to warn
about.  The flag hanging off the doorbell rather than the child is the same
substitution `cooked--start' already documents for comint's benefit, and it is
honest in the one way that matters here: the pipe is open for exactly as long as
the child is alive, and `cooked--on-exit' deletes it the moment it is not.

`auto' is safe where the shell says nothing.  It reads `cooked--policy', not a
shell hook, so a session with no OSC 133 integration at all never reaches the
`cooked' policy and is therefore always queried -- the same answer as t.  Going
quiet is something the shell has to ask for, by telling us it is at a prompt."
  :type '(choice (const :tag "Never ask" nil)
                 (const :tag "Ask only when the child owns the keyboard" auto)
                 (const :tag "Always ask while the child is alive" t))
  :group 'cooked)

(defun cooked--query-on-kill-p ()
  "Whether this session should be queried about before it is killed.
See `cooked-confirm-kill'."
  (pcase cooked-confirm-kill
    ('nil nil)
    ('auto (cooked--child-owns-keyboard-p))
    (_ t)))

(defun cooked--sync-query-flag ()
  "Say whether this session minds being killed without a warning.

Called from `cooked--refresh-keymap', because under `auto' the answer is the
policy and a policy change is exactly what that function is told about.  The
flag is read at kill time and cannot be computed then -- `process-list' is all
`save-buffers-kill-emacs' has -- so it has to be kept current instead."
  (when (process-live-p cooked--wake)
    (set-process-query-on-exit-flag cooked--wake (cooked--query-on-kill-p))))

(provide 'cooked-state)
;;; cooked-state.el ends here
