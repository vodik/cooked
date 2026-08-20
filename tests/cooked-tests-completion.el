;;; cooked-tests-completion.el --- Completing at a prompt, in Emacs and in zsh -*- lexical-binding: t; -*-

;;; Commentary:

;; Both backends: the native table, and the round trip that asks the child's own
;; completion system over OSC 51;C.  The shell half is mostly driven by a stub
;; that answers on demand, so the protocol can be tested without zsh's timing.

;;; Code:

(require 'cooked-tests-helpers)

(ert-deftest cooked-completion-offers-programs-then-files ()
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'ready$ '; exec cat")
    (should (cooked-tests--settle
             (lambda () (and (string-match-p "ready" (cooked-tests--text))
                             (cooked--input-start-position)))))
    ;; First word: programs on PATH.
    (goto-char cooked--input-end)
    (insert "ls")
    (pcase-let ((`(,start ,end ,table . ,_) (cooked-completion-at-point)))
      (should (= start (cooked--input-start-position)))
      (should (= end (point)))
      (should (member "ls" (all-completions "ls" table))))
    ;; Later words complete as file names, relative to the child's directory.
    (insert " REA")
    (pcase-let ((`(,start ,end ,table . ,_) (cooked-completion-at-point)))
      (should (> start (cooked--input-start-position)))
      (should (= end (point)))
      (let ((default-directory (file-name-directory
                                (directory-file-name cooked--source-directory))))
        (should (member "README.md" (all-completions "REA" table)))))))

(ert-deftest cooked-completion-reply-becomes-candidates ()
  "The shell's answer, decoded: candidates, their descriptions, their groups."
  (with-temp-buffer
    (cooked--completion-handle
     (cooked-tests--completion-reply
      3 4 '(("checkout" "checkout   -- switch branches" "%B%F{cyan}>> command%f%b")
            ("check-attr" "check-attr -- gitattributes" "-default-"))))
    (pcase-let ((`(,serial ,prefix ,_suffix ,truncated . ,records)
                 cooked--completion-reply))
      (should-not truncated)
      (should (= serial 3))
      (should (= prefix 4))
      (pcase-let ((`(,matches ,annotate ,group)
                   (cooked--shell-completion-table records)))
        (should (equal matches '("checkout" "check-attr")))
        (should (equal (funcall annotate "checkout") " switch branches"))
        ;; The heading is what compsys would have printed, prompt escapes and all.
        (should (equal (funcall group "checkout" nil) "command"))
        ;; zsh's name for "no group": a heading of "-default-" is worse than none.
        (should-not (funcall group "check-attr" nil))))))

(ert-deftest cooked-completion-keeps-the-annotated-half-of-a-duplicate ()
  "zsh offers a branch under both `heads' and `commits'; only one is worth showing."
  (with-temp-buffer
    (cooked--completion-handle
     (cooked-tests--completion-reply
      1 2 '(("main" "main" "-default-")
            ("main" "main -- [76165fd] the tip" "branch"))))
    (pcase-let* ((`(,_serial ,_prefix ,_suffix ,_truncated . ,records)
                  cooked--completion-reply)
                 (`(,matches ,annotate ,_group) (cooked--shell-completion-table records)))
      (should (equal matches '("main")))
      (should (equal (funcall annotate "main") " [76165fd] the tip")))))

(ert-deftest cooked-completion-filters-a-complete-answer-in-emacs ()
  "A list the shell sent whole needs no second query as the word grows."
  (cooked-tests--with-stub-shell
      '(("git chec" . (4 0 nil ("checkout" "" "") ("check-attr" "" ""))))
      queries
    (let* ((table (cooked--completion-dynamic
                   "git " "" (make-hash-table :test #'equal) (make-hash-table :test #'equal)
                   '("chec" nil ("checkout" "" "") ("check-attr" "" ""))))
           (grown (all-completions "checko" table)))
      (should (equal grown '("checkout")))
      (should (= queries 0)))))

(ert-deftest cooked-completion-asks-again-when-the-answer-was-truncated ()
  "The reported bug: `pacman' is past the cap at `p', and no filtering finds it."
  (cooked-tests--with-stub-shell
      '(("pacman" . (6 0 nil ("pacman" "" "") ("pacman-key" "" ""))))
      queries
    (let ((table (cooked--completion-dynamic
                  "" "" (make-hash-table :test #'equal) (make-hash-table :test #'equal)
                  ;; What the shell sent for `p': cut off before `pacman'.
                  '("p" t ("pacman-key" "" "")))))
      (should (equal (all-completions "pacman" table) '("pacman" "pacman-key")))
      (should (= queries 1)))))

(ert-deftest cooked-completion-asks-again-when-the-completion-changed-kind ()
  "`git checkout ' offers branches; a `-' makes it flags, which no branch matches."
  (cooked-tests--with-stub-shell
      '(("git checkout -" . (1 0 nil ("--track" "" "") ("--detach" "" ""))))
      queries
    (let ((table (cooked--completion-dynamic
                  "git checkout " "" (make-hash-table :test #'equal)
                  (make-hash-table :test #'equal)
                  '("" nil ("main" "" "") ("cache" "" "")))))
      (should (equal (all-completions "-" table) '("--track" "--detach")))
      (should (= queries 1)))))

(ert-deftest cooked-completion-keeps-the-last-answer-when-a-query-fails ()
  "A completer past the timeout must not empty the popup under the user."
  (cooked-tests--with-stub-shell '() queries
    (let ((table (cooked--completion-dynamic
                  "" "" (make-hash-table :test #'equal) (make-hash-table :test #'equal)
                  '("p" t ("pacman-key" "" "")))))
      (should (equal (all-completions "pacman-k" table) '("pacman-key")))
      (should (= queries 1)))))

(ert-deftest cooked-completion-drops-a-reply-to-a-request-it-did-not-make ()
  "A completer slower than the timeout answers eventually; by then it is stale."
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle #'cooked--input-start-position))
    (setq cooked--completion-nonce "1234" cooked--completion-serial 6)
    (let ((cooked-completion-timeout 0.05))
      ;; The reply that lands is for the previous request, not this one.
      (cooked--completion-handle (cooked-tests--completion-reply 6 0 '(("stale" "" ""))))
      (should-not (cooked--shell-completions "wha" 3)))))

(ert-deftest cooked-completion-asks-nobody-without-an-announcement ()
  "The trigger is only a keystroke: to a shell with no widget bound to it, the
request is a line of input.  Nothing is sent until the shell says it is listening."
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle #'cooked--input-start-position))
    (should-not cooked--completion-nonce)
    (should-not (cooked--shell-completions "git chec" 8))
    ;; And the CAPF still completes, in Emacs.
    (goto-char cooked--input-end)
    (insert "ls")
    (pcase-let ((`(,_start ,_end ,table . ,_) (cooked-completion-at-point)))
      (should (member "ls" (all-completions "ls" table))))))

(ert-deftest cooked-completion-forgets-the-nonce-when-the-shell-runs-something ()
  "Once a command is running, those bytes would land in it rather than in ZLE."
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle #'cooked--input-start-position))
    (setq cooked--completion-nonce "abcd")
    (cooked--handle-semantic '(command-start (screen 0 . 0)) nil)
    (should-not cooked--completion-nonce)
    (should-not (cooked--shell-completions "git chec" 8))))

(ert-deftest cooked-completion-comes-from-zsh-itself ()
  "The whole exchange against a real shell: zsh's own completion system, run in
the shell you are typing at, over a line it has never seen."
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-fake-zdotdir
      '((".zshrc" . "autoload -Uz compinit\ncompinit -u -d $ZDOTDIR/zcompdump\nPS1='%% '\n"))
    (let ((buffer (generate-new-buffer "*cooked-complete*"))
          (root (file-name-directory (directory-file-name cooked--source-directory))))
      (unwind-protect
          (with-current-buffer buffer
            (cooked-mode)
            (pcase-let ((`(,argv ,env ,scratch)
                         (cooked--shell-invocation (executable-find "zsh"))))
              (setq cooked--scratch scratch)
              (cooked--start argv root env))
            (cooked--refresh-keymap)
            ;; The nonce is the shell saying its widget is bound and ZLE is reading.
            (should (cooked-tests--settle
                     (lambda () (and (cooked--input-start-position) cooked--completion-nonce))))
            (goto-char cooked--input-end)
            (insert "cd shell-int")
            (let ((before (cooked-tests--text))
                  (cooked-completion-timeout 5))
              (cooked-completion-at-point)
              ;; The line briefly lives in ZLE, which redraws from it when the widget
              ;; returns.  Putting it back byte for byte is what keeps that redraw a
              ;; no-op; anything else shows up here as the screen having changed.
              (cooked-tests--settle (lambda () nil) 0.3)
              (should (equal (cooked-tests--text) before)))
            (let ((cooked-completion-timeout 5))
              (pcase-let ((`(,start ,end ,table . ,_) (cooked-completion-at-point)))
                ;; Only the word is replaced, and only the directory is offered.
                ;; Emacs would have offered the files too: knowing that `cd' takes a
                ;; directory is the shell's knowledge, not ours.
                (should (equal (buffer-substring-no-properties start end) "shell-int"))
                (should (equal (all-completions "shell-int" table) '("shell-integration")))))
            ;; A path is completed against its own directory, and the candidate comes
            ;; back carrying the components compsys walked past to reach it.
            (delete-region (cooked--input-start-position) (point))
            (insert "cat shell-integration/cooked.z")
            (let ((cooked-completion-timeout 5))
              (pcase-let ((`(,start ,end ,table . ,_) (cooked-completion-at-point)))
                (should (equal (buffer-substring-no-properties start end)
                               "shell-integration/cooked.z"))
                (should (equal (all-completions "shell-integration/cooked.z" table)
                               '("shell-integration/cooked.zsh")))))
            ;; The table is asked again for each word typed into it, rather than
            ;; filtered in Emacs.  Nothing else can pass this: the first answer is a
            ;; list of file names, and no amount of filtering turns that into flags.
            (let ((cooked-completion-timeout 5))
              (delete-region (cooked--input-start-position) (point))
              (insert "ls ")
              (pcase-let ((`(,_start ,_end ,table . ,_) (cooked-completion-at-point)))
                (should (member "README.md" (all-completions "" table)))
                (should (equal (all-completions "--colo" table) '("--color"))))))
        (with-current-buffer buffer (cooked--cleanup))
        (kill-buffer buffer)))))

(ert-deftest cooked-completion-is-a-normal-capf ()
  "So corfu, cape and friends work without knowing about cooked."
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle #'cooked--input-start-position))
    (should (memq #'cooked-completion-at-point completion-at-point-functions))
    (should (eq (lookup-key cooked-input-map (kbd "TAB")) #'completion-at-point))))

(ert-deftest cooked-completion-declines-outside-the-input-line ()
  "Raw-mode programs get their own TAB; we must not complete over them."
  (cooked-tests--with-session '("/bin/sh" "-c" "stty -icanon -echo; sleep 5")
    (should (cooked-tests--settle (lambda () (eq cooked--mode 'raw))))
    (should-not (cooked-completion-at-point))))

(provide 'cooked-tests-completion)
;;; cooked-tests-completion.el ends here
