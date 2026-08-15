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

(defface cooked-blink '((t :overline t))
  "How SGR 5 and SGR 6 \\=(blink and rapid blink) are drawn.

Emacs has no per-character blink attribute, and this is the substitute: a face
blinking text inherits, so the terminal's claim to blink comes out as *some*
visible difference from text that does not.  Restyle it and every blinking cell
in every session follows; set it to nothing at all and blink renders as plain
text again, which is the honest way to turn this off.  It is the whole of the
policy, which is why there is no separate variable saying the same thing twice.

The default is an overline because that is the one channel nothing else here
uses.  Weight is bold and faint, slant is italic, `:underline\=' is a whole
sub-protocol of its own, `:strike-through\=' is SGR 9, and reverse and conceal
both spend the two colours — so any of those would make blinking text
indistinguishable from text carrying the attribute it collided with, which is
the bug this face exists to fix rather than move.

Inherited rather than merged, so anything the rendition itself sets wins: a
blinking cell that also names a foreground gets that foreground, not this
face's.  That is the right way round — the child said the colour, and it only
said *that* it blinks.

There is deliberately no animation.  A hardware terminal blinks because the
glyph generator costs it nothing; here it would cost a buffer-local timer
repainting every blinking cell a couple of times a second, forever, on the path
DESIGN.md's \"The pace is a floor, not a clock\" spends its whole argument
keeping quiet — redisplay work that no child output asked for and that a
buffer left on screen goes on paying while nothing at all is happening.  The
cursor blink `eat\=' drives from a timer is one cell and one overlay; this
would be up to a screenful of text properties.  Terminals from xterm down have
always been allowed to render blink as a static distinction, and that is what
this is: the compromise `cooked--face-build\=' already makes for conceal, which
paints foreground over background rather than reaching for `invisible\='."
  :group 'cooked)

(defconst cooked--attr-face-properties
  `((,cooked--attr-bold :weight bold)
    (,cooked--attr-faint :weight light)
    (,cooked--attr-italic :slant italic)
    (,cooked--attr-blink :inherit cooked-blink)
    (,cooked--attr-strike :strike-through t))
  "SGR attribute bits that map straight onto a face property and a constant value.

The attributes needing more than a constant — underline, whose style and colour
are a whole sub-protocol, and conceal, which resolves against the background
that was just computed — are handled separately in `cooked--face'.")

(defsubst cooked--attr-p (attrs bit)
  "Whether BIT is set in the ATTRS bitmask."
  (/= 0 (logand attrs bit)))

(defconst cooked--color-tag-default 0)
(defconst cooked--color-tag-indexed 1)
(defconst cooked--color-tag-rgb 2)

(defsubst cooked--color-spec (packed i)
  "Decode the four-byte colour field at offset I of PACKED.

Returns what `cooked--color\=' takes: nil for the terminal default, an integer
for a palette index, or a list of R G B.  The encoding is `Color::packed\=' in
src/emu/cell.rs, little-endian, and the two sides must agree on it forever:

  tag 0  default  -- the whole field is zero
  tag 1  indexed  -- the index in bits 0-7
  tag 2  rgb      -- r in bits 16-23, g in 8-15, b in 0-7

The tag is the top byte, so little-endian order puts it at I+3 and the two
common variants never assemble the other three bytes at all.  Only rgb pays for
the full decode, and it is the rare one: palette colours are what shells and
TUIs actually emit."
  (let ((tag (aref packed (+ i 3))))
    (cond ((eq tag cooked--color-tag-default) nil)
          ((eq tag cooked--color-tag-indexed) (aref packed i))
          (t (list (aref packed (+ i 2)) (aref packed (+ i 1)) (aref packed i))))))

(defsubst cooked--color-code (packed i)
  "Cache-key code for the colour field at offset I of PACKED, or nil for rgb.

0 for the terminal default and 1+INDEX for a palette index, so the codes of the
256 palette colours and the default occupy 0-256 and fit in nine bits.  Nil for
an rgb colour, which has 24 bits of value and cannot be squeezed alongside two
more of its kind -- see `cooked--face-key\=' for what that nil is for."
  (let ((tag (aref packed (+ i 3))))
    (cond ((eq tag cooked--color-tag-default) 0)
          ((eq tag cooked--color-tag-indexed) (1+ (aref packed i)))
          (t nil))))

(defun cooked--face-key (fgc bgc ulc attrs)
  "Cache key for colour codes FGC, BGC and ULC with the ATTRS bitmask.

A single fixnum whenever all three codes are non-nil, which is to say whenever
no colour is rgb -- and that is the overwhelmingly common case, since the
palette is what shells and TUIs emit.  Nil when any code is nil, and the caller
falls back to a consed list.

The key exists because building one used to cost more than answering with it.
`cooked--face\=' consed a fresh four-element list per span and looked it up in an
`equal\=' table; 192 lookups on a styled frame measured 0.220 ms that way against
0.049 ms for a fixnum.  Almost none of that is the hash: it is the allocation
and the element-by-element `equal\=' walk, neither of which a fixnum has.

The layout packs into 43 bits -- ATTRS is 16, each code is 9 -- which a 64-bit
Emacs holds in a fixnum with 18 to spare.  On a 32-bit build the shifts spill
into a bignum instead, which is slower but still a perfectly good `equal\=' key,
so nothing here has to check the word size to stay correct.  That is the reason
the fallback below is chosen for rgb rather than for narrow fixnums: the first
is a real limit of the encoding, the second is only a matter of speed."
  (and fgc bgc ulc
       (logior attrs (ash fgc 16) (ash bgc 25) (ash ulc 34))))

(defun cooked--face-packed (packed i)
  "Face plist for the rendition packed at offset I of PACKED.

I points at the FG field of a style record -- see `Block::push_style\=' in
src/lib.rs for the layout, of which this reads the trailing fourteen bytes: FG,
BG and UNDERLINE as four-byte tagged colours, then ATTRS as a `u16\='.

The whole point is that a hit decodes nothing.  The key is built from four
`aref\='s of the two low bytes of each colour field, and the specs the face is
actually built from are decoded only inside the memoized body, on the miss --
which a full-screen repaint takes a few dozen times and then never again.

Memoized per buffer in `cooked--face-cache\=', the same table and the same
lifetime as before, so `cooked--flush-face-cache\=' still reaches every resolved
colour with one `clrhash\=' when the theme changes."
  (let* ((attrs (cooked--u16 packed (+ i 12)))
         (key (or (cooked--face-key (cooked--color-code packed i)
                                    (cooked--color-code packed (+ i 4))
                                    (cooked--color-code packed (+ i 8))
                                    attrs)
                  ;; An rgb colour somewhere in the rendition, so there is no fixnum
                  ;; to be had -- and the key becomes the record's own fourteen
                  ;; rendition bytes -- I points at FG, so that is I through I+14,
                  ;; the four-byte colour triple plus the two of ATTRS -- which is the
                  ;; one thing that always identifies it exactly.  One short unibyte string, compared by `equal' as a
                  ;; memcmp rather than walked.
                  ;;
                  ;; It was a consed list of decoded specs, and that made truecolor
                  ;; the slowest thing in the renderer: a `(list r g b)' per colour
                  ;; field, then a four-element key holding them, then an `equal'
                  ;; hash descending into the nesting -- 14.6us against 2.6us for a
                  ;; palette span, where before the packed format the lists at least
                  ;; arrived ready-made from Rust.  `flood, 20k styled lines' has one
                  ;; truecolor span per line and went from 117ms to 225ms on it.
                  ;; Optimising the palette case is no excuse for pessimising the
                  ;; other one; `ls --color' is not the only thing that emits colour,
                  ;; and a build log full of `38;2' is exactly the flood this path is
                  ;; for.
                  ;; Never `equal' to a fixnum, so the two kinds of key share one
                  ;; table with no chance of colliding -- which is what keeps
                  ;; `cooked--flush-face-cache' a single `clrhash' over everything
                  ;; holding a resolved colour.
                  (substring packed i (+ i 14)))))
    (cooked--cached cooked--face-cache key
      ;; Decoded on the miss only, which a full-screen repaint takes a few dozen
      ;; times and then never again.  The old fallback decoded before it had even
      ;; looked, and then handed the specs to `cooked--face' to build a second key
      ;; out of.
      (cooked--face-build (cooked--color-spec packed i)
                          (cooked--color-spec packed (+ i 4))
                          attrs
                          (cooked--color-spec packed (+ i 8))))))

(defun cooked--face (fg bg attrs &optional ul)
  "Face plist for FG, BG, the ATTRS bitmask and underline colour UL.

FG, BG and UL are in `cooked--color\=''s spelling: nil, an index, or a list of
R G B.  Memoized per buffer.

The entry point for callers holding decoded colours -- tests, and
`cooked--face-packed\=''s rgb fallback.  The render path does not come through
here; it calls `cooked--face-packed\=' and never spells a colour out at all
unless the cache misses.  Both share one table and must therefore agree on the
key for a rendition they can both describe, or the same face would be built
twice and compare non-`eq\=' -- which
`cooked-a-packed-span-and-a-spelled-out-one-share-a-face\=' pins."
  (let ((code (lambda (spec) (cond ((null spec) 0)
                                   ((consp spec) nil)
                                   (t (1+ spec))))))
    (if-let* ((key (cooked--face-key (funcall code fg) (funcall code bg)
                                     (funcall code ul) attrs)))
        (cooked--cached cooked--face-cache key
          (cooked--face-build fg bg attrs ul))
      (cooked--cached cooked--face-cache (list fg bg attrs ul)
        (cooked--face-build fg bg attrs ul)))))

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
      (setq face (plist-put face :foreground (or bg* (face-background 'default))))
      ;; And it outranks blink.  `cooked-blink' is a visible mark on the cell, and
      ;; on a concealed cell that mark is the one thing SGR 8 was asked to keep
      ;; quiet: an overline hanging over apparently blank text says there is text
      ;; there.  A hardware terminal blinking a concealed glyph shows nothing
      ;; either, so dropping it is the faithful answer as well as the careful one.
      (setq face (plist-put face :inherit nil)))
    face))

(provide 'cooked-face)
;;; cooked-face.el ends here
