;;; cooked-process.el --- a pty under an ordinary process filter -*- lexical-binding: t; -*-

;;; Commentary:

;; The rest of cooked spends what it knows on a buffer somebody is looking at.
;; This file spends it on the buffers nobody looks at as terminals at all: the
;; ones `compile', `grep' and `async-shell-command' fill by hanging a filter on
;; a process and letting text pile up.  Those consumers do not want a terminal.
;; They want what a terminal would have given the child, and then text they can
;; parse, in the colours the child chose.
;;
;; It is worth being exact about what that is, because the obvious answer is
;; wrong.  It is not `isatty'.  `compilation-start' never binds
;; `process-connection-type', so it inherits the default `t' and the child
;; already has a pty: `[ -t 1 ]' in a stock `emacs -Q' compilation buffer says
;; yes, and did before any of this existed.
;;
;; What Emacs' pty has not got is a *size* or a *name*.  `stty size' on it
;; reports `0 0', and TERM is whatever the environment Emacs was launched from
;; happened to hold -- the terminal that ran `emacs' in one case, and nothing at
;; all when a desktop launcher started it.  Both of those are answers that mean
;; "no terminal here" to the program asking.  Cargo draws its progress bar on a
;; 120x40 pty and draws nothing on a 0x0 one; a child told `TERM=dumb' emits no
;; escape sequences at all, on a real pty, however wide.  So a build under stock
;; Emacs is usually a build that decided not to say anything interesting, and
;; the first thing this file does is stop asking it to.
;;
;; The second is to finish resolving what does arrive.  Emacs makes a start:
;; `compilation-filter' calls `comint-carriage-motion' (compile.el) and
;; `async-shell-command' hangs `comint-output-filter' on its process
;; (simple.el), so carriage returns and backspaces are already handled today.
;; They are handled by deleting, though, which is not what a terminal does with
;; them -- a terminal overwrites:
;;
;;   $ printf 'abcdefghij\rXYZ\n'
;;   XYZ           # comint: the CR deleted to the start of the line
;;   XYZdefghij    # here: the CR moved the cursor and XYZ overwrote
;;
;; and past those two characters there is nothing in Emacs at all.  An erase to
;; end of line, an absolute cursor address, a region scrolled by the child --
;; each of them is a sequence `ansi-color' drops on the floor and a grid
;; applies.  That is the difference this file is for, and it is a difference in
;; what the text *says*, not in how it is decorated.
;;
;; So the session here is headless.  A grid exists, because it is the parser,
;; but it is never rendered: no keymap, no input region, no decorations, no
;; links, no `cooked-mode'.  What the consumer's filter receives is the text
;; that has *retired* from that grid -- and with `cooked-process--rejoin', a
;; diagnostic the child wrapped at COLUMNS arrives as one line, so a
;; `compilation-mode' regexp matches it rather than finding a newline through
;; the middle of `error:'.  That last one is a debt this file incurs and then
;; pays: nothing wraps on a 0x0 pty, and giving the child a width is what makes
;; wrapping possible in the first place.
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
;; the mechanism.
;;
;; An `OSC 8' link rides along the same way now that its destination sits on the
;; text itself, as `cooked-link-uri', rather than behind an id only the hidden
;; host could resolve: the consumer gets the highlight, the `help-echo' and the
;; keymap that follows it, so a link a build tool printed is followable with no
;; `cooked-mode' in the buffer at all.  What still does not travel is a glyph
;; decoration, a terminal's answer to a screen column that a compilation buffer
;; has none of.  See `cooked-process--text'.
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
;; ## Two processes, and why the visible one is a stand-in
;;
;; `cooked--spawn' wants a pipe process to wake, and the consumer wants a
;; process object of its own to hang a filter and a sentinel on.  These cannot
;; be the same object: `compilation-start' calls `set-process-filter' on what we
;; return, and that would tear out the pump.  So the wake pipe stays private and
;; a second process is what the consumer sees.  It carries none of the child's
;; output: `process-buffer', `process-mark', `set-process-filter' and
;; `set-process-sentinel' are real on it and are all the consumer uses, and the
;; pump reads the filter back off it and calls it with text the emulator has
;; finished with.
;;
;; The one thing the consumer needs beyond that is an exit status, and
;; `compilation-sentinel' will not proceed without a real one: `(memq
;; (process-status proc) (quote (exit signal)))' before it hands anything to
;; `compilation-handle-exit'.  A pipe process can never say that.  So the
;; stand-in is not a pipe but a real child of Emacs -- a shell doing nothing but
;; waiting to be told which status to leave with, `cooked-process--stand-in'.
;; When the pty's child exits, the residue is flushed and the shell is sent the
;; code; it exits with it, and Emacs reports that to the consumer's sentinel the
;; way it reports any process' exit.
;;
;; The cost is one sleeping `sh' for the life of a build.  It buys a process
;; object that is honest to every accessor rather than to the two a `cl-letf'
;; could cover -- and that rebinding was not merely inelegant.  Emacs'
;; primitives are reached directly from natively compiled code, so `compile.el'
;; saw a rebinding of `process-status' only through a subr trampoline, and with
;; `native-comp-enable-subr-trampolines' nil it saw none: the build's exit
;; vanished and the buffer sat at "run" forever.  Calling
;; `compilation-handle-exit' by hand instead would mean this file knowing the
;; consumer it is feeding, which is exactly what it is trying not to know.

;;; Code:

(require 'cl-lib)
(require 'cooked)

(cooked--declare-core)

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
wraps, the wrap decides what `cooked-process--rejoin' rejoins, and a buffer
whose text depends on how wide a window happened to be when the build ran is
not reproducible.  Following the window is friendlier and is one `setq' away.

Raising it to escape the wrap entirely is the tempting mistake, and it buys
nothing: the wrap is exactly invertible, so a 20,000-line log retires
byte-identical text at 120 columns and at 8192.  What changes is the cost.  A
child that erases to end of line with a background colour set fills every
column to the margin, and that log went from 2.4 MB and 1.3 seconds at 120 to
164 MB and 70 seconds at 8192.  Eighty is the floor worth having -- `curl -#'
pads its progress bar to it -- and there is no reason above a few hundred."
  :type '(choice integer (const :tag "Follow the window" nil)))

(defcustom cooked-process-styled t
  "Whether the child's colours reach the consumer's buffer.

On, because the reason to give a build a pty is to be shown what it shows a
human, and half of that is colour: cargo's green `Compiling', rustc's red
`error', the bold path in a diagnostic.  The emulator has already parsed the
SGR that named them -- `cooked--drain' hands the styling back beside the text
-- so dropping it would be throwing away the more expensive half of the work.

Off is the older behaviour and still the right answer for a consumer that would
rather own the styling itself, or one whose faces are load-bearing in some way
`grep-mode' is not; see `cooked-process-excluded-modes' for the stronger
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
text, which is the whole point.  `compilation-mode' never parses it, no
`next-error' can land in it, `process-mark' does not move for it, and it is
replaced wholesale on every drain and gone at exit -- by which time the same
rows have retired properly, as text, through `cooked-process--residue'.

Off gives the buffer that is only ever what the child finished saying."
  :type 'boolean)

(defconst cooked-process--rejoin t
  "Always rejoin wrapped lines, unlike `cooked-rejoin-wrapped-lines'.

That option is about a transcript somebody reads, where breaking a wrapped line
back apart is a defensible taste.  Here it decides whether a regexp matches: a
diagnostic the child wrapped at COLUMNS has `error:' with a newline through it
until this rejoins it, and no consumer of this file wants that.

A constant rather than an option, and it has to stay one.  Giving the child a
width is what makes it wrap at all -- nothing wraps on the 0x0 pty Emacs would
have handed it -- so this is not a preference about presentation but the other
half of a debt `cooked-process-columns' incurs.  The reason a wide grid buys
nothing, and the reason the width may be chosen for cost alone, is that the
imposed wrap inverts exactly; an option here would leave it inverted only
sometimes, and the argument in `cooked-process-columns' would stop holding.")

(defvar-local cooked-process--session nil
  "Native session handle, in the hidden host buffer.")
(defvar-local cooked-process--wake nil
  "The private pipe `cooked--spawn' wakes.  Not the consumer's process.")
(defvar-local cooked-process--proc nil
  "The stand-in process the consumer sees.")
(defvar-local cooked-process--reported nil
  "Set once the stand-in has been told which status to exit with.

From then on it is Emacs' to finish with: the reap must leave it alone rather
than kill it, or the exit it was asked for never reaches the sentinel.")
(defvar-local cooked-process--columns nil
  "Columns the session was spawned at, needed by the flush at exit.")
(defvar-local cooked-process--reaped nil
  "Set once the exit path has run, so it can run only once.")
(defvar-local cooked-process--tail nil
  "Overlay showing the live grid, in the consumer's buffer.")

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

(defconst cooked-process--stand-in-script
  "while read -r reply; do
  case $reply in
    cooked-exit:[0-9]*) exit \"${reply#cooked-exit:}\" ;;
  esac
done
exit 255"
  "The shell the consumer's process object runs while the build does.

It reads nothing but the one line `cooked-process--report' writes, and every
other line it is handed is ignored rather than acted on -- a consumer that
wrote to the process it was given would otherwise end the build with a status
nobody chose.  Losing the channel altogether, which is what reaching the end of
the loop means, is reported as 255 rather than as the success an empty `exit'
would have claimed.")

(defun cooked-process--stand-in (name buffer)
  "Start the process object the consumer sees, named NAME and showing BUFFER.

It is a real child of Emacs, and the Commentary says why: the consumer's
sentinel wants a status `process-status' will vouch for, which a pipe process
has no way to produce.  This one produces it by exiting, once
`cooked-process--report' has told it what to exit with.

It gets a pipe rather than a pty -- there is already a pty in this file and it
belongs to the child that matters -- and it starts in the directory named by
the variable `temporary-file-directory', because the directory it runs in is
not a thing it can observe, while a remote `default-directory' inherited from
the caller would be one `make-process' cannot honour at all."
  (let ((default-directory temporary-file-directory)
        (process-connection-type nil))
    (make-process :name name :buffer buffer :noquery t
                  :connection-type 'pipe
                  :command (list shell-file-name shell-command-switch
                                 cooked-process--stand-in-script)
                  :filter #'ignore :sentinel #'ignore)))

(defun cooked-process-start (name buffer argv &optional directory)
  "Run ARGV on a pty and return a process object feeding BUFFER.

NAME names the process.  DIRECTORY is where the child starts, defaulting to
BUFFER's `default-directory'; a remote one is refused the same way
`cooked--start' refuses it, the pty being local either way.

The object returned carries none of the child's output: its filter is called by
this file, with the text the emulator has finished with, and it is a stand-in
process that exits with the child's status once the child has one.  See this
file's Commentary for why it cannot be the child's own process."
  (cooked--load-module)
  (let* ((host (generate-new-buffer (format " *cooked-process %s*" name)))
         (proc (cooked-process--stand-in name buffer))
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
      ;; The tables `cooked--install-images' fills, made here as `cooked--start'
      ;; makes them for a session buffer.  Nothing here ever displays a picture --
      ;; `cooked-process--text' renders with no decorations -- but the shared step
      ;; installs what a drain carries whatever the consumer does with it, and an
      ;; image's bytes cross exactly once, so the id has to land in a table rather
      ;; than in a nil nobody made.
      (cooked--reset-images)
      (setq cooked-process--proc proc)
      (pcase-let ((`(,rows . ,cols) (cooked-process--size buffer)))
        (setq cooked-process--columns cols)
        (setq cooked-process--wake
              (cooked--make-wake-pipe (format " cooked-process-wake<%s>" name) host
                                      (lambda (_p _s) (cooked-process--pump host))))
        ;; The same builder `cooked--start' spawns through, with no frame: there is no
        ;; window here to report a pixel size or a graphics type for, and the palette
        ;; is passed all the same, since the colours a build tool asks about before it
        ;; draws are a real answer wherever its text ends up.  Pushed once, at the
        ;; spawn: this host is not a `cooked-mode' buffer, so `cooked-theme-change-hook'
        ;; does not run in it and a theme changed mid-build leaves the rest of that
        ;; build answering in the theme it started under -- which is what the text
        ;; already above it in the buffer says, and the same bargain
        ;; `cooked-process--text' strikes with its face cache.
        (setq cooked-process--session
              (apply #'cooked--spawn
                     (cooked--spawn-arguments argv (cooked-process--environment)
                                              rows cols cooked-process--wake
                                              directory nil)))
        ;; Where `cooked--route-events' and `cooked--sync-palette' look for the
        ;; session to speak for, as they would in a session buffer.
        (setq cooked--session cooked-process--session)))
    proc))

(defun cooked-process-start-shell-command (name buffer command)
  "Run COMMAND through the shell on a pty, feeding BUFFER under NAME.

Signature-compatible with `start-file-process-shell-command', which is what
lets `cooked-process-mode' put it in that function's place for the extent of
one `compilation-start' rather than advising every caller of it."
  (cooked-process-start name (get-buffer-create buffer)
                        (list shell-file-name shell-command-switch command)))

;;;; Rendering

(defun cooked-process--text (block &optional unlinked)
  "BLOCK's text, carrying the child's colours and links when they are wanted.

BLOCK is what `cooked--drain' hands back for a run of rendered text, and what
`cooked--screen-text' hands over for the live screen -- `(TEXT STYLE-SPANS
DECO-SPANS ROWS)', the shape `cooked--render-block' takes.  Only the first two
are used, and that is a decision each.  The text can be several screen rows
separated by newlines, and stays one string here: the only caller that cares
where the rows are is `cooked-process--tail-text', which splits it on those
newlines.

Decorations are dropped because they are a *terminal's* answer to a glyph the
font cannot draw -- a box character composed out of overlays, a shade dithered
against the screen column it sits on.  A compilation buffer has no screen
column, and text that displays as something other than itself is text a regexp
matches and the eye does not.

Links travel now, by default: the destination rides on the text as
`cooked-link-uri', so `cooked--render-block' is called with its UNLINKED
argument off, and `cooked-link--propertize' puts the same `keymap',
`mouse-face' and `help-echo' on the span it would in a `cooked-mode' buffer.
`RET' and `mouse-2' there both run `cooked-follow-link', which opens the
destination through `cooked-link-browse' -- the same path a live session
uses -- so a link a build tool printed is followable in a plain compilation
buffer with no `cooked-mode' loaded at all.  Where a diagnostic and a link
land on the same characters, `compilation-mode''s own parse runs after this
text is inserted and overwrites `keymap', `mouse-face' and `help-echo' with
its own -- see `compilation-error-properties' -- so `next-error' still wins
there.

UNLINKED is for `cooked-process--tail-text', which passes it non-nil.  Point
cannot land inside an overlay's `after-string', only before or after it, so
`RET' could never reach a link shown there; a link only `mouse-2' can follow
is the same bad trade decorations already declined above.

The styling is applied by rendering into the host buffer and lifting the result
out again, rather than by building a propertized string: `cooked--render-block'
is the one place that knows the packed span format, and its face cache is
buffer-local, so the host is what gives the memoization a lifetime -- one
build's worth.  A theme changed mid-build therefore leaves the rest of that
build's colours resolved against the old theme, which is the same thing the
text already above it in the buffer says, and the next build starts a fresh
host and a fresh cache.

Both `face' and `font-lock-face' are set, to the same value.  Neither alone
covers both consumers: `compilation-mode' fontifies, and
`font-lock-default-unfontify-region' strips a bare `face' from every region
it touches -- which is why `ansi-color' reaches for `font-lock-face' in
exactly this situation -- while a consumer with no font-lock at all, such as
`async-shell-command's buffer, never installs the
`char-property-alias-alist' entry that would make `font-lock-face' visible.
The alias is consulted only where `face' is absent, so the pair is read as
one face and not as two -- and it is why a link's own `cooked-link' face,
`cooked-link--propertize' puts on unstyled link text the same as it would in
a `cooked-mode' buffer, reaches the consumer at all."
  (when block
    (if (not cooked-process-styled)
        (car block)
      (let ((start (point-max)))
        (save-excursion
          (goto-char start)
          (cooked--render-block (list (car block) (cadr block) nil nil) nil nil unlinked)
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

(defun cooked-process--tail-text ()
  "The live grid as text, or nil when it says nothing.  Runs in the host.

Asked of the core, which has the screen, rather than assembled here from the
drains that have gone by.  `cooked--screen-text' hands over every row the screen
occupies in the same block `:scrolled' arrives in, so this file needs nothing
from `:shifts', `:rows' or `:edits' -- and the delta protocol keeps the one
renderer, `cooked--render-block', that `delta_replay' and the Lisp oracle hold
to the core.  A second renderer here would have been a second reading of shift
direction, of a nil CHAR-END and of LENGTH, with nothing pinning it.

Trailing blank rows are dropped rather than shown.  The grid is a fixed eight
rows and a child using one of them would otherwise be followed by seven blank
lines, which is a worse answer than no tail at all.

Rendered unlinked, deliberately: see UNLINKED in `cooked-process--text'.  The
tail is an overlay's `after-string', and point cannot land inside one, so a
link here could only ever answer `mouse-2' and never `RET' -- an affordance
this file would rather not offer than offer by half."
  (when-let* ((session cooked-process--session)
              ;; Right-trimmed because a bar is padded out to the terminal's width
              ;; with spaces, and an overlay is not a screen: the trailing run would
              ;; only widen the window for a line whose visible text stops well
              ;; short of it.  Trimmed rather than left to the core, which keeps a
              ;; row as the child wrote it.
              (rows (mapcar #'string-trim-right
                            (split-string (cooked-process--text
                                           (cooked--screen-text session) t)
                                          "\n")))
              (last (cl-position-if-not #'string-empty-p rows :from-end t)))
    (mapconcat #'identity (cl-subseq rows 0 (1+ last)) "\n")))

(defun cooked-process--refresh-tail (host)
  "Show HOST's live screen below the retired text, or take the overlay down.

Placed at `point-max' on every drain rather than left to a marker's insertion
type: the retired text of this same drain has just been inserted there, and
moving the overlay afterwards is one call against reasoning about which side of
an insertion at `process-mark' a zero-length overlay ends up on."
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
  "Remove the live tail from the consumer's buffer.  Runs in the host.

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

(defconst cooked-process--drain-keys '(:scrolled :head)
  "The keys of a drain this file reads beyond `cooked--consumed-drain-keys'.

The retired text, which is the whole of what a consumer here is promised, and
the seam it can end on -- `cooked-process--residue' is the one reader of that,
and says why the last row of a build needs it.  Everything else the shared step
answers for, or `cooked-process--ignored-drain-keys' argues out.")

(defconst cooked-process--ignored-drain-keys
  '((:promoted . "Promotion hands rows the buffer already holds to the
scrollback, and a `scrolled' drain does none: the consumer's buffer is not a
transcript of the grid, and nothing here holds a copy of a row.")
    (:rows . "Empty on every drain this file takes, and not merely unread:
`cooked-process--pump' asks for a `scrolled' drain, which builds no damaged row
at all, a consumer with no copy of the screen having none to patch.  What is
still on the grid is read whole, by `cooked--screen-text', and shown as an
overlay; see `cooked-process--tail-text'.")
    (:edits . "As `:rows': no held row for an edit to replace part of, and so
none built.")
    (:shifts . "As `:rows': no held row for a shift to move, and so none
built.")
    (:height . "The grid's shape is this file's own, from `cooked-process-rows'
and `cooked-process--columns', and nothing here is laid out against it.")
    (:width . "As `:height'.")
    (:used . "As `:height'.  `cooked--screen-text' leaves the unused rows out
for us.")
    (:cursor . "There is no cursor to place: the text lands wherever the
consumer's `process-mark' is, which is the consumer's business.")
    (:reverse . "DECSCNM remaps the faces of a screen, and a compilation buffer
is not one; its text keeps the colours the child chose.")
    (:reverse-toggles . "As `:reverse'.")
    (:marks . "An OSC 133 mark anchors into a transcript this file does not
own, and no consumer here asks where the prompts were.")
    (:alt . "Which screen the rows came off, and the retired text is the same
text either way: the alternate screen contributes no scrollback (`State::resize'
in src/emu/term/state.rs), so anything in `:scrolled' while it is up came off
the primary and is history.  A live session reads this to decide where the
screen region starts and whether to pin it, and there is no region here.")
    (:app-cursor . "A key encoding, for sending keys.  Nothing here sends any:
the consumer's process object is the stand-in shell, and what reaches the child
goes through `cooked-process-send-string' as bytes the caller composed.")
    (:keys . "As `:app-cursor'.")
    (:kitty-flags . "As `:app-cursor'.")
    (:modify-other-keys . "As `:app-cursor'.")
    (:withheld . "Nil on every drain this file takes.  A `scrolled' drain
leaves the screen out without withholding it: the damage waits in the core for
a whole drain nobody here asks for, and a consumer with no screen is owed
none."))
  "Why the pump leaves each remaining key of a drain alone.

Not an inventory of the drain -- the `cooked--drain' docstring in src/lib.rs is
that -- but the argument that each key this file does not read is one it is
right not to read.  Four defects in two days came of picking fields out of the
drain by hand and never being told about the ones that were missed, so a key
added to the drain and to neither table fails
`cooked-process-accounts-for-every-key-of-a-drain'.")

(defun cooked-process--pump (host)
  "Drain HOST's session and pass what retired to the consumer.

The drain is a `scrolled' one: the scrollback, the events, the resources and
the levels, and no damaged rows.  Asking for a whole drain cost the core a row
diff and a block per damaged row -- a progress bar rewriting one row pays it on
every wake -- and every one of them landed on the ignored list below, because
the live grid is read whole a moment later by `cooked-process--refresh-tail'.
The damage waits in the core exactly as it does for a hidden buffer, so the
session is still one a whole drain would report correctly; nothing here ever
takes one.

`cooked--consume-drain' is what makes this a consumer of a drain rather than a
second reading of one.  It installs the resources before the retired text is
rendered -- a link a row names by id has to resolve before
`cooked-process--text' reads it off that text -- adopts the levels that
describe the child rather than a screen, which is how a build that reaches a
`getpass' is noticed here at all, and answers the replies the core is holding.

No event handler is supplied, and that is the one choice this consumer makes: a
title would rename the hidden host, OSC 7 would move its `default-directory',
and a colour set would remap a face in a buffer nobody sees.  A reply is not an
event in that sense, and declining is not offered for it: the child is blocked
on the answer whether or not anyone is looking at a terminal.

What is left here is the two things only this consumer does: hand the retired
text to the filter, and show what is still on the grid below it.

Errors are reported rather than swallowed: this runs from a process filter,
where Emacs discards them, and the symptom would be a compilation buffer that
simply stopped filling.  The readiness is owed however it went, and not once
the exit has reaped the session, which kills it and the host with it."
  (when (and host (buffer-live-p host))
    (with-current-buffer host
      (when-let* ((session cooked-process--session))
        (cooked--owing-readiness
            (and (buffer-live-p host)
                 (buffer-local-value 'cooked-process--session host))
          (condition-case err
              (let ((update (cooked--drain session cooked-process--rejoin 'scrolled)))
                (cooked--consume-drain
                 update
                 (lambda ()
                   (when-let* ((scrolled (plist-get update :scrolled)))
                     (cooked-process--emit (cooked-process--text scrolled)))))
                (if cooked--exit
                    (cooked-process--finish host cooked--exit)
                  (cooked-process--refresh-tail host)))
            (error (message "cooked-process: %S" err))))))))

;;;; Exit

(defun cooked-process--residue (host)
  "Everything still on HOST's grid, as text, or nil.

Retired by shrinking the grid to a single row rather than by reading the rows
out of it.  The two are not the same text: `:rows' is one entry per *screen*
row, so a logical line the child wrapped comes back in the pieces the wrap made
of it, and the rejoin that would have put them together belongs to `:scrolled'
-- which is to say, to rows that have retired.  A resize retires them.  Rows
leaving the top of a shrinking grid scroll off exactly as they do under a child
that keeps printing, so the last screenful of a build arrives in the same shape
as every screenful before it, and a diagnostic that happened to be near the end
is not the one `compilation-mode' fails to match.

What is left after that is row 0, which no scroll can reach.  It is the
cursor's row and is usually empty; when it is not, `:head' is what says
whether it continues the line above rather than starting one.  That row is read
with `cooked--screen-text', which asks the core what is on the grid, rather
than out of the drain's `:rows', which says what changed.  Both answer the same
thing here -- a resize sends every row again, `State::resize' in
src/emu/term/state.rs having forgotten what Emacs holds -- and asking for the
screen is the reading that does not depend on that."
  (with-current-buffer host
    (let ((session cooked-process--session)
          (cols cooked-process--columns))
      (cooked--resize session 1 cols)
      (let* ((update (cooked--drain session cooked-process--rejoin 'scrolled))
             ;; Through the shared step for the same reason the pump is, and it
             ;; is the last drain of the build: the resources this text names go
             ;; in before it is rendered, and a reply the child is still waiting
             ;; for is owed to it even now, `cooked--kill' being what ends the
             ;; wait otherwise.
             (scrolled (cooked--owing-readiness cooked-process--session
                         (cooked--consume-drain
                          update
                          (lambda ()
                            (cooked-process--text (plist-get update :scrolled))))))
             (head (plist-get update :head))
             ;; The grid is one row tall by now, so this is that row and nothing
             ;; else, newlines and all: there is no second row for it to reach.
             (block (cooked--screen-text session))
             (tail (unless (string-empty-p (car block))
                     (let ((text (cooked-process--text block)))
                       (if (and head (> head 0)) text (concat text "\n"))))))
        (when (or scrolled tail)
          (concat (or scrolled "") (or tail "")))))))

(defun cooked-process--finish (host exit)
  "Report EXIT to HOST's consumer, then take the session down.

The order is the whole of it.  The reader thread may still be holding the tail
of the output when the child dies -- which is where a build puts its error
summary -- so the residue is flushed through the consumer's filter before the
stand-in is told to exit, and `compilation-handle-exit' therefore runs after
the last line it is meant to have parsed rather than before it."
  (with-current-buffer host
    (unless cooked-process--reaped
      (setq cooked-process--reaped t)
      (cooked-process--drop-tail)
      (when-let* ((residue (cooked-process--residue host)))
        (cooked-process--emit residue))
      (cooked-process--report host exit)
      (cooked-process-reap host))))

(defun cooked-process--report (host exit)
  "Hand EXIT to HOST's stand-in process, which leaves with it.

EXIT is the child's status as the core reports it, and it is the shell's
convention throughout: a code from 0 to 255, or 128 plus the signal for a child
a signal killed -- `Pty::reap' in src/pty.rs is where the second is made to
look like the first.  The one value that is neither is -1, which means a
session whose reader gave up with the child still unreapable, and it is
reported as 255, the same answer as any other channel that ended without
saying why.

Nothing is called back here.  The stand-in exits, Emacs notices, and the
consumer's sentinel runs from Emacs' own status-reporting machinery with
`process-status' and `process-exit-status' answering for real -- which is what
`compilation-sentinel' demands before it will hand anything to
`compilation-handle-exit', and what it could not be given while this was a pipe
process with the two accessors rebound around the call."
  (with-current-buffer host
    (let ((proc cooked-process--proc)
          (code (if (and (integerp exit) (<= 0 exit 255)) exit 255)))
      (when (process-live-p proc)
        (setq cooked-process--reported t)
        (process-send-string proc (format "cooked-exit:%d\n" code))))))

;;;; Teardown

(defun cooked-process-reap (host)
  "Take down HOST's session, whatever state it is in.

Idempotent, because every path out ends here: a normal exit, `kill-buffer' on
the consumer's buffer while the child still runs, and `recompile' reusing a
buffer whose last session was never asked to stop.  What has to go is not
anything in Lisp -- no keymap or hook was ever installed for a headless
session -- but the reader thread, the pty, the wake pipe and the stand-in."
  (when (and host (buffer-live-p host))
    (with-current-buffer host
      ;; A build that reached a `getpass' is a build the shared step put into
      ;; secret mode, and the prompt for it is a timer or a minibuffer read
      ;; against a child that is going away.  `cooked--cancel-secret' is what
      ;; makes the answer unsendable rather than sent to whatever runs next; a
      ;; session that never asked has nothing pending and this costs nothing.
      (cooked--cancel-secret)
      (when cooked-process--session
        (ignore-errors (cooked--kill cooked-process--session))
        (setq cooked-process--session nil
              cooked--session nil))
      ;; Before the processes go, while `cooked-process--proc' still names the
      ;; buffer the overlay is in: a session reaped without exiting -- a
      ;; `recompile' over a running build -- has one standing.
      (cooked-process--drop-tail)
      (when (process-live-p cooked-process--wake)
        (delete-process cooked-process--wake))
      ;; A stand-in that has been told what to exit with is left to do it:
      ;; killing it here would replace the status the child actually had with
      ;; the one `delete-process' gives, and that is the whole of what the
      ;; consumer is waiting for.  One that has not -- a `recompile' over a
      ;; running build, or a buffer killed mid-run -- is killed, and silenced
      ;; first, because the consumer's sentinel is written for a build that
      ;; ended and this one is being abandoned rather than finished.
      (when (and (process-live-p cooked-process--proc)
                 (not cooked-process--reported))
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
    (with-current-buffer host (cooked--signal session 'sigint))
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
correct and unhighlighted, which is worse than leaving it on the pipe.

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
predicate because the mode is `compilation-start's second argument and not
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

`kill-compilation' reaches for `interrupt-process', which would reach the
stand-in shell -- a process with no part in the build -- rather than the child
on the pty or the tree beneath it."
  (or (cooked-process-interrupt (current-buffer)) (apply fn args)))

;;;###autoload
(define-minor-mode cooked-process-mode
  "Run `compile' and its relatives on a real pty, through cooked's emulator.

Output reaches `compilation-filter' as text the emulator has finished with:
carriage returns resolved, cursor addressing spent, the child's colours carried
over as faces, an `OSC 8' link followable with `RET' or `mouse-2' though
nothing here turns on `cooked-mode', and lines the child wrapped at COLUMNS
rejoined so that `compilation-error-regexp-alist' can match them.  What the
child is still rewriting in place -- a progress bar -- is shown below that as
an overlay, and is never part of the buffer's text.
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
