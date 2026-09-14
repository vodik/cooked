;;; cooked-cursor.el --- The child's cursor, and point when it wanders -*- lexical-binding: t; -*-

;;; Commentary:

;; Point and the child's cursor are two different things that usually sit on the
;; same cell.  While the child owns the keyboard, an Emacs motion can move point
;; off the cursor to read the screen; a ghost cursor then marks where the child
;; will act, and the next key sent puts point back.  This file keeps the two
;; apart and together: the cursor shape the child asked for, the ghost, the
;; wandered state, and the point cooked restores when a buffer comes back.
;;
;; It sits on cooked-pending.el and cooked-screen.el, and below the drain
;; pipeline and the keymaps, which both call into it.

;;; Code:

(require 'cooked-util)
(require 'cooked-state)
(require 'cooked-screen)
(require 'cooked-pending)

;;;; The child's cursor, while Emacs has wandered off it

(defcustom cooked-cursor-shapes
  '((block . t) (underline . hbar) (bar . (bar . 2)))
  "How DECSCUSR shapes map onto `cursor-type'.

The child names a shape with `CSI Ps SP q'; vim and fish's vi-mode use it to
show which mode they are in.  Only the shape is honoured — DECSCUSR also
distinguishes blinking from steady, and whether your cursor blinks is
`blink-cursor-mode', which is yours to set and not the child's."
  :type '(alist :key-type symbol :value-type sexp)
  :group 'cooked)

(defun cooked--cursor-type ()
  "The `cursor-type' for the shape the child last asked for."
  (alist-get (cooked-cursor-shape cooked--cursor) cooked-cursor-shapes t))

;; The ghost cursor below deliberately does not follow the shape.  It is hollow to
;; say "not receiving your keystrokes", and that reading comes from the hollowness
;; rather than from the outline — Emacs has no meaningful hollow bar to draw anyway.

(defface cooked-ghost-cursor
  '((t :box (:line-width (-1 . -1))))
  "Face marking where the child's cursor is while point is somewhere else.

Drawn hollow on purpose.  A terminal draws its cursor hollow when the window
is unfocused, so the shape already reads as \"this cursor is not receiving
your keystrokes\" — which is exactly what is true of the child's cursor while
you are navigating with Emacs' own motions."
  :group 'cooked)

(defvar-local cooked--ghost-cursor nil
  "Overlay drawing the child's cursor, or nil when it is not being drawn.")

(defvar-local cooked--wandered nil
  "Whether a command has moved point off the child's cursor.

Tracked as a state set by commands rather than inferred by comparing point to
the cursor on each drain.  The comparison is order-dependent — streaming output
lets the cursor overtake point for a single drain — and inferring from it would
strand point for every drain after that.  See `cooked--apply'.")

(defvar-local cooked--point nil
  "Where cooked itself last put point in this buffer.

Kept because Emacs remembers a *position* on cooked's behalf and cooked's
positions do not survive a redraw.  A window that stops showing this buffer
leaves a point marker for it in `window-prev-buffers', and
`cooked--render-rows' deletes and reinserts whole rows, so by the time it
comes back that
marker has been dragged off whatever it was pointing at -- to the end of the
rebuilt region, which at a prompt is the empty line below it.  Emacs restores it
over the top of the position the drain maintained meanwhile, so cooked has to
hold its own answer.  The same reasoning as `cooked--wandered' holding a screen
cell rather than a position, one level up: a cell survives a redraw, a marker
does not, and an unwatched marker is not evidence about anything.

Written by the drain and by `cooked--track-wandering', which between them are
every way point moves that cooked has an opinion about; read by
`cooked--restore-point' when the buffer comes back on screen.")

(defun cooked--restore-point (window)
  "Put point back where cooked last had it, over a marker Emacs restored.

Called when this buffer returns to WINDOW.  What Emacs restores is the window
point it recorded when the buffer left, and for a cooked buffer that is a marker
every drain since has been dragging -- see `cooked--point'.  The drain's own
answer is the one that means something: it re-seats a wandered point on its
cell and follows the child's cursor otherwise, and it does that whether or not
anyone is looking.

Declines when the recorded position is not in the accessible portion -- the alt
screen narrows, and a position from before it did is not this screen's."
  (when (and cooked--point
             (<= (point-min) cooked--point (point-max))
             (/= (point) cooked--point))
    (goto-char cooked--point)
    (when (window-live-p window)
      (set-window-point window cooked--point))))

(defun cooked--sync-cursor-type ()
  "Make `cursor-type' say what the child last asked for.

Written only on an actual change: reassigning the same value on every drain
perturbs the cursor's blink phase, which is one more contributor to flicker on
a line the child rewrites rapidly.

Called at the end of a drain, after the block that scrolls windows, and again
from `post-command-hook'.  `evil' refreshes its own cursor from
`window-configuration-change-hook' and on every state change.  Setting the
cursor any earlier would let evil have the last word inside the very drain that
hid it, and a progress bar the child asked to draw without a cursor would show
one jumping around it.

A hidden cursor is honoured by default: every full-screen program drawing a
frame, `less', and any progress bar worth the name relies on that.  Two cases
override it, and both are cases where point is the only cursor there is.  The
user has stepped out, which the mode alone answers -- `still' or `frozen'.
Or Emacs is editing the line, which `cooked--input-state-p' alone is too wide
to say, because `brew upgrade' hides the cursor and repaints progress bars
without ever leaving canonical mode.  Under a shell that sends OSC 133 we know
which of the two it is, and while a command is running the child's `CSI ?25l'
is about the picture it is painting and is honoured."
  (let ((shape (cond ((and cooked--cursor (cooked-cursor-visible cooked--cursor))
                      (cooked--cursor-type))
                     ((memq cooked--input-mode '(still frozen)) t)
                     ((and (cooked--input-state-p)
                           (not (eq cooked--semantic 'output)))
                      t))))
    (unless (equal cursor-type shape)
      (setq-local cursor-type shape))))

(defun cooked--ghost-cursor-visible-p ()
  "Whether the child's cursor should be drawn separately from point.

Not an alt-screen thing: `raw', `command' and every suspended state -- `evil'
normal state included -- are all cases where the child owns the keyboard and
point may be somewhere else, and the ghost is what keeps the way back visible
in each of them.

Nothing is drawn for a cursor the child has hidden, which is also the case in
which `cooked--sync-cursor-type' gives point a visible cursor of its own: there
is exactly one cursor on screen either way, and it is the one that will act on
the next keystroke."
  (and cooked--wandered
       ;; Only where the child owns the keyboard and the screen is its drawing.
       ;; At a prompt, point being elsewhere is ordinary editing, not a divergence.
       (cooked--child-owns-keyboard-p)
       ;; A hidden cursor stays hidden; nvim hides it during some redraws, and a
       ;; box left behind would be a cursor the child does not think it has.
       (cooked-cursor-visible cooked--cursor)))

(defun cooked--update-ghost-cursor ()
  "Draw, move, or remove the overlay marking the child's cursor."
  (if (not (cooked--ghost-cursor-visible-p))
      (when cooked--ghost-cursor
        (delete-overlay cooked--ghost-cursor)
        (setq cooked--ghost-cursor nil))
    (let* ((beg (cooked--cursor-position))
           (eol (save-excursion (goto-char beg) (line-end-position)))
           ;; Past the last character of its row the cursor has nothing to cover,
           ;; so the box rides on a stand-in space instead.
           (empty (>= beg eol)))
      (unless cooked--ghost-cursor
        (setq cooked--ghost-cursor (make-overlay beg beg nil t nil))
        ;; Above `hl-line-mode' and the region, which would otherwise paint over
        ;; the one thing on screen the user is aiming at.
        (overlay-put cooked--ghost-cursor 'priority 100))
      (move-overlay cooked--ghost-cursor beg (if empty beg (1+ beg)))
      (overlay-put cooked--ghost-cursor 'face (unless empty 'cooked-ghost-cursor))
      (overlay-put cooked--ghost-cursor 'after-string
                   (when empty (propertize " " 'face 'cooked-ghost-cursor))))))

;;;; Where point is while the child has the keyboard
;;
;; Two halves of one idea, and the reason they are here rather than in
;; cooked-keys.el: neither is about what a key means, both are about the buffer
;; the key is pressed in.  A command may move point off the cell the child is
;; drawing its cursor on, and the ghost cursor keeps saying where that cell is;
;; then the next key sent puts point back, because the child was always going to
;; act at its own cursor whatever Emacs was showing.

(defun cooked--track-wandering ()
  "Notice a command moving point off the child's cursor, or back onto it.

Runs from `post-command-hook' because Emacs' own motions produce no output:
nothing is drained, so a redraw cannot be what discovers that point has moved."
  (cooked--protect-hook
    (setq cooked--wandered
          (and
           ;; Not "the child owns the keyboard", which is the same test wherever
           ;; there is no pending input -- and the wrong one at a prompt, where a
           ;; `still' render still has to pin a point the user parked out in the
           ;; screen against `cooked--render-rows' deleting the row under it.
           ;; Point inside the input has not wandered off anything: it is in the
           ;; text Emacs is holding for the child, which is rebuilt around the
           ;; child's cursor on every drain and so has no cell to be pinned to.
           ;;
           ;; With no region at all, though, there is nothing for point to be
           ;; inside of, and the question falls back to who owns the keyboard.
           ;; A prompt without a region is a line in flight -- before the first
           ;; drain has built one, or in the gap `cooked-send-input' opens by
           ;; unmarking the text it submitted -- and the row under point is about
           ;; to be redrawn by the echo, so there is no view being held for the
           ;; user to protect.  Pinning there strands point on the old cell: the
           ;; `wandered' arm of `cooked--apply' outranks `follow'.
           (if-let* ((region (cooked--input-region)))
               (not (<= (car region) (point) (cdr region)))
             (cooked--child-owns-keyboard-p))
           ;; Scrollback is the reading case, already handled by `follow'.
           (cooked--screen-cell)
           (not (cooked--at-child-cursor-p))))
    ;; Not only on a drain: `evil' refreshes its cursor from
    ;; `window-configuration-change-hook' and on every state change, neither of
    ;; which produces output, so there would be no drain to put it back.
    ;; The other half of `cooked--point': a command moving point is the second way
    ;; it moves, and a buffer the user leaves without a drain in between must
    ;; remember where they left it rather than where the last drain did.
    (setq cooked--point (point))
    (cooked--sync-cursor-type)
    (cooked--update-ghost-cursor)))

(defun cooked--snap-to-cursor ()
  "Return point to the child's cursor before handing it a key.

Typing is the moment the keyboard goes back, so it is the moment to stop
pretending point is anywhere else — the child will act at its own cursor
whatever Emacs is showing, and the ghost has been marking that spot."
  (when (and cooked--wandered (cooked--child-owns-keyboard-p))
    (goto-char (cooked--cursor-position))
    (setq cooked--wandered nil)
    (cooked--update-ghost-cursor)))

(provide 'cooked-cursor)
;;; cooked-cursor.el ends here
