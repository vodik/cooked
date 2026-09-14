;;; cooked-tests-osc.el --- OSC handlers and the channels they open -*- lexical-binding: t; -*-

;;; Commentary:

;; The sequences cooked answers in Lisp rather than in Rust: titles, colours,
;; notifications and the bell, the clipboard, SetUserVar, and the OSC 51 command channel -- which is also
;; where the opt-in defaults are asserted, since every one of these is something
;; a hostile stream can send.

;;; Code:

(require 'cooked-tests-helpers)
(require 'cooked-osc-eval)
(require 'cooked-user-var)
;; Loaded before any test stubs its functions, so a `require' inside cooked
;; cannot put the real ones back under a stub.
(require 'notifications nil t)

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
    (should (cooked-tests--settle (lambda () (equal cooked-title "my-title"))))
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

(defmacro cooked-tests--raising-notifications (capabilities &rest body)
  "Run BODY against a stub desktop that advertises CAPABILITIES.

BODY sees `raised\=', the arguments of every `notifications-notify\=' call so
far, oldest first, and `said\=', every message, and can call `flush\=' to run
the notifications it has deferred.  They are run before the stubs go in any
case, so a timer left behind cannot reach the real desktop."
  (declare (indent 1))
  `(let ((raised nil)
         (said nil)
         (cooked--notification-times nil)
         (cooked--notification-markup nil))
     (cl-letf (((symbol-function 'notifications-get-capabilities)
                (lambda (&rest _) ,capabilities))
               ((symbol-function 'notifications-notify)
                (lambda (&rest params) (setq raised (append raised (list params)))))
               ((symbol-function 'message)
                (lambda (fmt &rest args)
                  (setq said (append said (list (apply #'format fmt args)))))))
       (cl-flet ((flush ()
                   (let ((deadline (+ (float-time) (cooked-tests-timeout 2))))
                     (while (and (< (float-time) deadline)
                                 (seq-find (lambda (timer)
                                             (eq (timer--function timer)
                                                 #'cooked--raise-notification))
                                           timer-list))
                       (accept-process-output nil 0.01)))))
         (unwind-protect (progn ,@body)
           (flush))))))

(ert-deftest cooked-notifications-are-rate-limited ()
  (with-temp-buffer
    (cooked-mode)
    (let ((cooked-allow-notifications t)
          (cooked-notification-rate '(2 . 10)))
      ;; A `cat\=' of a hostile file must not be able to flood the desktop.  Driven
      ;; through the real `cooked--notify\=', since that is where the limit lives.
      (cooked-tests--raising-notifications '(:body)
        (dotimes (i 5) (cooked--osc-notify (list "i=1" (format "n%d" i))))
        (flush)
        (should (= (length raised) 2))
        (setq cooked--notification-times nil)
        (should (cooked--notification-allowed-p))
        (push (float-time) cooked--notification-times)
        (should (cooked--notification-allowed-p))
        (push (float-time) cooked--notification-times)
        (should-not (cooked--notification-allowed-p))))))

(ert-deftest cooked-notification-rate-is-shared-by-every-session ()
  "Two sessions share one cap, since the desktop they fill is the same one."
  (let ((cooked-allow-notifications t)
        (cooked-notification-rate '(2 . 10))
        (buffers (list (generate-new-buffer "a") (generate-new-buffer "b"))))
    (unwind-protect
        (cooked-tests--raising-notifications '(:body)
          (dolist (buffer buffers)
            (with-current-buffer buffer
              (cooked-mode)
              (dotimes (_ 2) (cooked--osc-9 '("done")))))
          (flush)
          (should (= (length raised) 2)))
      (mapc #'kill-buffer buffers))))

(ert-deftest cooked-notification-is-raised-outside-the-drain ()
  "A real child\='s OSC 9 reaches the desktop from a timer, not from its drain.

A desktop notification is a synchronous D-Bus call, and inside the drain a slow
server would hold up the child\='s output.  The stub records the session\='s
`cooked--draining\=' when it is called."
  (let ((cooked-allow-notifications t)
        (session nil)
        (during nil))
    (cooked-tests--raising-notifications '(:body)
      (cl-letf* ((real-notify (symbol-function 'notifications-notify))
                 ((symbol-function 'notifications-notify)
                  (lambda (&rest params)
                    (push (buffer-local-value 'cooked--draining session) during)
                    (apply real-notify params))))
        (cooked-tests--with-session
            '("/bin/sh" "-c" "printf '\\033]9;build done\\007'; sleep 5")
          (setq session (current-buffer))
          (should (cooked-tests--settle (lambda () raised)))
          (should (equal during '(nil)))
          (should (equal (plist-get (car raised) :body) "build done"))
          (should (equal (plist-get (car raised) :title) (buffer-name))))))))

(ert-deftest cooked-notification-body-markup-is-escaped ()
  "A server that reads markup is sent the body escaped, and one that does not is
sent it as it came, since it would show the entities literally.  The buffer
leads the title either way."
  (with-temp-buffer
    (rename-buffer "*cooked-notify*" t)
    (let ((body "<img src=\"file:///etc/passwd\"> & <a href=\"x\">y</a>"))
      (cooked-tests--raising-notifications '(:body :body-markup)
        (cooked--notify "Build" body)
        (flush)
        (should (equal (car raised)
                       (list :title (concat (buffer-name) ": Build")
                             :body (concat "&lt;img src=\"file:///etc/passwd\"&gt; &amp; "
                                           "&lt;a href=\"x\"&gt;y&lt;/a&gt;")))))
      (cooked-tests--raising-notifications '(:body)
        (cooked--notify "Build" body)
        (flush)
        (should (equal (plist-get (car raised) :body) body))))))

(ert-deftest cooked-notification-falls-back-to-a-message-without-a-bus ()
  "With no session bus every call signals, and every notification is a message.

Not just the first: the seam used to report the failure once and then lose
each notification after it."
  (with-temp-buffer
    (rename-buffer "*cooked-notify*" t)
    (cooked-tests--raising-notifications '(:body)
      (cl-letf (((symbol-function 'notifications-get-capabilities)
                 (lambda (&rest _) (signal 'dbus-error '("No session bus")))))
        (cooked--notify "" "first")
        (cooked--notify "" "second")
        (flush)
        (should-not raised)
        (should (equal said (list (concat (buffer-name) " first")
                                  (concat (buffer-name) " second"))))))))

(ert-deftest cooked-notification-strips-control-characters ()
  (should (equal (cooked--notification-clean "a\e]0;evil\007b" 100) "a]0;evilb"))
  (should (equal (cooked--notification-clean "abcdef" 3) "abc"))
  ;; C1 controls, and format characters such as a right-to-left override, which
  ;; would draw `txt.exe' as `exe.txt'.
  (should (equal (cooked--notification-clean "\u009b31m\u202etxt.exe\u200b" 100)
                 "31mtxt.exe"))
  ;; Characters dropped do not count against the limit.
  (should (equal (cooked--notification-clean "\u202e\u202eabc" 3) "abc"))
  ;; A zero-width joiner holds an emoji sequence together and is kept.
  (should (equal (cooked--notification-clean "\U0001F469\u200d\U0001F4BB" 100)
                 "\U0001F469\u200d\U0001F4BB")))

;; OSC 9 is two protocols under one number, so what is asserted is the split:
;; iTerm2's message notifies, and none of ConEmu's numbered commands does.

(ert-deftest cooked-osc-9-message-notifies-under-the-gate ()
  (with-temp-buffer
    (cooked-mode)
    (let ((cooked-allow-notifications nil))
      (should (null (cooked-tests--capturing-notifications
                      (cooked--osc-9 '("done"))))))
    (let ((cooked-allow-notifications t))
      (should (equal (cooked-tests--capturing-notifications
                       (cooked--osc-9 '("done"))
                       ;; A message may hold a `;' of its own.
                       (cooked--osc-9 '("built" " 3 warnings"))
                       ;; A number leading a message does not make it ConEmu's.
                       (cooked--osc-9 '("42 files built")))
                     '(("" . "done") ("" . "built; 3 warnings")
                       ("" . "42 files built"))))
      ;; And the rate cap applies, through the real `cooked--notify\='.
      (let ((cooked-notification-rate '(2 . 10)))
        (cooked-tests--raising-notifications '(:body)
          (dotimes (_ 5) (cooked--osc-9 '("again")))
          (flush)
          (should (= (length raised) 2)))))))

(ert-deftest cooked-osc-9-conemu-commands-never-notify ()
  "A leading all-digit field is ConEmu's, implemented or not.

`9;9;PATH' is ConEmu's working directory; read as iTerm2's message it would put
a path on the desktop, which is the mistake testing for `4' alone would make."
  (with-temp-buffer
    (cooked-mode)
    (let ((cooked-allow-notifications t))
      (should (null (cooked-tests--capturing-notifications
                      (dolist (parts '(("9" "/home/me") ("1" "500") ("12")
                                       ("4" "1" "42") ("42") ("") ()))
                        (cooked--osc-9 parts)))))
      ;; `9;4' still reaches the progress indicator through the same handler.
      (should (equal cooked--progress '(set . 42))))))

(ert-deftest cooked-notification-chunks-are-bounded ()
  (with-temp-buffer
    (cooked-mode)
    (let ((cooked-allow-notifications t))
      ;; A child that opens chunks and never closes them must not grow this forever.
      (dotimes (i 30)
        (cooked--osc-notify (list (format "i=%d:d=0" i) "x")))
      (should (<= (length cooked--notification-chunks)
                  (car cooked--notification-chunk-limits))))))

(defun cooked-tests--bell-annotation ()
  "This buffer's `cooked-buffer-annotation', as plain text."
  (substring-no-properties (cooked-buffer-annotation (current-buffer))))

(ert-deftest cooked-a-burst-of-bells-rings-once ()
  "A hundred BELs from one `printf' are one ring, through the real drain.

Visible in the selected frame, which is the case that rings at all.  The second
half is what tells a rate limit from a latch: once the interval has passed the
next bell rings again."
  (let ((rings 0)
        (cooked--bell-last nil))
    (cl-letf (((symbol-function 'ding) (lambda (&rest _) (cl-incf rings))))
      (cooked-tests--with-session
          '("/bin/sh" "-c" "i=0; while [ $i -lt 100 ]; do printf '\\a'; i=$((i+1)); done; \
printf 'rang\\n'; sleep 5")
        (set-window-buffer (selected-window) (current-buffer))
        (should (cooked-tests--settle
                 (lambda () (string-match-p "rang" (cooked-tests--text)))))
        (should (= rings 1))
        (should-not cooked-bell-pending)
        (setq cooked--bell-last (- (float-time) 1))
        (cooked-bell-default)
        (should (= rings 2))))))

(ert-deftest cooked-a-hidden-bell-waits-in-the-annotation-until-seen ()
  "Out of sight a bell is a mark rather than a noise, and looking clears it.

Cleared through the window hook rather than by setting the variable back,
because the wiring is the part that can rot.  Batch runs no redisplay, so the
hook is run here where redisplay would run it on showing the buffer: its global
value, which is what reaches a buffer that was displayed nowhere."
  (let ((rings 0)
        (cooked--bell-last nil))
    (cl-letf (((symbol-function 'ding) (lambda (&rest _) (cl-incf rings))))
      (cooked-tests--with-session '("/bin/sh" "-c" "printf 'done\\a\\n'; sleep 5")
        ;; Batch Emacs displays the session in no window, so this is hidden.
        (should-not (get-buffer-window (current-buffer)))
        (should (cooked-tests--settle (lambda () cooked-bell-pending)))
        (should (= rings 0))
        (should (string-match-p "\\`  idle  bell\\b" (cooked-tests--bell-annotation)))
        (should (string-match-p " bell" (cooked--mode-line)))
        (set-window-buffer (selected-window) (current-buffer))
        (run-hook-with-args 'window-buffer-change-functions (selected-frame))
        (should-not cooked-bell-pending)
        ;; Anchored on the field: the worktree this runs in may have `bell' in its
        ;; name, and the directory is in the annotation too.
        (should-not (string-match-p "\\`  idle  bell\\b" (cooked-tests--bell-annotation)))
        (should-not (string-search "bell" (cooked--mode-line)))))))

(ert-deftest cooked-a-bell-outlives-the-session-that-rang-it ()
  "A build that rings and exits leaves the mark, and the mark still clears.

`cooked--update-attention' does everything else only for a live session; the
bell is cleared ahead of that test, since a dead buffer is still one the user
comes back to."
  (with-temp-buffer
    (cooked-mode)
    (setq cooked--exit 0 cooked-bell-pending t)
    (should (string-match-p "\\`  exited 0  bell" (cooked-tests--bell-annotation)))
    (should (string-match-p "exited 0 bell" (cooked--mode-line)))
    (set-window-buffer (selected-window) (current-buffer))
    (cooked--update-attention)
    (should-not cooked-bell-pending)))

(ert-deftest cooked-a-bell-rings-under-a-keyboard-macro ()
  "A bell arriving while a keyboard macro runs rings and leaves the macro alone.

Batch Emacs never takes the branch of `ding' that ends a macro, since it is
`noninteractive', so the stub does what the C does outside batch: with no
argument and `executing-kbd-macro' set, `ding' signals `user-error'.  The bell
goes through the real event and seam, which would otherwise swallow the signal
and report a failure where a ring should have been."
  (let ((rings 0)
        (failures nil)
        (cooked--bell-last nil))
    (cl-letf (((symbol-function 'ding)
               (lambda (&optional arg)
                 (if (and (null arg) executing-kbd-macro)
                     (user-error "Keyboard macro terminated by a command ringing the bell")
                   (cl-incf rings))))
              ((symbol-function 'cooked--seam-failed)
               (lambda (&rest args) (push args failures))))
      (with-temp-buffer
        (cooked-mode)
        (set-window-buffer (selected-window) (current-buffer))
        (let ((executing-kbd-macro [?x]))
          (cooked--handle-event '(bell) (point-min)))
        (should-not failures)
        (should (= rings 1))))))

(ert-deftest cooked-a-reset-clears-the-bell-mark ()
  "RIS takes a bell\='s mark with it, as it takes the progress indicator.

Pinned at the seam, like `cooked-progress-is-cleared-by-a-reset'; that a BEL
after the reset is raised afresh is the Rust test
`a_burst_of_bells_is_one_event_per_drain'."
  (with-temp-buffer
    (cooked-mode)
    (setq cooked-bell-pending t)
    (should (string-search "bell" (cooked--mode-line)))
    (cooked--handle-event '(reset) (point-min))
    (should-not cooked-bell-pending)
    (should-not (string-search "bell" (cooked--mode-line)))))

(ert-deftest cooked-a-reset-from-a-real-child-puts-back-what-emacs-holds ()
  "`reset' is what a user types at a terminal a program left purple under a
stale title.  RIS takes off the OSC 10 and 11 remaps and the OSC 12 cursor
colour, and forgets the title and the titles pushed under it."
  (let ((go (make-temp-name (expand-file-name "cooked-reset-go" temporary-file-directory)))
        (cooked-allow-color-set t))
    (unwind-protect
        (cooked-tests--with-session
            (list "/bin/sh" "-c"
                  (format "printf '\\033]10;#00ff00\\007\\033]11;#800080\\007\\033]12;#ff0000\\007'; \
printf '\\033]2;shell\\007\\033[22;0;0t\\033]2;vim\\007'; \
while [ ! -e %s ]; do sleep 0.05; done; printf '\\033c'; sleep 5" go))
          (should (cooked-tests--settle
                   (lambda () (and (equal cooked-title "vim")
                                   (alist-get 'foreground cooked--color-remaps)
                                   (alist-get 'background cooked--color-remaps)
                                   cooked--cursor-color))))
          (should cooked--title-stack)
          (write-region "" nil go)
          (should (cooked-tests--settle (lambda () (null cooked-title))))
          (should-not cooked--title-stack)
          (should-not cooked--color-remaps)
          (should-not (alist-get 'default face-remapping-alist))
          (should-not cooked--cursor-color))
      (ignore-errors (delete-file go)))))

(ert-deftest cooked-title-stack-restores-on-pop ()
  "XTWINOPS 22/23, which `smcup'/`rmcup' send around the alternate screen."
  (cooked-tests--with-session
   '("/bin/sh" "-c"
     "printf '\\033]2;shell\\007\\033[22;0;0t\\033]2;vim\\007'; sleep 5")
   (should (cooked-tests--settle (lambda () (equal cooked-title "vim"))))
   (cooked--handle-title-stack nil)
   (should (equal cooked-title "shell"))))

(ert-deftest cooked-title-stack-is-bounded-and-survives-underflow ()
  (with-temp-buffer
    (cooked-mode)
    (setq-local cooked--title-stack nil cooked-title "last")
    ;; A child that pushes and never pops must not grow the list without bound.
    (dotimes (i 20)
      (setq-local cooked-title (number-to-string i))
      (cooked--handle-title-stack t))
    (should (= (length cooked--title-stack) cooked--title-stack-limit))
    ;; Popping past the bottom leaves the title alone rather than clearing it.
    (dotimes (_ 20) (cooked--handle-title-stack nil))
    (should cooked-title)))

(defmacro cooked-tests--with-resize-request (script &rest body)
  "Run BODY in a session running SCRIPT, shown in the top of two windows.

The split is what gives a request somewhere to go: a window alone in its frame
cannot move without the frame, which a request never touches.  WINDOW is bound
to the session's window, and `cooked--last-size' is settled first so a resize
counted afterwards is one the request caused.

SCRIPT should wait for a line before it sends anything, and the test sends one
once it is ready: a request drained before the buffer is in a window has no
layout window to move."
  (declare (indent 1))
  `(save-window-excursion
     (delete-other-windows)
     (let ((below (split-window-below)))
       (cooked-tests--with-session (list "/bin/sh" "-c" ,script)
         (should (cooked-tests--settle (lambda () cooked--session)))
         (set-window-buffer below (get-buffer-create "*cooked-test-neighbour*"))
         (set-window-buffer (selected-window) (current-buffer))
         (let ((window (selected-window)))
           (ignore window)
           (cooked--sync-size)
           ,@body)))))

(ert-deftest cooked-a-resize-request-resizes-the-window-once ()
  "`resize -s ROWS 0' under `window': the window moves, the child is told once.

And told the size the window really took, which is what `stty size' prints.
The request is sent and then the child waits for a line, so the size it reads
is the one it has after Emacs has noticed the window change -- simulated here
by running `window-size-change-functions'\\=' handler by hand, since batch has
no redisplay to run it.

Once, twice over: noticing the change a second time, as the configuration hook
and the size hook both do in a live frame, resizes nothing more, and a second
identical request finds the window already where it asked and moves nothing."
  (let ((cooked-resize-requests 'window)
        (moves 0) (resizes 0))
    (cooked-tests--with-resize-request
        "read _; printf '\\033[8;14;0t'; read _; stty size; printf '\\033[8;14;0t'; sleep 5"
      (cl-letf* ((real-resize (symbol-function 'cooked--resize))
                 ((symbol-function 'cooked--resize)
                  (lambda (&rest args) (cl-incf resizes) (apply real-resize args)))
                 (real-move (symbol-function 'window-resize))
                 ((symbol-function 'window-resize)
                  (lambda (&rest args) (cl-incf moves) (apply real-move args))))
        (cooked--send-if-live "\r")
        (should (cooked-tests--settle (lambda () (> moves 0))))
        (should (= moves 1))
        (should (= (cooked--window-rows window) 14))
        (should (= resizes 0))
        (cooked--frame-size-changed (selected-frame))
        (cooked--frame-size-changed (selected-frame))
        (should (= resizes 1))
        (should (equal cooked--last-size
                       (cons 14 (window-max-chars-per-line window))))
        (cooked--send-if-live "\r")
        (should (cooked-tests--settle
                 (lambda ()
                   (string-match-p
                    (format "^14 %d$" (window-max-chars-per-line window))
                    (cooked-tests--text)))))
        ;; The second request, already satisfied.
        (cooked-tests--pump 0.3)
        (cooked-tests--settle (lambda () nil) 0.3)
        (cooked--frame-size-changed (selected-frame))
        (should (= moves 1))
        (should (= resizes 1))))))

(ert-deftest cooked-a-resize-request-is-refused-by-default ()
  "Nothing moves, and nothing answers: the child's `18t' tells it the truth."
  (should-not (default-value 'cooked-resize-requests))
  (let ((out (make-temp-file "cooked-resize-refused")))
    (unwind-protect
        (cooked-tests--with-resize-request
            (format "stty raw -echo; dd bs=1 count=1 >/dev/null 2>&1; printf '\\033[8;14;40t\\033[30t\\033[18t'; cat > %s" out)
          (cooked--send-if-live "\r")
          (let ((before (window-body-height window t))
                (width (window-max-chars-per-line window)))
            (should (cooked-tests--settle
                     (lambda () (string-match-p "t\\'" (cooked-tests--contents out)))))
            (should (= (window-body-height window t) before))
            (should (= (window-max-chars-per-line window) width))
            ;; The `18t' is the whole of what came back.
            (should (equal (cooked-tests--contents out)
                           (format "\e[8;%d;%dt" (car cooked--last-size) width)))))
      (delete-file out))))

(ert-deftest cooked-a-resize-request-never-moves-the-frame ()
  "A buffer filling its frame has nowhere to grow, and the request is clamped to nothing."
  (let ((cooked-resize-requests 'window))
    (save-window-excursion
      (delete-other-windows)
      (with-temp-buffer
        (cooked-mode)
        (set-window-buffer (selected-window) (current-buffer))
        (let ((frame (list (frame-width) (frame-height)))
              (window (list (window-body-height nil t) (window-max-chars-per-line))))
          (cooked--handle-resize-request 200 300)
          (cooked--handle-resize-request 3 10)
          (should (equal (list (frame-width) (frame-height)) frame))
          (should (equal (list (window-body-height nil t) (window-max-chars-per-line))
                         window)))))))

(ert-deftest cooked-a-resize-request-moves-only-the-layout-window ()
  "The narrowest window is the child's, and it may not grow past the next one.

Grown past it, the other window becomes the layout window and hands the child
its own width instead -- and a child that asked again would grow that one next."
  (let ((cooked-resize-requests 'window))
    (save-window-excursion
      (delete-other-windows)
      (with-temp-buffer
        (cooked-mode)
        (let* ((left (selected-window))
               (middle (split-window-right 20))
               (right (split-window-right 35 middle)))
          (set-window-buffer left (current-buffer))
          (set-window-buffer middle (get-buffer-create "*cooked-test-neighbour*"))
          (set-window-buffer right (current-buffer))
          ;; 20, 35 and the 25 left over: LEFT is narrowest, and MIDDLE is wide
          ;; enough to give LEFT all it can take without RIGHT having to shrink.
          (should (eq (cooked--layout-window) left))
          (let ((right-width (window-max-chars-per-line right))
                (right-rows (window-body-height right)))
            (cooked--handle-resize-request nil 15)
            (should (= (window-max-chars-per-line left) 15))
            (cooked--handle-resize-request nil 200)
            (should (= (window-max-chars-per-line left) right-width))
            (should (= (window-max-chars-per-line right) right-width))
            (should (= (window-body-height right) right-rows))))))))

(ert-deftest cooked-a-resize-request-on-a-character-frame-stays-within-its-clamp ()
  "Where windows move by whole characters, a request never steps past the room.

With `window-resize-pixelwise' nil, `window-resize' rounds a pixel delta to the
nearest `frame-char-size'.  A batch frame's character is one pixel, so nothing
ever rounds there, and `frame-char-size' is made to say three: the frame then
behaves as a graphical frame whose rows are three pixels tall.  Each split
leaves the window different room to grow, and a room of 14, 11 or 8 pixels is
the case that used to signal, rounding up to 15, 12 or 9.  Every split must
resize without an error, by a whole number of characters no larger than the
room."
  (let ((window-resize-pixelwise nil)
        (window-min-height 1)
        (window-safe-min-height 1)
        (residues nil))
    (save-window-excursion
      (dolist (split '(5 6 7 8 9 10 11 12 13 14 15))
        (delete-other-windows)
        (split-window-below split)
        (cl-letf (((symbol-function 'frame-char-size) (lambda (&rest _) 3)))
          (let* ((window (selected-window))
                 (before (window-pixel-height window))
                 (room (window-resizable window 99 nil nil t)))
            (push (% room 3) residues)
            (cooked--resize-window-by window nil 99)
            (let ((grown (- (window-pixel-height window) before)))
              (should (zerop (% grown 3)))
              (should (<= 0 (- room grown) 2)))))))
    ;; The rounding-up case was actually reached, so the loop tested something.
    (should (memq 2 residues))))

(ert-deftest cooked-a-failed-resize-request-keeps-the-rest-of-its-drain ()
  "A resize that signals is reported, and the events after it still run.

The request moves windows the drain does not own, so a layout that refuses it
is not the drain's failure: the reply queued behind it in the same drain, here
a bell, must still be handled."
  (let* ((cooked-resize-requests 'window)
         (cooked-debug nil)
         (rings 0)
         (cooked-bell-function (lambda () (cl-incf rings)))
         (failures nil))
    (save-window-excursion
      (delete-other-windows)
      (split-window-below)
      (with-temp-buffer
        (cooked-mode)
        (set-window-buffer (selected-window) (current-buffer))
        (cl-letf (((symbol-function 'window-resize)
                   (lambda (window &rest _)
                     (error "Cannot resize window %s" window)))
                  ((symbol-function 'cooked--seam-failed)
                   (lambda (key _err) (push key failures))))
          (dolist (event '((resize-request 5 nil) (bell)))
            (cooked--handle-event event (point-min))))
        (should (equal failures '(cooked-resize-requests)))
        (should (= rings 1))))))

(ert-deftest cooked-frame-size-reports-answer-from-the-frame ()
  "`19t' in cells on any frame; `15t' only where there are pixels, like `14t'."
  (let ((out (make-temp-file "cooked-19t")))
    (unwind-protect
        (cooked-tests--with-session (cooked-tests--reply-to "\\033[19t\\033[15t\\033[11t" out)
          (should (cooked-tests--settle
                   (lambda () (string-suffix-p "\e[1t" (cooked-tests--contents out)))))
          (should (equal (cooked-tests--contents out)
                         (concat
                          (format "\e[9;%d;%dt" (frame-text-lines) (frame-text-cols))
                          (if (display-graphic-p)
                              (format "\e[5;%d;%dt" (frame-text-height) (frame-text-width))
                            "")
                          "\e[1t"))))
      (delete-file out))))

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

(ert-deftest cooked-osc-7-keeps-a-foreign-host-out-of-a-local-default-directory ()
  "The authority half of the OSC 7 URL used to be matched and thrown away.

Throwing it away is what makes the remote case dangerous rather than merely
useless: after an `ssh\=' the far shell reports its directory perfectly
honestly, and a tree kept in step with the local one turns that honest report
into a local path that exists.  So the one thing a foreign host may never
produce is a *local* `default-directory\='.

What it produces instead is a remote one -- see
`cooked-osc-7-maps-a-foreign-host-onto-a-tramp-path\=' -- which is the same
answer to the same question: a name that says which machine it is on.  This test
is about the spellings of *this* machine that must not be read as a move at all,
and it is those that this file's `system-name\=' games are for."
  (let* ((here (make-temp-file "cooked-osc7-" t))
         (there (file-name-as-directory here)))
    (unwind-protect
        (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
          (let ((default-directory "/tmp/")
                (cooked-tramp-default-method "ssh"))
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
            ;; And somewhere else is somewhere else: the path is rewritten onto
            ;; the host that reported it, and what it must never be is the local
            ;; `/tmp/' that also exists and is not the directory in question.
            (cooked--osc-cwd '("file://other.example/tmp"))
            (should (cooked--foreign-host-p))
            (should (equal default-directory "/ssh:other.example:/tmp/"))))
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

(ert-deftest cooked-osc-7-decodes-a-utf-8-directory-name ()
  "A non-ASCII directory arrives as percent-escaped UTF-8 bytes, and is found.

`café' is reported as `caf%C3%A9'.  Unescaping alone gave two raw-byte
characters in place of the `é', a name that exists nowhere, so tracking stopped
at the first directory whose name was not ASCII."
  (let* ((parent (make-temp-file "cooked-osc7-" t))
         (dir (expand-file-name "café" parent)))
    (unwind-protect
        (progn
          (make-directory dir)
          (with-temp-buffer
            (cooked-mode)
            (let ((default-directory "/"))
              (cooked--osc-cwd
               (list (concat "file://" (system-name)
                             (url-hexify-string
                              dir (cons ?/ url-unreserved-chars)))))
              (should (string-search "caf%C3%A9" (car cooked--directory-report)))
              (should (equal default-directory (file-name-as-directory dir))))))
      (delete-directory parent t))))

(ert-deftest cooked-osc-7-repeated-report-does-no-work ()
  "The shell reports its directory at every prompt, moved or not.  An identical
report does no stat and no rename -- unless \\[cd] in the buffer has moved
`default-directory\=' since, in which case the report puts it back."
  (let ((here (file-name-as-directory (make-temp-file "cooked-osc7-" t)))
        (stats 0)
        (renames 0))
    (unwind-protect
        (with-temp-buffer
          (cooked-mode)
          (let ((url (list (format "file://%s%s" (system-name) here))))
            (cl-letf* ((real-directory-p (symbol-function 'file-directory-p))
                       ((symbol-function 'file-directory-p)
                        (lambda (name) (cl-incf stats) (funcall real-directory-p name)))
                       (real-rename (symbol-function 'cooked--update-buffer-name))
                       ((symbol-function 'cooked--update-buffer-name)
                        (lambda () (cl-incf renames) (funcall real-rename))))
              (cooked--osc-cwd url)
              (should (equal default-directory here))
              (should (equal (list stats renames) '(1 1)))
              (dotimes (_ 5) (cooked--osc-cwd url))
              (should (equal (list stats renames) '(1 1)))
              (setq default-directory "/")
              (cooked--osc-cwd url)
              (should (equal default-directory here))
              (should (equal (list stats renames) '(2 2))))))
      (delete-directory here t))))

;; The OSC 7 remote branch.  Every test here asserts about a *string*: setting
;; `default-directory' to a TRAMP name opens nothing, and `file-remote-p' is pure
;; parsing, so the whole group runs without a network and must keep doing so --
;; the one call that would connect is the `file-directory-p' the branch does not
;; make, and the first test below is what holds it out.

(ert-deftest cooked-osc-7-maps-a-foreign-host-onto-a-tramp-path ()
  "ROADMAP §5's scenario: after an outbound `ssh\=', the shell's own report of
where it is becomes a `default-directory\=' Emacs can act on, so \\[find-file]
opens the file the prompt meant instead of a same-named local one.

No `file-directory-p\=', and that is the load-bearing half.  Validating the name
would open a synchronous TRAMP connection on every `cd\=' -- the shell's report
is trusted precisely because it is the only account available for free."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let ((default-directory "/tmp/")
          (cooked-tramp-default-method "ssh")
          (asked nil))
      (cl-letf (((symbol-function 'file-directory-p)
                 (lambda (&rest _) (setq asked t) t)))
        (cooked--osc-cwd '("file://other.example/srv/app"))
        (should (equal default-directory "/ssh:other.example:/srv/app/"))
        (should-not asked)
        ;; And it tracks, rather than landing once: a second `cd' is a second
        ;; rewrite and still not a connection.
        (cooked--osc-cwd '("file://other.example/srv/app/lib"))
        (should (equal default-directory "/ssh:other.example:/srv/app/lib/"))
        (should-not asked)))))

(ert-deftest cooked-osc-7-takes-the-tramp-host-from-the-report-never-the-payload ()
  "The hostile-`cat\=' defence, on the branch that cannot use `cooked--local-name\='.

OSC 7 is always on, so any program that can write to the terminal can send one,
and a TRAMP name assembled out of the payload is a way to make Emacs dial a
machine the sender chose.  Both halves of the URL are attacker-chosen strings and
TRAMP's syntax is punctuation, so both halves are checked here.

The path half may say whatever it likes: appended after a complete
`/method:host:\=' prefix it is a localname, so `/ssh:evil.example:/etc\=' names a
file that does not exist on the host we were already talking about, and not a
hop to `evil.example\='.

The authority half is the one that could choose a method, and it is refused
outright rather than quoted.  `a|sudo:\=' is a perfectly good `[^/]*\=' match and
percent-decodes out of an innocent-looking URL; formatted into `/ssh:%s:\=' it
would read as a second hop to root.  A host containing TRAMP punctuation is not
a host anyone has, so there is nothing to lose by declining it."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let ((default-directory "/tmp/")
          (cooked-tramp-default-method "ssh"))
      ;; The path half is attacker-chosen and that is allowed to be true.
      (cooked--osc-cwd '("file://other.example/ssh:evil.example:/etc"))
      (should (equal (file-remote-p default-directory 'host) "other.example"))
      (should (equal default-directory
                     "/ssh:other.example:/ssh:evil.example:/etc/"))
      ;; A `sudo' hop written into the authority, percent-encoded so that the URL
      ;; on the wire looks like nothing at all.  Declined, leaving the last
      ;; directory cooked could vouch for.
      (setq default-directory "/tmp/")
      (cooked--osc-cwd '("file://a%7Csudo%3A/etc"))
      (should (equal default-directory "/tmp/"))
      ;; Same move without the encoding, and the same answer.
      (cooked--osc-cwd '("file://evil.example|sudo:/etc"))
      (should (equal default-directory "/tmp/"))
      ;; A bare method separator is no better: `/ssh:a:b::/etc' is a host `a'
      ;; with a port, reached by a method the payload named.
      (cooked--osc-cwd '("file://a:b:/etc"))
      (should (equal default-directory "/tmp/"))
      ;; Refusing is about the punctuation, not about being unfriendly: an
      ;; ordinary name with dots, hyphens and digits still maps.
      (cooked--osc-cwd '("file://build-07.ci.example/srv"))
      (should (equal default-directory "/ssh:build-07.ci.example:/srv/")))))

(ert-deftest cooked-osc-7-keeps-a-multi-hop-connection-across-a-cd ()
  "Reuse the prefix that is already there, rather than formatting a fresh one.

A buffer reached through a bastion is at `/ssh:jump|ssh:host:\=', and a `cd\=' on
the far side must not flatten that to `/ssh:host:\=' -- the whole reason the jump
is in the name is that the host is not reachable without it.  Reusing the prefix
keeps the user and the method that were actually connected with, too."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let ((default-directory "/ssh:jump.example|ssh:me@other.example:/tmp/")
          (cooked-tramp-default-method "ssh"))
      (cooked--osc-cwd '("file://other.example/srv/app"))
      (should (equal default-directory
                     "/ssh:jump.example|ssh:me@other.example:/srv/app/"))
      ;; The short spelling the far shell's `HOST' actually sends is the same
      ;; machine as the qualified one in the prefix, and must not read as a move.
      (cooked--osc-cwd '("file://other/srv/lib"))
      (should (equal default-directory
                     "/ssh:jump.example|ssh:me@other.example:/srv/lib/")))))

(ert-deftest cooked-osc-7-rebuilds-the-prefix-when-the-far-shell-moves-on ()
  "An `ssh\=' *from* the far shell moves `cooked--host\=' and leaves the prefix
behind.  Inheriting it then would hang the new host's paths off the old host's
connection -- the wrong-file error this handler exists to avoid, arrived at from
the other side."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let ((default-directory "/ssh:first.example:/tmp/")
          (cooked-tramp-default-method "ssh"))
      (cooked--osc-cwd '("file://second.example/srv"))
      (should (equal default-directory "/ssh:second.example:/srv/")))))

(ert-deftest cooked-osc-7-remote-mapping-can-be-turned-off ()
  "`cooked-remote-directory\=' nil is what cooked did before the mapping existed:
stop at `cooked--host\=', leaving `default-directory\=' where it was.  Still the
right answer for anyone who would rather a foreign prompt resolve nothing."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let ((default-directory "/tmp/")
          (cooked-remote-directory nil))
      (cooked--osc-cwd '("file://other.example/srv/app"))
      (should (equal default-directory "/tmp/"))
      ;; The host still moved, because that is what the mode line and the
      ;; buffer name are reading.
      (should (cooked--foreign-host-p))
      (should (equal cooked--host "other.example")))))

(ert-deftest cooked-osc-7-falls-back-to-tramps-own-default-method ()
  "`cooked-tramp-default-method\=' nil defers to TRAMP rather than picking a
method of cooked's own, so a user who has already chosen one chooses once."
  (require 'tramp)
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let ((default-directory "/tmp/")
          (cooked-tramp-default-method nil))
      (cooked--osc-cwd '("file://other.example/srv"))
      (should (equal default-directory
                     (format "/%s:other.example:/srv/" tramp-default-method))))))

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
to be under test at all.  SECONDS is scaled by `cooked-tests-timeout\='."
  (let ((deadline (+ (float-time) (cooked-tests-timeout (or seconds 5)))))
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
  :tags '(zsh)
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
  :tags '(zsh)
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
  :tags '(zsh)
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
  :tags '(zsh)
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
  :tags '(zsh)
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
  :tags '(zsh)
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
  :tags '(zsh)
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
  :tags '(zsh)
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
  :tags '(zsh)
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
  :tags '(zsh)
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
  :tags '(zsh)
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

;; `+' and `/' are two of the sixty-four characters of the standard alphabet, so
;; most real text encodes with at least one of them.  `<<??>>' is `PDw/Pz4+'.
(ert-deftest cooked-osc-52-decodes-the-standard-base64-alphabet ()
  (with-temp-buffer
    (let ((kill-ring nil)
          (cooked-clipboard-write t)
          (inhibit-message t))
      (cooked--osc-52-write '(?c) "PDw/Pz4+")
      (should (equal (car kill-ring) "<<??>>"))
      ;; Unpadded, and multibyte: `héllo ?>~ ü' with its trailing `==' stripped.
      (cooked--osc-52-write '(?c) "aMOpbGxvID8+fiDDvA")
      (should (equal (car kill-ring) "héllo ?>~ ü"))
      ;; Not base64 at all is dropped rather than half-copied.
      (cooked--osc-52-write '(?c) "not base64!")
      (should (equal (car kill-ring) "héllo ?>~ ü")))))

(ert-deftest cooked-decode-base64-refuses-garbage-and-restores-padding ()
  (should (equal (cooked--decode-base64 "aGk") "hi"))
  (should (equal (cooked--decode-base64 "aGk=") "hi"))
  (should (equal (cooked--decode-base64-utf8 "w7w") "ü"))
  (should-not (cooked--decode-base64 "a"))
  (should-not (cooked--decode-base64 "*!*!"))
  (should-not (cooked--decode-base64 nil)))

(defmacro cooked-tests--osc-52-replies (query &rest body)
  "Run BODY in a session that sends QUERY, with `replies' bound to a function.

Calling `replies' with a predicate pumps until the child\='s input satisfies it,
then pumps a little longer so that a second, unwanted reply has time to land,
and returns everything the child received."
  (declare (indent 1))
  `(let ((out (make-temp-file "cooked-osc52")))
     (unwind-protect
         (cooked-tests--with-session (cooked-tests--reply-to ,query out)
           (cl-flet ((replies (done)
                       (should (cooked-tests--settle
                                (lambda () (funcall done (cooked-tests--contents out)))))
                       (cooked-tests--settle #'ignore 0.3)
                       (cooked-tests--contents out)))
             ,@body))
       (delete-file out))))

(ert-deftest cooked-osc-52-read-is-refused-out-loud-by-default ()
  "A query blocks its sender -- neovim\='s paste provider waits on it -- so the
refusal is an empty reply, sent once, and the kill ring is neither read nor
touched."
  (cooked-tests--with-kill "secret"
    (cooked-tests--osc-52-replies "\\033]52;c;?\\007"
      (should (equal (replies (lambda (s) (not (string-empty-p s))))
                     "\033]52;c;\007"))
      (should (equal kill-ring '("secret"))))))

(ert-deftest cooked-osc-52-read-echoes-the-terminator-and-the-target ()
  (cooked-tests--osc-52-replies "\\033]52;p;?\\033\\\\"
    (should (equal (replies (lambda (s) (string-suffix-p "\033\\" s)))
                   "\033]52;p;\033\\"))))

(ert-deftest cooked-osc-52-private-round-trips-through-a-cut-buffer ()
  "Written to `0\=', read back from `0\=', and never near the kill ring --
while the real clipboard, asked for in the same breath, stays empty."
  (cooked-tests--with-kill "secret"
    (let ((cooked-clipboard-read 'private))
      (cooked-tests--osc-52-replies
          "\\033]52;0;aGVsbG8=\\007\\033]52;0;?\\007\\033]52;c;?\\007"
        (should (equal (replies (lambda (s) (string-search "52;c;" s)))
                       "\033]52;0;aGVsbG8=\007\033]52;c;\007"))
        (should (equal kill-ring '("secret")))))))

(ert-deftest cooked-osc-52-default-reads-no-cut-buffer-either ()
  (let ((cooked-clipboard-read nil))
    (cooked-tests--osc-52-replies "\\033]52;0;aGVsbG8=\\007\\033]52;0;?\\007"
      (should (equal (replies (lambda (s) (not (string-empty-p s))))
                     "\033]52;0;\007")))))

(ert-deftest cooked-osc-52-t-answers-from-the-kill-ring-and-primary ()
  (cooked-tests--with-kill "héllo"
    (cl-letf (((symbol-function 'gui-get-selection)
               (lambda (type &rest _) (and (eq type 'PRIMARY) "primary"))))
      (let ((cooked-clipboard-read t))
        (cooked-tests--osc-52-replies "\\033]52;c;?\\007\\033]52;p;?\\007"
          (should (equal (replies (lambda (s) (string-search "52;p;" s)))
                         (concat "\033]52;c;"
                                 (base64-encode-string
                                  (encode-coding-string "héllo" 'utf-8) t)
                                 "\007\033]52;p;cHJpbWFyeQ==\007"))))))))

(ert-deftest cooked-osc-52-ask-answers-once-whichever-way-it-goes ()
  "The prompt names the program and runs outside the filter; a no is still a
reply, and a second query while the prompt is open is refused rather than
queued behind it."
  (dolist (yes '(t nil))
    (cooked-tests--with-kill "secret"
      (let ((cooked-clipboard-read 'ask)
            (prompts nil))
        (cl-letf (((symbol-function 'yes-or-no-p)
                   (lambda (prompt) (push prompt prompts) yes)))
          (cooked-tests--osc-52-replies "\\033]52;c;?\\007\\033]52;c;?\\007"
            (should (equal (replies (lambda (s) (>= (cl-count ?\a s) 2)))
                           (concat "\033]52;c;\007"
                                   "\033]52;c;" (if yes "c2VjcmV0" "") "\007")))
            (should (= (length prompts) 1))
            (should (string-match-p "clipboard" (car prompts)))
            (should-not cooked--clipboard-prompting)))))))

(defmacro cooked-tests--osc-52-ask (answer &rest body)
  "Run BODY around an OSC 52 query under `ask\=', answered by ANSWER.

ANSWER is called in place of both `y-or-n-p\=' and `yes-or-no-p\=' with the
prompt.  BODY sees `query\=', which asks for the clipboard as `cat\=' and
returns the deferred prompt without running it, `replies\=', the payloads sent
so far, and `prompts\=', the prompts shown."
  (declare (indent 1))
  `(cooked-tests--with-kill "secret"
     (with-temp-buffer
       (let ((cooked-clipboard-read 'ask)
             (program "cat")
             (deferred nil)
             (replies nil)
             (prompts nil))
         (cl-letf (((symbol-function 'y-or-n-p) ,answer)
                   ((symbol-function 'yes-or-no-p) ,answer)
                   ((symbol-function 'cooked--foreground-program) (lambda () program))
                   ((symbol-function 'cooked--defer) (lambda (f) (setq deferred f)))
                   ((symbol-function 'cooked--osc-52-reply)
                    (lambda (_target payload) (push payload replies))))
           (cl-flet ((query ()
                       (cooked--osc-52-query '(?c))
                       ;; The query has returned; the child is gone by the time
                       ;; the prompt runs.
                       (setq program "zsh")
                       deferred))
             ,@body))))))

(ert-deftest cooked-osc-52-ask-is-not-answered-by-typeahead ()
  "A `y\=' already queued when the prompt opens does not hand over the clipboard.

The stub answers yes to any prompt that finds a `y\=' waiting, as `y-or-n-p\='
does, so only discarding the input first keeps it out.  The prompt must also
refuse the short answers a single key could give, and name the buffer and the
program that asked, as it was when it asked."
  (cooked-tests--osc-52-ask
      (lambda (prompt)
        (push prompt prompts)
        (should-not use-short-answers)
        (eq (car unread-command-events) ?y))
    (let ((prompt (query))
          (use-short-answers t))
      (let ((unread-command-events (list ?y)))
        (funcall prompt))
      (should (equal replies '("")))
      (should (string-search "cat" (car prompts)))
      (should (string-search (buffer-name) (car prompts)))
      (should-not cooked--clipboard-prompting))))

(ert-deftest cooked-osc-52-ask-answers-empty-when-the-prompt-fails ()
  "An error inside the prompt is an empty reply, since the child still waits.

For example a daemon with no usable frame to prompt on."
  (cooked-tests--osc-52-ask
      (lambda (_prompt) (error "No usable frame"))
    (let ((inhibit-message t))
      (ignore-errors (funcall (query))))
    (should (equal replies '("")))
    (should-not cooked--clipboard-prompting)))

(ert-deftest cooked-osc-52-read-over-the-size-bound-is-answered-empty ()
  "`cooked-clipboard-max-size\=' bounds replies as it bounds writes.  A kill that
would encode past it gets the empty reply, once, so the child is not left
waiting, and a message says why the paste came back blank.  Both settings that
can hand over the kill ring are checked, since `ask\=' builds its reply in a
deferred prompt rather than in the filter."
  (dolist (setting '(t ask))
    (cooked-tests--with-kill "0123456789"
      (let ((cooked-clipboard-read setting)
            ;; Ten bytes encode to sixteen characters.
            (cooked-clipboard-max-size 15)
            (refusals nil))
        (cl-letf* ((real-message (symbol-function 'message))
                   ((symbol-function 'message)
                    (lambda (fmt &rest args)
                      (when (and fmt (string-search "cooked-clipboard-max-size" fmt))
                        (push (apply #'format fmt args) refusals))
                      (apply real-message fmt args)))
                   ((symbol-function 'yes-or-no-p) (lambda (_) t)))
          (cooked-tests--osc-52-replies "\\033]52;c;?\\007"
            (should (equal (replies (lambda (s) (not (string-empty-p s))))
                           "\033]52;c;\007"))
            (should (equal refusals
                           '("cooked: answered a clipboard read with nothing, as its 16 characters exceed `cooked-clipboard-max-size'")))
            (should (equal kill-ring '("0123456789")))))))))

(ert-deftest cooked-osc-52-read-at-the-size-bound-is-answered ()
  (cooked-tests--with-kill "0123456789"
    (let ((cooked-clipboard-read t)
          (cooked-clipboard-max-size 16))
      (cooked-tests--osc-52-replies "\\033]52;c;?\\007"
        (should (equal (replies (lambda (s) (not (string-empty-p s))))
                       "\033]52;c;MDEyMzQ1Njc4OQ==\007"))))))

(ert-deftest cooked-osc-52-read-is-measured-before-it-is-encoded ()
  "An oversized selection is refused on its byte count, without being encoded.

The count is exact for UTF-8 text, so `héllo\=' at six bytes needs its full
eight characters of base64 and is refused at seven.  A query loop against the
same oversized kill says so once rather than once per query."
  (with-temp-buffer
    (let ((encodes 0)
          (said nil))
      (cl-letf* ((real-encode (symbol-function 'base64-encode-string))
                 ((symbol-function 'base64-encode-string)
                  (lambda (&rest args) (cl-incf encodes) (apply real-encode args)))
                 ((symbol-function 'message)
                  (lambda (fmt &rest args) (push (apply #'format fmt args) said))))
        (let ((cooked-clipboard-max-size 7))
          (dotimes (_ 3)
            (should (equal (cooked--osc-52-encode "héllo") ""))))
        (should (= encodes 0))
        (should (= (length said) 1))
        (should (string-search "its 8 characters" (car said)))
        (let ((cooked-clipboard-max-size 8))
          (should (equal (cooked--osc-52-encode "héllo") "aMOpbGxv")))))))

(ert-deftest cooked-osc-52-write-is-bounded-by-what-can-be-read-back ()
  "An unpadded write is measured padded, since that is what a query answers with.

`aMOpbGxvID8+fiDDvA\=' is eighteen characters, and the cut buffer it fills reads
back as twenty.  Accepting it under a bound of eighteen would store text that
every later query is refused."
  (with-temp-buffer
    (let ((cooked-clipboard-read 'private)
          (cooked-clipboard-max-size 18)
          (inhibit-message t))
      (cooked--osc-52-write '(?0) "aMOpbGxvID8+fiDDvA")
      (should-not cooked--cut-buffers)
      (setq cooked-clipboard-max-size 20)
      (cooked--osc-52-write '(?0) "aMOpbGxvID8+fiDDvA")
      (should (equal (cooked--osc-52-encode (aref cooked--cut-buffers 0))
                     "aMOpbGxvID8+fiDDvA==")))))

(ert-deftest cooked-osc-52-bound-cannot-exceed-the-cores ()
  "Raising `cooked-clipboard-max-size\=' past the core\='s OSC limit raises nothing.

A write the core would have dropped unseen is refused in Lisp with a message
instead, and a reply the core\='s limit could not have carried is refused too."
  (with-temp-buffer
    (let ((cooked-clipboard-max-size (ash 1 22))
          (cooked-clipboard-write t)
          (kill-ring nil)
          (said nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (push (apply #'format fmt args) said))))
        (cooked--osc-52-write '(?c) (make-string (+ cooked--osc-52-core-limit 4) ?A))
        (should-not kill-ring)
        (should (string-search "refused" (car said)))
        (should (equal (cooked--osc-52-encode
                        (make-string (* 3 (1+ (/ cooked--osc-52-core-limit 4))) ?a))
                       ""))
        (should (string-search "answered a clipboard read with nothing" (car said)))))))

(ert-deftest cooked-osc-52-cut-buffer-writes-ignore-the-write-switch ()
  "A cut buffer is the session\='s own, so refusing clipboard writes does not
refuse it, and filling it does not touch the kill ring."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let ((cooked-clipboard-write nil)
          (cooked-clipboard-read 'private)
          (kill-ring nil))
      (cooked--osc-clipboard '("3" "aGVsbG8="))
      (should-not kill-ring)
      (should (equal (aref cooked--cut-buffers 3) "hello")))))

(ert-deftest cooked-osc-52-read-names-every-target-and-answers-the-first-with-text ()
  "The reply echoes the targets as asked, as xterm does, and its payload comes
from the first of them that has something to give under the setting."
  (cooked-tests--osc-52-replies "\\033]52;cp;?\\007"
    (should (equal (replies (lambda (s) (not (string-empty-p s))))
                   "\033]52;cp;\007")))
  ;; `s' is shared and so empty under `private'; the cut buffer after it answers.
  (let ((cooked-clipboard-read 'private))
    (cooked-tests--osc-52-replies
        "\\033]52;0;aGVsbG8=\\007\\033]52;s0;?\\007"
      (should (equal (replies (lambda (s) (not (string-empty-p s))))
                     "\033]52;s0;aGVsbG8=\007"))))
  ;; An empty kill ring falls through to PRIMARY.
  (cooked-tests--with-kill ""
    (cl-letf (((symbol-function 'gui-get-selection)
               (lambda (type &rest _) (and (eq type 'PRIMARY) "primary"))))
      (let ((cooked-clipboard-read t))
        (cooked-tests--osc-52-replies "\\033]52;cp;?\\007"
          (should (equal (replies (lambda (s) (not (string-empty-p s))))
                         "\033]52;cp;cHJpbWFyeQ==\007")))))))

(ert-deftest cooked-osc-52-empty-write-clears-rather-than-copies-nothing ()
  "`52;c;\=' is not a copy of the empty string: the kill ring is left as it was
and nothing says a copy happened, while PRIMARY and a cut buffer are cleared."
  (with-temp-buffer
    (let ((cooked-clipboard-write t)
          (cooked-clipboard-read 'private)
          (kill-ring (list "kept"))
          (selections nil)
          (messages nil))
      (cl-letf (((symbol-function 'gui-set-selection)
                 (lambda (type value) (push (cons type value) selections)))
                ((symbol-function 'message)
                 (lambda (&rest args) (push args messages))))
        (cooked--osc-52-write '(?0) "aGVsbG8=")
        (should (equal (aref cooked--cut-buffers 0) "hello"))
        (cooked--osc-52-write '(?c ?p ?0) "")
        (should (equal kill-ring '("kept")))
        (should-not messages)
        (should (equal selections '((PRIMARY . nil))))
        (should-not (aref cooked--cut-buffers 0))
        ;; Not base64 at all clears as well, as xterm does.
        (cooked--osc-52-write '(?q) "not base64!")
        (should (equal (car selections) '(SECONDARY . nil)))
        (should (equal kill-ring '("kept")))))))

(ert-deftest cooked-osc-52-default-keeps-no-cut-buffer ()
  "Under nil nothing reads a cut buffer back, so a write to one is not kept."
  (with-temp-buffer
    (let ((cooked-clipboard-read nil)
          (inhibit-message t))
      (cooked--osc-52-write '(?0 ?7) "aGVsbG8=")
      (should-not cooked--cut-buffers))))

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

(ert-deftest cooked-osc-10-and-11-answer-the-colours-the-buffer-draws ()
  "A query after an OSC 11 set gets the colour set, and under DECSCNM the swap.
The answer used to be the theme\='s face, read without the buffer\='s remaps, so a
child was told a background it had already replaced; xterm answers from the
colours it draws, which DECSCNM exchanges."
  (let ((out (make-temp-file "cooked-osc-drawn"))
        (cooked-allow-color-set t))
    (unwind-protect
        (cooked-tests--with-session
            (cooked-tests--reply-to "\\033]11;#ff0000\\007\\033[?5h\\033]10;?;?\\007" out)
          (let ((foreground (cooked--default-color 'foreground)))
            (should (cooked-tests--settle
                     (lambda () (string-match-p "11;rgb:" (cooked-tests--contents out)))))
            (should (equal (cooked-tests--contents out)
                           (format "\033]10;rgb:ffff/0000/0000\007\033]11;%s\007"
                                   (cooked--color-to-osc foreground))))
            ;; And the scheme `CSI ? 996 n' is answered with reads that background.
            (should (eq (cooked--color-scheme)
                        (if (color-dark-p (mapcar (lambda (v) (/ v 65535.0))
                                                  (color-values foreground)))
                            'dark
                          'light)))))
      (delete-file out))))

(ert-deftest cooked-osc-4-sweep-is-answered-in-one-write ()
  "A theme picker asking for all 256 palette entries gets them back in one write.

Each answer used to be its own synchronous write to the pty, so the sweep cost
256 of them, each able to stall on a child that had stopped reading.  The
queries go out from a file in one `cat', so they reach the core in one read and
Lisp in one drain."
  (let ((out (make-temp-file "cooked-osc4-sweep"))
        (queries (make-temp-file "cooked-osc4-queries"))
        (writes nil)
        (reply (symbol-function 'cooked--reply)))
    (unwind-protect
        (progn
          (with-temp-file queries
            (dotimes (n 256) (insert (format "\e]4;%d;?\a" n))))
          (cl-letf (((symbol-function 'cooked--reply)
                     (lambda (session bytes)
                       (when (string-match-p "\e]4;" bytes) (push bytes writes))
                       (funcall reply session bytes))))
            (cooked-tests--with-session
                (list "/bin/sh" "-c"
                      (format "stty raw -echo; cat %s; cat > %s" queries out))
              (should (cooked-tests--settle
                       (lambda () (string-match-p "4;255;rgb:"
                                                  (cooked-tests--contents out)))))
              (should (= 1 (length writes)))
              (should (equal (cooked-tests--contents out) (car writes)))
              (should (string-prefix-p "\e]4;0;rgb:" (car writes))))))
      (delete-file out)
      (delete-file queries))))

(ert-deftest cooked-a-frozen-buffer-keeps-a-colour-answer-ahead-of-da1 ()
  "DA1 behind a colour query waits with the query for the thaw, and follows it.

A program asks for the background and then DA1, and takes DA1 answered first
as the colour never coming.  Only Lisp can answer the colour, and a frozen
buffer does not drain, so the core must not send DA1 on ahead of it."
  (let ((out (make-temp-file "cooked-frozen-osc11"))
        (flag (make-temp-name (expand-file-name "cooked-frozen-flag"
                                                temporary-file-directory))))
    (unwind-protect
        (cooked-tests--with-session
            (list "/bin/sh" "-c"
                  (format "stty raw -echo; printf ready; until [ -e %s ]; do sleep 0.02; done; printf '\\033]11;?\\033\\\\\\033[c'; cat > %s"
                          flag out))
          (should (cooked-tests--settle
                   (lambda () (string-match-p "ready" (cooked-tests--text)))))
          (setq cooked--input-mode 'frozen)
          (write-region "" nil flag)
          (cooked-tests--pump 0.5)
          (should (equal "" (cooked-tests--contents out)))
          (setq cooked--input-mode nil)
          (should (cooked-tests--settle
                   (lambda () (string-suffix-p "c" (cooked-tests--contents out)))))
          (should (string-match-p "\\`\e\\]11;rgb:[^\e]+\e\\\\\e\\[\\?62[;0-9]*c\\'"
                                  (cooked-tests--contents out))))
      (delete-file out)
      (ignore-errors (delete-file flag)))))

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

(ert-deftest cooked-osc-4-answers-palette-queries-and-ignores-sets ()
  "Each entry is answered in xterm's form from the colour a cell is drawn in, and
a set in front of them produces neither a reply nor a change.

The expected colours are read before the child sends its set.  Read after it,
they would move with a set that took effect, and the comparison would still
hold."
  (let ((out (make-temp-file "cooked-osc4"))
        (expected (mapconcat
                   (lambda (n)
                     (format "\033]4;%d;%s\007"
                             n (cooked--color-to-osc (cooked--color n))))
                   '(1 196 244))))
    (unwind-protect
        (cooked-tests--with-session
            (cooked-tests--reply-to
             (concat "\\033]4;196;rgb:0/f/0\\007"
                     "\\033]4;1;?\\007\\033]4;196;?\\007\\033]4;244;?\\007")
             out)
          (should (cooked-tests--settle
                   (lambda () (string-match-p "244;rgb:" (cooked-tests--contents out)))))
          (should (equal (cooked-tests--contents out) expected))
          (should (string-match-p
                   "\\`\\(\033\\]4;[0-9]+;rgb:[0-9a-f]\\{4\\}/[0-9a-f]\\{4\\}/[0-9a-f]\\{4\\}\007\\)\\{3\\}\\'"
                   (cooked-tests--contents out))))
      (delete-file out))))

(ert-deftest cooked-osc-4-walks-its-pairs ()
  "A chained query gets one reply per `?', a bad index is skipped without
shifting the pairs after it, and a set stays silent even with sets allowed."
  (let ((replies nil)
        (before (cooked--color 1))
        (cooked-allow-color-set t)
        (cooked--osc-bell-terminated nil))
    (cl-letf (((symbol-function 'cooked--reply-osc)
               (lambda (_session code payload bell)
                 (push (list code payload bell) replies))))
      (with-temp-buffer
        (cooked--osc-palette '("1" "#00ff00" "x" "?" "256" "?" "7" "?" "9"))
        (should-not face-remapping-alist))
      (should (equal (mapcar #'car replies) '(4)))
      (should (string-prefix-p "7;rgb:" (nth 1 (car replies))))
      (should-not (nth 2 (car replies)))
      (should (equal (cooked--color 1) before)))))

(ert-deftest cooked-osc-17-and-19-answer-from-the-region-face ()
  "The selection colours are read, chained through 18, and never set."
  (let ((replies nil)
        (cooked-allow-color-set t)
        (cooked--osc-bell-terminated t))
    (cl-letf (((symbol-function 'cooked--reply-osc)
               (lambda (_session code payload _bell)
                 (push (cons code payload) replies))))
      (with-temp-buffer
        (let ((cooked--osc-code 17))
          (cooked--osc-color '("?" "?" "?")))
        (should (equal (mapcar #'car (reverse replies)) '(17 18 19)))
        (should (equal (cdr (assq 17 replies))
                       (cooked--color-to-osc
                        (cooked--default-color 'highlight-background))))
        (dolist (code '(17 19))
          (let ((cooked--osc-code code))
            (cooked--osc-color '("#ff0000"))))
        (should-not cooked--color-remaps)
        (should-not face-remapping-alist)))))

(ert-deftest cooked-osc-13-to-18-answer-a-lone-query ()
  "Every colour xterm answers from 10 to 19 is answered, so a child asking one of
them alone is not left waiting.  The pointer is the `mouse' face over the
default background, and xterm\='s Tektronix window, which is not here, has the
default colours and the cursor\='s.  None of them is settable."
  (let ((out (make-temp-file "cooked-osc-13")))
    (unwind-protect
        (cooked-tests--with-session
            (cooked-tests--reply-to
             (mapconcat (lambda (code) (format "\\033]%d;?\\007" code))
                        '(13 14 15 16 18) "")
             out)
          (should (cooked-tests--settle
                   (lambda () (string-match-p "18;rgb:" (cooked-tests--contents out)))))
          (should (equal (cooked-tests--contents out)
                         (mapconcat
                          (pcase-lambda (`(,code . ,kind))
                            (format "\033]%d;%s\007" code
                                    (cooked--color-to-osc (cooked--default-color kind))))
                          '((13 . pointer-foreground) (14 . background)
                            (15 . foreground) (16 . background) (18 . cursor))
                          "")))
          (let ((cooked--osc-bell-terminated t)
                (cooked-allow-color-set t))
            (dolist (code '(13 14 15 16 18))
              (let ((cooked--osc-code code))
                (cooked--osc-color '("#ff0000"))))
            (should-not cooked--color-remaps)
            (should-not cooked--cursor-color)))
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

(ert-deftest cooked-osc-12-is-worn-by-the-frame-while-the-buffer-is-selected ()
  "The cursor is drawn in the frame\='s `cursor-color\=', so a remap of the `cursor\='
face never reached the screen.  The frame wears the child\='s colour while the
buffer is in its selected window, gives its own back when it is not, and gives
back a colour something else set in the meantime rather than the stale one.

Batch runs no redisplay, so the window hooks are run here where redisplay would
run them, by their global values: the buffer leaving the window and coming back,
and the selection moving to another window and back."
  (let* ((frame (selected-frame))
         (window (selected-window))
         (before (window-buffer window))
         (own (frame-parameter frame 'cursor-color))
         (other (generate-new-buffer " other")))
    (unwind-protect
        (cooked-tests--with-session
            '("/bin/sh" "-c" "sleep 0.3; printf '\033]12;#ff0000\007'; sleep 5")
          (set-window-buffer window (current-buffer))
          (let ((cooked-allow-color-set t))
            (should (cooked-tests--settle (lambda () cooked--cursor-color))))
          (should (equal (frame-parameter frame 'cursor-color) "#ff0000"))
          (should-not (alist-get 'cursor face-remapping-alist))
          ;; A query answers with the colour set, and a query from a buffer that
          ;; set none answers with the frame's own, not the one it is wearing.
          (should (equal (cooked--default-color 'cursor) "#ff0000"))
          (with-current-buffer other
            (should (equal (cooked--default-color 'cursor) own)))
          (set-window-buffer window other)
          (run-hook-with-args 'window-buffer-change-functions frame)
          (should (equal (frame-parameter frame 'cursor-color) own))
          (should-not (frame-parameter frame 'cooked--cursor-color))
          (set-window-buffer window (current-buffer))
          (run-hook-with-args 'window-buffer-change-functions frame)
          (should (equal (frame-parameter frame 'cursor-color) "#ff0000"))
          (let ((beside (split-window window)))
            (set-window-buffer beside other)
            (select-window beside)
            (run-hook-with-args 'window-selection-change-functions frame)
            (should (equal (frame-parameter frame 'cursor-color) own))
            (select-window window)
            (run-hook-with-args 'window-selection-change-functions frame)
            (should (equal (frame-parameter frame 'cursor-color) "#ff0000"))
            (delete-window beside))
          ;; What a theme does underneath: the frame's own colour changes while
          ;; the child's is worn, and that is the colour given back.
          (set-frame-parameter frame 'cursor-color "#00ff00")
          (cooked--sync-cursor-color frame)
          (should (equal (frame-parameter frame 'cursor-color) "#ff0000"))
          (let ((cooked--osc-code 112))
            (cooked--osc-color-reset nil))
          (should-not cooked--cursor-color)
          (should (equal (frame-parameter frame 'cursor-color) "#00ff00")))
      (set-window-buffer window before)
      (kill-buffer other)
      (set-frame-parameter frame 'cooked--cursor-color nil)
      (set-frame-parameter frame 'cursor-color own))))

(defun cooked-tests--osc-22-query-reply (graphic)
  "What a real child is told for six OSC 22 names.
GRAPHIC non-nil stands in for a graphical frame; nil leaves the batch frame,
which is a text terminal's."
  (let ((out (make-temp-file "cooked-osc22")))
    (unwind-protect
        (cl-letf (((symbol-function 'cooked--pointer-displayable-p)
                   (if graphic
                       (lambda () t)
                     (symbol-function 'cooked--pointer-displayable-p))))
          (unless graphic (should-not (display-graphic-p)))
          (cooked-tests--with-session
              (cooked-tests--reply-to
               "\\033]22;?pointer,crosshair,ew-resize,__current__,__default__,__grabbed__\\033\\\\" out)
            (should (cooked-tests--settle
                     (lambda () (string-suffix-p "\033\\" (cooked-tests--contents out)))))
            (cooked-tests--contents out)))
      (delete-file out))))

(ert-deftest cooked-osc-22-query-says-which-shapes-can-be-shown ()
  "One answer per name, in order: 1 for a shape Emacs has a pointer for, 0 for
one it has not, the top of the stack -- empty, so 0 -- for `__current__',
Emacs' own text pointer for `__default__', and the arrow shown while the child
has the mouse, by its CSS name, for `__grabbed__'."
  (should (equal (cooked-tests--osc-22-query-reply t)
                 "\033]22;1,0,1,0,text,default\033\\"))
  (let ((cooked-grabbed-pointer-shape nil))
    (should (equal (cooked-tests--osc-22-query-reply t)
                   "\033]22;1,0,1,0,text,text\033\\"))))

(ert-deftest cooked-osc-22-query-supports-nothing-where-no-pointer-is-seen ()
  "On a text terminal, and with the knob off, a real child is told no shape is
supported, since a set would change nothing it could see."
  (should (equal (cooked-tests--osc-22-query-reply nil)
                 "\033]22;0,0,0,0,text,default\033\\"))
  (let ((cooked-allow-pointer-shape nil))
    (should (equal (cooked-tests--osc-22-query-reply t)
                   "\033]22;0,0,0,0,text,default\033\\"))))

(ert-deftest cooked-osc-22-empty-set-resets-and-a-full-stack-drops-its-bottom ()
  "kitty's `ESC ] 22 ; ST' resets the top of the stack to the default pointer
and leaves what is under it for the pop; a 17th push drops the oldest shape;
and turning the knob off takes a shape on show away at once."
  (cooked-tests--with-session '("/bin/sh" "-c" "stty -icanon -echo; printf '\\033[?1000h'; exec sleep 30")
    (should (cooked-tests--settle (lambda () cooked--mouse-grab)))
    (cl-flet ((shown () (and cooked--pointer-overlay
                             (overlay-get cooked--pointer-overlay 'pointer)))
              (stack () (alist-get 'main cooked--pointer-stacks))
              (osc (payload) (cooked--osc-pointer-shape (list payload))))
      ;; Nothing to reset on an empty stack.
      (osc "")
      (should-not cooked--pointer-stacks)
      (dolist (reset '("" "="))
        (osc ">text,pointer")
        (should (eq (shown) 'hand))
        (osc reset)
        (should (eq (shown) 'arrow))
        (should (equal (stack) '(nil "text")))
        (osc "<")
        (should (eq (shown) 'text))
        (osc "<")
        (should-not (stack)))
      ;; Sixteen fit; the seventeenth drops the first.
      (osc ">wait")
      (dotimes (_ 15) (osc ">text"))
      (should (= (length (stack)) 16))
      (should (equal (car (last (stack))) "wait"))
      (osc ">pointer")
      (should (= (length (stack)) 16))
      (should-not (member "wait" (stack)))
      (should (eq (shown) 'hand))
      ;; The knob off takes the shape away without waiting for a drain.
      (setq-local cooked-allow-pointer-shape nil)
      (should (eq (shown) 'arrow))
      (kill-local-variable 'cooked-allow-pointer-shape)
      (should (eq (shown) 'hand))
      (let ((cooked-allow-pointer-shape nil))
        (should (eq (shown) 'arrow)))
      (should (eq (shown) 'hand)))))

(ert-deftest cooked-osc-22-shape-covers-the-grid-only-while-reporting ()
  "The pointer changes over the screen and not the scrollback above it, stays off
the scrollback when more output scrolls the screen down, and is gone the moment
the child stops asking for mouse reports."
  (let ((go (make-temp-name (expand-file-name "cooked-osc22-go" temporary-file-directory))))
    (unwind-protect
        (cooked-tests--with-session
            (list "/bin/sh" "-c"
                  (format "stty -icanon -echo; seq 60; printf '\\033[?1000h\\033]22;pointer\\007'; \
while [ ! -e %s ]; do sleep 0.05; done; seq 100 160; echo scrolled; exec sleep 30"
                          go))
          (should (cooked-tests--settle
                   (lambda () (eq (get-char-property (cooked--screen-start-position) 'pointer)
                                  'hand))))
          (should (> (cooked--screen-start-position) (point-min)))
          (should-not (get-char-property (point-min) 'pointer))
          (should-not (get-char-property (1- (cooked--screen-start-position)) 'pointer))
          ;; Scroll the screen: rows leave it for history, and the shape must not
          ;; leave with them.
          (let ((before (cooked--screen-start-position)))
            (write-region "" nil go)
            ;; Nothing after the scroll touches the shape, so only the drain
            ;; itself can have put the overlay back on the marker.
            (should (cooked-tests--settle
                     (lambda () (save-excursion
                                  (goto-char (point-min))
                                  (search-forward "scrolled" nil t)))))
            (should (eq (get-char-property (cooked--screen-start-position) 'pointer) 'hand))
            (should (> (cooked--screen-start-position) before))
            (should-not (get-char-property before 'pointer))
            (should (= (overlay-start cooked--pointer-overlay)
                       (cooked--screen-start-position))))
          ;; Reporting off drops the shape; back on restores it, since the child
          ;; did not pop it.
          (cooked--set-mouse-state nil nil nil nil nil)
          (should-not cooked--pointer-overlay)
          (should-not (get-char-property (cooked--screen-start-position) 'pointer))
          (cooked--set-mouse-state t nil nil nil nil)
          (should (eq (get-char-property (cooked--screen-start-position) 'pointer) 'hand)))
      (ignore-errors (delete-file go)))))

(ert-deftest cooked-osc-22-leaves-the-overlay-alone-when-nothing-moved ()
  "A drain that scrolls nothing, and a set of the shape already on top, do not
move the overlay.  A move to the same bounds still marks the buffer's overlays
changed, which costs redisplay its shortcuts for an unchanged buffer."
  (let ((go (make-temp-name (expand-file-name "cooked-osc22-go" temporary-file-directory)))
        (moves 0))
    (unwind-protect
        (cooked-tests--with-session
            (list "/bin/sh" "-c"
                  (format "stty -icanon -echo; printf '\\033[?1000h\\033]22;pointer\\007'; \
while [ ! -e %s ]; do sleep 0.05; done; \
printf 'x\\033]22;pointer\\007\\033]22;=hand\\007\\033]22;>pointer\\007\\033]22;<\\007done'; \
exec sleep 30"
                          go))
          (should (cooked-tests--settle
                   (lambda () (eq (get-char-property (cooked--screen-start-position) 'pointer)
                                  'hand))))
          (let ((overlay cooked--pointer-overlay))
            (cl-letf* ((real-move (symbol-function 'move-overlay))
                       ((symbol-function 'move-overlay)
                        (lambda (&rest args) (cl-incf moves) (apply real-move args))))
              (write-region "" nil go)
              (should (cooked-tests--settle
                       (lambda () (save-excursion
                                    (goto-char (point-min))
                                    (search-forward "done" nil t))))))
            (should (eq cooked--pointer-overlay overlay))
            (should (eq (overlay-get overlay 'pointer) 'hand))
            (should (= (overlay-start overlay) (cooked--screen-start-position)))
            (should (= moves 0))))
      (ignore-errors (delete-file go)))))

(ert-deftest cooked-grabbed-pointer-is-an-arrow-until-the-child-sets-one ()
  "While the child has the mouse and has set no shape, the screen shows
`cooked-grabbed-pointer-shape', an arrow, as kitty and Ghostty do.  With
reporting off, or with only alternate scroll opening the gate, Emacs' own
I-beam shows; a shape the child sets replaces the arrow; and the knob follows a
change without waiting for a drain."
  (cooked-tests--with-session '("/bin/sh" "-c" "stty -icanon -echo; exec sleep 30")
    (cl-flet ((shown () (and cooked--pointer-overlay
                             (overlay-get cooked--pointer-overlay 'pointer))))
      (should-not cooked--mouse-grab)
      (should-not (shown))
      ;; Alternate scroll opens the gate without the child asking for the mouse.
      (cl-letf (((symbol-function 'cooked--alt-scroll-active-p) (lambda () t)))
        (should (cooked-tests--settle (lambda () (cooked--update-mouse-grab)
                                        cooked--mouse-grab)))
        (should-not (shown)))
      (cooked--set-mouse-state t nil nil nil nil)
      (should cooked--mouse-grab)
      (should (eq (shown) 'arrow))
      (should (eq (get-char-property (cooked--screen-start-position) 'pointer) 'arrow))
      (cooked--osc-pointer-shape '("pointer"))
      (should (eq (shown) 'hand))
      (cooked--osc-pointer-shape '("<"))
      (should (eq (shown) 'arrow))
      (setq-local cooked-grabbed-pointer-shape 'hand)
      (should (eq (shown) 'hand))
      (setq-local cooked-grabbed-pointer-shape nil)
      (should-not (shown))
      (kill-local-variable 'cooked-grabbed-pointer-shape)
      (should (eq (shown) 'arrow))
      (cooked--set-mouse-state nil nil nil nil nil)
      (should-not (shown)))))

(ert-deftest cooked-osc-22-stacks-per-screen-and-honours-the-knob ()
  "Push, pop and set move the top of the current screen's stack; the other
screen's stack is untouched; a reset empties both; and with the knob off a set
does nothing and a query is told nothing is supported."
  (cooked-tests--with-session '("/bin/sh" "-c" "stty -icanon -echo; printf '\\033[?1000h'; exec sleep 30")
    (should (cooked-tests--settle (lambda () cooked--mouse-grab)))
    (let ((cooked--osc-bell-terminated t)
          (replies nil))
      (cl-letf (((symbol-function 'cooked--reply-osc)
                 (lambda (_session code payload _bell) (push (cons code payload) replies))))
        (cl-flet ((shown () (and cooked--pointer-overlay
                                 (overlay-get cooked--pointer-overlay 'pointer)))
                  (osc (payload) (cooked--osc-pointer-shape (list payload))))
          (osc ">text,pointer")
          (should (eq (shown) 'hand))
          (osc "<")
          (should (eq (shown) 'text))
          ;; A shape Emacs cannot draw is still pushed, so its pop stays paired;
          ;; while it is on top, the grabbed pointer shows.
          (osc ">crosshair")
          (should (eq (shown) 'arrow))
          (osc "?__current__")
          (should (equal (pop replies) '(22 . "crosshair")))
          (osc "<")
          (should (eq (shown) 'text))
          (osc "=wait")
          (should (eq (shown) 'hourglass))
          (should (equal (alist-get 'main cooked--pointer-stacks) '("wait")))
          ;; The alternate screen starts with a stack of its own.
          (let ((cooked--alt t))
            (cooked--sync-pointer-shape)
            (should (eq (shown) 'arrow))
            (osc "hand")
            (should (eq (shown) 'hand)))
          (cooked--sync-pointer-shape)
          (should (eq (shown) 'hourglass))
          (cooked--reset-pointer-shapes)
          (should-not cooked--pointer-stacks)
          (should (eq (shown) 'arrow))
          (let ((cooked-allow-pointer-shape nil))
            (osc "pointer")
            (should-not cooked--pointer-stacks)
            (should (eq (shown) 'arrow))
            (osc "?pointer,text")
            (should (equal (pop replies) '(22 . "0,0")))))))))

;; The payloads below are read by `cooked--osc-pointer-shape' and nothing
;; else, so no session is needed: with none, the overlay is simply never shown.
(ert-deftest cooked-osc-22-refuses-a-name-outside-the-spec-and-never-reads-it-back ()
  "A name outside [a-z0-9_-], or too long, is not kept, so `__current__' cannot
return it; it still holds its place on the stack so the pop stays paired."
  (with-temp-buffer
    (let ((cooked--osc-bell-terminated t)
          (cooked-allow-pointer-shape t)
          (replies nil))
      (cl-letf (((symbol-function 'cooked--reply-osc)
                 (lambda (_session code payload _bell) (push (cons code payload) replies))))
        (cl-flet ((osc (payload) (cooked--osc-pointer-shape (list payload))))
          (osc "=wait")
          (dolist (junk (list "rm -rf ~ x" "Pointer" "text\u00e9" (make-string 33 ?a)))
            (osc (concat ">" junk))
            (osc "?__current__")
            (should (equal (pop replies) '(22 . "0")))
            (should-not (member junk (alist-get 'main cooked--pointer-stacks)))
            (osc "<")
            (osc "?__current__")
            (should (equal (pop replies) '(22 . "wait")))
            (osc (concat "=" junk))
            (osc "?__current__")
            (should (equal (pop replies) '(22 . "0")))
            (osc "=wait"))
          ;; The longest the spec allows is still a name.
          (osc (concat ">" (make-string 32 ?a)))
          (osc "?__current__")
          (should (equal (pop replies) (cons 22 (make-string 32 ?a)))))))))

(ert-deftest cooked-no-osc-query-echoes-the-text-it-was-sent ()
  "The Lisp half of `no_query_echoes_the_text_it_was_sent' in reply.rs.

Every OSC query Lisp answers is sent printable text wherever a reply might
carry it -- after the `?', in place of an index or target, and stored first by
a set or push that a later query reads back -- with every knob that widens an
answer turned on.  The child's input must never contain that text.  A DSR is
sent last, so its answer marks the point by which everything has come back."
  (let* ((payload "rm -rf ~ x")
         (bodies
          (append
           (list (concat "4;1;?" payload) (concat "4;" payload ";?")
                 (concat "22;?" payload) (concat "22;>" payload) "22;?__current__"
                 (concat "52;c;?" payload) (concat "52;" payload ";?")
                 ;; Base64 for the payload, which a read must return re-encoded.
                 "52;0;cm0gLXJmIH4geA==" "52;0;?")
           (mapcan (lambda (code)
                     (list (format "%d;?%s" code payload)
                           (format "%d;%s;?" code payload)
                           (format "%d;%s" code payload)
                           (format "%d;?" code)))
                   '(10 11 12 13 14 15 16 17 18 19))))
         (query (concat (mapconcat (lambda (body) (concat "\\033]" body "\\007"))
                                   bodies "")
                        "\\033[5n"))
         (out (make-temp-file "cooked-osc-echo")))
    (let ((cooked-allow-color-set t)
          (cooked-allow-pointer-shape t)
          (cooked-clipboard-read 'private))
      (cooked-tests--with-kill "secret"
        (unwind-protect
            (cooked-tests--with-session (cooked-tests--reply-to query out)
              (should (cooked-tests--settle
                       (lambda () (string-suffix-p "\033[0n" (cooked-tests--contents out)))))
              (let ((received (cooked-tests--contents out)))
                ;; The queries were answered, so the check below is not vacuous.
                (should (string-search "\033]22;0\007" received))
                (should (string-search "\033]52;0;cm0gLXJmIH4geA==\007" received))
                (should (string-match-p "\033]11;rgb:" received))
                (should-not (string-search payload received))))
          (delete-file out))))))

(defun cooked-tests--reverse-remap ()
  "The colors DECSCNM has remapped `default' to, as one plist, or nil.
Only when both remaps are in force and nothing outranks them."
  (let ((specs (alist-get 'default face-remapping-alist)))
    (when (and cooked--reverse-screen-remaps
               (equal (take 2 specs)
                      (reverse (mapcar #'cdr (take 2 cooked--reverse-screen-remaps)))))
      (append (nth 1 specs) (nth 0 specs)))))

(ert-deftest cooked-reverse-screen-swaps-the-default-colors-and-undoes-it ()
  "DECSCNM from a real child: set, reset, and set again then RIS.
Each step waits on the child reading a line, so no two of them can land in one
drain and cancel out before the buffer has seen the first."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "stty raw -echo; printf '\\033[?5h'; read -r _; printf '\\033[?5l'; read -r _; printf '\\033[?5h'; read -r _; printf '\\033c'; sleep 5")
    (let ((foreground (cooked--default-color 'foreground))
          (background (cooked--default-color 'background)))
      (should (cooked-tests--settle #'cooked-tests--reverse-remap))
      (should (equal (cooked-tests--reverse-remap)
                     (list :foreground background :background foreground)))
      (cooked--send-if-live "\n")
      (should (cooked-tests--settle (lambda () (not cooked--reverse-screen))))
      (should-not cooked--reverse-screen-remaps)
      (should-not (alist-get 'default face-remapping-alist))
      (cooked--send-if-live "\n")
      (should (cooked-tests--settle #'cooked-tests--reverse-remap))
      (cooked--send-if-live "\n")
      (should (cooked-tests--settle (lambda () (not cooked--reverse-screen))))
      (should-not (alist-get 'default face-remapping-alist)))))

(ert-deftest cooked-a-flash-inside-one-drain-still-flashes ()
  "`flash\=' written in one go reverses the screen once and puts it back.

The set and the reset reach the core in one read, so the drain after them reports
the level where it began; only the toggle count says anything happened.  Every
change actually drawn is recorded, and the screen must have gone reversed and
then come back, with the reversal held until the timer ends it."
  (let ((drawn nil))
    (cl-flet ((record (on)
                (unless (eq on cooked--reverse-screen)
                  (push on drawn))))
      (advice-add 'cooked--draw-reverse-screen :before #'record)
      (unwind-protect
          (cooked-tests--with-session
              '("/bin/sh" "-c" "printf '\\033[?5h\\033[?5l'; sleep 5")
            (should (cooked-tests--settle (lambda () (equal drawn '(nil t)))))
            (should (= cooked--reverse-screen-toggles 2))
            (should-not cooked--reverse-screen-level)
            (should-not cooked--reverse-screen)
            ;; And a drain that moves nothing does not flash again.
            (cooked--set-reverse-screen nil 2)
            (should-not cooked--flash-timer)
            (should (equal drawn '(nil t))))
        (advice-remove 'cooked--draw-reverse-screen #'record)))))

(ert-deftest cooked-a-held-flash-outlasts-the-drains-during-it ()
  "Drains arriving while a flash shows leave it showing, and its end draws the
level the last of them reported, which a reset in the meantime may have moved."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (cooked--set-reverse-screen nil 2)
    (should cooked--reverse-screen)
    (should cooked--flash-timer)
    (cooked--set-reverse-screen nil 2)
    (should cooked--reverse-screen)
    (cooked--set-reverse-screen t 2)
    (should cooked--reverse-screen)
    (cooked--set-reverse-screen nil 2)
    (should (cooked-tests--settle (lambda () (not cooked--flash-timer))))
    (should-not cooked--reverse-screen)
    ;; A set that simply changes the level is drawn at once, with no flash.
    (cooked--set-reverse-screen t 3)
    (should cooked--reverse-screen)
    (should-not cooked--flash-timer)))

(ert-deftest cooked-reverse-screen-on-a-tty-swaps-the-terminals-own-colours ()
  "A text terminal that keeps its colours to itself is reversed by name.
The remap is to `unspecified-bg\=' on `unspecified-fg\=', which Emacs draws in
standout, rather than to the black and white `cooked--default-color\=' guesses.
An OSC 11 background is still swapped as the colour it is.  The tty is
simulated: batch Emacs crashes redisplaying a real tty frame with no colours."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (cl-letf (((symbol-function 'tty-type) (lambda (&rest _) "xterm-direct"))
              ((symbol-function 'face-attribute)
               (lambda (_face attribute &rest _)
                 (if (eq attribute :foreground) "unspecified-fg" "unspecified-bg"))))
      (let ((cooked-allow-color-set t)
            (cooked--osc-bell-terminated t))
        (cooked--set-reverse-screen t)
        (should (equal (cooked-tests--reverse-remap)
                       '(:foreground "unspecified-bg" :background "unspecified-fg")))
        (let ((cooked--osc-code 11))
          (cooked--osc-color '("#ff0000")))
        (should (equal (cooked-tests--reverse-remap)
                       '(:foreground "#ff0000" :background "unspecified-fg")))))))

(ert-deftest cooked-reverse-screen-swaps-the-colors-the-child-set ()
  "An OSC 11 background is the one reversed, before the reversal and after it."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let ((cooked-allow-color-set t)
          (cooked--osc-bell-terminated t)
          (foreground (cooked--default-color 'foreground)))
      (let ((cooked--osc-code 11))
        (cooked--osc-color '("#ff0000")))
      (cooked--set-reverse-screen t)
      (should (equal (cooked-tests--reverse-remap)
                     (list :foreground "#ff0000" :background foreground)))
      ;; Set while reversed: the swap follows it, and still outranks it.
      (let ((cooked--osc-code 11))
        (cooked--osc-color '("#00ff00")))
      (should (equal (cooked-tests--reverse-remap)
                     (list :foreground "#00ff00" :background foreground)))
      (cooked--set-reverse-screen nil)
      (should-not cooked--reverse-screen-remaps)
      (should (equal (car (alist-get 'default face-remapping-alist))
                     '(:background "#00ff00"))))))

(defun cooked-tests--drawn-colors (face)
  "The foreground and background Emacs paints FACE in, as a list of two.

Emacs's own rule, written out because batch mode realizes no faces to ask: a
colour the plist does not name comes from `default' as this buffer remaps it,
the first relative spec naming the attribute winning, and `:inverse-video'
swaps the pair only after that.  The order is the load-bearing part, and it was
read off the pixels of a headless pgtk frame rather than assumed: reversed
default-coloured text there followed an OSC 11 remap, and under the three
DECSCNM remaps came out in normal video."
  (let ((specs (alist-get 'default face-remapping-alist)))
    (cl-flet ((resolve (property kind)
                (or (plist-get face property)
                    (seq-some (lambda (spec)
                                (and (consp spec) (plist-get spec property)))
                              specs)
                    (cooked--default-color kind))))
      (let ((foreground (resolve :foreground 'foreground))
            (background (resolve :background 'background)))
        (if (plist-get face :inverse-video)
            (list background foreground)
          (list foreground background))))))

(ert-deftest cooked-reverse-video-swaps-default-colors-too ()
  "SGR 7 on text in the default colours draws it reversed, as `smso' promises.

The face used to swap two nils and name no colour at all, so `less\=''s status
line and every other standout in the default pair came out as plain text.  A
cell with colours of its own still swaps them; a default one follows an OSC 11
set; and under DECSCNM, which has already reversed `default', it reads as
normal video again."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let* ((cooked-allow-color-set t)
           (cooked--osc-bell-terminated t)
           (foreground (cooked--default-color 'foreground))
           (background (cooked--default-color 'background))
           (reverse (cooked--face nil nil cooked--attr-reverse)))
      (should (equal (cooked-tests--drawn-colors reverse)
                     (list background foreground)))
      ;; Explicit colours: red on blue becomes blue on red.
      (should (equal (cooked-tests--drawn-colors
                      (cooked--face 1 4 cooked--attr-reverse))
                     (list (cooked--color 4) (cooked--color 1))))
      ;; One of each: the default half is the buffer's, not a hole.
      (should (equal (cooked-tests--drawn-colors
                      (cooked--face 1 nil cooked--attr-reverse))
                     (list background (cooked--color 1))))
      ;; Concealed and reversed is still concealed: the glyph takes the colour
      ;; the swap put behind it.
      (let ((drawn (cooked-tests--drawn-colors
                    (cooked--face 1 4 (logior cooked--attr-reverse
                                              cooked--attr-conceal)))))
        (should (equal (car drawn) (cadr drawn)))
        (should (equal (cadr drawn) (cooked--color 1))))
      (let ((cooked--osc-code 11))
        (cooked--osc-color '("#ff0000")))
      (should (equal (cooked-tests--drawn-colors
                      (cooked--face nil nil cooked--attr-reverse))
                     (list "#ff0000" foreground)))
      (cooked--set-reverse-screen t)
      (should (equal (cooked-tests--drawn-colors
                      (cooked--face nil nil cooked--attr-reverse))
                     (list foreground "#ff0000")))
      ;; And the plain text beside it is the one that is reversed now.
      (should (equal (cooked-tests--drawn-colors (cooked--face nil nil 0))
                     (list "#ff0000" foreground))))))

(ert-deftest cooked-concealed-default-text-stays-hidden-as-the-colours-move ()
  "SGR 8 on the default colours hides its text under OSC 11 and DECSCNM too.

Read off what a real tty frame draws, not a model of it.  Concealment used to
name the global `default' background as the foreground, which ignored the
buffer's remaps: after an OSC 11 set, or under the three DECSCNM remaps, the
text came out in the old background over the new one, plainly legible.  Q is
concealed in the default colours, R is concealed and reversed, and the a
beside them is ordinary text, there to show each step really moved the colours."
  (cooked-tests--with-tty-frame
    (cooked-tests--with-session
        '("/bin/sh" "-c" "printf 'a\\033[8mQ\\033[7mR\\033[m\\n'; sleep 5")
      (should (cooked-tests--settle
               (lambda () (string-search "aQR" (cooked-tests--text)))))
      (let ((cooked-allow-color-set t)
            (cooked--osc-bell-terminated t)
            (buffer (current-buffer)))
        ;; A reversed cell sits on the foreground, so that is what R hides in.
        (cl-flet ((hidden (foreground background)
                    (should (equal (cooked-tests--realized-colors buffer ?Q)
                                   (list background background)))
                    (should (equal (cooked-tests--realized-colors buffer ?R)
                                   (list foreground foreground)))))
          (should (equal (cooked-tests--realized-colors buffer ?a)
                         '("#e0e0e0" "#101010")))
          (hidden "#e0e0e0" "#101010")
          (let ((cooked--osc-code 11))
            (cooked--osc-color '("#ff0000")))
          (should (equal (cooked-tests--realized-colors buffer ?a)
                         '("#e0e0e0" "#ff0000")))
          (hidden "#e0e0e0" "#ff0000")
          (cooked--set-reverse-screen t)
          (should (equal (cooked-tests--realized-colors buffer ?a)
                         '("#ff0000" "#e0e0e0")))
          (hidden "#ff0000" "#e0e0e0")
          (let ((cooked--osc-code 10))
            (cooked--osc-color '("#00ff00")))
          (hidden "#ff0000" "#00ff00")
          (cooked--set-reverse-screen nil)
          (hidden "#00ff00" "#ff0000")
          ;; A new theme: its background is the one hidden in once OSC 110/111
          ;; hand the defaults back.
          (let ((cooked--osc-code 110)) (cooked--osc-color-reset nil))
          (let ((cooked--osc-code 111)) (cooked--osc-color-reset nil))
          (set-frame-parameter nil 'background-color "#202040")
          (cooked--flush-face-cache)
          (should (equal (cooked-tests--realized-colors buffer ?a)
                         '("#e0e0e0" "#202040")))
          (hidden "#e0e0e0" "#202040"))))))

(ert-deftest cooked-reverse-video-from-a-child-reaches-the-buffer ()
  "`printf \\='\\e[7mX\\e[m\\=' leaves X in a face that draws reversed."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'a\\033[7mX\\033[mb\\n'; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "aXb" (cooked-tests--text)))))
    (goto-char (point-min))
    (search-forward "aXb")
    (should (equal (cooked-tests--drawn-colors
                    (get-text-property (- (point) 2) 'face))
                   (list (cooked--default-color 'background)
                         (cooked--default-color 'foreground))))))

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
    (should (cooked-line-prompt-continued (cooked--line)))
    ;; No `A' came, so there is no prompt for this to be a continuation *of*.
    (should-not cooked--prompt-start)
    (cooked--send-input-string "one")
    (cooked--send-input-string "two")
    ;; Replaced, not appended: the second line is its own submission.
    (should (equal (cooked-line-submitted-input (cooked--line)) "two"))))

(ert-deftest cooked-zsh-marks-its-continuation-prompt ()
  "The end to end version, and the reason PS2 is worth touching at all: without
the mark every line after the first of a multi-line construct falls out of
Emacs' hands back to ZLE, so you compose the first line in Emacs and the rest in
the shell's own line editor.

The record is the other half.  Each continuation line is submitted separately,
so the command's own text has to accumulate across them or the record for the
whole construct would say only its last line."
  :tags '(zsh)
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-zsh
    (cooked--replace-input "for x in alpha beta; do")
    (cooked-send-input)
    ;; The continuation prompt arrives and Emacs still owns the line.
    (should (cooked-tests--settle
             (lambda () (and (cooked-line-prompt-continued (cooked--line))
                             (eq cooked--semantic 'input)
                             (cooked--input-start-position)))
             8))
    (should (cooked--input-state-p))
    ;; Waiting on the next prompt has to be a wait for the input region to *move*.
    ;; `cooked-line-prompt-continued' is already set from the prompt above and stays set
    ;; for the whole construct, so a settle on it returns at once and the line below
    ;; would be typed at a prompt the shell has not drawn yet.
    (let ((line (cooked--input-start-position)))
      (cooked--replace-input "echo $x")
      (cooked-send-input)
      (should (cooked-tests--settle
               (lambda () (let ((now (cooked--input-start-position)))
                            (and now (> now line) (cooked-line-prompt-continued (cooked--line)))))
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

;;;; OSC 9;4 -- progress

;; ConEmu's `ESC ] 9 ; 4 ; STATE ; PERCENT ST'.  Driven through
;; `cooked--osc-progress' rather than through a child for everything except the
;; end-to-end case below, because what is being asserted is a state machine and
;; a child can only ever show it one path through at a time.

(defun cooked-tests--progress (&rest payloads)
  "Feed each of PAYLOADS to the OSC 9 handler and return the resulting state."
  (dolist (parts payloads)
    (cooked--osc-progress parts))
  cooked--progress)

(ert-deftest cooked-progress-tracks-every-state ()
  (with-temp-buffer
    (cooked-mode)
    ;; 1, set: the ordinary case, and the one that carries a number.
    (should (equal (cooked-tests--progress '("4" "1" "42")) '(set . 42)))
    ;; 3, indeterminate: no number at all, and it drops the one already showing
    ;; rather than leaving a stale percentage beside a pulsing state.
    (should (equal (cooked-tests--progress '("4" "3")) '(indeterminate)))
    (should (equal (cooked-tests--progress '("4" "3" "42")) '(indeterminate)))
    ;; 2, error, and 4, paused: a number if one is sent.
    (should (equal (cooked-tests--progress '("4" "2" "73")) '(error . 73)))
    (should (equal (cooked-tests--progress '("4" "4" "25")) '(paused . 25)))
    ;; And, if none is, the one already showing -- which is the whole point of
    ;; the percentage being optional: `1;70' while the work runs, a bare `2'
    ;; when it fails, and the mode line says how far it had got.
    (should (equal (cooked-tests--progress '("4" "1" "70") '("4" "2")) '(error . 70)))
    (should (equal (cooked-tests--progress '("4" "1" "70") '("4" "4")) '(paused . 70)))
    ;; 0, remove: the absence of the other four, not a fifth of them.
    (should (null (cooked-tests--progress '("4" "1" "42") '("4" "0"))))
    ;; A bare `2' with nothing to carry says the state and no number.
    (should (equal (cooked-tests--progress '("4" "2")) '(error)))
    ;; A bare `1' has to invent one, since a set is nothing but its number.
    (should (equal (cooked-tests--progress '("4" "0") '("4" "1")) '(set . 0)))))

(ert-deftest cooked-progress-refuses-what-it-cannot-parse ()
  "A malformed report leaves the indicator exactly as it was.

The alternative -- guessing -- is what lets a stream park a wrong number in the
mode line and then go quiet, leaving it there."
  (with-temp-buffer
    (cooked-mode)
    (dolist (bad '(("4")                    ; no state at all
                   ("4" "5")                ; state outside 0-4
                   ("4" "01")               ; not the digit, however it reads
                   ("4" "1.0")
                   ("4" " 1")
                   ("4" "-1")
                   ("4" "1" "nan")          ; `string-to-number' answers 0 to all
                   ("4" "1" "0x40")         ; of these; the digit check is what
                   ("4" "1" "1e2")          ; keeps them from becoming a number
                   ("4" "1" "4 2")
                   ("4" "1" "42" "43")      ; a field ConEmu does not define
                   ("9" "1" "42")           ; not 9;4 at all
                   ()))
      (should (null (cooked-tests--progress bad))))
    ;; Nor does a bad report clear a good one.
    (should (equal (cooked-tests--progress '("4" "1" "42") '("4" "1" "eek"))
                   '(set . 42)))
    ;; Out of range is clamped rather than refused: a build tool that computes
    ;; 101% has a rounding bug, not an intent.
    (should (equal (cooked-tests--progress '("4" "1" "999")) '(set . 100)))
    (should (equal (cooked-tests--progress '("4" "1" "99999999999999999999"))
                   '(set . 100)))))

(ert-deftest cooked-progress-cannot-inject-a-mode-line-specifier ()
  "The mode line prints what a child sends; it never reads it.

Two halves, and the second is the one that is easy to miss.  A `:eval''s string
result is itself a mode-line construct, so it is rescanned for `%'-specifiers --
which makes the child's title an injection site, and makes cooked's *own*
`[42%]' one too, `%]' being the specifier that closes a recursion group."
  (with-temp-buffer
    (cooked-mode)
    ;; Asserted on the escaped string rather than on `format-mode-line''s
    ;; output, which answers the empty string under `--batch': there is no
    ;; window for it to measure against, so the one rendering call that would
    ;; close this loop is the one thing the suite cannot make.  `%%' is the
    ;; escape that displays as a single `%', so an even run is the property.
    (cooked--osc-progress '("4" "1" "100"))
    (should (string-match-p (regexp-quote "[100%%]") (cooked--mode-line)))
    ;; And a title full of specifiers is passed through doubled, so it is shown
    ;; rather than obeyed: `%b' would otherwise become the buffer name and `%-'
    ;; a run of dashes out to the margin.
    (setq cooked-title "%b%-%%")
    (should (string-match-p (regexp-quote "%%b%%-%%%%") (cooked--mode-line)))
    ;; The general form of both: nothing reaches the mode line holding an odd
    ;; number of `%' in a row, which is the only way a specifier can survive.
    (should-not (string-match-p "\\(?:\\`\\|[^%]\\)\\(?:%%\\)*%\\(?:[^%]\\|\\'\\)"
                                (cooked--mode-line)))))

(ert-deftest cooked-progress-is-cleared-by-a-reset ()
  "RIS clears the indicator, which nothing in Rust can do for us.

Pinned at the seam rather than by feeding `ESC c' to a child, because the two
halves fail independently: that the emulator raises `reset' for RIS and for
nothing else is a Rust test (`a_reset_says_so_where_a_soft_reset_does_not'), and
this is the other half -- that the event, once raised, reaches the one piece of
session state Emacs holds on the emulator's behalf."
  (with-temp-buffer
    (cooked-mode)
    (cooked--osc-progress '("4" "1" "60"))
    (should cooked--progress)
    (cooked--handle-event '(reset) (point-min))
    (should (null cooked--progress))
    (should-not (string-match-p "%" (cooked--mode-line)))))

(ert-deftest cooked-progress-function-is-the-whole-of-the-rendering ()
  "A replacement renderer needs nothing from cooked but the two values.

The default has to be what somebody with no extra packages gets, so the
indirection is only worth having if a substitute is genuinely interchangeable --
including one that renders nothing and puts the state somewhere else entirely."
  (with-temp-buffer
    (cooked-mode)
    (cooked--osc-progress '("4" "2" "73"))
    (should (string-match-p (regexp-quote "[err 73%%]") (cooked--mode-line)))
    (let* ((seen nil)
           (cooked-progress-function
            (lambda (state percent) (push (cons state percent) seen) "<spin>")))
      (should (string-match-p "<spin>" (cooked--mode-line)))
      ;; Called with the state, and called again with nil once there is none --
      ;; which is where an animated renderer stops its timer.
      (cooked--osc-progress '("4" "0"))
      (cooked--mode-line)
      (should (equal (car seen) '(nil))))
    ;; nil is a supported value, not an unconfigured one.
    (let ((cooked-progress-function nil))
      (cooked--osc-progress '("4" "1" "50"))
      (should-not (string-match-p "50" (cooked--mode-line))))
    ;; A renderer that signals shows nothing and does not take the mode line
    ;; down with it.  `cooked-debug' is bound off because it is exactly the
    ;; switch that turns the guard back into a re-signal.
    (let ((cooked-debug nil)
          (cooked-progress-function (lambda (&rest _) (error "Boom"))))
      (should (cooked--mode-line)))))

(ert-deftest cooked-progress-reaches-the-mode-line-from-a-real-child ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\033]9;4;1;37\\007'; sleep 5")
    (should (cooked-tests--settle (lambda () (equal cooked--progress '(set . 37)))))
    (should (string-match-p (regexp-quote "[37%%]") (cooked--mode-line)))))

(ert-deftest cooked-progress-repeated-report-does-not-repaint ()
  "A report identical to the one on show asks the mode line for nothing.
Tools resend the same percentage many times a second while a step runs."
  (with-temp-buffer
    (cooked-mode)
    (let ((repaints 0))
      (cl-letf (((symbol-function 'force-mode-line-update)
                 (lambda (&rest _) (cl-incf repaints))))
        (cooked--osc-progress '("4" "1" "42"))
        (should (= repaints 1))
        (dotimes (_ 10) (cooked--osc-progress '("4" "1" "42")))
        (should (= repaints 1))
        ;; A bare `1' carries the 42 forward, so it is the same report too.
        (cooked--osc-progress '("4" "1"))
        (should (= repaints 1))
        (cooked--osc-progress '("4" "1" "43"))
        (should (= repaints 2))
        (cooked--osc-progress '("4" "0"))
        (cooked--osc-progress '("4" "0"))
        (should (= repaints 3))))))

(ert-deftest cooked-progress-is-cleared-when-the-command-is-over ()
  "A build that never sends the report removing its bar loses it at the shell's
next OSC 133 C, at its D, and when the child exits."
  (let ((go (make-temp-name (expand-file-name "cooked-progress-go" temporary-file-directory))))
    (unwind-protect
        (cooked-tests--with-session
            (list "/bin/sh" "-c"
                  (format "printf '\\033]9;4;1;42\\007'; \
while [ ! -e %1$s.1 ]; do sleep 0.05; done; printf '\\033]133;C\\007\\033]9;4;1;17\\007'; \
while [ ! -e %1$s.2 ]; do sleep 0.05; done; printf '\\033]133;D;130\\007\\033]9;4;2;60\\007'; \
while [ ! -e %1$s.3 ]; do sleep 0.05; done; exit 3"
                          go))
          (should (cooked-tests--settle (lambda () (equal cooked--progress '(set . 42)))))
          ;; C clears what came before it, and the new command's report stands.
          (write-region "" nil (concat go ".1"))
          (should (cooked-tests--settle (lambda () (equal cooked--progress '(set . 17)))))
          ;; D clears it; a report after D, from nothing the shell ran, stands.
          (write-region "" nil (concat go ".2"))
          (should (cooked-tests--settle (lambda () (equal cooked--progress '(error . 60)))))
          ;; And exit clears that.
          (write-region "" nil (concat go ".3"))
          (should (cooked-tests--settle (lambda () cooked--exit)))
          (should-not cooked--progress))
      (dolist (n '("1" "2" "3"))
        (ignore-errors (delete-file (concat go "." n)))))))

;;;; What a dead command leaves behind

(defun cooked-tests--dying-command (go set &optional probe)
  "ARGV for a shell whose command sets SET and is killed before it can unset it.

The shell marks its prompt and hands over at C.  SET is printf text, run in a
`sh -c' that `kill -9's itself, which is as dead as a command gets.  The shell
then runs PROBE on `before', waits for the file GO, sends D and its next
prompt, runs PROBE on `after', and sleeps.  PROBE is a function from a label
to shell text, or nil."
  (list "/bin/sh" "-c"
        (format "printf '\\033]133;A\\007$ \\033]133;B\\007\\033]133;C\\007'; \
sh -c \"printf '%s'; kill -9 \\$\\$\"; %s \
while [ ! -e %s ]; do sleep 0.05; done; \
printf '\\033]133;D;137\\007\\033]133;A\\007next$ \\033]133;B\\007'; %s sleep 5"
                set (if probe (funcall probe "before") "") go
                (if probe (funcall probe "after") ""))))

(defun cooked-tests--mode-probe (mode)
  "A probe for `cooked-tests--dying-command' printing DECRQM's answer for MODE.

It prints its label, a colon and everything the terminal sent up to the reply's
final `y', with ESC spelled E, so the answer for 2048 while it is set ends
`E[?2048;1$y' -- after the size report its `h' sent.  The tty is left raw."
  (lambda (label)
    (format "stty raw -echo; printf '\\033[?%d$p'; r=; \
while c=$(dd bs=1 count=1 2>/dev/null); [ \"$c\" != y ]; do r=\"$r$c\"; done; \
printf '%s:%%sy\\r\\n' \"$r\" | tr '\\033' E;"
            mode label)))

(defmacro cooked-tests--after-dying-command (set probe before after)
  "Run a `cooked-tests--dying-command' with SET and PROBE in a session.

BEFORE must come to hold while what the command left stands, and AFTER once the
shell has sent D and its next prompt."
  (declare (indent 2))
  (let ((go (make-symbol "go")))
    `(let ((,go (make-temp-name
                 (expand-file-name "cooked-handover-go" temporary-file-directory))))
       (unwind-protect
           (cooked-tests--with-session
               (cooked-tests--dying-command ,go ,set ,probe)
             (should (cooked-tests--settle (lambda () ,before)))
             (write-region "" nil ,go)
             ;; Short of the exit, which ends some of the same state for its own reasons.
             (should (cooked-tests--settle (lambda () (and (not cooked--exit) ,after)))))
         (ignore-errors (delete-file ,go))))))

(defun cooked-tests--text-has (regexp)
  "Whether the buffer text matches REGEXP."
  (string-match-p regexp (cooked-tests--text)))

(ert-deftest cooked-command-end-ends-size-reports ()
  "A command killed with mode 2048 on would have every resize type
`ESC [ 48 ; ...' into the prompt after it."
  (cooked-tests--after-dying-command "\\033[?2048h"
      (cooked-tests--mode-probe 2048)
    (cooked-tests--text-has "before:.*E\\[\\?2048;1\\$y")
    (cooked-tests--text-has "after:E\\[\\?2048;2\\$y")))

(ert-deftest cooked-command-end-ends-mouse-tracking ()
  "Left on, a hovering pointer is input for the next program that takes the
keyboard."
  (cooked-tests--after-dying-command "\\033[?1003h\\033[?1006h" nil
    (cooked-mouse-state-motion cooked--mouse-state)
    (and (cooked-tests--text-has "next\\$")
         (not (cooked-mouse-state-enabled cooked--mouse-state))
         (not (cooked-mouse-state-sgr cooked--mouse-state)))))

(ert-deftest cooked-command-end-ends-focus-reports ()
  "Left on, every change of window types `ESC [ I' into bash."
  (cooked-tests--after-dying-command "\\033[?1004h" nil
    (cooked--focus-events-p cooked--session)
    (and (cooked-tests--text-has "next\\$")
         (not (cooked--focus-events-p cooked--session)))))

(ert-deftest cooked-command-end-pops-the-primary-kitty-flags ()
  "A primary-screen program that pushed kitty flags and crashed left bash
reading `CSI 114 ; 5 u' for C-r."
  (cooked-tests--after-dying-command "\\033[>1u" nil
    (eq cooked--keys 'kitty)
    (and (cooked-tests--text-has "next\\$")
         (eq cooked--keys 'legacy))))

(ert-deftest cooked-command-end-empties-the-alternate-kitty-stack ()
  "A program that left the alternate screen without popping handed its flags to
the next full-screen program that pushes none of its own."
  (cooked-tests--after-dying-command "\\033[?1049h\\033[>1u\\033[?1049l"
      (lambda (label)
        (format "stty raw -echo; printf '\\033[?1049h\\033[?u'; \
r=$(dd bs=1 count=5 2>/dev/null); printf '\\033[?1049l'; \
printf '%s:%%s\\r\\n' \"$r\" | tr '\\033' E;"
                label))
    (cooked-tests--text-has "before:E\\[\\?1u")
    (cooked-tests--text-has "after:E\\[\\?0u")))

(ert-deftest cooked-command-end-empties-the-pointer-stacks ()
  "A pointer a crashed editor left as a text bar is not the shell's."
  (cooked-tests--after-dying-command "\\033]22;>text\\007" nil
    (alist-get 'main cooked--pointer-stacks)
    (and (cooked-tests--text-has "next\\$")
         (null cooked--pointer-stacks))))

(ert-deftest cooked-command-end-leaves-bracketed-paste-to-the-shell ()
  "bash, zsh and fish all set bracketed paste before the prompt that carries
their A, so the handover must not take it back: at D it is still as the command
left it, and the shell clears it before the next command itself."
  (cooked-tests--after-dying-command "\\033[?2004h" nil
    (cooked--bracketed-paste-p cooked--session)
    (and (cooked-tests--text-has "next\\$")
         (cooked--bracketed-paste-p cooked--session))))

(defmacro cooked-tests--until-exit (script before &rest after)
  "Run SCRIPT, a shell that waits for the file named by $GO and then exits.

BEFORE must come to hold first; AFTER is the body run once the child is gone."
  (declare (indent 2))
  (let ((go (make-symbol "go")))
    `(let ((,go (make-temp-name
                 (expand-file-name "cooked-exit-go" temporary-file-directory))))
       (unwind-protect
           (cooked-tests--with-session
               (list "/bin/sh" "-c"
                     (concat ,script
                             (format "; while [ ! -e %s ]; do sleep 0.05; done; exit 0"
                                     ,go)))
             (should (cooked-tests--settle (lambda () ,before)))
             (write-region "" nil ,go)
             (should (cooked-tests--settle (lambda () cooked--exit)))
             ,@after)
         (ignore-errors (delete-file ,go))))))

(ert-deftest cooked-exit-ends-hover-tracking ()
  "Nothing reports the mouse off once the child is dead, so a buffer kept after
exit went on holding `track-mouse' on, a command-loop turn per glyph crossed."
  (let ((cooked-mouse-hover-motion t))
    (cooked-tests--until-exit
        "printf '\\033[?1049h\\033[?1003h\\033[?1006h'; stty raw -echo"
        (local-variable-p 'track-mouse)
      (should-not (cooked-mouse-state-enabled cooked--mouse-state))
      (should-not (local-variable-p 'track-mouse)))))

(ert-deftest cooked-exit-takes-off-the-cursor-colour-and-marks-do-not ()
  "base16-shell sets OSC 12 from `.bashrc', so a prompt mark keeps it; the frame
wearing it after the child exited was the other way round."
  (let ((cooked-allow-color-set t))
    (cooked-tests--until-exit
        "printf '\\033]12;#ff0000\\007\\033]133;C\\007\\033]133;D;0\\007\\033]133;A\\007$ '"
        (and cooked--cursor-color (cooked-tests--text-has "\\$"))
      (should-not cooked--cursor-color))))

(ert-deftest cooked-osc-9-notifies-from-a-real-child ()
  "The TERM.org check, end to end: a message notifies and `9;9;PATH' does not."
  (let* ((cooked-allow-notifications t)
         (seen (cooked-tests--capturing-notifications
                 (cooked-tests--with-session
                     '("/bin/sh" "-c" "printf '\\033]9;9;/tmp\\007\\033]9;done\\007'; sleep 5")
                   (should (cooked-tests--settle (lambda () seen)))))))
    (should (equal seen '(("" . "done"))))))

;;;; OSC 1337 SetUserVar

(ert-deftest cooked-user-var-set-reaches-the-hook ()
  "The WezTerm snippet's shape, through a real pty: stored, then announced."
  (let* ((seen nil)
         (cooked-user-var-functions
          (list (lambda (name value) (push (cons name value) seen)))))
    (cooked-tests--with-session
        '("/bin/sh" "-c" "printf '\\033]1337;SetUserVar=prog=%s\\007' \"$(printf 'vim ü' | base64)\"; sleep 5")
      (should (cooked-tests--settle (lambda () seen)))
      (should (equal seen '(("prog" . "vim ü"))))
      (should (equal (cooked-user-var "prog") "vim ü")))))

(ert-deftest cooked-user-var-over-the-bound-is-refused-out-loud ()
  "A silent drop would look like a snippet that never worked."
  (with-temp-buffer
    (cooked-mode)
    (let* ((ran nil)
           (said nil)
           (cooked-user-var-max-size 16)
           (cooked-user-var-functions (list (lambda (&rest _) (setq ran t)))))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (push (apply #'format fmt args) said))))
        (cooked-user-var--osc (list (concat "SetUserVar=big=" (base64-encode-string (make-string 64 ?x))))))
      (should-not ran)
      (should-not cooked-user-vars)
      (should (= (length said) 1))
      (should (string-match-p "refused.*big.*cooked-user-var-max-size" (car said))))))

(ert-deftest cooked-user-var-refusals-are-rate-limited-and-checked-before-a-copy ()
  "A burst of refused sets says so once, and an oversized value is refused from
its length without being copied out of the payload."
  (with-temp-buffer
    (cooked-mode)
    (let* ((said nil)
           (copies 0)
           (cooked-user-var-max-size 16)
           (payload (concat "SetUserVar=big=" (base64-encode-string (make-string 64 ?x)))))
      (cl-letf* ((real-substring (symbol-function 'substring))
                 ((symbol-function 'substring)
                  (lambda (string &rest args)
                    (let ((copy (apply real-substring string args)))
                      ;; The name is copied, and is short; the value is not.
                      (when (and (stringp string) (>= (length string) (length payload))
                                 (> (length copy) 16))
                        (cl-incf copies))
                      copy)))
                 (real-join (symbol-function 'string-join))
                 ((symbol-function 'string-join)
                  (lambda (&rest args) (cl-incf copies) (apply real-join args)))
                 ((symbol-function 'message)
                  (lambda (fmt &rest args) (push (apply #'format fmt args) said))))
        (dotimes (_ 50) (cooked-user-var--osc (list payload)))
        (should (= copies 0))
        (should (= (length said) 1))
        ;; A second later, the next refusal is reported again.
        (setq cooked-user-var--refused-at (- (float-time) 2))
        (cooked-user-var--osc (list payload))
        (should (= (length said) 2))
        ;; The name in the message has lost its bidi override.
        (setq cooked-user-var--refused-at nil)
        (cooked-user-var--osc (list (concat "SetUserVar=a\u202eb=" (make-string 20 ?A))))
        (should (string-match-p "`ab'" (car said)))))))

(ert-deftest cooked-user-var-refuses-a-value-that-is-not-utf-8 ()
  "Bytes that do not decode as UTF-8 never reach the hook as raw-byte characters."
  (with-temp-buffer
    (cooked-mode)
    (let* ((seen nil)
           (cooked-user-var-functions (list (lambda (&rest args) (push args seen)))))
      (cooked-user-var--osc (list (concat "SetUserVar=bad=" (base64-encode-string "a\377b"))))
      (should-not seen)
      (should-not cooked-user-vars)
      (cooked-user-var--osc (list (concat "SetUserVar=good="
                                          (base64-encode-string (encode-coding-string "ü" 'utf-8)))))
      (should (equal seen '(("good" "ü")))))))

(ert-deftest cooked-user-var-limit-refuses-new-names-but-not-updates ()
  (with-temp-buffer
    (cooked-mode)
    (let ((cooked-user-var-limit 2)
          (said nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (push (apply #'format fmt args) said))))
        (cooked-user-var--osc '("SetUserVar=a=MQ=="))
        (cooked-user-var--osc '("SetUserVar=b=Mg=="))
        (cooked-user-var--osc '("SetUserVar=c=Mw=="))
        (cooked-user-var--osc '("SetUserVar=a=NA==")))
      (should (equal (cooked-user-var "a") "4"))
      (should (equal (cooked-user-var "b") "2"))
      (should-not (cooked-user-var "c"))
      (should (equal (length said) 1))
      (should (string-match-p "cooked-user-var-limit" (car said))))))

(ert-deftest cooked-user-var-ignores-what-is-not-a-well-formed-set ()
  "Other 1337 keys are not ours, and bad base64 is the child's bug."
  (with-temp-buffer
    (cooked-mode)
    (let* ((ran nil)
           (cooked-user-var-functions (list (lambda (&rest _) (setq ran t)))))
      (cooked-user-var--osc '("CurrentDir=/tmp"))
      (cooked-user-var--osc '("SetUserVar==YmFy"))
      (cooked-user-var--osc '("SetUserVar=novalue"))
      (cooked-user-var--osc '("SetUserVar=bad=not*base64"))
      (should-not ran)
      (should-not cooked-user-vars)
      ;; Unpadded base64 is cosmetic, not malformed; an empty value is a value.
      (cooked-user-var--osc '("SetUserVar=bare=YmE"))
      (cooked-user-var--osc '("SetUserVar=empty="))
      (should (equal (cooked-user-var "bare") "ba"))
      (should (equal (assoc "empty" cooked-user-vars) '("empty" . ""))))))

(ert-deftest cooked-user-var-yields-to-a-1337-handler-of-your-own ()
  "Loading the layer must not silently displace a handler already configured."
  (let ((cooked-osc-handlers (cons (cons 1337 #'ignore)
                                   (assq-delete-all 1337 (copy-alist cooked-osc-handlers)))))
    (load (locate-library "cooked-user-var.el") nil t t)
    (should (eq (alist-get 1337 cooked-osc-handlers) #'ignore))
    (should (rassq 'cooked-user-var--osc cooked-osc-handlers))))

(provide 'cooked-tests-osc)
;;; cooked-tests-osc.el ends here
