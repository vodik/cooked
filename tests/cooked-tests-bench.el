;;; cooked-tests-bench.el --- The benchmark's fixtures, against the protocol -*- lexical-binding: t; -*-

;;; Commentary:

;; tests/cooked-bench.el hand-builds the packed records the native core would have
;; sent, so that `cooked--apply\=' can be driven a frame at a time with no child on
;; the other end -- which is the whole reason the per-frame figures are worth
;; anything: no scheduling, no damage coalescing, and the same number run to run.
;;
;; The cost of that is a third copy of the wire format.  The Rust encoder states it
;; (`Block::push_style\=', `Deco::packed\='), the Lisp reader states it again
;; (`cooked--render-block\=', `cooked--apply-glyph-deco\='), and the fixtures state it
;; a third time.  The first two are pinned -- by the Rust tests on one side and by
;; the whole suite driving real children through the real module on the other.  The
;; third was trusted, and it is the copy nothing would have complained about.
;;
;; That is not hypothetical.  Both fixtures have already gone stale once, in the
;; commit that packed these formats: `cooked-bench--box-rows\=' had to be taught the
;; run-length records, and `cooked-bench--styled-rows\=' was left emitting the old
;; list of lists -- which did not fail a test, because no test read it.  It crashed
;; the benchmark, and a fixture that goes wrong more quietly would simply have
;; reported a plausible number for work the renderer never does.
;;
;; So these tests are pointed at the fixtures rather than at the renderer.  They
;; check the fixture against the *reader*, which is the edge that can drift: a
;; format moved in Rust and in Lisp with the fixture forgotten is exactly what they
;; catch, and it is the way round it actually happened.

;;; Code:

(require 'ert)
(require 'cooked-tests-helpers)
(require 'cooked-bench)

(ert-deftest cooked-bench-style-records-are-the-stride-the-reader-steps-by ()
  "`cooked--render-block\=' finds the next span by adding `cooked--style-record\='
and never by decoding a length, so a fixture whose records are a different width
does not fail -- it reads every span after the first out of its neighbour's
bytes.  One record, one stride, asserted against the constant itself."
  (should (= (length (cooked-bench--style-record 0 8 0 0 0 0))
             cooked--style-record))
  ;; And the offsets are where the reader looks for them, which is the half a
  ;; stride check cannot see: a record of the right width with START and END
  ;; transposed would style backwards.
  (let ((packed (apply #'unibyte-string
                       (cooked-bench--style-record 3 11 0 0 0 0))))
    (should (= (cooked--u32 packed 0) 3))
    (should (= (cooked--u32 packed 4) 11))))

(ert-deftest cooked-bench-style-records-decode-to-the-rendition-they-name ()
  "The fixture's colour fields go through `cooked--face-packed\=', so this asks the
reader itself what the fixture said and compares it against the same rendition
spelled out.  `cooked--face\=' is the entry point for a caller holding decoded
colours, which makes it the independent statement of the answer.

Both a palette colour and a truecolor one, because they take different paths
through the cache key -- a fixnum for the first, the record's own bytes for the
second -- and a fixture that packed the tag wrong would still look right on
whichever of the two happened to be tested."
  (with-temp-buffer
    (dolist (case '((#x01000002 2)          ; tag 1, indexed 2
                    (#x020A141E (10 20 30)))) ; tag 2, rgb
      (pcase-let* ((`(,packed-fg ,spec) case)
                   (record (apply #'unibyte-string
                                  (cooked-bench--style-record
                                   0 4 packed-fg 0 0 cooked--attr-bold))))
        (should (equal (cooked--face-packed record 0)
                       (cooked--face spec nil cooked--attr-bold nil)))))))

(ert-deftest cooked-bench-box-rows-carry-one-record-per-run-not-per-cell ()
  "A row of one repeated shape is the single record the run-length encoding
exists to produce, and a fixture still emitting two bytes per character is the
stale state this file exists to catch.  Asserted on the bytes, because the
length is the difference: eighty cells are four bytes, not a hundred and sixty."
  (pcase-let* ((`((,_index . (,_text ,_styles ,spans)))
                (cooked-bench--box-rows 1 80))
               (`(,_start (glyph . ,packed)) (car spans)))
    (should (= (length packed) 4))
    (should (= (cooked--u16 packed 0) #x50))
    (should (= (cooked--u16 packed 2) 80))))

(ert-deftest cooked-bench-box-rows-decorate-every-cell-they-claim ()
  "The consequence, and the assertion that would survive a format this file has
not thought of: whatever the fixture says, applying it has to leave a decoration
on each of the row's cells and on nothing else.

Two things this needs in order to assert anything, and it asserted nothing
without either.

*Forty columns, not eighty.*  The stale two-bytes-per-character encoding read as
four-byte runs gives a first record of `bits\=' #x50 and `count\=' #x50 -- the next
glyph's low byte -- and at eighty columns that count *is* eighty, so the row came
out correctly decorated by coincidence.  A width whose low byte is not the glyph's
own leaves nothing to coincide.

*`cooked-debug\=' bound.*  The records after the first run past the row, and
`cooked--apply-deco\=' is wrapped in `cooked--protect-seam\=', which outside
`cooked-debug\=' catches that and reports it once -- so the overrun was swallowed
and the count came back plausible.  `cooked-tests--with-session\=' binds the flag
for the whole suite for exactly this reason and states it in its docstring;
`cooked-bench--with-session\=' does not, because the benchmark wants a drain to
survive a cosmetic failure rather than stop for it.  So it is bound here, around
the one call under test."
  (cooked-bench--with-session '("/bin/sh" "-c" "sleep 300")
    (cooked-tests--settle-briefly)
    (let ((cooked-debug t))
      (cooked--apply (cooked-bench--update (cooked-bench--box-rows 1 40))))
    (let ((decorated 0)
          (pos (point-min)))
      (save-restriction
        (widen)
        (while (< pos (point-max))
          (when (get-text-property pos 'cooked-deco)
            (setq decorated (1+ decorated)))
          (setq pos (1+ pos))))
      (should (= decorated 40)))))

(ert-deftest cooked-bench-tree-rows-carry-a-record-per-run-and-decorate-each-one ()
  "The `tree\=' fixture is the opposite of the border one, and its whole value is
in being so: `cooked-bench--box-rows\=' is one record covering eighty cells,
where a `tree\=' row is a record per nesting level covering one cell each.  A
fixture that quietly coalesced them -- by padding with an ordinary space that the
core would not have separated runs on, say -- would look like a second border
row and measure nothing new, which is exactly the silent staleness this file
exists to catch.

So both halves are asserted.  The records are counted against the depth, and
then the fixture is applied and the decorations counted in the buffer, because a
record naming a cell it does not cover is the failure a byte-level check cannot
see -- the same argument
`cooked-bench-box-rows-decorate-every-cell-they-claim\=' makes, and `cooked-debug\='
is bound here for the same reason it is bound there."
  ;; Depth six is five verticals, a tee and a two-cell horizontal run: seven
  ;; records, against the border row's one.
  (pcase-let* ((`((,_index . (,_text ,_styles ,spans)))
                (cooked-bench--run (list (cooked-bench--tree-row 6 80)))))
    (should (= (length spans) 7))
    ;; Every one is a run of its own, and the horizontals are the only record
    ;; covering more than a single cell.
    (should (equal (mapcar (lambda (span)
                             (cooked--u16 (cdr (cadr span)) 2))
                           spans)
                   '(1 1 1 1 1 1 2))))
  (cooked-bench--with-session '("/bin/sh" "-c" "sleep 300")
    (cooked-tests--settle-briefly)
    (let ((cooked-debug t))
      (cooked--apply (cooked-bench--update
                      (cooked-bench--run (list (cooked-bench--tree-row 6 40))))))
    (let ((decorated 0)
          (pos (point-min)))
      (save-restriction
        (widen)
        (while (< pos (point-max))
          (when (get-text-property pos 'cooked-deco)
            (setq decorated (1+ decorated)))
          (setq pos (1+ pos))))
      ;; Five verticals, a tee and two horizontals: eight decorated cells, and
      ;; the NO-BREAK SPACEs and the filename between them undecorated.
      (should (= decorated 8)))))

(ert-deftest cooked-bench-image-rows-are-twelve-bytes-a-cell-where-the-reader-looks ()
  "The image fixture is the third copy of a wire format again, and the one the
suite has no other reason to exercise -- no test in tests/cooked-tests-render.el
reads `cooked-bench--image-cell', and no benchmark reads `Deco::packed'.  So the
stride and every field are asserted against the same decoders
`cooked--apply-image-deco' walks the records with.

A stride check alone would not be enough here and was not enough for the box
row either: twelve bytes of anything is twelve bytes, and a record with CROW and
CCOL transposed reads as a picture drawn down its own left column.  What makes
that visible is asking for the *second* cell of the *second* row, the only
position at which every one of the four fields is distinct."
  (pcase-let* ((`((,_index . (,_text ,_styles ,spans ,_links ,_table)))
                (cooked-bench--image-rows 2 80))
               (`(,_start (image . ,packed)) (cadr spans)))
    ;; Row 1 of the picture, eighty cells of it, twelve bytes each.
    (should (= (length packed) (* 12 80)))
    (let ((base (* 12 1)))
      (should (= (cooked--u32 packed base) 1))          ; id
      (should (= (cooked--u16 packed (+ base 4)) 1))    ; crow: the second row
      (should (= (cooked--u16 packed (+ base 6)) 1))    ; ccol: the second cell
      (should (= (cooked--u16 packed (+ base 8)) 80))   ; cols
      (should (= (cooked--u16 packed (+ base 10)) 2)))))  ; rows

(ert-deftest cooked-bench-image-rows-coalesce-to-one-run-a-row ()
  "The consequence, and the assertion that would survive a wire format this file
has not thought of: applying the fixture has to leave one `display\=' run and one
`cooked-deco\=' run *per screen row*, forty cells wide, because that is the state
94b43e6 produced and the whole of what `cooked-bench-image\=' claims to be timing.

The failure this guards is not a crash.  A fixture whose CCOLs did not rise by
one -- every cell claiming column 0, say, which is the shape a per-row record
would decode to -- still applies, still decorates every cell, and still reports
a number.  It would just report the per-cell cost the change removed, labelled
as the coalesced one, and the benchmark would say the commit did nothing.
Reverting 94b43e6\='s cooked-deco.el hunk turns the seven runs below into a
hundred and sixty-three, so this is the assertion that fails on the old code.

Asserted as \"every decorated run is a whole row wide\" and not as a total over
the buffer, which is what it said first, because a total is hostage to how many
rows the buffer has and one thing in the suite takes a row away.  `evil-mode\='
is a global minor mode, `cooked-a-mouse-report-in-visual-state-leaves-evil-agreeing\='
turns it on and nothing turns it off, so every test after it in the run has evil
loaded -- and with evil loaded, `cooked--set-mode\=' drives an evil state exit,
whose hook calls `evil-maybe-remove-spaces\=', which deletes a line consisting
entirely of whitespace.  An image cell *is* a blank, so a frame of picture loses
the row point is standing on and the total comes back one short.  That is worth
knowing and is not this test\='s subject: the run width says exactly what
coalescing means and says it about whichever rows survived.

`cooked-debug\=' bound for the reason `cooked-bench-box-rows-decorate-every-cell-they-claim\='
binds it: `cooked--apply-deco\=' runs inside `cooked--protect-seam\=', which outside
the flag swallows a malformed record and lets the row come back plausible."
  (cooked-bench--with-session '("/bin/sh" "-c" "sleep 300")
    (cooked-tests--settle-briefly)
    (let ((cooked-debug t)
          (rows (cooked-bench--image-rows 4 40)))
      (cooked--install-images (cooked-bench--image-resources 4 40))
      (cooked--apply (cooked-bench--update rows :alt t)))
    (save-restriction
      (widen)
      (let ((pos (point-min))
            (runs 0))
        (while (< pos (point-max))
          (let ((next (or (next-single-property-change pos 'display) (point-max))))
            (when (get-text-property pos 'cooked-deco)
              (setq runs (1+ runs))
              ;; The whole row in one interval, both properties over the same
              ;; extent -- a `cooked-deco' per cell would leave the interval tree
              ;; exactly as long however few `display' values it held, which is
              ;; why the commit moved both and why both are checked.
              (should (= (- next pos) 40))
              (should (= (or (next-single-property-change pos 'cooked-deco)
                             (point-max))
                         next)))
            (setq pos next)))
        ;; At least three of the four rows: see the docstring for the fourth.
        (should (>= runs 3))))))

(ert-deftest cooked-bench-a-scroll-damages-the-row-it-names-and-no-other ()
  "The scroll fixture has two halves that have to agree, and nothing else in the
suite would notice them disagreeing.

FIRST is the screen row the run lands at, and it has to be the row the shift
recycled: a shift of (0 23 1 t) moves rows 1..23 up and leaves row 23 holding
whatever the reopened line has, so a run at row 0 would rewrite the top of the
screen and leave the recycled row blank -- a fixture measuring the same amount
of work at the wrong end of the buffer, which is exactly the quiet kind of wrong
this file exists for.

HEIGHT is the other half.  `cooked-bench--update' defaults it to the rows
damaged, and one damaged row means a one-row screen, which `cooked--fit-screen'
obeys by deleting the twenty-three the shift had just carefully preserved.  Both
are asserted here as a screen that still has twenty-four rows after a frame, the
last of which is the one the fixture wrote."
  (cooked-bench--with-session '("/bin/sh" "-c" "sleep 300")
    (cooked-tests--settle-briefly)
    (let ((update (cooked-bench--update (cooked-bench--scrolled-row 23 40)
                                        :alt t :height 24
                                        :shifts '((0 23 1 t)))))
      ;; Twice: the first apply grows the screen and the second is the one that
      ;; actually scrolls a screen that was already full, which is the state the
      ;; benchmark times and the only one in which the shift moves real rows.
      (cooked--apply update)
      (cooked--apply update))
    (let ((start (cooked--screen-start-position)))
      (should start)
      (should (= (count-lines start (point-max)) 24))
      (save-excursion
        (goto-char (point-max))
        (should (equal (buffer-substring-no-properties
                        (line-beginning-position) (line-end-position))
                       (make-string 40 ?x)))))))

(ert-deftest cooked-bench-a-run-carries-every-row-the-guard-and-the-spans-need ()
  "A fixture is one run -- `(0 . BLOCK)\=' -- and a block is (TEXT STYLE-SPANS
DECO-SPANS LINK-SPANS ROWS), where ROWS has one (START WIDTH UNIFORM) per screen
row.  Every generator here has to supply it, and the row table has to describe
the text it rides on.

The measurements are the ones that went stale before, and they went stale in the
quietest way this file has yet seen.  Nothing reads them in
`cooked--render-block\='; `cooked--render-rows\=' reads them off the block
afterwards and hands them to `cooked--guard-row-width\=', which does nothing at
all unless the buffer is displayed.  The benchmark displayed nothing, so blocks
missing them drove every figure in the file for as long as they existed, and the
moment a window was attached the guard got a nil WIDTH and the run died in
`cooked--row-mismeasured-p\='.  A crash was the lucky outcome: had the fixture
said a WIDTH the guard could work with and UNIFORM t, it would have reported the
fast path's cost for rows that in production take the slow one.

So the table is asserted against the *text*, row by row: START must be where
that row actually begins, WIDTH its cell count, and UNIFORM whether every
character of it is one byte on one cell -- which makes the box row, whose
characters are three bytes each, the one that has to answer nil.  The style and
decoration offsets are checked to land inside the row they were written for,
since re-basing them onto the assembled text is the one thing
`cooked-bench--run\=' does that a per-row fixture never had to."
  (dolist (rows (list (cooked-bench--plain-rows 2 80)
                      (cooked-bench--styled-rows 2 80)
                      (cooked-bench--url-rows 2 80)
                      (cooked-bench--box-rows 2 80)
                      (cooked-bench--tree-rows 2 80)
                      (cooked-bench--image-rows 2 80)))
    (should (= (length rows) 1))
    (pcase-let ((`((,first . ,block)) rows))
      (should (= first 0))
      (should (= (length block) 5))
      (pcase-let* ((`(,text ,styles ,decos ,_links ,table) block)
                   (lines (split-string text "\n")))
        (should (= (length table) 2))
        (should (= (length lines) 2))
        (let ((offset 0))
          (cl-loop for line in lines
                   for row in table
                   do (pcase-let ((`(,start ,width ,uniform) row))
                        (should (= start offset))
                        (should (= width (string-width line)))
                        (should (eq (and uniform t)
                                    (= (string-bytes line) (length line))))
                        (setq offset (+ offset (length line) 1)))))
        ;; The last row ends the text, so nothing may be addressed past it.
        (let ((limit (length text)))
          (cl-loop for i from 0 below (length styles) by cooked--style-record
                   do (should (<= (cooked--u32 styles (+ i 4)) limit)))
          (pcase-dolist (`(,from ,_deco) decos)
            (should (< from limit))))))))

(ert-deftest cooked-bench-allocation-prints-a-row-per-fixture ()
  "`cooked-bench-allocation\=' runs last in `cooked-bench\=', after every timed case,
so a crash there costs the whole run its only machine-independent rows.  It
once called `cooked-bench--update\=' positionally after that helper had become
keyword-only, and nothing but a full benchmark run would have said so; the
byte-compiler does not check keyword arguments.  Running it here is four
frames and four sessions, cheap enough to pin."
  (let (rows)
    (cl-letf (((symbol-function 'message)
               (lambda (format &rest args)
                 (push (apply #'format-message format args) rows))))
      (cooked-bench-allocation))
    (should (= (length rows) 4))
    (dolist (row rows)
      (should (string-match-p "\\`  alloc, .* conses +[0-9]+ .* intervals +[0-9]+\\'"
                              row)))))

(provide 'cooked-tests-bench)
;;; cooked-tests-bench.el ends here
