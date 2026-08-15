;;; cooked-tests-sticky-scroll.el --- the sticky-scroll header line -*- lexical-binding: t; -*-

;;; Commentary:

;; `cooked--sticky-command' and `cooked--sticky-header' are read-only over
;; `cooked--commands' and the live markers `cooked--command-around' already
;; walks, so most of what needs covering is pure presentation logic: buffer
;; state built by hand with `cooked-tests--make-command', the way
;; `cooked-tests-render.el' builds screen rows directly rather than driving a
;; shell for every case.  One real-session test at the end proves the whole
;; pipeline, OSC 133 through to the header, actually wires together.

;;; Code:

(require 'cooked-tests-helpers)

(ert-deftest cooked-sticky-header-hides-on-the-alt-screen ()
  "The alt screen is a fixed rectangle with no scrollback to pin against."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (cooked-tests--make-command "$ " "some-command" "output\n" 0)
    (setq cooked--alt t)
    (should (equal (cooked--sticky-header) ""))))

(ert-deftest cooked-sticky-header-hides-with-nothing-found ()
  "Scrolled above the first prompt, or a buffer with no history at all."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (should (equal (cooked--sticky-header) ""))))

(ert-deftest cooked-sticky-header-hides-for-a-command-emacs-never-submitted ()
  "A command the shell ran itself, or one typed while the child owned the
keyboard, has no `input' -- `cooked-command-finished-functions''s docstring
promises exactly this, and the header honours the same promise rather than
pinning a blank command line."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (goto-char (point-max))
    (let ((prompt (point-marker)))
      (insert "$ typed-without-cooked\nsome output\n")
      (push (cooked--command-make :start (copy-marker (point-min))
                                  :end (copy-marker (point-max))
                                  :code 0 :input nil :prompt prompt)
            cooked--commands)
      (set-window-start (selected-window) (marker-position prompt)))
    (should (equal (cooked--sticky-header) ""))))

(ert-deftest cooked-sticky-header-pins-whichever-command-window-start-is-inside ()
  "VS Code's own behaviour, and the `window' default: each window answers from
its own `window-start', not from point."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (let* ((first (cooked-tests--make-command "$ " "first-command" "one\n" 0))
           (second (cooked-tests--make-command "$ " "second-command" "two\n" 0)))
      (set-window-start (selected-window) (cooked--command-start-position first))
      (should (string-search "first-command" (cooked--sticky-header)))
      (set-window-start (selected-window) (cooked--command-start-position second))
      (should (string-search "second-command" (cooked--sticky-header))))))

(ert-deftest cooked-sticky-header-running-style-ignores-scroll-position ()
  "The configurable alternative: pin only what is actually running, wherever
the window happens to be scrolled."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (let ((finished (cooked-tests--make-command "$ " "finished-one" "done\n" 0)))
      ;; A command still running has no record yet -- it is answered from the
      ;; live markers, same as `cooked--command-around' documents.
      (goto-char (point-max))
      (setq cooked--command-prompt (point-marker))
      (insert "$ running-command\n")
      (setq cooked--command-start (point-marker) cooked--command-input "running-command")
      (insert "partial output so far\n")
      (let ((cooked-sticky-scroll-style 'running))
        (set-window-start (selected-window) (cooked--command-start-position finished))
        (should (string-search "running-command" (cooked--sticky-header))))
      (let ((cooked-sticky-scroll-style 'window))
        (set-window-start (selected-window) (cooked--command-start-position finished))
        (should (string-search "finished-one" (cooked--sticky-header)))))))

(ert-deftest cooked-sticky-scroll-is-off-until-asked-for ()
  "Off by default, and read once in `cooked-mode\=' rather than consulted per
redisplay: a header line costs a row of the window body, which
`cooked--window-rows\=' folds straight into a PTY resize."
  (with-temp-buffer
    (let ((cooked-sticky-scroll nil))
      (cooked-mode)
      (should-not header-line-format))))

(ert-deftest cooked-sticky-scroll-installs-the-header-when-enabled ()
  (with-temp-buffer
    (let ((cooked-sticky-scroll t))
      (cooked-mode)
      (should (equal header-line-format '(:eval (cooked--sticky-header)))))))

(ert-deftest cooked-sticky-label-collapses-multiline-input-with-an-ellipsis ()
  (should (equal (cooked--sticky-label "first\nsecond\nthird" 80) "first …"))
  (should (equal (cooked--sticky-label "plain" 80) "plain")))

(ert-deftest cooked-sticky-label-truncates-to-the-window-width ()
  (let ((label (cooked--sticky-label (make-string 200 ?x) 10)))
    (should (<= (string-width label) 10))))

(ert-deftest cooked-sticky-header-follows-a-real-command-through-osc-133 ()
  "The whole pipeline, not just the presentation layer above: a real zsh's OSC
133 marks land in `cooked--commands' with a prompt marker and an `input', and
the header pins to it once the window is scrolled into its output."
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-shell ("zsh" :name "*cooked-sticky-zsh*" :setup (cooked-tests--display-buffer) :settle (lambda () (eq cooked--semantic 'input)))
    (cooked--restore-pending-input nil)
    (goto-char cooked--input-end)
    (insert "echo sticky-marker")
    (cooked-send-input)
    (should (cooked-tests--settle (lambda () cooked--commands)))
    (set-window-start (selected-window) (cooked--command-start-position (car cooked--commands)))
    (should (string-search "echo sticky-marker" (cooked--sticky-header)))))

(provide 'cooked-tests-sticky-scroll)
;;; cooked-tests-sticky-scroll.el ends here
