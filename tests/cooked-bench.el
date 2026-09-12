;;; cooked-bench.el --- Where does the time go on the Emacs side? -*- lexical-binding: t; -*-

;;; Commentary:

;; tests/throughput.rs measures the emulator core and stops at `Term::drain'.
;; That is the half that was already fast: a real session also pays to marshal
;; the delta across the module boundary and to apply it to the buffer, and
;; neither was measured by anything.  This is the other half.
;;
;;   emacs -Q --batch -L lisp -L tests -l cooked-bench.el -f cooked-bench
;;
;; Batch mode has no window system, so the box-drawing figures here measure spec
;; construction and property application, not rasterization.  That is the part
;; that scales per cell, which is what makes it worth watching.
;;
;; Every case reports a distribution rather than a total, and *the median is the
;; headline*.  Not a house preference: garbage collection is deliberately left
;; running inside a measured loop, so a case that allocates has a p99 fifteen
;; times its median with nothing at all wrong -- see `cooked-bench--record' for
;; the GC count that makes that readable.  A mean sits somewhere between the two
;; and describes neither.

;;; Code:

(require 'cl-lib)
(require 'jit-lock)
(require 'cooked)
(require 'cooked-mode)

(defvar cooked-bench-results nil
  "Accumulated (LABEL SAMPLES DETAIL) rows, for `cooked-bench--report'.

SAMPLES is the list of per-iteration seconds, not a total: every case here
reports a spread, because a single total cannot tell a workload that is
genuinely slow from one that was interrupted once by something else on the
machine.")

(defvar cooked-bench-min-duration 0.5
  "Seconds a measured loop must run before its samples are worth reading.

A case declares an iteration count, but that count is a *floor*: if the
declared iterations finish faster than this the loop keeps going.  The reason
is that `float-time' resolution and scheduler granularity are fixed costs, so
a loop that finishes in 5 ms is mostly measuring them.  Half a second is
ghostel's figure and there is no reason to differ.")

;;;; Two guards, because a timing result is only as good as the machine
;;
;; Neither of these makes a number more accurate.  What they do is refuse to
;; let a number that is *not* a measurement of cooked be read as one, and they
;; catch different things: the load check looks at the machine before the run,
;; and the stability check looks at the samples afterwards.  A build that was
;; already running when the suite started is caught by the first; a build that
;; starts halfway through is caught only by the second.

(defvar cooked-bench-load-fraction 0.5
  "Fraction of the CPUs that may already be busy before a run is refused.

Half is the figure ghostel's plan settled on, and the reasoning is that the
benchmark wants a core to itself with room for the child processes it spawns.
Set `COOKED_BENCH_FORCE' in the environment to run anyway.")

(defvar cooked-bench-unstable-ratio 3.0
  "How far a case's p99 may exceed its median before it is called unstable.

Self-relative on purpose, so it needs no per-machine calibration -- a wall
clock threshold would have to be retuned for every machine the suite runs on
and would be silently wrong on the ones nobody retuned it for.")

(defvar cooked-bench-min-clean-samples 3
  "Fewest collection-free samples a case needs before stability is judged.

Below this there is no distribution to speak of and the check would be reading
noise.  The real-child cases sit near this line by nature: an iteration there
is a whole session, so there are five or six of them, not five thousand.")

(defvar cooked-bench--load nil
  "The (ONE-MINUTE . CPUS) load sampled once at the start of the run.

Sampled once and never again, which is not laziness.  The suite spawns child
processes and burns a core for the better part of a minute, so it raises the
very number it would be reading; a mid-run re-check would find the load the
benchmark itself created and refuse in the middle of its own work.")

(defun cooked-bench--load-sample ()
  "The (ONE-MINUTE . CPUS) load right now, or nil if the system will not say."
  (condition-case nil
      (cons (/ (car (load-average)) 100.0) (num-processors))
    (error nil)))

(defun cooked-bench--load-ok-p (sample)
  "Non-nil when SAMPLE is quiet enough for a timing result to be trusted.

Nil SAMPLE -- a system with no `load-average' -- is not a busy machine, it is
an unknown one, and a guard that cannot tell should not block."
  (or (null sample)
      (< (car sample) (* cooked-bench-load-fraction (cdr sample)))))

(defun cooked-bench--check-load ()
  "Print the sampled load, and refuse to run on a machine that is already busy.

The one-minute average lags by design, so a run started twenty seconds after a
big build still reads high and is still refused.  That is the conservative
direction: the cost is a rerun, and the cost of the other direction is a
number in a commit message that nothing in the code explains."
  (setq cooked-bench--load (cooked-bench--load-sample))
  (let ((forced (getenv "COOKED_BENCH_FORCE")))
    (if (null cooked-bench--load)
        (message "load: unavailable on this system -- guard cannot judge, running anyway")
      (message "load: %.2f over %d cpus (limit %.2f)%s"
               (car cooked-bench--load) (cdr cooked-bench--load)
               (* cooked-bench-load-fraction (cdr cooked-bench--load))
               (cond ((cooked-bench--load-ok-p cooked-bench--load) "")
                     (forced " -- BUSY, forced by COOKED_BENCH_FORCE")
                     (t " -- BUSY"))))
    (unless (or (cooked-bench--load-ok-p cooked-bench--load) forced)
      (let ((complaint
             (format "machine is busy (load %.2f over %d cpus) -- quieten it, or set COOKED_BENCH_FORCE=1 to measure anyway"
                     (car cooked-bench--load) (cdr cooked-bench--load))))
        ;; A refusal is not a bug, and in batch a `user-error' is printed with
        ;; a full backtrace anyway -- `backtrace-on-error-noninteractive' is
        ;; consulted by the top-level handler, after any binding here has
        ;; unwound, so it cannot be suppressed from inside.  Ten lines of
        ;; internals in front of one sentence of advice trains the reader to
        ;; scroll past both.  So batch exits non-zero with the sentence, which
        ;; is what `make bench' needs, and a caller with a Lisp stack to unwind
        ;; gets the error it can handle.
        (if noninteractive
            (progn (message "cooked-bench: %s" complaint) (kill-emacs 1))
          (user-error "cooked-bench: %s" complaint))))))

;;;; The measured primitive
;;
;; One place where iteration, warmup, GC and statistics are decided, so that
;; every case in this file is comparable with every other and none of them has
;; to get the discipline right on its own.  The semantics are ghostel's
;; `ghostel-bench--measure' (bench/ghostel-bench.el:270) -- discarded warmup,
;; three collections, a trial phase that raises the iteration count to reach
;; `cooked-bench-min-duration', and a loop that continues while *either* the
;; count is unmet or the clock is short -- with two deliberate divergences.
;;
;; First, every per-iteration time is kept rather than summed.  ghostel reports
;; a mean everywhere except typing latency, and a mean is the statistic one
;; interfering scheduler event destroys: a case that ran 200 clean iterations
;; and one 40 ms stall reports a number nothing in the code explains.  The
;; median survives that, so the median is the headline here and the mean is
;; printed beside it as the thing to distrust when the two disagree.  The same
;; argument is made at greater length in the header of
;; scripts/bench-scroll-ceiling.el, from the other direction: there it is the
;; compositor's frame callback rather than another process, and the median was
;; still the only statistic that held still.
;;
;; Second, the trial phase scales on *wall* time while the sample charged is
;; whatever BODY-FN says it is.  ghostel does not need the distinction because
;; its bodies are pure computation, but cooked's real-child cases spend most of
;; their wall clock waiting in `accept-process-output' for a shell loop, and
;; charge only the drain and apply that happen between waits.  Scaling on the
;; charged time would divide a 0.5 s target by a 4 ms sample and ask for a
;; hundred and twenty child processes.

(defun cooked-bench--pct (sorted p)
  "The P quantile of SORTED, by nearest rank.

Nearest rank rather than interpolation, so the figure printed is always a time
that was actually observed -- an interpolated p99 of a twelve-sample run is a
number no iteration ever took.  Same rule as `ceil--pct' in
scripts/bench-scroll-ceiling.el."
  (nth (min (1- (length sorted)) (floor (* p (length sorted)))) sorted))

(defun cooked-bench--flag-instability (label clean)
  "Say so, loudly, if CLEAN's spread says LABEL was interfered with.

CLEAN is the samples from iterations during which no garbage collection
happened, and using only those is the whole trick.  The obvious check -- p99
against the median of everything -- fires on nearly every case in this file,
because collection is deliberately left running and an allocating workload
therefore has a p99 fifteen times its median as a matter of course.  A flag
that fires on eight rows out of eighteen tells the reader nothing.  Among
iterations that did not collect, though, there is no reason for one to take
three times as long as the typical one except that something else on the
machine took the CPU, which is exactly the condition worth shouting about and
the one loadavg cannot see because it starts *during* the run.

The alternative considered was to keep every sample and ask whether the tail
is larger than collection can account for -- flag when more iterations exceed
three times the median than there were collections.  It was tried and it is
worse: on a quiet machine it fired on six of ten cases, because a case that
collects fifteen times has a few more than fifteen samples over the line for
ordinary reasons, while dropping the collecting iterations outright fired on
none.  Under load the two agreed row for row, so the extra sensitivity bought
nothing to pay for the false alarms with.

What it cannot see is a *uniform* slowdown, and this is the reason the two
guards are not redundant.  Measured under forty spinners on sixteen cores, the
median of the styled per-frame case moved from 0.6 ms to 7.5 ms -- twelve
times slower, every iteration of it -- and the ratio barely moved, because a
self-relative test divides the interference out of both halves.  Three of the
ten cases in that run were flagged and the rest reported inflated numbers with
no complaint at all.  Only the load check refuses that run, and it did; the
figures above exist because `COOKED_BENCH_FORCE' was set to get them.  Nor is
the converse redundant: the load check samples once at the start and cannot
see a build that begins in the middle.

Marked rather than failed: an interfered case is still evidence, and a suite
that errors out on a laptop that woke up to index something is a suite people
stop running."
  (when (>= (length clean) cooked-bench-min-clean-samples)
    (let* ((sorted (sort (copy-sequence clean) #'<))
           (median (cooked-bench--pct sorted 0.50))
           (p99 (cooked-bench--pct sorted 0.99))
           (ratio (if (> median 0) (/ p99 median) 0)))
      (when (> ratio cooked-bench-unstable-ratio)
        (message "  %-40s UNSTABLE (p99 %.1fx median over %d gc-free samples) -- rerun"
                 label ratio (length sorted))))))

(defun cooked-bench--record (label samples &optional clean gcs detail)
  "Record and print SAMPLES, a list of per-iteration seconds, under LABEL.

CLEAN is the subset of SAMPLES whose iterations collected no garbage, GCS is
how many collections happened inside the measured loop, and DETAIL is appended
to the printed row.

The GC count is printed rather than kept to one side because it is what makes
the tail readable.  Collection is deliberately not suppressed during a loop --
a workload that allocates should pay for it, as a real session does -- so a
case that allocates heavily can have a p99 twenty times its median with
nothing wrong: the slow iterations are the ones that collected.  Without the
count there is no way to tell that apart from another process having taken the
CPU, which is a different problem with a different fix."
  (push (list label samples clean gcs detail) cooked-bench-results)
  (let* ((sorted (sort (copy-sequence samples) #'<))
         (n (length sorted))
         (mean (/ (apply #'+ sorted) (float n))))
    (message "  %-40s n=%5d  min %7.3f  p50 %7.3f  p99 %7.3f  max %7.3f  mean %7.3f ms  %3d gc  %s"
             label n
             (* 1000 (car sorted))
             (* 1000 (cooked-bench--pct sorted 0.50))
             (* 1000 (cooked-bench--pct sorted 0.99))
             (* 1000 (car (last sorted)))
             (* 1000 mean)
             (or gcs 0)
             (or detail "")))
  (cooked-bench--flag-instability label clean))

(defun cooked-bench--measure (label unit-count body-fn &optional iterations)
  "Time BODY-FN repeatedly and record its distribution under LABEL.

BODY-FN is called with no arguments.  If it returns a float that float is the
sample, and the rest of the call is not cooked's to answer for -- which is how
the real-child cases exclude the child's own runtime.  Any other return value
means the wall time of the call is the sample.  A float specifically, rather
than \"non-nil\": bodies that end in a call whose value nobody wanted are the
common case here, and one of them returning a cons was enough to make the
charge nonsense before the test was narrowed.

UNIT-COUNT is how many units of work one iteration does -- frames, rows,
drains.  When it is more than one, the per-unit median is printed alongside,
because that is the figure that compares across cases of different sizes.

ITERATIONS is a floor and defaults to 1.  The loop runs until both the count
is met and `cooked-bench-min-duration' has elapsed, so a case that got faster
than its trial estimate still runs long enough to be timed."
  (let ((n (max 1 (or iterations 1)))
        (samples nil))
    (garbage-collect)
    ;; The discarded warmup: first call through a code path pays for
    ;; autoloading, the byte-compiler's lazy work and every cache in the render
    ;; being cold, and none of that is what the case is about.
    (funcall body-fn)
    (garbage-collect)
    ;; Trial phase.  Three iterations is enough to size the loop and cheap
    ;; enough to throw away, which is what happens to its samples -- they were
    ;; taken before the count was settled and there is no reason to mix them in.
    (let* ((trials (min 3 n))
           (trial-start (float-time)))
      (dotimes (_ trials) (funcall body-fn))
      (let ((trial-wall (- (float-time) trial-start)))
        (when (and (> trial-wall 0) (< trial-wall cooked-bench-min-duration))
          (setq n (max n (ceiling (/ (* cooked-bench-min-duration trials)
                                     trial-wall)))))))
    (garbage-collect)
    ;; Not suppressed during the loop, deliberately.  A workload that allocates
    ;; its way into a collection should pay for it here, because a real session
    ;; does; the three collections above only make sure it is not paying for
    ;; garbage some earlier case left behind.
    (let ((start (float-time))
          (collections gcs-done)
          (clean nil)
          (done 0))
      (while (or (< done n) (< (- (float-time) start) cooked-bench-min-duration))
        ;; `gcs-done' is read across the whole call rather than across the
        ;; charged region, which for the real-child cases includes the wait in
        ;; `accept-process-output'.  So an iteration that collected only while
        ;; waiting is dropped from CLEAN although its charged time was
        ;; untouched.  That errs towards judging fewer samples, which is the
        ;; direction a guard against false alarms should err in.
        (let* ((gc-before gcs-done)
               (t0 (float-time))
               (charged (funcall body-fn))
               (sample (if (floatp charged) charged (- (float-time) t0))))
          (push sample samples)
          (when (= gcs-done gc-before) (push sample clean))
          (setq done (1+ done))))
      (setq collections (- gcs-done collections))
      (cooked-bench--record
       label samples clean collections
       (when (> unit-count 1)
         (let ((sorted (sort (copy-sequence samples) #'<)))
           (format "%d units/iter, %.3f ms/unit at p50"
                   unit-count
                   (/ (* 1000 (cooked-bench--pct sorted 0.50)) unit-count))))))
    samples))

(defvar cooked-bench--cell '(10 . 20)
  "The cell size in pixels the bench window claims, as (WIDTH . HEIGHT).

Batch's window is a terminal window and reports a cell of one pixel by one, so
once the buffer is displayed `cooked--deco-cell-size' prefers that to
`cooked--last-cell' and every box glyph is rasterized into a single pixel.
Nothing errors; the box-drawing figures just quietly stop being about the
bitmaps.  Holding the window's answer at the 10x20 every other batch fixture
uses keeps attaching the window to one change instead of two, which is what
makes a before-and-after diff of these numbers mean anything.

Also the handle the rescale benchmark turns, because it is now the only way to
move the cell: see `cooked-bench-rescale'.")

(defmacro cooked-bench--with-session (argv &rest body)
  "Run BODY in a live cooked buffer running ARGV."
  (declare (indent 1))
  `(let ((buffer (generate-new-buffer "*cooked-bench*")))
     (unwind-protect
         (cl-letf (((symbol-function 'cooked--cell-size)
                    (lambda (_window) cooked-bench--cell)))
           (with-current-buffer buffer
             (cooked-mode)
             (cooked--start ,argv)
             (cooked--refresh-keymap)
             ;; What `cooked--deco-cell-size' falls back to when the buffer is
             ;; displayed nowhere -- kept for the drain's own size bookkeeping,
             ;; and now shadowed for decoration purposes by the window below.
             (setq cooked--last-cell '(10 . 20))
             ;; Batch's selected window does not display anything, but
             ;; `get-buffer-window-list' returns it all the same, and that is the
             ;; whole of what the window-dependent paths test for.  Without this
             ;; they short-circuit and the benchmark measures less work than a
             ;; session does: `cooked--layout-window' answers nil, so
             ;; `cooked--guard-row-width' skips every row and the wrap cache is
             ;; never consulted, and the bottom anchoring in cooked-render.el has
             ;; no window to walk.  Same reason and same idiom as
             ;; `cooked-tests--display-buffer' in cooked-tests-helpers.el, whose
             ;; docstring makes the point for the guard specifically -- a row
             ;; displayed nowhere has no layout to disagree with, so there is
             ;; nothing to trim and nothing to measure.
             ;;
             ;; It does not make this a graphical measurement.  The window has no
             ;; glyph matrix to rasterize into, so the box-drawing figures still
             ;; measure spec construction rather than drawing, and the guard still
             ;; counts characters where a real frame would ask for font metrics --
             ;; a gap the scroll-ceiling run measured at 2.4x in apply alone.  What
             ;; attaching the window buys is that the code runs at all.
             (set-window-buffer (selected-window) buffer)
             ,@body))
       (with-current-buffer buffer (cooked--cleanup))
       (kill-buffer buffer))))

(defvar cooked-bench--last-detail nil
  "Detail string left by the most recent session, for `cooked-bench--session'.

An iteration of a real-child case is a whole session, so the drain count and
buffer size differ from one to the next and there is no single figure for the
run.  The last iteration's is reported, which is representative because the
child is the same every time; the spread that actually matters is in the
samples.")

(defun cooked-bench--drain-until-exit (&optional seconds)
  "Pump the current session to completion, charging only drain and apply.

The child runs on its own while we wait in `accept-process-output', so the
elapsed time of the whole loop is mostly the child's.  Only the work Emacs does
per wakeup is accumulated, which is the number this file exists to produce, and
it is that accumulation -- not the wall clock -- that is returned as the
sample."
  (let ((deadline (+ (float-time) (or seconds 30)))
        (spent 0.0)
        (drains 0))
    (while (and cooked--session (< (float-time) deadline) (null cooked--exit))
      (accept-process-output nil 0.02)
      (when cooked--session
        (let ((t0 (float-time)))
          (cooked--apply (cooked--drain cooked--session cooked-rejoin-wrapped-lines))
          (setq spent (+ spent (- (float-time) t0))
                drains (1+ drains)))))
    (setq cooked-bench--last-detail
          (format "%d drains, %d buffer chars" drains (buffer-size)))
    spent))

(defun cooked-bench--session (label argv &optional iterations)
  "Measure LABEL as repeated whole sessions of ARGV, drained to exit.

One iteration is one spawn, one flood and one teardown, because there is no
smaller repeatable unit for a case whose whole point is a real child: the
drains inside a single session are not interchangeable samples, the first
seeing a cold buffer and the last a full one.  So the count stays small -- the
default floor of three is usually raised to five or six by
`cooked-bench-min-duration' -- and at that n the p99 is the maximum by
construction.  That is not a defect to hide: the p99 column on these rows is
reading `the worst of about six sessions', which is exactly what the stability
check downstream wants from it."
  (cooked-bench--measure
   label 1
   (lambda ()
     (cooked-bench--with-session argv (cooked-bench--drain-until-exit)))
   (or iterations 3))
  (message "  %-40s   %s" "" cooked-bench--last-detail))

(defun cooked-bench-flood ()
  "Plain output scrolling into the buffer: the `cat a big file' case."
  (cooked-bench--session
   "flood, 20k plain lines"
   '("/bin/sh" "-c" "i=0; while [ $i -lt 20000 ]; do \
echo \"line $i the quick brown fox jumps over the lazy dog\"; i=$((i+1)); done")))

(defun cooked-bench-styled ()
  "Heavily coloured output: the `ls --color' / build-log case.

This is the one the face cache is for — every line carries several styled runs,
so it is the shape that turns a per-run cost into a visible one."
  (cooked-bench--session
   "flood, 20k styled lines"
   '("/bin/sh" "-c" "i=0; while [ $i -lt 20000 ]; do \
printf '\\033[1;32mword\\033[0m \\033[38;2;10;20;30mrgb\\033[0m plain %s\\n' $i; \
i=$((i+1)); done")))

(defun cooked-bench-repaint ()
  "Full-screen repaint over the alternate screen: the `htop' case.

Nothing scrolls, so this isolates the damaged-row path — every frame rewrites
every row in place and the buffer never grows."
  (cooked-bench--session
   "repaint, 400 frames x 24 rows"
   '("/bin/sh" "-c" "printf '\\033[?1049h'; f=0; while [ $f -lt 400 ]; do \
r=1; while [ $r -le 24 ]; do printf '\\033[%s;1H\\033[4%sm' $r $((f%8)); \
printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; r=$((r+1)); done; \
f=$((f+1)); done; printf '\\033[?1049l'")))

(defun cooked-bench-box-drawing ()
  "A repaint made of box-drawing characters, which take the bitmap path.

The reason this is separate from `cooked-bench-repaint': every cell here gets a
`display' property and an image spec of its own, so it is the workload that
tells you whether `cooked--box-image-cache' is earning its keep.  Compare the
two figures — the gap is what box drawing costs over plain text."
  (cooked-bench--session
   "repaint, 400 frames of box drawing"
   '("/bin/sh" "-c" "printf '\\033[?1049h'; f=0; while [ $f -lt 400 ]; do \
r=1; while [ $r -le 24 ]; do printf '\\033[%s;1H' $r; \
printf '\\342\\224\\200%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; \
r=$((r+1)); done; f=$((f+1)); done; printf '\\033[?1049l'")))

(defun cooked-bench-marshalling ()
  "Cost of `cooked--drain' alone, with nothing applied to the buffer.

Isolates the module boundary: the same delta is built and converted to Lisp,
but never rendered.  Subtract this from the figures above to see how much of a
drain is marshalling rather than redisplay."
  (cooked-bench--measure
   "drain only, 20k plain lines" 1
   (lambda ()
     (cooked-bench--with-session
         '("/bin/sh" "-c" "i=0; while [ $i -lt 20000 ]; do \
echo \"line $i the quick brown fox jumps over the lazy dog\"; i=$((i+1)); done")
       (let ((deadline (+ (float-time) 30))
             (spent 0.0)
             (drains 0))
         (while (and cooked--session (< (float-time) deadline)
                     (null (plist-get (cooked--drain cooked--session) :exit)))
           (accept-process-output nil 0.02)
           (when cooked--session
             (let ((t0 (float-time)))
               (cooked--drain cooked--session cooked-rejoin-wrapped-lines)
               (setq spent (+ spent (- (float-time) t0))
                     drains (1+ drains)))))
         (setq cooked-bench--last-detail
               (format "%d drains, nothing rendered" drains))
         spent)))
   3)
  (message "  %-40s   %s" "" cooked-bench--last-detail))

;;;; Per-frame rendering, driven synthetically
;;
;; The benchmarks above are honest about a real session and therefore say very
;; little about per-frame cost: damage coalescing means 400 frames of repaint
;; reach Emacs as four drains, and the 396 that were superseded are never
;; rendered at all.  That is the design working, but it is not the number you
;; want when the child paints at a rate Emacs *can* keep up with — htop at 1Hz
;; renders every frame, and then the per-frame cost is the whole story.
;;
;; So these hand `cooked--apply' the same plist shape the module produces, one
;; frame at a time, against a child that is asleep and sending nothing.  No
;; scheduling noise, no coalescing, and reproducible run to run.

(defun cooked-bench--update (rows &optional alt)
  "An update plist of ROWS, shaped exactly as `cooked--drain' returns one.

`:height', `:used' and `:head' are not optional: `cooked--apply' builds a
`cooked-grid' from them and `cooked--fit-screen' does arithmetic on it, so a
plist without them fails on a nil rather than benchmarking anything.  They were
missing here from the moment the drain grew them, which is how
`cooked-bench-per-frame' came to error out instead of reporting."
  (let ((height (length rows)))
    (list :scrolled nil :rows rows
          :height height :used height :head 0
          :cursor '(0 0 t block) :alt alt
          :app-cursor nil :keys 'legacy :mode 'raw :events nil :exit nil)))

(defun cooked-bench--plain-rows (count cols)
  "COUNT damaged rows of unstyled text, the cheapest thing to render.

A row is (INDEX . BLOCK), and a block is (TEXT STYLE-SPANS DECO-SPANS
LINK-SPANS WIDTH UNIFORM) with offsets in characters -- see
`cooked--render-block'.  Unstyled text carries no span list at all, which is
the case the sparse shape is built around.  WIDTH is the cell count and
UNIFORM is t here because every character is one ASCII byte on one cell."
  (let ((text (make-string cols ?x)))
    (cl-loop for i below count collect (cons i (list text nil nil nil cols t)))))

(defun cooked-bench--le (value bytes)
  "VALUE as BYTES little-endian bytes, as a list."
  (cl-loop for b below bytes collect (logand (ash value (* -8 b)) 255)))

(defun cooked-bench--style-record (start end fg bg ul attrs)
  "One packed style span, as `Block::push_style\=' in src/lib.rs lays it out.

START and END are character offsets, FG, BG and UL already-packed colours in
`Color::packed\=''s tagged encoding, and ATTRS the bitmask.  Hand-built here
because the point of these fixtures is to hand `cooked--apply\=' exactly what the
module would, without a child having to produce it -- so the layout is spelled
out on this side too, and `cooked--style-record\=' is the number that has to
agree."
  (append (cooked-bench--le start 4) (cooked-bench--le end 4)
          (cooked-bench--le fg 4) (cooked-bench--le bg 4)
          (cooked-bench--le ul 4) (cooked-bench--le attrs 2)))

(defun cooked-bench--styled-rows (count cols)
  "COUNT damaged rows split into eight differently-styled spans.

The spans arrive packed, not as lists -- see `cooked-bench--style-record\='.  An
indexed foreground and a default background, which is what a shell or a build
log actually emits and so the case the encoding is tuned for."
  (let ((width (/ cols 8)))
    (cl-loop for i below count
             collect (cons i (list (make-string (* 8 width) ?x)
                                   (apply #'unibyte-string
                                          (cl-loop for r below 8
                                                   append (cooked-bench--style-record
                                                           (* r width)
                                                           (* (1+ r) width)
                                                           (logior (ash 1 24) (mod (+ i r) 8))
                                                           0 0
                                                           (if (cl-evenp r) 1 0))))
                                   nil nil (* 8 width) t)))))

(defun cooked-bench--url-rows (count cols)
  "COUNT damaged rows each carrying a URL, which is what the goto-addr scan costs.

Plain text otherwise, so the gap against `cooked-bench--plain-rows\=' is the whole
of what `cooked--fontify-links\=' spends on a row that has something to find."
  (let* ((url "curl https://example.com/some/long/path ")
         (text (truncate-string-to-width (concat url (make-string cols ?x)) cols)))
    (cl-loop for i below count collect (cons i (list text nil nil nil cols t)))))

(defun cooked-bench--box-rows (count cols)
  "COUNT damaged rows of box drawing, every cell taking the bitmap path.

The decoration is `(glyph . PACKED)\=' as the module hands it over: four
little-endian bytes per run of one shape, the `BoxGlyph\=' bits and the number of
characters drawing them.  0x0050 is a plain light horizontal — left and right
edges at weight 1 — which is what a border is made of, and a row of them is the
single record the encoding exists to produce."
  (let* ((text (make-string cols ?─))
         (deco (cons 'glyph (unibyte-string #x50 #x00
                                            (logand cols #xff) (ash cols -8))))
         (spans (list (list 0 deco))))
    ;; UNIFORM is nil, unlike every other fixture here: the box-drawing
    ;; character is three bytes, and UNIFORM asks about bytes as well as cells.
    ;; That is not a detail -- it is the flag that decides whether
    ;; `cooked--guard-row-width' can finish without measuring anything, so a
    ;; fixture claiming t would make the box rows look like the cheap case and
    ;; measure the one path this row exists to exercise.
    (cl-loop for i below count
             collect (cons i (list text nil spans nil cols nil)))))

(defun cooked-bench--frames (label rows &optional frames)
  "Apply ROWS as a damaged-row update, one frame per iteration.

The unit is one `cooked--apply' rather than a batch of them, which the earlier
shape could not offer: a batch total divided by its count hides whether the
frames all cost the same.  It is safe to iterate here because they do -- the
alternate screen rewrites its rows in place, so the buffer does not grow and
the thousandth frame costs what the first did.  That was checked before the
loop was allowed to auto-scale, not assumed.

FRAMES is the floor, defaulting to the 200 the earlier batches used, so a
declared count is never lower than what the recorded numbers were taken at."
  (cooked-bench--with-session '("/bin/sh" "-c" "sleep 300")
    (cooked-tests--settle-briefly)
    (let ((update (cooked-bench--update rows t)))
      (cooked-bench--measure label 1
                             (lambda () (cooked--apply update))
                             (or frames 200))
      (message "  %-40s   %d rows/frame" "" (length rows)))))

(defun cooked-tests--settle-briefly ()
  "Let the child start and the first drain land."
  (dotimes (_ 5) (accept-process-output nil 0.02))
  (when cooked--session
    (cooked--apply (cooked--drain cooked--session cooked-rejoin-wrapped-lines))))

(defun cooked-bench-per-frame ()
  "Per-frame render cost by run shape, with coalescing taken out of the picture."
  (cooked-bench--frames "per-frame, 24x80 plain"
                        (cooked-bench--plain-rows 24 80) 200)
  (cooked-bench--frames "per-frame, 24x80 styled (8 runs/row)"
                        (cooked-bench--styled-rows 24 80) 200)
  (cooked-bench--frames "per-frame, 24x80 box drawing"
                        (cooked-bench--box-rows 24 80) 200)
  ;; `cooked-bench--frames' paints the alternate screen, where the URL scan is off
  ;; by default -- see `cooked-detect-links-on-alt-screen'.  What is under test is
  ;; the scan, not which screen it runs on, so it is asked for here.
  (let ((cooked-detect-links-on-alt-screen t))
    (cooked-bench--frames "per-frame, 24x80 with a URL per row"
                          (cooked-bench--url-rows 24 80) 200)))

;;;; Cosmetic passes, and when they are paid
;;
;; The benchmarks above time `cooked--apply' and nothing else, which is the whole
;; cost today because every cosmetic pass runs from inside the render: a damaged
;; row is scanned for URLs as it is written, whether or not that row is ever
;; displayed.
;;
;; That is the thing under review.  `goto-address-mode' does not work that way --
;; it calls `jit-lock-register', so Emacs scans at redisplay, over the visible
;; region, and text overwritten before the next redisplay is never scanned at
;; all.  Moving cooked onto the same footing would make the scan's cost depend on
;; how many frames actually reach the screen rather than on how many were
;; rendered.
;;
;; Batch mode never redisplays, so a benchmark that only calls `cooked--apply'
;; cannot see that difference: it would report the scan's cost dropping to zero,
;; which is an artifact of nothing having asked for it rather than a saving.  So
;; these drive the fontification redisplay would have driven, explicitly, once
;; every RATIO frames -- and time it alongside the apply, so the figure is the
;; whole cost of getting those frames onto a screen either way.
;;
;; Read them as a pair.  While the scan runs from the render path, RATIO changes
;; nothing: the work is tied to frames rendered.  Once it runs from jit-lock the
;; two rows separate, which is what the URL rows now show.
;;
;; What RATIO is *not* is a claim about a real session, and this is worth stating
;; because the figure invites the mistake.  Measured in a live frame -- an Emacs
;; sitting in its command loop while `yes' floods a buffer -- `cooked--apply' runs
;; 40 times against 91 redisplays, and a spinner rewriting one line 155 against
;; 215.  Renders never outrun redisplays: the wake byte is not re-armed until
;; `cooked--ready', and the core coalesces everything that arrives in between, so
;; Emacs already renders about what it is going to draw.  A RATIO of 8 does not
;; happen, and the live screen therefore saves almost nothing by deferring.
;;
;; The win is the scrollback, and it does not depend on RATIO at all.  A flood
;; pushes megabytes through the buffer that scroll past between two redisplays
;; and are never displayed at all; the eager passes scanned every one of those
;; lines, and jit-lock scans only what a window shows.  Over six seconds of
;; `yes' emitting a URL per line, that is 33 thousand characters scanned against
;; 12 million -- 361x less text.  None of which this benchmark can see, because
;; the frames here are handed over one at a time with no scrollback in them.

(defun cooked-bench--fontify-as-redisplay (beg end)
  "Run the fontification redisplay would run over BEG..END.

Nothing at all while no jit-lock function is registered in this buffer, which
is what makes one benchmark fair to both designs: today the scan has already
been paid inside `cooked--apply\=' and there is nothing left here to do, so the
figure is the render path's own cost and not an empty call added to it."
  (when (bound-and-true-p jit-lock-mode)
    (jit-lock-fontify-now beg end)))

(defun cooked-bench--deferred-frames (label rows frames ratio)
  "Apply ROWS FRAMES times, fontifying once every RATIO frames.

RATIO stands in for coalescing: 1 is a child slow enough that every frame it
paints is displayed, 8 is one painting eight times between two redisplays --
which is the ordinary case for anything fast, and the case the deferral exists
for.  The scan is driven over the screen region rather than the whole buffer,
because that is what a window would have shown.

The iteration here is a whole group of RATIO frames plus the one fontification
that follows them, not a single frame.  It has to be: a per-frame unit would
put the scan's whole cost into every RATIOth sample and nothing into the rest,
so the median would report the frames that skipped the scan and the comparison
between RATIO 1 and RATIO 8 -- the only reason these rows exist -- would come
out as a difference in how often the tail fires rather than in cost.  The
per-unit figure printed beside the group is the per-frame number the earlier
shape reported."
  (cooked-bench--with-session '("/bin/sh" "-c" "sleep 300")
    (cooked-tests--settle-briefly)
    ;; The primary screen: the alternate one has the URL scan off by default,
    ;; and what is under test is when the scan is paid rather than which screen
    ;; pays it.  See `cooked-detect-links-on-alt-screen'.
    (let ((update (cooked-bench--update rows nil)))
      (cooked-bench--measure
       label ratio
       (lambda ()
         (dotimes (_ ratio) (cooked--apply update))
         (cooked-bench--fontify-as-redisplay
          (or (cooked--screen-start-position) (point-min)) (point-max)))
       (max 1 (/ frames ratio)))
      (message "  %-40s   %d rows/frame, 1 redisplay per %d frames"
               "" (length rows) ratio))))

(defun cooked-bench-deferred ()
  "What the cosmetic passes cost against how often the screen is actually drawn."
  (dolist (ratio '(1 8))
    (cooked-bench--deferred-frames
     (format "URL scan, 24x80, 1 draw per %d frames" ratio)
     (cooked-bench--url-rows 24 80) 200 ratio))
  ;; The floor both designs are measured against: the same frames with no
  ;; cosmetic pass asked for at all.
  (let ((cooked-detect-links nil))
    (cooked-bench--deferred-frames
     "URL scan off, 24x80 (the floor)"
     (cooked-bench--url-rows 24 80) 200 1))
  ;; Box drawing is not deferred -- `cooked--apply-deco' runs from the render,
  ;; where every other cosmetic pass used to.  These two rows are what deferring
  ;; it could be worth, and they are here to be read against each other rather
  ;; than as a result: while the decoration is applied per rendered row, the
  ;; ratio changes nothing, which is exactly what the URL rows said before the
  ;; scan moved.  The gap to the plain figure -- some 2.8ms of the 2.9 -- is the
  ;; whole of what a frame that is rendered and never displayed currently pays
  ;; for a picture nobody sees.
  ;;
  ;; What the ratio cannot say is how often that actually happens in a live
  ;; session, and it is the whole question: cooked's backpressure holds the next
  ;; wakeup until `cooked--ready', so renders and redisplays are far closer to
  ;; 1:1 here than a synthetic ratio of 8 suggests.  Deferring only ever pays for
  ;; the frames in between.
  (dolist (ratio '(1 8))
    (cooked-bench--deferred-frames
     (format "box drawing, 24x80, 1 draw per %d frames" ratio)
     (cooked-bench--box-rows 24 80) 200 ratio))
  (cooked-bench--deferred-frames
   "plain, 24x80 (the floor box drawing would fall to)"
   (cooked-bench--plain-rows 24 80) 200 1))

(defun cooked-bench-rescale ()
  "Cost of `cooked--rescale-deco\=', the walk a cell-size change runs.

The one thing in cooked that rewrites decoration already in the scrollback, and
so the only thing that can bring a transcript back into agreement with the font.
It is a whole-buffer walk under `widen\=', paid per cell-size change -- a font
change, a `text-scale-adjust\=', a frame dragged to a different-DPI monitor --
and never per drain, which is what `cooked--sync-size\=''s gate is for.  What it
scales with is the length of the transcript, so the figure to watch is the
per-row one.

The transcript is grown by copying rendered text, properties and all, rather
than by driving forty thousand cells through the module: what is under test here
is the walk, and the walk reads nothing but the `cooked-deco\=' property."
  (cooked-bench--with-session '("/bin/sh" "-c" "sleep 300")
    (cooked-tests--settle-briefly)
    (cooked--apply (cooked-bench--update (cooked-bench--box-rows 24 80)))
    (let ((inhibit-read-only t)
          (buffer-undo-list t)
          (chunk (buffer-substring (point-min) (point-max))))
      (goto-char (point-max))
      (dotimes (_ 40) (insert chunk)))
    ;; Alternating the cell every iteration is what makes the loop measure
    ;; anything: `cooked--rescale-deco' declines to walk a buffer that is
    ;; already at the size asked for, so a loop that requested the same cell
    ;; twice would time the gate from the second iteration onward and report a
    ;; walk that costs almost nothing.  The two sizes are the pair the earlier
    ;; shape used, and the walk is symmetric between them.
    ;;
    ;; It is `cooked-bench--cell' that has to move, not `cooked--last-cell'.
    ;; Poking the latter worked only while the buffer was displayed nowhere:
    ;; once there is a window, `cooked--deco-cell-size' prefers what the window
    ;; says and never looks at the fallback, so the gate closed on every
    ;; iteration and the case reported seventy thousand iterations of four
    ;; microseconds -- the gate, timed over and over, labelled as the walk.  A
    ;; benchmark that measures nothing does not fail, it just reports a
    ;; flattering number, which is the failure mode this whole file is written
    ;; against.  Moving the window's answer also drives the walk the way
    ;; production does, through `cooked--deco-cell-size', rather than around it.
    (let ((rows (count-lines (point-min) (point-max)))
          (cells (buffer-size))
          (toggle nil))
      (cooked-bench--measure
       (format "rescale-deco, %d rows of box drawing" rows) rows
       (lambda ()
         (setq toggle (not toggle)
               cooked-bench--cell (if toggle '(12 . 26) '(10 . 20))
               cooked--last-cell cooked-bench--cell)
         (cooked--rescale-deco))
       2)
      (message "  %-40s   %d cells" "" cells))
    ;; The gate the whole design rests on: asked for a size it is already at, it
    ;; does not walk anything.  Left un-alternated on purpose -- this row is the
    ;; gate and nothing else.
    (cooked-bench--measure "rescale-deco, cell unchanged" 1
                           (lambda () (cooked--rescale-deco)))
    (message "  %-40s   %s" "" "the gate `cooked--sync-size' relies on")))

(defun cooked-bench--report ()
  "Print the run footer.

The total is the time actually spent under measurement, which is no longer the
sum of one pass over each workload: every case now iterates until it has
enough samples to have a distribution, so this figure grew when the primitive
landed without anything getting slower.  It is a cost-of-the-suite number, not
a result."
  (message "\n%-42s %11s" "total" "")
  (message "  %-40s %8.1f ms"
           "all iterations of all benchmarks"
           (* 1000 (apply #'+ (mapcar (lambda (row) (apply #'+ (cadr row)))
                                      cooked-bench-results)))))

(defun cooked-bench ()
  "Run every benchmark in this file."
  (setq cooked-bench-results nil)
  (message "cooked: Emacs-side cost per workload (drain + apply only)")
  (message "per-iteration distribution; read the p50 -- see the Commentary")
  ;; Before anything is timed, and before the header is complete: the load is
  ;; part of the run's provenance, so it is printed whether or not it passes.
  (cooked-bench--check-load)
  (message "")
  (cooked-bench-marshalling)
  (cooked-bench-flood)
  (cooked-bench-styled)
  (cooked-bench-repaint)
  (cooked-bench-box-drawing)
  (message "")
  (cooked-bench-per-frame)
  (message "")
  (cooked-bench-deferred)
  (message "")
  (cooked-bench-rescale)
  (cooked-bench--report))

(provide 'cooked-bench)
;;; cooked-bench.el ends here
