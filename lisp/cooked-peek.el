;;; cooked-peek.el --- Stepping out of forwarding, and back in -*- lexical-binding: t; -*-

;;; Commentary:

;; While the child owns the keyboard nearly every key is forwarded, which leaves
;; no way to search the buffer or navigate it.  Peek is the way out -- the buffer
;; goes read-only under `cooked-peek-map' -- and `cooked--resume-forwarding' is
;; the way back that every command writing to the child takes, so its effect is
;; seen landing rather than held behind a freeze.
;;
;; It sits on the drain pipeline, which a resume may have to run, and below the
;; key encoding and the commands that send.

;;; Code:

(require 'cooked-util)
(require 'cooked-state)
(require 'cooked-render)

;;;; Suspending: peek, and what evil's states ask for
;;
;; While the child owns the keyboard there is, by design, almost no way back to
;; an ordinary Emacs command -- `C-c'-prefixed ones aside.  That is exactly
;; right for a full-screen program, which needs every other key for itself, but
;; it leaves no way to fire an arbitrary command, search the buffer, or just
;; navigate with `evil' normal state.  Suspending forwarding is that door: the
;; buffer goes read-only and is handed to `cooked-peek-map', so nothing
;; forwards and nothing can be edited into text that goes nowhere while the
;; user looks around.
;;
;; Whether the render *also* stops is a separate question, and collapsing the two
;; is what makes stepping out expensive.  `cooked--input-mode' is `still' when the
;; child should keep
;; drawing while the view stays put, and `frozen' when even that is too much
;; movement -- a visual selection, say, which means something only against text
;; that is not being rewritten underneath it.  `still' is what makes stepping
;; out cheap: `C-z' to look at something no longer stops the terminal, and
;; walking away to another window certainly does not.  `cooked--wandered' and
;; the ghost cursor already pin point to its screen cell across a redraw, which
;; is the machinery that makes a live render survivable to navigate.
;;
;; Leaving is not a separate step to remember: peek is look-only, so the
;; instant a key means anything other than looking -- typing a character, RET,
;; or any of cooked's own commands that write to the child -- it ends on its
;; own, forwards whatever was pressed, and the buffer catches up immediately.
;; `cooked-peek-map' covers the first two, by reusing `cooked-send-key''s own
;; snap-to-cursor so typing lands exactly where the ghost cursor was already
;; pointing (see `cooked--peek-resume-and-send'); `cooked--send-to-child' and
;; `cooked-interrupt'/`cooked-suspend' cover the rest.  `cooked-toggle-peek'
;; remains the way to leave without acting on anything.
;;
;; That auto-resume is the half `evil' cannot use, and the reason the mode is
;; recomputed from evil's state rather than latched by a hook on it: in normal
;; state a letter is a motion, not `self-insert-command', so nothing here would
;; ever fire -- a buffer suspended on the way out of emacs state and then put
;; into insert state stayed suspended forever.  Deriving the mode instead means
;; insert state selects `cooked-semi-map' and resumes on its own, whatever
;; route got you into normal state.  See `cooked-input-mode-functions', which is
;; the seam `cooked-evil.el' fills in.

(defun cooked--resume-forwarding ()
  "Hand the keyboard back to the child, and catch the buffer up.

Called by every command that writes to the child out of band -- an interrupt,
a paste, a signal -- so the result is seen landing rather than held behind a
freeze.  Clears a deliberate `cooked-toggle-peek' and recomputes the mode,
which for an `evil' user in normal state may well be `still' again: the point
is that the effect becomes visible, not that the user is dragged back into
forwarding they did not ask to resume.  A drain is forced in that case, since
nothing else would deliver it.

Not gated on a live session: one that ended while suspended must not strand
the buffer read-only with no way back.  `cooked--refresh-keymap' now answers
that at the source -- a buffer with no session has no input mode at all, and
`cooked--on-exit' refreshes on the way out -- so this is the second lock on the
same door rather than the only one."
  (let ((was cooked--input-mode))
    (setq cooked--peek-explicit nil)
    (when cooked--input-mode
      (cooked--request-refresh))
    (when (and cooked--session (eq was 'frozen) (cooked--frozen-p))
      (cooked--drain-and-apply))))

(defun cooked-toggle-peek ()
  "Step out to a read-only, navigable Emacs buffer, or back to the child.

While the child owns the keyboard, `cooked-raw-map'/`cooked-alt-map' forward
almost everything to it, which leaves no way to fire an Emacs command, search
the buffer, or navigate with `evil' normal state.  This suspends forwarding --
freezing the render so the child's own output does not disturb the view, and
making the buffer read-only so nothing can be edited into text that goes
nowhere -- and installs `cooked-peek-map' instead.  Peek is look-only: typing
a character or RET ends it and forwards what was pressed, same as it would
have gone straight through without the interruption (see
`cooked--peek-resume-and-send'), and so does any of cooked's own commands
that write to the child (\\`C-c C-c', \\`C-c C-y', and the rest).  Calling this
again leaves without acting on anything, and either way the buffer catches up
on whatever the child produced meanwhile.

The freeze lifts on its own when this buffer's window stops being the selected
one -- see `cooked--frozen-p'.  Holding a picture still is only worth anything
while someone is looking at it, and a terminal that stopped because its window
lost focus is a bug wearing a feature's clothes.

`evil' users reach the same place through their own states, and do not need
this: `C-z' to emacs state and back, or simply normal state, which is `still'
by default -- read-only and navigable, with the render still live.  This is the
door for everyone else."
  (interactive)
  (when (cooked--input-state-p)
    (user-error "Already editable"))
  (if cooked--peek-explicit
      (cooked--resume-forwarding)
    (setq cooked--peek-explicit t)
    (cooked--request-refresh)
    (message "Peeking (read-only) -- type, RET, or C-c C-v to resume")))

(provide 'cooked-peek)
;;; cooked-peek.el ends here
