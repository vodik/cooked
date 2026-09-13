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
`cooked--sync-graphics'.")

(defun cooked--frame-shows-images-p (frame)
  "Whether FRAME can display a picture the child transmits.

`display-images-p' rather than `display-graphic-p': a graphical build with no
image support leaves the rectangle blank as surely as a terminal frame does.
A function of its own so that a batch test, which has no graphical frame at
all, can say what one would answer."
  (display-images-p frame))

(defun cooked--sync-graphics (&optional frame inline)
  "Tell this buffer's child whether a picture it sends can be shown.

Shown when images are on and some window showing the buffer, on any frame,
can display them.  One such window is enough: that is where the picture will
be seen, and a terminal frame beside it shows the stashed characters instead,
which is the fallback decoration already has.  See `cooked--set-graphics-shown'
for what the core does with the answer.

A buffer displayed nowhere keeps what its windows last said, in
`cooked--graphics-displayable'.  Its pictures are held and render the moment a
window turns up, so being buried is no reason to tell the child it cannot
draw, and the window hooks report wherever it is shown next.  The preference
still applies while buried, since it needs no window to be true.

FRAME stands in for those windows at session start, when the buffer has not
been displayed yet: the frame the command ran from is where it is about to
appear.  Given FRAME the answer is sent even if it matches the cache, because
the core it goes to is new and has never been told anything.

INLINE, when given, is `(VALUE)\=' and stands in for `cooked-inline-images\=',
for the variable watcher, which runs before the new value is in place."
  (when-let* ((session (cooked--live-session)))
    (let ((frames (or (mapcar #'window-frame (get-buffer-window-list nil nil t))
                      (and frame (list frame)))))
      (when frames
        (setq cooked--graphics-displayable
              (and (cl-some #'cooked--frame-shows-images-p frames) t)))
      (let ((shown (and (if inline (car inline) cooked-inline-images)
                        cooked--graphics-displayable
                        t)))
        (when (or frame (not (eq shown cooked--graphics-shown)))
          (setq cooked--graphics-shown shown)
          (cooked--set-graphics-shown session shown))))))

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
a flag touches nothing redisplay depends on."
  (unless (eq operation 'defvaralias)
    (if where
        (when (buffer-live-p where)
          (with-current-buffer where
            (when cooked--session
              (cooked--sync-graphics nil (list newval)))))
      (cooked--dolist-buffers
        (when (and cooked--session (not (local-variable-p 'cooked-inline-images)))
          (cooked--sync-graphics nil (list newval)))))))

(provide 'cooked-graphics)
;;; cooked-graphics.el ends here
