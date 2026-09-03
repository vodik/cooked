;;; cooked-tests-helpers.el --- Shared fixtures for the cooked test suite -*- lexical-binding: t; -*-

;;; Commentary:

;; Every helper the suite uses, in one place rather than scattered through the
;; tests that first needed them.  The themed files all require this and nothing
;; else of each other, so a test can be moved between them freely.
;;
;; The suite is end-to-end by preference: `cooked-tests--with-session' drives a
;; real child through a real pty, and `cooked-tests--settle' pumps Emacs' event
;; loop until the thing being waited for is true or a deadline passes.  Tests that
;; assert on pure functions -- the rasterizer, the key encoder -- say so by not
;; opening a session at all.

;;; Code:

(require 'ert)
(require 'cl-lib)

;; Optional packages the suite tests against have to be found before the tests
;; that need them run, or `skip-unless' quietly turns a whole feature's coverage
;; off.  That is not hypothetical: the documented `emacs -Q --batch -L lisp -L
;; tests' invocation leaves `evil' off `load-path' even where it is installed, so
;; every evil test skipped and a broken one read as green.
;;
;; `-Q' is deliberate -- the suite must not inherit a user's configuration -- so
;; the answer is to look in the standard install locations ourselves rather than
;; to ask each person to remember a `-L'.

(defconst cooked-tests--package-roots
  (list (expand-file-name "straight/build" user-emacs-directory)
        (expand-file-name "~/.config/emacs/straight/build")
        (expand-file-name "~/.emacs.d/straight/build")
        (expand-file-name "elpa" user-emacs-directory)
        (bound-and-true-p package-user-dir))
  "Where an optional package might already be installed.")

(defun cooked-tests--add-package (name)
  "Put package NAME on `load-path' if it can be found, and say whether it was.
Matches a bare directory (straight) or a versioned one (package.el)."
  (or (locate-library name)
      (catch 'found
        (dolist (root cooked-tests--package-roots)
          (dolist (dir (and root (file-directory-p root)
                            (directory-files root t (concat "\\`" (regexp-quote name)
                                                           "\\(-[0-9.]+\\)?\\'"))))
            (when (file-directory-p dir)
              (add-to-list 'load-path dir)
              (throw 'found dir)))))))

(defconst cooked-tests--optional-packages
  '("goto-chg" "evil" "evil-collection")
  "Packages a `skip-unless' asks for, and which therefore have to be found first.

One list rather than a call apiece, because what the tests ask for and what is
searched for have to be the same set, and the bug this file exists to prevent is
exactly them drifting apart: a test asking for `evil-collection' was added while
only `evil' and its dependency `goto-chg' were ever put on `load-path', so that
test skipped on a machine where the package had been installed all along.  A new
one goes here.")

(defun cooked-tests--find-optional-packages ()
  "Put `cooked-tests--optional-packages' on `load-path', naming what is missing.
Returns the packages that could not be found."
  (seq-remove #'cooked-tests--add-package cooked-tests--optional-packages))

;; Announced at load, not left to the summary: a skipped suite is the failure
;; mode this exists to prevent, so it should be the first thing on the screen.
;; Named individually, because "evil not found" was printed for a shortfall that
;; was never evil.
(when-let* ((missing (cooked-tests--find-optional-packages)))
  (message "cooked-tests: %s not found -- tests needing %s will skip"
           (string-join missing ", ")
           (if (cdr missing) "them" "it")))

(require 'cooked)
(require 'cooked-mode)

(defun cooked-tests--stamp-background (image)
  "Put a `:background\=' on IMAGE, as `solaire-mode\=' advises `create-image\=' to do.

A stand-in for third-party advice that colours every image unconditionally --
see `cooked-box-drawing-resists-advice-that-colors-every-image\='.  Mutates the
returned spec with `plist-put\=', which is what the original does and is the
half that matters: the pair is spliced onto a list the caller already holds."
  (when (consp image)
    (plist-put (cdr image) :background "#123456"))
  image)

(defun cooked-tests--mouse (&rest keys)
  "Set this buffer's mouse state from KEYS, as a drain's `mouse\=' event would.

KEYS are `cooked--mouse-state-make\=' keywords: :enabled, :sgr, :drag, :motion.
A field not named is off, deliberately -- the child\='s request arrives as one
event rather than four independent switches, so a test naming only `:sgr\=' is
describing a child that asked for SGR and nothing else.  Where a test means
\"and keep the mouse on\", it says `:enabled t\=' as well."
  (setq-local cooked--mouse-state (apply #'cooked--mouse-state-make keys)))

(defun cooked-tests--cell (&optional width height)
  "Give the current buffer a cell size of WIDTH by HEIGHT pixels, default 10x20.

Decorations -- box glyphs and image slices -- are cut to the cell, and
`cooked--deco-cell-size\=' will not guess one: with the buffer in no window it
answers from the buffer\='s own `cooked--last-cell\=', and with neither it answers
nil and nothing is decorated at all.  Batch Emacs displays the test buffer in no
window, so this is the ordinary no-window path rather than a stub -- and a real
pixel size rather than the 1x1 a tty window would report, so slice geometry is
arithmetic a reader can check."
  (setq cooked--last-cell (cons (or width 10) (or height 20))))

(defmacro cooked-tests--with-session (argv &rest body)
  "Run BODY in a live cooked buffer running ARGV.

`cooked-debug' is bound throughout, which is what makes the rest of the suite
mean anything.  Without it every protective `condition-case' in the tree --
`cooked--protect-hook', `cooked--dolist-buffers', and the guards around the
cosmetic passes inside a drain -- swallows what it catches, so a test can go on
passing over a layer that signals on every row.  `cooked--check-seam', the
assertion that buffer text still equals the grid, is gated on it too and
otherwise never runs at all.

A test that is *about* containment has to bind it back to nil for the duration;
see `cooked-osc-handler-errors-do-not-break-redisplay'."
  (declare (indent 1))
  `(let ((buffer (generate-new-buffer "*cooked-test*"))
         (cooked-debug t))
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

(defun cooked-tests--pump (seconds)
  "Pump the event loop for SECONDS without forcing a drain.

Unlike `cooked-tests--settle', which applies `cooked--drain'/`cooked--apply'
on every iteration regardless of what triggered them: a test asserting that
draining has been *suppressed* (peek mode) cannot wait with
`cooked-tests--settle', since the wait itself would apply the very drain
under test.  `cooked--on-wake', the process filter, is the only thing
draining here."
  (let ((deadline (+ (float-time) seconds)))
    (while (< (float-time) deadline) (accept-process-output nil 0.05))))

(defun cooked-tests--text ()
  "Visible buffer text with trailing blank lines removed."
  (string-trim-right (buffer-substring-no-properties (point-min) (point-max))))

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

(defmacro cooked-tests--with-echoing-child (setup &rest body)
  "Run BODY against a raw child that echoes what it receives, visibly.
SETUP is shell run before it, for turning bracketed paste on.  `cat -v' spells
control characters out, so what the child was actually sent can be read straight
off the buffer."
  (declare (indent 1))
  `(cooked-tests--with-session
       (list "/bin/sh" "-c" (concat ,setup "stty raw -echo; cat -v"))
     (should (cooked-tests--settle (lambda () (eq cooked--mode 'raw))))
     (should-not (cooked--input-state-p))
     ,@body))

(defconst cooked-tests--prompt "$ "
  "The prompt `cooked-tests--zshrc\=' sets, for tests that must recognise one.

Counting prompts in the buffer is a real thing a test needs to do, and the
string has to be written down somewhere for that to be possible.  Written down
*here*, so that a test doing it is visibly coupled to the suite\='s own shell
configuration rather than invisibly coupled to whatever prompt the person
running it happens to use.")

(defconst cooked-tests--zshrc (concat "\
PROMPT='" cooked-tests--prompt "'
RPROMPT=''
HISTFILE=$ZDOTDIR/history
autoload -U compinit && compinit -u -d $ZDOTDIR/zcompdump
osc_emacs_verb() { printf '\\e]51;E1;%s;%s\\e\\\\' \"$1\" \"${2-}\" }
find_file()              { osc_emacs_verb F \"${${1:-.}:a}\" }
find_file_other_window() { osc_emacs_verb O \"${${1:-.}:a}\" }
dired()                  { osc_emacs_verb D \"${${1:-.}:a}\" }
")
  "The zsh configuration the suite runs against.

Minimal on purpose, and `compinit\=' is in it because the completion tests drive
the real compsys: without it `_main_complete\=' has nothing to call and those
tests fail for a reason that has nothing to do with cooked.  The prompt is a
fixed two characters (`cooked-tests--prompt\='), so that what a test reads out of
the buffer is the command\='s output and a prompt of known width -- rather than
a hostname, a working directory and a git branch that vary per machine.

The `find_file\=' helpers are here rather than in the shipped snippet because
that is where they now live for everyone: they are an example in docs/SHELL.md
to copy into your own rc, not something cooked puts in your shell.  Being user
configuration is exactly what makes this file the right place for them, and the
tests that drive the OSC 51;E channel end to end still need a caller.")

(defvar cooked-tests--zdotdir nil
  "Temporary ZDOTDIR the suite\='s shells are started against.")

(defun cooked-tests--isolate-zsh ()
  "Point ZDOTDIR at `cooked-tests--zshrc\=' rather than at the user\='s own.

Done once, when this file loads, and so for every entry point: the full suite
and a single subject file alike.  It is `setenv\=' rather than a macro around the
tests that want it because there is no test that wants the other thing --
`cooked-tests--with-fake-zdotdir\=' rebinds this for the two that check the
sourcing mechanism itself, and everything else should be running a shell whose
configuration is written down in this file.

The suite must not run the developer\='s own zsh configuration.  By default it
would: `cooked--shell-invocation\=' generates startup stubs that source whatever
ZDOTDIR or $HOME holds, which is the right behaviour for a terminal and the
wrong one for a test.  Inherited configuration makes the suite untrustworthy in
three separate ways, all of them observed here rather than imagined:

  - *Timing.*  A `vcs_info\=' precmd shells out to git on every prompt.  In this
    repository, with cargo and Emacs already competing for the disk, that turns
    prompt latency into a variable and the settle timeouts into a coin flip.
    That is what made the zsh tests fail about one full run in ten locally while
    CI, whose containers have no ~/.zshrc, stayed green -- and why the shells
    here now reach their first prompt in a fifth of the time.
  - *Duplicate marks.*  A configuration that already emits OSC 133 from its own
    precmd hook -- a common thing to have -- puts a second `133;A\=' on the wire
    beside cooked\='s, so a test counting marks is counting someone else\='s too.
  - *Widget collisions.*  `cooked.zsh\=' announces its completion widget from
    `zle-line-init\='; a configuration defining that name wins or loses by source
    order, and the completion tests then silently measure whichever won.

HISTFILE points inside the temporary directory for the same reason, so running
the suite cannot append to the history of the person running it."
  ;; Named rather than left at the default so the suite keeps generating startup
  ;; files even if the default changes again: a hermetic shell, built to order,
  ;; is exactly what injection is good at.  Set for the whole suite rather than
  ;; per call site, for the same reason ZDOTDIR is.
  (setq cooked-shell-integration 'detect)
  (unless cooked-tests--zdotdir
    (setq cooked-tests--zdotdir (make-temp-file "cooked-tests-zdotdir-" t))
    (with-temp-file (expand-file-name ".zshrc" cooked-tests--zdotdir)
      (insert cooked-tests--zshrc))
    (setenv "ZDOTDIR" cooked-tests--zdotdir)
    (add-hook 'kill-emacs-hook
              (lambda () (when cooked-tests--zdotdir
                           (delete-directory cooked-tests--zdotdir t))))))

(cooked-tests--isolate-zsh)

(cl-defmacro cooked-tests--with-shell ((shell &key name env setup settle directory
                                              (timeout 8))
                                       &rest body)
  "Run BODY in a cooked buffer running SHELL, settled at its first prompt.

SHELL is a program name looked up on PATH; callers should `skip-unless\=' it
themselves, since a macro cannot skip for them.  The shell is started through
`cooked--shell-invocation\=', so the integration snippet is injected exactly as
it would be for a user -- which is the point: the marks are what everything
about prompts, command records and exit codes depends on, and a printf cannot
produce them.

  :name     buffer name, for reading a failure; defaults to the shell\='s.
  :env      extra environment pairs, ahead of the invocation\='s own.
  :directory  where to start the child, when it matters what it completes
            against; nil leaves it wherever Emacs is.
  :setup    one form run in the buffer after `cooked-mode\=' and before the
            child, for a test that has to arrange something first.
  :settle   predicate for the first prompt, replacing the default below.
  :timeout  seconds to wait for it.

`cooked--scratch\=' is set from the invocation, which is not bookkeeping: it is
the only handle on the generated startup files, and `cooked--cleanup\=' removes
them through it.  The helper this replaces discarded it, and so left one
temporary directory behind per test that used it.

The default settle condition asks for the editable line as well as the mark,
because \"the prompt has arrived\" is what callers mean and `cooked--semantic\='
alone is true a moment before the input region exists."
  (declare (indent 1) (debug (sexp body)))
  (let ((invocation (gensym "invocation"))
        (extra (gensym "extra")))
    `(let ((buffer (generate-new-buffer (or ,name (format "*cooked-%s*" ,shell))))
           (,extra ,env))
       (unwind-protect
           (with-current-buffer buffer
             (cooked-mode)
             ,@(and setup (list setup))
             (pcase-let ((`(,argv ,,invocation ,scratch)
                          (cooked--shell-invocation (executable-find ,shell))))
               (setq cooked--scratch scratch)
               (cooked--start argv ,directory (append ,extra ,invocation)))
             (cooked--refresh-keymap)
             (should (cooked-tests--settle
                      ,(or settle
                           '(lambda () (and (eq cooked--semantic 'input)
                                            (cooked--input-start-position))))
                      ,timeout))
             ,@body)
         (with-current-buffer buffer (cooked--cleanup))
         (kill-buffer buffer)))))

(defmacro cooked-tests--with-zsh (&rest body)
  "Run BODY in a cooked buffer running zsh, settled at its first prompt.

Started against `cooked-tests--zshrc\=', not the user\='s own; see
`cooked-tests--isolate-zsh\=' for why that is not optional."
  (declare (indent 0))
  `(cooked-tests--with-shell ("zsh") ,@body))

(defmacro cooked-tests--with-fish (&rest body)
  "Run BODY in a cooked buffer running fish, settled at its first prompt.

fish needs a pty in a way bash does not: with stdin off a terminal it never runs
its reader, so the prompt is never drawn and no mark is ever written.  The bash
snippet tests can pipe into `call-process\='; this one has to go through a real
session, which is why it lives here rather than beside them.

fish is not injected -- cooked writes a startup file for zsh and bash, and fish
needs none -- so the snippet is sourced from a generated `config.fish\=' reached
by pointing XDG_CONFIG_HOME at it.  That is the arrangement the file documents
for a user, run as documented.  The prompt is a bare `$ \=', so what a test reads
off the buffer is the shell\='s output rather than a theme\='s."
  (declare (indent 0))
  `(let ((config (make-temp-file "cooked-tests-fish-" t)))
     (unwind-protect
         (progn
           (make-directory (expand-file-name "fish" config))
           (with-temp-file (expand-file-name "fish/config.fish" config)
             (insert "function fish_prompt; printf '$ '; end\n"
                     "source " (shell-quote-argument
                                (expand-file-name "cooked.fish"
                                                  (cooked--integration-directory)))
                     "\n"))
           (cooked-tests--with-shell ("fish" :env `(("XDG_CONFIG_HOME" . ,config)))
             ,@body))
       (delete-directory config t))))

(defun cooked-tests--undo-entries ()
  "The real entries in `buffer-undo-list\=', with the boundaries dropped.

Emacs\=' own command loop pushes a nil boundary after any command that modified
the buffer, so \"the history is empty\" is a claim about what survives once
those are taken out.  Nil in a buffer where undo is off, which is the same
answer as nothing recorded and the one every caller here wants."
  (and (listp buffer-undo-list) (delq nil (copy-sequence buffer-undo-list))))

(defmacro cooked-tests--with-kill (text &rest body)
  "Run BODY with TEXT as the most recent kill and no clipboard in the way."
  (declare (indent 1))
  `(let* ((interprogram-paste-function nil)
          (kill-ring (list ,text))
          (kill-ring-yank-pointer kill-ring))
     ,@body))

;; MARKER is pushed into real scrollback by the lines that follow it — the point
;; being that it is history, not screen content, which the alt screen hides anyway.
(defconst cooked-tests--scrollback-then-alt
  "printf 'MARKER\\n'; seq 1 60; printf '\\033[?1049h'; printf 'inalt\\n'; ")

(defun cooked-tests--run-until-dead (argv seconds)
  "Run ARGV in a cooked buffer and pump for up to SECONDS, killing it if alive.
Returns non-nil when the buffer killed itself along the way."
  (let ((buffer (generate-new-buffer "*cooked-test*")))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (cooked-mode)
            (cooked--start argv))
          (let ((deadline (+ (float-time) seconds)))
            (while (and (< (float-time) deadline) (buffer-live-p buffer))
              (accept-process-output nil 0.05)
              ;; Timers, so the deferred kill actually fires.
              (sit-for 0)
              (when (buffer-live-p buffer)
                (with-current-buffer buffer
                  (when cooked--session
                    (cooked--apply (cooked--drain cooked--session)))))))
          (not (buffer-live-p buffer)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (cooked--cleanup))
        (kill-buffer buffer)))))

;; Twelve rows of exactly twelve columns, `ps'-like: padded out to the right edge and
;; hard-newlined there rather than wrapped, with interior runs of spaces wide enough that
;; a narrower width has to break inside one.  Each row is tagged, so a duplicate is
;; countable rather than a judgement call.
(defconst cooked-tests--filled-screen
  "i=1; while [ $i -le 12 ]; do printf 'r%02d  aaa    bb  cc  \\n' $i; i=$((i+1)); done; exec cat"
  "Fill a 12x20 screen with space-padded lines that reach the right edge.")

(defmacro cooked-tests--with-filled-screen (&rest body)
  "Run BODY with a 12x20 session whose screen `cooked-tests--filled-screen' has filled."
  (declare (indent 0))
  `(let ((buffer (generate-new-buffer "*cooked-filled*")))
     (unwind-protect
         (with-current-buffer buffer
           (cooked-mode)
           (setq cooked--rows 12 cooked--cols 20 cooked--last-size '(12 . 20))
           (cooked--start (list "/bin/sh" "-c" cooked-tests--filled-screen))
           (cooked--refresh-keymap)
           (should (cooked-tests--settle
                    (lambda () (string-match-p "r12" (cooked-tests--text)))))
           ,@body)
       (with-current-buffer buffer (cooked--cleanup))
       (kill-buffer buffer))))

(defmacro cooked-tests--capturing-notifications (&rest body)
  "Run BODY with notifications captured into `seen\=' instead of raised."
  (declare (indent 0))
  `(let ((seen nil))
     (cl-letf (((symbol-function 'cooked--notify)
                (lambda (title body) (push (cons title body) seen))))
       ,@body
       (nreverse seen))))

(defun cooked-tests--reply-to (query out)
  "Shell that sends QUERY, then copies whatever comes back into OUT."
  (list "/bin/sh" "-c"
        (format "stty raw -echo; printf '%s'; cat > %s" query out)))

(defun cooked-tests--contents (file)
  "Contents of FILE, or the empty string if it has none yet."
  (with-temp-buffer
    (ignore-errors (insert-file-contents file))
    (buffer-string)))

(defconst cooked-tests--erase-scrollback-script
  "for i in $(seq 60); do printf 'line%s\\n' $i; done; sleep 1; printf '\\033[3J'; exec cat"
  "Print enough to fill scrollback, settle, then the child erases it.

The `sleep' matters: it lets a test observe the buffer in its pre-erase state
before the `CSI 3 J' this is testing for ever arrives, rather than racing to
read output that a fast child overwrites before the test gets a look at it.")

(defun cooked-tests--type (keys)
  "Run KEYS through the command loop, so `pre-command-hook' applies."
  (execute-kbd-macro (kbd keys)))

(defun cooked-tests--completion-reply (serial prefix records &optional truncated)
  "The OSC 51;C payload a shell would send for RECORDS, as the handler sees it."
  (concat (format "R;%d;%d;0;%d;" serial prefix (if truncated 1 0))
          (base64-encode-string
           (encode-coding-string
            (mapconcat (lambda (record) (concat (string-join record "\x1f") "\x1e"))
                       records "")
            'utf-8)
           t)))

(defmacro cooked-tests--with-stub-shell (answers count &rest body)
  "Run BODY with `cooked--shell-completions' answering from ANSWERS.

ANSWERS is an alist of LINE to the reply it produces; COUNT is a symbol bound to
the number of queries made, which is the point of the exercise: a round trip the
shell did not need is a stutter while typing."
  (declare (indent 2))
  `(let ((,count 0))
     (cl-letf (((symbol-function 'cooked--shell-completions)
                (lambda (line _offset)
                  (cl-incf ,count)
                  (cdr (assoc line ,answers)))))
       ,@body)))

(defconst cooked-tests--two-stage-output-script
  "for i in $(seq 40); do printf 'line%s\\n' $i; done; sleep 1; printf 'AFTER\\n'; exec cat"
  "Enough lines to build real scrollback, then more output after a pause a
test can settle across — see `cooked-tests--erase-scrollback-script'.")

(defmacro cooked-tests--with-straddling-line (&rest body)
  "Run BODY with a 4x10 session holding one 59-character line.
Six rows of one logical line through a four-row screen: two rows have gone to
Emacs while the rest is still on the grid, so the line spans the seam between
them — the arrangement every seam bug needs."
  (declare (indent 0))
  `(let ((buffer (generate-new-buffer "*cooked-seam*")))
     (unwind-protect
         (with-current-buffer buffer
           (cooked-mode)
           (setq cooked--rows 4 cooked--cols 10 cooked--last-size '(4 . 10))
           (cooked--start '("/bin/sh" "-c"
                            "printf '%s' 00000000001111111111222222222233333333334444444444555555555; \
                             sleep 5"))
           (cooked--refresh-keymap)
           (should (cooked-tests--settle
                    (lambda () (string-match-p "555555555" (cooked-tests--text)))))
           ,@body)
       (with-current-buffer buffer (cooked--cleanup))
       (kill-buffer buffer))))

(defun cooked-tests--resize (rows cols)
  "Resize the session to ROWS by COLS and let the redraw land."
  (setq cooked--last-size nil cooked--rows rows cooked--cols cols)
  (cooked--resize cooked--session rows cols)
  (cooked-tests--settle (lambda () nil) 0.3))

(defun cooked-tests--unwrapped ()
  "Buffer text with the line structure taken out."
  (string-replace "\n" "" (cooked-tests--text)))

;; The same arrangement with a padded line rather than a solid one.  Digits cannot catch a
;; trimming bug, because there is nothing about them to trim: every row of the solid line
;; is full to its last column whatever width it is chunked at.  Real column-aligned output
;; is padded with spaces at every boundary, so a wrap landing inside a run of them is the
;; ordinary case, and a continuation row that loses them shortens the buffer's copy of the
;; line — which is the seam drifting, silently, until the next rewrap resumes it a few
;; columns out.
(defconst cooked-tests--padded-seam-line
  "aa        bb        cc        dd        ee        ff       "
  "Fifty-nine characters, padded so that a chunk boundary lands inside the spaces.")

(defmacro cooked-tests--with-padded-straddling-line (&rest body)
  "Run BODY with a 4x10 session holding `cooked-tests--padded-seam-line'."
  (declare (indent 0))
  `(let ((buffer (generate-new-buffer "*cooked-padded-seam*")))
     (unwind-protect
         (with-current-buffer buffer
           (cooked-mode)
           (setq cooked--rows 4 cooked--cols 10 cooked--last-size '(4 . 10))
           (cooked--start (list "/bin/sh" "-c"
                                (format "printf '%%s' '%s'; sleep 5"
                                        cooked-tests--padded-seam-line)))
           (cooked--refresh-keymap)
           (should (cooked-tests--settle
                    (lambda () (string-match-p "ff" (cooked-tests--text)))))
           ,@body)
       (with-current-buffer buffer (cooked--cleanup))
       (kill-buffer buffer))))

(defmacro cooked-tests--with-mocked-wrap (wrap-at &rest body)
  "Run BODY with `vertical-motion' reporting a wrap after WRAP-AT characters.

`cooked--guard-row-width' gates entry to the trim path on `cooked--cols',
which defaults to 80 -- large enough that the short rows these tests write
always fit, so the mocked wrap below is what drives the trim path rather
than the gate.  Tests that need a *smaller*, genuinely-narrower terminal —
the \"genuinely wider row\" case — bind `cooked--cols' themselves."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'vertical-motion)
              (lambda (&rest _) (goto-char (min (point-max) (+ (point) ,wrap-at))))))
     ,@body))

(defun cooked-tests--display-buffer ()
  "Show the current buffer in the selected window, and return that window.

`cooked--guard-row-width' measures a row in `cooked--layout-window' and does
nothing at all when the buffer is displayed nowhere -- there being no layout
for a row to disagree with yet -- so a `with-temp-buffer' test has to put the
buffer on screen before there is any trimming to assert about."
  (set-window-buffer (selected-window) (current-buffer))
  (selected-window))

(defun cooked-tests--glyph-grid (bits width height &optional phase)
  "The pixel bitmap `cooked--render-box-glyph' would pack, for BITS."
  (let ((bitmap (cooked--bitmap-make width height)))
    (if (cooked--box-block-p bits)
        (cooked--box-draw-block bitmap bits (or phase 0))
      (cooked--box-draw-line bitmap bits))
    bitmap))

(defun cooked-tests--line-bits (up down left right &optional dash)
  "A line descriptor, mirroring `BoxGlyph::line' in src/emu/glyph.rs.
DASH is the raw 2-bit code, not a dash count."
  (logior up (ash down 2) (ash left 4) (ash right 6)
          (ash (or dash 0) cooked--box-dash-shift)))

(defun cooked-tests--row-runs (grid y width)
  "Lengths of the set runs in row Y of GRID, left to right."
  (let ((runs nil) (run 0))
    (dotimes (x width)
      (if (cooked--bitmap-ref grid x y)
          (setq run (1+ run))
        (when (> run 0) (push run runs))
        (setq run 0)))
    (when (> run 0) (push run runs))
    (nreverse runs)))

(defun cooked-tests--make-command (prompt-text input-text output-text code)
  "Insert one fake command at `point-max' and push a matching record.

Built by hand rather than driven through OSC 133, the way this file's other
helpers build screen state directly: sticky scroll and command decorations
are both presentation logic layered over `cooked--commands', which OSC
parsing already has coverage of in `cooked-tests-osc.el' and
`cooked-tests-session.el', so their own tests get to start from a buffer in
the shape a real session would have left it rather than driving one.

PROMPT-TEXT and INPUT-TEXT make up the prompt line, OUTPUT-TEXT follows it as
the command's output, and CODE is the exit status.  Returns the new record."
  (goto-char (point-max))
  (let ((prompt (point-marker)))
    (insert prompt-text input-text "\n")
    (let ((start (point-marker)))
      (insert output-text)
      (unless (bolp) (insert "\n"))
      (let* ((end (point-marker))
             (command (cooked--command-make :start start :end end :code code
                                            :input input-text :prompt prompt)))
        (push command cooked--commands)
        command))))

(provide 'cooked-tests-helpers)
;;; cooked-tests-helpers.el ends here
