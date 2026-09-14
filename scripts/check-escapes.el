;;; check-escapes.el --- Refuse a string escape the reader throws away  -*- lexical-binding: t; -*-

;;; Commentary:

;; A docstring that wants a quote shown literally writes two backslashes, an
;; equals sign and the quote in its source.  The reader turns the two
;; backslashes into one, and `substitute-command-keys' reads backslash-equals as
;; "the next character is literal".  Written with one backslash, the reader
;; does not know the escape, drops the backslash and keeps the equals sign, and
;; the help buffer shows it: a source docstring saying session, backslash,
;; equals, quote, s reads as "session=’s" in `describe-function'.  Nothing else
;; notices.  The byte compiler accepts the unknown escape, checkdoc reads the
;; string after the reader has eaten the backslash, and the suite never looks
;; at a help buffer.  The tree once held over four thousand of them.

;; So this gates, where check-citations.el only advises: one backslash before
;; an equals sign inside a string is never what anyone meant, so there is no
;; prose to be wrong about and no exemption to keep.  A closing quote wants a
;; plain apostrophe, since backquote, foo, apostrophe already shows as ‘foo’;
;; a quote meant literally, as in a Lisp quoted symbol, wants the backslash
;; doubled.

;;; Code:

(require 'cl-lib)

(defun cooked-escapes--check-file (file)
  "Report each string in FILE with an odd run of backslashes before `='.
Return how many there were."
  (with-temp-buffer
    (insert-file-contents file)
    (emacs-lisp-mode)
    (let ((found 0))
      (goto-char (point-min))
      (while (search-forward "\\=" nil t)
        (let* ((backslash (- (point) 2))
               (start backslash))
          (while (and (> start (point-min)) (eq (char-before start) ?\\))
            (cl-decf start))
          ;; An even run is escaped backslashes followed by a bare `=', which
          ;; is what `\\=' is meant to be.
          (when (and (cl-oddp (- (point) 1 start))
                     ;; `syntax-ppss' leaves point where it parsed to, which
                     ;; would find this same backslash again forever.
                     (nth 3 (save-excursion (syntax-ppss backslash))))
            (cl-incf found)
            (message "%s:%d: one backslash before = in a string is dropped by the reader"
                     file (line-number-at-pos backslash)))))
      found)))

(defun cooked-escapes-batch ()
  "Entry point: check every Lisp file in the tree, and exit non-zero on a find."
  (let ((found (cl-loop for file in (append (file-expand-wildcards "lisp/*.el")
                                            (file-expand-wildcards "tests/*.el")
                                            (file-expand-wildcards "scripts/*.el"))
                        sum (cooked-escapes--check-file file))))
    (message "check-escapes: %d unread escape%s" found (if (= found 1) "" "s"))
    (kill-emacs (if (zerop found) 0 1))))

(provide 'check-escapes)
;;; check-escapes.el ends here
