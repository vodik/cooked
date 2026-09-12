;;; glyph-scaling-shot.el --- render the glyph-scaling fixture  -*- lexical-binding: t; -*-

;; For looking at what `cooked--scale-offenders' actually draws, which the pixel
;; measurements cannot substitute for -- the geometry can be right while the
;; typography is wrong, and that is exactly what happened once already.
;;
;;     WAYLAND_DISPLAY=wayland-1 emacs -Q -l scripts/glyph-scaling-shot.el
;;
;; writes before.png and after.png beside this file's `dir' below.  It cannot run
;; under the gamescope headless recipe the other scripts use: `x-export-frames'
;; refuses a frame that is not *visible*, and a headless frame never is.

(let ((root (file-name-directory
             (directory-file-name
              (file-name-directory (or load-file-name buffer-file-name))))))
  (add-to-list 'load-path (expand-file-name "lisp" root)))
(defvar dir (or (getenv "COOKED_SHOT_DIR") "/tmp/"))
(defvar log nil)
(condition-case e
    (progn
      (require 'cooked) (require 'cooked-mode)
      (set-face-attribute 'default nil :height 400)
      (switch-to-buffer (get-buffer-create "s"))
      (setq mode-line-format nil)
      (redisplay t)
      (push (format "cell %dx%d frame %dx%d" (frame-char-width) (frame-char-height)
                    (frame-pixel-width) (frame-pixel-height)) log)
      (cl-flet ((shot (name)
                  (redisplay t)
                  (let ((data (x-export-frames (selected-frame) 'png)))
                    (with-temp-file (concat dir name ".png")
                      (set-buffer-multibyte nil)
                      (insert data))
                    (push (format "%s: %d bytes" name (length data)) log))))
        (erase-buffer)
        (insert "┌────────┬────────┐\n"
                "│abc文def│abc🙂def│\n"
                "│ABCDEFGH│IJKLMNOP│\n"
                "└────────┴────────┘\n")
        (shot "before")
        (let ((m (make-hash-table :test #'equal)))
          (save-excursion
            (goto-char (point-min))
            (while (not (eobp))
              (cooked--scale-offenders (line-beginning-position) (line-end-position)
                                       (selected-window) m)
              (forward-line 1))))
        (shot "after")))
  (error (push (format "ERROR %S" e) log)))
(with-temp-file (concat dir "shot.log") (insert (mapconcat #'identity (nreverse log) "\n") "\n"))
(kill-emacs 0)
