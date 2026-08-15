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
    ;; `cooked-debug' back off against the fixture's binding: this is a test of
    ;; the containment in `cooked--handle-osc', and under debug that containment
    ;; re-signals by design -- which would put the deliberate error into the
    ;; process filter and end the batch run rather than fail one test.
    (let ((cooked-debug nil)
          (cooked-osc-handlers '((2 . (lambda (_parts) (error "deliberate"))))))
      ;; The handler blows up, but output after it still renders.
      (should (cooked-tests--settle
               (lambda () (string-match-p "after" (cooked-tests--text))))))))

(defun cooked-tests--run-deferred ()
  "Run the timers `cooked--defer\=' queued, without leaving the current bindings.

The OSC 51;E arm hands the request to a timer rather than running it inside the
drain, so a test that asserts on the command must pump the event loop -- and
must do it *inside* the `let\=' that bound whatever it is asserting on -- those
bindings are dynamic, and the timer reads them when it runs rather than when the
request arrived."
  (dotimes (_ 3) (accept-process-output nil 0.02)))

(ert-deftest cooked-osc-51-is-closed-until-opted-in ()
  "The command channel is the one place terminal output becomes action, so it
must do nothing at all until the user has loaded `cooked-osc-eval' on purpose."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let ((cooked-osc-eval-functions nil)
          (visited nil))
      (cl-letf (((symbol-function 'find-file) (lambda (f) (setq visited f))))
        (cooked--osc-emacs '("E1" "F" "/tmp/x"))
        (cooked-tests--run-deferred)
        (should-not visited)))))

(ert-deftest cooked-osc-51-runs-the-fixed-verbs ()
  "The closed set, each reached the way the emulator delivers it: split on `;'."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let ((visited nil) (other nil) (dir nil) (cleared nil))
      (cl-letf (((symbol-function 'find-file) (lambda (f) (setq visited f)))
                ((symbol-function 'find-file-other-window) (lambda (f) (setq other f)))
                ((symbol-function 'dired) (lambda (f) (setq dir f)))
                ((symbol-function 'cooked-clear-scrollback) (lambda () (setq cleared t))))
        (cooked--osc-emacs '("E1" "F" "/tmp/one"))
        (cooked--osc-emacs '("E1" "O" "/tmp/two"))
        (cooked--osc-emacs '("E1" "D" "/tmp/three"))
        (cooked--osc-emacs '("E1" "K"))
        (cooked-tests--run-deferred)
        (should (equal visited "/tmp/one"))
        (should (equal other "/tmp/two"))
        (should (equal dir "/tmp/three"))
        (should cleared)))))

(ert-deftest cooked-osc-51-takes-its-argument-verbatim ()
  "Every fixed verb takes exactly one argument, so there is nothing to quote and
a path may contain the separator and the quote character alike."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let ((visited nil))
      (cl-letf (((symbol-function 'find-file) (lambda (f) (setq visited f))))
        ;; The emulator split this into three parts; the handler must put it back
        ;; without treating any of it as syntax.
        (cooked--osc-emacs '("E1" "F" "/tmp/a" "b" "c\"d"))
        (cooked-tests--run-deferred)
        (should (equal visited "/tmp/a;b;c\"d"))))))

(ert-deftest cooked-osc-51-declines-a-protocol-version-it-does-not-speak ()
  "Version before verb, so a newer shell snippet is declined rather than
half-understood by an older Emacs."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let ((visited nil))
      (cl-letf (((symbol-function 'find-file) (lambda (f) (setq visited f))))
        (cooked--osc-emacs '("E2" "F" "/tmp/x"))
        (cooked-tests--run-deferred)
        (should-not visited)))))

(ert-deftest cooked-osc-51-ignores-a-verb-it-does-not-have ()
  "An unknown verb is refused with a message rather than signalled: this runs from
a timer the drain queued, where an error is a backtrace nobody asked for."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let ((visited nil))
      (cl-letf (((symbol-function 'find-file) (lambda (f) (setq visited f))))
        (cooked--osc-emacs '("E1" "Z" "/tmp/x"))
        (cooked-tests--run-deferred)
        (should-not visited))
      ;; The channel is still usable afterwards: a bad verb is refused, not fatal.
      (cl-letf (((symbol-function 'find-file) (lambda (f) (setq visited f))))
        (cooked--osc-emacs '("E1" "F" "/tmp/after"))
        (cooked-tests--run-deferred)
        (should (equal visited "/tmp/after"))))))

(ert-deftest cooked-osc-51-refuses-a-remote-file-name ()
  "The path is an argument the sender chose, and under TRAMP visiting one dials
out to a host of their choosing."
  (let ((visited nil))
    (cl-letf (((symbol-function 'find-file) (lambda (f) (setq visited f))))
      (cooked-osc-eval-visit-file "/ssh:evil.example:/etc/motd")
      (should-not visited)
      (cooked-osc-eval-visit-file "/sudo::/etc/shadow")
      (should-not visited)
      ;; A local name still goes through, or the guard would just be a way of
      ;; doing nothing.
      (cooked-osc-eval-visit-file "/tmp/local-file")
      (should (equal visited "/tmp/local-file")))))

(ert-deftest cooked-osc-51-refuses-a-remote-name-through-the-whole-channel ()
  "End to end, in the shape a hostile file would send it."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let ((visited nil))
      (cl-letf (((symbol-function 'find-file) (lambda (f) (setq visited f))))
        (cooked--osc-emacs '("E1" "F" "/ssh:evil.example:/etc/motd"))
        (cooked-tests--run-deferred)
        (should-not visited)))))

(ert-deftest cooked-osc-7-refuses-a-remote-directory-before-asking-about-it ()
  "`file-directory-p\=' on a remote name is itself the connection, so the check
has to come first rather than second -- and OSC 7 is always on, with no `require'
in front of it, which makes this the one that matters most."
  ;; Resolving a remote name autoloads TRAMP, which asks about directories of its
  ;; own while loading.  Do that here, so what the instrumented call below counts
  ;; is ours.
  (file-remote-p "/ssh:example:/tmp")
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let ((default-directory "/tmp/")
          (asked nil))
      (cl-letf (((symbol-function 'file-directory-p)
                 (lambda (&rest _) (setq asked t) t)))
        (cooked--osc-cwd '("file:///ssh:evil.example:/tmp"))
        (should-not asked)
        (should (equal default-directory "/tmp/"))
        ;; A local one still lands, so the guard is not just a way of doing nothing.
        (cooked--osc-cwd '("file:///tmp/somewhere"))
        (should (equal default-directory "/tmp/somewhere/"))))))

(ert-deftest cooked-osc-7-keeps-a-foreign-host-out-of-default-directory ()
  "The authority half of the OSC 7 URL used to be matched and thrown away.

Throwing it away is what makes the remote case dangerous rather than merely
useless: after an `ssh\=' the far shell reports its directory perfectly
honestly, and a tree kept in step with the local one turns that honest report
into a local path that exists.  So a foreign host has to stop at
`cooked--host\=', leaving `default-directory\=' where it was."
  (let* ((here (make-temp-file "cooked-osc7-" t))
         (there (file-name-as-directory here)))
    (unwind-protect
        (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
          (let ((default-directory "/tmp/"))
            (cooked--osc-cwd (list (format "file://%s%s" (system-name) here)))
            (should-not (cooked--foreign-host-p))
            (should (equal default-directory there))
            ;; The short spelling of this machine is still this machine.
            (cooked--osc-cwd
             (list (format "file://%s/tmp" (car (split-string (system-name) "\\.")))))
            (should-not (cooked--foreign-host-p))
            (should (equal default-directory "/tmp/"))
            ;; An empty authority is the conventional `localhost'.
            (cooked--osc-cwd (list (format "file://%s" here)))
            (should-not (cooked--foreign-host-p))
            (should (equal default-directory there))
            ;; And somewhere else stops at the host, leaving the last directory
            ;; we could actually vouch for in place.
            (cooked--osc-cwd '("file://other.example/tmp"))
            (should (cooked--foreign-host-p))
            (should (equal default-directory there))))
      (delete-directory here t))))

(ert-deftest cooked-osc-7-decodes-a-percent-in-the-path ()
  "The path half of an OSC 7 URL is percent-encoded, and has to be decoded as one.

A directory literally called `100%20cake\=' is reported as `100%2520cake\=', and
anything that skipped the decoding would land in `100%20cake\=' -- the right
answer by accident.  The reverse is the bug that was there: cooked\='s own
snippets sent the path raw while this decoded it, so that directory arrived as
`100 cake\=', which does not exist, and tracking stopped without a word."
  (let* ((parent (make-temp-file "cooked-osc7-" t))
         (awkward (expand-file-name "100%20cake" parent)))
    (unwind-protect
        (progn
          (make-directory awkward)
          (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
            (let ((default-directory "/tmp/"))
              (cooked--osc-cwd
               (list (concat "file://" (system-name)
                             (replace-regexp-in-string "%" "%25" awkward t t))))
              (should (equal default-directory (file-name-as-directory awkward))))))
      (delete-directory parent t))))

(ert-deftest cooked-command-start-takes-the-shells-own-command-line ()
  "`OSC 133;C;cmdline_url=\=' is the shell saying what it is about to run.

It is the only account of the command in every case where Emacs has none -- a
prompt whose line the shell kept, the far end of an `ssh\=', a `no-input-mark\='
session -- where the record used to carry nothing at all.  Percent-encoded
because kitty\='s older `cmdline=\=' spelling holds `printf %q\=' output, which
only the shell that wrote it can undo."
  (cooked-tests--with-session
      (cooked-tests--marks
       (concat "\\033]133;A\\007$ \\033]133;B\\007"
               ;; `%%' because the script is a `printf' format; the shell writes
               ;; one `%' per pair and the mark on the wire is `%20' and `%22'.
               "\\033]133;C;cmdline_url=echo%%20%%22hi%%20there%%22\\007out\\r\\n"
               "\\033]133;D;0\\007"))
    (should (cooked-tests--settle (lambda () cooked--commands) 8))
    (should (equal (cooked-command-input (car cooked--commands)) "echo \"hi there\""))))

(ert-deftest cooked-command-start-survives-a-command-line-it-cannot-use ()
  "A `C\=' is the mark Emacs cannot do without; the command line on it is a
courtesy.  So one that is too long, or decodes to nothing, or is spelled in
kitty\='s ambiguous `cmdline=\=', leaves the mark standing and the record\='s
input merely empty -- never the mark dropped."
  (cooked-tests--with-session
      (cooked-tests--marks
       (concat "\\033]133;A\\007$ \\033]133;B\\007"
               ;; kitty's spelling, deliberately not read: shell quoting has no
               ;; single reading and a guess would be indistinguishable from truth.
               "\\033]133;C;cmdline=ls\\\\ -la\\007out\\r\\n"
               "\\033]133;D;0\\007"))
    (should (cooked-tests--settle (lambda () cooked--commands) 8))
    (should (= (length cooked--commands) 1))
    (should-not (cooked-command-input (car cooked--commands)))))

(ert-deftest cooked-native-completion-declines-on-a-foreign-host ()
  "Both tables are about this machine, so at a remote prompt they are not a
weaker answer but a wrong one.  Declining leaves the prompt with no Emacs
completion, which is the honest report."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let ((default-directory "/tmp/"))
      (cooked--osc-cwd '("file://other.example/tmp"))
      (should-not (cooked--native-completion)))))

(ert-deftest cooked-osc-51-escape-hatch-is-empty-until-filled ()
  "`cooked-eval-commands' governs the `!' verb alone, and starts empty: the fixed
verbs need no entry, so deny-by-default costs nothing here."
  (should-not cooked-eval-commands)
  (should-not (assoc "compile" cooked-eval-commands))
  (should-not (assoc "magit-status" cooked-eval-commands)))

(ert-deftest cooked-osc-51-escape-hatch-refuses-what-is-not-allowlisted ()
  "Output from a hostile host reaches here, and may not intern a name."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let ((cooked-eval-commands '(("noted" . ignore)))
          (danger nil))
      (cl-letf (((symbol-function 'shell-command)
                 (lambda (&rest _) (setq danger t))))
        (cooked--osc-emacs '("E1" "!" "\"shell-command\" \"rm -rf /\""))
        (cooked-tests--run-deferred)
        (should-not danger))
      ;; Nor by naming something that merely exists as a function.
      (cl-letf (((symbol-function 'delete-file)
                 (lambda (&rest _) (setq danger t))))
        (cooked--osc-emacs '("E1" "!" "\"delete-file\" \"/tmp/x\""))
        (cooked-tests--run-deferred)
        (should-not danger)))))

(ert-deftest cooked-osc-51-escape-hatch-runs-what-is-allowlisted ()
  "The one verb that still takes many arguments, so the one that still quotes."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let* ((called nil)
           (cooked-eval-commands `(("noted" . ,(lambda (&rest args) (setq called args))))))
      (cooked--osc-emacs '("E1" "!" "\"noted\" \"one\" \"two\""))
      (cooked-tests--run-deferred)
      (should (equal called '("one" "two"))))))

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
                  (format "printf 'BEFORE\\n'; printf '\\033]51;E1;F;%s\\033\\\\'; \
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
  (let ((target (make-temp-file "cooked-open")))
    (unwind-protect
        (cooked-tests--with-shell ("zsh")
          (let ((opened nil))
            ;; `find_file' is the shell helper emitting the `F' verb, so what this
            ;; exercises is the whole path: zsh's function, the wire format, the
            ;; verb table, and the remote-name guard the verb runs first.
            (cl-letf (((symbol-function 'find-file) (lambda (f) (setq opened f))))
              (cooked--replace-input (format "find_file %s" target))
              (cooked-send-input)
              (should (cooked-tests--settle (lambda () opened) 8))
              (should (equal opened target)))))
      (delete-file target))))

(ert-deftest cooked-comint-markers-follow-the-osc-133-marks ()
  "comint brackets the last input with `comint-last-input-start\='/`-end\=', and
its whole output family measures from them.  They sat at `point-min\=' until the
shell\='s own marks started feeding them -- which is why `comint-delete-output\='
used to flush the entire buffer."
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-shell ("zsh")
    (cooked--replace-input "echo alpha")
    (cooked-send-input)
    (should (cooked-tests--settle (lambda () cooked--commands) 8))
    (let ((command (car cooked--commands)))
      ;; The command line is recovered from the marks, not from a prompt regexp.
      (should (equal (cooked-command-input command) "echo alpha"))
      (goto-char (cooked--command-start-position command))
      (should (equal (cooked--get-old-input) "echo alpha"))
      ;; ...and the output really is bracketed, rather than starting at point-min.
      (should (> (cooked--command-start-position command) (point-min)))
      (should (string-match-p
               "alpha"
               (buffer-substring-no-properties
                (cooked--command-start-position command)
                (cooked--command-end-position command)))))))

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
    ;; And the emulator is still told how much of its top row Emacs holds -- asserted by
    ;; `cooked--check-seam', which signals on a drift.  Wrapping a drain in a settle whose
    ;; predicate ends in `t' only looked like a check: the predicate was true on its first
    ;; call, so the `should' could not fail whatever the drain did.
    (cooked--drain-and-apply)
    (cooked--check-seam)))

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
                        (alist-get 'default face-remapping-alist)))
        ;; The fringe rides along, or it visibly splits from the terminal background.
        (should (member '(:background "#ff0000")
                        (alist-get 'fringe face-remapping-alist))))
      ;; OSC 111 puts the theme's own background back.
      (let ((cooked--osc-code 111))
        (cooked--osc-color-reset nil))
      (should-not cooked--color-remaps))))

(ert-deftest cooked-color-scheme-follows-the-rendered-background ()
  "Read from the same background OSC 11 answers with, so a child that reacts to a
scheme change by querying the background cannot be told two different things."
  (cl-letf (((symbol-function 'cooked--default-color) (lambda (_) "#101014")))
    (should (eq (cooked--color-scheme) 'dark)))
  (cl-letf (((symbol-function 'cooked--default-color) (lambda (_) "#f8f8f2")))
    (should (eq (cooked--color-scheme) 'light))))

(ert-deftest cooked-color-scheme-is-answered-from-session-start ()
  "`cooked--start' reports it once, or a session that outlives no theme change
would answer `CSI ? 996 n' with silence for its whole life."
  (let ((out (make-temp-file "cooked-996")))
    (unwind-protect
        (cooked-tests--with-session
            (list "/bin/sh" "-c"
                  (format "stty raw -echo; printf '\\033[?996n'; cat > %s" out))
          (should (cooked-tests--settle
                   (lambda () (string-match-p "997" (cooked-tests--contents out)))))
          (should (string-match-p "\\`\033\\[\\?997;[12]n\\'"
                                  (cooked-tests--contents out))))
      (delete-file out))))

(ert-deftest cooked-a-colour-that-cannot-be-read-still-leaves-a-session ()
  "The scheme is reported from inside `cooked--start', so anything it signals is
signalled at the one moment there is no session yet to fall back on.  A terminal
that failed to open because a colour could not be read would be trading the whole
feature for the courtesy answer to a query most children never send.

The fixture cannot be used: it binds `cooked-debug' before it spawns, and this is
a test of containment, which under debug re-signals by design.  So the session is
built by hand with debug off -- the shape
`cooked-osc-handler-errors-do-not-break-redisplay' uses for the same reason."
  (let ((buffer (generate-new-buffer "*cooked-test*"))
        (cooked-debug nil))
    (unwind-protect
        (with-current-buffer buffer
          (cooked-mode)
          (cl-letf (((symbol-function 'cooked--color-scheme)
                     (lambda () (error "deliberate"))))
            (cooked--start '("/bin/sh" "-c" "sleep 5")))
          (should cooked--session)
          (should (cooked--live-session)))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer))))

(ert-deftest cooked-a-theme-change-notifies-a-subscribed-child ()
  "Driven through `cooked--flush-face-cache' rather than by calling the hook
function: the wiring — the hook, `cooked--dolist-buffers', and the buffer being
current — is the half most likely to be wrong.  The scheme is stubbed rather than
really themed: `-Q --batch' has no theme worth enabling, and the derivation is
`cooked-color-scheme-follows-the-rendered-background'."
  (let ((out (make-temp-file "cooked-2031"))
        (scheme 'dark))
    (unwind-protect
        (cl-letf (((symbol-function 'cooked--color-scheme) (lambda () scheme)))
          (cooked-tests--with-session
              (list "/bin/sh" "-c"
                    (format "stty raw -echo; printf '\\033[?2031h'; echo ready; cat > %s"
                            out))
            ;; The subscription has to have reached the emulator before the flip, and
            ;; the child says so on its own stdout.
            (should (cooked-tests--settle
                     (lambda () (string-match-p "ready" (cooked-tests--text)))))
            (setq scheme 'light)
            (cooked--flush-face-cache)
            (should (cooked-tests--settle
                     (lambda () (equal (cooked-tests--contents out) "\033[?997;2n"))))
            ;; The theme reloaded onto itself is not a change.
            (cooked--flush-face-cache)
            (cooked-tests--pump 0.3)
            (should (equal (cooked-tests--contents out) "\033[?997;2n"))
            ;; And the reverse flip is.
            (setq scheme 'dark)
            (cooked--flush-face-cache)
            (should (cooked-tests--settle
                     (lambda () (equal (cooked-tests--contents out)
                                       "\033[?997;2n\033[?997;1n"))))))
      (delete-file out))))

(ert-deftest cooked-a-theme-change-says-nothing-to-an-unsubscribed-child ()
  (let ((out (make-temp-file "cooked-no-2031"))
        (scheme 'dark))
    (unwind-protect
        (cl-letf (((symbol-function 'cooked--color-scheme) (lambda () scheme)))
          (cooked-tests--with-session
              (list "/bin/sh" "-c" (format "stty raw -echo; echo ready; cat > %s" out))
            (should (cooked-tests--settle
                     (lambda () (string-match-p "ready" (cooked-tests--text)))))
            (setq scheme 'light)
            (cooked--flush-face-cache)
            (cooked-tests--pump 0.3)
            (should (equal (cooked-tests--contents out) ""))))
      (delete-file out))))

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


;;; Duplicate and missing OSC 133 marks
;;
;; Nobody specifies these -- not kitty, not Ghostty, not the freedesktop proposal --
;; and we own the parser, so the behaviour is ours to state and ours to keep true.
;; The `no-marks' negotiation exists to stop two emitters bracketing the same prompt;
;; these are what happens when it fails, which is a shell on the far end of an ssh
;; whose rc knows nothing of the feature list.  Driven through a real pty rather than
;; by handing `cooked--handle-semantic' events, because the marks have to survive the
;; Rust half -- which is where a duplicate `A' is decided -- to mean anything here.

(defun cooked-tests--marks (script)
  "An argv printing SCRIPT and then waiting, for driving marks by hand.

SCRIPT is a `printf\=' format, so the marks are written as the octal escapes a
shell would print rather than as literal control bytes.  The trailing sleep is
what keeps the child alive long enough for the assertions: a session whose child
has exited is torn down."
  (list "/bin/sh" "-c" (concat "printf '" script "'; sleep 5")))

(ert-deftest cooked-a-second-command-start-is-ignored ()
  "The one duplicate that loses information, so the one worth a rule.

A second `C' before the `D' would move the start of the output region down to
it, dropping whatever the command printed in between -- and the exit code, which
the first mark opened the record for, would then be attributed to a region that
does not describe it.  The first `C' wins."
  (cooked-tests--with-session
      (cooked-tests--marks
       "\\033]133;A\\007$ \\033]133;B\\007cmd\\r\\n\\033]133;C\\007one\\r\\n\\033]133;C\\007two\\r\\n\\033]133;D;0\\007")
    (should (cooked-tests--settle (lambda () cooked--commands) 8))
    (should (= (length cooked--commands) 1))
    (let ((command (car cooked--commands)))
      ;; Both lines are inside the record: the region begins at the first `C'.
      (should (string-match-p
               "one"
               (buffer-substring-no-properties (cooked--command-start-position command)
                                               (cooked--command-end-position command)))))))

(ert-deftest cooked-a-command-start-after-a-fresh-prompt-is-not-a-duplicate ()
  "The escape hatch on that rule.  A shell that drops its `D' -- or one killed
between two commands -- must still open a record at its next prompt, or the
session never produces another one.  `A' is what says the last command is over."
  (cooked-tests--with-session
      (cooked-tests--marks
       "\\033]133;C\\007one\\r\\n\\033]133;A\\007$ \\033]133;B\\007\\033]133;C\\007two\\r\\n\\033]133;D;0\\007")
    (should (cooked-tests--settle (lambda () cooked--commands) 8))
    (let ((command (car cooked--commands)))
      ;; The record is the second command's, so the first one's output is above it.
      (should-not (string-match-p
                   "one"
                   (buffer-substring-no-properties (cooked--command-start-position command)
                                                   (cooked--command-end-position command)))))))

(ert-deftest cooked-a-second-command-end-is-a-no-op ()
  "`D' clears the start marker on its way out and guards on it, so the second one
has nothing to close.  One record, and the exit code is the first `D''s."
  (cooked-tests--with-session
      (cooked-tests--marks
       "\\033]133;A\\007$ \\033]133;B\\007\\033]133;C\\007out\\r\\n\\033]133;D;0\\007\\033]133;D;7\\007")
    (should (cooked-tests--settle (lambda () cooked--commands) 8))
    (should (= (length cooked--commands) 1))
    (should (= (cooked-command-code (car cooked--commands)) 0))))

(ert-deftest cooked-a-command-end-without-a-start-records-nothing ()
  "There is no region to record and no input to attribute to it.  A `D' arriving
alone is a shell whose `C' we never saw -- the first prompt after sourcing the
snippet, or a `no-marks' rc that only half took effect."
  (cooked-tests--with-session
      (cooked-tests--marks "\\033]133;A\\007$ \\033]133;B\\007\\033]133;D;0\\007")
    (should (cooked-tests--settle (lambda () (eq cooked--semantic nil)) 8))
    (should-not cooked--commands)))

(ert-deftest cooked-a-second-prompt-start-replaces-the-prompt-marker ()
  "A second `A' before any `C' is a prompt redrawn, not a command begun -- a
theme repainting, or two emitters bracketing the same prompt.  The later mark
wins, because it is the one the prompt on screen actually starts at."
  (cooked-tests--with-session
      (cooked-tests--marks "one\\r\\n\\033]133;A\\007two\\r\\n\\033]133;A\\007$ \\033]133;B\\007")
    (should (cooked-tests--settle
             (lambda () (and cooked--prompt-start (eq cooked--semantic 'input))) 8))
    (should (string-prefix-p
             "$ " (buffer-substring-no-properties
                   (marker-position cooked--prompt-start)
                   (save-excursion (goto-char (marker-position cooked--prompt-start))
                                   (line-end-position)))))))

;;; Continuation prompts

(ert-deftest cooked-a-continuation-prompt-keeps-the-prompt-marker ()
  "`A;k=s' is a prompt that continues the previous one -- `PS2'.  It hands Emacs
the line the same way a first prompt does, and deliberately does *not* move the
prompt marker: the command record is filed under the prompt the construct began
at, not under its last continuation line."
  (cooked-tests--with-session
      (cooked-tests--marks
       "\\033]133;A\\007$ for x in 1 2; do\\r\\n\\033]133;A;k=s\\007> \\033]133;B\\007")
    (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input)) 8))
    ;; Emacs owns the continuation line: the `B' arrived and was believed.
    (should (cooked--input-state-p))
    ;; And the marker is still on the line the construct began at.
    (should cooked--prompt-start)
    (should (string-match-p
             "for x in 1 2"
             (buffer-substring-no-properties
              (marker-position cooked--prompt-start)
              (save-excursion (goto-char (marker-position cooked--prompt-start))
                              (line-end-position)))))))

(ert-deftest cooked-an-orphan-continuation-does-not-latch-the-input-together ()
  "A continuation continues *something*, and when nothing arrives to end it the
flag saying so must not go on being true for the rest of the session.

The shell that produced this: `A;k=s' emitted with the plain marks turned off, so
no `A' ever set a prompt marker and no `C' ever consumed one.  Both arms that
clear the flag are therefore unreachable, and every line submitted afterwards was
appended to the one before it -- one record's input growing without bound, and
the whole session's history attached to whichever command finally closed."
  (cooked-tests--with-session
      (cooked-tests--marks "\\033]133;A;k=s\\007> \\033]133;B\\007")
    (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input)) 8))
    (should cooked--prompt-continued)
    ;; No `A' came, so there is no prompt for this to be a continuation *of*.
    (should-not cooked--prompt-start)
    (cooked--send-input-string "one")
    (cooked--send-input-string "two")
    ;; Replaced, not appended: the second line is its own submission.
    (should (equal cooked--submitted-input "two"))))

(ert-deftest cooked-zsh-marks-its-continuation-prompt ()
  "The end to end version, and the reason PS2 is worth touching at all: without
the mark every line after the first of a multi-line construct falls out of
Emacs' hands back to ZLE, so you compose the first line in Emacs and the rest in
the shell's own line editor.

The record is the other half.  Each continuation line is submitted separately,
so the command's own text has to accumulate across them or the record for the
whole construct would say only its last line."
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-zsh
    (cooked--replace-input "for x in alpha beta; do")
    (cooked-send-input)
    ;; The continuation prompt arrives and Emacs still owns the line.
    (should (cooked-tests--settle
             (lambda () (and cooked--prompt-continued
                             (eq cooked--semantic 'input)
                             (cooked--input-start-position)))
             8))
    (should (cooked--input-state-p))
    ;; Waiting on the next prompt has to be a wait for the input region to *move*.
    ;; `cooked--prompt-continued' is already set from the prompt above and stays set
    ;; for the whole construct, so a settle on it returns at once and the line below
    ;; would be typed at a prompt the shell has not drawn yet.
    (let ((line (cooked--input-start-position)))
      (cooked--replace-input "echo $x")
      (cooked-send-input)
      (should (cooked-tests--settle
               (lambda () (let ((now (cooked--input-start-position)))
                            (and now (> now line) cooked--prompt-continued)))
               8)))
    (cooked--replace-input "done")
    (cooked-send-input)
    (should (cooked-tests--settle
             (lambda () (and cooked--commands
                             (string-match-p "beta" (cooked-tests--text))))
             8))
    (let ((command (car cooked--commands)))
      ;; The whole construct, not just the line that completed it.
      (should (equal (cooked-command-input command)
                     "for x in alpha beta; do\necho $x\ndone"))
      ;; And the prompt it is filed under is the one it was typed at.
      (should (string-match-p
               "for x in alpha beta"
               (buffer-substring-no-properties
                (cooked--command-prompt-position command)
                (save-excursion
                  (goto-char (cooked--command-prompt-position command))
                  (line-end-position))))))))

(provide 'cooked-tests-osc)
;;; cooked-tests-osc.el ends here
