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

;; For the `ansi-color-' faces themselves, which were until now reached without
;; loading anything: nothing asked for one until a coloured cell was drawn, and by
;; then a session had pulled in comint and comint had pulled in ansi-color.  The
;; faces are read at load time now -- `cooked--sync-ansi-faces' gives cooked's own
;; the colours before the first row -- so the file that defines them is a real
;; dependency and says so.
(require 'ansi-color)
(require 'color)
(require 'face-remap)
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
so a theme that styles those faces wins.

Setting it through `customize' or `setopt' recolours the text already drawn,
scrollback included, without redrawing anything; see `cooked--sync-ansi-faces'."
  :type '(vector (repeat :inline t string))
  :set (lambda (symbol value)
         (set-default symbol value)
         (when (fboundp 'cooked--sync-ansi-faces)
           (cooked--sync-ansi-faces)))
  :group 'cooked)

(defcustom cooked-bold-is-bright nil
  "Whether bold text in one of the first eight colours is drawn in its bright twin.

Colours 0 to 7 become 8 to 15 when the text is also bold, as xterm does with
its `boldColors' resource: `ESC [ 1 ; 34 m' draws in `ansi-color-bright-blue'
rather than `ansi-color-blue'.  Programs written for terminals that did this
use bold to reach the bright colours, and in a theme whose normal blue is dark
their bold text is otherwise hard to read.  The text stays bold, and a colour
given any other way, from the 256-colour cube or as RGB, is left as it is.

Off by default, since a program that asks for bold blue gets bold blue.
Setting it through `customize' or `setopt' redraws the screens already
running; see `cooked--set-bold-is-bright'."
  :type 'boolean
  :set (lambda (symbol value)
         (set-default symbol value)
         (when (fboundp 'cooked--set-bold-is-bright)
           (cooked--set-bold-is-bright)))
  :group 'cooked)

(defconst cooked--ansi-faces
  [ansi-color-black ansi-color-red ansi-color-green ansi-color-yellow
   ansi-color-blue ansi-color-magenta ansi-color-cyan ansi-color-white
   ansi-color-bright-black ansi-color-bright-red ansi-color-bright-green
   ansi-color-bright-yellow ansi-color-bright-blue ansi-color-bright-magenta
   ansi-color-bright-cyan ansi-color-bright-white]
  "Faces the theme is expected to style, indexed by ANSI color number.")

;; The sixteen indexed colours are worn as named faces rather than written onto the
;; text as strings, and this is where those faces come from.  `cooked--face-build'
;; says what that buys; what it costs is this synchronisation, and the reason it is
;; needed rather than a plain `:inherit ansi-color-red' is that those faces name
;; *both* colours: `ansi-color-red' is `:foreground "red3" :background "red3"', so a
;; cell inheriting it for its foreground would come out on a red background too.
;; ansi-color.el has the same problem and answers it by baking --
;; `ansi-color--face-vec-face' writes `(:background ,(face-background ...))' -- which
;; is exactly what this file is getting away from.  So cooked keeps a face per index
;; per channel, each naming one colour, and follows `ansi-color-' with a
;; `set-face-attribute' rather than with a walk over anybody's buffer.

(defconst cooked--fg-faces
  (vconcat (mapcar (lambda (n) (intern (format "cooked-fg-%d" n))) (number-sequence 0 15)))
  "Faces carrying the foreground of each ANSI colour, indexed by colour number.")

(defconst cooked--bg-faces
  (vconcat (mapcar (lambda (n) (intern (format "cooked-bg-%d" n))) (number-sequence 0 15)))
  "Faces carrying the background of each ANSI colour, indexed by colour number.")

(dotimes (n 16)
  (let ((ansi (aref cooked--ansi-faces n)))
    ;; On the face's own symbol, so that `cooked--notice-face-change' can answer
    ;; "is this one of the sixteen" with a property lookup.  That predicate runs
    ;; after *every* `set-face-attribute' in this Emacs, cooked's or not, so what
    ;; it costs on a miss is what the advice costs everybody: a `cl-position' over
    ;; the vector measured 0.84 us a call against 0.24 for the lookup, which is
    ;; the difference between tripling `set-face-attribute' and not.
    (put ansi 'cooked--ansi-index n)
    (custom-declare-face
     (aref cooked--fg-faces n) '((t))
     (format "Foreground of ANSI colour %d, as text the child printed in it inherits.

Not a face to customize: cooked overwrites its `:foreground' from `%s'
whenever that face moves, and styling that one is how a theme sets this
colour.  It exists because `%s' names a background as well as a
foreground -- both `red3' in the stock definition -- so text cannot simply
inherit it for one channel; see `cooked--sync-ansi-faces'." n ansi ansi)
     :group 'cooked)
    (custom-declare-face
     (aref cooked--bg-faces n) '((t))
     (format "Background of ANSI colour %d, as text the child printed on it inherits.

The mirror of `%s': its `:background' is the *foreground* `%s'
names, which is the colour index %d stands for.  Not a face to customize,
for the reason that one gives." n (aref cooked--fg-faces n) ansi n)
     :group 'cooked)))


(defvar-local cooked--face-cache nil)

(defconst cooked--face-cache-limit 8192
  "Entries `cooked--face-cache' may hold before it is emptied and begun again.

The key is the rendition itself -- foreground, background, attributes and
underline colour -- and truecolor output has no bound on how many of those a
child prints: a `chafa' or `timg' animation names hundreds of new colours a
frame, and every one was remembered for the life of the buffer.  Three
thousand distinct colours were three thousand entries, measured.

Twice what the core keeps live: its rendition table frees an id once 4096 are
in use (`STYLE_TABLE_CAPACITY'), so a face for a rendition no cell names any
more is one nothing will ask for again until the child prints it afresh.
Emptying is the whole policy, as `cooked--cached-bounded' says: a face is a
plist rebuilt in microseconds, and text already carrying one keeps it.")

(defvar-local cooked--style-specs nil
  "Renditions by id, as the core announced them in a drain's `:styles'.

A vector indexed by id, each slot (FG BG UL ATTRS) in `cooked--color''s
spelling, or nil for an id not announced.  Kept for the whole session, because
the core announces an id once and names it by number from then on; an id it
frees and hands out again is announced again, and overwrites its slot.")

(defvar-local cooked--style-faces nil
  "Faces by rendition id, resolved from `cooked--style-specs' as they are needed.

A slot is nil until the id is first drawn, and `none' for a rendition that
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
from here: `cooked-deco.el' requires this file, so this file cannot reach back
into it for a cache to clear.  Adding to this hook is how it says so instead.")

(defun cooked--flush-face-cache (&rest _)
  "Forget resolved colors so a new theme applies to subsequent output.

The rendition faces themselves no longer need this: a cell in one of the
sixteen indexed colours wears `cooked-fg-*' and `cooked-bg-*', and
`cooked--sync-ansi-faces' -- called first, from here -- moves those faces
rather than the text, so the plists in `cooked--face-cache' are as true after a
theme change as before it.  What is still resolved against the colours of the
moment is a shade's blend, which shares this cache under a key naming the two
colours it mixed, and everything `cooked-theme-change-hook' speaks for.  So the
`clrhash' is now for the blends, and the hook is the point.

Nothing colorless needs flushing: `cooked--box-glyph-cache' holds shape bitmaps
that are colorized live at display time, so a theme change leaves them true."
  (cooked--sync-ansi-faces)
  (cooked--dolist-buffers
    (when (hash-table-p cooked--face-cache)
      (clrhash cooked--face-cache))
    (when cooked--style-faces
      (fillarray cooked--style-faces nil))
    (run-hooks 'cooked-theme-change-hook)))

(defvar cooked--ansi-face-stamp nil
  "The ANSI colours `cooked-fg-*' and `cooked-bg-*' were last given, or nil.

A vector of what `cooked--color' answers for indices 0 to 15, in index order,
with `cooked-color-names' itself last.  Global, like the faces it describes.")

(defun cooked--sync-ansi-faces ()
  "Give `cooked-fg-*' and `cooked-bg-*' the colour ANSI index N now resolves to.

This is the whole of following a theme.  Text the child printed in an indexed
colour inherits these two faces and names no colour of its own, so moving them
recolours every character wearing them at once -- the live screen, the
scrollback, a batch that has not been coloured yet, and text copied out of the
buffer into somebody else's -- with no flush, no walk over any buffer and no
row sent again.  Emacs re-realizes faces after a `set-face-attribute' and
redisplays; that is the entire mechanism.

Answers whether anything moved, and touches only the indices that did.  A theme
sets every face whether its colour changes or not, and `set-face-attribute'
discards every realized face on every frame, so a sixteen-way comparison is
well worth making before making sixteen of those.  The first call finds an
empty stamp and sets all sixteen, which is how the faces get their colours at
all."
  (let* ((stamp (or cooked--ansi-face-stamp
                    (setq cooked--ansi-face-stamp (make-vector 17 nil))))
         (moved nil)
         (i 0))
    (while (< i 16)
      (let ((color (cooked--color i)))
        (unless (equal color (aref stamp i))
          (aset stamp i color)
          (setq moved t)
          ;; `unspecified' rather than nil for a colour that resolved to
          ;; nothing: a tty frame answers `unspecified-fg' for a face no theme
          ;; styled, and `set-face-attribute' rejects nil.
          (set-face-attribute (aref cooked--fg-faces i) nil
                              :foreground (or color 'unspecified))
          (set-face-attribute (aref cooked--bg-faces i) nil
                              :background (or color 'unspecified))))
      (setq i (1+ i)))
    (unless (eq cooked-color-names (aref stamp 16))
      (aset stamp 16 cooked-color-names)
      (setq moved t))
    moved))

(defvar cooked--ansi-refresh-timer nil
  "The pending `cooked--sync-ansi-faces' call, or nil.")

(defun cooked--notice-face-change (face &rest _)
  "Follow FACE into `cooked-fg-*' and `cooked-bg-*' soon, if it is an ANSI face.

After `set-face-attribute', which is where `set-face-foreground',
`customize-face' and a theme all end up.  Only a theme runs a hook, so a face
edited any other way -- from an init file, or interactively while picking a
colour -- would otherwise leave cooked's own faces behind.  Deferred to one
idle call, so a theme setting all sixteen faces costs one pass, and that pass
finds the stamp already current when `cooked--flush-face-cache' got there
first.

The test is the `cooked--ansi-index' property rather than a search of
`cooked--ansi-faces', because this runs after every `set-face-attribute' in
this Emacs and almost all of them are somebody else's: one `load-theme' makes
654 of these calls, and a miss has to cost as close to nothing as it can.

This cannot recurse: the faces it sets are not in `cooked--ansi-faces'."
  (when (and (not cooked--ansi-refresh-timer)
             (get face 'cooked--ansi-index))
    (setq cooked--ansi-refresh-timer
          (run-at-time 0 nil (lambda ()
                               (setq cooked--ansi-refresh-timer nil)
                               (cooked--sync-ansi-faces))))))

;; Global advice on a core function, which is the kind of thing a package gets
;; refused upstream for, and it is here because Emacs offers nothing else: there
;; is no face-change hook in 29 or in 32, and the sixteen faces cannot be
;; `:inherit'ed for one channel (see the commentary above `cooked--fg-faces').
;;
;; Doing without it was measured rather than argued.  The alternative is to check
;; the stamp from the places that already run rarely, and the one such place that
;; is not already wired -- a `cooked--wrap-cache' miss -- never fires for this:
;; `cooked--layout-stamp' names the font and the geometry, and a colour change
;; moves neither, so a face edited from an init file or interactively would not be
;; followed at the next miss but never, until a theme or a new frame happened
;; along.  Cooked's own face docstrings tell people that styling `ansi-color-red'
;; is how they set that colour, so "never" is not a trade this can make.  What the
;; advice costs instead is 0.78 us a call before the lookup above, and 0.5 ms over
;; one `load-theme'.  The behaviour it buys is pinned by
;; `cooked-an-ansi-face-edited-outside-a-theme-recolours-the-screen'.
(advice-add 'set-face-attribute :after #'cooked--notice-face-change)

(defvar cooked--theme-redraw-timer nil
  "The pending `cooked--redraw-every-screen' call after a theme change, or nil.")

(defun cooked--bakes-an-indexed-color-p ()
  "Whether any live rendition still writes a themed colour onto the text.

Which is one rendition and no more: SGR 58 with a palette index, whose colour
goes into `:underline (:color ...)'.  A face attribute that takes a colour and
not a face has nowhere to put an inherit, so that one is resolved when it is
drawn and does not follow a theme by itself.  Everything else about a cell
either names a colour the child gave literally -- the 256-colour cube, RGB --
or wears `cooked-fg-*' and `cooked-bg-*' and follows.

A scan of the renditions the core has announced, cheapest where it matters: a
session that has never seen SGR 58, which is nearly all of them, answers nil
after a walk of a vector and costs a theme change nothing."
  (let ((i 0)
        (limit (length cooked--style-specs))
        (found nil))
    (while (and (not found) (< i limit))
      (let ((ul (nth 2 (aref cooked--style-specs i))))
        (when (and (integerp ul) (< ul 16))
          (setq found t)))
      (setq i (1+ i)))
    found))

(defun cooked--theme-changed (&rest _)
  "Follow the new theme, redrawing only the screens that cannot follow it alone.

Almost nothing has to be redrawn.  A cell's colours are `cooked-fg-*' and
`cooked-bg-*', which `cooked--flush-face-cache' moves through
`cooked--sync-ansi-faces', and every character wearing them is recoloured by
redisplay wherever it is -- so the scrollback follows the theme too, which it
never did while colours were written onto the text.

What is left is the one attribute that has to hold a colour rather than a face,
an indexed SGR 58 underline colour; `cooked--bakes-an-indexed-color-p' looks
for it and the redraw is skipped when no buffer has one, which is the ordinary
case.  A shade's blend is the other baked colour and needs no redraw either:
`cooked--reblend-shades' is on `cooked-theme-change-hook' and rewrites it in
place, in the scrollback as well.

The redraw waits for an idle moment, because switching theme is usually two
calls: `load-theme' after `disable-theme' on the old one, or several themes
enabled in a row by an init file.  Each call flushes, which is cheap, and all of
them share one redraw."
  (cooked--flush-face-cache)
  (unless cooked--theme-redraw-timer
    (setq cooked--theme-redraw-timer
          (run-at-time 0 nil (lambda ()
                               (setq cooked--theme-redraw-timer nil)
                               (let ((baked nil))
                                 (cooked--dolist-buffers
                                   (when (cooked--bakes-an-indexed-color-p)
                                     (setq baked t)))
                                 (when baked
                                   (cooked--redraw-every-screen))))))))

;; `enable-theme-functions' arrived in Emacs 29, and `add-hook' on an unbound variable
;; quietly defines it rather than failing — so on 28 this looked fine and did nothing.
(if (boundp 'enable-theme-functions)
    (progn
      (add-hook 'enable-theme-functions #'cooked--theme-changed)
      (add-hook 'disable-theme-functions #'cooked--theme-changed))
  (advice-add 'enable-theme :after #'cooked--theme-changed)
  (advice-add 'disable-theme :after #'cooked--theme-changed))

(defun cooked--set-bold-is-bright ()
  "Draw every screen again under the new `cooked-bold-is-bright'.
The resolved faces are flushed first, since each was built under the old value
and is cached by its rendition alone.

The one colour setting that still costs a redraw, and it is not a colour: it
changes which face a rendition wears -- `cooked-fg-1' becomes `cooked-fg-9' --
rather than what that face is, so the plists have to be built again and put on
the text again.  Rows already in the scrollback keep the mapping they were
drawn under, as they did before."
  (cooked--flush-face-cache)
  (cooked--redraw-every-screen))

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

Plain t whenever there is nothing to say beyond `underlined', so the common
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
uses.  Weight is bold and faint, slant is italic, `:underline' is a whole
sub-protocol of its own, `:strike-through' is SGR 9, `:overline' is SGR 53,
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
cursor blink `eat' drives from a timer is one cell and one overlay; this
would be up to a screenful of text properties.  Terminals from xterm down have
always been allowed to render blink as a static distinction, and that is what
this is: the compromise `cooked--face-build' already makes for conceal, which
paints foreground over background rather than reaching for `invisible'."
  :group 'cooked)

(defface cooked--concealed '((t))
  "Internal: what concealed text on the default background inherits.

Not for customizing, since the buffer remaps it: `cooked--remap-concealed'
gives it a `:foreground' of the background this buffer draws, whatever OSC 11
and DECSCNM have made that.  A face plist cannot say `the colour of the default
background' any other way, and naming the colour itself would freeze it at the
moment the plist was built.

On a text terminal whose colours Emacs does not know, the background is
`unspecified-bg', and concealed text shows anyway.  Emacs draws a foreground
of `unspecified-bg' by turning on reverse video, since that is the only way a
terminal paints text in its own background colour, so a concealed password
comes out as a reversed block with the letters legible in it.  No face hides
text there, because every channel a face has is a colour or an attribute the
terminal draws visibly.  Hiding it would take a `display' of blanks over the
cells, which the renderer does not put on concealed text.  A frame whose
default colours are named, by a theme or its `background-color' parameter,
conceals as intended."
  :group 'cooked)

(defface cooked--concealed-reversed '((t))
  "Internal: what reversed concealed text on the default foreground inherits.

The mirror of `cooked--concealed': remapped to a `:background' of the default
foreground, which inverse video then paints as the glyph over a cell that is
that same colour."
  :group 'cooked)

(defvar-local cooked--concealed-remaps nil
  "The cookies remapping `cooked--concealed' and its reversed twin, or nil.")

(defun cooked--remap-concealed (foreground background)
  "Draw concealed default-coloured text in FOREGROUND and BACKGROUND from now on.

The two are the colours this buffer draws as its defaults, swapped already if
the screen is reversed.  Every concealed cell that inherits the faces follows
at once, including the ones already on the screen, which is why this is a
remap rather than a colour baked into the cell's face: a password prompt's
hidden echo must stay hidden when an OSC 11 set lands after it."
  (mapc #'face-remap-remove-relative cooked--concealed-remaps)
  (setq cooked--concealed-remaps
        (list (face-remap-add-relative 'cooked--concealed :foreground background)
              (face-remap-add-relative 'cooked--concealed-reversed
                                       :background foreground))))

(defconst cooked--attr-face-properties
  `((,cooked--attr-bold :weight bold)
    (,cooked--attr-faint :weight light)
    (,cooked--attr-italic :slant italic)
    (,cooked--attr-strike :strike-through t)
    (,cooked--attr-overline :overline t))
  "SGR attribute bits that map straight onto a face property and a constant value.

The attributes needing more than a constant are handled separately in
`cooked--face-build': underline, whose style and colour are a whole
sub-protocol; conceal, which resolves against the background that was just
computed; and blink, which is an inherited face and so shares one property with
the colours and with conceal.")

(defsubst cooked--attr-p (attrs bit)
  "Whether BIT is set in the ATTRS bitmask."
  (/= 0 (logand attrs bit)))

(eval-and-compile
  (defconst cooked--style-record 16
    "Bytes in one packed style span.  See `Block::push_style' in src/wire.rs.

The stride *is* the format: a reader finds the next span by adding this and
never by decoding a length.  The Rust side asserts the same number, so a field
added to the record on one side without widening it on both desynchronises the
two at the second span of the first styled row, where every later span reads
its neighbour's bytes and the buffer comes out miscoloured with nothing to
point at.

The fields are `u32's at the offsets the constants below name: START and END
as character offsets, then the ids of the span's rendition and link.  They are
available at compile time so that `cooked--do-style-spans' adds literals rather
than look up variables on the render path.")

  (defconst cooked--style-start 0 "Offset of START in a style record.")
  (defconst cooked--style-end 4 "Offset of END in a style record.")
  (defconst cooked--style-id 8 "Offset of the rendition id in a style record.")
  (defconst cooked--style-link 12
    "Offset of the link id in a style record, 0 for none."))

(defun cooked--install-styles (styles)
  "Record STYLES, a drain's `:styles', before anything naming them renders.

Each entry is (ID FG BG UL ATTRS).  A redefined id forgets the face it had,
since the id now names a different rendition.

Which is the one thing deferred styling has to be told about.  The core frees a
rendition id once no cell names it and mints it again for something else -- see
`StyleStore::collect' in src/emu/style.rs -- and a batch of scrollback waiting
to be coloured names its renditions by id, having scrolled off the screen and
so released every id it uses.  So a redefinition pays out everything still owed
before it lands: the batches that referred to the old rendition are coloured
while the id still means it.  Ordinary output never reaches this -- the core
collects only past `STYLE_TABLE_CAPACITY' live renditions -- and an id
re-announced with the rendition it already had is the core reusing a slot for
the same colours, which changes nothing and is worth nothing to flush for."
  (pcase-dolist (`(,id ,fg ,bg ,ul ,attrs) styles)
    (let ((size (length cooked--style-specs)))
      (when (>= id size)
        (let ((grown (max 64 (* 2 (1+ id)))))
          (setq cooked--style-specs
                (vconcat cooked--style-specs (make-vector (- grown size) nil))
                cooked--style-faces
                (vconcat cooked--style-faces
                         (make-vector (- grown (length cooked--style-faces)) nil))))))
    (let ((spec (list fg bg ul attrs))
          (was (aref cooked--style-specs id)))
      (when (and was (not (equal was spec)))
        (cooked--settle-all-styles))
      (aset cooked--style-specs id spec)
      (aset cooked--style-faces id nil))))

(defun cooked--reset-styles ()
  "Forget every rendition id, for a session starting in this buffer.

Anything still owed is paid first, for the reason a redefinition pays it: an
id nothing can resolve any more would leave a deferred batch colourless."
  (cooked--settle-all-styles)
  (setq cooked--style-specs nil
        cooked--style-faces nil))

(defun cooked--style-face-resolve (id)
  "Resolve rendition ID into a face, remembering the answer.

Out of line from `cooked--style-face' because it runs once per id per theme
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

SPEC is (FROM TO FACE LINK STYLES): FROM and TO are bound to the span's START
and END character offsets, FACE to the face its rendition resolves to or nil,
and LINK to its link id or nil.  A span with neither runs nothing.

The one walker for the records, shared by the terminal's renderer and the
comint filter.  It steps by `cooked--style-record' and allocates nothing per
span: resolving a face is an `aref' into `cooked--style-faces'."
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

(defmacro cooked--do-style-links (spec &rest body)
  "Run BODY for each span in the packed style records STYLES that names a link.

SPEC is (FROM TO STYLED LINK STYLES): FROM and TO are bound to the span's
START and END character offsets, LINK to its link id, and STYLED to whether
its rendition resolves to a face -- which is all a link needs to know about
the colour, since it only asks in order to leave a coloured run alone.  A span
with no link runs nothing.

The second walker over the same records, and the reason there are two is that
the two halves of a record now come due at different moments: a batch of
scrollback keeps its faces until somebody displays it -- see
`cooked--settle-styles' -- while its links are hung on the text as it is
inserted, because `cooked-next-link' and the mouse read them off the buffer
without waiting to be shown.  So the render path walks the records for the
link ids alone, which is one `cooked--u32' per span and no property write at
all on the blocks -- nearly all of them -- that carry no link."
  (declare (indent 1) (debug ((symbolp symbolp symbolp symbolp form) body)))
  (pcase-let ((`(,from ,to ,styled ,link ,styles) spec)
              (packed (make-symbol "packed"))
              (i (make-symbol "i"))
              (limit (make-symbol "limit"))
              (linked (make-symbol "link")))
    `(let* ((,packed ,styles)
            (,i 0)
            (,limit (length ,packed)))
       (while (< ,i ,limit)
         (let ((,linked (cooked--u32 ,packed (+ ,i ,cooked--style-link))))
           (unless (= 0 ,linked)
             (let ((,from (cooked--u32 ,packed (+ ,i ,cooked--style-start)))
                   (,to (cooked--u32 ,packed (+ ,i ,cooked--style-end)))
                   (,styled (and (cooked--style-face
                                  (cooked--u32 ,packed (+ ,i ,cooked--style-id)))
                                 t))
                   (,link ,linked))
               ,@body)))
         (setq ,i (+ ,i ,cooked--style-record))))))

;;;; The colours a batch of scrollback owes until somebody looks at it
;;
;; The end-to-end throughput ceiling was never the insert.  A drain's worth of
;; evicted rows arrives as one string and goes into the buffer in one `insert';
;; what it then costs is one `put-text-property' per styled run over text that,
;; under a flood, scrolls past unseen.  On 20k lines of `ls --color'-shaped
;; output that was four fifths of the Emacs-side cost of the whole drain.
;;
;; So the packed records are kept instead of walked: the batch carries them on
;; its own text as `cooked-pending-style', and the faces are put on at the
;; moment redisplay asks for that text and not before.  Three things make that
;; a property rather than a side table of markers.  It is added in the same
;; `add-text-properties' pass as `cooked-scrollback' and the read-only props,
;; so recording the debt costs nothing extra.  It is deleted with the text, so
;; `cooked--trim-scrollback' and `cooked--discard-scrollback' throw the debt
;; away by throwing the text away, which is exactly what a flood wants.  And it
;; needs no per-batch marker, so a session with a hundred batches in flight
;; does not make every insertion walk a hundred markers.
;;
;; What the property does not carry is where the batch begins, which is what the
;; offsets in the records are counted from.  That is read back off the interval
;; the property occupies -- a fresh cons per piece, so two pieces meeting in the
;; buffer are two intervals and never one.  Which holds only as long as no edit
;; splits an interval or eats its front, and that is the one invariant this file
;; asks of the rest: every path that deletes scrollback goes through
;; `cooked--settle-styles' with DOOMED first, so a piece losing part of itself
;; pays the surviving part before it is cut and carries no debt across.  The
;; insertions are all at a batch's edges -- the seam newline
;; `cooked--place-seam' writes and the next batch above it -- and plain `insert'
;; inherits no properties, so neither lands inside one.
;;
;; A batch is not the unit of payment, though, because a batch is not a bounded
;; thing.  One drain's scrollback is one block, and under a flood that is
;; thousands of rows: a `tree -C'-shaped flood at the default
;; `cooked-scrollback-lines' of 10000 leaves a transcript of three batches of
;; some 56000 spans each, and the first jit-lock chunk to touch one of them
;; measured 60 ms against 0.001 ms for a chunk of the same batch once settled.
;; That is the first-view cost, and it was proportional to the flood rather than
;; to the window.  So `cooked--style-pieces' cuts the packed string into pieces
;; of at most `cooked--style-piece-spans' spans, each hung over its own stretch
;; of the batch's text, and a jit-lock chunk pays for the pieces it overlaps and
;; no more.
;;
;; The cuts are at span boundaries and cost two `cooked--u32' reads apiece, not
;; a walk: the records are fixed-width and sorted by START, so the byte index of
;; the 2000th span is arithmetic and the character offset its text begins at is
;; read straight out of it.  Rebasing each piece's offsets to its own start
;; would have meant rewriting every record, which is the very walk the deferral
;; exists to avoid, so a piece carries the offset it was cut at instead and
;; `cooked--settle-styles' recovers the base by subtracting it from where the
;; piece's own interval begins.  That subtraction is also what keeps the base
;; right after a cut: a piece's first span lands on the first character of the
;; piece by construction, whatever has happened to the text above it.

(defvar cooked-lazy-scrollback-styles t
  "Whether a batch of scrollback waits to be displayed before it is coloured.

Non-nil, the default, defers the faces of everything that scrolls off the
screen to the jit-lock pass that runs when the text is first displayed; nil
puts them on as the text is inserted, which is what every version before the
deferral did.  The user-visible answer is identical either way, and there is no
reason to turn this off outside a test that wants to compare the two -- see
`cooked-deferred-and-eager-styling-agree-however-the-flood-is-split', which
feeds one small flood both ways with the drain boundary at every byte of it.

The live screen is not affected: it is on its way to being displayed by
definition, and deferring a row the cursor is on would only pay the walk twice.")

(defvar cooked--style-piece-spans 2000
  "How many style spans one piece of a deferred batch may hold at most.

A batch is one drain's worth of evicted rows and so has no bound but the flood
that made it; a piece is what gets paid for when any part of it is displayed,
so this is what bounds the first-view cost of scrolling into coloured
scrollback.  Settling measures about 0.6 us a span byte-compiled, which puts a
piece at roughly 1.2 ms -- under a frame, with room left for the redisplay that
asked for it.

Smaller is not free: every piece is a text-property interval of its own and a
separate entry to walk in `cooked--settle-styles'.  A variable rather than a
constant only so that a test can ask for pieces it can produce without a flood;
see `cooked-settling-a-chunk-pays-only-for-the-pieces-it-overlaps'.")

(defvar-local cooked--pending-styles 0
  "How many pieces of deferred scrollback in this buffer still owe their faces.

Read to decide whether there is any deferred work at all: whether the jit-lock
pass is worth registering -- see `cooked--sync-fontification' -- and whether
`cooked--settle-styles' need look at the text.  Kept by hand rather than
counted, since counting means walking the whole buffer.

It can only err high, and only by way of something deleting scrollback without
going through `cooked--settle-styles'.  What that costs is a registered hook
with nothing to do, which is why it is a counter and not a list of pieces.")

(defun cooked--style-pieces (packed)
  "Cut PACKED into pieces of at most `cooked--style-piece-spans' spans each.

The answer is (PIECE OFFSET) per piece, in ascending order, PIECE being the
records themselves and OFFSET the character offset into the batch's text at
which the piece's own stretch begins -- zero for the first, so that the pieces
tile the whole batch however far along its first span starts.

The cuts are at span boundaries, so no span belongs to two pieces and a piece's
records are exactly those whose START falls in its stretch.  A span reaching
past its piece's end is left whole rather than clipped: spans do not overlap,
so it writes over text no other piece's records name, whichever order the two
are settled in.

Finding a cut costs two `cooked--u32' reads and no walk.  The records are
fixed-width and sorted by START, so the byte index of the Nth span is
arithmetic, and the character offset its text begins at is that span's own
START.  Two spans can share a START -- a run of no characters -- and the cut is
carried on to the next candidate in that case, an empty stretch of text being
unable to hold the property that would make its piece reachable."
  (let ((limit (length packed))
        (stride (* (max 1 cooked--style-piece-spans) cooked--style-record))
        (pieces nil)
        (from 0)
        (offset 0))
    (while (< from limit)
      (let ((to (min limit (+ from stride))))
        (while (and (< to limit)
                    (<= (cooked--u32 packed (+ to cooked--style-start)) offset))
          (setq to (min limit (+ to stride))))
        (push (list (substring packed from to) offset) pieces)
        (setq from to)
        (when (< to limit)
          (setq offset (cooked--u32 packed (+ to cooked--style-start))))))
    (nreverse pieces)))

(defun cooked--defer-styles (packed)
  "Take PACKED on as a debt of styling, and return the pieces that record it.

The answer is what `cooked--style-pieces' returned, or nil when there is
nothing to defer -- an unstyled batch, or the deferral switched off.  So a
caller reads it as \"is this batch deferred\" as well.

The first piece covers the batch from its very first character and is meant for
the caller's own `add-text-properties' pass, along with the rest of the batch's
properties; `cooked--place-style-pieces' hangs the others over their own
stretches afterwards.

Whether a batch *may* be deferred is the caller's question and not this one's:
`cooked--render-scrolled' keeps a decorated batch eager, and says why.

Each piece is a fresh list.  Fresh because the property functions compare
values with `eq' and the interval is what says where a piece begins: two pieces
sharing a value would read as one."
  (when (and cooked-lazy-scrollback-styles packed (> (length packed) 0))
    (let ((pieces (cooked--style-pieces packed)))
      (setq cooked--pending-styles (+ cooked--pending-styles (length pieces)))
      pieces)))

(defun cooked--place-style-pieces (start end pieces)
  "Hang PIECES over their own stretches of the batch inserted at START..END.

PIECES are the ones past the first, as `cooked--defer-styles' returned them:
the first went on with the rest of the batch's properties and so covers all of
START..END already, and each of these claims the stretch from its own offset to
the next one's -- the last of them to END.

One property write per piece, against the one span-by-span walk the deferral is
there to avoid: a batch of 56000 spans takes twenty-eight of these."
  (while pieces
    (let ((piece (car pieces))
          (next (cadr pieces)))
      (put-text-property (+ start (cadr piece))
                         (if next (+ start (cadr next)) end)
                         'cooked-pending-style piece)
      (setq pieces (cdr pieces)))))

(defun cooked--apply-style-spans (start packed &optional floor ceiling)
  "Put the faces the records in PACKED name on the text they describe at START.

START is where the batch begins; every offset in a record is characters from
there.  FLOOR and CEILING clip the writes to a range of the buffer, for a batch
that is about to lose one end of itself to a deletion: only the part that
survives is worth colouring.

Links are not applied here.  They went on as the text was inserted -- see
`cooked--do-style-links'."
  (cooked--do-style-spans (from to face _link packed)
                          (when face
                            (let ((beg (if floor (max (+ start from) floor) (+ start from)))
                                  (end (if ceiling (min (+ start to) ceiling) (+ start to))))
                              (when (< beg end)
                                (put-text-property beg end 'face face))))))

(defun cooked--pending-style-bounds (pos)
  "The extent of the piece of owed styling POS is inside, as (START . END).

Read off the `cooked-pending-style' interval rather than from a marker, which
is what the piece's own start position has to be recovered from; see the
commentary above."
  (cons (or (previous-single-property-change (1+ pos) 'cooked-pending-style)
            (point-min))
        (or (next-single-property-change pos 'cooked-pending-style)
            (point-max))))

(defun cooked--settle-styles (beg end &optional doomed)
  "Pay the styling every piece of scrollback meeting BEG..END still owes.

The jit-lock pass calls this for the region redisplay asked about, and the
copy path for the region being lifted out, so that text leaving the buffer
carries the colours it would have shown.  A piece is paid whole the first time
any part of it is wanted: it is at most `cooked--style-piece-spans' spans, and
a piece half-coloured would need a second property to say which half.

With DOOMED, BEG..END is about to be deleted.  A piece wholly inside it is then
dropped uncoloured -- which is the whole point of the deferral, and what makes
`cooked--trim-scrollback' free under a flood -- and a piece straddling either
edge is coloured over the part that survives and nothing else.  Both edges can
be one piece's, for a `cooked--discard-scrollback-region' taking one command's
output out of the middle of a piece.

`with-silent-modifications' rather than a bare `inhibit-read-only': scrollback
is read-only text, and a copy or a redisplay must not leave the buffer looking
modified or put an entry in the undo history for a colour.

Widens to look, while leaving BEG..END alone.  A piece's extent is read off the
text and a narrowing would answer with the edge of the accessible portion
instead, which would both colour half a piece and leave the other half holding
a start position that has stopped being one.  A full-screen program narrows the
buffer to its own rectangle, and a copy or a redisplay under one is ordinary."
  (when (and (> cooked--pending-styles 0) (< beg end))
    (save-restriction
      (widen)
      (with-silent-modifications
        (let ((pos beg))
          (while (and pos (< pos end))
            (let ((owed (get-text-property pos 'cooked-pending-style)))
              (if (not owed)
                  (setq pos (next-single-property-change
                             pos 'cooked-pending-style nil end))
                (pcase-let* ((`(,from . ,to) (cooked--pending-style-bounds pos))
                             (`(,packed ,offset) owed)
                             ;; Where the batch's offsets are counted from, which
                             ;; is not this piece's own start unless it is the
                             ;; first: the piece carries the offset it was cut at
                             ;; rather than records rewritten to start at zero.
                             (base (- from offset)))
                  (cond ((not doomed)
                         (cooked--apply-style-spans base packed))
                        (t
                         (when (< from beg)
                           (cooked--apply-style-spans base packed nil beg))
                         (when (< end to)
                           (cooked--apply-style-spans base packed end nil))))
                  ;; A piece that goes with the text needs no property removed:
                  ;; the interval is deleted along with the characters it is on.
                  (unless (and doomed (<= beg from) (<= to end))
                    (remove-text-properties from to '(cooked-pending-style nil)))
                  (setq cooked--pending-styles (max 0 (1- cooked--pending-styles))
                        pos to))))))))))

(defun cooked--settle-all-styles ()
  "Pay every batch of styling this buffer owes, wherever it is.

For the two moments a deferred batch's rendition ids are about to stop meaning
what they meant: an id being reused for another rendition, and the table being
forgotten outright.  Widens, since the answer must not depend on a full-screen
program having narrowed the buffer to its own rectangle."
  (when (> cooked--pending-styles 0)
    (save-restriction
      (widen)
      (cooked--settle-styles (point-min) (point-max)))))

(defun cooked--color-rgb (color)
  "COLOR as a list of three channels from 0.0 to 1.0, or nil if unreadable.

A hex spelling is read here rather than handed to `color-name-to-rgb', which
asks the frame: a frame with few colours -- a tty, or batch -- answers with the
nearest one it has, and a blend of those is not the blend of the colours the
child sent.  Names still go to the frame, having no other source."
  (if (and (stringp color)
           (string-match "\\`#\\(?:[[:xdigit:]]\\{3\\}\\)\\{1,4\\}\\'" color))
      (let* ((digits (/ (1- (length color)) 3))
             (scale (float (1- (ash 1 (* 4 digits))))))
        (mapcar (lambda (i)
                  (/ (string-to-number
                      (substring color (+ 1 (* i digits)) (+ 1 (* (1+ i) digits)))
                      16)
                     scale))
                '(0 1 2)))
    (color-name-to-rgb color)))

(defun cooked--blend (fg bg alpha)
  "FG laid over BG at coverage ALPHA, mixed in linear light, as a hex colour.

What a shade glyph is drawn in -- see `cooked--shade-face' in cooked-deco.el.
The mix is done on light rather than on the sRGB numbers, because that is what
the eye does with a fine stipple of the two: half white and half black averages
to #bcbcbc, and a naive per-channel mix would say #808080, visibly darker than
the ▒ it stands for.  So each channel is decoded from sRGB to linear, mixed, and
encoded back.

A colour `color-name-to-rgb' cannot read -- a tty frame's unspecified pair --
leaves nothing to mix, and the nearer of the two colours stands in."
  (let ((front (cooked--color-rgb fg))
        (back (cooked--color-rgb bg)))
    (if (not (and front back))
        (if (>= alpha 0.5) fg bg)
      (cl-flet ((decode (c) (if (<= c 0.04045)
                                (/ c 12.92)
                              (expt (/ (+ c 0.055) 1.055) 2.4)))
                (encode (l) (if (<= l 0.0031308)
                                (* l 12.92)
                              (- (* 1.055 (expt l (/ 1 2.4))) 0.055))))
        (apply #'format "#%02x%02x%02x"
               (cl-mapcar (lambda (f b)
                            (round (* 255 (encode (+ (* alpha (decode f))
                                                     (* (- 1 alpha) (decode b)))))))
                          front back))))))

(defun cooked--face (fg bg attrs &optional ul)
  "Face plist for FG, BG, the ATTRS bitmask and underline colour UL.

FG, BG and UL are in `cooked--color's spelling: nil, an index, or a list of
R G B.  Memoized per buffer in `cooked--face-cache', so every rendition id that
names the same rendition shares one face, and a theme change flushes them all
with one `clrhash'."
  (cooked--cached-bounded cooked--face-cache cooked--face-cache-limit (list fg bg attrs ul)
    (cooked--face-build fg bg attrs ul)))

(defun cooked--bright-index (fg attrs)
  "FG, moved to its bright twin if `cooked-bold-is-bright' and ATTRS say bold.
Only the first eight palette indices have a twin; a colour from the cube or
given as RGB is returned as it is."
  (if (and cooked-bold-is-bright
           (integerp fg) (< fg 8)
           (cooked--attr-p attrs cooked--attr-bold))
      (+ fg 8)
    fg))

(defsubst cooked--indexed-p (spec)
  "Whether colour SPEC is one of the sixteen faces rather than a literal colour."
  (and (integerp spec) (< spec 16)))

(defun cooked--face-color (face attribute)
  "The ATTRIBUTE colour FACE draws in, resolving `:inherit', or nil for none.

FACE is one of this file's rendition plists, and ATTRIBUTE `:foreground' or
`:background'.  Written out rather than left to `face-attribute', which takes
a face name and signals on an anonymous plist -- so there is no stock way to
ask a plist what colour it comes out as, and every caller that wants the
answer has to follow the inherit chain itself.  There is exactly one step of
chain to follow here: the plist either names the colour or inherits one of
`cooked-fg-*' and `cooked-bg-*', each of which names it outright.

A face this buffer remaps -- `cooked--concealed' and its reversed twin -- is
not resolved, since `face-attribute' does not see a buffer's remaps; the
caller that cares reads the inherit itself.  See `cooked--shade-face'."
  (let ((plist (and (consp face) (keywordp (car face)) face)))
    (or (plist-get plist attribute)
        (let ((inherit (plist-get plist :inherit))
              (color nil))
          (dolist (one (if (listp inherit) inherit (list inherit)) color)
            (unless color
              (let ((value (and (facep one) (face-attribute one attribute nil t))))
                (when (stringp value)
                  (setq color value)))))))))

(defun cooked--face-build (fg bg attrs ul)
  "Build the face plist `cooked--face' memoizes for FG, BG, ATTRS and UL.

A colour from the sixteen-colour palette is worn as a face and not written
down.  Index N comes out as an `:inherit' of `cooked-fg-*' for a foreground
and of `cooked-bg-*' for a background, and those two faces carry whatever the
matching `ansi-color-*' face resolves to at the moment -- see
`cooked--sync-ansi-faces'.  So a theme that restyles the ANSI faces recolours
every character already in the
buffer, the scrollback included, because redisplay merges the inherit afresh
and the text never held the old colour to begin with.  Baking it, which is what
this did and what `ansi-color--face-vec-face' still does, made a theme change a
cache flush plus a redraw of every live screen, and left the scrollback in the
colours of whatever theme was loaded when those rows scrolled off.

The 256-colour cube and RGB stay literal strings, as they do in every other
terminal: the child named an absolute colour and there is no palette entry for
a theme to have an opinion about.  One attribute stays literal that would
rather not: an indexed SGR 58 underline colour, because `:underline' takes a
colour and has nowhere to put a face; `cooked--bakes-an-indexed-color-p' is
what pays for that.

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
         (conceal (cooked--attr-p attrs cooked--attr-conceal))
         (fg* (cooked--bright-index fg attrs))
         (bg* bg)
         (inherit nil)
         (face nil))
    ;; Concealed text is drawn in the colour it sits on.  Which property that is
    ;; depends on reverse video, since an inverse face paints its `:foreground'
    ;; as the background -- so a reversed cell has its background matched to its
    ;; foreground instead.  Copied as a specification rather than as a colour,
    ;; so a concealed cell on an indexed background wears that index's face and
    ;; follows the theme like any other.
    (when conceal
      (if reverse (setq bg* fg*) (setq fg* bg*)))
    (cond ((null fg*))
          ((cooked--indexed-p fg*) (push (aref cooked--fg-faces fg*) inherit))
          (t (setq face (plist-put face :foreground (cooked--color fg*)))))
    (cond ((null bg*))
          ((cooked--indexed-p bg*) (push (aref cooked--bg-faces bg*) inherit))
          (t (setq face (plist-put face :background (cooked--color bg*)))))
    (setq inherit (nreverse inherit))
    (when reverse (setq face (plist-put face :inverse-video t)))
    (pcase-dolist (`(,bit ,property ,value) cooked--attr-face-properties)
      (when (cooked--attr-p attrs bit)
        (setq face (plist-put face property value))))
    (when (cooked--attr-p attrs cooked--attr-underline)
      (setq face (plist-put face :underline (cooked--underline-spec attrs ul))))
    (cond
     (conceal
      ;; A default colour to hide in is not a colour this can name, for the same
      ;; reason reverse video names none: the cache would outlive it.  So the
      ;; face inherits one of two that the buffer remaps to the colours it draws.
      ;; A buffer that has not remapped them yet -- no OSC 10/11 set and no
      ;; DECSCNM, which remap them as they change the colours -- draws the
      ;; theme's own.
      (unless (or (if reverse fg* bg*) cooked--concealed-remaps)
        (cooked--remap-concealed (face-foreground 'default nil t)
                                 (face-background 'default nil t)))
      (unless (if reverse fg* bg*)
        (setq inherit (list (if reverse
                                'cooked--concealed-reversed
                              'cooked--concealed)))))
     ;; Blink is inherited too, and gives way to conceal: `cooked-blink' is a
     ;; visible mark on the cell, and on a concealed cell that mark is the one
     ;; thing SGR 8 was asked to keep quiet -- a box drawn round apparently blank
     ;; text says there is text there.  A hardware terminal blinking a concealed
     ;; glyph shows nothing either, so dropping it is the faithful answer as well
     ;; as the careful one.
     ((cooked--attr-p attrs cooked--attr-blink)
      (setq inherit (append inherit (list 'cooked-blink)))))
    ;; One face inherits as a symbol, several as a list, which is what every
    ;; other producer of face plists writes and what keeps the common case --
    ;; a cell in one colour and nothing else -- a two-element plist.
    (when inherit
      (setq face (plist-put face :inherit
                            (if (cdr inherit) inherit (car inherit)))))
    face))

(defun cooked--sync-ansi-faces-on-new-frame (frame)
  "Resolve the ANSI colours again for FRAME, which has just been created.

`cooked--color' asks the selected frame what an `ansi-color-' face comes out
as, and the answer moves with the frame: a tty knows eight colours where a
graphical frame knows sixteen million, and a daemon started with no frame at
all answers for none.  So a new frame is a reason to look again, which is what
this is -- the whole of it, since the faces are global and there is no text
to touch.

Global is also its limit.  One pair of faces serves every frame, so a session
showing the same buffer on a tty and on a graphical frame draws both in
whichever the newer frame resolved; the colours before this were baked per
buffer at the moment a row was drawn and were no better."
  (when (frame-live-p frame)
    (with-selected-frame frame
      (cooked--sync-ansi-faces))))

(add-hook 'after-make-frame-functions #'cooked--sync-ansi-faces-on-new-frame)

;; And once now, so that the faces have colours before the first row is drawn.
(cooked--sync-ansi-faces)

(provide 'cooked-face)
;;; cooked-face.el ends here
