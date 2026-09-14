;;; cooked-history.el --- the shell's own history, in a completing-read -*- lexical-binding: t; -*-

;;; Commentary:

;; Opt-in:
;;
;;   (use-package cooked
;;     :commands (cooked cooked-other-window)
;;     :config (require 'cooked-history))
;;
;; \\[cooked-history] offers the shell's own history in a `completing-read' and puts
;; what you pick at the prompt, where you can still edit it before pressing RET.
;;
;; `docs/DESIGN.md' concludes that history "has no channel" and that
;; `cooked-delegate-key' is the only mechanism, and for *interactive* history search
;; -- C-r, with the user's own bindkeys, inside the shell's line editor -- that is
;; exactly right and this file does not try to compete with it.  But "pick a past
;; command from a list and insert it" needs no channel at all.  The shell has already
;; written its history to a file, and a subprocess can read it back.  Strictly weaker
;; than delegation, strictly stronger than the empty ring cooked has today, and it
;; composes with both.
;;
;; The one design decision worth stating: the history command runs through
;; `process-file', not `call-process'.  That is what makes a *remote* session query
;; the *remote* host's history -- `process-file' dispatches on `default-directory',
;; which `cooked--set-directory' keeps on a TRAMP path once the child has reported
;; one.  The only remote branch is the shell that runs the command line, because
;; the local `shell-file-name' is an absolute path on this machine; see
;; `cooked-history--run'.

;;; Code:

(require 'cooked)
(require 'cooked-mode)

(defgroup cooked-history nil
  "Reading the shell's history back out of the shell."
  :group 'cooked)

(defcustom cooked-history-commands
  '((bash . "bash -ic 'history -r; fc -lnr 1'")
    (zsh  . "zsh -ic 'fc -R; fc -lnr 1'")
    (fish . "fish -c 'history -z'")
    (nu   . "nu -c 'history | get command | reverse | to text'"))
  "How to ask each shell for its history, newest first.

An alist of (SHELL . COMMAND).  COMMAND is either a shell command line, run
by `cooked-history--run', or a *function*
called with no arguments in the session's buffer, which returns the list of
entries itself.  The function form is the seam atuin, histdb and any other
history database plug into, and it is why this is not a plain list of strings.

The shells are asked *interactively* (`-i') because a non-interactive shell
does not read the rc file that sets `HISTFILE', and would answer with an empty
history or with the wrong one.  That does mean the rc file runs, so a shell
whose rc is slow makes this slow; a function value is the way out.

fish emits NUL-separated entries, which is why it is asked with `history -z':
its entries can contain newlines, and splitting those on newlines would offer
you half a command.  The output is split on NUL whenever it contains one and on
newlines otherwise, so a shell not listed here works if it can do either."
  :type '(alist :key-type symbol :value-type (choice string function))
  :group 'cooked-history)

(defcustom cooked-history-shell nil
  "Which shell's history \\[cooked-history] asks for, or nil to guess.

nil guesses from `cooked-shell', which is what `M-x cooked' starts.  The
guess is wrong for a session started with an explicit command -- cooked keeps no
per-buffer record of what it launched, and inventing one for this would be a
change to the core on behalf of an optional layer.  Set this buffer-locally in
such a session, or set it globally if you always use one shell.

A remote session, one whose `default-directory' is a TRAMP path because the
far shell reported its directory, guesses from the far host's `SHELL'
instead, since the local `cooked-shell' says nothing about what ssh started
there.  That is the login shell, so it is wrong for someone who ran `fish' by
hand after logging in to a host whose login shell is bash; the history command
then fails and says so, and setting this is the way out."
  :type '(choice (const :tag "Guess from `cooked-shell'" nil) symbol)
  :group 'cooked-history)

(defcustom cooked-history-limit 2000
  "How many history entries to offer, or nil for all of them.

A cap rather than a preference: the shells are asked for their whole history and
a long one is tens of thousands of lines, which is slow to complete against and
almost never what anyone is looking for.  Newest first, so the cap drops the
oldest."
  :type '(choice (const :tag "All of them" nil) natnum)
  :group 'cooked-history)

(defun cooked-history--shell ()
  "The shell symbol to look up in `cooked-history-commands'.
See `cooked-history-shell' for how it is guessed, here and on a remote host."
  (or cooked-history-shell
      (let ((name (file-name-nondirectory
                   (if (file-remote-p default-directory)
                       (string-trim (cooked-history--run "printf %s \"$SHELL\""))
                     ;; `cooked-shell' may carry arguments the way
                     ;; `explicit-shell-file-name' is allowed to.
                     (car (split-string-and-unquote (or cooked-shell "")))))))
        (and (not (string-empty-p name)) (intern name)))))

(defun cooked-history--split (output)
  "Split OUTPUT into entries, on NUL if it uses them and on newlines if not.

Deciding per call rather than per shell so an unlisted shell works either way,
and because `history -z' is a fish flag rather than a fish property -- a
wrapper could reasonably emit NULs from anything."
  (let ((entries (split-string output (if (string-search "\0" output) "\0" "\n") t)))
    (mapcar #'string-trim entries)))

(defun cooked-history--run (command)
  "Run the shell command line COMMAND and return what it wrote to stdout.

Through `process-file', so a session whose `default-directory' is a TRAMP
path asks the far host.  The command line is run by `shell-file-name' here,
and by /bin/sh on a remote host.  `shell-file-name' is an absolute path on
this machine, such as /opt/homebrew/bin/fish, and TRAMP runs it by that path
rather than looking the name up, so a Linux server would answer
\"sh: /opt/homebrew/bin/fish: not found\".  Every host has /bin/sh.

Stderr goes to a file of its own rather than into the output.  An interactive
shell with no controlling terminal, which is what a GUI Emacs starts, prints
\"bash: no job control in this shell\" before the history, and that line would
be offered as the newest entry.  A non-zero exit status signals a `user-error'
with the first line of stderr, so a missing shell or an empty zsh history is
reported rather than offered as a command."
  (let ((stderr (make-temp-file "cooked-history")))
    (unwind-protect
        (with-temp-buffer
          (let ((status (process-file (if (file-remote-p default-directory)
                                          "/bin/sh"
                                        shell-file-name)
                                      nil (list t stderr) nil
                                      shell-command-switch command)))
            (unless (eql status 0)
              (user-error "cooked: history command failed (%s): %s" status
                          (with-temp-buffer
                            (insert-file-contents stderr)
                            (buffer-substring-no-properties
                             (point-min) (line-end-position)))))
            (buffer-string)))
      (delete-file stderr))))

(defun cooked-history--refuse-while-busy ()
  "Signal a `user-error' unless the shell is at its prompt.

While a command owns the keyboard, as `vim' does, an entry would be pasted
into that program rather than put on the shell's line.  `cooked--policy'
says `command' or `alt' then, and those are the states refused.  `raw' is
allowed, because without shell integration it is also what a shell at its own
prompt looks like."
  (when (memq (cooked--policy) '(command alt))
    (user-error "cooked: a command is running; history is for the prompt")))

(defun cooked-history--entries ()
  "This session's history, newest first, without duplicates."
  (let* ((shell (cooked-history--shell))
         (command (alist-get shell cooked-history-commands)))
    (unless command
      (user-error "cooked: no history command for %s; see `cooked-history-commands'"
                  (or shell "an unknown shell")))
    (let* ((raw (if (functionp command)
                    (funcall command)
                  (cooked-history--run command)))
           (entries (if (listp raw) raw (cooked-history--split raw)))
           ;; `delete-dups' preserves the newest-first order, which is the
           ;; whole reason the shells are asked for a reversed history.
           (entries (delete-dups (seq-remove #'string-empty-p entries))))
      (if (and cooked-history-limit (> (length entries) cooked-history-limit))
          (seq-take entries cooked-history-limit)
        entries))))

;;;###autoload
(defun cooked-history ()
  "Pick a command out of the shell's history and put it at the prompt."
  (interactive)
  (unless cooked--session (user-error "cooked: no session in this buffer"))
  (cooked-history--refuse-while-busy)
  (let* ((entries (cooked-history--entries))
         (choice (completing-read
                  "History: "
                  ;; A table that refuses to re-sort, so the shell's
                  ;; newest-first order is what you see.  Without this
                  ;; `completing-read' sorts alphabetically and the most recent
                  ;; command -- the one being reached for nine times in ten --
                  ;; is wherever the alphabet puts it.
                  (lambda (string predicate action)
                    (if (eq action 'metadata)
                        '(metadata (display-sort-function . identity)
                                   (cycle-sort-function . identity))
                      (complete-with-action action entries string predicate)))
                  nil nil nil nil nil t)))
    ;; Asked again, because a command may have started while the minibuffer
    ;; was open.
    (cooked-history--refuse-while-busy)
    (cooked-history--insert choice)))

(defun cooked-history--insert (text)
  "Put TEXT where the user can still edit it before running it.

Two paths, because a cooked buffer is two different things depending on who
owns the keyboard.  In an input state the buffer *is* editable and the prompt
is Emacs' -- so this inserts, and \\[cooked-send-input] runs it.  The entry is
marked as pasted, see `cooked--mark-pasted', so its control bytes are stripped
on the way out as they would be on the other path.  Otherwise the child owns the
line editor and the only way in is the wire, so it goes through the paste path.

Never a newline either way.  Offering a list of past commands and running the
chosen one on the spot is a one-way door over somebody's shell history, and
the entry you meant is one line away from the entry you did not."
  (if (cooked--input-state-p)
      (progn
        (when-let* ((start (cooked--input-start-position)))
          (goto-char (max (point) start)))
        (insert (cooked--mark-pasted text)))
    ;; Through the paste path rather than `cooked--send-to-child': a history
    ;; file is not necessarily one you wrote -- a shared account, a restored
    ;; dotfiles repo, a container image -- so it gets the control-byte strip
    ;; every other inbound text does.  See `cooked--strip-paste-controls'.
    (cooked--send-paste text)))

(provide 'cooked-history)
;;; cooked-history.el ends here
