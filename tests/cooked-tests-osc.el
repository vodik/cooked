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

(ert-deftest cooked-osc-51-is-closed-until-opted-in ()
  "The command channel is the one place terminal output becomes action, so it
must do nothing at all until the user has loaded `cooked-osc-eval' on purpose."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let ((cooked-osc-eval-function nil)
          (ran nil))
      (let ((cooked-eval-commands `(("find-file" . ,(lambda (&rest _) (setq ran t))))))
        (cooked--osc-emacs '("E\"find-file\" \"/tmp/x\""))
        (should-not ran))
      ;; The annotation half is inert, so it keeps working without opting in.
      (cooked--osc-emacs '("Asimon@host:~"))
      (should (equal cooked--annotation "simon@host:~")))))

(ert-deftest cooked-osc-51-runs-allowlisted-commands ()
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let* ((called nil)
           (cooked-eval-commands `(("noted" . ,(lambda (&rest args) (setq called args))))))
      (cooked--osc-emacs '("E\"noted\" \"one\" \"two\""))
      (should (equal called '("one" "two"))))))

(ert-deftest cooked-osc-51-refuses-anything-not-allowlisted ()
  "The allowlist is the entire defence: output from a hostile host reaches here."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let ((cooked-eval-commands '(("find-file" . ignore)))
          (danger nil))
      (cl-letf (((symbol-function 'shell-command)
                 (lambda (&rest _) (setq danger t))))
        (cooked--osc-emacs '("E\"shell-command\" \"rm -rf /\""))
        (should-not danger))
      ;; Nor by interning a name that merely exists as a function.
      (cl-letf (((symbol-function 'delete-file)
                 (lambda (&rest _) (setq danger t))))
        (cooked--osc-emacs '("E\"delete-file\" \"/tmp/x\""))
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
      (should (equal got "/tmp/a;b")))))

(ert-deftest cooked-osc-51-annotation-is-recorded ()
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (cooked--osc-emacs '("Asimon@ryzen:~/src"))
    (should (equal cooked--annotation "simon@ryzen:~/src"))))

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
          (should (string-match-p "echo alpha" (cooked-tests--text))))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer))))

(ert-deftest cooked-delete-output-reaches-output-that-has-scrolled-off ()
  "The case worth having it for: a long build log is exactly the output you want
gone, and exactly the output that has left the grid.  Each half has one owner --
the emulator removes the rows it still holds, Emacs deletes the scrollback it
owns outright -- and the seam bookkeeping is only owed when the cut reaches it."
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
          ;; More lines than the grid is tall, so most of it scrolls into scrollback.
          (cooked--replace-input "seq 1 60")
          (cooked-send-input)
          (should (cooked-tests--settle
                   (lambda () (and cooked--commands
                                   (eq cooked--semantic 'input)
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
                     (lambda () (progn (cooked--drain-and-apply) t)) 4))))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer))))

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
