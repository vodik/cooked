;;; cooked-guard.el --- Keeping a screen row to one screen line -*- lexical-binding: t; -*-

;;; Commentary:

;; The grid budgets every character a whole number of cells, and a font is free
;; to disagree.  When it does, a live row renders wider than the window and Emacs
;; softwraps it, which is never legitimate output.  `cooked--guard-row-width' is
;; the one place that notices: it measures the row against Emacs' own layout,
;; scales a glyph that does not fit its cells, and trims the row with a
;; truncation mark as the last resort.
;;
;; It sits on cooked-state.el and is called by the row renderer in
;; cooked-screen.el; nothing here reaches further up.

;;; Code:

(require 'cl-lib)
(require 'cooked-util)
(require 'cooked-state)

(defconst cooked--fixed-pitch-probe
  (concat (apply #'string (number-sequence ?\s ?~))
          " -> => == != <= >= :: // <> |> === !== <-> ... >>= <<= "
          "&& || ++ -- ** /* */ www fi ff ffi")
  "The text `cooked--ascii-fixed-pitch-p' measures a font with.

Every printable ASCII character, so nothing in the range is measured by proxy,
followed by the sequences a programming font ligates.  The ligatures are there
because they are the case the answer is *about*: a shaper hands `->' to the
font as one glyph, and if that glyph were wider than the two cells the two
characters occupy, a row of them would render wider than the grid said and
softwrap.  Written out as literal pairs rather than generated, because what is
being asked is a question about specific glyphs a specific font may or may not
have.")

(defcustom cooked-wrap-cache-limit 4096
  "How many rows `cooked--wrap-memo' remembers before it starts over.

Not an eviction policy -- there is no ordering here to evict by -- but a bound.
The memo is keyed by row text, and a buffer whose every row is different (a log
scrolling past, a file being catted) would otherwise accumulate one entry per
row rendered for as long as the session lives, none of which will ever be asked
about again.  Four thousand is many screenfuls of a full-height frame, so the
repeating rows this exists for -- a border, a status line, a table rule -- are
never the ones a reset loses, and the whole table is a few hundred kilobytes at
its largest.  Reached, it is cleared outright rather than halved: a wrong guess
about which entries were worth keeping costs a `vertical-motion' apiece, and
cheap-and-obvious beats clever here.

Raise it for a session that spends most of its life full-screen in a program
whose redraws revisit more distinct rows than the default holds -- a wider
terminal or a busier TUI -- at the cost of a larger table between resets;
lower it to make a reset cheaper at the cost of more memo misses."
  :type 'natnum
  :group 'cooked)

(defvar-local cooked--wrap-memo nil
  "This buffer's memo of which rows Emacs lays out on one screen line.

(STAMP FIXED-PITCH . TABLE), rebuilt from scratch whenever STAMP moves.

TABLE maps a row's layout hash to t when Emacs was seen to lay that row out on
a single screen line.  Only that direction is recorded *here*, and the
asymmetry is the whole safety argument for keying on a hash.  A colliding
\"this does not wrap\" costs a row that softwraps until something rewrites it.
A colliding \"this wraps\" would delete characters off a row that fits, which
is the failure this guard exists to avoid -- so no hash is ever allowed to say
it.

A row that did wrap is remembered too, but in a table of its own and under a
key that cannot collide: see `cooked--wrap-cache' for the TRIMS table and
`cooked--fit-row' for what reads it.

The key is the drain's layout hash, which folds in the renditions that change
the font as well as the text; a caller with no hash gets the same question
asked of the buffer by `cooked--wrap-fallback-key'.  So two rows of identical
text in different faces -- a bold face whose font is not the same width as the
regular one -- are two entries on both paths.

FIXED-PITCH is `cooked--ascii-fixed-pitch-p' for the font STAMP names, held
here because it is a per-font question with a per-font answer and this is
already the thing that notices the font moving.

STAMP is `cooked--layout-stamp'.")

(defun cooked--layout-stamp (window)
  "Everything about WINDOW that can change what Emacs' layout makes of a row.

The memo's validity, stated as a value rather than as a hook.  The events that
matter are a font change, a face remap (`text-scale-adjust' is one), a change
in how much room the text area has, and a change of `line-spacing'; each of
them moves one of these six values, and nothing else here is expected to.

`line-spacing' does not move where a row wraps.  It is here because a moving
stamp also says every row on screen was rendered for a layout that has gone, and
`cooked--wrap-cache' has the core send them all again: a box-drawing bitmap is
placed on the line box, which `line-spacing' changes, and a row the child does
not repaint would otherwise keep the old placement.

Observed rather than notified, which is a deliberate choice against hanging
this off `cooked--rescale-deco' -- the other place in this package that reacts
to the font moving.  A notification only invalidates for the events somebody
remembered to connect: `cooked--rescale-deco' is reached by a cell-size change
and by a zoom, and would not be reached by a window losing a fringe, gaining a
margin, or being dragged a pixel narrower -- all of which change where a row
wraps.  Comparing the stamp cannot miss an event it was not told about; it can
only be too conservative, and being too conservative here costs one rebuilt
hash table.

Five of the six are cheap accessors, none of which selects a window.  The
`font' frame parameter is the expensive one and is here anyway: it names the
font outright, where the rest only describe its metrics, so without it a font
swapped for another of exactly the same cell size would leave the memo answering
for the outgoing font.

Reading it costs about 21us on pgtk, which is more than everything else here put
together and too much to pay per row.  So the stamp is built once per drain, in
`cooked--render-rows', and threaded in by way of `cooked--wrap-cache', where
the same read is small against the cost of the drain.  A caller that has not
threaded it is answered per row, correctly and slowly.

`window-body-width' in pixels rather than in columns: the column form divides
by the frame's character width, so a font change and a resize can cancel out in
it, and a fringe or margin change does not move it at all."
  (let ((frame (window-frame window)))
    (list (window-body-width window t)
          (frame-char-width frame)
          (frame-char-height frame)
          (frame-parameter frame 'font)
          face-remapping-alist
          line-spacing)))

(defconst cooked--string-pixel-width-takes-buffer
  (let ((most (cdr (func-arity #'string-pixel-width))))
    (and (integerp most) (>= most 2)))
  "Whether `string-pixel-width' can be told which buffer to measure as.
Asked once, here, rather than per call: it is a question about which Emacs this
is -- the argument arrived in Emacs 30 -- and the answer cannot change while one
is running.  See `cooked--string-pixel-width'.")

(defun cooked--string-pixel-width (string)
  "The width STRING renders at, in pixels, as this buffer would render it.

`string-pixel-width' measures in a work buffer of its own, and only from
Emacs 30 can it be told to inherit a buffer's `face-remapping-alist'.  Where it
cannot, a buffer under `text-scale-adjust' or `buffer-face-mode' is measured
unscaled -- which disagrees with the cell size its window reports, so
`cooked--ascii-fixed-pitch-p' concludes the font is not fixed pitch and the
rows go through the full probe.  That is the safe direction to be wrong in, and
it is wrong only on Emacs 29 and only while a remap is in force."
  (if cooked--string-pixel-width-takes-buffer
      (string-pixel-width string (current-buffer))
    (string-pixel-width string)))

(defun cooked--ascii-fixed-pitch-p (window)
  "Whether plain ASCII in WINDOW occupies exactly one cell per character.

The question that licenses `cooked--guard-row-width' to skip a row outright.
Asked of the font in force rather than of the row, because it is a property of
the font: the answer is the same for every ASCII row until the font changes,
and `cooked--wrap-memo' is what holds it in between.

A terminal frame has no shaping engine and no per-face fonts, so ASCII there is
one cell per character by construction and nothing is measured.

On a graphical frame the probe is `cooked--fixed-pitch-probe' measured against
the cell width, in each of the faces cooked's own renditions can put a row into
-- default, bold, light and italic, and `cooked-blink', which is the whole of
what `cooked--attr-face-properties' varies that a font could answer with
different metrics.

`cooked-blink' is in that list because it is the one *named* face a rendition
can pull in: SGR 5 inherits it, and its docstring invites a user to restyle it,
which includes giving it a family.  The rest of what `cooked--face' builds is
colours, an underline, a strike and an overline, none of which moves a glyph.
The two concealed faces are not probed: the buffer remaps them, and it remaps
them to a colour.

Ligatures are not the hazard they look like.  A monospace font draws `->' as
one glyph inside the two cells its characters already occupy -- that is what
makes it monospace -- and this guard only ever trims a row that renders *wider*
than nominal.  Across Noto Sans Mono, Iosevka Fixed and Adwaita Mono, every
ligature sequence in the probe rendered at its nominal width.

The real hazard is a face whose font is not fixed pitch at all:
`buffer-face-mode', a `:family' on the default face, or a fallback font
chosen for a character the primary font lacks.  ASCII in a proportional face
such as Iosevka Aile is wider than the grid assumed, exactly as a mismeasured
wide character is, and that is what this measures."
  (or (not (display-graphic-p (window-frame window)))
      (let ((cell (window-font-width window))
            (chars (length cooked--fixed-pitch-probe)))
        (and (> cell 0)
             (cl-every
              (lambda (face)
                (= (cooked--string-pixel-width
                    (propertize cooked--fixed-pitch-probe 'face face))
                   (* cell chars)))
              '(default (:weight bold) (:weight light) (:slant italic)
                (:inherit cooked-blink)))))))

(defun cooked--wrap-cache (window)
  "This buffer's layout cache for WINDOW, rebuilt when the layout moves.

The value is (FIXED-PITCH WRAPS METRICS TRIMS).

The whole of `cooked--wrap-memo''s invalidation: one comparison against
`cooked--layout-stamp', and a new table and a fresh font probe when it
differs.  Nothing is invalidated piecemeal, because nothing here outlives the
font it was measured under.

WRAPS memoises which rows Emacs lays out on one line, METRICS what a cluster
actually measures, and TRIMS how many characters a row that did *not* fit was
cut back to.  They share one cache because the same events invalidate all
three, and because the stamp is the expensive part: a second cache with a
second stamp would cost more than any table saves.

TRIMS is keyed by `cooked--wrap-fallback-key', the row's own text and faces,
and not by the layout hash WRAPS uses.  An entry there deletes characters, so
its key has to be the row and not a digest of it; a row that wraps is rare
enough that copying it out of the buffer is cheap next to the layout queries
the entry saves.

The rows already on screen were measured, scaled and trimmed under the stamp
that has just gone, so a move also has the core send every row again with
`cooked--redraw-live-rows'.  Otherwise the copy of the screen the core keeps
would leave them out: a zoom that keeps the grid size, followed by a program
repainting the same cells, would keep every CJK character on screen scaled for
the old font.  The rows are damaged rather than only forgotten, for a screen
nothing repaints, and they arrive with the next drain rather than this one,
which is already rendering.  Not on the first stamp a buffer builds, which has
no earlier layout to disagree with."
  (let ((stamp (cooked--layout-stamp window)))
    (if (equal (car cooked--wrap-memo) stamp)
        (cdr cooked--wrap-memo)
      (when cooked--wrap-memo
        (cooked--redraw-live-rows))
      (cdr (setq cooked--wrap-memo
                 (cons stamp
                       (list (cooked--ascii-fixed-pitch-p window)
                             (make-hash-table :test #'equal :size 64)
                             (make-hash-table :test #'equal :size 64)
                             (make-hash-table :test #'equal :size 16))))))))

(defun cooked--row-mismeasured-p (width uniform fixed-pitch)
  "Whether a row is one Emacs may render wider than Rust assumed.

WIDTH is how many cells the row occupies on the grid, which the drain carries
alongside the text -- see `Block::push_runs' in src/wire.rs -- and is always
supplied: `cooked--render-rows' is the only caller, and a block always has
one.  A row already wider than `cooked--cols' is genuinely long, scrollback
from a wider grid predating a resize, and should soft-wrap rather than be
trimmed.

Compared against `cooked--cols' rather than a fresh
`window-max-chars-per-line': the two agree only once `cooked--sync-size' has
caught up with the window's pixel geometry, and a wake-driven drain can land in
the gap during a resize drag.  There the row was rendered against the old width
while a fresh measurement already answers for the new one, which reads an
ordinary render as a too-wide row and waves it through to a silent, unmarked
soft-wrap.

UNIFORM says nothing in the row can come out wider than a byte-per-column
reading of it, as the caller has already resolved the drain's flag: every
character is one byte on one cell, or the ones that are not are box glyphs
cooked is drawing as bitmaps of exactly one cell -- see `cooked--render-rows'.
It is not \"is ASCII\": a run of ASCII declared a different width by `OSC 66'
fails it just the same.  FIXED-PITCH is
`cooked--ascii-fixed-pitch-p' for the font in force.  Together they are the
one case that can be answered without asking Emacs' layout anything at all: a
uniform row in a font that renders ASCII one cell per character cannot come out
wider than the grid said, on a graphical frame or a terminal one.  See
`cooked--ascii-fixed-pitch-p' for why a ligature is not a counterexample and a
proportional face is."
  (and (<= width cooked--cols)
       (not (and uniform fixed-pitch))))

(defun cooked--wrap-fallback-key (start end)
  "A memo key for the row START..END, for a caller with no layout hash.

The row's text and the faces laid over it, which is as much of `BlockRow::hash'
in src/wire.rs as Lisp can read back out of the buffer: that hash folds in the
renditions that change the font, and text alone would answer for a row Emacs
lays out differently because a face put it in another one.  The cost of being
wrong is the cosmetic half of the pair `cooked--wrap-memo' describes -- a row
that softwraps until something rewrites it -- but it costs nothing to be right
here, on the path that has already given up on the hash.

The faces and not every property: a `display' or a link says nothing about the
metrics of the text under it, and keying on them would only cost misses.  The
runs carry their offsets, so the same faces in another arrangement are another
key."
  (let ((runs nil)
        (pos start))
    (while (< pos end)
      (push (cons (- pos start) (get-text-property pos 'face)) runs)
      (setq pos (next-single-property-change pos 'face nil end)))
    (cons (buffer-substring-no-properties start end) (nreverse runs))))

(defun cooked--row-wraps-p (start end window memo &optional key)
  "Whether Emacs lays the row START..END out on more than one screen line.

The one question about a row that cannot be answered anywhere but here.  Rust
knows what it put on the grid and how wide the cells are -- Emacs tells it, see
`cooked--sync-size' -- but not which of those characters this font will
compose into one grapheme, which it will substitute another font for, or what
that substitute's metrics are.  So this stays a `vertical-motion' in Emacs'
own layout, and the work is in not asking it twice.

MEMO is `cooked--wrap-cache''s table for the font and geometry in force; nil
skips the memo entirely.  A hit is a row whose text was laid out on one line
under this very stamp, and nothing but the text, the font and the width decides
that -- so the answer stands until the stamp moves, which is when the table is
thrown away.

The row that motivates the memo is a border: a few hundred identical
box-drawing characters, rewritten by a full-screen program on every frame it
paints, and laying out the same way every time.  `vertical-motion' over a row
of box glyphs is most of what the guard costs per row, and across a whole
screen of them it adds up to more than a 60Hz frame.

Only the negative is stored here; see `cooked--wrap-memo' for why that is also
the safety argument, and `cooked--fit-row' for where the positive goes.

KEY is the row's layout hash from the drain's row table -- its text and the
renditions that change its font, see `BlockRow::hash' in src/wire.rs -- so a
row is looked up without being copied out of the buffer.  The row has just been
written from that very text, so the hash describes what `vertical-motion' is
about to measure.  Without one, as for a row driven from Lisp,
`cooked--wrap-fallback-key' reads the same question off the buffer."
  (let ((key (and memo (or key (cooked--wrap-fallback-key start end)))))
    (unless (and key (gethash key memo))
      (let ((wraps (save-excursion
                     (goto-char start)
                     (vertical-motion 1 window)
                     (< (point) end))))
        (when (and key (not wraps))
          ;; Bounded, not evicted: see `cooked-wrap-cache-limit'.
          (when (> (hash-table-count memo) cooked-wrap-cache-limit)
            (clrhash memo))
          (puthash key t memo))
        wraps))))

(defun cooked--trim-to-one-line (start window)
  "Delete characters from the end of the row at START until it stops wrapping.

WINDOW is the window whose layout decides what wrapping means; it is passed
through to `vertical-motion', and nil there means the selected window.  See
`cooked--guard-row-width', the only caller, for why that choice matters.

Returns non-nil if anything went.  Rarely more than a character or two, since
the mismatch is usually a column.

`line-end-position' is captured before each `vertical-motion' and never after:
taken after, it measures the end of whatever line the motion landed on rather
than this row's own end, so a row that does not wrap at all still reads as short
of it -- and the loop then eats the newline above START and the row below."
  (let (trimmed eol)
    (while (progn (goto-char start)
                  (setq eol (line-end-position))
                  (vertical-motion 1 window)
                  (< (point) eol))
      (setq trimmed t)
      (delete-region (1- eol) eol))
    trimmed))

(defun cooked--fit-row (start end window memo trims hash)
  "Cut the row START..END back to one screen line, if Emacs lays it out on more.

Returns non-nil when characters were deleted.

The three answers, cheapest first.  MEMO says the row was seen to fit, by HASH,
and nothing is asked.  TRIMS says this very row was cut before, and to how many
characters, and it is cut to that again with nothing measured.  Only a row
neither table knows reaches `vertical-motion', and the trim loop after it.

TRIMS is what keeps a row that never fits from being expensive for ever.  A
status bar carrying an icon the font draws two cells wide is repainted on every
frame of a full-screen program, and without the table each repaint paid one
layout query to learn that it wraps and one more per character deleted to learn
where it stops -- the same answer every time, to the same row under the same
font.

The key is `cooked--wrap-fallback-key', read off the row as it stands: after
`cooked--scale-offenders', which the caller runs first, and before anything is
deleted, so the row that is looked up is the row that was recorded.  See
`cooked--wrap-cache' for why this table may not be keyed by HASH.  The stamp
that guards MEMO guards this too, so an entry never outlives the font or the
width it was measured under.

WINDOW is the window whose layout decides what wrapping means, as for
`cooked--row-wraps-p'.  With TRIMS nil nothing is remembered, and every
wrapping row is measured."
  (let* ((exact (and trims
                     (not (and memo hash (gethash hash memo)))
                     (cooked--wrap-fallback-key start end)))
         (kept (and exact (gethash exact trims))))
    (cond ((and kept (< (+ start kept) end))
           (delete-region (+ start kept) end)
           t)
          ((and (cooked--row-wraps-p start end window memo hash)
                (cooked--trim-to-one-line start window))
           (when exact
             ;; Bounded as the other two tables are; see `cooked-wrap-cache-limit'.
             (when (> (hash-table-count trims) cooked-wrap-cache-limit)
               (clrhash trims))
             (goto-char start)
             (puthash exact (- (line-end-position) start) trims))
           t))))

(defcustom cooked-glyph-scale-floor 0.5
  "How far a glyph may be shrunk to make it fit its cell, or nil not to shrink.

The grid budgets a character a whole number of cells, and a font is free to
disagree.  Iosevka draws its arrows and geometric shapes at *twice* its cell
width, so a row of btop carrying one is a cell too wide and every column after
it is out of line.  Without this cooked answers by deleting characters off the
end of the row and drawing a truncation arrow -- it notices the problem and
destroys the overflow.  With it, the offending glyph is scaled down instead and
the row keeps its text.

*A clamp, not a threshold.*  A glyph needing a smaller scale than this is shrunk
to exactly this and left slightly over its cell, rather than being refused.  An
exactly-double-width arrow wants 0.5, which quantizes just under 0.5, so a
floor read as a threshold would refuse the one glyph the mechanism exists for.
Where the clamp leaves a glyph a little over, a slightly wide character beats
an illegible one.

There is a floor at all because below it scaling stops being a repair and
starts being a hiding place: a character rendered at a third of its size is
worse than a truncation arrow saying plainly that something did not fit.

*nil turns scaling off* -- no measuring, no scaling, and the trim as the only
answer.  Worth reaching for if a font of yours renders worse with this on than
without: the scaling only touches a glyph whose measured size disagrees with
its cells, but that judgement rests on font metrics, and a font can always
surprise it.

Setting it through `customize' or `setopt' redraws the screens already
running; see `cooked--set-rendering-option'."
  :type '(choice (const :tag "Never scale, only trim" nil)
                 (number :tag "Smallest scale a glyph may be shrunk to"))
  :set #'cooked--set-rendering-option
  :group 'cooked)

(defun cooked--glyph-metrics (beg end window metrics)
  "What the cluster in BEG..END actually measures, as (WIDTH ASCENT DESCENT PIXEL).

Memoised in METRICS, `cooked--wrap-memo's third slot, first by face and then
by the cluster's own character or text -- so a border row of five hundred
identical characters is one measurement and four hundred and ninety-nine hash
lookups that allocate nothing, while the same character in bold is measured
again, which it must be: a bold face is a
different font and so a different glyph with different metrics.  The cache is
a prerequisite rather than an optimisation: without one this is a `font-at'
and a shaping call per cell per drain.

The shaping is asked for the way the display engine asks: a composition if there
is one -- `find-composition' answers for a ligature or a base plus combining
marks, and its gstring is what will actually be drawn -- and otherwise a gstring
shaped from the font at BEG.  Measuring the characters separately would answer a
question nobody is rendering.

Two indices that are easy to get wrong and silent when they are.  The glyph sits
at index *2* of the gstring, not 1.  And the font's own metrics come from
`query-font' -- pixel size 2, ascent 4, descent 5 -- not from `font-info',
which is a different vector whose slots 4 and 5 are a baseline offset and a
compose rule, and which therefore answers 0 for both without complaining.

A cluster that cannot be measured is remembered as nil, rather than asked about
again on every drain: `font-at' has no font for a character nothing covers,
and a cache that only held answers would shape that cluster once per cell per
drain for as long as it stayed on screen.

Bounded like `cooked--wrap-memo', by `cooked-wrap-cache-limit' measurements
across every face, and emptied outright past it.  The key has a face in it, and
a truecolour stream hands out a new face for nearly every run it colours:
`lolcat' over a file of CJK text is one entry per distinct colour and
character, and nothing but a font change would otherwise ever drop one."
  (let* ((face (get-text-property beg 'face))
         (table (gethash face metrics))
         ;; The character itself for the one-character cluster the scale walk
         ;; always asks about, so a hit allocates nothing; the text otherwise.
         (key (if (= end (1+ beg))
                  (char-after beg)
                (buffer-substring-no-properties beg end)))
         (known (if table (gethash key table 'unmeasured) 'unmeasured)))
    (if (not (eq known 'unmeasured))
        known
      ;; Counted in the table it bounds, under a key no face can be, so that
      ;; emptying the table resets the count with it.
      (when (> (cl-incf (gethash 'cooked--measured metrics 0))
               cooked-wrap-cache-limit)
        (clrhash metrics)
        (setq table nil))
      (unless table
        (setq table (puthash face (make-hash-table :test #'equal) metrics)))
      (puthash
       key
       (when-let*
           ((gstring
             (if-let* ((composition (and (cooked--composition-possible-p beg)
                                         (find-composition beg end nil t))))
                 (nth 2 composition)
               (when-let* ((font (font-at beg window)))
                 (font-shape-gstring
                  (composition-get-gstring beg end font nil) nil))))
            ((vectorp gstring))
            ((> (length gstring) 2))
            (header (aref gstring 0))
            ((vectorp header))
            (font (aref header 0))
            (glyph (aref gstring 2))
            ((vectorp glyph))
            (info (query-font font)))
         (list (aref glyph 4) (aref info 4) (aref info 5) (aref info 2)))
       table))))

(defun cooked--composition-possible-p (pos)
  "Whether a composition could cover the character at POS.

`find-composition' is the expensive half of a measurement, and nearly every
character it is asked about composes with nothing.  A composition needs either
a `composition' property, or an entry in `composition-function-table' for
the character or the one after it -- after, because a combining mark or a
zero-width joiner is what triggers composing the character before it.  So `e'
followed by U+0301 is still asked, and `e' followed by `f' is not."
  (or (get-text-property pos 'composition)
      (and auto-composition-mode
           (or (aref composition-function-table (char-after pos))
               (when-let* ((next (char-after (1+ pos))))
                 (aref composition-function-table next))))))

(defun cooked--glyph-fits-p (measured slot default)
  "Whether MEASURED already sits inside SLOT pixels and DEFAULT's metrics.

The guard that runs first: a glyph whose width is exactly its slot and whose
ascent and descent are exactly the default face's is left entirely alone.

A glyph that fits needs no scaling, and it also must not *claim* the next cell.
A box-drawing character has precisely cell-shaped proportions, so
`cooked--glyph-claims-next-cell-p' would compare two equal aspects, answer yes
on the `>=', and hide the space after it -- in `tree' output every line
begins `│ ', and every one of those spaces would vanish.  So nothing else runs
until this answers no."
  (pcase-let ((`(,width ,ascent ,descent ,_) measured)
              (`(,default-ascent ,default-descent) default))
    (and (eql width slot)
         (eql ascent default-ascent)
         (eql descent default-descent))))

(defun cooked--glyph-scale (measured slot default)
  "The scale that fits MEASURED into SLOT pixels, or nil if it already fits.

MEASURED is `cooked--glyph-metrics's answer, SLOT is how many pixels wide the
grid budgeted for it, and DEFAULT is `cooked--default-metrics's.

Pixels rather than cells so that this is arithmetic and nothing else: taking
cells would mean asking `frame-char-width', which answers 1 on a terminal
frame and would make the whole function untestable in batch for a reason having
nothing to do with what it computes.

The minimum of three ratios, and the third one is the one an implementation
skips.  A row realises `max(ascent) + max(descent)' across every glyph sharing
its baseline, so a glyph overflows if *either* side is over, and scaling by the
ratio of the sums can leave one side over the line.  A CJK glyph with ascent 18
against a default of 15, and descent 5 against 5, has a sum ratio of 0.87 but
an ascent ratio of 0.83: scaled by 0.87 the row is still too tall.

Quantized, because `height' is applied as a scale of the font's pixel size and
Emacs rounds the result -- so a mathematically exact scale rounds back up and
the cell overflows anyway.  Flooring at the pixel is what makes the fit
hold."
  (pcase-let ((`(,width ,ascent ,descent ,pixel) measured)
              (`(,default-ascent ,default-descent) default))
    (when (and default-ascent default-descent (> pixel 0)
               (or (> width slot) (> ascent default-ascent) (> descent default-descent)))
      (let* ((computed (min (if (> width 0) (/ (float slot) width) 1.0)
                            (if (> ascent 0) (/ (float default-ascent) ascent) 1.0)
                            (if (> descent 0) (/ (float default-descent) descent) 1.0)))
             ;; The floor clamps rather than rejects; see
             ;; `cooked-glyph-scale-floor' for why.
             (bounded (max computed (or cooked-glyph-scale-floor 0)))
             ;; After the clamp, not before: `height' scales the font's pixel
             ;; size and Emacs rounds, so a mathematically exact scale rounds
             ;; back up and the cell overflows anyway.
             (quantized (/ (ffloor (* pixel bounded)) pixel)))
        (and (< quantized 1.0) quantized)))))

(defun cooked--default-metrics (window metrics)
  "The default face's (ASCENT DESCENT CELL) in WINDOW, or nil without a font.

What a row is laid out *against*, and therefore what a glyph has to fit inside:
the font's ascent and descent, and CELL, the width of one grid cell in pixels.

All three as this buffer draws them, which after a zoom is not what the frame
says.  Under `text-scale-increase' in a 15-pixel font the buffer is drawn in a
26-pixel one with 16-pixel cells, while the frame's default face and
`frame-char-width' still answer 15 and 9.  Measured against the frame, every
glyph on a row with a box character or a CJK one would be too big for its cell
and shrink, while the ASCII rows beside it stayed zoomed.  So the font comes
from `cooked--default-font' and the cell from `window-font-width', both of
which follow `face-remapping-alist'.

Not `font-at' on the row: that answers about the font covering a position,
which for a CJK character is the *fallback* font it was drawn from.  Asking it
would compare the offender against itself and conclude everything fits.  The
probe is a space in the default face, which is the font the grid is sized by.

Nil on a terminal frame, where there is no font to fit a glyph inside and
nothing to scale.  That answer is remembered like any other, so a terminal
frame asks once per stamp and `cooked--scale-offenders' returns at once for
every row after it.

Cached in METRICS under a key no cluster can collide with, because it is a fact
about the same font and geometry the rest of that table is keyed on and is
thrown away with them."
  (let ((known (gethash 'cooked--default metrics 'unmeasured)))
    (if (not (eq known 'unmeasured))
        known
      (puthash 'cooked--default
               (when-let* ((font (cooked--default-font window))
                           (info (query-font font)))
                 (list (aref info 4) (aref info 5) (window-font-width window)))
               metrics))))

(defun cooked--glyph-claims-next-cell-p (measured from to end default cell)
  "Whether the glyph at FROM..TO may take the cell after it instead of shrinking.

After ghostel's `adjustWidth': a glyph too wide for its cell does not have to
be made smaller if there is somewhere for it to go.  Given two cells it is
scaled less, or not at all, and less scaling leaves less of a gap behind.

Four conditions, each of them load-bearing.

The glyph must be *relatively wider than the cell* -- aspect against aspect,
not width against width.  A glyph narrower in proportion than the cell it sits
in has no use for more room: whatever is making it overflow is its height, and
a wider slot does not help.

It must *stand alone*, with a space or a row edge on both sides.  Claiming a
cell that holds a character would draw two glyphs on top of each other, and
claiming inconsistently -- this instance widened because of what happened to be
beside it, the next one not -- looks worse than either answer applied evenly.

And there must *be* a next cell: a glyph in the last column has nowhere to go.

And the space must be free.  A blank between two box glyphs is absorbed into
their run and carries its share of the run's image, so a space with a
`cooked-deco' on it is already spoken for.  See `Row::absorb_blank_runs' in
src/emu/cell.rs.

CELL is the frame's character width in pixels, passed in for the same reason
`cooked--glyph-scale' takes a slot in pixels: `frame-char-width' answers 1
on a terminal frame, which would make every glyph relatively narrow and this
untestable in batch for a reason having nothing to do with what it decides.

The claimed space is hidden by the caller rather than overwritten, which is
what keeps this non-destructive.  A space rendered at zero width is still a
space in the buffer, so yanking the row, searching it, and the seam assertion
all still see the text the child sent."
  (pcase-let ((`(,width ,ascent ,descent ,_) measured)
              (`(,default-ascent ,default-descent) default))
    (and (> (+ ascent descent) 0)
         (>= (/ (float width) (+ ascent descent))
             (/ (float cell) (+ default-ascent default-descent)))
         (< to end)
         (eq (char-after to) ?\s)
         ;; And the space must actually be free.  A space between two box glyphs
         ;; is part of their run and carries its share of the run's image -- see
         ;; `Row::absorb_blank_runs' in src/emu/cell.rs -- so hiding it at zero
         ;; width would cut a hole in a bitmap that is still as wide as the cells
         ;; it was built for, and pull the rest of the row left under it.
         (not (get-text-property to 'cooked-deco))
         (or (= from (line-beginning-position)) (eq (char-before from) ?\s)))))

(defun cooked--scale-offenders (start end window metrics)
  "Shrink any glyph in START..END that does not fit the cells it was given.

The non-destructive half of the guard, which makes the destructive half a
backstop: a glyph a pixel too wide costs a few percent of its own size rather
than the characters at the end of the row.

Walks clusters rather than characters, because a cluster is what gets shaped and
therefore what has a width: a base plus its combining marks is one glyph in one
cell, and measuring the base alone would answer about something nobody draws.

Nothing is measured on a row that got here uniform and fixed-pitch -- the caller
has already refused those, which is the whole cost control.  What reaches here
is a row the grid thinks may be mismeasured, and on such a row each *distinct*
cluster costs one shaping call, one that cannot be measured included, until the
font changes or `cooked-wrap-cache-limit' measurements empty the memo -- see
`cooked--glyph-metrics'.  Nothing is measured
on a terminal frame either, where `cooked--default-metrics' has no answer.

A character carrying `cooked-deco' is passed over whole.  It is drawn as
cooked's own image cut to its cells, so it fits by construction whatever the
font would have made of it -- and the image of a box-drawing run is one
`display' spanning every cell of the run.  Scaling one character inside it
would replace the picture for that character with a shrunk font glyph and leave
the rest of the run drawing the whole image again, two images wide.

`min-width' as well as `height' because the two answer different halves: the
scale shrinks the glyph, and `min-width' holds the cell it sits in at the size
the grid budgeted, so a shrunk glyph does not pull the rest of the row left."
  (when-let* ((cooked-glyph-scale-floor)
              (default (cooked--default-metrics window metrics))
              (cell (nth 2 default)))
    (save-excursion
      (goto-char start)
      (while (< (point) end)
        (if (get-text-property (point) 'cooked-deco)
            (goto-char
             (next-single-property-change (point) 'cooked-deco nil end))
          (let* ((from (point))
                 ;; One character.  A base and its combining marks are one
                 ;; glyph, and `cooked--glyph-metrics' measures them together
                 ;; through the composition that covers them; stepping by
                 ;; character here costs no allocation, where finding the
                 ;; position by moving point cost a marker per character.
                 (to (min end (1+ from)))
                 (cells (if (= to (1+ from))
                            (char-width (char-after from))
                          (string-width
                           (buffer-substring-no-properties from to))))
                 (measured (and (> cells 0)
                                (cooked--glyph-metrics from to window metrics)))
                 ;; Widen the slot where that is free, then scale whatever is
                 ;; still over: a glyph given two cells is scaled less, or not
                 ;; at all.  Nothing at all for a glyph that already fits, which
                 ;; is the overwhelming majority.
                 (fits (and measured
                            (cooked--glyph-fits-p
                             measured (* cell cells) default)))
                 (claim (and measured (not fits)
                             (= cells 1)
                             (cooked--glyph-claims-next-cell-p
                              measured from to end default cell)))
                 (cells (if claim 2 cells))
                 (scale (and measured (not fits)
                             (cooked--glyph-scale
                              measured (* cell cells) default))))
            (when (or claim scale)
              (put-text-property from to 'display
                                 (if scale
                                     `((min-width (,cells)) (height ,scale))
                                   `((min-width (,cells)))))
              (when claim
                ;; Hidden, not deleted.  A space rendered at zero width is still
                ;; a space in the buffer, so the yank, the search and
                ;; `cooked--check-seam' all still see what the child sent.
                (put-text-property to (1+ to) 'display '(space :width 0))))
            (goto-char to)))))))

(defun cooked--guard-row-width (start width &optional window uniform cache hash)
  "Keep the screen row beginning at START to one screen line.

Every live row is its own hard-newlined buffer line, so Emacs softwrapping one
is never legitimate output: it means some character rendered wider than
`cooked--cols' assumed -- an ambiguous East-Asian width, a composed grapheme, a
font substitution, a face that is not fixed pitch.  Rust's width model is not
the place to chase that, since it has to keep reporting the plain narrow
classification curses programs expect, so this catches what gets through on the
one side that can observe the truth: Emacs' own layout, by way of
`vertical-motion'.

WIDTH is the row's width in grid cells and UNIFORM whether nothing in it can
render wider than a byte-per-column reading, both carried by the drain --
`cooked--render-rows' reads them off the block it has just rendered, and both
are required: there is no caller with a row and no block to have got them
from, so nothing here falls back to measuring the row itself.  They are what
the three steps below are made of, and the order is the point, because each
step exists to keep the next one from running:

  1. A row whose width the grid already accounts for and whose characters no
     font can widen is finished here, with nothing measured at all.  That is
     a uniform row in a fixed-pitch font, which is the overwhelming majority
     of rows -- see `cooked--row-mismeasured-p' and
     `cooked--ascii-fixed-pitch-p'.
  2. A row whose text was already seen to fit under this font and this geometry
     is finished at a hash lookup -- see `cooked--row-wraps-p' -- and one
     already seen *not* to fit is cut to the length it was cut to before.
  3. Only what is left reaches `vertical-motion', and only what that says wraps
     reaches the trim.  See `cooked--fit-row', which is steps 2 and 3.

HASH is the row's layout hash, the key step 2 looks it up by; see
`cooked--row-wraps-p'.

CACHE is `cooked--wrap-cache' for WINDOW, which steps 1 and 2 are both answers
out of.  It is an argument for the same reason WINDOW is: it is a fact about the
drain and not about the row, and building `cooked--layout-stamp' to validate it
per row would cost more than the guard itself.  `cooked--render-rows' asks once
and threads it in.  A caller without one is answered per row, correctly and
slowly.

Measured against WINDOW -- `cooked--layout-window' when it is not given --
rather than against the selected window, which need not be showing this buffer
at all: a row measured against a foreign window is trimmed to a width it was
never written for.  A buffer displayed nowhere is not measured, and gets its
chance when it is displayed.  Computing WINDOW means asking
`window-max-chars-per-line', which selects each window it measures, so doing
that per row would run `select-window' advice in the middle of a render; see
docs/DESIGN.md.

Returns non-nil when characters were deleted, which makes the buffer's row
differ from what the core sent; the caller says so with `cooked--row-edited'.

The cut is marked with the truncation bitmap `truncate-lines' would show, by
hand, because `cooked-rejoin-wrapped-lines' keeps `truncate-lines' off
buffer-wide so a genuinely wrapped scrollback line still reflows for free.

Trimming by character rather than by grapheme cluster is an accepted gap: a cut
between a base character and a combining mark is possible in principle and
vanishingly unlikely in practice, the trigger being a character whose own width
was mismeasured rather than an adjacent one."
  (let ((window (or window (cooked--layout-window))))
    (when (and cooked-rejoin-wrapped-lines window (< start (line-end-position)))
      (goto-char start)
      (pcase-let* ((end (line-end-position))
                   (`(,fixed-pitch ,memo ,metrics ,trims)
                    (or cache (cooked--wrap-cache window))))
        (when (cooked--row-mismeasured-p width uniform fixed-pitch)
          ;; Before the wrap question rather than after it.  A repair hung off
          ;; `cooked--row-wraps-p' would only reach glyphs too *wide*; a glyph
          ;; too *tall*, such as a CJK character from a fallback font, makes
          ;; the row deeper while its width fits and the wrap check says nil.
          (cooked--scale-offenders start end window metrics)
          (when (cooked--fit-row start end window memo trims hash)
            (goto-char start)
            (cooked--mark-truncation start (1- (line-end-position)) window)
            t))))))

(defcustom cooked-truncation-bitmap nil
  "Fringe bitmap `cooked--truncation-bitmap' draws for a trimmed row.

nil (the default) defers to the `truncation' entry in
`fringe-indicator-alist', the way Emacs's own truncation arrow does, so a
user who already rebound that indicator sees their own choice here too.  Set
this to a bitmap symbol -- one of `fringe-bitmaps', or one of your own from
`define-fringe-bitmap' -- to override it directly instead."
  :type '(choice (const :tag "Defer to fringe-indicator-alist" nil) symbol)
  :group 'cooked)

(defun cooked--mark-truncation (start cut window)
  "Mark the row from START to CUT as having had characters trimmed.

Where the marker goes depends on whether WINDOW -- the one the trim was measured
in -- has a fringe to put it in, and the difference is a column of the user's
text.  WINDOW's frame rather than the selected one answers that, since the two
are the same only when the buffer is displayed where it is being rendered from.

On a graphical frame the marker rides an overlay string rather than a `display'
property on CUT itself.  A fringe `display' spec shows its bitmap \"instead of
the characters that have the display specification\", so putting one on a real
character silently costs the row one more character than the trim already did --
while the whole point of using the fringe is that it sits outside the text area
and costs nothing.  The overlay evaporates on its own, because
`cooked--render-rows' deletes the row before rewriting it.

The string goes at the *start* of the row as a `before-string', not at CUT as
an `after-string'.  A fringe bitmap belongs to the screen line rather than to
the column it is anchored in, so either end draws the same picture -- but the
string still has to be placed, and the trim loop leaves the row as wide as it
can.  Anchoring at the cut therefore lands it flush with the right edge often
enough to matter, and redisplay opens an empty continuation line to put it on.
Column zero is never full.

On a terminal frame there is no fringe, so the marker has to cost a column,
exactly as `truncate-lines' spends the last one on `$'.

Known gap: a graphical frame whose window has no right fringe has nowhere to
draw the bitmap, so the marker is invisible there.  See docs/DESIGN.md."
  (if (display-graphic-p (window-frame window))
      (let ((overlay (make-overlay start (1+ start))))
        (overlay-put overlay 'evaporate t)
        (overlay-put overlay 'cooked-truncation t)
        (overlay-put overlay 'before-string
                     (propertize " " 'display
                                 (list 'right-fringe (cooked--truncation-bitmap)))))
    (put-text-property cut (1+ cut) 'display
                       (string (cooked--truncation-glyph)))))

(defun cooked--truncation-bitmap ()
  "The fringe bitmap Emacs marks a line truncated on the right with.

Reads `cooked-truncation-bitmap' first; when that is nil, falls back to
`fringe-indicator-alist' so a user who rebound the indicator but never set
`cooked-truncation-bitmap' sees their own choice.  Its entry is (LEFT RIGHT)
and we are always the right-hand end."
  (or cooked-truncation-bitmap
      (let ((indicator (cdr (assq 'truncation fringe-indicator-alist))))
        (if (consp indicator) (nth 1 indicator) indicator))
      'right-arrow))

(defun cooked--truncation-glyph ()
  "The character a terminal frame marks a truncated line with.
Whatever the display table says, so a user who has rebound it sees their own
choice here too, and `$' — which is what Emacs itself falls back to — otherwise."
  (or (when-let* ((table (or buffer-display-table standard-display-table))
                  (glyph (display-table-slot table 'truncation)))
        (glyph-char glyph))
      ?$))

(provide 'cooked-guard)
;;; cooked-guard.el ends here
