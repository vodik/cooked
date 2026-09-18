;;; cooked-render.el --- Applying a drain to the buffer -*- lexical-binding: t; -*-

;;; Commentary:

;; Everything between the native core saying "something changed" and the buffer
;; showing it: the drain itself, the order an update is applied in, and the view
;; put back on top afterwards.
;;
;; The unit worth reading whole is `cooked--apply', whose docstring already says
;; "the order below is the whole of it".  Everything else here either feeds it --
;; `cooked--on-wake' is the process filter's callback, `cooked--drain-and-apply'
;; the re-entrancy the filter cannot be trusted not to provoke -- or is one step
;; of it named so that the order stays legible: `cooked-viewport' and
;; `cooked--capture-viewport' for the view the render is about to invalidate,
;; `cooked--place-point' and `cooked--scroll-windows' for putting it back.
;; `cooked-refresh' is the way out when a step of that order signalled part-way.
;;
;; The adoption of what a drain reports that is not rows lives here too: the
;; alternate screen going up or down, the tty's mode, and the child's exit.
;;
;; The pipeline is a consumer.  It reads the session state, the pending input,
;; the marks and the screen region, and calls down into the renderers, the
;; decorations, the links, the OSC handlers and the mouse; nothing below it needs
;; anything it defines.  Starting a session, which installs `cooked--on-wake' as
;; the wake pipe's filter, is cooked-session.el, one level up.  What this file
;; has to tell the keymap it tells through `cooked--request-refresh'.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'jit-lock)
(require 'cooked-util)
(require 'cooked-state)
(require 'cooked-deco)
(require 'cooked-link)
(require 'cooked-screen)
(require 'cooked-pending)
(require 'cooked-cursor)
(require 'cooked-semantic)
(require 'cooked-bell)
(require 'cooked-secret)
(require 'cooked-mouse)
(require 'cooked-osc)
(require 'cooked-color)
(require 'cooked-window-ops)
(require 'cooked-scrollback)

(cooked--declare-core)

;;;; Draining

(defvar cooked--resyncing nil
  "Whether a resync is already under way, so a failing one cannot loop.
Bound for the dynamic extent of the repair rather than kept per buffer: it
answers \"am I inside one right now\", which is not something a buffer holds.")

(defvar-local cooked--draining nil
  "Whether a drain is already running in this buffer.
See `cooked--drain-and-apply', which is where re-entry is folded away.")

(defvar-local cooked--drain-pending nil
  "Whether a drain was asked for while one was already running.")

(defvar-local cooked--repaint-pending nil
  "Whether the next `cooked--apply' owes every window a real repaint.

`cooked--scroll-windows' only reaches the windows `cooked--capture-viewport'
found still following the cursor -- a window showing this buffer but not
selected, and not following, is never told anything there.  Ordinarily that is
fine: an in-place row rewrite marks the buffer modified and Emacs' own
incremental redisplay picks it up in any window regardless of selection.  A
resize is the case that is not ordinary -- `cooked--sync-size' rewraps or
rescales every row at once -- and has been observed to leave exactly such a
window's glyph matrix stale, showing blank or stale content until something
else forces the window to be looked at again.

Set by `cooked--sync-size' rather than acted on there, so the repaint rides
`cooked--apply's own pacing instead of firing on the spot: a drag-resize can
call `cooked--sync-size' many times before the next drain actually runs, and
each call only flips this flag, cheaply and idempotently.  Whichever
`cooked--apply' runs next -- paced or, as a resize's own is, forced -- pays for
the one `force-window-update' that flag earned, not one per resize event.
See `cooked--flush-pending-repaint'.")

(defun cooked--schedule-repaint ()
  "Ask the next `cooked--apply' to force every window on this buffer to redraw.
See `cooked--repaint-pending'.  Cheap and idempotent, so a caller with no way
to know how many times it will run before the next drain -- `cooked--sync-size'
mid-drag -- may call this on every one of them."
  (setq cooked--repaint-pending t))

(defun cooked--flush-pending-repaint ()
  "Force a real redisplay of every window on this buffer, if one is owed.

Called once from `cooked--apply', after `cooked--scroll-windows' has settled
where each window starts -- forcing a window before its start is right would
force it a second time when the start then moved.  See
`cooked--repaint-pending'.

`force-window-update' rather than `redisplay': the former only marks the
window for redisplay's ordinary next pass, which happens whenever Emacs gets
back to its command loop, while the latter would run one synchronously right
here, inside a process filter -- as expensive as the render that just finished
and blocking on it for no reason a mid-drag `cooked--sync-size' would forgive."
  (when cooked--repaint-pending
    (setq cooked--repaint-pending nil)
    (cooked--dolist-windows w (get-buffer-window-list (current-buffer) nil t)
      (force-window-update w))))

(defun cooked--drain-and-apply (&optional hidden)
  "Apply whatever the native core has accumulated since the last drain.

With HIDDEN, the buffer is one no window shows, and the core may leave the
screen out of the drain; see `cooked--apply-withheld'.  A drain asked for
while this one runs is always whole, since whoever asked wants to see it.

Re-entrant calls are folded into the drain already under way rather than
nested inside it.  `cooked--apply' decides `follow', `wandered' and the
windows that count as following *before* it rewrites the screen, and then
calls three things that can refresh the keymap -- `cooked--set-alt',
`cooked--set-mode' and `cooked--handle-event' for an OSC 133 mark.  A
refresh that lifts a freeze asks for a catch-up drain, so nesting there would
leave the outer `cooked--apply' finishing against an update, and a set of
captured positions, two drains stale.

Nothing is dropped by refusing: the request is remembered and honoured once
the outer drain has returned, which is also the only point at which draining
again is safe."
  (if cooked--draining
      (setq cooked--drain-pending t)
    ;; `unwind-protect' and `setq' rather than `let': `cooked--apply' runs the
    ;; layers' own hooks, which may change the current buffer, and a `let' on a
    ;; buffer-local restores into whichever buffer is current when the binding
    ;; unwinds.
    ;;
    ;; The invariant the captured buffer keeps: *the flags are cleared in the
    ;; buffer they were set in, whatever the current buffer has become by then*.
    ;; A bare `setq' has the same defect as `let' from the other direction -- it
    ;; writes wherever the buffer pointer happens to point *now* -- so a callee
    ;; that switched buffers without restoring would clear the flag in the wrong
    ;; buffer and leave this one draining forever, folding every later wake into
    ;; a drain that has already returned.  That is a frozen terminal no refresh
    ;; can mend, since `cooked-refresh' drains too.  Callees are meant not to
    ;; wander (see `cooked--handle-osc'), but this is the drain's own guarantee
    ;; and does not depend on their good behaviour.
    (let ((buffer (current-buffer))
          (applied nil))
      (unwind-protect
          (progn
            (setq cooked--draining t
                  cooked--drain-pending nil)
            (let ((update (cooked--drain cooked--session cooked-rejoin-wrapped-lines hidden t)))
              (if (plist-get update :withheld)
                  (cooked--apply-withheld update)
                (cooked--apply update)))
            ;; Bounded in practice: the pending flag is set by a freeze lifting,
            ;; and a freeze that has lifted does not lift again.
            (while (and cooked--drain-pending cooked--session)
              (setq cooked--drain-pending nil)
              (cooked--apply (cooked--drain cooked--session cooked-rejoin-wrapped-lines nil t)))
            (setq applied t))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (setq cooked--draining nil
                  cooked--drain-pending nil)
            ;; A drain that did not finish applying has told the core Emacs holds
            ;; rows it never inserted, and the core leaves a row out of later
            ;; drains when its cells match that copy.  So a child repainting the
            ;; same frame would never mend the screen.  `cooked--on-wake' follows
            ;; a failure with `cooked-refresh', which clears the copy itself, but
            ;; not under `cooked-debug', and not for any other caller; this is the
            ;; one place every unfinished apply passes.
            (unless applied
              (cooked--forget-sent-rows))
            ;; The far end of the core's backpressure: one wake byte is in flight
            ;; from the drain that brought us here until this says the drain has
            ;; been applied, so `cooked-min-redisplay-interval' paces applying --
            ;; which is where the milliseconds are -- rather than the taking of a
            ;; delta, which costs nothing.  Once, at the very end: the loop above
            ;; may have drained several times, and it is the last apply that the
            ;; interval is measured from.  Not after redisplay, which runs once the
            ;; process filter this is called from has returned: the window covers
            ;; the Lisp work, and the interval is what leaves the redraw its room.
            ;;
            ;; In the cleanup rather than the body, and for a stronger reason than
            ;; tidiness: an apply that signals must still re-arm, or the core waits
            ;; on a readiness that is never declared and the buffer stops repainting
            ;; until the reader thread's own tick notices -- and `cooked-refresh',
            ;; which is the way back from a half-drawn screen, drains too.  Inside
            ;; the `with-current-buffer' for the same reason as the flags: it is
            ;; this buffer's session that owes the answer, whatever buffer a callee
            ;; has left current.  Guarded because the session can be gone by now,
            ;; killed by something the apply ran.
            (when cooked--session
              (cooked--ready cooked--session))
            ;; Also in the cleanup, though `cooked--apply' ends with it: the drain
            ;; has assertions in it (`cooked--check-seam', `cooked--guard-row-width')
            ;; and a signal out of one leaves the screen half-rewritten with the
            ;; input line moved and the anchor still naming its old position.
            ;; Idempotent on the ordinary path, the anchor already matching by then
            ;; -- and inside the `with-current-buffer' for the same reason as the
            ;; flags: it is this buffer's anchor it exists to check.
            (cooked--check-undo-anchor)))))))

(defvar cooked-inhibit-redraw-functions nil
  "Abnormal hook asked whether a buffer's drain should wait.

Each entry is called with the buffer, current, on every wake, and the first
non-nil answer defers the drain.  It is for something that has borrowed the
buffer's text for a moment and would be damaged by a redraw under it: an input
method holding its preedit at the child's cursor while it reads the next key.
Quail reads that key with `read-key-sequence', which runs the wake pipe's
filter, and a drain there would rewrite the cursor row beneath the preedit.

A deferred wake is not repeated.  The native core sends one wake byte and
sends no other until Emacs has drained, so an entry that answered non-nil owes
the buffer a call to `cooked--on-wake' once it would answer nil again;
without it the buffer stops updating until something else drains.  See
`cooked-ime--compose', which makes that call when its composition ends.")

(defun cooked--on-wake (buffer)
  "Drain BUFFER's session and apply what changed.

A buffer no window shows is drained without its screen; see
`cooked--screen-debt'.

An error here is otherwise invisible: Emacs swallows `process-filter' errors,
and
the symptom reaches the user as a buffer that stopped updating or a point that
jumped somewhere absurd.  Name it, then repair it — a drain that signalled
part-way through leaves the screen region disagreeing with the emulator's grid,
and no later delta mends that, because a delta only says what changed.

`cooked--resyncing' guards the repair rather than the failure: a resync that
itself fails must report and stop, not recurse a redisplay error into a loop of
them.  It is cleared once a resync completes, so this is once per failure and
not once per session.

Skipped entirely while `cooked--frozen-p': the native core keeps the
authoritative grid state regardless of whether Lisp ever asks for it, so
nothing is lost by deferring — `cooked--refresh-keymap' catches the buffer up
with one more call to `cooked--drain-and-apply' the moment the freeze lifts.
Note that `cooked--frozen-p' is false for a buffer whose window is not the
selected one, so leaving a frozen buffer resumes it rather than stranding it.
Skipped the same way while `cooked-inhibit-redraw-functions' asks, whose
entries owe the catch-up themselves."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and cooked--session
                 (not (cooked--frozen-p))
                 (not (cooked--run-seam-until-success
                       'cooked-inhibit-redraw-functions buffer)))
        ;; The only reader that tells the two debts apart, because it is the
        ;; only one deciding what this drain should do rather than whether the
        ;; rows can be trusted.  A completion request asks for a hidden buffer's
        ;; treatment in a buffer that is not hidden; see `cooked--screen-held-by'
        ;; for why.
        (cooked--drain-and-repair (eq (cooked--screen-debt) 'hidden))))))

(defun cooked--drain-and-repair (hidden)
  "Drain and apply as `cooked--drain-and-apply' does, and repair a failure.
HIDDEN is passed on.  The failure is named and the screen resynced, once; see
`cooked--on-wake'."
  (if cooked-debug
      (cooked--drain-and-apply hidden)
    (condition-case err
        (cooked--drain-and-apply hidden)
      (error
       (message "cooked: redisplay failed: %S (point %s, cursor %S, screen-start %s)%s"
                err (point) cooked--cursor
                (cooked--screen-start-position)
                (if cooked--resyncing "" "; resyncing"))
       (unless cooked--resyncing
         (let ((cooked--resyncing t))
           (condition-case again
               (cooked-refresh)
             (error (message "cooked: resync failed too: %S" again)))))))))

(defun cooked--sync ()
  "Bring the current buffer's screen up to date, if a drain left it out.

The one way in for anything that reads the text of a buffer no window shows:
command search counting a running command's output, `cooked-write-output',
`next-error' walking a build log.  While `cooked--screen-debt' answers at all,
the rows below `cooked--screen-start' can be stale, and this drains the buffer
whole, as showing it would.  Everywhere else it costs two variable tests, so a
reader calls it unconditionally rather than learning what hidden means.

Either debt will do, and a screen still being held back is one of them: the
core does not wake Emacs for output that only changes a hidden buffer's screen,
so a child that printed one line there has left nothing drained that could have
owed anything.

Not for code that already runs inside a drain: there the drain under way has
the text as current as it is going to be, and the request is folded into a
whole drain that runs once it returns."
  (when (and (cooked--screen-debt) cooked--session)
    (cooked--drain-and-repair nil)))

(defun cooked--apply-withheld (update)
  "Apply UPDATE, a drain that left the screen out, to a buffer no window shows.

Only what has to happen whether or not anyone can see it: the scrollback is
appended, the marks that scrolled away with it are moved there, the tty mode is
adopted, so a password prompt is still noticed, and the events are handled, so
bells, titles, progress and notifications still arrive.  The rows below
`cooked--screen-start' are left as they are, and so is everything shaped by
them: the guard, the region's height, the padding, the input line, the window.
The core has kept the damage, and the next whole drain repaints what changed.

Appending is an insertion above the stale rows and nothing more, which leaves
the one thing the whole drain reads off them before it repaints: whether point
was on the screen.  Point and `cooked--point' are kept where they were relative
to the screen's start, so a buffer left at its cursor still follows the cursor
when it is shown, however much scrollback went in above it meanwhile."
  (cooked--apply-resources update)
  (let* ((screen (cooked--screen-start-position))
         (on-screen (and screen (>= (point) screen) (- (point) screen)))
         (recorded (and screen cooked--point (>= cooked--point screen)
                        (- cooked--point screen))))
    (let* ((inhibit-read-only t)
           (buffer-undo-list t)
           ;; Lifted over the insertion as `cooked--apply' lifts it.  An empty
           ;; input line at the top of the screen has its end marker advancing and
           ;; its start not, so text inserted there would land inside it.
           (pending (cooked--take-pending-input))
           (batch-start (when-let* ((scrolled (plist-get update :scrolled)))
                          (cooked--render-scrolled scrolled))))
      (cooked--restore-pending-input pending)
      (when batch-start (setq cooked--pin-screen-top nil))
      ;; The seam is scrollback's business, so it is settled here as a whole drain
      ;; settles it.  With `cooked-rejoin-wrapped-lines' off, a wrapped row sent now
      ;; ends its line, and the core's carry has to be told before a resize under a
      ;; hidden buffer rewraps against it: `日本語' at 5 columns, its first row
      ;; scrolled away and the screen then widened to 9, sent `語' to scrollback as
      ;; though it had been cut from that row's line.  The head is the drain's own,
      ;; the screen's `cooked--grid' being otherwise left as it was.
      (setf (cooked-grid-head cooked--grid) (plist-get update :head))
      (cooked--split-seam (and batch-start (plist-get update :alt)))
      (cooked--relocate-marks (plist-get update :marks) batch-start)
      (cooked--set-mode (plist-get update :mode))
      (cooked--batching-replies cooked--session
        (dolist (event (plist-get update :events))
          (cooked--handle-event event batch-start))))
    ;; Whether or not a claim is still holding the screen back: this drain is
    ;; the one that left it out, and what it owes outlives the claim.
    (setq cooked--screen-owed t)
    (cooked--trim-scrollback)
    (when-let* ((screen (cooked--screen-start-position)))
      (when on-screen (goto-char (min (+ screen on-screen) (point-max))))
      (when recorded (setq cooked--point (min (+ screen recorded) (point-max))))))
  (cooked--check-undo-anchor))

;;;; Applying an update

(defcustom cooked-clear-selection-on-output t
  "Whether output that rewrites the selected text takes the selection with it.

A region is a claim about particular text, and the child rewriting that text
makes the claim into a lie -- an invisible one, because the highlight stays.
The mark itself is carried to its character across the rewrite (see
`cooked--capture-relocations'), but a character is all it keeps: select
`alpha' on a live row, let the child redraw that row as `bravo', and the
highlight now covers `bravo', which is not what was selected.  Every
xterm-family terminal drops a selection whose cells are overwritten, for the
reason this does.

Only a mark in the live screen.  The scrollback is text the child has finished
with and can no longer reach, so a region up there still means what it did when
it was drawn.

nil keeps the mark wherever it is.  Defensible if you never select the live
screen; if you do, the region you are left holding is not the one you drew."
  :type 'boolean
  :group 'cooked)

(defun cooked--following-windows ()
  "Other windows on this buffer whose point should track the child's cursor.

The selected window's point *is* the buffer's point for as long as it stays
selected — Emacs keeps the two in sync on its own, which is what `follow' and
`wandered' below ride on.  No such thing happens for any other window
showing the same buffer: its `window-point' is a value Emacs stores and
redisplays from independently, touched only by `set-window-point', so a
second window on a busy cooked buffer would otherwise freeze wherever it
last happened to be pointed, deaf to every later drain.

A window's own point, not the buffer's, decides whether it is still
following, mirroring `follow' one level down: scrolling that window with the
wheel or a scrollbar does not move its point, so such a window is left alone
here for the same reason `follow' would leave the buffer's point alone for
the same case — it reads as the user choosing to look elsewhere, not as a
window that fell behind."
  (when-let* ((start (cooked--screen-start-position)))
    (seq-filter (lambda (w) (>= (window-point w) start))
                (delq (selected-window) (get-buffer-window-list nil nil t)))))

(defun cooked--apply-resources (update)
  "Record the images, links and renditions UPDATE's rows refer to by id.

Before any rendering: this is the drain's third category -- neither a level
redisplay reads nor an occurrence to react to, but a resource the rows depend
on.  Touches no buffer text, so it needs no `inhibit-read-only'."
  (cooked--install-images (plist-get update :images))
  (cooked--install-links (plist-get update :links))
  (cooked--install-styles (plist-get update :styles)))

(cl-defstruct (cooked-viewport (:constructor cooked--viewport-make) (:copier nil))
  "What the view looked like before a drain rewrote the screen under it.

Every field has to be read before the render, because afterwards the thing it
describes is gone: the pending input has been lifted out, the rows point and the
mark named have been deleted and reinserted, and which windows counted as
following has already been decided by the deletion dragging their point along.

Restored by `cooked--place-point' and `cooked--scroll-windows', in that order
and both from `cooked--apply' -- point first, because where the windows are
scrolled to is decided against where point ended up.

Captured by one function and put back by two, which is the design rather than an
omission: the fields are read in a single pass because the render is about to
invalidate every one of them at once, while they are answered at different
points in `cooked--apply''s order, with the mark cleared and the alt-screen pin
applied in between.  So there is no one restore to pair with the capture, and
looking for one is looking for the wrong shape."
  (editing nil :documentation "\
Point's offset within the pending input, or nil if it was not in there.

An offset rather than a position: the input is taken out and put back verbatim
around the child's cursor on every drain, so a buffer position cannot survive
that but an offset into the text can.  Without it, anything that drains while
the user is editing mid-line -- a background job printing a line, a completion
reply -- yanks them to the end of what they were typing.")
  (follow nil :documentation "\
Whether to track the child's cursor, or leave point where the user put it.

Asked of the mode and of where point is, not by comparing point against the
cursor: output arriving in chunks lets the cursor overtake point for a single
drain, which strands point at column 0 for every drain after it.")
  (wandered nil :documentation "\
The screen cell point sat on, when it had wandered off the cursor.

A redraw deletes and reinserts whole rows, so a buffer position would be dragged
to the start of whatever was rebuilt under it.  The cell survives that.")
  (stale-mark nil :documentation "\
Whether an active mark named screen text this drain is about to rewrite.

Unlike point the mark cannot be re-found afterwards -- there is no cell to look
it up by, only a claim about text that is about to stop being that text -- so
the question is asked while it still has an answer.  See
`cooked-clear-selection-on-output'.")
  (others nil :documentation "\
The other windows on this buffer that were following the child's cursor.")
  (relocations nil :documentation "\
The positions the render has to carry mechanically, having no intent above them.

The odd field out, and knowingly: everything else here is read once and answered
once, while these are handed to `cooked--render-rows' and corrected *during* the
render.  They are captured with the rest because the question they answer -- who
is going to be moved by something else, and so needs no carrying -- is only
answerable before the render, exactly like `others' above.  See
`cooked--capture-relocations'.")
  (reflow nil :documentation "\
For a drain that rewraps the screen, (BASE . POINT), and nil for any other.

BASE is where the places in RELOCATIONS are counted from, and POINT is
point's own place when it had wandered, standing in for `wandered', whose
cell the rewrap gives to another character.  See `cooked--logical-place'."))

(defun cooked--capture-relocations (others &optional reflow)
  "The positions this drain would otherwise drag, as `cooked-relocation's.

The policy half of the floor cooked-screen.el implements; see the commentary
above `cooked-relocation' for what the transform is and why the mark and a held
window's point are the two things with nothing else speaking for them.

The mark whenever there is one in the live screen, active or not.  Not gated on
`cooked-clear-selection-on-output', which decides something else: whether an
active selection's *highlight* survives output that rewrote the text under it.
The mark is a position either way -- it is where \\[exchange-point-and-mark] and
\\[pop-to-mark-command] go -- and dropping the highlight is not a reason to move
it.  A mark in the scrollback needs nothing, that text never being rewritten.

The other windows only while the view is held.  While it is following,
`cooked--scroll-transcript' points every one of them at the cursor, so carrying
them across the render would be work whose result is overwritten a few lines
later -- and worse than pointless if the two ever disagreed about which windows
those are.  The list is the same one, for that reason: OTHERS, as
`cooked--following-windows' just answered it.

REFLOW, for a drain that rewraps the screen, is (BASE . COLS): each position is
then captured as its place in the logical lines counted from BASE at COLS wide,
since the row and column it had name another character once the rows are laid
out again.  See `cooked--logical-place'."
  (let ((start (cooked--screen-start-position))
        (relocations nil))
    (when start
      (when-let* ((mark (mark t))
                  ((>= mark start)))
        (push (cooked--relocation-make) relocations))
      (unless (cooked--follow-p)
        (dolist (window others)
          (push (cooked--relocation-make :window window) relocations))))
    (when reflow
      (dolist (relocation relocations)
        (when-let* ((position (cooked--relocation-position relocation)))
          (setf (cooked-relocation-place relocation)
                (cooked--logical-place position (car reflow) (cdr reflow))))))
    relocations))

(defun cooked--capture-viewport (&optional cols)
  "Snapshot the view, before the render invalidates every part of it.

COLS, for a drain that rewraps the screen, is the width its rows are laid out
at now, before the drain; see the `reflow' field."
  (let* ((others (cooked--following-windows))
         (base (and cols (cooked--screen-start-position)
                    (cooked--logical-base)))
         (reflow (and base (cons base cols)))
         (wandered (and cooked--wandered (cooked--screen-cell))))
    (cooked--viewport-make
     :editing (when-let* ((region (cooked--input-region))
                          ((<= (car region) (point) (cdr region))))
                (- (point) (car region)))
     :follow (and (cooked--follow-p)
                  (>= (point) (cooked--screen-start-position)))
     :wandered (and (not reflow) wandered)
     :stale-mark (and cooked-clear-selection-on-output
                      mark-active (mark)
                      (>= (mark) (cooked--screen-start-position)))
     :others others
     :relocations (cooked--capture-relocations others reflow)
     :reflow (and reflow
                  (cons base (and wandered
                                  (cooked--logical-place (point) base cols)))))))

(defun cooked--apply-levels (update cursor)
  "Adopt UPDATE's levels: the state as of this drain, for redisplay to read.
CURSOR is UPDATE's cursor, already decoded by `cooked--apply'."
  (setq cooked--cursor cursor
        ;; Before `cooked--fit-screen', which is shaped by it.
        cooked--grid (cooked--grid-make :height (plist-get update :height)
                                        :width (plist-get update :width)
                                        :used (plist-get update :used)
                                        :head (plist-get update :head))
        cooked--app-cursor (plist-get update :app-cursor)
        cooked--keys (plist-get update :keys)
        cooked--kitty-flags (or (plist-get update :kitty-flags) 0)
        cooked--modify-other-keys (or (plist-get update :modify-other-keys) 0)
        cooked--exit (plist-get update :exit))
  (cooked--set-alt (plist-get update :alt))
  (cooked--set-reverse-screen (plist-get update :reverse)
                              (plist-get update :reverse-toggles))
  (cooked--set-mode (plist-get update :mode)))

(defun cooked--set-mode (mode)
  "Adopt MODE, switching keymaps and handling secret prompts on a change."
  (unless (eq mode cooked--mode)
    (setq cooked--mode mode)
    (cooked--request-refresh)
    (if (eq mode 'secret)
        (cooked--schedule-secret 'termios)
      (cooked--cancel-secret))))

(defun cooked--place-point (viewport)
  "Put point where VIEWPORT says it belongs, now that the render is done.

`editing' outranks `follow' rather than sharing an arm with it: point inside the
pending input is a claim about the line being typed, and the end of that line is
only the right answer when point was there already.  Staying put outranks both
once the user has taken the keyboard back -- the child keeps redrawing under
them, and being yanked to its cursor mid-motion is what this exists to stop.
The ghost keeps the way back visible; `cooked--snap-to-cursor' takes it."
  (let ((editing (cooked-viewport-editing viewport)))
    (cond ((cooked-viewport-wandered viewport)
           (cooked--goto-screen-cell (cooked-viewport-wandered viewport)))
          ;; Clamped for the drain that ends the prompt, where
          ;; `cooked--restore-pending-input' declined and left no region for the
          ;; offset to be an offset into.
          (editing
           (goto-char (if-let* ((start (cooked--input-start-position)))
                          (min (+ start editing) (cooked--point-after-input))
                        (cooked--point-after-input))))
          ((cooked-viewport-follow viewport)
           (goto-char (cooked--point-after-input))))))

(defun cooked--scroll-windows (viewport)
  "Scroll every window on this buffer to what VIEWPORT and the new grid want.

Explicit rather than left to redisplay, for a narrow reason.
`scroll-conservatively' *is* a guarantee for the
selected window whatever moved its point: `redisplay_window' compares the
window's start against its point and has no idea whether a command or a process
filter did the moving.  What redisplay will not do is move a *non-selected*
window, whose `window-point' nothing here has touched, and what it will not
decide is the policy question -- whether the last line belongs at the foot of
the window with nothing below it, which is what `comint-scroll-show-maximum-
output' gates comint's own recentring on.

The selected window belongs in none of these lists unless it is actually showing
this buffer: output can arrive while the user's focus is elsewhere, and
scrolling that window would be a bug rather than a courtesy."
  (let ((here (and (eq (window-buffer (selected-window)) (current-buffer))
                   (list (selected-window))))
        (others (cooked-viewport-others viewport)))
    (if cooked--alt
        (cooked--pin-alt-screen (append here others))
      (cooked--scroll-transcript viewport here others))))

(defun cooked--pin-alt-screen (windows)
  "Put the alternate screen back at the top of each of WINDOWS.

A resize reaches the buffer in two steps: the window changes height the instant
Emacs notices (`cooked--sync-size'), while the buffer is not re-fitted to match
until the next drain's `cooked--fit-screen'.  Ordinary redisplay fills that gap
by pushing `window-start' down to keep point on screen, and nothing corrected
that once the buffer caught up -- so the window kept a scroll a now-irrelevant
redisplay had chosen, clipping the top of the screen.

Unconditional, and the restriction `cooked--apply-alt-pin' re-applies is what
makes that safe: every window here shows the screen region and nothing else, so
the region's top is the only start any of them can hold.  NOFORCE stays, because
forcing would drag point along with it."
  (let ((top (cooked--screen-start-position)))
    (cooked--dolist-windows w windows
      (set-window-start w top t))))

(defun cooked--pin-transcript-bottom (windows &optional pos bottom)
  "Follow POS, defaulting to `point-max', with the bottom row of each of WINDOWS.

BOTTOM, defaulting to POS, is what the bottom row is computed against: the
child's cursor can sit above text it has already printed -- a couple of
trailing lines below where the cursor ultimately rests is an ordinary shape
for a non-TUI program that prints and then repositions -- and it is that
trailing text, not the cursor, that must not be scrolled out of view.  POS
still decides window-point, so editing and the caret stay at the cursor.

Factored out of `cooked--scroll-transcript' because a drain is not the only
thing that can grow the buffer's true end.  `cooked--on-exit' does too,
appending the \"[exited N]\" line from outside `cooked--scroll-windows'
entirely, and it needs exactly this rather than a second copy of it.

Computed and NOFORCE, rather than `recenter'.  `recenter' sets a forced
start that redisplay then overrules through `make-cursor-line-fully-visible',
so the window lands where neither chose; and it counts every screen line as the
default font's height, so a row taller than that -- an image slice, a Nerd
Font prompt separator -- is paid back in whole lines of scroll.  A NOFORCE start
is a suggestion redisplay may settle against, and the pixels stay
`make-cursor-line-fully-visible's business.  No `with-selected-window' either:
`select-window' is advised -- by `evil', to refresh its cursor -- and nothing
here needs the window selected.

Monotone, which is what stops this jittering.  The follow direction is taken
whenever the tail has grown, and the equality is the common case: a steady
stream whose tail is the same length leaves TOP exactly where it already is and
this writes nothing at all, at a drain rate whose floor is
`cooked-min-redisplay-interval'.  The shrink direction gives
`comint-scroll-show-maximum-output's semantics, no blank space below the last
line, and is taken only when the
*last* redisplay had the buffer's end on screen, so it fires when the grid
really has fewer used rows than before rather than every time
`vertical-motion's whole-line count disagrees with what redisplay laid out in
pixels.  That disagreement is permanent on a window whose rows differ in height,
and correcting for it once per drain is the oscillation itself."
  (let* ((target (or pos (point-max)))
         (foot (or bottom target)))
    (cooked--dolist-windows w windows
      (set-window-point w target)
      (let ((top (save-excursion
                   (goto-char foot)
                   (vertical-motion (- (1- (window-body-height w))) w)
                   (point))))
        (when (or (> top (window-start w))
                  (and (< top (window-start w))
                       (let ((end (window-end w)))
                         (and end (>= end (point-max))))))
          (set-window-start w top t))))))

(defun cooked--scroll-transcript (viewport here others)
  "Scroll the transcript in HERE and OTHERS as VIEWPORT asks."
  (let* ((target (cooked--point-after-input)))
    ;; Only while the view is following at all: suspending exists to stop the
    ;; child's output moving what is being read, and a second window on the same
    ;; buffer is being read on the same terms.
    (when (cooked--follow-p)
      (cooked--dolist-windows w others
        (set-window-point w target)))
    (cond
     ;; The child cleared the display.  Its rows were archived rather than
     ;; dropped, so nothing scrolls out of view on its own, and recentring on the
     ;; cursor would leave the transcript filling the window above a blank screen
     ;; -- which is `clear' looking like it did nothing.
     ((and (cooked-viewport-follow viewport) cooked--pin-screen-top)
      (let ((top (cooked--screen-start-position)))
        (cooked--dolist-windows w (append here others)
          (set-window-start w top t))))
     ;; The pin's own foot is `point-max', not TARGET: a non-TUI child can print
     ;; a few trailing lines below where its cursor ultimately rests -- printing
     ;; output and then repositioning is ordinary -- and it is that trailing
     ;; text, not the cursor, whose bottom edge decides the window's scroll.
     ((cooked-viewport-follow viewport)
      (cooked--pin-transcript-bottom (append here others) target (point-max))))))

(defun cooked--reflow-width (update)
  "The width this buffer's rows are laid out at, when UPDATE rewrapped them.

A drain reporting another width has rewrapped the primary screen's rows, which
moves every character on them to another cell; the width the buffer's rows are
laid out at is the last drain's, and that is what `cooked--capture-viewport'
needs to count the places it carries.  Nil when nothing was rewrapped.

Nil too with `cooked-rejoin-wrapped-lines' off, where the rows that scroll into
history keep newlines nothing marks, so the logical lines a position is counted
in cannot be read back; and nil on the alternate screen, which is clipped rather
than rewrapped."
  (let ((was (cooked-grid-width cooked--grid))
        (now (plist-get update :width)))
    (and was now (/= was now)
         cooked-rejoin-wrapped-lines
         (not cooked--alt) (not (plist-get update :alt))
         was)))

(defun cooked--apply-scrollback (update)
  "Hand UPDATE's evicted rows to the scrollback, and say where they landed.

The answer is where this drain's scrollback begins, for resolving a `scrolled'
anchor against, and nil when the drain evicted nothing.

The rows the buffer already holds are promoted first, since they are the batch's
first rows and the top of the screen, and the rest is inserted after them."
  (let ((promoted (when-let* ((promoted (plist-get update :promoted)))
                    (cooked--promote-rows promoted (plist-get update :height))))
        (inserted (when-let* ((scrolled (plist-get update :scrolled)))
                    (cooked--render-scrolled scrolled))))
    (or promoted inserted)))

(defun cooked--apply-rows (update viewport)
  "Write UPDATE's damaged rows, and place what a rewrap moved.

Returns the bounds `cooked--render-rows' rewrote, for
`cooked--notify-rows-rendered'.

The places are put back here, right after the rows and before anything else
inserts or deletes: a place is counted in the lines as the render leaves them.
VIEWPORT's `wandered' is answered by that count, the rewrap having given the
cell point sat on to another character."
  (let ((rendered (cooked--render-rows (plist-get update :rows)
                                       (plist-get update :alt)
                                       (cooked-viewport-relocations viewport)
                                       (plist-get update :edits))))
    (when-let* ((reflow (cooked-viewport-reflow viewport)))
      (setf (cooked-viewport-wandered viewport)
            (cooked--place-reflowed (cooked-viewport-relocations viewport)
                                    reflow (plist-get update :width))))
    rendered))

(defun cooked--apply-events (update batch-start rendered)
  "React to everything in UPDATE that is not a row.

BATCH-START is where this drain's scrollback began, from
`cooked--apply-scrollback', and RENDERED the bounds `cooked--apply-rows' wrote.

After both render passes, which is what every step here needs: a mark's anchor
is resolved against text that has to be in the buffer before it can be pointed
at, and `cooked-row-rendered-functions' is documented against that order too."
  ;; Cleared before the events, so a drain that both scrolls and then clears
  ;; stays pinned.
  (when batch-start (setq cooked--pin-screen-top nil))
  ;; A drain that both resizes and carries a fresh mark should end with the
  ;; fresh mark's own anchor.
  (cooked--relocate-marks (plist-get update :marks) batch-start)
  ;; Batched, so a drain that asks for the whole palette is answered in one
  ;; write rather than one per entry.  See `cooked--batching-replies'.
  (cooked--batching-replies cooked--session
    (dolist (event (plist-get update :events))
      (cooked--handle-event event batch-start)))
  (cooked--notify-rows-rendered rendered)
  ;; After the render, so the cursor is where this drain put it: a row the URL
  ;; guess declined while the cursor sat on it has to be asked for again once
  ;; the cursor has moved on.
  (cooked--release-held-link-row)
  ;; And the other question that can only be asked once the cursor has landed:
  ;; whether a *remote* child is at a password prompt.  The termios detector
  ;; fires on a change of the local tty, which a remote child never makes, so
  ;; there is no transition to hang it off -- see `cooked--check-secret-prompt'.
  (cooked--check-secret-prompt batch-start))

(defun cooked--apply-shape (update batch-start pending)
  "Shape the screen region UPDATE's rows were written into, and give PENDING back.

BATCH-START is where this drain's scrollback began, from
`cooked--apply-scrollback'.

The seam is split immediately before the assertion that reads it, which is the
whole reason it is here rather than riding `cooked--trim-scrollback' at the foot
of the drain.  The two are one subject -- the seam the emulator and the buffer
co-own -- and a drain that evicts a wrapped row with
`cooked-rejoin-wrapped-lines' off remakes the emulator's claim about a
continuation the buffer never took.  Reset after the assertion had already
looked, the claim was still standing when it looked, which is why the assertion
had to exclude this mode instead of covering it.  See `cooked--split-seam'."
  (cooked--fit-screen)
  (cooked--pad-to-cursor)
  (cooked--split-seam (and batch-start (plist-get update :alt)))
  (when cooked-debug (cooked--check-seam))
  (cooked--restore-pending-input pending)
  (cooked--protect (or (and (cooked--input-state-p) (cooked--input-start-position))
                       (point-max)))
  (cooked--apply-alt-pin)
  ;; After the rows and the scrollback have both landed: the pointer overlay's
  ;; start has to be put back on the screen marker a scroll just moved, or it
  ;; spreads up into history.  See `cooked--sync-pointer-shape'.
  (when cooked--pointer-overlay (cooked--sync-pointer-shape)))

(defun cooked--apply-view (viewport)
  "Put the view VIEWPORT captured back on top of what the drain wrote.

The mark goes before the point block, not after it: under evil this leaves
visual state, and evil adjusts point on the way into normal state -- so cooked's
own pin has to be the last thing to speak about where point ends up."
  (when (cooked-viewport-stale-mark viewport) (cooked--deactivate-mark))
  (cooked--place-point viewport)
  ;; Recorded, not merely left in the buffer: a window not showing this buffer
  ;; has a stale point marker Emacs will restore on the way back, over the top
  ;; of this.  See `cooked--point'.
  (setq cooked--point (point))
  (cooked--scroll-windows viewport)
  ;; After `cooked--scroll-windows', which is what decides where each window's
  ;; start belongs: forcing a window before that would force it a second time
  ;; once the start then moved.  See `cooked--repaint-pending'.
  (cooked--flush-pending-repaint)
  ;; After the window block, not before it: see `cooked--sync-cursor-type'.
  (cooked--sync-cursor-type)
  (cooked--update-ghost-cursor))

(defun cooked--apply (update)
  "Apply UPDATE, the plist returned by `cooked--drain'.

The order below is the whole of it, and every step depends on the one above:
resources before the rows that name them, the viewport before the render that
invalidates it, the render before the marks resolved against the text it wrote,
and the region shaped before anything measures it.  Each step says in its own
docstring why it stands where it does; this is the list, and nothing here does
anything a stage does not do.

The three steps that are still bindings rather than calls are the ones later
steps read: the cursor two of them decode against, the viewport the render
invalidates, and the pending input lifted out before the rows move under it.

`cooked--place-seam' and `cooked--apply-shifts' sit between the scrollback and
the rows and have to be exactly there.  After the scrollback, because the rows a
scroll pushed off the top are inserted above `cooked--screen-start' or promoted
past it, and the shift's first row is measured from the marker once that has
moved it.  Before the damaged rows, because their indices are in post-shift
coordinates -- the emulator's dirty flags travel with their rows through every
move precisely so that they can be.  `tests/cooked-tests-oracle.el' is what
holds that order in place: the read-back there fails five generated cases in
five with the shifts moved after the rows."
  ;; First, so a reader reached from inside this drain does not ask for another.
  ;; The claims are left alone: a hidden buffer that `cooked--sync' has drained
  ;; whole is caught up and still hidden.
  (setq cooked--screen-owed nil)
  (cooked--apply-resources update)
  ;; `let*', emphatically: these initialisers delete and insert, and under plain
  ;; `let' they would run before the two bindings above them took effect -- so a
  ;; protected buffer would abort the redisplay half-done from inside the process
  ;; filter, and lifting the pending input would land in the undo history.  They
  ;; are the pair `cooked--with-child-edit' binds, spelled out because the
  ;; sequence below is not worth nesting one level deeper.
  (let* ((inhibit-read-only t)
         (buffer-undo-list t)
         ;; Decoded once, here, for the two readers below that need it at
         ;; different moments: the render passes and `cooked--apply-levels'.
         (cursor (cooked--cursor-decode (plist-get update :cursor)))
         ;; Two more dynamic bindings, here in the `let*' rather than wrapped
         ;; around it precisely because `let*' binds in order: the render below
         ;; is an initialiser, and it is what both are for.  The first is the box
         ;; the window and the cell size are measured into once instead of once
         ;; per decoration record; the second is where this drain is putting the
         ;; cursor, which `cooked--cursor' cannot say until `cooked--apply-levels'
         ;; runs below the render, and which a glyph run has to be broken at.
         ;; See `cooked--deco-pass' and `cooked--deco-cursor'.
         (cooked--deco-pass (list 'unset))
         (cooked--deco-cursor
          (cons (cooked-cursor-row cursor) (cooked-cursor-chars cursor)))
         (viewport (cooked--capture-viewport (cooked--reflow-width update)))
         (pending (cooked--take-pending-input))
         (batch-start (cooked--apply-scrollback update))
         ;; After the scrollback, which is what the line ends or continues after,
         ;; and before anything is measured from `cooked--screen-start'.
         (_ (cooked--place-seam (plist-get update :head) (plist-get update :alt)))
         (_ (cooked--apply-shifts (plist-get update :shifts)))
         (rendered (cooked--apply-rows update viewport)))
    (cooked--apply-levels update cursor)
    (cooked--apply-events update batch-start rendered)
    (cooked--apply-shape update batch-start pending)
    (cooked--apply-view viewport)
    (when cooked--exit (cooked--on-exit cooked--exit)))
  ;; Both outside the `let*', and in this order.  The binding above is what kept
  ;; this drain out of the undo history, and a discard has to reach the buffer's
  ;; own list rather than that binding -- which is also why the trim cannot run
  ;; inside: it moves the input line, and the `cooked--check-undo-anchor' it does
  ;; for itself would then update the anchor against a discard that was thrown
  ;; away with the binding, leaving the history vouched for by an anchor nothing
  ;; ever cleared.  See `cooked--with-child-edit'.
  (cooked--trim-scrollback)
  (cooked--check-undo-anchor))

(defun cooked--handle-event (event batch-start)
  "Dispatch a single EVENT from the emulator.

BATCH-START is where this drain's scrollback was inserted, which the semantic
marks need to place their anchors; see `cooked--anchor-position'.

Events are occurrences only.  State the redisplay depends on rides the drain's
own fields instead — `:alt' and the rest — so that nothing arrives twice with
two chances to disagree."
  (pcase event
    ;; Handed on rather than rung: whether a bell is a noise, a mark on the
    ;; buffer or nothing depends on whether anyone can see it, which is the
    ;; interaction layer's question.  See `cooked-bell-default'.
    (`(bell) (cooked--protect-seam 'cooked-bell-function
               (funcall cooked-bell-function)))
    (`(osc ,code ,bell . ,parts) (cooked--handle-osc code bell parts))
    (`(reply . ,bytes) (cooked--reply-if-live bytes))
    (`(title-stack ,push) (cooked--handle-title-stack push))
    ;; Guarded, because it moves windows the drain does not own: a layout that
    ;; refuses the resize must not cost this drain the replies queued after it.
    (`(resize-request ,rows ,cols)
     (cooked--protect-seam 'cooked-resize-requests
       (cooked--handle-resize-request rows cols)))
    (`(frame-size ,pixels) (cooked--handle-frame-size pixels))
    ;; `CSI 3 J', the tail of what `clear' sends.  Honoured unconditionally: it is
    ;; only reachable by something already holding the terminal, every other terminal
    ;; honours it, and it is precisely what the user typed `clear' to get.  The
    ;; command history is not lost with it: that lives in comint's ring, not here.
    (`(erase-scrollback)
     (cooked--discard-scrollback (cooked--screen-start-position)))
    (`(display-cleared) (setq cooked--pin-screen-top t))
    ;; `ESC c'.  Everything RIS resets inside the emulator the emulator resets
    ;; itself; this event exists for the state Emacs holds on its behalf.  A
    ;; `reset' that blanked the screen and left the mode line still claiming a
    ;; build was 60% through would be stuck in the one way the user has no
    ;; second thing to type their way out of.  See `cooked--reset-terminal'.
    (`(reset) (cooked--reset-terminal))
    ;; Decoded into a record at the boundary, like the cursor and the grid; see
    ;; `cooked-mouse-state'.  cooked-mouse.el owns it because it is the only
    ;; reader, and re-gates its own keymap on the way through.
    (`(mouse ,enabled ,sgr ,drag ,motion ,pixels)
     (cooked--set-mouse-state enabled sgr drag motion pixels))
    ((or `(prompt-start ,_ . ,_) `(prompt-continuation ,_ . ,_)
         `(prompt-end ,_ . ,_))
     (cooked--handle-semantic event batch-start))
    ((or `(command-start ,_ ,_ . ,_) `(command-end ,_ ,_ . ,_))
     (cooked--end-of-command)
     (cooked--handle-semantic event batch-start))
    (_ nil)))

(defun cooked--reset-terminal ()
  "Put back everything Emacs holds for the child, on RIS.

RIS is a power-on reset, and every piece of it a child can change lives here
rather than in the emulator: the OSC 9;4 progress indicator, the OSC 22 pointer
stacks, the bell's mark, the OSC 10 and 11 colour remaps, the OSC 12 cursor
colour and the title with its XTWINOPS stack.  `reset' is what a user types at
a terminal a program left purple with a stale title, and it has to fix all of
it, as ghostty's `fullReset' clears the title and eat's reset does.

The OSC 3008 contexts are not here, on purpose: see
`cooked-osc-context--stack'."
  (cooked--reset-progress)
  (cooked--reset-pointer-shapes)
  (cooked--reset-bell)
  (dolist (kind cooked--osc-settable-colors)
    (cooked--reset-default-color kind))
  (setq cooked--title-stack nil)
  (when cooked-title
    (cooked--set-title nil)))

(defun cooked--end-of-command (&optional exited)
  "Drop what a command left in Emacs, at OSC 133 C or D, or on exit when EXITED.

The shell saying a command has finished, or that the next one is starting, is
the one signal that whatever ran before it is gone, however it went.  Both
marks, rather than D alone, because a shell that drops its D still sends the
next C.  What the emulator holds for the shell -- the mouse, focus and size
reports, the key encoding -- the core puts back itself at D, and explains there
why D and not the prompt's A; a mouse that goes off reaches Emacs as an ordinary
`mouse' event.  This is the Emacs half, for state that is about a command:

- the OSC 9;4 progress indicator: `cargo build' interrupted at the keyboard
  never sends the report that removes its bar, so without this `[42%]' stays
  in the mode line through every command after it;
- the OSC 22 pointer stacks, which no shell sets, so a pointer left as a
  `text' bar by a crashed editor is not the shell's.

Some state waits for EXITED, because a shell sets it too.  The OSC 12 cursor
colour is one: base16-shell sets it from `.bashrc', before the first prompt,
and clearing it at every mark would undo the theme the user chose.  The mouse
state is another kind of wait: the core keeps it right while a child lives, but
nothing reports it once the child is dead, so a kept buffer went on holding
`track-mouse' on.  The OSC 3008 contexts belong to `cooked-exit-hook': a
`run0 bash' prompts inside its `elevate' context, so no mark may end one."
  (cooked--reset-progress)
  ;; Guarded, since this runs twice per command and almost nothing sets a shape.
  (when cooked--pointer-stacks (cooked--reset-pointer-shapes))
  (when exited
    (cooked--set-cursor-color nil)
    (cooked--set-mouse-state nil nil nil nil nil)
    (cooked--run-seam 'cooked-exit-hook)))

(defcustom cooked-exit-hook nil
  "Hook run in a session buffer once its child has exited.

For a layer keeping state about the child that nothing else will clear: once
the child is gone that state is wrong rather than stale, and a buffer can be
kept and shown long after.  Run from inside the drain that saw the exit, each
function contained, so one that signals is reported once and the rest still
run."
  :type 'hook
  :group 'cooked)

;;;; The alternate screen, and the link passes redisplay runs

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
a command.  Coming back needs no hook -- restoring the primary rewrites every
row that differs from the program's last frame, and a layer that re-applies
per render is repainted by that."
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
      (cooked--request-refresh)
      (run-hooks 'cooked-alt-change-hook))))

(defun cooked--sync-fontification ()
  "Register or drop the jit-lock pass, following whether it has work to do.

Registration is not free and the cost is not at redisplay, which is the part
worth knowing: jit-lock hangs `jit-lock-after-change' on
`after-change-functions', and that fires for every text property applied as
well as for every insertion.  Every styled run of a row is a `face' property,
and every run of box drawing a `display' and a `cooked-deco' on top, so a
frame of a full-screen program pays the hook once for each of them to be told
something it could have been told once -- a fifth again on plain rows and half
again on box drawing, with `cooked--fontify-region' never called.

So the registration follows the work rather than the mode.  Two things can make
it worthless, and both are ordinary.  The alternate screen is one: that grid is
a rectangle the child owns, `cooked--fontify-region' declines it outright, and
a full-screen program repainting flat out is exactly the thing that would pay
the hook most and get nothing.  A session with the URL guess switched off and
no scan layer loaded is the other.

Idempotent, and cheap enough to call on any transition -- `jit-lock-register'
and `jit-lock-unregister' both go through `add-hook'/`remove-hook' on a
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

The cursor's row always, and the whole input region on top of it when the user
is typing -- the two are usually the same row and the `max' costs nothing when
they are.  Returns buffer positions, not markers.

This lives here rather than in cooked-link.el on purpose.  Where the cursor is
and whether input is being edited are session state, and cooked-link.el is base
tier, which must not ask questions upward.  The link layer is told what range
to scan; it does not ask why."
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

Called from `cooked--apply', which is the moment the cursor can have moved.
`jit-lock-refontify' rather than a direct scan: the row may not be on screen,
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

Registered by `cooked-mode' and called by redisplay, which is the whole point
of it.  Both passes here are guesses about text -- what looks like a URL, what
looks like a file name -- and a guess is only worth making about text somebody
is about to read.  Running them from the render path instead meant scanning
every damaged row whether or not that row was ever displayed, which for a child
painting faster than Emacs redraws is most of them.  `goto-address-mode' has
always worked this way; this is cooked wearing the same clothes, with the two
bindings `cooked--fontify-links' makes on top.

One entry point for two passes because they are one question asked twice, and
the order between them is the precedence `cooked-link--claimed-p' states: a
`goto-addr' match is settled before the file layer looks, so the file layer can
decline text already spoken for.

`inhibit-read-only' because scrollback carries `read-only', and the file layer
answers by adding text properties to it.  The render path had this for free from
`cooked--apply'; redisplay does not.

Rounded out to whole lines.  jit-lock hands over chunks of
`jit-lock-chunk-size' characters and a chunk boundary falls wherever it falls,
so a candidate straddling one would be matched by neither half.  Rounded here
rather than in either pass, because neither does it for itself -- see
`cooked--fontify-links'.

Whole *logical* lines, because
a soft-wrapped line is several buffer lines, so rounding to buffer lines alone
would let a chunk boundary fall between two rows of one line and split the very
candidate the joining exists to put back together.  See
`cooked-link-logical-line-bounds', which is bounded so this cannot round out to
a screenful.

Nothing at all on the alternate screen, where a full-screen program repaints
continuously and usually wants the mouse for itself.  That is safe to answer by
simply returning: that grid is rewritten row by row on the way back to the
primary screen, and rewriting text is what marks it unfontified again, so
nothing is stranded by having been skipped here."
  (when (and cooked--session (not cooked--alt))
    (let* ((inhibit-read-only t)
           ;; The only `syntax-table' property in the buffer is the prompt's,
           ;; see `cooked--mark-input-syntax', and the held row below keeps
           ;; these passes off the prompt.  Consulting properties would only
           ;; slow the syntax-aware URL regexp at every face boundary, by about
           ;; a sixth over styled output.
           (parse-sexp-lookup-properties nil)
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
      ;;
      ;; Only when the held row is inside the chunk, though.  Scrolled back, the
      ;; chunk is far above the cursor, and splitting it there anyway scans from
      ;; the chunk all the way down to the cursor: asking for 500 characters of
      ;; old output scanned 67 KB.  Past `goto-address-fontify-maximum-size' the
      ;; scan is skipped outright, and jit-lock still marks the chunk done, so
      ;; the URLs in it were never linked at all.
      ;;
      ;; And a side of the held row is scanned only when jit-lock's own chunk
      ;; reaches into it, not merely because the rounding out to the logical
      ;; line does.  Typing into a long word rewrites the cursor's row and
      ;; nothing else, so the chunk is that row; rounding it out and scanning
      ;; what lay either side rescanned rows that had not changed, once per
      ;; keystroke, and the regexp is quadratic in an unbroken word: on a
      ;; 1000-character word 114 columns wide, 920 characters a keystroke.
      ;; Nothing is lost by skipping them.  Their text is what it was when they
      ;; were last scanned, and a URL that runs on into the held row is put
      ;; together whole when the hold is released, since that rescan rounds out
      ;; to the logical line with no hold left to split it.  The chunk's END is
      ;; exclusive and the held row's own newline may be in it, hence the `1+'.
      (if (not (and held (< from (cdr held)) (< (car held) to)))
          (cooked--fontify-links from to)
        ;; The held row's logical line may have changed since it was last
        ;; scanned, and a link left on it would name a URL that is no longer
        ;; there: `https://e.x/abc' rewritten in place to `https://e.x/aZc', or
        ;; the half of a wrapped URL left on the row above once the row below is
        ;; erased.  Nothing rescans that line until the hold is released, so it
        ;; shows no detected link until then, as a line drawn afresh would not.
        (let ((line (cooked-link-logical-line-bounds (car held) (cdr held))))
          (cooked-link--unfontify-urls (car line) (cdr line)))
        (when (< beg (car held)) (cooked--fontify-links from (car held)))
        (when (> end (1+ (cdr held))) (cooked--fontify-links (cdr held) to))
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

;;;; What happens when the child exits

(defcustom cooked-kill-buffer-on-exit nil
  "Whether the session buffer is killed when the child exits.

nil keeps the buffer, exit status and all, which is the point of running the
terminal inside Emacs: the transcript outlives the command.  t kills it,
`on-success' kills it only for a zero status — the shell-in-a-window habit,
where a failure is the one case you still want to read.  A function is called
with the exit code and kills the buffer when it returns non-nil.

The buffer is killed from a timer rather than mid-redraw, so `kill-buffer-hook'
and anything watching the buffer list see an ordinary kill."
  :type '(choice (const :tag "Keep the buffer" nil)
                 (const :tag "Always kill it" t)
                 (const :tag "Kill it only on a zero exit status" on-success)
                 (function :tag "Function of the exit code"))
  :group 'cooked)

(defun cooked--kill-buffer-on-exit-p (code)
  "Whether `cooked-kill-buffer-on-exit' wants the buffer killed for CODE."
  (pcase cooked-kill-buffer-on-exit
    ('nil nil)
    ('on-success (eql code 0))
    ((and (pred functionp) f) (funcall f code))
    (_ t)))

(defun cooked--stop-session ()
  "Kill the child and close the wake pipe, leaving the buffer sessionless.

Kill before closing the pipe.  The other order leaves the reader thread writing
into a closed pipe -- harmless, since it blocks SIGPIPE -- but this order costs
nothing.

The child is killed rather than left to the garbage collector: clearing
`cooked--session' only drops the last reference, and nothing guarantees a
collection ever runs, so the child would keep going long after whatever reason
there was to stop it.

Idempotent, and both callers rely on that -- `cooked--on-exit' runs when the
child reports its own exit and `cooked--cleanup' when the buffer is killed,
and a session that exits and is then killed goes through both."
  (when cooked--session (ignore-errors (cooked--kill cooked--session)))
  (when cooked--wake (delete-process cooked--wake))
  (setq cooked--session nil cooked--wake nil))

(defun cooked--on-exit (code)
  "Report that the child exited with CODE and stop the session."
  ;; A child can die while still on the alt screen — killed from outside, or
  ;; crashed mid-redraw — and nothing later would widen the buffer for it.
  (setq cooked--alt nil)
  (cooked--release-alt-pin)
  ;; `cooked--scroll-windows' already ran for this drain and pinned whatever was
  ;; then the buffer's true end to the bottom of every window that was following
  ;; it -- this call is what appends past that end, from entirely outside that
  ;; machinery, and stranding the line it adds is the same bug
  ;; `cooked--pin-transcript-bottom' exists to prevent. Captured before the
  ;; insert, and compared with the same slack-of-one `cooked--scroll-transcript'
  ;; uses: a window whose point was already at the old end was following, and
  ;; is owed the new one; a window scrolled up into history is left alone.
  (let ((old-end (point-max)))
    (cooked--with-child-edit
      (save-excursion
        (goto-char (point-max))
        ;; -1 is not a status: the core reports it when its reader lost the pty
        ;; with the child still unreapable, and the session is over either way.
        (insert (if (< code 0)
                    "\n[session lost]\n"
                  (format "\n[exited %s]\n" code)))))
    (cooked--dolist-windows w (get-buffer-window-list nil nil t)
      (when (>= (window-point w) (1- old-end))
        (cooked--pin-transcript-bottom (list w)))))
  ;; A child that dies mid-`getpass' -- interrupted from the buffer, killed from
  ;; outside -- leaves a password prompt with nothing behind it.
  (cooked--cancel-secret)
  ;; Nor is there any command left for what it set to describe.
  (cooked--end-of-command t)
  (cooked--stop-session)
  ;; After the session is gone, so the mode is recomputed as nil: a child that
  ;; exited while the buffer was suspended -- evil in normal state, or a
  ;; deliberate peek -- would otherwise leave it read-only under `cooked-peek-map'
  ;; with nothing left to thaw it.
  (cooked--request-refresh)
  ;; Deferred: this runs from inside the drain, which keeps working with the
  ;; buffer and its locals after we return.  Killing here would pull them out
  ;; from under it, and would run `kill-buffer-hook' — arbitrary user code —
  ;; halfway through a redraw.
  (when (cooked--kill-buffer-on-exit-p code)
    (let ((buffer (current-buffer)))
      (run-at-time 0 nil (lambda () (when (buffer-live-p buffer) (kill-buffer buffer)))))))

;;;; Starting over

(defun cooked-refresh ()
  "Rebuild the live screen from the emulator.

The way back from a redisplay that failed part-way.  An ordinary drain only
reports what changed since the last one, so it cannot repair a buffer holding
some rows of a drain that signalled halfway through applying them — the screen
region and the emulator's grid simply stay out of step, and every later delta is
applied on top of the disagreement.  This throws the screen region away and asks
the native core to re-send all of it.

The scrollback above is untouched, and so is the emulator's carry count with it:
only the region below `cooked--screen-start' is rebuilt."
  (interactive)
  (when cooked--session
    (save-restriction
      (widen)
      (cooked--with-child-edit
        (cooked--release-alt-pin)
        (delete-region (cooked--screen-start-position) (point-max))
        ;; They pointed into the text just deleted; `cooked--restore-pending-input'
        ;; puts them back at the cursor on the drain below.
        (cooked--clear-input-region)))
    ;; Here rather than left to the drain below, which would see the rebuilt
    ;; input line start where the old one did and conclude that nothing moved --
    ;; while every entry in the history was recorded against text this has just
    ;; deleted and the child is about to re-send.  Outside the macro, for the
    ;; reason given there.
    (cooked--check-undo-anchor)
    (cooked--redraw cooked--session)
    (cooked--drain-and-apply)))

(provide 'cooked-render)
;;; cooked-render.el ends here
