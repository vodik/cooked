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
                   ;; Offset 8 is where `cooked--render-block' hands the reader a
                   ;; record: START and END are the walker's business, the
                   ;; rendition is the face layer's.
                   (record (apply #'unibyte-string
                                  (cooked-bench--style-record
                                   0 4 packed-fg 0 0 cooked--attr-bold))))
        (should (equal (cooked--face-packed record 8)
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

(provide 'cooked-tests-bench)
;;; cooked-tests-bench.el ends here
