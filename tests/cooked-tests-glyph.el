;;; cooked-tests-glyph.el --- The box-drawing rasterizer, pixel by pixel -*- lexical-binding: t; -*-

;;; Commentary:

;; `cooked-glyph.el' is a pure function of a descriptor and a pixel size, so
;; these assert on the bitmap itself rather than going through a session and a
;; display property.  That is the only way to see any of this in batch: the
;; defects below -- a dash that is not dashed, a dither that steps at the cell
;; boundary, a diagonal that misses the corner its neighbour has to meet -- are
;; all invisible to a test that only checks a `display' property exists.

;;; Code:

(require 'cooked-tests-helpers)

(defun cooked-tests--glyph-image (pos)
  "The image spec inside the `display' property at POS.

A decorated character's `display' is a one-element list holding the image, not
the image itself -- see `cooked--deco-display' for why it has to be a fresh list
per character."
  (car-safe (get-text-property pos 'display)))

(ert-deftest cooked-adjacent-box-glyphs-share-only-a-run-wide-image ()
  "Emacs merges a run of characters whose `display' properties are `eq' into one
displayed image, and whether that is the bug or the point depends entirely on
how wide the image is.

Shared with a *cell-wide* bitmap it is the bug, and it is the one this test was
originally written for: a border rendered as a single glyph and the row lost the
width of everything the merge swallowed.  Shared with a bitmap built for exactly
the run it is put over -- `cooked--deco-image's COUNT -- it is the point: one
interval, one image, and the run occupies precisely the pixels its characters
did.  That is what `cooked--apply-glyph-deco' now does, and it is where nearly
all of the box-drawing redisplay cost went, a 24x80 frame of border falling from
1920 `display' intervals to 24.

So the invariant is not \"never share\" but *the image is as wide as the span
its `display' property covers*, and that is what is asserted: the four
cells share one property, and the bitmap under it is four cells wide rather
than one.
Asserting the sharing alone would pass just as happily for the old bug.

Nothing here is observable in batch, where nothing is drawn, which is how the
original defect got through: every character had a correct `display' property
and only the display engine merged them.  Reading the width off the spec is what
makes the merge visible from batch at all."
  (cooked-tests--with-session
      ;; Four of the same character in a row, which is what a border is.
      '("/bin/sh" "-c" "printf '\\342\\224\\200\\342\\224\\200\\342\\224\\200\\342\\224\\200\\n'")
    (cooked-tests--cell 10 20)
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'display))))
    (let ((beg (point-min)))
      ;; One `display' interval over the whole run, which is the saving.
      (should (get-text-property beg 'display))
      (should (>= (or (next-single-property-change beg 'display) (point-max))
                  (+ beg 4)))
      (dotimes (i 4)
        (should (eq (get-text-property (+ beg i) 'display)
                    (get-text-property beg 'display))))
      ;; And the image it shares is four cells wide, so the merge draws the run
      ;; at the width it had.  `:data-width' rather than `image-size', which
      ;; needs a graphic display -- see
      ;; `cooked-box-drawing-image-spec-is-a-valid-inline-xbm'.
      (let ((image (cooked-tests--glyph-image beg)))
        (should (eq (car image) 'image))
        (should (equal (plist-get (cdr image) :data-width) (* 4 10)))
        (should (equal (plist-get (cdr image) :data-height) 20))))))

(ert-deftest cooked-a-box-glyph-run-broken-by-text-narrows-its-image ()
  "The other half of the invariant above, and the case that would have made
sharing unsafe: a run is only run-wide where the shapes actually run.

A border with a letter dropped in the middle of it is three decoration spans on
the wire, not one, because `Deco::packed' counts consecutive cells of one shape.
So each span gets a bitmap of its own width and the letter keeps its cell.  A
single count taken from the row rather than from the run would have drawn the
first glyph over the text beside it."
  (cooked-tests--with-session
      ;; ──x── : two runs of two, with a plain character between them.
      '("/bin/sh" "-c" "printf '\\342\\224\\200\\342\\224\\200x\\342\\224\\200\\342\\224\\200\\n'")
    (cooked-tests--cell 10 20)
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'display))))
    (let ((beg (point-min)))
      (should (equal (char-after (+ beg 2)) ?x))
      ;; The letter displays as itself: no decoration reaches it.
      (should-not (get-text-property (+ beg 2) 'display))
      ;; Two cells each side, two cells of bitmap each side.
      (dolist (start (list beg (+ beg 3)))
        (should (equal (plist-get (cdr (cooked-tests--glyph-image start))
                                  :data-width)
                       (* 2 10)))
        (should (eq (get-text-property start 'display)
                    (get-text-property (1+ start) 'display)))))))

(ert-deftest cooked-box-drawing-gets-a-display-property ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\342\\224\\214\\342\\224\\200\\342\\224\\220\\n'") ; ┌─┐
    (cooked-tests--cell)
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'display))))))

(ert-deftest cooked-box-drawing-images-disabled-falls-back-to-plain-text ()
  (let ((cooked-box-drawing-images nil))
    (cooked-tests--with-session
        '("/bin/sh" "-c" "printf '\\342\\224\\214\\342\\224\\200\\342\\224\\220\\n'") ; ┌─┐
      (should (cooked-tests--settle
               (lambda () (string-match-p "┌" (cooked-tests--text)))))
      (should-not (get-text-property (point-min) 'display)))))

(ert-deftest cooked-a-run-of-identical-glyphs-shares-one-deco-record ()
  "The point of the run-length wire format, seen from the buffer.

`Deco::packed\=' in src/emu/cell.rs sends `(BITS COUNT)\=' per run of one shape, so
`cooked--apply-glyph-deco\=' can look the image spec up once and put one
`cooked-deco\=' record over the whole run with a single `put-text-property\='.
What is asserted is the sharing itself -- `next-single-property-change\=' compares
with `eq\=', so a run that shares its record is one step of that walk -- because
that is the observable the saving is made of, and it is also exactly what
`cooked--rescale-deco\=' had to be taught to expect.

The `display\=' value is shared across the same run, and that is a second claim
rather than the same one restated: sharing the record is safe because nothing in
it is cell-specific, while sharing the value is safe only because the image
under it was built COUNT cells wide.  See
`cooked-adjacent-box-glyphs-share-only-a-run-wide-image\='."
  (cooked-tests--with-session
      ;; Four of the same character in a row, which is what a border is.
      '("/bin/sh" "-c" "printf '\\342\\224\\200\\342\\224\\200\\342\\224\\200\\342\\224\\200\\n'")
    (cooked-tests--cell)
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'display))))
    (let ((beg (point-min)))
      (should (get-text-property beg 'cooked-deco))
      ;; One step of the walk covers all four cells: one record, not four.
      (should (>= (or (next-single-property-change beg 'cooked-deco) (point-max))
                  (+ beg 4)))
      (dotimes (i 4)
        (should (eq (get-text-property (+ beg i) 'cooked-deco)
                    (get-text-property beg 'cooked-deco))))
      ;; ...and one `display' interval covers the same four cells, the image
      ;; under it being four cells wide.
      (should (eq (get-text-property beg 'display)
                  (get-text-property (+ beg 3) 'display))))))

(defun cooked-tests--deco-lookups (argv)
  "Run ARGV and return (LOOKUPS . RECORDS) for the busiest `cooked--apply\=' of it.

LOOKUPS is how many times that apply asked `cooked--layout-window\=' -- the walk
behind both `cooked--deco-window\=' and `cooked--deco-cell-size\=' -- and RECORDS
how many decoration records it applied.  Counted per apply rather than per
session, and by the maximum rather than the total, because the number of drains
a child\='s output arrives in is not something a test may depend on: the ratio
between the two figures is the invariant, and it is the same whether the output
came in one drain or five."
  (let ((lookups 0) (records 0) (worst-lookups 0) (worst-records 0))
    (cl-letf* ((layout (symbol-function 'cooked--layout-window))
               (deco (symbol-function 'cooked--apply-deco))
               (apply-fn (symbol-function 'cooked--apply))
               ((symbol-function 'cooked--layout-window)
                (lambda (&rest args)
                  (setq lookups (1+ lookups))
                  (apply layout args)))
               ((symbol-function 'cooked--apply-deco)
                (lambda (&rest args)
                  (setq records (1+ records))
                  (apply deco args)))
               ((symbol-function 'cooked--apply)
                (lambda (&rest args)
                  (setq lookups 0 records 0)
                  (prog1 (apply apply-fn args)
                    (when (> records worst-records)
                      (setq worst-records records worst-lookups lookups))))))
      (cooked-tests--with-session argv
        (cooked-tests--cell)
        (cooked-tests--settle
         (lambda () (get-text-property (point-min) 'cooked-deco)))))
    (cons worst-lookups worst-records)))

(ert-deftest cooked-a-render-pass-measures-the-window-once-not-once-per-record ()
  "`cooked--cell-size\=' has always said it is \"measured once per render pass and
passed down, rather than asked per character\", and for a long time the path that
reaches it did the opposite: `cooked--apply-deco\=' asked `cooked--layout-window\='
and `cooked--deco-cell-size\=' -- which walks the window list again -- afresh for
every decoration record.

A border hid that completely, being one record for the whole row, which is why
no benchmark and no test here caught it.  A `tree\=' listing is the shape that
does not hide it: `U+2502\=' separated by NO-BREAK SPACE is a record per nesting
level, so the per-record cost multiplies by the depth.  On
`tree -C /usr/include\=' that was 172,224 window walks and 86,107 cell
measurements at 29.7us apiece on pgtk -- 2.56s of a 3.10s session, which the
hoist took to 311ms.

The invariant is stated as a *ratio* rather than as a number, which is what
makes it robust: two rows differing only in how many records they carry must
cost the same number of window lookups.  A count would have to be revised every
time a render grew or lost an unrelated call to `cooked--layout-window\='; a
comparison cannot go stale, and it fails loudly on the defect -- before
`cooked--deco-pass\=' the wide row cost five times the lookups of the narrow one.

The separator is a letter, and it has to be something that is neither a glyph
nor a blank: a space and a NO-BREAK SPACE are both absorbed into the run beside
them now -- which is the whole of `Row::absorb_blank_runs\=' and exactly why
`tree\=' got cheaper -- so a `tree\=' indent is one record however deep it is and
would make both rows here identical.  A letter is also what keeps the fixture
off `cooked--glyph-claims-next-cell-p\=', which looks for a space; a fixture
using one would be exercising the claim path as well and measuring two things at
once."
  (let* ((narrow (cooked-tests--deco-lookups
                  ;; Two records: a horizontal, a letter, a horizontal.
                  '("/bin/sh" "-c"
                    "printf '\\342\\224\\200x\\342\\224\\200\\n'")))
         (wide (cooked-tests--deco-lookups
                ;; Ten of them, which is an ordinary `tree' nesting depth.
                '("/bin/sh" "-c"
                  "printf '\\342\\224\\200x%.0s' 1 2 3 4 5 6 7 8 9 10; printf '\\n'"))))
    ;; The premise: the two really do differ in record count, so the comparison
    ;; below is comparing something.  Without this the test would pass just as
    ;; happily on a child that printed nothing.
    (should (>= (cdr narrow) 2))
    (should (>= (cdr wide) (* 4 (cdr narrow))))
    ;; And the invariant: the window is measured for the pass, not for the row's
    ;; contents.
    (should (= (car narrow) (car wide)))))

(defun cooked-tests--display-intervals (beg end)
  "How many `display' intervals cover BEG..END.

`next-single-property-change' compares with `eq', which is exactly the
comparison Emacs' own redisplay makes when it walks the interval tree -- so this
counts the thing `find_interval' and `parse_image_spec' are paid per, rather
than a proxy for it."
  (let ((n 0)
        (pos beg))
    (while (< pos end)
      (setq n (1+ n)
            pos (or (next-single-property-change pos 'display nil end) end)))
    n))

(ert-deftest cooked-a-tree-indent-costs-one-display-interval ()
  "A `tree' row's whole indent is one image, however deep the row sits.

This is the invariant the milliseconds are a symptom of.  Box-drawing images
were measured at 67% of a scroll gesture through settled `tree -C /usr/include'
output -- 11.05ms p50 against 3.61 with `cooked-box-drawing-images' off, a 3.1x
effect -- and what makes an indent expensive is not the drawing but the interval
count: a run breaks on any undecorated cell, a space classifies to nothing, and
so `│   │   ├── ' arrived as one decorated run per nesting level.  86,107
decoration records for 30,326 rows, 2.84 per row.

Stated as a *ratio* and not as a number, for the reason
`cooked-a-render-pass-measures-the-window-once-not-once-per-record' states its
own invariant that way: two rows differing only in how deep they are nested must
cost the same number of `display' intervals.  A count would have to be revised
every time something unrelated added or dropped a property; a comparison cannot
go stale, and it fails loudly on the defect -- before `Row::absorb_blank_runs'
the deep row cost four times the intervals of the shallow one.

The fixture is `tree''s own indent byte for byte, NO-BREAK SPACEs included: tree
2.3.2 writes `│   ', and a rule admitting only U+0020 would split every row
at the first two cells and reach none of this."
  (cooked-tests--with-session
      ;; Depth 2 then depth 6, of `│   ' repeated and `└── name'.
      '("/bin/sh" "-c"
        "printf '\\342\\224\\202\\302\\240\\302\\240 %.0s' 1 2; \
printf '\\342\\224\\224\\342\\224\\200\\342\\224\\200 a\\n'; \
printf '\\342\\224\\202\\302\\240\\302\\240 %.0s' 1 2 3 4 5 6; \
printf '\\342\\224\\224\\342\\224\\200\\342\\224\\200 b\\n'")
    (cooked-tests--cell)
    (should (cooked-tests--settle
             (lambda () (save-excursion
                          (goto-char (point-min))
                          (forward-line 1)
                          (get-text-property (point) 'display)))))
    (save-excursion
      (goto-char (point-min))
      (let* ((shallow-end (line-end-position))
             (shallow (cooked-tests--display-intervals (point) shallow-end))
             (shallow-width (- shallow-end (point))))
        (forward-line 1)
        (let* ((deep-end (line-end-position))
               (deep (cooked-tests--display-intervals (point) deep-end))
               (deep-width (- deep-end (point))))
          ;; The premise: the two rows really do differ in nesting depth, so the
          ;; comparison below is comparing something.  Without this the test
          ;; would pass just as happily on a child that printed two blank lines.
          (should (> deep-width (* 2 shallow-width)))
          ;; And the invariant: the indent costs one interval at either depth.
          ;; The name beyond it carries no `display' at all, so the whole row is
          ;; the indent's interval plus the undecorated tail.
          (should (= shallow deep))
          (should (= shallow 2)))))))

(ert-deftest cooked-a-glyph-run-absorbs-the-blanks-between-its-shapes ()
  "The bitmap is baked for the run's whole pattern, blanks and all.

`Row::absorb_blank_runs' in src/emu/cell.rs hands the gaps of `│ │ ├─' over as
a reserved blank shape inside one `Deco::Glyphs' run, and `cooked--deco-image'
rasterizes the whole record list as one image.  Two claims, and the second is
the one a test asserting only the interval count would miss: the image has to be
as wide as the span it is put over, or the merge Emacs makes of that span draws
the row short.  See `cooked-adjacent-box-glyphs-share-only-a-run-wide-image'.

The blanks are still blanks in the buffer -- nothing is deleted and nothing is
substituted -- which is what keeps a yank, a search and `cooked--check-seam'
seeing the text the child sent."
  (cooked-tests--with-session
      ;; `│ │ ├──': seven cells, three of them blank, one run.
      '("/bin/sh" "-c"
        "printf '\\342\\224\\202 \\342\\224\\202 \\342\\224\\234\\342\\224\\200\\342\\224\\200\\n'")
    (cooked-tests--cell 10 20)
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'display))))
    (let ((beg (point-min)))
      (should (equal (buffer-substring-no-properties beg (+ beg 7))
                     "│ │ ├──"))
      ;; One interval over all seven cells, blanks included.
      (should (= (cooked-tests--display-intervals beg (+ beg 7)) 1))
      ;; And one image seven cells wide under it, not three cells' worth spread
      ;; over seven.
      (should (equal (plist-get (cdr (cooked-tests--glyph-image beg)) :data-width)
                     (* 7 10))))))

(ert-deftest cooked-trailing-blanks-stay-out-of-a-glyph-runs-image ()
  "A row's trailing spaces are not baked into a bitmap nobody can see.

The absorbing rule takes a gap *between* two glyph runs and nothing else, which
is what trims the leading and trailing blanks without a trimming step -- see
`Row::absorb_blank_runs'.  Asserted from the buffer because that is where it
would be visible: a run that swallowed the padding out to the right margin would
carry an image as wide as the screen, and the `display' interval would run past
the last glyph into text that has nothing to draw.

`leading_and_trailing_blanks_stay_out_of_the_run' is the same claim made in Rust
against a wrapped row, where the padding is not trimmed before the runs are
built and so actually reaches the rule."
  (cooked-tests--with-session
      ;; Two glyphs with a gap, then a space the row ends on.
      '("/bin/sh" "-c" "printf '\\342\\224\\200 \\342\\224\\200 x\\n'")
    (cooked-tests--cell 10 20)
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'display))))
    (let ((beg (point-min)))
      (should (equal (buffer-substring-no-properties beg (+ beg 5)) "─ ─ x"))
      ;; The run is the three cells the glyphs and their gap occupy.
      (should (= (cooked-tests--display-intervals beg (+ beg 3)) 1))
      (should (equal (plist-get (cdr (cooked-tests--glyph-image beg)) :data-width)
                     (* 3 10)))
      ;; The space after them belongs to nobody, and neither does the letter.
      (should-not (get-text-property (+ beg 3) 'display))
      (should-not (get-text-property (+ beg 3) 'cooked-deco)))))

(ert-deftest cooked-the-cursors-cell-starts-its-own-glyph-run ()
  "A `display' span never bridges the cell the child's cursor is on.

Emacs draws the cursor at the *start* of a `display' span however many
characters the span covers, and cooked puts point wherever the child's cursor is
on every drain.  So a span bridging the cursor's column draws the cursor several
cells to the left of where the child put it -- and the wider the span, the
further wrong it is.

This was invisible for as long as a run was identical box glyphs, a cursor
having no business inside a border, and became visible the moment runs learned
to bridge the blanks of an indent: an indent is exactly where a cursor does sit.
The break is a split rather than a per-cell expansion, because the start of a
span is where Emacs was going to draw it anyway -- so the cost is one extra
interval on one row.

The fixture writes the row and then addresses the cursor back into the middle of
it with CUP, which is what a full-screen program does and what no amount of
plain output would produce.  Without the rule the whole indent is one interval
and the assertion on the boundary fails."
  (cooked-tests--with-session
      ;; `│ │ ├──', then CUP to row 1 column 3 -- the second blank, mid-run.
      '("/bin/sh" "-c"
        "printf '\\342\\224\\202 \\342\\224\\202 \\342\\224\\234\\342\\224\\200\\342\\224\\200\\033[1;4H'")
    (cooked-tests--cell 10 20)
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'display))))
    (let ((beg (point-min)))
      ;; The premise: the cursor really is where the fixture put it, three cells
      ;; into a run that would otherwise be one span of seven.
      (should (equal (cooked--cursor-cell) '(0 . 3)))
      ;; Two spans, and the boundary is the cursor's own cell.
      (should (= (cooked-tests--display-intervals beg (+ beg 7)) 2))
      (should (equal (next-single-property-change beg 'display) (+ beg 3)))
      ;; Each carries an image of its own width, so the row is still as wide as
      ;; its characters -- the split must not cost the cells it separates.
      (should (equal (plist-get (cdr (cooked-tests--glyph-image beg)) :data-width)
                     (* 3 10)))
      (should (equal (plist-get (cdr (cooked-tests--glyph-image (+ beg 3)))
                                :data-width)
                     (* 4 10))))))

(ert-deftest cooked-a-shade-between-blanks-still-keeps-its-own-cell ()
  "The shade rule survives the blanks now sharing a run with it.

A blank is absorbed into a `Deco::Glyphs' run whatever the shapes around it are,
so `░ ░' crosses as one run of three records -- and a shade may never share an
image with anything, its dither phase being a function of the cell's own pixel
origin.  `cooked--glyph-run-segments' is where the two rules meet, and this is
the case that reaches it: the run is split into three, and the blank between two
shades is a segment of its own rather than being folded into either."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\342\\226\\221 \\342\\226\\221\\n'") ; ░ ░
    (cooked-tests--cell 9 20)             ; odd width, where the phase can differ
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'cooked-deco))))
    (let ((beg (point-min)))
      (should (= (cooked-tests--display-intervals beg (+ beg 3)) 3))
      (dotimes (i 3)
        (should (equal (cooked--glyph-pattern-cells
                        (nth 1 (get-text-property (+ beg i) 'cooked-deco)))
                       1))
        ;; Each carries its own column, which is what the phase is derived from.
        (should (equal (nth 2 (get-text-property (+ beg i) 'cooked-deco)) i))))))

(ert-deftest cooked-a-run-of-shades-keeps-a-record-per-cell ()
  "A shade dithers, so its phase is a function of the cell's own pixel origin --
see `cooked--box-phase\='.  The shapes are identical and so cross as one
run-length record like any other repeat, but `cooked--apply-glyph-deco\=' expands
that record per cell rather than sharing it: a shared record carries one column
for the whole run, and `cooked--rescale-deco\=' rebuilding from it would phase
every cell as though it sat where the first one does, drawing a doubled column
down each seam at an odd cell width.

The distinction is in the reader and not in the wire, which is the decision
`Deco::packed\=' argues: run-length encoding already moved the shade test from
once per character to once per record, so a flag bit would have bought one
`logand\=' per run."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\342\\226\\222\\342\\226\\222\\342\\226\\222\\n'") ; ▒▒▒
    (cooked-tests--cell 9 20)             ; odd width, where the phase can differ
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'cooked-deco))))
    (let ((beg (point-min)))
      (should (cooked--box-shade-p
               (cooked--glyph-pattern-head
                (nth 1 (get-text-property beg 'cooked-deco)))))
      ;; One cell per record, which is the expansion: a shared pattern would
      ;; carry all three.
      (should (equal (cooked--glyph-pattern-cells
                      (nth 1 (get-text-property beg 'cooked-deco)))
                     1))
      ;; Each cell its own record, so each carries its own column.
      (dotimes (i 3)
        (should (equal (nth 2 (get-text-property (+ beg i) 'cooked-deco)) i)))
      (should-not (eq (get-text-property beg 'cooked-deco)
                      (get-text-property (1+ beg) 'cooked-deco))))))

(ert-deftest cooked-a-rescale-rebuilds-every-cell-of-a-shared-glyph-run ()
  "`cooked--rescale-deco\=' walks with `next-single-property-change\=', which
compares values with `eq\=' -- so cells sharing one `cooked-deco\=' record are a
single step of that walk, and rebuilding only the step\='s first character would
leave the rest of the run drawn at the old cell size for as long as the buffer
lives.

That the walk reached every character was an accident of allocation rather than
anything the property promised: `cooked--apply-deco\=' consed a fresh record per
cell, so no two were ever `eq\=' and no run was ever longer than one.  A run of
identical glyphs is exactly what a border is made of, so sharing one record
across it is the obvious saving to make on the render path -- and making it
would have broken this silently, the buffer simply ceasing to track the font
with nothing to point at.  So the walk is pinned to the property\='s semantics
here rather than to that accident.

Glyphs and not an image placement, and the difference is the point: an image
record carries the cell\='s own row and column within the picture, so no two
cells of one placement can share it.  A glyph record for a shape that does not
dither carries nothing cell-specific at all."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\342\\224\\200\\342\\224\\200\\342\\224\\200\\n'") ; ───
    (cooked-tests--cell)
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'display))))
    (let* ((inhibit-read-only t)
           (buffer-undo-list t)
           (beg (point-min))
           (end (+ beg 3)))
      ;; One record across the run, which is what a run-length-encoded deco span
      ;; arrives as.  The three cells hold the same shape, so the record they
      ;; share is the record each already had.
      (put-text-property beg end 'cooked-deco (get-text-property beg 'cooked-deco))
      (should (equal (or (next-single-property-change beg 'cooked-deco) end) end))
      ;; Clobbered rather than compared afterwards, for the reason
      ;; `cooked-box-drawing-rescales-on-zoom' gives: batch Emacs reports one
      ;; cell size at every zoom level, so a regenerated spec is `equal' to the
      ;; one it replaced and neither identity nor value distinguishes them.
      (dotimes (i 3)
        (put-text-property (+ beg i) (+ beg i 1) 'display 'clobbered))
      (cooked-tests--cell 12 26)
      (cooked--rescale-deco)
      ;; Every cell of the run, not just the one the walk landed on.
      (dotimes (i 3)
        (should (eq (car-safe (cooked-tests--glyph-image (+ beg i))) 'image)))
      ;; And the rebuilt value is shared across exactly the run the walk found,
      ;; because the bitmap under it was rebuilt at that run's width.  A rescale
      ;; that shared a *cell-wide* image would collapse the border it just
      ;; rebuilt; one that shared a run-wide one draws it at full width.  See
      ;; `cooked--deco-display' and
      ;; `cooked-adjacent-box-glyphs-share-only-a-run-wide-image'.
      (should (eq (get-text-property beg 'display)
                  (get-text-property (+ beg 2) 'display)))
      (should (equal (plist-get (cdr (cooked-tests--glyph-image beg))
                                :data-width)
                     (* 3 12))))))

(ert-deftest cooked-box-drawing-rescales-on-zoom ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\342\\224\\214\\342\\224\\200\\342\\224\\220\\n'") ; ┌─┐
    (cooked-tests--cell)
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'display))))
    ;; Zoom regenerates the image in place, purely from the `cooked-deco'
    ;; property already in the buffer — no round-trip to the native core, so this
    ;; holds regardless of whether batch Emacs' font backend reports a different
    ;; pixel size than the one it started with.
    ;;
    ;; Probed by clobbering the property and watching the sweep put it back, rather
    ;; than by watching for a fresh object: batch Emacs reports one cell size at
    ;; every zoom level, so the regenerated spec is `equal' to the one it replaced,
    ;; and object identity stopped distinguishing them once specs were memoized.
    (let ((inhibit-read-only t))
      (put-text-property (point-min) (1+ (point-min)) 'display 'clobbered))
    (text-scale-increase 1)
    (should (eq (car-safe (cooked-tests--glyph-image (point-min))) 'image))))

;; `image-scaling-factor' defaults to `auto', which scales images by cell-width/10
;; on most GUI font sizes.  These bitmaps are generated at exactly the cell size, so
;; any scaling breaks the pixel-exactness the whole feature exists for — the glyphs
;; stop meeting at cell boundaries and blur back into looking like font characters.
;; An inline `xbm' whose `:data' is raw bits is only a valid spec with
;; `:data-width', `:data-height' and `:stride' (see (elisp) XBM Images).  Get that
;; wrong and Emacs rejects the whole spec and silently falls back to drawing the
;; character with the font, so every other box-drawing test here still passes while
;; nothing renders.  Asserted on the spec rather than via `image-size' because that
;; needs a graphic display and this suite runs in batch.
(ert-deftest cooked-box-drawing-image-spec-is-a-valid-inline-xbm ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\342\\224\\214\\342\\224\\200\\342\\224\\220\\n'") ; ┌─┐
    (cooked-tests--cell)
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'display))))
    (let* ((image (cooked-tests--glyph-image (point-min)))
           (plist (cdr image))
           (width (plist-get plist :data-width)))
      (should (stringp (plist-get plist :data)))
      (should (natnump width))
      (should (natnump (plist-get plist :data-height)))
      ;; Stride is bits per row, rounded up to a whole number of bytes.
      (should (equal (plist-get plist :stride) (* 8 (ceiling width 8))))
      ;; The data must hold at least stride*height bits.
      (should (>= (* 8 (length (plist-get plist :data)))
                  (* (plist-get plist :stride) (plist-get plist :data-height)))))))

;; The colour model, and the one thing about it that is easy to get backwards.  A
;; glyph names neither colour, so Emacs draws the XBM in the colours of the face at
;; the position it sits on (`xbm_load' falls back to the face's own pair, and
;; `search_image_cache' keys the cached pixmap on it).  Naming them in the spec
;; instead looks right and is wrong for the background: it paints over the region,
;; `hl-line-mode', an `isearch' match and every other face Emacs composites on top,
;; so a selection over a screenful of `htop' highlighted everything but the borders.
;; The foreground hid that for as long as it lasted, being exactly the colour the
;; face already carries.
;;
;; Asserted on the spec because it is the whole of the mechanism: what is under test
;; is the *absence* of two properties, which no rendering test in batch could see.
(ert-deftest cooked-box-drawing-takes-its-colors-from-the-face ()
  (cooked-tests--with-session
      ;; A red-on-blue border, so a spec that colours itself has something to say.
      '("/bin/sh" "-c" "printf '\\033[31;44m\\342\\224\\214\\342\\224\\200\\033[0m\\n'") ; ┌─
    (cooked-tests--cell)
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'display))))
    (let ((plist (cdr (cooked-tests--glyph-image (point-min)))))
      (should-not (plist-member plist :foreground))
      (should-not (plist-member plist :background)))
    ;; ...and the rendition is not lost, it is on the text, which is where Emacs
    ;; reads it from.
    (should (equal (get-text-property (point-min) 'face)
                   '(:foreground "red3" :background "blue2")))))

;; One spec per shape and size, whatever colour the cells are drawn in.  This is the
;; payoff of the test above rather than a separate feature: once the colours are out
;; of the spec they are out of the cache key too, so a border that changes colour
;; part way along still rasterizes once.
(ert-deftest cooked-box-drawing-shares-one-spec-across-renditions ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\033[31m\\342\\224\\200\\033[44m\\342\\224\\200\\033[0m\\n'") ; ──
    (cooked-tests--cell)
    (should (cooked-tests--settle
             (lambda () (get-text-property (1+ (point-min)) 'display))))
    (should (eq (cooked-tests--glyph-image (point-min))
                (cooked-tests--glyph-image (1+ (point-min)))))))

;; A spec leaves `create-image' having passed through the user's advice on it,
;; and `solaire-mode' ships one that `plist-put's the background of
;; `solaire-default-face' onto every image made in a buffer where it is enabled.
;; That is right for an icon's transparent PNG and wrong for a bitmap whose
;; second colour is the cell it stands in: it pinned box drawing to solaire's
;; background, so a full-screen program repainting on a colourscheme change
;; recoloured its whole screen except the borders.  Reproduced here with the
;; same advice rather than with solaire, since what matters is the shape of the
;; interference and not who wrote it.
(ert-deftest cooked-box-drawing-resists-advice-that-colors-every-image ()
  (advice-add 'create-image :filter-return #'cooked-tests--stamp-background)
  (unwind-protect
      (cooked-tests--with-session
          '("/bin/sh" "-c" "printf '\\033[44m\\342\\224\\200\\033[0m\\n'") ; blue ─
        (cooked-tests--cell)
        (should (cooked-tests--settle
                 (lambda () (get-text-property (point-min) 'display))))
        (let ((plist (cdr (cooked-tests--glyph-image (point-min)))))
          (should-not (plist-member plist :background))
          (should-not (plist-member plist :foreground))
          ;; The rest of the spec is untouched -- this strips two keys, it does
          ;; not rebuild the image.
          (should (equal (plist-get plist :scale) 1))
          (should (stringp (plist-get plist :data)))))
    (advice-remove 'create-image #'cooked-tests--stamp-background)))

(ert-deftest cooked-box-drawing-images-opt-out-of-auto-scaling ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\342\\224\\214\\342\\224\\200\\342\\224\\220\\n'") ; ┌─┐
    (cooked-tests--cell)
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'display))))
    (let ((image (cooked-tests--glyph-image (point-min))))
      (should (eq (car image) 'image))
      (should (equal (plist-get (cdr image) :scale) 1)))))

;; The two features meet here: box glyphs live in the scrollback, and the alt pin
;; narrows the buffer away from it.  A zoom while a full-screen program is up must
;; still reach the glyphs above the restriction, or they stay at the old pixel size
;; and only reveal it — mismatched against their neighbours — once the pin lifts.
(ert-deftest cooked-box-drawing-rescales-above-the-alt-screen-pin ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\342\\224\\214\\342\\224\\200\\342\\224\\220\\n'") ; ┌─┐
    (cooked-tests--cell)
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'display))))
    (let ((glyph (point-min)))
      ;; Clobbered so the sweep reaching this position is observable; see
      ;; `cooked-box-drawing-rescales-on-zoom' for why identity will not do.
      (let ((inhibit-read-only t))
        (put-text-property glyph (1+ glyph) 'display 'clobbered))
      ;; Pin the buffer to a screen region starting below the glyph, as entering the
      ;; alt screen does.
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert "\n"))
      (setq cooked--screen-start (copy-marker (point-max)))
      (setq cooked--alt t)
      (cooked--apply-alt-pin)
      (should cooked--narrowed)
      (should (< glyph (point-min)))
      (text-scale-increase 1)
      (save-restriction
        (widen)
        (should (eq (car-safe (cooked-tests--glyph-image glyph)) 'image))))))

;; Distinct from the alt-pin test above: there, the glyph reaches "scrollback" by
;; the marker moving past it in place, never leaving the buffer.  Here it genuinely
;; scrolls off the top of the screen and round-trips through `scrolled_rows', the
;; flood path that used to flatten glyphs to plain styled text for cost reasons.
(ert-deftest cooked-box-drawing-survives-scrolling-into-history ()
  (cooked-tests--with-session
      (list "/bin/sh" "-c"
            (concat "printf '\\342\\224\\214\\342\\224\\200\\342\\224\\220\\n'" ; ┌─┐
                    "; for i in $(seq 40); do printf 'line%s\\n' $i; done; exec cat"))
    (cooked-tests--cell)
    (should (cooked-tests--settle
             (lambda () (string-match-p "line40" (cooked-tests--text)))))
    ;; More lines were printed than fit on screen, so the box-drawing row has
    ;; actually scrolled away rather than merely being relabeled in place.
    (should (< (point-min) (marker-position cooked--screen-start)))
    (save-excursion
      (goto-char (point-min))
      (should (search-forward "┌" (marker-position cooked--screen-start) t))
      (should (get-text-property (match-beginning 0) 'display)))))

;; The one test that crosses the boundary: the dash field is a hand-kept mirror
;; between `BoxGlyph' in src/emu/glyph.rs and the `cooked--box-dash-*' constants, and
;; nothing else here would notice the two drifting apart.  ┄ is U+2504, whose only
;; difference from a solid ─ is the dash count — exactly what used to be dropped.
(ert-deftest cooked-box-dash-descriptors-survive-the-round-trip ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\342\\224\\204\\n'") ; ┄
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'cooked-deco))))
    ;; `(KIND PATTERN COLUMN ROW)' -- the run's records are behind the kind, and
    ;; a lone ┄ is a pattern of exactly one of them.
    (let ((bits (cooked--glyph-pattern-head
                 (cadr (get-text-property (point-min) 'cooked-deco)))))
      (should (= 3 (cooked--box-dashes bits)))
      ;; ...and it is still a light horizontal line underneath.
      (should (= 1 (cooked--box-weight bits 'left)))
      (should (= 1 (cooked--box-weight bits 'right)))
      (should (= 0 (cooked--box-weight bits 'up))))))

;; Before this, every dashed codepoint was classified as its solid counterpart, so
;; ┄ and ─ produced byte-identical bitmaps and no amount of drawing could have told
;; them apart.
(ert-deftest cooked-box-dashed-lines-break-into-the-right-number-of-dashes ()
  (let ((width 9) (height 20))
    (let ((solid (cooked-tests--glyph-grid
                  (cooked-tests--line-bits 0 0 1 1) width height)))
      (should (equal (cooked-tests--row-runs solid (/ height 2) width) (list width))))
    ;; Dash codes 1/2/3 are 2, 3 and 4 dashes.
    (dolist (case '((1 . 2) (2 . 3) (3 . 4)))
      (let* ((grid (cooked-tests--glyph-grid
                    (cooked-tests--line-bits 0 0 1 1 (car case)) width height))
             (runs (cooked-tests--row-runs grid (/ height 2) width)))
        (should (equal (length runs) (cdr case)))
        ;; Every dash has to survive as at least one pixel.
        (should (cl-every (lambda (run) (>= run 1)) runs))))))

(ert-deftest cooked-box-dashed-lines-follow-the-stroke-axis ()
  (let* ((width 9) (height 20)
         (vertical (cooked-tests--glyph-grid
                    (cooked-tests--line-bits 1 1 0 0 2) width height))
         (column (/ width 2))
         (rows (let ((n 0))
                 (dotimes (y height) (when (cooked--bitmap-ref vertical column y) (setq n (1+ n))))
                 n)))
    ;; Gaps came out of the column, not out of nothing and not out of a row.
    (should (< rows height))
    (should (> rows 0))))

;; The gap has to straddle the cell boundary, or two dashed cells side by side fuse
;; their edge dashes into one double-length dash at every seam.
(ert-deftest cooked-box-dashes-tile-across-the-cell-boundary ()
  (let* ((width 9) (height 20)
         (grid (cooked-tests--glyph-grid
                (cooked-tests--line-bits 0 0 1 1 2) width height))
         (row (/ height 2)))
    ;; A cell that ends set and starts set would join across the seam.
    (should-not (and (cooked--bitmap-ref grid 0 row)
                     (cooked--bitmap-ref grid (1- width) row)))))

;; A 9-pixel cell is odd, so a dither phased from cell-local coordinates repeats a
;; column at every seam: the last column of one cell and the first of the next are
;; both set, drawing a doubled line down the join between two ▒ cells.
(ert-deftest cooked-box-shade-dither-tiles-across-an-odd-cell-width ()
  (let* ((width 9) (height 8)
         (medium (logior cooked--box-kind-block cooked--box-direction-shade (ash 2 3)))
         (unphased (cooked-tests--glyph-grid medium width height 0))
         ;; The phase the next cell along gets at this width.
         (phase (logand width 1))
         (phased (cooked-tests--glyph-grid medium width height phase)))
    (should (= phase 1))
    (should-not (equal unphased phased))
    ;; Walking off the right edge of one cell into the left edge of the next must
    ;; alternate exactly as it does inside a cell.
    (dotimes (y height)
      (should-not (eq (cooked--bitmap-ref unphased (1- width) y)
                      (cooked--bitmap-ref phased 0 y))))))

(ert-deftest cooked-box-shade-phase-is-zero-unless-it-can-matter ()
  (let ((window (selected-window))
        (medium (logior cooked--box-kind-block cooked--box-direction-shade (ash 2 3)))
        (solid (cooked-tests--line-bits 0 0 1 1)))
    ;; Nothing but a shade is phase-sensitive, so nothing else doubles its cache.
    (should (= 0 (cooked--box-phase solid window 3 5)))
    ;; Nor is a shade whose column is unknown.
    (should (= 0 (cooked--box-phase medium window nil 5)))))

;; A diagonal has to reach the two corners it shares with its neighbours, or a run
;; of ╱ breaks at every cell join — and it has to put a pixel on every scanline, or
;; the stroke itself comes apart at a cell's aspect ratio.
(ert-deftest cooked-box-diagonals-are-connected-and-reach-their-corners ()
  (let* ((width 9) (height 20)
         (forward (cooked-tests--glyph-grid cooked--box-diag-forward width height))
         (backward (cooked-tests--glyph-grid cooked--box-diag-backward width height)))
    (dotimes (y height)
      (should (cooked-tests--row-runs forward y width))
      (should (cooked-tests--row-runs backward y width)))
    ;; ╱ runs bottom-left to top-right, ╲ top-left to bottom-right.
    (should (cooked--bitmap-ref forward (1- width) 0))
    (should (cooked--bitmap-ref forward 0 (1- height)))
    (should (cooked--bitmap-ref backward 0 0))
    (should (cooked--bitmap-ref backward (1- width) (1- height)))))

(ert-deftest cooked-box-cross-is-the-union-of-both-diagonals ()
  (let* ((width 9) (height 20)
         (forward (cooked-tests--glyph-grid cooked--box-diag-forward width height))
         (backward (cooked-tests--glyph-grid cooked--box-diag-backward width height))
         (cross (cooked-tests--glyph-grid
                 (logior cooked--box-diag-forward cooked--box-diag-backward)
                 width height)))
    (dotimes (y height)
      (dotimes (x width)
        (should (eq (and (cooked--bitmap-ref cross x y) t)
                    (and (or (cooked--bitmap-ref forward x y)
                             (cooked--bitmap-ref backward x y))
                         t)))))))

;; Cells are not square and the font size moves, so the stroke has to stay connected
;; at any geometry, not just the one that happened to be tested.
(ert-deftest cooked-box-diagonals-stay-connected-at-any-cell-size ()
  (dolist (size '((4 . 3) (5 . 20) (9 . 20) (20 . 5) (16 . 32)))
    (let* ((width (car size)) (height (cdr size))
           (grid (cooked-tests--glyph-grid cooked--box-diag-forward width height)))
      (dotimes (y height)
        (should (cooked-tests--row-runs grid y width)))
      (dotimes (x width)
        (should (let ((set nil))
                  (dotimes (y height) (when (cooked--bitmap-ref grid x y) (setq set t)))
                  set))))))

(ert-deftest cooked-box-glyph-bits-match-the-rust-side-encoding ()
  "Descriptors mirror `BoxGlyph' in src/emu/glyph.rs by hand (see this file's own
\"Mirrors the bit layout\" commentary), and cross the wire as a raw `u16' (see
`Deco::Glyphs' in src/wire.rs) -- nothing enforces that the two ends agree on what a
bit means. These are the same twelve literals
`bit_pattern_matches_the_lisp_side_mirror' pins in glyph.rs, written here
independently rather than read across the boundary: a change to either side's
packing with no matching change to the other is exactly the bug this pair of
tests exists to catch."
  ;; ─ U+2500 light horizontal
  (let ((bits #x0050))
    (should (= (cooked--box-weight bits 'left) 1))
    (should (= (cooked--box-weight bits 'right) 1))
    (should (= (cooked--box-weight bits 'up) 0))
    (should (= (cooked--box-weight bits 'down) 0))
    (should (= (cooked--box-dashes bits) 0))
    (should-not (cooked--box-block-p bits)))
  ;; ┃ U+2503 heavy vertical
  (let ((bits #x000A))
    (should (= (cooked--box-weight bits 'up) 2))
    (should (= (cooked--box-weight bits 'down) 2))
    (should (= (cooked--box-weight bits 'left) 0))
    (should (= (cooked--box-weight bits 'right) 0)))
  ;; ╋ U+254B heavy cross
  (let ((bits #x00AA))
    (dolist (edge '(up down left right))
      (should (= (cooked--box-weight bits edge) 2))))
  ;; ═ U+2550 double horizontal
  (let ((bits #x00F0))
    (should (= (cooked--box-weight bits 'left) 3))
    (should (= (cooked--box-weight bits 'right) 3))
    (should (= (cooked--box-weight bits 'up) 0)))
  ;; ┄ U+2504 light horizontal, triple-dashed
  (let ((bits #x1050))
    (should (= (cooked--box-weight bits 'left) 1))
    (should (= (cooked--box-weight bits 'right) 1))
    (should (= (cooked--box-dashes bits) 3)))
  ;; ╭ U+256D light arc, down and right
  (let ((bits #x0144))
    (should (/= 0 (logand bits cooked--box-arc)))
    (should (= (cooked--box-weight bits 'down) 1))
    (should (= (cooked--box-weight bits 'right) 1))
    (should (= (cooked--box-weight bits 'up) 0))
    (should (= (cooked--box-weight bits 'left) 0)))
  ;; ╱ U+2571 diagonal, forward only
  (let ((bits #x0200))
    (should (/= 0 (logand bits cooked--box-diag-forward)))
    (should (= 0 (logand bits cooked--box-diag-backward))))
  ;; ╳ U+2573 diagonal, both directions
  (let ((bits #x0600))
    (should (/= 0 (logand bits cooked--box-diag-forward)))
    (should (/= 0 (logand bits cooked--box-diag-backward))))
  ;; █ U+2588 full block
  (let ((bits #x8044))
    (should (cooked--box-block-p bits))
    (should (= (logand bits 7) cooked--box-direction-full))
    (should (= (logand (ash bits -3) 15) 8)))
  ;; ▄ U+2584 lower half block
  (let ((bits #x8021))
    (should (cooked--box-block-p bits))
    (should (= (logand bits 7) cooked--box-direction-down))
    (should (= (logand (ash bits -3) 15) 4)))
  ;; ▒ U+2592 medium shade
  (let ((bits #x8015))
    (should (cooked--box-shade-p bits))
    (should (= (logand (ash bits -3) 15) 2)))
  ;; ▙ U+2599 quadrant: upper-left, lower-left, lower-right
  (let ((bits #x806E))
    (should (cooked--box-block-p bits))
    (should (= (logand bits 7) cooked--box-direction-quadrant))
    (should (= (logand (ash bits -3) 15) #b1101))))

;;;; Line geometry, checked against a statement of it
;;
;; The tests below do not look at a picture.  Each restates, as rectangles, what a
;; shape has to be -- where a stroke of each weight sits across its axis, and
;; where it has to start and stop -- and compares the rasterizer's bitmap against
;; that pixel for pixel over a sweep of cell sizes.  A failure prints both grids.

(defconst cooked-tests--glyph-sizes
  (let ((sizes nil))
    (dolist (width '(5 7 8 9 10 11 16))
      (dolist (height '(10 15 17 20 23 34))
        (push (cons width height) sizes)))
    (nreverse sizes))
  "Cell sizes the geometry tests sweep: narrow, odd, even, and a large one each way.")

(defun cooked-tests--grid-string (grid)
  "GRID as rows of `#' and `.', for a failure message a reader can see."
  (let ((rows nil))
    (dotimes (y (cooked-bitmap-height grid))
      (let ((row (make-string (cooked-bitmap-width grid) ?.)))
        (dotimes (x (cooked-bitmap-width grid))
          (when (cooked--bitmap-ref grid x y)
            (aset row x ?#)))
        (push row rows)))
    (mapconcat #'identity (nreverse rows) "\n")))

(defun cooked-tests--grid-from-rects (width height rects)
  "A WIDTH x HEIGHT bitmap with every rectangle of RECTS set.
Each rectangle is (X0 Y0 X1 Y1), half-open, as `cooked--bitmap-fill' takes it."
  (let ((grid (cooked--bitmap-make width height)))
    (pcase-dolist (`(,x0 ,y0 ,x1 ,y1) rects)
      (cooked--bitmap-fill grid x0 y0 x1 y1))
    grid))

(defun cooked-tests--grid-mirror (grid axis)
  "GRID flipped left to right when AXIS is `horizontal', else top to bottom."
  (let* ((width (cooked-bitmap-width grid))
         (height (cooked-bitmap-height grid))
         (out (cooked--bitmap-make width height)))
    (dotimes (y height)
      (dotimes (x width)
        (when (cooked--bitmap-ref grid x y)
          (if (eq axis 'horizontal)
              (cooked--bitmap-set out (- width 1 x) y t)
            (cooked--bitmap-set out x (- height 1 y) t)))))
    out))

(defun cooked-tests--grid-components (grid &optional diagonal)
  "How many connected groups of set pixels GRID holds.
Four-connected, or eight-connected with DIAGONAL."
  (let* ((width (cooked-bitmap-width grid))
         (height (cooked-bitmap-height grid))
         (seen (make-bool-vector (* width height) nil))
         (steps (append '((1 . 0) (-1 . 0) (0 . 1) (0 . -1))
                        (and diagonal '((1 . 1) (1 . -1) (-1 . 1) (-1 . -1)))))
         (count 0))
    (dotimes (y height)
      (dotimes (x width)
        (when (and (cooked--bitmap-ref grid x y)
                   (not (aref seen (+ x (* y width)))))
          (setq count (1+ count))
          (let ((stack (list (cons x y))))
            (aset seen (+ x (* y width)) t)
            (while stack
              (pcase-let ((`(,px . ,py) (pop stack)))
                (pcase-dolist (`(,dx . ,dy) steps)
                  (let ((nx (+ px dx)) (ny (+ py dy)))
                    (when (and (>= nx 0) (>= ny 0) (< nx width) (< ny height)
                               (cooked--bitmap-ref grid nx ny)
                               (not (aref seen (+ nx (* ny width)))))
                      (aset seen (+ nx (* ny width)) t)
                      (push (cons nx ny) stack))))))))))
    count))

(defun cooked-tests--light (width height)
  "Light stroke thickness at WIDTH x HEIGHT."
  (max 1 (/ (min width height) 8)))

(defun cooked-tests--heavy (width height)
  "Heavy stroke thickness at WIDTH x HEIGHT."
  (max 2 (/ (min width height) 4)))

(defun cooked-tests--bands (weight center light heavy)
  "Where a stroke of WEIGHT sits across its axis, as a list of (LO . HI).

The statement the rasterizer is held to.  A light stroke is LIGHT pixels with
the odd pixel after CENTER; a heavy one is centred the same way; a double one is
two light strokes whose gap is exactly where the light stroke would be, so that
═ and ─ share a centre line and a double line is one light stroke either side."
  (let ((a (- center (/ light 2))))
    (pcase weight
      (1 (list (cons a (+ a light))))
      (2 (let ((b (- center (/ heavy 2))))
           (list (cons b (+ b heavy)))))
      (3 (list (cons (- a light) a)
               (cons (+ a light) (+ a light light)))))))

(defun cooked-tests--should-grid (bits width height expected)
  "Assert descriptor BITS draws exactly EXPECTED at WIDTH x HEIGHT."
  (let ((actual (cooked-tests--glyph-grid bits width height)))
    (unless (equal (cooked-bitmap-bits actual) (cooked-bitmap-bits expected))
      (ert-fail (list (format "#x%04x at %dx%d" bits width height)
                      :expected (cooked-tests--grid-string expected)
                      :actual (cooked-tests--grid-string actual))))))

(ert-deftest cooked-box-every-edge-meets-its-neighbour-at-the-border ()
  "The pixels a line glyph puts on the edge of its cell are exactly its band.

This is the property every border depends on: the column of pixels ─ leaves on
its right edge is the column ┼ picks up on its left, so the two only join if
both put the same band of the same weight there, and nothing else.  Checked for
every combination of weights on the four edges, not only the ones Unicode
names, since each edge is drawn by the same code whatever the others are."
  (pcase-dolist (`(,width . ,height) '((5 . 10) (8 . 17) (9 . 20) (16 . 34)))
    (let ((light (cooked-tests--light width height))
          (heavy (cooked-tests--heavy width height))
          (cx (/ width 2))
          (cy (/ height 2)))
      (dotimes (up 4)
        (dotimes (down 4)
          (dotimes (left 4)
            (dotimes (right 4)
              (let* ((bits (cooked-tests--line-bits up down left right))
                     (grid (cooked-tests--glyph-grid bits width height))
                     (edge-pixels
                      (lambda (along-fn extent)
                        (let ((set nil))
                          (dotimes (i extent)
                            (when (funcall along-fn i) (push i set)))
                          (nreverse set))))
                     (band-pixels
                      (lambda (weight center)
                        (let ((set nil))
                          (pcase-dolist (`(,lo . ,hi)
                                         (cooked-tests--bands weight center light heavy))
                            (cl-loop for i from lo below hi do (push i set)))
                          (sort set #'<)))))
                (should
                 (equal (list bits width height
                              (funcall edge-pixels
                                       (lambda (x) (cooked--bitmap-ref grid x 0)) width)
                              (funcall edge-pixels
                                       (lambda (x) (cooked--bitmap-ref grid x (1- height)))
                                       width)
                              (funcall edge-pixels
                                       (lambda (y) (cooked--bitmap-ref grid 0 y)) height)
                              (funcall edge-pixels
                                       (lambda (y) (cooked--bitmap-ref grid (1- width) y))
                                       height))
                        (list bits width height
                              (funcall band-pixels up cx)
                              (funcall band-pixels down cx)
                              (funcall band-pixels left cy)
                              (funcall band-pixels right cy))))))))))))

(defmacro cooked-tests--with-double-geometry (&rest body)
  "Run BODY once per size in `cooked-tests--glyph-sizes', with the geometry bound.

Binds WIDTH, HEIGHT, L (light thickness), and for each axis the three
coordinates a double line is built from: X- and X+ are where the left and right
strokes of a vertical double line start, XL is where a light vertical stroke
starts; Y-, Y+ and YL likewise across the horizontal axis.  Every stroke is L
wide, so each band is [coordinate, coordinate + L)."
  (declare (indent 0))
  `(pcase-dolist (`(,width . ,height) cooked-tests--glyph-sizes)
     (let* ((L (cooked-tests--light width height))
            (xl (- (/ width 2) (/ L 2)))
            (yl (- (/ height 2) (/ L 2)))
            (x- (- xl L)) (x+ (+ xl L))
            (y- (- yl L)) (y+ (+ yl L)))
       (ignore L xl yl x- x+ y- y+)
       ,@body)))

(ert-deftest cooked-box-double-corners-nest ()
  "╔ is two corners, one inside the other, each a single unbroken stroke.

Drawing each edge's pair of strokes out from the centre without looking at the
other edge left a gap at the outer corner and a stub of the inner stroke poking
past the inner one.  The outer stroke turns at the outer band on both axes and
the inner one at the inner band, so the two never touch."
  (cooked-tests--with-double-geometry
    ;; ╔ down+right
    (cooked-tests--should-grid
     (cooked-tests--line-bits 0 3 0 3) width height
     (cooked-tests--grid-from-rects
      width height
      `((,x- ,y- ,(+ x- L) ,height) (,x- ,y- ,width ,(+ y- L))
        (,x+ ,y+ ,(+ x+ L) ,height) (,x+ ,y+ ,width ,(+ y+ L)))))
    ;; ╝ up+left
    (cooked-tests--should-grid
     (cooked-tests--line-bits 3 0 3 0) width height
     (cooked-tests--grid-from-rects
      width height
      `((,x+ 0 ,(+ x+ L) ,(+ y+ L)) (0 ,y+ ,(+ x+ L) ,(+ y+ L))
        (,x- 0 ,(+ x- L) ,(+ y- L)) (0 ,y- ,(+ x- L) ,(+ y- L)))))))

(ert-deftest cooked-box-double-cross-is-four-corners ()
  "╬ has nothing crossing its centre: four inner corners and a clear gap.
It came out as a # grid, every stroke running straight through the others."
  (cooked-tests--with-double-geometry
    (cooked-tests--should-grid
     (cooked-tests--line-bits 3 3 3 3) width height
     (cooked-tests--grid-from-rects
      width height
      `(;; top-left
        (,x- 0 ,(+ x- L) ,(+ y- L)) (0 ,y- ,(+ x- L) ,(+ y- L))
        ;; top-right
        (,x+ 0 ,(+ x+ L) ,(+ y- L)) (,x+ ,y- ,width ,(+ y- L))
        ;; bottom-left
        (,x- ,y+ ,(+ x- L) ,height) (0 ,y+ ,(+ x- L) ,(+ y+ L))
        ;; bottom-right
        (,x+ ,y+ ,(+ x+ L) ,height) (,x+ ,y+ ,width ,(+ y+ L)))))
    (should (= 4 (cooked-tests--grid-components
                  (cooked-tests--glyph-grid
                   (cooked-tests--line-bits 3 3 3 3) width height))))))

(ert-deftest cooked-box-double-tee-breaks-only-the-inner-line ()
  "╦ keeps its outer line whole and opens the inner one where the branch leaves."
  (cooked-tests--with-double-geometry
    (cooked-tests--should-grid
     (cooked-tests--line-bits 0 3 3 3) width height
     (cooked-tests--grid-from-rects
      width height
      `((0 ,y- ,width ,(+ y- L))
        (0 ,y+ ,(+ x- L) ,(+ y+ L)) (,x- ,y+ ,(+ x- L) ,height)
        (,x+ ,y+ ,width ,(+ y+ L)) (,x+ ,y+ ,(+ x+ L) ,height))))
    ;; ╠ is the same shape turned, and must agree with it.
    (cooked-tests--should-grid
     (cooked-tests--line-bits 3 3 0 3) width height
     (cooked-tests--grid-from-rects
      width height
      `((,x- 0 ,(+ x- L) ,height)
        (,x+ 0 ,(+ x+ L) ,(+ y- L)) (,x+ ,y- ,width ,(+ y- L))
        (,x+ ,y+ ,(+ x+ L) ,height) (,x+ ,y+ ,width ,(+ y+ L)))))))

(ert-deftest cooked-box-single-meets-double ()
  "Where a single stroke meets a double line it joins the line the shape needs.

At a corner (╒) it runs on to the far stroke, so the outer corner closes; at a
tee (╤) it stops at the near stroke and leaves the far one whole; at a cross
(╪) it runs through both.  ╥ and ╫ are the same three cases with the weights
exchanged between the axes."
  (cooked-tests--with-double-geometry
    ;; ╒ down light, right double
    (cooked-tests--should-grid
     (cooked-tests--line-bits 0 1 0 3) width height
     (cooked-tests--grid-from-rects
      width height
      `((,xl ,y- ,(+ xl L) ,height)
        (,xl ,y- ,width ,(+ y- L)) (,xl ,y+ ,width ,(+ y+ L)))))
    ;; ╤ down light, left and right double
    (cooked-tests--should-grid
     (cooked-tests--line-bits 0 1 3 3) width height
     (cooked-tests--grid-from-rects
      width height
      `((0 ,y- ,width ,(+ y- L)) (0 ,y+ ,width ,(+ y+ L))
        (,xl ,y+ ,(+ xl L) ,height))))
    ;; ╪ vertical light through a double horizontal
    (cooked-tests--should-grid
     (cooked-tests--line-bits 1 1 3 3) width height
     (cooked-tests--grid-from-rects
      width height
      `((0 ,y- ,width ,(+ y- L)) (0 ,y+ ,width ,(+ y+ L))
        (,xl 0 ,(+ xl L) ,height))))
    ;; ╓ down double, right light
    (cooked-tests--should-grid
     (cooked-tests--line-bits 0 3 0 1) width height
     (cooked-tests--grid-from-rects
      width height
      `((,x- ,yl ,width ,(+ yl L))
        (,x- ,yl ,(+ x- L) ,height) (,x+ ,yl ,(+ x+ L) ,height))))
    ;; ╫ vertical double through a light horizontal
    (cooked-tests--should-grid
     (cooked-tests--line-bits 3 3 1 1) width height
     (cooked-tests--grid-from-rects
      width height
      `((0 ,yl ,width ,(+ yl L))
        (,x- 0 ,(+ x- L) ,height) (,x+ 0 ,(+ x+ L) ,height))))))

(ert-deftest cooked-box-lines-mirror-where-their-bands-do ()
  "Swapping left for right draws the mirror image, wherever that is possible.

A band of odd thickness is symmetric in a cell of odd width and one of even
thickness in a cell of even width; in the other two cases the odd pixel has to
fall on one side, and mirroring moves it.  So the check runs over the weights
whose bands are symmetric at each size -- light and double at 9x20, where the
light stroke is one pixel, and heavy at 8x16, where it is two -- and there it
catches any junction rule that treats one side differently from the other."
  (pcase-dolist (`(,width ,height ,weights) '((9 21 (0 1 3)) (8 16 (0 2))))
    (dolist (up weights)
      (dolist (down weights)
        (dolist (left weights)
          (dolist (right weights)
            (let ((grid (cooked-tests--glyph-grid
                         (cooked-tests--line-bits up down left right) width height)))
              (should (equal (cooked-tests--grid-string
                              (cooked-tests--grid-mirror grid 'horizontal))
                             (cooked-tests--grid-string
                              (cooked-tests--glyph-grid
                               (cooked-tests--line-bits up down right left)
                               width height))))
              (should (equal (cooked-tests--grid-string
                              (cooked-tests--grid-mirror grid 'vertical))
                             (cooked-tests--grid-string
                              (cooked-tests--glyph-grid
                               (cooked-tests--line-bits down up left right)
                               width height)))))))))))

;;;; Block and arc geometry

(defun cooked-tests--block-bits (direction eighths)
  "A block descriptor, mirroring `BoxGlyph::block' in src/emu/glyph.rs."
  (logior cooked--box-kind-block direction (ash eighths 3)))

(defun cooked-tests--grid-union-disjoint (a b)
  "Whether A and B together set every pixel exactly once."
  (let ((ok t))
    (dotimes (y (cooked-bitmap-height a))
      (dotimes (x (cooked-bitmap-width a))
        (unless (and (cooked--bitmap-ref a x y) (not (cooked--bitmap-ref b x y))
                     t)
          (unless (and (cooked--bitmap-ref b x y) (not (cooked--bitmap-ref a x y)))
            (setq ok nil)))))
    ok))

(ert-deftest cooked-box-complementary-blocks-tile-the-cell ()
  "▀ and ▄ together cover every pixel once, at every fraction and every size.

A block of F eighths from one side and one of 8-F from the other are the two
halves of one cut, so they have to agree on where the cut is.  Rounding each to
its own nearest pixel left `round' to break the tie, and it breaks 8.5 to 8 --
so at a 17-pixel line ▀ and ▄ were both 8 rows, and a picture drawn from half
blocks had a blank line through every row of it."
  (pcase-dolist (`(,width . ,height) cooked-tests--glyph-sizes)
    (cl-loop
     for f from 1 to 7 do
     (should (cooked-tests--grid-union-disjoint
              (cooked-tests--glyph-grid
               (cooked-tests--block-bits cooked--box-direction-up f) width height)
              (cooked-tests--glyph-grid
               (cooked-tests--block-bits cooked--box-direction-down (- 8 f))
               width height)))
     (should (cooked-tests--grid-union-disjoint
              (cooked-tests--glyph-grid
               (cooked-tests--block-bits cooked--box-direction-left f) width height)
              (cooked-tests--glyph-grid
               (cooked-tests--block-bits cooked--box-direction-right (- 8 f))
               width height))))))

(ert-deftest cooked-box-half-blocks-cut-where-quadrants-do ()
  "▀ ▄ ▌ ▐ and the quadrants ▘▝▖▗ share one cut on each axis.
Otherwise ▌ beside ▙ steps by a pixel at an odd cell width."
  (pcase-dolist (`(,width . ,height) cooked-tests--glyph-sizes)
    (dolist (pair `((,cooked--box-direction-up . #b0011)
                    (,cooked--box-direction-down . #b1100)
                    (,cooked--box-direction-left . #b0101)
                    (,cooked--box-direction-right . #b1010)))
      (should (equal (cooked-tests--grid-string
                      (cooked-tests--glyph-grid
                       (cooked-tests--block-bits (car pair) 4) width height))
                     (cooked-tests--grid-string
                      (cooked-tests--glyph-grid
                       (cooked-tests--block-bits cooked--box-direction-quadrant
                                                 (cdr pair))
                       width height)))))))

(defconst cooked-tests--arcs
  '((#x0144 down right) (#x0114 down left) (#x0111 up left) (#x0141 up right))
  "The four arc descriptors, ╭ ╮ ╯ ╰, and the edges each one joins.")

(ert-deftest cooked-box-arcs-meet-their-lines-and-nothing-else ()
  "An arc puts on the border exactly what ─ and │ put there, on its two sides only.

That is the same property `cooked-box-every-edge-meets-its-neighbour-at-the-border'
checks for straight lines, and for the same reason: a rounded box is ╭ and ─
side by side.  The stroke also has to be one piece."
  (pcase-dolist (`(,width . ,height) cooked-tests--glyph-sizes)
    (pcase-dolist (`(,bits . ,edges) cooked-tests--arcs)
      (let ((grid (cooked-tests--glyph-grid bits width height))
            (straight (cooked-tests--glyph-grid
                       (apply #'cooked-tests--line-bits
                              (mapcar (lambda (edge) (if (memq edge edges) 1 0))
                                      '(up down left right)))
                       width height)))
        (should (= 1 (cooked-tests--grid-components grid t)))
        (dotimes (x width)
          (should (eq (cooked--bitmap-ref grid x 0) (cooked--bitmap-ref straight x 0)))
          (should (eq (cooked--bitmap-ref grid x (1- height))
                      (cooked--bitmap-ref straight x (1- height)))))
        (dotimes (y height)
          (should (eq (cooked--bitmap-ref grid 0 y) (cooked--bitmap-ref straight 0 y)))
          (should (eq (cooked--bitmap-ref grid (1- width) y)
                      (cooked--bitmap-ref straight (1- width) y))))))))

(ert-deftest cooked-box-arcs-run-straight-into-their-corner ()
  "╭ is a straight │ that turns through a circle of the cell's half-width into ─.

The ellipse it replaced spanned the whole quadrant, so the stroke left │'s column
almost as soon as it entered the cell and the corner read as a slanted line.
Here every row from the bottom edge up to where the circle begins holds exactly
the │ band and nothing else, and the circle begins no more than the half-width
below the centre."
  (pcase-dolist (`(,width . ,height) cooked-tests--glyph-sizes)
    (let* ((light (cooked-tests--light width height))
           (xl (- (/ width 2) (/ light 2)))
           (yl (- (/ height 2) (/ light 2)))
           (radius (min (- width (+ xl (/ light 2.0)))
                        (- height (+ yl (/ light 2.0)))))
           (grid (cooked-tests--glyph-grid #x0144 width height)))
      (cl-loop
       for y from (ceiling (+ yl (/ light 2.0) radius)) below height do
       (should (equal (list width height y (cooked-tests--row-runs grid y width))
                      (list width height y (list light))))
       (should (cooked--bitmap-ref grid xl y))))))

(ert-deftest cooked-box-arcs-are-mirror-images ()
  "╮ ╯ ╰ are ╭ reflected, wherever the line bands are themselves symmetric.
See `cooked-box-lines-mirror-where-their-bands-do' for which sizes those are."
  (pcase-dolist (`(,width . ,height) '((9 . 21) (7 . 15) (11 . 23)))
    (let ((tl (cooked-tests--glyph-grid #x0144 width height)))
      (should (equal (cooked-tests--grid-string (cooked-tests--grid-mirror tl 'horizontal))
                     (cooked-tests--grid-string
                      (cooked-tests--glyph-grid #x0114 width height))))
      (should (equal (cooked-tests--grid-string (cooked-tests--grid-mirror tl 'vertical))
                     (cooked-tests--grid-string
                      (cooked-tests--glyph-grid #x0141 width height))))
      (should (equal (cooked-tests--grid-string
                      (cooked-tests--grid-mirror
                       (cooked-tests--grid-mirror tl 'vertical) 'horizontal))
                     (cooked-tests--grid-string
                      (cooked-tests--glyph-grid #x0111 width height)))))))

(provide 'cooked-tests-glyph)
;;; cooked-tests-glyph.el ends here
