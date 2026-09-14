;;; cooked-session.el --- Starting a child in a buffer -*- lexical-binding: t; -*-

;;; Commentary:

;; What it takes to get a child running in a cooked buffer: the size to give it,
;; the environment to hand it, the wake pipe the native core rings, and the two
;; numbers that pace how often it is drawn.  `cooked--start' is the one entry
;; point, and both `cooked-mode' and `cooked-process' go through it or through
;; the pieces it is made of.
;;
;; It sits above the drain pipeline in cooked-render.el, because the wake pipe's
;; filter is that pipeline's entry point, and below cooked-mode.el.

;;; Code:

(require 'cl-lib)
(require 'cooked-util)
(require 'cooked-module)
(require 'cooked-state)
(require 'cooked-deco)
(require 'cooked-screen)
(require 'cooked-pending)
(require 'cooked-graphics)
(require 'cooked-render)
(require 'cooked-color)

(cooked--declare-core)

;;;; Starting and stopping a session
;;
;; The environment to hand a child, the wake pipe the native core rings, and the
;; two options that pace it.

;; Defined by the two `defcustom's below, which name this function as their
;; `:set' and so need it to exist first.
(defvar cooked-min-redisplay-interval)
(defvar cooked-backlog-limit)

(defun cooked--set-tuning-option (symbol value)
  "Set SYMBOL to VALUE and hand the pair to every session already running.

The `:set' behind `cooked-min-redisplay-interval\=' and
`cooked-backlog-limit\='.

Two numbers, and only one of them is a pace.  That is what the name is being
careful about: `cooked-min-redisplay-interval\=' says how often the screen is
redrawn while the child is busy, and the frame ceiling derives from it, so it is
the whole of how fast a session draws.  `cooked-backlog-limit\=' sets no rate at
all.  It is backpressure -- how much may pile up while Emacs falls behind before
the reader stops taking bytes off the pty, at which point the pty's own buffer
fills and the child blocks in `write\='.  One paces, the other pauses; calling
the pair pacing would advertise a second pace mechanism that deliberately does
not exist.

Both reach a session already running, so tuning the interval does not mean
killing the terminal you are tuning it for.

Both are sent whichever one changed, because the core takes them together: they
are tuned as a pair, a longer interval leaving more to accumulate between drains
and so filling the queue sooner, and one call is what stops half a pair being
set.  `set-default\=' first, so what is sent is what the variables now say rather
than one new value and one stale one.

Sessions are walked rather than notified, for the reason
`cooked--dolist-buffers\=' exists: a buffer displayed nowhere still has a child
running at whatever rate it was last told."
  (set-default symbol value)
  (cooked--dolist-buffers
    (when cooked--session
      (cooked--set-tuning cooked--session
                          (round (* 1000 cooked-min-redisplay-interval))
                          cooked-backlog-limit))))

(defcustom cooked-min-redisplay-interval 0.008
  "Floor, in seconds, on how often a session triggers a redisplay.

Without one, a child that rewrites the same line rapidly -- a spinner, a
progress meter -- drives one full Emacs redisplay per write, far more than
any of them are actually meant to be seen at, which shows up as flicker.
Modelled on `eat-minimum-latency', though a matching ceiling on the other
end is not needed: the native core always holds the latest terminal state
regardless of whether a redisplay was requested for it, and retries a
throttled one on every read cycle, so nothing is ever stranded behind this.

A floor on the rate, and not the answer to a half-drawn frame: the core
already holds a frame back until the child stops writing it, which is what
keeps a picture's cursor move from being drawn without the picture.  Raising
this cannot improve on that and costs latency on every keystroke.

It bounds that hold from the other side as well, and is the only number that
does: a child writing continuously never falls quiet, so its frame is drawn
once this interval has passed rather than waiting for a gap that is not
coming.  One interval is therefore the whole answer to how often a busy child
redraws the buffer -- there is no second cap underneath it.

Measured from the end of the apply rather than from the drain: the core sends
one wakeup and stays quiet until Emacs has applied to the buffer what the last
one brought, so a slow apply (box drawing costs some 70 times what plain text
does) paces the child by itself and this interval is the floor beneath that
rather than a rate of its own.  Redisplay comes after the apply, and the
interval is what leaves it room.

A floor and never a clock: nothing in cooked draws faster than this, and no
urgent path bypasses it.  Four things can make a redraw *later* -- Emacs
not having applied the last one, DEC mode 2026, this interval, and the child
still writing -- and only the first is what usually decides the rate.  See
docs/DESIGN.md.

Lower it if the terminal feels less responsive than it should; raise it if a
program that rewrites one line very fast still flickers.  Takes effect at once,
on sessions already running as well as on the next one."
  :type 'number
  :set #'cooked--set-tuning-option
  :group 'cooked)

(defcustom cooked-backlog-limit 8000
  "Items awaiting collection before the child is left to block on its writes.

Counts scrolled-off lines plus undelivered events.  Raising it does not make
output render faster: throughput is bounded by how fast Emacs can insert text,
not by this queue.  What it changes is who waits.  Below the limit the child
runs ahead and finishes sooner while Emacs catches up; at the limit the reader
stops draining the pty, the pty's buffer fills, and the child blocks in `write'
exactly as it would against a slow terminal.  Nothing is ever dropped.

The cost of raising it is memory, and a larger worst-case pause when a big
backlog finally lands in one redisplay.  Tuned together with
`cooked-min-redisplay-interval': a longer interval leaves more to accumulate
between drains, so this fills sooner.  A static relationship between two
numbers you set once, not a rate that moves underneath the child -- what
actually paces a session is Emacs' own readiness to draw again, and the
interval is only a floor under that -- so size this against the slowest
cadence the pair allows and leave it alone.

Takes effect at once, on sessions already running as well as on the next one."
  :type 'natnum
  :set #'cooked--set-tuning-option
  :group 'cooked)

(defun cooked--start (argv &optional directory extra-env)
  "Spawn ARGV in the current buffer, optionally in DIRECTORY.
EXTRA-ENV is an alist prepended to the child\\='s environment.

A remote DIRECTORY is refused and the child starts in the home directory
instead.  The pty is always a local one, so a TRAMP name here is not somewhere
the child can be put: it reaches the module verbatim, the `chdir\\=' fails, and
`child_exec\\=' in src/pty.rs is right to treat that as fatal rather than exec
from wherever Emacs happened to be.  What that left was a buffer reading
\"[exited 127]\" and nothing else, which is the correct behaviour reported as an
unexplained number -- and it is reached by nothing more unusual than
\\[cooked] from a buffer visiting a remote file.

`cooked--local-name\\=' is what refuses it, rather than a `file-remote-p\\=' of
our own, because that is the chokepoint every other path from a string to the
filesystem already goes through, and its message is the one the user is told.

Only when DIRECTORY is non-nil: nil keeps its own meaning of leaving the child
wherever Emacs is, and is not a request to be second-guessed."
  (cooked--load-module)
  (cooked--reset-images)
  ;; A new core numbers its renditions from scratch, and counts DECSCNM changes
  ;; from zero.
  (cooked--reset-styles)
  (setq cooked--reverse-screen-toggles 0)
  ;; A layer that failed against the last child's output is worth hearing about
  ;; again for this one; see `cooked--seams-reported'.
  (setq cooked--seams-reported nil)
  (pcase-let ((`(,rows . ,cols) (cooked--window-size)))
    (setq cooked--rows rows cooked--cols cols
          ;; Matches `cooked--sync-size' having already run once at exactly
          ;; this size: nothing has diverged from it yet, so its very next
          ;; invocation -- on the first real window or font event -- must not
          ;; read a stale `nil' here and mistake "never synced" for "resized",
          ;; forcing a redraw against native-core state nothing has spawned
          ;; a window for yet.
          cooked--last-size (cons rows cols)))
  (cooked--with-child-edit
    (erase-buffer)
    (insert (make-string cooked--rows ?\n))
    (setq cooked--screen-start (copy-marker (point-min) nil)))
  ;; The previous session's entries describe text `erase-buffer' has just taken
  ;; away, and the anchor that vouches for them cannot notice: a buffer being
  ;; reused for a second session puts the new prompt at exactly the position the
  ;; old one held, which is the one thing `cooked--check-undo-anchor' reads as
  ;; nothing having moved.  Cleared here rather than inside the macro above, for
  ;; the reason given there.
  (setq cooked--undo-anchor nil)
  (cooked--discard-undo)
  ;; Attached to the buffer, unlike a plain doorbell would be: `get-buffer-process'
  ;; answering is the whole of what comint needs from a process, since every one of
  ;; its commands works through `process-mark' and none of them through the process
  ;; itself.  `shell-maker' buys the same thing by spawning a `hexl' it never speaks
  ;; to; we already had a process object and were only withholding it.
  ;;
  ;; Nothing may ever write here: the read end belongs to Rust, and a stray
  ;; `process-send-string' would land in the wakeup channel.  `comint-input-sender'
  ;; is overridden in `cooked-mode' so comint's own submission path cannot.  The
  ;; sentinel is silenced because the default one inserts "Process ... finished"
  ;; into the buffer it is attached to, which is now the terminal.
  (setq cooked--wake
        (make-pipe-process :name (format "cooked-wake<%s>" (buffer-name))
                           :buffer (current-buffer)
                           ;; This pipe is also the session's stand-in for the
                           ;; "active processes exist" warning, and whether it
                           ;; wants one depends on what the child is doing, so
                           ;; the flag is kept current by
                           ;; `cooked--sync-query-flag' rather than fixed here.
                           :noquery t
                           :sentinel #'ignore
                           :filter (let ((buffer (current-buffer)))
                                     (lambda (_proc _string) (cooked--on-wake buffer)))))
  (set-marker-insertion-type (process-mark cooked--wake) nil)
  (cooked--sync-query-flag)
  (cooked--set-input-mark nil)
  ;; Told at the spawn rather than after it, with the frame the buffer is about to
  ;; appear on: a child can probe before this function returns, and the core answers
  ;; a probe from what it was spawned with.  See `cooked--graphics-answer'.
  (setq cooked--graphics-shown (cooked--graphics-answer (selected-frame)))
  (setq cooked--session
        (cooked--spawn argv (cooked--child-environment extra-env) cooked--rows cooked--cols cooked--wake
                      (when directory
                        (expand-file-name (or (cooked--local-name directory) "~")))
                      (round (* 1000 cooked-min-redisplay-interval))
                      cooked-backlog-limit
                      cooked--graphics-shown))
  ;; Once, at the start: the core answers `CSI ? 996 n' from what Emacs last reported,
  ;; and a session that outlives no theme change would otherwise answer with silence for
  ;; its whole life.  Here rather than in `cooked--start-session' so that the callers who
  ;; spawn directly -- the test fixture and the benchmark -- exercise the same path.
  ;;
  ;; Protected because the session is already started by this point and is correct
  ;; without it: the only thing lost is a courtesy answer to a query most children never
  ;; send, and failing the spawn over it would trade a terminal for a colour.  The seam
  ;; is real rather than theoretical -- `cooked--default-color' guards against
  ;; `color-values' returning nil, which is not the same as it signalling, and it does
  ;; signal on a frame that claims to be graphical without a window system behind it.
  (cooked--protect-seam 'cooked--sync-color-scheme
    (cooked--sync-color-scheme))
  cooked--session)

(defun cooked--child-environment (&optional extra)
  "Environment alist for the child, with EXTRA taking precedence.

Every name this function sets is also stripped from the inherited environment,
so a value from whatever terminal started Emacs cannot shadow ours.  That is the
whole point of the exclusion list below: an inherited TERM_PROGRAM=iTerm.app
sitting beside our own TERM is worse than no answer at all, because the programs
that branch on it would take a path for a terminal that is not driving this pty.

TERMINFO is set to our own database and the inherited one is dropped with the
rest, which is the same rule and not an exception to it.  It names one directory
and we need it to name ours."
  (let* ((term (cooked--terminfo))
         ;; Only alongside our own entry: if we fell back to xterm-256color there is
         ;; nothing of ours to find and so nothing to say.
         (database (and (equal term cooked-term-name) (cooked--terminfo-database))))
    `(,@extra
      ("TERM" . ,term)
      ("COLORTERM" . "truecolor")
      ;; Identity, not capability -- what we can do is in the terminfo entry and
      ;; COLORTERM.  Nothing keys off "cooked" yet, so consumers fall through to
      ;; their defaults, which is the correct behaviour for a terminal they have
      ;; never heard of.  Set as a pair: they are read as one.
      ("TERM_PROGRAM" . "cooked")
      ("TERM_PROGRAM_VERSION" . ,(cooked-version))
      ,@(and database `(("TERMINFO" . ,database)))
      ;; LINES and COLUMNS are deliberately *not* set. ncurses treats them as
      ;; authoritative over the tty's own size (`use_env'), so a program started with
      ;; them pinned keeps its original geometry for life and ignores every SIGWINCH.
      ;; The winsize is the single source of truth; shells re-export these themselves.
      ,@(cl-loop with seen = nil
                 for entry in process-environment
                 for split = (string-search "=" entry)
                 for name = (and split (substring entry 0 split))
                 when (and name
                           (not (member name '("TERM" "COLORTERM" "TERM_PROGRAM"
                                               "TERM_PROGRAM_VERSION" "LINES"
                                               "COLUMNS" "TERMINFO")))
                           ;; First occurrence only, which is `getenv''s answer
                           ;; and so the one the caller meant.  `process-environment'
                           ;; is a list a caller shadows by consing onto the
                           ;; front -- the documented way to bind a variable for
                           ;; one process, and what `compilation-start' does to
                           ;; empty PAGER -- so a name appearing twice is
                           ;; ordinary rather than a mistake.
                           ;;
                           ;; Passing both on inverts it.  `execve' takes a plain
                           ;; array and POSIX leaves duplicate names unspecified,
                           ;; so the tie is broken by whatever reads it; measured
                           ;; here, a shell handed ("SHADOWED" . "wanted") ahead
                           ;; of ("SHADOWED" . "inherited") reports `inherited',
                           ;; the entry consed on to be overridden.  The shadow
                           ;; loses to the thing it was written to shadow, which
                           ;; is worse than not honouring it at all: nothing
                           ;; downstream does a lookup, so the loser has to be
                           ;; absent rather than merely second.
                           (not (member name seen)))
                 collect (cons name (substring entry (1+ split)))
                 and do (push name seen)))))

(provide 'cooked-session)
;;; cooked-session.el ends here
