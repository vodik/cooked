;;; cooked.el --- A terminal that hands the keyboard back -*- lexical-binding: t; -*-

;; Author: Simon Gomizelj <simongmzlj@gmail.com>
;; Version: 1.0.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: terminals, processes
;; URL: https://github.com/vodik/cooked

;;; Commentary:

;; A terminal emulator whose input model follows what the child actually wants.
;; The kernel's line discipline says when a program is doing a canonical read;
;; OSC 133 says when the shell is at a prompt.  In either case Emacs owns the
;; line and you edit it as you would any buffer.  Otherwise keys are forwarded
;; verbatim and the emulator behaves as a terminal.
;;
;;   (use-package cooked
;;     :load-path "/path/to/cooked/lisp"
;;     :commands (cooked cooked-other-window
;;                cooked-project cooked-project-other-window
;;                cooked-here cooked-here-other-window)
;;     :custom (cooked-buffer-name "*cooked: %p*")
;;     :config
;;     (require 'cooked-evil)             ; opt in to evil state syncing
;;     (require 'cooked-osc-eval)         ; opt in to the OSC 51 command channel
;;     (require 'cooked-shell-completion) ; opt in to the shell's own completion
;;     (require 'cooked-project))         ; opt in to project-scoped sessions
;;
;; Emulation happens in a Rust module, built on first use with cargo.
;;
;; This file is the package's front door: the commands an installation names, on
;; top of `cooked-mode' and everything it requires.  The layers above it are
;; separate because you should choose them, and choosing one is `require'ing its
;; file rather than setting a variable: `cooked-evil', `cooked-osc-eval',
;; `cooked-shell-completion', `cooked-project', `cooked-file-link',
;; `cooked-next-error', `cooked-command-decorations', `cooked-dnd',
;; `cooked-user-var' and `cooked-eshell'.  The snippet above names only the four
;; most people want; the other six load the same way.

;; The buffer is the scrollback.  Rows that scroll off the emulator's screen are
;; handed over once and become ordinary buffer text; the lines after
;; `cooked--screen-start' are the live screen, rewritten from damage reports.
;;
;; Invariant: buffer text equals the grid, plus any pending input rendered at the
;; cursor.  Every redisplay lifts the pending input out, applies the grid, and puts
;; it back.
;;
;; The two ends therefore hold one structure between them, and the boundary is the
;; only place they can disagree.  So the geometry of it is reported rather than
;; re-derived: `cooked--grid' carries the emulator's own account of how tall the
;; grid is, how much of it is occupied, and how much of the line straddling the
;; boundary has already been handed over.  Emacs owns the buffer and makes every
;; edit; it just does not get a second opinion about the shape it is editing to.
;; `cooked--check-seam' is that boundary stated as an assertion.

;; The files underneath require one another in one direction only.  From the
;; floor up: cooked-util.el; the base tier that knows nothing of a session
;; (faces, glyphs, decorations, links, command records, the module loader);
;; cooked-state.el, a session's state and who owns the keyboard; the screen as
;; buffer text and the row guard under it; the pending input, the cursor, the
;; shell marks; the OSC handlers, the mouse and the bell; the drain pipeline in
;; cooked-render.el; starting a session; peek, the key encoding, the line's
;; commands, the keymaps and input methods; and `cooked-mode' at the top.
;; Where a lower file has to report a change the keymap depends on, it runs
;; `cooked--refresh-hook' rather than naming the function above it.

;;; Code:

(require 'cooked-mode)

;;;; Entry points

;; Here rather than in cooked-mode.el, where the rest of the interaction lives,
;; because this is the file an installation names: `package.el' autoloads from it
;; and a `:load-path' install autoloads `cooked' from "cooked".  An autoload that
;; forwards to a second file does not chain -- Emacs signals rather than following
;; it -- so the commands themselves have to be defined here.

(defcustom cooked-display-action '((display-buffer-same-window
                                    display-buffer-pop-up-window))
  "Action `\\[cooked]' passes to `pop-to-buffer'.

The selected window first, the way `vterm' and `eat' do it: a terminal is
usually what you want to be looking at, whereas the fallback `display-buffer'
uses -- reuse a window, else split -- would put it beside the buffer you
invoked it from as often as not.  Splitting is still the second choice, for
when the selected window will not take it (a dedicated or side window), and
`\\[cooked-other-window]' remains the way to ask for the split on purpose.

The extra pair of parentheses is load-bearing, and their absence was the bug
this docstring described its way around for a long time.  A `display-buffer'
action is (FUNCTIONS . ALIST), so the flat list read as FUNCTIONS =
`display-buffer-same-window' and ALIST = (display-buffer-pop-up-window) -- an
alist entry `assq' never asks for and so silently drops.  The second choice
therefore did not exist: a window that would not take the buffer fell through to
`display-buffer-fallback-action', whose first entry is
`display-buffer-reuse-window' -- the behaviour named two paragraphs up as the
one to avoid.

Here rather than in cooked-mode.el with the other session options, because
every command that reads it is here or in cooked-project.el, and each reads it
as an *argument*."
  ;; `sexp' rather than a hand-written (FUNCTIONS . ALIST) type: Emacs has no
  ;; public widget for a display action, and the one thing a narrower type here
  ;; could have caught -- the missing parentheses above -- it would only have
  ;; caught for a value set through Customize, which this one never was.
  :type 'sexp :group 'cooked)

(defconst cooked-other-window-action '(display-buffer-pop-up-window)
  "Display action every `-other-window' command in cooked passes.

A constant rather than the literal written out at each of them: there are three
pairs of commands whose two halves differ in nothing else -- here, and the two
in cooked-project.el -- so the literal was the only thing saying they agree,
three times over.  Deliberately not a `defcustom': the customisable choice is
`cooked-display-action', and a command whose whole name is `other-window'
has already been told what to do.")

;;;; The Lisp interface

;; Three functions for a package that wants a terminal without knowing how one
;; is made: create a session, find the ones there are, and run a command in a
;; fresh one.  Sending to a session already running is `cooked-send-string',
;; and a key is `cooked-send-key'.  Everything named with a double dash stays
;; free to change under them; see docs/FEATURES.md.
;;
;; vterm and eat offer only their commands (`vterm-other-window', `eat') and a
;; buffer-filling `eat-exec', so a caller wanting a buffer back has to go through
;; one that also displays it.  ghostel's `ghostel-create' and `ghostel-exec' are
;; the shape followed here, with one difference: `cooked-exec' runs its command
;; in a shell, where `ghostel-exec' replaces the shell with the program.  Running
;; a program on its own is `cooked-create' with an argv list.

;;;###autoload
(defun cooked-create (&optional command directory display)
  "Start a session and return its buffer.

COMMAND is what `\\[cooked]' would run: nil for `cooked-shell', or another
shell's file name, either getting its shell integration.  A list is an argv
run exactly as given, with no integration, so (\"htop\" \"-d\" \"5\") starts
htop itself rather than a shell.

DIRECTORY is where the child starts, and defaults to `default-directory'.

DISPLAY is a `display-buffer' action, such as `cooked-display-action'.  With
one the buffer is shown with `pop-to-buffer' and the child is sized to the
window it landed in straight away; with nil the buffer is not shown, and the
child starts at the default size until something displays it.

A new session every time: reusing a live one is the caller's decision, and
`cooked-buffer-list' is how to find one."
  (let* ((default-directory (or directory default-directory))
         (buffer (cooked--start-session command)))
    (if display
        (cooked--display buffer display)
      buffer)))

;;;###autoload
(defun cooked-buffer-list (&optional directory)
  "Buffers whose session is still running, the most recently used first.

With DIRECTORY, only those whose shell is in it or somewhere below it, which is
where the shell is now rather than where it started: OSC 7 keeps each buffer's
`default-directory' current, so a shell that ran \"cd /tmp\" is listed under
/tmp.  A buffer whose child has exited is not listed."
  (let ((buffers (cooked--live-buffers)))
    (if directory
        (seq-filter (lambda (buffer)
                      (with-current-buffer buffer
                        (ignore-errors
                          (file-in-directory-p default-directory directory))))
                    buffers)
      buffers)))

;;;###autoload
(defun cooked-exec (command &optional directory display)
  "Start a shell, run COMMAND at its first prompt, and return the buffer.

COMMAND is a line of shell input, such as \"make test\", submitted as if typed
and entered, so it lands in the shell's history and in cooked's command records
like anything else run there.  DIRECTORY and DISPLAY mean what they do in
`cooked-create'.

The line is sent once the shell marks its first prompt, which is when a line
editor is reading and the line is submitted the way \\[cooked-send-input] would
submit it.  Sent at once, it would arrive while the shell was still reading its
startup files, with the tty still echoing, and the transcript would show it
twice: once above the first prompt and once after it.  Waiting needs the shell
integration, so a shell that never marks a prompt is sent COMMAND after
`cooked-integration-hint-delay' seconds instead, the same wait after which
cooked says the marks are missing."
  (let ((buffer (cooked-create nil directory display))
        (sent nil))
    (with-current-buffer buffer
      (letrec ((send
                (lambda ()
                  (unless sent
                    (setq sent t)
                    (remove-hook 'cooked--refresh-hook at-prompt t)
                    (when (and (buffer-live-p buffer)
                               (buffer-local-value 'cooked--session buffer))
                      (with-current-buffer buffer
                        (cooked--send-input-string command))))))
               (at-prompt
                (lambda ()
                  ;; This hook runs inside the drain that applied the mark, which
                  ;; is still editing the buffer, so the line is sent from a timer
                  ;; once the drain has finished.
                  (when (eq cooked--semantic 'input)
                    (remove-hook 'cooked--refresh-hook at-prompt t)
                    (run-at-time 0 nil send)))))
        (add-hook 'cooked--refresh-hook at-prompt nil t)
        (run-at-time cooked-integration-hint-delay nil
                     (lambda ()
                       (when (and (buffer-live-p buffer)
                                  (not (buffer-local-value 'cooked--semantic-seen buffer)))
                         (funcall send))))))
    buffer))

(defun cooked--open-session (new command action)
  "Display a session using ACTION, starting one unless a live one may be reused.

The body `cooked' and `cooked-other-window' share; NEW and COMMAND mean what
they do there.  cooked-project.el has its own, which differs in looking for a
session already rooted at a particular directory rather than for any at all."
  (if-let* ((live (unless new (car (cooked-buffer-list)))))
      (cooked--display live action)
    (cooked-create command nil action)))

;;;###autoload
(defun cooked (&optional new command)
  "Switch to a terminal session, starting one if needed.

With a prefix argument, or NEW non-nil, always start another session rather than
reusing a live one.  COMMAND overrides `cooked-shell'."
  (interactive "P")
  (cooked--open-session new command cooked-display-action))

;;;###autoload
(defun cooked-other-window (&optional new command)
  "Like `cooked', but display the session in another window.

NEW and COMMAND mean what they do there."
  (interactive "P")
  (cooked--open-session new command cooked-other-window-action))

(provide 'cooked)
;;; cooked.el ends here
