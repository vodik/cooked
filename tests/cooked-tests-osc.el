;;; cooked-tests-osc.el --- OSC handlers and the channels they open -*- lexical-binding: t; -*-

;;; Commentary:

;; The sequences cooked answers in Lisp rather than in Rust: titles, colours,
;; notifications, the clipboard, and the OSC 51 command channel -- which is also
;; where the opt-in defaults are asserted, since every one of these is something
;; a hostile stream can send.

;;; Code:

(require 'cooked-tests-helpers)
(require 'cooked-osc-eval)

(ert-deftest cooked-osc-133-drives-the-input-state ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "stty -icanon -echo; printf '\\033]133;A\\007$ \\033]133;B\\007'; sleep 5")
    ;; Raw mode would normally mean pass-through; the shell's mark overrides it.
    (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input))))
    (should (eq cooked--mode 'raw))
    (should (cooked--input-state-p))
    (should (eq (current-local-map) cooked-input-map))))

(ert-deftest cooked-osc-handlers-are-extensible-without-rust ()
  "The point of the passthrough: a new sequence is a few lines of Lisp."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '\\033]12345;hello;there\\007'; sleep 5")
    (let* ((seen nil)
           (cooked-osc-handlers (cons (cons 12345 (lambda (parts) (setq seen parts)))
                                      cooked-osc-handlers)))
      (should (cooked-tests--settle (lambda () seen)))
      (should (equal seen '("hello" "there"))))))

(ert-deftest cooked-osc-title-reaches-the-mode-line ()
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '\\033]2;my-title\\007'; sleep 5")
    (should (cooked-tests--settle (lambda () (equal cooked--title "my-title"))))
    (should (string-match-p "my-title" (cooked--mode-line)))))

(ert-deftest cooked-notifications-are-closed-until-opted-in ()
  (with-temp-buffer
    (cooked-mode)
    (let ((cooked-allow-notifications nil))
      (should (null (cooked-tests--capturing-notifications
                      (cooked--osc-notify '("i=1" "hello"))
                      (cooked--osc-notify-777 '("notify" "t" "b"))))))))

(ert-deftest cooked-notification-arrives-once-opted-in ()
  (with-temp-buffer
    (cooked-mode)
    (let ((cooked-allow-notifications t))
      (should (equal (cooked-tests--capturing-notifications
                       (cooked--osc-notify '("i=1" "build done")))
                     '(("build done" . "")))))))

(ert-deftest cooked-notification-assembles-chunks ()
  (with-temp-buffer
    (cooked-mode)
    (let ((cooked-allow-notifications t))
      (should (equal (cooked-tests--capturing-notifications
                       (cooked--osc-notify '("i=7:d=0:p=title" "Build "))
                       (cooked--osc-notify '("i=7:d=0:p=title" "failed"))
                       (cooked--osc-notify '("i=7:p=body" "3 errors")))
                     '(("Build failed" . "3 errors"))))
      ;; The assembled notification is forgotten, not left to accumulate.
      (should (null cooked--notification-chunks)))))

(ert-deftest cooked-notifications-are-rate-limited ()
  (with-temp-buffer
    (cooked-mode)
    (let ((cooked-allow-notifications t)
          (cooked-notification-rate '(2 . 10)))
      ;; A `cat\=' of a hostile file must not be able to flood the desktop.  Driven
      ;; through the real `cooked--notify\=', since that is where the limit lives.
      (let ((raised 0))
        (cl-letf (((symbol-function 'message) (lambda (&rest _) (cl-incf raised)))
                  ((symbol-function 'notifications-notify)
                   (lambda (&rest _) (cl-incf raised))))
          (dotimes (i 5) (cooked--osc-notify (list "i=1" (format "n%d" i)))))
        (should (= raised 2)))
      (setq cooked--notification-times nil)
      (should (cooked--notification-allowed-p))
      (push (float-time) cooked--notification-times)
      (should (cooked--notification-allowed-p))
      (push (float-time) cooked--notification-times)
      (should-not (cooked--notification-allowed-p)))))

(ert-deftest cooked-notification-strips-control-characters ()
  (should (equal (cooked--notification-clean "a\e]0;evil\007b" 100) "a]0;evilb"))
  (should (equal (cooked--notification-clean "abcdef" 3) "abc")))

(ert-deftest cooked-notification-chunks-are-bounded ()
  (with-temp-buffer
    (cooked-mode)
    (let ((cooked-allow-notifications t))
      ;; A child that opens chunks and never closes them must not grow this forever.
      (dotimes (i 30)
        (cooked--osc-notify (list (format "i=%d:d=0" i) "x")))
      (should (<= (length cooked--notification-chunks)
                  (car cooked--notification-chunk-limits))))))

(ert-deftest cooked-title-stack-restores-on-pop ()
  "XTWINOPS 22/23, which `smcup'/`rmcup' send around the alternate screen."
  (cooked-tests--with-session
   '("/bin/sh" "-c"
     "printf '\\033]2;shell\\007\\033[22;0;0t\\033]2;vim\\007'; sleep 5")
   (should (cooked-tests--settle (lambda () (equal cooked--title "vim"))))
   (cooked--handle-title-stack nil)
   (should (equal cooked--title "shell"))))

(ert-deftest cooked-title-stack-is-bounded-and-survives-underflow ()
  (with-temp-buffer
    (cooked-mode)
    (setq-local cooked--title-stack nil cooked--title "last")
    ;; A child that pushes and never pops must not grow the list without bound.
    (dotimes (i 20)
      (setq-local cooked--title (number-to-string i))
      (cooked--handle-title-stack t))
    (should (= (length cooked--title-stack) cooked--title-stack-limit))
    ;; Popping past the bottom leaves the title alone rather than clearing it.
    (dotimes (_ 20) (cooked--handle-title-stack nil))
    (should cooked--title)))

(ert-deftest cooked-osc-handler-errors-do-not-break-redisplay ()
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '\\033]2;boom\\007'; printf 'after\\n'; sleep 5")
    (let ((cooked-osc-handlers '((2 . (lambda (_parts) (error "deliberate"))))))
      ;; The handler blows up, but output after it still renders.
      (should (cooked-tests--settle
               (lambda () (string-match-p "after" (cooked-tests--text))))))))

(defun cooked-tests--run-deferred ()
  "Run the timers `cooked--defer\=' queued, without leaving the current bindings.

The OSC 51;E arm hands the request to a timer rather than running it inside the
drain, so a test that asserts on the command must pump the event loop -- and
must do it *inside* the `let\=' that bound `cooked-eval-commands\=', since the
binding is dynamic and the timer reads it when it runs."
  (dotimes (_ 3) (accept-process-output nil 0.02)))

(ert-deftest cooked-osc-51-is-closed-until-opted-in ()
  "The command channel is the one place terminal output becomes action, so it
must do nothing at all until the user has loaded `cooked-osc-eval' on purpose."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let ((cooked-osc-eval-function nil)
          (ran nil))
      (let ((cooked-eval-commands `(("find-file" . ,(lambda (&rest _) (setq ran t))))))
        (cooked--osc-emacs '("E\"find-file\" \"/tmp/x\""))
        (cooked-tests--run-deferred)
        (should-not ran))
      ;; The annotation half is inert, so it keeps working without opting in.
      (cooked--osc-emacs '("Asimon@host:~"))
      (should (equal cooked--annotation "simon@host:~")))))

(ert-deftest cooked-osc-51-runs-allowlisted-commands ()
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let* ((called nil)
           (cooked-eval-commands `(("noted" . ,(lambda (&rest args) (setq called args))))))
      (cooked--osc-emacs '("E\"noted\" \"one\" \"two\""))
      (cooked-tests--run-deferred)
      (should (equal called '("one" "two"))))))

(ert-deftest cooked-osc-51-refuses-anything-not-allowlisted ()
  "The allowlist is the entire defence: output from a hostile host reaches here."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let ((cooked-eval-commands '(("find-file" . ignore)))
          (danger nil))
      (cl-letf (((symbol-function 'shell-command)
                 (lambda (&rest _) (setq danger t))))
        (cooked--osc-emacs '("E\"shell-command\" \"rm -rf /\""))
        (cooked-tests--run-deferred)
        (should-not danger))
      ;; Nor by interning a name that merely exists as a function.
      (cl-letf (((symbol-function 'delete-file)
                 (lambda (&rest _) (setq danger t))))
        (cooked--osc-emacs '("E\"delete-file\" \"/tmp/x\""))
        (cooked-tests--run-deferred)
        (should-not danger)))))

(ert-deftest cooked-osc-51-does-not-run-shell-commands-by-default ()
  "`compile' would turn any terminal output into arbitrary execution."
  (should-not (assoc "compile" cooked-eval-commands))
  (should-not (assoc "recompile" cooked-eval-commands)))

(ert-deftest cooked-osc-51-rejoins-payloads-split-on-semicolons ()
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let* ((got nil)
           (cooked-eval-commands `(("open" . ,(lambda (path) (setq got path))))))
      ;; The emulator split this into two parts; the handler must put it back.
      (cooked--osc-emacs '("E\"open\" \"/tmp/a" "b\""))
      (cooked-tests--run-deferred)
      (should (equal got "/tmp/a;b")))))

(ert-deftest cooked-osc-51-annotation-is-recorded ()
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (cooked--osc-emacs '("Asimon@ryzen:~/src"))
    (should (equal cooked--annotation "simon@ryzen:~/src"))))

(defun cooked-tests--pump-wakes (predicate &optional seconds)
  "Pump the event loop until PREDICATE holds or SECONDS elapse.

Unlike `cooked-tests--settle\=', this never calls `cooked--apply\=' itself: the
wake filter has to drive `cooked--drain-and-apply\=' for the drain's own
bookkeeping -- `cooked--draining\=' and the `unwind-protect\=' that clears it --
to be under test at all."
  (let ((deadline (+ (float-time) (or seconds 5))))
    (while (and (< (float-time) deadline) (not (funcall predicate)))
      (accept-process-output nil 0.05))
    (funcall predicate)))

(ert-deftest cooked-osc-51-find-file-does-not-strand-the-drain ()
  "A command that switches buffers must not take the drain with it.

The regression the stubbed end-to-end test below could never catch, because its
stub only records its argument: the *real* `find-file\=' calls
`switch-to-buffer\=', and when that happened from inside `cooked--handle-osc\='
the rest of `cooked--apply\=' ran against the file buffer, signalled on its nil
`cooked--screen-start\=', and `cooked--drain-and-apply\=''s cleanup cleared
`cooked--draining\=' *there* -- leaving this buffer draining for good, so nothing
it printed afterwards ever appeared again."
  (let ((target (make-temp-file "cooked-open" nil ".txt" "opened by the child\n"))
        (terminal nil))
    (unwind-protect
        (cooked-tests--with-session
            (list "/bin/sh" "-c"
                  (format "printf 'BEFORE\\n'; printf '\\033]51;E\"find-file\" \"%s\"\\033\\\\'; \
sleep 0.3; printf 'LATER\\n'; sleep 5"
                          target))
          (setq terminal (current-buffer))
          (should (cooked-tests--pump-wakes (lambda () (find-buffer-visiting target)) 8))
          ;; The buffer the child asked for really opened -- otherwise everything
          ;; below passes for the wrong reason.
          (should (find-buffer-visiting target))
          (should (eq (current-buffer) terminal))
          ;; The drain that carried the request finished in this buffer.
          (should-not cooked--draining)
          (should-not cooked--drain-pending)
          (should (cooked--screen-start-position))
          ;; ...and the session is still alive: output after the request renders.
          (should (cooked-tests--pump-wakes
                   (lambda () (string-match-p "LATER" (cooked-tests--text))) 8)))
      (when-let* ((visiting (find-buffer-visiting target)))
        (kill-buffer visiting))
      (delete-file target))))

(ert-deftest cooked-osc-handler-that-relocates-does-not-strand-the-drain ()
  "The containment `cooked--handle-osc\=' owes every handler, not just OSC 51.

Handlers are an extension point run mid-drain, so one that switches buffers and
forgets to switch back must cost nothing beyond its own confusion."
  (let ((elsewhere (generate-new-buffer "*cooked-elsewhere*")))
    (unwind-protect
        (cooked-tests--with-session
            '("/bin/sh" "-c" "printf '\\033]12345;go\\007'; sleep 0.3; printf 'AFTER\\n'; sleep 5")
          (let* ((terminal (current-buffer))
                 (seen nil)
                 (cooked-osc-handlers
                  (cons (cons 12345 (lambda (_parts)
                                      (setq seen t)
                                      (set-buffer elsewhere)))
                        cooked-osc-handlers)))
            (should (cooked-tests--pump-wakes (lambda () seen) 8))
            (should (eq (current-buffer) terminal))
            (should-not cooked--draining)
            (should (cooked--screen-start-position))
            (should (cooked-tests--pump-wakes
                     (lambda () (string-match-p "AFTER" (cooked-tests--text))) 8))))
      (kill-buffer elsewhere))))

(ert-deftest cooked-osc-51-find-file-leaves-point-at-the-new-prompt ()
  "Point ends on the prompt the command returned to, not on the line below it.

`find-file' takes the terminal's own window, so the buffer is off screen while
the shell prints its next prompt -- and the window point Emacs recorded on the
way out is a marker every drain since has been dragging.  Restoring it on the
way back put point one line below the new prompt and, because that is outside
the input region, `cooked--track-wandering' then pinned it there.

Batch runs no redisplay and no command loop, so the two hooks that would notice
are called here where Emacs would call them: `cooked--update-attention' from
`window-buffer-change-functions', and `cooked--track-wandering' from
`post-command-hook'."
  (skip-unless (executable-find "zsh"))
  (let ((buffer (generate-new-buffer "*cooked-zsh*"))
        (target (make-temp-file "cooked-open" nil ".txt" "opened by the child\n")))
    (unwind-protect
        (progn
          (switch-to-buffer buffer)
          (with-current-buffer buffer
            (cooked-mode)
            (pcase-let ((`(,argv ,env ,_scratch) (cooked--shell-invocation (executable-find "zsh"))))
              (cooked--start argv nil env))
            (cooked--refresh-keymap)
            (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input)) 8)))
          (cooked--update-attention)
          (with-current-buffer buffer
            (cooked--replace-input (format "find_file %s" target))
            (cooked-send-input)
            (cooked--track-wandering))
          (cooked--update-attention)
          ;; The deferred `find-file' takes the window, and the next prompt is
          ;; drained into a buffer nobody is looking at.
          (should (cooked-tests--pump-wakes (lambda () (find-buffer-visiting target)) 8))
          (cooked--update-attention)
          ;; Two prompts and no more: the one the command was typed at, and the
          ;; one it returned to.  `cooked-tests--prompt' rather than a literal,
          ;; which would be this test quietly asserting something about the
          ;; prompt of whoever ran it.
          (should (cooked-tests--pump-wakes
                   (lambda () (with-current-buffer buffer
                                (equal 2 (length (split-string (cooked-tests--text)
                                                               (regexp-quote cooked-tests--prompt))))))
                   2))
          ;; ...and the user closes it again, which is the report's `:bd'.
          (kill-buffer (find-buffer-visiting target))
          (cooked--update-attention)
          (with-current-buffer buffer
            (should (eq (window-buffer (selected-window)) buffer))
            (should (cooked--input-start-position))
            (should (= (point) (cooked--input-start-position)))
            (should (= (line-number-at-pos (point))
                       (line-number-at-pos (cooked--input-start-position))))
            ;; Nothing to pin, so nothing sticks: the next command leaves
            ;; `cooked--wandered' clear rather than fixing point to the stale line.
            (cooked--track-wandering)
            (should-not cooked--wandered)))
      (when-let* ((visiting (find-buffer-visiting target)))
        (kill-buffer visiting))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer)
      (delete-file target))))

(ert-deftest cooked-find-file-works-end-to-end-from-the-shell ()
  "The headline trick: a shell function opens a buffer in the Emacs running it."
  (skip-unless (executable-find "zsh"))
  (let ((buffer (generate-new-buffer "*cooked-zsh*"))
        (target (make-temp-file "cooked-open")))
    (unwind-protect
        (with-current-buffer buffer
          (cooked-mode)
          (pcase-let ((`(,argv ,env ,_scratch) (cooked--shell-invocation (executable-find "zsh"))))
            (cooked--start argv nil env))
          (cooked--refresh-keymap)
          (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input))))
          (let ((opened nil))
            (let ((cooked-eval-commands `(("find-file" . ,(lambda (f) (setq opened f))))))
              (cooked--replace-input (format "find_file %s" target))
              (cooked-send-input)
              (should (cooked-tests--settle (lambda () opened) 8))
              (should (equal opened target)))))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer)
      (delete-file target))))

(ert-deftest cooked-comint-markers-follow-the-osc-133-marks ()
  "comint brackets the last input with `comint-last-input-start\='/`-end\=', and
its whole output family measures from them.  They sat at `point-min\=' until the
shell\='s own marks started feeding them -- which is why `comint-delete-output\='
used to flush the entire buffer."
  (skip-unless (executable-find "zsh"))
  (let ((buffer (generate-new-buffer "*cooked-zsh*")))
    (unwind-protect
        (with-current-buffer buffer
          (cooked-mode)
          (pcase-let ((`(,argv ,env ,_scratch) (cooked--shell-invocation (executable-find "zsh"))))
            (cooked--start argv nil env))
          (cooked--refresh-keymap)
          (should (cooked-tests--settle
                   (lambda () (and (eq cooked--semantic 'input)
                                   (cooked--input-start-position)))
                   8))
          (cooked--replace-input "echo alpha")
          (cooked-send-input)
          (should (cooked-tests--settle (lambda () cooked--commands) 8))
          (let ((command (car cooked--commands)))
            ;; The command line is recovered from the marks, not from a prompt regexp.
            (should (equal (cooked--command-input command) "echo alpha"))
            (goto-char (cooked--command-start-position command))
            (should (equal (cooked--get-old-input) "echo alpha"))
            ;; ...and the output really is bracketed, rather than starting at point-min.
            (should (> (cooked--command-start-position command) (point-min)))
            (should (string-match-p
                     "alpha"
                     (buffer-substring-no-properties
                      (cooked--command-start-position command)
                      (cooked--command-end-position command))))))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer))))

(defun cooked-tests--prompt-texts ()
  "Each recorded command\='s input, paired with the text its prompt region holds.

The prompt region is the marker the `A\=' mark left through to where the `C\=' mark
says the output began -- which is the prompt as drawn plus the command line
typed at it, and nothing else.  Newlines are dropped because a narrow enough
width wraps that region across several rows, and a row boundary inside it is a
fact about the width rather than about whether the marker is still right."
  (mapcar (lambda (command)
            (let ((at (cooked--command-prompt-position command))
                  (to (cooked--command-start-position command)))
              (cons (cooked-command-input command)
                    (and at to (<= at to)
                         (string-replace
                          "\n" ""
                          (buffer-substring-no-properties at to))))))
          cooked--commands))

(defun cooked-tests--prompts-still-match-p ()
  "Whether every recorded command\='s prompt marker still names its own prompt.

Two conditions, and the second is what catches the reported drift: the marker
sits at the start of a buffer line, as column 0 of a prompt\='s first row does,
and the region it opens ends with that command\='s own input.  A marker that slid
onto a neighbouring command fails the second; one that slid into the middle of a
row fails the first."
  (and (seq-every-p (lambda (command)
                      (let ((at (cooked--command-prompt-position command)))
                        (and at
                             (save-excursion
                               (goto-char at)
                               (= at (line-beginning-position))))))
                    cooked--commands)
       (seq-every-p (lambda (pair)
                      (and (cdr pair) (string-suffix-p (car pair) (cdr pair))))
                    (cooked-tests--prompt-texts))))

(ert-deftest cooked-command-records-survive-a-resize ()
  "The reported bug: resizing desyncs the fringe markers from their prompt lines.

Not a decorations bug -- the markers paint exactly where `cooked--commands\=' says
-- and not confined to them: `next-error\=', `cooked-previous-command\=', sticky
scroll and evil\='s command text objects all read the same records.  A rewrap
re-lays every logical line at the new width and Emacs rebuilds every live row
from it, which leaves markers taken from the original anchors naming text that
has moved.  A scroll never does this, which is why it went unnoticed: rows leave
the top and the buffer above grows by exactly what left.

The emulator now keeps each mark on its cell and reports the ones a rewrap moved;
see `cooked--relocate-marks\='."
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-zsh
    (dolist (input '("echo alpha" "echo beta" "echo gamma"))
      (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input)) 8))
      (cooked--send-input-string input)
      (should (cooked-tests--settle
               (lambda () (string-match-p (substring input 5) (cooked-tests--text)))
               8)))
    (should (= 3 (length cooked--commands)))
    (should (cooked-tests--prompts-still-match-p))
    ;; Narrower, which is the case that rewraps and used to drift every record.
    (cooked-tests--resize 24 40)
    (should (cooked-tests--prompts-still-match-p))
    ;; And back out again: the rewrap round-trips, so the records have to as well.
    (cooked-tests--resize 24 100)
    (should (cooked-tests--prompts-still-match-p))))

(ert-deftest cooked-command-records-survive-their-own-output-scrolling ()
  "The second half of the same report: the markers drift as the scrollback moves.

Smaller than the resize case and reached without touching the frame.  A row
that leaves the live screen is *re-rendered* into the scrollback above it while
the rows below move up a slot, and the two renderings differ whenever
`cooked-rejoin-wrapped-lines\=' withholds the newline from a continuation row --
so every live position slides by one per wrapped row evicted, and a command
printing wrapped output walks its own prompt marker away from its prompt.

Output wider than the screen is what makes it wrapped, so the width here is
load-bearing: at 20 columns each of these lines is two rows, the second a
continuation."
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-zsh
    (cooked-tests--resize 8 20)
    (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input)) 8))
    (cooked--send-input-string "echo one")
    (should (cooked-tests--settle
             (lambda () (string-match-p "one" (cooked-tests--text))) 8))
    (should (cooked-tests--prompts-still-match-p))
    ;; Enough wrapped output to push that prompt off the live screen and well into
    ;; the scrollback, one eviction at a time.
    (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input)) 8))
    (cooked--send-input-string
     "for i in 1 2 3 4 5 6 7 8; do echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaa; done")
    (should (cooked-tests--settle
             (lambda () (and (eq cooked--semantic 'input)
                             (= 2 (length cooked--commands))))
             8))
    (should (cooked-tests--prompts-still-match-p))))

(ert-deftest cooked-a-record-whose-rows-a-resize-evicts-keeps-its-marker ()
  "A rewrap narrow and short enough pushes rows off the top, and a mark on one of
them is in text Emacs is about to *insert* rather than on a row it is about to
rewrite.  Both spellings come through `cooked--anchor-position\=', so the records
that end up in scrollback and the ones still on the live screen are right
together."
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-zsh
    (dolist (input '("echo alpha" "echo beta" "echo gamma"))
      (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input)) 8))
      (cooked--send-input-string input)
      (should (cooked-tests--settle
               (lambda () (string-match-p (substring input 5) (cooked-tests--text)))
               8)))
    (cooked-tests--resize 6 30)
    (should (cooked-tests--prompts-still-match-p))
    ;; The oldest records are below the seam now, which is the half a rewrap never
    ;; touches -- and the newest is above it, which is the half it re-lays.
    (should (< (cooked--command-prompt-position (car (last cooked--commands)))
               (cooked--screen-start-position)))))

(ert-deftest cooked-command-records-survive-a-refresh ()
  "`cooked-refresh\=' deletes the whole screen region and has the emulator re-send
it, which collapses every marker Emacs holds into that text -- the rows coming
back identical is no help, since it was the delete that destroyed them.  So the
redraw reports its marks the same way a resize does."
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-zsh
    (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input)) 8))
    (cooked--send-input-string "echo delta")
    (should (cooked-tests--settle
             (lambda () (string-match-p "delta" (cooked-tests--text))) 8))
    (should (cooked-tests--prompts-still-match-p))
    (cooked-refresh)
    (should (cooked-tests--settle
             (lambda () (string-match-p "delta" (cooked-tests--text))) 8))
    (should (cooked-tests--prompts-still-match-p))))

(ert-deftest cooked-marks-are-forgotten-once-they-reach-scrollback ()
  "The relocation index is not a second copy of the transcript.  A mark below
`cooked--screen-start\=' is on a row the emulator handed over and will never
mention again, so `cooked--render-scrolled\=' drops it -- which keeps the table at
the handful of marks the live screen carries rather than four per command of the
session.  The records keep their markers; what goes is the ability to relocate
them, which nothing will ask for."
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-zsh
    (cooked--replace-input "seq 1 200")
    (cooked-send-input)
    (should (cooked-tests--settle
             (lambda () (and cooked--commands
                             (> (cooked--screen-start-position) 1)))
             8))
    (should (< (hash-table-count cooked--marks) 8))
    ;; And the record that outlived them is intact, marker and all.
    (should (cooked--command-prompt-position (car cooked--commands)))))

(ert-deftest cooked-the-prompt-a-command-was-typed-at-is-recorded ()
  "The OSC 133 `A' mark says where the prompt begins, and used to be thrown
away for a flag.  It is what `cooked-previous-command' lands on and where the
outer half of an `evil' command text object starts, and no regexp can recover
it: a prompt is whatever the user's theme decided to draw."
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-zsh
    (cooked--replace-input "echo alpha")
    (cooked-send-input)
    (should (cooked-tests--settle (lambda () cooked--commands) 8))
    (let* ((command (car cooked--commands))
           (prompt (cooked--command-prompt-position command)))
      (should prompt)
      ;; Column 0 of the prompt's own first row, and the line it names is the
      ;; one the command was typed on.
      (should (= prompt (save-excursion (goto-char prompt) (line-beginning-position))))
      (should (string-suffix-p
               "echo alpha"
               (buffer-substring-no-properties
                prompt (save-excursion (goto-char prompt) (line-end-position)))))
      ;; And it is above the output, which is what makes the outer region a
      ;; superset of the inner one.
      (should (< prompt (cooked--command-start-position command))))))

(ert-deftest cooked-delete-output-removes-rows-through-the-emulator ()
  "The grid owns the rows, so deleting output asks the emulator and repaints,
rather than cutting buffer text the grid would still hold.  The check that
matters is that both ends still agree afterwards: a `cooked-refresh\=', which
rebuilds the buffer from the grid alone, must not bring the output back."
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-zsh
    (cooked--replace-input "echo alpha")
    (cooked-send-input)
    (should (cooked-tests--settle
             (lambda () (and cooked--commands
                             (string-match-p "alpha" (cooked-tests--text))))
             8))
    ;; Wait for the next prompt, so the output is no longer the child's row.
    (should (cooked-tests--settle
             (lambda () (and (eq cooked--semantic 'input)
                             (cooked--input-start-position)))
             8))
    ;; The echoed command line stays; only the output row goes.
    (should (string-match-p "^alpha$" (cooked-tests--text)))
    (goto-char (cooked--command-start-position (car cooked--commands)))
    (cooked-delete-output)
    (should-not (string-match-p "^alpha$" (cooked-tests--text)))
    (should (string-match-p "echo alpha" (cooked-tests--text)))
    ;; The emulator really let go of the row, rather than Emacs hiding it:
    ;; `cooked-refresh' rebuilds the buffer from the grid and nothing else.
    (cooked-refresh)
    (should (cooked-tests--settle
             (lambda () (not (string-match-p "^alpha$" (cooked-tests--text)))) 8))
    (should (string-match-p "echo alpha" (cooked-tests--text)))))

(ert-deftest cooked-delete-output-reaches-output-that-has-scrolled-off ()
  "The case worth having it for: a long build log is exactly the output you want
gone, and exactly the output that has left the grid.  Each half has one owner --
the emulator removes the rows it still holds, Emacs deletes the scrollback it
owns outright -- and the seam bookkeeping is only owed when the cut reaches it."
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-zsh
    ;; More lines than the grid is tall, so most of it scrolls into scrollback.
    (cooked--replace-input "seq 1 60")
    (cooked-send-input)
    ;; Two waits, not one.  The output arriving and the next prompt arriving are
    ;; separate events, and a single predicate over both reports whichever came
    ;; last while saying nothing about the other -- so a failure here would name
    ;; the wrong one.  Wait for the text first, then for the prompt that means the
    ;; rows are no longer the child's to redraw.
    (should (cooked-tests--settle
             (lambda () (and cooked--commands
                             (string-match-p "^60$" (cooked-tests--text))))
             10))
    (should (cooked-tests--settle
             (lambda () (and (eq cooked--semantic 'input)
                             (cooked--input-start-position)))
             10))
    (should (string-match-p "^42$" (cooked-tests--text)))
    ;; It really did straddle: some of it is above the live screen.
    (let ((command (car cooked--commands)))
      (should (< (cooked--command-start-position command)
                 (cooked--screen-start-position)))
      (goto-char (cooked--command-start-position command))
      (cooked-delete-output))
    (should-not (string-match-p "^42$" (cooked-tests--text)))
    ;; The two ends still agree: this rebuilds the screen from the grid alone,
    ;; and the emulator is still told how much of its top row Emacs holds.
    (cooked-refresh)
    (should (cooked-tests--settle
             (lambda () (not (string-match-p "^42$" (cooked-tests--text)))) 8))
    (let ((cooked-debug t))
      (should (cooked-tests--settle
               (lambda () (progn (cooked--drain-and-apply) t)) 4)))))

(ert-deftest cooked-delete-output-refuses-the-row-the-child-is-on ()
  "Below the child\='s cursor the shell is editing its own prompt line and
tracking where it sits; moving it would corrupt a redisplay cooked cannot see."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'ready$ '; exec cat")
    (should (cooked-tests--settle #'cooked--input-start-position))
    (setq cooked--commands
          (list (cooked--command-make
                 :start (copy-marker (point-min))
                 :end (copy-marker (point-max))
                 :code 0)))
    (goto-char (point-min))
    (should-error (cooked-delete-output) :type 'user-error)))

(ert-deftest cooked-osc-52-copies-to-the-kill-ring ()
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '\\033]52;c;aGVsbG8gd29ybGQ=\\007'; sleep 5")
    (let ((kill-ring nil))
      (should (cooked-tests--settle
               (lambda () (equal (car kill-ring) "hello world")))))))

(ert-deftest cooked-osc-52-never-answers-a-read ()
  "Replying to a query would hand the clipboard to whatever asked."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let ((kill-ring '("secret")))
      (cooked--osc-clipboard '("c" "?"))
      ;; Nothing added, and nothing written back to the child.
      (should (equal kill-ring '("secret"))))))

(ert-deftest cooked-osc-52-can-be-refused-entirely ()
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let ((cooked-clipboard-write nil)
          (kill-ring nil))
      (cooked--osc-clipboard '("c" "aGVsbG8="))
      (should-not kill-ring))))

(ert-deftest cooked-osc-11-answers-a-background-query ()
  "Theme-aware programs block on this before picking a light or dark palette,
so a terminal that never answers costs them their whole timeout on startup."
  (let ((out (make-temp-file "cooked-osc11")))
    (unwind-protect
        (cooked-tests--with-session (cooked-tests--reply-to "\\033]11;?\\007" out)
          (should (cooked-tests--settle
                   (lambda () (string-match-p "rgb:" (cooked-tests--contents out)))))
          (should (string-match-p
                   "\\`\033\\]11;rgb:[0-9a-f]\\{4\\}/[0-9a-f]\\{4\\}/[0-9a-f]\\{4\\}\007\\'"
                   (cooked-tests--contents out))))
      (delete-file out))))

(ert-deftest cooked-osc-color-reply-echoes-the-terminator-it-was-asked-with ()
  "A client that queried with ST does not recognise a BEL-terminated answer."
  (let ((out (make-temp-file "cooked-osc10")))
    (unwind-protect
        (cooked-tests--with-session (cooked-tests--reply-to "\\033]10;?\\033\\\\" out)
          (should (cooked-tests--settle
                   (lambda () (string-match-p "rgb:" (cooked-tests--contents out)))))
          (should (string-suffix-p "\033\\" (cooked-tests--contents out)))
          (should (string-prefix-p "\033]10;rgb:" (cooked-tests--contents out))))
      (delete-file out))))

(ert-deftest cooked-osc-color-answers-each-part-of-a-chained-query ()
  "`ESC ] 10 ; ? ; ? ST' asks for the foreground and then the background."
  (let ((out (make-temp-file "cooked-osc-chain")))
    (unwind-protect
        (cooked-tests--with-session (cooked-tests--reply-to "\\033]10;?;?\\007" out)
          (should (cooked-tests--settle
                   (lambda () (string-match-p "11;rgb:" (cooked-tests--contents out)))))
          (should (string-match-p "\\`\033\\]10;rgb:[^\007]+\007\033\\]11;rgb:"
                                  (cooked-tests--contents out))))
      (delete-file out))))

(ert-deftest cooked-osc-color-sets-are-refused-by-default ()
  "Anything that can write to the terminal can send one, so it is opt-in."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let ((cooked--osc-code 11)
          (cooked--osc-bell-terminated t))
      (cooked--osc-color '("#ff0000"))
      (should-not cooked--color-remaps)
      (let ((cooked-allow-color-set t))
        (cooked--osc-color '("#ff0000"))
        (should (alist-get 'background cooked--color-remaps))
        ;; Buffer-local, not frame-wide: the child repaints its own terminal only.
        (should (member '(:background "#ff0000")
                        (alist-get 'default face-remapping-alist))))
      ;; OSC 111 puts the theme's own background back.
      (let ((cooked--osc-code 111))
        (cooked--osc-color-reset nil))
      (should-not cooked--color-remaps))))

(ert-deftest cooked-osc-color-parses-the-xterm-spellings ()
  "Channels are scaled by width, not zero-padded: rgb:f/f/f is white."
  (should (equal (cooked--parse-osc-color "rgb:ffff/0000/0000") "#ffff00000000"))
  (should (equal (cooked--parse-osc-color "rgb:f/0/0") "#ffff00000000"))
  (should (equal (cooked--parse-osc-color "#ff0000") "#ff0000"))
  (should-not (cooked--parse-osc-color "rgb:fffff/0/0"))
  (should-not (cooked--parse-osc-color "not-a-color")))

(ert-deftest cooked-child-erase-scrollback-is-honored ()
  "`CSI 3 J' is the tail of what `clear' sends, and it is the half that actually
empties the buffer -- the `2 J' before it archives the screen rather than losing
it.  Unlike `2 J', real xterm's `3 J' never touches the visible screen either,
only the scrollback."
  (cooked-tests--with-session (list "/bin/sh" "-c" cooked-tests--erase-scrollback-script)
    (should (cooked-tests--settle
             (lambda () (string-match-p "line60" (cooked-tests--text)))))
    (should (string-match-p "line1\n" (cooked-tests--text)))
    (should (cooked-tests--settle
             (lambda () (not (string-match-p "line1\n" (cooked-tests--text))))
             3))
    ;; The live screen is untouched: real xterm's `3 J' never erases it.
    (should (string-match-p "line60" (cooked-tests--text)))))

(provide 'cooked-tests-osc)
;;; cooked-tests-osc.el ends here
