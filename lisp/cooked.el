;;; cooked.el --- A terminal that hands the keyboard back -*- lexical-binding: t; -*-

;; Author: Simon <simongmzlj@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: terminals, processes
;; URL: https://github.com/simon/cooked

;;; Commentary:

;; A terminal emulator whose input model follows what the child actually wants.
;; The kernel's line discipline says when a program is doing a canonical read;
;; OSC 133 says when the shell is at a prompt.  In either case Emacs owns the
;; line and you edit it as you would any buffer.  Otherwise keys are forwarded
;; verbatim and the emulator behaves as a terminal.
;;
;;   (use-package cooked
;;     :load-path "/path/to/cooked/lisp"
;;     :commands (cooked cooked-other-window)
;;     :custom (cooked-buffer-name "*cooked: %s*")
;;     :config
;;     (require 'cooked-evil)        ; opt in to evil state syncing
;;     (require 'cooked-osc-eval))   ; opt in to the OSC 51 command channel
;;
;; Emulation happens in a Rust module, built on first use with cargo.
;;
;; This file is the core: rendering, colours, and the OSC handlers that are inert
;; enough to be on by default.  `cooked-mode' has the interaction; `cooked-evil'
;; and `cooked-osc-eval' are separate because you should choose them.

;; The buffer is the scrollback.  Rows that scroll off the emulator's screen are
;; handed over once and become ordinary buffer text; the last `cooked--rows' lines
;; are the live screen, rewritten from damage reports.
;;
;; Invariant: buffer text equals the grid, plus any pending input rendered at the
;; cursor.  Every redisplay lifts the pending input out, applies the grid, and puts
;; it back.

;;; Code:

(require 'cl-lib)
(require 'face-remap)
(require 'url-util)

(defgroup cooked nil
  "A terminal emulator that yields to Emacs when the child wants a line."
  :group 'processes
  :prefix "cooked-")

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

(defcustom cooked-box-drawing-images t
  "Whether to render box-drawing and block-element characters as generated bitmaps.

On by default: most monospace fonts draw ─│┌┐└┘├┤┬┴┼ and the block-shade
characters (▀▄█▌▐░▒▓ etc.) with glyph-to-glyph inconsistencies, highly visible
in full-screen programs like htop, ranger and fzf that rely on these
characters forming continuous borders.  Cooked classifies these characters in
its native core and renders them as small generated bitmaps sized to the
current font and colored from the active theme — the same approach VTE, Kitty
and Alacritty take.

Falls back to plain colored text, exactly as when this is nil, if Emacs lacks
XBM image support or bitmap generation fails for a glyph."
  :type 'boolean
  :group 'cooked)

;; Mirrors the bit layout of `BoxGlyph' in src/emu/glyph.rs — kept in sync by hand,
;; the same way `cooked--attr-*' above mirrors `Attrs'. Line glyphs: four 2-bit
;; edge-weight fields (up/down/left/right, 0=none 1=light 2=heavy 3=double) packed
;; into bits 0-7, an arc flag at bit 8, forward/backward diagonal flags at bits 9-10
;; (mutually exclusive with the edge fields on any real codepoint), and a 2-bit dash
;; code in bits 11-12. Block glyphs: bit 15 set, a 3-bit direction in bits 0-2, a
;; 4-bit fill amount in bits 3-6.
(defconst cooked--box-kind-block (ash 1 15))
(defconst cooked--box-arc (ash 1 8))
(defconst cooked--box-diag-forward (ash 1 9))
(defconst cooked--box-diag-backward (ash 1 10))
(defconst cooked--box-dash-shift 11)
(defconst cooked--box-dash-mask (ash 3 11))
(defconst cooked--box-dash-counts [0 2 3 4]
  "Dash code (bits 11-12 of a line descriptor) to the number of dashes it means.
Unicode defines only 2-, 3- and 4-dash lines, so the count does not fit the
two bits the layout has left; `BoxGlyph::dashes' in src/emu/glyph.rs decodes
the same table on the Rust side.")
(defconst cooked--box-direction-up 0)
(defconst cooked--box-direction-down 1)
(defconst cooked--box-direction-left 2)
(defconst cooked--box-direction-right 3)
(defconst cooked--box-direction-full 4)
(defconst cooked--box-direction-shade 5)
(defconst cooked--box-direction-quadrant 6)

(defvar-local cooked--session nil "Handle returned by `cooked--spawn'.")
(defvar-local cooked--wake nil "Pipe process Rust pokes when output is pending.")
(defvar-local cooked--rows 24)
(defvar-local cooked--cols 80)
(defvar-local cooked--screen-start nil
  "Marker at the first line of the live screen; everything before is scrollback.")
(defvar-local cooked--cursor '(0 0 t block)
  "The child's cursor as (ROW COL VISIBLE SHAPE).
SHAPE is `block', `underline' or `bar', from DECSCUSR.")
(defvar-local cooked--alt nil)
(defvar-local cooked--narrowed nil
  "Whether the restriction in force is ours, from `cooked-alt-screen-pin'.")
(defvar-local cooked--app-cursor nil
  "DECCKM: send cursor keys as SS3, which is what `smkx' asks for.")
(defvar-local cooked--keys 'legacy
  "How to spell modified Return, Tab, Escape and Backspace for this child.

One of `legacy', `modify-other' or `kitty', as negotiated by the child itself —
see `cooked--literal-codes' for why this cannot simply be assumed.")
(defvar-local cooked--title nil "Title the child last set, via OSC 0 or 2.")
(defvar-local cooked--title-stack nil
  "Titles saved by XTWINOPS 22, newest first.  See `cooked--handle-title-stack'.")
(defvar-local cooked--hyperlink nil "Current OSC 8 hyperlink target, if any.")
(defvar-local cooked--annotation nil "Prompt annotation from OSC 51;A.")
(defvar-local cooked--mouse nil "Whether the child asked for mouse reports.")
(defvar-local cooked--mouse-sgr nil "Whether to encode mouse reports as SGR (1006).")
(defvar-local cooked--mode 'cooked)
(defvar-local cooked--exit nil)
(defvar-local cooked--face-cache nil)
(defvar-local cooked--box-ascent-cache nil
  "Line-box height -> the `:ascent' that lands a bitmap on it, per buffer.

Separate from `cooked--box-glyph-cache' because it memoizes a `font-info' call
rather than a bitmap, and that call is far too costly to repeat per character
on a full-screen repaint.  Keyed by height alone: the answer depends only on
the font's ascent relative to the line box.")

(defvar-local cooked--box-glyph-cache nil
  "Descriptor+pixel-size -> raw XBM bitmap, memoized per buffer.

Colorless by construction: the cached value is a shape only, colorized live
via :foreground/:background at `create-image' time, so unlike
`cooked--face-cache' this needs no theme-change invalidation — only pixel-size
changes (zoom, font change) miss the cache key, naturally, with no extra
plumbing.")

;; Rendering lives here, interaction in cooked-mode.el, and redisplay has to call
;; into it: applying an update needs to know who owns the keyboard.
(defvar cooked--input-start)
(defvar cooked--input-end)
(declare-function cooked--take-pending-input "cooked-mode")
(declare-function cooked--restore-pending-input "cooked-mode")
(declare-function cooked--point-after-input "cooked-mode")
(declare-function cooked--input-state-p "cooked-mode")
(declare-function cooked--refresh-keymap "cooked-mode")
(declare-function cooked--update-mouse-grab "cooked-mode")
(declare-function cooked--policy "cooked-mode")
(declare-function cooked--set-mode "cooked-mode")
(declare-function cooked--semantic "cooked-mode")
(declare-function cooked--on-exit "cooked-mode")
(declare-function cooked--rename-to-title "cooked-mode")
(defvar cooked-rejoin-wrapped-lines)

(declare-function cooked--spawn "cooked-core")
(declare-function cooked--drain "cooked-core")
(declare-function cooked--send "cooked-core")
(declare-function cooked--reply-osc "cooked-core")
(declare-function cooked--resize "cooked-core")
(declare-function cooked--forget-history "cooked-core")
(declare-function cooked--redraw "cooked-core")
(declare-function cooked--prompt-text "cooked-core")
(declare-function cooked--signal "cooked-core")
(declare-function cooked--pid "cooked-core")
(declare-function cooked--bracketed-paste-p "cooked-core")
(declare-function cooked--kill "cooked-core")

;; `signal' refuses a symbol with no `error-conditions' property, so the native
;; core's `io_error' would otherwise itself fail with "Invalid error symbol"
;; the first time a pty operation errors.
(define-error 'cooked-error "cooked: I/O error")

(defun cooked-session-p (object)
  "Whether OBJECT is a session handle made by the native core.

Exists mostly so the `wrong-type-argument' the core signals names a
predicate that resolves.  The core does the real check, comparing the
user-pointer's finalizer against its own; Emacs itself cannot tell one
module's user-pointer from another's."
  (and (user-ptrp object) (ignore-errors (integerp (cooked--pid object)))))

(defconst cooked--source-directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory holding this file, captured at load time.")

(defcustom cooked-alt-screen-pin 'narrow
  "What the buffer does while a full-screen program owns the alternate screen.

`narrow' confines the buffer to the screen region, which is how a terminal
behaves: scrollback is unreachable until the program exits.  `follow' leaves
the whole buffer accessible, so you can scroll up and read the transcript
behind a running program -- possible only because Emacs, not the emulator,
owns the history.

Under `narrow' a deliberate \\[widen] is undone by the next redraw; quit the
program to get the transcript back."
  :type '(choice (const :tag "Narrow to the alt screen" narrow)
                 (const :tag "Allow scrolling into scrollback" follow))
  :group 'cooked)

(defcustom cooked-term-name "cooked-256color"
  "Value of TERM for the child, or nil to present as xterm-256color.

Shipping an entry is the honest option — it declares direct colour, which
xterm-256color does not, and withholds the capabilities we ignore — and it is
what alacritty, wezterm, foot and Emacs' own `term.el' all do.  The cost is
remote hosts that have never heard of it; see `cooked-install-terminfo-remote'.
The entry is installed under ~/.terminfo, needing no root, and we fall back to
xterm-256color if that is not possible."
  :type '(choice (const :tag "Present as xterm-256color" nil) string)
  :group 'cooked)

(defun cooked--root ()
  "Top of the source tree."
  (file-name-directory (directory-file-name cooked--source-directory)))

(defun cooked--terminfo-known-p (name)
  "Whether terminfo can describe NAME."
  (and name (eq 0 (call-process "infocmp" nil nil nil name))))

(defun cooked--terminfo ()
  "TERM to hand the child, installing our entry on first use."
  (let ((source (expand-file-name "terminfo/cooked.ti" (cooked--root))))
    (cond
     ((null cooked-term-name) "xterm-256color")
     ((cooked--terminfo-known-p cooked-term-name) cooked-term-name)
     ((and (executable-find "tic")
           (file-exists-p source)
           (eq 0 (call-process "tic" nil nil nil "-x" "-o"
                               (expand-file-name "~/.terminfo") source)))
      cooked-term-name)
     (t
      (message "cooked: could not install terminfo, presenting as xterm-256color")
      "xterm-256color"))))

;;;###autoload
(defun cooked-install-terminfo-remote (host)
  "Copy our terminfo entry to HOST so remote programs recognise TERM."
  (interactive "sHost: ")
  (unless (cooked--terminfo-known-p cooked-term-name)
    (cooked--terminfo))
  (let ((command (format "infocmp -x %s | ssh %s 'mkdir -p ~/.terminfo && tic -x -o ~/.terminfo -'"
                         (shell-quote-argument cooked-term-name)
                         (shell-quote-argument host))))
    (if (eq 0 (call-process-shell-command command))
        (message "cooked: installed %s on %s" cooked-term-name host)
      (user-error "cooked: failed to install terminfo on %s" host))))

(defcustom cooked-native-module nil
  "Path to the built native core, or nil to look under the source tree.
An escape hatch for installations where the compiled module does not sit beside
the Lisp — a system package, or a build directory somewhere else."
  :type '(choice (const :tag "Find it in the source tree" nil) file)
  :group 'cooked)

(defun cooked--load-module ()
  "Load the native core, building it if necessary."
  (unless (featurep 'cooked-core)
    (unless module-file-suffix
      (error "cooked: this Emacs was built without dynamic module support"))
    (let* ((root (cooked--root))
           ;; Not a hardcoded \".so\": cargo names a cdylib \"libcooked.dylib\" on macOS,
           ;; which is exactly what `module-file-suffix' reports there.
           (built (or cooked-native-module
                      (expand-file-name (concat "target/release/libcooked" module-file-suffix)
                                        root))))
      (unless (file-exists-p built)
        (message "cooked: building native core...")
        (let ((default-directory root))
          (unless (zerop (call-process "cargo" nil "*cooked-build*" nil "build" "--release"))
            (pop-to-buffer "*cooked-build*")
            (error "cooked: cargo build failed"))))
      (module-load built))))

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

(defun cooked--flush-face-cache (&rest _)
  "Forget resolved colors so a new theme applies to subsequent output.

Deliberately does not touch `cooked--box-glyph-cache': that cache holds
colorless shape bitmaps, colorized live at display time, so it has nothing a
theme change could make stale."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and (derived-mode-p 'cooked-mode) (hash-table-p cooked--face-cache))
        (clrhash cooked--face-cache)))))

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

(defun cooked--face (fg bg attrs &optional ul)
  "Face plist for FG, BG, the ATTRS bitmask and underline colour UL.
Memoized per buffer."
  (let ((key (list fg bg attrs ul)))
    (or (gethash key cooked--face-cache)
        (puthash key
                 (let* ((reverse (/= 0 (logand attrs cooked--attr-reverse)))
                        (fg* (cooked--color (if reverse bg fg)))
                        (bg* (cooked--color (if reverse fg bg)))
                        (face nil))
                   (when fg* (setq face (plist-put face :foreground fg*)))
                   (when bg* (setq face (plist-put face :background bg*)))
                   (when (/= 0 (logand attrs cooked--attr-bold))
                     (setq face (plist-put face :weight 'bold)))
                   (when (/= 0 (logand attrs cooked--attr-faint))
                     (setq face (plist-put face :weight 'light)))
                   (when (/= 0 (logand attrs cooked--attr-italic))
                     (setq face (plist-put face :slant 'italic)))
                   (when (/= 0 (logand attrs cooked--attr-underline))
                     (setq face (plist-put face :underline
                                           (cooked--underline-spec attrs ul))))
                   (when (/= 0 (logand attrs cooked--attr-strike))
                     (setq face (plist-put face :strike-through t)))
                   (when (/= 0 (logand attrs cooked--attr-conceal))
                     (setq face (plist-put face :foreground (or bg* (face-background 'default)))))
                   face)
                 cooked--face-cache))))

;;;; Box-drawing / block-element bitmaps
;;
;; The native core classifies U+2500-U+259F characters into a compact shape
;; descriptor (see BoxGlyph in src/emu/glyph.rs) instead of handing them over as
;; opaque text, so fonts are never trusted for these characters — the same reason
;; VTE, Kitty and Alacritty stopped trusting the font for this range: glyph-to-glyph
;; inconsistency breaks continuous borders in full-screen programs like htop/ranger.
;;
;; Rendering is a themed XBM mask: the bitmap itself is colorless shape data,
;; colorized live via :foreground/:background at `create-image' time, so
;; `cooked--box-glyph-cache' never needs the theme-flush treatment `cooked--face-cache'
;; gets — only pixel-size (zoom, font change) is part of its cache key.

(defun cooked--box-bitmap-make (width height)
  "A HEIGHT x WIDTH grid of booleans, all initially nil."
  (let ((grid (make-vector height nil)))
    (dotimes (y height)
      (aset grid y (make-vector width nil)))
    grid))

(defun cooked--box-bitmap-fill-rect (grid width height x0 y0 x1 y1 &optional value)
  "Set every pixel of GRID in [X0,X1) x [Y0,Y1), clamped to WIDTH x HEIGHT.

VALUE defaults to t; pass the symbol `clear' to unset the span instead, which is
how `cooked--box-draw-dashes' punches gaps out of an already-drawn stroke."
  (let ((x0 (max 0 x0)) (y0 (max 0 y0)) (x1 (min width x1)) (y1 (min height y1))
        (value (if (eq value 'clear) nil t)))
    (let ((y y0))
      (while (< y y1)
        (let ((row (aref grid y)) (x x0))
          (while (< x x1)
            (aset row x value)
            (setq x (1+ x))))
        (setq y (1+ y))))))

(defun cooked--box-bitmap-pack (grid width height)
  "Pack boolean GRID into (WIDTH HEIGHT DATA) for `cooked--box-glyph-image'.

DATA is a unibyte string with each row byte-aligned, LSB first.  This triple is
this file's own shape, not an image spec: `create-image' takes DATA as `:data'
and needs WIDTH and HEIGHT restated as `:data-width'/`:data-height' alongside a
`:stride'.  Handing it the triple instead yields an invalid spec, which Emacs
resolves by drawing the underlying character with the font — leaving the
feature looking switched off rather than broken."
  (let* ((row-bytes (ceiling width 8))
         (data (make-string (* row-bytes height) 0)))
    (dotimes (y height)
      (let ((row (aref grid y)))
        (dotimes (x width)
          (when (aref row x)
            (let ((i (+ (* y row-bytes) (/ x 8))))
              (aset data i (logior (aref data i) (ash 1 (mod x 8)))))))))
    (list width height data)))

(defun cooked--box-weight (bits shift)
  (logand (ash bits (- shift)) 3))

(defun cooked--box-draw-edge (grid width height cx cy edge weight light-t heavy-t)
  "Draw one edge of a line glyph from the cell center outward."
  (cond
   ((= weight 0) nil) ; no edge
   ((= weight 3) (cooked--box-draw-double-edge grid width height cx cy edge))
   (t (let* ((thickness (if (= weight 2) heavy-t light-t))
             (half (/ thickness 2)))
        (pcase edge
          ('up (cooked--box-bitmap-fill-rect grid width height
                                             (- cx half) 0 (+ cx (- thickness half)) (1+ cy)))
          ('down (cooked--box-bitmap-fill-rect grid width height
                                               (- cx half) cy (+ cx (- thickness half)) height))
          ('left (cooked--box-bitmap-fill-rect grid width height
                                               0 (- cy half) (1+ cx) (+ cy (- thickness half))))
          ('right (cooked--box-bitmap-fill-rect grid width height
                                                cx (- cy half) width (+ cy (- thickness half)))))))))

(defun cooked--box-draw-double-edge (grid width height cx cy edge)
  "Two parallel 1px strokes with a 1px gap, for `Weight::Double' edges."
  (pcase edge
    ('up (progn
           (cooked--box-bitmap-fill-rect grid width height (- cx 2) 0 (1- cx) (1+ cy))
           (cooked--box-bitmap-fill-rect grid width height (1+ cx) 0 (+ cx 2) (1+ cy))))
    ('down (progn
             (cooked--box-bitmap-fill-rect grid width height (- cx 2) cy (1- cx) height)
             (cooked--box-bitmap-fill-rect grid width height (1+ cx) cy (+ cx 2) height)))
    ('left (progn
             (cooked--box-bitmap-fill-rect grid width height 0 (- cy 2) (1+ cx) (1- cy))
             (cooked--box-bitmap-fill-rect grid width height 0 (1+ cy) (1+ cx) (+ cy 2))))
    ('right (progn
              (cooked--box-bitmap-fill-rect grid width height cx (- cy 2) width (1- cy))
              (cooked--box-bitmap-fill-rect grid width height cx (1+ cy) width (+ cy 2))))))

(defun cooked--box-draw-arc (grid width height cx cy thickness down-p right-p)
  "A quarter-ellipse connecting the two present edges of a rounded corner.

The center sits at whichever cell corner combines the two connected directions
(e.g. down+right puts it at the bottom-right corner), and the two radii are the
distances from that corner to the strokes this arc has to meet: horizontally to
the vertical stroke's column CX, vertically to the horizontal stroke's row CY.

Deliberately not a circle.  A single radius can satisfy only one axis unless the
cell is square, and terminal cells are roughly half as wide as they are tall — a
circle of radius (min CX CY) leaves the arc meeting the horizontal edge far from
CY, so a rounded corner fails to line up with the ─ beside it.

Thickness is applied by dividing the ellipse's implicit function by the gradient
magnitude, which approximates true distance to the curve; the naive |d - 1| on
the normalized radius would vary the stroke width around the sweep."
  (let* ((ccx (if right-p width 0))
         (ccy (if down-p height 0))
         (rx (float (max 1 (if right-p (- width cx) cx))))
         (ry (float (max 1 (if down-p (- height cy) cy))))
         (half (/ thickness 2.0)))
    (dotimes (y height)
      (dotimes (x width)
        (let* ((dx (/ (- x ccx) rx))
               (dy (/ (- y ccy) ry))
               (f (- (+ (* dx dx) (* dy dy)) 1.0))
               (gx (/ (* 2.0 dx) rx))
               (gy (/ (* 2.0 dy) ry))
               (g (sqrt (+ (* gx gx) (* gy gy)))))
          (when (and (> g 0.0) (<= (/ (abs f) g) half))
            (aset (aref grid y) x t)))))))

(defun cooked--box-draw-diagonal (grid width height thickness forward backward)
  "A straight stroke corner-to-corner: FORWARD is ╱, BACKWARD is ╲, both is ╳.

Scans the longer axis and fills a span across the shorter one, rather than
testing every pixel's perpendicular distance to the line.  The distance test is
right for a curve, where `cooked--box-draw-arc' still uses it, but wrong here
for two reasons that both show up at the aspect ratio of a cell (about 9x20).

A perpendicular half-width of half a pixel spans barely one pixel horizontally
on a stroke that steep, so whether a row got one pixel or none came down to
rounding, and the stroke came out ragged and broken.  Scanning rows instead
guarantees exactly one span per row, so the line is connected by construction at
any aspect ratio.

The stroke also has to reach the cell's corner pixels, or a run of ╱ breaks at
every cell join — the same continuity requirement the arc has against the ─
beside it.  Pixel (X,Y) covers [X,X+1) x [Y,Y+1), so its center is at
\(X+0.5, Y+0.5); measuring from centers is what puts a pixel in the corner,
where measuring from integer coordinates against a line drawn to (WIDTH,0) —
one column past the last pixel — left the top-right corner permanently unset.

THICKNESS is still perpendicular to the stroke, converted to a span along the
scanned axis by the ratio of the diagonal's length to that axis'."
  (let* ((w (float width))
         (h (float height))
         (norm (sqrt (+ (* w w) (* h h))))
         (half (/ thickness 2.0))
         ;; Scan whichever axis is longer, so the span is always across the
         ;; shorter one and every step of the scan advances the stroke.
         (rows (>= height width))
         (steps (if rows height width))
         (span (if rows width height))
         ;; Perpendicular half-thickness, projected onto the scanned axis.
         (reach (/ (* half norm) (if rows h w))))
    (dotimes (i steps)
      (let ((at (/ (+ i 0.5) steps)))
        (dolist (center (delq nil
                              (list (and forward (* span (- 1.0 at)))
                                    (and backward (* span at)))))
          (let ((lo (max 0 (floor (- center reach))))
                (hi (min span (ceiling (+ center reach))))
                ;; The span can round to nothing on a very thin stroke; the pixel
                ;; the center falls in always belongs to the line, so it anchors
                ;; the row and keeps the stroke connected.
                (anchor (min (1- span) (max 0 (floor center)))))
            (if rows
                (cooked--box-bitmap-fill-rect grid width height lo i hi (1+ i))
              (cooked--box-bitmap-fill-rect grid width height i lo (1+ i) hi))
            (if rows
                (aset (aref grid i) anchor t)
              (aset (aref grid anchor) i t))))))))

(defun cooked--box-dashes (bits)
  "Number of dashes line descriptor BITS asks for, or 0 for a solid stroke."
  (aref cooked--box-dash-counts (ash (logand bits cooked--box-dash-mask)
                                     (- cooked--box-dash-shift))))

(defun cooked--box-draw-dashes (grid width height horizontal count)
  "Break an already-drawn stroke into COUNT dashes by clearing the gaps.

HORIZONTAL selects the axis.  Runs as a post-pass over the solid line rather
than drawing the segments directly: Unicode only ever dashes a plain horizontal
or vertical stroke, never a junction or corner, so nothing else is in the cell
for a full-width clear to damage — and the stroke keeps the exact thickness and
centering `cooked--box-draw-edge' gave it.

Every measurement comes from the cell, never a fixed pixel count, or the dashes
drift out of phase with the solid lines they join as the font size changes.

The gap straddles the period boundary rather than sitting inside it, which is
what makes the pattern tile: a cell loses part of a gap off its leading edge and
the rest off its trailing one, so the gap that appears at a seam between two
dashed cells is exactly the gap that appears inside one.  Anchoring the gaps
inside the cell instead would leave the two half-dashes either side of a seam
fusing into a double-length dash.  That is also why the loop runs to COUNT
inclusive: the last iteration is the half-gap the next cell continues.

Each gap is positioned by its low edge and then given a fixed width, rather than
rounding both edges independently.  `round' breaks ties to even on some builds
and towards zero on others, and every gap here lands on an exact half whenever
the period is a whole number of pixels — rounding both ends turned a run of
three even dashes into one 2px gap and two that vanished."
  (let* ((length (if horizontal width height))
         (period (/ (float length) count))
         ;; Enough gap to read as a gap, but never so much that the dash it
         ;; leaves behind rounds away to nothing.
         (gap (max 1 (min (floor (1- period)) (round (* period 0.35))))))
    (dotimes (i (1+ count))
      (let* ((lo (floor (- (* i period) (/ gap 2.0))))
             (hi (+ lo gap)))
        (if horizontal
            (cooked--box-bitmap-fill-rect grid width height lo 0 hi height 'clear)
          (cooked--box-bitmap-fill-rect grid width height 0 lo width hi 'clear))))))

(defun cooked--box-draw-line (grid width height bits)
  (let* ((up (cooked--box-weight bits 0))
         (down (cooked--box-weight bits 2))
         (left (cooked--box-weight bits 4))
         (right (cooked--box-weight bits 6))
         (cx (/ width 2))
         (cy (/ height 2))
         (light-t (max 1 (/ (min width height) 8)))
         (heavy-t (max 2 (/ (min width height) 4))))
    (cond
     ((/= 0 (logand bits cooked--box-arc))
      (cooked--box-draw-arc grid width height cx cy light-t (/= down 0) (/= right 0)))
     ((/= 0 (logand bits (logior cooked--box-diag-forward cooked--box-diag-backward)))
      (cooked--box-draw-diagonal grid width height light-t
                                 (/= 0 (logand bits cooked--box-diag-forward))
                                 (/= 0 (logand bits cooked--box-diag-backward))))
     (t
      (cooked--box-draw-edge grid width height cx cy 'up up light-t heavy-t)
      (cooked--box-draw-edge grid width height cx cy 'down down light-t heavy-t)
      (cooked--box-draw-edge grid width height cx cy 'left left light-t heavy-t)
      (cooked--box-draw-edge grid width height cx cy 'right right light-t heavy-t)
      ;; Dashes only ever appear on a plain horizontal or vertical line, so which
      ;; edges are set is enough to name the axis.
      (let ((dashes (cooked--box-dashes bits)))
        (when (/= 0 dashes)
          (cooked--box-draw-dashes grid width height
                                   (or (/= left 0) (/= right 0)) dashes)))))))

(defun cooked--box-draw-shade (grid width height level phase)
  "An ordered-dither approximation of the three shade densities (░▒▓).

PHASE positions the pattern in absolute screen space: bit 0 offsets the columns,
bit 1 the rows, as `cooked--box-shade-phase' computes them.  Without it the
dither restarts at every cell, which tiles only when the cell is even-sized —
and a cell is very often 9 pixels wide.  At an odd width the last column of one
cell and the first of the next are both set, drawing a doubled column down every
seam between adjacent shade cells; an odd line-box height (which `line-spacing'
can easily produce) does the same horizontally.

All three patterns have period 2 on both axes, so one bit per axis is the whole
phase — there is no third alignment to represent."
  (let ((dx (logand phase 1))
        (dy (logand (ash phase -1) 1)))
    (dotimes (y height)
      (dotimes (x width)
        ;; The shifted coordinates choose the pattern; the plain ones address the
        ;; grid, which is always cell-local.
        (let ((px (+ x dx)) (py (+ y dy)))
          (when (pcase level
                  (1 (and (evenp px) (evenp py)))
                  (2 (evenp (+ px py)))
                  (_ (not (and (evenp px) (evenp py)))))
            (aset (aref grid y) x t)))))))

(defun cooked--box-draw-quadrant (grid width height mask)
  "Fill whichever quarters of the cell MASK selects (upper-left=1, upper-right=2,
lower-left=4, lower-right=8), for the ten 2x2 quadrant glyphs."
  (let ((hw (/ (1+ width) 2)) (hh (/ (1+ height) 2)))
    (when (/= 0 (logand mask 1)) (cooked--box-bitmap-fill-rect grid width height 0 0 hw hh))
    (when (/= 0 (logand mask 2)) (cooked--box-bitmap-fill-rect grid width height hw 0 width hh))
    (when (/= 0 (logand mask 4)) (cooked--box-bitmap-fill-rect grid width height 0 hh hw height))
    (when (/= 0 (logand mask 8)) (cooked--box-bitmap-fill-rect grid width height hw hh width height))))

(defun cooked--box-draw-block (grid width height bits phase)
  (let* ((direction (logand bits 7))
         (fraction (logand (ash bits -3) 15)))
    (cond
     ((= direction cooked--box-direction-full)
      (cooked--box-bitmap-fill-rect grid width height 0 0 width height))
     ((= direction cooked--box-direction-up)
      (cooked--box-bitmap-fill-rect grid width height 0 0 width (round (* height (/ fraction 8.0)))))
     ((= direction cooked--box-direction-down)
      (let ((h (round (* height (/ fraction 8.0)))))
        (cooked--box-bitmap-fill-rect grid width height 0 (- height h) width height)))
     ((= direction cooked--box-direction-left)
      (cooked--box-bitmap-fill-rect grid width height 0 0 (round (* width (/ fraction 8.0))) height))
     ((= direction cooked--box-direction-right)
      (let ((w (round (* width (/ fraction 8.0)))))
        (cooked--box-bitmap-fill-rect grid width height (- width w) 0 width height)))
     ((= direction cooked--box-direction-shade)
      (cooked--box-draw-shade grid width height fraction phase))
     ((= direction cooked--box-direction-quadrant)
      (cooked--box-draw-quadrant grid width height fraction)))))

(defun cooked--render-box-glyph (bits width height &optional phase)
  "Raw XBM bitmap for glyph descriptor BITS at WIDTH x HEIGHT pixels.

PHASE, defaulting to 0, positions patterns that have to line up with the
neighbouring cell rather than with this one — see `cooked--box-draw-shade'."
  (let ((grid (cooked--box-bitmap-make width height)))
    (if (/= 0 (logand bits cooked--box-kind-block))
        (cooked--box-draw-block grid width height bits (or phase 0))
      (cooked--box-draw-line grid width height bits))
    (cooked--box-bitmap-pack grid width height)))

(defun cooked--box-glyph-bits (bits window &optional phase)
  "Cached raw bitmap for glyph descriptor BITS at WINDOW's current cell size.

PHASE joins the cache key, since two cells of the same glyph at opposite phases
are genuinely different bitmaps.  It is non-zero only for shade glyphs at an odd
cell size, so in practice nothing else pays for the extra variant.

Sized from `window-font-width'/`window-default-line-height' rather than
`frame-char-width'/`frame-char-height': the latter ignore `text-scale-mode's
per-buffer face remapping, so zooming just this buffer would desync bitmap
size from font size — the very misalignment this feature exists to remove.

Height comes from `window-default-line-height', not `window-font-height', for
the reason `cooked--window-rows' already gives: the line box is what a row
actually occupies and includes `line-spacing', while the font height does not.
A bitmap sized to the font leaves exactly `line-spacing' pixels of background
beneath every glyph, breaking the continuous vertical borders this exists to
produce — the same defect `indent-bars' documents for box characters."
  (let* ((width (window-font-width window 'default))
         (height (window-default-line-height window))
         (phase (or phase 0))
         (key (list bits width height phase)))
    (or (gethash key cooked--box-glyph-cache)
        (puthash key (cooked--render-box-glyph bits width height phase)
                 cooked--box-glyph-cache))))

(defun cooked--box-glyph-ascent (window height)
  "`:ascent' placing a HEIGHT-pixel bitmap exactly on WINDOW's line box.

A percentage rather than `center' now that the bitmap spans the whole line box:
`center' balances the image around the text's midline, which splits any
`line-spacing' evenly above and below and lifts the glyph off the box it was
sized to fill.  Anchoring the font's own ascent instead keeps the extra space
where Emacs actually puts it — below the baseline.

Falls back to `center' if the font reports no metrics, which is the previous
behaviour and still correct whenever `line-spacing' is nil."
  (unless cooked--box-ascent-cache ; `cooked--rescale-box-glyphs' is not error-guarded
    (setq cooked--box-ascent-cache (make-hash-table :test #'equal)))
  (let ((key (list 'ascent height)))
    (or (gethash key cooked--box-ascent-cache)
        (puthash key
                 (let ((base (ignore-errors
                               (aref (font-info (face-font 'default nil window)) 8))))
                   (if (and (natnump base) (> height 0) (<= base height))
                       (round (* 100 base) height)
                     'center))
                 cooked--box-ascent-cache))))

(defun cooked--box-phase (bits window column row)
  "Dither phase for glyph BITS drawn at screen COLUMN and ROW of WINDOW.

Bit 0 is the parity of the cell's left edge in pixels, bit 1 the parity of its
top edge — which is all `cooked--box-draw-shade' needs, its patterns having
period 2 on both axes.  An even cell size makes the corresponding bit constantly
0, so the common case adds no cache variants at all.

Always 0 for anything but a shade, so no other glyph doubles its cached
variants, and 0 as well when COLUMN is unknown.  ROW may be nil where the caller
has no row index, which costs at most a horizontal seam on an odd line height.

Derived from the cell size at every call rather than remembered: the phase of a
given cell changes when the font does, so a value cached alongside the glyph
would be stale the moment the buffer is zoomed."
  (if (not (and column
                (/= 0 (logand bits cooked--box-kind-block))
                (= (logand bits 7) cooked--box-direction-shade)))
      0
    (logior (logand (* column (window-font-width window 'default)) 1)
            (ash (logand (* (or row 0) (window-default-line-height window)) 1) 1))))

(defun cooked--box-glyph-image (bits fg bg attrs &optional window phase)
  "Image spec for glyph BITS, colored from FG/BG/ATTRS like `cooked--face'.

`:scale 1' is load-bearing, not a default being restated.  `image-scaling-factor'
is `auto', which scales every image by cell-width/10 once a cell is wider than
10 pixels — true of most GUI font sizes.  These bitmaps are already generated at
exactly the cell size, so letting that apply would resample a pixel-exact 10x20
stroke up to 12x24 inside a 10x20 cell: borders stop meeting at the cell edge and
the strokes blur into something no better than the font glyphs this replaces."
  (let* ((window (or window (get-buffer-window (current-buffer)) (selected-window)))
         (reverse (/= 0 (logand attrs cooked--attr-reverse)))
         (fg* (or (cooked--color (if reverse bg fg)) (face-foreground 'default nil t)))
         (bg* (or (cooked--color (if reverse fg bg)) (face-background 'default nil t))))
    ;; `:data-width'/`:data-height'/`:stride' are what an inline `xbm' actually
    ;; requires when `:data' is raw bits, per (elisp) XBM Images -- and they are not
    ;; interchangeable with `:width'/`:height', which scale an already-decoded image
    ;; rather than describe the bit layout.  Emacs accepts only three `:data' shapes:
    ;; a vector of per-row strings, a whole XBM *file* in a string, or bare bits with
    ;; these three properties.  A packed (WIDTH HEIGHT DATA) list is none of them.
    (pcase-let ((`(,width ,height ,data) (cooked--box-glyph-bits bits window phase)))
      (create-image data 'xbm t
                    :data-width width :data-height height
                    :stride (* 8 (ceiling width 8)) ; bits per row, byte-aligned
                    :foreground fg* :background bg* :scale 1
                    ;; `image-transform-smoothing' defaults on, which interpolates
                    ;; edge pixels.  These bitmaps are pixel art meant to butt up
                    ;; against their neighbours, and a smoothed edge column reads as
                    ;; a faint seam between adjacent glyphs rather than a join.
                    :transform-smoothing nil
                    :ascent (cooked--box-glyph-ascent window height)))))

(defun cooked--overlay-box-glyphs (start glyphs fg bg attrs &optional origin row)
  "Overlay a generated bitmap `display' property on each glyph in GLYPHS.

GLYPHS is the packed unibyte string `cooked--insert-runs' describes: two
little-endian bytes per character.  Packed rather than a list because this runs
on every damaged row of every frame, and box drawing is what full-screen
programs are made of — a list would cons per character of each redraw.

Box-drawing characters are always single-column and a merged run can mix
shapes, so this is one `display' property per character rather than one
spanning the whole run.  Also stashes `cooked-box-glyph', the raw descriptor
plus its colors and its place on the screen, so `cooked--rescale-box-glyphs' can
regenerate at a new zoom level without asking the native core for anything — and
without having to work out where each glyph sat all over again.

ORIGIN is the buffer position of screen column 0 on this row, and ROW the row's
index; together they place a shade glyph's dither in absolute screen space.
ORIGIN is passed in rather than taken from `line-beginning-position' because row
0 does not always start a buffer line — it continues the wrapped row above it,
as `cooked--goto-screen-row' explains.  A preceding double-width character still
puts the column out by one, which costs a seam in a rare case and is not worth a
per-row width scan to avoid."
  (condition-case nil
      (let ((pos start)
            (window (or (get-buffer-window (current-buffer)) (selected-window))))
        (dotimes (i (/ (length glyphs) 2))
          (let* ((bits (logior (aref glyphs (* 2 i))
                               (ash (aref glyphs (1+ (* 2 i))) 8)))
                 (column (and origin (- pos origin)))
                 (phase (cooked--box-phase bits window column row)))
            (put-text-property pos (1+ pos) 'cooked-box-glyph
                               (list bits fg bg attrs column row))
            (put-text-property pos (1+ pos) 'display
                               (cooked--box-glyph-image bits fg bg attrs window phase)))
          (setq pos (1+ pos))))
    ;; A cosmetic feature must never break rendering: any failure here leaves the
    ;; plain face-only text `cooked--insert-runs' already inserted.
    (error nil)))

(defun cooked--rescale-box-glyphs ()
  "Regenerate on-screen box-glyph bitmaps for the buffer's current zoom level.
Reuses the `cooked-box-glyph' property `cooked--overlay-box-glyphs' stashed, so
this never needs the native core — the classified shape and its colors already
survive in the buffer.

Widens first: `cooked-alt-screen-pin' confines the buffer to the screen region
while a full-screen program is up, and a zoom during that would otherwise
rescale only the alt frame — leaving every glyph in the scrollback above it
stuck at the previous font size, visibly mismatched once the pin is released."
  (when (derived-mode-p 'cooked-mode)
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (let ((window (selected-window))
              (inhibit-read-only t)) ; the live screen (and scrollback) are read-only text
          (while (< (point) (point-max))
            (let ((spec (get-text-property (point) 'cooked-box-glyph))
                  (next (or (next-single-property-change (point) 'cooked-box-glyph)
                            (point-max))))
              (when spec
                ;; A tail pattern rather than two more elements: a buffer rendered
                ;; before the screen position was stashed still holds four-element
                ;; specs, and a zoom must not error on them.
                (pcase-let* ((`(,bits ,fg ,bg ,attrs . ,where) spec)
                             (phase (cooked--box-phase
                                     bits window (car where) (cadr where))))
                  (put-text-property (point) (1+ (point)) 'display
                                     (cooked--box-glyph-image
                                      bits fg bg attrs window phase))))
              (goto-char next))))))))

(defun cooked--rescale-box-glyphs-on-zoom (_symbol _newval operation where)
  "React to `text-scale-mode-amount' changing so bitmaps track the zoom level.

A variable watcher rather than advice on `text-scale-set' or
`text-scale-mode-hook': in current Emacs, `text-scale-increase'/`-decrease' are
native subrs that do not reliably dispatch back through the Lisp-visible
`text-scale-set' symbol, so advice on it can silently never fire, and a
define-minor-mode body is not guaranteed to re-run its hook on every amount
change once the mode is already active. The buffer-local amount variable
itself is the one thing every zoom entry point actually sets."
  (when (eq operation 'set)
    (with-current-buffer (or where (current-buffer))
      (when (derived-mode-p 'cooked-mode)
        (cooked--rescale-box-glyphs)))))

(add-variable-watcher 'text-scale-mode-amount #'cooked--rescale-box-glyphs-on-zoom)

(defun cooked--insert-runs (runs &optional row)
  "Insert RUNS, each (TEXT FG BG ATTRS GLYPHS), with faces applied.

Both `face' and `font-lock-face' are set.  comint leaves `font-lock-defaults'
at (nil t), so any fontification of this buffer unfontifies it first and would
strip a bare `face' property — taking every colour with it.

GLYPHS is nil for a plain-text run, or a unibyte string of raw box-glyph
descriptors (see src/emu/glyph.rs) classified by the native core, packed
little-endian in two bytes per character of TEXT.  When present, and
`cooked-box-drawing-images' allows it, each character additionally gets a
generated bitmap `display' property so it renders as a pixel-exact shape
instead of whatever the font happens to draw for that codepoint.

ROW is the screen row these runs make up, where the caller knows it.  Point on
entry is that row's screen column 0, which is the origin a shade glyph's dither
is phased against — and is not the same as the row's line beginning, since row 0
can continue a wrapped line."
  (let ((origin (point)))
    (dolist (run runs)
      (pcase-let ((`(,text ,fg ,bg ,attrs ,glyphs ,ul) run))
        (let ((start (point))
              (face (cooked--face fg bg attrs ul)))
          (insert text)
          (when face
            (add-text-properties start (point) (list 'face face 'font-lock-face face)))
          (when (and glyphs cooked-box-drawing-images (image-type-available-p 'xbm))
            (cooked--overlay-box-glyphs start glyphs fg bg attrs origin row)))))))

;;;; Rendering

(defun cooked--goto-screen-row (index &optional extend)
  "Move point to the start of screen row INDEX.
With EXTEND, add the lines needed to reach it; the screen region is trimmed to
its content, so a row below the cursor may not have a line yet.  Without EXTEND
this only moves point, which keeps queries free of side effects.

Row 0 begins at `cooked--screen-start' itself, which is not always the start of
a buffer line: when the last row handed to scrollback was wrapped it was written
without a newline, because row 0 continues it.  `forward-line' would snap back to
that line's beginning, and the caller would then delete the head it was meant to
continue — a whole row lost per eviction.  Rows below it are unaffected: moving
forward from a mid-line start lands on the next buffer line, which is right,
because row 0 owns the remainder of the shared one."
  (goto-char cooked--screen-start)
  (let ((missing (if (zerop index) 0 (forward-line index))))
    ;; `forward-line' counts a final line that lacks a newline as one line
    ;; successfully moved, so it can report success while leaving point at that
    ;; line's end rather than at the start of the row we asked for.  Rendering
    ;; the next row then appends to the previous one — which is how a command's
    ;; output and the following prompt end up sharing a line.
    (unless (or (zerop index) (bolp))
      (setq missing (1+ missing)))
    (when (and extend (> missing 0))
      (goto-char (point-max))
      (insert (make-string missing ?\n)))
    missing))

(defun cooked--pad-to-cursor ()
  "Extend the cursor's row so it can hold the cursor column.

Rendered rows have trailing blanks trimmed, which loses the space at the
end of a prompt like \"$ \".  The input region would then begin one column
early, and the shell's echo of the submitted line would disagree with
what was displayed."
  (save-excursion
    (cooked--goto-screen-row (nth 0 cooked--cursor) 'extend)
    (let ((short (- (nth 1 cooked--cursor) (- (line-end-position) (point)))))
      (when (> short 0)
        (goto-char (line-end-position))
        (insert (make-string short ?\s))))))

(defun cooked--render-scrolled (rows)
  "Append ROWS to the scrollback above the live screen, returning where they went.

The return value is the buffer position the batch was inserted at, which is what
a `scrolled' anchor is an offset from — see `cooked--anchor-position'.  It stays
valid for the rest of the redisplay: everything rendered afterwards goes below
it.

The marker is advanced explicitly rather than by insertion type:
rendering screen row 0 also inserts at this position, and an
auto-advancing marker would drift into the screen region.

Widens first: history can arrive while the alt screen is up — a resize evicts
rows from the primary even when a full-screen program is showing — and the
insertion point is above the region `cooked-alt-screen-pin' confines us to."
  (save-restriction
    (widen)
    (save-excursion
      (goto-char cooked--screen-start)
      ;; ROWS arrives pre-assembled as (TEXT STYLE-SPANS GLYPH-SPANS), so this is one
      ;; insert of plain text plus property calls only where styling or glyphs exist.
      ;; Note that building a propertized string in Lisp and inserting that instead
      ;; measures three times slower: `concat' on propertized strings makes Emacs copy
      ;; and merge property intervals over and over.
      (pcase-let ((`(,text ,spans ,glyph-spans) rows))
        (let ((start (point)))
          (insert text)
          (dolist (span spans)
            (pcase-let ((`(,from ,to ,fg ,bg ,attrs ,ul) span))
              (when-let* ((face (cooked--face fg bg attrs ul)))
                (add-text-properties (+ start from) (+ start to)
                                     (list 'face face 'font-lock-face face)))))
          ;; Box-drawing that scrolled into history is rasterized exactly as it would
          ;; be live, via the same `cooked--overlay-box-glyphs' the screen region uses
          ;; — there is no screen column here to phase a shade glyph's dither against,
          ;; which costs at most a seam on that one glyph kind, same as a live row
          ;; rendered without a known origin.
          (when (and glyph-spans cooked-box-drawing-images (image-type-available-p 'xbm))
            (dolist (span glyph-spans)
              (pcase-let ((`(,from ,_to ,fg ,bg ,attrs ,glyphs) span))
                (cooked--overlay-box-glyphs (+ start from) glyphs fg bg attrs))))
          ;; Scrollback never changes again, so it is protected once, here, rather
          ;; than re-swept on every redisplay.
          (add-text-properties start (point)
                               '(cooked-scrollback t read-only t
                                 front-sticky (read-only) rear-nonsticky (read-only)))
          (set-marker cooked--screen-start (point))
          start)))))

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
  (alist-get (or (nth 3 cooked--cursor) 'block) cooked-cursor-shapes t))

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

(defun cooked--ghost-cursor-visible-p ()
  "Whether the child's cursor should be drawn separately from point."
  (and cooked--wandered
       ;; Only where the child owns the keyboard and the screen is its drawing.
       ;; At a prompt, point being elsewhere is ordinary editing, not a divergence.
       (memq (cooked--policy) '(alt raw))
       ;; A hidden cursor stays hidden; nvim hides it during some redraws, and a
       ;; box left behind would be a cursor the child does not think it has.
       (nth 2 cooked--cursor)))

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

(defun cooked--set-alt (on)
  "Adopt alternate-screen state ON, refreshing ownership when it changes.

The keymap has to follow this and not only the line discipline: a program can
take the screen while the shell's last OSC 133 mark still says `prompt-end',
and Emacs would otherwise keep editing an input region that no longer exists
and swallow the keys the program was waiting for."
  (let ((on (and on t)))
    (unless (eq on cooked--alt)
      (setq cooked--alt on)
      (cooked--refresh-keymap))))

(defun cooked--apply-alt-pin ()
  "Confine the buffer to the screen region while the alt screen is up.

Re-applied on every redraw rather than only on the transition: the accessible
end behaves like a marker that insertions push past, so rows appended at the
end of one redraw would fall outside the region by the next.

Only ever undoes its own restriction.  A narrowing the user made themselves is
none of our business, and widening it on the next drain would make `\\[narrow-to-region]'
unusable in a terminal buffer."
  (if (and cooked--alt (eq cooked-alt-screen-pin 'narrow)
           cooked--screen-start (marker-position cooked--screen-start))
      (progn
        (narrow-to-region (marker-position cooked--screen-start) (point-max))
        (setq cooked--narrowed t))
    (cooked--release-alt-pin)))

(defun cooked--release-alt-pin ()
  "Undo the restriction `cooked--apply-alt-pin' put on the buffer, if any."
  (when cooked--narrowed
    (setq cooked--narrowed nil)
    (widen)))

(defun cooked--fit-screen ()
  "Shape the screen region to the emulator.

On the alternate screen a terminal is a fixed rectangle, so the region must hold
exactly `cooked--rows' lines — trimming to content would fight a full-screen
program, and leaving the old lines in place is why a shrunk window kept showing
stale rows."
  (if cooked--alt
      (save-excursion
        (cooked--goto-screen-row cooked--rows 'extend)
        (delete-region (point) (point-max)))
    (cooked--trim-screen)))

(defun cooked--trim-screen ()
  "Drop blank lines below the cursor so the buffer reads as a transcript.
A terminal shows a fixed rectangle; a buffer should not carry two dozen empty
lines under the prompt.  Only wholly blank tails are removed, so full-screen
programs that draw below the cursor keep their layout."
  (unless cooked--alt
    (save-excursion
      (cooked--goto-screen-row (1+ (nth 0 cooked--cursor)))
      (let ((start (point)))
        (when (and (< start (point-max))
                   (string-blank-p (buffer-substring-no-properties start (point-max))))
          (delete-region start (point-max)))))))

(defun cooked--protect (limit)
  "Make the screen read-only up to LIMIT, leaving anything after it editable.

Stickiness carries the whole design: `rear-nonsticky' leaves the far edge
open so typing at the start of the input region is accepted, while
`front-sticky' closes the near edge so nothing can be wedged in above the
transcript."
  (when (and cooked--screen-start (marker-position cooked--screen-start))
    (let ((beg (min (marker-position cooked--screen-start) limit)))
      (add-text-properties beg limit
                           '(read-only t front-sticky (read-only) rear-nonsticky (read-only)))
      (when (< limit (point-max))
        (remove-text-properties limit (point-max) '(read-only nil))))))

(defun cooked--guard-row-width (start)
  "Keep the screen row beginning at START to one screen line.

Every live row is its own hard-newlined buffer line — `cooked--render-rows'
always starts one at `cooked--goto-screen-row' and never joins it to its
neighbours — so Emacs softwrapping one is never legitimate output. It only
happens when some character's real rendered width disagreed with what
`cooked--cols' assumed for it: an ambiguous East-Asian-width character, a
composed grapheme, a font substitution, a ligature, anything. Rust's width
model is not the place to chase that — it has to stay the plain narrow
classification curses programs expect it to report — so this catches
whatever gets through on the one side that can actually observe the truth:
Emacs' own layout.

Only checked when a mismatch is even possible, as a cheap fast path: a plain
ASCII row can still disagree on a graphical frame, where font shaping can turn
`->' or `!=' into a single ligature glyph no narrower-font metric predicts —
but never in a terminal frame, which has no shaping engine to disagree with
Rust in the first place. Non-ASCII content is checked on both, since an
ambiguous-width or composed character can mismatch either way.

`vertical-motion' is that layout decision, reused rather than re-derived
from pixel widths, so this is correct regardless of cause. A row found to
wrap is trimmed from the end, one character at a time — rarely more than
one or two, since the mismatch is usually a column or so — until it no
longer does, and the cut is marked with the same right-fringe truncation
bitmap plain `truncate-lines' would show. That has to be done by hand:
`cooked-rejoin-wrapped-lines' (which see) keeps `truncate-lines' off
buffer-wide precisely so a *genuinely* wrapped scrollback line can still
softwrap and reflow for free, and this must not fight that.

Trimming by character rather than by grapheme cluster is an accepted gap: a
cut that lands between a base character and a combining mark is possible in
principle and vanishingly unlikely in practice, since the trigger is a
character whose own width was already mismeasured, not an adjacent one."
  (when (and cooked-rejoin-wrapped-lines (< start (line-end-position)))
    (goto-char start)
    (when (or (display-graphic-p)
              (string-match-p (rx (not ascii)) (buffer-substring-no-properties start (line-end-position))))
      (let (trimmed)
        ;; `line-end-position' has to be captured before `vertical-motion' moves
        ;; point, not after: taken after, it measures the end of whatever line
        ;; `vertical-motion' landed on rather than the row's own end, so a row that
        ;; does not wrap at all still reads as short of it (that next buffer line's
        ;; end is almost always past a one-line hop) — a false positive on every
        ;; non-ASCII row followed by a non-blank one, not just a genuinely
        ;; mismeasured one. The loop then deletes real characters, and once the
        ;; row is empty keeps going: `end-of-line' at START stops moving, so the
        ;; delete starts eating the newline above START and then the row below.
        (let (eol)
          (while (progn (goto-char start)
                        (setq eol (line-end-position))
                        (vertical-motion 1)
                        (< (point) eol))
            (setq trimmed t)
            (delete-region (1- eol) eol)))
        (when trimmed
          (goto-char start)
          (let ((cut (1- (line-end-position))))
            (put-text-property cut (1+ cut) 'display '(right-fringe right-truncation))))))))

(defun cooked--render-rows (rows)
  "Rewrite damaged ROWS, an alist of (INDEX . RUNS)."
  (save-excursion
    (pcase-dolist (`(,index . ,runs) rows)
      (cooked--goto-screen-row index 'extend)
      (delete-region (point) (line-end-position))
      (let ((start (point)))
        (cooked--insert-runs runs index)
        (cooked--guard-row-width start)))))

(defun cooked--cursor-position ()
  "Buffer position of the emulator cursor.
A pure query: it never extends the buffer, so it is safe to call before
`inhibit-read-only' is in effect."
  (save-excursion
    (cooked--goto-screen-row (nth 0 cooked--cursor))
    (min (+ (point) (nth 1 cooked--cursor)) (line-end-position))))

(defun cooked--anchor-position (anchor batch-start)
  "Buffer position ANCHOR names, or the cursor if it names nothing we can place.

ANCHOR is what the native core attached to a semantic mark, spelled in whichever
coordinate system survives the drain the mark arrived in — see `anchor_to_lisp'
in src/lib.rs:

  (scrolled . OFFSET)  characters into the scrollback this drain just
                       inserted, for a row that scrolled away while the
                       drain accumulated.  BATCH-START, from
                       `cooked--render-scrolled', is where that text begins.
  (screen ROW . COL)   a cell on the live grid, for a row still on it.

Both are resolvable only after the scrollback and the damaged rows have been
rendered, which is where `cooked--apply' dispatches events.

The fallback is the cursor, which is where every mark used to land — precise
enough whenever a drain carries a single mark, and wrong in exactly the case
anchors exist for."
  (pcase anchor
    (`(scrolled . ,offset)
     (if batch-start
         (min (+ batch-start offset) (point-max))
       (cooked--cursor-position)))
    (`(screen ,row . ,col)
     (save-excursion
       (cooked--goto-screen-row row)
       (min (+ (point) col) (line-end-position))))
    (_ (cooked--cursor-position))))

(defun cooked--screen-cell (&optional pos)
  "Screen row and column of POS, or nil if it is not on the screen.

The grid outlives the text: a redraw deletes and reinserts whole rows, so a
buffer position is not a stable way to remember where the user was looking,
while a cell is.

The inverse of `cooked--goto-screen-row', including its treatment of row 0:
when `cooked--screen-start' sits mid-line, the head before it belongs to
scrollback, so the column is measured from the marker rather than from the
line's beginning, which would count characters that are not on the screen
at all."
  (let ((pos (or pos (point)))
        (start (and cooked--screen-start (marker-position cooked--screen-start))))
    (when (and start (>= pos start))
      (save-excursion
        (goto-char pos)
        (if (< (line-beginning-position) start)
            (cons 0 (- pos start))
          (cons (count-lines start (line-beginning-position))
                (current-column)))))))

(defun cooked--goto-screen-cell (cell)
  "Move point to CELL, a (ROW . COL) pair, clamped to what the row holds."
  (cooked--goto-screen-row (car cell))
  (forward-char (min (cdr cell) (- (line-end-position) (point)))))

(defun cooked--at-child-cursor-p ()
  "Whether point is sitting where the child's cursor is."
  (and cooked--screen-start (marker-position cooked--screen-start)
       (= (point) (cooked--cursor-position))))

;;;; Session lifecycle

(defun cooked--window-size ()
  "Rows and columns to give the child.

A buffer can be displayed in several windows at once, across frames, but the
child has exactly one size.  Take the smallest: sizing to a larger window would
wrap and clip everything shown in the smaller one.

`window-max-chars-per-line' rather than `window-body-width', because the
latter counts the column reserved for the continuation glyph and measures
in the frame's canonical character width.  Both round the wrong way: claim
one column too many and the child wraps a line the window cannot fit,
which shows up as the last character folding onto a line of its own."
  (let ((windows (get-buffer-window-list (current-buffer) nil t)))
    (if windows
        (cons (max 1 (apply #'min (mapcar #'cooked--window-rows windows)))
              (max 1 (apply #'min (mapcar #'window-max-chars-per-line windows))))
      (cons cooked--rows cooked--cols))))

(defun cooked--window-rows (window)
  "Rows of text WINDOW can actually show, rounding a partial row down.

`window-body-height' divides by the frame's *canonical* character height,
so it disagrees with the buffer whenever the default face is remapped —
`text-scale-mode' being the usual way — and it says nothing about
`line-spacing'.  Dividing the real pixel height by the real line height
gets both, and floors, so a row that is only half visible is not a row we
claim to have."
  (floor (window-body-height window t) (window-default-line-height window)))

(defcustom cooked-min-redisplay-interval 0.008
  "Floor, in seconds, on how often a session triggers a redisplay.

Without one, a child that rewrites the same line rapidly -- a spinner, a
progress meter -- drives one full Emacs redisplay per write, far more than
any of them are actually meant to be seen at, which shows up as flicker.
Modelled on `eat-minimum-latency', though a matching ceiling on the other
end is not needed: the native core always holds the latest terminal state
regardless of whether a redisplay was requested for it, and retries a
throttled one on every read cycle, so nothing is ever stranded behind this.

Lower it if the terminal feels less responsive than it should; raise it if
it still flickers.  Takes effect for sessions started after it is set."
  :type 'number
  :group 'cooked)

(defcustom cooked-backlog-limit 8000
  "Items awaiting collection before the child is left to block on its writes.

Counts scrolled-off lines plus undelivered events.  Raising it does not make
output render faster: throughput is bounded by how fast Emacs can insert text,
not by this queue.  What it changes is who waits.  Below the limit the child
runs ahead and finishes sooner while Emacs catches up; at the limit the reader
stops draining the pty, the pty's buffer fills, and the child blocks in `write'
exactly as it would against a slow terminal.  Nothing is ever dropped.

The cost of raising it is memory, and a larger worst-case pause when a big
backlog finally lands in one redisplay.  Tuned together with
`cooked-min-redisplay-interval': a longer interval leaves more to accumulate
between drains, so this fills sooner.

Takes effect for sessions started after it is set."
  :type 'natnum
  :group 'cooked)


(defun cooked--start (argv &optional directory extra-env)
  "Spawn ARGV in the current buffer, optionally in DIRECTORY.
EXTRA-ENV is an alist prepended to the child's environment."
  (cooked--load-module)
  (setq cooked--face-cache (make-hash-table :test #'equal))
  (setq cooked--box-glyph-cache (make-hash-table :test #'equal))
  (setq cooked--box-ascent-cache (make-hash-table :test #'equal))
  (pcase-let ((`(,rows . ,cols) (cooked--window-size)))
    (setq cooked--rows rows cooked--cols cols))
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (make-string cooked--rows ?\n))
    (setq cooked--screen-start (copy-marker (point-min) nil)))
  (setq cooked--wake
        (make-pipe-process :name (format "cooked-wake<%s>" (buffer-name))
                           :buffer nil
                           :noquery t
                           :filter (let ((buffer (current-buffer)))
                                     (lambda (_proc _string) (cooked--on-wake buffer)))))
  (setq cooked--session
        (cooked--spawn argv (cooked--child-environment extra-env) cooked--rows cooked--cols cooked--wake
                      (and directory (expand-file-name directory))
                      (round (* 1000 cooked-min-redisplay-interval))
                      cooked-backlog-limit))
  cooked--session)

(defun cooked--child-environment (&optional extra)
  "Environment alist for the child, with EXTRA taking precedence."
  `(,@extra
    ("TERM" . ,(cooked--terminfo))
    ("COLORTERM" . "truecolor")
    ("INSIDE_EMACS" . ,(format "%s,cooked" emacs-version))
    ;; LINES and COLUMNS are deliberately *not* set. ncurses treats them as
    ;; authoritative over the tty's own size (`use_env'), so a program started with
    ;; them pinned keeps its original geometry for life and ignores every SIGWINCH.
    ;; The winsize is the single source of truth; shells re-export these themselves.
    ,@(cl-loop for entry in process-environment
               for split = (string-search "=" entry)
               when (and split (not (member (substring entry 0 split)
                                            '("TERM" "COLORTERM" "INSIDE_EMACS" "LINES" "COLUMNS"))))
               collect (cons (substring entry 0 split) (substring entry (1+ split))))))

(defvar cooked-debug nil
  "When non-nil, re-signal redisplay errors instead of reporting them.")

(defvar cooked--resyncing nil
  "Whether a resync is already under way, so a failing one cannot loop.
Bound for the dynamic extent of the repair rather than kept per buffer: it
answers \"am I inside one right now\", which is not something a buffer holds.")

(defun cooked--on-wake (buffer)
  "Drain BUFFER's session and apply what changed.

An error here is otherwise invisible: Emacs swallows process-filter errors, and
the symptom reaches the user as a buffer that stopped updating or a point that
jumped somewhere absurd.  Name it, then repair it — a drain that signalled
part-way through leaves the screen region disagreeing with the emulator's grid,
and no later delta mends that, because a delta only says what changed.

`cooked--resyncing' guards the repair rather than the failure: a resync that
itself fails must report and stop, not recurse a redisplay error into a loop of
them.  It is cleared once a resync completes, so this is once per failure and
not once per session."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when cooked--session
        (if cooked-debug
            (cooked--apply (cooked--drain cooked--session cooked-rejoin-wrapped-lines))
          (condition-case err
              (cooked--apply (cooked--drain cooked--session cooked-rejoin-wrapped-lines))
            (error
             (message "cooked: redisplay failed: %S (point %s, cursor %S, screen-start %s)%s"
                      err (point) cooked--cursor
                      (and cooked--screen-start (marker-position cooked--screen-start))
                      (if cooked--resyncing "" "; resyncing"))
             (unless cooked--resyncing
               (let ((cooked--resyncing t))
                 (condition-case again
                     (cooked-refresh)
                   (error (message "cooked: resync failed too: %S" again))))))))))))

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
  (when-let* ((start (and cooked--screen-start (marker-position cooked--screen-start))))
    (seq-filter (lambda (w) (>= (window-point w) start))
                (delq (selected-window) (get-buffer-window-list nil nil t)))))

(defun cooked--apply (update)
  "Apply UPDATE, the plist returned by `cooked--drain'."
  ;; `let*', emphatically: these initialisers delete and insert, and under plain
  ;; `let' they would run before `inhibit-read-only' took effect, so a protected
  ;; buffer aborts the redisplay half-done from inside the process filter.
  (let* ((inhibit-read-only t)
         (pending (cooked--take-pending-input))
         ;; Follow the cursor unless the user has gone up into the scrollback to
         ;; read.  Comparing point against the cursor instead is order-dependent:
         ;; output arriving in chunks lets the cursor overtake point for a single
         ;; drain, and point is then stranded for every drain after it — landing
         ;; at column 0 of whichever line it was on.
         (follow (>= (point) (marker-position cooked--screen-start)))
         ;; A redraw deletes and reinserts whole rows, so a wandered point would
         ;; be dragged to the start of whatever was rebuilt underneath it.  The
         ;; cell survives that; the buffer position does not.
         (wandered (and cooked--wandered (cooked--screen-cell)))
         ;; Captured before the redraw for the same reason `follow' is: once the
         ;; screen region is rewritten, every window's old point either points at
         ;; text that no longer means what it did or has already been dragged
         ;; along by the deletion, so which windows counted as "following" has to
         ;; be decided now, not after.
         (other-follows (cooked--following-windows))
         ;; Where this drain's scrollback landed, for resolving a `scrolled' anchor
         ;; against.  nil when the drain evicted nothing, in which case no anchor can
         ;; refer to it either.
         (batch-start (when-let* ((scrolled (plist-get update :scrolled)))
                        (cooked--render-scrolled scrolled))))
    (cooked--render-rows (plist-get update :rows))
    (setq cooked--cursor (plist-get update :cursor)
          cooked--app-cursor (plist-get update :app-cursor)
          cooked--keys (plist-get update :keys)
          cooked--exit (plist-get update :exit))
    (cooked--set-alt (plist-get update :alt))
    (cooked--set-mode (plist-get update :mode))
    ;; After both render passes: a mark's anchor is resolved against text that has to
    ;; be in the buffer before it can be pointed at.
    (dolist (event (plist-get update :events))
      (cooked--handle-event event batch-start))
    (cooked--fit-screen)
    (cooked--pad-to-cursor)
    ;; Written only on an actual change: reassigning it to the same value on every
    ;; drain was perturbing the cursor's blink phase on each redraw, one more small
    ;; contributor to flicker on a line the child rewrites rapidly.
    (let ((shape (and (nth 2 cooked--cursor) (cooked--cursor-type))))
      (unless (equal cursor-type shape)
        (setq-local cursor-type shape)))
    (cooked--restore-pending-input pending)
    (cooked--protect (if (and (cooked--input-state-p) cooked--input-start)
                        (marker-position cooked--input-start)
                      (point-max)))
    ;; After the region has settled, so the bounds match what was just drawn.
    (cooked--apply-alt-pin)
    ;; Staying put beats following the cursor once the user has taken the
    ;; keyboard back: the child keeps redrawing under them, and being yanked to
    ;; its cursor mid-motion is the behaviour this exists to stop.  The ghost
    ;; keeps the way back visible; `cooked--snap-to-cursor' takes it.
    (cond (wandered (cooked--goto-screen-cell wandered))
          (follow (goto-char (cooked--point-after-input))))
    ;; Explicit rather than left to redisplay, for two separate reasons: a
    ;; non-selected window is never the one `goto-char' above just moved, so
    ;; nothing else here would touch it; and even the selected window's
    ;; `scroll-conservatively' is not a redisplay guarantee once output arrives
    ;; from a process filter rather than a command. `comint-postoutput-scroll-
    ;; to-bottom' recenters explicitly for exactly that reason — this mirrors
    ;; it, in place of the `comint-output-filter-functions' hook cooked cannot
    ;; use, having replaced comint's own insertion with `cooked--apply' outright.
    ;;
    ;; The alt screen takes a different path: that region is sized to the window
    ;; exactly (`cooked--fit-screen'), so a full-screen program's own cursor
    ;; position is never an "end of output" to scroll toward — the whole screen
    ;; is meant to be on screen by construction, but a resize reaches here in two
    ;; steps rather than one. The window changes height the instant Emacs notices
    ;; (`cooked--sync-size'), while the buffer is not re-fitted to match until this
    ;; drain's `cooked--fit-screen' above runs. Ordinary redisplay fills that gap
    ;; on its own terms, pushing `window-start' down to keep point on screen in
    ;; the meantime — and nothing corrected that once the buffer caught up, so the
    ;; window kept the scroll a now-irrelevant redisplay had chosen, clipping the
    ;; top of the screen. Pin it back to the region's start on every drain, not
    ;; only the transition, the same way `cooked--apply-alt-pin' re-narrows on
    ;; every drain rather than only when `cooked--alt' flips.
    (if cooked--alt
        (when follow
          (let ((top (marker-position cooked--screen-start))
                (here (and (eq (window-buffer (selected-window)) (current-buffer))
                           (selected-window))))
            (dolist (w (if here (cons here other-follows) other-follows))
              (when (window-live-p w) (set-window-start w top t)))))
      (let* ((target (cooked--point-after-input))
             ;; A rendered row always ends with a newline, even the cursor's own —
             ;; see `cooked--insert-runs' — so the cursor at the true end of output
             ;; sits one short of `point-max', not on it.
             (at-end (>= target (1- (point-max))))
             ;; The selected window only belongs here if it is actually showing
             ;; this buffer — output can arrive from a process filter while the
             ;; user's focus is on an entirely different window, and recentering
             ;; that one would be a bug, not a courtesy.
             (recenter-too (and follow (eq (window-buffer (selected-window)) (current-buffer))
                                 (list (selected-window)))))
        (dolist (w other-follows)
          (when (window-live-p w) (set-window-point w target)))
        (when at-end
          (dolist (w (append recenter-too other-follows))
            (when (window-live-p w) (with-selected-window w (recenter (- -1 scroll-margin))))))))
    (cooked--update-ghost-cursor)
    (when cooked--exit (cooked--on-exit cooked--exit))))

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
    (`(reply . ,bytes) (cooked--send cooked--session bytes))
    (`(title-stack ,push) (cooked--handle-title-stack push))
    (`(erase-scrollback)
     (when cooked-honor-erase-scrollback
       (cooked--discard-scrollback (marker-position cooked--screen-start))))
    (`(mouse ,enabled ,sgr)
     (setq cooked--mouse enabled cooked--mouse-sgr sgr)
     ;; The keymap that outranks `pixel-scroll-precision-mode' is gated on this,
     ;; so it has to move when the child changes its mind about the mouse.
     (cooked--update-mouse-grab))
    ((or `(prompt-start ,_) `(prompt-end ,_) `(command-start ,_) `(command-end ,_ ,_))
     (cooked--semantic event batch-start))
    (_ nil)))

;;;; OSC dispatch
;;
;; Everything except OSC 133 arrives here verbatim, so a new integration is a
;; handler in this alist rather than a change to the native core.

(defvar cooked-osc-handlers
  '((0 . cooked--osc-title)
    (2 . cooked--osc-title)
    (7 . cooked--osc-cwd)
    (8 . cooked--osc-hyperlink)
    (10 . cooked--osc-color)
    (11 . cooked--osc-color)
    (12 . cooked--osc-color)
    (110 . cooked--osc-color-reset)
    (111 . cooked--osc-color-reset)
    (112 . cooked--osc-color-reset)
    (51 . cooked--osc-emacs)
    (52 . cooked--osc-clipboard))
  "Alist of OSC code to a function taking the remaining payload parts.
Add to this to teach cooked a new escape sequence without touching Rust.

A handler that answers a query calls `cooked--reply-osc' rather than framing
the reply itself, passing `cooked--osc-bell-terminated' straight through.")

(defvar cooked--osc-bell-terminated nil
  "Whether the OSC being handled ended with BEL rather than ST.

Bound around each handler.  It is not an argument because handlers are a
documented extension point and most of them never reply; a handler that does
hands this back to `cooked--reply-osc' without interpreting it.")

(defvar cooked--osc-code nil
  "Code of the OSC being handled, bound around each handler.
Handlers registered for a range of codes — the colour ones — need to know
which of them they were called for.")

(defun cooked--handle-osc (code bell parts)
  "Run the handler for OSC CODE with PARTS, which arrived BELL-terminated."
  (when-let* ((handler (alist-get code cooked-osc-handlers)))
    (condition-case err
        (let ((cooked--osc-bell-terminated bell)
              (cooked--osc-code code))
          (funcall handler parts))
      (error (message "cooked: OSC %s handler failed: %S" code err)))))

(defun cooked--osc-title (parts)
  "Show the child's title, from OSC 0 or 2."
  (cooked--set-title (string-join parts ";")))

(defun cooked--set-title (title)
  "Set the child's title to TITLE and show it."
  (setq cooked--title title)
  (cooked--rename-to-title)
  (force-mode-line-update))

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
            (last (cons cooked--title cooked--title-stack)
                  cooked--title-stack-limit))
    ;; An underflowing pop is the child's bug, not ours; leave the title alone.
    (when cooked--title-stack
      (cooked--set-title (pop cooked--title-stack)))))

(defun cooked--osc-cwd (parts)
  "Track the child's directory, from OSC 7."
  (cooked--set-directory (string-join parts ";")))

(defun cooked--osc-hyperlink (parts)
  "Record the current OSC 8 hyperlink target."
  (setq cooked--hyperlink (let ((uri (string-join (cdr parts) ";")))
                            (unless (string-empty-p uri) uri))))

;;;; OSC 10/11/12 — the default colors
;;
;; Theme-aware programs ask the terminal for its background before choosing a light or
;; dark palette, and a terminal that never answers costs them their whole timeout on
;; every startup.  We are the only ones who can answer: Rust has no default fg/bg at
;; all — `Color::Default' is an unresolved marker — because the real value is whatever
;; the buffer's `default' face resolves to under the user's theme.

(defcustom cooked-allow-color-set nil
  "Whether the child may change this buffer's default foreground and background.

Queries are always answered; this is about OSC 10/11/12 requests that *set* a
color.  Anything that can write to the terminal can send one — a `cat' of a
hostile file, output from a compromised host — so it is off by default, for the
same reason the OSC 51 command channel is a separate file you have to require."
  :type 'boolean
  :group 'cooked)

(defcustom cooked-honor-erase-scrollback nil
  "Whether the child may delete this buffer's scrollback with `CSI 3 J'.

That is xterm's `clear -x' sequence.  Scrollback lives in the Emacs buffer,
not the emulator's grid, on the principle that history is Emacs' to keep or
discard — never the child's; anything that can write to the terminal can send
this sequence, a `cat' of a hostile file included, so honoring it is off by
default, for the same reason `cooked-allow-color-set' is.  `M-x
cooked-clear-scrollback' remains available either way."
  :type 'boolean
  :group 'cooked)

(defvar-local cooked--color-remaps nil
  "Alist of color kind to face remapping cookie, so OSC 110/111/112 can undo a set.")

(defconst cooked--osc-color-sources
  '((10 . foreground) (11 . background) (12 . cursor))
  "Which default color each OSC code asks about.")

(defun cooked--default-color (kind)
  "The color this buffer renders for KIND: foreground, background or cursor.

Falls back through the frame and then to plain black or white.  On a tty frame
the face returns `unspecified-fg'/`unspecified-bg', which `color-values' cannot
read; answering approximately still beats not answering, which is the bug this
exists to fix."
  (let ((color (pcase kind
                 ('foreground (or (face-foreground 'default nil t)
                                  (frame-parameter nil 'foreground-color)))
                 ('background (or (face-background 'default nil t)
                                  (frame-parameter nil 'background-color)))
                 ('cursor (or (frame-parameter nil 'cursor-color)
                              (face-foreground 'default nil t))))))
    (if (and color (color-values color))
        color
      (let ((dark (eq (frame-parameter nil 'background-mode) 'dark)))
        (if (eq kind 'background)
            (if dark "black" "white")
          (if dark "white" "black"))))))

(defun cooked--color-to-osc (color)
  "Format COLOR as xterm's `rgb:RRRR/GGGG/BBBB', 16 bits per channel.
That is exactly what `color-values' returns, so no rescaling is involved."
  (when-let* ((values (color-values color)))
    (apply #'format "rgb:%04x/%04x/%04x" values)))

(defun cooked--parse-osc-color (spec)
  "Turn an X or xterm color SPEC into something Emacs understands, or nil.
Accepts `rgb:R/G/B' with one to four hex digits per channel, `#RGB' forms, and
plain color names."
  (cond
   ((string-match "\\`rgb:\\([0-9a-fA-F]+\\)/\\([0-9a-fA-F]+\\)/\\([0-9a-fA-F]+\\)\\'" spec)
    (let ((parts (list (match-string 1 spec) (match-string 2 spec) (match-string 3 spec))))
      ;; Channels are scaled by width, not padded: "rgb:f/f/f" is white, not #0f0f0f.
      (when (cl-every (lambda (p) (<= 1 (length p) 4)) parts)
        (apply #'format "#%04x%04x%04x"
               (mapcar (lambda (p)
                         (let ((v (string-to-number p 16))
                               (max (1- (ash 1 (* 4 (length p))))))
                           (/ (* v 65535) max)))
                       parts)))))
   ((color-values spec) spec)))

(defun cooked--osc-color (parts)
  "Answer or apply an OSC 10, 11 or 12 request.

A `?' is a query and is answered from the buffer's own faces.  Anything else is
a set, which needs `cooked-allow-color-set'.  Several may be chained — `ESC ] 10
; ? ; ? ST' asks for the foreground and then the background — so each part
advances the code."
  (let ((code cooked--osc-code))
    (dolist (part parts)
      (when-let* ((kind (alist-get code cooked--osc-color-sources)))
        (if (equal part "?")
            (when-let* ((payload (cooked--color-to-osc (cooked--default-color kind))))
              (cooked--reply-osc cooked--session code payload
                                 cooked--osc-bell-terminated))
          (when cooked-allow-color-set
            (cooked--set-default-color kind part))))
      (setq code (1+ code)))))

(defun cooked--set-default-color (kind spec)
  "Remap this buffer's default KIND to SPEC, if it parses.
Buffer-local rather than frame-wide: a child gets to repaint its own terminal,
not every window in the Emacs running it."
  (when-let* ((color (cooked--parse-osc-color spec)))
    (cooked--reset-default-color kind)
    (push (cons kind (pcase kind
                       ('foreground (face-remap-add-relative 'default :foreground color))
                       ('background (face-remap-add-relative 'default :background color))
                       ('cursor (face-remap-add-relative 'cursor :background color))))
          cooked--color-remaps)
    ;; Every cell face resolves against `default', so the memoized ones are stale the
    ;; moment the remap lands.
    (cooked--flush-face-cache)))

(defun cooked--reset-default-color (kind)
  "Drop any OSC 10/11/12 remap of KIND, restoring the theme's own color."
  (when-let* ((cookie (alist-get kind cooked--color-remaps)))
    (face-remap-remove-relative cookie)
    (setq cooked--color-remaps (assq-delete-all kind cooked--color-remaps))
    (cooked--flush-face-cache)))

(defun cooked--osc-color-reset (_parts)
  "Undo an OSC 10/11/12 set, from OSC 110, 111 or 112."
  (when-let* ((kind (alist-get (- cooked--osc-code 100) cooked--osc-color-sources)))
    (cooked--reset-default-color kind)))

;;;; OSC 51 — the child asking Emacs to do something
;;
;; Only the harmless half lives here.  `A' annotates the prompt and is inert, so it
;; costs nothing to support.  `E' is a command channel driven by bytes on the
;; terminal — anything that can write there can pull the trigger: `cat' of a hostile
;; file, output from a compromised host over ssh, a build log quoting text somebody
;; else chose — so it is off until you load `cooked-osc-eval' and say you want it.

(defvar cooked-osc-eval-function nil
  "Function handling the OSC 51;E command channel, called with the payload.

Nil means the channel is closed and requests are ignored.
`cooked-osc-eval' sets it; requiring that file is how you opt in, and the
point of the split is that opting in is something you do on purpose
rather than inherit.")

(defvar-local cooked--eval-refused nil
  "Whether this buffer has already reported an ignored OSC 51;E request.")

(defun cooked--osc-emacs (parts)
  "Handle OSC 51: E asks Emacs to run something, A annotates the prompt."
  (let ((payload (string-join parts ";")))
    (unless (string-empty-p payload)
      (pcase (aref payload 0)
        (?E (cond
             (cooked-osc-eval-function
              (funcall cooked-osc-eval-function (substring payload 1)))
             ;; Once per buffer: silence looks like a bug to someone porting their
             ;; vterm configuration, but a stream can send these as fast as it likes.
             ((not cooked--eval-refused)
              (setq cooked--eval-refused t)
              (message "cooked: ignoring an OSC 51 command; (require 'cooked-osc-eval) to enable"))))
        (?A (setq cooked--annotation (substring payload 1)))
        (_ nil)))))

(defun cooked--discard-scrollback (end)
  "Delete scrollback from `point-min' up to END, and tell the emulator.

The only sanctioned way to delete above `cooked--screen-start', and worth
routing every future caller — a scrollback cap, a `clear' handler — through
rather than open-coding.  The scrollback is the one piece of state the two ends
co-own: Emacs holds the text, while the emulator holds a count of how much of
its top row's line already left for Emacs, so that a rewrap resumes that line
where the buffer wraps it.  A wrapped line can span the boundary being cut, so
a deletion that does not say so leaves the emulator continuing a line that is
no longer there — and the desync is silent until the next resize.

Widens first, so it still clears while a full-screen program has the buffer
narrowed to the alt screen — where `point-min' is the top of the screen and
this would otherwise quietly do nothing."
  (save-restriction
    (widen)
    (let ((inhibit-read-only t))
      (delete-region (point-min) end)))
  (when cooked--session (cooked--forget-history cooked--session)))

(defun cooked-clear-scrollback ()
  "Delete everything above the live screen."
  (interactive)
  (cooked--discard-scrollback (marker-position cooked--screen-start)))

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
      (let ((inhibit-read-only t))
        (cooked--release-alt-pin)
        (delete-region (marker-position cooked--screen-start) (point-max))
        ;; They pointed into the text just deleted; `cooked--restore-pending-input'
        ;; puts them back at the cursor on the drain below.
        (setq cooked--input-start nil cooked--input-end nil)))
    (cooked--redraw cooked--session)
    (cooked--apply (cooked--drain cooked--session cooked-rejoin-wrapped-lines))))

;;;; OSC 52 — clipboard

(defcustom cooked-clipboard-write t
  "Whether the child may put text on the kill ring via OSC 52.
Reads are never answered regardless: replying to a query would hand the
clipboard's contents to any program that asks for them."
  :type 'boolean
  :group 'cooked)

(defcustom cooked-clipboard-max-size 100000
  "Largest OSC 52 payload accepted onto the kill ring, in base64 characters.
Anything writing to the terminal can push to the clipboard, so this bounds how
much of the kill ring a runaway or hostile stream can take over."
  :type 'natnum
  :group 'cooked)

(defun cooked--osc-clipboard (parts)
  "Put the child's OSC 52 selection on the kill ring."
  (let ((data (car (last parts))))
    (when (and cooked-clipboard-write data (not (equal data "?")))
      (if (> (length data) cooked-clipboard-max-size)
          ;; Refuse out loud: a silent drop looks like the copy simply failed.
          (message "cooked: refused a %d-character clipboard write (see `cooked-clipboard-max-size')"
                   (length data))
        (when-let* ((text (ignore-errors (base64-decode-string data t))))
          (kill-new (decode-coding-string text 'utf-8))
          (message "cooked: copied %d characters" (length text)))))))

(defun cooked--set-directory (url)
  "Track the child's directory from an OSC 7 URL."
  (when (string-match "\\`file://[^/]*\\(/.*\\)\\'" url)
    (let ((dir (file-name-as-directory (url-unhex-string (match-string 1 url)))))
      (when (file-directory-p dir)
        (setq default-directory dir)))))

(provide 'cooked)
;;; cooked.el ends here
