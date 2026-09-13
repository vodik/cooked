;;; cooked-graphics.el --- Telling the child whether a picture can be shown -*- lexical-binding: t; -*-

;;; Commentary:

;; The native core claims graphics in three answers, and a producer that believes
;; them draws a picture.  Where Emacs cannot show one -- `cooked-inline-images' is
;; off, or the buffer is only on a terminal frame -- the claim has to be
;; withdrawn, so the producer draws in half blocks instead of leaving a blank
;; rectangle.  This file keeps the claim in step with what the windows showing a
;; buffer can display.
;;
;; It sits on cooked-deco.el and cooked-state.el and calls nothing above them.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'cooked-util)
(require 'cooked-deco)

(cooked--declare-core)

;;;; Whether a picture can be shown
;;
;; The core claims graphics in three answers -- the `4' in DA1, XTSMGRAPHICS and a
;; kitty `a=q' probe -- and a producer that believes them draws a picture.  Where
;; none can be shown, because `cooked-inline-images' is off or the buffer is only
;; on a terminal frame, that picture is a blank rectangle, while the same producer
;; told the truth would have drawn it in half blocks.  So the claim follows what
;; Emacs can display, and this is where Emacs says so.

(defvar-local cooked--graphics-shown nil
  "What this buffer's core was last told by `cooked--sync-graphics'.
Kept so the window hooks, which run on every buffer change in every frame, only
reach the module when the answer actually moves.")

(defvar-local cooked--graphics-displayable nil
  "Whether the windows last seen showing this buffer could display images.
The half of the answer that a buffer displayed nowhere keeps; see
`cooked--graphics-answer'.")

(defconst cooked--graphics-types '(png jpeg gif pbm)
  "The image types the core ever hands Emacs a picture as.
Sixel and kitty RGBA arrive as PNG, kitty RGB as `pbm\=', and an iTerm2 file as
whichever of the first three it is.")

(defun cooked--frame-shows-images-p (frame)
  "Whether FRAME can display a picture the child transmits.

`display-images-p' rather than `display-graphic-p': a graphical build with no
image support leaves the rectangle blank as surely as a terminal frame does.
A function of its own so that a batch test, which has no graphical frame at
all, can say what one would answer."
  (display-images-p frame))

(defun cooked--graphics-answer (&optional frame inline)
  "What this buffer's core should be told about pictures, as a list or nil.

Nil when nothing can be shown, and otherwise the members of
`cooked--graphics-types' this Emacs decodes, like (png jpeg gif pbm).  The list
and not a flag because the answers ask about different formats: a build without
libpng can show a kitty RGB picture, which arrives as `pbm\=', and not a sixel,
which arrives as PNG.

Shown when images are on and some window showing the buffer, on any frame,
can display them.  One such window is enough: that is where the picture will
be seen, and a terminal frame beside it shows the stashed characters instead,
which is the fallback decoration already has.  A window on an iconified frame
counts, for the reason a buried buffer keeps its answer: the picture is held
and appears when the frame does.

A buffer displayed nowhere keeps what its windows last said, in
`cooked--graphics-displayable', which this updates.  FRAME stands in for those
windows at session start, when the buffer has not been displayed yet: the frame
the command ran from is where it is about to appear.

INLINE, when given, is `(VALUE)\=' and stands in for `cooked-inline-images\=',
for the variable watcher, which runs before the new value is in place."
  (let ((frames (or (mapcar #'window-frame (get-buffer-window-list nil nil t))
                    (and frame (list frame)))))
    (when frames
      (setq cooked--graphics-displayable
            (and (cl-some #'cooked--frame-shows-images-p frames) t)))
    (and (if inline (car inline) cooked-inline-images)
         cooked--graphics-displayable
         (seq-filter #'image-type-available-p cooked--graphics-types))))

(defun cooked--sync-graphics (&optional inline)
  "Tell this buffer's child whether a picture it sends can be shown.

The answer is `cooked--graphics-answer\=' with INLINE; see there for what it
is, and `cooked--set-graphics-shown' for what the core does with it.  The
preference applies to a buried buffer too, since it needs no window to be true,
and the window hooks report wherever the buffer is shown next.  A session's
first answer is not sent from here but passed to `cooked--spawn', by
`cooked--start', so the core has it before the child can probe."
  (when-let* ((session (cooked--live-session)))
    (let ((shown (cooked--graphics-answer nil inline)))
      (unless (equal shown cooked--graphics-shown)
        (setq cooked--graphics-shown shown)
        (cooked--set-graphics-shown session shown)))))

(defun cooked--sync-graphics-everywhere (&rest _)
  "Run `cooked--sync-graphics' in every live session.

From `window-buffer-change-functions', whose global value runs once per frame
whenever a window on it was added, deleted or changed buffer -- which covers a
buffer appearing on a terminal frame and leaving the last graphical one -- and
from `after-delete-frame-functions', since deleting a whole frame is neither."
  (cooked--dolist-buffers
    (when cooked--session
      (cooked--sync-graphics))))

(defun cooked--sync-graphics-on-toggle (_symbol newval operation where)
  "Follow `cooked-inline-images' to NEWVAL, as a variable watcher.

WHERE is the buffer a buffer-local OPERATION applies to, and nil for the
default value, which reaches every session that has not made the variable
local.  Pushed directly rather than deferred: unlike a drain, telling the core
a flag touches nothing redisplay depends on.

`kill-local-variable\=' arrives as `makunbound\=' with NEWVAL nil, while the
value the buffer is left with is the default one, so that is what it syncs to."
  (unless (eq operation 'defvaralias)
    (if where
        (when (buffer-live-p where)
          (with-current-buffer where
            (when cooked--session
              (cooked--sync-graphics
               (list (if (eq operation 'makunbound)
                             (default-value 'cooked-inline-images)
                           newval))))))
      (cooked--dolist-buffers
        (when (and cooked--session (not (local-variable-p 'cooked-inline-images)))
          (cooked--sync-graphics (list newval)))))))

(provide 'cooked-graphics)
;;; cooked-graphics.el ends here
