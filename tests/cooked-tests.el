;;; cooked-tests.el --- End-to-end tests against a real child -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cooked)
(require 'cooked-mode)

(defmacro cooked-tests--with-session (argv &rest body)
  "Run BODY in a live cooked buffer running ARGV."
  (declare (indent 1))
  `(let ((buffer (generate-new-buffer "*cooked-test*")))
     (unwind-protect
         (with-current-buffer buffer
           (cooked-mode)
           (cooked--start ,argv)
           (cooked--refresh-keymap)
           ,@body)
       (with-current-buffer buffer (cooked--cleanup))
       (kill-buffer buffer))))

(defun cooked-tests--settle (predicate &optional seconds)
  "Pump the event loop until PREDICATE holds or SECONDS elapse."
  (let ((deadline (+ (float-time) (or seconds 5))))
    (while (and (< (float-time) deadline) (not (funcall predicate)))
      (accept-process-output nil 0.05)
      (when cooked--session (cooked--apply (cooked--drain cooked--session))))
    (funcall predicate)))

(defun cooked-tests--text ()
  "Visible buffer text with trailing blank lines removed."
  (string-trim-right (buffer-substring-no-properties (point-min) (point-max))))

(ert-deftest cooked-module-loads-and-defines-its-api ()
  (cooked--load-module)
  (should (featurep 'cooked-core))
  (dolist (fn '(cooked--spawn cooked--drain cooked--send cooked--resize cooked--mode))
    (should (fboundp fn))))

(ert-deftest cooked-child-output-reaches-the-buffer ()
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'hello world\\n'")
    (should (cooked-tests--settle
             (lambda () (string-match-p "hello world" (cooked-tests--text)))))))

(ert-deftest cooked-colors-become-faces ()
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '\\033[31mred\\033[0m\\n'")
    (should (cooked-tests--settle
             (lambda () (string-match-p "red" (cooked-tests--text)))))
    (goto-char (point-min))
    (should (search-forward "red" nil t))
    (let ((face (get-text-property (- (point) 1) 'face)))
      (should (equal (plist-get face :foreground) (aref cooked-color-names 1))))))

(ert-deftest cooked-cooked-mode-gives-emacs-the-input-line ()
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle (lambda () (eq cooked--mode 'cooked))))
    (should (cooked--input-state-p))
    (should (eq (current-local-map) cooked-input-map))
    ;; Typing edits the buffer; nothing has been sent to the child yet.
    (cooked--restore-pending-input nil)
    (goto-char cooked--input-end)
    (insert "typed")
    (should (equal (cooked--pending-input) "typed"))
    (cooked-send-input)
    (should (cooked-tests--settle
             (lambda () (string-match-p "typed" (cooked-tests--text)))))))

(defmacro cooked-tests--with-fake-zdotdir (files &rest body)
  "Run BODY with ZDOTDIR pointing at a directory built from FILES.
FILES is an alist of (NAME . CONTENTS)."
  (declare (indent 1))
  `(let* ((home (make-temp-file "cooked-fake-zdot-" t))
          (process-environment (cons (concat "ZDOTDIR=" home) process-environment)))
     (unwind-protect
         (progn
           (pcase-dolist (`(,name . ,contents) ,files)
             (with-temp-file (expand-file-name name home) (insert contents)))
           ,@body)
       (delete-directory home t))))

(ert-deftest cooked-shell-invocation-cleans-up-after-itself ()
  (pcase-let ((`(,_argv ,_env ,scratch) (cooked--shell-invocation "/bin/zsh")))
    (should (file-directory-p scratch))
    ;; zsh reads every startup file from ZDOTDIR, so all of them need a stub.
    (dolist (file '(".zshenv" ".zprofile" ".zshrc" ".zlogin"))
      (should (file-exists-p (expand-file-name file scratch))))
    (let ((cooked--scratch scratch))
      (cooked--remove-scratch)
      (should-not (file-exists-p scratch))
      (should-not cooked--scratch))))

(ert-deftest cooked-zsh-sources-the-users-zshenv ()
  "Regression: ZDOTDIR pointed at a directory with only a .zshrc, so the user's
own ~/.zshenv — where PATH and friends usually live — was never read."
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-fake-zdotdir
      '((".zshenv" . "export COOKED_ZSHENV_WITNESS=yes\n")
        (".zshrc" . "export COOKED_ZSHRC_WITNESS=yes\n"))
    (let ((buffer (generate-new-buffer "*cooked-zshenv*")))
      (unwind-protect
          (with-current-buffer buffer
            (cooked-mode)
            (pcase-let ((`(,argv ,env ,scratch)
                         (cooked--shell-invocation (executable-find "zsh"))))
              (setq cooked--scratch scratch)
              (cooked--start argv nil env))
            (cooked--refresh-keymap)
            (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input))))
            (cooked--send cooked--session "echo env=$COOKED_ZSHENV_WITNESS rc=$COOKED_ZSHRC_WITNESS\r")
            (should (cooked-tests--settle
                     (lambda () (string-match-p "env=yes rc=yes" (cooked-tests--text)))))
            ;; And ZDOTDIR is handed back, so nested shells still find the real config.
            ;; Compared against the actual paths, not a literal /tmp: macOS puts temp
            ;; files under $TMPDIR in /var/folders.
            (let ((user-zdotdir (getenv "ZDOTDIR")))
              (cooked--send cooked--session "echo zdot=$ZDOTDIR\r")
              (should (cooked-tests--settle
                       (lambda () (string-match-p (concat "zdot=" (regexp-quote user-zdotdir))
                                                  (cooked-tests--text)))))
              (should-not (string-match-p (concat "zdot=" (regexp-quote cooked--scratch))
                                          (cooked-tests--text)))))
        (with-current-buffer buffer (cooked--cleanup))
        (kill-buffer buffer)))))

(ert-deftest cooked-zsh-survives-a-theme-that-rebuilds-the-prompt ()
  "Regression: the 133;B mark was appended to PS1 once at source time, so any
theme rebuilding PS1 from its own precmd dropped it — and with it the whole
hand-the-keyboard-back feature.  Exit codes broke the same way, because our
precmd then ran after the theme's and read its status instead of the command's."
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-fake-zdotdir
      '((".zshrc" . "__theme_precmd() { PS1='theme%% ' }\n\
autoload -Uz add-zsh-hook\n\
add-zsh-hook precmd __theme_precmd\n"))
    (let ((buffer (generate-new-buffer "*cooked-theme*")))
      (unwind-protect
          (with-current-buffer buffer
            (cooked-mode)
            (pcase-let ((`(,argv ,env ,scratch)
                         (cooked--shell-invocation (executable-find "zsh"))))
              (setq cooked--scratch scratch)
              (cooked--start argv nil env))
            (cooked--refresh-keymap)
            ;; Only an OSC 133;B can put us here.
            (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input))))
            ;; And the exit code still belongs to the command, not the theme's hook.
            (cooked--replace-input "exit 7")
            (cooked--send cooked--session "(exit 7)\r")
            (should (cooked-tests--settle
                     (lambda () (eql (cooked-last-exit-code) 7)))))
        (with-current-buffer buffer (cooked--cleanup))
        (kill-buffer buffer)))))

(ert-deftest cooked-cleanup-kills-the-child-without-waiting-for-gc ()
  "Clearing the Lisp variable only drops a reference; nothing guarantees a
collection ever runs, so the child has to be killed explicitly."
  (let ((buffer (generate-new-buffer "*cooked-kill*")) pid)
    (unwind-protect
        (with-current-buffer buffer
          (cooked-mode)
          (cooked--start '("/bin/sh" "-c" "sleep 300"))
          (setq pid (cooked--pid cooked--session))
          (should (zerop (call-process "kill" nil nil nil "-0" (number-to-string pid))))
          (cooked--cleanup)
          (should-not cooked--session)
          (should-not (zerop (call-process "kill" nil nil nil "-0" (number-to-string pid)))))
      (kill-buffer buffer))))

(ert-deftest cooked-core-refuses-values-that-are-not-sessions ()
  "The core compares a user-pointer's finalizer against its own before casting.
Emacs cannot tell one module's user-pointer from another's, so without that check
a foreign handle would be reinterpreted as a session."
  ;; No session here, so nothing else has pulled the core in yet.
  (cooked--load-module)
  (should-error (cooked--send 42 "x") :type 'wrong-type-argument)
  (should-error (cooked--send "not a session" "x") :type 'wrong-type-argument)
  (should-error (cooked--pid nil) :type 'wrong-type-argument)
  (should-error (cooked--kill (make-marker)) :type 'wrong-type-argument))

(ert-deftest cooked-raw-mode-passes-keys-through ()
  (cooked-tests--with-session '("/bin/sh" "-c" "stty -icanon -echo; sleep 5")
    (should (cooked-tests--settle (lambda () (eq cooked--mode 'raw))))
    (should-not (cooked--input-state-p))
    (should (eq (current-local-map) cooked-raw-map))))

(ert-deftest cooked-secret-mode-is-detected-and-prompts ()
  (cooked-tests--with-session
      '("/bin/sh" "-c"
        "printf 'Password: '; stty -echo; read p; stty echo; \
         if [ \"$p\" = hunter2 ]; then printf '\\nACCEPTED\\n'; else printf '\\nDENIED\\n'; fi; sleep 5")
    (should (cooked-tests--settle (lambda () (eq cooked--mode 'secret))))
    (let ((cooked-password-function (lambda (_prompt) "hunter2")))
      (cooked--prompt-secret (current-buffer)))
    (should (cooked-tests--settle
             (lambda () (string-match-p "ACCEPTED" (cooked-tests--text)))))
    ;; The child received it, but it was never echoed into the buffer.
    (should-not (string-match-p "hunter2" (buffer-substring-no-properties
                                           (point-min) (point-max))))))

(ert-deftest cooked-secret-prompt-text-is-recovered ()
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'Enter passphrase: '; stty -echo; sleep 5")
    (should (cooked-tests--settle (lambda () (eq cooked--mode 'secret))))
    (should (equal (cooked--prompt-text cooked--session) "Enter passphrase:"))))

(ert-deftest cooked-osc-133-drives-the-input-state ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "stty -icanon -echo; printf '\\033]133;A\\007$ \\033]133;B\\007'; sleep 5")
    ;; Raw mode would normally mean pass-through; the shell's mark overrides it.
    (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input))))
    (should (eq cooked--mode 'raw))
    (should (cooked--input-state-p))
    (should (eq (current-local-map) cooked-input-map))))

(ert-deftest cooked-command-output-is-tagged-with-its-exit-code ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\033]133;C\\007'; printf 'out\\n'; printf '\\033]133;D;3\\007'; sleep 5")
    (should (cooked-tests--settle (lambda () (string-match-p "out" (cooked-tests--text)))))
    (should (cooked-tests--settle (lambda () (null cooked--semantic))))))

(ert-deftest cooked-scrollback-accumulates-above-the-screen ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "for i in $(seq 60); do printf 'line%s\\n' $i; done; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "line60" (cooked-tests--text)))))
    ;; Early lines scrolled off the emulator but survive as buffer text.
    (should (string-match-p "line1\n" (cooked-tests--text)))
    (goto-char (point-min))
    (should (get-text-property (point) 'cooked-scrollback))))

(ert-deftest cooked-alt-screen-hides-then-restores-the-primary-screen ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf 'keepme\\n'; printf '\\033[?1049h'; printf 'inalt\\n'; \
                        sleep 0.3; printf '\\033[?1049l'; sleep 5")
    (should (cooked-tests--settle (lambda () cooked--alt)))
    ;; While on the alt screen the primary content is hidden, as in any terminal.
    (should (string-match-p "inalt" (cooked-tests--text)))
    ;; Leaving it restores the primary screen, and the alt content leaves no trace.
    (should (cooked-tests--settle (lambda () (not cooked--alt))))
    (should (cooked-tests--settle
             (lambda () (string-match-p "keepme" (cooked-tests--text)))))
    (should-not (string-match-p "inalt" (cooked-tests--text)))))

(ert-deftest cooked-exit-status-is-reported ()
  (cooked-tests--with-session '("/bin/sh" "-c" "exit 9")
    (should (cooked-tests--settle
             (lambda () (string-match-p "\\[exited 9\\]" (cooked-tests--text)))))))

(ert-deftest cooked-real-bash-reaches-input-state-at-its-prompt ()
  "The headline case: a real interactive shell, whose prompt is raw-mode."
  (skip-unless (executable-find "bash"))
  (let ((buffer (generate-new-buffer "*cooked-bash*")))
    (unwind-protect
        (with-current-buffer buffer
          (cooked-mode)
          (pcase-let ((`(,argv ,env ,_scratch) (cooked--shell-invocation (executable-find "bash"))))
            (cooked--start argv nil env))
          (cooked--refresh-keymap)
          ;; The shell's own line editor puts the tty in raw mode...
          (should (cooked-tests--settle (lambda () (eq cooked--mode 'raw))))
          ;; ...yet OSC 133 still hands the line to Emacs.
          (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input))))
          (should (cooked--input-state-p))
          (should (eq (current-local-map) cooked-input-map))
          ;; Submitting runs the command and the output is attributed to it.
          (cooked--restore-pending-input nil)
          (goto-char cooked--input-end)
          (insert "echo marker-ok")
          (cooked-send-input)
          (should (cooked-tests--settle
                   (lambda () (string-match-p "marker-ok" (cooked-tests--text)))))
          (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input)))))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer))))

(ert-deftest cooked-colors-survive-font-lock ()
  "comint leaves `font-lock-defaults' at (nil t); fontifying unfontifies first,
which strips a bare `face' property and with it every colour."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '\\033[32mGREEN\\033[0m\\n'; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "GREEN" (cooked-tests--text)))))
    (goto-char (point-min))
    (should (search-forward "GREEN" nil t))
    (let ((pos (- (point) 2)))
      (should (get-text-property pos 'face))
      (font-lock-ensure)
      (should (get-text-property pos 'font-lock-face))
      (should (equal (plist-get (get-text-property pos 'font-lock-face) :foreground)
                     (cooked--color 2))))))

(ert-deftest cooked-colors-follow-the-theme ()
  (let ((resolved (cooked--color 1)))
    (should (stringp resolved))
    ;; With no theme styling ansi-color-red we fall back to the static palette.
    (should (equal resolved (or (face-foreground 'ansi-color-red nil t)
                                (aref cooked-color-names 1))))))

(ert-deftest cooked-scrollback-and-screen-are-read-only ()
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'banner\\n'; exec cat")
    (should (cooked-tests--settle
             (lambda () (string-match-p "banner" (cooked-tests--text)))))
    (should (eq cooked--mode 'cooked))
    (should (marker-position cooked--input-start))
    ;; The transcript above the input line refuses edits.
    (goto-char (point-min))
    (should-error (insert "nope") :type 'text-read-only)
    (should-error (delete-char 1) :type 'text-read-only)
    ;; ...but the input region itself takes text.
    (goto-char cooked--input-end)
    (insert "typed")
    (should (equal (cooked--pending-input) "typed"))))

(ert-deftest cooked-screen-is-trimmed-to-a-transcript ()
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'one\\ntwo\\n'; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "two" (cooked-tests--text)))))
    ;; Without trimming the buffer would carry a screenful of blank lines.
    (should (< (count-lines (point-min) (point-max)) 8))
    (should (string-match-p "one" (cooked-tests--text)))))

(ert-deftest cooked-comint-commands-are-remapped ()
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle (lambda () (eq cooked--mode 'cooked))))
    ;; evil-collection binds `repl-submit' to `comint-send-input'; the remap is
    ;; what makes that reach us.
    (should (eq (key-binding [remap comint-send-input]) #'cooked-send-input))
    (should (eq (key-binding [remap comint-interrupt-subjob]) #'cooked-interrupt))
    (should (keymap-parent cooked-input-map))))

(ert-deftest cooked-zsh-reports-command-exit-codes ()
  "Regression: `local status=$?' fails in zsh, which silently killed OSC 133;D."
  (skip-unless (executable-find "zsh"))
  (let ((buffer (generate-new-buffer "*cooked-zsh*")))
    (unwind-protect
        (with-current-buffer buffer
          (cooked-mode)
          (pcase-let ((`(,argv ,env ,_scratch) (cooked--shell-invocation (executable-find "zsh"))))
            (cooked--start argv nil env))
          (cooked--refresh-keymap)
          (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input))))
          (should-not (string-match-p "read-only variable" (cooked-tests--text)))
          (cooked--restore-pending-input nil)
          (goto-char cooked--input-end)
          (insert "(exit 42)")
          (cooked-send-input)
          (should (cooked-tests--settle (lambda () (cooked-last-exit-code))))
          (should (equal (cooked-last-exit-code) 42))
          ;; A command that printed nothing still gets a record.
          (should (= 1 (length cooked--commands)))
          ;; And a second one with output is tagged in the text too.
          (cooked--restore-pending-input nil)
          (goto-char cooked--input-end)
          (insert "echo out-marker")
          (cooked-send-input)
          (should (cooked-tests--settle
                   (lambda () (equal (cooked-last-exit-code) 0))))
          (should (string-match-p "out-marker" (cooked-tests--text))))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer))))

(ert-deftest cooked-evil-follows-keyboard-ownership ()
  "Evil must not interpret keys a TUI needs.

State syncing lives in `cooked-evil', which is opt-in, so the test has to opt in
the same way a user's configuration does — without it `cooked-state-change-hook'
has no handler and nothing drives evil at all."
  (skip-unless (and (executable-find "zsh") (require 'evil nil t)))
  (require 'cooked-evil)
  (evil-mode 1)
  (let ((buffer (generate-new-buffer "*cooked-evil*")))
    (unwind-protect
        (with-current-buffer buffer
          (cooked-mode)
          (pcase-let ((`(,argv ,env ,_scratch) (cooked--shell-invocation (executable-find "zsh"))))
            (cooked--start argv nil env))
          (cooked--refresh-keymap)
          (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input))))
          (should (eq (current-local-map) cooked-input-map))
          (should (eq evil-state 'insert))
          ;; RET submits from insert state by falling through to `cooked-input-map'.
          (should (eq (key-binding (kbd "RET")) #'cooked-send-input))
          ;; In normal state RET is evil's own, as in any other buffer: cooked no
          ;; longer installs a state-specific binding for it.
          (evil-normal-state)

          ;; A raw full-screen program takes the keyboard, and evil steps aside.
          ;; The shell restores canonical mode before exec'ing, so this is briefly
          ;; still an input state; wait for the program itself to go raw.
          (cooked--send cooked--session "stty raw -echo; sleep 1; stty sane\r")
          (should (cooked-tests--settle
                   (lambda () (and (eq cooked--semantic 'output)
                                   (eq (current-local-map) cooked-raw-map)))))
          (should (eq evil-state 'emacs))

          ;; ...and hands it back at the next prompt.
          (should (cooked-tests--settle
                   (lambda () (and (eq cooked--semantic 'input)
                                   (eq (current-local-map) cooked-input-map)))))
          (should (eq evil-state 'insert)))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer))))

(ert-deftest cooked-prompt-trailing-space-is-preserved ()
  "Trimming trailing blanks would put the input one column left of the prompt."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'ready$ '; exec cat")
    (should (cooked-tests--settle
             (lambda () (string-match-p "ready" (cooked-tests--text)))))
    (should (marker-position cooked--input-start))
    (goto-char cooked--input-start)
    (should (equal (char-before) ?\s))
    (should (equal (buffer-substring-no-properties (line-beginning-position)
                                                   cooked--input-start)
                   "ready$ "))))

(ert-deftest cooked-cursor-visibility-follows-the-child ()
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'x\\033[?25l'; sleep 5")
    (should (cooked-tests--settle (lambda () (null cursor-type))))
    (should-not (nth 2 cooked--cursor))))

(ert-deftest cooked-input-history-recalls-submissions ()
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle
             (lambda () (and (eq cooked--mode 'cooked) cooked--input-start))))
    (dolist (line '("first" "second"))
      (cooked--replace-input line)
      (cooked-send-input)
      (should (cooked-tests--settle
               (lambda () (string-match-p line (cooked-tests--text))))))

    ;; The binding that used to signal "Not at command line".
    (should (eq (key-binding [remap comint-previous-input]) #'cooked-previous-input))

    (cooked-previous-input)
    (should (equal (cooked--pending-input) "second"))
    (cooked-previous-input)
    (should (equal (cooked--pending-input) "first"))
    (cooked-next-input)
    (should (equal (cooked--pending-input) "second"))
    ;; Stepping past the newest entry restores what was being typed.
    (cooked-next-input)
    (should (equal (cooked--pending-input) ""))))

(ert-deftest cooked-history-preserves-work-in-progress ()
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle
             (lambda () (and (eq cooked--mode 'cooked) cooked--input-start))))
    (cooked--replace-input "remembered")
    (cooked-send-input)
    (should (cooked-tests--settle
             (lambda () (string-match-p "remembered" (cooked-tests--text)))))
    (cooked--replace-input "half-typed")
    (cooked-previous-input)
    (should (equal (cooked--pending-input) "remembered"))
    (cooked-next-input)
    (should (equal (cooked--pending-input) "half-typed"))))

(ert-deftest cooked-resize-reaches-sessions-in-other-buffers ()
  "`window-size-change-functions' runs per frame, not per buffer."
  (cooked-tests--with-session '("/bin/sh" "-c" "while true; do sleep 0.1; done")
    (should (cooked-tests--settle (lambda () cooked--session)))
    (let ((buffer (current-buffer)))
      (set-window-buffer (selected-window) buffer)
      (setq cooked--last-size nil)
      ;; Run the global hook from a different current buffer, as Emacs does.
      (with-temp-buffer
        (cooked--frame-size-changed (selected-frame)))
      (with-current-buffer buffer
        (should cooked--last-size)
        (should (= (car cooked--last-size)
                   (cooked--window-rows (get-buffer-window buffer))))
        (should (= (cdr cooked--last-size)
                   (window-max-chars-per-line (get-buffer-window buffer))))))))

(ert-deftest cooked-terminfo-is-installed-and-used ()
  "The child should see a TERM that describes what we actually implement."
  (skip-unless (executable-find "tic"))
  (should (equal (cooked--terminfo) cooked-term-name))
  (should (cooked--terminfo-known-p cooked-term-name))
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '%s|%s\\n' \"$TERM\" \"$(tput colors)\"; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p (regexp-quote cooked-term-name)
                                        (cooked-tests--text)))))
    ;; The entry resolves on the child's side, not just ours.
    (should (string-match-p "|256" (cooked-tests--text)))))

(ert-deftest cooked-terminfo-falls-back-when-unavailable ()
  (let ((cooked-term-name nil))
    (should (equal (cooked--terminfo) "xterm-256color"))))

(ert-deftest cooked-redisplay-survives-a-protected-buffer ()
  "Regression: `let' ran the initialisers before `inhibit-read-only' was bound,
so a drain touching protected text aborted the redisplay from inside the filter."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'banner\\n'; exec cat")
    (should (cooked-tests--settle
             (lambda () (string-match-p "banner" (cooked-tests--text)))))
    ;; Everything above the input is read-only by now.
    (should (get-text-property (point-min) 'read-only))
    (cooked--replace-input "typed")
    ;; A drain must not signal, and must leave the input intact.
    (cooked--apply (cooked--drain cooked--session))
    (should (equal (cooked--pending-input) "typed"))
    (should (marker-position cooked--input-start))))

(ert-deftest cooked-cursor-position-does-not-mutate ()
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle (lambda () cooked--input-start)))
    ;; Ask for a row far below the trimmed screen; it must not extend the buffer.
    (let ((cooked--cursor (list (+ 5 cooked--rows) 0 t))
          (before (buffer-string)))
      (cooked--cursor-position)
      (should (equal (buffer-string) before)))))

(ert-deftest cooked-resize-round-trip-keeps-the-transcript ()
  "Shrinking must absorb blank rows, not push the live screen into scrollback."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'alpha\\nbeta\\n'; exec cat")
    (should (cooked-tests--settle
             (lambda () (string-match-p "beta" (cooked-tests--text)))))
    (let ((original (cooked-tests--text)))
      (dolist (size '(10 40 24))
        (setq cooked--last-size nil)
        (setq cooked--rows size cooked--cols 80)
        (cooked--resize cooked--session size 80)
        (cooked-tests--settle (lambda () nil) 0.3))
      ;; No duplication, nothing lost.
      (let ((text (cooked-tests--text)))
        (should (string-match-p "alpha" text))
        (should (string-match-p "beta" text))
        (should (= 1 (cl-count "alpha" (split-string text "\n") :test #'string-search)))
        (should (equal (string-trim original) (string-trim text)))))))

(ert-deftest cooked-rows-do-not-merge-into-one-line ()
  "Regression: `forward-line' reports success at an unterminated final line,
so the next grid row was appended to the previous one — merging a command's
output with the prompt that followed it."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'aaa\\nbbb\\nccc\\n'; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "ccc" (cooked-tests--text)))))
    (let ((lines (split-string (cooked-tests--text) "\n")))
      (should (member "aaa" lines))
      (should (member "bbb" lines))
      (should (member "ccc" lines))
      (should-not (seq-find (lambda (l) (string-match-p "aaabbb\\|bbbccc" l)) lines)))))

(ert-deftest cooked-prompt-lands-on-its-own-line-after-a-command ()
  (skip-unless (executable-find "zsh"))
  (let ((buffer (generate-new-buffer "*cooked-zsh*")))
    (unwind-protect
        (with-current-buffer buffer
          (cooked-mode)
          (pcase-let ((`(,argv ,env ,_scratch) (cooked--shell-invocation (executable-find "zsh"))))
            (cooked--start argv nil env))
          (cooked--refresh-keymap)
          (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input))))
          (let ((prompt (string-trim (buffer-substring-no-properties
                                      (line-beginning-position) (point-max)))))
            (cooked--replace-input "printf 'one\\ntwo\\n'")
            (cooked-send-input)
            (should (cooked-tests--settle
                     (lambda () (and (eq cooked--semantic 'input)
                                     (string-match-p "two" (cooked-tests--text))))))
            (let ((lines (split-string (cooked-tests--text) "\n")))
              (should (member "one" lines))
              (should (member "two" lines))
              ;; The new prompt must not be glued onto the last output line.
              (should-not (seq-find (lambda (l)
                                      (and (string-match-p (regexp-quote prompt) l)
                                           (string-match-p "^two" l)))
                                    lines)))))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer))))

(ert-deftest cooked-point-follows-the-cursor-after-falling-behind ()
  "Regression: output arriving in chunks let the cursor overtake point for one
drain, after which point was stranded at column 0 of whatever line it was on."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'aaa\\nbbb\\n'; exec cat")
    (should (cooked-tests--settle
             (lambda () (string-match-p "bbb" (cooked-tests--text)))))
    ;; Put point behind the cursor but still inside the live screen, exactly the
    ;; state a chunked drain used to leave it in.
    (goto-char (marker-position cooked--screen-start))
    (should (< (point) (cooked--cursor-position)))
    (cooked--send cooked--session "ccc\n")
    (should (cooked-tests--settle
             (lambda () (string-match-p "ccc" (cooked-tests--text)))))
    ;; Point must be back at the input position rather than stranded behind.
    (should (equal (point) (cooked--point-after-input)))
    (should (> (point) (marker-position cooked--screen-start)))))

(ert-deftest cooked-point-stays-put-while-reading-scrollback ()
  "Following the cursor must not yank point away from someone reading history."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "for i in $(seq 60); do printf 'line%s\\n' $i; done; exec cat")
    (should (cooked-tests--settle
             (lambda () (string-match-p "line60" (cooked-tests--text)))))
    (goto-char (point-min))
    (let ((parked (point)))
      (cooked--send cooked--session "more\n")
      (should (cooked-tests--settle
               (lambda () (string-match-p "more" (cooked-tests--text)))))
      (should (equal (point) parked)))))

(ert-deftest cooked-arrow-keys-follow-application-cursor-mode ()
  "Regression: DECCKM was ignored, so arrows reached full-screen programs in the
CSI encoding while ncurses (via `smkx') expects SS3, and nothing happened."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (setq cooked--app-cursor nil)
    (should (equal (cooked--encode-event 'up) "\e[A"))
    (should (equal (cooked--encode-event 'left) "\e[D"))
    (setq cooked--app-cursor t)
    (should (equal (cooked--encode-event 'up) "\eOA"))
    (should (equal (cooked--encode-event 'left) "\eOD"))
    ;; Keys outside the cursor cluster are unaffected by the mode.
    (should (equal (cooked--encode-event 'next) "\e[6~"))))

(ert-deftest cooked-application-cursor-mode-round-trips ()
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '\\033[?1h'; sleep 5")
    (should (cooked-tests--settle (lambda () cooked--app-cursor)))
    (should (equal (cooked--encode-event 'up) "\eOA"))))

(ert-deftest cooked-alt-screen-keeps-exactly-the-emulator-height ()
  "Trimming is disabled on the alt screen, so nothing else removes stale rows
when the window shrinks — which looked like resize doing nothing."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '\\033[?1049h'; printf 'top\\n'; sleep 5")
    (should (cooked-tests--settle (lambda () cooked--alt)))
    (let ((screen-lines (lambda ()
                          (count-lines (marker-position cooked--screen-start) (point-max)))))
      (should (= (funcall screen-lines) cooked--rows))
      ;; Shrink: the region must follow, not keep the old rows.
      (setq cooked--rows 10 cooked--cols 40)
      (cooked--resize cooked--session 10 40)
      (should (cooked-tests--settle (lambda () (= (funcall screen-lines) 10))))
      ;; And grow again.
      (setq cooked--rows 30)
      (cooked--resize cooked--session 30 40)
      (should (cooked-tests--settle (lambda () (= (funcall screen-lines) 30)))))))

(ert-deftest cooked-mouse-reports-reach-the-child ()
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '\\033[?1000h\\033[?1006h'; exec cat")
    (should (cooked-tests--settle (lambda () cooked--mouse)))
    (should cooked--mouse-sgr)
    (should (equal (cooked--mouse-report 0 4 9 t) "\e[<0;10;5M"))
    (should (equal (cooked--mouse-report 0 4 9 nil) "\e[<0;10;5m"))
    (should (equal (cooked--mouse-report 64 0 0 t) "\e[<64;1;1M"))))

(ert-deftest cooked-mouse-x10-encoding-when-sgr-is-off ()
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '\\033[?1000h'; exec cat")
    (should (cooked-tests--settle (lambda () cooked--mouse)))
    (should-not cooked--mouse-sgr)
    ;; X10 biases coordinates by 32 and is 1-based, so column 0 is ?!.
    (should (equal (cooked--mouse-report 0 0 0 t) "\e[M !!"))
    (should (equal (cooked--mouse-report 0 2 4 t) "\e[M %#"))
    ;; Release is button 3 in X10, which cannot say which button was let go.
    (should (equal (cooked--mouse-report 0 0 0 nil) "\e[M#!!"))))

(ert-deftest cooked-mouse-is-left-to-emacs-when-unrequested ()
  "A child that never asked for mouse reports must not steal the click."
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle (lambda () cooked--input-start)))
    ;; The child never enabled reporting, so `cooked-mouse-event' takes the
    ;; fallback branch and the click behaves as it would in any buffer.
    (should-not cooked--mouse)
    (should (eq (lookup-key cooked-raw-map [mouse-1]) #'cooked-mouse-event))))

(ert-deftest cooked-does-not-pin-lines-and-columns ()
  "Regression: exporting LINES/COLUMNS makes ncurses ignore the tty size, so a
full-screen program keeps its startup geometry and never honours SIGWINCH."
  (let ((env (cooked--child-environment)))
    (should-not (assoc "LINES" env))
    (should-not (assoc "COLUMNS" env)))
  ;; Also stripped when inherited from the Emacs that launched us.
  (let* ((process-environment (append '("LINES=11" "COLUMNS=22") process-environment))
         (env (cooked--child-environment)))
    (should-not (assoc "LINES" env))
    (should-not (assoc "COLUMNS" env))))

(ert-deftest cooked-full-screen-programs-redraw-after-a-resize ()
  "End to end: htop must move its footer when the terminal grows."
  (skip-unless (executable-find "htop"))
  (let ((buffer (generate-new-buffer "*cooked-htop*")))
    (unwind-protect
        (with-current-buffer buffer
          (cooked-mode)
          (setq cooked--rows 20 cooked--cols 90 cooked--last-size '(20 . 90))
          (cooked--start '("htop" "-d" "5"))
          (cooked--refresh-keymap)
          (cl-flet ((footer-row ()
                      (save-excursion
                        (goto-char (marker-position cooked--screen-start))
                        (let ((i 0) found)
                          (while (and (not found) (not (eobp)))
                            (when (string-match-p "F10" (buffer-substring-no-properties
                                                         (line-beginning-position)
                                                         (line-end-position)))
                              (setq found i))
                            (setq i (1+ i))
                            (forward-line 1))
                          found))))
            (should (cooked-tests--settle (lambda () (eql (footer-row) 19)) 8))
            (setq cooked--rows 40 cooked--last-size '(40 . 90))
            (cooked--resize cooked--session 40 90)
            (should (cooked-tests--settle (lambda () (eql (footer-row) 39)) 8))
            (should (= (count-lines (marker-position cooked--screen-start) (point-max)) 40))))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer))))

;;;; Generic OSC dispatch

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

(ert-deftest cooked-osc-handler-errors-do-not-break-redisplay ()
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '\\033]2;boom\\007'; printf 'after\\n'; sleep 5")
    (let ((cooked-osc-handlers '((2 . (lambda (_parts) (error "deliberate"))))))
      ;; The handler blows up, but output after it still renders.
      (should (cooked-tests--settle
               (lambda () (string-match-p "after" (cooked-tests--text))))))))

;;;; OSC 51 — the Emacs command channel
;;
;; Opt-in, so these load it explicitly.  `cooked-osc-51-is-closed-until-opted-in'
;; below covers the other half: that it really is closed until you do.

(require 'cooked-osc-eval)

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

;;;; OSC 52 — clipboard

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

;;;; OSC 10/11/12 — the default colors
;;
;; The child is put in raw mode first: the reply carries no newline, so a canonical
;; read would sit on it forever, and echo would put it in the buffer instead.

(defun cooked-tests--reply-to (query out)
  "Shell that sends QUERY, then copies whatever comes back into OUT."
  (list "/bin/sh" "-c"
        (format "stty raw -echo; printf '%s'; cat > %s" query out)))

(defun cooked-tests--contents (file)
  "Contents of FILE, or the empty string if it has none yet."
  (with-temp-buffer
    (ignore-errors (insert-file-contents file))
    (buffer-string)))

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

(ert-deftest cooked-clear-scrollback-keeps-the-live-screen ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "for i in $(seq 60); do printf 'line%s\\n' $i; done; exec cat")
    (should (cooked-tests--settle
             (lambda () (string-match-p "line60" (cooked-tests--text)))))
    (should (string-match-p "line1\n" (cooked-tests--text)))
    (cooked-clear-scrollback)
    (should-not (string-match-p "line1\n" (cooked-tests--text)))
    (should (string-match-p "line60" (cooked-tests--text)))))

;;;; Packaging

(ert-deftest cooked-buffer-names-are-configurable-and-unique ()
  (let ((cooked-buffer-name "*cooked: %s*"))
    (should (string-match-p "\\*cooked: .+\\*" (cooked--buffer-name "/tmp/")))
    (let ((buffer (generate-new-buffer (cooked--buffer-name "/tmp/"))))
      (unwind-protect
          ;; A second session in the same directory must not collide.
          (should-not (equal (buffer-name buffer) (cooked--buffer-name "/tmp/")))
        (kill-buffer buffer))))
  (let ((cooked-buffer-name (lambda (dir) (format "term[%s]" dir))))
    (should (equal (cooked--buffer-name "/tmp/") "term[/tmp/]"))))

(ert-deftest cooked-title-renames-the-buffer-only-when-asked ()
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '\\033]2;running-thing\\007'; sleep 5")
    (let ((original (buffer-name)))
      (should (cooked-tests--settle (lambda () (equal cooked--title "running-thing"))))
      ;; Default is off: a name that moves under you is hard to find again.
      (should (equal (buffer-name) original)))))

(ert-deftest cooked-live-buffers-finds-running-sessions ()
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (should (memq (current-buffer) (cooked--live-buffers)))))

(ert-deftest cooked-send-eof-reaches-the-child ()
  "C-c C-d must end input even when the line is not empty."
  (cooked-tests--with-session '("/bin/sh" "-c" "cat; printf 'SAW-EOF\\n'; sleep 5")
    (should (cooked-tests--settle (lambda () (eq cooked--mode 'cooked))))
    (should (eq (lookup-key cooked-raw-map (kbd "C-c C-d")) #'cooked-send-eof))
    (should (eq (lookup-key cooked-input-map (kbd "C-c C-d")) #'cooked-send-eof))
    (cooked--send cooked--session "partial line\n")
    (should (cooked-tests--settle
             (lambda () (string-match-p "partial line" (cooked-tests--text)))))
    (cooked-send-eof)
    (should (cooked-tests--settle
             (lambda () (string-match-p "SAW-EOF" (cooked-tests--text)))))))

(ert-deftest cooked-shifted-keys-are-not-flattened ()
  "Regression: Emacs reports S as shift+s, so reading `event-basic-type' alone
turned every capital letter into a lowercase one."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (setq cooked--app-cursor nil)
    (should (equal (cooked--encode-event ?S) "S"))
    (should (equal (cooked--encode-event ?A) "A"))
    (should (equal (cooked--encode-event ?s) "s"))
    (should (equal (cooked--encode-event ?!) "!"))
    ;; Control and meta still survive.
    (should (equal (cooked--encode-event ?\C-a) "\C-a"))
    (should (equal (cooked--encode-event ?\M-x) "\ex"))))

(ert-deftest cooked-modified-arrows-use-xterm-parameters ()
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (setq cooked--app-cursor nil)
    (should (equal (cooked--encode-event 'up) "\e[A"))
    (should (equal (cooked--encode-event 'S-up) "\e[1;2A"))
    (should (equal (cooked--encode-event 'M-up) "\e[1;3A"))
    (should (equal (cooked--encode-event 'C-up) "\e[1;5A"))
    (should (equal (cooked--encode-event 'C-S-right) "\e[1;6C"))
    ;; DECCKM only applies to the unmodified form.
    (setq cooked--app-cursor t)
    (should (equal (cooked--encode-event 'up) "\eOA"))
    (should (equal (cooked--encode-event 'C-up) "\e[1;5A"))))

(ert-deftest cooked-modified-special-keys-are-encoded ()
  "Regression: the special-key branch applied only the meta modifier, so
Shift+Return, Control+Return, Shift+F5 and Shift+PageDown were all sent as their
unmodified selves, and Shift+TAB produced nothing at all."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (setq cooked--app-cursor nil)
    ;; Shift+TAB has a real terminfo entry (kcbt), so it needs no negotiation.
    (should (equal (cooked--encode-event 'backtab) "\e[Z"))
    ;; Tilde-style keys take the modifier as a second parameter.
    (should (equal (cooked--encode-event 'f5) "\e[15~"))
    (should (equal (cooked--encode-event 'S-f5) "\e[15;2~"))
    (should (equal (cooked--encode-event 'S-next) "\e[6;2~"))
    ;; F1-F4 are SS3 until modified, then CSI like everything else.
    (should (equal (cooked--encode-event 'f1) "\eOP"))
    (should (equal (cooked--encode-event 'S-f1) "\e[1;2P"))

    ;; Return and friends have no classical modified form, so they follow whatever
    ;; the child negotiated — and send the bare byte when it negotiated nothing.
    (setq cooked--keys 'legacy)
    (should (equal (cooked--encode-event 'return) "\r"))
    (should (equal (cooked--encode-event 'S-return) "\r"))
    (should (equal (cooked--encode-event 'M-return) "\e\r"))

    (setq cooked--keys 'modify-other)
    (should (equal (cooked--encode-event 'S-return) "\e[27;2;13~"))
    (should (equal (cooked--encode-event 'C-return) "\e[27;5;13~"))
    (should (equal (cooked--encode-event 'C-tab) "\e[27;5;9~"))
    ;; Unmodified stays plain regardless of what was negotiated.
    (should (equal (cooked--encode-event 'return) "\r"))

    (setq cooked--keys 'kitty)
    (should (equal (cooked--encode-event 'S-return) "\e[13;2u"))
    (should (equal (cooked--encode-event 'C-return) "\e[13;5u"))
    (should (equal (cooked--encode-event 'return) "\r"))))

(defun cooked-tests--type (keys)
  "Run KEYS through the command loop, so `pre-command-hook' applies."
  (execute-kbd-macro (kbd keys)))

(ert-deftest cooked-typing-snaps-into-the-input-region ()
  "Regression, from two directions.

The screen is rendered with a newline after the last row, so there is a blank
line below the prompt; typing there used to land outside the input markers, and
`cooked-send-input' would then submit an empty line while the text sat in the
buffer looking accepted.  Before the region, the prompt is read-only, so typing
signalled \"Text is read-only\" — which is exactly where evil's normal state
leaves the cursor at an empty prompt, since it pulls back off the end of a line."
  (skip-unless (executable-find "zsh"))
  (let ((buffer (generate-new-buffer "*cooked-snap*")))
    (unwind-protect
        (with-current-buffer buffer
          (cooked-mode)
          (pcase-let ((`(,argv ,env ,scratch)
                       (cooked--shell-invocation (executable-find "zsh"))))
            (setq cooked--scratch scratch)
            (cooked--start argv nil env))
          (cooked--refresh-keymap)
          (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input))))
          (switch-to-buffer buffer)

          ;; Below the input region: the blank line the screen render leaves.
          (goto-char (point-max))
          (should (> (point) (marker-position cooked--input-end)))
          (cooked-tests--type "e c h o")
          (should (equal (cooked--pending-input) "echo"))

          ;; Before it: inside the read-only prompt, where evil parks the cursor.
          (cooked-kill-input)
          (goto-char (1- (marker-position cooked--input-start)))
          (cooked-tests--type "h i")
          (should (equal (cooked--pending-input) "hi")))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer))))

(ert-deftest cooked-window-rows-round-a-partial-row-down ()
  "A row only half on screen is not a row the child can use."
  (let* ((window (selected-window))
         (line (window-default-line-height window))
         (rows (cooked--window-rows window)))
    (should (integerp rows))
    ;; The claimed rows must fit in the pixels actually available.
    (should (<= (* rows line) (window-body-height window t)))
    ;; And be the largest number that does.
    (should (> (* (1+ rows) line) (window-body-height window t)))))

(ert-deftest cooked-c-c-m-x-escapes-back-to-emacs ()
  "In raw state every key including ESC goes to the child, so plain M-x arrives
there as ESC x.  C-c M-x is the way back to Emacs, and honours whatever the user
has bound M-x to."
  (should (eq (lookup-key cooked-raw-map (kbd "C-c M-x")) #'cooked-meta-x))
  (should (eq (lookup-key cooked-input-map (kbd "C-c M-x")) #'cooked-meta-x))
  ;; Plain M-x is still the child's in raw state — that is the behaviour C-c M-x
  ;; exists to work around, not one to break.
  (should (eq (lookup-key cooked-raw-map (kbd "ESC")) #'cooked-send-key))
  (let (ran)
    (cl-letf (((symbol-function 'execute-extended-command) (lambda (&rest _) (interactive) (setq ran t))))
      (call-interactively #'cooked-meta-x)
      (should ran))))

(ert-deftest cooked-modified-keys-survive-shift-translation ()
  "Without a binding of its own, Emacs translates S-return to return before the
command runs, flattening the event past recovery.  The binding is the fix."
  (should (eq (lookup-key cooked-raw-map [S-return]) #'cooked-send-key))
  (should (eq (lookup-key cooked-raw-map [C-return]) #'cooked-send-key))
  (should (eq (lookup-key cooked-raw-map [backtab]) #'cooked-send-key))
  (should (eq (lookup-key cooked-raw-map [S-f5]) #'cooked-send-key))
  ;; At a prompt the same key composes a multi-line command instead.
  (should (eq (lookup-key cooked-input-map [S-return]) #'cooked-newline)))

(ert-deftest cooked-shift-return-composes-multiple-lines ()
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle (lambda () (eq cooked--mode 'cooked))))
    (cooked--restore-pending-input nil)
    (goto-char cooked--input-end)
    (insert "first")
    (cooked-newline)
    (insert "second")
    (should (equal (cooked--pending-input) "first\nsecond"))))

(ert-deftest cooked-shift-reaches-the-child ()
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle (lambda () (eq cooked--mode 'cooked))))
    (cooked--send cooked--session (cooked--encode-event ?S))
    (cooked--send cooked--session (cooked--encode-event ?H))
    (cooked--send cooked--session "\r")
    (should (cooked-tests--settle
             (lambda () (string-match-p "SH" (cooked-tests--text)))))))

;;;; Completion

(ert-deftest cooked-completion-offers-programs-then-files ()
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'ready$ '; exec cat")
    (should (cooked-tests--settle
             (lambda () (and (string-match-p "ready" (cooked-tests--text))
                             cooked--input-start))))
    ;; First word: programs on PATH.
    (goto-char cooked--input-end)
    (insert "ls")
    (pcase-let ((`(,start ,end ,table . ,_) (cooked-completion-at-point)))
      (should (= start (marker-position cooked--input-start)))
      (should (= end (point)))
      (should (member "ls" (all-completions "ls" table))))
    ;; Later words complete as file names, relative to the child's directory.
    (insert " REA")
    (pcase-let ((`(,start ,end ,table . ,_) (cooked-completion-at-point)))
      (should (> start (marker-position cooked--input-start)))
      (should (= end (point)))
      (let ((default-directory (file-name-directory
                                (directory-file-name cooked--source-directory))))
        (should (member "README.md" (all-completions "REA" table)))))))

(ert-deftest cooked-size-follows-the-smallest-window ()
  "One child, possibly several windows: the largest would wrap in the smallest."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let ((buffer (current-buffer)))
      (delete-other-windows)
      (set-window-buffer (selected-window) buffer)
      (let* ((tall (cdr (cooked--window-size)))
             (other (split-window (selected-window) nil 'right)))
        (set-window-buffer other buffer)
        ;; Two windows now, each narrower than the original single one.
        (should (= (length (get-buffer-window-list buffer nil t)) 2))
        (pcase-let ((`(_ . ,cols) (cooked--window-size)))
          (should (< cols tall))
          (should (= cols (apply #'min (mapcar #'window-max-chars-per-line
                                               (get-buffer-window-list buffer nil t))))))
        (delete-window other)))))

(ert-deftest cooked-completion-is-a-normal-capf ()
  "So corfu, cape and friends work without knowing about cooked."
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle (lambda () cooked--input-start)))
    (should (memq #'cooked-completion-at-point completion-at-point-functions))
    (should (eq (lookup-key cooked-input-map (kbd "TAB")) #'completion-at-point))))

(ert-deftest cooked-completion-declines-outside-the-input-line ()
  "Raw-mode programs get their own TAB; we must not complete over them."
  (cooked-tests--with-session '("/bin/sh" "-c" "stty -icanon -echo; sleep 5")
    (should (cooked-tests--settle (lambda () (eq cooked--mode 'raw))))
    (should-not (cooked-completion-at-point))))

(ert-deftest cooked-wrapped-lines-rejoin-in-scrollback ()
  "A line the terminal wrapped is one line again, so yanking history does not
pick up newlines nobody typed, and a wider window re-wraps it for free."
  (let ((buffer (generate-new-buffer "*cooked-wrap*")))
    (unwind-protect
        (with-current-buffer buffer
          (cooked-mode)
          (setq cooked--rows 4 cooked--cols 20 cooked--last-size '(4 . 20))
          ;; 60 characters through a 20-column terminal: three screen rows, one line.
          (cooked--start '("/bin/sh" "-c"
                           "printf 'AAAAAAAAAABBBBBBBBBBCCCCCCCCCCDDDDDDDDDDEEEEEEEEEEFFFFFFFFFF\\n'; \
                            printf 'tail\\n'; printf 'x\\n'; printf 'y\\n'; sleep 5"))
          (cooked--refresh-keymap)
          (should (cooked-tests--settle
                   (lambda () (string-match-p "FFFFFFFFFF" (cooked-tests--text)))))
          (goto-char (point-min))
          (should (looking-at-p (regexp-quote (concat "AAAAAAAAAABBBBBBBBBB"
                                                      "CCCCCCCCCCDDDDDDDDDD"
                                                      "EEEEEEEEEEFFFFFFFFFF")))))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer))))

(ert-deftest cooked-wrapped-lines-stay-split-when-asked ()
  (let ((buffer (generate-new-buffer "*cooked-wrap2*")))
    (unwind-protect
        (with-current-buffer buffer
          (cooked-mode)
          (setq cooked--rows 4 cooked--cols 20 cooked--last-size '(4 . 20)
                cooked-rejoin-wrapped-lines nil)
          (cooked--start '("/bin/sh" "-c"
                           "printf 'AAAAAAAAAABBBBBBBBBBCCCCCCCCCCDDDDDDDDDDEEEEEEEEEEFFFFFFFFFF\\n'; \
                            printf 'tail\\n'; printf 'x\\n'; printf 'y\\n'; sleep 5"))
          (cooked--refresh-keymap)
          (should (cooked-tests--settle
                   (lambda () (string-match-p "FFFFFFFFFF" (cooked-tests--text)))))
          ;; The literal terminal view: one buffer line per screen row.
          (goto-char (point-min))
          (should (looking-at-p "AAAAAAAAAABBBBBBBBBB$")))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer))))

(ert-deftest cooked-transcript-navigation-works-in-both-states ()
  "Jumping between commands sends nothing to the child, so a running program
must not take the binding away."
  (dolist (map (list cooked-input-map cooked-raw-map))
    (should (eq (lookup-key map (kbd "C-c C-p")) #'cooked-previous-command))
    (should (eq (lookup-key map (kbd "C-c C-n")) #'cooked-next-command))
    (should (eq (lookup-key map (kbd "C-c TAB")) #'cooked-toggle-fold))))

(ert-deftest cooked-previous-command-lands-on-command-starts ()
  (skip-unless (executable-find "zsh"))
  (let ((buffer (generate-new-buffer "*cooked-nav*")))
    (unwind-protect
        (with-current-buffer buffer
          (cooked-mode)
          (pcase-let ((`(,argv ,env ,_scratch) (cooked--shell-invocation (executable-find "zsh"))))
            (cooked--start argv nil env))
          (cooked--refresh-keymap)
          (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input))))
          ;; Settle on the record appearing, not on the text.  Waiting for
          ;; "first-marker" matched the *echo* of the line being typed, so the second
          ;; command went out before the first had a record — the assertion below then
          ;; failed roughly two runs in five.
          (dolist (line '("echo first-marker" "echo second-marker"))
            (let ((before (length cooked--commands)))
              (cooked--replace-input line)
              (cooked-send-input)
              (should (cooked-tests--settle
                       (lambda () (> (length cooked--commands) before))))))
          (should (= (length cooked--commands) 2))
          ;; From the end, stepping back reaches the newest command's output.
          (goto-char (point-max))
          (cooked-previous-command)
          (let ((newest (marker-position (plist-get (car cooked--commands) :start))))
            (should (= (point) newest))))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer))))

(ert-deftest cooked-box-drawing-gets-a-display-property ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\342\\224\\214\\342\\224\\200\\342\\224\\220\\n'") ; ┌─┐
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'display))))))

(ert-deftest cooked-box-drawing-images-disabled-falls-back-to-plain-text ()
  (let ((cooked-box-drawing-images nil))
    (cooked-tests--with-session
        '("/bin/sh" "-c" "printf '\\342\\224\\214\\342\\224\\200\\342\\224\\220\\n'") ; ┌─┐
      (should (cooked-tests--settle
               (lambda () (string-match-p "┌" (cooked-tests--text)))))
      (should-not (get-text-property (point-min) 'display)))))

(ert-deftest cooked-box-drawing-rescales-on-zoom ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\342\\224\\214\\342\\224\\200\\342\\224\\220\\n'") ; ┌─┐
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'display))))
    ;; Zoom regenerates the image in place, purely from the `cooked-box-glyph'
    ;; property already in the buffer — no round-trip to the native core, so this
    ;; holds regardless of whether batch Emacs' font backend reports a different
    ;; pixel size than the one it started with.
    (let ((before (get-text-property (point-min) 'display)))
      (text-scale-increase 1)
      (should-not (eq before (get-text-property (point-min) 'display))))))

(provide 'cooked-tests)
;;; cooked-tests.el ends here
