;;; cooked-tests-render.el --- Turning the emulator's grid into buffer text -*- lexical-binding: t; -*-

;;; Commentary:

;; The largest group, and the one with the most invariants: the screen region
;; is rewritten from damage reports while the scrollback above it is ordinary
;; buffer text, and the seam between them is a single wrapped line the two ends
;; each hold half of.  Resizes, narrowing, the alt screen and `cooked--guard-row-
;; width' all press on that boundary.

;;; Code:

(require 'cooked-tests-helpers)

(ert-deftest cooked-child-output-reaches-the-buffer ()
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'hello world\\n'")
    (should (cooked-tests--settle
             (lambda () (string-match-p "hello world" (cooked-tests--text)))))))

(ert-deftest cooked-colors-become-faces ()
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '\\033[31mred\\033[0m\\n'")
    (should (cooked-tests--settle
             (lambda () (string-match-p "red" (cooked-tests--text)))))
    (goto-char (point-min))
    (should (search-forward "red" nil t))
    (let ((face (get-text-property (- (point) 1) 'face)))
      (should (equal (plist-get face :foreground) (aref cooked-color-names 1))))))

(ert-deftest cooked-cooked-mode-gives-emacs-the-input-line ()
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle (lambda () (eq cooked--mode 'cooked))))
    (should (cooked--input-state-p))
    (should (eq (current-local-map) cooked-input-map))
    ;; Typing edits the buffer; nothing has been sent to the child yet.
    (cooked--restore-pending-input nil)
    (goto-char cooked--input-end)
    (insert "typed")
    (should (equal (cooked--pending-input) "typed"))
    (cooked-send-input)
    (should (cooked-tests--settle
             (lambda () (string-match-p "typed" (cooked-tests--text)))))))

(ert-deftest cooked-command-output-is-tagged-with-its-exit-code ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\033]133;C\\007'; printf 'out\\n'; printf '\\033]133;D;3\\007'; sleep 5")
    (should (cooked-tests--settle (lambda () (string-match-p "out" (cooked-tests--text)))))
    (should (cooked-tests--settle (lambda () (null cooked--semantic))))
    ;; The code itself, which is what the name promises and what nothing else in the
    ;; suite checks: `cooked--semantic' returns to nil for exit code 0 and 3 alike, so
    ;; asserting only that left the tagging untested on both the record and the text.
    (should (equal (cooked-command-code (car cooked--commands)) 3))
    (save-excursion
      (goto-char (point-min))
      (should (search-forward "out" nil t))
      (should (equal (get-text-property (match-beginning 0) 'cooked-exit-code) 3)))))

(ert-deftest cooked-scrollback-accumulates-above-the-screen ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "for i in $(seq 60); do printf 'line%s\\n' $i; done; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "line60" (cooked-tests--text)))))
    ;; Early lines scrolled off the emulator but survive as buffer text.
    (should (string-match-p "line1\n" (cooked-tests--text)))
    (goto-char (point-min))
    (should (get-text-property (point) 'cooked-scrollback))))

(ert-deftest cooked-alt-screen-hides-then-restores-the-primary-screen ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf 'keepme\\n'; printf '\\033[?1049h'; printf 'inalt\\n'; \
                        sleep 0.3; printf '\\033[?1049l'; sleep 5")
    (should (cooked-tests--settle (lambda () cooked--alt)))
    ;; While on the alt screen the primary content is hidden, as in any terminal.
    (should (string-match-p "inalt" (cooked-tests--text)))
    ;; Leaving it restores the primary screen, and the alt content leaves no trace.
    (should (cooked-tests--settle (lambda () (not cooked--alt))))
    (should (cooked-tests--settle
             (lambda () (string-match-p "keepme" (cooked-tests--text)))))
    (should-not (string-match-p "inalt" (cooked-tests--text)))))

(ert-deftest cooked-alt-screen-takes-the-keyboard-from-a-prompt ()
  "Entering the alt screen must swap the keymap even mid-prompt."
  (with-temp-buffer
    (cooked-mode)
    (setq-local cooked--mode 'raw cooked--semantic 'input cooked--alt nil)
    (cooked--refresh-keymap)
    (should (eq (current-local-map) cooked-input-map))
    (cooked--set-alt t)
    (should (eq (current-local-map) cooked-alt-map))
    (cooked--set-alt nil)
    (should (eq (current-local-map) cooked-input-map))))

(ert-deftest cooked-alt-screen-narrows-away-the-scrollback ()
  (cooked-tests--with-session
      (list "/bin/sh" "-c"
            (concat cooked-tests--scrollback-then-alt
                    "sleep 0.3; printf '\\033[?1049l'; sleep 5"))
    (should (cooked-tests--settle (lambda () cooked--alt)))
    (should (buffer-narrowed-p))
    ;; The transcript is out of reach while the program owns the screen, which is
    ;; what every other terminal does.
    (should-not (string-match-p "MARKER" (cooked-tests--text)))
    (should (string-match-p "inalt" (cooked-tests--text)))
    (save-restriction
      (widen)
      (should (string-match-p "MARKER" (buffer-substring-no-properties
                                        (point-min) (point-max)))))
    (should (cooked-tests--settle (lambda () (not cooked--alt))))
    (should-not (buffer-narrowed-p))
    (should (string-match-p "MARKER" (cooked-tests--text)))))

(ert-deftest cooked-clear-scrollback-reaches-past-the-alt-screen-restriction ()
  (cooked-tests--with-session
      (list "/bin/sh" "-c" (concat cooked-tests--scrollback-then-alt "sleep 5"))
    (should (cooked-tests--settle (lambda () cooked--alt)))
    (should (buffer-narrowed-p))
    (cooked-clear-scrollback)
    (save-restriction
      (widen)
      (should-not (string-match-p "MARKER" (buffer-substring-no-properties
                                            (point-min) (point-max)))))))

(ert-deftest cooked-alt-pin-leaves-a-users-own-narrowing-alone ()
  "Redraws may only undo the restriction they themselves imposed."
  (with-temp-buffer
    (cooked-mode)
    (insert "history\nSCREEN\n")
    (setq-local cooked--alt nil
                cooked--screen-start (copy-marker 9 nil))
    (narrow-to-region 1 9)
    (cooked--apply-alt-pin)
    (should (buffer-narrowed-p))
    (widen)
    (setq-local cooked--alt t)
    (cooked--apply-alt-pin)
    (should (buffer-narrowed-p))
    (setq-local cooked--alt nil)
    (cooked--apply-alt-pin)
    (should-not (buffer-narrowed-p))))

(ert-deftest cooked-a-child-dying-on-the-alt-screen-leaves-the-buffer-widened ()
  (cooked-tests--with-session
      (list "/bin/sh" "-c" (concat cooked-tests--scrollback-then-alt "exit 3"))
    (should (cooked-tests--settle
             (lambda () (string-match-p "\\[exited 3\\]" (cooked-tests--text)))))
    (should-not (buffer-narrowed-p))
    (should (string-match-p "MARKER" (cooked-tests--text)))))

(ert-deftest cooked-colors-survive-font-lock ()
  "comint leaves `font-lock-defaults' at (nil t); fontifying unfontifies first,
which strips a bare `face' property and with it every colour."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '\\033[32mGREEN\\033[0m\\n'; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "GREEN" (cooked-tests--text)))))
    (goto-char (point-min))
    (should (search-forward "GREEN" nil t))
    (let ((pos (- (point) 2)))
      (should (get-text-property pos 'face))
      (font-lock-ensure)
      (should (get-text-property pos 'face))
      (should (equal (plist-get (get-text-property pos 'face) :foreground)
                     (cooked--color 2))))))

(ert-deftest cooked-colors-follow-the-theme ()
  (let ((resolved (cooked--color 1)))
    (should (stringp resolved))
    ;; With no theme styling ansi-color-red we fall back to the static palette.
    (should (equal resolved (or (face-foreground 'ansi-color-red nil t)
                                (aref cooked-color-names 1))))))

(ert-deftest cooked-scrollback-and-screen-are-read-only ()
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'banner\\n'; exec cat")
    (should (cooked-tests--settle
             (lambda () (string-match-p "banner" (cooked-tests--text)))))
    (should (eq cooked--mode 'cooked))
    (should (cooked--input-start-position))
    ;; The transcript above the input line refuses edits.
    (goto-char (point-min))
    (should-error (insert "nope") :type 'text-read-only)
    (should-error (delete-char 1) :type 'text-read-only)
    ;; ...but the input region itself takes text.
    (goto-char cooked--input-end)
    (insert "typed")
    (should (equal (cooked--pending-input) "typed"))))

(ert-deftest cooked-screen-is-trimmed-to-a-transcript ()
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'one\\ntwo\\n'; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "two" (cooked-tests--text)))))
    ;; Without trimming the buffer would carry a screenful of blank lines.
    (should (< (count-lines (point-min) (point-max)) 8))
    (should (string-match-p "one" (cooked-tests--text)))))

(ert-deftest cooked-prompt-trailing-space-is-preserved ()
  "Trimming trailing blanks would put the input one column left of the prompt."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'ready$ '; exec cat")
    (should (cooked-tests--settle
             (lambda () (string-match-p "ready" (cooked-tests--text)))))
    (should (cooked--input-start-position))
    (goto-char (cooked--input-start-position))
    (should (equal (char-before) ?\s))
    (should (equal (buffer-substring-no-properties (line-beginning-position)
                                                   (cooked--input-start-position))
                   "ready$ "))))

(ert-deftest cooked-redisplay-survives-a-protected-buffer ()
  "Regression: `let' ran the initialisers before `inhibit-read-only' was bound,
so a drain touching protected text aborted the redisplay from inside the filter."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'banner\\n'; exec cat")
    (should (cooked-tests--settle
             (lambda () (string-match-p "banner" (cooked-tests--text)))))
    ;; Everything above the input is read-only by now.
    (should (get-text-property (point-min) 'read-only))
    (cooked--replace-input "typed")
    ;; A drain must not signal, and must leave the input intact.
    (cooked--apply (cooked--drain cooked--session))
    (should (equal (cooked--pending-input) "typed"))
    (should (cooked--input-start-position))))

(ert-deftest cooked-cursor-position-does-not-mutate ()
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle #'cooked--input-start-position))
    ;; Ask for a row far below the trimmed screen; it must not extend the buffer.
    (let ((cooked--cursor (cooked--cursor-make :row (+ 5 cooked--rows) :col 0))
          (before (buffer-string)))
      (cooked--cursor-position)
      (should (equal (buffer-string) before)))))

(ert-deftest cooked-resize-round-trip-keeps-the-transcript ()
  "Shrinking must absorb blank rows, not push the live screen into scrollback."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'alpha\\nbeta\\n'; exec cat")
    (should (cooked-tests--settle
             (lambda () (string-match-p "beta" (cooked-tests--text)))))
    (let ((original (cooked-tests--text)))
      (dolist (size '(10 40 24))
        (setq cooked--last-size nil)
        (setq cooked--rows size cooked--cols 80)
        (cooked--resize cooked--session size 80)
        (cooked-tests--settle (lambda () nil) 0.3))
      ;; No duplication, nothing lost.
      (let ((text (cooked-tests--text)))
        (should (string-match-p "alpha" text))
        (should (string-match-p "beta" text))
        (should (= 1 (cl-count "alpha" (split-string text "\n") :test #'string-search)))
        (should (equal (string-trim original) (string-trim text)))))))

(ert-deftest cooked-narrowing-keeps-lines-that-are-still-on-screen ()
  "The `ps' case: long lines that have not scrolled off yet live on the grid, not
in the buffer, and narrowing used to cut every one of them to the new width.  The
grid rewraps them instead, so the text is all still there — across more rows."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '%s\\n' aaaaaaaaaabbbbbbbbbbcccccccccc; exec cat")
    (should (cooked-tests--settle
             (lambda () (string-match-p "cccccccccc" (cooked-tests--text)))))
    (setq cooked--last-size nil cooked--rows 24 cooked--cols 10)
    (cooked--resize cooked--session 24 10)
    (cooked-tests--settle (lambda () nil) 0.3)
    ;; Each grid row is its own buffer line, so the wrapped line reads back whole
    ;; only once the row boundaries are taken out.
    (should (string-match-p
             "aaaaaaaaaabbbbbbbbbbcccccccccc"
             (string-replace "\n" "" (cooked-tests--text))))))

(ert-deftest cooked-a-width-round-trip-restores-the-original-rows ()
  "Rewrapping keeps the wrap provenance, so widening back is not a lossy guess."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '%s\\n' aaaaaaaaaabbbbbbbbbbcccccccccc; exec cat")
    (should (cooked-tests--settle
             (lambda () (string-match-p "cccccccccc" (cooked-tests--text)))))
    (dolist (cols '(10 80))
      (setq cooked--last-size nil cooked--rows 24 cooked--cols cols)
      (cooked--resize cooked--session 24 cols)
      (cooked-tests--settle (lambda () nil) 0.3))
    (should (member "aaaaaaaaaabbbbbbbbbbcccccccccc"
                    (split-string (cooked-tests--text) "\n")))))

(ert-deftest cooked-a-two-dimensional-resize-round-trips ()
  "Shrinking in both directions at once puts the two halves of a resize in each
other's way: the rewrap makes more rows than the shorter screen can hold, so rows
leave for scrollback in their rewrapped form while the buffer still holds them in
their old one.  Going back to the original size must give the original transcript
back — the same text, and each row exactly once."
  (cooked-tests--with-filled-screen
    (let ((original (cooked-tests--unwrapped)))
      (cooked-tests--resize 6 12)
      (cooked-tests--resize 12 20)
      (let ((text (cooked-tests--text)))
        (dotimes (i 12)
          (let ((tag (format "r%02d" (1+ i))))
            ;; Every row still there, and there exactly once.
            (should (= 1 (cl-count tag (split-string text "\n") :test #'string-search))))))
      ;; And the padding survived, so the columns still line up.
      (should (equal original (cooked-tests--unwrapped)))
      (cooked--check-seam))))

(ert-deftest cooked-a-height-shrink-does-not-leave-the-old-rows-below-the-screen ()
  "The rows a shrink evicts are inserted above the screen as scrollback, and the
survivors are re-rendered from row 0 down.  Nothing was removing the buffer lines
below the new last row, so the live screen was left with a stale copy of itself
underneath it — invisible until you scrolled, and duplicated text when you did."
  (cooked-tests--with-filled-screen
    (cooked-tests--resize 6 20)
    (should (<= (count-lines (marker-position cooked--screen-start) (point-max)) 6))
    (let ((text (cooked-tests--text)))
      (dotimes (i 12)
        (let ((tag (format "r%02d" (1+ i))))
          (should (>= 1 (cl-count tag (split-string text "\n") :test #'string-search))))))))

(ert-deftest cooked-clearing-the-screen-keeps-the-transcript ()
  "`clear' and C-l wipe the grid, but the screen they wipe is history Emacs is
holding: blanking those rows in place used to delete it from the buffer too."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'alpha\\nbeta\\n'; exec cat")
    (should (cooked-tests--settle
             (lambda () (string-match-p "beta" (cooked-tests--text)))))
    (cooked--send cooked--session "\e[2J")
    (cooked-tests--settle (lambda () nil) 0.3)
    (let ((text (cooked-tests--text)))
      (should (string-match-p "alpha" text))
      (should (string-match-p "beta" text)))))

(ert-deftest cooked-rows-do-not-merge-into-one-line ()
  "Regression: `forward-line' reports success at an unterminated final line,
so the next grid row was appended to the previous one — merging a command's
output with the prompt that followed it."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'aaa\\nbbb\\nccc\\n'; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "ccc" (cooked-tests--text)))))
    (let ((lines (split-string (cooked-tests--text) "\n")))
      (should (member "aaa" lines))
      (should (member "bbb" lines))
      (should (member "ccc" lines))
      (should-not (seq-find (lambda (l) (string-match-p "aaabbb\\|bbbccc" l)) lines)))))

(ert-deftest cooked-prompt-lands-on-its-own-line-after-a-command ()
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-shell ("zsh" :settle (lambda () (eq cooked--semantic 'input)))
    (let ((prompt (string-trim (buffer-substring-no-properties
                                (line-beginning-position) (point-max)))))
      (cooked--replace-input "printf 'one\\ntwo\\n'")
      (cooked-send-input)
      ;; Waited out on the command record rather than on the text: the
      ;; submitted line stays on screen until the echo redraws over it, so
      ;; "two" is in the buffer -- inside the command itself -- before the
      ;; child has run anything.
      (should (cooked-tests--settle
               (lambda () (and (eq cooked--semantic 'input)
                               cooked--commands
                               (string-match-p "two" (cooked-tests--text))))))
      (let ((lines (split-string (cooked-tests--text) "\n")))
        (should (member "one" lines))
        (should (member "two" lines))
        ;; The new prompt must not be glued onto the last output line.
        (should-not (seq-find (lambda (l)
                                (and (string-match-p (regexp-quote prompt) l)
                                     (string-match-p "^two" l)))
                              lines))))))

(ert-deftest cooked-point-follows-the-cursor-after-falling-behind ()
  "Regression: output arriving in chunks let the cursor overtake point for one
drain, after which point was stranded at column 0 of whatever line it was on."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'aaa\\nbbb\\n'; exec cat")
    (should (cooked-tests--settle
             (lambda () (string-match-p "bbb" (cooked-tests--text)))))
    ;; Put point behind the cursor but still inside the live screen, exactly the
    ;; state a chunked drain used to leave it in.
    (goto-char (marker-position cooked--screen-start))
    (should (< (point) (cooked--cursor-position)))
    (cooked--send cooked--session "ccc\n")
    (should (cooked-tests--settle
             (lambda () (string-match-p "ccc" (cooked-tests--text)))))
    ;; Point must be back at the input position rather than stranded behind.
    (should (equal (point) (cooked--point-after-input)))
    (should (> (point) (marker-position cooked--screen-start)))))

(ert-deftest cooked-point-stays-put-while-reading-scrollback ()
  "Following the cursor must not yank point away from someone reading history."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "for i in $(seq 60); do printf 'line%s\\n' $i; done; exec cat")
    (should (cooked-tests--settle
             (lambda () (string-match-p "line60" (cooked-tests--text)))))
    (goto-char (point-min))
    (let ((parked (point)))
      (cooked--send cooked--session "more\n")
      (should (cooked-tests--settle
               (lambda () (string-match-p "more" (cooked-tests--text)))))
      (should (equal (point) parked)))))

(ert-deftest cooked-output-drops-a-selection-it-rewrites ()
  "A region is a claim about particular text, and the child rewriting that text
makes the claim false without making it look false: `cooked--render-rows'
deletes a damaged row whole, so the mark collapses to that row's start and the
highlight spreads or shrinks on its own.  Every xterm-family terminal drops such
a selection instead, and `cooked-clear-selection-on-output' is that."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'alpha\\n'; exec cat")
    (should (cooked-tests--settle
             (lambda () (string-match-p "alpha" (cooked-tests--text)))))
    (goto-char (point-max))
    ;; `activate-mark' rather than `push-mark''s ACTIVATE, which leaves
    ;; `transient-mark-mode' off in batch -- and `deactivate-mark' does nothing
    ;; without it, so the test would pass for the wrong reason.
    (set-mark (cooked--screen-start-position))
    (activate-mark)
    (should mark-active)
    (cooked--send cooked--session "bravo\n")
    (should (cooked-tests--settle
             (lambda () (string-match-p "bravo" (cooked-tests--text)))))
    (should-not mark-active)))

(ert-deftest cooked-a-selection-in-the-scrollback-survives-output ()
  "The half that has to be kept.  Scrollback is text the child has finished with
and cannot reach again, so a region up there means exactly what it did when it
was drawn -- and copying out of the transcript while a program runs is what the
distinction is worth having for."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "for i in $(seq 60); do printf 'line%s\\n' $i; done; exec cat")
    (should (cooked-tests--settle
             (lambda () (string-match-p "line60" (cooked-tests--text)))))
    (goto-char (point-min))
    (set-mark (point-min))
    (activate-mark)
    (forward-line 3)
    (should (< (mark) (cooked--screen-start-position)))
    (cooked--send cooked--session "more\n")
    (should (cooked-tests--settle
             (lambda () (string-match-p "more" (cooked-tests--text)))))
    (should mark-active)
    (should (= (mark) (point-min)))))

(ert-deftest cooked-clearing-a-selection-on-output-can-be-turned-off ()
  "The option is the whole of the behaviour: nil leaves the mark wherever the
redraw put it, which is what cooked did before there was an option."
  (let ((cooked-clear-selection-on-output nil))
    (cooked-tests--with-session '("/bin/sh" "-c" "printf 'alpha\\n'; exec cat")
      (should (cooked-tests--settle
               (lambda () (string-match-p "alpha" (cooked-tests--text)))))
      (goto-char (point-max))
      (set-mark (cooked--screen-start-position))
      (activate-mark)
      (cooked--send cooked--session "bravo\n")
      (should (cooked-tests--settle
               (lambda () (string-match-p "bravo" (cooked-tests--text)))))
      (should mark-active))))

(ert-deftest cooked-alt-screen-keeps-exactly-the-emulator-height ()
  "Trimming is disabled on the alt screen, so nothing else removes stale rows
when the window shrinks — which looked like resize doing nothing."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '\\033[?1049h'; printf 'top\\n'; sleep 5")
    (should (cooked-tests--settle (lambda () cooked--alt)))
    ;; The row `point-max' lands on, not a line count: the last row is left
    ;; unterminated so that nothing sits below it, and `count-lines' then reads
    ;; one short whenever that row happens to be empty.  This says the thing the
    ;; test is actually about anyway — the bottom of the region is the bottom row
    ;; of the grid.
    (let ((screen-lines (lambda () (1+ (car (cooked--screen-cell (point-max)))))))
      (should (= (funcall screen-lines) cooked--rows))
      ;; Shrink: the region must follow, not keep the old rows.
      (setq cooked--rows 10 cooked--cols 40)
      (cooked--resize cooked--session 10 40)
      (should (cooked-tests--settle (lambda () (= (funcall screen-lines) 10))))
      ;; And grow again.
      (setq cooked--rows 30)
      (cooked--resize cooked--session 30 40)
      (should (cooked-tests--settle (lambda () (= (funcall screen-lines) 30)))))))

(ert-deftest cooked-alt-screen-resize-does-not-leave-window-start-adrift ()
  "Regression: a shrink reaches `cooked--apply' in two steps rather than one --
the window changes height the instant Emacs notices (`cooked--sync-size'),
while the buffer is not trimmed to match until this drain's `cooked--fit-screen'
runs.  Ordinary redisplay can spend that gap pushing `window-start' down to
keep point on screen, and nothing used to undo that once the buffer caught
up: the window kept showing the scroll a now-stale redisplay had chosen,
clipping the top of the screen even though the buffer content was correct."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '\\033[?1049h'; printf 'top\\n'; sleep 5")
    (should (cooked-tests--settle (lambda () cooked--alt)))
    (set-window-buffer (selected-window) (current-buffer))
    (goto-char (point-max))
    ;; Simulate the drift a shrink leaves behind, without depending on real
    ;; redisplay timing: window-start pushed away from the top of the screen
    ;; region, as if a resize had shrunk the window before the buffer caught up.
    (set-window-start (selected-window) (point-max) t)
    (should-not (= (window-start (selected-window)) (marker-position cooked--screen-start)))
    (cooked--apply (cooked--drain cooked--session))
    (should (= (window-start (selected-window)) (marker-position cooked--screen-start)))))

(ert-deftest cooked-alt-screen-has-no-line-below-its-last-row ()
  "Regression: `cooked--fit-screen' used to shape the alt region by walking to row
HEIGHT — one past the last — and trimming from there, and a row is made to exist
by inserting the newline that ends the row above it.  The region was therefore
HEIGHT newline-terminated lines plus an empty one at `point-max': a buffer line
below the bottom of the screen, which point could be moved onto and which
scrolled the whole picture up by one when it was."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '\\033[?1049h'; printf 'top\\n'; sleep 5")
    (should (cooked-tests--settle (lambda () cooked--alt)))
    (let ((last-row (lambda () (car (cooked--screen-cell (point-max))))))
      ;; The last position in the region is on the bottom row of the grid rather
      ;; than one below it, so there is nowhere for point to go that the child
      ;; does not own and the window has nothing extra to scroll.
      (should (= (funcall last-row) (1- cooked--rows)))
      ;; And it is a fixed point: a further drain neither regrows the phantom line
      ;; nor eats a real row.
      (cooked--apply (cooked--drain cooked--session))
      (should (= (funcall last-row) (1- cooked--rows))))))

(ert-deftest cooked-alt-screen-stays-pinned-without-a-drain ()
  "Regression: the window pin lived only at the end of `cooked--apply', so it
fired when the child spoke and never when the user did.  An idle full-screen
program produces no output, so a wheel event reaching `mwheel-scroll' — which is
what happens while the keyboard is suspended for a peek — scrolled the screen
off the window with nothing left to put it back."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '\\033[?1049h'; printf 'top\\n'; sleep 5")
    (should (cooked-tests--settle (lambda () cooked--alt)))
    (set-window-buffer (selected-window) (current-buffer))
    (let ((top (marker-position cooked--screen-start)))
      ;; The reported case: Emacs owns the keyboard, so `cooked--mouse-grab' is
      ;; off and the wheel reaches `mwheel-scroll' rather than the child.
      (setq cooked--input-mode 'still)
      (should (cooked--suspended-p))
      ;; Scroll it away, then run the hook the way a command would.  No drain
      ;; happens in between: that is the whole point.
      (set-window-start (selected-window) (point-max))
      (should-not (= (window-start (selected-window)) top))
      (cooked--pin-alt-windows)
      (should (= (window-start (selected-window)) top)))))

(ert-deftest cooked-alt-screen-is-pinned-from-redisplay-too ()
  "Regression: pinning from `post-command-hook' alone left the wheel two ways
out — a notch over an unselected window ends its command in another buffer, and
a notch from a mouse is animated inside one command by
`pixel-scroll-precision-interpolate', which redisplays a dozen times before that
command ends.  `pre-redisplay-functions' sees both, and names the window about
to be drawn rather than leaving the pin to find it.

`window-scroll-functions' was the hook here first and could not do the job: it
is not called for a window redisplayed with a vscroll, which is three of every
four events of a pixel scroll.  So the vscroll is asserted about too — pinning
the start alone leaves the top row shaved by the pixels the last event carried."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '\033[?1049h'; printf 'top\n'; sleep 5")
    (should (cooked-tests--settle (lambda () cooked--alt)))
    (set-window-buffer (selected-window) (current-buffer))
    (let ((top (marker-position cooked--screen-start))
          (window (selected-window)))
      (should (memq #'cooked--pin-alt-windows
                    (buffer-local-value 'pre-redisplay-functions (current-buffer))))
      ;; Called the way redisplay calls it: the window about to be drawn.
      (set-window-start window (point-max))
      (set-window-vscroll window 5 t)
      (run-hook-with-args 'pre-redisplay-functions window)
      (should (= (window-start window) top))
      (should (zerop (window-vscroll window t)))
      ;; Redisplay calls the hook again for the move the pin itself just made, so
      ;; the pin has to decline to answer itself.
      (set-window-start window (point-max))
      (let ((cooked--pinning t))
        (cooked--pin-alt-windows window (window-start window)))
      (should-not (= (window-start window) top)))))

(ert-deftest cooked-clearing-the-screen-scrolls-the-transcript-out-of-view ()
  "`CSI 2 J' archives the screen rather than losing it, because history is Emacs'
-- so nothing scrolls out of view on its own, and `clear' or the shell's `C-l'
looked like it had done nothing at all: the transcript still filled the window.
A real terminal's viewport moves instead, which here means the window.  The text
above is untouched and one scroll away, exactly as scrollback is anywhere else."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "for i in $(seq 40); do printf 'line%s\\n' $i; done; \
                        sleep 1; printf '\\033[H\\033[2Jafter'; exec cat")
    (set-window-buffer (selected-window) (current-buffer))
    (should (cooked-tests--settle
             (lambda () (string-match-p "line40" (cooked-tests--text)))))
    (should (cooked-tests--settle
             (lambda () (string-match-p "after" (cooked-tests--text)))))
    (should (string-match-p "line40" (cooked-tests--text)))
    (should (= (window-start (selected-window)) (marker-position cooked--screen-start)))
    ;; And it holds.  The cleared screen is one row, so recentring on the cursor
    ;; would seat that row at the foot of the window and fill the rest with the
    ;; transcript again -- the clear undone by the next thing the child printed.
    (cooked-tests--type "x")
    (should (cooked-tests--settle
             (lambda () (string-match-p "afterx" (cooked-tests--text)))))
    (should (= (window-start (selected-window)) (marker-position cooked--screen-start)))))

(ert-deftest cooked-underline-face-keeps-its-old-shape-when-plain ()
  "A plain underline must still produce `:underline t', not a plist."
  (with-temp-buffer
    (cooked-mode)
    (setq-local cooked--face-cache (make-hash-table :test #'equal))
    (should (eq (plist-get (cooked--face nil nil cooked--attr-underline nil)
                           :underline)
                t))
    ;; SGR 4:1 is single, which Emacs renders the same way.
    (let ((single (logior cooked--attr-underline
                          (ash 1 cooked--attr-underline-shift))))
      (should (eq (plist-get (cooked--face nil nil single nil) :underline) t)))))

(ert-deftest cooked-underline-face-carries-style-and-color ()
  (with-temp-buffer
    (cooked-mode)
    (setq-local cooked--face-cache (make-hash-table :test #'equal))
    (let* ((curly (logior cooked--attr-underline
                          (ash 3 cooked--attr-underline-shift)))
           (spec (plist-get (cooked--face nil nil curly 1) :underline)))
      (should (eq (plist-get spec :style) 'wave))
      (should (stringp (plist-get spec :color))))
    ;; Dotted and dashed have no Emacs rendering, so they fall back to a line —
    ;; but the color still has to survive.
    (let* ((dotted (logior cooked--attr-underline
                           (ash 4 cooked--attr-underline-shift)))
           (spec (plist-get (cooked--face nil nil dotted 1) :underline)))
      (should (null (plist-get spec :style)))
      (should (stringp (plist-get spec :color))))))

(ert-deftest cooked-underline-color-does-not-collide-in-the-face-cache ()
  (with-temp-buffer
    (cooked-mode)
    (setq-local cooked--face-cache (make-hash-table :test #'equal))
    (let ((a (cooked--face nil nil cooked--attr-underline 1))
          (b (cooked--face nil nil cooked--attr-underline 2)))
      (should-not (equal a b)))))

(ert-deftest cooked-clear-scrollback-keeps-the-line-the-child-is-on ()
  "Everything above the child's line goes, on both sides of the seam: the output
that scrolled off into the buffer and the rows the grid is still holding.  Only
the scrollback went before, which left the whole screen in place -- and a few
commands into a session that is all of it, so the command looked inert."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "for i in $(seq 60); do printf 'line%s\\n' $i; done; \
                        printf 'PROMPT> '; exec cat")
    (should (cooked-tests--settle
             (lambda () (string-match-p "PROMPT>" (cooked-tests--text)))))
    (should (string-match-p "line1\n" (cooked-tests--text)))
    (should (string-match-p "line60" (cooked-tests--text)))
    (cooked-clear-scrollback)
    (should-not (string-match-p "line1\n" (cooked-tests--text)))
    (should-not (string-match-p "line60" (cooked-tests--text)))
    (should (string-match-p "PROMPT>" (cooked-tests--text)))))

(ert-deftest cooked-clear-scrollback-keeps-a-two-line-prompt-whole ()
  "With OSC 133 the cut is at the prompt's own mark, not at the cursor's row, so
a prompt that draws more than one line survives entire.  Cutting at the cursor
would eat the line above it, which the shell believes it is still drawing on.

Nothing here has scrolled off at all -- the whole transcript is on the grid,
which is the state the old scrollback-only command could not touch."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "for i in $(seq 5); do printf 'line%s\\n' $i; done; \
                        printf '\\033]133;A\\033\\\\top-of-prompt\\n$ '; exec cat")
    (should (cooked-tests--settle
             (lambda () (string-match-p "top-of-prompt" (cooked-tests--text)))))
    (cooked-clear-scrollback)
    (should-not (string-match-p "line5" (cooked-tests--text)))
    (should (string-prefix-p "top-of-prompt\n$" (cooked-tests--text)))))

(ert-deftest cooked-title-renames-the-buffer-only-when-asked ()
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '\\033]2;running-thing\\007'; sleep 5")
    (let ((original (buffer-name)))
      (should (cooked-tests--settle (lambda () (equal cooked--title "running-thing"))))
      ;; Default is off: a name that moves under you is hard to find again.
      (should (equal (buffer-name) original)))))

(ert-deftest cooked-second-window-follows-new-output ()
  "Emacs never re-syncs a window's point to the buffer's on its own, so a
second, non-selected window on a busy cooked buffer must be moved explicitly
to keep tracking new output the way the selected window already does."
  (cooked-tests--with-session (list "/bin/sh" "-c" cooked-tests--two-stage-output-script)
    (should (cooked-tests--settle
             (lambda () (string-match-p "line40" (cooked-tests--text)))))
    (let ((main (selected-window))
          (buffer (current-buffer)))
      (delete-other-windows)
      (set-window-buffer main buffer)
      (let ((other (split-window main nil 'below)))
        (set-window-buffer other buffer)
        (should (= (length (get-buffer-window-list buffer nil t)) 2))
        ;; A freshly split window starts at the buffer's point: already following.
        (should (>= (window-point other) (marker-position cooked--screen-start)))
        (should (cooked-tests--settle
                 (lambda () (string-match-p "AFTER" (cooked-tests--text)))))
        ;; It tracked the new cursor without ever being the selected window.
        (should (= (window-point other) (point)))
        (delete-window other)))))

(ert-deftest cooked-second-window-reading-history-is-left-alone ()
  "A window scrolled up into history is the user choosing to look elsewhere,
not a window that fell behind -- later output must not yank it back to the
cursor, the same restraint `follow' already shows for the buffer's own point."
  (cooked-tests--with-session (list "/bin/sh" "-c" cooked-tests--two-stage-output-script)
    (should (cooked-tests--settle
             (lambda () (string-match-p "line40" (cooked-tests--text)))))
    (should (> (marker-position cooked--screen-start) (point-min)))
    (let ((main (selected-window))
          (buffer (current-buffer))
          (reading (point-min)))
      (delete-other-windows)
      (set-window-buffer main buffer)
      (let ((other (split-window main nil 'below)))
        (set-window-buffer other buffer)
        (set-window-point other reading)
        (should (cooked-tests--settle
                 (lambda () (string-match-p "AFTER" (cooked-tests--text)))))
        (should (= (window-point other) reading))
        (delete-window other)))))

(ert-deftest cooked-new-output-recenters-a-following-window ()
  "`scroll-conservatively' is not a redisplay guarantee when output arrives
from a process filter rather than a command -- `comint-postoutput-scroll-
to-bottom' recenters explicitly for the same reason, which is the pattern
`cooked--apply' mirrors.  Batch Emacs has no real display for `pos-visible-
in-window-p' to check against, so this asserts the mechanism fires rather
than its rendered effect."
  (cooked-tests--with-session (list "/bin/sh" "-c" cooked-tests--two-stage-output-script)
    (should (cooked-tests--settle
             (lambda () (string-match-p "line40" (cooked-tests--text)))))
    (should-not cooked--alt)
    ;; The selected window only counts if it is actually showing this buffer —
    ;; without this, `cooked--apply' correctly declines to recenter a window
    ;; that has nothing to do with this session.
    (set-window-buffer (selected-window) (current-buffer))
    (let ((calls 0))
      (cl-letf (((symbol-function 'recenter)
                 (lambda (&rest _) (cl-incf calls))))
        (should (cooked-tests--settle
                 (lambda () (string-match-p "AFTER" (cooked-tests--text))))))
      (should (> calls 0)))))

(ert-deftest cooked-recenter-never-touches-an-unrelated-selected-window ()
  "Output can arrive from a process filter for a session that is not on
screen anywhere -- whatever window happens to be selected at that moment is
almost certainly showing something else, and recentering it would scroll the
user's actual work out from under them."
  (cooked-tests--with-session (list "/bin/sh" "-c" cooked-tests--two-stage-output-script)
    (should (cooked-tests--settle
             (lambda () (string-match-p "line40" (cooked-tests--text)))))
    (should-not (eq (window-buffer (selected-window)) (current-buffer)))
    (let ((calls 0))
      (cl-letf (((symbol-function 'recenter)
                 (lambda (&rest _) (cl-incf calls))))
        (should (cooked-tests--settle
                 (lambda () (string-match-p "AFTER" (cooked-tests--text))))))
      (should (= calls 0)))))

(ert-deftest cooked-wrapped-lines-rejoin-in-scrollback ()
  "A line the terminal wrapped is one line again, so yanking history does not
pick up newlines nobody typed, and a wider window re-wraps it for free."
  (let ((buffer (generate-new-buffer "*cooked-wrap*")))
    (unwind-protect
        (with-current-buffer buffer
          (cooked-mode)
          (setq cooked--rows 4 cooked--cols 20 cooked--last-size '(4 . 20))
          ;; 60 characters through a 20-column terminal: three screen rows, one line.
          (cooked--start '("/bin/sh" "-c"
                           "printf 'AAAAAAAAAABBBBBBBBBBCCCCCCCCCCDDDDDDDDDDEEEEEEEEEEFFFFFFFFFF\\n'; \
                            printf 'tail\\n'; printf 'x\\n'; printf 'y\\n'; sleep 5"))
          (cooked--refresh-keymap)
          (should (cooked-tests--settle
                   (lambda () (string-match-p "FFFFFFFFFF" (cooked-tests--text)))))
          (goto-char (point-min))
          (should (looking-at-p (regexp-quote (concat "AAAAAAAAAABBBBBBBBBB"
                                                      "CCCCCCCCCCDDDDDDDDDD"
                                                      "EEEEEEEEEEFFFFFFFFFF")))))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer))))

(ert-deftest cooked-a-line-straddling-the-scrollback-seam-keeps-its-head ()
  "A wrapped row that scrolls off is the start of a line whose rest is still on
the grid, so it is handed over without a newline and screen row 0 continues it.
Rendering row 0 at the start of that buffer line instead of at `cooked--screen-start'
deleted the head it was supposed to continue, losing a row per eviction."
  (let ((buffer (generate-new-buffer "*cooked-seam*")))
    (unwind-protect
        (with-current-buffer buffer
          (cooked-mode)
          (setq cooked--rows 4 cooked--cols 10 cooked--last-size '(4 . 10))
          ;; 59 characters of one line through a 4x10 terminal: six rows, so the
          ;; first two scroll off while the line they belong to is still on screen.
          (cooked--start '("/bin/sh" "-c"
                           "printf '%s' 00000000001111111111222222222233333333334444444444555555555; \
                            sleep 5"))
          (cooked--refresh-keymap)
          (should (cooked-tests--settle
                   (lambda () (string-match-p "555555555" (cooked-tests--text)))))
          (should (string-match-p
                   "00000000001111111111"
                   (string-replace "\n" "" (cooked-tests--text)))))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer))))

(ert-deftest cooked-a-line-across-the-seam-rewraps-as-one-line ()
  "The head is in the buffer and the tail on the grid, so a rewrap has to resume
the line where the buffer wraps it rather than starting a fresh one.  Widening
to 30 must leave all 59 characters on a single buffer line — one logical line,
which Emacs then wraps into two visual rows — and narrowing must give the text
back unchanged."
  (let ((whole (concat "00000000001111111111222222222233333333334444444444"
                       "555555555")))
    (cooked-tests--with-straddling-line
      (should (string-match-p whole (cooked-tests--unwrapped)))

      (cooked-tests--resize 4 30)
      (should (string-match-p whole (cooked-tests--unwrapped)))
      (should (member whole (split-string (cooked-tests--text) "\n")))

      (cooked-tests--resize 4 10)
      (should (string-match-p whole (cooked-tests--unwrapped)))
      (cooked--check-seam))))

(ert-deftest cooked-a-padded-line-across-the-seam-keeps-its-padding ()
  "A continuation row's trailing blanks are interior to its line, so they have to
survive the trip into the buffer.  Trimming them as though they ended the line
pulled the text after them forward, both losing the alignment and leaving the
buffer holding fewer characters of the line than the emulator believes it handed
over — which is the offset seam a later rewrap turns into a visible one."
  (let ((whole (string-trim-right cooked-tests--padded-seam-line)))
    (cooked-tests--with-padded-straddling-line
      (cooked--check-seam)
      ;; Wide enough that the whole line is one buffer line: the part in scrollback plus
      ;; the row that continues it.  Checked here rather than at 10 because a *live* row
      ;; is rendered with its trailing blanks trimmed, each on its own buffer line — it is
      ;; still a rectangle on a grid, and only on the way into scrollback does a row
      ;; become part of a logical line that has to keep its interior padding.
      (cooked-tests--resize 4 30)
      (should (string-match-p whole (cooked-tests--unwrapped)))
      (cooked--check-seam)

      ;; Back down and up again: the padding has now been through the seam twice, in both
      ;; directions, which is where a lost column compounds rather than cancelling out.
      (cooked-tests--resize 4 10)
      (cooked--check-seam)
      (cooked-tests--resize 4 30)
      (should (string-match-p whole (cooked-tests--unwrapped)))
      (cooked--check-seam))))

(ert-deftest cooked-clearing-scrollback-across-the-seam-keeps-the-screen ()
  "Discarding scrollback can cut a line in half: its head is scrollback and its
tail is the top of the screen.  The screen must survive intact, and the emulator
must be told, so the next rewrap does not resume a line that is gone.

Driven through `cooked--discard-scrollback' rather than through
`cooked-clear-scrollback', which is about the seam bookkeeping alone: the
command also drops the rows above the prompt, so it would take the screen this
is watching with it.  The child's own `CSI 3 J' arrives here by the same route."
  (cooked-tests--with-straddling-line
    (cooked--discard-scrollback (cooked--screen-start-position))
    (should (string-prefix-p "2222222222" (cooked-tests--text)))
    ;; The one place state flows Emacs -> Rust: cutting the head has to reach the
    ;; emulator's carry, or it resumes a line that is no longer there.  Now checkable
    ;; from the other side rather than only visible in the next rewrap's output.
    (cooked--check-seam)

    (cooked-tests--resize 4 30)
    (should (string-match-p "222222222233333333334444444444555555555"
                            (cooked-tests--unwrapped)))
    (should-not (string-match-p "0000000000" (cooked-tests--text)))))

(ert-deftest cooked-clearing-to-the-prompt-across-the-seam-keeps-the-seam-honest ()
  "The command cuts on both sides of the seam in one go, and the emulator has to
be told about both halves: Emacs' text through `cooked--discard-scrollback', and
its own rows through `cooked--clear-to-prompt', which drops the carry with them.

No OSC 133 here, so the cut is at the cursor's row -- and the line straddling
the seam is above it in every part but its tail."
  (cooked-tests--with-straddling-line
    (cooked-clear-scrollback)
    (should (equal (string-trim (cooked-tests--text)) "555555555"))
    (cooked--check-seam)

    (cooked-tests--resize 4 30)
    (should-not (string-match-p "0000000000" (cooked-tests--text)))
    (should (equal (string-trim (cooked-tests--text)) "555555555"))
    (cooked--check-seam)))

(ert-deftest cooked-a-resize-mid-alt-does-not-weld-history-onto-the-live-row ()
  "A resize can evict primary rows into scrollback while a full-screen program
owns the alt screen — the primary keeps running underneath, and its history is
still history.  When the evicted row was itself a wrapped continuation, the
text that used to follow it on the primary grid is not what comes next in the
buffer any more: alt's own row 0 is.  That row 0 must still start its own
buffer line rather than being welded, without a newline, to the tail of
scrollback that just arrived — the seam only closes correctly when whatever
follows really is the continuation."
  (let ((buffer (generate-new-buffer "*cooked-seam-alt*")))
    (unwind-protect
        (with-current-buffer buffer
          (cooked-mode)
          (setq cooked--rows 4 cooked--cols 10 cooked--last-size '(4 . 10))
          ;; The child waits on its own stdin between the straddling write and the
          ;; alt switch, so the test can settle on each stage instead of racing a
          ;; handful of printfs that would otherwise land in one drain together.
          (cooked--start '("/bin/sh" "-c"
                           "printf '%s' 00000000001111111111222222222233333333334444444444555555555; \
                            read -r _; \
                            printf '\\033[?1049h'; printf 'inalt\\n'; \
                            sleep 5"))
          (cooked--refresh-keymap)
          (should (cooked-tests--settle
                   (lambda () (string-match-p "555555555" (cooked-tests--text)))))

          (cooked--send cooked--session "\n")
          (should (cooked-tests--settle (lambda () cooked--alt)))
          (should (cooked-tests--settle
                   (lambda ()
                     (save-restriction
                       (widen)
                       (string-match-p "inalt" (buffer-substring-no-properties
                                                (point-min) (point-max)))))))

          ;; Same width, fewer rows: the plain truncate-from-top path, which
          ;; evicts "2222222222" — a wrapped row — off the still-live primary grid.
          (cooked-tests--resize 3 10)

          (save-restriction
            (widen)
            (should (eq (char-before (marker-position cooked--screen-start)) ?\n))
            (should (string-match-p "inalt" (buffer-substring-no-properties
                                             (point-min) (point-max))))))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer))))

(ert-deftest cooked-wrapped-lines-stay-split-when-asked ()
  (let ((buffer (generate-new-buffer "*cooked-wrap2*")))
    (unwind-protect
        (with-current-buffer buffer
          (cooked-mode)
          (setq cooked--rows 4 cooked--cols 20 cooked--last-size '(4 . 20)
                cooked-rejoin-wrapped-lines nil)
          (cooked--start '("/bin/sh" "-c"
                           "printf 'AAAAAAAAAABBBBBBBBBBCCCCCCCCCCDDDDDDDDDDEEEEEEEEEEFFFFFFFFFF\\n'; \
                            printf 'tail\\n'; printf 'x\\n'; printf 'y\\n'; sleep 5"))
          (cooked--refresh-keymap)
          (should (cooked-tests--settle
                   (lambda () (string-match-p "FFFFFFFFFF" (cooked-tests--text)))))
          ;; The literal terminal view: one buffer line per screen row.
          (goto-char (point-min))
          (should (looking-at-p "AAAAAAAAAABBBBBBBBBB$")))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer))))

(ert-deftest cooked-guard-row-width-trims-a-row-that-would-softwrap ()
  "A 26-character row whose `string-width' is 26 in a 26-column viewport — it
should fit, but the mock says `vertical-motion' wraps at character 10,
simulating the `é' rendering wider than one column.  The guard trims."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (let ((cooked-rejoin-wrapped-lines t)
          (inhibit-read-only t))
      (insert (make-string 5 ?x) "é" (make-string 20 ?y) "\n")
      (cooked-tests--with-mocked-wrap 10 (cooked--guard-row-width (point-min)))
      (goto-char (point-min))
      (should (= (- (line-end-position) (point-min)) 10))
      ;; A terminal frame, so the marker spends the last column rather than the fringe.
      (should (equal (get-text-property (1- (line-end-position)) 'display) "$")))))

(ert-deftest cooked-guard-row-width-leaves-a-row-that-fits-alone ()
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (let ((cooked-rejoin-wrapped-lines t)
          (inhibit-read-only t))
      (insert "é\n")
      (cooked-tests--with-mocked-wrap 10 (cooked--guard-row-width (point-min)))
      (should (equal (buffer-string) "é\n"))
      (should-not (get-text-property (point-min) 'display)))))

(ert-deftest cooked-guard-row-width-skips-pure-ascii-rows-on-a-terminal-frame ()
  "A terminal frame has no font-shaping engine, so a plain ASCII row cannot
disagree with cooked's width model there -- skipped as a cheap fast path,
exercised here by leaving a row Emacs would (per the mock) report as wrapped
untouched, since it never contains anything but ASCII."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (let ((cooked-rejoin-wrapped-lines t)
          (inhibit-read-only t)
          (text (concat (make-string 40 ?x) "\n")))
      (insert text)
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil)))
        (cooked-tests--with-mocked-wrap 10 (cooked--guard-row-width (point-min))))
      (should (equal (buffer-string) text)))))

(ert-deftest cooked-guard-row-width-checks-pure-ascii-rows-on-a-graphical-frame ()
  "On a graphical frame, font shaping can turn a run of plain ASCII (a `->' or
`!=' ligature, say) into a glyph no narrower-font metric predicts, so the
fast path above must not apply -- a pure-ASCII row still gets trimmed there.
A pure-ASCII row still gets trimmed there."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (let ((cooked-rejoin-wrapped-lines t)
          (inhibit-read-only t))
      (insert (make-string 40 ?x) "\n")
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
        (cooked-tests--with-mocked-wrap 10 (cooked--guard-row-width (point-min))))
      (goto-char (point-min))
      (should (= (- (line-end-position) (point-min)) 10))
      ;; The fringe is outside the text area, so the marker costs no column: it rides an
      ;; overlay string, and the character it is anchored to is still the row's own.
      (should-not (get-text-property (1- (line-end-position)) 'display))
      ;; Anchored at the row's *start*, as a `before-string'.  At the end it needs a
      ;; column's worth of room to be placed in, which a row the trim left flush with
      ;; the right edge of the text area does not have -- see `cooked--mark-truncation'.
      (let ((overlay (car (overlays-in (point-min) (1+ (point-min))))))
        (should (overlay-get overlay 'cooked-truncation))
        (should (= (overlay-start overlay) (point-min)))
        (should-not (overlay-get overlay 'after-string))
        (let ((spec (get-text-property 0 'display (overlay-get overlay 'before-string))))
          (should (eq (car spec) 'right-fringe))
          ;; A real bitmap, not just a plausible-looking name: `right-truncation' was
          ;; not one, so the marker drew nothing for as long as it was spelled that way.
          (should (memq (cadr spec) fringe-bitmaps)))))))

(ert-deftest cooked-guard-row-width-does-nothing-without-rejoin ()
  "When `cooked-rejoin-wrapped-lines' is nil, `truncate-lines' is already t
buffer-wide (see `cooked-mode'), so a softwrap is already structurally
impossible and this guard would only be redundant work."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (let ((cooked-rejoin-wrapped-lines nil)
          (inhibit-read-only t)
          (text (concat (make-string 5 ?x) "é" (make-string 20 ?y) "\n")))
      (insert text)
      (cooked-tests--with-mocked-wrap 10 (cooked--guard-row-width (point-min)))
      (should (equal (buffer-string) text)))))

(ert-deftest cooked-guard-row-width-leaves-a-non-wrapping-row-with-a-nonblank-neighbor-alone ()
  "A row that does not actually wrap must be left alone even when the row below
it is non-blank. `(line-end-position)' has to be read before `vertical-motion'
moves point, not after: read after, on a row that does not wrap at all,
`vertical-motion' lands at the start of the next buffer line, and that next
line's own end -- almost always past a one-line hop -- was being mistaken for
how far the trimmed row was allowed to extend. That false positive doesn't
just fail to trim: it deletes real characters, one per iteration, until this
row is gone. At `point-min' that emptying is also what used to crash
redisplay with `args-out-of-range' (see the test below for what happens to a
row that isn't at `point-min')."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (let ((cooked-rejoin-wrapped-lines t)
          (inhibit-read-only t)
          (text "é\nNEXT\n"))
      (insert text)
      (cooked--guard-row-width (point-min))
      (should (equal (buffer-string) text)))))

(ert-deftest cooked-guard-row-width-measures-in-the-buffer-s-own-window ()
  "The bug this guard is one wrong window away from causing.

`vertical-motion' measures in the selected window unless told otherwise, and
the selected window is routinely not one this buffer is in: the minibuffer
throughout a completion session previewing the buffer beside it, or a
neighbouring window while the frame is resized.  Measured against a narrower
foreign window, every row that reaches the right edge reads as wrapped, and the
guard trims it -- one character at a time, down to what that other window could
have held.  A full-width row of box drawing loses everything after its first
cell or two, and stays lost until something damages the row and rewrites it.

Asserted as \"which window was Emacs' layout asked about\", since that is the
whole of the fix; the mock reports no wrap, so nothing is trimmed and the
answer is not tangled up with what a trim would have done."
  (let ((buffer (generate-new-buffer "*cooked-layout-window*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (let* ((elsewhere (selected-window))
                 (ours (split-window elsewhere)))
            (set-window-buffer ours buffer)
            (select-window elsewhere)
            (with-current-buffer buffer
              (cooked-mode)
              (let ((cooked-rejoin-wrapped-lines t)
                    (inhibit-read-only t)
                    (asked nil))
                (insert "é" (make-string 20 ?x) "\n")
                (cl-letf (((symbol-function 'vertical-motion)
                           (lambda (_lines &optional window &rest _)
                             (push window asked)
                             (goto-char (point-max)))))
                  (cooked--guard-row-width (point-min)))
                (should asked)
                (should-not (memq elsewhere asked))
                (should (cl-every (lambda (window) (eq window ours)) asked))))))
      (kill-buffer buffer))))

(ert-deftest cooked-guard-row-width-skips-a-buffer-displayed-nowhere ()
  "A buffer on no window has no layout to disagree with, so there is nothing to
measure against and nothing to trim -- and no selected window to be tempted by,
since that one is showing somebody else's buffer.  A render into a hidden
buffer therefore keeps its rows whole; displaying it resizes the session, which
marks every row damaged and rewrites them against the window it now has."
  (with-temp-buffer
    (cooked-mode)
    (let ((cooked-rejoin-wrapped-lines t)
          (inhibit-read-only t)
          (text (concat "é" (make-string 40 ?x) "\n")))
      (insert text)
      (cooked-tests--with-mocked-wrap 10 (cooked--guard-row-width (point-min)))
      (should (equal (buffer-string) text)))))

(ert-deftest cooked-guard-row-width-trims-against-cooked-cols-not-a-fresh-window-measurement ()
  "During a live resize drag, WINDOW's pixel geometry can already report a
narrower `window-max-chars-per-line' than `cooked--cols' before
`cooked--sync-size' has caught up and rewrapped the native core to match.
A row rendered against the still-current `cooked--cols' must not be mistaken
for genuinely-too-wide scrollback merely because a fresh measurement of
WINDOW now answers smaller -- it is trimmed and marked exactly as it would be
if `window-max-chars-per-line' agreed with `cooked--cols', because
`cooked--cols', not WINDOW, is what this row was actually rendered against."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (let ((cooked-rejoin-wrapped-lines t)
          (cooked--cols 26)
          (inhibit-read-only t))
      (insert (make-string 5 ?x) "é" (make-string 20 ?y) "\n")
      (cl-letf (((symbol-function 'window-max-chars-per-line) (lambda (&rest _) 10))
                ((symbol-function 'vertical-motion)
                 (lambda (&rest _) (goto-char (min (point-max) (+ (point) 10))))))
        (cooked--guard-row-width (point-min)))
      (goto-char (point-min))
      (should (= (- (line-end-position) (point-min)) 10))
      (should (equal (get-text-property (1- (line-end-position)) 'display) "$")))))

(ert-deftest cooked-guard-row-width-leaves-a-genuinely-wider-row-alone ()
  "A row from a wider grid -- scrollback from before a resize narrowed the
window, or the grid simply wider than the viewport -- should soft-wrap
normally.  The guard must not truncate it: the overflow is real content, not a
glyph-width disagreement.  The row has `string-width' 26, `cooked--cols' only
10 -- the resize that narrowed the terminal has already landed, which is what
makes this row genuinely stale rather than merely mismeasured against a
window whose pixel geometry has moved ahead of `cooked--cols' (see the
comment in `cooked--guard-row-width')."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (let ((cooked-rejoin-wrapped-lines t)
          (cooked--cols 10)
          (inhibit-read-only t)
          (text (concat (make-string 5 ?x) "é" (make-string 20 ?y) "\n")))
      (insert text)
      (cl-letf (((symbol-function 'vertical-motion)
                 (lambda (&rest _) (goto-char (min (point-max) (+ (point) 10))))))
        (cooked--guard-row-width (point-min)))
      (should (equal (buffer-string) text)))))

(ert-deftest cooked-guard-row-width-does-not-eat-into-neighbouring-rows ()
  "The same false positive away from row 0 does not crash -- `end-of-line'
from START still has somewhere to go, the row above -- but before the fix it
ran on regardless: once START's row was emptied, deleting \"the character
before START\" ate the newline above it, merging START into the row above,
and the same broken check then chewed through the entire row below too."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (let ((cooked-rejoin-wrapped-lines t)
          (inhibit-read-only t)
          (text "PREVROW\né\nNEXTROW\nTAILROW\n"))
      (insert text)
      (goto-char (point-min))
      (forward-line 1)
      (cooked--guard-row-width (point))
      (should (equal (buffer-string) text)))))

(ert-deftest cooked-two-commands-in-one-drain-keep-separate-regions ()
  "The case anchors exist for.

A child fast enough to finish two commands between redisplays lands both sets of
OSC 133 marks in a single drain.  Before the marks carried anchors, every one of
them resolved to the same place — the cursor as of the end of that drain — so the
two commands were recorded as regions ending in the same spot, and navigation
could not tell them apart.  Driven by a bare printf rather than a real shell so
that the whole burst is one write, and so lands in one drain deterministically."
  (cooked-tests--with-session
      '("/bin/sh" "-c"
        "printf '\\033]133;C\\007first\\n\\033]133;D;0\\007\
\\033]133;C\\007second\\n\\033]133;D;0\\007'; sleep 5")
    (should (cooked-tests--settle (lambda () (= (length cooked--commands) 2))))
    (pcase-let ((`(,newer ,older) cooked--commands))
      ;; Each command's output is where it actually was, not where the drain ended.
      (should (string-match-p
               "first"
               (buffer-substring-no-properties (cooked--command-start-position older)
                                               (cooked--command-end-position older))))
      (should (string-match-p
               "second"
               (buffer-substring-no-properties (cooked--command-start-position newer)
                                               (cooked--command-end-position newer))))
      ;; And the regions are distinct rather than collapsed onto one another.
      (should (< (cooked--command-start-position older)
                 (cooked--command-start-position newer)))
      (should (<= (cooked--command-end-position older)
                  (cooked--command-start-position newer))))))

(ert-deftest cooked-a-mark-on-a-scrolled-row-lands-in-the-scrollback ()
  "An anchor outlives the row it was taken from.

The command starts, then prints enough to push its own first row off the screen
before Emacs ever sees it.  The mark has to resolve into the scrollback text
this drain inserted, not to some row still on the grid."
  (let ((buffer (generate-new-buffer "*cooked-anchor*")))
    (unwind-protect
        (with-current-buffer buffer
          (cooked-mode)
          (setq cooked--rows 4 cooked--cols 20 cooked--last-size '(4 . 20))
          (cooked--start '("/bin/sh" "-c"
                           "printf '\\033]133;C\\007marked\\n'; \
                            for i in 1 2 3 4 5 6 7 8; do echo pad$i; done; \
                            printf '\\033]133;D;0\\007'; sleep 5"))
          (cooked--refresh-keymap)
          (should (cooked-tests--settle (lambda () (= (length cooked--commands) 1))))
          (let* ((record (car cooked--commands))
                 (start (cooked--command-start-position record)))
            ;; It landed above the live screen, on the row that said "marked".
            (should (< start (marker-position cooked--screen-start)))
            (should (string-match-p
                     "\\`marked"
                     (buffer-substring-no-properties
                      start (min (point-max) (+ start 6)))))))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer))))

(ert-deftest cooked-refresh-rebuilds-a-corrupted-screen ()
  "Resync throws the screen region away and has the emulator re-send it."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'alpha\\nbeta\\n'; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "beta" (cooked-tests--text)))))
    ;; Vandalise the screen region the way a half-applied redisplay would.
    (let ((inhibit-read-only t))
      (delete-region (marker-position cooked--screen-start) (point-max))
      (goto-char (point-max))
      (insert "wreckage"))
    (should (string-match-p "wreckage" (cooked-tests--text)))
    (cooked-refresh)
    (should-not (string-match-p "wreckage" (cooked-tests--text)))
    (should (string-match-p "alpha" (cooked-tests--text)))
    (should (string-match-p "beta" (cooked-tests--text)))))

(ert-deftest cooked-a-failed-redisplay-resyncs-rather-than-freezing ()
  "A drain that signals part-way through must not cost the buffer its content.

Damage is cleared by the drain that reports it, so rows dropped by a redisplay
that failed are never offered again: nothing short of asking the core to re-send
the screen brings them back.  The test turns on that — the text carried by the
failed drain has to be on screen afterwards, and it is only there because the
resync went and got it."
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle (lambda () cooked--session)))
    ;; Fail exactly one `cooked--apply', from inside the filter where Emacs would
    ;; otherwise swallow the error entirely.
    (let* ((failed nil)
           (advice (lambda (orig &rest args)
                     (if failed
                         (apply orig args)
                       (setq failed t)
                       (error "cooked-tests: deliberate redisplay failure")))))
      (advice-add 'cooked--apply :around advice)
      (unwind-protect
          (progn
            (cooked--send cooked--session "hello\n")
            (should (cooked-tests--settle (lambda () failed))))
        (advice-remove 'cooked--apply advice)))
    ;; The echo the failed drain was carrying is on screen regardless.
    (should (cooked-tests--settle
             (lambda () (string-match-p "hello" (cooked-tests--text)))))
    ;; And the session keeps rendering rather than being wedged.
    (cooked--send cooked--session "afterwards\n")
    (should (cooked-tests--settle
             (lambda () (string-match-p "afterwards" (cooked-tests--text)))))))

(ert-deftest cooked-a-still-render-at-a-prompt-holds-the-view-but-not-the-line ()
  "The three axes come apart at a prompt.

`still\=' there means the view stops chasing the child -- a program repainting a
tty it never took out of canonical mode is exactly what that is for, and gating
the freeze on forwarding made it unreachable in that case.  The keyboard half of
the mode lapses instead: Emacs owns the line, so nothing is read-only and
`cooked-input-map\=' stays installed.

Point inside the pending input is the one thing the held view cannot speak for.
That region is lifted out and rebuilt around the child\='s cursor on every drain,
so \"stay where you are\" is not a position a *buffer position* can hold; the
offset into the region is, because the text is reinserted verbatim.  Carrying
that offset is what keeps the user where they were typing, and without it a
repaint would drop them at the start of their own line."
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle
             (lambda () (and (cooked--input-state-p) (cooked--input-start-position)))))
    (cooked--replace-input "hello")
    (setq cooked--input-mode 'still)
    (should-not (cooked--follow-p))
    (should-not (cooked--suspended-p))
    (should-not buffer-read-only)
    ;; Point in the user's own text: the drain carries it by *offset* into the
    ;; region rather than leaving it where the lift collapsed it.  Mid-word on
    ;; purpose -- at offset 0 a carried point and a collapsed one are the same
    ;; position, so the start of the line cannot tell the two apart.
    (goto-char (+ (cooked--input-start-position) 3))
    (cooked--send-to-child "x\n")
    (should (cooked-tests--settle
             (lambda () (string-search "x" (cooked-tests--text)))))
    (should (equal (cooked--pending-input) "hello"))
    (should (= (point) (+ (car (cooked--input-region)) 3)))
    ;; Point parked out in the screen instead: held, which is the whole of what
    ;; `still' buys here.  `cooked--track-wandering' has to notice it for that,
    ;; and it used to ask whether the child owned the keyboard -- which at a
    ;; prompt is the one answer that leaves nothing pinning point at all.
    (goto-char (cooked--screen-start-position))
    (cooked--track-wandering)
    (should cooked--wandered)
    (let ((cell (cooked--screen-cell)))
      (cooked--send-to-child "y\n")
      (should (cooked-tests--settle
               (lambda () (string-search "y" (cooked-tests--text)))))
      (should (equal (cooked--screen-cell) cell)))))


;;;; The scrollback cap

(defun cooked-tests--scrollback-lines ()
  "Lines of transcript above the live screen."
  (save-restriction
    (widen)
    (1- (line-number-at-pos (cooked--screen-start-position) t))))

(defun cooked-tests--flood (n)
  "A shell command printing N numbered lines and then waiting."
  (list "/bin/sh" "-c"
        (format "i=0; while [ $i -lt %d ]; do echo line$i; i=$((i+1)); done; sleep 5" n)))

(ert-deftest cooked-scrollback-cap-holds-under-a-flood ()
  "Without a cap a session grows for as long as it runs.  The buffer is allowed
to overshoot by `cooked--scrollback-slack\=', so this asserts a bound rather than
an exact count."
  (let ((cooked-scrollback-lines 50))
    (cooked-tests--with-session (cooked-tests--flood 600)
      (should (cooked-tests--settle
               (lambda () (string-match-p "line599" (cooked-tests--text)))))
      (should (<= (cooked-tests--scrollback-lines)
                  (+ cooked-scrollback-lines
                     (round (* cooked-scrollback-lines cooked--scrollback-slack))
                     1)))
      ;; The recent end is what survives; the old end is what went.
      (should (string-match-p "line599" (cooked-tests--text)))
      (should-not (string-match-p "line0\n" (cooked-tests--text))))))

(ert-deftest cooked-scrollback-cap-nil-keeps-everything ()
  (let ((cooked-scrollback-lines nil))
    (cooked-tests--with-session (cooked-tests--flood 400)
      (should (cooked-tests--settle
               (lambda () (string-match-p "line399" (cooked-tests--text)))))
      (should (string-match-p "line0\n" (cooked-tests--text)))
      (should (> (cooked-tests--scrollback-lines) 300)))))

(ert-deftest cooked-scrollback-cap-keeps-the-seam-honest ()
  "A trim is a deletion above `cooked--screen-start\=', so it owes the emulator
the news that its top row begins a line again.  Left unsaid, the desync is
silent until the next resize -- which is what this drives."
  (let ((cooked-scrollback-lines 40))
    (cooked-tests--with-session (cooked-tests--flood 500)
      (should (cooked-tests--settle
               (lambda () (string-match-p "line499" (cooked-tests--text)))))
      (cooked--check-seam)
      (cooked-tests--resize 4 30)
      (cooked--check-seam)
      (cooked-tests--resize 4 10)
      (cooked--check-seam))))

(ert-deftest cooked-scrollback-cap-trims-at-a-line-beginning ()
  "`cooked--discard-scrollback\=' hands the emulator a seam, and half a line is
not one.  A flood of lines long enough to wrap makes the mid-line cut reachable."
  (let ((cooked-scrollback-lines 30))
    (cooked-tests--with-session
        (list "/bin/sh" "-c"
              "i=0; while [ $i -lt 300 ]; do printf 'w%s-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' $i; i=$((i+1)); done; sleep 5")
      (should (cooked-tests--settle
               (lambda () (string-match-p "w299" (cooked-tests--text)))))
      (save-restriction
        (widen)
        (goto-char (point-min))
        (should (bolp))
        ;; Whatever survived starts at the beginning of some line the child wrote.
        (should (looking-at-p "\\(w[0-9]+-a+\\)?$\\|w[0-9]+-a")))
      (cooked--check-seam))))

(ert-deftest cooked-scrollback-cap-prunes-the-command-records-it-cuts ()
  "A record whose whole region is in the text being cut would survive as an empty
region sitting at the cut, which is indistinguishable from a command that
genuinely printed nothing."
  (let ((cooked-scrollback-lines 40))
    (cooked-tests--with-session
        (list "/bin/sh" "-c"
              (concat "i=0; while [ $i -lt 200 ]; do "
                      "printf '\033]133;C\007'; echo out$i; "
                      "printf '\033]133;D;0\007'; i=$((i+1)); done; sleep 5"))
      (should (cooked-tests--settle
               (lambda () (string-match-p "out199" (cooked-tests--text)))))
      (let ((screen (cooked--screen-start-position)))
        (dolist (command cooked--commands)
          (should (> (cooked--command-end-position command) (point-min)))
          (should (<= (cooked--command-end-position command) (max screen (point-max)))))))))

(provide 'cooked-tests-render)
;;; cooked-tests-render.el ends here

;;;; Inline images
;;
;; Driven through `cooked--apply' with a synthetic update rather than through a
;; child where the resource layer is what is under test, and it is reachable from
;; the drain's shape alone; `cooked-bench.el' builds updates the same way.  The
;; two `kitty' tests at the end drive a real picture the whole way, and
;; `cooked-discarding-the-scrollback-forgets-the-pictures-in-it' drives one
;; across a real scroll.
;;
;; Every test that expects a `display' property calls `cooked-tests--cell' first;
;; see there for why that is the ordinary path in batch rather than a stub.  The
;; cell it gives is 10x20, which is the arithmetic the slice assertions below are
;; written against.

(defun cooked-tests--png ()
  "A tiny valid PNG, built here so the suite needs no fixture file."
  (let* ((ihdr (apply #'unibyte-string
                      (append '(0 0 0 1 0 0 0 1 8 2 0 0 0) nil)))
         (idat (string-to-unibyte
                (base64-decode-string "eJxjZGBg+A8AAQQBAHAgZQU="))))
    (concat (unibyte-string #x89 ?P ?N ?G 13 10 26 10)
            (cooked-tests--png-chunk "IHDR" ihdr)
            (cooked-tests--png-chunk "IDAT" idat)
            (cooked-tests--png-chunk "IEND" ""))))

(defun cooked-tests--png-chunk (tag data)
  "One PNG chunk: length, TAG, DATA, CRC."
  (let* ((body (concat (string-to-unibyte tag) (string-to-unibyte data)))
         (len (length (string-to-unibyte data)))
         (crc (cooked-tests--crc32 body)))
    (concat (unibyte-string (logand (ash len -24) 255) (logand (ash len -16) 255)
                            (logand (ash len -8) 255) (logand len 255))
            body
            (unibyte-string (logand (ash crc -24) 255) (logand (ash crc -16) 255)
                            (logand (ash crc -8) 255) (logand crc 255)))))

(defun cooked-tests--crc32 (bytes)
  "CRC-32 of BYTES, the polynomial PNG uses."
  (let ((crc #xFFFFFFFF))
    (dolist (byte (append (string-to-unibyte bytes) nil))
      (setq crc (logxor crc byte))
      (dotimes (_ 8)
        (setq crc (if (zerop (logand crc 1))
                      (ash crc -1)
                    (logxor (ash crc -1) #xEDB88320)))))
    (logxor crc #xFFFFFFFF)))

(defun cooked-tests--image-update (id cols rows &optional data)
  "An update placing image ID as a COLS by ROWS rectangle on screen row 0."
  (let ((packed (apply #'unibyte-string
                       (cl-loop for c below cols
                                append (list (logand id 255)
                                             (logand (ash id -8) 255)
                                             (logand (ash id -16) 255)
                                             (logand (ash id -24) 255)
                                             0 0
                                             (logand c 255) (logand (ash c -8) 255))))))
    (list :scrolled nil
          :rows (list (cons 0 (list (make-string cols ?\s)
                                    nil
                                    (list (list 0 cols nil nil 0 (cons 'image packed))))))
          :images (and data
                       (list (list id 'png data (* cols 10) (* rows 20) cols rows)))
          :height 12 :used 1 :head 0
          :cursor '(0 0 t block) :alt nil
          :app-cursor nil :keys 'legacy :mode 'raw :events nil :exit nil)))

(ert-deftest cooked-image-cells-each-get-their-own-slice ()
  "Per cell rather than one spec over the rectangle: that is what lets text
overwrite part of a picture, and a scroll split it, without special-casing."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 300")
    (should (cooked-tests--settle (lambda () cooked--session)))
    (cooked-tests--cell)
    (cooked--apply (cooked-tests--image-update 7 3 1 (cooked-tests--png)))
    (goto-char (point-min))
    (dotimes (col 3)
      (let ((display (get-text-property (+ (point-min) col) 'display)))
        (should (eq (car-safe (car-safe display)) 'slice))
        ;; (slice X Y W H) -- X advances a cell per column, Y stays on row 0.
        (should (= (nth 1 (car display)) (* col 10)))
        (should (= (nth 2 (car display)) 0))
        (should (eq (car-safe (cadr display)) 'image))))))

(ert-deftest cooked-image-cells-share-one-decoded-spec ()
  "Every cell slices the same spec, so Emacs decodes the picture once."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 300")
    (should (cooked-tests--settle (lambda () cooked--session)))
    (cooked-tests--cell)
    (cooked--apply (cooked-tests--image-update 7 3 1 (cooked-tests--png)))
    (let ((first (cadr (get-text-property (point-min) 'display)))
          (last (cadr (get-text-property (+ (point-min) 2) 'display))))
      (should (eq first last)))))

(ert-deftest cooked-image-bytes-cross-once-and-are-kept ()
  "The module sends a picture once however often it is placed, so a later
placement naming the same id has to find the bytes still here."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 300")
    (should (cooked-tests--settle (lambda () cooked--session)))
    (cooked-tests--cell)
    (cooked--apply (cooked-tests--image-update 7 3 1 (cooked-tests--png)))
    ;; A second drain places the same id and carries no `:images' at all.
    (cooked--apply (cooked-tests--image-update 7 3 1 nil))
    (should (eq (car-safe (car-safe (get-text-property (point-min) 'display))) 'slice))))

(defun cooked-tests--install-image (id bytes)
  "Install image ID with BYTES bytes of stand-in data."
  (cooked--install-images
   (list (list id 'png (make-string bytes ?x) 10 20 1 1))))

(ert-deftest cooked-image-data-is-accounted-as-it-arrives ()
  "The running total has to match the table, or the cap bounds nothing.  Ids are
content-addressed, so the same id arriving twice is one picture, not two."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 300")
    (should (cooked-tests--settle (lambda () cooked--session)))
    (let ((cooked-image-cache-size nil))
      (cooked-tests--install-image 1 100)
      (cooked-tests--install-image 2 250)
      (should (= cooked--image-bytes 350))
      (should (equal cooked--image-order '(1 2)))
      ;; The module will not send the same id twice, but a re-render must not be
      ;; able to make the total drift if it ever did.
      (cooked-tests--install-image 1 100)
      (should (= cooked--image-bytes 350))
      (should (equal cooked--image-order '(1 2))))))

(ert-deftest cooked-image-cache-drops-the-oldest-past-its-cap ()
  "A session drawing a different picture every frame added an entry per frame and
nothing ever took them away.  Oldest first, because that is the one that
scrolled away longest ago."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 300")
    (should (cooked-tests--settle (lambda () cooked--session)))
    (let ((cooked-image-cache-size 1000))
      (dolist (id '(1 2 3 4))
        (cooked-tests--install-image id 400))
      ;; Four 400-byte pictures do not fit in 1000 bytes; the two oldest go.
      (should (= cooked--image-bytes 800))
      (should (equal cooked--image-order '(3 4)))
      (should-not (gethash 1 cooked--image-data))
      (should-not (gethash 2 cooked--image-data))
      (should (gethash 3 cooked--image-data))
      (should (gethash 4 cooked--image-data)))))

(ert-deftest cooked-the-cap-never-evicts-a-picture-that-is-on-screen ()
  "The cap used to have a second pass that took the oldest regardless, which made
it a real bound and also made it a bug: `cooked--image-spec' answers nil for an
id with no data, so the next resize -- which damages every row of the grid, and
only the grid -- rebuilt the on-grid half of a picture as nothing while its
scrollback half went on drawing.  The cap is soft now, on purpose.  What bounds
an ordinary session is `cooked--collect-images', not this."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 300")
    (should (cooked-tests--settle (lambda () cooked--session)))
    (let ((cooked-image-cache-size 500))
      (cl-letf (((symbol-function 'cooked--image-displayed-p) (lambda (_id) t)))
        (dolist (id '(1 2 3))
          (cooked-tests--install-image id 400)))
      (should (= cooked--image-bytes 1200))
      (should (equal cooked--image-order '(1 2 3)))
      (should (gethash 1 cooked--image-data)))))

(ert-deftest cooked-an-image-lives-as-long-as-the-text-showing-it ()
  "The eviction model: an image is a resource belonging to the rows that display
it, so it goes when the last of those rows does and not before.  Same shape as
the `cooked--commands' prune it sits beside in `cooked--discard-scrollback'."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 300")
    (should (cooked-tests--settle (lambda () cooked--session)))
    (cooked-tests--cell)
    (cooked--apply (cooked-tests--image-update 7 3 1 (cooked-tests--png)))
    ;; The ids under a cut are candidates, not verdicts: the question is whether
    ;; that was the last of them, and ids are content-addressed, so the same
    ;; picture is very often above the seam and on the grid at once.
    (let ((ids (cooked--release-images (point-min) (+ (point-min) 3))))
      (should (equal ids '(7)))
      (cooked--collect-images ids)
      (should (gethash 7 cooked--image-data)))
    (let ((ids (cooked--release-images (point-min) (point-max)))
          (inhibit-read-only t))
      (delete-region (point-min) (point-max))
      (cooked--collect-images ids)
      (should-not (gethash 7 cooked--image-data))
      (should (= cooked--image-bytes 0))
      (should-not cooked--image-order))))

(ert-deftest cooked-image-cache-spends-what-nothing-is-showing-first ()
  "Given a choice, evict the picture whose loss is invisible rather than the
oldest one still on screen."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 300")
    (should (cooked-tests--settle (lambda () cooked--session)))
    (let ((cooked-image-cache-size nil))
      (dolist (id '(1 2 3))
        (cooked-tests--install-image id 400)))
    ;; 1 is the oldest, but only 2 is unclaimed, so 2 is what pays.
    (let ((cooked-image-cache-size 800))
      (cl-letf (((symbol-function 'cooked--image-displayed-p)
                 (lambda (id) (memq id '(1 3)))))
        (cooked--evict-images)))
    (should (equal cooked--image-order '(1 3)))
    (should-not (gethash 2 cooked--image-data))))

(ert-deftest cooked-image-cache-size-nil-keeps-everything ()
  "The opt-out has to actually opt out."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 300")
    (should (cooked-tests--settle (lambda () cooked--session)))
    (let ((cooked-image-cache-size nil))
      (dotimes (id 20)
        (cooked-tests--install-image id 1000))
      (should (= cooked--image-bytes 20000))
      (should (= (hash-table-count cooked--image-data) 20)))))

(ert-deftest cooked-a-displayed-image-is-recognised-as-displayed ()
  "`cooked--image-displayed-p\=' reads the weak spec table, which is the only free
signal for \"something is still showing this\".  If it ever stopped answering yes
for a picture on screen, eviction would quietly start preferring live images."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 300")
    (should (cooked-tests--settle (lambda () cooked--session)))
    (cooked-tests--cell)
    (cooked--apply (cooked-tests--image-update 7 3 1 (cooked-tests--png)))
    (should (cooked--image-displayed-p 7))
    (should-not (cooked--image-displayed-p 8))))

(ert-deftest cooked-image-placement-without-data-renders-as-blanks ()
  "An id this buffer was never told about must not break the row: the cells are
blanks on the grid, and they stay blanks here."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 300")
    (should (cooked-tests--settle (lambda () cooked--session)))
    (cooked-tests--cell)
    (cooked--apply (cooked-tests--image-update 99 3 1 nil))
    (should-not (get-text-property (point-min) 'display))
    ;; Read from the buffer, not `cooked-tests--text', which trims trailing
    ;; whitespace -- and a row that is only image cells is nothing but that.
    (should (equal (buffer-substring-no-properties (point-min) (+ (point-min) 3))
                   "   "))))

(ert-deftest cooked-inline-images-disabled-leaves-the-cells-alone ()
  (let ((cooked-inline-images nil))
    (cooked-tests--with-session '("/bin/sh" "-c" "sleep 300")
      (should (cooked-tests--settle (lambda () cooked--session)))
      (cooked-tests--cell)
      (cooked--apply (cooked-tests--image-update 7 3 1 (cooked-tests--png)))
      (should-not (get-text-property (point-min) 'display)))))

(ert-deftest cooked-image-slices-are-rebuilt-when-the-cell-moves ()
  "The slice geometry is in cells, so a new cell size moves every slice as well
as resizing the spec they cut from -- and nothing else in cooked ever rewrites a
row once it is written, so a picture whose halves were built at two sizes stays
mismatched until this runs."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 300")
    (should (cooked-tests--settle (lambda () cooked--session)))
    (cooked-tests--cell)
    (cooked--apply (cooked-tests--image-update 7 3 1 (cooked-tests--png)))
    (should (equal (car (get-text-property (1+ (point-min)) 'display))
                   '(slice 10 0 10 20)))
    (cooked-tests--cell 12 26)
    (cooked--rescale-deco)
    (should (equal (car (get-text-property (1+ (point-min)) 'display))
                   '(slice 12 0 12 26)))
    ;; And declines to walk the buffer again for a size it is already at.
    (cl-letf (((symbol-function 'next-single-property-change)
               (lambda (&rest _) (error "walked"))))
      (cooked--rescale-deco))))

(ert-deftest cooked-image-slices-follow-a-zoom-with-no-window-event ()
  "`text-scale-adjust' moves the cell without resizing anything, so no window
event follows it and `cooked--sync-size' never hears.  The
`text-scale-mode-amount' watcher is the other route in, and it is the only one
for this case."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 300")
    (should (cooked-tests--settle (lambda () cooked--session)))
    (cooked-tests--cell)
    (cooked--apply (cooked-tests--image-update 7 3 1 (cooked-tests--png)))
    ;; Batch has no font to remap, so the zoom's *effect* is stood in for; what
    ;; is under test is that the watcher reaches the rescale at all.
    (cl-letf (((symbol-function 'cooked--deco-cell-size) (lambda () '(12 . 26))))
      (text-scale-increase 1))
    (should (equal (car (get-text-property (1+ (point-min)) 'display))
                   '(slice 12 0 12 26)))))

(ert-deftest cooked-image-cells-are-sized-from-the-buffer-not-the-selected-window ()
  "The reported corruption, at its source.  With the buffer displayed in no
window -- a completion session previewing it, which is exactly how it was hit --
the cell size used to come from `selected-window', i.e. from the minibuffer,
whose `window-font-width' and `window-default-line-height' are its own and
honour its own face remapping.  Half a picture was then written at one scale and
half at another, permanently, because nothing re-renders scrollback."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 300")
    (should (cooked-tests--settle (lambda () cooked--session)))
    (cooked-tests--cell)
    (should-not (cooked--layout-window))
    ;; The selected window is someone else's buffer at someone else's size.
    (should-not (equal (cooked--cell-size (selected-window)) '(10 . 20)))
    (cooked--apply (cooked-tests--image-update 7 3 1 (cooked-tests--png)))
    (should (equal (car (get-text-property (1+ (point-min)) 'display))
                   '(slice 10 0 10 20)))
    ;; And the same on every later drain: one picture, one scale.
    (cooked--apply (cooked-tests--image-update 7 3 1 nil))
    (should (equal (car (get-text-property (1+ (point-min)) 'display))
                   '(slice 10 0 10 20)))))

(ert-deftest cooked-image-cells-with-no-measurement-wait-for-one ()
  "No window and no last known cell -- a terminal frame, or a session nothing
has ever displayed -- means there is no honest size, and the decision is to
decorate nothing rather than to guess or to blank the cells.  The `cooked-deco'
record still goes on the text, which is the whole of what the repair pass needs."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 300")
    (should (cooked-tests--settle (lambda () cooked--session)))
    (setq cooked--last-cell '(nil . nil))
    (cooked--apply (cooked-tests--image-update 7 3 1 (cooked-tests--png)))
    (should-not (get-text-property (point-min) 'display))
    (should (equal (get-text-property (point-min) 'cooked-deco) '(image 7 0 0)))
    ;; A window turns up; `cooked--sync-size' sees the cell move and repairs.
    (cooked-tests--cell)
    (cooked--rescale-deco)
    (should (equal (car (get-text-property (1+ (point-min)) 'display))
                   '(slice 10 0 10 20)))))

(ert-deftest cooked-a-cell-size-change-rescales-and-a-plain-resize-does-not ()
  "`cooked--sync-size' is the one place that notices the cell moving, so it is
where the rescale hangs -- and the gate matters, because the rescale is a
whole-buffer walk under `widen' and an ordinary reshape must not pay for one."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 300")
    (should (cooked-tests--settle (lambda () cooked--session)))
    (let ((calls 0))
      (cl-letf (((symbol-function 'cooked--rescale-deco)
                 (lambda () (cl-incf calls))))
        (cl-letf (((symbol-function 'cooked--session-cell-size)
                   (lambda () '(10 . 20))))
          (cooked--sync-size)
          (should (= calls 1))
          ;; A resize with the cell standing still: the child hears about it and
          ;; the buffer is left alone.
          (setq cooked--last-size nil)
          (cooked--sync-size)
          (should (= calls 1)))
        (cl-letf (((symbol-function 'cooked--session-cell-size)
                   (lambda () '(12 . 26))))
          (cooked--sync-size)
          (should (= calls 2)))))))

(ert-deftest cooked-kitty-transmission-reaches-the-buffer ()
  "The whole path, driven by a child through a real pty: APC out of the parser,
the kitty command, the image store, the drain, and a `display' slice on a cell.
Every other image test here starts partway along it."
  (let ((b64 (base64-encode-string (cooked-tests--png) t)))
    (cooked-tests--with-session
        (list "/bin/sh" "-c"
              (format "printf '\\033_Ga=T,f=100,i=1;%%s\\033\\\\' '%s'; sleep 300" b64))
      (cooked-tests--cell)
      (should (cooked-tests--settle
               (lambda () (get-text-property (point-min) 'display))
               8))
      (let ((display (get-text-property (point-min) 'display)))
        (should (eq (car-safe (car-safe display)) 'slice))
        (should (eq (car-safe (cadr display)) 'image))))))

(ert-deftest cooked-discarding-the-scrollback-forgets-the-pictures-in-it ()
  "The whole eviction path with nothing stubbed: a real child transmits a real
picture, scrolls it off the grid and into Emacs\=' scrollback, and clearing the
scrollback is what spends it.  Nothing here is a sweep, a budget or a timer --
the bytes go because the last row referring to them went."
  (let ((b64 (base64-encode-string (cooked-tests--png) t)))
    (cooked-tests--with-session
        (list "/bin/sh" "-c"
              (format (concat "printf '\033_Ga=T,f=100,i=1;%%s\033\\' '%s'; "
                              "i=0; while [ $i -lt 200 ]; do printf 'x\n'; "
                              "i=$((i+1)); done; sleep 300")
                      b64))
      (cooked-tests--cell)
      (should (cooked-tests--settle
               (lambda () (= (hash-table-count cooked--image-data) 1))
               8))
      ;; Wait for it to be genuinely above the seam rather than merely drawn.
      (should (cooked-tests--settle
               (lambda () (< (point-min) (cooked--screen-start-position)))
               8))
      (should (> cooked--image-bytes 0))
      (cooked--discard-scrollback (cooked--screen-start-position))
      (should (= (hash-table-count cooked--image-data) 0))
      (should (= cooked--image-bytes 0))
      (should-not cooked--image-order))))

(ert-deftest cooked-kitty-capability-probe-is-answered ()
  "A client detects graphics support by transmitting a 1x1 image with `a=q' and
watching for a reply; there is no terminfo capability for it, so answering this
is the whole of advertising the protocol.

The reply is observed via the tty's own echo of it, which in cooked mode renders
the escape as `^[' rather than sending it back through the parser -- so what the
buffer shows is the answer having reached the child, which is the claim."
  (cooked-tests--with-session
      (list "/bin/sh" "-c"
            "printf '\\033_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\\033\\\\'; cat")
    (should (cooked-tests--settle
             (lambda () (string-match-p "_Gi=31;OK" (cooked-tests--text)))
             8))))
