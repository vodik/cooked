;;; cooked-tests-command-decorations.el --- the fringe marker per command -*- lexical-binding: t; -*-

;;; Commentary:

;; `display-graphic-p' is mocked rather than relied on, per the note in
;; HANDOFF.md: batch Emacs draws nothing, so the graphical/terminal split is
;; exercised the way `cooked-tests-render.el' exercises the same split in
;; `cooked--mark-truncation' -- `cl-letf' over `display-graphic-p', not a real
;; frame.  Command records are built with `cooked-tests--make-command' rather
;; than driven from a shell, for the same reason as the sticky-scroll tests.

;;; Code:

(require 'cooked-tests-helpers)
(require 'cooked-command-decorations)

(ert-deftest cooked-command-decorations-requiring-the-file-wires-the-hook ()
  "The extension point: requiring this file is the whole of opting in.
Both halves of it -- the once-per-command paint and the per-render re-arm."
  (should (memq #'cooked-command-decorations--started cooked-command-started-functions))
  (should (memq #'cooked-command-decorations--add cooked-command-finished-functions))
  (should (memq #'cooked-command-decorations--rearm cooked-row-rendered-functions)))

(ert-deftest cooked-command-decorations-paints-nothing-on-a-terminal-frame ()
  "No sensible single-glyph substitute for a coloured marker exists, and a real
column per command line is too high a tax -- so a terminal frame gets no
decoration at all, same as the `fringe-mode' 0 gap `cooked--mark-truncation'
documents for its own indicator."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (let ((command (cooked-tests--make-command "$ " "echo hi" "hi\n" 0)))
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil)))
        (cooked-command-decorations--add command))
      (should-not (overlays-in (point-min) (point-max))))))

(ert-deftest cooked-command-decorations-paints-an-overlay-on-a-graphical-frame ()
  "Uses an overlay's `before-string', never a `display' property on the
buffer's own text -- `cooked--render-rows' deletes and reinserts whole rows,
so a text property dies with the row, and a `display' spec on a real
character would cost that character a column."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (let ((command (cooked-tests--make-command "$ " "echo hi" "hi\n" 0)))
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
        (cooked-command-decorations--add command))
      (let ((overlay (car (overlays-in (point-min) (point-max)))))
        (should overlay)
        (should (overlay-get overlay 'evaporate))
        (should (eq (overlay-get overlay 'cooked-command-decoration) command))
        ;; Anchored at the prompt marker, a row-start marker, not at `start'.
        (should (= (overlay-start overlay) (cooked--command-prompt-position command)))
        ;; The real character underneath is untouched -- no `display' property
        ;; of its own -- exactly the reason the indicator rides a virtual
        ;; string instead.
        (should-not (get-text-property (overlay-start overlay) 'display))
        (let ((spec (get-text-property 0 'display (overlay-get overlay 'before-string))))
          (should (eq (car spec) 'left-fringe))
          (should (memq (cadr spec) fringe-bitmaps))
          (should (eq (caddr spec) 'cooked-command-decoration-success)))))))

(ert-deftest cooked-command-decorations-colours-a-failure-differently ()
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (let ((command (cooked-tests--make-command "$ " "false" "" 1)))
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
        (cooked-command-decorations--add command))
      (let* ((overlay (car (overlays-in (point-min) (point-max))))
             (spec (get-text-property 0 'display (overlay-get overlay 'before-string))))
        (should (eq (caddr spec) 'cooked-command-decoration-failure))))))

(ert-deftest cooked-command-decorations-falls-back-to-the-start-marker ()
  "A command whose shell never sent an `A' mark has no `prompt', so the marker
anchors at `start' instead -- the closest thing to a beginning there is."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (goto-char (point-max))
    (insert "output only, no prompt seen\n")
    (let ((command (cooked--command-make :start (copy-marker (point-min))
                                         :end (copy-marker (point-max))
                                         :code 0 :input nil :prompt nil)))
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
        (cooked-command-decorations--add command))
      (let ((overlay (car (overlays-in (point-min) (point-max)))))
        (should (= (overlay-start overlay) (cooked--command-start-position command)))))))

(ert-deftest cooked-command-decorations-are-not-painted-twice ()
  "Both entry points can arrive at an already-decorated row -- the re-arm runs
on every rewrite of one -- so painting is idempotent per command rather than
guarded at each call site."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (let ((command (cooked-tests--make-command "$ " "echo hi" "hi\n" 0)))
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
        (cooked-command-decorations--add command)
        (cooked-command-decorations--add command)
        (cooked-command-decorations--rearm (point-min) (point-max)))
      (should (= 1 (length (overlays-in (point-min) (point-max))))))))

(ert-deftest cooked-command-decorations-survive-a-resize-damaging-every-row ()
  "The gap the re-arm closes, driven the way it actually happens.

The overlay carries `evaporate t\=' and rides on real characters, so
`cooked--render-rows\=' deleting a damaged row takes it with it -- and a resize
damages every live row at once, while `cooked-command-finished-functions\=' fires
exactly once per command.  A command whose prompt is still on the live screen
would lose its marker the first time the window changed width."
  (skip-unless (executable-find "zsh"))
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
    (cooked-tests--with-zsh
      (cooked--send-input-string "echo decorated")
      (should (cooked-tests--settle (lambda () cooked--commands) 8))
      (let* ((command (car cooked--commands))
             (anchor (cooked--command-prompt-position command)))
        ;; On the live screen, which is the only place the gap existed: a row in
        ;; permanent scrollback is never rendered again.
        (should (>= anchor (cooked--screen-start-position)))
        (should (cooked-command-decorations--decoration-at anchor command))
        (cooked-tests--resize 20 40)
        (cooked-tests--resize 24 80)
        (let ((moved (cooked--command-prompt-position command)))
          (should (cooked-command-decorations--decoration-at moved command))
          ;; And on the right row, which is the other half of the same complaint:
          ;; the record itself is kept true across a rewrap by
          ;; `cooked--relocate-marks', so a re-armed marker lands where the prompt
          ;; actually is rather than wherever the old anchor now points.
          (should (save-excursion
                    (goto-char moved)
                    (and (= moved (line-beginning-position))
                         (string-suffix-p
                          "echo decorated"
                          (buffer-substring-no-properties
                           moved (line-end-position)))))))))))

(defun cooked-tests--run-marked-commands (count)
  "Run COUNT alternating true/false commands in the current cooked buffer.

Alternating on purpose: the marker's colour comes from the record's own exit
code, so a run where every neighbour disagrees with its neighbours is one where
a decoration that has slid onto the wrong row says something visibly false --
which is how this was reported, as prompts flipping green and red to match the
command below them."
  (dotimes (i count)
    (let ((before (length cooked--commands)))
      (cooked--send-input-string (if (cl-evenp i) "true" "false"))
      (should (cooked-tests--settle
               (lambda () (> (length cooked--commands) before)) 8))
      (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input)) 8)))))

(defun cooked-tests--check-decorations ()
  "Assert every recorded command has exactly its own marker on its own row."
  (dolist (command cooked--commands)
    (let* ((anchor (cooked--command-prompt-position command))
           (found (seq-filter (lambda (overlay)
                                (overlay-get overlay 'cooked-command-decoration))
                              (overlays-at anchor))))
      ;; One marker, and it is this command's -- not the next command's, which
      ;; is what a decoration painted from a marker a scroll had just pushed a
      ;; row down looked like.
      (should (= 1 (length found)))
      (should (eq (overlay-get (car found) 'cooked-command-decoration) command))
      ;; And still one character wide.  An overlay sitting exactly at
      ;; `cooked--screen-start' swallows the rows a scroll inserts there, which
      ;; leaves it answering `overlays-at' for a screenful of scrollback.
      (should (= (overlay-start (car found)) anchor))
      (should (= (overlay-end (car found)) (1+ anchor))))))

(ert-deftest cooked-command-decorations-stay-on-their-own-prompt-across-a-scroll ()
  "The bug this file's ordering exists to prevent, at the point it appeared.

A drain that evicts rows inserts their text above the live screen before it
rewrites anything, which drags every marker below the insertion forward by a
whole row; `cooked--relocate-marks' puts them back, but only after the rows
have been rendered.  A decoration painted from inside the render therefore
painted the row below its own prompt, and since the correction that followed
moved the marker and not the paint, every marker on a full screen ended up
wearing its neighbour's colour."
  (skip-unless (executable-find "zsh"))
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
    (cooked-tests--with-zsh
      ;; Comfortably more than the 24 rows the screen starts at, so the last
      ;; several commands are all run against a screen that scrolls per prompt.
      (cooked-tests--run-marked-commands 30)
      (should (> (cooked--screen-start-position) (point-min)))
      (cooked-tests--check-decorations))))

(ert-deftest cooked-command-decorations-follow-their-prompt-into-scrollback ()
  "A prompt row that scrolls off keeps its marker, and keeps only one.

The drain that evicts a row renders it one last time as a live row and then
deletes it, so an `evaporate t\=' overlay on it dies with the text -- while the
scrollback copy that now owns the prompt is never rendered again and would be
decorated by nothing.  The re-arm therefore asks about commands rather than
about the row it was called for, and reaches the ones that have just settled."
  (skip-unless (executable-find "zsh"))
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
    (cooked-tests--with-zsh
      (cooked-tests--run-marked-commands 24)
      ;; Several rows at once, in one drain, which is the case a per-row hook
      ;; cannot see: only the last of them is still a live row by the time
      ;; anything is called back.
      (let ((before (length cooked--commands)))
        (cooked--send-input-string "seq 1 10")
        (should (cooked-tests--settle
                 (lambda () (> (length cooked--commands) before)) 8))
        (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input)) 8)))
      (let ((screen (cooked--screen-start-position)))
        ;; The test is only about scrollback if something actually got there.
        (should (seq-some (lambda (command)
                            (< (cooked--command-prompt-position command) screen))
                          cooked--commands)))
      (cooked-tests--check-decorations))))

(ert-deftest cooked-command-decorations-come-down-for-the-alt-screen ()
  "A full-screen program draws over the same buffer positions the live rows sit
at, so a marker left up would ride in the fringe beside its frame claiming to be
about a command.  It comes back on its own when the program leaves: restoring the
primary marks every row damaged, and the re-arm repaints from that."
  (skip-unless (executable-find "zsh"))
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
    (cooked-tests--with-zsh
      (cooked--send-input-string "echo decorated")
      (should (cooked-tests--settle (lambda () cooked--commands) 8))
      (let ((command (car cooked--commands)))
        (should (cooked-command-decorations--decoration-at
                 (cooked--command-prompt-position command) command))
        (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input)) 8))
        (cooked--send-input-string
         "printf '\\033[?1049h'; sleep 1; printf '\\033[?1049l'")
        (should (cooked-tests--settle (lambda () cooked--alt) 8))
        (should-not (cooked-command-decorations--decoration-at
                     (cooked--command-prompt-position command) command))
        ;; And back, without anything putting them back on purpose.
        (should (cooked-tests--settle (lambda () (not cooked--alt)) 8))
        (should (cooked-tests--settle
                 (lambda () (cooked-command-decorations--decoration-at
                             (cooked--command-prompt-position command) command))
                 8))))))

(ert-deftest cooked-command-decorations-mark-a-running-command-neutrally ()
  "The third state, and the whole of what makes it a third state rather than a
third *answer*: it is dim, it carries no exit code, and there is nothing on it
to click, since all three menu actions want a command that has finished."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (goto-char (point-max))
    (let ((prompt (point-marker)))
      (insert "$ sleep 1\n")
      (setq cooked--command-prompt prompt
            cooked--command-start (point-marker)
            cooked--command-input "sleep 1")
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
        (cooked-command-decorations--started (cooked--running-anchor)))
      (let* ((overlay cooked-command-decorations--running)
             (string (overlay-get overlay 'before-string))
             (spec (get-text-property 0 'display string)))
        (should (= (overlay-start overlay) prompt))
        (should (eq (caddr spec) 'cooked-command-decoration-running))
        (should-not (get-text-property 0 'keymap string))
        ;; And it names no command, there being no record to name: what the menu
        ;; makes of a running prompt is `cooked--command-around''s business and
        ;; predates this marker, but the marker itself offers it nothing.
        (should-not (overlay-get overlay 'cooked-command-decoration))))))

(ert-deftest cooked-command-decorations-take-the-running-marker-down-again ()
  "Derived, not remembered.  Nothing has to notice the ways a running marker
can be stranded -- a `D\=' whose `C\=' was lost, a session reset -- because the
re-arm asks `cooked--running-anchor\=' what is running rather than trusting what
it painted last."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (goto-char (point-max))
    (let ((prompt (point-marker)))
      (insert "$ sleep 1\n")
      (setq cooked--command-prompt prompt cooked--command-start (point-marker))
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
        (cooked-command-decorations--started (cooked--running-anchor))
        (should cooked-command-decorations--running)
        (setq cooked--command-prompt nil cooked--command-start nil)
        (cooked-command-decorations--rearm (point-min) (point-max)))
      (should-not cooked-command-decorations--running)
      (should-not (overlays-in (point-min) (point-max))))))

(ert-deftest cooked-command-decorations-hand-the-marker-over-at-the-exit-code ()
  "The two markers want the same row -- this command's prompt -- so the running
one comes down as the finished one goes up, at the `D\=' mark rather than at the
next render.  One marker on that row throughout, and the colour changes under
it."
  (skip-unless (executable-find "zsh"))
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
    (cooked-tests--with-zsh
      (cooked--send-input-string "sleep 1")
      (should (cooked-tests--settle
               (lambda () cooked-command-decorations--running) 8))
      (let ((overlay cooked-command-decorations--running))
        (should (= (overlay-start overlay)
                   (marker-position (cooked--running-anchor))))
        (should (eq (caddr (get-text-property
                            0 'display (overlay-get overlay 'before-string)))
                    'cooked-command-decoration-running)))
      (should (cooked-tests--settle (lambda () cooked--commands) 8))
      (should-not cooked-command-decorations--running)
      (let* ((command (car cooked--commands))
             (anchor (cooked--command-prompt-position command)))
        (should (= 1 (length (overlays-at anchor))))
        (should (cooked-command-decorations--decoration-at anchor command))
        (should (eq (caddr (get-text-property
                            0 'display
                            (overlay-get (cooked-command-decorations--decoration-at
                                          anchor command)
                                         'before-string)))
                    'cooked-command-decoration-success))))))

(ert-deftest cooked-command-decorations-menu-finds-the-command-at-point ()
  "Keyboard-reachable: the menu command works from ordinary point, not only
from a click on a marker that happens to still be there."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (let ((command (cooked-tests--make-command "$ " "echo hi" "hi\n" 0)))
      (goto-char (cooked--command-start-position command))
      (should (eq (cooked-command-decorations--command-at (point)) command)))))

(ert-deftest cooked-command-decorations-copy-command-kills-the-input ()
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (let ((command (cooked-tests--make-command "$ " "echo copy-me" "copy-me\n" 0)))
      (cooked-command-decorations--copy-command command)
      (should (equal (current-kill 0) "echo copy-me")))))

(ert-deftest cooked-command-decorations-copy-output-kills-the-output-region ()
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (let ((command (cooked-tests--make-command "$ " "echo out-text" "out-text\n" 0)))
      (cooked-command-decorations--copy-output command)
      (should (string-search "out-text" (current-kill 0))))))

(ert-deftest cooked-command-decorations-rerun-refuses-a-busy-prompt ()
  "Resending a command line only makes sense at an empty prompt -- not while
something is running or mid-edit, which `cooked--send-input-string' has no
way to interleave with safely."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (let ((command (cooked-tests--make-command "$ " "echo hi" "hi\n" 0)))
      (cl-letf (((symbol-function 'cooked--input-state-p) (lambda () nil)))
        (should-error (cooked-command-decorations--rerun command) :type 'user-error)))))

(ert-deftest cooked-command-decorations-rerun-refuses-a-command-with-no-input ()
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (goto-char (point-max))
    (insert "no input recorded\n")
    (let ((command (cooked--command-make :start (copy-marker (point-min))
                                         :end (copy-marker (point-max))
                                         :code 0 :input nil :prompt nil)))
      (should-error (cooked-command-decorations--rerun command) :type 'user-error))))

(ert-deftest cooked-command-decorations-menu-key-is-bound ()
  (should (eq (lookup-key cooked-mode-map (kbd "C-c C-o")) #'cooked-command-decorations-menu)))

(provide 'cooked-tests-command-decorations)
;;; cooked-tests-command-decorations.el ends here
