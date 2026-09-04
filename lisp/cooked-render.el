;;; cooked-render.el --- Applying a drain to the buffer -*- lexical-binding: t; -*-

;;; Commentary:

;; Everything between the native core saying "something changed" and the buffer
;; showing it: the drain itself, the order an update is applied in, and the view
;; put back on top afterwards.
;;
;; Not opt-in, unlike `cooked-next-error' and its neighbours; `cooked-mode'
;; requires this, on the argument cooked-mouse.el and cooked-keys.el each make in
;; turn -- a self-contained subject that had grown too large to keep sharing a
;; file with everything else in it.  Here the file was cooked.el and the section
;; was "Session lifecycle", which at a thousand lines was three subjects filed
;; together because they were written in that order: starting a child, drawing
;; what it sends, and capping how much of it the buffer keeps.  Only the first is
;; the session's life.  The second is this file; the third is
;; cooked-scrollback.el.
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
;; This file sits ABOVE cooked.el rather than beside it, and that was the one
;; decision the split turned on.  The pipeline is a pure consumer: it reads
;; `cooked--grid', the input region, the marks and the screen region, and calls
;; down into the renderers, the decorations, the links and the OSC handlers.
;; Nothing below it needs anything it defines.  Sitting below cooked.el would
;; have meant declaring most of that file's screen-region section; sitting here
;; means requiring it -- and requiring cooked-osc.el and cooked-mouse.el with it,
;; so the two OSC handlers and the mouse state that `cooked--handle-event'
;; dispatches to become ordinary calls.  Three of cooked.el's own
;; `declare-function's went away with the code that needed them.
;;
;; One back-edge downward survives, and it is the honest one: the wake pipe's
;; filter is installed by `cooked--start', in cooked.el, and its callback is
;; `cooked--on-wake' here.  cooked.el declares that pair and nothing else of this
;; file.  Upward, three things cooked-mode.el owns are declared below -- a
;; setting read, and two notifications that something changed, which is the one
;; shape a back-edge here is allowed to have; see cooked-mode-line.el's header
;; for the same arrangement stated at length.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'cooked)
(require 'cooked-util)
(require 'cooked-deco)
(require 'cooked-link)
(require 'cooked-mouse)
(require 'cooked-osc)
(require 'cooked-scrollback)

;; Defined by the native core at `module-load' time, so the byte-compiler cannot
;; see them; cooked.el and cooked-mode.el declare their own sets the same way.
(declare-function cooked--drain "ext:cooked-core")
(declare-function cooked--ready "ext:cooked-core")
(declare-function cooked--redraw "ext:cooked-core")

;; Owned by cooked-mode.el, which requires this file.  One setting the drain is
;; parameterised by, and two notifications -- the mode the child is in and the
;; exit it reported -- handed to the layer that owns what they mean.  Reads and
;; notifications only, never a question asked upward, which is what keeps the
;; list this short.
(defvar cooked-rejoin-wrapped-lines)
(declare-function cooked--set-mode "cooked-mode")
(declare-function cooked--on-exit "cooked-mode")

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

(defun cooked--drain-and-apply ()
  "Apply whatever the native core has accumulated since the last drain.

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
    (let ((buffer (current-buffer)))
      (unwind-protect
          (progn
            (setq cooked--draining t
                  cooked--drain-pending nil)
            (cooked--apply (cooked--drain cooked--session cooked-rejoin-wrapped-lines))
            ;; Bounded in practice: the pending flag is set by a freeze lifting,
            ;; and a freeze that has lifted does not lift again.
            (while (and cooked--drain-pending cooked--session)
              (setq cooked--drain-pending nil)
              (cooked--apply (cooked--drain cooked--session cooked-rejoin-wrapped-lines))))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (setq cooked--draining nil
                  cooked--drain-pending nil)
            ;; The far end of the core's backpressure: one wake byte is in flight
            ;; from the drain that brought us here until this says the buffer has
            ;; been drawn, so `cooked-min-redisplay-interval' paces rendering --
            ;; which is where the milliseconds are -- rather than the taking of a
            ;; delta, which costs nothing.  Once, at the very end: the loop above
            ;; may have drained several times, and it is the last render that the
            ;; interval is measured from.
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
            ;; input line moved and the anchor still naming where it used to be.
            ;; Idempotent on the ordinary path, the anchor already matching by then
            ;; -- and inside the `with-current-buffer' for the same reason as the
            ;; flags: it is this buffer's anchor it exists to check.
            (cooked--check-undo-anchor)))))))

(defun cooked--on-wake (buffer)
  "Drain BUFFER's session and apply what changed.

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
selected one, so leaving a frozen buffer resumes it rather than stranding it."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and cooked--session (not (cooked--frozen-p)))
        (if cooked-debug
            (cooked--drain-and-apply)
          (condition-case err
              (cooked--drain-and-apply)
            (error
             (message "cooked: redisplay failed: %S (point %s, cursor %S, screen-start %s)%s"
                      err (point) cooked--cursor
                      (cooked--screen-start-position)
                      (if cooked--resyncing "" "; resyncing"))
             (unless cooked--resyncing
               (let ((cooked--resyncing t))
                 (condition-case again
                     (cooked-refresh)
                   (error (message "cooked: resync failed too: %S" again))))))))))))

;;;; Applying an update

(defcustom cooked-clear-selection-on-output t
  "Whether output that rewrites the selected text takes the selection with it.

A region is a claim about particular text, and the child rewriting that text
makes the claim into a lie -- an invisible one, because the highlight stays.
`cooked--render-rows\=' deletes and reinserts each damaged row whole, so a mark
inside one collapses to that row\='s start and the region visibly warps under
live output; the drain re-pins point (see `cooked--apply\='), and nothing ever
did the same for the mark.  Every xterm-family terminal drops a selection whose
cells are overwritten, for the reason this does.

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

(defun cooked--install-resources (update)
  "Record the images and links UPDATE's rows refer to by id.

Before any rendering: this is the drain's third category -- neither a level
redisplay reads nor an occurrence to react to, but a resource the rows depend
on.  Touches no buffer text, so it needs no `inhibit-read-only'."
  (cooked--install-images (plist-get update :images))
  (cooked--install-links (plist-get update :links)))

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
The other windows on this buffer that were following the child's cursor."))

(defun cooked--capture-viewport ()
  "Snapshot the view, before the render invalidates every part of it."
  (cooked--viewport-make
   :editing (when-let* ((region (cooked--input-region))
                        ((<= (car region) (point) (cdr region))))
              (- (point) (car region)))
   :follow (and (cooked--follow-p)
                (>= (point) (cooked--screen-start-position)))
   :wandered (and cooked--wandered (cooked--screen-cell))
   :stale-mark (and cooked-clear-selection-on-output
                    mark-active (mark)
                    (>= (mark) (cooked--screen-start-position)))
   :others (cooked--following-windows)))

(defun cooked--apply-levels (update)
  "Adopt UPDATE's levels: the state as of this drain, for redisplay to read."
  (setq cooked--cursor (cooked--cursor-decode (plist-get update :cursor))
        ;; Before `cooked--fit-screen', which is shaped by it.
        cooked--grid (cooked--grid-make :height (plist-get update :height)
                                        :used (plist-get update :used)
                                        :head (plist-get update :head))
        cooked--app-cursor (plist-get update :app-cursor)
        cooked--keys (plist-get update :keys)
        cooked--exit (plist-get update :exit))
  (cooked--set-alt (plist-get update :alt))
  (cooked--set-mode (plist-get update :mode)))

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

Explicit rather than left to redisplay, and the honest reason is narrower than
it used to be stated here.  `scroll-conservatively' *is* a guarantee for the
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

(defun cooked--pin-transcript-bottom (windows &optional pos)
  "Follow POS, defaulting to `point-max\=', with the bottom row of each of WINDOWS.

Factored out of `cooked--scroll-transcript\=' because a drain is not the only
thing that can grow the buffer\='s true end.  `cooked--on-exit\=' does too,
appending the \"[exited N]\=\" line from outside `cooked--scroll-windows\='
entirely, and it needs exactly this rather than a second copy of it.

Computed and NOFORCE, rather than the `recenter\=' this used to be.
`recenter\=' sets a forced start that redisplay then overrules through
`make-cursor-line-fully-visible\=', so the window landed where neither of them
had chosen; and it counts every screen line as the default font\='s height, so a
row taller than that -- an image slice, a Nerd Font prompt separator -- had to
be paid back afterwards in whole lines of scroll.  A NOFORCE start is a
suggestion redisplay may settle against instead, and the pixels are
`make-cursor-line-fully-visible\='s business, which is where they were always
handled correctly.  No `with-selected-window\=' either: nothing here needs the
window selected, and `select-window\=' is advised -- by `evil\=', to refresh its
cursor -- so a pair of them per window per drain was arbitrary code running in
the middle of a render.

Monotone, which is what stops this jittering.  The follow direction is taken
whenever the tail has grown, and the equality is the common case: a steady
stream whose tail is the same length leaves TOP exactly where it already is and
this writes nothing at all, at a drain rate whose floor is
`cooked-min-redisplay-interval\='.  The shrink direction is the one thing the
two-way pin was buying -- `comint-scroll-show-maximum-output\='s actual
semantics, no blank space below the last line -- and is taken only when the
*last* redisplay had the buffer\='s end on screen, so it fires when the grid
really has fewer used rows than before rather than every time
`vertical-motion\='s whole-line count disagrees with what redisplay laid out in
pixels.  That disagreement is permanent on a window whose rows differ in height,
and correcting for it once per drain is the oscillation itself."
  (let ((target (or pos (point-max))))
    (cooked--dolist-windows w windows
      (set-window-point w target)
      (let ((top (save-excursion
                   (goto-char target)
                   (vertical-motion (- (1- (window-body-height w))) w)
                   (point))))
        (when (or (> top (window-start w))
                  (and (< top (window-start w))
                       (let ((end (window-end w)))
                         (and end (>= end (point-max))))))
          (set-window-start w top t))))))

(defun cooked--scroll-transcript (viewport here others)
  "Scroll the transcript in HERE and OTHERS as VIEWPORT asks."
  (let* ((target (cooked--point-after-input))
         ;; Slack of one, because whether the last rendered row carries a
         ;; terminating newline depends on how the region was last shaped: rows
         ;; are made to exist by the newline ending the row above them, so the
         ;; bottom one has one only when `cooked--fit-screen' trimmed something
         ;; below it.  So this can flip from drain to drain, which used to mean
         ;; the pin alternated with whatever redisplay chose for itself.  It no
         ;; longer costs anything: a drain that declines to pin leaves point at
         ;; the buffer's end under `scroll-conservatively' 101 and
         ;; `scroll-margin' 0, and the minimal scroll redisplay makes to keep it
         ;; visible is the same start `cooked--pin-transcript-bottom' computes.
         (at-end (>= target (1- (point-max)))))
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
     ((and (cooked-viewport-follow viewport) at-end)
      (cooked--pin-transcript-bottom (append here others) target)))))

(defun cooked--apply (update)
  "Apply UPDATE, the plist returned by `cooked--drain'.

The order below is the whole of it, and every step depends on the one above:
resources before the rows that name them, the viewport before the render that
invalidates it, the render before the marks resolved against the text it wrote,
and the region shaped before anything measures it."
  (cooked--install-resources update)
  ;; `let*', emphatically: these initialisers delete and insert, and under plain
  ;; `let' they would run before the two bindings above them took effect -- so a
  ;; protected buffer would abort the redisplay half-done from inside the process
  ;; filter, and lifting the pending input would land in the undo history.  They
  ;; are the pair `cooked--with-child-edit' binds, spelled out because a body this
  ;; long is not worth nesting one level deeper.
  (let* ((inhibit-read-only t)
         (buffer-undo-list t)
         (viewport (cooked--capture-viewport))
         (pending (cooked--take-pending-input))
         ;; Where this drain's scrollback landed, for resolving a `scrolled'
         ;; anchor against.  nil when the drain evicted nothing.
         (batch-start (when-let* ((scrolled (plist-get update :scrolled)))
                        (cooked--render-scrolled scrolled)))
         (rendered (cooked--render-rows (plist-get update :rows)
                                        (plist-get update :alt))))
    (cooked--apply-levels update)
    ;; Cleared before the events, so a drain that both scrolls and then clears
    ;; stays pinned.
    (when batch-start (setq cooked--pin-screen-top nil))
    ;; After both render passes and before the events: a mark's anchor is
    ;; resolved against text that has to be in the buffer before it can be
    ;; pointed at, and a drain that both resizes and carries a fresh mark should
    ;; end with the fresh mark's own anchor.
    (cooked--relocate-marks (plist-get update :marks) batch-start)
    (dolist (event (plist-get update :events))
      (cooked--handle-event event batch-start))
    ;; After both, which is the ordering `cooked-row-rendered-functions' is
    ;; documented against.
    (cooked--notify-rows-rendered rendered)
    (cooked--fit-screen)
    (cooked--pad-to-cursor)
    (when cooked-debug (cooked--check-seam))
    (cooked--restore-pending-input pending)
    (cooked--protect (or (and (cooked--input-state-p) (cooked--input-start-position))
                         (point-max)))
    (cooked--apply-alt-pin)
    ;; Before the point block, not after it: under evil this leaves visual state,
    ;; and evil adjusts point on the way into normal state -- so cooked's own pin
    ;; has to be the last thing to speak about where point ends up.
    (when (cooked-viewport-stale-mark viewport) (cooked--deactivate-mark))
    (cooked--place-point viewport)
    ;; Recorded, not merely left in the buffer: a window not showing this buffer
    ;; has a stale point marker Emacs will restore on the way back, over the top
    ;; of this.  See `cooked--point'.
    (setq cooked--point (point))
    (cooked--scroll-windows viewport)
    ;; After the window block, not before it: see `cooked--sync-cursor-type'.
    (cooked--sync-cursor-type)
    (cooked--update-ghost-cursor)
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
    (`(bell) (ding))
    (`(osc ,code ,bell . ,parts) (cooked--handle-osc code bell parts))
    (`(reply . ,bytes) (cooked--send-if-live bytes))
    (`(title-stack ,push) (cooked--handle-title-stack push))
    ;; `CSI 3 J', the tail of what `clear' sends.  Honoured unconditionally: it is
    ;; only reachable by something already holding the terminal, every other terminal
    ;; honours it, and it is precisely what the user typed `clear' to get.  The
    ;; command history is not lost with it: that lives in comint's ring, not here.
    (`(erase-scrollback)
     (cooked--discard-scrollback (cooked--screen-start-position)))
    (`(display-cleared) (setq cooked--pin-screen-top t))
    ;; Decoded into a record at the boundary, like the cursor and the grid; see
    ;; `cooked-mouse-state'.  cooked-mouse.el owns it because it is the only
    ;; reader, and re-gates its own keymap on the way through.
    (`(mouse ,enabled ,sgr ,drag ,motion)
     (cooked--set-mouse-state enabled sgr drag motion))
    ((or `(prompt-start ,_ . ,_) `(prompt-continuation ,_ . ,_)
         `(prompt-end ,_ . ,_)
         `(command-start ,_ ,_ . ,_) `(command-end ,_ ,_ . ,_))
     (cooked--handle-semantic event batch-start))
    (_ nil)))

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
