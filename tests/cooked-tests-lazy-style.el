;;; cooked-tests-lazy-style.el --- Scrollback coloured when it is looked at -*- lexical-binding: t; -*-

;;; Commentary:

;; The deferral of scrollback's faces: `cooked--defer-styles' taking a batch's
;; packed style records on as a debt, and `cooked--settle-styles' paying it out
;; when the text is displayed, copied, or about to be cut.
;;
;; Two tests carry most of the weight.  The first asserts the deferral happens
;; at all -- no `face' on scrollback that nobody has displayed -- because
;; everything else here would also pass if the faces were simply applied
;; eagerly.  The second asserts that it cannot be seen: the same bytes rendered
;; with the deferral on and off leave the same face at every position, however
;; they were split into drains on the way in.  The rest are the paths where a
;; debt could be lost or paid twice: a trim, a discard out of the middle, a
;; rendition id reused, a theme changed, a copy.
;;
;; How many drains a flood arrives in is the thing to be careful of here, and
;; `cooked-tests--owed-red' is where that is written down.  A flood that
;; arrives whole is deferred whole; the same flood in several drains has its
;; first rows on the screen before the later ones push them off, and
;; `cooked--promote-rows' keeps those where they stand, coloured already.  A
;; test that reaches for the first red run in scrollback and calls it owing is
;; therefore asserting about the machine's load, which is what four tests here
;; were doing.  Either drive the flood with `cooked--feed', which pins the
;; drains, or ask the buffer where the debt actually is.

;;; Code:

(require 'ert)
(require 'cooked-tests-helpers)
(require 'cooked-tests-render)

(defconst cooked-tests--red-flood
  "i=0; while [ $i -lt 90 ]; do printf '\\033[31mred\\033[0m line %s\\n' $i; i=$((i+1)); done; sleep 5"
  "A child printing ninety short lines, each with one red run on it.

Enough to push most of them off a 24-row screen, so that what is asserted on
is scrollback and not the live screen, which is never deferred.")

(defun cooked-tests--settled-flood ()
  "Wait for `cooked-tests--red-flood' to have printed its last line."
  (should (cooked-tests--settle
           (lambda () (string-match-p "line 89" (cooked-tests--text))))))

(defun cooked-tests--scrollback-red ()
  "The position of the first red run in scrollback, which must be there."
  (let ((screen (cooked--screen-start-position)))
    (goto-char (point-min))
    (should (search-forward "red" nil t))
    (let ((pos (match-beginning 0)))
      (should (< pos screen))
      pos)))

(defun cooked-tests--owed-red ()
  "The position of a red run in scrollback whose colours are still owed.

Not the first red run in scrollback, which is what a test asserting about the
deferral wants but not what it gets.  A row the live screen was already holding
when it scrolled off is promoted where it stands -- `cooked--promote-rows'
moves `cooked--screen-start' past it rather than inserting it again -- so it
wears the face it was drawn with and owes nothing.  A flood arriving in one
drain never reaches the screen at all and so is deferred whole; the same flood
arriving in several drains, which is what a loaded machine makes of it, opens
the transcript with a stretch of promoted rows instead.  Three tests here read
that stretch as the deferral having failed, about one run in four at a load
average above twenty."
  (let ((screen (cooked--screen-start-position))
        (found nil))
    (goto-char (point-min))
    (while (and (not found) (search-forward "red" screen t))
      (let ((pos (match-beginning 0)))
        (when (get-text-property pos 'cooked-pending-style)
          (setq found pos))))
    (should found)
    found))

(defun cooked-tests--red ()
  "The foreground `\\033[31m' resolves to in this buffer."
  (aref cooked-color-names 1))

(defun cooked-tests--face-runs ()
  "Every `face' run in the buffer, as (START LENGTH FACE) from `point-min'.

Offsets rather than positions, so that two renders of the same bytes compare
equal whatever else is in the buffer."
  (let ((runs nil)
        (pos (point-min)))
    (while (< pos (point-max))
      (let ((next (next-single-property-change pos 'face nil (point-max))))
        (push (list (- pos (point-min)) (- next pos)
                    (get-text-property pos 'face))
              runs)
        (setq pos next)))
    (nreverse runs)))

(defun cooked-tests--pending-style-positions ()
  "Every position in the buffer still carrying an unpaid styling debt."
  (let ((found nil)
        (pos (point-min)))
    (while (and pos (< pos (point-max)))
      (if (get-text-property pos 'cooked-pending-style)
          (push pos found)
        nil)
      (setq pos (next-single-property-change pos 'cooked-pending-style)))
    (nreverse found)))

(defun cooked-tests--red-lines (from to)
  "Bytes for red lines numbered FROM to TO, ready for `cooked--feed'.

`cooked--feed' hands the emulator bytes directly rather than through a pty, so
unlike `cooked-tests--red-flood' -- a shell script whose newlines the kernel's
`ONLCR' turns into \\r\\n on their way out -- the carriage return has to be
spelled here."
  (mapconcat (lambda (n) (format "\033[31mred\033[0m line %d\r\n" n))
             (number-sequence from to) ""))

(defun cooked-tests--first-pending (pos limit)
  "The first position from POS, below LIMIT, still owing a styling debt.

Not simply POS itself: a screen too small to hold everything fed since the
last drain promotes its own oldest rows to scrollback before appending the
rest as a new batch, and a promoted row was on its way to being displayed
already, so it was never deferred.  A batch fed onto such a screen can
therefore open with a stretch of already-coloured text before its own debt
begins."
  (let ((pos pos))
    (while (and pos (< pos limit) (not (get-text-property pos 'cooked-pending-style)))
      (setq pos (next-single-property-change pos 'cooked-pending-style nil limit)))
    (and pos (< pos limit) pos)))

(ert-deftest cooked-scrollback-is-not-coloured-until-it-is-displayed ()
  "The deferral itself: faces absent after a flood, present once looked at."
  :tags '(pty)
  (cooked-tests--with-session (list "/bin/sh" "-c" cooked-tests--red-flood)
    (cooked-tests--settled-flood)
    (let ((pos (cooked-tests--owed-red)))
      (should (get-text-property pos 'cooked-pending-style))
      (should-not (get-text-property pos 'face))
      (should (> cooked--pending-styles 0))
      ;; The live screen is never deferred: its rows are on their way to being
      ;; displayed by definition.
      (save-excursion
        (goto-char (cooked--screen-start-position))
        (should (search-forward "red" nil t))
        (should (equal (cooked--face-color (get-text-property (match-beginning 0) 'face)
                                  :foreground)
                       (cooked-tests--red))))
      (cooked-tests--fontify)
      (should (equal (cooked--face-color (get-text-property pos 'face) :foreground)
                     (cooked-tests--red)))
      (should-not (get-text-property pos 'cooked-pending-style))
      (should (= 0 cooked--pending-styles))
      (should-not (cooked-tests--pending-style-positions)))))

(defconst cooked-tests--split-flood
  (concat "\033[31mred\033[0m one\r\n"
          "\033[32mgreen wrapping past the edge\033[0m\r\n"
          "\033[34mblue\r\nstill blue\033[0m\r\n"
          "plain last\r\n")
  "A small flood holding every shape a style run can be cut in half by.

Fed to a three by twelve screen, so more of it is scrollback than is ever on
the screen at once.  A run inside one row, a run wrapped across three rows of
one logical line -- which `cooked-rejoin-wrapped-lines' joins back up on the
way into the transcript -- a run that outlives its own line and carries into
the next, a reset at the end of a line, and a line with no styling on it at
all.  Ninety-six bytes, which is what makes cutting it at every one of them
affordable.")

(defun cooked-tests--split-render (cut lazy spans)
  "Render `cooked-tests--split-flood' cut into two drains at byte CUT.

LAZY is what `cooked-lazy-scrollback-styles' is bound to and SPANS what
`cooked--style-piece-spans' is, so that a handful of style records already
makes several pieces.  The answer is (TEXT . RUNS) once everything owed has
been paid, ready to be compared with another arm's.

A CUT at either end feeds the flood in one drain, which is the shape an idle
machine produces; every CUT between is a drain boundary falling inside a
sequence, inside a styled run, inside a row, or inside a wrapped line."
  (let ((cooked-lazy-scrollback-styles lazy)
        (cooked--style-piece-spans spans))
    (cooked-tests--with-fed-screen 3 12
      (if (or (<= cut 0) (>= cut (length cooked-tests--split-flood)))
          (cooked-tests--fed cooked-tests--split-flood)
        (cooked-tests--fed (substring cooked-tests--split-flood 0 cut))
        (cooked-tests--fed (substring cooked-tests--split-flood cut)))
      (cooked--settle-all-styles)
      (cons (buffer-substring-no-properties (point-min) (point-max))
            (cooked-tests--face-runs)))))

(ert-deftest cooked-deferred-and-eager-styling-agree-however-the-flood-is-split ()
  "The deferral cannot be seen: the same bytes leave the same faces either way.

However the child's output is split into drains, which is the part that used to
be left to chance.  This was two real children racing the same flood, each
waited for by its text and then compared run for run, and it failed about one
run in four at a load average above twenty -- not on a colour but on the
trailing newline after the last line, which one session had drained and the
other had not.  `cooked-tests--text' trims that away, so the text check the
test made first could not see the very difference the face runs then tripped
over.  Nothing about the deferral was wrong.

So both arms are fed instead, the same bytes cut at the same byte, and the only
thing that differs between them is `cooked-lazy-scrollback-styles'.  Every byte
offset of the flood is tried as the drain boundary, at three piece sizes, which
between them cover a boundary landing inside an SGR sequence, inside a styled
run, inside a wrapped line -- so the second drain
opens mid-row and the batch begins at a `:head' seam -- and on the rows the
first drain left on the screen, which the second promotes into scrollback where
they stand rather than deferring them.

Piece sizes of one, two and three: one puts a cut at every span boundary there
is, and the other two put a drain boundary inside a piece holding more than one
span.  The real value is two thousand, which no flood this size would reach."
  (let ((cuts 0))
    (dotimes (cut (1+ (length cooked-tests--split-flood)))
      (let ((eager (cooked-tests--split-render cut nil 1)))
        ;; Worth comparing: there are faces in the answer, and text under them.
        (should (seq-find (lambda (run) (nth 2 run)) (cdr eager)))
        (dolist (spans '(1 2 3))
          (setq cuts (1+ cuts))
          (should (equal (cooked-tests--split-render cut t spans) eager)))))
    (should (> cuts 200))))

(ert-deftest cooked-trimming-scrollback-leaves-no-unpaid-batch-behind ()
  "A trim throws away what it cuts and pays for the part of a batch it keeps."
  :tags '(pty)
  (let ((cooked-scrollback-lines 20))
    (cooked-tests--with-session (list "/bin/sh" "-c" cooked-tests--red-flood)
      (cooked-tests--settled-flood)
      ;; The cap was reached and enforced, so at least one cut landed in the
      ;; middle of a batch's text.
      (should (< (line-number-at-pos (point-max)) 60))
      ;; Whatever survived is either paid for already or still owed, and
      ;; nothing is owed by text that has gone: every red run in the buffer is
      ;; red once the buffer is displayed, and nothing is left owing.
      (cooked-tests--fontify)
      (should (= 0 cooked--pending-styles))
      (should-not (cooked-tests--pending-style-positions))
      (goto-char (point-min))
      (let ((seen 0))
        (while (search-forward "red" nil t)
          (setq seen (1+ seen))
          (should (equal (cooked--face-color (get-text-property (match-beginning 0) 'face)
                                    :foreground)
                         (cooked-tests--red))))
        (should (> seen 10))))))

(ert-deftest cooked-discarding-the-middle-of-a-batch-pays-for-both-sides ()
  "One command's output cut out of the middle leaves the rest of its batch red.

Driven through `cooked--feed' and an explicit drain rather than a real child
and `cooked-tests--settle': a real child's flood arrives as one drain when the
machine is idle, and this test used to assume exactly that, but under load it
can arrive as several, each its own batch -- see the next test for what that
does to the assertion.  This one instead forces the shape the doomed path has
to get right regardless of load: `cooked--style-piece-spans' bound down turns
one flood, fed and drained once, into several pieces, and the cut both starts
inside a piece that is not the batch's first -- so its offset is not zero --
and ends exactly on another piece's boundary, dropping the pieces between
outright.

Asserted before anything is displayed, which is the point: the colours on
either side of the cut are put on by the cut itself, since the offsets they
are counted from do not survive it."
  (let ((cooked--style-piece-spans 6))
    (cooked-tests--with-fed-screen 5 20
      (cooked-tests--fed (cooked-tests--red-lines 0 39))
      (let* ((screen (cooked--screen-start-position))
             (first-owed (cooked-tests--first-pending (point-min) screen))
             (first-piece (cooked--pending-style-bounds first-owed))
             ;; The cut starts inside the SECOND piece, not the first, so the
             ;; survivor it paints is based at a nonzero offset into the batch.
             (left (cooked--pending-style-bounds (cdr first-piece)))
             (left-from (car left))
             (beg (+ left-from 3))
             ;; And ends exactly where a later piece begins: nothing of that
             ;; piece is in the cut, and nothing of it should be painted.
             (past (cdr (cooked--pending-style-bounds (cdr left))))
             (end (car (cooked--pending-style-bounds past))))
        (should (< beg end))
        (let ((owed-before cooked--pending-styles))
          (cooked--discard-scrollback-region beg end)
          ;; At least the pieces strictly between LEFT and END are gone.
          (should (< cooked--pending-styles owed-before))
          ;; The survivor before BEG is already coloured.
          (goto-char left-from)
          (let ((seen 0))
            (while (search-forward "red" beg t)
              (setq seen (1+ seen))
              (should (equal (cooked--face-color (get-text-property (match-beginning 0) 'face)
                                        :foreground)
                             (cooked-tests--red))))
            (should (> seen 0)))
          ;; The piece just past END was never touched, and is still owed,
          ;; sitting at BEG now that the cut has closed the gap in front of it.
          (should (get-text-property beg 'cooked-pending-style)))))))

(ert-deftest cooked-discarding-across-a-batch-boundary-pays-only-what-it-touches ()
  "A batch the discard never reaches stays owed; that is not a leftover bug.

The failure this guards: under load a flood can arrive as several drains, each
its own batch, and a discard landing in one of them leaves the others exactly
as owing as it found them.  `(should-not (cooked-tests--pending-style-positions))'
over the whole buffer read that as a bug once, on a run at loadavg 8.2, because
the test that asserted it had only ever been fed as one batch.  Reproduced here
without load: three feeds, each drained before the next, make three batches,
and the cut spans the boundary between the first two, entirely clear of the
third."
  (let ((cooked--style-piece-spans 6))
    (cooked-tests--with-fed-screen 5 20
      (cooked-tests--fed (cooked-tests--red-lines 0 19))
      (let ((batch1-end (cooked--screen-start-position)))
        (cooked-tests--fed (cooked-tests--red-lines 20 39))
        (let ((batch2-end (cooked--screen-start-position)))
          (cooked-tests--fed (cooked-tests--red-lines 40 59))
          (let* ((batch3-end (cooked--screen-start-position))
                 (batch2-owed (cooked-tests--first-pending batch1-end batch2-end))
                 ;; A few characters into batch2's second piece, again for a
                 ;; nonzero offset, so the cut both crosses the batch boundary
                 ;; above it and starts mid-piece below it.
                 (left (cooked--pending-style-bounds
                        (cdr (cooked--pending-style-bounds batch2-owed))))
                 (left-from (car left))
                 (beg (+ left-from 3))
                 (end (- batch2-end 5))
                 (owed-before cooked--pending-styles))
            (should (< batch1-end left-from))
            (should (< beg end))
            (should (< end batch2-end))
            (cooked--discard-scrollback-region beg end)
            (should (< cooked--pending-styles owed-before))
            ;; batch1, entirely above BEG, is untouched and still fully owed.
            (should (get-text-property (point-min) 'cooked-pending-style))
            ;; batch3, entirely below the cut, is untouched too, now sitting
            ;; earlier in the buffer by however much the cut removed.
            (should (get-text-property (- batch3-end (- end beg) 1) 'cooked-pending-style))
            ;; The survivor above the cut, inside batch2, is already coloured.
            (goto-char left-from)
            (let ((seen 0))
              (while (search-forward "red" beg t)
                (setq seen (1+ seen))
                (should (equal (cooked--face-color (get-text-property (match-beginning 0) 'face)
                                          :foreground)
                               (cooked-tests--red))))
              (should (> seen 0)))
            ;; And nothing is left owing right where the cut closed.
            (should-not (get-text-property beg 'cooked-pending-style))))))))

(ert-deftest cooked-reusing-a-rendition-id-pays-the-debt-that-named-it ()
  "An id about to mean something else colours the batches that still mean it.

The core frees a rendition id once no cell names it, which every batch of
scrollback has stopped doing, and mints it again for another rendition.  So
`cooked--install-styles' settles what is owed before it redefines one, and this
asks it to redefine the very id the flood's red runs name."
  :tags '(pty)
  (cooked-tests--with-session (list "/bin/sh" "-c" cooked-tests--red-flood)
    (cooked-tests--settled-flood)
    (let ((pos (cooked-tests--scrollback-red))
          (id nil))
      (should (> cooked--pending-styles 0))
      (dotimes (i (length cooked--style-specs))
        (when (and (null id) (aref cooked--style-specs i))
          (setq id i)))
      (should id)
      ;; A different rendition under the same id, as a collection and a remint
      ;; would announce it.
      (cooked--install-styles (list (list id 4 nil nil cooked--attr-bold)))
      (should (= 0 cooked--pending-styles))
      (should-not (get-text-property pos 'cooked-pending-style))
      (should (equal (cooked--face-color (get-text-property pos 'face) :foreground)
                     (cooked-tests--red))))))

(ert-deftest cooked-a-theme-change-leaves-an-unpaid-batch-to-resolve-later ()
  "Flushing the resolved faces under a pending batch costs it no colour.

A batch waiting to be displayed holds rendition ids, not faces, so a theme
change between the output and the looking is answered by resolving late --
which is the one way deferred scrollback differs from scrollback already
coloured, and it differs in the direction of being more right."
  :tags '(pty)
  (cooked-tests--with-session (list "/bin/sh" "-c" cooked-tests--red-flood)
    (cooked-tests--settled-flood)
    (let ((pos (cooked-tests--owed-red)))
      (should (get-text-property pos 'cooked-pending-style))
      (cooked--flush-face-cache)
      (should (get-text-property pos 'cooked-pending-style))
      (cooked-tests--fontify)
      (should (equal (cooked--face-color (get-text-property pos 'face) :foreground)
                     (cooked-tests--red))))))

(ert-deftest cooked-copying-undisplayed-scrollback-takes-its-colours-along ()
  "`filter-buffer-substring' pays the debt over the region it is lifting out."
  :tags '(pty)
  (cooked-tests--with-session (list "/bin/sh" "-c" cooked-tests--red-flood)
    (cooked-tests--settled-flood)
    (let* ((pos (cooked-tests--scrollback-red))
           (text (filter-buffer-substring pos (+ pos 3))))
      (should (equal (substring-no-properties text) "red"))
      (should (equal (cooked--face-color (get-text-property 0 'face text) :foreground)
                     (cooked-tests--red))))))

(ert-deftest cooked-an-osc-8-link-in-scrollback-is-hung-on-without-waiting ()
  "Links do not wait for a display, because the buffer is read for them.

`cooked-next-link' and the mouse both ask the text, so the destinations go on as
the batch is inserted; only the faces are deferred.  An unstyled link run is
given `cooked-link' then and there, which is the one face a deferred batch can
carry before anybody looks at it."
  :tags '(pty)
  (cooked-tests--with-session
      (list "/bin/sh" "-c"
            (concat "i=0; while [ $i -lt 90 ]; do "
                    "printf '\\033]8;;https://example.com/\\033\\\\here\\033]8;;\\033\\\\ %s\\n' $i; "
                    "i=$((i+1)); done; sleep 5"))
    (should (cooked-tests--settle
             (lambda () (string-match-p "here 89" (cooked-tests--text)))))
    (goto-char (point-min))
    (should (search-forward "here" nil t))
    (let ((pos (match-beginning 0)))
      (should (< pos (cooked--screen-start-position)))
      (should (equal (cooked-link-uri pos) "https://example.com/"))
      (should (eq (get-text-property pos 'face) 'cooked-link)))))

(ert-deftest cooked-a-deferred-batch-registers-the-pass-that-pays-it ()
  "The debt is work of its own: it registers jit-lock where nothing else would.

A session with the URL guess off and no scan layer loaded registers no
fontification pass at all -- that is what `cooked--sync-fontification' is for --
and deferred colours would then never be put on.  So the count of unpaid
batches is one of the things the registration follows."
  :tags '(pty)
  (let ((cooked-detect-links nil)
        (cooked-link-scan-functions nil))
    (cooked-tests--with-session (list "/bin/sh" "-c" cooked-tests--red-flood)
      (cooked-tests--settled-flood)
      (should (> cooked--pending-styles 0))
      (should (memq #'cooked--fontify-region jit-lock-functions))
      (let ((pos (cooked-tests--scrollback-red)))
        (cooked-tests--fontify)
        (should (equal (cooked--face-color (get-text-property pos 'face) :foreground)
                       (cooked-tests--red)))))))

(ert-deftest cooked-a-hidden-buffer-defers-its-scrollback-as-a-shown-one-does ()
  "The drain that leaves the screen out still appends scrollback, and still
defers its colours -- which is the case the deferral is worth most in, nobody
having looked at the buffer at all."
  :tags '(pty)
  (cooked-tests--with-session
      (list "/bin/sh" "-c" (concat "read -r _; " cooked-tests--red-flood))
    (should (cooked-tests--settle (lambda () cooked--session)))
    (cooked-tests--hide-buffer)
    ;; The child prints nothing until it is told to, so every row of the flood
    ;; arrives at a buffer no window shows: `cooked--apply-withheld', not
    ;; `cooked--apply'.
    (cooked--send-to-child "\n")
    (should (cooked-tests--settle
             (lambda () (string-match-p "line 89" (cooked-tests--text)))))
    (should (> cooked--pending-styles 0))
    (should-not (get-text-property (cooked-tests--scrollback-red) 'face))
    (cooked-tests--show-buffer)
    (cooked-tests--fontify)
    ;; Found again rather than remembered: showing the buffer drains the screen
    ;; the drains so far left out, and what that evicts moves every position in
    ;; the scrollback below it.
    (should (equal (cooked--face-color (get-text-property (cooked-tests--scrollback-red)
                                                 'face)
                              :foreground)
                   (cooked-tests--red)))
    (should (= 0 cooked--pending-styles))))

(ert-deftest cooked-a-decorated-batch-of-scrollback-keeps-its-colours-eager ()
  "A decoration reads the face off the text as it lands, so it cannot wait.

`cooked--apply-shade' blends the cell's own two colours into the `face' it
writes over the shade, so a rendition that arrived later would be both
invisible to the blend and written over it.  The block is the unit either way,
so a batch with any decoration span on it is coloured as it is inserted."
  :tags '(pty)
  (cooked-tests--with-session
      (list "/bin/sh" "-c"
            (concat "i=0; while [ $i -lt 90 ]; do "
                    "printf '\033[31m\342\226\222\342\226\222\033[0m shade %s\n' $i; "
                    "i=$((i+1)); done; sleep 5"))
    (should (cooked-tests--settle
             (lambda () (string-match-p "shade 89" (cooked-tests--text)))))
    (goto-char (point-min))
    (should (search-forward "▒" nil t))
    (let ((pos (match-beginning 0)))
      (should (< pos (cooked--screen-start-position)))
      (should-not (get-text-property pos 'cooked-pending-style))
      (should (= 0 cooked--pending-styles))
      ;; Whether the shade is painted at all depends on what this Emacs can
      ;; display; what the eagerness is for is that the rendition is there to
      ;; be read either way.
      (should (get-text-property pos 'face)))))

(ert-deftest cooked-settling-a-chunk-pays-only-for-the-pieces-it-overlaps ()
  "A flooded batch is cut into pieces, and a jit-lock chunk pays for its own.

One drain's scrollback is one block, and under a flood that is thousands of
rows: the whole batch owed its colours as a unit once, so the first jit-lock
chunk to touch a flooded coloured transcript paid for the flood rather than for
the window.  `cooked--style-piece-spans' is bound down to a handful here so
that forty short lines make several pieces, which a real flood would take
tens of thousands of lines to do.

The count dropping by exactly the number of pieces the chunk overlapped is the
assertion: settling one piece must leave the rest of the batch owing.

Fed through `cooked--feed' and drained once rather than driven by a real child,
so that the flood is one batch whatever the machine is doing.  It was a real
child, and it read the first red run in scrollback as owing: under load the
flood arrives as several drains and the transcript then opens with rows the
screen already held, promoted where they stand and coloured already, so
settling a chunk there paid nothing and the count did not move."
  (let ((cooked--style-piece-spans 8))
    (cooked-tests--with-fed-screen 5 20
      (cooked-tests--fed (cooked-tests--red-lines 0 39))
      (let* ((pos (cooked-tests--owed-red))
             (owing (cooked-tests--pending-style-positions))
             (before cooked--pending-styles)
             (bounds (cooked--pending-style-bounds pos)))
        ;; Several pieces, and the count agrees with what is on the text.
        (should (> before 1))
        (should (= before (length owing)))
        ;; A chunk wholly inside one piece settles that piece and no other.
        (should (> (- (cdr bounds) (car bounds)) 2))
        (cooked--settle-styles (car bounds) (1+ (car bounds)))
        (should (= cooked--pending-styles (1- before)))
        (should-not (get-text-property pos 'cooked-pending-style))
        (should (equal (cooked--face-color (get-text-property pos 'face) :foreground)
                       (cooked-tests--red)))
        ;; The piece above this one is still owing, and its colours are still
        ;; only owed: nothing was paid for text the chunk did not name.
        (let ((later (car (last (cooked-tests--pending-style-positions)))))
          (should later)
          (should (> later (cdr bounds)))
          (should-not (get-text-property later 'face)))
        ;; And the rest of the transcript settles from where it is, each piece
        ;; finding its own base off its own interval.
        (cooked-tests--fontify)
        (should (= 0 cooked--pending-styles))
        (goto-char (point-min))
        (let ((seen 0))
          (while (search-forward "red" nil t)
            (setq seen (1+ seen))
            (should (equal (cooked--face-color
                            (get-text-property (match-beginning 0) 'face)
                            :foreground)
                           (cooked-tests--red))))
          (should (= seen 40)))))))

(ert-deftest cooked-a-promoted-row-is-coloured-already-and-owes-nothing ()
  "Rows the screen was holding are promoted with their faces on them.

`cooked--promote-rows' moves `cooked--screen-start' past rows the buffer
already holds rather than rendering them again, so they keep the faces they
were drawn with on the live screen and there is nothing left to defer.  A batch
deferred immediately below such a stretch has to settle from its own start all
the same, which is the second half of this: the promoted rows and the deferred
batch abut with no seam between them, and a piece's base is read off its own
`cooked-pending-style' interval rather than off the top of the transcript.

This is the shape three tests here used to trip over.  Each asked for the first
red run in scrollback and assumed it was owing; under load a flood arrives as
several drains, so the rows of the first ones are on the screen by the time the
later ones scroll them off, and the transcript opens with promoted rows."
  (let ((cooked--style-piece-spans 6))
    (cooked-tests--with-fed-screen 5 20
      ;; Less than a screenful: nothing is scrollback yet, so the next feed has
      ;; rows to promote rather than rows to render.
      (cooked-tests--fed (cooked-tests--red-lines 0 3))
      (should (= 0 cooked--pending-styles))
      (cooked-tests--fed (cooked-tests--red-lines 4 23))
      (let ((screen (cooked--screen-start-position)))
        ;; The promoted rows: scrollback, coloured, owing nothing.
        (should (> screen (point-min)))
        (should-not (get-text-property (point-min) 'cooked-pending-style))
        (should (equal (cooked--face-color (get-text-property (point-min) 'face)
                                           :foreground)
                       (cooked-tests--red)))
        ;; And the batch below them, which is owing and has no colour yet.
        (let ((owed (cooked-tests--first-pending (point-min) screen)))
          (should owed)
          (should (> cooked--pending-styles 0))
          (should-not (get-text-property owed 'face))
          (cooked-tests--fontify)
          (should (= 0 cooked--pending-styles))
          (goto-char (point-min))
          (let ((seen 0))
            (while (search-forward "red" nil t)
              (setq seen (1+ seen))
              (should (equal (cooked--face-color
                              (get-text-property (match-beginning 0) 'face)
                              :foreground)
                             (cooked-tests--red))))
            (should (= seen 24))))))))

(ert-deftest cooked-a-trim-landing-inside-a-piece-pays-what-it-leaves-behind ()
  "The cap cutting a piece in half colours the half that stays.

`cooked--trim-scrollback' goes through `cooked--settle-styles' with DOOMED, so
a piece wholly above the cap is thrown away uncoloured -- which is what makes a
trim free under a flood -- and the one the cap falls inside pays for its tail
before losing its head.  `cooked-scrollback-lines' is small and
`cooked--style-piece-spans' smaller still, so the cap is reached several times
over and lands inside a piece rather than between two."
  (let ((cooked--style-piece-spans 6)
        (cooked-scrollback-lines 9))
    (cooked-tests--with-fed-screen 5 20
      (cooked-tests--fed (cooked-tests--red-lines 0 29))
      ;; The cap was reached and enforced: most of the flood is gone.
      (should (< (line-number-at-pos (point-max)) 20))
      (cooked-tests--fontify)
      (should (= 0 cooked--pending-styles))
      (should-not (cooked-tests--pending-style-positions))
      (goto-char (point-min))
      (let ((seen 0))
        (while (search-forward "red" nil t)
          (setq seen (1+ seen))
          (should (equal (cooked--face-color (get-text-property (match-beginning 0) 'face)
                                             :foreground)
                         (cooked-tests--red))))
        (should (> seen 5))))))

(ert-deftest cooked-redefining-a-rendition-pays-every-batch-that-named-it ()
  "An id about to mean something else settles more than the newest batch.

`cooked--install-styles' calls `cooked--settle-all-styles', so every batch in
the buffer that still names the old rendition is coloured while the id still
means it -- not only the one the drain that redefined it appended.  Two feeds,
each drained, leave two batches owing, and the redefinition has to find both."
  (let ((cooked--style-piece-spans 6))
    (cooked-tests--with-fed-screen 5 20
      (cooked-tests--fed (cooked-tests--red-lines 0 19))
      (let ((first-batch-end (cooked--screen-start-position)))
        (cooked-tests--fed (cooked-tests--red-lines 20 39))
        (should (> cooked--pending-styles 1))
        ;; Both batches are owing something before the redefinition lands.
        (should (cooked-tests--first-pending (point-min) first-batch-end))
        (should (cooked-tests--first-pending first-batch-end
                                             (cooked--screen-start-position)))
        (let ((id nil))
          (dotimes (i (length cooked--style-specs))
            (when (and (null id) (aref cooked--style-specs i))
              (setq id i)))
          (should id)
          (cooked--install-styles (list (list id 4 nil nil cooked--attr-bold))))
        (should (= 0 cooked--pending-styles))
        (should-not (cooked-tests--pending-style-positions))
        (goto-char (point-min))
        (let ((seen 0))
          (while (search-forward "red" nil t)
            (setq seen (1+ seen))
            (should (equal (cooked--face-color
                            (get-text-property (match-beginning 0) 'face)
                            :foreground)
                           (cooked-tests--red))))
          (should (= seen 40)))))))

(ert-deftest cooked-scrollback-follows-a-theme-whether-it-was-coloured-or-not ()
  "Rows in the scrollback do not keep the colours they were drawn in any more.

That sentence was true of every version that wrote a colour onto the text, and
it is the thing this file's own deferral made worse: with a batch coloured
whenever somebody first looked at it, the seam between the old theme and the
new one could fall anywhere in the transcript.  There is no seam now, because
there is no colour on the text -- a red run wears `cooked-fg-1' and that face
is what the theme moves.

Both kinds of scrollback are here on purpose.  One batch is paid before the
theme lands, so it holds a `face' value built under the old red; the batch
after it is still owing, and is paid afterwards.  They have to agree, and they
have to agree on the new colour.  Nothing is redrawn and nothing walks the
buffer: the paid batch's `face' is the very same cons after the theme as
before, which is what `eq' is asserting."
  :tags '(pty)
  (let ((loop (concat "i=0; while [ $i -lt 90 ]; do "
                      "printf '\\033[31mred\\033[0m line %s\\n' $i; i=$((i+1)); done; ")))
    (cooked-tests--with-session
        (list "/bin/sh" "-c" (concat loop "read -r _; " loop "sleep 5"))
      (cooked-tests--settled-flood)
      ;; The first flood, paid: this is scrollback carrying faces built under
      ;; the theme in force when it scrolled off.
      (cooked-tests--fontify)
      (let ((paid (cooked-tests--scrollback-red))
            (owing nil))
        (should (= 0 cooked--pending-styles))
        ;; And a second flood behind it, which nobody has looked at.
        (cooked--send-to-child "\n")
        (should (cooked-tests--settle (lambda () (> cooked--pending-styles 0))))
        (setq owing (car (cooked-tests--pending-style-positions)))
        (should owing)
        (should-not (get-text-property owing 'face))
        (let ((face (get-text-property paid 'face)))
          (should face)
          (should (equal (cooked--face-color face :foreground) (cooked--color 1)))
          (cooked-tests--with-ansi-red "#123456"
            (should (eq (get-text-property paid 'face) face))
            (should (equal (cooked--face-color face :foreground) "#123456"))
            (cooked-tests--fontify)
            (should (equal (cooked--face-color (get-text-property owing 'face)
                                               :foreground)
                           "#123456")))
          ;; And back again when the theme goes, with the same value on the text.
          (should (eq (get-text-property paid 'face) face))
          (should (equal (cooked--face-color face :foreground)
                         (cooked--color 1))))))))

(provide 'cooked-tests-lazy-style)
;;; cooked-tests-lazy-style.el ends here
