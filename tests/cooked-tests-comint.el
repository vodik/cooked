;;; cooked-tests-comint.el --- the VT filter on somebody else's comint buffer -*- lexical-binding: t; -*-

;;; Commentary:

;; Through `comint-output-filter' with a real comint buffer, because that is the claim:
;; the consumer is not adapted.  What these assert on is the text and the properties
;; comint ended up with, never what the filter returned -- a filter that returned the
;; right string and left the buffer wrong would pass the second kind of test and fail
;; the user.
;;
;; The process is a pipe process that carries nothing, so a test says exactly which
;; bytes arrive in exactly which chunks.  A child on a pty would say the same things
;; eventually and would say them at times nobody can write an assertion against; the
;; chunk boundaries are half the subject here, since resuming across one is the whole
;; argument for a parser over a regexp.

;;; Code:

(require 'ert)
(require 'comint)
(require 'cooked-tests-helpers)
(require 'cooked-comint)

(defvar cooked-tests-comint--proc nil
  "The pipe process standing in for a child in the buffer under test.")

(defmacro cooked-tests-comint--with (&rest body)
  "Run BODY in a comint buffer under `cooked-comint-mode'."
  (declare (indent 0) (debug body))
  `(let ((buffer (generate-new-buffer " *cooked-comint-test*")))
     (unwind-protect
         (with-current-buffer buffer
           (comint-mode)
           ;; A test that says Password: would otherwise have comint queue a
           ;; `read-passwd' of its own, from a timer that outlives the buffer;
           ;; see the guard in `cooked-tests-helpers.el'.  The list is
           ;; comint's global one, so it is copied without the watcher rather
           ;; than removed from, which would change it for every buffer.
           (setq-local comint-output-filter-functions
                       (remq #'comint-watch-for-password-prompt
                             comint-output-filter-functions))
           (setq cooked-tests-comint--proc
                 (make-pipe-process :name "cooked-comint-test" :buffer buffer
                                    :noquery t :filter #'ignore))
           (set-marker (process-mark cooked-tests-comint--proc) (point-max))
           (cooked-comint-mode 1)
           ,@body)
       (when (process-live-p cooked-tests-comint--proc)
         (delete-process cooked-tests-comint--proc))
       (kill-buffer buffer))))

(defun cooked-tests-comint--say (string)
  "Deliver STRING as one chunk of the child's output."
  (comint-output-filter cooked-tests-comint--proc string))

(defun cooked-tests-comint--type (string)
  "Put STRING in the buffer the way `comint-send-input' does.

Not by calling it: this process has nobody at the far end to send to.  What
matters to the filter is only the buffer half of what comint does -- the input
is inserted at the process mark and the mark is moved past it -- which is
precisely what makes the text the filter emitted for the open line stop being
the last thing in the buffer."
  (goto-char (process-mark cooked-tests-comint--proc))
  (insert string)
  (set-marker (process-mark cooked-tests-comint--proc) (point)))

(defun cooked-tests-comint--text ()
  "The buffer's text, without properties."
  (buffer-substring-no-properties (point-min) (point-max)))

;;;; What the control characters meant

(ert-deftest cooked-comint-resolves-a-carriage-return-by-overwriting ()
  ;; The example in cooked-process.el's commentary, and the one comint gets wrong:
  ;; `comint-carriage-motion' would leave "XYZ" here, having deleted to the start of
  ;; the line instead of moving the cursor to it.
  (cooked-tests-comint--with
    (cooked-tests-comint--say "abcdefghij\rXYZ\n")
    (should (equal (cooked-tests-comint--text) "XYZdefghij\n"))))

(ert-deftest cooked-comint-resolves-a-backspace-by-rubbing-out ()
  (cooked-tests-comint--with
    (cooked-tests-comint--say "abc\b\b\bXY\n")
    (should (equal (cooked-tests-comint--text) "XYc\n"))))

(ert-deftest cooked-comint-resolves-an-erase-to-end-of-line ()
  ;; The sequence `ansi-color' drops on the floor, and the one that tells "the child
  ;; erased the line and reprinted it" from "the child rewrote part of it".
  (cooked-tests-comint--with
    (cooked-tests-comint--say "abcdefghij\rXYZ\e[K\n")
    (should (equal (cooked-tests-comint--text) "XYZ\n"))))

(ert-deftest cooked-comint-turns-crlf-into-one-line ()
  (cooked-tests-comint--with
    (cooked-tests-comint--say "one\r\ntwo\r\n")
    (should (equal (cooked-tests-comint--text) "one\ntwo\n"))))

(ert-deftest cooked-comint-redraws-a-progress-bar-in-place ()
  ;; Three chunks, each rewriting the line the last one wrote: the buffer holds one
  ;; line throughout and the final state is the last frame plus what followed it.
  (cooked-tests-comint--with
    (cooked-tests-comint--say "[#     ] 10%")
    (should (equal (cooked-tests-comint--text) "[#     ] 10%"))
    (cooked-tests-comint--say "\r[###   ] 42%")
    (should (equal (cooked-tests-comint--text) "[###   ] 42%"))
    (cooked-tests-comint--say "\r[######] 100%\ndone\n")
    (should (equal (cooked-tests-comint--text) "[######] 100%\ndone\n"))))

(ert-deftest cooked-comint-shows-an-unterminated-prompt-immediately ()
  ;; The reason this is not `cooked-process.el''s grid: nothing waits for a row to
  ;; scroll off anything.
  (cooked-tests-comint--with
    (cooked-tests-comint--say "Password: ")
    (should (equal (cooked-tests-comint--text) "Password: "))))

;;;; Chunk boundaries

(ert-deftest cooked-comint-resumes-an-escape-sequence-across-chunks ()
  ;; The whole argument for a parser rather than a regexp: a read can end anywhere.
  (cooked-tests-comint--with
    (cooked-tests-comint--say "\e[3")
    (should (equal (cooked-tests-comint--text) ""))
    (cooked-tests-comint--say "1mred\n")
    (should (equal (cooked-tests-comint--text) "red\n"))
    (should (equal (get-text-property 0 'face (cooked-tests-comint--text))
                   nil))))

(ert-deftest cooked-comint-carries-a-rendition-across-chunks ()
  (cooked-tests-comint--with
    (cooked-tests-comint--say "\e[31m")
    (cooked-tests-comint--say "red\n")
    (should (equal (get-text-property (point-min) 'face)
                   (cooked--face 1 nil 0)))))

(ert-deftest cooked-comint-resolves-a-carriage-return-across-chunks ()
  ;; The overwrite has to reach text comint has already inserted, which is what the
  ;; retraction is for.
  (cooked-tests-comint--with
    (cooked-tests-comint--say "abcdefghij")
    (cooked-tests-comint--say "\rXYZ\n")
    (should (equal (cooked-tests-comint--text) "XYZdefghij\n"))))

;;;; The open line

(ert-deftest cooked-comint-reads-the-open-line-off-the-end-of-a-chunk ()
  (should (equal (cooked-comint--tail "") '("" . nil)))
  (should (equal (cooked-comint--tail "$ ") '("$ " . nil)))
  (should (equal (cooked-comint--tail "one\n") '("" . t)))
  (should (equal (cooked-comint--tail "one\ntwo\n$ ") '("$ " . t))))

(ert-deftest cooked-comint-finds-the-open-line-after-a-long-one-in-linear-time ()
  ;; A regexp for the characters before the end of the string is tried again from
  ;; every position of a line that turns out to end in a newline, so a long line
  ;; followed by a prompt costs the square of its length: over a second for this one.
  ;; The bound is loose enough that only that shape can miss it.
  (let* ((text (concat (make-string 20000 ?x) "\n$ "))
         (started (float-time)))
    (should (equal (cooked-comint--tail text) '("$ " . t)))
    (should (< (- (float-time) started) (cooked-tests-timeout 0.25)))))

;;;; Where the buffer stops being ours

(ert-deftest cooked-comint-does-not-repeat-a-prompt-the-user-typed-after ()
  ;; The ordinary shape of every command in `M-x shell': the prompt is an open line,
  ;; comint inserts the input after it, and the child then ends that same line with a
  ;; `\r\n' of its own.  Re-sending the prompt to close the line would double it.
  (cooked-tests-comint--with
    (cooked-tests-comint--say "$ ")
    (cooked-tests-comint--type "ls\n")
    (cooked-tests-comint--say "\r\nfile\n$ ")
    (should (equal (cooked-tests-comint--text) "$ ls\n\nfile\n$ "))))

(ert-deftest cooked-comint-never-deletes-text-it-did-not-write ()
  ;; The check that makes the retraction safe.  Here the child *does* rewrite its open
  ;; line, but the user's input is in the way, so nothing before the process mark may
  ;; be touched -- and in particular the user's own text must survive intact.  The
  ;; rewrite is not lost either: it lands after the input, where the child's output
  ;; now begins.
  (cooked-tests-comint--with
    (cooked-tests-comint--say "$ ")
    (cooked-tests-comint--type "typed by the user")
    (cooked-tests-comint--say "\rZZ\n")
    (should (equal (cooked-tests-comint--text) "$ typed by the userZZ\n"))))

(ert-deftest cooked-comint-draws-a-progress-bar-that-follows-a-prompt ()
  ;; What every command run from `M-x shell' looks like to the filter.  The pty does not
  ;; echo, so the child never ends the prompt's line; comint does, with the input.  A
  ;; bar that starts with a carriage return is the command's output and not a rewrite
  ;; of the prompt, and each of its frames has to replace the last.  This used to show
  ;; "wnloading 10%" and then stop, the prompt's two columns taken off the front.
  (cooked-tests-comint--with
    (cooked-tests-comint--say "$ ")
    (cooked-tests-comint--type "pip install x\n")
    (cooked-tests-comint--say "\rDownloading 10%")
    (should (equal (cooked-tests-comint--text) "$ pip install x\nDownloading 10%"))
    (cooked-tests-comint--say "\rDownloading 42%")
    (cooked-tests-comint--say "\rDownloading 100%\n$ ")
    (should (equal (cooked-tests-comint--text)
                   "$ pip install x\nDownloading 100%\n$ "))))

;;;; Colours

(ert-deftest cooked-comint-sets-both-face-and-font-lock-face ()
  ;; Neither alone covers both consumers; `cooked-process--text' argues it out.  The
  ;; pair must be the same object, not merely equal faces, so one lookup answers both.
  (cooked-tests-comint--with
    (cooked-tests-comint--say "plain\e[31mred\e[0m\n")
    (let* ((at (+ (point-min) 5))
           (face (get-text-property at 'face)))
      (should face)
      (should (eq face (get-text-property at 'font-lock-face)))
      (should (equal face (cooked--face 1 nil 0)))
      ;; And the text around it carries neither.
      (should-not (get-text-property (point-min) 'face))
      (should-not (get-text-property (point-min) 'font-lock-face)))))

(ert-deftest cooked-comint-colours-what-an-overwrite-left-behind ()
  ;; A rewrite in a second colour leaves the tail of the line in the first, which is
  ;; the thing a filter without cells cannot get right.
  (cooked-tests-comint--with
    (cooked-tests-comint--say "\e[31mabcdef\r\e[32mXY\n")
    (should (equal (cooked-tests-comint--text) "XYcdef\n"))
    (should (equal (get-text-property (point-min) 'face) (cooked--face 2 nil 0)))
    (should (equal (get-text-property (+ (point-min) 2) 'face)
                   (cooked--face 1 nil 0)))))

(ert-deftest cooked-comint-leaves-the-newline-unstyled ()
  ;; A background on a newline paints to the window's edge.
  (cooked-tests-comint--with
    (cooked-tests-comint--say "\e[41mred\n")
    (should (get-text-property (point-min) 'face))
    (should-not (get-text-property (- (point-max) 1) 'face))))

;;;; The sequences that reach Lisp

(ert-deftest cooked-comint-hangs-a-hyperlinks-destination-on-its-text ()
  ;; The URI itself rather than an id: an id resolves through a session's table, and
  ;; there is no session here.
  (cooked-tests-comint--with
    (cooked-tests-comint--say "see \e]8;;https://example.com\e\\here\e]8;;\e\\ ok\n")
    (should (equal (cooked-tests-comint--text) "see here ok\n"))
    (should (equal (get-text-property (+ (point-min) 4) 'help-echo)
                   "https://example.com"))
    (should-not (get-text-property (point-min) 'help-echo))))

(ert-deftest cooked-comint-tracks-the-childs-directory ()
  (cooked-tests-comint--with
    (let ((dir (file-name-as-directory (temporary-file-directory))))
      (cooked-tests-comint--say (format "\e]7;file://%s%s\a$ " (system-name) dir))
      (should (equal default-directory dir)))))

(ert-deftest cooked-comint-refuses-a-directory-on-another-host ()
  ;; A `cat' of a hostile file can put anything here, and the refusal has to come
  ;; before anything asks the filesystem about the path -- under TRAMP the asking is
  ;; itself the connection.
  (cooked-tests-comint--with
    (let ((was default-directory))
      (cooked-tests-comint--say "\e]7;file://elsewhere.example/tmp/\a$ ")
      (should (equal default-directory was)))))

(ert-deftest cooked-comint-agrees-with-the-terminal-about-which-host-is-this-one ()
  ;; zsh reports `HOST', which is usually the short name, where `system-name' is
  ;; fully qualified.  The terminal has always read the two as one machine; the
  ;; comint filter compared them exactly and so tracked nothing.  A different
  ;; machine on the same domain is still a different machine.
  (cooked-tests-comint--with
    (cl-letf (((symbol-function 'system-name) (lambda () "box.example.org")))
      (let ((dir (file-name-as-directory (temporary-file-directory)))
            (was default-directory))
        (cooked-tests-comint--say "\e]7;file://other.example.org/\a$ ")
        (should (equal default-directory was))
        (cooked-tests-comint--say (format "\e]7;file://box%s\a$ " dir))
        (should (equal default-directory dir))
        (should-not (cooked--local-host-p "boxer"))
        (should (cooked--local-host-p "BOX.example.org"))))))

(ert-deftest cooked-comint-leaves-the-directory-alone-when-asked-to ()
  (cooked-tests-comint--with
    (let ((cooked-comint-track-directory nil)
          (was default-directory))
      (cooked-tests-comint--say
       (format "\e]7;file://%s%s\a$ " (system-name) (temporary-file-directory)))
      (should (equal default-directory was)))))

;;;; The mode itself

(ert-deftest cooked-comint-turns-off-the-two-passes-it-replaces ()
  ;; Both would otherwise walk every chunk, and both would find nothing: the escape
  ;; sequences and the carriage returns are spent by the time either looks.  Off
  ;; buffer-locally in both cases -- `ansi-color-process-output' sits on comint's
  ;; *global* hook value, so its own switch is the only per-buffer way to say this.
  (cooked-tests-comint--with
    (should-not ansi-color-for-comint-mode)
    (should (local-variable-p 'ansi-color-for-comint-mode))
    (should comint-inhibit-carriage-motion)
    (should (local-variable-p 'comint-inhibit-carriage-motion))))

(ert-deftest cooked-comint-stops-filtering-when-it-is-turned-off ()
  (cooked-tests-comint--with
    (cooked-comint-mode -1)
    (should-not (memq #'cooked-comint--filter comint-preoutput-filter-functions))
    (cooked-tests-comint--say "abcdefghij\rXYZ\n")
    ;; comint's own carriage motion is back in charge, which is the state the buffer
    ;; was in before this mode existed.
    (should (equal (cooked-tests-comint--text) "XYZ\n"))))

(ert-deftest cooked-comint-global-mode-reaches-buffers-that-already-exist ()
  (let ((buffer (generate-new-buffer " *cooked-comint-existing*")))
    (unwind-protect
        (progn
          (with-current-buffer buffer (comint-mode))
          (cooked-comint-global-mode 1)
          (should (buffer-local-value 'cooked-comint-mode buffer)))
      (cooked-comint-global-mode -1)
      (kill-buffer buffer))))

(ert-deftest cooked-comint-global-mode-leaves-cooked-buffers-alone ()
  ;; `cooked-mode' derives from `comint-mode', so asking only whether a buffer is
  ;; comint turned this on inside every terminal, where nothing would ever feed it.
  (let ((buffer (generate-new-buffer " *cooked-comint-terminal*")))
    (unwind-protect
        (progn
          (cooked-comint-global-mode 1)
          (with-current-buffer buffer (cooked-mode))
          (should-not (buffer-local-value 'cooked-comint-mode buffer)))
      (cooked-comint-global-mode -1)
      (kill-buffer buffer))))

(ert-deftest cooked-comint-global-mode-leaves-other-buffers-alone ()
  (let ((buffer (generate-new-buffer " *cooked-comint-not-comint*")))
    (unwind-protect
        (progn
          (cooked-comint-global-mode 1)
          (should-not (buffer-local-value 'cooked-comint-mode buffer)))
      (cooked-comint-global-mode -1)
      (kill-buffer buffer))))

;;;; Loading the core

(ert-deftest cooked-comint-loads-the-core-for-the-first-output-and-not-before ()
  ;; The global mode turns this on from `after-change-major-mode-hook', so a core
  ;; that cannot be loaded must not signal there: every `M-x shell' would fail at
  ;; mode setup.  It is the first chunk that loads it.
  (let ((loads 0))
    (cl-letf (((symbol-function 'cooked--load-module)
               (lambda (&rest _) (cl-incf loads))))
      (cooked-tests-comint--with
        (should (zerop loads))
        (should-not cooked-comint--core-filter)
        (cooked-tests-comint--say "abcdefghij\rXYZ\n")
        (should (= loads 1))
        (should cooked-comint--core-filter)
        (cooked-tests-comint--say "more\n")
        (should (= loads 1))
        (should (equal (cooked-tests-comint--text) "XYZdefghij\nmore\n"))))))

(ert-deftest cooked-comint-leaves-the-buffer-to-comint-when-there-is-no-core ()
  ;; A checkout whose core is missing: loading it from the first chunk must not run
  ;; `cargo build' inside the process filter.  The mode gives up instead, and the
  ;; chunk reaches comint as it would have without this file, colours and all.
  (let ((builds 0)
        (cooked-native-module nil)
        (featurep* (symbol-function 'featurep)))
    (cl-letf (((symbol-function 'featurep)
               (lambda (feature &rest rest)
                 (unless (eq feature 'cooked-core)
                   (apply featurep* feature rest))))
              ((symbol-function 'cooked--source-core)
               (lambda (_root) "/nonexistent/libcooked.so"))
              ((symbol-function 'cooked--build-module)
               (lambda (&rest _) (cl-incf builds)))
              ((symbol-function 'module-load) #'ignore)
              ((symbol-function 'message) #'ignore))
      (cooked-tests-comint--with
        (should cooked-comint-mode)
        (cooked-tests-comint--say "abcdefghij\rXYZ\n")
        (should (zerop builds))
        (should-not cooked-comint-mode)
        (should-not (local-variable-p 'ansi-color-for-comint-mode))
        ;; comint's own carriage motion, which deletes to the start of the line.
        (should (equal (cooked-tests-comint--text) "XYZ\n"))))))

;;;; Layering

(ert-deftest cooked-comint-does-not-drag-in-cooked ()
  "Loading `cooked-comint' must not load `cooked'.

The constraint the file exists under, tested rather than asserted in a comment,
and tested transitively: a `require' three files down would satisfy any reading
of the source and still put a session's worth of machinery behind a hook
function.  So this asks the only question that cannot be got wrong -- a fresh
Emacs loads the file and is asked what it has.

`cooked-face', `cooked-util' and `cooked-module' are the three it is allowed,
and the test names them rather than counting, so adding a permitted dependency
is a decision somebody makes here on purpose.  `cooked-module' is only the
loader for the native core, which the filter cannot do without."
  (let* ((emacs (expand-file-name invocation-name invocation-directory))
         (lisp (expand-file-name "lisp" (cooked--root)))
         (script "(progn (require 'cooked-comint)
                         (prin1 (list (featurep 'cooked)
                                      (featurep 'cooked-face)
                                      (featurep 'cooked-util)
                                      (featurep 'cooked-module))))")
         (output (with-output-to-string
                   (with-current-buffer standard-output
                     (call-process emacs nil t nil
                                   "-Q" "--batch" "-L" lisp "--eval" script)))))
    (should (equal (car (read-from-string output)) '(nil t t t)))))

(provide 'cooked-tests-comint)
;;; cooked-tests-comint.el ends here
