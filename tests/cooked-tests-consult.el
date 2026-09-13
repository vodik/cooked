;;; cooked-tests-consult.el --- the terminal picker, and what it annotates with -*- lexical-binding: t; -*-

;;; Commentary:

;; Two halves, and only the second needs consult.  The annotations are completion
;; metadata defined in cooked-mode-line.el, so their tests run everywhere and one
;; of them runs in a fresh Emacs that has never heard of consult, since "works
;; with consult unloaded" is a claim a suite that has already loaded it cannot
;; check.  Command records are built with `cooked-tests--make-command' rather than
;; driven from a shell, as in the sticky-scroll and decoration tests.
;;
;; The picker tests skip without consult and carry the `consult' tag.  None of them
;; opens a minibuffer: batch Emacs reads one from stdin, so each asks the sources
;; directly what `consult--multi' would have asked them -- the items, the preview,
;; and which source a miss is created from.

;;; Code:

(require 'cooked-tests-helpers)

(defun cooked-tests--annotation ()
  "This buffer's `cooked-buffer-annotation', without its text properties."
  (substring-no-properties (cooked-buffer-annotation (current-buffer))))

(ert-deftest cooked-annotation-says-what-a-running-a-failed-and-an-idle-session-is-doing ()
  "The three states, and the one that has no record.

A running command is read from `cooked--command-input' and the anchor, never
from `cooked--commands', which holds only what has finished -- so a session
running its second command after a failed first says `running', not `exit 2'.
A zero status is `idle' rather than `exit 0', which down a column of sessions
would be noise around the one that failed."
  (with-temp-buffer
    (cooked-mode)
    ;; Idle: nothing has run at all.
    (should (string-prefix-p "  idle" (cooked-tests--annotation)))
    ;; Idle: something ran, and it went well.
    (cooked-tests--make-command "$ " "true" "" 0)
    (should (string-prefix-p "  idle" (cooked-tests--annotation)))
    ;; Failed.
    (cooked-tests--make-command "$ " "make" "error\n" 2)
    (let ((annotation (cooked-buffer-annotation (current-buffer))))
      (should (string-prefix-p "  exit 2" annotation))
      (should (memq 'cooked-failure
                    (ensure-list (get-text-property 2 'face annotation)))))
    ;; Running, after the failure: the anchor is what says so.
    (goto-char (point-max))
    (let ((prompt (point-marker)))
      (insert "$ make  -j8\n")
      (setq cooked--command-prompt prompt
            cooked--command-start (point-marker)
            cooked--command-input "make  -j8"))
    (should (cooked--running-anchor))
    (should (string-prefix-p "  running: make -j8" (cooked-tests--annotation)))
    (should-not (string-search "exit" (cooked-tests--annotation)))
    ;; And back to failed once the anchor is gone, with no record having moved.
    (setq cooked--command-prompt nil cooked--command-start nil cooked--command-input nil)
    (should (string-prefix-p "  exit 2" (cooked-tests--annotation)))))

(ert-deftest cooked-annotation-carries-the-title-directory-and-input-mode ()
  (with-temp-buffer
    (cooked-mode)
    (setq default-directory (expand-file-name "~/"))
    (should (equal (cooked-tests--annotation) "  idle  ~/"))
    (setq cooked-title "htop" cooked--input-mode 'still)
    (should (equal (cooked-tests--annotation) "  idle  htop  ~/  still"))
    ;; A title that only repeats the running command is left out.
    (goto-char (point-max))
    (setq cooked--command-prompt (point-marker)
          cooked--command-input "htop"
          cooked--input-mode nil)
    (should (equal (cooked-tests--annotation) "  running: htop  ~/"))
    ;; A dead session says how it went and nothing about what it was doing.
    (setq cooked--exit 1 cooked--input-mode 'frozen)
    (should (equal (cooked-tests--annotation) "  exited 1  ~/"))
    ;; The whole string is dim, and the fields that carry a face keep theirs.
    (let ((annotation (cooked-buffer-annotation (current-buffer))))
      (should (equal (get-text-property 2 'face annotation)
                     '(cooked-failure completions-annotations))))))

(ert-deftest cooked-annotation-leaves-a-remote-directory-unabbreviated ()
  "Abbreviating a TRAMP name asks the far end for its home directory, and a
completion list redrawn per keystroke must not be what opens the connection."
  (with-temp-buffer
    (cooked-mode)
    (setq default-directory "/ssh:elsewhere:/home/you/")
    ;; Only the session's own name is refused: loading TRAMP to ask
    ;; `file-remote-p' abbreviates names of its own on the way in.
    (cl-letf* ((abbreviate (symbol-function 'abbreviate-file-name))
               ((symbol-function 'abbreviate-file-name)
                (lambda (name)
                  (if (string-prefix-p "/ssh:" name)
                      (error "Abbreviated %s" name)
                    (funcall abbreviate name)))))
      (should (equal (cooked-tests--annotation) "  idle  /ssh:elsewhere:/home/you/")))))

(ert-deftest cooked-annotation-is-nil-for-anything-but-a-cooked-buffer ()
  (with-temp-buffer
    (should-not (cooked-buffer-annotation (current-buffer)))
    (should-not (cooked-buffer-annotation (buffer-name)))
    (should-not (cooked-buffer-annotation "no such buffer, surely"))))

(ert-deftest cooked-completion-table-annotates-without-consult ()
  "The drawer's condition, checked where it can fail: a fresh Emacs with only
lisp/ on `load-path', so consult cannot have been loaded by anything, reading
the table's metadata the way every completion UI does."
  (let ((lisp (expand-file-name "lisp" (cooked--root))))
    (should
     (eq 0 (call-process
            (expand-file-name invocation-name invocation-directory)
            nil nil nil "-Q" "--batch" "-L" lisp
            "--eval"
            (prin1-to-string
             '(progn
                (require 'cooked-mode)
                (with-current-buffer (get-buffer-create "*cooked: short*")
                  (cooked-mode)
                  (setq cooked-title "vim"))
                (with-current-buffer (get-buffer-create "*cooked: a longer name*")
                  (cooked-mode))
                (let* ((table (cooked-buffer-completion-table))
                       (metadata (completion-metadata "" table nil))
                       (annotate (completion-metadata-get metadata 'annotation-function))
                       (affix (completion-metadata-get metadata 'affixation-function))
                       (names (all-completions "" table)))
                  (unless (and (not (featurep 'consult))
                               (eq (completion-metadata-get metadata 'category)
                                   'cooked-buffer)
                               (member "*cooked: short*" names)
                               (member "*cooked: a longer name*" names)
                               (not (member "*scratch*" names))
                               (string-search "vim" (funcall annotate "*cooked: short*"))
                               ;; Aligned: every suffix ends the same distance
                               ;; from where its candidate began.
                               (let ((ends (mapcar (lambda (row)
                                                     (+ (string-width (car row))
                                                        (string-search
                                                         "  idle" (nth 2 row))))
                                                   (funcall affix names))))
                                 (apply #'= ends)))
                    (kill-emacs 1))))))))))

;;;; The picker

(defmacro cooked-tests--with-consult-buffers (specs &rest body)
  "Run BODY with a cooked buffer per SPEC, killed afterwards.

Each SPEC is (VAR NAME DIRECTORY): VAR is bound to a buffer named NAME in
`cooked-mode', with `default-directory' DIRECTORY -- which is where OSC 7 would
have said its shell is.  No child: what is under test is which source lists a
buffer, and that is a question about the directory alone."
  (declare (indent 1))
  `(let ,(mapcar (lambda (spec)
                   `(,(car spec) (with-current-buffer (generate-new-buffer ,(nth 1 spec))
                                   (cooked-mode)
                                   (setq default-directory ,(nth 2 spec))
                                   (current-buffer))))
                 specs)
     (unwind-protect (progn ,@body)
       ,@(mapcar (lambda (spec) `(kill-buffer ,(car spec))) specs))))

(defun cooked-tests--source-items (source)
  "The buffers SOURCE lists, in order."
  (mapcar #'cdr (funcall (plist-get (symbol-value source) :items))))

(ert-deftest cooked-consult-registers-hidden-sources-behind-the-t-key ()
  :tags '(consult)
  (skip-unless (require 'consult nil t))
  (require 'cooked-consult)
  (should (memq 'cooked-consult-source-hidden consult-buffer-sources))
  (should (memq 'cooked-consult-source-project-hidden consult-project-buffer-sources))
  (dolist (source '(cooked-consult-source-hidden cooked-consult-source-project-hidden))
    (should (plist-get (symbol-value source) :hidden))
    (should (equal (plist-get (symbol-value source) :narrow) '(?t . "Terminal"))))
  ;; Requiring again, as a re-evaluated `:config' does, registers nothing twice.
  (load "cooked-consult" nil t)
  (should (= 1 (seq-count (lambda (s) (eq s 'cooked-consult-source-hidden))
                          consult-buffer-sources))))

(ert-deftest cooked-consult-splits-terminals-by-where-their-shell-is ()
  "This project's first, the rest after, and each session once.

Membership is `default-directory', which OSC 7 keeps where the shell is now,
so a session that has `cd'd out of the project has left it."
  :tags '(consult)
  (skip-unless (require 'consult nil t))
  (require 'cooked-consult)
  (let* ((root (file-name-as-directory (make-temp-file "cooked-project" t)))
         (consult-project-function (lambda (_) root)))
    (unwind-protect
        (cooked-tests--with-consult-buffers
            ((inside "*cooked: inside*" (expand-file-name "sub/" root))
             (outside "*cooked: outside*" temporary-file-directory))
          (with-temp-buffer
            (should (memq inside (cooked-tests--source-items 'cooked-consult-source-project)))
            (should-not (memq outside (cooked-tests--source-items 'cooked-consult-source-project)))
            (should (memq outside (cooked-tests--source-items 'cooked-consult-source-other)))
            (should-not (memq inside (cooked-tests--source-items 'cooked-consult-source-other)))
            (let ((all (cooked-tests--source-items 'cooked-consult-source)))
              (should (memq inside all))
              (should (memq outside all))
              (should-not (memq (current-buffer) all)))
            ;; Outside any project the project group is not enabled at all -- which
            ;; is what makes a miss start a session here rather than prompt for one.
            (let ((consult-project-function (lambda (_) nil)))
              (should-not (funcall (plist-get cooked-consult-source-project :enabled)))
              (should (memq inside (cooked-tests--source-items 'cooked-consult-source-other))))))
      (delete-directory root t))))

(ert-deftest cooked-consult-previews-a-terminal-and-puts-the-window-back ()
  :tags '(consult)
  (skip-unless (require 'consult nil t))
  (require 'cooked-consult)
  (cooked-tests--with-consult-buffers
      ((terminal "*cooked: preview*" temporary-file-directory))
    (let ((original (get-buffer-create "*cooked-test-original*")))
      (unwind-protect
          (save-window-excursion
            (switch-to-buffer original)
            (let ((state (funcall (plist-get cooked-consult-source :state))))
              (funcall state 'setup nil)
              (funcall state 'preview (buffer-name terminal))
              (should (eq (window-buffer) terminal))
              (funcall state 'preview nil)
              (should (eq (window-buffer) original))))
        (kill-buffer original)))))

(ert-deftest cooked-consult-creates-a-session-on-a-miss ()
  "A name matching nothing starts a session called that, from the source
consult picks for a miss: the project group inside a project, the other group
outside one, and whichever group a narrow key has chosen."
  :tags '(consult)
  (skip-unless (require 'consult nil t))
  (require 'cooked-consult)
  (let* ((root (file-name-as-directory (make-temp-file "cooked-project" t)))
         (consult-project-function (lambda (_) root))
         (cooked-shell "/bin/sh")
         (consult--buffer-display #'set-buffer)
         (sources (consult--multi-enabled-sources
                   '(cooked-consult-source-project cooked-consult-source-other)))
         (made nil))
    (unwind-protect
        (progn
          ;; Which source a miss goes to.
          (should (equal (plist-get (cdr (consult--multi-lookup sources "fresh" nil)) :name)
                         "Project Terminal"))
          (let ((consult--narrow ?o))
            (should (equal (plist-get (cdr (consult--multi-lookup sources "fresh" nil)) :name)
                           "Terminal")))
          ;; And what it does there.
          (let ((buffer (funcall (plist-get cooked-consult-source-project :new) "named")))
            (push buffer made)
            (should (equal (buffer-name buffer) "named"))
            (with-current-buffer buffer
              (should (derived-mode-p 'cooked-mode))
              (should cooked--session)
              (should (file-equal-p default-directory root))))
          (let ((buffer (let ((default-directory temporary-file-directory))
                          (funcall (plist-get cooked-consult-source-other :new) ""))))
            (push buffer made)
            ;; Blank is the default name, not a buffer called "".
            (should (string-prefix-p "*cooked" (buffer-name buffer)))
            (with-current-buffer buffer
              (should (file-equal-p default-directory temporary-file-directory)))))
      (dolist (buffer made)
        (with-current-buffer buffer (cooked--cleanup))
        (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest cooked-consult-with-a-prefix-is-cooked ()
  :tags '(consult)
  (skip-unless (require 'consult nil t))
  (require 'cooked-consult)
  (let (called)
    (cl-letf (((symbol-function 'cooked) (lambda (&rest args) (push (cons 'cooked args) called)))
              ((symbol-function 'cooked-other-window)
               (lambda (&rest args) (push (cons 'cooked-other-window args) called)))
              ((symbol-function 'consult--multi) (lambda (&rest _) (error "Picker opened"))))
      (consult-cooked '(4))
      (consult-cooked-other-window '(4)))
    (should (equal called '((cooked-other-window (4)) (cooked (4)))))))

(provide 'cooked-tests-consult)
;;; cooked-tests-consult.el ends here
