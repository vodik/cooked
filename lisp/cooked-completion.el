;;; cooked-completion.el --- completion for cooked terminals -*- lexical-binding: t; -*-

;;; Commentary:

;; TAB at a cooked prompt is `completion-at-point', so corfu, cape, consult and
;; friends work here exactly as they do anywhere else.  This file is what answers
;; them by default: programs on PATH for the first word, file names after it.
;; Honest, and entirely ignorant of what you are actually completing.
;;
;; The shell's own completion system -- zsh's compsys, run in the very shell you
;; are typing at, so `git checkout <TAB>' offers branches and `ssh <TAB>' offers
;; hosts -- is a layer you load on purpose:
;;
;;   (require 'cooked-shell-completion)
;;
;; It announces itself by setting `cooked-shell-completion-function' below, which
;; is the only thing this file knows about it.  Unloaded, that variable is nil and
;; the Emacs table here is the whole of completion; loaded, it is asked first and
;; this answers when it cannot.  See `cooked-shell-completion.el' for what that
;; costs and why it is not the default.

;;; Code:

(require 'cooked)

(defgroup cooked-completion nil
  "Completing at a cooked prompt."
  :group 'cooked)

(defvar cooked-shell-completion-function nil
  "Function asking the child's own completion system, or nil for none.

Called with the pending input's region as (START . END) and returning a
`completion-at-point-functions' answer, or nil when the shell cannot help
-- no integration, no answer in time, no candidates -- in which case the
Emacs table here answers instead.

Nil means the layer is not loaded.  `cooked-shell-completion' sets it, and
requiring that file is how you opt in; the point of the split is that
asking a shell to complete costs a blocking round trip and a `compadd'
shadow in that shell for the life of the session, so it is something you
choose rather than something you inherit.  This is also the flag
`cooked--shell-invocation' reads when it decides whether to tell the child
to install its half at all, which is why turning the layer on mid-session
reaches Emacs at once but the shell only at its next start.")

;;;; The native table

(defvar cooked--executables nil "Cached PATH lookup, see `cooked--executable-table'.")

(defun cooked--executable-table ()
  "Names of programs on PATH, cached for the session."
  (or cooked--executables
      (setq cooked--executables
            (delete-dups
             (mapcan (lambda (dir)
                       (when (file-accessible-directory-p dir)
                         (ignore-errors (directory-files dir nil "\\`[^.]" t))))
                     exec-path)))))

(defun cooked-flush-executables ()
  "Forget the cached list of programs on PATH."
  (interactive)
  (setq cooked--executables nil))

(defun cooked--completion-bounds ()
  "Bounds of the word before point, clamped to the pending input."
  (let ((limit (cooked--input-start-position)))
    (save-excursion
      (let ((end (point)))
        (skip-chars-backward "^ \t" limit)
        (cons (point) end)))))

(defun cooked--native-completion ()
  "Completion in Emacs: a program name first, file names after it.

Nil when there is no pending input to complete.  `cooked-completion-at-point'
has already established that there was one, but the shell layer blocks between
that check and this call, and a drain arriving in the meantime can end the
prompt -- at which point the word before point is screen text and not a command
line at all."
  (when-let* ((limit (cooked--input-start-position)))
    (pcase-let* ((`(,start . ,end) (cooked--completion-bounds))
                 ;; The first word of the line is the command; everything after it
                 ;; is an argument, and arguments are file names far more often
                 ;; than not.
                 (first-word (eql start limit)))
      (list start end
            (if first-word
                (completion-table-in-turn (cooked--executable-table)
                                          #'completion-file-name-table)
              #'completion-file-name-table)
            :exclusive 'no
            :annotation-function (lambda (_) (when first-word " program"))))))

(defun cooked-completion-at-point ()
  "Complete the pending input.

From the shell where its layer is loaded and can answer, and from Emacs
otherwise.  The two are tried in that order rather than merged: the shell
knows what the command it is completing actually takes, and Emacs knows
only that a word is a word."
  (when-let* (((cooked--input-state-p))
              (region (cooked--input-region))
              ((>= (point) (car region))))
    (or (and cooked-shell-completion-function
             (funcall cooked-shell-completion-function region))
        (cooked--native-completion))))

(provide 'cooked-completion)
;;; cooked-completion.el ends here
