;;; cooked-process.el --- a pty under an ordinary process filter -*- lexical-binding: t; -*-

;;; Commentary:

;; The rest of cooked spends what it knows on a buffer somebody is looking at.
;; This file spends it on the buffers nobody looks at as terminals at all: the
;; ones `compile', `grep' and `async-shell-command' fill by hanging a filter on
;; a process and letting text pile up.  Those consumers do not want a terminal.
;; They want the thing a terminal would have given the child -- an `isatty' that
;; answers yes -- and then text they can parse, in the colours the child chose.
;;
;; So the session here is headless.  A grid exists, because it is the parser,
;; but it is never rendered: no keymap, no input region, no decorations, no
;; links, no `cooked-mode'.  What the consumer's filter receives is the text
;; that has *retired* from that grid, which is the whole idea:
;;
;;   $ printf 'Building [1] \rBuilding [2] \rBuilding [3] \n'
;;   Building [3]
;;
;; One line, already resolved, instead of three carriage returns for
;; `ansi-color' to fail to clean up.  A cursor-addressed progress meter costs
;; nothing at all, because the rows it rewrites in place never retire until it
;; is done with them -- and is shown from the grid instead, see the live tail
;; below.  And with `cooked-rejoin-wrapped-lines' on, a diagnostic
;; the child wrapped at COLUMNS arrives as one line, so a `compilation-mode'
;; regexp matches it -- which it cannot do today, the wrap having landed in the
;; middle of `error:'.
;;
;; ## What is resolved, and what is carried
;;
;; Resolving is not stripping, and the difference is the whole of what this file
;; hands over.  An escape sequence that *addressed* the grid -- a carriage
;; return, a cursor move, an erase -- has already had its effect and is spent by
;; the time a row retires.  An escape sequence that *coloured* it has not: the
;; rendition is still an attribute of the characters, and `cooked--drain' hands
;; it back beside them.  So the text arrives clean and the colours arrive with
;; it, as `face' and `font-lock-face' on the string the filter is called with;
;; `cooked-process-styled' is the switch and `cooked-process--text' the whole of
;; the mechanism.  What does not travel is the two things that would mean
;; nothing where they landed -- glyph decorations, which are a terminal's answer
;; to a screen column, and `OSC 8' links, whose ids resolve only in the session
;; that issued them.  Both reasons are in `cooked-process--text'.
;;
;; The consumer is not adapted to any of this.  `compilation-filter' is called
;; with a string, at `process-mark', exactly as it is now; `compilation-filter-start'
;; means what it meant.  The only difference is which string.
;;
;; ## The bar that can never retire
;;
;; Retirement is the wrong instrument for a progress bar, and no amount of grid
;; is going to fix it.  Cargo draws one by rewriting a single row with a
;; carriage return, and wipes that row with an erase before it prints a real log
;; line -- so at the instant the row scrolls it is blank.  That is the child
;; being careful, not the emulator losing anything: the bar's only home is the
;; live grid.
;;
;; So the live grid is where it is read from.  `cooked-process--refresh-tail'
;; hangs the rows still on it after the last retired line as an overlay's
;; `after-string', replaced on every drain and taken down at exit, at which
;; point those same rows retire properly as text.  An overlay rather than text
;; because everything that makes the consumer's buffer work depends on the text
;; being only what the child finished saying: `compilation-mode' parses it,
;; `next-error' points into it, `process-mark' advances through it.  A bar frame
;; is none of those things, and a bar frame that a diagnostic regexp could match
;; would be worse than no bar.  `cooked-process-live-tail' is the switch.
;;
;; ## The grid's height is the latency knob
;;
;; Retirement is what scrolling off the top of the grid means, so nothing
;; retires until the grid is full: a session eight rows tall hands the filter
;; its first line when the ninth arrives, and the last eight at exit.  That is
;; the trade this file has instead of a flush timer.  Tall grids give a
;; full-screen program room to redraw and make the consumer wait; short ones are
;; prompt and clip the redraw.  `cooked-process-rows' is the knob and eight is
;; the default, which covers every progress meter I have found (cargo uses two
;; lines, ninja one) while keeping the tail under a screenful.
;;
;; ## Two processes, and why the visible one is a fake
;;
;; `cooked--spawn' wants a pipe process to wake, and the consumer wants a
;; process object of its own to hang a filter and a sentinel on.  These cannot
;; be the same object: `compilation-start' calls `set-process-filter' on what we
;; return, and that would tear out the pump.  So the wake pipe stays private and
;; a second pipe process is what the consumer sees.  It never carries a byte.
;; `process-buffer', `process-mark', `set-process-filter' and
;; `set-process-sentinel' are real on it and are all the consumer uses; the pump
;; reads the filter back off it and calls it.
;;
;; The one thing that object cannot do is exit with the child's status, and
;; `compilation-sentinel' asks it to -- `(memq (process-status proc) '(exit
;; signal))' before it will hand anything to `compilation-handle-exit'.  So the
;; sentinel is called with those two accessors rebound, for that one call and
;; that one process.  It is a cute trick and the alternative was worse: calling
;; `compilation-handle-exit' ourselves would mean this file knowing the consumer
;; it is feeding, which is exactly what it is trying not to know.

;;; Code:

(require 'cl-lib)
(require 'cooked)

(declare-function cooked--spawn "ext:cooked-core")
(declare-function cooked--drain "ext:cooked-core")
(declare-function cooked--send "ext:cooked-core")
(declare-function cooked--resize "ext:cooked-core")
(declare-function cooked--redraw "ext:cooked-core")
(declare-function cooked--signal "ext:cooked-core")
(declare-function cooked--kill "ext:cooked-core")

(defgroup cooked-process nil
  "Pty-backed processes for commands that only want text."
  :group 'cooked)

(defcustom cooked-process-rows 8
  "Rows in the headless grid, which is how far behind the filter runs.

Nothing reaches the consumer until it scrolls off the top, so this is a
latency in lines -- and at the same time the window a child has to redraw
something in place before anyone sees the intermediate states.  Raise it for a
child with a tall status block; lower it to see output sooner."
  :type 'integer)

(defcustom cooked-process-columns 120
  "Columns to give the child, or nil to follow the buffer's window.

Fixed by default, and that is not laziness.  COLUMNS decides where the child
wraps, the wrap decides what `cooked-rejoin-wrapped-lines' rejoins, and a
buffer whose text depends on how wide a window happened to be when the build
ran is not reproducible.  Following the window is friendlier and is one
`setq' away."
  :type '(choice integer (const :tag "Follow the window" nil)))

(defcustom cooked-process-styled t
  "Whether the child's colours reach the consumer's buffer.

On, because the reason to give a build a pty is to be shown what it shows a
human, and half of that is colour: cargo's green `Compiling\=', rustc's red
`error\=', the bold path in a diagnostic.  The emulator has already parsed the
SGR that named them -- `cooked--drain\=' hands the styling back beside the text
-- so dropping it would be throwing away the more expensive half of the work.

Off is the older behaviour and still the right answer for a consumer that would
rather own the styling itself, or one whose faces are load-bearing in some way
`grep-mode\=' is not; see `cooked-process-excluded-modes\=' for the stronger
version of that exception."
  :type 'boolean)

(defcustom cooked-process-live-tail t
  "Whether the rows still on the grid are shown below the retired text.

A progress bar cannot arrive as retired text and never will.  Cargo draws one
by rewriting a single row with a carriage return, and wipes it with an erase
before every real log line -- so at the instant that row scrolls it is blank,
which is not a defect in the emulator but the child being careful.  The bar
only ever exists on the *live* grid.

So it is shown from there, as an overlay after the last retired line: not buffer
text, which is the whole point.  `compilation-mode\=' never parses it, no
`next-error\=' can land in it, `process-mark\=' does not move for it, and it is
replaced wholesale on every drain and gone at exit -- by which time the same
rows have retired properly, as text, through `cooked-process--residue\='.

Off gives the buffer that is only ever what the child finished saying."
  :type 'boolean)

(defconst cooked-process--rejoin t
  "Always rejoin wrapped lines, unlike `cooked-rejoin-wrapped-lines\='.

That option is about a transcript somebody reads, where breaking a wrapped line
back apart is a defensible taste.  Here it decides whether a regexp matches: a
diagnostic the child wrapped at COLUMNS has `error:\=' with a newline through it
until this rejoins it, and no consumer of this file wants that.  A constant
rather than an option, so the terminal\='s width cannot change what the buffer
says.")

(defvar-local cooked-process--session nil
  "Native session handle, in the hidden host buffer.")
(defvar-local cooked-process--wake nil
  "The private pipe `cooked--spawn' wakes.  Not the consumer's process.")
(defvar-local cooked-process--proc nil
  "The pipe process the consumer sees.")
(defvar-local cooked-process--columns nil
  "Columns the session was spawned at, needed by the flush at exit.")
(defvar-local cooked-process--reaped nil
  "Set once the exit path has run, so it can run only once.")
(defvar-local cooked-process--live nil
  "The live grid as a vector of rendered rows, one per screen row.

A drain reports only the rows it damaged, so the untouched ones have to be
remembered somewhere to be shown at all.  Coherent under scrolling because
`Screen::scroll_up\=' in src/emu/screen.rs damages the whole region: rows that
merely shifted are re-reported rather than left for this to shift itself.")
(defvar-local cooked-process--tail nil
  "Overlay showing `cooked-process--live\=', in the consumer\='s buffer.")

(defvar-local cooked-process--host nil
  "The hidden host buffer, set in the *consumer's* buffer.

`kill-compilation' and friends start from the consumer's buffer and have only
the process object; this is how the session is found from there.")

;;;; Spawning

(defun cooked-process--environment ()
  "The child's environment: cooked's own, over whatever the caller bound.

`compilation-start' binds `process-environment' around the spawn to add
INSIDE_EMACS and to empty PAGER, and both are still wanted -- the second more
than ever, since a real tty is precisely what makes git reach for `less'."
  (cooked--child-environment nil))

(defun cooked-process--size (buffer)
  "Rows and columns for a session feeding BUFFER."
  (cons cooked-process-rows
        (or cooked-process-columns
            (when-let* ((window (get-buffer-window buffer t)))
              (window-max-chars-per-line window))
            80)))

(defun cooked-process-start (name buffer argv &optional directory)
  "Run ARGV on a pty and return a process object feeding BUFFER.

NAME names the process.  DIRECTORY is where the child starts, defaulting to
BUFFER's `default-directory'; a remote one is refused the same way
`cooked--start' refuses it, the pty being local either way.

The object returned is a pipe process that carries nothing: its filter and
sentinel are called by this file, with the text the emulator has finished with
and with the child's real exit status.  See this file's Commentary for why it
cannot be the child's own process."
  (cooked--load-module)
  (let* ((host (generate-new-buffer (format " *cooked-process %s*" name)))
         (proc (make-pipe-process :name name :buffer buffer :noquery t
                                  :filter #'ignore :sentinel #'ignore))
         (directory (or directory (buffer-local-value 'default-directory buffer))))
    (set-marker-insertion-type (process-mark proc) nil)
    (set-marker (process-mark proc) (point-max) buffer)
    ;; `recompile' hands back the same buffer, and the session it had last time
    ;; may never have been asked to stop -- a build killed by starting another
    ;; one is the ordinary case, not the exceptional one.
    (cooked-process-reap (buffer-local-value 'cooked-process--host buffer))
    (with-current-buffer buffer
      (setq cooked-process--host host)
      ;; Without this the reader thread and the pty outlive the only buffer
      ;; that could have shown their output, and the pump wakes for a filter
      ;; whose process has no buffer left to write to.
      (add-hook 'kill-buffer-hook #'cooked-process--buffer-killed nil t))
    (with-current-buffer host
      ;; The host holds buffer-locals and, when `cooked-process-styled' is on,
      ;; is also the scratch the styling is rendered in -- see
      ;; `cooked-process--text'.  Every drain inserts and deletes there, and an
      ;; undo history of a buffer nobody can visit is a flood's worth of
      ;; retained strings.
      (buffer-disable-undo)
      (setq cooked-process--proc proc)
      (pcase-let ((`(,rows . ,cols) (cooked-process--size buffer)))
        (setq cooked-process--columns cols)
        (setq cooked-process--wake
              (make-pipe-process :name (format " cooked-process-wake<%s>" name)
                                 :buffer host :noquery t :sentinel #'ignore
                                 :filter (lambda (_p _s) (cooked-process--pump host))))
        (setq cooked-process--session
              (cooked--spawn argv (cooked-process--environment) rows cols
                             cooked-process--wake
                             (and directory
                                  (expand-file-name (or (cooked--local-name directory) "~")))
                             (round (* 1000 cooked-min-redisplay-interval))
                             cooked-backlog-limit))))
    proc))

(defun cooked-process-start-shell-command (name buffer command)
  "Run COMMAND through the shell on a pty, feeding BUFFER under NAME.

Signature-compatible with `start-file-process-shell-command', which is what
lets `cooked-process-mode' put it in that function's place for the extent of
one `compilation-start' rather than advising every caller of it."
  (cooked-process-start name (get-buffer-create buffer)
                        (list shell-file-name shell-command-switch command)))

;;;; Rendering

(defun cooked-process--text (block)
  "BLOCK\='s text, carrying the child\='s colours when they are wanted.

BLOCK is what `cooked--drain\=' hands back for a run of rendered text --
`(TEXT STYLE-SPANS DECO-SPANS LINK-SPANS)\=', the shape `cooked--render-block\='
takes.  Only the first two are used, and that is a decision each:

Decorations are dropped because they are a *terminal\='s* answer to a glyph the
font cannot draw -- a box character composed out of overlays, a shade dithered
against the screen column it sits on.  A compilation buffer has no screen
column, and text that displays as something other than itself is text a regexp
matches and the eye does not.

Links are dropped because they could not be followed from there.  A
`cooked-link-id\=' resolves through `cooked--link-uris\=', which is buffer-local
to the session -- the hidden host, here -- so an id carried into the consumer\='s
buffer would arrive as a `mouse-face\=' over text whose destination nothing in
that buffer can look up.  Worse than no link.

The styling is applied by rendering into the host buffer and lifting the result
out again, rather than by building a propertized string: `cooked--render-block\='
is the one place that knows the packed span format, and its face cache is
buffer-local, so the host is what gives the memoization a lifetime -- one
build\='s worth.  A theme changed mid-build therefore leaves the rest of that
build\='s colours resolved against the old theme, which is the same thing the
text already above it in the buffer says, and the next build starts a fresh
host and a fresh cache.

Both `face\=' and `font-lock-face\=' are set, to the same value.  Neither alone
covers both consumers: `compilation-mode\=' fontifies, and
`font-lock-default-unfontify-region\=' strips a bare `face\=' from every region
it touches -- which is why `ansi-color\=' reaches for `font-lock-face\=' in
exactly this situation -- while a consumer with no font-lock at all, such as
`async-shell-command\='s buffer, never installs the
`char-property-alias-alist\=' entry that would make `font-lock-face\=' visible.
The alias is consulted only where `face\=' is absent, so the pair is read as
one face and not as two."
  (when block
    (if (not cooked-process-styled)
        (car block)
      (let ((start (point-max)))
        (save-excursion
          (goto-char start)
          (cooked--render-block (list (car block) (cadr block) nil nil))
          (let ((end (point)))
            (let ((pos start))
              (while (< pos end)
                (let ((next (next-single-property-change pos 'face nil end))
                      (face (get-text-property pos 'face)))
                  (when face (put-text-property pos next 'font-lock-face face))
                  (setq pos next))))
            (prog1 (buffer-substring start end)
              (delete-region start end))))))))

(defun cooked-process--emit (text)
  "Hand TEXT to the filter of HOST's consumer process.

Nothing here inserts anything.  Where the text lands is `process-mark''s
business and therefore the consumer's, which is the whole of what makes
`compilation-filter' work unmodified."
  (when-let* (((not (string-empty-p text)))
              (proc cooked-process--proc)
              (buffer (process-buffer proc))
              ((buffer-live-p buffer)))
    (funcall (or (process-filter proc) #'ignore) proc text)))

;;;; The live tail

(defun cooked-process--remember-rows (rows height)
  "Fold ROWS, a drain\='s damaged rows, into `cooked-process--live\='.

HEIGHT is the grid\='s row count, which decides the vector\='s length: a resize
between drains means the remembered rows describe a screen that no longer
exists, and the drain that carries the new height re-reports every row of the
new one."
  (unless (and cooked-process--live
               (eql (length cooked-process--live) height))
    (setq cooked-process--live (make-vector height "")))
  (pcase-dolist (`(,index . ,block) rows)
    (when (< index height)
      (aset cooked-process--live index
            ;; Right-trimmed because a bar is padded out to the terminal's width
            ;; with spaces, and an overlay is not a screen: nothing here has to
            ;; reach the right margin, and the trailing run would only widen the
            ;; window for a line whose visible text stops well short of it.
            (string-trim-right (or (cooked-process--text block) ""))))))

(defun cooked-process--tail-text ()
  "`cooked-process--live\=' as text, or nil when the grid says nothing.

Trailing blank rows are dropped rather than shown.  The grid is a fixed eight
rows and a child using one of them would otherwise be followed by seven blank
lines, which is a worse answer than no tail at all."
  (when-let* ((live cooked-process--live)
              (last (cl-position-if-not #'string-empty-p live :from-end t)))
    (mapconcat #'identity (cl-subseq live 0 (1+ last)) "\n")))

(defun cooked-process--refresh-tail (host)
  "Show HOST\='s live grid below the retired text, or take the overlay down.

Placed at `point-max\=' on every drain rather than left to a marker\='s insertion
type: the retired text of this same drain has just been inserted there, and
moving the overlay afterwards is one call against reasoning about which side of
an insertion at `process-mark\=' a zero-length overlay ends up on."
  (with-current-buffer host
    (let* ((proc cooked-process--proc)
           (buffer (and proc (process-buffer proc)))
           (text (and cooked-process-live-tail (cooked-process--tail-text))))
      (when (buffer-live-p buffer)
        (if (not text)
            (cooked-process--drop-tail)
          (with-current-buffer buffer
            (unless (overlayp cooked-process--tail)
              (setq cooked-process--tail (make-overlay (point-max) (point-max) nil t t)))
            (move-overlay cooked-process--tail (point-max) (point-max))
            ;; A newline only where `point-max' is not already at the start of
            ;; a line -- asked of `char-before' rather than `bolp', which reads
            ;; at point, and point in the consumer's buffer is wherever the user
            ;; left it.  Retired rows arrive *with* their newline, so the ordinary
            ;; case puts the overlay at column zero of a line that does not
            ;; exist yet, and an unconditional one costs a blank line between
            ;; the output and the tail -- for the whole build, since the tail is
            ;; replaced rather than moved.  The other case is real and is why
            ;; this is not simply dropped: `Update::scrolled_rows' withholds the
            ;; newline after a row it expects to rejoin, so a drain can retire
            ;; half a logical line, and without the newline the tail would weld
            ;; onto the end of it.
            (overlay-put cooked-process--tail 'after-string
                         (concat (unless (memq (char-before (point-max)) '(?\n nil))
                                   "\n")
                                 text))))))))

(defun cooked-process--drop-tail ()
  "Remove the live tail from the consumer\='s buffer.  Runs in the host.

Called from the exit path before the residue is flushed: those same rows are
about to arrive as text, and an overlay left standing would show the last frame
of the build twice."
  (when-let* ((proc cooked-process--proc)
              (buffer (process-buffer proc))
              ((buffer-live-p buffer)))
    (with-current-buffer buffer
      (when (overlayp cooked-process--tail)
        (delete-overlay cooked-process--tail))
      (setq cooked-process--tail nil))))

;;;; The pump

(defun cooked-process--pump (host)
  "Drain HOST's session and pass what retired to the consumer.

Errors are reported rather than swallowed: this runs from a process filter,
where Emacs discards them, and the symptom would be a compilation buffer that
simply stopped filling."
  (when (and host (buffer-live-p host))
    (with-current-buffer host
      (when cooked-process--session
        (condition-case err
            (let* ((update (cooked--drain cooked-process--session cooked-process--rejoin))
                   (scrolled (plist-get update :scrolled))
                   (exit (plist-get update :exit)))
              (when scrolled
                (cooked-process--emit (cooked-process--text scrolled)))
              (cooked-process--remember-rows (plist-get update :rows)
                                             (plist-get update :height))
              (if exit
                  (cooked-process--finish host exit)
                (cooked-process--refresh-tail host)))
          (error (message "cooked-process: %S" err)))))))

;;;; Exit

(defun cooked-process--residue (host)
  "Everything still on HOST\='s grid, as text, or nil.

Retired by shrinking the grid to a single row rather than by reading the rows
out of it.  The two are not the same text: `:rows\=' is one entry per *screen*
row, so a logical line the child wrapped comes back in the pieces the wrap made
of it, and the rejoin that would have put them together belongs to `:scrolled\='
-- which is to say, to rows that have retired.  A resize retires them.  Rows
leaving the top of a shrinking grid scroll off exactly as they do under a child
that keeps printing, so the last screenful of a build arrives in the same shape
as every screenful before it, and a diagnostic that happened to be near the end
is not the one `compilation-mode\=' fails to match.

What is left after that is row 0, which no scroll can reach.  It is the
cursor\='s row and is usually empty; when it is not, `:head\=' is what says
whether it continues the line above rather than starting one."
  (with-current-buffer host
    (let ((session cooked-process--session)
          (cols cooked-process--columns))
      (cooked--resize session 1 cols)
      (let* ((update (cooked--drain session cooked-process--rejoin))
             (scrolled (cooked-process--text (plist-get update :scrolled)))
             (head (plist-get update :head))
             (rows (plist-get update :rows))
             (block (cdr (assq 0 rows)))
             (last (car block))
             (tail (unless (or (null last) (string-empty-p last))
                     (let ((text (cooked-process--text block)))
                       (if (and head (> head 0)) text (concat text "\n"))))))
        (when (or scrolled tail)
          (concat (or scrolled "") (or tail "")))))))

(defun cooked-process--finish (host exit)
  "Report EXIT to HOST's consumer, then take the session down.

The order is the whole of it.  The reader thread may still be holding the tail
of the output when the child dies -- which is where a build puts its error
summary -- so the residue is flushed before anything is told the process is
over, and `compilation-handle-exit' therefore runs after the last line it is
meant to have parsed rather than before it."
  (with-current-buffer host
    (unless cooked-process--reaped
      (setq cooked-process--reaped t)
      (cooked-process--drop-tail)
      (when-let* ((residue (cooked-process--residue host)))
        (cooked-process--emit residue))
      (cooked-process--report host exit)
      (cooked-process-reap host))))

(defun cooked-process--report (host exit)
  "Call HOST's consumer's sentinel for EXIT, as a real process would.

EXIT is the child's status.  `compilation-sentinel' will not look at a message
until `process-status' says the process is over, and a pipe process can never
say that, so both accessors are rebound for the duration of this one call and
for this one process.  Everything else they are asked about is passed through."
  (with-current-buffer host
    (let* ((proc cooked-process--proc)
           (sentinel (process-sentinel proc))
           (signalled (and (consp exit) (eq (car exit) 'signal)))
           (code (if (consp exit) (cdr exit) exit))
           (status (if signalled 'signal 'exit))
           (message (cond (signalled (format "signal %s\n" code))
                          ((eql code 0) "finished\n")
                          (t (format "exited abnormally with code %s\n" code))))
           (real-status (symbol-function 'process-status))
           (real-code (symbol-function 'process-exit-status)))
      (when sentinel
        ;; Detached before it is called, not after.  `compilation-sentinel'
        ;; deletes the process it was handed, and a deletion runs the sentinel
        ;; -- so leaving ours installed means `compilation-handle-exit' running
        ;; a second time, from inside the first, still under the rebinding that
        ;; makes it look like a fresh exit.  The buffer ends up annotated twice
        ;; and the mode line reports whichever ran last.
        (set-process-sentinel proc #'ignore)
        (cl-letf (((symbol-function 'process-status)
                   (lambda (p) (if (eq p proc) status (funcall real-status p))))
                  ((symbol-function 'process-exit-status)
                   (lambda (p) (if (eq p proc) code (funcall real-code p)))))
          (funcall sentinel proc message))))))

;;;; Teardown

(defun cooked-process-reap (host)
  "Take down HOST's session, whatever state it is in.

Idempotent, because every path out ends here: a normal exit, `kill-buffer' on
the consumer's buffer while the child still runs, and `recompile' reusing a
buffer whose last session was never asked to stop.  What has to go is not
anything in Lisp -- no keymap or hook was ever installed for a headless
session -- but the reader thread, the pty, and the two pipe processes."
  (when (and host (buffer-live-p host))
    (with-current-buffer host
      (when cooked-process--session
        (ignore-errors (cooked--kill cooked-process--session))
        (setq cooked-process--session nil))
      ;; Before the processes go, while `cooked-process--proc' still names the
      ;; buffer the overlay is in: a session reaped without exiting -- a
      ;; `recompile' over a running build -- has one standing.
      (cooked-process--drop-tail)
      (when (process-live-p cooked-process--wake)
        (delete-process cooked-process--wake))
      (when (process-live-p cooked-process--proc)
        ;; Silenced first.  `delete-process' runs the sentinel, and the
        ;; consumer's is written for a process that has just ended -- so a
        ;; `compilation-handle-exit' that has already run for the child's real
        ;; status runs a second time for the pipe's fictional one, and the
        ;; buffer ends "finished" whatever the build did.
        (set-process-sentinel cooked-process--proc #'ignore)
        (delete-process cooked-process--proc))
      (let ((buffer (and cooked-process--proc (process-buffer cooked-process--proc))))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (setq cooked-process--host nil)))))
    (kill-buffer host)))

(defun cooked-process--buffer-killed ()
  "Reap the session feeding the buffer being killed."
  (cooked-process-reap cooked-process--host))

(defun cooked-process-interrupt (buffer)
  "Interrupt the child feeding BUFFER, if one is running.

Goes to the process *group* on the pty, which is what the interrupt character
does at a terminal and what `interrupt-process' on a pipe cannot do at all."
  (when-let* ((host (buffer-local-value 'cooked-process--host buffer))
              ((buffer-live-p host))
              (session (buffer-local-value 'cooked-process--session host)))
    (with-current-buffer host (cooked--signal session 2))
    t))

(defun cooked-process-send-string (buffer string)
  "Write STRING to the pty feeding BUFFER."
  (when-let* ((host (buffer-local-value 'cooked-process--host buffer))
              ((buffer-live-p host))
              (session (buffer-local-value 'cooked-process--session host)))
    (with-current-buffer host (cooked--send session string))
    t))


;;;; The consumers

;; Kept in this file rather than in one of its own.  There is no mechanism here
;; -- each entry is a `cl-letf' naming the function that consumer happens to
;; spawn with -- and a file per consumer would be filing three one-line facts
;; under three headings.

(defcustom cooked-process-commands nil
  "Predicate deciding which commands get a pty, or nil for all of them.

Called with the shell command as a string.  Nil is the honest default for a
mode you turned on deliberately, but a tty changes what some programs print --
progress meters appear, colour appears, and a few tools become chattier --
so a project where that matters wants a predicate rather than the mode off."
  :type '(choice (const :tag "Every command" nil) function))

(defcustom cooked-process-excluded-modes '(grep-mode)
  "Compilation modes that must keep the ordinary pipe.

`grep-mode' is here because its escape sequences are load-bearing rather than
decoration: `grep' passes `--color=always' on purpose and `grep-filter' turns
what comes back into the face on each match.  Resolving that away -- which is
the service this file offers everything else -- would leave a grep buffer
correct and unhighlighted, which is a worse buffer than the one it replaced.

The general shape of the exception is a consumer that parses the styling, and
`grep-mode' is the only one in Emacs that does."
  :type '(repeat symbol))

(defun cooked-process--wanted-p (command)
  "Whether COMMAND should be run on a pty."
  (or (null cooked-process-commands)
      (funcall cooked-process-commands command)))

(defun cooked-process--around-compilation-start (fn command &rest args)
  "Call FN -- `compilation-start' -- with COMMAND and ARGS, over a pty.

`compilation-start' has no hook at the point it spawns -- it calls
`start-file-process-shell-command' directly and then hangs
`compilation-sentinel' and `compilation-filter' on the result -- so the seam
is the function itself, rebound for this dynamic extent only.  Nothing else in
Emacs sees a different definition, which an `advice-add' on the spawner would
not have been able to promise.

`compilation-disable-input' is bound off because it is an answer to a question
that no longer applies: it exists to stop a build blocking forever on a read
nobody can answer, and a pty session is exactly where somebody can -- the
`getpass' case reaches the minibuffer.

`cooked-process-excluded-modes' is consulted here rather than inside the
predicate because the mode is `compilation-start\='s second argument and not
something a user predicate over the command string could recover.

A remote `default-directory' is left alone, and this is the one guard here
that is not a preference.  `start-file-process-shell-command' consults
`file-name-handler-alist' and runs the command on the host the directory names;
ours allocates a pty on this machine, TRAMP having no part in it.  Substituting
one for the other would not degrade a remote compile, it would silently run a
different command on a different machine -- against the local checkout, if one
happens to sit at the same path."
  (if (not (and (stringp command)
                (not (file-remote-p default-directory))
                (not (memq (car args) cooked-process-excluded-modes))
                (cooked-process--wanted-p command)))
      (apply fn command args)
    (let ((compilation-disable-input nil))
      (cl-letf (((symbol-function 'start-file-process-shell-command)
                 #'cooked-process-start-shell-command))
        (apply fn command args)))))

(defun cooked-process--around-kill-compilation (fn &rest args)
  "Interrupt the pty's process group, or fall back to FN with ARGS.

`kill-compilation' reaches for `interrupt-process', which a pipe process
cannot honour and which would in any case reach only the shell rather than
the tree beneath it."
  (or (cooked-process-interrupt (current-buffer)) (apply fn args)))

;;;###autoload
(define-minor-mode cooked-process-mode
  "Run `compile' and its relatives on a real pty, through cooked's emulator.

Output reaches `compilation-filter' as text the emulator has finished with:
carriage returns resolved, cursor addressing spent, the child's colours carried
over as faces, and lines the child wrapped at COLUMNS rejoined so that
`compilation-error-regexp-alist' can match them.  What the child is still
rewriting in place -- a progress bar -- is shown below that as an overlay, and
is never part of the buffer's text.
`grep', `rgrep' and `project-find-regexp' come along, all of them being
`compilation-start' underneath.

What the child sees is a terminal, so it will print what it prints for one:
colour, progress meters, and the diagnostics tools keep for a human."
  :global t
  (if cooked-process-mode
      (progn
        (advice-add 'compilation-start :around #'cooked-process--around-compilation-start)
        (advice-add 'kill-compilation :around #'cooked-process--around-kill-compilation))
    (advice-remove 'compilation-start #'cooked-process--around-compilation-start)
    (advice-remove 'kill-compilation #'cooked-process--around-kill-compilation)))

(provide 'cooked-process)
;;; cooked-process.el ends here
