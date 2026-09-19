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
;; with the deferral on and off leave the same face at every position.  The
;; rest are the paths where a debt could be lost or paid twice: a trim, a
;; discard out of the middle, a rendition id reused, a theme changed, a copy.

;;; Code:

(require 'ert)
(require 'cooked-tests-helpers)

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

(ert-deftest cooked-scrollback-is-not-coloured-until-it-is-displayed ()
  "The deferral itself: faces absent after a flood, present once looked at."
  (cooked-tests--with-session (list "/bin/sh" "-c" cooked-tests--red-flood)
    (cooked-tests--settled-flood)
    (let ((pos (cooked-tests--scrollback-red)))
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

(ert-deftest cooked-deferred-and-eager-styling-agree-at-every-position ()
  "The deferral cannot be seen: the same bytes leave the same faces either way.

Rendered twice, once with `cooked-lazy-scrollback-styles' off, and compared run
for run over the whole buffer -- which is the assertion that covers the runs no
other test here names, the reset at the end of a line and the blanks between."
  (let (eager lazy text)
    (let ((cooked-lazy-scrollback-styles nil))
      (cooked-tests--with-session (list "/bin/sh" "-c" cooked-tests--red-flood)
        (cooked-tests--settled-flood)
        (should (= 0 cooked--pending-styles))
        (cooked-tests--fontify)
        (setq eager (cooked-tests--face-runs)
              text (cooked-tests--text))))
    (cooked-tests--with-session (list "/bin/sh" "-c" cooked-tests--red-flood)
      (cooked-tests--settled-flood)
      (cooked-tests--fontify)
      (setq lazy (cooked-tests--face-runs))
      (should (equal (cooked-tests--text) text)))
    (should (equal lazy eager))
    ;; And the comparison is worth something: there were faces to compare.
    (should (seq-find (lambda (run) (nth 2 run)) eager))))

(ert-deftest cooked-trimming-scrollback-leaves-no-unpaid-batch-behind ()
  "A trim throws away what it cuts and pays for the part of a batch it keeps."
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

Asserted before anything is displayed, which is the point: the colours on
either side of the cut are put on by the cut itself, since the offsets they are
counted from do not survive it."
  (cooked-tests--with-session (list "/bin/sh" "-c" cooked-tests--red-flood)
    (cooked-tests--settled-flood)
    (let* ((pos (cooked-tests--scrollback-red))
           (bounds (cooked--pending-style-bounds pos))
           (from (car bounds))
           (to (cdr bounds))
           ;; A cut strictly inside the batch, on line boundaries, so that both
           ;; edges are the same batch's.
           (beg (save-excursion (goto-char (+ from (/ (- to from) 3)))
                                (line-beginning-position)))
           (end (save-excursion (goto-char (+ from (/ (* 2 (- to from)) 3)))
                                (line-beginning-position))))
      (should (< from beg))
      (should (< beg end))
      (should (< end to))
      (cooked--discard-scrollback-region beg end)
      (should-not (cooked-tests--pending-style-positions))
      (should (= 0 cooked--pending-styles))
      (goto-char (point-min))
      (while (search-forward "red" nil t)
        (should (equal (cooked--face-color (get-text-property (match-beginning 0) 'face)
                                  :foreground)
                       (cooked-tests--red)))))))

(ert-deftest cooked-reusing-a-rendition-id-pays-the-debt-that-named-it ()
  "An id about to mean something else colours the batches that still mean it.

The core frees a rendition id once no cell names it, which every batch of
scrollback has stopped doing, and mints it again for another rendition.  So
`cooked--install-styles' settles what is owed before it redefines one, and this
asks it to redefine the very id the flood's red runs name."
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
  (cooked-tests--with-session (list "/bin/sh" "-c" cooked-tests--red-flood)
    (cooked-tests--settled-flood)
    (let ((pos (cooked-tests--scrollback-red)))
      (should (get-text-property pos 'cooked-pending-style))
      (cooked--flush-face-cache)
      (should (get-text-property pos 'cooked-pending-style))
      (cooked-tests--fontify)
      (should (equal (cooked--face-color (get-text-property pos 'face) :foreground)
                     (cooked-tests--red))))))

(ert-deftest cooked-copying-undisplayed-scrollback-takes-its-colours-along ()
  "`filter-buffer-substring' pays the debt over the region it is lifting out."
  (cooked-tests--with-session (list "/bin/sh" "-c" cooked-tests--red-flood)
    (cooked-tests--settled-flood)
    (let* ((pos (cooked-tests--scrollback-red))
           (text (filter-buffer-substring pos (+ pos 3))))
      (should (equal (substring-no-properties text) "red"))
      (should (equal (cooked--face-color (get-text-property 0 'face text) :foreground)
                     (cooked-tests--red))))))

(ert-deftest cooked-an-osc-8-link-in-scrollback-is-hung-on-without-waiting ()
  "Links do not wait for a display, because the buffer is read for them.

`cooked-next-link' and the mouse both ask the text, so the ids go on as the
batch is inserted; only the faces are deferred.  An unstyled link run is given
`cooked-link' then and there, which is the one face a deferred batch can carry
before anybody looks at it."
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
      (should (get-text-property pos 'cooked-link-id))
      (should (equal (cooked-link-uri pos) "https://example.com/"))
      (should (eq (get-text-property pos 'face) 'cooked-link)))))

(ert-deftest cooked-a-deferred-batch-registers-the-pass-that-pays-it ()
  "The debt is work of its own: it registers jit-lock where nothing else would.

A session with the URL guess off and no scan layer loaded registers no
fontification pass at all -- that is what `cooked--sync-fontification' is for --
and deferred colours would then never be put on.  So the count of unpaid
batches is one of the things the registration follows."
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
that ninety short lines make several pieces, which a real flood would take
tens of thousands of lines to do.

The count dropping by exactly the number of pieces the chunk overlapped is the
assertion: settling one piece must leave the rest of the batch owing."
  (let ((cooked--style-piece-spans 8))
    (cooked-tests--with-session (list "/bin/sh" "-c" cooked-tests--red-flood)
      (cooked-tests--settled-flood)
      (let* ((pos (cooked-tests--scrollback-red))
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
          (should (> seen 40)))))))

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
