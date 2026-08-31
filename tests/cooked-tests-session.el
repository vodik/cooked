;;; cooked-tests-session.el --- Starting, sizing and ending a session -*- lexical-binding: t; -*-

;;; Commentary:

;; The lifecycle: loading the native core, spawning a child, injecting shell
;; integration without trampling the user's own configuration, terminfo, window
;; sizing, and what happens to the buffer when the child exits.

;;; Code:

(require 'cooked-tests-helpers)

(ert-deftest cooked-snippet-does-nothing-outside-cooked ()
  "The snippet guards itself on TERM_PROGRAM, so a shared rc is safe.

Sourcing it is a line in the user\='s own configuration, which means it runs in
every shell they start -- under alacritty, under tmux, over an ssh from a laptop
that has never heard of cooked.  Defining hooks and appending to PS1 there would
be cooked following someone home.

The probe is `precmd_functions\=' rather than any single hook name because setup
is deferred to the first prompt: immediately after sourcing, the only thing
registered is the deferred initializer, and under another terminal there must be
nothing at all."
  (skip-unless (executable-find "zsh"))
  (let ((snippet (expand-file-name "cooked.zsh" (cooked--integration-directory))))
    (dolist (term '("xterm-kitty" "cooked"))
      (with-temp-buffer
        (call-process
         (executable-find "zsh") nil t nil "-f" "-i" "-c"
         (format "TERM_PROGRAM=%s source %s; print -r -- ${${(M)precmd_functions:#__cooked_*}:-none}"
                 term (shell-quote-argument snippet)))
        (should (equal (string-trim (buffer-string))
                       (if (equal term "cooked") "__cooked_deferred_init" "none")))))))

(ert-deftest cooked-core-snippet-announces-but-cannot-answer ()
  "The announcement is in the core and the capture is not, so the two fields of
`OSC 51;CH\=' come apart: the core alone claims a line editor is reading -- which
is what licenses the Emacs input region behind an ssh -- while saying it can
answer no requests.  Sourcing the capture is what turns the last field on."
  (skip-unless (executable-find "zsh"))
  (skip-unless (executable-find "base64"))
  (let* ((dir (cooked--integration-directory))
         (core (shell-quote-argument (expand-file-name "cooked.zsh" dir)))
         (capture (shell-quote-argument (expand-file-name "cooked-completion.zsh" dir))))
    (dolist (probe (list (cons (format "source %s" core) "0")
                         (cons (format "source %s; source %s" core capture) "1")))
      (with-temp-buffer
        (call-process (executable-find "zsh") nil t nil "-f" "-i" "-c"
                      (format "TERM_PROGRAM=cooked; %s; print -r -- $__cooked_complete_replies"
                              (car probe)))
        (should (equal (string-trim (buffer-string)) (cdr probe)))))))

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

(ert-deftest cooked-integration-features-reach-the-child-verbatim ()
  "The feature list is passed as a string the shell can append to.

Verbatim rather than re-encoded, and that is the whole mechanism: the shell
appends `no-NAME\=' to the value it was handed, so the vocabulary it answers in
has to be the one it received.  A normalized re-encoding would round-trip to
something the rc could not extend."
  (should (equal (cooked--integration-environment)
                 "marks input-mark cwd announce completion title"))
  ;; Ordered by the canonical list rather than by however the option was written,
  ;; so the value a shell sees is stable enough to quote in a bug report.
  (let ((cooked-shell-integration-features '(cwd marks)))
    (should (equal (cooked--integration-environment) "marks cwd")))
  (let ((cooked-shell-integration-features nil))
    (should (null (cooked--integration-environment)))))

(ert-deftest cooked-integration-scheme-is-detected-or-forced ()
  "`detect\=' matches the basename; naming a shell overrides the guess both ways."
  (should (eq (cooked--integration-shell "/bin/zsh") 'zsh))
  (should (eq (cooked--integration-shell "/usr/local/bin/bash") 'bash))
  ;; Unknown shells are left alone rather than guessed at.
  (should (null (cooked--integration-shell "/bin/nu")))
  (let ((cooked-shell-integration 'none))
    (should (null (cooked--integration-shell "/bin/zsh"))))
  (let ((cooked-shell-integration 'bash))
    (should (eq (cooked--integration-shell "/bin/whatever") 'bash)))
  ;; This option was a boolean before it was a choice, and a session that refuses
  ;; to start is a poor way to learn that a setting grew values.
  (let ((cooked-shell-integration t))
    (should (eq (cooked--integration-shell "/bin/zsh") 'zsh))))

(ert-deftest cooked-integration-features-travel-without-injection ()
  "Turning injection off does not turn the features off.

The two are separate questions -- whether cooked put the code there, and what it
does once it is there -- because the shells that most need the second are the
ones injection cannot reach.  A hand-sourced snippet in a nested shell reads the
same list as an injected one."
  (let ((cooked-shell-integration 'none))
    (pcase-let ((`(,argv ,env ,scratch) (cooked--shell-invocation "/bin/zsh")))
      (should (equal argv '("/bin/zsh")))
      (should (null scratch))
      (should (equal (cdr (assoc "COOKED_SHELL_INTEGRATION_FEATURES" env))
                     "marks input-mark cwd announce completion title")))))

(ert-deftest cooked-a-prompt-that-marks-itself-can-stand-cooked-down ()
  "An rc that already emits OSC 133 appends `no-marks\=' and keeps the rest.

This is the case with no good answer anywhere else: kitty documents the same
convention, Ghostty cannot express it, and nobody specifies what a terminal does
with two sets of marks for one prompt.  Here the shell settles it before any
duplicate reaches the wire -- and settling it must not cost the editable line,
which is the half a user standing the marks down still wants.

The snippet defers its own setup to the first prompt precisely so that the rc,
which runs earlier, has somewhere to stand."
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-fake-zdotdir
      '((".zshrc" . "PROMPT='$ '\nCOOKED_SHELL_INTEGRATION_FEATURES=\"${COOKED_SHELL_INTEGRATION_FEATURES-} no-marks\"\n"))
    (let ((buffer (generate-new-buffer "*cooked-no-marks*")))
      (unwind-protect
          (with-current-buffer buffer
            (cooked-mode)
            (pcase-let ((`(,argv ,env ,scratch)
                         (cooked--shell-invocation (executable-find "zsh"))))
              (setq cooked--scratch scratch)
              (cooked--start argv nil env))
            (cooked--refresh-keymap)
            ;; The `B\=' mark still arrives, so Emacs still owns the line.
            (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input))))
            ;; But no `A\=' ever did, so there is no prompt extent to report --
            ;; which is what the rc asked for by standing the marks down.
            (should (null cooked--prompt-start)))
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

(defun cooked-tests--bash-marks (rc &optional input)
  "Run bash over RC, feed it INPUT, and return the OSC 133 marks it wrote, in order.

Read off the raw byte stream rather than out of a cooked buffer, because what
these tests are about is what the *snippet* put on the wire: a mark emitted twice
is invisible in the buffer -- an OSC occupies no columns -- and reaches Emacs as a
second claim about the same prompt, which is exactly the kind of bug that hides
until something downstream quietly disagrees.

bash is the shell this matters most for.  It is the one the author does not use,
so it has no daily driver to notice a regression, and its hooks are the fragile
ones: PS1 holds the marks as backslash escapes rather than as bytes, and the
`C\=' mark rides in PS0, which is a prompt string like any other and so is lost
to anything that rebuilds it."
  (let ((marks nil))
    (with-temp-buffer
      (let ((process-environment (cons "TERM_PROGRAM=cooked" process-environment)))
        (insert (or input "true\nexit\n"))
        (call-process-region (point-min) (point-max) (executable-find "bash")
                             t t nil "--rcfile" rc "-i"))
      (goto-char (point-min))
      ;; The options are captured, not skipped past: `A;k=s' -- the continuation
      ;; prompt -- differs from a bare `A' in what it means rather than in detail, and
      ;; a regexp that read them as the same mark would report a construct's every
      ;; continuation line as a fresh prompt.
      (while (re-search-forward "\e]133;\\([A-D]\\)\\(;[^\a]*\\)?\a" nil t)
        (push (concat (match-string 1) (or (match-string 2) "")) marks)))
    (nreverse marks)))

(defun cooked-tests--bash-output (rc &optional input)
  "Run bash over RC, feed it INPUT, and return everything it wrote, verbatim.

The sibling of `cooked-tests--bash-marks\=' for the assertions that are about a
payload rather than about a mark -- the encoding of an OSC 7 path, the contents
of PROMPT_COMMAND -- and for the ones that are about what bash still has rather
than about what it printed, which it can only answer by being asked."
  (with-temp-buffer
    (let ((process-environment (cons "TERM_PROGRAM=cooked" process-environment)))
      (insert (or input "true\nexit\n"))
      (call-process-region (point-min) (point-max) (executable-find "bash")
                           t t nil "--rcfile" rc "-i"))
    (buffer-string)))

(defun cooked-tests--bash-rc (&rest lines)
  "Write a bash rc sourcing the core snippet after LINES, and return its name."
  (let ((rc (make-temp-file "cooked-tests-bashrc-")))
    (with-temp-file rc
      (insert "PS1='$ '\n"
              (mapconcat #'identity lines "\n")
              (if lines "\n" "")
              ". " (shell-quote-argument
                    (expand-file-name "cooked.bash" (cooked--integration-directory)))
              "\n"))
    rc))

(ert-deftest cooked-bash-marks-each-prompt-exactly-once ()
  "Regression: the prompt marks accumulated, one more pair per prompt.

`A\=' and `B\=' live in PS1, which holds them as the backslash escapes bash
expands when it draws the prompt -- not as bytes.  The guard against
re-appending tested for a real ESC, so it never matched, and by the tenth prompt
PS1 was mostly marks.  Nothing was visibly wrong: an OSC occupies no columns."
  (skip-unless (executable-find "bash"))
  (let ((rc (cooked-tests--bash-rc)))
    (unwind-protect
        (let ((marks (cooked-tests--bash-marks rc "true\ntrue\nexit\n")))
          ;; Three prompts, one A and one B each, and never two in a row.
          (should (= 3 (seq-count (lambda (m) (equal m "A")) marks)))
          (should (= 3 (seq-count (lambda (m) (equal m "B")) marks)))
          (should-not (seq-find (lambda (pair) (equal (car pair) (cdr pair)))
                                (seq-mapn #'cons marks (cdr marks)))))
      (delete-file rc))))

(ert-deftest cooked-bash-does-not-mark-its-own-prompt-as-a-command ()
  "Regression: every prompt emitted a stray `C\='.

A `C\=' says a command started, which is not merely untidy -- it clears the
announcement nonce, so the next completion request on that prompt arrives
unlicensed and is refused.

This used to be a DEBUG trap, which fires before every command including the
prompt\='s own, so it had to work out which ones the user typed; comparing against
PROMPT_COMMAND could not do it, because that holds several commands joined by
`;\=' while the trap sees one at a time.  The mark now rides in PS0, which bash
expands exactly once per command line it is about to run, so the question the
latch answered no longer gets asked.  The test stays because the property is the
same one either way, and it is the property rather than the mechanism that
Emacs depends on."
  (skip-unless (executable-find "bash"))
  (let ((rc (cooked-tests--bash-rc)))
    (unwind-protect
        (let ((marks (cooked-tests--bash-marks rc "true\nexit\n")))
          ;; A `C' only ever follows the `B' of the prompt the command was typed at.
          (should (seq-every-p (lambda (pair) (equal (car pair) "B"))
                               (seq-filter (lambda (pair) (equal (cdr pair) "C"))
                                           (seq-mapn #'cons marks (cdr marks)))))
          ;; And the first thing on the wire is a prompt, not a command.
          (should (equal (car marks) "A")))
      (delete-file rc))))

(ert-deftest cooked-bash-reports-command-exit-codes ()
  "The `D\=' mark carries the command\='s status, not the prompt hook\='s.

The zsh half of this is covered separately; bash gets its own because the way it
stays first differs -- a string prepended to PROMPT_COMMAND rather than a
reordered array -- and because a theme appending to PROMPT_COMMAND is the common
way to break it."
  (skip-unless (executable-find "bash"))
  (let ((rc (cooked-tests--bash-rc "__theme() { :; }"
                                   "PROMPT_COMMAND='__theme'")))
    (unwind-protect
        (let ((marks (cooked-tests--bash-marks rc "(exit 7)\nexit\n")))
          (should (member "D;7" marks)))
      (delete-file rc))))

(ert-deftest cooked-bash-marks-its-continuation-prompt ()
  "PS2 carries the marks too, or every line after the first of a multi-line
construct falls out of Emacs\=' hands back to readline.

`A;k=s\=' rather than a bare `A\=': the option is what says this prompt continues
the previous one, which is what keeps the command record filed under the prompt
the construct was typed at."
  (skip-unless (executable-find "bash"))
  (let ((rc (cooked-tests--bash-rc)))
    (unwind-protect
        (let ((marks (cooked-tests--bash-marks
                      rc "for x in 1 2; do\necho $x\ndone\nexit\n")))
          ;; Two continuation prompts -- after `do\=' and after `echo $x\=' -- and a
          ;; `B\=' for each, since the point is that Emacs keeps the line.
          (should (= 2 (seq-count (lambda (m) (equal m "A;k=s")) marks)))
          ;; Still one real prompt per command, not one per line typed.
          (should (= 2 (seq-count (lambda (m) (equal m "A")) marks))))
      (delete-file rc))))

(ert-deftest cooked-bash-gates-the-continuation-marks-like-zsh ()
  "The two shells have to answer the feature list the same way, and did not.

`PS2' is touched only under `input-mark\\=', because Emacs taking the continuation
line is the whole point of marking it; the `A;k=s\\=' inside that is the marks\\'
half.  Gating both halves on `input-mark\\=' alone emitted a continuation whose
prompt start was never announced -- a claim about a command Emacs has no record
of, which then latched a flag on the Emacs side that nothing could clear."
  (skip-unless (executable-find "bash"))
  (let ((rc (cooked-tests--bash-rc))
        (script "for x in 1 2; do\necho $x\ndone\nexit\n"))
    (unwind-protect
        (let ((all (let ((process-environment
                          (cons "COOKED_SHELL_INTEGRATION_FEATURES=marks input-mark cwd"
                                process-environment)))
                     (cooked-tests--bash-marks rc script)))
              (no-marks (let ((process-environment
                               (cons "COOKED_SHELL_INTEGRATION_FEATURES=input-mark cwd"
                                     process-environment)))
                          (cooked-tests--bash-marks rc script)))
              (no-input (let ((process-environment
                               (cons "COOKED_SHELL_INTEGRATION_FEATURES=marks cwd"
                                     process-environment)))
                          (cooked-tests--bash-marks rc script))))
          (should (= 2 (seq-count (lambda (m) (equal m "A;k=s")) all)))
          ;; Never a continuation without the marks that give it something to continue.
          (should-not (member "A;k=s" no-marks))
          (should-not (member "A" no-marks))
          ;; And nothing on PS2 at all when Emacs is not taking the line.
          (should-not (member "A;k=s" no-input))
          (should-not (member "B" no-input)))
      (delete-file rc))))

(ert-deftest cooked-bash-leaves-the-users-debug-trap-alone ()
  "Regression: loading cooked silently disabled bash-preexec.

The `C\=' mark used to come from a DEBUG trap, installed at the first prompt --
which is to say after everything else had run.  `trap ... DEBUG\=' replaces
whatever was there without a word, so the thing it replaced was, as often as not,
bash-preexec: every `preexec_functions\=' hook the user had went quiet, and
nothing anywhere said so.  The mark rides in PS0 now, which displaces nothing."
  (skip-unless (executable-find "bash"))
  (let ((rc (cooked-tests--bash-rc "__user_preexec() { :; }"
                                   "trap '__user_preexec' DEBUG")))
    (unwind-protect
        (let ((output (cooked-tests--bash-output rc "trap -p DEBUG\nexit\n")))
          (should (string-match-p "__user_preexec" output)))
      (delete-file rc))))

(ert-deftest cooked-bash-keeps-an-array-prompt-command ()
  "PROMPT_COMMAND has been an array since bash 5.1, and treating it as a string
there does not fail loudly.

`$PROMPT_COMMAND\=' reads element 0 only and assigning a string back writes
element 0 only, so the user\='s remaining entries survive -- and now run *after*
everything we appended, which under the old DEBUG trap meant the first of them
was reported as a command the user had typed and every prompt emitted a stray
`C\='.  Branch on the actual type, as kitty and Ghostty both do."
  (skip-unless (executable-find "bash"))
  (let ((rc (cooked-tests--bash-rc "PROMPT_COMMAND=(\"__first=1\" \"__second=1\")")))
    (unwind-protect
        (let ((output (cooked-tests--bash-output
                       rc "declare -p PROMPT_COMMAND __first __second\nexit\n"))
              (marks (cooked-tests--bash-marks rc "true\nexit\n")))
          ;; Still an array, with both of the user\'s entries and both of ours.
          (should (string-match-p "declare -a PROMPT_COMMAND" output))
          (should (string-match-p "__first=1" output))
          (should (string-match-p "__second=1" output))
          ;; Ours bracket theirs: the status half first, where `$?\' is still the
          ;; command\'s, and the prompt half last, after any theme rebuilt PS1.
          (should (string-match-p "\\[0\\]=\"__cooked_precmd\"" output))
          (should (string-match-p "\\[3\\]=\"__cooked_prompt_hook\"" output))
          ;; And the user\'s entries are not mistaken for typed commands.
          (should (= 2 (seq-count (lambda (m) (string-prefix-p "C" m)) marks))))
      (delete-file rc))))

(ert-deftest cooked-bash-reports-the-command-line-it-is-about-to-run ()
  "`cmdline_url=\=' on the `C\=' mark, which is the shell\='s own account of the
command and the only one Emacs has when the shell kept the line.

Percent-encoded rather than kitty\='s `cmdline=\=', which is `printf %q\=' output
and so is quoted in a way only that shell can undo."
  (skip-unless (executable-find "bash"))
  (let ((rc (cooked-tests--bash-rc)))
    (unwind-protect
        (let ((marks (cooked-tests--bash-marks rc "echo 'hi there'\nexit\n")))
          (should (member "C;cmdline_url=echo%20%27hi%20there%27" marks)))
      (delete-file rc))))

(ert-deftest cooked-bash-refuses-to-guess-at-a-command-line-it-was-not-told ()
  "`history 1\=' is the only way bash will tell a hook what was typed, and under
`HISTCONTROL=ignorespace\=' it is a liar: the line about to run was never
recorded, so it answers with the *previous* command.  kitty and Ghostty both
report that one as the command that is running.

The history number settles it -- what bash said the next command would be
numbered, taken at the prompt, against what the entry actually carries -- and
when they disagree the mark goes out bare.  Saying nothing is the only honest
answer, and it costs nothing: Emacs still has the text it submitted."
  (skip-unless (executable-find "bash"))
  (let ((rc (cooked-tests--bash-rc "HISTCONTROL=ignorespace")))
    (unwind-protect
        (let ((marks (cooked-tests--bash-marks
                      rc "echo recorded\n echo hidden\nexit\n")))
          (should (member "C;cmdline_url=echo%20recorded" marks))
          ;; Three commands ran -- the two above and the `exit\' -- so three `C\'
          ;; marks, and the hidden one is the bare one.  Above all there is no second
          ;; claim about `echo recorded\', which is what reporting a stale history
          ;; entry would have produced.
          (should (= 3 (seq-count (lambda (m) (string-prefix-p "C" m)) marks)))
          (should (= 1 (seq-count (lambda (m) (equal m "C")) marks)))
          (should (= 1 (seq-count (lambda (m) (equal m "C;cmdline_url=echo%20recorded"))
                                  marks))))
      (delete-file rc))))

(ert-deftest cooked-bash-survives-a-theme-that-rebuilds-the-prompt ()
  "A theme rebuilding PS1 from PROMPT_COMMAND must not cost the `B\=' mark, which
is the whole hand-the-keyboard-back feature."
  (skip-unless (executable-find "bash"))
  (let ((rc (cooked-tests--bash-rc "__theme() { PS1='theme$ '; }"
                                   "PROMPT_COMMAND='__theme'")))
    (unwind-protect
        (let ((marks (cooked-tests--bash-marks rc "true\ntrue\nexit\n")))
          (should (= 3 (seq-count (lambda (m) (equal m "B")) marks))))
      (delete-file rc))))

(ert-deftest cooked-fish-marks-its-prompts ()
  "The first fish coverage the suite has ever had: a fish session reaching input
state, recording commands with their exit codes, and tracking its directory.

On a stock fish 4 the marks under test are *fish\='s own* -- `cooked.fish\='
installs nothing there, by design.  That is the arrangement worth asserting,
because it is the one every fish user gets.  The snippet\='s own path is
`cooked-fish-supplies-the-marks-fish-declines-to-send\=', which has to force
fish to be quiet before there is anything of ours to see."
  (skip-unless (executable-find "fish"))
  (cooked-tests--with-fish
    ;; The `B' arrived and was believed: Emacs owns the line.
    (should (cooked--input-state-p))
    (cooked--replace-input "false")
    (cooked-send-input)
    (should (cooked-tests--settle (lambda () cooked--commands) 8))
    ;; `$status' really is the command's inside the postexec handler.
    (should (= (cooked-command-code (car cooked--commands)) 1))
    (cooked--replace-input "cd /tmp")
    (cooked-send-input)
    (should (cooked-tests--settle
             (lambda () (equal (expand-file-name default-directory) "/tmp/"))
             8))))

(ert-deftest cooked-fish-keeps-its-marks-when-the-prompt-is-redefined ()
  "The marks have to travel inside `fish_prompt\=', because the `fish_prompt\='
event fires *before* the function is called and so is no place to put the `B\='
that must follow the prompt text.

Wrapping it once at startup was not enough: anything that redefines
`fish_prompt\=' afterwards throws the wrapper away, and `fish_config\=' does
exactly that every time you change theme.  So the wrapper is re-applied at each
prompt, from the same reasoning that re-applies the PS1 marks in bash and zsh.
The test redefines the prompt mid-session and asks for the marks again."
  (skip-unless (executable-find "fish"))
  (skip-unless (executable-find "script"))
  (let* ((config (make-temp-file "cooked-tests-fish-" t))
         (input (make-temp-file "cooked-tests-fish-in-"))
         (marks nil))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "fish" config))
          (with-temp-file (expand-file-name "fish/config.fish" config)
            (insert "function fish_prompt; printf \'$ \'; end\n"
                    "source " (shell-quote-argument
                               (expand-file-name "cooked.fish"
                                                 (cooked--integration-directory)))
                    "\n"))
          (with-temp-file input
            (insert "function fish_prompt; printf \'NEW> \'; end\n" "false\n" "exit\n"))
          (with-temp-buffer
            (let ((process-environment
                   (append (list (concat "XDG_CONFIG_HOME=" config)
                                 "TERM_PROGRAM=cooked" "TERM=xterm-256color")
                           process-environment)))
              (call-process "script" input t nil "-qc"
                            "fish --features=no-mark-prompt -i" "/dev/null"))
            (goto-char (point-min))
            (while (re-search-forward "\e]133;\\([A-D]\\)\\(;[^\a]*\\)?\a" nil t)
              (push (concat (match-string 1) (or (match-string 2) "")) marks)))
          (setq marks (nreverse marks))
          ;; Three prompts -- the one the redefinition was typed at, the one `false\'
          ;; was typed at, and the one `exit\' was -- and the last two are drawn by a
          ;; `fish_prompt\' the snippet never saw at startup.
          (should (<= 3 (seq-count (lambda (m) (equal m "A")) marks)))
          (should (<= 3 (seq-count (lambda (m) (equal m "B")) marks)))
          ;; And the run really did get past the redefinition.
          (should (member "C;cmdline_url=false" marks))
          (should (member "D;1" marks)))
      (delete-directory config t)
      (delete-file input))))

(ert-deftest cooked-fish-supplies-the-marks-fish-declines-to-send ()
  "The snippet\\'s own path, which on a stock fish 4 never runs -- so without
forcing it, the fish tests assert fish\\'s marks and nothing of cooked\\'s.

`no-mark-prompt\\=' is fish\\'s own switch for a terminal that cannot parse the
sequences.  A fish told to be quiet leaves the job to us, and this is the whole
of what `cooked.fish\\=' then does: bracket the prompt, and carry the exit status
out of a `fish_postexec\\=' handler where `$status\\=' is the command\\'s.

Read off the wire rather than through a session, because what is under test is
which *emitter* spoke: a mark reaches Emacs the same way whoever sent it."
  (skip-unless (executable-find "fish"))
  (skip-unless (executable-find "script"))
  (let* ((config (make-temp-file "cooked-tests-fish-" t))
         (input (make-temp-file "cooked-tests-fish-in-"))
         (marks nil))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "fish" config))
          (with-temp-file (expand-file-name "fish/config.fish" config)
            (insert "function fish_prompt; printf '$ '; end\n"
                    "source " (shell-quote-argument
                               (expand-file-name "cooked.fish"
                                                 (cooked--integration-directory)))
                    "\n"))
          (with-temp-file input (insert "false\nexit\n"))
          (with-temp-buffer
            (let ((process-environment
                   (append (list (concat "XDG_CONFIG_HOME=" config)
                                 "TERM_PROGRAM=cooked" "TERM=xterm-256color")
                           process-environment)))
              ;; fish never runs its reader off a pipe, so this needs a pty even to
              ;; draw a prompt -- which is why it goes through `script' rather than
              ;; through `call-process' the way the bash equivalents do.  The input is
              ;; `script''s to forward onto the pty: piping it into fish *inside* the
              ;; `-c' would hand fish a pipe again and nothing would ever be drawn.
              (call-process "script" input t nil "-qc"
                            "fish --features=no-mark-prompt -i" "/dev/null"))
            (goto-char (point-min))
            (while (re-search-forward "\e]133;\\([A-D]\\)\\(;[^\a]*\\)?\a" nil t)
              (push (concat (match-string 1) (or (match-string 2) "")) marks)))
          (setq marks (nreverse marks))
          ;; Both emitters spell the prompt mark `A', so the discriminator is the
          ;; option beside it: fish writes `A;click_events=1' and cooked writes the mark
          ;; bare.  That is a thinner distinction than the one this test used to draw
          ;; and it is the honest one -- the question here is which emitter spoke, and
          ;; now that cooked has stopped writing a second spelling of the same mark
          ;; there is nothing coarser left to ask.  A bare `A' present and no
          ;; `click_events=' anywhere is fish silent and cooked speaking.
          (should (member "A" marks))
          (should-not (seq-find (lambda (m) (string-search "click_events" m)) marks))
          (should (member "B" marks))
          ;; A `C' carrying the command line, which is the shell's own account of what
          ;; it is about to run and the one Emacs prefers to its own submitted text.
          (should (member "C;cmdline_url=false" marks))
          ;; `$status' really is the command's inside the postexec handler.
          (should (member "D;1" marks)))
      (delete-directory config t)
      (delete-file input))))

(ert-deftest cooked-fish-stands-down-where-fish-marks-its-own-prompts ()
  "fish 4.0 emits the 133 marks, OSC 7 and OSC 0 itself and unconditionally, so
the snippet has to get out of the way or bracket every prompt twice.

Asserted through the feature list rather than by counting marks on the wire,
because the feature list is *how* it gets out of the way: the snippet appends the
same `no-NAME\=' forms an rc would, so there is one mechanism deciding what is on
and `__cooked_want\=' remains the only thing that answers."
  (skip-unless (executable-find "fish"))
  (cooked-tests--with-fish
    ;; Asked of `__cooked_want' rather than read off `$__cooked_features', which is
    ;; both the predicate that actually decides and short enough not to wrap: the
    ;; feature list is wider than the test screen, and reading a wrapped line back
    ;; out of the buffer had this test failing on a truncated `no-input-mark'.
    (cooked--replace-input
     "for f in marks input-mark cwd title; __cooked_want $f; and echo \"$f=on\"; or echo \"$f=off\"; end")
    (cooked-send-input)
    (should (cooked-tests--settle
             (lambda () (string-match-p "^title=" (cooked-tests--text))) 8))
    (let ((text (cooked-tests--text)))
      ;; `cwd' and `title' are the unconditional ones: OSC 7 and OSC 0 have both been
      ;; unconditional in fish since 4.0.0 and neither has a switch of its own, so both
      ;; stand down on any fish 4 whatever else is set.
      (should (string-match-p "^title=off$" text))
      (should (string-match-p "^cwd=off$" text))
      ;; The marks do have a switch -- `no-mark-prompt' -- so a fish told to be quiet
      ;; about them leaves that job to the snippet.  Either answer is correct; what
      ;; would not be is the two halves disagreeing, since the `A' and the `B' have to
      ;; come from the same emitter to bracket the same prompt.
      (should (eq (and (string-match-p "^marks=off$" text) t)
                  (and (string-match-p "^input-mark=off$" text) t))))))

(ert-deftest cooked-bash-honours-the-feature-list ()
  "The same subtraction zsh honours, on the shell that gets less attention."
  (skip-unless (executable-find "bash"))
  (let ((rc (cooked-tests--bash-rc)))
    (unwind-protect
        (let* ((process-environment
                (cons "COOKED_SHELL_INTEGRATION_FEATURES=input-mark cwd announce"
                      process-environment))
               (marks (cooked-tests--bash-marks rc "true\nexit\n")))
          ;; The keyboard still changes hands...
          (should (member "B" marks))
          ;; ...and nothing else is claimed.
          (should-not (seq-find (lambda (m) (member m '("A" "C"))) marks)))
      (delete-file rc))))

(defun cooked-tests--zsh-osc (code rc &optional input features)
  "Run zsh over RC and return the payloads of every `OSC CODE\=' it wrote.

FEATURES, when given, is the value of COOKED_SHELL_INTEGRATION_FEATURES.  RC is
written into a throwaway ZDOTDIR, and deliberately does *not* set options like
EXTENDED_GLOB: the snippet has to stand on its own in a shell configured by
somebody who never heard of it."
  (let ((dir (make-temp-file "cooked-tests-zsh-" t))
        (payloads nil))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name ".zshrc" dir)
            (insert "PROMPT='$ '\n" rc "\n"
                    "source " (shell-quote-argument
                               (expand-file-name "cooked.zsh"
                                                 (cooked--integration-directory)))
                    "\n"))
          (with-temp-buffer
            (let ((process-environment
                   (append (list "TERM_PROGRAM=cooked" (concat "ZDOTDIR=" dir))
                           (when features
                             (list (concat "COOKED_SHELL_INTEGRATION_FEATURES="
                                           features)))
                           process-environment)))
              (insert (or input "true\nexit\n"))
              (call-process-region (point-min) (point-max) (executable-find "zsh")
                                   t t nil "-i"))
            (goto-char (point-min))
            (while (re-search-forward (format "\e]%d;\\([^\a\e]*\\)\a" code) nil t)
              (push (match-string 1) payloads)))
          (nreverse payloads))
      (delete-directory dir t))))

(ert-deftest cooked-zsh-title-names-the-command-and-the-directory ()
  "Regression: every title came out empty, and nothing said so.

The preexec title picks the first word that is not an assignment or a wrapper
like `sudo\=', which is spelled with a negated glob -- and `^(...)\=' is a
negation only under EXTENDED_GLOB.  Without it the subscript matches nothing and
the title is the empty string rather than an error, so the feature looks
registered and does nothing.  It reached the snippet by being copied out of an rc
that set the option globally, which is exactly the difference between an example
and a shipped file, so the rc here does not set it."
  (skip-unless (executable-find "zsh"))
  ;; `command\=' and an assignment stand in for the whole skip list.  Not `sudo\=',
  ;; which is on it: running one in a test would sit waiting for a password.
  (let ((titles (cooked-tests--zsh-osc 2 "" "true\ncommand true\nFOO=1 true\nexit\n")))
    (should (member "true" titles))
    ;; The wrapper is skipped in favour of what it is wrapping.
    (should-not (member "command" titles))
    (should-not (member "FOO=1" titles))
    (should-not (seq-find #'string-empty-p titles))))

(ert-deftest cooked-zsh-title-can-be-declined ()
  "`no-title\=' leaves the title to whoever was already writing it."
  (skip-unless (executable-find "zsh"))
  (should-not (cooked-tests--zsh-osc 2 "" "true\nexit\n"
                                     "marks input-mark cwd announce title no-title")))

(ert-deftest cooked-zsh-does-not-close-a-command-that-never-ran ()
  "A `D\=' closes a command, so a prompt with no command behind it must not send
one carrying a status it made up.

Three states, which is kitty\='s and Ghostty\='s shape: nothing marked yet -- the
first prompt of a session -- sends no `D\=' at all; an open `C\=' is closed with
`D;<status>\='; and a prompt that ran nothing, an empty return, is closed with a
bare `D\=' that reports no status because there is none to report.  cooked\='s
Emacs side ignores a `D\=' that closes nothing either way, so this is about not
putting an untrue mark on a wire that other readers also have to make sense of."
  (skip-unless (executable-find "zsh"))
  (let ((marks (cooked-tests--zsh-osc 133 "" "\ntrue\nexit\n")))
    ;; Nothing before the session\'s first prompt: the first mark on the wire opens a
    ;; prompt rather than closing a command that never ran.
    (should (string-prefix-p "A" (car marks)))
    ;; The empty line closes with a bare `D\', the `true\' with its status.
    (should (member "D" marks))
    (should (member "D;0" marks))
    ;; And exactly one command actually started: the empty return is not one.
    (should (= 2 (seq-count (lambda (m) (string-prefix-p "C" m)) marks)))))

(ert-deftest cooked-shells-percent-encode-the-directory-they-report ()
  "OSC 7 carries a URL, so its path has to be encoded as one.

`cd /tmp/100%20cake\=' reported raw arrives in Emacs as `/tmp/100 cake\=', a
directory that does not exist, and tracking stops without a word.  The receiving
half has always decoded; it was the sending half that did not encode, in all
three shells at once, so all three are checked here against the same directory."
  (skip-unless (executable-find "zsh"))
  (skip-unless (executable-find "bash"))
  (let* ((parent (make-temp-file "cooked-tests-cwd-" t))
         (awkward (expand-file-name "100%20cake" parent))
         (encoded (concat (replace-regexp-in-string
                           "%" "%25" (file-name-directory awkward) t t)
                          "100%2520cake"))
         (rc (cooked-tests--bash-rc)))
    (unwind-protect
        (progn
          (make-directory awkward)
          (let ((zsh (cooked-tests--zsh-osc
                      7 "" (format "cd %s\nexit\n" (shell-quote-argument awkward)))))
            (should (seq-find (lambda (p) (string-suffix-p encoded p)) zsh))
            ;; Reported once per directory, not once per prompt: the encoding is a
            ;; loop over the bytes of the path and a prompt is drawn far more often
            ;; than a directory is entered.
            (should (= 1 (seq-count (lambda (p) (string-suffix-p encoded p)) zsh))))
          (let ((output (cooked-tests--bash-output
                         rc (format "cd %s\ntrue\nexit\n"
                                    (shell-quote-argument awkward)))))
            (should (string-match-p (regexp-quote encoded) output))))
      (delete-file rc)
      (delete-directory parent t))))

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

(ert-deftest cooked-exports-its-own-terminfo-database ()
  "The default lookup finds ~/.terminfo only while HOME says what it said when we
compiled the entry, and `sudo\=', `su -\=' and a container all change it -- and a
privileged program is not shown ~/.terminfo at all.  Naming the directory on the
search path is what survives that."
  ;; The entry has to be installed for there to be anything to name; installing it
  ;; is `cooked--terminfo\=''s job and is covered by its own test.
  (cooked--terminfo)
  (skip-unless (cooked--terminfo-directory cooked-term-name))
  (let ((home (expand-file-name "~/.terminfo")))
    ;; Bound rather than inherited, and that is the point of spelling it out: read
    ;; from the environment this ran in, this case asserted whatever the developer
    ;; happened to export.  Anyone with TERMINFO_DIRS already set failed here.
    (let* ((process-environment (cons "TERMINFO_DIRS=" process-environment))
           (env (cooked--child-environment)))
      ;; Ours first, then the compiled-in default, which is what the empty entry means.
      (should (equal (cdr (assoc "TERMINFO_DIRS" env)) (concat home ":"))))
    ;; The database already on the user's own path, which is where ncurses looks by
    ;; default and so a reasonable thing to have set.  Ours moves to the front and
    ;; theirs is dropped rather than left behind it: one entry, not two.
    (let* ((process-environment (cons (concat "TERMINFO_DIRS=" home ":") process-environment))
           (env (cooked--child-environment)))
      (should (equal (cdr (assoc "TERMINFO_DIRS" env)) (concat home ":"))))
    ;; Not when we fell back to xterm-256color: there is nothing of ours to find.
    (let* ((cooked-term-name nil)
           (env (cooked--child-environment)))
      (should-not (assoc "TERMINFO_DIRS" env)))
    ;; A search path the user already had is extended, not replaced -- the entries on
    ;; it are theirs and a terminfo lookup that used to succeed has to go on
    ;; succeeding.  Exactly one entry for the name, so the child cannot read the
    ;; inherited value instead of this one.
    (let* ((process-environment (cons "TERMINFO_DIRS=/opt/terminfo:" process-environment))
           (env (cooked--child-environment)))
      (should (equal (cdr (assoc "TERMINFO_DIRS" env))
                     (concat home ":/opt/terminfo:")))
      (should (= 1 (seq-count (lambda (pair) (equal (car pair) "TERMINFO_DIRS")) env))))
    ;; And a TERMINFO the user chose is left alone: it holds one directory, so taking
    ;; it would mean choosing between their entries and ours.  TERMINFO_DIRS is bound
    ;; here for the same reason as above -- this case is about TERMINFO, and reading
    ;; the other one from the ambient environment is what made it fail elsewhere.
    (let* ((process-environment (append '("TERMINFO=/opt/terminfo" "TERMINFO_DIRS=")
                                        process-environment))
           (env (cooked--child-environment)))
      (should (equal (cdr (assoc "TERMINFO" env)) "/opt/terminfo"))
      (should (equal (cdr (assoc "TERMINFO_DIRS" env)) (concat home ":"))))))

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
