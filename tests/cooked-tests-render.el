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
    (should (cooked-tests--settle (lambda () (null cooked--semantic))))))

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
                cooked-alt-screen-pin 'narrow
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

(ert-deftest cooked-alt-screen-pin-can-be-turned-off ()
  (let ((cooked-alt-screen-pin 'follow))
    (cooked-tests--with-session
        (list "/bin/sh" "-c" (concat cooked-tests--scrollback-then-alt "sleep 5"))
      (should (cooked-tests--settle (lambda () cooked--alt)))
      (should-not (buffer-narrowed-p))
      (should (string-match-p "MARKER" (cooked-tests--text))))))

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
  (let ((buffer (generate-new-buffer "*cooked-zsh*")))
    (unwind-protect
        (with-current-buffer buffer
          (cooked-mode)
          (pcase-let ((`(,argv ,env ,_scratch) (cooked--shell-invocation (executable-find "zsh"))))
            (cooked--start argv nil env))
          (cooked--refresh-keymap)
          (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input))))
          (let ((prompt (string-trim (buffer-substring-no-properties
                                      (line-beginning-position) (point-max)))))
            (cooked--replace-input "printf 'one\\ntwo\\n'")
            (cooked-send-input)
            (should (cooked-tests--settle
                     (lambda () (and (eq cooked--semantic 'input)
                                     (string-match-p "two" (cooked-tests--text))))))
            (let ((lines (split-string (cooked-tests--text) "\n")))
              (should (member "one" lines))
              (should (member "two" lines))
              ;; The new prompt must not be glued onto the last output line.
              (should-not (seq-find (lambda (l)
                                      (and (string-match-p (regexp-quote prompt) l)
                                           (string-match-p "^two" l)))
                                    lines)))))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer))))

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

(ert-deftest cooked-alt-screen-keeps-exactly-the-emulator-height ()
  "Trimming is disabled on the alt screen, so nothing else removes stale rows
when the window shrinks — which looked like resize doing nothing."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '\\033[?1049h'; printf 'top\\n'; sleep 5")
    (should (cooked-tests--settle (lambda () cooked--alt)))
    (let ((screen-lines (lambda ()
                          (count-lines (marker-position cooked--screen-start) (point-max)))))
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

(ert-deftest cooked-clear-scrollback-keeps-the-live-screen ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "for i in $(seq 60); do printf 'line%s\\n' $i; done; exec cat")
    (should (cooked-tests--settle
             (lambda () (string-match-p "line60" (cooked-tests--text)))))
    (should (string-match-p "line1\n" (cooked-tests--text)))
    (cooked-clear-scrollback)
    (should-not (string-match-p "line1\n" (cooked-tests--text)))
    (should (string-match-p "line60" (cooked-tests--text)))))

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
  "`cooked-clear-scrollback' can cut a line in half: its head is scrollback and
its tail is the top of the screen.  The screen must survive intact, and the
emulator must be told, so the next rewrap does not resume a line that is gone."
  (cooked-tests--with-straddling-line
    (cooked-clear-scrollback)
    (should (string-prefix-p "2222222222" (cooked-tests--text)))
    ;; The one place state flows Emacs -> Rust: cutting the head has to reach the
    ;; emulator's carry, or it resumes a line that is no longer there.  Now checkable
    ;; from the other side rather than only visible in the next rewrap's output.
    (cooked--check-seam)

    (cooked-tests--resize 4 30)
    (should (string-match-p "222222222233333333334444444444555555555"
                            (cooked-tests--unwrapped)))
    (should-not (string-match-p "0000000000" (cooked-tests--text)))))

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
  (with-temp-buffer
    (cooked-mode)
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
fast path above must not apply -- a pure-ASCII row still gets trimmed there."
  (with-temp-buffer
    (cooked-mode)
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
      (let ((overlay (car (overlays-in (1- (line-end-position)) (line-end-position)))))
        (should (overlay-get overlay 'cooked-truncation))
        (let ((spec (get-text-property 0 'display (overlay-get overlay 'after-string))))
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
    (let ((cooked-rejoin-wrapped-lines t)
          (inhibit-read-only t)
          (text "é\nNEXT\n"))
      (insert text)
      (cooked--guard-row-width (point-min))
      (should (equal (buffer-string) text)))))

(ert-deftest cooked-guard-row-width-does-not-eat-into-neighbouring-rows ()
  "The same false positive away from row 0 does not crash -- `end-of-line'
from START still has somewhere to go, the row above -- but before the fix it
ran on regardless: once START's row was emptied, deleting \"the character
before START\" ate the newline above it, merging START into the row above,
and the same broken check then chewed through the entire row below too."
  (with-temp-buffer
    (cooked-mode)
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

(provide 'cooked-tests-render)
;;; cooked-tests-render.el ends here
