;;; cooked-tests-eshell.el --- eshell's visual commands, run in cooked -*- lexical-binding: t; -*-

;;; Commentary:

;; Through a real eshell buffer and `eshell-send-input', because the claim is
;; about eshell's own dispatch: a command eshell decides is visual reaches
;; cooked, and nothing about how it decides has been replaced.

;;; Code:

(require 'cooked-tests-helpers)
(require 'cooked-eshell)
(require 'eshell)
(require 'esh-mode)
(require 'em-term)
(require 'em-hist)
(require 'em-dirs)

(ert-deftest cooked-eshell-runs-a-visual-command-in-cooked ()
  "With the mode on, a command in `eshell-visual-commands' typed at an eshell
prompt opens a cooked buffer named after the program, in the selected window,
running that program with the arguments eshell parsed.  With the mode off it is
`term-mode' again."
  :tags '(pty)
  (let* ((directory (make-temp-file "cooked-tests-eshell" t))
         (eshell-directory-name directory)
         (eshell-history-file-name nil)
         (eshell-last-dir-ring-file-name nil)
         (eshell-visual-commands '("sh"))
         (eshell-destroy-buffer-when-process-dies t)
         (cooked-debug t)
         (before (buffer-list))
         eshell)
    (unwind-protect
        (progn
          (cooked-eshell-visual-command-mode 1)
          (delete-other-windows)
          (setq eshell (eshell t))
          (with-current-buffer eshell
            (goto-char (point-max))
            (insert "sh -c 'printf visual-%s $((6 * 7)); exec sleep 5'")
            (eshell-send-input))
          (let ((buffer (window-buffer (selected-window))))
            (should (eq (buffer-local-value 'major-mode buffer) 'cooked-mode))
            (should (equal (buffer-name buffer) "*sh*"))
            (should (eq (buffer-local-value 'eshell-parent-buffer buffer) eshell))
            (should (eq (buffer-local-value 'cooked-kill-buffer-on-exit buffer) 'on-success))
            (with-current-buffer buffer
              (should (cooked-tests--settle
                       (lambda ()
                         (save-excursion
                           (goto-char (point-min))
                           (search-forward "visual-42" nil t)))))))
          (cooked-eshell-visual-command-mode -1)
          (should-not (advice-member-p #'cooked-eshell--exec-visual 'eshell-exec-visual)))
      (cooked-eshell-visual-command-mode -1)
      (dolist (buffer (buffer-list))
        (unless (memq buffer before)
          (with-current-buffer buffer
            (when (derived-mode-p 'cooked-mode) (cooked--cleanup)))
          (let ((kill-buffer-query-functions nil))
            (kill-buffer buffer))))
      (delete-directory directory t))))

(provide 'cooked-tests-eshell)
;;; cooked-tests-eshell.el ends here
