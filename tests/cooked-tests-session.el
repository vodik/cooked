;;; cooked-tests-session.el --- Starting, sizing and ending a session -*- lexical-binding: t; -*-

;;; Commentary:

;; The lifecycle: loading the native core, spawning a child, injecting shell
;; integration without trampling the user's own configuration, terminfo, window
;; sizing, and what happens to the buffer when the child exits.

;;; Code:

(require 'cooked-tests-helpers)

(ert-deftest cooked-snippet-does-nothing-outside-cooked ()
  "The snippet guards itself on TERM_PROGRAM, so a shared rc is safe.

Sourcing it is a line in the user's own configuration, which means it runs in
every shell they start -- under alacritty, under tmux, over an ssh from a laptop
that has never heard of cooked.  Defining hooks and appending to PS1 there would
be cooked following someone home.

The probe is `precmd_functions' rather than any single hook name because setup
is deferred to the first prompt: immediately after sourcing, the only thing
registered is the deferred initializer, and under another terminal there must be
nothing at all."
  :tags '(zsh)
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
`OSC 51;CH' come apart: the core alone claims a line editor is reading -- which
is what licenses the Emacs input region behind an ssh -- while saying it can
answer no requests.  Sourcing the capture is what turns the last field on."
  :tags '(base64 zsh)
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

(ert-deftest cooked-a-core-rebuilt-under-a-session-is-reported ()
  "Installing by rename is what keeps a running session alive across a rebuild,
and the same thing is what lets its core fall behind the Lisp calling it.  Emacs
cannot unload a module, so all that is left is to say so; the check answers on
the file rather than on `cooked--core-version', which does not move when a
defun is added and so stays quiet through exactly the drift that bites."
  (cooked--load-module)
  (let ((file (car cooked--core-loaded))
        (built-at (cdr cooked--core-loaded)))
    ;; The artifact this session mapped is still the one on disk.
    (let ((cooked--core-loaded (cons file built-at)))
      (should-not (cooked--check-core-drift file)))
    ;; Rebuilt since: the session is running a core older than the file.
    (let ((cooked--core-loaded (cons file (time-subtract built-at 3600))))
      (should (cooked--check-core-drift file)))
    ;; A core somebody else is responsible for -- `cooked-native-module' -- is
    ;; not this session's to have an opinion about.
    (let ((cooked--core-loaded
           (cons "/nonexistent/libcooked.so" (time-subtract built-at 3600))))
      (should-not (cooked--check-core-drift file)))))

(ert-deftest cooked-signal-refuses-a-number-that-is-not-one ()
  "Regression: a signal number wider than an int used to wrap into a real signal.

The number arrives as a Lisp integer, which is wider than the `int' a signal
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

(ert-deftest cooked-signal-takes-a-name-as-well-as-a-number ()
  "Regression: the signal numbers written down in Lisp were Linux's.

SIGTSTP is 20 there and 18 on the BSDs, where 20 is SIGCHLD and 18 is what
Linux calls SIGCONT -- so `cooked-suspend' sent macOS a signal the child
ignores, and `cooked-continue' sent it the one that stops the job it means to
restart.  Naming the signal moves the number to the side that links libc and
can see which platform it is on; see `cooked--send-job-control'.

A name that is not a signal is refused the same way a number that is not one
is, and the child is still there afterwards to prove nothing was guessed at."
  (cooked-tests--with-session (list "/bin/sh")
    (should (cooked-tests--settle (lambda () (cooked--live-p cooked--session))))
    (dolist (name '(sigwoof sig nil t))
      (should-error (cooked--signal cooked--session name)
                    :type (quote args-out-of-range)))
    ;; Neither a symbol nor a number, so it is the wrong kind of thing rather
    ;; than the wrong value -- which is what double-quoting the name looks like.
    (should-error (cooked--signal cooked--session ''sigtstp)
                  :type (quote wrong-type-argument))
    (should (cooked--live-p cooked--session))
    (dolist (name '(sigcont SIGCONT sigwinch))
      (should-not (cooked--signal cooked--session name)))
    (should (cooked--live-p cooked--session))))

(ert-deftest cooked-entry-points-autoload-from-the-main-file ()
  "Regression: `M-x cooked' from a `:load-path' install.

`package.el' and `use-package's `:commands' both autoload `cooked' from
\"cooked\", so the command has to be reachable by loading cooked.el and nothing
else.  It lived in cooked-mode.el once, and an autoload cookie there does not
help: an autoload that forwards to a second file is not followed, it is
signalled.

Reaching the command is only half of it: it also has to *run*, which means
everything it reads -- the display action it passes, the session it starts --
has to be loaded by that one file.  Calling the command rather than merely
resolving it is what says so.

Run in a fresh Emacs, because in this one the whole suite is already loaded and
there is no autoload left to resolve."
  (let ((lisp (expand-file-name "lisp" (cooked--root))))
    (pcase-dolist (`(,command . ,file)
                   '((cooked . "cooked")
                     (cooked-other-window . "cooked")
                     ;; The project commands are autoloaded from their own file,
                     ;; which is a second entry point into the same hazard.
                     (cooked-here . "cooked-project")
                     (cooked-here-other-window . "cooked-project")))
      (should
       (eq 0 (call-process
              (expand-file-name invocation-name invocation-directory)
              nil nil nil "-Q" "--batch" "-L" lisp
              "--eval" (prin1-to-string
                        `(progn (autoload ',command ,file nil t)
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
  :tags '(zsh)
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-fake-zdotdir
      '((".zshenv" . "export COOKED_ZSHENV_WITNESS=yes\n")
        (".zshrc" . "export COOKED_ZSHRC_WITNESS=yes\n"))
    (cooked-tests--with-shell ("zsh" :name "*cooked-zshenv*" :settle (lambda () (eq cooked--semantic 'input)))
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
                                    (cooked-tests--text)))))))

(ert-deftest cooked-zsh-survives-a-theme-that-rebuilds-the-prompt ()
  "Regression: the 133;B mark was appended to PS1 once at source time, so any
theme rebuilding PS1 from its own precmd dropped it — and with it the whole
hand-the-keyboard-back feature.  Exit codes broke the same way, because our
precmd then ran after the theme's and read its status instead of the command's."
  :tags '(zsh)
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-fake-zdotdir
      '((".zshrc" . "__theme_precmd() { PS1='theme%% ' }\n\
autoload -Uz add-zsh-hook\n\
add-zsh-hook precmd __theme_precmd\n"))
    ;; Settling at all means an OSC 133;B arrived.
    (cooked-tests--with-shell ("zsh" :name "*cooked-theme*")
      ;; And the exit code still belongs to the command, not the theme's hook.
      (cooked--replace-input "exit 7")
      (cooked--send cooked--session "(exit 7)\r")
      (should (cooked-tests--settle
               (lambda () (eql (cooked-last-exit-code) 7)))))))

(ert-deftest cooked-integration-features-reach-the-child-verbatim ()
  "The feature list is passed as a string the shell can append to.

Verbatim rather than re-encoded, and that is the whole mechanism: the shell
appends `no-NAME' to the value it was handed, so the vocabulary it answers in
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
  "`detect' matches the basename; naming a shell overrides the guess both ways."
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
  "An rc that already emits OSC 133 appends `no-marks' and keeps the rest.

This is the case with no good answer anywhere else: kitty documents the same
convention, Ghostty cannot express it, and nobody specifies what a terminal does
with two sets of marks for one prompt.  Here the shell settles it before any
duplicate reaches the wire -- and settling it must not cost the editable line,
which is the half a user standing the marks down still wants.

The snippet defers its own setup to the first prompt precisely so that the rc,
which runs earlier, has somewhere to stand."
  :tags '(zsh)
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-fake-zdotdir
      '((".zshrc" . "PROMPT='$ '\nCOOKED_SHELL_INTEGRATION_FEATURES=\"${COOKED_SHELL_INTEGRATION_FEATURES-} no-marks\"\n"))
    ;; Settling means the `B\=' mark still arrives, so Emacs still owns the line.
    (cooked-tests--with-shell ("zsh" :name "*cooked-no-marks*")
      ;; But no `A\=' ever did, so there is no prompt extent to report --
      ;; which is what the rc asked for by standing the marks down.
      (should (null cooked--prompt-start)))))

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
  "Run bash over RC, feed it INPUT, and return its OSC 133 marks in order.

Read off the raw byte stream rather than out of a cooked buffer, because what
these tests are about is what the *snippet* put on the wire: a mark emitted
twice is invisible in the buffer -- an OSC occupies no columns -- and reaches
Emacs as a second claim about the same prompt, which is exactly the kind of bug
that hides until something downstream quietly disagrees.

bash is the shell this matters most for.  It is the one the author does not
use, so it has no daily driver to notice a regression, and its hooks are the
fragile ones: PS1 holds the marks as backslash escapes rather than as bytes,
and the `C' mark rides in PS0, which is a prompt string like any other and
so is lost to anything that rebuilds it."
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

The sibling of `cooked-tests--bash-marks' for the assertions that are about a
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

`A' and `B' live in PS1, which holds them as the backslash escapes bash
expands when it draws the prompt -- not as bytes.  The guard against
re-appending tested for a real ESC, so it never matched, and by the tenth prompt
PS1 was mostly marks.  Nothing was visibly wrong: an OSC occupies no columns."
  :tags '(bash)
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
  "Regression: every prompt emitted a stray `C'.

A `C' says a command started, which is not merely untidy -- it clears the
announcement nonce, so the next completion request on that prompt arrives
unlicensed and is refused.

This used to be a DEBUG trap, which fires before every command including the
prompt's own, so it had to work out which ones the user typed; comparing against
PROMPT_COMMAND could not do it, because that holds several commands joined by
`;' while the trap sees one at a time.  The mark now rides in PS0, which bash
expands exactly once per command line it is about to run, so the question the
latch answered no longer gets asked.  The test stays because the property is the
same one either way, and it is the property rather than the mechanism that
Emacs depends on."
  :tags '(bash)
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
  "The `D' mark carries the command's status, not the prompt hook's.

The zsh half of this is covered separately; bash gets its own because the way it
stays first differs -- a string prepended to PROMPT_COMMAND rather than a
reordered array -- and because a theme appending to PROMPT_COMMAND is the common
way to break it."
  :tags '(bash)
  (skip-unless (executable-find "bash"))
  (let ((rc (cooked-tests--bash-rc "__theme() { :; }"
                                   "PROMPT_COMMAND='__theme'")))
    (unwind-protect
        (let ((marks (cooked-tests--bash-marks rc "(exit 7)\nexit\n")))
          (should (member "D;7" marks)))
      (delete-file rc))))

(ert-deftest cooked-bash-marks-its-continuation-prompt ()
  "PS2 carries the marks too, or every line after the first of a multi-line
construct falls out of Emacs' hands back to readline.

`A;k=s' rather than a bare `A': the option is what says this prompt continues
the previous one, which is what keeps the command record filed under the prompt
the construct was typed at."
  :tags '(bash)
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
  :tags '(bash)
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

The `C' mark used to come from a DEBUG trap, installed at the first prompt --
which is to say after everything else had run.  `trap ... DEBUG' replaces
whatever was there without a word, so the thing it replaced was, as often as not,
bash-preexec: every `preexec_functions' hook the user had went quiet, and
nothing anywhere said so.  The mark rides in PS0 now, which displaces nothing."
  :tags '(bash)
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

`$PROMPT_COMMAND' reads element 0 only and assigning a string back writes
element 0 only, so the user's remaining entries survive -- and now run *after*
everything we appended, which under the old DEBUG trap meant the first of them
was reported as a command the user had typed and every prompt emitted a stray
`C'.  Branch on the actual type, as kitty and Ghostty both do."
  :tags '(bash)
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
  "`cmdline_url=' on the `C' mark, which is the shell's own account of the
command and the only one Emacs has when the shell kept the line.

Percent-encoded rather than kitty's `cmdline=', which is `printf %q' output
and so is quoted in a way only that shell can undo."
  :tags '(bash)
  (skip-unless (executable-find "bash"))
  (let ((rc (cooked-tests--bash-rc)))
    (unwind-protect
        (let ((marks (cooked-tests--bash-marks rc "echo 'hi there'\nexit\n")))
          (should (member "C;cmdline_url=echo%20%27hi%20there%27" marks)))
      (delete-file rc))))

(ert-deftest cooked-bash-refuses-to-guess-at-a-command-line-it-was-not-told ()
  "`history 1' is the only way bash will tell a hook what was typed, and under
`HISTCONTROL=ignorespace' it is a liar: the line about to run was never
recorded, so it answers with the *previous* command.  kitty and Ghostty both
report that one as the command that is running.

The history number settles it -- what bash said the next command would be
numbered, taken at the prompt, against what the entry actually carries -- and
when they disagree the mark goes out bare.  Saying nothing is the only honest
answer, and it costs nothing: Emacs still has the text it submitted."
  :tags '(bash)
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
  "A theme rebuilding PS1 from PROMPT_COMMAND must not cost the `B' mark, which
is the whole hand-the-keyboard-back feature."
  :tags '(bash)
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

On a stock fish 4 the marks under test are *fish's own* -- `cooked.fish'
installs nothing there, by design.  That is the arrangement worth asserting,
because it is the one every fish user gets.  The snippet's own path is
`cooked-fish-supplies-the-marks-fish-declines-to-send', which has to force
fish to be quiet before there is anything of ours to see."
  :tags '(fish)
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
  "The marks have to travel inside `fish_prompt', because the `fish_prompt'
event fires *before* the function is called and so is no place to put the `B'
that must follow the prompt text.

Wrapping it once at startup was not enough: anything that redefines
`fish_prompt' afterwards throws the wrapper away, and `fish_config' does
exactly that every time you change theme.  So the wrapper is re-applied at each
prompt, from the same reasoning that re-applies the PS1 marks in bash and zsh.
The test redefines the prompt mid-session and asks for the marks again."
  :tags '(fish script)
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
  :tags '(fish script)
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

(ert-deftest cooked-fish-and-zsh-close-a-prompt-that-ran-nothing-alike ()
  "The three shells are supposed to put the same bytes on the wire for the same
thing, and for an empty return two of them did not: zsh sends a bare `D' closing
a prompt that ran no command, and fish sent nothing at all, so `true', an empty
return and `false' read as `... A B A B ...' where zsh read `... A B D A B ...'.

Emacs ignores a `D' that closes nothing, so nothing was wrong on screen.  What
was wrong is the claim: a mark is read by other terminals too, and \"no command
ran\" is a fact worth having one spelling for.

Run against the same input in both shells and compared mark for mark, which is
the only form of this assertion that cannot drift: it is not a list of marks
written down here, it is zsh's own transcript.  The comparison stops at the `C'
for `exit', where the two shells genuinely differ -- fish runs its postexec
handler for `exit' and zsh dies before its precmd -- and that is a fact about
the shells rather than about the snippets."
  :tags '(fish zsh script)
  (skip-unless (executable-find "fish"))
  (skip-unless (executable-find "zsh"))
  (skip-unless (executable-find "script"))
  (let* ((session "true\n\nfalse\nexit\n")
         (zsh (cooked-tests--zsh-osc 133 "" session))
         (config (make-temp-file "cooked-tests-fish-" t))
         (input (make-temp-file "cooked-tests-fish-in-"))
         (fish nil))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "fish" config))
          (with-temp-file (expand-file-name "fish/config.fish" config)
            (insert "function fish_prompt; printf '$ '; end\n"
                    "source " (shell-quote-argument
                               (expand-file-name "cooked.fish"
                                                 (cooked--integration-directory)))
                    "\n"))
          (with-temp-file input (insert session))
          (with-temp-buffer
            (let ((process-environment
                   (append (list (concat "XDG_CONFIG_HOME=" config)
                                 "TERM_PROGRAM=cooked" "TERM=xterm-256color")
                           process-environment)))
              ;; `no-mark-prompt' so that the marks under test are the snippet's;
              ;; a stock fish 4 marks its own prompts and cooked stands down.  A pty,
              ;; because fish never runs its reader off a pipe.
              (call-process "script" input t nil "-qc"
                            "fish --features=no-mark-prompt -i" "/dev/null"))
            (goto-char (point-min))
            (while (re-search-forward "\e]133;\\([A-D]\\)\\(;[^\a]*\\)?\a" nil t)
              (push (concat (match-string 1) (or (match-string 2) "")) fish)))
          (setq fish (nreverse fish))
          ;; The mark this is about, from the shell that did not send it.
          (should (member "D" fish))
          ;; A prompt, the empty return's `D', and a prompt: nothing was written twice
          ;; where fish reaches one prompt by more than one route.
          (should (equal (seq-count (lambda (m) (equal m "D")) fish) 1))
          (let ((upto (lambda (marks)
                        (seq-take marks (1+ (or (seq-position marks "C;cmdline_url=exit")
                                                (1- (length marks))))))))
            (should (equal (funcall upto fish) (funcall upto zsh)))))
      (delete-directory config t)
      (delete-file input))))

(ert-deftest cooked-fish-stands-down-where-fish-marks-its-own-prompts ()
  "fish 4.0 emits the 133 marks, OSC 7 and OSC 0 itself and unconditionally, so
the snippet has to get out of the way or bracket every prompt twice.

Asserted through the feature list rather than by counting marks on the wire,
because the feature list is *how* it gets out of the way: the snippet appends the
same `no-NAME' forms an rc would, so there is one mechanism deciding what is on
and `__cooked_want' remains the only thing that answers."
  :tags '(fish)
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
  :tags '(bash)
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
  "Run zsh over RC and return the payloads of every `OSC CODE' it wrote.

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
like `sudo', which is spelled with a negated glob -- and `^(...)' is a
negation only under EXTENDED_GLOB.  Without it the subscript matches nothing and
the title is the empty string rather than an error, so the feature looks
registered and does nothing.  It reached the snippet by being copied out of an rc
that set the option globally, which is exactly the difference between an example
and a shipped file, so the rc here does not set it."
  :tags '(zsh)
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
  "`no-title' leaves the title to whoever was already writing it."
  :tags '(zsh)
  (skip-unless (executable-find "zsh"))
  (should-not (cooked-tests--zsh-osc 2 "" "true\nexit\n"
                                     "marks input-mark cwd announce title no-title")))

(ert-deftest cooked-zsh-does-not-close-a-command-that-never-ran ()
  "A `D' closes a command, so a prompt with no command behind it must not send
one carrying a status it made up.

Three states, which is kitty's and Ghostty's shape: nothing marked yet -- the
first prompt of a session -- sends no `D' at all; an open `C' is closed with
`D;<status>'; and a prompt that ran nothing, an empty return, is closed with a
bare `D' that reports no status because there is none to report.  cooked's
Emacs side ignores a `D' that closes nothing either way, so this is about not
putting an untrue mark on a wire that other readers also have to make sense of."
  :tags '(zsh)
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

`cd /tmp/100%20cake' reported raw arrives in Emacs as `/tmp/100 cake', a
directory that does not exist, and tracking stops without a word.  The receiving
half has always decoded; it was the sending half that did not encode, in all
three shells at once, so all three are checked here against the same directory."
  :tags '(bash zsh)
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
  :tags '(bash)
  (skip-unless (executable-find "bash"))
  (cooked-tests--with-shell
      ("bash"
       ;; The shell's own line editor puts the tty in raw mode, and yet OSC 133
       ;; still hands the line to Emacs -- which is the whole headline.
       :settle (lambda () (and (eq cooked--mode 'raw)
                               (eq cooked--semantic 'input)
                               (cooked--input-start-position))))
    (should (cooked--input-state-p))
    (should (eq (current-local-map) cooked-input-map))
    ;; Submitting runs the command and the output is attributed to it.
    (cooked--restore-pending-input nil)
    (goto-char cooked--input-end)
    (insert "echo marker-ok")
    (cooked-send-input)
    (should (cooked-tests--settle
             (lambda () (string-match-p "marker-ok" (cooked-tests--text)))))
    (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input))))))

(ert-deftest cooked-zsh-reports-command-exit-codes ()
  "Regression: `local status=$?' fails in zsh, which silently killed OSC 133;D."
  :tags '(zsh)
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-shell ("zsh" :settle (lambda () (eq cooked--semantic 'input)))
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
    (should (string-match-p "out-marker" (cooked-tests--text)))))

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

(ert-deftest cooked-a-line-spacing-change-resizes-the-child ()
  "Rows that grow taller hold fewer of them, and the child is told so.

`line-spacing' changes how many rows a window holds without changing the
window, so no window hook runs, and the child went on drawing rows for the old
count until something else resized it.  A default face remapped to a new
height by `face-remap-add-relative' is the same, and runs no hook either.

Batch has no line spacing or face height to measure, so the line height is made
to include a pixel of each, as a graphical frame's would, and the redisplay
that would draw the buffer runs its hooks by hand."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "old=; while :; do s=$(stty size); [ \"$s\" = \"$old\" ] || echo \"$s\"; old=$s; sleep 0.05; done")
    (set-window-buffer (selected-window) (current-buffer))
    (cooked--sync-size)
    (cl-letf* ((real (symbol-function 'window-default-line-height))
               ((symbol-function 'window-default-line-height)
                (lambda (&optional window)
                  (with-current-buffer (window-buffer window)
                    (+ (funcall real window)
                       (or line-spacing 0)
                       (if (assq 'default face-remapping-alist) 1 0))))))
      (dolist (change (list (lambda () (setq-local line-spacing 1))
                            (lambda () (face-remap-add-relative 'default :height 2.0))))
        (let ((rows (car cooked--last-size)))
          (funcall change)
          (run-hook-with-args 'pre-redisplay-functions (selected-window))
          (should (< (cooked--window-rows (selected-window)) rows))
          (should (cooked-tests--settle
                   (lambda ()
                     (string-match-p
                      (format "^%d %d$" (cooked--window-rows (selected-window))
                              (cdr cooked--last-size))
                      (cooked-tests--text)))))
          (should (equal (car cooked--last-size)
                         (cooked--window-rows (selected-window)))))))))

(ert-deftest cooked-terminfo-is-installed-and-used ()
  "The child should see a TERM that describes what we actually implement.

Whichever database it came out of -- the one we ship or one compiled here.  The
assertion is the child's answer, which is the only one that matters, and
`tput colors' is the child answering."
  (should (equal (cooked--terminfo) cooked-term-name))
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '%s|%s\\n' \"$TERM\" \"$(tput colors)\"; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p (regexp-quote cooked-term-name)
                                        (cooked-tests--text)))))
    ;; The entry resolves on the child's side, not just ours.
    (should (string-match-p "|256" (cooked-tests--text)))))

(ert-deftest cooked-terminfo-falls-back-when-unavailable ()
  (let ((cooked-term-name nil))
    (should (equal (cooked--terminfo) "xterm-256color"))))

(ert-deftest cooked-xtgettcap-answers-tc-through-the-pty ()
  "A child asking for Tc in band gets the entry's answer on its own input.

This is the request neovim makes over ssh, where no terminfo database knows
our TERM, and the only way it learns there is direct colour."
  (let ((out (make-temp-file "cooked-xtgettcap")))
    (unwind-protect
        (cooked-tests--with-session (cooked-tests--reply-to "\\033P+q5463\\033\\\\" out)
          (should (cooked-tests--settle
                   (lambda () (string-suffix-p "\033\\" (cooked-tests--contents out)))))
          (should (equal "\033P1+r5463\033\\" (cooked-tests--contents out))))
      (delete-file out))))

(ert-deftest cooked-a-frozen-buffer-still-answers-device-attributes ()
  "A query from a frozen buffer's child is answered without waiting for the thaw.

A freeze defers the render, and every reply used to be sent from the drain, so
DA1 from a child started under a held selection went unanswered until the user
let go.  The child waits on a flag file rather than a delay, so the query is
provably sent after the freeze is in place."
  (let ((out (make-temp-file "cooked-frozen-da1"))
        (flag (make-temp-name (expand-file-name "cooked-frozen-flag"
                                                temporary-file-directory))))
    (unwind-protect
        (cooked-tests--with-session
            (list "/bin/sh" "-c"
                  (format "stty raw -echo; printf ready; until [ -e %s ]; do sleep 0.02; done; printf '\\033[c'; cat > %s"
                          flag out))
          (should (cooked-tests--settle
                   (lambda () (string-match-p "ready" (cooked-tests--text)))))
          (setq cooked--input-mode 'frozen)
          (should (cooked--frozen-p))
          (write-region "" nil flag)
          ;; Pumped, not settled: settling drains by hand, which is the very
          ;; thing a freeze withholds.
          (let ((deadline (+ (float-time) (cooked-tests-timeout 3))))
            (while (and (< (float-time) deadline)
                        (not (string-suffix-p "c" (cooked-tests--contents out))))
              (accept-process-output nil 0.05)))
          (should (cooked--frozen-p))
          ;; The `4\=' comes and goes with whether this Emacs can show pictures.
          (should (string-match-p "\\`\033\\[\\?62\\(;4\\)?;22c\\'"
                                  (cooked-tests--contents out))))
      (delete-file out)
      (ignore-errors (delete-file flag)))))

(ert-deftest cooked-a-hidden-buffer-answers-and-records-its-commands ()
  "A child in a buffer no window shows is answered, and its commands recorded.

Hiding a buffer leaves its screen undrawn, and none of this is drawing: DA1
goes out from the core, and the OSC 133 marks that make a command record ask
for a whole drain because a marker needs its row.  The child waits on a flag
file, so everything it sends is sent after the buffer is hidden."
  (let ((out (make-temp-file "cooked-hidden-da1"))
        (flag (make-temp-name (expand-file-name "cooked-hidden-flag"
                                                temporary-file-directory))))
    (unwind-protect
        (cooked-tests--with-session
            (list "/bin/sh" "-c"
                  (format "stty raw -echo; printf ready; until [ -e %s ]; do sleep 0.02; done; printf '\\033]133;A\\007$ \\033]133;B\\007\\033]133;C\\007done\\r\\n\\033]133;D;0\\007\\033[c'; cat > %s"
                          flag out))
          (should (cooked-tests--settle
                   (lambda () (string-match-p "ready" (cooked-tests--text)))))
          (cooked-tests--hide-buffer)
          (write-region "" nil flag)
          ;; Pumped, so every drain is the wake filter's, as a hidden buffer's are.
          (let ((deadline (+ (float-time) (cooked-tests-timeout 3))))
            (while (and (< (float-time) deadline)
                        (not (and cooked--commands
                                  (string-suffix-p "c" (cooked-tests--contents out)))))
              (accept-process-output nil 0.05)))
          (should cooked--hidden)
          (should (string-match-p "\\`\033\\[\\?62\\(;4\\)?;22c\\'"
                                  (cooked-tests--contents out)))
          (should (= 1 (length cooked--commands)))
          (should (= 0 (cooked-command-code (car cooked--commands)))))
      (delete-file out)
      (ignore-errors (delete-file flag)))))

(ert-deftest cooked-a-hidden-buffer-draws-its-screen-only-when-read ()
  "Output that only changes a hidden buffer's screen waits until something reads it.

The child prints after the buffer is hidden and says so with a file, and the
screen still does not show it: nothing woke Emacs, and a drain would have left
the rows out anyway.  `cooked--sync', which readers of the text call, draws it."
  (let ((flag (make-temp-name (expand-file-name "cooked-hidden-flag"
                                                temporary-file-directory)))
        (done (make-temp-name (expand-file-name "cooked-hidden-done"
                                                temporary-file-directory))))
    (unwind-protect
        (cooked-tests--with-session
            (list "/bin/sh" "-c"
                  (format "stty raw -echo; printf ready; until [ -e %s ]; do sleep 0.02; done; printf '\\r\\nlater'; touch %s; exec cat"
                          flag done))
          (should (cooked-tests--settle
                   (lambda () (string-match-p "ready" (cooked-tests--text)))))
          (cooked-tests--hide-buffer)
          (write-region "" nil flag)
          (let ((deadline (+ (float-time) (cooked-tests-timeout 3))))
            (while (and (< (float-time) deadline) (not (file-exists-p done)))
              (accept-process-output nil 0.05)))
          (cooked-tests--pump 0.2)
          (should-not (string-match-p "later" (cooked-tests--text)))
          (cooked--sync)
          (should (string-match-p "ready\nlater\\'" (cooked-tests--text)))
          (should-not cooked--withheld))
      (ignore-errors (delete-file flag))
      (ignore-errors (delete-file done)))))

(ert-deftest cooked-a-hidden-flood-runs-to-the-end-without-drawing-a-row ()
  "Two million lines into a hidden buffer are appended, never drawn, and never stall.

Holding the screen back must not hold the scrollback back with it: pending
scrollback counts towards the backlog, and at the limit the reader stops and the
child blocks, so a hidden drain that kept it would stop the build for good.
Every drain until the child exits leaves the rows out; the one that reports the
exit is whole, since the session is gone after it and nothing could draw the
screen later."
  (let ((rows 0))
    (cooked-tests--with-session '("/bin/sh" "-c" "stty raw -echo; printf ready; read -r _; yes \"$(printf 'y\\r')\" | head -n 2000000")
      (should (cooked-tests--settle
               (lambda () (string-match-p "ready" (cooked-tests--text)))))
      (cooked-tests--hide-buffer)
      (cl-letf* ((apply (symbol-function 'cooked--apply))
                 ((symbol-function 'cooked--apply)
                  (lambda (update)
                    (unless (plist-get update :exit)
                      (setq rows (+ rows (length (plist-get update :rows)))))
                    (funcall apply update))))
        (cooked--send cooked--session "\n")
        (let ((deadline (+ (float-time) (cooked-tests-timeout 60))))
          (while (and (< (float-time) deadline) (null cooked--exit))
            (accept-process-output nil 0.05))))
      (should (eql cooked--exit 0))
      (should (= rows 0))
      (should (string-match-p "^y\ny\n" (buffer-string))))))

(ert-deftest cooked-showing-a-hidden-buffer-catches-it-up-before-it-is-drawn ()
  "A buffer shown again is drawn whole before its window is, following the cursor.

Ten thousand lines went by while hidden, enough for the backlog to have woken
Emacs to append scrollback above a screen it left alone.  Coming back, the
window hook says a whole drain is owed and `cooked--sync-before-redisplay'
makes it, so the first frame is the child's screen as it is now, with point on
its cursor rather than somewhere in the scrollback that went in above.  The
cursor starts at the top of the screen, where an insertion leaves point behind."
  (let ((done (make-temp-name (expand-file-name "cooked-hidden-done"
                                                temporary-file-directory)))
        (appended 0))
    (unwind-protect
        (cooked-tests--with-session
            (list "/bin/sh" "-c"
                  (format "stty raw -echo; printf 'ready\\r'; read -r _; i=0; while [ $i -lt 10000 ]; do printf 'line %%s\\r\\n' $i; i=$((i+1)); done; printf tail; touch %s; exec cat"
                          done))
          (should (cooked-tests--settle
                   (lambda () (string-match-p "ready" (cooked-tests--text)))))
          ;; At the very start of the screen, where the scrollback goes in.
          (should (= (point) (cooked--cursor-position) (cooked--screen-start-position)))
          (cooked-tests--hide-buffer)
          (cl-letf* ((apply-withheld (symbol-function 'cooked--apply-withheld))
                     ((symbol-function 'cooked--apply-withheld)
                      (lambda (update)
                        (setq appended (1+ appended))
                        (funcall apply-withheld update))))
            (cooked--send cooked--session "\n")
            (let ((deadline (+ (float-time) (cooked-tests-timeout 10))))
              (while (and (< (float-time) deadline) (not (file-exists-p done)))
                (accept-process-output nil 0.05)))
            (cooked-tests--pump 0.2))
          (should (> appended 0))
          (should-not (string-match-p "tail" (cooked-tests--text)))
          (let ((window (cooked-tests--show-buffer)))
            (should cooked--withheld)
            (cooked--sync-before-redisplay window))
          (should-not cooked--withheld)
          (should (string-match-p "line 9999\ntail\\'" (cooked-tests--text)))
          (should (= (point) (cooked--cursor-position))))
      (ignore-errors (delete-file done)))))

(ert-deftest cooked-xtgettcap-answers-for-the-entry-term-names ()
  "The core answers from the entry the child was told about, not a fixed one.

RGB is declared on cooked-direct and deliberately not on cooked-256color, so
the same question gets a hit under one TERM and a miss under the other.  The
name travels to the core in the environment the child is spawned with."
  :tags '(terminfo)
  (skip-unless (cooked--terminfo-database))
  (dolist (case '(("cooked-direct" . "\033P1+r524742\033\\")
                  ("cooked-256color" . "\033P0+r524742\033\\")))
    (let ((cooked-term-name (car case))
          (out (make-temp-file "cooked-xtgettcap")))
      (unwind-protect
          (cooked-tests--with-session (cooked-tests--reply-to "\\033P+q524742\\033\\\\" out)
            (should (cooked-tests--settle
                     (lambda () (string-suffix-p "\033\\" (cooked-tests--contents out)))))
            (should (equal (cdr case) (cooked-tests--contents out))))
        (delete-file out)))))

(ert-deftest cooked-names-its-own-terminfo-database ()
  "TERMINFO names our database, and an inherited one does not survive beside it.

TERMINFO holds exactly one directory and we need it to hold ours, which used to
be the argument for staying off it and putting a database on TERMINFO_DIRS
instead.  The argument does not survive being looked at: nothing sets TERMINFO,
and a name we do not describe still resolves, ncurses falling through to
~/.terminfo and the system database on a miss.  So there is nothing to merge and
no list to keep, and a caller who really does keep a database there can name it
on TERMINFO_DIRS, which we no longer touch either."
  :tags '(terminfo)
  (skip-unless (cooked--terminfo-database))
  (let* ((process-environment (cons "TERMINFO=/opt/theirs" process-environment))
         (env (cooked--child-environment)))
    (should (equal (cdr (assoc "TERMINFO" env)) (cooked--terminfo-database)))
    (should (= 1 (seq-count (lambda (pair) (equal (car pair) "TERMINFO")) env))))
  ;; Nothing of ours to name once we have fallen back: TERM says xterm-256color
  ;; and the system database is where that lives.
  (let* ((cooked-term-name nil)
         (env (cooked--child-environment)))
    (should-not (assoc "TERMINFO" env)))
  ;; TERMINFO_DIRS is not ours and is passed through untouched, which is the
  ;; whole of our involvement with it now.
  (let* ((process-environment (cons "TERMINFO_DIRS=/opt/theirs:" process-environment))
         (env (cooked--child-environment)))
    (should (equal (cdr (assoc "TERMINFO_DIRS" env)) "/opt/theirs:"))))

(ert-deftest cooked-terminfo-is-rebuilt-when-the-source-is-newer ()
  "A database older than terminfo/cooked.ti is not used, it is rebuilt.

The hazard `cooked--module-stale-p' guards, in the other artifact: edit the
source, forget to rebuild, and every child is handed a description of a
terminal this no longer is.  It cannot surface downstream -- a capability that
is merely wrong reads as the child declining to use it -- so it is caught while
the two files can still be compared."
  :tags '(tic)
  (skip-unless (executable-find "tic"))
  (let ((database (make-temp-file "cooked-terminfo" t)))
    (unwind-protect
        (progn
          (should (cooked--terminfo-install database))
          (should (cooked--terminfo-usable-p database cooked-term-name))
          ;; The compiled entry aged back behind the source it came from, which
          ;; is what forgetting `make terminfo' looks like from here.  Dated off
          ;; the source rather than off now: the source is itself hours old in a
          ;; fresh checkout, so an hour ago is still comfortably newer than it.
          (let ((entry (cooked--terminfo-entry database cooked-term-name))
                (source (cooked--terminfo-source)))
            (set-file-times entry
                            (time-subtract
                             (file-attribute-modification-time (file-attributes source))
                             3600)))
          (should-not (cooked--terminfo-usable-p database cooked-term-name)))
      (delete-directory database t))))

(ert-deftest cooked-shadowed-environment-variables-reach-the-child-shadowed ()
  "A name bound twice is handed over once, with the value `getenv' would give.

Consing onto `process-environment' is the documented way to bind a variable
for one process, so the same name appearing twice is ordinary rather than a
mistake -- `compilation-start' does it to empty PAGER.

Passing both entries on does not merely fail to honour the shadow, it inverts
it.  `execve' takes a plain array, POSIX leaves duplicate names unspecified,
and the tie goes to whoever reads it: a shell given `SHADOWED=wanted' ahead of
`SHADOWED=inherited' reports the second, which is the entry the caller consed
onto the front to override.  So the child would end up with exactly the value
the binding existed to replace."
  (let* ((process-environment (append '("PAGER=" "GIT_PAGER=cat")
                                      (cons "GIT_PAGER=less" process-environment)))
         (env (cooked--child-environment)))
    (should (equal (cdr (assoc "PAGER" env)) ""))
    (should (equal (cdr (assoc "GIT_PAGER" env)) "cat"))
    ;; Not merely first-wins in the lookup: the loser must not be in the list at
    ;; all, since nothing downstream of here does a lookup.
    (should (equal 1 (cl-count "PAGER" env :key #'car :test #'equal)))
    (should (equal 1 (cl-count "GIT_PAGER" env :key #'car :test #'equal)))
    ;; The value Emacs itself reports, which is the whole of the contract.
    (should (equal (cdr (assoc "PAGER" env)) (getenv "PAGER")))
    (should (equal (cdr (assoc "GIT_PAGER" env)) (getenv "GIT_PAGER")))))

(ert-deftest cooked-full-screen-programs-redraw-after-a-resize ()
  "End to end: htop must move its footer when the terminal grows."
  :tags '(htop)
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
  (let ((cooked-buffer-name "*cooked: %p*"))
    (should (string-match-p "\\*cooked: .+\\*" (cooked--buffer-name "/tmp/")))
    (let ((buffer (generate-new-buffer (cooked--buffer-name "/tmp/"))))
      (unwind-protect
          ;; A second session in the same directory must not collide.
          (should-not (equal (buffer-name buffer) (cooked--buffer-name "/tmp/")))
        (kill-buffer buffer))))
  ;; A new session has no title or host yet, so both come through empty.
  (let ((cooked-buffer-name (lambda (dir title host) (format "term[%s/%s/%s]" dir title host))))
    (should (equal (cooked--buffer-name "/tmp/") "term[/tmp///]"))))

(ert-deftest cooked-live-buffers-finds-running-sessions ()
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (should (memq (current-buffer) (cooked--live-buffers)))))

(defmacro cooked-tests--with-created (binding &rest body)
  "Bind (VAR FORM), a form returning a session buffer, and clean it up after BODY."
  (declare (indent 1))
  `(let ((,(car binding) nil)
         (cooked-debug t))
     (unwind-protect
         (progn (setq ,(car binding) ,(cadr binding)) ,@body)
       (when (buffer-live-p ,(car binding))
         (with-current-buffer ,(car binding) (cooked--cleanup))
         (kill-buffer ,(car binding))))))

(ert-deftest cooked-create-starts-an-argv-in-a-directory-without-showing-it ()
  "The public constructor returns the buffer and leaves showing it to the caller,
which is what `vterm' and `eat' never offered: their commands display what they
make.  A list is the child's argv, and `cooked-buffer-list' finds the session by
where its shell is, at or below the directory asked about."
  (let ((directory (file-name-as-directory (make-temp-file "cooked-create" t))))
    (unwind-protect
        (cooked-tests--with-created (buffer (cooked-create '("/bin/sh" "-c" "exec sleep 5")
                                                           directory))
          (should (buffer-live-p buffer))
          (should (eq (buffer-local-value 'major-mode buffer) 'cooked-mode))
          (should-not (get-buffer-window buffer t))
          (should (equal (buffer-local-value 'default-directory buffer) directory))
          (should (memq buffer (cooked-buffer-list)))
          (should (memq buffer (cooked-buffer-list directory)))
          (should (memq buffer (cooked-buffer-list (file-name-directory
                                                    (directory-file-name directory)))))
          (should-not (memq buffer (cooked-buffer-list (expand-file-name "below" directory))))
          ;; An argv has no startup files written for it.
          (should-not (buffer-local-value 'cooked--scratch buffer))
          ;; And once the child has gone it is not listed at all.
          (with-current-buffer buffer
            (cooked--kill cooked--session)
            (should (cooked-tests--settle (lambda () (not cooked--session)))))
          (should-not (memq buffer (cooked-buffer-list))))
      (delete-directory directory t))))

(ert-deftest cooked-create-with-an-action-shows-the-session ()
  (let ((other (generate-new-buffer "*cooked-tests-other*")))
    (unwind-protect
        (progn
          (delete-other-windows)
          (set-window-buffer (selected-window) other)
          (cooked-tests--with-created (buffer (cooked-create '("/bin/sh" "-c" "exec sleep 5")
                                                             nil '(display-buffer-same-window)))
            (should (eq (window-buffer (selected-window)) buffer))))
      (kill-buffer other))))

(ert-deftest cooked-exec-runs-the-command-at-the-first-prompt ()
  "The line is held until the shell marks a prompt and then submitted as typed
input, so it becomes a command record with the line as its input.  Sent at once
instead, it reaches a tty still in canonical mode, which echoes it above the
prompt before the shell's line editor echoes it again after."
  :tags '(zsh)
  (skip-unless (executable-find "zsh"))
  (let ((cooked-shell (executable-find "zsh"))
        ;; Long enough that the fallback cannot be what sends it.
        (cooked-integration-hint-delay 60))
    (cooked-tests--with-created (buffer (cooked-exec "echo exec-$((6 * 7))"))
      (with-current-buffer buffer
        (should (cooked-tests--settle
                 (lambda ()
                   (and cooked--commands
                        (save-excursion
                          (goto-char (point-min))
                          (search-forward "exec-42" nil t))))
                 10))
        (should (equal (cooked-command-input (car (last cooked--commands)))
                       "echo exec-$((6 * 7))"))
        (should (= 1 (how-many (regexp-quote "echo exec-") (point-min) (point-max))))))))

(ert-deftest cooked-exec-sends-to-a-shell-without-marks-after-the-hint-delay ()
  "A shell with no integration never marks a prompt, and waiting for one forever
would leave a caller with a session that silently never ran what it was given."
  (let ((cooked-shell "/bin/sh")
        (cooked-integration-hint-delay 0.2))
    (cooked-tests--with-created (buffer (cooked-exec "echo fallback-$((6 * 7))"))
      (with-current-buffer buffer
        (should-not cooked--semantic-seen)
        (should (cooked-tests--settle
                 (lambda ()
                   (save-excursion
                     (goto-char (point-min))
                     (search-forward "fallback-42" nil t)))))))))

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

(ert-deftest cooked-the-pacing-options-reach-a-running-session ()
  "Both used to be read once, at spawn, and said so in their docstrings -- which
made them the only options a running session could not be told about, and meant
tuning the one knob with a taste question behind it began by killing the
terminal you were tuning it for."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let ((cooked-min-redisplay-interval cooked-min-redisplay-interval)
          (cooked-backlog-limit cooked-backlog-limit))
      ;; Through `customize-set-variable', which is what runs the `:set' a user
      ;; setting this from the customize interface would run.
      (customize-set-variable 'cooked-min-redisplay-interval 0.04)
      (customize-set-variable 'cooked-backlog-limit 99)
      ;; The core has no reader for either, by design -- they are write-only
      ;; tuning -- so what is asserted is that the call went through without
      ;; signalling and that the session is still drawing afterwards.
      (should (cooked--live-p cooked--session))
      (cooked--send cooked--session "printf 'after\\n'\n")
      (should (cooked-tests--settle
               (lambda () (string-match-p "after" (cooked-tests--text))))))))

(ert-deftest cooked-setting-pacing-without-a-session-is-harmless ()
  "The `:set' walks every cooked buffer, and a buffer whose child has gone is an
ordinary one to walk past -- as is having no cooked buffers at all, which is the
state a user setting this in their init file is in."
  (let ((cooked-min-redisplay-interval cooked-min-redisplay-interval))
    (customize-set-variable 'cooked-min-redisplay-interval 0.02)
    (should (= cooked-min-redisplay-interval 0.02))
    (customize-set-variable 'cooked-min-redisplay-interval 0.008)))

;;;; The echo of a key

(defun cooked-tests--echo-arrives-early-p (event)
  "Whether a byte sent with `last-input-event' bound to EVENT is drawn early.

The session runs at a three-second `cooked-min-redisplay-interval', and the
frame its child prints on starting has just been applied, so the interval has
nearly all of its length to run when the byte goes out.  The tty echoes the
byte, and only the wake filter drains: an echo in the buffer within half a
second skipped the interval."
  (let ((cooked-min-redisplay-interval 3))
    (cooked-tests--with-session '("/bin/sh" "-c" "printf ready; read -r _; sleep 5")
      (let ((deadline (+ (float-time) (cooked-tests-timeout 5))))
        (while (and (< (float-time) deadline)
                    (not (string-search "ready" (cooked-tests--text))))
          (accept-process-output nil 0.01)))
      (should (string-search "ready" (cooked-tests--text)))
      (let ((last-input-event event))
        (cooked--send cooked--session "z"))
      (let ((deadline (+ (float-time) 0.5)))
        (while (and (< (float-time) deadline)
                    (not (string-search "readyz" (cooked-tests--text))))
          (accept-process-output nil 0.01)))
      (prog1 (and (string-search "readyz" (cooked-tests--text)) t)
        ;; The echo does arrive, so a nil answer is the interval holding it and
        ;; not a child that never wrote.
        (should (cooked-tests--settle
                 (lambda () (string-search "readyz" (cooked-tests--text)))))))))

(ert-deftest cooked-a-key-is-echoed-without-waiting-out-the-interval ()
  "A key typed moments after the last frame is echoed at once.

`cooked--send' asks `last-input-event' whether a key was pressed, and a key
lets the frame that echoes it skip `cooked-min-redisplay-interval'.  Held down,
every key otherwise waited out the rest of the interval that the previous echo
had started."
  (should (cooked-tests--echo-arrives-early-p ?z)))

(ert-deftest cooked-a-mouse-event-waits-out-the-interval ()
  "A byte sent for a mouse event is paced like any other output.

A pointer sweep under mode 1003 sends a report per motion event, and a wheel
notch under alternate scroll sends cursor keys no byte test could tell from
typing, so it is the event that says what the input was, and a mouse event
waives nothing."
  (should-not (cooked-tests--echo-arrives-early-p
               `(mouse-movement ,(posn-at-point)))))

;;;; The seam, with wrapped rows kept split

;; `cooked-tests--settle' drains with `(cooked--drain cooked--session)', and the
;; core defaults that missing argument to rejoining -- so a test that binds
;; `cooked-rejoin-wrapped-lines' to nil and then settles is watching rows be
;; joined anyway, whatever the flag says.  The helpers below go through
;; `cooked--drain-and-apply', which is what the mode itself calls and the only
;; path that asks with the flag in force.

(defun cooked-tests--split-settle (predicate &optional seconds)
  "Pump until PREDICATE holds or SECONDS elapse, draining as the mode does.
SECONDS is scaled by `cooked-tests-timeout'."
  (let ((deadline (+ (float-time) (cooked-tests-timeout (or seconds 5)))))
    (while (and (< (float-time) deadline) (not (funcall predicate)))
      (accept-process-output nil 0.05)
      (when cooked--session (cooked--drain-and-apply)))
    (funcall predicate)))

(defun cooked-tests--split-resize (rows cols)
  "Resize to ROWS by COLS and let the rewrap land, draining as the mode does."
  (setq cooked--last-size nil cooked--rows rows cooked--cols cols)
  (cooked--resize cooked--session rows cols)
  (cooked-tests--split-settle (lambda () nil) 0.3))

(defun cooked-tests--seam-offset ()
  "How far into its own buffer line `cooked--screen-start' sits."
  (let ((start (cooked--screen-start-position)))
    (save-excursion (goto-char start) (- start (line-beginning-position)))))

(defun cooked-tests--scrollback-text ()
  "The transcript above the live screen, widened."
  (save-restriction
    (widen)
    (buffer-substring-no-properties (point-min) (cooked--screen-start-position))))

(defmacro cooked-tests--with-straddling-session (rejoin &rest body)
  "Run BODY over a 4x10 session whose one long line straddles the seam.

REJOIN is what `cooked-rejoin-wrapped-lines' is bound to for the duration,
globally as `cooked-toggle-rejoin-wrapped-lines' would set it.  The line is
`cooked-tests--padded-seam-line': fifty-nine characters at ten columns, so two
of its rows have been evicted by the time it has finished printing and the
emulator is carrying a head."
  (declare (indent 1))
  `(let ((buffer (generate-new-buffer "*cooked-split-seam*"))
         (cooked-rejoin-wrapped-lines ,rejoin)
         (cooked-debug t))
     (unwind-protect
         (with-current-buffer buffer
           (cooked-mode)
           (setq cooked--rows 4 cooked--cols 10 cooked--last-size '(4 . 10))
           (cooked--start (list "/bin/sh" "-c"
                                (format "printf '%%s' '%s'; sleep 5"
                                        cooked-tests--padded-seam-line)))
           (cooked--refresh-keymap)
           (should (cooked-tests--split-settle
                    (lambda () (string-match-p "ff" (cooked-tests--text)))))
           ,@body)
       (with-current-buffer buffer (cooked--cleanup))
       (kill-buffer buffer))))

(ert-deftest cooked-split-rows-leave-the-emulator-carrying-nothing ()
  "With rows kept split the buffer holds no continuation, so neither may the core.

The seam is one number the two ends co-own, and with
`cooked-rejoin-wrapped-lines' off Emacs' half is always zero: every row handed
over gets a newline of its own.  The emulator goes on counting a head anyway --
nothing on that side is told which shape the rows were handed over in -- and
`cooked--split-seam' is what settles it, once per drain."
  (cooked-tests--with-straddling-session nil
    (should (= 0 (cooked-grid-head cooked--grid)))
    (should (= 0 (cooked-tests--seam-offset)))))

(ert-deftest cooked-split-rows-survive-a-resize-without-a-stub-line ()
  "A rewrap must not wedge a fragment of a line between transcript and screen.

The carry is spent at the next width change: `Logical::take_front' cuts a
fragment off the front of row 0's line to top the head up to a whole number of
rows at the new width.  With rows rejoined that fragment continues the line
above; with them split it arrives as a line of its own -- a stub of a few
characters, or of nothing but the padding a chunk boundary landed in -- and
another one lands at every resize after it."
  (cooked-tests--with-straddling-session nil
    (dolist (cols '(30 7 13 10))
      (cooked-tests--split-resize 4 cols)
      ;; The invariant, asserted directly: neither end carries a head.
      (should (= 0 (cooked-grid-head cooked--grid)))
      (should (= 0 (cooked-tests--seam-offset)))
      ;; And its visible consequence.  A stub is a line the child never printed,
      ;; and both kinds this produced are caught here: the whitespace-only one,
      ;; and a widow narrower than the row it was cut from.
      (dolist (line (split-string (cooked-tests--scrollback-text) "\n" t))
        (should-not (string-blank-p line))))
    ;; Nothing of the line was lost or repeated along the way, whatever width it
    ;; ended up chunked at.
    (should (equal (string-join
                    (split-string (cooked-tests--unwrapped) " " t) "")
                   "aabbccddeeff"))))

(ert-deftest cooked-split-rows-gain-no-transcript-line-from-widening ()
  "Widening evicts nothing, so nothing may be added above the seam.

The sharpest form of the stub: at ten columns the line takes six rows and two of
them have been handed over; at thirty it takes two, so the rewrap has nothing to
evict and the transcript must come out of it exactly as tall as it went in.  The
carry is what breaks that -- twenty characters of head to top up to a whole row
of thirty leaves a ten-character fragment, and with rows split it lands as a
third line above the seam that the child never printed."
  (cooked-tests--with-straddling-session nil
    (let ((before (count-lines (point-min) (cooked--screen-start-position))))
      (cooked-tests--split-resize 4 30)
      (should (= before (count-lines (point-min) (cooked--screen-start-position))))
      ;; And what is below the seam is still one buffer line per screen row,
      ;; none of them wider than the grid the rewrap left.
      (save-restriction
        (widen)
        (let ((rows (split-string
                     (buffer-substring-no-properties
                      (cooked--screen-start-position) (point-max))
                     "\n")))
          (should (<= (length (delete "" rows)) (cooked-grid-height cooked--grid)))
          (dolist (row rows)
            (should (<= (length row) cooked--cols))))))))

(ert-deftest cooked-toggling-rejoining-off-keeps-the-head-it-really-holds ()
  "The head standing at a toggle is a continuation, and stays one.

`cooked-toggle-rejoin-wrapped-lines' exists because the variable is only half of
what has to move, and the seam is a third half -- but the half it needs here is
to be left alone.  Text handed over while rejoining was on really is a
continuation, so a resize arriving before the next drain must rewrap against it;
what the emulator has to stop counting is the head the rows handed over *after*
the flip do not have, and `cooked--split-seam' picks that up on the drain that
closes the line.  Both ends agreeing throughout is the whole of the invariant."
  (cooked-tests--with-straddling-session t
    ;; Rejoined, so the seam is genuinely mid-line and the core says so.
    (should (> (cooked-grid-head cooked--grid) 0))
    (should (= (cooked-tests--seam-offset) (cooked-grid-head cooked--grid)))
    (cooked-toggle-rejoin-wrapped-lines)
    (should-not cooked-rejoin-wrapped-lines)
    ;; Untouched by the flip itself, and still true of the buffer.
    (should (> (cooked-grid-head cooked--grid) 0))
    (should (= (cooked-tests--seam-offset) (cooked-grid-head cooked--grid)))
    ;; A resize before any drain is the case the flip must not have broken: the
    ;; rewrap resumes the line where the buffer wraps it, and what it hands back
    ;; closes that line rather than starting a stub of its own.
    (cooked-tests--split-resize 4 7)
    (should (= 0 (cooked-grid-head cooked--grid)))
    (should (= 0 (cooked-tests--seam-offset)))
    (dolist (line (split-string (cooked-tests--scrollback-text) "\n" t))
      (should-not (string-blank-p line)))
    (should (equal (string-join
                    (split-string (cooked-tests--unwrapped) " " t) "")
                   "aabbccddeeff"))))

(ert-deftest cooked-rejoining-sessions-still-carry-their-head ()
  "The repair is for split rows only; rejoining is the mode the carry is for.

A reset that fired in both modes would take the head away from the one end that
has it right, and the next rewrap would resume row 0's line at column zero
against a buffer holding half of it."
  (cooked-tests--with-straddling-session t
    (should (> (cooked-grid-head cooked--grid) 0))
    (should (= (cooked-tests--seam-offset) (cooked-grid-head cooked--grid)))
    (cooked-tests--split-resize 4 13)
    (should (= (cooked-tests--seam-offset) (cooked-grid-head cooked--grid)))
    (cooked--check-seam)))

(ert-deftest cooked-fish-is-injected-through-its-own-vendor-path ()
  "fish is injected now, and by the path fish documents rather than by guessing.

The scheme was refused because injecting looked like it meant being right about
`-C' ordering and config.fish sourcing against a shell nothing here had run.
It does not: fish sources `fish/vendor_conf.d/*.fish' out of every directory
in `XDG_DATA_DIRS', at startup, interactive and login alike.

Asserted on the *invocation* rather than on a live fish, because what is being
tested is the arrangement -- that the argv stays plain, that the snippet lands
where fish will find it, and that the user's own data dirs survive.  Whether
fish honours its own documented path is fish's business, and
`cooked-tests--with-fish' exercises the snippet itself."
  :tags '(fish)
  (skip-unless (executable-find "fish"))
  (pcase-let ((`(,argv ,env ,scratch)
               (cooked--shell-invocation (executable-find "fish"))))
    (unwind-protect
        (let ((dirs (alist-get "XDG_DATA_DIRS" env nil nil #'equal)))
          ;; No `-C', which is the whole point.
          (should-not (member "-C" argv))
          (should (member "-i" argv))
          (should dirs)
          (should (string-prefix-p (concat scratch ":") dirs))
          ;; The user's own directories are appended, not replaced -- dropping them
          ;; would hide every vendor completion on the system.
          (should (string-search "/usr/share" dirs))
          ;; And the snippet is where fish looks.
          (let ((file (expand-file-name "fish/vendor_conf.d/cooked.fish" scratch)))
            (should (file-exists-p file))
            (should (string-search "cooked.fish"
                                   (with-temp-buffer
                                     (insert-file-contents file)
                                     (buffer-string))))))
      (when scratch (delete-directory scratch t)))))

(ert-deftest cooked-fish-vendor-conf-is-sourced-by-a-real-fish ()
  "The claim the arm rests on, put to the shell itself rather than to its manual."
  :tags '(fish)
  (skip-unless (executable-find "fish"))
  (let ((dir (make-temp-file "cooked-fish" t)))
    (unwind-protect
        (let ((conf (expand-file-name "fish/vendor_conf.d" dir)))
          (make-directory conf t)
          (with-temp-file (expand-file-name "probe.fish" conf)
            (insert "set -g COOKED_VENDOR_RAN yes\n"))
          (let ((process-environment
                 (cons (concat "XDG_DATA_DIRS=" dir ":/usr/share") process-environment)))
            (should (string-search
                     "yes"
                     (with-output-to-string
                       (with-current-buffer standard-output
                         (call-process "fish" nil t nil
                                       "-c" "echo $COOKED_VENDOR_RAN")))))))
      (delete-directory dir t))))

(defun cooked-tests--fish-injected-env (original &optional command)
  "What `env' prints inside a fish cooked injected, with XDG_DATA_DIRS at ORIGINAL.

ORIGINAL nil means the variable is unset in Emacs.  The fish is started with
the invocation's own program and environment, run non-interactively with
COMMAND, `env' by default, since fish sources vendor_conf.d either way.
XDG_CONFIG_HOME points at an empty directory so the user's config.fish stays
out of it."
  (let* ((config (make-temp-file "cooked-tests-fish-config" t))
         (process-environment
          (cons (concat "XDG_CONFIG_HOME=" config)
                (cl-remove-if (lambda (entry) (string-prefix-p "XDG_DATA_DIRS=" entry))
                              process-environment)))
         (process-environment (if original
                                  (cons (concat "XDG_DATA_DIRS=" original)
                                        process-environment)
                                process-environment)))
    (pcase-let ((`(,argv ,env ,scratch)
                 (cooked--shell-invocation (executable-find "fish"))))
      (unwind-protect
          (let ((process-environment
                 (append (mapcar (lambda (pair) (concat (car pair) "=" (cdr pair))) env)
                         process-environment)))
            (with-output-to-string
              (with-current-buffer standard-output
                (call-process (car argv) nil t nil "-c" (or command "env")))))
        (delete-directory config t)
        (when scratch (delete-directory scratch t))))))

(ert-deftest cooked-fish-puts-xdg-data-dirs-back-for-its-children ()
  "`env' inside an injected fish shows XDG_DATA_DIRS exactly as it was.

cooked prepends a scratch directory so fish finds its vendor_conf.d file, and
nothing took it out again.  Every child of that fish inherited the directory, an
unset variable became an exported /usr/local/share:/usr/share, and a nested fish
sourced the snippet a second time.  Run against a real fish, for a variable
with a value (including a quote, which the generated file has to survive) and
for one that was unset."
  :tags '(fish)
  (skip-unless (executable-find "fish"))
  (let ((original "/opt/it's here:/usr/share"))
    (let ((lines (split-string (cooked-tests--fish-injected-env original) "\n")))
      (should (equal (seq-filter (lambda (line) (string-prefix-p "XDG_DATA_DIRS=" line))
                                 lines)
                     (list (concat "XDG_DATA_DIRS=" original))))))
  (should-not (string-search "XDG_DATA_DIRS=" (cooked-tests--fish-injected-env nil)))
  ;; A nested fish inherits the restored value, so it finds no cooked vendor file.
  (should (equal (cooked-tests--fish-injected-env
                  "/usr/share" "fish -c 'echo \"[$XDG_DATA_DIRS]\"'")
                 "[/usr/share]\n")))

;;; tmux

(defun cooked-tests--script-output (command input &rest env)
  "Run COMMAND on a pty under `script', type INPUT at it, and return its output.

ENV is extra environment entries, ahead of the inherited ones.  A pty rather
than a pipe because zsh writes its marks to the terminal itself rather than to
stdout, and fish will not draw a prompt without one."
  (let ((file (make-temp-file "cooked-tests-input-")))
    (unwind-protect
        (with-temp-buffer
          (with-temp-file file (insert input))
          (let ((process-environment (append env '("TERM=xterm-256color")
                                             process-environment)))
            (call-process "script" file t nil "-qc" command "/dev/null"))
          (buffer-string))
      (delete-file file))))

(defun cooked-tests--tmux-unwrap (bytes)
  "BYTES with each tmux passthrough replaced by the sequence it carries."
  (replace-regexp-in-string
   "\ePtmux;\\(\\(?:[^\e]\\|\e\e\\)*\\)\e\\\\"
   (lambda (match) (string-replace "\e\e" "\e" (match-string 1 match)))
   bytes t t))

(defun cooked-tests--integration-oscs (bytes)
  "The distinct OSC 7, 133 and 51 sequences in BYTES, sorted, nonces blanked.

Sorted and deduplicated because what the tmux tests compare is two runs of a
shell, and how many times a shell redraws a prompt under type-ahead is not
something either run controls."
  (let ((found nil))
    (with-temp-buffer
      (insert bytes)
      (goto-char (point-min))
      (while (re-search-forward "\e]\\(\\(?:7\\|133\\|51\\);[^\a\e]*\\)\\(?:\a\\|\e\\\\\\)"
                                nil t)
        (push (replace-regexp-in-string "\\`\e]51;CH;2;[0-9]+;" "\e]51;CH;2;N;"
                                        (match-string 0))
              found)))
    (sort (delete-dups found) #'string<)))

(defun cooked-tests--bare-integration-osc-p (bytes)
  "Whether BYTES holds an OSC 7, 133 or 51 that tmux would read for itself.

One whose ESC is not the second of a doubled pair, which is to say one outside a
passthrough."
  (string-match-p "\\(?:\\`\\|[^\e]\\)\e]\\(?:7\\|133\\|51\\);" bytes))

(defconst cooked-tests--tmux-env
  '("TMUX=/tmp/cooked-tests-tmux,1,0" "COOKED_SHELL_INTEGRATION_FEATURES=marks input-mark cwd announce")
  "The environment of a pane in a tmux server started from cooked, less TERM_PROGRAM.")

(ert-deftest cooked-bash-and-zsh-wrap-their-marks-for-tmux ()
  "Inside tmux the snippets send what they always send, inside tmux\\='s passthrough.

tmux reads OSC 7 and 133 for itself and drops OSC 51, so written plainly none of
them gets through.  The property is that unwrapping the tmux run gives back exactly
the sequences the direct run sends, and that nothing of ours is left outside a
passthrough for tmux to take.

The direct run has TMUX set as well, which is the case of an Emacs started inside
tmux: TMUX is inherited by every cooked buffer, where nothing is in the way, so
TERM_PROGRAM is what has to decide."
  :tags '(bash zsh script)
  (skip-unless (executable-find "script"))
  (let* ((dir (cooked--integration-directory))
         (zdotdir (make-temp-file "cooked-tests-zdotdir-" t))
         (bashrc (cooked-tests--bash-rc))
         (runs
          `(("bash" ,(format "bash --rcfile %s -i" (shell-quote-argument bashrc))
             "cd /tmp\ntrue\nexit\n")
            ("zsh" "zsh -i" "cd /tmp\ntrue\nexit\n"))))
    (with-temp-file (expand-file-name ".zshrc" zdotdir)
      (insert "PS1='$ '\nsource "
              (shell-quote-argument (expand-file-name "cooked.zsh" dir)) "\n"))
    (unwind-protect
        (pcase-dolist (`(,shell ,command ,input) runs)
          (when (executable-find shell)
            (let* ((zenv (concat "ZDOTDIR=" zdotdir))
                   (direct (apply #'cooked-tests--script-output command input zenv
                                  "TERM_PROGRAM=cooked" cooked-tests--tmux-env))
                   (wrapped (apply #'cooked-tests--script-output command input zenv
                                   "TERM_PROGRAM=tmux" cooked-tests--tmux-env))
                   (expected (cooked-tests--integration-oscs direct)))
              (ert-info ((format "%s" shell))
                ;; The run did something worth comparing: a directory, both prompt
                ;; marks and an announcement.
                (should (seq-find (lambda (s) (string-match-p "\\`\e]7;file://.*/tmp" s))
                                  expected))
                (should (member "\e]133;A\a" expected))
                (should (member "\e]133;B\a" expected))
                (should (seq-find (lambda (s) (string-prefix-p "\e]51;CH;" s)) expected))
                (should-not (string-search "\ePtmux;" direct))
                (should-not (cooked-tests--bare-integration-osc-p wrapped))
                (should (equal (cooked-tests--integration-oscs
                                (cooked-tests--tmux-unwrap wrapped))
                               expected))))))
      (delete-file bashrc)
      (delete-directory zdotdir t))))

(ert-deftest cooked-fish-wraps-its-marks-for-tmux-and-does-not-stand-down ()
  "fish 4 marks its own prompts, and inside tmux those marks go to tmux and stop.

So the stand-down that is right everywhere else would leave a fish in a tmux pane
with no marks reaching cooked at all.  Inside tmux the snippet keeps its marks and
its directory, and wraps them."
  :tags '(fish script)
  (skip-unless (executable-find "fish"))
  (skip-unless (executable-find "script"))
  (let ((config (make-temp-file "cooked-tests-fish-" t)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "fish" config))
          (with-temp-file (expand-file-name "fish/config.fish" config)
            (insert "function fish_prompt; printf '$ '; end\n"
                    "source " (shell-quote-argument
                               (expand-file-name "cooked.fish"
                                                 (cooked--integration-directory)))
                    "\n"))
          (let* ((wrapped (apply #'cooked-tests--script-output "fish -i" "cd /tmp\nexit\n"
                                 (concat "XDG_CONFIG_HOME=" config)
                                 "TERM_PROGRAM=tmux" cooked-tests--tmux-env))
                 ;; Only what travelled inside a passthrough: fish's own marks are
                 ;; on the wire too, bare, and are tmux's.
                 (carried nil))
            (with-temp-buffer
              (insert wrapped)
              (goto-char (point-min))
              (while (re-search-forward "\ePtmux;\\(\\(?:[^\e]\\|\e\e\\)*\\)\e\\\\" nil t)
                (push (string-replace "\e\e" "\e" (match-string 1)) carried)))
            (should (member "\e]133;A\a" carried))
            (should (member "\e]133;B\a" carried))
            (should (member "\e]133;C;cmdline_url=cd%20/tmp\a" carried))
            (should (seq-find (lambda (s) (string-match-p "\\`\e]7;file://.*/tmp\a" s))
                              carried))))
      (delete-directory config t))))

(ert-deftest cooked-snippets-stay-out-of-a-tmux-cooked-did-not-start ()
  "A pane whose environment has no feature list is not cooked\\='s, and gets nothing.

Inside tmux TERM_PROGRAM says tmux whoever the client is, so the feature list is
the snippet\\='s test.  Without it -- a server started from another terminal, or a
`update-environment\\=' that cleared it -- sourcing the file from a shared rc must
be as inert as it is under any other terminal."
  :tags '(bash script)
  (skip-unless (executable-find "bash"))
  (skip-unless (executable-find "script"))
  (let ((bashrc (cooked-tests--bash-rc)))
    (unwind-protect
        (let ((out (cooked-tests--script-output
                    (format "env -u COOKED_SHELL_INTEGRATION_FEATURES bash --rcfile %s -i"
                            (shell-quote-argument bashrc))
                    "cd /tmp\nexit\n"
                    "TERM_PROGRAM=tmux" (car cooked-tests--tmux-env))))
          (should-not (string-search "\ePtmux;" out))
          (should-not (string-match-p "\e]\\(?:7\\|133\\|51\\);" out)))
      (delete-file bashrc))))

(defun cooked-tests--tmux ()
  "The tmux to test against: COOKED_TEST_TMUX if it names one, else PATH\\='s."
  (let ((named (getenv "COOKED_TEST_TMUX")))
    (if (and named (file-executable-p named)) named (executable-find "tmux"))))

(defmacro cooked-tests--with-tmux (config &rest body)
  "Run BODY in a cooked buffer running bash inside a private tmux server.

CONFIG is the text of the server\\='s configuration.  The server has a socket of
its own and no user configuration, and is killed on the way out.  TMUX is
removed from tmux\\='s own environment, because a suite run from inside tmux
would otherwise be refused as a nested session."
  (declare (indent 1))
  `(let* ((tmux (cooked-tests--tmux))
          (dir (make-temp-file "cooked-tests-tmux-" t))
          (socket (expand-file-name "socket" dir))
          (conf (expand-file-name "tmux.conf" dir))
          (rc (cooked-tests--bash-rc)))
     (with-temp-file conf (insert ,config))
     (unwind-protect
         (cooked-tests--with-session
             (list "env" "-u" "TMUX"
                   (concat "COOKED_SHELL_INTEGRATION_FEATURES="
                           "marks input-mark cwd announce")
                   tmux "-S" socket "-f" conf "new-session"
                   "bash" "--rcfile" rc "-i")
           ;; A prompt mark says the shell is ready off the alternate screen.  On it
           ;; the marks are dropped, and the prompt tmux draws is the only sign.
           (should (cooked-tests--settle
                    (lambda ()
                      (or (eq cooked--semantic 'input)
                          (and cooked--alt
                               (string-match-p "^\\$ " (cooked-tests--text)))))
                    15))
           ,@body)
       (call-process tmux nil nil nil "-S" socket "kill-server")
       (delete-file rc)
       (delete-directory dir t))))

(defun cooked-tests--tmux-run (command)
  "Submit COMMAND at the prompt and wait for the next one."
  (let ((before (length cooked--commands)))
    (if (cooked--input-region)
        (progn (cooked--replace-input command) (cooked-send-input))
      (cooked--send cooked--session (concat command "\r")))
    (should (cooked-tests--settle
             (lambda () (and (> (length cooked--commands) before)
                             (eq cooked--semantic 'input)))
             10))))

(ert-deftest cooked-prompt-navigation-and-directory-work-inside-tmux ()
  "A shell in tmux in cooked: its directory tracked, its prompts navigable.

tmux is kept off the alternate screen and without a status line, which is the
arrangement docs/SHELL.md gives for marks that last into scrollback.  The long
command is there to push its own prompt off the screen: a mark that was not
carried into scrollback with its row would now name a line of its output."
  :tags '(tmux bash)
  (skip-unless (cooked-tests--tmux))
  (skip-unless (executable-find "bash"))
  (cooked-tests--with-tmux
      (concat "set -g allow-passthrough on\n"
              "set -g status off\n"
              "set -ga terminal-overrides ',cooked*:smcup@:rmcup@'\n")
    (cooked-tests--tmux-run "cd /tmp")
    (should (equal default-directory "/tmp/"))
    (cooked-tests--tmux-run "seq 1 100")
    (cooked-tests--tmux-run "true")
    (should (equal (cooked-tests--prompt-lines)
                   '("$ cd /tmp" "$ seq 1 100" "$ true" "$ ")))
    ;; And the navigation command lands on them, the live prompt counting as one.
    (goto-char (point-max))
    (cooked-previous-command 3)
    (should (looking-at-p (regexp-quote "$ seq 1 100")))
    ;; Emacs owns the line: the announcement got through as well as the marks.
    (should (eq (cooked--policy) 'cooked))))

(ert-deftest cooked-tmux-on-the-alternate-screen-keeps-the-keyboard ()
  "By default tmux takes the alternate screen, and there the keys stay tmux\\='s.

The directory is still tracked, but the prompt marks passed through are
dropped: the screen is tmux\\='s frame and scrolls with no scrollback, so a mark
there would name a line of output as soon as the pane scrolled, and no command
record is filed from one."
  :tags '(tmux bash)
  (skip-unless (cooked-tests--tmux))
  (skip-unless (executable-find "bash"))
  (cooked-tests--with-tmux "set -g allow-passthrough on\n"
    (should-not (equal default-directory "/usr/"))
    (cooked--send cooked--session "cd /usr\r")
    (should (cooked-tests--settle (lambda () (equal default-directory "/usr/")) 10))
    (should (eq (cooked--policy) 'alt))
    (should-not cooked--semantic-seen)
    (should-not cooked--commands)))

(ert-deftest cooked-tmux-hands-on-the-active-pane-directory-through-swd ()
  "With `set-titles\\=' on, tmux sends the active pane\\='s directory itself, as the
entry\\='s `Swd\\=', and nothing else\\='s.

`allow-passthrough\\=' stays off, so the snippet\\='s wrapped reports are dropped
and only tmux\\='s own can move `default-directory\\='.  The panes write plain
OSC 7, which tmux keeps per pane.  A background pane changing directory moves
nothing, and selecting it hands its directory on."
  :tags '(tmux bash)
  (skip-unless (cooked-tests--tmux))
  (skip-unless (executable-find "bash"))
  (cooked-tests--with-tmux "set -g set-titles on\n"
    (cl-flet ((tmux (&rest args)
                (should (zerop (apply #'call-process tmux nil nil nil
                                      "-S" socket args))))
              (report (dir)
                (format "printf '\\033]7;file://%s\\007'" dir)))
      (should-not (member default-directory '("/usr/" "/etc/")))
      (tmux "send-keys" "-t" "%0" (report "/usr") "Enter")
      (should (cooked-tests--settle (lambda () (equal default-directory "/usr/")) 10))
      (tmux "split-window" "-d" "bash" "--rcfile" rc "-i")
      (tmux "send-keys" "-t" "%1" (report "/etc") "Enter")
      (cooked-tests--settle #'ignore 1)
      (should (equal default-directory "/usr/"))
      (tmux "select-pane" "-t" "%1")
      (should (cooked-tests--settle (lambda () (equal default-directory "/etc/")) 10)))))

(ert-deftest cooked-osc-7-with-no-path-changes-nothing ()
  "tmux reports an empty OSC 7 for a pane that has never sent one."
  (with-temp-buffer
    (let ((default-directory "/tmp/"))
      (cooked--osc-cwd '(""))
      (should (equal default-directory "/tmp/")))))

(provide 'cooked-tests-session)
;;; cooked-tests-session.el ends here
