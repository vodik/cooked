;;; cooked-tests-completion.el --- Completing at a prompt, in Emacs and in zsh -*- lexical-binding: t; -*-

;;; Commentary:

;; Both tables: the native one that ships loaded, and the round trip that asks the
;; child's own completion system over OSC 51;C.  The shell half is mostly driven by
;; a stub that answers on demand, so the protocol can be tested without zsh's
;; timing.
;;
;; `cooked-shell-completion' is required here, so most of this file runs with the
;; layer loaded -- which is how the layer gets tested at all.  The tests for the
;; *unloaded* state bind the three seams back to nil rather than arranging a second
;; Emacs, for the same reason `cooked-osc-51-is-closed-until-opted-in' binds
;; `cooked-osc-eval-function': the variables are not a proxy for the layer being
;; absent, they are the entire mechanism by which the core notices it.

;;; Code:

(require 'cooked-tests-helpers)
(require 'cooked-shell-completion)

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
    ;; Through a real announcement, so the shell is reply-capable: setting the nonce
    ;; alone left `cooked--shell-completions' failing its guard a clause early, and
    ;; nothing downstream of it -- including the serial comparison this test is about --
    ;; ever ran.
    (cooked--osc-emacs '("CH;2;1234;1"))
    ;; And ZLE has to be the thing reading, or the request stops at that clause instead
    ;; and the wait below never runs.  A bare `cat' sends no OSC 133, so `cooked--semantic'
    ;; is nil here until it is told otherwise.
    (cooked--handle-semantic '(prompt-end (screen 0 . 0)) nil)
    (should (eq cooked--semantic 'input))
    (let ((cooked-completion-timeout 0.05))
      ;; Injected as the request goes out rather than before it.  A reply seeded ahead of
      ;; the call was cleared by `cooked--shell-completions' on entry, so the serial was
      ;; never compared against anything; the stale answer has to be standing while the
      ;; wait is running, which is also what actually happens to a slow completer.
      (cl-letf (((symbol-function 'cooked--send-if-live)
                 (lambda (&rest _)
                   (cooked--completion-handle
                    (cooked-tests--completion-reply
                     (1- cooked--completion-serial) 0 '(("stale" "" "")))))))
        (should-not (cooked--shell-completions "wha" 3))))))

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

(ert-deftest cooked-completion-asks-nothing-once-the-shell-runs-something ()
  "Once a command is running, those bytes would land in it rather than in ZLE.

The core forgets the nonce at `command-start\=' -- `cooked-completion-nonce-does-not-outlive-its-prompt\='
covers that -- so this is the second of the two guards rather than the only one:
the question is asked again at the moment of sending, against a nonce that is
somehow still standing.  It is the sharper one.  With `zsh\=' running a canonical
reader like `cat\=', the termios mode is `cooked\=' and the policy stays `cooked\='
too, so nothing about keyboard ownership notices that ZLE has stopped reading.

The announcement is therefore replayed *after* the command starts, which is the
only way to reach that guard now: an announcement made before it is cleared by
it, and the request then stops for the missing nonce without ever asking the
question this test is named for."
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle #'cooked--input-start-position))
    (cooked--handle-semantic '(command-start (screen 0 . 0)) nil)
    (should (eq cooked--semantic 'output))
    (cooked--osc-emacs '("CH;2;abcd;1"))
    (should (equal cooked--completion-nonce "abcd"))
    ;; Ownership has *not* changed, which is the case this covers.
    (should (cooked--input-state-p))
    (let (sent)
      (cl-letf (((symbol-function 'cooked--send-if-live)
                 (lambda (&rest _) (setq sent t))))
        (should-not (cooked--shell-completions "git chec" 8))
        (should-not sent)))))

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

(ert-deftest cooked-completion-mid-line-replaces-the-word-under-the-cursor ()
  "The span is anchored at the cursor the request was *sent* from.

zsh measures PREFIX against the cursor position it was handed, and the answer
comes back through a drain -- which lifts the pending input out of the buffer
and rebuilds it.  Reading point again afterwards therefore gives the right
length against the wrong anchor: a span reaching PREFIX characters back from
wherever the drain left point, which is why the report described it as
sometimes the next chunk and sometimes the whole prompt.  Here there is a word
after the cursor to make the difference visible."
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
            (should (cooked-tests--settle
                     (lambda () (and (cooked--input-start-position)
                                     cooked--completion-nonce))))
            (goto-char cooked--input-end)
            (insert "cat shell-int README.md")
            ;; Back onto the end of `shell-int', leaving ` README.md' after point.
            (goto-char (- (point) (length " README.md")))
            (let ((here (point))
                  (cooked-completion-timeout 5))
              (pcase-let ((`(,start ,end ,table . ,_) (cooked-completion-at-point)))
                ;; Point is where the request was issued from, not at the end of
                ;; the line the drain rebuilt.
                (should (= (point) here))
                (should (= end here))
                (should (equal (buffer-substring-no-properties start end) "shell-int"))
                (should (equal (all-completions "shell-int" table)
                               '("shell-integration")))))
            ;; And the rest of the line is untouched by any of it.
            (should (equal (cooked--pending-input) "cat shell-int README.md")))
        (with-current-buffer buffer (cooked--cleanup))
        (kill-buffer buffer)))))

(ert-deftest cooked-completion-comes-from-bash-itself ()
  "The same exchange against bash, over the same wire.

bash needs none of zsh\='s ZLE gymnastics -- `complete -p\=' names the registered
function and it can be invoked directly -- so the whole capture is bookkeeping.
What is worth testing is that it is the *same* bookkeeping: one Emacs-side
parser, one protocol, and a shell that announces for itself.

The spec here is registered by the test rather than borrowed from
bash-completion, which is not installed everywhere and would make this a test of
somebody else\='s package."
  (skip-unless (executable-find "bash"))
  (skip-unless (executable-find "base64"))
  (let ((buffer (generate-new-buffer "*cooked-bash-complete*"))
        (home (make-temp-file "cooked-bash-home-" t)))
    (with-temp-file (expand-file-name ".bashrc" home)
      (insert "PS1='$ '\n"
              "_mytool() { COMPREPLY=( $(compgen -W \"alpha beta gamma\" -- \"$2\") ); }\n"
              "complete -F _mytool mytool\n"))
    (unwind-protect
        (with-current-buffer buffer
          (cooked-mode)
          ;; The real HOME is *removed* rather than shadowed by a second entry:
          ;; which of two entries for one name reaches the child is not a thing to
          ;; depend on, and getting it wrong here means the shell reads the
          ;; developer's own .bashrc and completes against whatever that defines.
          ;; `default-directory' moves with it, since it is stored abbreviated and a
          ;; `~/...' would otherwise resolve against the fake home.
          (let ((default-directory (file-name-as-directory home))
                (process-environment
                 (cons (concat "HOME=" home)
                       (seq-remove (lambda (entry) (string-prefix-p "HOME=" entry))
                                   process-environment))))
            (pcase-let ((`(,argv ,env ,scratch)
                         (cooked--shell-invocation (executable-find "bash"))))
              (setq cooked--scratch scratch)
              ;; An explicit directory: HOME is redirected for this shell, and a
              ;; `default-directory' that abbreviates to ~ would resolve against the
              ;; fake one.
              (cooked--start argv home env)))
          (cooked--refresh-keymap)
          ;; The announcement is the shell saying a line editor is reading and that
          ;; this one can also answer.
          (should (cooked-tests--settle
                   (lambda () (and (cooked--input-start-position)
                                   cooked--completion-nonce
                                   cooked--completion-reply-capable))
                   10))
          (let ((cooked-completion-timeout 5))
            (pcase-let ((`(,prefix ,_suffix ,_truncated . ,records)
                         (cooked--shell-completions "mytool a" 8)))
              ;; Only the word being completed is replaced.
              (should (= prefix 1))
              (should (equal (mapcar #'car records) '("alpha")))))
          (let ((cooked-completion-timeout 5))
            (pcase-let ((`(,prefix ,_suffix ,_truncated . ,records)
                         (cooked--shell-completions "mytool " 7)))
              (should (= prefix 0))
              (should (equal (mapcar #'car records) '("alpha" "beta" "gamma"))))))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer)
      (delete-directory home t))))

(ert-deftest cooked-completion-without-the-layer-stays-in-emacs ()
  "Unloaded, the layer is idle but the announcement is still heard.

The two halves come apart here.  A request is this layer\='s business, so with
both seams nil nothing leaves Emacs and the CAPF answers from its own table.
The *announcement* is not: `cooked--policy\=' reads it as a license to own the
input line, and a session that never loads this file needs that reading as much
as one that does -- so the nonce is kept regardless of who is listening for
replies."
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle #'cooked--input-start-position))
    (let ((cooked-osc-completion-function nil)
          (cooked-shell-completion-function nil)
          (sent nil))
      ;; Believed with no layer loaded: this is an ownership signal, not a
      ;; completion one.
      (cooked--osc-emacs '("CH;2;1234;1"))
      (should (equal cooked--completion-nonce "1234"))
      (should cooked--completion-reply-capable)
      ;; And the CAPF still answers from Emacs without sending anything.
      (cl-letf (((symbol-function 'cooked--send-if-live)
                 (lambda (&rest _) (setq sent t))))
        (goto-char cooked--input-end)
        (insert "ls")
        (pcase-let ((`(,start ,_end ,table . ,_) (cooked-completion-at-point)))
          (should (= start (cooked--input-start-position)))
          (should (member "ls" (all-completions "ls" table)))))
      (should-not sent))))

(ert-deftest cooked-completion-announcement-carries-a-reply-capability ()
  "Framing a reply needs `base64\='; owning the input line does not.

A shell without it announces anyway and says so in the last field, so it keeps
its editable line and merely has nothing to offer `completion-at-point\='.
Snippets predating the field could only announce when they could also reply, so
their silence reads as capable."
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle #'cooked--input-start-position))
    (cooked--osc-emacs '("CH;2;1234;1"))
    (should (equal cooked--completion-nonce "1234"))
    (should cooked--completion-reply-capable)
    (cooked--osc-emacs '("CH;2;5678;0"))
    (should (equal cooked--completion-nonce "5678"))
    (should-not cooked--completion-reply-capable)
    (cooked--osc-emacs '("CH;2;9012"))
    (should (equal cooked--completion-nonce "9012"))
    (should cooked--completion-reply-capable)
    ;; A version we do not speak is a shell failing to make a claim, and the safe
    ;; reading of no claim is no license.
    (cooked--osc-emacs '("CH;3;3456;1"))
    (should-not cooked--completion-nonce)))

(ert-deftest cooked-completion-nonce-does-not-outlive-its-prompt ()
  "`ssh host\=' must not leave the local shell\='s license standing.

The announcement is a claim about the line being read now.  Once a command
starts, whatever it spawns -- a remote shell, a nested `zsh -f\=', a REPL --
announces for itself or does not announce at all; inheriting the old nonce would
hand a bare remote prompt a license nothing on that host ever issued."
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle #'cooked--input-start-position))
    (cooked--osc-emacs '("CH;2;1234;1"))
    (should (equal cooked--completion-nonce "1234"))
    (cooked--handle-semantic '(command-start (screen 0 . 0)) nil)
    (should-not cooked--completion-nonce)
    (should-not cooked--completion-reply-capable)))

(ert-deftest cooked-completion-layer-decides-what-the-shell-is-told ()
  "The zsh capture cannot retract a `compadd' shadow, so whether to install one
is decided when the child starts, from whether the layer was loaded by then.

It used to travel as COOKED_COMPLETION in the environment.  That was only ever a
longer way of saying this: the startup file is written at spawn too, so writing
the `source' line or not makes the same decision at the same moment, with one
fewer variable to explain.  The core snippet is sourced either way -- it is what
the marks and the announcement come from, and neither is optional."
  (skip-unless (executable-find "zsh"))
  (dolist (loaded '(nil t))
    (let ((cooked-shell-completion-function
           (and loaded #'cooked--shell-completion-at-point)))
      (pcase-let ((`(,_argv ,_env ,scratch)
                   (cooked--shell-invocation (executable-find "zsh"))))
        (unwind-protect
            (let ((rc (with-temp-buffer
                        (insert-file-contents (expand-file-name ".zshrc" scratch))
                        (buffer-string))))
              (should (string-match-p "cooked\\.zsh" rc))
              (should (eq (and (string-match-p "cooked-completion\\.zsh" rc) t)
                          loaded)))
          (when scratch (delete-directory scratch t)))))))

(ert-deftest cooked-completion-that-lists-nothing-leaves-no-copy-of-the-line ()
  "A completer with nothing to offer used to paint the line onto the screen.

compsys refreshes the display itself on the way to a message or a beep, and the
line it draws is the one the capture put in BUFFER -- so a second copy of the
command appeared exactly where the completion would have gone, and restoring
BUFFER did not take it back.  `git commit -am <TAB>' is the everyday case: the
flags have already said everything, so `_git' offers nothing and explains why."
  (skip-unless (executable-find "zsh"))
  (skip-unless (executable-find "git"))
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
            (should (cooked-tests--settle
                     (lambda () (and (cooked--input-start-position) cooked--completion-nonce))))
            (goto-char cooked--input-end)
            (insert "git commit -am ")
            (let ((before (cooked-tests--text))
                  (cooked-completion-timeout 5))
              ;; An answer arrived and it is empty -- (PREFIX SUFFIX TRUNCATED),
              ;; with no records behind it -- which is the case this is about.
              (should-not (nthcdr 3 (cooked--shell-completions "git commit -am " 15)))
              ;; Asserted the moment the reply lands, not after the dust settles: the
              ;; repair travels ahead of the reply, so there is no drain that can see
              ;; the answer and still be showing the copy.
              (should (equal (cooked-tests--text) before))
              (cooked-tests--settle (lambda () nil) 0.3)
              (should (equal (cooked-tests--text) before))))
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
