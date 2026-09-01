;;; cooked-face.el --- ANSI colours and SGR attributes as Emacs faces -*- lexical-binding: t; -*-

;;; Commentary:

;; The emulator reports a cell's rendition as a foreground, a background, a bitmask of
;; SGR attributes and an underline colour.  This turns that into a face plist, and
;; memoizes the answer, because a full-screen repaint asks the same question thousands
;; of times a second.
;;
;; Colours resolve through the `ansi-color-\=' faces first, so a theme that styles those
;; wins; `cooked-color-names\=' is only the fallback.  Nothing here reads the buffer, so
;; the whole file is exercisable without a session.

;;; Code:

(require 'cooked-util)

(defconst cooked--attr-bold 1)
(defconst cooked--attr-faint 2)
(defconst cooked--attr-italic 4)
(defconst cooked--attr-underline 8)
(defconst cooked--attr-blink 16)
(defconst cooked--attr-reverse 32)
(defconst cooked--attr-conceal 64)
(defconst cooked--attr-strike 128)
(defconst cooked--attr-underline-shift 8
  "Bit position of the underline-style field.  See `Attrs' in src/emu/cell.rs.")
(defconst cooked--attr-underline-style (ash 7 cooked--attr-underline-shift))

(defcustom cooked-color-names
  ["black" "red3" "green3" "yellow3" "blue2" "magenta3" "cyan3" "gray90"
   "gray50" "red" "green" "yellow" "blue" "magenta" "cyan" "white"]
  "Fallback palette for the sixteen ANSI colors.
Consulted only where the corresponding `ansi-color-' face gives no foreground,
so a theme that styles those faces wins."
  :type '(vector (repeat :inline t string))
  :group 'cooked)

(defconst cooked--ansi-faces
  [ansi-color-black ansi-color-red ansi-color-green ansi-color-yellow
   ansi-color-blue ansi-color-magenta ansi-color-cyan ansi-color-white
   ansi-color-bright-black ansi-color-bright-red ansi-color-bright-green
   ansi-color-bright-yellow ansi-color-bright-blue ansi-color-bright-magenta
   ansi-color-bright-cyan ansi-color-bright-white]
  "Faces the theme is expected to style, indexed by ANSI color number.")


(defvar-local cooked--face-cache nil)

;;;; Colors and faces

(defun cooked--xterm-256 (index)
  "Hex string for xterm 256-color INDEX at or above 16."
  (if (>= index 232)
      (let ((v (+ 8 (* 10 (- index 232)))))
        (format "#%02x%02x%02x" v v v))
    (let* ((n (- index 16))
           (step (lambda (c) (if (zerop c) 0 (+ 55 (* 40 c))))))
      (format "#%02x%02x%02x"
              (funcall step (/ n 36))
              (funcall step (% (/ n 6) 6))
              (funcall step (% n 6))))))

(defun cooked--color (spec)
  "Emacs color for SPEC: nil, an index, or a list of R G B."
  (cond ((null spec) nil)
        ((consp spec) (apply #'format "#%02x%02x%02x" spec))
        ((< spec 16) (or (face-foreground (aref cooked--ansi-faces spec) nil t)
                         (aref cooked-color-names spec)))
        (t (cooked--xterm-256 spec))))

(defvar cooked-theme-change-hook nil
  "Run in each cooked buffer when the theme changes, to drop stale colors.

The layer above this one caches things it has already colored, and cannot say so
from here: `cooked-deco.el\=' requires this file, so this file cannot reach back
into it for a cache to clear.  Adding to this hook is how it says so instead.")

(defun cooked--flush-face-cache (&rest _)
  "Forget resolved colors so a new theme applies to subsequent output.

Nothing colorless needs flushing: `cooked--box-glyph-cache\=' holds shape bitmaps
that are colorized live at display time, so a theme change leaves them true.
What does need it is anything holding a color already resolved against the old
theme, which is what `cooked-theme-change-hook\=' is for."
  (cooked--dolist-buffers
    (when (hash-table-p cooked--face-cache)
      (clrhash cooked--face-cache))
    (run-hooks 'cooked-theme-change-hook)))

;; `enable-theme-functions' arrived in Emacs 29, and `add-hook' on an unbound variable
;; quietly defines it rather than failing — so on 28 this looked fine and did nothing.
(if (boundp 'enable-theme-functions)
    (progn
      (add-hook 'enable-theme-functions #'cooked--flush-face-cache)
      (add-hook 'disable-theme-functions #'cooked--flush-face-cache))
  (advice-add 'enable-theme :after #'cooked--flush-face-cache)
  (advice-add 'disable-theme :after #'cooked--flush-face-cache))

(defconst cooked--underline-styles
  [nil line line wave line line]
  "Emacs `:underline' styles, indexed by the SGR 4:x subparameter.

Emacs renders only `line' and `wave', so double, dotted and dashed all fall
back to a plain line rather than being approximated with overlays.")

(defun cooked--underline-spec (attrs ul)
  "The `:underline' value for the ATTRS bitmask with underline colour UL.

Plain t whenever there is nothing to say beyond \='underlined\=', so the common
case produces exactly the face plist it did before styled underlines existed."
  (let ((style (aref cooked--underline-styles
                     (min 5 (ash (logand attrs cooked--attr-underline-style)
                                 (- cooked--attr-underline-shift)))))
        (color (and ul (cooked--color ul))))
    (cond ((and (null color) (memq style '(nil line))) t)
          (t (append (and color (list :color color))
                     (and (eq style 'wave) (list :style 'wave)))))))

(defconst cooked--attr-face-properties
  `((,cooked--attr-bold :weight bold)
    (,cooked--attr-faint :weight light)
    (,cooked--attr-italic :slant italic)
    (,cooked--attr-strike :strike-through t))
  "SGR attribute bits that map straight onto a face property and a constant value.

The attributes needing more than a constant — underline, whose style and colour
are a whole sub-protocol, and conceal, which resolves against the background
that was just computed — are handled separately in `cooked--face'.")

(defsubst cooked--attr-p (attrs bit)
  "Whether BIT is set in the ATTRS bitmask."
  (/= 0 (logand attrs bit)))

(defun cooked--face (fg bg attrs &optional ul)
  "Face plist for FG, BG, the ATTRS bitmask and underline colour UL.
Memoized per buffer."
  (cooked--cached cooked--face-cache (list fg bg attrs ul)
    (cooked--face-build fg bg attrs ul)))

(defun cooked--face-build (fg bg attrs ul)
  "Build the face plist `cooked--face' memoizes for FG, BG, ATTRS and UL."
  (let* ((reverse (cooked--attr-p attrs cooked--attr-reverse))
         (fg* (cooked--color (if reverse bg fg)))
         (bg* (cooked--color (if reverse fg bg)))
         (face nil))
    (when fg* (setq face (plist-put face :foreground fg*)))
    (when bg* (setq face (plist-put face :background bg*)))
    (pcase-dolist (`(,bit ,property ,value) cooked--attr-face-properties)
      (when (cooked--attr-p attrs bit)
        (setq face (plist-put face property value))))
    (when (cooked--attr-p attrs cooked--attr-underline)
      (setq face (plist-put face :underline (cooked--underline-spec attrs ul))))
    ;; Last, and after the foreground it overrides: concealed text is drawn in the
    ;; background colour, which is only known once reverse video has been settled.
    (when (cooked--attr-p attrs cooked--attr-conceal)
      (setq face (plist-put face :foreground (or bg* (face-background 'default)))))
    face))

(provide 'cooked-face)
;;; cooked-face.el ends here
