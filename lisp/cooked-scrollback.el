;;; cooked-scrollback.el --- Capping what the buffer keeps -*- lexical-binding: t; -*-

;;; Commentary:

;; The transcript's upper bound: how many lines above the live screen a session
;; keeps, and the two ways text up there is taken away again.
;;
;; Not opt-in: the drain pipeline in cooked-render.el requires this.  It is kept
;; out of that file because a cap is not part of the pipeline, only something
;; the pipeline calls once per drain.
;;
;; The subject is one number the two ends co-own, and every function here is
;; about not lying about it.  Emacs holds the transcript text; the emulator holds
;; a count of how much of its top row's line has already left for Emacs, so that
;; a rewrap resumes that line where the buffer wraps it.  Delete above the seam
;; without saying so and the emulator goes on continuing a line that is no longer
;; there, silently, until the next resize.  `cooked--discard-scrollback' is that
;; news being given; `cooked--discard-scrollback-region' is the case where it is
;; provably not owed, which is what makes cutting one command's output out of the
;; middle possible at all.  `cooked--split-seam' is the third case and the odd
;; one: nothing was deleted at all, the buffer simply never took the
;; continuation, because `cooked-rejoin-wrapped-lines' is off.
;;
;; Below cooked-render.el, which is the direction the calls run: the drain ends
;; with `cooked--trim-scrollback' and dispatches `CSI 3 J' to
;; `cooked--discard-scrollback', and neither needs anything the pipeline defines.
;; `cooked-clear-scrollback', which cuts and then drains to repaint, is a command
;; in cooked-mode.el for that reason.

;;; Code:

(require 'seq)
(require 'cooked-util)
(require 'cooked-state)
(require 'cooked-command)
(require 'cooked-deco)
(require 'cooked-pending)

(cooked--declare-core)

(defcustom cooked-scrollback-lines 10000
  "How many lines of transcript to keep above the live screen, or nil for all.

Rows that scroll off the emulator's screen become ordinary buffer text and are
never taken back, so without a cap a session grows for as long as it runs: one
`yes', one chatty build, one `tail -f' left overnight, and the buffer is the
largest thing in your Emacs.  Every other terminal emulator caps this, and this
is cooked's version of `vterm-max-scrollback' or `eat-term-scrollback-size'.

Counted in lines of the buffer above `cooked--screen-start', which is not
quite the same as rows the child printed: `cooked-rejoin-wrapped-lines' joins
a wrapped row onto the line above, so one long line of output is one line here
however many screen rows it took.  That is the honest unit, being the one the
buffer is actually made of, and it is the unit every other emulator caps in.

*It does mean this setting alone does not decide how much memory a session
uses.*  At a cap of 500, 80-column output retains the same forty thousand
characters either way, but 800-column output retains about nine times as much
with rejoining on, because each retained line is ten screen rows of text rather
than one.  You asked for 500 lines and got 500 lines, for whichever meaning of a
line the other setting chose -- so turning rejoining *off* is what shrinks your
history.  Cap in characters instead and the
failure inverts: one pathological line evicts the entire transcript, which is
worse and is why this is not counted that way.

Trimming is not free -- it releases images, prunes command records and tells the
emulator its seam moved -- so it happens in batches once the buffer is over the
cap by a margin rather than a line at a time.  A little over the cap is normal
and expected.

nil keeps everything, which is what you want if the session is a transcript you
mean to save, and is a decision to make deliberately."
  :type '(choice (const :tag "Keep everything" nil) natnum)
  :group 'cooked)

(defconst cooked--scrollback-slack 0.1
  "How far over `cooked-scrollback-lines' the buffer may go before a trim.

A fraction of the cap.  Trimming on the very first line over would delete on
almost every drain of a flood, and each deletion costs a walk of the text being
cut to find the images in it -- so the buffer is allowed to overshoot and the
cost is paid once for many lines instead of many times for one.")

(defun cooked--split-seam ()
  "Drop the emulator's carry once the buffer has stopped holding a continuation.

The seam is one number the two ends co-own: how much of screen row 0's logical
line has already left for Emacs.  `cooked-rejoin-wrapped-lines' decides whether
Emacs holds one at all.  With rejoining on it does, and the carry is exactly
what makes a rewrap resume that line where the buffer wraps it; with rejoining
off every row handed over gets a newline of its own, so the buffer's half is
zero and the emulator's is a claim about text that is not there.

Nothing on the other side resets it.  The two `cooked--forget-history' calls
below are both discards, and this mode discards nothing -- it just never
continues anything.  Left standing the claim is spent at the next rewrap:
`Logical::take_front' cuts a fragment off the front of row 0's line to top the
head up to a whole number of rows at the new width, and with rows staying split
that fragment arrives as a line of its own -- a stub of a few characters, or of
nothing but the padding a chunk boundary landed in, wedged between the
transcript and the screen.  One more of them at every resize, and the head
growing by the width of each.  `cooked--check-seam' said nothing about any of
it for as long as this ran from `cooked--trim-scrollback', at the foot of the
drain: the reset landed after the assertion had already looked, so the
assertion had to exclude this mode.  Called from `cooked--apply' one line above
it, the claim is settled before the assertion reads it, and the assertion
covers both modes -- with rows split, Emacs' half of the seam is simply always
zero.

The test is the buffer's own head rather than the flag alone, and that is what
makes this safe to run unconditionally: the news is only given once
`cooked--screen-start' is at a line beginning, which is the buffer saying it
continues nothing.  So a mid-line seam is left alone -- the text handed over
while rejoining was still on is a continuation, and the emulator counting it is
right about it until the next row handed over closes that line and this
notices.  Which is also why `cooked-toggle-rejoin-wrapped-lines' needs nothing
of its own: at the moment the flag flips the two ends still agree, so a resize
arriving before the next drain rewraps against a head that is really there.

Called once per drain from `cooked--trim-scrollback', because every eviction of
a wrapped row makes the claim again.  Two integer comparisons on the drains
where there is nothing to do."
  (when (and cooked--session
             (not cooked-rejoin-wrapped-lines)
             (/= 0 (cooked-grid-head cooked--grid)))
    (when-let* ((start (cooked--screen-start-position))
                ((save-excursion (goto-char start) (bolp))))
      (cooked--forget-history cooked--session)
      (setf (cooked-grid-head cooked--grid) 0))))

(defvar-local cooked--scrollback-counted nil
  "Where `cooked--scrollback-newlines' last counted to.

A list (MARKER CHARS . NEWLINES): MARKER is where the count stopped, CHARS how
many characters were above it and NEWLINES how many of those were newlines.")

(defun cooked--scrollback-newlines (screen)
  "How many newlines the buffer holds above SCREEN, counting only new text.

Scrollback is appended at the screen and otherwise only ever deleted from, so
until something is deleted the newlines above the last count are still there:
a drain that pushed three rows off the screen is counted three rows' worth.
Whether the text above the last count is still the text that was counted is
judged by its length.  A deletion from it, by a trim or by
`cooked--discard-scrollback-region', changes the length, and the next call
counts from `point-min' again.

This is what `cooked--trim-scrollback' runs on every drain of a long session.
Counting from `point-min' instead cost 57 us a drain under ten thousand
80-column lines and 159 us under 800-column ones, against 0.7 and 1.2 us for
this, interleaved in one compiled Emacs at load 1.8 over 16 CPUs; the newline
cache made no difference to it.

Called with the buffer widened."
  (pcase-let ((`(,marker ,chars . ,newlines) cooked--scrollback-counted))
    (unless (and marker
                 (<= marker screen)
                 (= (- marker (point-min)) chars))
      (setq marker (set-marker (or marker (make-marker)) (point-min))
            newlines 0))
    (setq newlines (+ newlines
                      ;; `save-excursion' too, because narrowing moves point
                      ;; into the region, and point is on the screen below it.
                      (save-excursion
                        (save-restriction
                          (narrow-to-region marker screen)
                          (1- (line-number-at-pos screen))))))
    (set-marker marker screen)
    (setq cooked--scrollback-counted
          (cons marker (cons (- screen (point-min)) newlines)))
    newlines))

(defun cooked--trim-scrollback ()
  "Cut the transcript back to `cooked-scrollback-lines' if it has outgrown it.

Runs at the end of every drain, and does nothing on all but a few of them: the
line count is only taken once the buffer holds enough characters to have that
many lines at all, and the deletion only happens once it is over the cap by
`cooked--scrollback-slack'.

Cuts at a line beginning, because `cooked--discard-scrollback' hands the
emulator a seam and half a line is not one.

`cooked--split-seam' does not run here but in `cooked--apply', one line
above `cooked--check-seam', so that the assertion sees the seam after it has
been split rather than before."
  (save-restriction
    (widen)
    (when-let* ((cap cooked-scrollback-lines)
                (screen (cooked--screen-start-position))
                (threshold (+ cap (max 1 (round (* cap cooked--scrollback-slack)))))
                ;; A line above the screen carries at least its own newline, so
                ;; there cannot be THRESHOLD of them in fewer than THRESHOLD
                ;; characters.  That makes this a sound way to skip the count
                ;; rather than a guess at how wide a line is: a gate assuming
                ;; some average width would never open for output narrower than
                ;; that, and a flood of `line1234' would sit far past the cap.
                ((>= (- screen (point-min)) threshold))
                ;; Only the scrollback added since the last drain is counted, which
                ;; is what makes it affordable on every drain of a long session:
                ;; see `cooked--scrollback-newlines'.  A line is a newline and the
                ;; screen's own, so THRESHOLD lines is THRESHOLD newlines above it.
                ((>= (cooked--scrollback-newlines screen) threshold)))
      (save-excursion
        (goto-char screen)
        (forward-line (- cap))
        (when (> (point) (point-min))
          (cooked--discard-scrollback (point)))))))

(defun cooked--discard-scrollback (end)
  "Delete scrollback from `point-min' up to END, and tell the emulator.

The only sanctioned way to delete above `cooked--screen-start', and worth
routing every future caller — a scrollback cap, a `clear' handler — through
rather than open-coding.  The scrollback is the one piece of state the two ends
co-own: Emacs holds the text, while the emulator holds a count of how much of
its top row's line already left for Emacs, so that a rewrap resumes that line
where the buffer wraps it.  A wrapped line can span the boundary being cut, so
a deletion that does not say so leaves the emulator continuing a line that is
no longer there — and the desync is silent until the next resize.

Widens first, so it still clears while a full-screen program has the buffer
narrowed to the alt screen — where `point-min' is the top of the screen and
this would otherwise quietly do nothing."
  ;; Before the deletion, while the positions still mean something.  A record whose
  ;; whole region is in the text being cut would survive as an empty region sitting
  ;; at the cut -- indistinguishable from a command that genuinely printed nothing,
  ;; which is exactly what the records exist to describe -- and `\[cooked-previous-command]'
  ;; and folding walk them.
  (setq cooked--commands
        (seq-filter (lambda (command) (> (cooked--command-end-position command) end))
                    cooked--commands))
  ;; Same shape, one line down: an image belongs to the rows displaying it, so
  ;; the ids in the text about to go are the candidates and the walk afterwards
  ;; decides which of them this was the last of.
  (let (images)
    (save-restriction
      (widen)
      (setq images (cooked--release-images (point-min) end))
      (cooked--with-child-edit
        (delete-region (point-min) end)))
    (cooked--collect-images images))
  ;; Everything below just moved up by the length of what went.
  (cooked--check-undo-anchor)
  (when cooked--session
    (cooked--forget-history cooked--session)
    ;; `cooked--grid' is a snapshot of the last drain, and this is the one thing that
    ;; changes the emulator's seam without one.  Left stale it describes a head that was
    ;; just deleted, which `cooked--check-seam' would rightly call a desync — and which
    ;; anything else reading the seam before the next drain would believe.
    (setf (cooked-grid-head cooked--grid) 0)))

(defun cooked--discard-scrollback-region (beg end)
  "Delete scrollback between BEG and END, telling the emulator only if it must.

The narrower sibling of `cooked--discard-scrollback', for deleting one
command's output out of the middle rather than everything above a point.

What the two ends co-own is exactly one number: how much of the emulator's top
row's line has already left for Emacs.  A cut that finishes short of
`cooked--screen-start' cannot change it -- the text row 0 continues is still
there, still ending where it did -- so it needs no bookkeeping at all, and
saying so is what makes deleting scrolled-off output possible.  A cut that
reaches the seam does remove that head, and then this owes the emulator the same
news `cooked--discard-scrollback' gives it."
  (when-let* ((screen (cooked--screen-start-position))
              ((< beg end)))
    (let ((end (min end screen)))
      (when (< beg end)
        (let ((at-seam (= end screen))
              images)
          (save-restriction
            (widen)
            (setq images (cooked--release-images beg end))
            (cooked--with-child-edit
              (delete-region beg end)))
          (cooked--collect-images images)
          (cooked--check-undo-anchor)
          (when (and at-seam cooked--session)
            (cooked--forget-history cooked--session)
            (setf (cooked-grid-head cooked--grid) 0)))))))

(provide 'cooked-scrollback)
;;; cooked-scrollback.el ends here
