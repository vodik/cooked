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
  (should (= (length (cooked-bench--style-record 0 8 0 0))
             cooked--style-record))
  ;; And the fields are where the reader looks for them, which is the half a
  ;; stride check cannot see: a record of the right width with START and END
  ;; transposed would style backwards.
  (let ((packed (apply #'unibyte-string (cooked-bench--style-record 3 11 5 7))))
    (should (= (cooked--u32 packed cooked--style-start) 3))
    (should (= (cooked--u32 packed cooked--style-end) 11))
    (should (= (cooked--u32 packed cooked--style-id) 5))
    (should (= (cooked--u32 packed cooked--style-link) 7))))

(ert-deftest cooked-bench-style-records-resolve-to-the-rendition-they-name ()
  "A fixture\='s rendition id resolves, through the table the fixture installs,
to the face the same rendition spelled out has.  `cooked--face\=' is the entry
point for a caller holding decoded colours, which makes it the independent
statement of the answer.  Both a palette colour and a truecolor one, because a
fixture that packed the tag wrong would still look right on one of them."
  (with-temp-buffer
    (dolist (case '((#x01000002 2)          ; tag 1, indexed 2
                    (#x020A141E (10 20 30)))) ; tag 2, rgb
      (pcase-let* ((`(,packed-fg ,spec) case)
                   (id (cooked-bench--style-id packed-fg 0 0 cooked--attr-bold)))
        (cooked--install-styles (cooked-bench--style-table))
        (should (equal (cooked--style-face id)
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

(ert-deftest cooked-bench-tree-rows-take-the-path-real-tree-output-takes ()
  "The `tree\=' fixture is what the core sends for a `tree -C\=' listing.

It used to be written by hand, with its NO-BREAK SPACE padding outside every
glyph record, so each row was flagged nil and measured the width guard\='s slow
path -- a path real `tree\=' output never takes, because the core absorbs the
blanks between two glyph runs into the run.  Now the rows come from the
emulator, and this pins the two facts that make the fixture honest.

Every row drawn with box glyphs is flagged `glyph\=' and carries one decoration
record, since a vertical, its padding and the branch after it are one run.  And
once applied, every box-drawing character is decorated while the names beside
them are not, which is the check a byte-level assertion cannot make."
  (pcase-let* ((rows (cooked-bench--tree-rows 24 80))
               (`((,first . (,text ,_styles ,decos ,table))) rows)
               (lines (split-string text "\n")))
    (should (= first 0))
    (should (= (length table) 24))
    (cl-loop for line in lines
             for row in table
             do (should (eq (nth 2 row)
                            (if (string-match-p "[─-╿]" line) 'glyph t))))
    (should (= (length decos)
               (cl-count-if (lambda (line) (string-match-p "[─-╿]" line))
                            lines)))
    (cooked-bench--with-session '("/bin/sh" "-c" "sleep 300")
      (cooked-tests--settle-briefly)
      (let ((cooked-debug t))
        (cooked--apply (cooked-bench--update rows :alt t)))
      (save-restriction
        (widen)
        (goto-char (point-min))
        (while (re-search-forward "[─-╿]" nil t)
          (should (get-text-property (match-beginning 0) 'cooked-deco)))
        (goto-char (point-min))
        (while (re-search-forward "[a-z]" nil t)
          (should-not (get-text-property (match-beginning 0) 'cooked-deco)))))))

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
  (pcase-let* ((`((,_index . (,_text ,_styles ,spans ,_table)))
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

(defun cooked-tests-bench--uniformity (line offset decos)
  "The UNIFORM the core would send for LINE, given the run\='s DECOS.

OFFSET is added to a decoration\='s start to make it relative to LINE."
  (if (= (string-bytes line) (length line))
      t
    (let ((covered (make-bool-vector (length line) nil)))
      (dolist (span decos)
        (pcase span
          (`(,from (glyph . ,packed))
           (let ((at (+ from offset)))
             (dotimes (i (cooked--glyph-pattern-cells packed))
               (when (< -1 (+ at i) (length line))
                 (aset covered (+ at i) t)))))))
      (and (cl-loop for i below (length line)
                    always (or (< (aref line i) 128) (aref covered i)))
           'glyph))))

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
that row actually begins, WIDTH its cell count, and UNIFORM t for a row of
one-byte characters, `glyph\=' for one whose multi-byte characters all sit in
box-glyph records, and nil otherwise -- which makes the box row `glyph\=' and
so too the tree listing\='s rows, whose padding the core absorbs into their
glyph runs.  The style and decoration offsets are checked to land inside the row they were written for,
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
      (should (= (length block) 4))
      (pcase-let* ((`(,text ,styles ,decos ,table) block)
                   (lines (split-string text "\n")))
        (should (= (length table) 2))
        (should (= (length lines) 2))
        (let ((offset 0))
          (cl-loop for line in lines
                   for row in table
                   do (pcase-let ((`(,start ,width ,uniform ,_wrapped ,hash) row))
                        (should (= start offset))
                        (should (= width (string-width line)))
                        (should (eq uniform
                                    (cooked-tests-bench--uniformity
                                     line (- start) decos)))
                        (should (fixnump hash))
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
byte-compiler does not check keyword arguments.  Running it here is eight
frames and eight sessions, cheap enough to pin."
  (let (rows)
    (cl-letf (((symbol-function 'message)
               (lambda (format &rest args)
                 (push (apply #'format-message format args) rows))))
      (cooked-bench-allocation))
    (should (= (length rows) 8))
    (dolist (row rows)
      (should (string-match-p "\\`  alloc, .* conses +[0-9]+ .* intervals +[0-9]+\\'"
                              row)))))

(ert-deftest cooked-a-box-row-drawn-as-bitmaps-is-not-measured ()
  "A row the core calls `glyph\=' skips the guard while its glyphs are bitmaps.

Every box glyph cooked draws itself is exactly one cell wide, so there is
nothing for `cooked--scale-offenders\=' to find and nothing to wrap: measuring
the font\='s glyph for a character the font never draws was nine tenths of what
a box-drawing frame allocated.  With the bitmaps turned off the font draws the
characters after all, and the same row has to be measured again."
  (cooked-bench--with-session '("/bin/sh" "-c" "sleep 300")
    (cooked-tests--settle-briefly)
    (let ((update (cooked-bench--update (cooked-bench--box-rows 4 40) :alt t))
          (walks 0))
      (cl-letf* ((real (symbol-function 'cooked--scale-offenders))
                 ((symbol-function 'cooked--scale-offenders)
                  (lambda (&rest args) (cl-incf walks) (apply real args))))
        (cooked--apply update)
        (should (= walks 0))
        (let ((cooked-box-drawing-images nil))
          (cooked--redraw cooked--session)
          (cooked--apply update))
        (should (> walks 0))))))

(ert-deftest cooked-a-cjk-row-is-still-scaled ()
  "A row the font draws still reaches the scale walk, and is scaled.

The other side of `cooked-a-box-row-drawn-as-bitmaps-is-not-measured\=': the
fast paths added for box drawing must not let a glyph that is really too big
through.  The metrics are the mock -- batch Emacs has no font to shape with --
and say the CJK character is half again wider than its two cells."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (let ((cooked-rejoin-wrapped-lines t)
          (cooked-glyph-scale-floor 0.5)
          (inhibit-read-only t))
      (insert "漢x\n")
      (cl-letf (((symbol-function 'cooked--glyph-metrics)
                 (lambda (beg _end _window _metrics)
                   (if (eq (char-after beg) ?漢) '(3 15 5 15) '(1 15 5 15))))
                ((symbol-function 'cooked--default-metrics)
                 (lambda (&rest _) '(15 5 1))))
        (cooked-tests--with-mocked-wrap 10
          (cooked--guard-row-width (point-min) 3 nil nil nil (sxhash-equal "漢x"))))
      (let ((display (get-text-property (point-min) 'display)))
        (should (assq 'height display))
        (should (< (cadr (assq 'height display)) 1.0))))))

;;;; The graphical scripts' prelude

(defvar cooked-tests--bench-script-args nil
  "Arguments `cooked-tests--bench-script' passes to Emacs before the script.")

(defun cooked-tests--bench-script (body)
  "Run a bench script whose measuring part is BODY, in a batch Emacs.

BODY is a string of forms placed after the prelude and its start call, as
scripts/bench-tree.el places its own; `probe--out' names the output file in it.
Return (EXIT . OUTPUT), OUTPUT being what the output file holds afterwards, or
nil if there is none.  The child gets `cooked-tests--bench-script-args' before
the script, and the caller's `process-environment'."
  (let* ((dir (make-temp-file "cooked-tests-script-" t))
         (script (expand-file-name "bench-probe.el" dir))
         (out (expand-file-name "probe.out" dir))
         (prelude (expand-file-name "scripts/bench-prelude" (cooked--root))))
    (unwind-protect
        (progn
          (with-temp-file script
            (insert ";;; bench-probe.el --- a probe  -*- lexical-binding: t; -*-\n"
                    (format "(eval-and-compile (load %S nil t))\n" prelude)
                    (format "(defconst probe--out %S)\n" out)
                    "(cooked-bench-script-start probe--out)\n"
                    body "\n(kill-emacs 0)\n"))
          (let ((exit (apply #'call-process
                             (expand-file-name invocation-name invocation-directory)
                             nil nil nil
                             `("-Q" "--batch" ,@cooked-tests--bench-script-args
                               "-l" ,script))))
            (cons exit (and (file-exists-p out)
                            (with-temp-buffer
                              (insert-file-contents out)
                              (buffer-string))))))
      (delete-directory dir t))))

(ert-deftest cooked-bench-script-refuses-a-busy-machine-unless-forced ()
  "The scripts judge the load by the batch bench\='s own rule.

A load of 9 over 16 CPUs is refused at the default fraction of one half, 7 is
not, and `COOKED_BENCH_FORCE\=' lets the refused one through.  The sentence
names the limit, because a refusal that does not say how quiet is quiet enough
sends the reader to the source."
  (load (expand-file-name "scripts/bench-prelude" (cooked--root)) nil t)
  (let ((cooked-bench-load-fraction 0.5))
    (should (string-match-p "load 9.00 over 16 cpus, limit 8.00"
                            (cooked-bench-script--refusal '(9.0 . 16) nil)))
    (should-not (cooked-bench-script--refusal '(7.0 . 16) nil))
    (should-not (cooked-bench-script--refusal '(9.0 . 16) "1"))))

(ert-deftest cooked-bench-script-runs-compiled-or-writes-why-it-did-not ()
  "A script measures compiled cooked, and on a busy machine measures nothing.

End to end, through a child Emacs, because both failures are silent from
inside.  An interpreted run reports numbers three times too slow with nothing
to say so, and a refusal printed to stdout under gamescope is never seen.  So
the refusal has to reach the output file with exit status 1 and the body must
not run, and a forced run must record `.elc\=' for both the script and
`cooked--apply\='.  A load fraction of 0 makes any machine busy."
  (let ((cooked-tests--bench-script-args
         '("--eval" "(setq cooked-bench-load-fraction 0.0)"))
        (body "(with-temp-file probe--out (insert (cooked-bench-script-provenance)))"))
    (let* ((process-environment (cons "COOKED_BENCH_FORCE" process-environment))
           (refused (cooked-tests--bench-script body)))
      (should (equal (car refused) 1))
      (should (string-match-p "\\`cooked-bench: machine is busy" (cdr refused))))
    (let* ((process-environment (cons "COOKED_BENCH_FORCE=1" process-environment))
           (ran (cooked-tests--bench-script body)))
      (should (equal (car ran) 0))
      (should (string-match-p
               "\\`compiled: bench-probe\\.elc, cooked--apply from .*/cooked-render\\.elc (byte-code); load .* BUSY, forced"
               (cdr ran))))))

(provide 'cooked-tests-bench)
;;; cooked-tests-bench.el ends here
