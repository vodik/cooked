;;; cooked-window-ops.el --- What the child asks of its window (XTWINOPS) -*- lexical-binding: t; -*-

;;; Commentary:

;; XTWINOPS is `CSI Ps t', a family of requests about the window a terminal
;; runs in.  The native core answers everything it can measure itself -- `18t'
;; and `14t' are the grid, and `19t'/`15t' are the frame, pushed down from
;; here -- and hands on the two that are actions rather than reports: pushing
;; and popping the title, and asking for a resize.
;;
;; It sits on cooked-osc.el, whose title it pushes and pops, and is dispatched
;; from the drain pipeline.

;;; Code:

(require 'cooked-util)
(require 'cooked-state)
(require 'cooked-osc)

(cooked--declare-core)

(defconst cooked--title-stack-limit 8
  "How many titles `cooked--title-stack' will hold.

A child can push without ever popping — `smcup' pushes on every entry to the
alternate screen — so the stack is bounded and drops from the bottom.  Eight is
past any real nesting of full-screen programs.")

(defun cooked--handle-title-stack (push)
  "Push the current title when PUSH, otherwise pop and restore one.

XTWINOPS 22 and 23, which `smcup' and `rmcup' send around the alternate screen:
without them a full-screen program that sets a title leaves it behind on exit."
  (if push
      (setq cooked--title-stack
            (last (cons cooked-title cooked--title-stack)
                  cooked--title-stack-limit))
    ;; An underflowing pop is the child's bug, not ours; leave the title alone.
    (when cooked--title-stack
      (cooked--set-title (pop cooked--title-stack)))))

;;;; XTWINOPS — the window the child is laid out for
;;
;; Two things a child may ask about the window beyond the title stack above: to
;; change its size, and how big the frame around it is.  The native core answers
;; both, as it answers `18t' and `14t' from the grid, but neither the layout
;; window nor the frame is something the grid can measure itself.  A resize is
;; an action with side effects Lisp alone can decide to take, so it stays an
;; event; the frame size is a value only Lisp can read, so it is pushed down
;; below and the core answers `19t'/`15t' from what it was last told, the way
;; it answers `CSI ? 996 n' from the colour scheme.

(defcustom cooked-resize-requests nil
  "What a child's request to resize the terminal does.

XTWINOPS `CSI 8 ; ROWS ; COLS t' asks for a size, and DECSLPP (`CSI ROWS t'
with ROWS of 24 or more) for a row count alone.  `resize -s' sends the first.

nil      Refuse.  Nothing moves and nothing is sent back, which is what
         xterm does with `allowWindowOps' off; the child reads its real
         size back with `CSI 18 t' and learns the answer that way.
`window' Resize the window the child is laid out for toward the request,
         as far as the windows around it allow.  The frame is never
         touched, so a buffer that fills its frame cannot move at all.

Refused by default because anything that can write to the terminal can send
one, and the windows it would move are yours: a program you ran over ssh does
not get to rearrange the layout you were working in.

Three things `window' does not do.  A 0 for ROWS or COLS leaves that dimension
alone, as a missing one does, where xterm reads 0 as the size of the display:
`CSI 8 ; 0 ; 100 t' changes only the columns.  Only the window the child is laid
out for moves, so with the buffer also shown in a shorter window the child keeps
that window's rows, and `resize -s 50 80' can leave it with fewer than 50.  And
a child that asks for its size again on every SIGWINCH, as some do, puts the
window back each time you drag it to another size: it cannot loop, but it does
undo the drag."
  :type '(choice (const :tag "Refuse" nil)
                 (const :tag "Resize the layout window" window))
  :group 'cooked)

(defun cooked--handle-resize-request (rows cols)
  "Resize this buffer's layout window toward ROWS by COLS, if allowed.

Either may be nil, meaning leave that dimension as it is.  See
`cooked-resize-requests', which decides whether anything happens at all.

Only `cooked--layout-window' moves, even when several windows show the buffer:
its size is the one the child has, so it is the one a request is about.  The
columns are capped below the next narrowest window for the same reason, since a
layout window grown past another stops being the layout window, and the child
would be handed the other one's width instead of what it asked for.

Nothing here tells the child.  The window changing size is noticed by
`window-size-change-functions' like any other resize, and that path sends the
SIGWINCH -- so the child is told once, in the one place a size is ever
reported from, and the size it is told is the one the window really took.

That is also what keeps a request from looping.  The resize is computed
against the window as it stands and clamped by `window-resizable', so asking
again for a size already reached, or for one the layout cannot give, resizes
nothing and so produces no SIGWINCH for a child to react to with another
request."
  (when-let* (((eq cooked-resize-requests 'window))
              (window (cooked--layout-window)))
    (when rows
      (cooked--resize-window-by
       window nil
       (- (* rows (window-default-line-height window))
          (window-body-height window t))))
    (when cols
      (let* ((others (delq window (get-buffer-window-list (current-buffer) nil t)))
             (cap (and others
                       (apply #'min (mapcar #'window-max-chars-per-line others))))
             (cols (if cap (min cols cap) cols)))
        (cooked--resize-window-by
         window t
         (* (- cols (window-max-chars-per-line window))
            (window-font-width window 'default)))))))

(defun cooked--resize-window-by (window horizontal pixels)
  "Resize WINDOW by up to PIXELS, HORIZONTAL or not, never touching the frame.

Pixelwise, because the child counts rows in `window-default-line-height' and
columns in the default face's width, and either can differ from the frame's
canonical character size under `text-scale-mode'.  A partial row or column the
clamp leaves behind is floored away by `cooked--window-size' like any other.

Unless `window-resize-pixelwise' is set, `window-resize' moves a window only by
whole multiples of `frame-char-size', and it rounds a pixel delta to the nearest
one on its own.  Rounding after the clamp could step past it: with 17-pixel
characters and room for 26 more pixels, a delta of 26 rounds to 34, and
`window-resize' signals \"Cannot resize window\" rather than doing what it
can.  So the request is rounded here, the way `window-resize' would round it,
before `window-resizable' clamps it, and a clamp that lands between two
multiples is truncated toward zero, to one `window-resize' can make exactly."
  (let* ((unit (if window-resize-pixelwise
                   1
                 (frame-char-size window horizontal)))
         (wanted (* (round pixels unit) unit))
         (room (window-resizable window wanted horizontal nil t))
         (delta (* (truncate room unit) unit)))
    (unless (zerop delta)
      (window-resize window delta horizontal nil t))))

(defun cooked--sync-frame-size ()
  "Tell this buffer's session how big the frame around it is.

The core answers `CSI 19t' (cells, `9;ROWS;COLS t') and `15t' (pixels,
`5;HEIGHT;WIDTH t') from what this last told it, the way it answers `18t' and
`14t' from the grid: the query is answered where it arrives instead of
waking Lisp for a value that has not moved.  Called from
`cooked--frame-size-changed' on every frame resize, and once more at spawn,
since a child can probe before any resize has happened.

The frame is the one showing `cooked--layout-window', or the selected frame
when the buffer is shown nowhere.  Pixels are left nil on a terminal frame,
by the rule `14t' already follows: a terminal has no pixels, and pushing
zero would be a claim rather than an absence."
  (when-let* ((session (cooked--live-session))
              (frame (if-let* ((window (cooked--layout-window)))
                         (window-frame window)
                       (selected-frame))))
    (cooked--set-frame-size
     session (frame-text-lines frame) (frame-text-cols frame)
     (and (display-graphic-p frame) (frame-text-height frame))
     (and (display-graphic-p frame) (frame-text-width frame)))))

(provide 'cooked-window-ops)
;;; cooked-window-ops.el ends here
