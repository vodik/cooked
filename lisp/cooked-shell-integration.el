;;; cooked-shell-integration.el --- Getting cooked's snippet into the child -*- lexical-binding: t; -*-

;;; Commentary:

;; The Emacs half of shell integration: deciding whether to inject at all,
;; deciding which features the snippet turns on, and building the argv and
;; environment that get it sourced.  The shell half is shell-integration/, and
;; the protocol between them is one environment variable carried verbatim -- see
;; `cooked-shell-integration-features\=' for why verbatim is load-bearing.
;;
;; Injection reaches exactly the shell cooked spawned and nothing else.  Every
;; `ssh\=', `sudo -i\=', `docker exec\=' and `exec zsh\=' lands outside it, which is
;; the shape of the mechanism rather than a gap in it: the line in your own rc is
;; the contract, and this is the convenience that saves you writing it for the
;; local case.

;;; Code:

(require 'cooked-util)
(require 'cooked-completion)

(defcustom cooked-shell-integration 'detect
  "Which shell to inject the OSC 133 integration into, if any.

  `detect\='  match the basename of `cooked-shell\=' against the shells we know
  `none\='    never inject; the snippet is yours to source
  `zsh\=', `bash\='  force that scheme regardless of the name

There is no `fish\=' scheme.  The snippet is shipped and honours the feature
list like the others, but injecting it would mean being right about `-C\='
ordering and config.fish sourcing against a shell nothing here has ever run.
Source it by hand; it is the same one line.

Injection generates startup files that source the user\='s own, so nobody\='s
configuration is bypassed or edited, and the generated directory is deleted with
the buffer.

It is on by default, and the honest statement of its limit is that it composes
with nothing.  A generated ZDOTDIR reaches exactly the shell cooked started:
every `ssh\=', every `sudo -i\=', every `docker exec\=', every nested `zsh -f\='
and every `exec zsh\=' lands outside it.  That is not a wart to be fixed but the
shape of the mechanism, and it is why injection is the convenience rather than
the contract -- the contract is a line in your own rc:

    [[ $TERM_PROGRAM == cooked ]] && source /path/to/cooked.zsh

The same line works at both ends of an `ssh\=', and sourcing it twice is a
no-op, so having it *and* injection is the supported arrangement rather than
a conflict.  Where the shell stays unmarked the mode line says `bare\=', and
says it once in words -- see `cooked-integration-hint\='.

What gets turned on once loaded is `cooked-shell-integration-features\=', which
is a separate question from whether cooked put the code there."
  :type '(choice (const :tag "Detect from the shell's name" detect)
                 (const :tag "Never inject" none)
                 (const :tag "Force zsh" zsh)
                 (const :tag "Force bash" bash))
  :group 'cooked)

(defconst cooked-shell-integration-all-features
  '(marks input-mark cwd announce completion title eval-helpers)
  "Every feature name `cooked-shell-integration-features\=' accepts.")

(defcustom cooked-shell-integration-features
  '(marks input-mark cwd announce completion title)
  "Which parts of the shell integration to turn on.

A list of symbols, passed to the shell verbatim in the environment variable
`COOKED_SHELL_INTEGRATION_FEATURES\=' and read there rather than acted on here,
so the same list governs a shell cooked injected into and one that sources the
snippet by hand.

  `marks\='         OSC 133 `A\=', `C\=' and `D\=': where each prompt began,
                  where its command\='s output began, and how it exited.
                  Buys the per-command records, `next-error\=', rerun, and
                  the fringe decorations.
  `input-mark\='    OSC 133 `B\=', which is separate from the rest because it is
                  the one mark that changes who owns the keyboard: it is what
                  lifts the input line into Emacs.  Drop it and the marks above
                  still work -- the shell keeps its own line editor, and you
                  keep the extents and the exit codes.
  `cwd\='           OSC 7, which tracks `default-directory\='.  Also what tells
                  cooked the shell is on this machine, which is half of
                  `cooked--ownership-license\='.
  `announce\='      the per-line OSC 51;CH announcement.  Licenses the editable
                  line from the far end of an `ssh\=', where termios cannot see,
                  and carries the token a completion request must quote.
  `completion\='    source the `compadd\=' capture, so TAB is answered by the
                  shell\='s own completion system.  Needs the Emacs half loaded
                  too -- `(require \\='cooked-shell-completion)\=' -- and does
                  nothing without it.
  `title\='         report the running command as the title.  cooked shows it in
                  the mode line, and `cooked-buffer-name-follows-title\=' can
                  put it in the buffer name.  If your prompt already writes
                  `OSC 2\=' this is a redundant write rather than a conflict --
                  last one wins, and ours runs last -- so drop it if you would
                  rather keep your own wording.
  `eval-helpers\='  define `find_file\=', `dired\=', `osc_copy\=' and
                  `cooked_send\='.  Off by default, and the Emacs half
                  (`(require \\='cooked-osc-eval)\=') gates what they can
                  actually do -- see `cooked-eval-commands\='.

Your rc may edit `COOKED_SHELL_INTEGRATION_FEATURES\=' before the snippet reads
it, which is the supported way to stand one part down from the shell side.  A
prompt that already emits its own OSC 133 marks can append ` no-marks\=' to it
and keep everything else, rather than choosing between duplicate marks and no
integration at all.  The snippet defers its own setup to the first prompt so
that there is a moment in which to do this."
  :type `(set ,@(mapcar (lambda (feature) `(const ,feature))
                        cooked-shell-integration-all-features))
  :group 'cooked)

(defun cooked--integration-shell (shell)
  "Which injection scheme SHELL should get, or nil for none.

`detect\=' matches on the basename, which is what every terminal that does this
uses and is wrong in the same ways for all of them: a shell installed under
another name is missed, and one *named* zsh that is not zsh is mangled.  Naming
the scheme explicitly overrides the guess in both directions.

A bare `t\=' is honoured as `detect\=', because that is what this option meant
while it was a boolean and a session that refuses to start is a poor way to
learn that a setting grew values."
  (let ((setting (if (eq cooked-shell-integration t) 'detect cooked-shell-integration)))
    (pcase setting
      ('detect (let ((name (file-name-nondirectory shell)))
                (and (member name '("zsh" "bash")) (intern name))))
      ((or 'zsh 'bash) setting)
      (_ nil))))

(defun cooked--integration-feature-p (feature)
  "Whether FEATURE is enabled in `cooked-shell-integration-features\='."
  (memq feature cooked-shell-integration-features))

(defun cooked--integration-environment ()
  "The feature-list binding for a child, or nil when nothing is enabled.

Space-separated symbol names, ordered as
`cooked-shell-integration-all-features\=' lists them rather than as the user
happened to write them, so the value a shell sees is stable across restarts
and diffable in a bug report.

Passed verbatim rather than as a normalized re-encoding, which is what makes the
rc-side edit described in `cooked-shell-integration-features\=' possible: the
shell appends to the same vocabulary it received."
  (let ((on (seq-filter #'cooked--integration-feature-p
                        cooked-shell-integration-all-features)))
    (and on (mapconcat #'symbol-name on " "))))

(defun cooked--integration-directory ()
  "Directory holding the shell integration snippets."
  (expand-file-name "shell-integration"
                    (file-name-directory (directory-file-name cooked--source-directory))))

(defvar-local cooked--scratch nil
  "Directory of generated shell startup files, deleted with the buffer.")

(defun cooked--scratch-directory ()
  "A fresh directory for this session's generated startup files."
  (make-temp-file "cooked-shell-" t))

(defun cooked--remove-scratch ()
  "Delete this buffer's generated startup files.

The prefix check is not decoration: this runs from `kill-buffer-hook', which
swallows errors, and a recursive delete of a path that got clobbered is not
something you get to undo."
  (when (and cooked--scratch
             (file-directory-p cooked--scratch)
             (string-prefix-p (file-name-as-directory (temporary-file-directory))
                              (file-name-as-directory cooked--scratch)))
    (ignore-errors (delete-directory cooked--scratch t)))
  (setq cooked--scratch nil))

(defun cooked--zsh-source-user (file)
  "Shell fragment sourcing the user's own FILE from their real ZDOTDIR."
  (concat "if [[ -n ${COOKED_USER_ZDOTDIR-} && -r $COOKED_USER_ZDOTDIR/" file " ]]; then\n"
          "  ZDOTDIR=$COOKED_USER_ZDOTDIR\n"
          "  source $COOKED_USER_ZDOTDIR/" file "\n"
          "  # The user's file is allowed to move ZDOTDIR; respect that downstream.\n"
          "  COOKED_USER_ZDOTDIR=$ZDOTDIR\n"
          "fi\n"))

(defun cooked--write-zsh-startup (scratch integration capture-p)
  "Generate zsh startup files in SCRATCH, sourcing INTEGRATION's snippets.

CAPTURE-P says whether to source the completion capture beside the core.

zsh reads every startup file from ZDOTDIR, so pointing it at a directory holding
only a .zshrc means the user's own ~/.zshenv is never read at all — a real and
silent loss, since .zshenv is where PATH and friends usually live.  Each stub
therefore hands the user's file the ZDOTDIR it expects and then takes it back.

Turning the completion layer on reaches Emacs at once and this shell not at
all; restart it, or source the file yourself."
  (let ((snippet (shell-quote-argument (expand-file-name "cooked.zsh" integration)))
        (capture (shell-quote-argument
                  (expand-file-name "cooked-completion.zsh" integration)))
        (here (shell-quote-argument scratch)))
    (dolist (file '(".zshenv" ".zprofile" ".zlogin"))
      (with-temp-file (expand-file-name file scratch)
        (insert "# Generated by cooked; deleted when the session's buffer is killed.\n"
                (cooked--zsh-source-user file)
                "ZDOTDIR=" here "\n")))
    (with-temp-file (expand-file-name ".zshrc" scratch)
      (insert "# Generated by cooked; deleted when the session's buffer is killed.\n"
              (cooked--zsh-source-user ".zshrc")
              "# After the user's config, so our hooks can order themselves against it.\n"
              "source " snippet "\n"
              (if capture-p (concat "source " capture "\n") "")
              "# Nested shells and `exec zsh' must not inherit the scratch directory,\n"
              "# which would also break them once it is deleted.\n"
              "if [[ -n ${COOKED_USER_ZDOTDIR_SET-} ]]; then\n"
              "  ZDOTDIR=$COOKED_USER_ZDOTDIR\n"
              "else\n"
              "  unset ZDOTDIR\n"
              "fi\n"
              "unset COOKED_USER_ZDOTDIR_SET\n"))))

(defun cooked--shell-invocation (shell)
  "Return (ARGV EXTRA-ENV SCRATCH) that starts SHELL with integration loaded.

Each shell gets the least invasive hook it offers: generated startup files
that source the user\'s own, so nobody\'s configuration is bypassed or edited.
SCRATCH is the directory holding them, for `cooked--remove-scratch\' to delete
later, or nil when none were generated.

COOKED_SHELL_INTEGRATION_FEATURES is set whether or not anything was injected,
and that asymmetry is deliberate: a shell the user sources the snippet in by
hand -- a nested `zsh\', a `fish\', the far end of an `ssh\' that forwards the
variable -- should honour the same feature list as one cooked set up itself.
Injection is how the code gets there; the variable is what it does once it
arrives."
  (let* ((dir (cooked--integration-directory))
         (features (cooked--integration-environment))
         (env (and features `(("COOKED_SHELL_INTEGRATION_FEATURES" . ,features))))
         ;; Both halves have to agree before the capture is worth sourcing: the
         ;; user asked for it, and the Emacs side that answers is loaded.  The
         ;; decision is made *here*, by writing the line or not, because a
         ;; generated file is written at spawn and a running shell cannot
         ;; usefully retract a `compadd\' shadow afterwards.
         (capture-p (and (cooked--integration-feature-p 'completion)
                         cooked-shell-completion-functions)))
    (pcase (cooked--integration-shell shell)
      ('bash
       (let* ((scratch (cooked--scratch-directory))
              (rc (expand-file-name "bashrc" scratch)))
         (with-temp-file rc
           (insert "[ -f ~/.bashrc ] && . ~/.bashrc\n"
                   ". " (shell-quote-argument (expand-file-name "cooked.bash" dir)) "\n"
                   (if capture-p
                       (concat ". " (shell-quote-argument
                                     (expand-file-name "cooked-completion.bash" dir))
                               "\n")
                     "")))
         (list (list shell "--rcfile" rc "-i") env scratch)))
      ('zsh
       (let ((scratch (cooked--scratch-directory))
             (user (or (getenv "ZDOTDIR") (expand-file-name "~"))))
         (cooked--write-zsh-startup scratch dir capture-p)
         (list (list shell "-i")
               `(,@env
                 ("ZDOTDIR" . ,scratch)
                 ("COOKED_USER_ZDOTDIR" . ,user)
                 ;; Distinguishes "put it back" from "there was none", so we do not
                 ;; leave every cooked child exporting ZDOTDIR=$HOME for life.
                 ,@(when (getenv "ZDOTDIR") '(("COOKED_USER_ZDOTDIR_SET" . "1"))))
               scratch)))
      (_ (list (list shell) env nil)))))

(provide 'cooked-shell-integration)
;;; cooked-shell-integration.el ends here
