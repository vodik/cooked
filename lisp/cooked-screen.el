;;; cooked-screen.el --- The live screen as buffer text -*- lexical-binding: t; -*-

;;; Commentary:

;; The grid outlives the text: a redraw deletes and reinserts whole rows, so a
;; screen cell and a buffer position have to be converted into each other
;; constantly.  This file is that conversion, and everything that writes the
;; emulator's rows into the buffer through it -- rendering a block, moving rows
;; for a scroll, fitting the region to the grid's height, keeping the transcript
;; read-only, and pinning the alternate screen to the top of its windows.
;;
;; It sits on cooked-state.el, and below the drain pipeline in cooked-render.el,
;; which decides when each of these happens.

;;; Code:

(require 'cl-lib)
(require 'jit-lock)
(require 'cooked-util)
(require 'cooked-state)
(require 'cooked-face)
(require 'cooked-deco)
(require 'cooked-link)
(require 'cooked-guard)

(cooked--declare-core)

;;;; Locating a cell in the buffer
;;
;; The grid outlives the text.  A redraw deletes and reinserts whole rows, so a
;; buffer position is not a stable way to say where something on the screen is,
;; while a (ROW . COL) cell is — and the two have to be converted into each other
;; constantly.  `cooked--goto-screen-row' is the primitive both directions rest
;; on, and row 0 is the awkward case in each of them.

(defvar-local cooked--owed-wrap nil
  "The `cooked-wrap' mark owed to the newline the last screen row lacks.

Nil, or (END . MARK): END is a marker at the end of the last row of the screen
region, which is left unterminated, and MARK is what `cooked--mark-row-wrap'
would have put on that row's newline had there been one.  A newline is added
there later by extending the region rather than by rendering the row again --
the cursor moving to the row below, or a row further down being drawn -- and
`cooked--goto-screen-row' pays the mark then.  Without it the wrapped row
`日hel' at the bottom of a five-column screen got a plain newline when the
cursor moved under it, and a URL across that wrap was read as two.

END advances over text inserted at it, so padding and pending input added to
the row stay part of the row.  It is only believed while it is still the end of
the buffer; see `cooked--owed-wrap-mark'.")

(defun cooked--goto-screen-row (index &optional extend)
  "Move point to the start of screen row INDEX.

With EXTEND, add the lines needed to reach it; the screen region is trimmed
to its content, so a row below the cursor may not have a line yet.  Without
EXTEND this only moves point, which keeps queries free of side effects.

Row 0 begins at `cooked--screen-start' itself, which is not always the start of
a buffer line: when the last row handed to scrollback was wrapped it was written
without a newline, because row 0 continues it.  `forward-line' would snap back
to that line's beginning, and the caller would then delete the head it was
meant to continue — a whole row lost per eviction.  Rows below it are
unaffected: moving forward from a mid-line start lands on the next buffer
line, which is right,
because row 0 owns the remainder of the shared one."
  (goto-char cooked--screen-start)
  (let ((missing (if (zerop index) 0 (forward-line index))))
    ;; `forward-line' counts a final line that lacks a newline as one line
    ;; successfully moved, so it can report success while leaving point at that
    ;; line's end rather than at the start of the row we asked for.  Rendering
    ;; the next row then appends to the previous one — which is how a command's
    ;; output and the following prompt end up sharing a line.
    ;;
    ;; Unless point never left `cooked--screen-start': row 0 continuing a line at
    ;; `point-max' is a row that exists but has no text yet, and `forward-line'
    ;; counted nothing for it.  Counting it again put the row a line too low.
    (unless (or (zerop index) (bolp) (= (point) cooked--screen-start))
      (setq missing (1+ missing)))
    (when (and extend (> missing 0))
      (goto-char (point-max))
      (let ((owed (cooked--owed-wrap-mark))
            (at (point)))
        (insert (make-string missing ?\n))
        (when owed
          (put-text-property at (1+ at) 'cooked-wrap owed))
        (cooked--owe-wrap nil nil)))
    missing))

;;;; Cells, anchors and positions

(defun cooked--cursor-position ()
  "Buffer position of the emulator cursor.
A pure query: it never extends the buffer, so it is safe to call before
`inhibit-read-only' is in effect.

Counted in characters along the row, which the core has already done: on
`日本X' with the cursor on `本', the column would land on `X'."
  (save-excursion
    (cooked--goto-screen-row (cooked-cursor-row cooked--cursor))
    (min (+ (point) (cooked-cursor-chars cooked--cursor)) (line-end-position))))

(defun cooked--anchor-position (anchor batch-start)
  "Buffer position ANCHOR names, or the cursor if it names nothing we can place.

ANCHOR is what the native core attached to a semantic mark, spelled in whichever
coordinate system survives the drain the mark arrived in — see `anchor_to_lisp'
in src/wire.rs:

  (scrolled . OFFSET)  characters into the scrollback this drain just
                       inserted, for a row that scrolled away while the
                       drain accumulated.  BATCH-START, from
                       `cooked--render-scrolled', is where that text begins.
  (screen ROW . CHARS) a place on the live grid, for a row still on it: the
                       row, and characters of its text before the anchor,
                       which the core counted from the cells so that a
                       wide character before it does not push it along.

Both are resolvable only after the scrollback and the damaged rows have been
rendered, which is where `cooked--apply' dispatches events.

The fallback is the cursor.  That is precise enough whenever a drain carries a
single mark, and wrong in exactly the case anchors exist for: several marks in
one drain would all land on the same position."
  (pcase anchor
    (`(scrolled . ,offset)
     (if batch-start
         (min (+ batch-start offset) (point-max))
       (cooked--cursor-position)))
    (`(screen ,row . ,chars)
     (save-excursion
       (cooked--goto-screen-row row)
       (min (+ (point) chars) (line-end-position))))
    (_ (cooked--cursor-position))))

(defun cooked--screen-cell (&optional pos)
  "Screen row and column of POS, or nil if it is not on the screen.

The grid outlives the text: a redraw deletes and reinserts whole rows, so a
buffer position is not a stable way to remember where the user was looking,
while a cell is.

The inverse of `cooked--goto-screen-row', including its treatment of row 0:
when `cooked--screen-start' sits mid-line, the head before it belongs to
scrollback, so the column is measured from the marker rather than from the
line's beginning, which would count characters that are not on the screen
at all.

The column is the `string-width' of the row's text before POS, without its
properties, which is the cells the grid gave that text.  Not `current-column':
that counts a decoration image as its pixel width over the frame's character
width, so after `text-scale-mode' has made a cell 12 pixels wide on a frame
whose characters are 9, a cell after a ten-cell run of box drawing read as
column 13.  See `cooked--mouse-glyph', which measures the same way."
  (let ((pos (or pos (point)))
        (start (cooked--screen-start-position)))
    (when (and start (>= pos start))
      (save-excursion
        (goto-char pos)
        (let ((bol (line-beginning-position)))
          (cons (if (< bol start) 0 (count-lines start bol))
                (string-width (buffer-substring-no-properties (max bol start) pos))))))))

(defun cooked--screen-place (&optional pos)
  "Screen row of POS and the characters of that row before it, or nil if it is
not on the screen.

The unit an anchor is spelled in, which is why this exists beside
`cooked--screen-cell': the core counts a row in characters and not in cells, so
a position handed to `cooked--resize' to be carried across a rewrap has to be
counted the same way.  On `日本X' the `X' is column 4 and two characters in.

Characters as the buffer holds them, which is what the grid holds too: the
width guard hides the tail of a row the font draws too wide rather than
deleting it, so the hidden characters are still text of the row and the core
counted them.  Row 0 is measured from `cooked--screen-start' rather than from
its line's beginning, for the reason `cooked--screen-cell' gives."
  (let ((pos (or pos (point)))
        (start (cooked--screen-start-position)))
    (when (and start (>= pos start))
      (save-excursion
        (goto-char pos)
        (let ((bol (line-beginning-position)))
          (cons (if (< bol start) 0 (count-lines start bol))
                (- pos (max bol start))))))))

(defun cooked--goto-screen-cell (cell)
  "Move point to CELL, a (ROW . COL) pair, clamped to what the row holds.

The inverse of `cooked--screen-cell', so COL is counted in cells as that
function counts them: point lands after the most characters of the row whose
`string-width' is still at most COL.  On `日本XYZ' column 4 is `X', where
moving four characters stopped on `Z', and column 3, the second half of
`本', is `本' itself.  That is the rule the core's `chars_before' gives
a cursor inside a wide character, and a combining mark after the last
character that fits is taken along with it.

A binary search over the row's text, since the width of a prefix only grows
with its length, and so a restore after every drain costs a handful of
`string-width' calls however wide the row is."
  (cooked--goto-screen-row (car cell))
  (let* ((start (point))
         (text (buffer-substring-no-properties start (line-end-position)))
         (col (cdr cell))
         (low 0)
         (high (length text)))
    (while (< low high)
      (let ((mid (/ (+ low high 1) 2)))
        (if (<= (string-width text 0 mid) col)
            (setq low mid)
          (setq high (1- mid)))))
    (goto-char (+ start low))))

(defun cooked--at-child-cursor-p ()
  "Whether point is sitting where the child's cursor is."
  (and cooked--screen-start (marker-position cooked--screen-start)
       (= (point) (cooked--cursor-position))))

;;;; Putting styled text in the buffer

(defun cooked--render-block (block &optional row origin unlinked defer)
  "Insert BLOCK at point, with its styling and decoration applied.

BLOCK is (TEXT STYLE-SPANS DECO-SPANS ROWS), the one shape rendered
text crosses the module boundary in -- see `cooked--drain'.  TEXT is the whole
run of characters, and every span carries offsets in characters into it; spans
appear only where there is something to say, so a plain unstyled row carries no
list at all.

ROWS is the block's row table: one (START WIDTH UNIFORM WRAPPED HASH) per
*screen row* the block covers, in order.  A block is a run of contiguous damaged
rows joined by newlines -- see `cooked--render-rows' -- so START is where that
row's text begins in TEXT, WIDTH how many grid cells it occupies, UNIFORM t
when every character of it is one byte on one cell, `glyph' when the ones that
are not are box glyphs, and nil otherwise, WRAPPED whether the row below
continues this row's logical line -- t, or an integer when blanks of that line
stand between the two, the columns of that integer a wide character's early
wrap left rather than blanks of the line, zero for an ordinary wrap -- and
HASH a key for its layout.  All four
are by-products of the core building the row; WIDTH, UNIFORM and HASH are
`cooked--guard-row-width's and WRAPPED is `cooked--mark-row-wrap's, and
all four are read by `cooked--render-rows' rather than here.  START is read
here, and only for a decoration, which is the one thing that has to know which
row of the run it landed on.  Scrollback
carries no table at all: its lines are ordinary buffer text that is allowed to
wrap, so there is nothing to guard, no screen row to phase against, and -- with
`cooked-rejoin-wrapped-lines' on, which is the default -- no soft wrap left to
mark, the continuation having been joined onto the line above as it was
written.

STYLE-SPANS is not a list but a unibyte string of fixed-width records, one per
run that has a rendition or a link to name, both by id -- see
`Block::push_style' in src/wire.rs for the layout and `cooked--style-record'
for the stride.  A rendition resolves through `cooked--style-faces', which the
drain's `:styles' filled, and a link through `cooked--link-uris'.  A
DECO-SPAN is (START DECO), what its characters display instead of themselves,
and repeats no colours: a box glyph takes them from the face at the position it
sits on, which the style span has just put there.  Links are applied last, over
the decorations, so they can see which cells turned out to be an image and
leave those alone.  UNLINKED leaves them off altogether, for text headed
somewhere no link id can be followed from.

DEFER leaves the *faces* off instead, for a caller that has taken the records
on as a debt to be paid when the text is first displayed -- scrollback, and
only scrollback: see `cooked--defer-styles'.  The links still go on, because
the buffer is read for them without being displayed, so the walk under DEFER is
`cooked--do-style-links' rather than the full one.  A deferring caller must
record the debt itself; nothing here would know where to put it, the property
that carries it going on in the same pass as the rest of the batch's.

One insert plus properties, rather than an insert per run: Emacs pays for every
`insert', and building a propertized string in Lisp and inserting that instead
measures three times slower, because `concat' on propertized strings makes
Emacs copy and merge property intervals over and over.

Colour rides on `face' alone.  `cooked-mode' clears `font-lock-defaults',
which comint leaves at (nil t) -- under that setting any fontification of the
buffer unfontifies it first and strips a bare `face'.

The insertion runs with `before-' and `after-change-functions' live and the
property writes after it do not, deliberately: a change hook the user added is
entitled to see the row rewrite, and nothing cooked has is on either hook.  The
comment beside the binding below carries the measurements that decision rests
on and what it would save to inhibit them for the whole apply.

ROW is the screen row BLOCK's *first* row is, where the caller knows it: the
live screen does, scrollback does not.  With the origin it says which cell of a
glyph run the child's cursor is on, which is where the run is split.
Scrollback passes neither, having no cursor.

Each further row of the run is ROW plus its place in the row table, and its
origin is where the table says its text begins.  That bookkeeping is why the
table carries START at all: a cursor column is measured from its own row's
start, not from the first row's.

ORIGIN, when given, is where the row begins in the buffer, for a BLOCK that
replaces only part of a row: its text starts partway along, and the cursor
column is still measured from the row's own start.

Returns the position the text was inserted at."
  (pcase-let ((`(,text ,styles ,decos ,table) block))
    (let ((start (point)))
      (insert text)
      ;; The `insert' is outside the binding below and the property phases are
      ;; inside it.  Emacs runs `after-change-functions' for a text property
      ;; change exactly as for an insertion, and jit-lock is on that hook, so a
      ;; row of box drawing would pay it once per decorated run and once per
      ;; style span to be told what the `insert' already said -- a cost of
      ;; about a fifth on plain rows and half on box drawing.  See
      ;; `cooked--sync-fontification', which drops the hook entirely for a
      ;; buffer with no scan to run.
      ;;
      ;; The `insert' stays outside because it, and the `delete-region' in
      ;; `cooked--render-rows', are the row rewrite itself, and a change hook a
      ;; user has added is entitled to see an edit.  Links are found either
      ;; way: `insert' inherits no properties, so a rewritten row reads as
      ;; unfontified whether or not `jit-lock-after-change' ran on it.  See
      ;; `cooked-rewriting-a-row-still-gets-it-scanned', and for where this
      ;; binding sits,
      ;; `cooked-a-repaint-announces-its-rewrite-and-not-its-properties'.
      ;;
      ;; What is left outside is not one hook call per run: a repaint of 24 rows
      ;; of eight styled spans each makes *three* `after-change-functions' calls,
      ;; measured, because this binding already covers every property write and
      ;; `cooked--render-rows' coalesces the rewrite into a handful of edits.
      ;; Inhibiting the hooks for the whole of `cooked--apply' was measured
      ;; against leaving them: 12.72 against 13.24 ms per fifty styled frames,
      ;; ten microseconds a frame, which is not worth blinding a hook the user
      ;; added.  Nothing cooked has is on either hook -- `before-change-functions'
      ;; is empty in a cooked buffer and `after-change-functions' holds
      ;; `jit-lock-after-change' alone, or `evil-track-last-insertion' beside it.
      ;; Re-measured 2026-09-20 against this tree: still nil and
      ;; (jit-lock-after-change t), and a repaint of 24 rows of eight spans each
      ;; makes two calls.
      ;;
      ;; Nor is a hook that signals lost in the process filter, which is the
      ;; other reason offered for inhibiting them: the error comes out of the
      ;; `insert' into `cooked--drain-and-repair', which names it and resyncs the
      ;; screen -- "cooked: redisplay failed: ...; resyncing" -- and re-signals
      ;; under `cooked-debug'.  Probed on this tree with an `after-change-functions'
      ;; entry that errors on every change.
      (let ((inhibit-modification-hooks t)
            (links nil))
        ;; Links are collected on the same walk and applied after the decorations,
        ;; so a block with none -- nearly every block -- is walked once.
        (if defer
            ;; The faces stay in the records for `cooked--settle-styles' to put
            ;; on later, so all that is walked for here is the link ids.
            (unless unlinked
              (cooked--do-style-links (from to styled link styles)
                (push (list from to link styled) links)))
          (cooked--do-style-spans (from to face link styles)
            (when face
              (put-text-property (+ start from) (+ start to) 'face face))
            (when (and link (not unlinked))
              (push (list from to link (and face t)) links))))
        ;; The row table and the decoration spans are both in ascending offset
        ;; order, so which row a span fell on is a pointer walked forward once
        ;; across the whole block rather than a search per span.  `rest' is the
        ;; table from the current row on, and `seen' how many rows have gone by.
        (let ((rest table)
              (seen 0))
          (dolist (span decos)
            (pcase-let ((`(,from ,deco) span))
              (while (and (cdr rest) (>= from (car (cadr rest))))
                (setq rest (cdr rest)
                      seen (1+ seen)))
              (cooked--apply-deco (+ start from) deco
                                  (and row (or origin
                                               (+ start (if rest (caar rest) 0))))
                                  (and row (+ row seen))))))
        (when links
          (cooked--render-link-spans start links)))
      start)))

;;;; Moving rows the emulator moved
;;
;; A scroll is the one grid operation where "which rows changed" and "how much work
;; Emacs has to do" come apart.  After the emulator rotates its rows every index in the
;; region genuinely holds different text, so the damage report is right to name them
;; all -- and yet the text did not change, it *moved*, and the buffer can move it the
;; same way for two edits.  What that buys is not mainly the edits: it is that a row
;; whose text was moved rather than rewritten keeps its markers, its overlays and its
;; fontification, where a rewritten one loses all three.  A prompt marker, a command
;; decoration, a linkified URL and a live `next-error' position would otherwise be
;; destroyed by every line of output; moved, they survive until the row they sit on is
;; genuinely recycled or scrolls off the top into scrollback.
;;
;; The emulator reports the moves as `:shifts', and the row indices in `:rows' are in
;; the coordinates the moves leave behind -- so these run first, before
;; `cooked--render-rows', and in order.  See `Shift' in src/emu/screen.rs.

(defun cooked--delete-screen-rows (first count)
  "Delete COUNT screen rows starting at index FIRST.

Nothing is deleted when FIRST is past the end of the screen region, which is
the ordinary state of a primary screen trimmed to its content: rows that have
no buffer line yet have no text to move, and the render pass creates them with
`cooked--goto-screen-row''s EXTEND if it needs them.

The awkward case is a run that reaches the end of the region.  The last screen
row is deliberately left unterminated -- see `cooked--fit-screen' -- so deleting
from the start of the first doomed row to `point-max' would leave the row
*above* it newline-terminated and the region one line longer than it should be.
Taking the newline that ends that row along with them keeps the last surviving
row unterminated, which is the shape every other path in this file expects."
  (let ((start (cooked--screen-start-position)))
    (when (zerop (cooked--goto-screen-row first))
      (let ((beg (point)))
        (if (zerop (cooked--goto-screen-row (+ first count)))
            (delete-region beg (point))
          (let ((from (if (and (> beg start) (eq (char-before beg) ?\n))
                          (1- beg)
                        beg)))
            ;; The newline taken may carry the row above's wrap mark, which
            ;; that row, now the last, is owed back when a row below it next
            ;; exists.
            (cooked--owe-wrap from (and (< from beg)
                                        (get-text-property from 'cooked-wrap)))
            (delete-region from (point-max))))))))

(defun cooked--open-screen-rows (at count)
  "Insert COUNT blank screen rows before index AT.

Without EXTEND, and deliberately: AT past the end of the region means the rows
below the move were never in the buffer to begin with, so there is nothing for
these blanks to hold apart and the render pass will extend to whatever it
actually writes.  Extending here instead would leave a screenful of empty lines
under the prompt for `cooked--fit-screen' to take straight back out."
  (when (zerop (cooked--goto-screen-row at))
    (insert (make-string count ?\n))))

(defun cooked--apply-shift (top bottom count up)
  "Move the buffer text for a scroll of COUNT rows within TOP..BOTTOM.

UP means towards TOP: an ordinary line feed, `SU', `DL'.  Nil means towards
BOTTOM: `RI', `SD', `IL'.

Expressed as one deletion and one insertion rather than as a rotation, because
that is what makes the surviving rows survive: their text is never touched, so
every marker and overlay in it rides along and Emacs' own redisplay sees a
line-count change rather than a screenful of modified text.

Deleting first and inserting second, and each half locating its row afresh: the
deletion moves every row below it, so the index the blanks belong at is read
from the buffer as it stands after the delete rather than computed from where
the rows used to be.  For UP that index is BOTTOM+1-COUNT in the new numbering,
which is the same line the rows below the region begin at -- so a scroll region
leaves everything under it exactly where it was, which is the whole point of
there being a region."
  (save-excursion
    (if up
        (progn (cooked--delete-screen-rows top count)
               (cooked--open-screen-rows (- (1+ bottom) count) count))
      (cooked--delete-screen-rows (- (1+ bottom) count) count)
      (cooked--open-screen-rows top count))))

(defun cooked--apply-shifts (shifts)
  "Apply SHIFTS, the drain's `:shifts', in order.

In order and not merged: two of them in one drain means the child alternated
between two scroll regions, and replaying them out of order would land the rows
between the regions in the wrong place.  The core already coalesces the case
that repeats -- a flood scrolling once per line arrives as one shift, or as
none at all when the region turned over completely and every row of it is
damaged anyway."
  (dolist (shift shifts)
    (pcase-let ((`(,top ,bottom ,count ,up) shift))
      (cooked--apply-shift top bottom count up))))

(defun cooked--pad-to-cursor ()
  "Extend the cursor's row so it can hold the cursor's character.

Rendered rows have trailing blanks trimmed, which loses the space at the
end of a prompt like \"$ \".  The input region would then begin one column
early, and the shell's echo of the submitted line would disagree with
what was displayed."
  (save-excursion
    (cooked--goto-screen-row (cooked-cursor-row cooked--cursor) 'extend)
    (let ((short (- (cooked-cursor-chars cooked--cursor)
                    (- (line-end-position) (point)))))
      (when (> short 0)
        (goto-char (line-end-position))
        (insert (make-string short ?\s))))))

(defconst cooked--read-only-props
  '(read-only t front-sticky (read-only) rear-nonsticky (read-only))
  "The read-only property and the stickiness that makes it usable.

Stickiness carries the whole design.  `rear-nonsticky' leaves the far edge
open, so typing at the start of the input region is accepted; `front-sticky'
closes the near edge, so nothing can be wedged in above the transcript.

One constant rather than the literal written out at both of the places that
protect text -- `cooked--render-scrolled', which protects a batch of
scrollback once and forever, and `cooked--protect', which keeps the live
screen protected as the input boundary moves.  They were always the same three
properties and had to stay the same, the two regions being adjacent halves of
one read-only transcript: a difference between them would show as a seam the
user could type into.

Sharing the *object* matters as well as sharing the value.
`add-text-properties' compares values with `eq', so two separately-written
`(read-only)' lists read as a change and provoke an interval rewrite over text
that already carries exactly what is being asked for.")

(defun cooked--render-scrolled (block)
  "Append BLOCK to the scrollback above the live screen, returning where it went.

The return value is the buffer position the batch was inserted at, which is what
a `scrolled' anchor is an offset from — see `cooked--anchor-position'.  It stays
valid for the rest of the redisplay: everything rendered afterwards goes below
it.

The marker is advanced explicitly rather than by insertion type: rendering
screen row 0 also inserts at this position, and an auto-advancing marker would
drift into the screen region.

Widens first: history can arrive while the alt screen is up — a resize evicts
rows from the primary even when a full-screen program is showing — and the
insertion point is above the region `cooked--apply-alt-pin' confines us to.

No row index is passed to `cooked--render-block': scrollback has no cursor to
split a glyph run at.

The faces are not put on here either.  This text has by definition just left
the screen, and under a flood it leaves it again before anyone has looked at
what went before, so the batch's packed style records are taken on as a debt
instead, cut into pieces small enough that displaying any part of the batch
pays for a bounded share of it, and paid by the jit-lock pass over the region
redisplay asks for -- `cooked--defer-styles' and `cooked--settle-styles', which
say why that is a text property and what it costs.  Its links do go on now; see
`cooked--render-block'."
  (save-restriction
    (widen)
    (save-excursion
      (let* ((seam (cooked--held-seam (marker-position cooked--screen-start)))
             ;; Before the render, which needs to be told whether the debt was
             ;; taken on: an unstyled batch, or the deferral switched off for a
             ;; test, is coloured as it is inserted like any other text.
             ;;
             ;; And so is a batch carrying decorations, however styled it is,
             ;; because a decoration reads the face off the very characters it
             ;; covers as it lands: `cooked--apply-shade' blends the cell's two
             ;; colours into the `face' it then writes there, so a deferred
             ;; rendition would be both invisible to the blend and, arriving
             ;; afterwards, written over it.  A box glyph would survive -- its
             ;; bitmap is uncoloured and takes the face at display time -- but
             ;; the two travel together in one block and the distinction is not
             ;; worth a second pass to draw.  Decorated scrollback is rare (a
             ;; full-screen program repaints the alternate screen, where nothing
             ;; scrolls off) and this costs it only what it cost before.
             (owed (unless (nth 2 block) (cooked--defer-styles (cadr block))))
             (start (progn (goto-char (or seam cooked--screen-start))
                           (cooked--render-block block nil nil nil (and owed t)))))
        ;; Scrollback never changes again, so it is protected once, here, rather
        ;; than re-swept on every redisplay.  The read-only half is
        ;; `cooked--read-only-props', shared with `cooked--protect' so the two
        ;; halves of the transcript cannot drift apart; only the marker saying
        ;; this text is scrollback, and the styling it still owes, are added on
        ;; top of it.  One pass for all of them: the debt is recorded by being
        ;; in this list, so recording it costs no interval walk of its own.
        ;;
        ;; That pass carries the batch's first piece of owed styling, which
        ;; covers the whole batch; the pieces after it then claim their own
        ;; stretches back off it, one property write each.
        (add-text-properties start (point)
                             `(cooked-scrollback t
                               ,@(and owed (list 'cooked-pending-style (car owed)))
                               ,@cooked--read-only-props))
        (cooked--place-style-pieces start (point) (cdr owed))
        ;; Neither link pass runs here.  Both are `cooked--fontify-region''s
        ;; now, so a batch that scrolls past without ever being displayed --
        ;; which is what a flood is -- costs nothing to scan, and the file
        ;; layer's `file-exists-p' is paid only for text somebody looks at.
        ;;
        ;; What the batch still buys them is the shape they see it in: this text
        ;; is inserted with `cooked-rejoin-wrapped-lines' having joined a
        ;; continuation row onto the line above it, so a URL the live screen
        ;; broke across two rows is one string by the time anything scans it.
        ;; Above a held seam the marker has moved already, past the newline that
        ;; stays below this batch.
        (unless seam (set-marker cooked--screen-start (point)))
        (cooked--forget-owed-wrap-above (marker-position cooked--screen-start))
        ;; After the marker moves, so it names the seam these marks are now above.
        (cooked--prune-marks)
        start))))

(defun cooked--promote-rows (promoted height)
  "Keep the top screen rows as history, returning where they begin.

PROMOTED is the drain's `:promoted', (BOTTOM . ROWS): one (CHARS . ENDS) per
row, from screen row 0 down, for the rows that scrolled off the top of the
region ending at row BOTTOM while the buffer already held them.  Their text
stays where it is and `cooked--screen-start' moves past it.  Sent as text
instead, `cooked--render-scrolled' would insert the same rows again above the
screen and `cooked--apply-shift' would delete the originals.  So a marker, an
overlay or a text property on one of them is still on its character once the
row is history: a bookmark at column 5 of the line `tail -f' pushes off the
top stays at column 5.

The buffer's row and what scrollback gets differ in three ways, and each is
mended by a small edit that leaves the rest of the row alone:
- CHARS is how long the row is as scrollback.  A row carrying spaces
  `cooked--pad-to-cursor' added is longer, and loses them; a wrapped row keeps
  its trailing blanks up there, which the live row trimmed, and gets them back.
- ENDS nil means the row joins the next one, as `cooked-rejoin-wrapped-lines'
  joins a wrapped row, so its newline is deleted.  If the next row is still on
  the screen, the screen then starts mid-line, at the seam `:head' counts.
- A newline that stays loses its `cooked-wrap' mark, which only the live
  screen carries.

A promotion is its share of the scroll that took the rows off the top, and
`:shifts' holds the rest of that scroll.  So it opens the blank rows at the
bottom of the region that `cooked--apply-shift' would have opened for it,
which keeps a status line below the region where it is, and leaves the newlines
ending the rows where that scroll would have: the newline a wrapped row's mark
goes on is one of them.  None open when the region is the whole screen, HEIGHT
rows tall, and every row of it went, since there is nothing below to hold apart.

The return value is what `cooked--render-scrolled' returns: where this
drain's scrollback begins, which a `scrolled' anchor is an offset from.  The
core counts a promoted row's characters into those offsets."
  (pcase-let ((`(,bottom . ,rows) promoted))
    (save-restriction
      (widen)
      (save-excursion
        (let ((start (marker-position cooked--screen-start))
              (count (length rows)))
          (goto-char start)
          (pcase-dolist (`(,chars . ,ends) rows)
            (let ((end (+ (point) chars))
                  (eol (line-end-position)))
              (if (> eol end)
                  (delete-region end eol)
                (goto-char eol)
                (insert (make-string (- end eol) ?\s)))
              (goto-char end)
              (cond ((eobp) (when ends (insert "\n")))
                    (ends (remove-text-properties (point) (1+ (point)) '(cooked-wrap nil))
                          (forward-char 1))
                    (t (delete-char 1)))))
          (add-text-properties start (point)
                               `(cooked-scrollback t ,@cooked--read-only-props))
          (set-marker cooked--screen-start (point))
          (cooked--forget-owed-wrap-above (point))
          (unless (= count (1+ bottom) height)
            (cooked--open-screen-rows (- (1+ bottom) count) count))
          (cooked--prune-marks)
          start)))))

(defun cooked--held-seam (start)
  "Where the newline `cooked--place-seam' holds before START is, or nil.

START is where the live screen begins.  Scrollback arriving while that newline
is held goes above it, since it continues the primary screen's line rather
than the alternate screen's row 0."
  (and (> start (point-min))
       (get-text-property (1- start) 'cooked-seam)
       (1- start)))

(defun cooked--place-seam (head alt)
  "Join or break the buffer line the live screen begins in, as this drain says.

HEAD is the drain's `:head', how many characters of screen row 0's line
the buffer already holds, and ALT whether the drain shows the alternate screen.
The seam is decided afresh on every whole drain rather than written once, so a
switch of screens leaves nothing behind in the transcript.

The alternate screen's row 0 begins a buffer line, but the primary keeps its
head in the core, so the transcript above can end mid-line: a wrapped line
whose head scrolled away before `less' started.  While the alternate screen
is shown, a newline marked `cooked-seam' is held between the two, and rows a
resize takes off the primary meanwhile go in above it, continuing the line
they belong to.  Once the primary is back with a HEAD above 0 the newline is
deleted, and row 0 continues the line again.  Ten `=' at 4 columns on a
2-row screen leave 4 in scrollback and 4 on row 0 of the same buffer line, and
after `1049h' and `1049l' they are one line still, however many drains
came between.

A HEAD of 0 on the primary screen while the buffer is mid-line is the core
saying the line ended without Emacs holding its newline, so the newline stays:
one is written for good, or the held one is kept for good.

Widens first, for the reason `cooked--render-scrolled' does."
  (save-restriction
    (widen)
    (when-let* ((start (cooked--screen-start-position)))
      (let* ((held (cooked--held-seam start))
             (line (or held start))
             (mid-line (not (or (= line (point-min)) (eq (char-before line) ?\n)))))
        (cond
         ((and held (or (not mid-line) (not (or alt (eql head 0)))))
          (delete-region held start))
         ((and held (not alt))
          (remove-list-of-text-properties held start '(cooked-seam)))
         ((and mid-line (not held) (or alt (eql head 0)))
          (save-excursion
            (goto-char start)
            (insert (apply #'propertize "\n" 'cooked-scrollback t
                           (if alt
                               `(cooked-seam t ,@cooked--read-only-props)
                             cooked--read-only-props)))
            (set-marker cooked--screen-start (point))
            (cooked--forget-owed-wrap-above (point)))))))))

(defun cooked--prune-marks ()
  "Forget the marks that have scrolled into permanent scrollback.

Called from `cooked--render-scrolled', which is the moment they get there.  A
mark below `cooked--screen-start' is on a row the emulator has handed over and
will never mention again -- it went to scrollback on the row it was attached to
-- so the entry can only grow the table.  The record that owns the marker keeps
it; what is dropped is the ability to relocate it, which nothing will ask for.

Here rather than on a timer or a size cap because this is the only path that
makes an entry unreachable, and it keeps the table at the handful of marks the
live screen carries rather than one per command of the session."
  (when-let* ((marks cooked--marks)
              (screen (cooked--screen-start-position)))
    (maphash (lambda (id marker)
               (when (or (not (marker-position marker))
                         (< (marker-position marker) screen))
                 (remhash id marks)))
             marks)))

;;;; Shaping the screen region
;;
;; What the buffer looks like between drains: how tall the live region is, what
;; the alternate screen does to the rest of the buffer, where the read-only text
;; ends, and the one place a row is allowed to disagree with the emulator about
;; its own width.

(defun cooked--apply-alt-pin ()
  "Confine the buffer to the screen region while the alt screen is up.

Re-applied on every redraw rather than only on the transition: the accessible
end behaves like a marker that insertions push past, so rows appended at the
end of one redraw would fall outside the region by the next.

Only ever undoes its own restriction.  A narrowing the user made themselves is
none of our business, and widening it on the next drain would make `\\[narrow-to-region]'
unusable in a terminal buffer.

Which also means a deliberate `\\[widen]' lasts exactly until the next drain, this
being re-applied rather than merely established.  The way to read the transcript
behind a running program is therefore to stop the drains first: `\\[cooked-toggle-peek]'
freezes the render, and a widening made inside that peek stands until it is
resumed."
  (if (and cooked--alt (cooked--screen-start-position))
      (progn
        (narrow-to-region (cooked--screen-start-position) (point-max))
        (setq cooked--narrowed t))
    (cooked--release-alt-pin)))

(defun cooked--screen-restricted-p ()
  "Whether the buffer is narrowed to the alternate screen and nothing else.

The state `cooked--apply-alt-pin' leaves behind, asked as a question about the
buffer rather than read off `cooked--narrowed': a user who answers
\\[widen] has widened whatever the flag still says, and the callers of this all
want to know what can be scrolled to *now*.  See `cooked--wheel-map'."
  (and cooked--alt
       (when-let* ((top (cooked--screen-start-position)))
         (= (point-min) top))))

(defun cooked--release-alt-pin ()
  "Undo the restriction `cooked--apply-alt-pin' put on the buffer, if any."
  (when cooked--narrowed
    (setq cooked--narrowed nil)
    (widen)))

(defun cooked--pin-alt-windows ()
  "Keep every window on this buffer showing the alt screen from its first row.

`cooked--apply' already pins at the end of a drain, and that is not enough.  A
drain is the child talking, and nothing the *user* does to a window produces
one: a full-screen program sitting idle at its prompt draws nothing, so a wheel
notch scrolled the picture off the window and left it there.  Run from
`cooked--after-command', the pin becomes the continuous invariant it always
meant to be.  `eat' states it the same way, in `eat--synchronize-scroll'.

Forcing, unlike the drain's pin, because the wheel moves point along with the
window and NOFORCE would let redisplay honour the point it left behind.  The
vscroll goes with the start, because `pixel-scroll-precision-mode' carries a
remainder that survives being told where the window starts.

Only while the buffer is *restricted* to the screen, which is the same rule
`cooked--wheel-map' is gated on and means the same thing in both places: the
rectangle is all there is to look at, so a window showing anything else is
showing the wrong thing.  Widen -- which is how the transcript behind a
full-screen program is read, inside a peek -- and there is somewhere to scroll
to, the wheel goes back to Emacs, and a scroll the user asked for is theirs to
keep.

Not also on `pre-redisplay-functions'.  A pin calls `set-window-start',
which clears the window's end-valid flag and denies redisplay its incremental
path; doing that from inside redisplay makes redisplay start over for the move
the pin itself just made, once per window per redisplay.  See docs/DESIGN.md
for the two cases that hook caught and how they are answered instead."
  (when (cooked--screen-restricted-p)
    (when-let* ((top (cooked--screen-start-position)))
      (dolist (w (get-buffer-window-list nil nil t))
        (unless (= (window-start w) top)
          (set-window-start w top))
        (unless (zerop (window-vscroll w t))
          (set-window-vscroll w 0 t))))))

(defun cooked--fit-screen ()
  "Shape the screen region to the number of rows the emulator says it has.

One number, and the emulator's rather than ours.  Which one differs by screen:

On the alternate screen a terminal is a fixed rectangle, so the region holds the
grid's full height — trimming to content would fight a full-screen program, and
leaving the old lines in place is why a shrunk window kept showing stale rows.

On the primary it holds `:used' rows, which is where the emulator's own content
ends: everything down to the last row holding something, and never above the
cursor.  A terminal shows a fixed rectangle but a buffer should not carry two
dozen empty lines under the prompt, and a program drawing below the cursor is
inside `:used' by construction, so its layout survives.

Unconditional in both cases, and deliberately not conditioned on the tail being
*wholly blank*: that is a question about the buffer's text rather than about
the grid, and the two stop agreeing the moment a height shrink evicts rows.
The rows that left are inserted above as scrollback and the survivors
re-rendered from row 0 down, so the old lines below the new last row are not
blank — they are a stale
copy of the live screen, and a blankness test leaves the screen showing twice."
  (save-excursion
    (let ((rows (if cooked--alt
                    (cooked-grid-height cooked--grid)
                  (cooked-grid-used cooked--grid))))
      (if (and cooked--alt (> rows 0))
          ;; `extend' on the alt screen only: the rectangle must be exactly that
          ;; tall even where the program has drawn nothing, while the primary is
          ;; trimmed to content and has no business growing here.  One of the
          ;; eight consequences of that distinction; see `cooked--set-alt'.
          ;;
          ;; Extend to the *last* row and trim from its end, rather than
          ;; walking one row past the last and trimming from its start.  A row
          ;; is made to exist by inserting the newline that ends the row above
          ;; it, so asking for row ROWS would leave an empty line at `point-max'
          ;; below the screen, which point can be moved onto and which scrolls
          ;; the whole picture up by one when it is.  Trimming to
          ;; `line-end-position' of the last row leaves that row unterminated,
          ;; exactly as the primary's last row already is, and is stable across
          ;; drains: the next one lands `bolp' on it and deletes nothing.
          (progn (cooked--goto-screen-row (1- rows) 'extend)
                 (let ((eol (line-end-position)))
                   (when (< eol (point-max))
                     (cooked--owe-wrap eol (get-text-property eol 'cooked-wrap))
                     (delete-region eol (point-max)))))
        ;; Without `extend' a region already short enough reports the
        ;; shortfall and is left alone.  What is left ends in a newline, so
        ;; no row is owed a mark.
        (when (zerop (cooked--goto-screen-row rows))
          (when (< (point) (point-max))
            (cooked--owe-wrap nil nil)
            (delete-region (point) (point-max))))))))

(defun cooked--check-seam ()
  "Signal if the buffer disagrees with the emulator about the seam.

`:head' is how many characters of screen row 0's logical line are already in the
buffer, so `cooked--screen-start' must sit exactly that far into its line: the
two ends each hold half of one wrapped line and nothing else ties them
together.  A drift here is silent — the text reads fine until the next rewrap
resumes the line in the wrong column — which is what this exists to make loud.

Meaningful in both modes, and the second one is where it earns its keep.  With
`cooked-rejoin-wrapped-lines' off every row handed over gets a newline of its
own, so Emacs' half of the seam is always zero -- and the emulator's half has to
be zero with it, or it is carrying a claim about a continuation the buffer never
took.  `cooked--split-seam' is what makes that true, and it runs a line earlier
in `cooked--apply' precisely so this can watch it.

Called under `cooked-debug' only.  It is a whole-line measurement on every
drain, and the invariant it guards is maintained in the native core rather than
here, so there is nothing for it to repair — see `Row::line_runs' in
src/emu/cell.rs.

Widens to measure: the drain that leaves the alternate screen still has the
buffer narrowed to the screen when this runs, and the head it rejoined is above
that."
  (when-let* ((start (cooked--screen-start-position)))
    (let* ((head (save-excursion (save-restriction
                                   (widen)
                                   (goto-char start)
                                   (- start (line-beginning-position)))))
           (want (cooked-grid-head cooked--grid)))
      (unless (= head want)
        (error "cooked: seam desync: buffer holds %d characters of row 0's line, emulator says %d"
               head want)))))

(defvar-local cooked--protected nil
  "What `cooked--protect' last did, as (TICK . LIMIT), or nil for never.

TICK is `buffer-chars-modified-tick' as of that call.  See there for what it
buys.")

(defun cooked--protect-holes (beg end)
  "Protect every run between BEG and END that is not already read-only.

A run is found by its `read-only' property alone.  That is sound because
nothing removes the stickiness `cooked--read-only-props' carries:
`cooked--protect' lifts `read-only' and leaves the rest.  On a screen whose
only unprotected text is a row the drain rewrote, for example a shell prompt
with one character echoed, this makes one call to `add-text-properties', over
that row."
  (let ((pos beg))
    (while (setq pos (text-property-not-all pos end 'read-only t))
      (let ((hole (next-single-property-change pos 'read-only nil end)))
        (add-text-properties pos hole cooked--read-only-props)
        (setq pos hole)))))

(defun cooked--protect (limit)
  "Make the screen read-only up to LIMIT, leaving anything after it editable.

The properties, and why they are the ones they are, are
`cooked--read-only-props'.

Runs on every drain, and most drains have nothing for it to do.  The property is
lost only where text is *inserted*, since an insertion carries no properties of
its own, so a drain that changed no characters can only have moved LIMIT -- and
then the whole of the work is the strip of text between the old boundary and the
new one, in whichever direction it went.  `buffer-chars-modified-tick' is what
says a drain changed no characters, and it says it about every writer rather
than about the ones this file knows of: an insertion anywhere, by any layer,
moves it.

When characters did change, every hole in the screen is filled rather than the
rows the render rewrote.  Those bounds do exist -- `cooked--render-rows'
returns them -- but they are not the whole of what a drain inserts:
`cooked--pad-to-cursor' extends the cursor's row, which need not be the last
one, `cooked--fit-screen', `cooked--goto-screen-row' and a shift add the
newlines that make a row exist, and a promotion opens blank rows at the foot of
its region.  A sweep that misses one of those leaves a hole in the transcript
the user can type into, which only the render oracle would show.  So the
holes are found by asking the text, with `text-property-not-all', and that
answer covers every writer, including ones this file does not know of.

What the sweep must not do is hand the whole screen to `add-text-properties'.
That walks the same intervals, but once one of them lacks the properties it
treats the entire range it was given as modified and adds to every interval in
turn, so the sweep cost what the screen held rather than what the drain wrote.
On a styled 24x80 screen with one row rewritten that was 12 us of a 70 us apply,
against 5.5 us for finding the one hole and filling it (interleaved in one
compiled Emacs, load 4.9 over 16 CPUs).  Both cons the same 56 cells: a cons is
per interval that gains the properties, and those are the same intervals.

The sweep runs with change hooks inhibited, for the reason
`cooked--render-block' gives for its property phases.  `add-text-properties'
reports a change over the whole range it was handed as soon as one character in
it lacked the properties, and jit-lock is on that hook: one echoed keystroke
marked every row of the screen unfontified, and the next redisplay scanned all
of them for URLs again.  Making text read-only changes nothing any hook reads."
  (when-let* ((screen (cooked--screen-start-position)))
    (let ((tick (buffer-chars-modified-tick))
          (beg (min screen limit))
          (inhibit-modification-hooks t))
      (pcase cooked--protected
        ;; Nothing moved at all: the previous call\='s answer still stands.
        (`(,(pred (eql tick)) . ,(pred (eql limit))) nil)
        ;; No text changed, so only the boundary did.  Everything below the
        ;; lower of the two limits was protected then and still is; everything
        ;; above the higher was open then and still is.
        (`(,(pred (eql tick)) . ,was)
         (if (< was limit)
             (add-text-properties (max beg was) limit cooked--read-only-props)
           (remove-text-properties limit (min was (point-max)) '(read-only nil))))
        (_
         (cooked--protect-holes beg limit)
         (when (< limit (point-max))
           (remove-text-properties limit (point-max) '(read-only nil)))))
      ;; Read again: the two calls above do not change `buffer-chars-modified-tick\='
      ;; -- a text property is not a character -- but reading it after the fact
      ;; rather than trusting that is one less thing to be wrong about later.
      (setq cooked--protected (cons (buffer-chars-modified-tick) limit)))))

;;;; Writing damaged rows

(defvar cooked-row-rendered-functions nil
  "Abnormal hook run with the bounds of each live row this drain rewrote.

Each entry is called as (BEG END) with the row's own buffer positions, once
per damaged row, from `cooked--notify-rows-rendered' at the end of the drain
rather than from `cooked--render-rows' as each row is written.

That delay is part of the contract rather than an implementation detail.  A
drain that evicts rows inserts their text above the live screen, which pushes
every marker below it forward by a whole row, so until `cooked--relocate-marks'
runs every semantic mark on the screen names the row below the one it belongs
to.  Rendering happens inside that window, and a layer painting from a mark
there painted the row below once per scroll -- and since the correction that
followed moved the marker and not the paint, the mistake stuck.  BEG and END are
still exact: nothing between the render and the notification moves text.

This is the seam for a decoration that has to be re-applied rather than
persisted.  A damaged row is deleted before it is rewritten, so anything
anchored to its characters dies with it, and a resize damages every live row at
once.  `cooked--fontify-links' is the same shape one level down and needs no
hook, links being cooked's own business; this exists for the optional layers,
which cannot reach into the render path themselves.

Not called for alternate-screen rows: that grid is a rectangle the child owns
outright, with no scrollback and no command records of Emacs' own to re-apply.
Empty by default, and run through `cooked--run-seam', so an entry that signals
costs its own contribution and neither the rest of the hook nor the drain.")

;; Carrying a position across a row the render rewrites.
;;
;; The mechanical floor under `cooked--capture-viewport''s intents, and only that:
;; `editing', `wandered' and `follow' each re-derive a position from something
;; that outlives the text -- an offset into the pending input, a screen cell, a
;; question put to the mode -- and they answer things arithmetic structurally
;; cannot.  Two positions have nothing of the sort to be re-derived from, and
;; until this existed neither had any rescue at all:
;;
;; - The *mark*.  A mark names text rather than a cell, so there is no cell to
;;   look it up by afterwards.  `cooked--deactivate-mark' drops an active
;;   selection whose characters the child has just rewritten, which is the right
;;   policy and is a different subject -- it decides what happens to the
;;   *highlight*.  The mark is somewhere either way, and it is that somewhere the
;;   next \\[exchange-point-and-mark] or \\[pop-to-mark-command] goes to.  Note
;;   which case this leaves: `cooked-selection-render' freezes the render while a
;;   selection is up, so the live selection is in no danger; what reaches a drain
;;   is the mark of a selection *already dismissed*, carried in by the catch-up
;;   drain the freeze lifting releases.  By then `mark-active' is nil and nothing
;;   above here is looking at the mark at all.
;;
;; - The `window-point' of another window in the live screen that
;;   `cooked--scroll-transcript' is not going to move.  While the view is
;;   following it points every one of them at the cursor and there is nothing to
;;   preserve; while it is held -- `still', `frozen', a peek -- it touches none
;;   of them, so without this the row rewrite underneath would take their point with it.
;;
;; The transform is ghostel's `adjustRegion' (saved_markers.zig:27) with one
;; departure.  ghostel replaces one row per edit, so clamping a position inside
;; the replaced region to that region's new end is exact-replace semantics and
;; is the right answer.  cooked coalesces contiguous damaged rows into one Block,
;; so a full-height repaint replaces the whole screen in a single edit -- and the
;; clamp would collapse a mark on row 1 onto the last column of row 23.  The
;; run's row table already says where each of its rows begins, so a position
;; keeps its *row and column* instead, clamped to that row's new end.  That
;; degenerates to exactly ghostel's answer for a run of one row, and is strictly
;; better for every longer one.
;;
;; Tracked through the render by the marker each of these already is, rather than
;; by the integer ghostel captures at the top of `redraw', and that is the design
;; rather than a shortcut.  A drain does much more than rewrite rows: it promotes
;; the top rows into scrollback or inserts this batch's scrollback above the
;; screen, moves rows for a scroll, extends and trims the region, lifts and
;; reinstates the pending input, and evicts from the top.  Emacs' own marker
;; adjustment is already right for every one of those, and re-deriving them all
;; in arithmetic would be a second implementation of the drain with its own way
;; of being wrong.  The edit markers are wrong for is the row rewrite, because a
;; delete-and-reinsert is not a replacement as far as that adjustment is
;; concerned: a mark collapses to the run's *start* and a `window-point' is pushed
;; to its *end*.  So that edit is corrected where it happens, and nothing else is
;; touched.
;;
;; A row leaving the top of the screen is a rewrite of the same kind when it is
;; sent as text -- a copy inserted above and the original deleted -- and nothing
;; carries a position across that.  It is sent as text only when the buffer does
;; not hold it as the core last sent it: a row the width guard trimmed, the rows a
;; flood scrolled through between drains, a row after a resize or a screen switch.
;; Every other row is promoted, and a position on it stays on its character; see
;; `cooked--promote-rows'.
;;
;; A drain that rewraps the screen is the other exception, and (row, column) is
;; the wrong thing to carry across it: at the new width the same cell holds some
;; other character.  Nothing here answers that one.  The reflow is the core's,
;; and it already carries a semantic mark through it by holding the mark on a
;; cell and reporting where the cell went, so a position Emacs needs carried is
;; registered with `cooked--resize' as a transient anchor and read back out of
;; the next drain's `:marks'; see `cooked--carry-positions'.  Lisp used to
;; re-derive it instead, measuring each position as (LINES . CHARS) over its own
;; `cooked-wrap' marks and the early-wrap padding and walking the new text to
;; find it again -- a second implementation of the reflow, agreeing with the
;; first only as long as an oracle test kept saying so.
;;
;; What made that plausible, and what the transient anchor had to answer, is that
;; the buffer's rows are not the grid's: `cooked--sync-size' runs from a window
;; hook and calls `cooked--resize' at once, while the reader thread has been
;; feeding the grid since the last drain, so a mark the buffer reports on screen
;; row 2 can be off the grid altogether by then -- see
;; `cooked-a-rewrap-carries-the-mark-the-buffer-holds-not-the-grid-s'.  Lisp has
;; no absolute row to name it with, `anchor_to_lisp' in src/wire.rs handing over
;; `(screen ROW . CHARS)' and `(scrolled . OFFSET)' precisely so that it never
;; holds one.  The core does: `State::drained_at' is the absolute row Emacs is
;; showing as row 0, so a row Emacs names is a row the core can find, whether it
;; is still on the grid or already in the scrollback this drain is bringing.

(cl-defstruct (cooked-relocation (:constructor cooked--relocation-make) (:copier nil))
  "A position `cooked--render-rows' has to carry across a run it rewrites.

Made by `cooked--capture-relocations', which is where the decision about *which*
positions need one lives; everything here is mechanism."
  (window nil :documentation "\
The window whose `window-point' this stands for, or nil for the mark.

Two cases and no function slot, deliberately: a closure per window per drain is
allocation on a path whose floor is `cooked-min-redisplay-interval', and it
would spell a choice between two branches written down right here.")
  (row nil :documentation "\
Which row of the run being rewritten this position was on, or nil.

Live only between `cooked--note-relocations' and `cooked--place-relocations',
which is the whole of one run's rewrite: outside it there is no run for a row
index to be an index into.")
  (column nil :documentation "\
The position's column within that row, in characters."))

(defun cooked--relocation-position (relocation)
  "Where RELOCATION currently points, or nil if there is nothing to carry.

Read afresh at every run rather than remembered, because the runs before this
one have already moved it: a row that came back shorter shifts every row below
it, and the marker underneath has been keeping up the whole time."
  (if-let* ((window (cooked-relocation-window relocation)))
      (and (window-live-p window) (window-point window))
    (mark t)))

(defun cooked--relocation-set (relocation position)
  "Put RELOCATION at POSITION."
  (if-let* ((window (cooked-relocation-window relocation)))
      (when (window-live-p window) (set-window-point window position))
    (set-marker (mark-marker) position)))

(defun cooked--note-relocations (relocations start end)
  "Record where each of RELOCATIONS sits inside the run START..END.

Before the deletion, because afterwards there is nothing left to read: the run's
newlines are the only thing that says which row a position was on, and its
column is an offset into text that is about to stop existing.

The row is cleared for everything first.  A relocation outside this run must not
still be carrying the row it was on in a *previous* one -- the runs of a drain
are rewritten one after another, and a stale index would place a position into
a row that has nothing to do with it."
  (dolist (relocation relocations)
    (setf (cooked-relocation-row relocation) nil)
    (when-let* ((position (cooked--relocation-position relocation))
                ((<= start position end)))
      (save-excursion
        (goto-char position)
        (let ((bol (line-beginning-position)))
          (setf (cooked-relocation-column relocation) (- position bol)
                ;; Screen row 0 does not always begin a buffer line -- it
                ;; continues the wrapped row handed to scrollback before it -- so
                ;; START can sit mid-line and a position on that row has its BOL
                ;; above START.  `count-lines' counts the newlines between two
                ;; places whatever either of them is in the middle of, which is
                ;; the row index for exactly that reason.
                (cooked-relocation-row relocation)
                (if (<= bol start) 0 (count-lines start bol))))))))

(defun cooked--place-relocations (relocations row start end)
  "Put back each of RELOCATIONS that belonged to ROW, now written at START..END.

Clamped to END, which is where the departure from `adjustRegion' stops: a row
that came back shorter has no column 12 any more, and the nearest thing to where
the user was pointing is the end of what the row now holds."
  (dolist (relocation relocations)
    (when (eql (cooked-relocation-row relocation) row)
      (setf (cooked-relocation-row relocation) nil)
      (cooked--relocation-set
       relocation (min (+ start (cooked-relocation-column relocation)) end)))))

(defun cooked--mark-row-wrap (eol wrap)
  "Record on the newline at EOL whether the row it ends was soft-wrapped.

The `cooked-wrap' property, and this is the only place it is written: WRAP is
the row table's own fourth field, nil, t or an integer, so the mark is
what the core says rather than anything inferred here.  Non-nil means the row
below carries the rest of a logical line the child never broke.  The buffer
has no other way to know that.  A screen row is one buffer line, so a line the
child ended and a line the terminal ran out of columns for are the same two
characters of text -- and everything that reads the buffer as language rather
than as a grid then gets the wrong answer.  cooked's one documented
link-detection gap is exactly this: a URL split across a row boundary matched
only as far as the break.  See
`cooked-link--join-wrapped', which is the reader.

Only the live screen.  Scrollback needs nothing under
`cooked-rejoin-wrapped-lines', which is the default: the continuation was
joined onto the line above as it was written, so there is no wrap newline left
to mark.  With rejoining off the rows do stay separate up there and no flag
follows them, which is the one place this does not reach -- an accepted cost of
a mode whose whole point is that the buffer keeps the grid's line structure.

Written only when it differs from what is already there, which on the ordinary
row is never.  A property change runs `after-change-functions' exactly as an
insertion does, and jit-lock is on that hook -- see `cooked--render-block'.  A
row inside a run has a freshly inserted newline that carries nothing, so the
common case reads a property and writes none; only a row that has just started
or stopped wrapping pays anything.

At `point-max' there is nothing to mark yet: the last screen row is left
unterminated -- see `cooked--fit-screen' -- so a wrap on it has no newline to
sit on.  The mark is owed instead, and paid when extending the region gives the
row its newline; see `cooked--owed-wrap'.

An integer rather than t says the row was rendered without blanks that are
interior to its line.  A row is inserted without its trailing blanks, wrapped
or not, so cells the child left blank before the line went on to the next row
are missing from the buffer and nothing in it says so.  At twenty columns
\"see https://e.x/abc end\" leaves \"see https://e.x/abc\" on the first row,
nineteen cells wide, and \"end\" on the second; joined at the newline with
nothing between them they read as \"https://e.x/abcend\".
`cooked-link--join-wrapped' joins such a row with a space instead.  The integer
itself is how many of the row's own last columns are not blanks of the line but
a wide character's leftover room -- `日本語' at five columns leaves column 4 to
the `語' that moved down whole, and that cell belongs to no character of the
line -- zero when there is no such room.  Nothing in Lisp reads the number
today: the rewrap arithmetic that did is gone, and `cooked-link--join-wrapped'
only asks whether the mark is one."
  (if (>= eol (point-max))
      (cooked--owe-wrap eol wrap)
    (let ((marked (get-text-property eol 'cooked-wrap)))
      (cond ((eq wrap marked))
            (wrap (put-text-property eol (1+ eol) 'cooked-wrap wrap))
            (t (remove-text-properties eol (1+ eol) '(cooked-wrap nil)))))))

(defun cooked--owe-wrap (end mark)
  "Record that the row ending at END, the end of the buffer, is owed MARK.
MARK nil forgets any debt.  See `cooked--owed-wrap'."
  (cond (mark
         (if cooked--owed-wrap
             (progn (set-marker (car cooked--owed-wrap) end)
                    (setcdr cooked--owed-wrap mark))
           (setq cooked--owed-wrap (cons (copy-marker end t) mark))))
        (cooked--owed-wrap
         (set-marker (car cooked--owed-wrap) nil)
         (setq cooked--owed-wrap nil))))

(defun cooked--owed-wrap-mark ()
  "The mark `cooked--owed-wrap' holds, if it is still owed to the last row.

Still owed when its marker is the end of the buffer.  Text added at the end
moves the marker along, so it is anywhere else only once the row it was
recorded for has stopped being the last, and the two ways a row stops being
the last with the marker still at the end forget the debt themselves: a trim
of the rows at the end, in `cooked--fit-screen', and history taking the row,
in `cooked--forget-owed-wrap-above'.  The row may be empty: a wide character
that did not fit wraps a row of nothing but blanks."
  (when-let* ((owed cooked--owed-wrap)
              ((= (marker-position (car owed)) (point-max))))
    (cdr owed)))

(defun cooked--forget-owed-wrap-above (start)
  "Forget the owed wrap mark if the row it was owed to is history above START.

Called where `cooked--screen-start' moves to START.  The row ending at the
owed marker went into history with the rows above START when the marker is
not below it, and history carries no wrap marks."
  (when-let* ((owed cooked--owed-wrap)
              ((<= (car owed) start)))
    (cooked--owe-wrap nil nil)))

(defun cooked--goto-screen-run-end (start first count)
  "End of the last of COUNT screen rows, the first of them row FIRST at START.

The far edge of the region `cooked--render-rows' deletes before writing a
coalesced run of damaged rows into it, and the rows below the first may not
exist yet: the screen region is trimmed to its content, so a run reaching past
what the buffer holds has to extend it exactly as a single row does.

The cheap path is a `forward-line' from START, since the rows of a run are
adjacent lines by construction.  It is trusted only when it both moved the whole
way and landed at a line start -- `forward-line' counts a final line lacking a
newline as a line moved, so it can report success while sitting at that line's
end, which would put the far edge of the deletion a whole row short.  Anything
else falls back to `cooked--goto-screen-row', which is the one place that knows
how to add the missing lines.

COUNT of one is answered without moving at all, and not merely as an
optimisation: screen row 0 does not always begin a buffer line -- it continues
the wrapped row handed to scrollback before it -- so the `bolp' test above
would send the ordinary single-row case down the fallback for no reason."
  (goto-char start)
  (if (or (= count 1)
          (and (zerop (forward-line (1- count))) (bolp)))
      (line-end-position)
    (cooked--goto-screen-row (+ first count -1) 'extend)
    (line-end-position)))

(defun cooked--damage-in-order (rows edits)
  "ROWS and EDITS as one list in ascending row index.

ROWS is the drain's `:rows', entries of (INDEX . BLOCK), and EDITS its
`:edits', entries of (INDEX CHAR-START CHAR-END LENGTH . BLOCK).  The two are
told apart by what follows INDEX: a block begins with its text, a string, and an
edit with a number.  Both arrive in ascending order and never name the same
row, so this is a merge, and the order it keeps is what lets
`cooked--render-rows' walk forward from the row it placed last.  A drain
without edits, which is most of them, is returned as it came."
  (if (null edits)
      rows
    (let (out)
      (while (or rows edits)
        (push (if (and rows (or (null edits) (< (caar rows) (caar edits))))
                  (pop rows)
                (pop edits))
              out))
      (nreverse out))))

(defun cooked--render-rows (rows &optional alt relocations edits)
  "Rewrite damaged ROWS, an alist of (FIRST . BLOCK), and apply EDITS.

Each entry is a *run* of contiguous damaged rows: FIRST is the index of its
first row, and BLOCK holds them all as one string with newlines between them
and a row table saying where each begins -- see `cooked--render-block'.  The
core coalesces the run; a run of one row is the ordinary case and the same code
path.

EDITS are the drain's `:edits', rows of which only part changed, each
\(INDEX CHAR-START CHAR-END LENGTH . BLOCK): the characters CHAR-START to
CHAR-END of the row, or to its end when CHAR-END is nil, are replaced with
BLOCK's text, and anything past LENGTH characters is deleted -- spaces
`cooked--pad-to-cursor' added for a cursor that has moved on, which rewriting
the whole row would have taken away too.
A spinner turning then costs one character rather than the row, and the markers
and overlays on the rest of the row stay where they are.  On the primary screen
a row with changed neighbours arrives as an edit too, so a few adjacent rows
each changing a little keep theirs, where a block would have taken them all;
on the alternate screen such rows still come as one block, for its cost.
Everything done to a
row after it is written happens to an edited row too, measured over the whole
row: the width guard, the wrap mark, the relocations and the notification.

That is where the win is.  Emacs pays per edit rather than per character, so a
24-row repaint that was 24 `delete-region's and 24 `insert's is one of each,
and the style and decoration loops in `cooked--render-block' run once across
the whole run instead of once per row.  What the core will not do is coalesce
across a row it was not told about: an undamaged row between two damaged ones
breaks the run, because deleting and reinserting it would destroy every marker
and overlay anchored in text nothing asked to have rewritten.  See
`contiguous_runs' in src/wire.rs, which is where that decision lives.

ROWS is expected in ascending index order, which is how the drain reports
damage.  Order is not required for correctness -- a run out of sequence is
found by walking from `cooked--screen-start' -- but it is what keeps a
full-height repaint from being quadratic; see the walk below.

ALT says whether these rows belong to the alternate screen, and is passed in
rather than read from `cooked--alt' because that variable still holds the
*previous* drain's answer at this point in `cooked--apply' -- which would leave
the frame that restores the primary screen, and every link on it, unscanned.

RELOCATIONS are the positions to carry across the runs this rewrites, from
`cooked--capture-relocations', and are the one thing here that is not about
putting text in the buffer.  They are handled from inside this loop rather than
corrected afterwards, because the offset a position had within its old row
is readable only in the moment between finding the run and deleting it.  Nil for
the ordinary drain, in which case the two calls below cost one test per run and
one per row.

Returns the (BEG . END) bounds of each live row it rewrote, in the order it
wrote them, for `cooked--notify-rows-rendered' to announce once the drain has
finished putting its markers right -- see `cooked-row-rendered-functions'.  The
positions stay exact while they wait: a row is rendered in place, so writing a
later row never moves an earlier one, and nothing between here and the
notification inserts or deletes anything either.  Nil for the alternate screen,
which has no such seam at all."
  (let* (rendered
        ;; Which row was placed last, and where it began.  The damaged rows
        ;; arrive in ascending order -- `Screen::drain_damage' walks the dirty
        ;; flags by index -- so each row is a short `forward-line' from the one
        ;; before it, and only the first has to be found from
        ;; `cooked--screen-start'.
        ;;
        ;; Restarting the walk per row is what made a repaint quadratic in the
        ;; height of the screen.  `forward-line' scans characters rather than
        ;; skipping to an index, so a full-height frame re-read most of the
        ;; screen region once for every row in it: at 96 rows of 200 columns
        ;; that was about half the cost of rendering the frame.
        ;;
        ;; Nil until the first row lands, and left alone by a row that had to
        ;; fall back, so the next row walks from the last position actually
        ;; known good rather than from one that was never reached.
        (last-row nil)
        (last-start nil)
        ;; Once per drain, not once per row.  `cooked--guard-row-width' needs
        ;; the window this buffer's rows are laid out for, and finding it means
        ;; asking `window-max-chars-per-line' of every window showing the
        ;; buffer -- a subr that does its measuring inside `with-selected-window'.
        ;; Per row that was two `select-window' round trips per displayed window
        ;; per rendered row, at a drain rate whose floor is 125 Hz, and
        ;; `select-window' is advised: see `cooked--sync-cursor-type' for what
        ;; else that runs.  The answer cannot change while a render is in
        ;; progress -- nothing here creates, deletes or resizes a window -- so
        ;; the multi-window case is answered exactly as before: one narrowest
        ;; window, chosen from the same list, for every row of this drain.
        ;;
        ;; Nil when the buffer is displayed nowhere, and then the guard is not
        ;; called at all: there is no layout for a row to disagree with, which is
        ;; the answer it would have reached per row anyway.
        (layout (and cooked-rejoin-wrapped-lines (cooked--layout-window)))
        ;; And once per drain for the same reason, and out of the same window:
        ;; the guard's memo of which rows Emacs lays out on one line, together
        ;; with whether this font renders ASCII one cell per character.  Both
        ;; are answers about the font and the geometry rather than about a row,
        ;; and checking that they are still current costs more per row than the
        ;; questions they answer.  See `cooked--wrap-cache'.
        (cache (and layout (cooked--wrap-cache layout)))
        ;; Whether a row the core calls `glyph' -- uniform but for its box
        ;; glyphs -- counts as uniform.  It does exactly when those glyphs are
        ;; being drawn as cooked's own bitmaps, which are one cell wide by
        ;; construction, and those are the conditions `cooked--apply-deco'
        ;; draws them under.  On a terminal frame there is no cell size, the
        ;; characters render as the font's own, and the row is measured.
        ;; `unset' until a `glyph' row asks, so a drain without one pays
        ;; nothing for the question.
        (glyphs-drawn 'unset))
    (save-excursion
      (pcase-dolist (`(,index . ,entry) (cooked--damage-in-order rows edits))
        ;; The short walk, or the whole one.  `bolp' is the same check
        ;; `cooked--goto-screen-row' makes and for the same reason: `forward-line'
        ;; counts a final line lacking a newline as a line moved, so it can
        ;; report success while leaving point at that line's end rather than at
        ;; the start of the row asked for.  Every row reaching here has a
        ;; positive index -- `last-row' is only set from one already placed --
        ;; so that check needs no row 0 exemption, which is the one case
        ;; legitimately not at a line start.
        (unless (and last-start
                     (> index last-row)
                     (progn (goto-char last-start)
                            (and (zerop (forward-line (- index last-row)))
                                 (bolp))))
          (cooked--goto-screen-row index 'extend))
        (let* ((span (and (numberp (car entry)) entry))
               (block (if span (nthcdr 3 entry) entry))
               (row-start (point))
               (start (if span
                          (min (+ row-start (car span)) (line-end-position))
                        row-start))
               ;; One entry per row of the run, and the only thing that says how
               ;; many rows this block covers.  A block that arrived without a
               ;; table is one row and no measurements -- nothing the core
               ;; produces is shaped that way, but the guard must not be handed
               ;; a nil width, which is a `wrong-type-argument' several layers
               ;; from anything that would explain it.
               (table (or (nth 3 block) '((0 nil nil))))
               (end (cond ((null span)
                           (cooked--goto-screen-run-end start index (length table)))
                          ((nth 1 span)
                           (min (+ row-start (nth 1 span)) (line-end-position)))
                          (t (line-end-position)))))
          ;; The two edits the whole change is about: one deletion spanning the
          ;; run and one insertion of its text.  The trailing newline of the
          ;; run's last row is left where it is -- a damaged row is written into
          ;; a line that already exists, and the block carries newlines only
          ;; *between* its rows for exactly that reason.
          ;;
          ;; Between finding the run and deleting it is the only moment a carried
          ;; position can still be read against the rows it was written for.
          (when relocations (cooked--note-relocations relocations start end))
          (delete-region start end)
          (goto-char start)
          (cooked--render-block block index (and span row-start))
          (when span
            (let ((keep (+ row-start (nth 2 span))))
              (when (< keep (line-end-position))
                (delete-region keep (line-end-position)))))
          ;; Now walk the rows just written.  Two things are per row and neither
          ;; can be done from the offsets in the table: the guard measures a row
          ;; against Emacs' own layout of it, and the wrap mark goes on the
          ;; newline after it, which an edit's LENGTH deletion has already
          ;; moved.  So every position here is read from the buffer rather than
          ;; computed from where the text was put.
          (let ((pos row-start)
                (i 0))
            (dolist (row table)
              (pcase-let ((`(,_ ,cells ,uniform ,wrapped ,hash) row))
                (goto-char pos)
                ;; An edit leaves the characters it did not change where they
                ;; are, so the guard's marks from the row as it was outlive the
                ;; measurement they were made from.  A block deletes the row
                ;; first and carries them off with it; see
                ;; `cooked--clear-guard-marks'.
                (when span (cooked--clear-guard-marks pos (line-end-position)))
                ;; The row table's own measurements: how many cells the row
                ;; occupies on the grid, whether anything in it could render
                ;; wider than that, and its layout hash.  All three are
                ;; by-products of the core building the row, so the guard need
                ;; not measure them; see `cooked--guard-row-width'.
                ;;
                ;; Nothing is owed to the core for what it does.  The guard
                ;; hides the tail of a row Emacs lays out too wide rather than
                ;; deleting it, so the buffer still holds the characters the
                ;; core sent and its copy of the screen stays true.
                (when (and layout cells)
                  (cooked--guard-row-width
                   pos cells layout
                   (if (eq uniform 'glyph)
                       (if (eq glyphs-drawn 'unset)
                           (setq glyphs-drawn
                                 (and cooked-box-drawing-images
                                      (image-type-available-p 'xbm)
                                      (cooked--deco-cell-size)
                                      t))
                         glyphs-drawn)
                     uniform)
                   cache hash))
                (goto-char pos)
                (cooked--mark-row-wrap (line-end-position) wrapped))
              ;; Nothing scans the row here.  Rewriting the text is what tells
              ;; jit-lock the row is no longer fontified, so redisplay asks
              ;; `cooked--fontify-region' for it -- and only if this frame is one
              ;; that reaches the screen.  See there.
              ;;
              ;; The bounds are read after the guard rather than before it, so
              ;; that a layer reading the row back sees the marks the guard put
              ;; on it.  The guard does not move them: it hides the tail of a
              ;; row Emacs laid out wider than `cooked--cols' assumed, and
              ;; hidden characters are still characters.
              ;;
              ;; The optional layers are still announced from here rather than
              ;; from redisplay, because a mark on this screen is not yet where
              ;; it belongs; `cooked--notify-rows-rendered' is the other half of
              ;; that.
              (let ((eol (line-end-position)))
                (when relocations (cooked--place-relocations relocations i pos eol))
                (when (and cooked-row-rendered-functions (not alt))
                  (push (cons pos eol) rendered))
                ;; The next run walks from the last row of this one, which is
                ;; where this loop leaves off rather than where it started.
                (setq last-row (+ index i)
                      last-start pos
                      i (1+ i)
                      pos (min (1+ eol) (point-max)))))))))
    (nreverse rendered)))

;; A theme change used to clear the core's copy of the screen from here, so that a
;; repaint of the same cells would arrive to be drawn in the new colours.  It does not
;; any more, and nothing replaces it: a cell in an indexed colour wears `cooked-fg-*'
;; and `cooked-bg-*', which `cooked--sync-ansi-faces' moves under the text, so the rows
;; already rendered follow the theme where they are.  Re-rendering them would produce
;; the same characters with an equal face, at the price of a frame.  The one attribute
;; that does bake a colour, an indexed SGR 58 underline, is caught by
;; `cooked--bakes-an-indexed-color-p', which damages every row rather than only
;; forgetting it; a theme that changes the default font moves `cooked--layout-stamp'
;; and is caught by `cooked--wrap-cache' the same way.

(defun cooked--notify-rows-rendered (bounds)
  "Hand BOUNDS, this drain's rewritten live rows, to the optional layers.

Separate from `cooked--render-rows' and called well after it, which is the
whole point of the split -- `cooked-row-rendered-functions' says why, and
`cooked--apply' is where the two halves are ordered against the marks.

Errors are contained per row: this runs from inside the process filter, over
text that is already correct without whatever the layer was going to add, so a
cosmetic pass must not be able to end a redisplay."
  (when cooked-row-rendered-functions
    (pcase-dolist (`(,beg . ,end) bounds)
      (cooked--run-seam 'cooked-row-rendered-functions beg end))))

(defun cooked--window-size ()
  "Rows and columns to give the child.

A buffer can be displayed in several windows at once, across frames, but the
child has exactly one size.  Take the smallest: sizing to a larger window would
wrap and clip everything shown in the smaller one.

`window-max-chars-per-line' rather than `window-body-width', because the
latter counts the column reserved for the continuation glyph and measures
in the frame's canonical character width.  Both round the wrong way: claim
one column too many and the child wraps a line the window cannot fit,
which shows up as the last character folding onto a line of its own.

The column count comes from `cooked--layout-window' rather than from a second
minimum taken here.  They were computed separately and are the same quantity by
construction -- that window is *defined* as the narrowest one -- so a change to
what counts as narrowest had two places to land and only ever reached one."
  (let ((windows (get-buffer-window-list (current-buffer) nil t)))
    (if-let* ((layout (cooked--layout-window)))
        (cons (max 1 (apply #'min (mapcar #'cooked--window-rows windows)))
              (max 1 (window-max-chars-per-line layout)))
      (cons cooked--rows cooked--cols))))

(defun cooked--window-rows (window)
  "Rows of text WINDOW can actually show, rounding a partial row down.

`window-body-height' divides by the frame's *canonical* character height,
so it disagrees with the buffer whenever the default face is remapped —
`text-scale-mode' being the usual way — and it says nothing about
`line-spacing'.  Dividing the real pixel height by the real line height
gets both, and floors, so a row that is only half visible is not a row we
claim to have."
  (floor (window-body-height window t) (window-default-line-height window)))

(provide 'cooked-screen)
;;; cooked-screen.el ends here
