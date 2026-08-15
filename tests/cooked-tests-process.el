;;; cooked-tests-process.el --- headless pty sessions under a filter -*- lexical-binding: t; -*-

;;; Commentary:

;; End-to-end against `compilation-start', because that is the claim: the
;; consumer is not adapted, so a test that drove `cooked-process-start'
;; directly would be testing the half that was never in doubt.  Every test here
;; runs a real child on a real pty and asserts on what `compilation-mode' made
;; of it.

;;; Code:

(require 'ert)
(require 'compile)
(require 'cooked-tests-helpers)
(require 'cooked-process)

(defmacro cooked-tests-process--with (command &rest body)
  "Run COMMAND under `cooked-process-mode' and evaluate BODY in its buffer.

The mode is global and an advice, so it is turned off again however BODY
leaves: a test that signalled while it was on would otherwise hand every
later test in the run a pty it never asked for."
  (declare (indent 1))
  `(let ((cooked-process-mode nil)
         (compilation-ask-about-save nil)
         ;; Let-bound, so a test that leaves an entry on it -- killing the
         ;; buffer mid-run is one, and is a test in its own right -- cannot
         ;; make every later test wait out its whole deadline for a process
         ;; that is never coming back.
         (compilation-in-progress nil)
         (compilation-buffer-name-function (lambda (_) "*cooked-test-compile*"))
         buffer)
     (unwind-protect
         (progn
           (cooked-process-mode 1)
           (setq buffer (compilation-start ,command))
           (cooked-tests--settle
            (lambda () (null (get-buffer-process buffer))) 20)
           (with-current-buffer buffer ,@body))
       (cooked-process-mode -1)
       (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defun cooked-tests-process--body ()
  "The child's output, without compilation's own header and footer.

The footer is found rather than counted back from the end.  Counting lines
works only while there is one, and a buffer whose child printed nothing at all
is exactly the buffer these tests must be able to tell apart from a buffer
whose output went missing -- which counting cannot do, the two being the same
number of lines."
  (save-excursion
    (goto-char (point-min))
    (forward-line 4)
    (let* ((start (point))
           (end (save-excursion
                  (goto-char (point-max))
                  (if (re-search-backward "^Compilation \\(finished\\|exited\\|interrupt\\)"
                                          start t)
                      (point)
                    (point-max)))))
      (string-trim (buffer-substring-no-properties start (max start end))))))

(defun cooked-tests-process--errors ()
  "The lines `compilation-mode' recognised as errors."
  (save-excursion
    (goto-char (point-min))
    (let (acc)
      (ignore-errors
        (while t
          (compilation-next-error 1)
          (push (buffer-substring-no-properties
                 (line-beginning-position) (line-end-position))
                acc)))
      (nreverse acc))))

(ert-deftest cooked-process-gives-the-child-a-sized-named-terminal ()
  "The child gets a terminal with a size and a name, which is the whole point.

Not a terminal at all -- it had one of those already.  `compilation-start\='
never binds `process-connection-type\=', so a stock `emacs -Q\=' compile runs
its child on a pty and `[ -t 1 ]\=' has always said yes.  What that pty reports
is `stty size\=' of `0 0\=' and whatever TERM the environment Emacs was launched
from happened to carry, and those are the two answers a program reads as
\"no terminal here\": cargo draws its bar at 120x40 and draws nothing at 0x0,
and a child told `TERM=dumb\=' emits no escape sequences at all however wide
its terminal is.

So the assertion is the geometry and the name, not the tty."
  (let ((cooked-process-rows 8)
        (cooked-process-columns 120))
    (cooked-tests-process--with
        "if [ -t 1 ]; then echo tty; fi; stty size; echo \"$TERM\""
      (should (equal (cooked-tests-process--body)
                     (format "tty\n8 120\n%s" (cooked--terminfo)))))))

(ert-deftest cooked-process-leaves-plain-output-alone ()
  "Output with nothing for an emulator to resolve comes through unchanged.

The point being that the emulator is not a filter with opinions: two hundred
ordinary lines are the same two hundred lines a pipe would have delivered, and
anything else here would be a regression in the only case that is common."
  (let ((command "for i in $(seq 1 200); do echo \"line $i of plain output\"; done"))
    (let ((piped (let ((compilation-ask-about-save nil)
                       (compilation-in-progress nil)
                       (compilation-buffer-name-function (lambda (_) "*cooked-test-pipe*")))
                   (let ((buffer (compilation-start command)))
                     (unwind-protect
                         (progn (cooked-tests--settle
                                 (lambda () (null (get-buffer-process buffer))) 20)
                                (with-current-buffer buffer (cooked-tests-process--body)))
                       (kill-buffer buffer))))))
      (cooked-tests-process--with command
        (should (equal (cooked-tests-process--body) piped))))))

(ert-deftest cooked-process-resolves-carriage-returns ()
  "A meter redrawn in place retires as its final state, not as three lines.

Emacs gets this case right already -- `comint-carriage-motion\=' runs from
`compilation-filter\=' -- so the assertion is that nothing here regressed it,
which is worth having precisely because it is the common shape.  Where the two
part company is `cooked-process-overwrites-rather-than-deleting-on-return\=':
comint deletes to the start of the line and a terminal overwrites."
  (cooked-tests-process--with
      "for i in 1 2 3; do printf 'Building [%s]\\r' $i; done; printf '\\ndone\\n'"
    (should (equal (cooked-tests-process--body) "Building [3]\ndone"))))

(ert-deftest cooked-process-overwrites-rather-than-deleting-on-return ()
  "A carriage return moves the cursor; it does not erase what it moved over.

The divergence from `comint-carriage-motion\=', whose docstring says it makes
\"single carriage returns delete to the beginning of the line\".  That is the
right approximation for a meter, which reprints its whole line every time, and
the wrong one whenever the second write is shorter than the first: the tail of
the earlier text is still on the screen of any real terminal, and comint has
thrown it away.  Measured on the stock path, the line below arrives as `XYZ\='."
  (cooked-tests-process--with "printf 'abcdefghij\\rXYZ\\n'"
    (should (equal (cooked-tests-process--body) "XYZdefghij"))))

(ert-deftest cooked-process-applies-an-erase-to-end-of-line ()
  "`CSI K\=' takes effect, where nothing in Emacs would have applied it.

Past the carriage return and the backspace, Emacs stops: `comint-carriage-motion\='
knows those two characters and `ansi-color\=' drops every non-SGR sequence it
meets.  So an erase is the first thing on this path that no consumer could have
resolved for itself -- the text it removes was already emitted, and only a grid
is holding it.

The erase here is issued after the cursor has been moved back over the stale
tail, which is how a program that reprints a shorter line keeps the screen
honest -- and is what cargo does before each real log line."
  (cooked-tests-process--with "printf 'stale tail here\\rshort\\033[K\\n'"
    (should (equal (cooked-tests-process--body) "short"))))

(ert-deftest cooked-process-keeps-styling-out-of-the-text ()
  "SGR reaches the buffer as a property, never as characters.

The two halves of one claim, and this is the half a `compilation-mode' regexp
depends on: whatever the child said about colour, what a regexp scans is
`error: red' and not an escape sequence with `error' somewhere inside it."
  (cooked-tests-process--with "printf '\\033[31merror\\033[0m: red\\n'"
    (should (equal (cooked-tests-process--body) "error: red"))))

(defun cooked-tests-process--face-at (string)
  "The face on the first occurrence of STRING in the current buffer.

Read from `font-lock-face' rather than through `get-char-property', which is
the property `font-lock-default-unfontify-region' leaves alone and therefore
the one that survives in a buffer `compilation-mode' fontifies -- see
`cooked-process--text'.  The `face' half of the pair cannot be asserted from
here at all: `font-lock-mode' refuses to turn on under `noninteractive', so a
test that read `face' would be reporting on batch mode rather than on Emacs."
  (save-excursion
    ;; From the body, not from `point-min': the header echoes the command, so
    ;; the first `error' in the buffer is the one inside the `printf' the test
    ;; ran and carries no face whatever the child did.
    (goto-char (point-min))
    (forward-line 4)
    (when (search-forward string nil t)
      (get-text-property (match-beginning 0) 'font-lock-face))))

(ert-deftest cooked-process-carries-the-childs-colours ()
  "A rendition the child asked for arrives as a face on the same characters.

The point of the pty, half of it anyway: cargo prints a green `Compiling' and
a red `error' only when `isatty' says yes, so a file that arranges to be told
them and then drops them would have paid for the terminal and kept the
receipt."
  (cooked-tests-process--with
      "printf '\\033[1;31merror\\033[0m\\033[1m: mismatched types\\033[0m\\n'"
    (should (equal (cooked-tests-process--body) "error: mismatched types"))
    (let ((error-face (cooked-tests-process--face-at "error"))
          (message-face (cooked-tests-process--face-at ": mismatched")))
      (should (eq (plist-get error-face :weight) 'bold))
      (should (plist-get error-face :foreground))
      ;; The second run is bold with no colour of its own, so the assertion is
      ;; that the runs stayed separate: one face over both would have carried
      ;; the red across the whole line.
      (should (eq (plist-get message-face :weight) 'bold))
      (should-not (plist-get message-face :foreground)))))

(ert-deftest cooked-process-styling-survives-the-flush-at-exit ()
  "The last screenful is styled too, having come the other way out of the grid.

`cooked-process--residue' retires the tail by shrinking the grid and then reads
row 0 separately, so it is a second path to the consumer's filter and the one a
short build takes for *all* of its output.  A styled line that never scrolled
is what tells the two apart."
  (let ((cooked-process-rows 8))
    (cooked-tests-process--with "printf '\\033[32mok\\033[0m\\n'"
      (should (equal (cooked-tests-process--body) "ok"))
      (should (plist-get (cooked-tests-process--face-at "ok") :foreground)))))

(ert-deftest cooked-process-styling-can-be-turned-off ()
  "With `cooked-process-styled' nil the text arrives bare, as it used to.

Asserted because the option is the escape hatch for a consumer that would
rather own the `face' property itself, and an escape hatch nothing tests is a
claim rather than a feature."
  (let ((cooked-process-styled nil))
    (cooked-tests-process--with "printf '\\033[31merror\\033[0m: red\\n'"
      (should (equal (cooked-tests-process--body) "error: red"))
      (should-not (cooked-tests-process--face-at "error")))))

(ert-deftest cooked-process-rejoins-a-line-the-child-wrapped ()
  "A diagnostic wider than COLUMNS is one line by the time a regexp sees it.

This is the case a pty makes worse before it makes it better.  Giving the
child a terminal is what makes it wrap at all; rejoining is what stops that
from putting a newline through the middle of `error:'."
  (let ((cooked-process-columns 40))
    (cooked-tests-process--with
        "printf 'src/main.rs:12:5: error: a message far wider than the terminal is\\n'; exit 1"
      (should (equal (cooked-tests-process--errors)
                     '("src/main.rs:12:5: error: a message far wider than the terminal is"))))))

(ert-deftest cooked-process-flushes-what-never-scrolled ()
  "Output too short to reach the top of the grid still arrives, at exit.

Retirement is scrolling, so a child printing fewer lines than
`cooked-process-rows' retires nothing at all while it runs.  The flush at exit
is the whole of what makes that case work, and a build's error summary is
exactly the text it covers."
  (let ((cooked-process-rows 8))
    (cooked-tests-process--with "echo one; echo two"
      (should (equal (cooked-tests-process--body) "one\ntwo")))))

(defun cooked-tests-process--tail ()
  "The live tail\='s text in the current buffer, or nil if none is showing."
  (when-let* ((overlay (seq-find (lambda (o) (overlay-get o 'after-string))
                                 (overlays-in (point-min) (point-max)))))
    (overlay-get overlay 'after-string)))

(defmacro cooked-tests-process--while (command &rest body)
  "Run COMMAND under `cooked-process-mode\=' and evaluate BODY while it runs.

The other macro waits for the child to finish, which is exactly wrong for the
live grid: everything the tail says is gone by then, on purpose.  BODY is
evaluated in the consumer\='s buffer with the child still going, and the child
is interrupted afterwards however BODY leaves."
  (declare (indent 1))
  `(let ((cooked-process-mode nil)
         (compilation-ask-about-save nil)
         (compilation-in-progress nil)
         (compilation-buffer-name-function (lambda (_) "*cooked-test-compile*"))
         buffer)
     (unwind-protect
         (progn
           (cooked-process-mode 1)
           (setq buffer (compilation-start ,command))
           (with-current-buffer buffer
             (cooked-tests--pump 0.3)
             ,@body))
       (when (buffer-live-p buffer)
         (with-current-buffer buffer (kill-compilation))
         (cooked-tests--settle (lambda () (null (get-buffer-process buffer))) 10)
         (kill-buffer buffer))
       (cooked-process-mode -1))))

(ert-deftest cooked-process-shows-a-meter-still-on-the-grid ()
  "A bar drawn in place is visible while it is being drawn, as an overlay.

The case retirement cannot serve and never will: cargo rewrites one row with a
carriage return and erases it before every real log line, so at the instant
that row scrolls it is blank.  The bar exists only on the live grid, which is
why there is something here that reads it from there."
  (cooked-tests-process--while
      "printf 'Building [   ]\\r'; printf 'Building [==>]\\r'; sleep 30"
    (should (string-match-p "Building \\[==>\\]" (or (cooked-tests-process--tail) "")))))

(ert-deftest cooked-process-tail-is-not-buffer-text ()
  "The tail is an overlay, so nothing that parses the buffer can see it.

The whole reason it is allowed to exist in a foreign consumer\='s buffer: a
`compilation-mode\=' regexp scanning for a diagnostic must not match a frame of
a progress bar, and `next-error\=' must not be able to land in one."
  (cooked-tests-process--while
      "printf 'src/main.rs:1:1: error: half-drawn\\r'; sleep 30"
    (should (cooked-tests-process--tail))
    (should (equal (cooked-tests-process--body) ""))
    (should-not (cooked-tests-process--errors))))

(ert-deftest cooked-process-tail-adds-no-blank-line ()
  "The tail begins where the retired text left off, not a line below it.

Retired rows arrive with their newline, so `point-max\=' is already at column
zero and a newline of the tail\='s own is a blank line sitting between the
output and the bar -- for the length of the build, the tail being replaced
rather than moved.  Nine rows against a grid of eight, so something has
certainly retired by the time the tail is read."
  (let ((cooked-process-rows 8))
    (cooked-tests-process--while
        "for i in $(seq 1 9); do echo \"line $i\"; done; printf 'Building [==>]\\r'; sleep 30"
      (let ((tail (cooked-tests-process--tail)))
        (should tail)
        (should-not (string-prefix-p "\n" tail))
        ;; And the retired half kept its own newline, which is the thing a fix
        ;; that simply trimmed the prefix would have broken instead.
        (should (eq (char-before (point-max)) ?\n))))))

(ert-deftest cooked-process-tail-clears-a-half-retired-line ()
  "A drain that retired half a logical line gets the newline back.

`Update::scrolled_rows\=' withholds the newline after a row it expects to
rejoin, so the buffer can end mid-line, and the tail has to start below that
rather than welding onto the end of it.

Reaching that state takes both knobs: eighty-five columns of output at a width
of forty is three screen rows, and a grid of two means writing the third
scrolls the first away -- as a wrapped row, so without its newline -- while its
continuation is still live.  Asserted unconditionally for that reason.  Guarding
the assertion on the state having been reached is what the first version of this
test did, and it passed against a line that wrapped only once and so never ended
mid-line at all."
  (let ((cooked-process-columns 40)
        (cooked-process-rows 2)
        (wide (concat (make-string 40 ?a) (make-string 40 ?b) (make-string 5 ?c))))
    (cooked-tests-process--while
        (concat "printf '%s' '" wide "'; sleep 30")
      (should-not (eq (char-before (point-max)) ?\n))
      (should (string-prefix-p "\n" (or (cooked-tests-process--tail) ""))))))

(ert-deftest cooked-process-tail-goes-before-the-flush ()
  "At exit the tail is taken down and the same rows arrive as text, once.

Ordering, and the failure it rules out is a build ending with its last
screenful shown twice -- once as the overlay's last frame and once as the
residue the flush retires."
  (cooked-tests-process--with "echo one; echo two"
    (should-not (cooked-tests-process--tail))
    (should (equal (cooked-tests-process--body) "one\ntwo"))))

(ert-deftest cooked-process-tail-can-be-turned-off ()
  "With `cooked-process-live-tail\=' nil the buffer is only retired text."
  (let ((cooked-process-live-tail nil))
    (cooked-tests-process--while
        "printf 'Building [==>]\\r'; sleep 30"
      (should-not (cooked-tests-process--tail)))))

(ert-deftest cooked-process-reports-the-exit-code ()
  "The status is the child's, not a pipe process's idea of one."
  (cooked-tests-process--with "exit 3"
    (should (string-match-p "abnormally with code 3" (buffer-string)))))

(ert-deftest cooked-process-annotates-the-exit-once ()
  "`compilation-handle-exit' runs once, however the sentinel is reached.

It deletes the process it is handed, and a deletion runs the sentinel again --
so the naive arrangement annotates the buffer twice and the second annotation,
being the pipe's own fictional exit, always says the build succeeded."
  (cooked-tests-process--with "exit 1"
    (should (equal 1 (cl-count-if (lambda (line) (string-prefix-p "Compilation exited" line))
                                  (split-string (buffer-string) "\n"))))
    (should (equal 0 (cl-count-if (lambda (line) (string-prefix-p "Compilation finished" line))
                                  (split-string (buffer-string) "\n"))))))

(ert-deftest cooked-process-interrupts-the-process-group ()
  "`kill-compilation\=' reaches the child, and its output survives the kill.

Spelled out rather than written through the macro, which waits for the child
to finish first -- and this child is chosen not to."
  (let ((cooked-process-mode nil)
        (compilation-ask-about-save nil)
        (compilation-in-progress nil)
        (compilation-buffer-name-function (lambda (_) "*cooked-test-compile*"))
        buffer)
    (unwind-protect
        (progn
          (cooked-process-mode 1)
          (setq buffer (compilation-start "echo before; sleep 30"))
          (with-current-buffer buffer
            ;; Not waiting for "before" to appear, because it will not: one
            ;; line does not fill the grid, so nothing has retired and the
            ;; buffer is still empty when the interrupt arrives.  That it is
            ;; there afterwards is the assertion -- the flush at exit runs on
            ;; the way out of a kill exactly as it does on a clean exit.
            (cooked-tests--pump 0.3)
            (kill-compilation)
            (cooked-tests--settle (lambda () (null (get-buffer-process buffer))) 10)
            (should (string-match-p "^before$" (buffer-string)))
            (should (string-match-p "abnormally with code 130" (buffer-string)))))
      (cooked-process-mode -1)
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest cooked-process-leaves-nothing-behind ()
  "Killing the buffer mid-run takes the session, the pty and the host with it.

Nothing in Lisp needs evicting -- a headless session installs no keymap and no
hook -- but the reader thread, the two pipes and the hidden host buffer all
outlive the buffer unless something reaps them."
  (let ((cooked-process-mode nil)
        (compilation-ask-about-save nil)
        (compilation-in-progress nil)
        (before (length (process-list))))
    (unwind-protect
        (progn
          (cooked-process-mode 1)
          (let ((buffer (compilation-start "sleep 30")))
            (cooked-tests--settle (lambda () (> (length (process-list)) before)) 5)
            (should (> (length (process-list)) before))
            (kill-buffer buffer))
          (cooked-tests--settle (lambda () (eql (length (process-list)) before)) 5)
          (should (eql (length (process-list)) before))
          (should-not (seq-filter (lambda (buffer)
                                    (string-prefix-p " *cooked-process" (buffer-name buffer)))
                                  (buffer-list))))
      (cooked-process-mode -1))))

(defun cooked-tests-process--spawner ()
  "Which spawner `compilation-start' would reach at this moment."
  (if (eq (symbol-function 'start-file-process-shell-command)
          #'cooked-process-start-shell-command)
      'cooked
    'ordinary))

(ert-deftest cooked-process-declines-a-remote-directory ()
  "A remote `default-directory\=' keeps the ordinary spawner.

Not a preference: our pty is local whatever the directory says, so taking this
one would not degrade a remote compile but run a different command on a
different machine -- against the local checkout, if one sits at that path.

The advice is called directly, with a stand-in for `compilation-start\=' that
reports which spawner was in place when it ran.  Rebinding `compilation-start\='
itself would have replaced the advice along with it and asserted nothing."
  (let (reached)
    (let ((default-directory "/ssh:nowhere:/tmp/"))
      (cooked-process--around-compilation-start
       (lambda (&rest _) (setq reached (cooked-tests-process--spawner)))
       "true"))
    (should (eq reached 'ordinary))
    (let ((default-directory temporary-file-directory))
      (cooked-process--around-compilation-start
       (lambda (&rest _) (setq reached (cooked-tests-process--spawner)))
       "true"))
    (should (eq reached 'cooked))))

(ert-deftest cooked-process-declines-grep-mode ()
  "`grep-mode\=' keeps its escape sequences, which it parses rather than shows.

`grep' asks for `--color=always' and `grep-filter\=' turns the result into the
face on each match, so resolving the styling away -- the service this file
offers every other consumer -- would cost a grep buffer its highlighting."
  (let (reached)
    (let ((default-directory temporary-file-directory))
      (cooked-process--around-compilation-start
       (lambda (&rest _) (setq reached (cooked-tests-process--spawner)))
       "grep -nH x ." 'grep-mode))
    (should (eq reached 'ordinary))))

(provide 'cooked-tests-process)
;;; cooked-tests-process.el ends here
