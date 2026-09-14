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

(defvar cooked-bench--last-counts nil
  "The (DRAINS APPLIES) the most recent session charged, for the tests.

DRAINS counts calls of `cooked--drain-and-apply', or of `cooked--drain' in
`cooked-bench--drain-only-until-exit', and APPLIES the calls of `cooked--apply'
made inside them.  `cooked-tests-bench.el' counts the same calls independently
and checks the two agree, which is the property the numbers depend on.")

(defun cooked-bench--charged (pump)
  "Call PUMP, timing every drain Emacs makes meanwhile, and return what they cost.

The value is (SECONDS DRAINS APPLIES): the time spent inside
`cooked--drain-and-apply', how many times it was entered, and how many calls of
`cooked--apply' those entries made.  A re-entrant call is folded into the drain
under way, as the function itself folds it, so no time is counted twice.

The drains are charged where production makes them, rather than made by the
harness, and that is the correction.  `cooked--start' installs the wake-pipe
filter, and the filter runs inside `accept-process-output' and drains there.  A
harness that timed only its own `cooked--apply' after each wait charged the
drains the filter had not already taken: counted with advice on the 20k-line
flood, the filter applied rows 14 and 15 times and the harness 5.  Advice on
the function the filter calls sees every drain whoever asks for it, and PUMP
needs to do nothing but wait.

The advice is inside the timed region, which costs a closure call per drain:
microseconds, against drains of a millisecond and more."
  (let ((spent 0.0) (drains 0) (applies 0) (inside nil))
    (let ((charge (lambda (fn &rest args)
                    (if inside
                        (apply fn args)
                      (let ((t0 (float-time)))
                        (setq inside t)
                        (unwind-protect (apply fn args)
                          (setq inside nil
                                spent (+ spent (- (float-time) t0))
                                drains (1+ drains)))))))
          (count (lambda (&rest _) (when inside (setq applies (1+ applies))))))
      (advice-add 'cooked--drain-and-apply :around charge)
      (advice-add 'cooked--apply :before count)
      (unwind-protect (funcall pump)
        (advice-remove 'cooked--drain-and-apply charge)
        (advice-remove 'cooked--apply count)))
    (list spent drains applies)))

(defun cooked-bench--drain-until-exit (&optional seconds)
  "Pump the current session to completion, charging only drain and apply.

The child runs on its own while we wait in `accept-process-output', so the
elapsed time of the whole loop is mostly the child's.  Only the work Emacs does
per wakeup is accumulated, which is the number this file exists to produce, and
it is that accumulation -- not the wall clock -- that is returned as the
sample.  The wakeups are the production ones, paced by the core; see
`cooked-bench--charged' for why the harness no longer drains for itself.

SECONDS bounds the wait, 30 by default."
  (let ((deadline (+ (float-time) (or seconds 30))))
    (pcase-let ((`(,spent ,drains ,applies)
                 (cooked-bench--charged
                  (lambda ()
                    (while (and cooked--session (< (float-time) deadline)
                                (null cooked--exit))
                      (accept-process-output nil 0.02))))))
      (setq cooked-bench--last-counts (list drains applies)
            cooked-bench--last-detail
            (format "%d drains, %d applies, %d buffer chars"
                    drains applies (buffer-size)))
      spent)))

(defun cooked-bench--drain-only-until-exit (&optional seconds)
  "Drain the current session to completion without applying, charging every drain.

The wake-pipe filter is replaced with `ignore' first.  Left in place it would
drain and apply inside `accept-process-output', and the drains timed here would
be whatever it had left over, each of them nearly empty.  Nothing re-arms the
core's wake byte after that, which does not matter: the drains here are made on
the harness's own 20 ms cadence and the core's backlog is emptied by them.

Every call of `cooked--drain' is timed, including the one that finds the exit;
that call was once made untimed in the loop condition, so a drain in two went
uncharged.  SECONDS bounds the wait, 30 by default."
  (set-process-filter cooked--wake #'ignore)
  (let ((deadline (+ (float-time) (or seconds 30)))
        (spent 0.0)
        (drains 0)
        (exited nil))
    (while (and cooked--session (< (float-time) deadline) (not exited))
      (accept-process-output nil 0.02)
      (let* ((t0 (float-time))
             (update (cooked--drain cooked--session cooked-rejoin-wrapped-lines)))
        (setq spent (+ spent (- (float-time) t0))
              drains (1+ drains)
              exited (plist-get update :exit))))
    (setq cooked-bench--last-counts (list drains 0)
          cooked-bench--last-detail (format "%d drains, nothing rendered" drains))
    spent))

(defun cooked-bench--hide ()
  "Take the current buffer off screen, as switching another buffer into its window does.

Both window changes are reported by hand, because batch Emacs runs no window
change functions: first that the buffer is on screen, which is what makes it
one that can be hidden, then that no window shows it.  On a tree without the
hidden level this changes nothing a drain does, which is what makes the same
case its own before figure."
  (cooked--window-buffers-changed)
  (set-window-buffer (selected-window) (get-buffer-create " *cooked-bench-elsewhere*"))
  (cooked--window-buffers-changed))

(defun cooked-bench--session (label argv &optional iterations hidden)
  "Measure LABEL as repeated whole sessions of ARGV, drained to exit.

With HIDDEN, each session's buffer is taken off screen before its child runs;
see `cooked-bench--hide'.  The child is started by the first line Emacs sends
it, so every drain of its output is a hidden buffer's.

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
     (cooked-bench--with-session (if hidden
                                     `("/bin/sh" "-c" ,(concat "read -r _; " (nth 2 argv)))
                                   argv)
       (when hidden
         (cooked-bench--hide)
         (cooked--send cooked--session "\n"))
       (cooked-bench--drain-until-exit)))
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

(defun cooked-bench-hidden ()
  "Output into a buffer no window shows, next to the same output shown.

Two children.  A yes flood keeps the backlog at its limit, so a hidden buffer
is still drained as often as a shown one and the difference is the screen each
drain leaves out.  A build printing a line a millisecond never gets near the
limit, so a hidden buffer is not woken for it at all until the child exits.
Each is a /bin/sh -c script, which the hidden rows prefix with a read so the
buffer is off screen before the first line."
  (pcase-dolist (`(,label . ,script)
                 '(("yes flood, 2M lines" . "yes | head -n 2000000")
                   ("build, 1000 lines a ms apart" . "perl -e '$|=1; for (1..1000) { print \"make: line $_ of the build\\n\"; select(undef,undef,undef,0.001) }'")))
    (cooked-bench--session (concat label ", shown") (list "/bin/sh" "-c" script))
    (cooked-bench--session (concat label ", hidden") (list "/bin/sh" "-c" script) nil t)))

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
tells you whether the three tiers of box-glyph cache are earning their keep --
`cooked--deco-image-cache' in front of `cooked--box-glyph-cache', with
`cooked--box-glyph-cell-cache' under both.  Compare the two figures — the gap is
what box drawing costs over plain text."
  (cooked-bench--session
   "repaint, 400 frames of box drawing"
   '("/bin/sh" "-c" "printf '\\033[?1049h'; f=0; while [ $f -lt 400 ]; do \
r=1; while [ $r -le 24 ]; do printf '\\033[%s;1H' $r; \
printf '\\342\\224\\200%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; \
r=$((r+1)); done; f=$((f+1)); done; printf '\\033[?1049l'")))

(defun cooked-bench-bottom-row ()
  "A still screen whose bottom row is rewritten, over a real child.

What a status line, a spinner under a full-screen listing or `watch' with one
changing figure look like: twenty-three rows drawn once, then two thousand
rewrites of the last, with a 10 ms pause every fifty so that they arrive over
forty-odd wakeups rather than two.  The core compares each rewrite with the row Emacs holds
and sends that one row, so this is the live counterpart of the synthetic
`per-frame, 24x80 styled, one cell, as a row', paced by the real wake pipe.  A
drain that sends more than the bottom row shows here as time per drain rising
towards `repaint, 400 frames x 24 rows'."
  (cooked-bench--session
   "live, still screen, bottom row x2000"
   '("/bin/sh" "-c" "printf '\\033[?1049h\\033[H'; r=1; while [ $r -lt 24 ]; do \
printf 'row %s the quick brown fox jumps over the lazy dog\\r\\n' $r; r=$((r+1)); done; \
i=0; while [ $i -lt 2000 ]; do printf '\\033[999;1Hstatus %s' $i; \
[ $((i % 50)) -eq 0 ] && sleep 0.01; i=$((i+1)); done; \
printf '\\033[?1049l'")))

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
       (cooked-bench--drain-only-until-exit)))
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

(defun cooked-bench--row-count (rows)
  "How many *screen rows* ROWS covers.

Not `length\=': an entry is a run of contiguous damaged rows and its block\='s row
table is what says how many of them there are.  Every figure in this file that
is per row rather than per frame reads this, and the grid height does too --
`:height\=' taken as the entry count declared a one-row screen, which
`cooked--fit-screen\=' then trimmed the other twenty-three rows down to."
  (cl-loop for (_first . block) in rows sum (length (nth 3 block))))

(cl-defun cooked-bench--update (rows &key alt images shifts height edits)
  "An update plist of ROWS, shaped exactly as `cooked--drain' returns one.

`:height', `:used' and `:head' are not optional: `cooked--apply' builds a
`cooked-grid' from them and `cooked--fit-screen' does arithmetic on it, so a
plist without them fails on a nil rather than benchmarking anything.  They were
missing here from the moment the drain grew them, which is how
`cooked-bench-per-frame' came to error out instead of reporting.

HEIGHT defaults to the rows damaged, which is right for every fixture that
repaints the whole screen and wrong for the one that does not.  A scroll damages
*one* row of a twenty-four row screen, and a plist that let the default stand
would declare a one-row screen -- which `cooked--fit-screen' then obeys,
deleting the twenty-three rows the shift just moved and turning the case into an
expensive way of measuring a truncation.  `cooked-bench-scroll' passes it
through `cooked-bench--frames', and it is the whole reason this argument
exists.

IMAGES is the drain's `:images', the (ID FORMAT DATA PX-WIDTH PX-HEIGHT) records
`cooked--install-images' files before anything names an id.  Only the first
frame of a run needs it -- the module sends a picture once however often it is
placed -- so `cooked-bench--frames' installs it once, outside the timed loop,
and leaves this nil for the frames it times.

SHIFTS is the drain's `:shifts', a list of (TOP BOTTOM COUNT UP) moves that
`cooked--apply-shifts' replays as one deletion and one insertion each.  Keywords
rather than positional arguments from here on: four optional trailing values
whose meanings are unrelated is exactly the call site nobody can read.

EDITS is the drain\='s `:edits\=', rows of which only part is replaced; see
`cooked-bench--edit\='."
  ;; The renditions the fixtures name go into this buffer here, once, rather than on
  ;; the plist: an update is applied over and over inside the timed loops, and a
  ;; `:styles' installed each time would charge every frame for resolving its faces
  ;; afresh, which a real session pays once per rendition.
  (cooked--install-styles (cooked-bench--style-table))
  (let ((height (or height (cooked-bench--row-count rows))))
    (list :scrolled nil :rows rows :edits edits :shifts shifts :images images
          :height height :used height :head 0
          :cursor '(0 0 t block) :alt alt
          :app-cursor nil :keys 'legacy :mode 'raw :events nil :exit nil)))

(defun cooked-bench--edit (index char-start char-end length text)
  "One `:edits' entry replacing CHAR-START..CHAR-END of row INDEX with TEXT.

LENGTH is the row\='s length afterwards, as the core sends it.  TEXT is plain,
and its block\='s row table is TEXT\='s own, which for a uniform ASCII row is the
same answer the whole row\='s would be."
  (cons index
        (cons char-start
              (cons char-end
                    (cons length
                          (cdar (cooked-bench--run (list (list text nil nil t)) index)))))))

(defun cooked-bench--run (rows &optional first)
  "ROWS, each a description of one screen row, as the single run the module sends.

The fixtures here hand `cooked--apply\=' what a full-screen repaint actually
produces, and since the core coalesces contiguous damaged rows that is *one*
entry -- `(0 . BLOCK)\=' -- whose block holds every row, joined by newlines, with
a row table saying where each of them begins.  See `contiguous_runs\=' in
src/wire.rs, and `cooked--render-block\=' for the block's shape.  A fixture still
sending a block per row would measure a path the module no longer takes.

Each element of ROWS is (TEXT SPANS DECOS UNIFORM): the row's characters, its
style spans as (START END FG BG UNDERLINE ATTRS) with offsets *within the row* and
colours in the tagged encoding `cooked-bench--color-spec\=' reads,
its (START DECO) decoration spans likewise, and its answer to the guard's
uniformity question -- t, `glyph\=' or nil, as the core spells it.  The row
table's layout hash is the row text\='s `sxhash-equal\=': any fixnum that differs
where the text does is a key the memo can use, which is all the core\='s is.  Offsets are given per row and re-based here because that
is the only place that knows where a row landed in the assembled text, and
getting it wrong is a miscolouring rather than an error -- see
`cooked-bench-a-run-carries-every-row-the-guard-and-the-spans-need\='.

FIRST is the screen row the run begins at, defaulting to 0 because every
fixture that repaints a whole screen begins there.  A scroll does not: the row
a line feed recycles is the *last* one, so `cooked-bench--scrolled-row\=' asks
for 23.  The index is what `cooked--render-rows\=' seeks to, so a run at the
wrong one would rewrite the top of the screen and leave the recycled row
holding the text that scrolled away."
  (let ((text nil)
        (styles nil)
        (decos nil)
        (table nil)
        (offset 0))
    (dolist (row rows)
      (pcase-let ((`(,row-text ,spans ,row-decos ,uniform) row))
        (when text
          ;; Between the rows and not after the last one, exactly as
          ;; `Block::push_newline\=' places it: a damaged row is written into a
          ;; line that already exists.
          (push "\n" text)
          (setq offset (1+ offset)))
        (push (list offset (string-width row-text) uniform nil (sxhash-equal row-text))
              table)
        (pcase-dolist (`(,from ,to ,fg ,bg ,ul ,attrs) spans)
          (setq styles (append styles (cooked-bench--style-record
                                       (+ offset from) (+ offset to)
                                       (cooked-bench--style-id fg bg ul attrs)
                                       0))))
        (pcase-dolist (`(,from ,deco) row-decos)
          (push (list (+ offset from) deco) decos))
        (push row-text text)
        (setq offset (+ offset (length row-text)))))
    (list (cons (or first 0)
                (list (apply #'concat (nreverse text))
                      (and styles (apply #'unibyte-string styles))
                      (nreverse decos)
                      (nreverse table))))))

(defun cooked-bench--plain-rows (count cols)
  "COUNT damaged rows of unstyled text, the cheapest thing to render.

Unstyled text carries no span list at all, which is the case the sparse shape is
built around, and UNIFORM is t because every character is one ASCII byte
standing on one cell."
  (let ((text (make-string cols ?x)))
    (cooked-bench--run (cl-loop repeat count collect (list text nil nil t)))))

(defun cooked-bench--le (value bytes)
  "VALUE as BYTES little-endian bytes, as a list."
  (cl-loop for b below bytes collect (logand (ash value (* -8 b)) 255)))

(defun cooked-bench--style-record (start end id link)
  "One packed style span, as `Block::push_style\=' in src/wire.rs lays it out.

START and END are character offsets, ID the rendition\='s id and LINK the link\='s,
0 for none.  Hand-built here because the point of these fixtures is to hand
`cooked--apply\=' exactly what the module would, without a child having to
produce it -- so the layout is spelled out on this side too, and
`cooked--style-record\=' is the number that has to agree."
  (append (cooked-bench--le start 4) (cooked-bench--le end 4)
          (cooked-bench--le id 4) (cooked-bench--le link 4)))

(defvar cooked-bench--styles (make-hash-table :test #'equal)
  "Every rendition a fixture has named, as (FG BG UL ATTRS) to its id.

Shared by every fixture, the way a session\='s store is shared by every row, and
numbered from 1 because 0 is the default rendition in the core too.")

(defun cooked-bench--color-spec (packed)
  "PACKED, a colour tagged in its top byte, in `cooked--color\=''s spelling.
Tag 0 is the default, 1 a palette index in the low byte, 2 a direct colour."
  (pcase (ash packed -24)
    (0 nil)
    (1 (logand packed 255))
    (_ (list (logand (ash packed -16) 255) (logand (ash packed -8) 255)
             (logand packed 255)))))

(defun cooked-bench--style-id (fg bg ul attrs)
  "The id of the rendition with tagged colours FG, BG and UL, and ATTRS."
  (cooked-bench--spec-id (list (cooked-bench--color-spec fg)
                               (cooked-bench--color-spec bg)
                               (cooked-bench--color-spec ul)
                               attrs)))

(defun cooked-bench--spec-id (spec)
  "The id of SPEC, a rendition as (FG BG UL ATTRS) in `cooked--color\=''s spelling."
  (or (gethash spec cooked-bench--styles)
      (puthash spec (1+ (hash-table-count cooked-bench--styles))
               cooked-bench--styles)))

(defun cooked-bench--adopt-styles (rows specs)
  "ROWS, a drain\='s `:rows\=' from another session, renumbered into the fixtures\=' ids.

The session that produced ROWS numbered its renditions in its own buffer, as
SPECS, and the buffer a benchmark applies them in knows only the fixtures\=' table.
Each record\='s id is rewritten to the id the same rendition has there, so the
captured rows resolve to the colours they were drawn in."
  (dolist (entry rows rows)
    (when-let* ((styles (nth 2 entry)))
      (let ((i 0))
        (while (< i (length styles))
          (let* ((at (+ i cooked--style-id))
                 (theirs (cooked--u32 styles at))
                 (ours (if (zerop theirs)
                           0
                         (cooked-bench--spec-id (aref specs theirs)))))
            (dotimes (b 4)
              (aset styles (+ at b) (logand (ash ours (* -8 b)) 255))))
          (setq i (+ i cooked--style-record)))))))

(defun cooked-bench--style-table ()
  "Every rendition named so far, as a drain\='s `:styles\=' spells them."
  (let (table)
    (maphash (lambda (spec id)
               (pcase-let ((`(,fg ,bg ,ul ,attrs) spec))
                 (push (list id fg bg ul attrs) table)))
             cooked-bench--styles)
    table))

(defun cooked-bench--styled-rows (count cols)
  "COUNT damaged rows split into eight differently-styled spans.

The spans arrive packed, not as lists -- see `cooked-bench--style-record\='.  An
indexed foreground and a default background, which is what a shell or a build
log actually emits and so the case the encoding is tuned for.  The colour is
rotated by row so that a screenful is not eight faces looked up once and cached
for the rest of the frame."
  (let ((width (/ cols 8)))
    (cooked-bench--run
     (cl-loop for i below count
              collect (list (make-string (* 8 width) ?x)
                            (cl-loop for r below 8
                                     collect (list (* r width) (* (1+ r) width)
                                                   (logior (ash 1 24) (mod (+ i r) 8))
                                                   0 0
                                                   (if (cl-evenp r) 1 0)))
                            nil t)))))

(defun cooked-bench--url-rows (count cols)
  "COUNT damaged rows each carrying a URL, which is what the goto-addr scan costs.

Plain text otherwise, so the gap against `cooked-bench--plain-rows\=' is the whole
of what `cooked--fontify-links\=' spends on a row that has something to find."
  (let* ((url "curl https://example.com/some/long/path ")
         (text (truncate-string-to-width (concat url (make-string cols ?x)) cols)))
    (cooked-bench--run (cl-loop repeat count collect (list text nil nil t)))))

(defun cooked-bench--box-rows (count cols)
  "COUNT damaged rows of box drawing, every cell taking the bitmap path.

The decoration is `(glyph . PACKED)\=' as the module hands it over: four
little-endian bytes per run of one shape, the `BoxGlyph\=' bits and the number of
characters drawing them.  0x0050 is a plain light horizontal -- left and right
edges at weight 1 -- which is what a border is made of, and a row of them is the
single record the encoding exists to produce."
  (let ((text (make-string cols ?─))
        (deco (cons 'glyph (unibyte-string #x50 #x00
                                           (logand cols #xff) (ash cols -8)))))
    ;; UNIFORM is `glyph', which is what the core sends for a row whose only
    ;; multi-byte characters sit in box-glyph runs.  The guard then skips the
    ;; row exactly when the bitmaps are drawn, which this fixture arranges, so
    ;; claiming t or nil here would measure a path production does not take.
    (cooked-bench--run
     (cl-loop repeat count collect (list text nil (list (list 0 deco)) 'glyph)))))


(defconst cooked-bench--tree-continuing
  (concat (string #x2502) (string #xa0) (string #xa0) " ")
  "One level of `tree\='s indent while that level has more entries below.

A vertical, two NO-BREAK SPACEs and an ordinary space, which is what
`tree -C\=' writes byte for byte.  Spelled with character codes because the
NO-BREAK SPACEs are invisible in a source file, and they are the reason a row of
this is multi-byte in places the box glyphs alone would not be.")

(defconst cooked-bench--tree-finished "    "
  "One level of `tree\='s indent once that level has no entries left below it.")

(defun cooked-bench--tree-entries (depth)
  "The entries of a directory at DEPTH in the synthetic listing, sorted by name.

Each entry is (NAME KIND . CHILDREN), where KIND is `dir\=', `exec\=',
`link\=' or `file\=', so that every colour `tree -C\=' uses turns up on
screen.  A directory at depth six holds only files, which keeps the listing
finite and puts the deepest rows six verticals in."
  (if (>= depth 6)
      (list (list (format "leaf-%d-a.h" depth) 'file)
            (list (format "leaf-%d-b.h" depth) 'file))
    (list (cons (format "dir-%d" depth)
                (cons 'dir (cooked-bench--tree-entries (1+ depth))))
          (list (format "header-%d.h" depth) 'file)
          (list (format "link-%d" depth) 'link)
          (list (format "script-%d" depth) 'exec))))

(defun cooked-bench--tree-lines ()
  "The synthetic directory as `tree -C\=' prints it, one string per line.

Colours are `tree\='s own: bold blue for a directory, bold cyan for a symlink
followed by its target, bold green for an executable, and `00\=' for a plain
file, each closed with `ESC [ 0 m\='."
  (let ((lines (list "\e[01;34m.\e[0m")))
    (cl-labels
        ((walk (entries prefix)
           (while entries
             (pcase-let* ((`(,name ,kind . ,children) (car entries))
                          (last (null (cdr entries)))
                          (branch (concat (string (if last #x2514 #x251c))
                                          (string #x2500 #x2500) " "))
                          (label (pcase kind
                                   ('dir (format "\e[01;34m%s\e[0m" name))
                                   ('exec (format "\e[01;32m%s\e[0m" name))
                                   ('link
                                    (format (concat "\e[01;36m%s\e[0m"
                                                    " -> \e[00mheader.h\e[0m")
                                            name))
                                   (_ (format "\e[00m%s\e[0m" name)))))
               (push (concat prefix branch label) lines)
               (when children
                 (walk children
                       (concat prefix (if last
                                          cooked-bench--tree-finished
                                        cooked-bench--tree-continuing)))))
             (setq entries (cdr entries)))))
      (walk (list (cons "include" (cons 'dir (cooked-bench--tree-entries 1)))
                  (cons "share" (cons 'dir (cooked-bench--tree-entries 1))))
            ""))
    (nreverse lines)))

(defun cooked-bench--core-rows (lines rows cols)
  "The damaged-row runs the core sends for LINES on a ROWS by COLS screen.

The text goes through the real emulator rather than being described by hand, so
the runs, the absorbed blanks, the decoration records and the row table's
uniformity flag are whatever production would send.  A hand-written `tree\=' row
got that wrong once: it left the NO-BREAK SPACEs outside every glyph run, so its
rows took the width guard\='s slow path, which real `tree\=' output never does.

A child prints the first ROWS lines on the alternate screen and then sleeps, so
nothing moves while the grid is read.  Once the last line has arrived the screen
is marked damaged and drained once, which hands back every row as one run.  This
happens before any timing starts; the timed loop only ever applies the result."
  (let ((file (make-temp-file "cooked-bench-tree-"))
        (buffer (generate-new-buffer "*cooked-bench-capture*"))
        (shown (seq-take lines rows)))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'utf-8-unix))
            (with-temp-file file
              (insert "\e[?1049h\e[H" (string-join shown "\r\n"))))
          (with-current-buffer buffer
            (cooked-mode)
            (cooked--start (list "/bin/sh" "-c"
                                 (format "read _; cat %s; exec sleep 300"
                                         (shell-quote-argument file))))
            (cooked--refresh-keymap)
            (setq cooked--rows rows cooked--cols cols
                  cooked--last-size (cons rows cols))
            (cooked--resize cooked--session rows cols)
            (cooked--send cooked--session "\n")
            (let ((deadline (+ (float-time) 10))
                  (tail (replace-regexp-in-string "\e\\[[0-9;]*m\\|\e\\][^\a]*\a" ""
                                                  (car (last shown)))))
              (while (and (< (float-time) deadline)
                          (not (string-search tail (buffer-string))))
                (accept-process-output nil 0.02)
                (cooked--apply (cooked--drain cooked--session
                                              cooked-rejoin-wrapped-lines)))
              (unless (string-search tail (buffer-string))
                (error "cooked-bench: the listing never reached the screen")))
            (cooked--redraw cooked--session)
            (let ((update (cooked--drain cooked--session cooked-rejoin-wrapped-lines)))
              (cooked--install-styles (plist-get update :styles))
              (cooked-bench--adopt-styles (plist-get update :rows)
                                          cooked--style-specs))))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer)
      (delete-file file))))

(defun cooked-bench--tree-rows (count cols)
  "COUNT rows of a `tree -C\=' listing, COLS wide, as the core sends them.

Box drawing, but not the border kind.  `cooked-bench--box-rows\=' is one
decoration record covering the whole row, and so is a `tree\=' row now: the
core absorbs the blanks between its verticals into one glyph run, so `│ │ ├──\='
is a single record however deep the entry.  What depth still changes is how
wide that record is, which sets the bitmap drawn for it, and the coloured name
beside it adds style spans.  Before the blanks were absorbed, `tree -C
/usr/include\=' sent 86,107 records over its 30,326 rows.

The listing mixes depths one to six, continuing and finished levels, and every
colour `tree\=' emits, so a frame is not one row cached twenty-four times."
  (cooked-bench--core-rows (cooked-bench--tree-lines) count cols))

(defun cooked-bench--linked-rows (count cols)
  "COUNT rows in which every cell is a link drawn with a coloured underline.

What an editor listing search results or diagnostics draws: each row a link to
its location, underlined in a colour of its own.  The rows come from the core,
as `cooked-bench--tree-rows\=' does, so the records carry the links the way
production sends them."
  (cooked-bench--core-rows
   (cl-loop for row from 1 to count
            collect (format "\e]8;;file:///src/file%03d.rs#%d\a\e[4;58;5;%dm%s\e[0m\e]8;;\a"
                            row row (1+ (% row 8))
                            (truncate-string-to-width
                             (concat (format "src/file%03d.rs:%d: " row row)
                                     (make-string cols ?x))
                             (1- cols))))
   count cols))

(defun cooked-bench--deco-records (rows)
  "How many decoration records ROWS carries.

The deterministic half of the `tree\=' case, and a count rather than a time for
the reason `cooked-bench--property-intervals\=' is one: it is exact, it is the
same on a busy machine as on a quiet one, and it is the quantity the cost is
proportional to.  Anything asked once per record -- which until this fixture
existed included `cooked--layout-window\=' twice over and `cooked--cell-size\='
once -- is paid this many times per frame."
  (cl-loop for (_first . block) in rows sum (length (nth 2 block))))

(defun cooked-bench--scrolled-row (index cols)
  "The one damaged row an ordinary scroll leaves, at screen row INDEX, COLS wide.

A line feed at the foot of a full screen moves twenty-three rows up by one and
recycles the twenty-fourth, and since 25365a1 that is what the module reports:
a `Shift' saying the text moved, and damage on the single row that genuinely
holds something new.  Everything else about the frame is plain text, so read
this against `cooked-bench--plain-rows' at the same width -- the difference
between the two is entirely the *shape* of the report, which is what the
change was."
  (cooked-bench--run (list (list (make-string cols ?x) nil nil t)) index))

;; A picture, and the scroll that moves one.  Both were added after the changes
;; they measure had already landed, and both were added because the changes
;; could not be measured: cooked-bench.el was box drawing and plain text, so a
;; run-wide `display' slice and a scroll expressed as a scroll were each
;; reported flat by a suite with no fixture that reached them.  A benchmark that
;; cannot see a fortyfold reduction is not a neutral benchmark, it is a wrong one.

(defconst cooked-bench--png
  (base64-decode-string
   (concat "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAAEUlEQVR4nGNkYGD4"
           "DwABBAEAcCBlBQRbYf8AAAAASUVORK5CYII="))
  "A one-pixel PNG, so the fixture needs no file on disk.

Valid rather than plausible, because `cooked--image-spec\=' hands it to
`create-image\=' and a spec built over bytes Emacs would refuse is not the spec
production builds.  One pixel because nothing here rasterizes -- batch has no
glyph matrix -- so the decode cost is not what these rows are about, and a
larger picture would only make the fixture slower to load.

Byte for byte the PNG `cooked-tests--png\=' assembles from chunks and CRCs in
tests/cooked-tests-render.el, and kept as a literal here instead: that file
builds it because its tests are partly *about* the format, and this one only
needs something Emacs will accept.")

(defun cooked-bench--image-cell (id crow ccol cols rows)
  "The twelve bytes `cooked--apply-image-deco\=' reads for one image cell.

A `u32\=' ID, then the cell\='s row CROW and column CCOL *within the picture*,
then the cell rectangle COLS by ROWS the placement was laid at, all
little-endian.
See `Deco::packed\=' in src/emu/cell.rs for the encoder, and
`cooked--apply-image-deco\=' for the walk that coalesces these back into runs."
  (append (cooked-bench--le id 4)
          (cooked-bench--le crow 2) (cooked-bench--le ccol 2)
          (cooked-bench--le cols 2) (cooked-bench--le rows 2)))

(defun cooked-bench--image-rows (count cols)
  "COUNT damaged rows holding one COUNT-row picture, COLS cells wide.

The workload the run-wide `display\=' slice was built for and the one nothing
here could measure before: a full-screen picture, redrawn every frame, which is
what
`icat\=', an image browser paging a directory, or a plotting TUI actually does.

Per cell on the wire and per run in the buffer, and the fixture has to be
per-cell or it measures the wrong side of that split.  The module addresses a
picture one cell at a time -- that is what makes it survive an overwrite, a
scroll and a rewrap -- and `cooked--apply-image-deco\=' coalesces the records
back into a maximal run of cells agreeing on the picture, the rectangle, the row
within it and the next column along.  Emitting one record per row here would
hand the renderer the answer and time the arithmetic that is left.

So CCOL rises by one across each row and CROW is the screen row\='s own index,
which is the shape a freshly drawn picture has and therefore coalesces to
exactly one `display\=' property and one `cooked-deco\=' per row -- 47 intervals
over a 24x80 frame against the 1943 the per-cell code left, which is the figure
this fixture exists to put a time against.  (One fewer than 94b43e6\='s 48 and
1944, and the difference is the trailing newline: the last of these rows ends
the buffer, so `cooked-bench--property-intervals\=' has 23 separators to walk and
not 24.  Same measurement, one boundary apart.)

The text is spaces because an image cell *is* a blank in the default style: see
`Cell::is_content\=' in src/emu/cell.rs, where the placement is what keeps such
a row from measuring as empty and being trimmed off the end.  UNIFORM is
therefore t, honestly and not by convenience -- a space is one byte on one cell
-- and the guard finishes this row at step 1 as it does a plain one.  What separates this
fixture from `cooked-bench--plain-rows\=' is the decoration and nothing else,
which is what makes the gap between the two readable as the picture\='s cost."
  (cooked-bench--run
   (cl-loop
    for row below count
    collect (list (make-string cols ?\s)
                  nil
                  (list (list 0 (cons 'image
                                      (apply #'unibyte-string
                                             (cl-loop for col below cols
                                                      append (cooked-bench--image-cell
                                                              1 row col cols count))))))
                  t))))

(defun cooked-bench--image-resources (count cols)
  "The `:images\=' records for the placement `cooked-bench--image-rows\=' makes.

COUNT rows by COLS columns, the same rectangle those rows claim.

One entry, because ids are content-addressed and the module sends a picture
exactly once however often the child places it.  The pixel dimensions are the
rectangle at the cell size the bench pins, which is what `cooked--image-spec\='
would have been given had a real child transmitted it."
  (list (list 1 'png cooked-bench--png
              (* cols (car cooked-bench--cell))
              (* count (cdr cooked-bench--cell)))))

(cl-defun cooked-bench--frames (label rows &optional frames &key images height shifts edits prime)
  "Apply ROWS as a damaged-row update, one frame per iteration.

The unit is one `cooked--apply' rather than a batch of them, which the earlier
shape could not offer: a batch total divided by its count hides whether the
frames all cost the same.  It is safe to iterate here because they do -- the
alternate screen rewrites its rows in place, so the buffer does not grow and
the thousandth frame costs what the first did.  That was checked before the
loop was allowed to auto-scale, not assumed.

FRAMES is the floor, defaulting to the 200 the earlier batches used, so a
declared count is never lower than what the recorded numbers were taken at.

IMAGES is installed once, before the loop and outside it, and deliberately does
not ride the timed update.  `cooked--install-images' is the drain's resource
pass and the module sends a picture once however many frames place it, so
charging every frame for a `puthash' and an eviction sweep would measure the
protocol wrongly -- it would put the picture's cost somewhere it is not.  What
the timed frames then measure is the placement alone, which is where the
interval tree is written and where the run-wide slice does its work.

HEIGHT and SHIFTS go straight to `cooked-bench--update'; see there.  A case
passing SHIFTS is also primed with one untimed apply first, because
`cooked--apply-shift' deletes and reopens rows *by index* and the child here has
left the buffer one line long: the first shift would be asked to move rows that
do not exist yet.  One apply is enough, `cooked--fit-screen' growing the screen
to HEIGHT, and every timed frame then starts from a full screen -- which is the
state a scroll actually arrives in.  The priming is conditional rather than
unconditional so that the cases recorded before it existed are still being run
exactly as they were."
  (cooked-bench--with-session '("/bin/sh" "-c" "sleep 300")
    (cooked-tests--settle-briefly)
    (when images (cooked--install-images images))
    (when prime
      (cooked--apply (cooked-bench--update prime :alt t :height height)))
    (let ((update (cooked-bench--update rows :alt t :height height :shifts shifts
                                        :edits edits)))
      (when shifts (cooked--apply update))
      (cooked-bench--measure label 1
                             (lambda () (cooked--apply update))
                             (or frames 200))
      (message "  %-40s   %d rows/frame" "" (cooked-bench--row-count rows)))))

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
  ;; A repaint in which only three rows ended up different: what the core sends for
  ;; `watch' or htop once it compares each erased-and-rewritten row with what the
  ;; buffer holds.  Read it against the full 24-row styled frame above, which is what
  ;; the same repaint cost when every damaged row was sent.
  (cooked-bench--frames "per-frame, 24x80 styled, 3 rows changed"
                        (cooked-bench--styled-rows 3 80) 200 :height 24)
  ;; One cell of a styled screen changing, as a spinner does: first as the whole row
  ;; the core used to send, then as the one-character edit it sends now.
  (cooked-bench--frames "per-frame, 24x80 styled, one cell, as a row"
                        (cooked-bench--styled-rows 1 80) 200
                        :height 24 :prime (cooked-bench--styled-rows 24 80))
  (cooked-bench--frames "per-frame, 24x80 styled, one cell, as an edit"
                        nil 200 :height 24 :prime (cooked-bench--styled-rows 24 80)
                        :edits (list (cooked-bench--edit 0 8 9 80 "x")))
  ;; And a progress bar's last ten cells, the other shape an edit is for.
  (cooked-bench--frames "per-frame, 24x80 styled, bar tail, as an edit"
                        nil 200 :height 24 :prime (cooked-bench--styled-rows 24 80)
                        :edits (list (cooked-bench--edit 0 70 nil 80 "##########")))
  ;; There was a URL-per-row frame after this one, on the alternate screen.
  ;; The scan runs from jit-lock and not from the render, batch never
  ;; redisplays, and the alternate screen is never scanned, so the row scanned
  ;; no URLs at all.  `cooked-bench-links' times the scan itself.
  (cooked-bench--frames "per-frame, 24x80 every cell linked and underlined"
                        (cooked-bench--linked-rows 24 80) 200))

;;;; The three shapes the suite could not see
;;
;; All three were added after the change they measure had already landed, and in
;; every case the reason is the same: the fixtures were box drawing and plain
;; text, so a change to the image path, a change to the shape of a scroll report
;; and a cost paid per decoration record were each invisible here -- flat by
;; construction, which reads as non-regression and is not evidence of anything.
;; The third is the one that reached a user before it reached this file.  A
;; benchmark's coverage is
;; part of what it claims, and a suite that cannot reach a path should not be
;; read as saying that path is unmoved.

(defun cooked-bench--property-intervals (property)
  "How many runs of PROPERTY the current buffer holds.

The deterministic half of the image case, and the figure 94b43e6 was measured
on: what Emacs' redisplay walks is the interval tree, so a frame of picture is
`find_interval' and `parse_image_spec' once per interval whether or not any
pixels change.  A count rather than a time because it is exact -- the same
number on a busy machine as on a quiet one -- and because it is the quantity
the change was about, the milliseconds being a consequence of it.

Counted with `next-single-property-change' rather than by asking the interval
tree directly: it is what a redisplay walk does, and it merges neighbouring
intervals that happen to agree, which is exactly the merge the run-wide slice is
asking Emacs for and would be wrong to count twice."
  (save-restriction
    (widen)
    (let ((pos (point-min))
          (runs 0))
      (while (< pos (point-max))
        (setq pos (or (next-single-property-change pos property) (point-max))
              runs (1+ runs)))
      runs)))

(defun cooked-bench-image ()
  "A full-screen picture, redrawn every frame: what `icat' and a plotting TUI do.

The case 94b43e6 needed and did not have.  It moved a placement's `display' and
`cooked-deco' properties from one per cell to one per run, and `make bench'
reported the change as flat because nothing here placed an image at all.  With
this row, reverting that one commit's cooked-deco.el hunk and rerunning says:

  display intervals over the frame  1943 -> 47
  cooked-deco intervals             1943 -> 47
  per-frame p50, three runs a side  5.98-7.15 ms -> 2.28-2.42 ms
  collections per 200 frames        64 -> 20

Two figures, and the interval count is the headline.  It is deterministic, it is
the quantity the change was about, and it is the one that can be compared across
machines and across a year of commits; the time is what that costs on this
machine today.  Read the time against `per-frame, 24x80 plain' rather than in
isolation -- the fixture is plain spaces plus a placement, so the gap between
the two rows is the picture and nothing else."
  (let ((rows (cooked-bench--image-rows 24 80)))
    (cooked-bench--frames "per-frame, 24x80 image" rows 200
                          :images (cooked-bench--image-resources 24 80))
    ;; Counted in a session of its own rather than at the end of the timed one:
    ;; the loop above leaves whatever the last frame wrote, and a count taken
    ;; there would be reporting the state a benchmark happened to stop in.
    (cooked-bench--with-session '("/bin/sh" "-c" "sleep 300")
      (cooked-tests--settle-briefly)
      (cooked--install-images (cooked-bench--image-resources 24 80))
      (cooked--apply (cooked-bench--update rows :alt t))
      (message "  %-40s   %d display intervals, %d cooked-deco" ""
               (cooked-bench--property-intervals 'display)
               (cooked-bench--property-intervals 'cooked-deco)))))

(defun cooked-bench-scroll ()
  "One line of ordinary scrolling, reported both ways.

The pair 25365a1 needed and did not have.  Before it, a line feed at the foot of
a full screen was twenty-four damaged rows -- true, since after a `rotate_left'
every index does hold different text, but silent about the text having *moved*.
After it the same operation is one `Shift' and one damaged row, and
`cooked--apply-shifts' turns the shift into a single deletion and insertion that
the surviving rows' markers, overlays and fontification ride through.

  damaged rows per frame            24 -> 1
  per-frame p50, three runs a side  0.098-0.102 ms -> 0.039-0.041 ms

No collection figure in that table, unlike the image row's: the two arms run to
a wall clock rather than to a frame count, so the faster one fits twice as many
frames into the same half second and its collection count is not comparable
with the other's.  The row count is the deterministic half and it is printed beside each row by
`cooked-bench--frames' already, which is what makes this pair readable without
trusting a clock at all.

Both rows are run here, on one build, and that is the honest comparison rather
than a shortcut around one: the change split across Rust and Lisp, but the Lisp
half is purely additive -- `cooked--apply-shifts' did not exist and now does --
so the whole of what Emacs saved is the difference between the two plists the
module can send for the same event.  Feeding it both says exactly that, and says
it without a second build to be wrong about.

What the difference does *not* include is the half that motivated the change:
markers surviving.  That is not a time, it is a fact about the buffer, and
tests/cooked-tests-render.el pins it."
  (cooked-bench--frames "scroll one line, as 24 damaged rows (before)"
                        (cooked-bench--plain-rows 24 80) 200)
  (cooked-bench--frames "scroll one line, as a shift (after)"
                        (cooked-bench--scrolled-row 23 80) 200
                        :height 24 :shifts '((0 23 1 t)))
  ;; A scroll region, which is the case cooked was already narrower than ghostel
  ;; on and must not regress: six rows move, one is recycled, and the eighteen
  ;; rows outside the region are not touched at all.
  (cooked-bench--frames "scroll region 5..10, as a shift"
                        (cooked-bench--scrolled-row 9 80) 200
                        :height 24 :shifts '((4 9 1 t))))

(defun cooked-bench-tree ()
  "`tree\=' in a large directory: an indent of box glyphs beside a name on every row.

The third shape this file could not see, filed with the other two because the
lesson is the same one for the third time.  A user reported `tree\=' in a large
directory as extremely slow and it could not be reproduced from here, because
every box-drawing figure in this file was taken on `cooked-bench--box-rows\=' --
a border, which is one decoration record covering the whole row.  That is the
shape the packed encoding is best at, and it hid a cost that is paid *per
record* completely.

What the profile said, on `tree -C /usr/include\=' in a pgtk frame under
gamescope: `cooked--deco-cell-size\=' was 80% of the session, because
`cooked--apply-deco\=' asked it, and `cooked--layout-window\=' twice, once for
every one of 86,107 records.  `window-font-width\=' costs 20.8us on pgtk and
`window-default-line-height\=' 8.9us, against `frame-char-width\=''s 0.085us, so
the same window answered the same question 86,107 times for 2.56s of a 3.10s
run.  Hoisting both to once per `cooked--apply\=' -- see `cooked--deco-pass\=' --
took the session to 311ms.

  wall for `tree -C /usr/include', 100x32 pgtk   3105 ms -> 311 ms
  `cooked--layout-window' calls per session    172,224 -> 17
  the same in `emacs --batch' on a tty frame      330 ms -> 210 ms

Both arms byte-compiled, three sessions each, medians, load average 1.6-2.3;
the graphical pair was re-run and agreed to 3%.

The batch figure is the same change measured where `window-font-width\=' is
cheap, and it is here to say what the graphical one is *not*: on a terminal
frame only the redundant walks and the consing are saved, and 1.6x is what that
alone is worth.  The other 2.5s was pgtk being asked about its font.

Both arms of the pair are run here on one build, as `cooked-bench-scroll\=' does
and for the same reason -- read the row against `per-frame, 24x80 box drawing\='
at the same width, and the gap between the two is entirely the record count.
The count itself is printed beside the row, which is the half that needs no
clock.

The rows come from the core rather than being described by hand, so they carry
what production does: the blanks between two glyph runs absorbed into the run,
one record per box-drawn row, and every such row flagged `glyph\='.  A 24x80
frame is 23 records and applies at about 0.12ms p50 with 915 conses.  The
hand-written rows it replaced left their padding unabsorbed, and so measured
108 records, 0.56ms and 3,079 conses on a width-guard path `tree\=' never
takes."
  (let ((rows (cooked-bench--tree-rows 24 80)))
    (cooked-bench--frames "per-frame, 24x80 tree listing" rows 200)
    (message "  %-40s   %d decoration records/frame" ""
             (cooked-bench--deco-records rows))))

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
    ;; The primary screen, because the alternate one is never scanned for URLs,
    ;; and what is under test is when the scan is paid rather than which screen
    ;; pays it.  See `cooked--fontify-region'.
    (let ((update (cooked-bench--update rows)))
      (cooked-bench--measure
       label ratio
       (lambda ()
         (dotimes (_ ratio) (cooked--apply update))
         (cooked-bench--fontify-as-redisplay
          (or (cooked--screen-start-position) (point-min)) (point-max)))
       (max 1 (/ frames ratio)))
      (message "  %-40s   %d rows/frame, 1 redisplay per %d frames"
               "" (cooked-bench--row-count rows) ratio))))

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

;;;; Link scans over settled scrollback
;;
;; The two passes that find links in text nobody marked up: the URL scan
;; `cooked--fontify-links' and the file-name scan `cooked-file-link-scan'.  Both
;; run from jit-lock, so a figure taken by calling `cooked--apply' measures
;; neither, and the alternate-screen URL row this file used to carry reported the
;; floor under that name.  These time what redisplay would run over a stretch of
;; scrollback, and print how many links the scan left behind, which is the proof
;; that it scanned.

(defconst cooked-bench--url-lines
  '("See https://example.com/docs/errors/E0042 for details"
    "Download: https://cdn.example.org/releases/v2.1.0/pkg.tar.gz"
    "More info: https://github.com/user/repo/issues/42"
    "nothing to find on this line but words and more words")
  "Lines of output carrying URLs, three in four, cycled to fill the scrollback.")

(defconst cooked-bench--path-lines
  '("src/session.rs:423:9: warning: unused variable"
    "  --> src/emu/screen.rs:422:5"
    "lisp/cooked-render.el:111: in cooked--drain-and-apply"
    "tests/delta_replay.rs:562 property failed"
    "pkg/server/handler.go:128:5: undefined: Foo"
    "ERROR in src/components/Button.tsx:17 TS2304: Cannot find name"
    "  File lib/python3/site.py, line 73, in main"
    "warning: unused variable at ./src/render.zig:156:13")
  "Build-log lines naming files, the first four of which exist in this tree.

Resolved against the top of the tree, so the four that exist are found in
`default-directory' and the four that do not cost the project-root retry as
well: a miss is the expensive answer, and a real build log holds plenty.
Paths relative to the tree rather than ghostel's /opt and /usr, which it chose
because a miss under /home goes through autofs on macOS; nothing here reads
an absolute path at all.")

(defun cooked-bench--count-property-runs (property from to)
  "How many runs between FROM and TO carry a non-nil PROPERTY."
  (save-restriction
    (widen)
    (let ((pos from)
          (runs 0))
      (while (< pos to)
        (let ((next (next-single-property-change pos property nil to)))
          (when (get-text-property pos property)
            (setq runs (1+ runs)))
          (setq pos next)))
      runs)))

(defun cooked-bench--scan-scrollback (label lines count property)
  "Time the link scans over COUNT settled LINES, and report PROPERTY's runs.

LINES are cycled to COUNT lines, printed by a child on the primary screen so
that all but a screenful settle into scrollback, and the child then sleeps.
One iteration marks the scrollback unfontified, untimed, and times
`jit-lock-fontify-now' over it, which runs `cooked--fontify-region' chunk by
chunk as redisplay would.  The scans in force are whatever the caller bound.

The detail line gives PROPERTY's run count after the last scan, which is what
makes the row evidence: a scan that found nothing, or never ran, prints 0."
  (let ((file (make-temp-file "cooked-bench-links-")))
    (unwind-protect
        (progn
          (with-temp-file file
            (dotimes (i count)
              (insert (nth (% i (length lines)) lines) "\r\n")))
          (cooked-bench--with-session
              (list "/bin/sh" "-c"
                    (format "stty -onlcr; cat %s; printf DONE; exec sleep 300"
                            (shell-quote-argument file)))
            (setq default-directory (file-name-as-directory (cooked--root)))
            (let ((deadline (+ (float-time) 10)))
              (while (and (< (float-time) deadline)
                          (not (save-excursion
                                 (goto-char (point-max))
                                 (search-backward "DONE" nil t))))
                (accept-process-output nil 0.02)))
            (let ((from (point-min))
                  (to (cooked--screen-start-position)))
              (cooked-bench--measure
               label (count-lines from to)
               (lambda ()
                 (with-silent-modifications
                   (put-text-property from to 'fontified nil))
                 (let ((t0 (float-time)))
                   (jit-lock-fontify-now from to)
                   (- (float-time) t0))))
              (message "  %-40s   %d lines of scrollback, %d runs carry `%s'"
                       "" (count-lines from to)
                       (cooked-bench--count-property-runs property from to) property))))
      (delete-file file))))

(defun cooked-bench-links ()
  "The URL scan and the file-name scan, each alone, over settled scrollback."
  (let ((cooked-link-scan-functions nil))
    (cooked-bench--scan-scrollback "URL scan, 200 lines of scrollback"
                                   cooked-bench--url-lines 224 'cooked-link-url))
  (require 'cooked-file-link)
  (let ((cooked-detect-links nil)
        (cooked-link-scan-functions (list #'cooked-file-link-scan)))
    (cooked-bench--scan-scrollback "file-link scan, 200 lines, half missing"
                                   cooked-bench--path-lines 224 'cooked-file-link)))

;;;; Allocation per frame, which is a count and not a time
;;
;; Every other case in this file is a clock, and a clock cannot answer the
;; question the residual p99 spikes raise.  Collection is what those spikes are
;; -- `cooked-bench--record' prints the count beside every row precisely so they
;; can be read that way -- and the only thing that removes a collection is not
;; allocating.  So this section counts allocation directly: `memory-use-counts'
;; is exact, identical on a busy machine and a quiet one, and comparable across
;; machines and across years, which is everything a timing is not.
;;
;; It is reported per *steady-state* frame.  The first frame of a fixture builds
;; the face cache, the glyph caches and the wrap memo, and charging a frame for
;; those would be charging a session's whole warm-up to every frame of it; three
;; frames are run and thrown away before the one that counts.
;;
;; What the counts said when this was written, and the reason the allocation
;; task closed rather than shipping something.  A styled 24x80 frame conses
;; 1,750 cells, and every one of them is accounted for:
;;
;;   53     the plain frame's floor -- the whole of the rest of a render
;;   384    two per style span, 192 spans
;;   1,300  six per interval, 215 intervals
;;   ~13    the other eleven phases of `cooked--apply' put together
;;
;; The middle two are one thing wearing two hats: *Emacs conses a fresh property
;; plist per property per interval*, in `add_text_properties', and there is no
;; Lisp API that hands it a shared one.  `set-text-properties' with a constant
;; plist was measured and conses identically -- 401 cells over 192 spans either
;; way -- because it copies.  So 96% of a styled frame's consing is the interval
;; machinery and not cooked's code, and the two levers over it are the number of
;; properties and the number of intervals.  The intervals are the colours the
;; child asked for.  The properties are `cooked--read-only-props', and one of its
;; three can be moved: putting `(read-only . t)' in a buffer-local
;; `text-property-default-nonsticky' instead of writing `rear-nonsticky' per
;; interval is behaviourally identical -- checked with `get-pos-property' at both
;; edges -- and takes the styled frame from 1,750 conses to 1,320.
;;
;; It was measured and not taken, which is the finding rather than a gap.  Three
;; runs a side of the styled per-frame case: p50 0.139-0.144 ms against
;; 0.138-0.141, ranges fully overlapping, and collections over ~3,000 frames 18,
;; 19, 23 against 17, 18, 18.  A quarter of the consing removed moves neither.
;; The arithmetic says why: 430 cells is 7 KB, `gc-cons-threshold' is 800 KB, and
;; a frame at 28 KB reaches it every thirtieth frame either way.  Removing a
;; collection means removing *all* the consing, and the majority of it belongs to
;; Emacs.  A global stickiness default is not worth a saving that measures as
;; nothing.
;;
;; Box drawing used to be the exception, and now allocates what a plain frame
;; does in strings: 703 conses, 55 vector cells, 31 string characters and 3
;; strings.  Nothing about box drawing needed more.  The core tells the guard a
;; row whose only multi-byte characters are box glyphs apart from one the font
;; draws, and a glyph drawn as cooked's own one-cell bitmap cannot be wider than
;; its cell, so such a row is not measured at all; a `tree' listing's rows are
;; this kind too, since the core absorbs their padding into the glyph runs.  Rows
;; that are measured -- CJK, emoji, font fallback -- key the wrap memo on a layout
;; hash the core sends rather than on a copy of the row, and the metrics memo on
;; the character rather than on a fresh string.  A hash is a safe key because only the negative is
;; memoized: a collision can leave a row soft-wrapped until it is rewritten, and
;; can never delete a character -- see `cooked--wrap-memo'.

(cl-defun cooked-bench--allocation (label rows &optional height &key edits prime fontify)
  "Print what one steady-state `cooked--apply' of ROWS allocates, under LABEL.

HEIGHT is the screen's, for a fixture whose rows do not fill it; see
`cooked-bench--update'.  EDITS are the update's `:edits', and PRIME rows applied
once beforehand, so that an edit has a screen to edit.

FONTIFY non-nil counts the fontification redisplay would run over the screen
after each apply, on the primary screen rather than the alternate one.  The URL
scan runs from jit-lock and batch never redisplays, so without it a row of URLs
allocates exactly what a plain row does: 2,492 conses both, interpreted, when
the URL row was last taken without it.  Return the number of `cooked-link-url'
runs the screen holds afterwards, which is the proof that a scan ran: 23 for
`cooked-bench--url-rows' of 24, whose cursor row the scan declines, and 0 for
every fixture without FONTIFY.

The fields are `memory-use-counts'\='s, whose order is easy to transpose and
worth naming: (CONSES FLOATS VECTOR-CELLS SYMBOLS STRING-CHARS INTERVALS
STRINGS).  Reading STRING-CHARS as STRINGS is a factor of a hundred on the box
row and was made once already while these numbers were being taken.

Not routed through `cooked-bench--measure', which is the whole point: there is
no distribution here to summarise and no machine to be quiet.  Two runs of this
on the same commit print the same numbers, and two runs across a commit that
allocates differently print different ones, which is the property a timing does
not have."
  (cooked-bench--with-session '("/bin/sh" "-c" "sleep 300")
    (cooked-tests--settle-briefly)
    (when prime
      (cooked--apply (cooked-bench--update prime :alt t :height height)))
    (let* ((update (cooked-bench--update rows :alt (not fontify) :height height
                                         :edits edits))
           (frame (lambda ()
                    (cooked--apply update)
                    (when fontify
                      (cooked-bench--fontify-as-redisplay
                       (or (cooked--screen-start-position) (point-min))
                       (point-max))))))
      ;; Three warm frames: the first builds the face cache, the glyph caches
      ;; and the wrap memo, and a fixture charged for those is reporting a
      ;; session's start-up once per frame.  Three rather than one because the
      ;; box path settles a frame later than the others.
      (dotimes (_ 3) (funcall frame))
      (garbage-collect)
      (let ((before (memory-use-counts)))
        (funcall frame)
        (let ((after (memory-use-counts)))
          (message "  %-40s conses %6d  vec-cells %5d  str-chars %6d  strings %4d  intervals %4d"
                   label
                   (- (nth 0 after) (nth 0 before))
                   (- (nth 2 after) (nth 2 before))
                   (- (nth 4 after) (nth 4 before))
                   (- (nth 6 after) (nth 6 before))
                   (- (nth 5 after) (nth 5 before)))))
      (cooked-bench--count-property-runs 'cooked-link-url (point-min) (point-max)))))

(defun cooked-bench-allocation ()
  "What each fixture allocates per frame, exactly.

Read the plain row as the floor and the others as what their content costs over
it.  See this section\='s commentary for where a styled frame\='s 1,750 conses
go and why the obvious quarter of them was measured and left alone."
  (cooked-bench--allocation "alloc, 24x80 plain" (cooked-bench--plain-rows 24 80))
  (cooked-bench--allocation "alloc, 24x80 styled (8 runs/row)"
                            (cooked-bench--styled-rows 24 80))
  (cooked-bench--allocation "alloc, 24x80 box drawing" (cooked-bench--box-rows 24 80))
  (cooked-bench--allocation "alloc, 24x80 styled, 3 rows changed"
                            (cooked-bench--styled-rows 3 80) 24)
  (cooked-bench--allocation "alloc, 24x80 styled, one cell, as a row"
                            (cooked-bench--styled-rows 1 80) 24
                            :prime (cooked-bench--styled-rows 24 80))
  (cooked-bench--allocation "alloc, 24x80 styled, one cell, as an edit"
                            nil 24 :prime (cooked-bench--styled-rows 24 80)
                            :edits (list (cooked-bench--edit 0 8 9 80 "x")))
  (cooked-bench--allocation "alloc, 24x80 every cell linked and underlined"
                            (cooked-bench--linked-rows 24 80))
  (cooked-bench--allocation "alloc, 24x80 with a URL per row, scanned"
                            (cooked-bench--url-rows 24 80) nil :fontify t))

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

(defconst cooked-bench-cases
  '(("marshalling" . cooked-bench-marshalling)
    ("flood" . cooked-bench-flood)
    ("styled" . cooked-bench-styled)
    ("hidden" . cooked-bench-hidden)
    ("repaint" . cooked-bench-repaint)
    ("box-drawing" . cooked-bench-box-drawing)
    ("bottom-row" . cooked-bench-bottom-row)
    ("per-frame" . cooked-bench-per-frame)
    ("image" . cooked-bench-image)
    ("scroll" . cooked-bench-scroll)
    ("tree" . cooked-bench-tree)
    ("links" . cooked-bench-links)
    ("deferred" . cooked-bench-deferred)
    ("rescale" . cooked-bench-rescale)
    ("allocation" . cooked-bench-allocation))
  "Every case `cooked-bench' runs, in order, as (NAME . FUNCTION).

NAME is what `cooked-bench-run-one' and `make bench CASE=NAME' accept, so that
a change aimed at one path can be measured on that path in seconds, and run
again under `perf record' without the rest of the suite in the profile.  The
allocation rows are last because they are the only rows that do not depend on
the machine, and so the ones worth quoting when the load line at the top has
scrolled away.")

(defun cooked-bench--header ()
  "Print the run's header and apply the load guard."
  (message "cooked: Emacs-side cost per workload (drain + apply only)")
  (message "per-iteration distribution; read the p50 -- see the Commentary")
  ;; Before anything is timed, and before the header is complete: the load is
  ;; part of the run's provenance, so it is printed whether or not it passes.
  (cooked-bench--check-load))

(defun cooked-bench ()
  "Run every benchmark in this file, in the order of `cooked-bench-cases'."
  (setq cooked-bench-results nil)
  (cooked-bench--header)
  (pcase-dolist (`(,_name . ,function) cooked-bench-cases)
    (message "")
    (funcall function))
  (cooked-bench--report))

(defun cooked-bench-run-one (name)
  "Run the one case of `cooked-bench-cases' called NAME.

For example `(cooked-bench-run-one \"tree\")', which is what `make bench
CASE=tree' evaluates.  An unknown NAME is an error that lists the names, and in
batch exits 1 with that sentence."
  (interactive (list (completing-read "Benchmark case: " cooked-bench-cases nil t)))
  (let ((function (cdr (assoc name cooked-bench-cases))))
    (unless function
      (let ((complaint (format "no case named %S; the cases are %s" name
                               (mapconcat #'car cooked-bench-cases ", "))))
        (if noninteractive
            (progn (message "cooked-bench: %s" complaint) (kill-emacs 1))
          (user-error "cooked-bench: %s" complaint))))
    (setq cooked-bench-results nil)
    (cooked-bench--header)
    (message "")
    (funcall function)
    (cooked-bench--report)))

(provide 'cooked-bench)
;;; cooked-bench.el ends here
