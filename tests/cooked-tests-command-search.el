;;; cooked-tests-command-search.el --- the transcript's commands, searched -*- lexical-binding: t; -*-

;;; Commentary:

;; `cooked-command-search.el' is an optional layer.  Most of what it does is
;; presentation over `cooked--commands', so most of these start from records
;; built by hand with `cooked-tests--make-command', the way the decoration and
;; menu tests do.  The two that are about a command *running* drive a real zsh,
;; because the claims they check -- that the finished record is built on the
;; very marker the running candidate held, and that the pick leaves point
;; following output that arrives afterwards -- are claims about the drain, and
;; a hand-built buffer would only be asserting what the test put in it.

;;; Code:

(require 'ert)
(require 'cooked-tests-helpers)
(require 'cooked-command-search)

(defmacro cooked-tests--with-cooked-buffers (names &rest body)
  "Run BODY with each of NAMES bound to a fresh `cooked-mode' buffer.

Real buffers rather than `with-temp-buffer', because the search walks
`buffer-list' and what is under test is that it finds more than the one it was
called from."
  (declare (indent 1))
  `(let ,(mapcar (lambda (name)
                   `(,name (with-current-buffer
                               (generate-new-buffer ,(format "*cooked-%s*" name))
                             (cooked-mode)
                             (current-buffer))))
                 names)
     (unwind-protect
         (progn ,@body)
       ,@(mapcar (lambda (name) `(kill-buffer ,name)) names))))

(defun cooked-tests--pick (name)
  "A `completing-read' that picks the candidate whose name starts with NAME."
  (lambda (_prompt table &rest _)
    (or (seq-find (lambda (candidate) (string-prefix-p name candidate))
                  (all-completions "" table))
        (error "No candidate named %s" name))))

(ert-deftest cooked-command-search-narrows-to-failures-across-buffers ()
  "\"Where did the build break\" is the everyday case, and the build is not
necessarily in the buffer you are in.

Failed-only keeps the failures from both buffers and nothing else, each grouped
under its own buffer, annotated with the exit status rather than coloured
only -- and the one picked is jumped to at its prompt, in its buffer."
  (cooked-tests--with-cooked-buffers (one two)
    (with-current-buffer one
      (cooked-tests--make-command "$ " "make" "ok\n" 0)
      (cooked-tests--make-command "$ " "make test" "boom\nmore\n" 2))
    (with-current-buffer two
      (cooked-tests--make-command "$ " "cargo build" "error[E0308]\n" 101)
      (cooked-tests--make-command "$ " "ls" "a\n" 0))
    (let* ((candidates (cooked-command-search--candidates 'failed))
           (table (cooked-command-search--table candidates))
           (metadata (completion-metadata "" table nil))
           (group (completion-metadata-get metadata 'group-function))
           (annotate (completion-metadata-get metadata 'annotation-function)))
      (should (equal (sort (mapcar #'substring-no-properties candidates) #'string<)
                     '("cargo build" "make test")))
      (should (equal (funcall group "make test" nil) (buffer-name one)))
      (should (equal (funcall group "cargo build" nil) (buffer-name two)))
      (should (string-search "exit 2" (funcall annotate "make test")))
      (should (string-search "2 lines" (funcall annotate "make test")))
      (should (string-search "exit 101" (funcall annotate "cargo build")))
      ;; The unfiltered list has all four, so the narrowing did the dropping.
      (should (= 4 (length (cooked-command-search--candidates)))))
    (cl-letf (((symbol-function 'completing-read) (cooked-tests--pick "cargo")))
      (cooked-command-search 'failed))
    (should (eq (current-buffer) two))
    (should (looking-at-p "\\$ cargo build"))))

(ert-deftest cooked-command-search-finds-a-multiline-loop-and-reruns-it-verbatim ()
  "Whitespace is collapsed for the name and for nothing else.

A word from the second line of a `for' loop matches, under an ordinary
completion style, because the collapsed name is exactly what is matched and
exactly what is shown.  Copying and rerunning send `cooked-command-input' --
newlines, indentation, the quoting -- and not the display form."
  (cooked-tests--with-cooked-buffers (loop)
    (let ((input "for f in *.log; do\n  gzip \"$f\"\ndone"))
      (with-current-buffer loop
        (cooked-tests--make-command "$ " "true" "" 0)
        (cooked-tests--make-command "$ " input "" 0))
      (let* ((candidates (cooked-command-search--candidates))
             (table (cooked-command-search--table candidates))
             (completion-styles '(substring)))
        ;; The tail of that list is a base size rather than nil.
        (let ((matches (completion-all-completions "gzip" table nil 4)))
          (setcdr (last matches) nil)
          (should (equal (mapcar #'substring-no-properties matches)
                         '("for f in *.log; do gzip \"$f\" done")))))
      (let (sent)
        (cl-letf (((symbol-function 'completing-read) (cooked-tests--pick "for f"))
                  ((symbol-function 'read-multiple-choice)
                   (lambda (_prompt choices &rest _)
                     (or (assq ?r choices) (error "No rerun offered"))))
                  ((symbol-function 'cooked--input-state-p) (lambda () t))
                  ((symbol-function 'cooked--pending-input) (lambda () ""))
                  ((symbol-function 'cooked--send-input-string)
                   (lambda (text) (push text sent))))
          (cooked-command-search-act))
        (should (equal sent (list input))))
      (cl-letf (((symbol-function 'completing-read) (cooked-tests--pick "for f")))
        (cooked-command-search-do (cooked-command-search-read) 'copy-input))
      (should (equal (current-kill 0) input)))))

(ert-deftest cooked-command-search-names-an-unreported-command-by-its-prompt-line ()
  "Nil `input' falls back to the prompt line, through the same function the
`imenu' index names it with -- so the two cannot come to disagree."
  (cooked-tests--with-cooked-buffers (bare)
    (with-current-buffer bare
      (goto-char (point-max))
      (let ((prompt (point-marker)))
        (insert "$ typed-without-cooked\n")
        (let ((start (point-marker)))
          (insert "output\n")
          (push (cooked--command-make :start start :end (point-marker) :code 0
                                      :input nil :prompt prompt)
                cooked--commands)))
      (should (equal (mapcar #'substring-no-properties
                             (cooked-command-search--candidates))
                     '("$ typed-without-cooked")))
      (should (equal (mapcar #'car (cooked--imenu-index))
                     '("$ typed-without-cooked"))))))

(ert-deftest cooked-command-search-offers-no-record-verb-for-a-running-command ()
  "The running candidate is its own type, so the verbs written for records are
refused for it by name rather than handed a half-built record reading exit 0."
  (cooked-tests--with-cooked-buffers (busy)
    (with-current-buffer busy
      (goto-char (point-max))
      (setq cooked--command-prompt (point-marker))
      (insert "$ python -m http.server\n")
      (setq cooked--command-start (point-marker)
            cooked--command-input "python -m http.server"
            cooked--command-started-at (- (float-time) 125))
      (insert "Serving HTTP on 0.0.0.0 port 8000\n"))
    (let* ((candidates (cooked-command-search--candidates 'running))
           (candidate (cooked-command-search--lookup
                       "python -m http.server" (cooked-command-search--index candidates)))
           (annotate (completion-metadata-get
                      (completion-metadata "" (cooked-command-search--table candidates) nil)
                      'annotation-function)))
      (should (cooked-command-search--running-p candidate))
      (should-not (cooked-command-p candidate))
      (should (string-search "running 2m 5s" (funcall annotate "python -m http.server")))
      (should-not (string-search "exit" (funcall annotate "python -m http.server")))
      (should-error (cooked-command-search-do candidate 'rerun) :type 'user-error)
      (should-error (cooked-command-search-do candidate 'copy-output) :type 'user-error)
      ;; Nothing that has finished is running.
      (should-not (cooked-command-search--candidates 'failed))
      ;; And nothing is running in a session that has exited, whatever its
      ;; buffer-locals were left saying.
      (with-current-buffer busy (setq cooked--exit 0))
      (should-not (cooked-command-search--candidates 'running)))))

(ert-deftest cooked-command-search-follows-a-running-command-in-a-hidden-buffer ()
  "The server left running in some buffer, found again and read from its tail.

The buffer is not on display when the search starts.  The running narrow finds
it, sorted ahead of the finished command beside it; the pick puts it in the
selected window with point on the child's cursor; and output that arrives
*afterwards* still carries point along, which is what following means and what
landing on the prompt, as a finished command does, would not do."
  :tags '(zsh pty)
  (skip-unless (executable-find "zsh"))
  (let ((elsewhere (get-buffer-create "*cooked-elsewhere*")))
    (unwind-protect
        (cooked-tests--with-zsh
          (let ((server (current-buffer)))
            (cooked--send-input-string "true")
            (should (cooked-tests--settle (lambda () cooked--commands) 8))
            (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input)) 8))
            (cooked--send-input-string
             "printf 'serving\\n'; read -r _; printf 'request\\n'; sleep 30")
            (should (cooked-tests--settle
                     (lambda () (and (cooked--running-anchor)
                                     (string-search "serving" (cooked-tests--text))))
                     8))
            (set-window-buffer (selected-window) elsewhere)
            (set-buffer elsewhere)
            (should-not (get-buffer-window server))
            ;; Running first in the unfiltered list, ahead of the newer-numbered
            ;; but finished `true'.
            (should (string-prefix-p "printf"
                                     (car (cooked-command-search--candidates))))
            (cl-letf (((symbol-function 'completing-read) (cooked-tests--pick "printf")))
              (cooked-command-search 'running))
            (should (eq (window-buffer (selected-window)) server))
            (should (eq (current-buffer) server))
            (should (= (point) (cooked--point-after-input)))
            (should (cooked--follow-p))
            ;; More output, after the pick: point goes with it.
            (cooked--send-to-child "\r")
            (should (cooked-tests--settle
                     (lambda () (string-search "request" (cooked-tests--text))) 8))
            (should (> (point) (save-excursion
                                 (goto-char (point-min))
                                 (search-forward "request"))))
            (should (= (point) (cooked--point-after-input)))
            (cooked-interrupt)))
      (kill-buffer elsewhere))))

(ert-deftest cooked-command-search-resolves-a-command-that-finished-mid-pick ()
  "Listed running, picked finished: the candidate resolves to its record.

The finish happens inside `completing-read', which is where it happens for a
user.  The record found is the one `cooked--mark-command-end' built on the very
marker the running candidate held -- so jumping lands on *that* command's
prompt, and interrupting it is refused as what it now is, a finished command."
  :tags '(zsh pty)
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-zsh
    (cooked--send-input-string "sleep 1; printf 'finished\\n'")
    (should (cooked-tests--settle #'cooked--running-anchor 8))
    (let* (listed
           (candidate
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (_prompt table &rest _)
                         (setq listed (all-completions "" table))
                         (should (cooked-tests--settle (lambda () cooked--commands) 8))
                         (car listed))))
              (cooked-command-search-read 'running))))
      (should (equal listed '("sleep 1; printf 'finished\\n'")))
      (should (cooked-command-search--running-p candidate))
      (should-not (cooked--running-anchor))
      (let ((resolved (cooked-command-search--resolve candidate)))
        (should (cooked-command-search--finished-p resolved))
        (should (eq (cooked-command-search--finished-command resolved)
                    (car cooked--commands))))
      (should-error (cooked-command-search-do candidate 'interrupt) :type 'user-error)
      (cooked-command-search-do candidate 'jump)
      (should (= (point) (cooked--command-prompt-position (car cooked--commands)))))))

(ert-deftest cooked-command-search-finds-the-oldest-of-5000-commands ()
  "5000 records, and the pick at the far end of the list is still the one found.

The oldest is the last candidate, so a lookup that went wrong on a large list
would show here first."
  (cooked-tests--with-cooked-buffers (many)
    (with-current-buffer many
      (dotimes (i 5000)
        (cooked-tests--make-command "$ " (format "make target-%d" i) "ok\n" (% i 3))))
    (should (= 5000 (length (cooked-command-search--candidates))))
    (should (= 1667 (length (cooked-command-search--candidates 'succeeded))))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt table &rest _)
                 (should (string-search
                          "exit 0" (funcall (completion-metadata-get
                                             (completion-metadata "" table nil)
                                             'annotation-function)
                                            "make target-0")))
                 "make target-0")))
      (cooked-command-search))
    (should (eq (current-buffer) many))
    (should (looking-at-p "\\$ make target-0$"))))

(ert-deftest cooked-command-search-groups-20000-candidates-without-walking-the-list ()
  "A completion refresh asks for every candidate's group, so lookup must be cheap.

vertico groups by calling the group function on each candidate, and each call
looks the candidate up by name.  With that lookup a `member' over the list, the
refresh was quadratic: 80ms over 5000 commands and 1.2s over 20000 on an idle
machine.  Through the index it is 4ms and 17ms.  20000 rather than 5000 because
that is where the two are far enough apart for a wall-clock bound to tell them
apart on a loaded machine: the bound is some fifteen times the indexed cost and
a quarter of the walked one.  The candidates are built directly rather than from
records, since 20000 records take half a minute to insert and the lookup never
reads past the candidate object."
  (cooked-tests--with-cooked-buffers (many)
    (let* ((candidates
            (cl-loop for i below 20000
                     collect (propertize (format "make target-%d" i)
                                         'cooked-command-search
                                         (cooked-command-search--finished-make
                                          :buffer many))))
           (group (completion-metadata-get
                   (completion-metadata "" (cooked-command-search--table candidates) nil)
                   'group-function))
           (names (mapcar #'substring-no-properties candidates))
           (start (float-time))
           (groups (mapcar (lambda (name) (funcall group name nil)) names))
           (elapsed (- (float-time) start)))
      (should (seq-every-p (lambda (g) (equal g (buffer-name many))) groups))
      (should (< elapsed 0.3)))))

(provide 'cooked-tests-command-search)
;;; cooked-tests-command-search.el ends here
