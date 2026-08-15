;;; cooked-tests-session.el --- Starting, sizing and ending a session -*- lexical-binding: t; -*-

;;; Commentary:

;; The lifecycle: loading the native core, spawning a child, injecting shell
;; integration without trampling the user's own configuration, terminfo, window
;; sizing, and what happens to the buffer when the child exits.

;;; Code:

(require 'cooked-tests-helpers)

(ert-deftest cooked-module-loads-and-defines-its-api ()
  (cooked--load-module)
  (should (featurep 'cooked-core))
  (dolist (fn '(cooked--spawn cooked--drain cooked--send cooked--resize cooked--redraw))
    (should (fboundp fn))))

(ert-deftest cooked-signal-refuses-a-number-that-is-not-one ()
  "Regression: a signal number wider than an int used to wrap into a real signal.

The number arrives as a Lisp integer, which is wider than the `int\=' a signal
is, and the conversion used to be a cast.  4294967305 truncates to 9, so asking
for a signal that does not exist killed the child outright -- the one number in
range where getting it wrong is unrecoverable.  It is rejected now, and the
child is still there afterwards to prove it."
  (cooked-tests--with-session (list "/bin/sh")
    (should (cooked-tests--settle (lambda () (cooked--live-p cooked--session))))
    (dolist (n (list 9999 4294967305 99999999999 -1))
      (should-error (cooked--signal cooked--session n) :type (quote args-out-of-range)))
    (should (cooked--live-p cooked--session))
    ;; A real one still gets through, so the check is not simply refusing everything.
    (should-not (cooked--signal cooked--session 2))))

(ert-deftest cooked-entry-points-autoload-from-the-main-file ()
  "Regression: `M-x cooked' from a `:load-path' install.

`package.el' and `use-package's `:commands' both autoload `cooked' from
\"cooked\", so the command has to be reachable by loading cooked.el and nothing
else.  It lived in cooked-mode.el, which cooked.el does not require, and an
autoload cookie there does not help: an autoload that forwards to a second file
is not followed, it is signalled.

Run in a fresh Emacs, because in this one the whole suite is already loaded and
there is no autoload left to resolve."
  (let ((lisp (expand-file-name "lisp" (cooked--root))))
    (dolist (command '(cooked cooked-other-window))
      (should
       (eq 0 (call-process
              (expand-file-name invocation-name invocation-directory)
              nil nil nil "-Q" "--batch" "-L" lisp
              "--eval" (prin1-to-string
                        `(progn (autoload ',command "cooked" nil t)
                                (unless (commandp ',command) (kill-emacs 1))
                                (call-interactively ',command)
                                (unless cooked--session (kill-emacs 1))
                                (cooked--cleanup)))))))))

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

(ert-deftest cooked-exit-status-is-reported ()
  (cooked-tests--with-session '("/bin/sh" "-c" "exit 9")
    (should (cooked-tests--settle
             (lambda () (string-match-p "\\[exited 9\\]" (cooked-tests--text)))))))

(ert-deftest cooked-buffer-is-kept-on-exit-by-default ()
  (should-not (cooked-tests--run-until-dead '("/bin/sh" "-c" "exit 0") 1)))

(ert-deftest cooked-buffer-can-close-itself-on-exit ()
  (let ((cooked-kill-buffer-on-exit t))
    (should (cooked-tests--run-until-dead '("/bin/sh" "-c" "exit 3") 5))))

(ert-deftest cooked-buffer-can-close-itself-only-on-success ()
  (let ((cooked-kill-buffer-on-exit 'on-success))
    (should (cooked-tests--run-until-dead '("/bin/sh" "-c" "exit 0") 5))
    (should-not (cooked-tests--run-until-dead '("/bin/sh" "-c" "exit 3") 1))))

(ert-deftest cooked-buffer-close-can-be-decided-by-a-function ()
  (let ((cooked-kill-buffer-on-exit (lambda (code) (eql code 7))))
    (should (cooked-tests--run-until-dead '("/bin/sh" "-c" "exit 7") 5))
    (should-not (cooked-tests--run-until-dead '("/bin/sh" "-c" "exit 8") 1))))

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

(ert-deftest cooked-text-scale-change-triggers-a-resize ()
  "`text-scale-increase' rescales the font without resizing any window, so
`window-configuration-change-hook' and `window-size-change-functions' both
stay silent -- `text-scale-mode-hook' is the one that has to pick it up."
  (cooked-tests--with-session '("/bin/sh" "-c" "while true; do sleep 0.1; done")
    (should (cooked-tests--settle (lambda () cooked--session)))
    (set-window-buffer (selected-window) (current-buffer))
    (setq cooked--last-size nil)
    (unwind-protect
        (progn
          (text-scale-increase 1)
          (should cooked--last-size)
          (should (= (car cooked--last-size)
                     (cooked--window-rows (get-buffer-window (current-buffer)))))
          (should (= (cdr cooked--last-size)
                     (window-max-chars-per-line (get-buffer-window (current-buffer))))))
      (text-scale-set 0))))

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

(ert-deftest cooked-presents-itself-as-term-program ()
  "The child is told who is driving the pty, and told it accurately."
  (let ((env (cooked--child-environment)))
    (should (equal (cdr (assoc "TERM_PROGRAM" env)) "cooked"))
    (should (equal (cdr (assoc "TERM_PROGRAM_VERSION" env)) (cooked-version))))
  ;; A value from the terminal that started Emacs must not shadow ours: programs
  ;; branch on it, and would take a path for a terminal not driving this pty.
  (let* ((process-environment (append '("TERM_PROGRAM=iTerm.app"
                                        "TERM_PROGRAM_VERSION=3.5.0")
                                      process-environment))
         (env (cooked--child-environment)))
    (should (equal (cdr (assoc "TERM_PROGRAM" env)) "cooked"))
    (should (equal (cdr (assoc "TERM_PROGRAM_VERSION" env)) (cooked-version)))
    (should-not (rassoc "iTerm.app" env))
    (should-not (rassoc "3.5.0" env))))

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

(ert-deftest cooked-live-buffers-finds-running-sessions ()
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (should (memq (current-buffer) (cooked--live-buffers)))))

(ert-deftest cooked-mx-cooked-takes-over-the-selected-window ()
  "`cooked-display-action' puts `display-buffer-same-window' first, the way
`vterm' and `eat' do it: a terminal is what \\[cooked] was asked for, so it
replaces whatever the selected window showed rather than opening beside it.
Regression target for the default `display-buffer' action -- reuse a window
elsewhere, else split -- which would have left the window the user was
looking at untouched and put the session somewhere off to the side instead."
  (let ((other (generate-new-buffer "*cooked-tests-other*"))
        (cooked-shell "/bin/sh")
        buffer)
    (unwind-protect
        (progn
          (delete-other-windows)
          (set-window-buffer (selected-window) other)
          (setq buffer (cooked t))
          (should (eq buffer (window-buffer (selected-window))))
          (should (= 1 (length (window-list)))))
      (when buffer
        (with-current-buffer buffer (cooked--cleanup))
        (kill-buffer buffer))
      (kill-buffer other))))

(ert-deftest cooked-other-window-keeps-the-selected-window-as-it-was ()
  "The one place `cooked-display-action' is deliberately not consulted: asking
for another window has to mean another window, so this passes its own action
-- `display-buffer-pop-up-window' alone, with no same-window entry ahead of it
-- rather than reuse of the selected window winning by default."
  (let ((other (generate-new-buffer "*cooked-tests-other*"))
        (cooked-shell "/bin/sh")
        buffer)
    (unwind-protect
        (progn
          (delete-other-windows)
          (set-window-buffer (selected-window) other)
          (let ((before (selected-window)))
            (setq buffer (cooked-other-window t))
            ;; A new window was opened for it rather than the old one reused.
            (should (> (length (window-list)) 1))
            (should (eq (window-buffer before) other))
            (should-not (eq (window-buffer (selected-window)) other))
            (should (eq (window-buffer (selected-window)) buffer))))
      (when buffer
        (with-current-buffer buffer (cooked--cleanup))
        (kill-buffer buffer))
      (kill-buffer other))))

(ert-deftest cooked-falls-back-to-a-split-when-the-selected-window-is-dedicated ()
  "`display-buffer-same-window' refuses a dedicated window outright, and
`cooked-display-action' lists `display-buffer-pop-up-window' right after it for
exactly that refusal -- a session started from a dedicated window (a side
window, or one the user pinned) must still land somewhere rather than
`pop-to-buffer' running out of action functions and erroring."
  (let ((other (generate-new-buffer "*cooked-tests-other*"))
        (cooked-shell "/bin/sh")
        buffer)
    (unwind-protect
        (progn
          (delete-other-windows)
          (set-window-buffer (selected-window) other)
          (set-window-dedicated-p (selected-window) t)
          (let ((before (selected-window)))
            (unwind-protect
                (progn
                  (setq buffer (cooked t))
                  (should (> (length (window-list)) 1))
                  ;; The dedicated window was left alone, still dedicated and
                  ;; still showing what it showed.
                  (should (window-dedicated-p before))
                  (should (eq (window-buffer before) other))
                  (should (eq (window-buffer (selected-window)) buffer)))
              (set-window-dedicated-p before nil))))
      (when buffer
        (with-current-buffer buffer (cooked--cleanup))
        (kill-buffer buffer))
      (kill-buffer other))))

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

(provide 'cooked-tests-session)
;;; cooked-tests-session.el ends here
