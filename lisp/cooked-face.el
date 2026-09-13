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
(defconst cooked--attr-overline (ash 1 11)
  "SGR 53, above the underline-style field.  See `Attrs' in src/emu/cell.rs.")

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

(defvar-local cooked--style-specs nil
  "Renditions by id, as the core announced them in a drain\='s `:styles\='.

A vector indexed by id, each slot (FG BG UL ATTRS) in `cooked--color\=''s
spelling, or nil for an id not announced.  Kept for the whole session, because
the core announces an id once and names it by number from then on; an id it
frees and hands out again is announced again, and overwrites its slot.")

(defvar-local cooked--style-faces nil
  "Faces by rendition id, resolved from `cooked--style-specs\=' as they are needed.

A slot is nil until the id is first drawn, and `none\=' for a rendition that
needs no face at all.  Cleared by a theme change, which is what resolves every
rendition again against the new theme without the core having to resend one.")

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
    (when cooked--style-faces
      (fillarray cooked--style-faces nil))
    (run-hooks 'cooked-theme-change-hook)))

;; `enable-theme-functions' arrived in Emacs 29, and `add-hook' on an unbound variable
;; quietly defines it rather than failing — so on 28 this looked fine and did nothing.
(if (boundp 'enable-theme-functions)
    (progn
      (add-hook 'enable-theme-functions #'cooked--flush-face-cache)
      (add-hook 'disable-theme-functions #'cooked--flush-face-cache))
  (advice-add 'enable-theme :after #'cooked--flush-face-cache)
  (advice-add 'disable-theme :after #'cooked--flush-face-cache))

(defun cooked--underline-styles-for (major)
  "The `:underline' styles Emacs MAJOR can draw, indexed by SGR 4:x.

Emacs 30 added `double-line', `dots' and `dashes' beside `line' and `wave', so
from there on every subparameter the Rust side keeps has a rendering of its own:
4:2 is double, 4:3 curly, 4:4 dotted and 4:5 dashed.  Before 30 only `line' and
`wave' exist, and the other three fall back to a plain line rather than being
approximated with overlays or handed a style that Emacs does not know.

A function of the version rather than a test of the running Emacs, so that both
answers can be checked from whichever Emacs runs the tests."
  (if (>= major 30)
      [nil line double-line wave dots dashes]
    [nil line line wave line line]))

(defconst cooked--underline-styles
  (cooked--underline-styles-for emacs-major-version)
  "Emacs `:underline' styles, indexed by the SGR 4:x subparameter.

Chosen once at load time by `cooked--underline-styles-for'; cooked still
supports Emacs 29, which draws fewer styles than 30.")

(defun cooked--underline-spec (attrs ul)
  "The `:underline' value for the ATTRS bitmask with underline colour UL.

Plain t whenever there is nothing to say beyond \='underlined\=', so the common
case produces exactly the face plist it did before styled underlines existed.
A `line' style is never spelled out, for the same reason: it is the default."
  (let ((style (aref cooked--underline-styles
                     (min 5 (ash (logand attrs cooked--attr-underline-style)
                                 (- cooked--attr-underline-shift)))))
        (color (and ul (cooked--color ul))))
    (cond ((and (null color) (memq style '(nil line))) t)
          (t (append (and color (list :color color))
                     (and (not (memq style '(nil line))) (list :style style)))))))

(defface cooked-blink '((t :box (:line-width (-1 . -1))))
  "How SGR 5 and SGR 6 \\=(blink and rapid blink) are drawn.

Emacs has no per-character blink attribute, and this is the substitute: a face
blinking text inherits, so the terminal's claim to blink comes out as *some*
visible difference from text that does not.  Restyle it and every blinking cell
in every session follows; set it to nothing at all and blink renders as plain
text again, which is the honest way to turn this off.  It is the whole of the
policy, which is why there is no separate variable saying the same thing twice.

The default is a hairline box because that is the one channel nothing else here
uses.  Weight is bold and faint, slant is italic, `:underline\=' is a whole
sub-protocol of its own, `:strike-through\=' is SGR 9, `:overline\=' is SGR 53,
and reverse and conceal both spend the two colours — so any of those would make
blinking text indistinguishable from text carrying the attribute it collided
with, which is the bug this face exists to fix rather than move.

The box is drawn inward, which is what the negative widths say: it takes its
pixels from the cells it surrounds rather than adding a column either side, so
a blinking run occupies exactly the width it would unstyled and the grid stays
aligned.  A positive width would push every cell after the run to the right.
One box surrounds each run of identically styled text, not each character, so
a blinking word reads as a framed word.

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
    (,cooked--attr-strike :strike-through t)
    (,cooked--attr-overline :overline t))
  "SGR attribute bits that map straight onto a face property and a constant value.

The attributes needing more than a constant — underline, whose style and colour
are a whole sub-protocol, and conceal, which resolves against the background
that was just computed — are handled separately in `cooked--face'.")

(defsubst cooked--attr-p (attrs bit)
  "Whether BIT is set in the ATTRS bitmask."
  (/= 0 (logand attrs bit)))

(eval-and-compile
  (defconst cooked--style-record 16
    "Bytes in one packed style span.  See `Block::push_style\=' in src/wire.rs.

The stride *is* the format: a reader finds the next span by adding this and
never by decoding a length.  The Rust side asserts the same number, so a field
added to the record on one side without widening it on both desynchronises the
two at the second span of the first styled row, where every later span reads
its neighbour\='s bytes and the buffer comes out miscoloured with nothing to
point at.

The fields are `u32\='s at the offsets the constants below name: START and END
as character offsets, then the ids of the span\='s rendition and link.  They are
available at compile time so that `cooked--do-style-spans\=' adds literals rather
than look up variables on the render path.")

  (defconst cooked--style-start 0 "Offset of START in a style record.")
  (defconst cooked--style-end 4 "Offset of END in a style record.")
  (defconst cooked--style-id 8 "Offset of the rendition id in a style record.")
  (defconst cooked--style-link 12
    "Offset of the link id in a style record, 0 for none."))

(defun cooked--install-styles (styles)
  "Record STYLES, a drain\='s `:styles\=', before anything naming them renders.

Each entry is (ID FG BG UL ATTRS).  A redefined id forgets the face it had,
since the id now names a different rendition."
  (pcase-dolist (`(,id ,fg ,bg ,ul ,attrs) styles)
    (let ((size (length cooked--style-specs)))
      (when (>= id size)
        (let ((grown (max 64 (* 2 (1+ id)))))
          (setq cooked--style-specs
                (vconcat cooked--style-specs (make-vector (- grown size) nil))
                cooked--style-faces
                (vconcat cooked--style-faces
                         (make-vector (- grown (length cooked--style-faces)) nil))))))
    (aset cooked--style-specs id (list fg bg ul attrs))
    (aset cooked--style-faces id nil)))

(defun cooked--reset-styles ()
  "Forget every rendition id, for a session starting in this buffer."
  (setq cooked--style-specs nil
        cooked--style-faces nil))

(defun cooked--style-face-resolve (id)
  "Resolve rendition ID into a face, remembering the answer.

Out of line from `cooked--style-face\=' because it runs once per id per theme
rather than once per span."
  (pcase-let* ((`(,fg ,bg ,ul ,attrs)
                (and (< id (length cooked--style-specs))
                     (aref cooked--style-specs id)))
               (face (and attrs (cooked--face fg bg attrs ul))))
    (when (< id (length cooked--style-faces))
      (aset cooked--style-faces id (or face 'none)))
    face))

(defsubst cooked--style-face (id)
  "The face rendition ID is drawn in, or nil for none."
  (let ((face (and (< id (length cooked--style-faces))
                   (aref cooked--style-faces id))))
    (cond ((eq face 'none) nil)
          (face)
          (t (cooked--style-face-resolve id)))))

(defmacro cooked--do-style-spans (spec &rest body)
  "Run BODY for each span in the packed style records STYLES.

SPEC is (FROM TO FACE LINK STYLES): FROM and TO are bound to the span\='s START
and END character offsets, FACE to the face its rendition resolves to or nil,
and LINK to its link id or nil.  A span with neither runs nothing.

The one walker for the records, shared by the terminal\='s renderer and the
comint filter.  It steps by `cooked--style-record\=' and allocates nothing per
span: resolving a face is an `aref\=' into `cooked--style-faces\='."
  (declare (indent 1) (debug ((symbolp symbolp symbolp symbolp form) body)))
  (pcase-let ((`(,from ,to ,face ,link ,styles) spec)
              (packed (make-symbol "packed"))
              (i (make-symbol "i"))
              (limit (make-symbol "limit"))
              (resolved (make-symbol "face"))
              (linked (make-symbol "link")))
    `(let* ((,packed ,styles)
            (,i 0)
            (,limit (length ,packed)))
       (while (< ,i ,limit)
         (let ((,resolved (cooked--style-face
                           (cooked--u32 ,packed (+ ,i ,cooked--style-id))))
               (,linked (cooked--u32 ,packed (+ ,i ,cooked--style-link))))
           (when (or ,resolved (/= ,linked 0))
             (let ((,from (cooked--u32 ,packed (+ ,i ,cooked--style-start)))
                   (,to (cooked--u32 ,packed (+ ,i ,cooked--style-end)))
                   (,face ,resolved)
                   (,link (and (/= ,linked 0) ,linked)))
               ,@body)))
         (setq ,i (+ ,i ,cooked--style-record))))))

(defun cooked--face (fg bg attrs &optional ul)
  "Face plist for FG, BG, the ATTRS bitmask and underline colour UL.

FG, BG and UL are in `cooked--color\='s spelling: nil, an index, or a list of
R G B.  Memoized per buffer in `cooked--face-cache\=', so every rendition id that
names the same rendition shares one face, and a theme change flushes them all
with one `clrhash\='."
  (cooked--cached cooked--face-cache (list fg bg attrs ul)
    (cooked--face-build fg bg attrs ul)))

(defun cooked--face-build (fg bg attrs ul)
  "Build the face plist `cooked--face' memoizes for FG, BG, ATTRS and UL.

Reverse video is `:inverse-video', with the colours left where the child put
them, and not a swap done here.  A swap can only exchange what it is given, and
for text in the default colours that is two nils: the face named no colour at
all, so SGR 7 drew plain text and `smso' stood out from nothing.  Resolving the
nils here instead would bake in the colours of the moment, and a face in
`cooked--face-cache' outlives them -- an OSC 11 set, a theme change or DECSCNM
would each leave reversed text in the old pair.  Emacs swaps an inverse face
after merging it with `default' as this buffer remaps it, so the one attribute
follows all three with nothing to invalidate.  Under DECSCNM that makes
reversed text read as normal video, which is what xterm does.  This was checked
by its pixels in a headless pgtk frame, and a cell with colours of its own
still comes out with the two exchanged."
  (let* ((reverse (cooked--attr-p attrs cooked--attr-reverse))
         (fg* (cooked--color fg))
         (bg* (cooked--color bg))
         (face nil))
    (when fg* (setq face (plist-put face :foreground fg*)))
    (when bg* (setq face (plist-put face :background bg*)))
    (when reverse (setq face (plist-put face :inverse-video t)))
    (pcase-dolist (`(,bit ,property ,value) cooked--attr-face-properties)
      (when (cooked--attr-p attrs bit)
        (setq face (plist-put face property value))))
    (when (cooked--attr-p attrs cooked--attr-underline)
      (setq face (plist-put face :underline (cooked--underline-spec attrs ul))))
    ;; Last, and after the colour it overrides: concealed text is drawn in the
    ;; colour it sits on.  Which property that is depends on reverse video, since
    ;; an inverse face paints its `:foreground' as the background -- so a
    ;; reversed cell has its `:background' matched to its foreground instead.
    (when (cooked--attr-p attrs cooked--attr-conceal)
      (setq face (if reverse
                     (plist-put face :background (or fg* (face-foreground 'default)))
                   (plist-put face :foreground (or bg* (face-background 'default)))))
      ;; And it outranks blink.  `cooked-blink' is a visible mark on the cell, and
      ;; on a concealed cell that mark is the one thing SGR 8 was asked to keep
      ;; quiet: a box drawn round apparently blank text says there is text
      ;; there.  A hardware terminal blinking a concealed glyph shows nothing
      ;; either, so dropping it is the faithful answer as well as the careful one.
      (setq face (plist-put face :inherit nil)))
    face))

(provide 'cooked-face)
;;; cooked-face.el ends here
