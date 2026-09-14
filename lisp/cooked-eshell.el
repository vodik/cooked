;;; cooked-eshell.el --- Eshell's visual commands, run in cooked -*- lexical-binding: t; -*-

;;; Commentary:

;; Opt-in:
;;
;;   (use-package cooked
;;     :commands (cooked cooked-other-window)
;;     :config
;;     (require 'cooked-eshell)
;;     (cooked-eshell-visual-command-mode))
;;
;; Eshell cannot run a full-screen program itself, so it hands the ones named in
;; `eshell-visual-commands', `eshell-visual-subcommands' and
;; `eshell-visual-options' -- vim, htop, less, "git log" if you add it -- to
;; `eshell-exec-visual', which starts them in a `term-mode' buffer.  With
;; `cooked-eshell-visual-command-mode' on, that function starts them in a cooked
;; buffer instead, named after the program as eshell names it, "*htop*".
;;
;; eat offers two ways to do this, and this file takes the smaller.
;; `eat-eshell-visual-command-mode' replaces `eshell-exec-visual' the same way
;; this does, and ghostel-eshell.el does too.  `eat-eshell-mode' instead puts a
;; terminal inside the eshell buffer and runs every command's output through it.
;; That second shape does not fit cooked at all: a cooked buffer is one terminal
;; from its first line to its last, its scrollback is the buffer's text above the
;; live screen, and the input model decides who owns the keyboard from the
;; child's termios and OSC 133 marks.  An eshell buffer is eshell's, with a prompt
;; and an input line eshell owns, and splicing a screen into the middle of it
;; would mean a second renderer.  Replacing one function costs one advice.
;;
;; The program runs as its own argv, through `cooked-create', so it gets the
;; directory eshell is in and nothing else from eshell: no shell integration and
;; no startup files, which is what `term-mode' gives it too.  When
;; `eshell-destroy-buffer-when-process-dies' is set the buffer is killed once the
;; program exits with status 0, the rule `eshell-term-sentinel' applies, and
;; otherwise it is kept with its "[exited N]" line.

;;; Code:

(require 'cooked)

(defvar eshell-interpreter-alist)
(defvar eshell-destroy-buffer-when-process-dies)
(defvar eshell-parent-buffer)
(declare-function eshell-find-interpreter "esh-ext" (file args &optional no-examine-p))
(declare-function eshell-stringify-list "esh-util" (args))
(declare-function eshell-exec-visual "em-term" (&rest args))

(defun cooked-eshell--exec-visual (&rest args)
  "Run the program and arguments in ARGS in a new cooked buffer, and show it.

The `:override' advice on `eshell-exec-visual', and resolves the program the
way that function does: `eshell-find-interpreter' with eshell's interpreter
table bound to nil, so a visual command is not handed straight back here, and
with a script's interpreter put in front of it.  So \"htop -d 5\" runs
\(\"/usr/bin/htop\" \"-d\" \"5\").

Returns nil, as `eshell-exec-visual' does, which is eshell's cue that the
command produced no output of its own for the eshell buffer."
  (require 'esh-ext)
  (require 'esh-util)
  (let* ((eshell-interpreter-alist nil)
         (interpreter (eshell-find-interpreter (car args) (cdr args)))
         (program (car interpreter))
         (argv (cons program
                     (flatten-tree
                      (eshell-stringify-list
                       (append (cdr interpreter) (cdr args))))))
         (parent (current-buffer))
         (buffer (cooked-create argv default-directory
                                '(display-buffer-same-window))))
    (with-current-buffer buffer
      (rename-buffer (generate-new-buffer-name
                      (concat "*" (file-name-nondirectory program) "*")))
      ;; The name says which program this is, and eshell users find the buffer
      ;; by it; a title the program sets must not rename it away.
      (setq-local cooked-buffer-name-auto-update nil)
      (setq-local eshell-parent-buffer parent)
      (when eshell-destroy-buffer-when-process-dies
        (setq-local cooked-kill-buffer-on-exit 'on-success)))
    nil))

;;;###autoload
(define-minor-mode cooked-eshell-visual-command-mode
  "Run eshell's visual commands, such as vim, htop and less, in cooked buffers.

When on, `eshell-exec-visual' starts the program in a new cooked buffer shown
in the selected window, where `term-mode' would have been used.  The commands
that count as visual are still the ones `eshell-visual-commands',
`eshell-visual-subcommands' and `eshell-visual-options' name."
  :global t
  :group 'cooked
  (if cooked-eshell-visual-command-mode
      (advice-add 'eshell-exec-visual :override #'cooked-eshell--exec-visual)
    (advice-remove 'eshell-exec-visual #'cooked-eshell--exec-visual)))

(provide 'cooked-eshell)
;;; cooked-eshell.el ends here
