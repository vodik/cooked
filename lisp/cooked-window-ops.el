;;; cooked-window-ops.el --- What the child asks of its window (XTWINOPS) -*- lexical-binding: t; -*-

;;; Commentary:

;; XTWINOPS is `CSI Ps t', a family of requests about the window a terminal
;; runs in.  The native core answers everything it can measure itself -- `18t'
;; and `14t' are the grid -- and hands on the three that are about Emacs' own
;; windows and frames: pushing and popping the title, asking for a size, and
;; asking how big the frame is.
;;
;; It sits on cooked-osc.el, whose title it pushes and pops, and is dispatched
;; from the drain pipeline.

;;; Code:

(require 'cooked-util)
(require 'cooked-state)
(require 'cooked-osc)

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
;; everything it can measure itself -- `18t' and `14t' are the grid -- and passes
;; these on because the frame and the window layout are Emacs', not the grid's.

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
not get to rearrange the layout you were working in."
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
clamp leaves behind is floored away by `cooked--window-size' like any other."
  (let ((delta (window-resizable window pixels horizontal nil t)))
    (unless (zerop delta)
      (window-resize window delta horizontal nil t))))

(defun cooked--handle-frame-size (pixels)
  "Answer XTWINOPS `19t', or `15t' when PIXELS: the frame's text area.

In cells, `CSI 9 ; ROWS ; COLS t'; in pixels, `CSI 5 ; HEIGHT ; WIDTH t'.  The
frame is the one showing the layout window, or the selected one when the
buffer is shown nowhere.  Both measure the text area, so the pixel answer is
the cell answer times a cell, the way `14t' and `18t' agree.

The pixel form is silent on a terminal frame, by the rule `14t' follows: a
terminal has no pixels, and answering zero would be a claim rather than an
absence."
  (let ((frame (if-let* ((window (cooked--layout-window)))
                   (window-frame window)
                 (selected-frame))))
    (cond ((not pixels)
           (cooked--reply-if-live
            (cooked--csi "t" 9 (frame-text-lines frame) (frame-text-cols frame))))
          ((display-graphic-p frame)
           (cooked--reply-if-live
            (cooked--csi "t" 5 (frame-text-height frame) (frame-text-width frame)))))))

(provide 'cooked-window-ops)
;;; cooked-window-ops.el ends here
