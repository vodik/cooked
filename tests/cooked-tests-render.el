;;; cooked-tests-render.el --- Turning the emulator's grid into buffer text -*- lexical-binding: t; -*-

;;; Commentary:

;; The largest group, and the one with the most invariants: the screen region
;; is rewritten from damage reports while the scrollback above it is ordinary
;; buffer text, and the seam between them is a single wrapped line the two ends
;; each hold half of.  Resizes, narrowing, the alt screen and `cooked--guard-row-
;; width' all press on that boundary.

;;; Code:

(require 'cooked-tests-helpers)

(defvar cooked-tests--seam nil
  "A stand-in abnormal hook, for testing the seam runners themselves.
`cooked--run-seam' takes the hook by symbol, so the runners can be exercised
without borrowing a real seam and having its own listeners in the way.")

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

(ert-deftest cooked-reset-leaves-the-alt-screen ()
  "RIS on the alt screen hands the buffer back to the transcript.
The `reset' a user types after a full-screen program died without its
`rmcup': the drain that carries it has to unpin and widen exactly as a
`?1049l' would, with the primary's text archived rather than lost."
  (cooked-tests--with-session
      (list "/bin/sh" "-c"
            (concat cooked-tests--scrollback-then-alt
                    "sleep 0.3; printf '\\033c'; printf 'after\\n'; sleep 5"))
    (should (cooked-tests--settle (lambda () cooked--alt)))
    (should (buffer-narrowed-p))
    (should (cooked-tests--settle (lambda () (not cooked--alt))))
    (should-not (buffer-narrowed-p))
    (should (cooked-tests--settle
             (lambda () (string-match-p "after" (cooked-tests--text)))))
    (should (string-match-p "MARKER" (cooked-tests--text)))
    (should-not (string-match-p "inalt" (cooked-tests--text)))))

(ert-deftest cooked-alt-screen-takes-the-keyboard-from-a-prompt ()
  "Entering the alt screen must swap the keymap even mid-prompt."
  (with-temp-buffer
    (cooked-mode)
    (setq-local cooked--mode 'raw cooked--semantic 'input cooked--alt nil)
    (cooked--refresh-keymap)
    (should (eq (current-local-map) cooked-input-map))
    (cooked--set-alt t)
    (should (eq (current-local-map) (cooked--forwarding-map cooked-alt-map)))
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

(ert-deftest cooked-an-undamaged-row-between-two-damaged-ones-is-not-rewritten ()
  "The hazard coalescing brings with it, pinned from the Emacs side.

Contiguous damaged rows arrive as one block and are rewritten with one
`delete-region\=' and one `insert\=' -- see `cooked--render-rows\='.  The version of
that idea worth refusing is the one that breaks a run only where a row is
*known* to be clean: a damage tracker with page granularity then reports the
whole viewport, the coalescer faithfully turns it into a single reinsert, and
every marker and overlay anchored anywhere in it dies.  cooked breaks a run on
any row it was not told about, which is a strictly narrower claim and the one
this asserts.

Rows 0 and 2 are rewritten with text of exactly their own width, so a marker on
row 1 must come back at exactly the position it went in at.  Had the run been
coalesced across row 1, the marker would not merely have moved -- a deletion
spanning it leaves it collapsed at the start of row 0, which is what makes this
a sharp test rather than an approximate one.  The wire shape is asserted
alongside it, because a Lisp-side test that only looked at the marker would
still pass if the core stopped coalescing altogether."
  (cooked-tests--with-session
      ;; `stty -echo\=' and a `read\=' rather than a sleep: the rewrite has to
      ;; land in a *later* drain than the text it rewrites, since the marker
      ;; goes in between, and echo would otherwise have the line discipline
      ;; print the escape sequence as `^[[1;1H\=' on the cursor\='s row instead of
      ;; the child ever executing it.  `-icanon\=' with it, because echo off in
      ;; canonical mode is `getpass\=' as far as `cooked-secret.el\=' can tell: the
      ;; `read\=' then had a password prompt scheduled behind it, which in batch
      ;; reads stdin and hung the suite whenever stdin was open and silent.  The
      ;; shell\='s `read\=' still waits for the newline either way.
      '("/bin/sh" "-c"
        "stty -echo -icanon; printf 'aaa\\nbbb\\nccc\\n'; read x; printf '\\033[1;1HXXX\\033[3;1HZZZ'; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "ccc" (cooked-tests--text)))))
    (let* ((middle (save-excursion
                     (goto-char (point-min))
                     (search-forward "bbb")
                     (match-beginning 0)))
           (mark (copy-marker (1+ middle)))
           (overlay (make-overlay middle (+ middle 3)))
           (runs nil)
           (capture (lambda (rows &optional _alt _relocations edits)
                      (push (sort (append
                                   (mapcar (lambda (entry)
                                             ;; (FIRST . ROWS-IN-THE-BLOCK), which
                                             ;; is the length of the block's row
                                             ;; table.
                                             (cons (car entry)
                                                   (length (nth 3 (cdr entry)))))
                                           rows)
                                   ;; An edit is one row replaced in part, which
                                   ;; is as narrow as a run of one row.
                                   (mapcar (lambda (edit) (cons (car edit) 1)) edits))
                                  #'car-less-than-car)
                            runs))))
      (advice-add 'cooked--render-rows :before capture)
      (unwind-protect
          (progn
            ;; Releases the child\='s `read\=', which then addresses rows 0 and 2
            ;; and nothing else -- row 1 is written by neither.
            (cooked--send cooked--session "\n")
            (should (cooked-tests--settle
                     (lambda () (string-match-p "ZZZ" (cooked-tests--text))))))
        (advice-remove 'cooked--render-rows capture))
      (should (member '((0 . 1) (2 . 1)) runs))
      (should (= (marker-position mark) (1+ middle)))
      (should (equal (buffer-substring-no-properties middle (+ middle 3)) "bbb"))
      (should (overlay-buffer overlay))
      (should (= (overlay-start overlay) middle))
      (should (= (overlay-end overlay) (+ middle 3)))
      (let ((lines (split-string (cooked-tests--text) "\n")))
        (should (member "XXX" lines))
        (should (member "bbb" lines))
        (should (member "ZZZ" lines))))))

(ert-deftest cooked-prompt-lands-on-its-own-line-after-a-command ()
  :tags '(zsh)
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

;; The mechanical floor: `cooked--capture-relocations' and the pair
;; `cooked--render-rows' calls around each run it rewrites.  Every one of these
;; failed before that existed, and each fails in its own way -- the mark lands on
;; the rewritten row's *start*, a window's point on its *end* -- which is worth
;; knowing only as evidence that neither was being carried by anything and both
;; were being left to Emacs' own marker adjustment.
;;
;; A raw child echoing what it is sent is the shape all of them need: rewriting a
;; row in place, over and over, without scrolling, is what a spinner or a
;; progress bar does and is the only way to damage a row whose position something
;; is already pointing into.

(defun cooked-tests--paint-rows (rows text)
  "Write TEXT plus the row number into each of the first ROWS screen rows.

One `cooked--send\\=', so the whole thing is one drain and the damaged rows are
contiguous -- which is what makes the core coalesce them into a single Block,
and so the whole screen into a single `delete-region\\='/`insert\\=' pair.

Addressed with `CUP\\=' rather than written as lines, and that is not tidiness.
A newline\\='s meaning depends on the line discipline, and the discipline is
still translating for as long as it takes the `stty\\=' to run -- so a `\\r\\n\\='
sent early comes back as two line feeds and every row after the first is one
lower than the test believes.  A cursor-position sequence means the same thing
either way."
  (cooked--send cooked--session
                (mapconcat (lambda (row) (format "\033[%d;1H%s%d" (1+ row) text row))
                           (number-sequence 0 (1- rows))))
  (should (cooked-tests--settle
           (lambda ()
             (string-match-p (format "%s%d" text (1- rows)) (cooked-tests--text))))))

(defmacro cooked-tests--with-rewritable-rows (rows &rest body)
  "Run BODY over a raw child, ROWS rows of `aaaN\\=' already on the screen.

The child echoes what it receives with no interpretation of its own, so BODY can
address the grid directly and the emulator sees the result exactly as it would a
full-screen program\\='s."
  (declare (indent 1))
  `(cooked-tests--with-session '("/bin/sh" "-c" "stty raw -echo; cat")
     (should (cooked-tests--settle (lambda () (eq cooked--mode 'raw))))
     (cooked-tests--paint-rows ,rows "aaa")
     ,@body))

(ert-deftest cooked-a-dismissed-selection-leaves-its-mark-where-it-was ()
  "The case `cooked-selection-render' leaves behind rather than the one it
answers.  The freeze holds the render for as long as the selection is up, so the
mark is in no danger there; the drain that has been waiting arrives the moment
the selection is dismissed, and by then `mark-active' is nil, so
`cooked--deactivate-mark' has nothing to say and the mark is just a position in
a row about to be deleted.

What the user is owed is the next \\[exchange-point-and-mark]: the mark is still
the place they marked, and the child overwriting the characters there does not
move the place."
  (cooked-tests--with-rewritable-rows 3
    (goto-char (cooked--screen-start-position))
    (cooked--goto-screen-cell '(1 . 2))
    (set-mark (point))
    (activate-mark)
    (setq cooked--input-mode 'frozen)
    ;; Nothing drains while the selection is up, which is the freeze working.
    (cooked--send cooked--session "\033[2;1Hzzz1")
    (cooked-tests--pump 0.2)
    (should-not (string-match-p "zzz1" (cooked-tests--text)))
    ;; The user dismisses it.  The catch-up drain runs against a mark nothing is
    ;; protecting any more.
    (deactivate-mark)
    (setq cooked--input-mode nil)
    (should (cooked-tests--settle
             (lambda () (string-match-p "zzz1" (cooked-tests--text)))))
    (should (equal (cooked--screen-cell (mark t)) '(1 . 2)))))

(ert-deftest cooked-a-mark-kept-through-output-keeps-its-cell ()
  "`cooked-clear-selection-on-output' nil is a decision to keep the mark, and
keeping it somewhere else is not keeping it.  Before the floor existed the mark
collapsed to column 0 of the row it was in, so the option delivered a region the
user never drew -- visibly, since this one stays highlighted."
  (let ((cooked-clear-selection-on-output nil))
    (cooked-tests--with-rewritable-rows 3
      ;; On the row about to be rewritten, which is the only row where there is
      ;; anything to keep.
      (cooked--goto-screen-cell '(0 . 2))
      (set-mark (point))
      (activate-mark)
      (cooked-tests--paint-rows 1 "zzz")
      (should mark-active)
      (should (equal (cooked--screen-cell (mark t)) '(0 . 2))))))

(ert-deftest cooked-a-mark-survives-a-coalesced-run-on-its-own-row ()
  "Where cooked's floor departs from ghostel's `adjustRegion', and why it has to.

ghostel replaces one row per edit, so clamping a position inside the replaced
region to that region's new end is exact-replace semantics and costs nothing.
cooked coalesces contiguous damaged rows into one Block, so the region here is
the whole screen in a single edit -- and the clamp would put a mark on row 1 at
the last column of the last row of the run.  The run's row table is what makes
the better answer cheap: the position keeps its row as well as its column."
  (let ((cooked-clear-selection-on-output nil))
    (cooked-tests--with-rewritable-rows 3
      (cooked--goto-screen-cell '(1 . 2))
      (set-mark (point))
      (cooked-tests--paint-rows 3 "zzz")
      ;; One run, not three: the point of coalescing, and the thing that makes
      ;; the clamp wrong.
      (should (equal (cooked--screen-cell (mark t)) '(1 . 2))))))

(ert-deftest cooked-a-mark-past-a-shortened-row-lands-on-its-new-end ()
  "The half the clamp is still right for.  A row that came back shorter has no
column 12 any more, and the nearest thing to where the user was pointing is the
end of what the row now holds."
  (let ((cooked-clear-selection-on-output nil))
    (cooked-tests--with-session '("/bin/sh" "-c" "stty raw -echo; cat")
      (should (cooked-tests--settle (lambda () (eq cooked--mode 'raw))))
      (cooked--send cooked--session "\033[1;1Habcdefghijklmnop")
      (should (cooked-tests--settle
               (lambda () (string-match-p "abcdefghijklmnop" (cooked-tests--text)))))
      (cooked--goto-screen-cell '(0 . 12))
      (set-mark (point))
      (should (equal (cooked--screen-cell (mark t)) '(0 . 12)))
      ;; `EL' after the four characters, so the row is genuinely shorter rather
      ;; than overwritten with blanks.
      (cooked--send cooked--session "\033[1;1Hwxyz\033[K")
      (should (cooked-tests--settle
               (lambda () (string-match-p "wxyz" (cooked-tests--text)))))
      (should (equal (cooked--screen-cell (mark t)) '(0 . 4))))))

(ert-deftest cooked-a-held-second-window-keeps-its-point-on-the-screen ()
  "`cooked--scroll-transcript' points the other windows at the cursor only while
the view is following.  While it is held -- `still', `frozen', a peek -- it
touches none of them, and until the floor existed nothing else did either: the
row rewrite dragged the window's point to the end of whatever was written over
it, which is a second view of the terminal scrolling itself while the user is
reading it."
  (cooked-tests--with-rewritable-rows 3
    (let ((buffer (current-buffer))
          (main (selected-window)))
      (delete-other-windows)
      (set-window-buffer main buffer)
      (let ((other (split-window main nil 'below)))
        (unwind-protect
            (progn
              (set-window-buffer other buffer)
              (set-window-point other (save-excursion
                                        (cooked--goto-screen-cell '(1 . 2))
                                        (point)))
              (setq cooked--input-mode 'still)
              (should-not (cooked--follow-p))
              (cooked-tests--paint-rows 3 "zzz")
              (should (equal (cooked--screen-cell (window-point other)) '(1 . 2))))
          (delete-window other))))))

(ert-deftest cooked-a-following-second-window-is-still-taken-to-the-cursor ()
  "The other half, and the reason the floor is captured conditionally: a window
that is following wants the cursor, not the cell it was last pointed at.  The
floor must not quietly turn `cooked-second-window-follows-new-output' into its
opposite."
  (cooked-tests--with-rewritable-rows 3
    (let ((buffer (current-buffer))
          (main (selected-window)))
      (delete-other-windows)
      (set-window-buffer main buffer)
      (let ((other (split-window main nil 'below)))
        (unwind-protect
            (progn
              (set-window-buffer other buffer)
              (set-window-point other (save-excursion
                                        (cooked--goto-screen-cell '(1 . 2))
                                        (point)))
              (should (cooked--follow-p))
              (cooked-tests--paint-rows 3 "zzz")
              (should (= (window-point other) (point))))
          (delete-window other))))))

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

(ert-deftest cooked-alt-screen-is-pinned-for-every-window-not-just-the-selected-one ()
  "The pin answers for every window on the buffer, because the one the wheel
moved is not always the one the user is in: `mouse-wheel-follow-mouse\=' sends a
notch to the window under the pointer.

This used to be answered by a second copy of the pin on
`pre-redisplay-functions\=', which named the window about to be drawn.  That hook
is gone -- it fired once per window per redisplay, and setting a window\='s start
from inside redisplay makes redisplay start over -- so the walk here is what is
left to catch the unselected window, and it is worth an assertion of its own.

What is deliberately no longer covered: a notch that lands in a *different*
buffer entirely, which is where `post-command-hook\=' runs when the pointer is
over an unselected terminal cooked does not hold the wheel for.  That window is
repaired by the child\='s next output, or by the next command in its own buffer."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '\033[?1049h'; printf 'top\n'; sleep 5")
    (should (cooked-tests--settle (lambda () cooked--alt)))
    (set-window-buffer (selected-window) (current-buffer))
    (let* ((top (marker-position cooked--screen-start))
           (other (split-window)))
      (set-window-buffer other (current-buffer))
      ;; Scrolled away, and with the pixel remainder `pixel-scroll-precision-mode'
      ;; leaves behind: pinning the start alone shaves the top row by however far
      ;; the last event carried.
      (set-window-start other (point-max))
      (set-window-vscroll other 5 t)
      (should-not (= (window-start other) top))
      (cooked--pin-alt-windows)
      (should (= (window-start other) top))
      (should (zerop (window-vscroll other t)))
      (delete-window other))))

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
    ;; A style with no colour is still a plist, since t would say only `line'.
    (let ((double (logior cooked--attr-underline
                          (ash 2 cooked--attr-underline-shift))))
      (should (equal (plist-get (cooked--face nil nil double nil) :underline)
                     (if (>= emacs-major-version 30) '(:style double-line) t))))
    ;; Dotted keeps its colour whether or not this Emacs can draw the dots.
    (let* ((dotted (logior cooked--attr-underline
                           (ash 4 cooked--attr-underline-shift)))
           (spec (plist-get (cooked--face nil nil dotted 1) :underline)))
      (should (eq (plist-get spec :style)
                  (and (>= emacs-major-version 30) 'dots)))
      (should (stringp (plist-get spec :color))))))

(ert-deftest cooked-underline-styles-follow-the-emacs-version ()
  "Emacs 30 draws every SGR 4:x its own way; 29 has only `line' and `wave'.
Both vectors are checked here whatever Emacs runs the suite, and the one in use
must be the one this Emacs gets."
  (should (equal (cooked--underline-styles-for 30)
                 [nil line double-line wave dots dashes]))
  (should (equal (cooked--underline-styles-for 29)
                 [nil line line wave line line]))
  (should (equal cooked--underline-styles
                 (cooked--underline-styles-for emacs-major-version)))
  ;; And the face follows the vector: a plain t where the style is only a line,
  ;; the style itself everywhere else.
  (with-temp-buffer
    (cooked-mode)
    (setq-local cooked--face-cache (make-hash-table :test #'equal))
    (dotimes (i 6)
      (let ((attrs (logior cooked--attr-underline
                           (ash i cooked--attr-underline-shift)))
            (style (aref cooked--underline-styles i)))
        (should (equal (plist-get (cooked--face nil nil attrs nil) :underline)
                       (if (memq style '(nil line)) t (list :style style))))))))

;; `cooked-blink' was drawn as an overline until SGR 53 needed that channel for
;; itself, so the one thing to check is that the two no longer look alike.
(ert-deftest cooked-overline-and-blink-are-drawn-differently ()
  "SGR 53 is `:overline t'; blink inherits `cooked-blink', which must not be.
A blinking cell and an overlined one would otherwise come out identical, which
is the collision `cooked-blink' was written to avoid in the first place."
  (with-temp-buffer
    (cooked-mode)
    (setq-local cooked--face-cache (make-hash-table :test #'equal))
    (let ((over (cooked--face nil nil cooked--attr-overline nil))
          (blink (cooked--face nil nil cooked--attr-blink nil))
          (both (cooked--face nil nil (logior cooked--attr-overline
                                              cooked--attr-blink)
                              nil)))
      (should (eq (plist-get over :overline) t))
      (should-not (plist-member over :inherit))
      (should (eq (plist-get blink :inherit) 'cooked-blink))
      (should-not (plist-member blink :overline))
      (should (eq (plist-get both :overline) t))
      (should (eq (plist-get both :inherit) 'cooked-blink)))
    ;; And the default face spec itself: no overline, and a box drawn inward so a
    ;; blinking run keeps its width on the grid.
    (should (equal (face-default-spec 'cooked-blink)
                   '((t :box (:line-width (-1 . -1))))))))

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
      (should (cooked-tests--settle (lambda () (equal cooked-title "running-thing"))))
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

(ert-deftest cooked-new-output-scrolls-a-following-window ()
  "Redisplay will not move a window whose point nothing touched, and the drain
moves `window-point\=' explicitly for exactly that reason -- so the window start
has to follow it down rather than be left where the last screenful put it.

Asserted on `window-start\=' and `window-point\=' rather than on the pin firing:
the pin is now a computed `set-window-start\=', so there is no call to count,
and the rendered effect is the thing worth asserting anyway."
  (cooked-tests--with-session (list "/bin/sh" "-c" cooked-tests--two-stage-output-script)
    (should (cooked-tests--settle
             (lambda () (string-match-p "line40" (cooked-tests--text)))))
    (should-not cooked--alt)
    ;; The selected window only counts if it is actually showing this buffer —
    ;; without this, `cooked--apply' correctly declines to scroll a window that
    ;; has nothing to do with this session.
    (set-window-buffer (selected-window) (current-buffer))
    (let ((window (selected-window)))
      (cooked--apply (cooked--drain cooked--session))
      (let ((before (window-start window)))
        (should (cooked-tests--settle
                 (lambda () (string-match-p "AFTER" (cooked-tests--text)))))
        ;; The window followed the cursor, and did so by scrolling down: the
        ;; transcript only ever grew here.
        (should (= (window-point window) (point)))
        (should (>= (window-start window) before))
        ;; And the start is where the pin computes it: a windowful up from the
        ;; transcript's *foot*, not from the target.
        ;;
        ;; The distinction is the whole of `cooked--pin-transcript-bottom's
        ;; BOTTOM argument, and it is invisible until the two land on different
        ;; screen lines -- which is the normal case here, because the drain
        ;; passes the cursor as POS and `point-max' as BOTTOM, and a transcript
        ;; ending in a newline puts `point-max' one screen line below the
        ;; cursor.  Deriving the expectation from POS instead asserted the
        ;; contract the function had before BOTTOM existed, and was wrong by
        ;; exactly that one line every time.  What BOTTOM buys is
        ;; `comint-scroll-show-maximum-output's actual semantics: no blank space
        ;; below the last line.
        (should (= (window-start window)
                   (save-excursion
                     (goto-char (point-max))
                     (vertical-motion (- (1- (window-body-height window))) window)
                     (point))))))))

(ert-deftest cooked-scrolling-never-touches-an-unrelated-selected-window ()
  "Output can arrive from a process filter for a session that is not on
screen anywhere -- whatever window happens to be selected at that moment is
almost certainly showing something else, and scrolling it would move the
user's actual work out from under them."
  (cooked-tests--with-session (list "/bin/sh" "-c" cooked-tests--two-stage-output-script)
    (should (cooked-tests--settle
             (lambda () (string-match-p "line40" (cooked-tests--text)))))
    (should-not (eq (window-buffer (selected-window)) (current-buffer)))
    (let* ((window (selected-window))
           (start (window-start window))
           (point (window-point window)))
      (should (cooked-tests--settle
               (lambda () (string-match-p "AFTER" (cooked-tests--text)))))
      (should (= (window-start window) start))
      (should (= (window-point window) point)))))

(ert-deftest cooked-pinning-the-transcript-is-idempotent ()
  "The property the old `recenter\='-and-correct pin never had, and the whole
point of computing the start instead: run twice over the same view, the second
run writes nothing.  Four writes to `window-start\=' per window per drain --
`set-window-point\=', `recenter\=', and the whole-line corrections after it --
each of which redisplay was then free to disagree with, is what the terminal
was visibly jittering to."
  (cooked-tests--with-session (list "/bin/sh" "-c" cooked-tests--two-stage-output-script)
    (should (cooked-tests--settle
             (lambda () (string-match-p "line40" (cooked-tests--text)))))
    (set-window-buffer (selected-window) (current-buffer))
    (let ((window (selected-window)))
      (cooked--pin-transcript-bottom (list window))
      (let ((start (window-start window)))
        (cooked--pin-transcript-bottom (list window))
        (should (= (window-start window) start))
        (cooked--pin-transcript-bottom (list window))
        (should (= (window-start window) start))))))

(ert-deftest cooked-a-moving-buffer-end-does-not-move-the-transcript ()
  "The structural oscillator this was jittering to: `cooked--fit-screen\=' shapes
the region to the rows the grid says are *used*, so `point-max\=' moves between
drains whenever a child alternates a tall screen with a short one -- while the
row the cursor is on, which is what the window is following, has not moved at
all.  Pinning the buffer's end to the foot of the window shifted the whole
transcript up and down at drain rate for that.  Following the cursor's own row
does not: the start is computed from the target, so the end of the buffer can
move under it without the window going anywhere."
  (cooked-tests--with-session (list "/bin/sh" "-c" cooked-tests--two-stage-output-script)
    (should (cooked-tests--settle
             (lambda () (string-match-p "line40" (cooked-tests--text)))))
    (set-window-buffer (selected-window) (current-buffer))
    (let* ((window (selected-window))
           (target (cooked--point-after-input)))
      (cooked--pin-transcript-bottom (list window) target)
      (let ((start (window-start window))
            (end (point-max)))
        ;; The region grows below the cursor and shrinks back, as a drain that
        ;; changes `cooked-grid-used' does.
        (let ((inhibit-read-only t))
          (save-excursion (goto-char (point-max)) (insert "\n\n\n")))
        (should (> (point-max) end))
        (cooked--pin-transcript-bottom (list window) target)
        (should (= (window-start window) start))
        (let ((inhibit-read-only t))
          (delete-region end (point-max)))
        (cooked--pin-transcript-bottom (list window) target)
        (should (= (window-start window) start))))))

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

;;; The ordinary scroll, expressed as a scroll
;;
;; A scroll used to damage every row of the region, because after the emulator rotates
;; its rows every index does hold different text.  It now reports the move as a
;; `:shifts' entry and damages only the rows it recycled, and `cooked--apply-shifts'
;; moves the buffer text to match.  The three tests below are the three things that has
;; to be true of: the text ends up right, and the two kinds of thing anchored *in* that
;; text survive.  The marker and the overlay are the point of the change rather than a
;; side effect of it -- a rewritten row loses both, which is why a prompt marker used to
;; walk away from its prompt on every line of output.

(defmacro cooked-tests--with-scrolling-screen (script &rest body)
  "Run BODY over a six-row screen driven by SCRIPT, a `sh -c' string.

Six rows and six lines, the last written without a newline, so the grid is
exactly full and the cursor sits at the end of the bottom row: the very next
line feed is an ordinary scroll and nothing else.  SCRIPT is appended to that
setup and is where a test does the thing it is measuring."
  (declare (indent 1))
  `(let ((buffer (generate-new-buffer "*cooked-scroll*")))
     (unwind-protect
         (with-current-buffer buffer
           (cooked-mode)
           (setq cooked--rows 6 cooked--cols 20 cooked--last-size '(6 . 20))
           (cooked--start
            (list "/bin/sh" "-c"
                  (concat "printf 'l0\\nl1\\nl2\\nl3\\nl4\\nl5'; sleep 0.4; "
                          ,script "; sleep 5")))
           (cooked--refresh-keymap)
           (should (cooked-tests--settle
                    (lambda () (string-match-p "l5" (cooked-tests--text)))))
           ,@body)
       (with-current-buffer buffer (cooked--cleanup))
       (kill-buffer buffer))))

(defun cooked-tests--row-marker (text)
  "A marker at the start of the screen row reading TEXT."
  (save-excursion
    (goto-char (point-min))
    (should (search-forward text nil t))
    (copy-marker (match-beginning 0))))

(ert-deftest cooked-a-scroll-carries-a-marker-in-the-viewport-with-it ()
  "The whole reason for expressing a scroll as a scroll.

A marker two rows up from the bottom is a prompt marker, a command's start, a
`next-error' position or a user's own; before this it was destroyed by every
line of output the child printed, because the row it sat in was deleted and
reinserted for holding text one row further up.  Now the row's text is *moved*,
so the marker rides with it and still points at the same characters."
  (cooked-tests--with-scrolling-screen "printf '\\nl6'"
    (let ((mark (cooked-tests--row-marker "l3")))
      (should (cooked-tests--settle
               (lambda () (string-match-p "l6" (cooked-tests--text)))))
      ;; Still pointing at `l3', and at the start of it: a marker dragged to the
      ;; deletion point would be sitting on whatever row now begins there.
      (should (equal (buffer-substring-no-properties mark (+ mark 2)) "l3"))
      (should (save-excursion (goto-char mark) (bolp))))))

(ert-deftest cooked-a-scroll-carries-an-overlay-in-the-viewport-with-it ()
  "The other half, and the one the report's ghostel hazard is about.

An overlay over a scrolled row is a command decoration, a highlight, a
`hl-line' -- and `delete-region' collapses one to a point rather than moving
it, so a whole-region repaint destroys every overlay in the viewport."
  (cooked-tests--with-scrolling-screen "printf '\\nl6'"
    (let* ((mark (cooked-tests--row-marker "l3"))
           (overlay (make-overlay mark (+ mark 2))))
      (should (cooked-tests--settle
               (lambda () (string-match-p "l6" (cooked-tests--text)))))
      (should (buffer-live-p (overlay-buffer overlay)))
      (should (equal (buffer-substring-no-properties (overlay-start overlay)
                                                     (overlay-end overlay))
                     "l3")))))

(ert-deftest cooked-a-scroll-leaves-the-buffer-saying-what-the-grid-says ()
  "Correctness, for the three shapes of move the emulator can report.

Each case ends with `cooked--check-seam' having run over it -- `cooked-debug'
is bound throughout the suite -- so the assertions here are about the visible
text rather than about the seam, which is watched on every drain anyway.

The scroll region is the case worth having twice over.  cooked was already
ahead of ghostel here, whose page-dirty flag turns a three-row status area into
a whole-viewport repaint, and the rows *outside* the region must not move: that
is what makes a shift two edits placed by index rather than a rotation."
  ;; An ordinary scroll: `l0' leaves for scrollback, everything else moves up one.
  (cooked-tests--with-scrolling-screen "printf '\\nl6'"
    (should (cooked-tests--settle
             (lambda () (string-match-p "l6" (cooked-tests--text)))))
    (should (equal (cooked-tests--text) "l0\nl1\nl2\nl3\nl4\nl5\nl6")))
  ;; A `DECSTBM' region over rows 2..4 (one-based), scrolled from its bottom. Rows 0
  ;; and 4..5 of the grid are outside it and must be exactly where they were.
  (cooked-tests--with-scrolling-screen "printf '\\033[2;4r\\033[4;1H\\nl6'"
    (should (cooked-tests--settle
             (lambda () (string-match-p "l6" (cooked-tests--text)))))
    (should (equal (cooked-tests--text) "l0\nl2\nl3\nl6\nl4\nl5")))
  ;; `RI' at the top of the screen: the same trade in the other direction, which a
  ;; pager scrolling backwards does on every keystroke.
  (cooked-tests--with-scrolling-screen "printf '\\033[1;1H\\033Mtop'"
    (should (cooked-tests--settle
             (lambda () (string-match-p "top" (cooked-tests--text)))))
    (should (equal (cooked-tests--text) "top\nl0\nl1\nl2\nl3\nl4"))))

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
  "The exact counterpart of `cooked-wrapped-lines-rejoin-in-scrollback\=', and it
has to be asserted where the two modes actually differ.  The *live screen* is one
buffer line per row in both modes -- a row is written into its own line whatever
the flag says -- so a test that reads the top of the buffer and finds
`AAAAAAAAAABBBBBBBBBB\=' at a line end has learned nothing about the flag: it
passes with rejoining fully on.  What the flag decides is what happens to a row
on its way *out* of the screen, so the assertion is about scrollback: each
evicted row keeps its own newline instead of being joined onto the line above."
  (let ((buffer (generate-new-buffer "*cooked-wrap2*"))
        ;; A `let\=', not a `setq\=': the flag is an ordinary global defcustom, so
        ;; setting it from inside a buffer leaves every later test in the batch
        ;; running with rejoining off.
        (cooked-rejoin-wrapped-lines nil))
    (unwind-protect
        (with-current-buffer buffer
          (cooked-mode)
          (setq cooked--rows 4 cooked--cols 20 cooked--last-size '(4 . 20))
          ;; Six rows through a four-row screen, so the three the wrapped line
          ;; took are all evicted and only `tail\=', `x' and `y' are left live.
          (cooked--start '("/bin/sh" "-c"
                           "printf 'AAAAAAAAAABBBBBBBBBBCCCCCCCCCCDDDDDDDDDDEEEEEEEEEEFFFFFFFFFF\\n'; \
                            printf 'tail\\n'; printf 'x\\n'; printf 'y\\n'; sleep 5"))
          (cooked--refresh-keymap)
          (should (cooked-tests--settle
                   (lambda () (string-match-p "FFFFFFFFFF" (cooked-tests--text)))))
          (save-restriction
            (widen)
            ;; Three evicted rows, three buffer lines.  Rejoining makes this one
            ;; line of sixty characters.
            (should (equal (buffer-substring-no-properties
                            (point-min) (cooked--screen-start-position))
                           (concat "AAAAAAAAAABBBBBBBBBB\n"
                                   "CCCCCCCCCCDDDDDDDDDD\n"
                                   "EEEEEEEEEEFFFFFFFFFF\n")))
            ;; And the emulator has stopped claiming a head Emacs never took;
            ;; see `cooked--split-seam\='.
            (should (= 0 (cooked-grid-head cooked--grid))))
          ;; The live screen, which looks the same in both modes and is why the
          ;; scrollback assertion above is the one that means anything.
          (goto-char (cooked--screen-start-position))
          (should (looking-at-p "tail$")))
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
      (cooked-tests--with-mocked-wrap 10 (cooked--guard-row-width (point-min) 26))
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
      (cooked-tests--with-mocked-wrap 10 (cooked--guard-row-width (point-min) 1))
      (should (equal (buffer-string) "é\n"))
      (should-not (get-text-property (point-min) 'display)))))

(ert-deftest cooked-guard-row-width-skips-pure-ascii-rows-on-a-terminal-frame ()
  "A terminal frame has no font-shaping engine and no per-face fonts, so a plain
ASCII row cannot disagree with cooked\='s width model there -- skipped as a cheap
fast path, exercised here by leaving a row Emacs would (per the mock) report as
wrapped untouched, since it never contains anything but ASCII.

Which row is plain ASCII is now the core\='s answer rather than a `string-match-p\='
taken here, so the flag is passed in the way `cooked--render-rows\=' passes it off
the block -- see `cooked--guard-row-width\='."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (let ((cooked-rejoin-wrapped-lines t)
          (inhibit-read-only t)
          (text (concat (make-string 40 ?x) "\n")))
      (insert text)
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil)))
        (cooked-tests--with-mocked-wrap 10
          (cooked--guard-row-width (point-min) 40 nil t)))
      (should (equal (buffer-string) text)))))

(ert-deftest cooked-guard-row-width-skips-pure-ascii-rows-in-a-fixed-pitch-font ()
  "The graphical half of the fast path above, and the one that pays for itself:
a plain ASCII row in a font that renders ASCII one cell per character is not
measured at all -- no `string-width\=', no `vertical-motion\=', not even a memo
lookup -- because nothing about it can come out wider than the grid said.

The sibling of `cooked-guard-row-width-checks-pure-ascii-rows-on-a-graphical-frame\='
below, which is the same row in a face that is *not* fixed pitch.  The two of
them are the whole of the decision `cooked--ascii-fixed-pitch-p\=' makes.

Batch Emacs has no graphical frame to measure in, so the frame is claimed and the
font metrics are the mock: a 10-pixel cell and a `string-pixel-width\=' that
answers ten pixels a character, which is what a monospace font answers.  A
ligature would not change that -- see `cooked--ascii-fixed-pitch-p\=' for the
measurement across four monospace fonts that says so."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (let ((cooked-rejoin-wrapped-lines t)
          (inhibit-read-only t)
          (text (concat (make-string 40 ?x) "\n")))
      (insert text)
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                ((symbol-function 'window-font-width) (lambda (&rest _) 10))
                ((symbol-function 'string-pixel-width)
                 (lambda (string &rest _) (* 10 (length string)))))
        (cooked-tests--with-mocked-wrap 10
          (cooked--guard-row-width (point-min) 40 nil t)))
      (should (equal (buffer-string) text)))))

(ert-deftest cooked-guard-row-width-checks-pure-ascii-rows-on-a-graphical-frame ()
  "A graphical frame can still render plain ASCII wider than one cell a
character, so the fast path above must not apply to every ASCII row -- this one
is measured, and trimmed.

The reason has changed, and the test is set up to the new one.  It used to be
ligatures: a shaper turning `->\=' into one glyph that no per-character metric
predicts.  Measured, that is not a thing that can happen -- across Noto Sans
Mono, Iosevka Fixed SS10, Adwaita Mono and generic `monospace\=', with 27
ligature sequences and with ligatures forced on the way ligature.el does it, not
one rendered at anything but `frame-char-width\=' times its length.  A monospace
font draws a ligature inside the cells its characters already had; that is what
makes it monospace, and this guard only ever trims a row that renders *wider*
than nominal.

What does render ASCII wider is a face whose font is not fixed pitch at all --
`buffer-face-mode\=', a `:family\=' on the default face, a fallback font for a
character the primary font lacks.  In the same measurement a quasi-proportional
face got 26 of the 27 wrong, `=>\=' at 20 pixels where two cells are 18 and
`www\=' at 39 where three are 27.  So that is the condition set up here: a
claimed graphical frame whose `string-pixel-width\=' does not agree with its cell
width, which is exactly what `cooked--ascii-fixed-pitch-p\=' asks and exactly
what a proportional family answers.  The row is ASCII and is checked anyway."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (let ((cooked-rejoin-wrapped-lines t)
          (inhibit-read-only t))
      (insert (make-string 40 ?x) "\n")
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                ((symbol-function 'window-font-width) (lambda (&rest _) 10))
                ;; A proportional face: the probe string measures wider than one
                ;; cell a character, and by a different amount than its length.
                ((symbol-function 'string-pixel-width)
                 (lambda (string &rest _) (+ 3 (* 11 (length string))))))
        (cooked-tests--with-mocked-wrap 10
          (cooked--guard-row-width (point-min) 40 nil t)))
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
      (cooked-tests--with-mocked-wrap 10 (cooked--guard-row-width (point-min) 26))
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
      (cooked--guard-row-width (point-min) 1)
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
                  (cooked--guard-row-width (point-min) 21))
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
      (cooked-tests--with-mocked-wrap 10 (cooked--guard-row-width (point-min) 41))
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
        (cooked--guard-row-width (point-min) 26))
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
        (cooked--guard-row-width (point-min) 26))
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
      (cooked--guard-row-width (point) 1)
      (should (equal (buffer-string) text)))))

(ert-deftest cooked-wrap-memo-answers-what-the-unmemoized-probe-answers ()
  "The memo is only allowed to be a speed-up, so its verdict has to be the
verdict `vertical-motion' would have given, for every row and both ways round.

Asserted over a corpus rather than one row, and against the *same* rows measured
with the memo switched off (a nil table, which `cooked--row-wraps-p' takes to
mean \"ask every time\"), so the two paths are compared rather than the memo
being compared with the test author's expectations.  Each row is asked twice:
the first call is a miss and does the measuring, the second is the hit that has
to agree with it."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (let ((inhibit-read-only t)
          (rows '("short" "0123456789abcdefghij" "─────" "漢字漢字漢字漢字"
                  "" "0123456789" "x")))
      (dolist (row rows) (insert row "\n"))
      ;; A wrap at ten characters: some of these rows reach it and some do not,
      ;; which is what makes the comparison worth making.
      (cooked-tests--with-mocked-wrap 10
        (let ((memo (make-hash-table :test #'equal)))
          (save-excursion
            (goto-char (point-min))
            (dolist (_row rows)
              (let* ((start (point))
                     (end (line-end-position))
                     (bare (cooked--row-wraps-p start end nil nil))
                     (miss (cooked--row-wraps-p start end nil memo))
                     (hit (cooked--row-wraps-p start end nil memo)))
                (should (eq bare miss))
                (should (eq (and bare t) (and hit t)))
                (forward-line 1)))))))))

(ert-deftest cooked-wrap-memo-is-discarded-when-the-layout-moves ()
  "Invalidation, which is the half of a memo that can be quietly wrong.

The cached answer is only good for the font and the geometry it was measured
under, so a font change, a face remap, a zoom or a resize has to throw it away
-- and the way that is arranged is `cooked--layout-stamp', a value compared once
per drain rather than a hook somebody has to remember to connect.  Here the
frame's character width moves, which is what a resize or a zoom looks like from
the stamp's side; the row is unchanged, and it must be measured again anyway.
A font swapped for one of the same cell size is the case next door, and
`cooked-wrap-memo-is-discarded-when-only-the-font-moves' is where it is asked.

Counted rather than timed: the assertion is that `vertical-motion' ran a second
time, which is the whole of what the memo is for and the whole of what
invalidating it undoes."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (let ((inhibit-read-only t)
          (measured 0)
          (width 10))
      (insert (make-string 40 ?x) "\n")
      (cl-letf (((symbol-function 'vertical-motion)
                 (lambda (&rest _) (setq measured (1+ measured)) (forward-line 1)))
                ((symbol-function 'frame-char-width) (lambda (&rest _) width)))
        (let ((probe (lambda ()
                       ;; (FIXED-PITCH WRAPS METRICS) since glyph scaling gave
                       ;; the cache a third slot; the wrap memo is the second.
                       (pcase-let ((`(,_ ,memo ,_)
                                    (cooked--wrap-cache (selected-window))))
                         (cooked--row-wraps-p (point-min) (line-end-position)
                                              nil memo)))))
          (funcall probe)
          (should (= measured 1))
          ;; Same row, same stamp: the memo answers and nothing is measured.
          (funcall probe)
          (should (= measured 1))
          ;; The font moved under it.
          (setq width 12)
          (funcall probe)
          (should (= measured 2))
          ;; And the new answer is itself cached, rather than the stamp being
          ;; rebuilt into a table that never gets used.
          (funcall probe)
          (should (= measured 2)))))))

(ert-deftest cooked-wrap-memo-is-discarded-when-only-the-font-moves ()
  "The case the metrics in the stamp cannot see, and the reason the `font'
frame parameter is in it despite costing more than the other four together.

Two fonts can have identical cell metrics and still lay a row out differently --
a substitution for a character one of them lacks, a composition the other
shapes.  Measured here, Adwaita Mono 11 and Noto Sans Mono 11 are both nine
pixels wide on this frame, so `frame-char-width' and `frame-char-height' agree
across the swap and the old stamp would have matched: every row already seen to
fit would keep answering with the outgoing font's verdict until a resize or a
face remap happened to move something else.

The font is mocked rather than set, because a batch frame has none to set: what
is being asserted is that the stamp *reads* it, which is what makes the memo
notice."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (let ((inhibit-read-only t)
          (measured 0)
          (font "-UKWN-Adwaita Mono-regular-normal-normal-*-15-*-*-*-m-0-iso10646-1"))
      (insert (make-string 40 ?x) "\n")
      (cl-letf* ((real (symbol-function 'frame-parameter))
                 ((symbol-function 'vertical-motion)
                  (lambda (&rest _) (setq measured (1+ measured)) (forward-line 1)))
                 ((symbol-function 'frame-parameter)
                  (lambda (frame parameter)
                    (if (eq parameter 'font) font (funcall real frame parameter)))))
        (let ((probe (lambda ()
                       ;; (FIXED-PITCH WRAPS METRICS) since glyph scaling gave
                       ;; the cache a third slot; the wrap memo is the second.
                       (pcase-let ((`(,_ ,memo ,_)
                                    (cooked--wrap-cache (selected-window))))
                         (cooked--row-wraps-p (point-min) (line-end-position)
                                              nil memo)))))
          (funcall probe)
          (should (= measured 1))
          (funcall probe)
          (should (= measured 1))
          ;; Same cell size, different font.
          (setq font "-GOOG-Noto Sans Mono-regular-normal-normal-*-15-*-*-*-*-0-iso10646-1")
          (funcall probe)
          (should (= measured 2))
          (funcall probe)
          (should (= measured 2)))))))

(ert-deftest cooked-carried-row-width-agrees-with-string-width ()
  "The number the core carries is the number Emacs would have computed.

`cooked--row-mismeasured-p' used to call `string-width' on every rendered row of
every drain, and now reads a count the core kept while it placed the row's
cells.  The two are the same model -- Unicode East Asian Width -- and this is
the assertion that they stay the same answer, over the characters where the
model has anything to say: CJK at two cells apiece, combining marks at none, box
drawing at one, and ASCII as the control.

Read off a real drain rather than a hand-built plist, because what is being
checked is the wire: `cooked--redraw' marks the whole grid damaged so every row
comes back as a block, and each block's WIDTH is compared with `string-width' of
that same block's own text."
  (cooked-tests--with-session
      '("/bin/sh" "-c"
        "printf 'ascii only\\n漢字 CJK\\ne\\314\\201 combining\\n┌───┬───┐\\n%s\\n' done; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "done" (cooked-tests--text)))))
    (cooked--redraw cooked--session)
    (let ((rows (plist-get (cooked--drain cooked--session) :rows))
          (checked 0))
      (should rows)
      ;; A redraw damages every row, and every row is contiguous with the next,
      ;; so the whole grid arrives as one block with one row table.  That is the
      ;; coalescing itself, read off the wire rather than asserted about the
      ;; grouping function -- see `contiguous_runs' in src/wire.rs.
      (should (= (length rows) 1))
      (should (= (caar rows) 0))
      (pcase-dolist (`(,_first . ,block) rows)
        (pcase-let* ((`(,text ,_styles ,_decos ,table) block)
                     (lines (split-string text "\n")))
          (should (= (length table) (length lines)))
          (cl-loop for line in lines
                   for row in table
                   do (pcase-let ((`(,start ,width ,uniform) row))
                        ;; START addresses the row's own text, which is what the
                        ;; two numbers beside it are about.
                        (should (equal line (substring text start (+ start (length line)))))
                        (should (equal width (string-width line)))
                        ;; t for ASCII, `glyph' for the border, whose three-byte
                        ;; characters are all box glyphs, and nil for CJK and the
                        ;; combining mark, which the font draws.
                        (should (eq uniform
                                    (cond ((not (string-match-p (rx (not ascii)) line)) t)
                                          ((string-match-p (rx bos (+ (any (#x2500 . #x257f))) eos)
                                                           line)
                                           'glyph))))
                        (unless (string-empty-p line)
                          (setq checked (1+ checked)))))))
      ;; The corpus really did arrive: five non-empty rows, not an empty grid
      ;; agreeing with itself.
      (should (>= checked 5)))))

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

(ert-deftest cooked-a-mark-after-a-wide-character-lands-on-its-character ()
  "An anchor on the live screen counts characters, not columns.

`日本 ' is five columns and three characters, so a mark after it taken as a
column landed two characters into the text that followed."
  (cooked-tests--with-session
      '("/bin/sh" "-c"
        "printf '\\346\\227\\245\\346\\234\\254 \\033]133;C\\007marked\\033]133;D;0\\007'; sleep 5")
    (should (cooked-tests--settle (lambda () (= (length cooked--commands) 1))))
    (let ((start (cooked--command-start-position (car cooked--commands))))
      (should (equal (buffer-substring-no-properties
                      start (min (point-max) (+ start 6)))
                     "marked")))))

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
    ;;
    ;; `cooked-debug' back off for the duration, against the fixture's own
    ;; binding: this test is *about* the containment in `cooked--on-wake', and
    ;; under debug that containment re-signals by design -- which here would put
    ;; the deliberate error back into the process filter and take the whole batch
    ;; run with it rather than failing one test.
    (let* ((cooked-debug nil)
           (failed nil)
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

(ert-deftest cooked-glyph-scale-clamps-each-side-not-the-sum ()
  "The three-way min, which is the detail an implementation skips.

A row realises `max(ascent) + max(descent)\=' across every glyph sharing its
baseline, so a glyph overflows if *either* side is over and scaling by the ratio
of the sums can leave one side over the line.

The numbers are this machine\='s, measured in a real frame: default ascent 15,
descent 5, and a CJK glyph at ascent 18, descent 5, pixel size 15.  The sum
ratio is 20/23 = 0.869; the ascent ratio is 15/18 = 0.833.  Take the sum and the
row is still too tall."
  (let* ((default '(15 5))
         (cjk '(15 18 5 15))
         (scale (cooked--glyph-scale cjk 18 default)))
    (should scale)
    ;; Strictly below the sum ratio, which is what proves it did not use it.
    (should (< scale (/ 20.0 23.0)))
    ;; And no greater than the ascent ratio, which is the binding one.
    (should (<= scale (/ 15.0 18.0)))))

(ert-deftest cooked-glyph-scale-quantizes-down-to-a-whole-pixel ()
  "`height\=' scales the font\='s pixel size and Emacs rounds the result, so a
mathematically exact scale rounds back up and the cell overflows anyway.

Asserted as the property rather than the value: whatever scale comes back, the
pixel size multiplied by it must already be a whole number, or the flooring did
not happen."
  (dolist (case '(((15 18 5 15) 18 (15 5))
                  ((19 14 4 15) 18 (15 5))
                  ((30 30 10 15) 9 (15 5))))
    (pcase-let ((`(,measured ,slot ,default) case))
      (when-let* ((scale (cooked--glyph-scale measured slot default))
                  (pixel (nth 3 measured)))
        (should (= (* pixel scale) (ffloor (* pixel scale))))))))

(ert-deftest cooked-the-scale-floor-clamps-rather-than-refusing ()
  "The floor says how far a glyph may shrink, not whether it may.

Getting this backwards made the feature useless on the font that needs it most.
An Iosevka arrow is exactly twice its cell -- 16 pixels in an 8-pixel cell, from
Iosevka itself rather than a fallback -- so it wants a scale of 0.5, which
quantizes to 0.46 at a pixel size of 13.  Read as a *threshold* the floor then
refuses the one glyph the whole mechanism exists for, and btop stays a cell out
of line on every row carrying an arrow.  Read as a *clamp* it says what it
means: never shrink more than this, and where that leaves the glyph still a
little over, a slightly wide character beats an illegible one."
  (let ((default '(13 4))
        (cooked-glyph-scale-floor 0.5))
    ;; Twice its cell: scaled, not refused.
    (let ((scale (cooked--glyph-scale '(16 13 4 13) 8 default)))
      (should scale)
      (should (< scale 1.0)))
    ;; Four times its cell wants 0.25 and is held at the floor instead, coming
    ;; out larger than the arithmetic asked for and still readable.
    (let ((unclamped (cooked--glyph-scale '(32 13 4 13) 8 default))
          (arrow (cooked--glyph-scale '(16 13 4 13) 8 default)))
      (should unclamped)
      (should (= unclamped arrow)))
    ;; And nil means no scaling at all, which is the off switch.
    (let ((cooked-glyph-scale-floor nil))
      (should (cooked--glyph-scale '(16 13 4 13) 8 default)))))

(ert-deftest cooked-glyph-scale-leaves-a-glyph-that-fits-alone ()
  "nil, not 1.0: the caller puts no property on at all, and a `display\=' property
per cell is exactly the cost the run-wide image work went to remove."
  (let ((default '(15 5)))
    ;; Exactly its slot in every dimension.
    (should-not (cooked--glyph-scale '(9 15 5 15) 9 default))
    ;; Comfortably inside it.
    (should-not (cooked--glyph-scale '(7 12 3 15) 9 default))
    ;; A wide glyph inside a two-cell slot.
    (should-not (cooked--glyph-scale '(15 15 5 15) 18 default))))

(ert-deftest cooked-glyph-scale-catches-a-glyph-that-is-only-too-tall ()
  "The case the plan this came from could not reach.

Hanging the repair off `cooked--row-wraps-p\=' only ever finds glyphs too
*wide*.  A glyph whose width fits and whose ascent does not makes the row deeper
without wrapping it, and the wrap check answers nil -- so this has to be decided
from the metrics rather than from the symptom."
  (let ((default '(15 5)))
    ;; Width fits in an 18px slot; ascent does not.
    (should (cooked--glyph-scale '(15 18 5 15) 18 default))
    ;; Width fits; descent does not.
    (should (cooked--glyph-scale '(9 15 9 15) 9 default))))

(ert-deftest cooked-a-lone-wide-glyph-claims-the-cell-after-it ()
  "ghostel\='s `adjustWidth\=', and the idea is better than shrinking.

A glyph too wide for its cell does not have to be made smaller if there is
somewhere for it to go.  Three conditions, each with its own way of failing."
  (let ((default '(15 5)))
    (with-temp-buffer
      ;; Relatively wider than the cell, standing alone with spaces both sides.
      (insert "a X b")
      (let ((from (+ (point-min) 2)))
        (should (cooked--glyph-claims-next-cell-p
                 '(20 15 5 15) from (1+ from) (point-max) default 9))
        ;; A glyph narrower *in proportion* than its cell has no use for more
        ;; room: whatever overflows is its height, and a wider slot cannot help.
        (should-not (cooked--glyph-claims-next-cell-p
                     '(2 15 5 15) from (1+ from) (point-max) default 9))))
    (with-temp-buffer
      ;; A character after it, so claiming would draw two glyphs on one cell.
      (insert "a Xb")
      (let ((from (+ (point-min) 2)))
        (should-not (cooked--glyph-claims-next-cell-p
                     '(20 15 5 15) from (1+ from) (point-max) default 9))))
    (with-temp-buffer
      ;; A character before it: claiming only where a glyph stands alone is what
      ;; stops one instance being widened and the next not, which reads worse
      ;; than either answer applied evenly.
      (insert "aX b")
      (let ((from (+ (point-min) 1)))
        (should-not (cooked--glyph-claims-next-cell-p
                     '(20 15 5 15) from (1+ from) (point-max) default 9))))
    (with-temp-buffer
      ;; Nowhere to go: the glyph is the last thing on the row.
      (insert "a X")
      (let ((from (+ (point-min) 2)))
        (should-not (cooked--glyph-claims-next-cell-p
                     '(20 15 5 15) from (1+ from) (point-max) default 9))))))

(ert-deftest cooked-a-face-remap-resizes-the-session-too ()
  "`text-scale-mode-hook\=' is not the whole story, and the gap is the case
cooked already knows how to detect.

`buffer-face-set\=', `variable-pitch-mode\=' and `buffer-face-toggle\=' all
rescale the buffer\='s font through `buffer-face-mode\=', which runs no hook --
so a session put into a proportional face was never told to re-measure, even
though `cooked--ascii-fixed-pitch-p\=' exists precisely to notice one.  Nothing
else observes it either: the window\='s pixel dimensions do not change, so
neither `window-configuration-change-hook\=' nor
`window-size-change-functions\=' fires."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (should (cooked-tests--settle (lambda () cooked--session)))
    (let ((synced 0))
      (cl-letf* ((real (symbol-function 'cooked--sync-size))
                 ((symbol-function 'cooked--sync-size)
                  (lambda (&rest args) (cl-incf synced) (apply real args))))
        (dolist (change (list (lambda () (text-scale-increase 1))
                              (lambda () (variable-pitch-mode 1))
                              (lambda () (buffer-face-set '(:height 120)))))
          (setq synced 0)
          (funcall change)
          (should (> synced 0)))))))

(ert-deftest cooked-a-minibuffer-does-not-resize-the-child ()
  "A minibuffer costs every window on the frame a row, and each is a SIGWINCH.

fish clears and re-emits its prompt on every one, so an `M-x\=' cycle -- grow
then shrink -- produces two prompt repaints for a gesture that never touched
this window\='s width.  Deferred only where the width is unchanged, which is
what makes it safe: a rewrap is what a child actually has to be told about, and
the height reaches it at the next real resize."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (should (cooked-tests--settle (lambda () cooked--session)))
    ;; Settle the cell first: `cooked--last-cell' starts nil, so the very first
    ;; sync counts as the cell having moved and resizes whatever else is true.
    (cooked--sync-size)
    (let ((resizes 0))
      (cl-letf* ((real (symbol-function 'cooked--resize))
                 ((symbol-function 'cooked--resize)
                  (lambda (&rest args) (cl-incf resizes) (apply real args))))
        (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () t)))
          ;; Same width, one row fewer: the minibuffer taking its line.
          (setq cooked--last-size (cons (1+ (car cooked--last-size))
                                        (cdr cooked--last-size))
                resizes 0)
          (cooked--sync-size)
          (should (= resizes 0))
          ;; A width change is a rewrap and reaches the child regardless.
          (setq cooked--last-size (cons (car cooked--last-size)
                                        (+ 7 (cdr cooked--last-size)))
                resizes 0)
          (cooked--sync-size)
          (should (> resizes 0)))
        ;; And with no minibuffer up, a rows-only change is an ordinary resize.
        (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () nil)))
          (setq cooked--last-size (cons (1+ (car cooked--last-size))
                                        (cdr cooked--last-size))
                resizes 0)
          (cooked--sync-size)
          (should (> resizes 0)))))))

(ert-deftest cooked-the-alt-screen-is-resized-even-under-a-minibuffer ()
  "A full-screen program has laid itself out against a row count.

Deferring there would leave it drawing into rows that are no longer on the
screen, which is worse than the repaint the deferral exists to avoid."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (should (cooked-tests--settle (lambda () cooked--session)))
    (cooked--sync-size)
    (let ((resizes 0))
      (cl-letf* ((real (symbol-function 'cooked--resize))
                 ((symbol-function 'cooked--resize)
                  (lambda (&rest args) (cl-incf resizes) (apply real args)))
                 ((symbol-function 'active-minibuffer-window) (lambda () t)))
        (setq cooked--alt t
              cooked--last-size (cons (1+ (car cooked--last-size))
                                      (cdr cooked--last-size))
              resizes 0)
        (cooked--sync-size)
        (should (> resizes 0))))))

(ert-deftest cooked-a-glyph-that-already-fits-is-left-entirely-alone ()
  "The guard whose absence misrendered htop, btop and tree.

Dropping it looks harmless: a glyph that fits needs no *scaling*, and
`cooked--glyph-scale\=' answers nil for it either way.  What it also needs is no
*claim*, and that is what went wrong.  A box-drawing character has exactly
cell-shaped proportions -- 9 pixels over an ascent and descent of 20, against a
cell of 9 over 20 -- so the claim test compared two equal aspects, answered yes
on the `>=\=', took the cell after it and hid the space living there.  Every
line of `tree\=' output begins `│ \=' and every one of them did it: measured, 8
display properties and 4 hidden spaces over three lines.

So this asserts the *absence* of a decision, which is the only thing that can
catch it -- the text was never wrong, only what was hung on it."
  (let ((default '(15 5)))
    ;; Exactly its cell in all three dimensions: nothing to improve.
    (should (cooked--glyph-fits-p '(9 15 5 15) 9 default))
    ;; A wide glyph exactly filling two cells.
    (should (cooked--glyph-fits-p '(18 15 5 15) 18 default))
    ;; Any one dimension off and it is not this function's business any more.
    (should-not (cooked--glyph-fits-p '(10 15 5 15) 9 default))
    (should-not (cooked--glyph-fits-p '(9 18 5 15) 9 default))
    (should-not (cooked--glyph-fits-p '(9 15 9 15) 9 default))
    ;; Under-filling is not fitting either -- that is the CJK case, which does
    ;; want the slot held at its budgeted width.
    (should-not (cooked--glyph-fits-p '(15 15 5 15) 18 default))))

(ert-deftest cooked-a-glyph-is-not-claimed-into-a-space-a-box-run-holds ()
  "A blank inside a box-drawing run is part of the run\='s image, not free.

`Row::absorb_blank_runs\=' merges the gap in `│ │\=' into one run whose bitmap
is three cells wide.  Hiding that space at zero width would pull the rest of
the row one cell left under an image still three cells wide, so a glyph beside
it must shrink rather than claim it.  The same row with a plain space claims."
  (let ((default '(15 5)))
    (with-temp-buffer
      (insert "a X b")
      (let ((from (+ (point-min) 2)))
        (should (cooked--glyph-claims-next-cell-p
                 '(20 15 5 15) from (1+ from) (point-max) default 9))
        (put-text-property (1+ from) (+ from 2) 'cooked-deco '(glyph "run" 2 0))
        (should-not (cooked--glyph-claims-next-cell-p
                     '(20 15 5 15) from (1+ from) (point-max) default 9))))))

(ert-deftest cooked-glyph-scaling-measures-against-the-zoomed-font ()
  "After a zoom, a glyph that fits the zoomed cell is left alone.

`text-scale-increase\=' from a 15-pixel font draws the buffer in a 26-pixel one
with 16-pixel cells, while the frame still says 15 pixels and 9.  Measured
against the frame, the `│\=' below -- exactly one zoomed cell -- would be too
big for its slot and shrink, while the ASCII rows beside it stayed zoomed.
Against the zoomed font it fits, and the glyph really twice the cell is the one
that shrinks."
  (with-temp-buffer
    (cooked-mode)
    (let ((inhibit-read-only t)
          (cooked-glyph-scale-floor 0.5))
      (insert "│ →\n")
      (cooked-tests--with-glyph-font '(20 6 16)
        (cl-letf (((symbol-function 'cooked--glyph-metrics)
                   (lambda (beg _end _window _metrics)
                     (pcase (char-after beg)
                       (?│ '(16 20 6 26))
                       (?→ '(32 20 6 26))
                       (_ '(16 20 6 26))))))
          (cooked--scale-offenders (point-min) (line-end-position)
                                   (selected-window)
                                   (make-hash-table :test #'equal))))
      (should-not (get-text-property (point-min) 'display))
      (let ((arrow (get-text-property (+ (point-min) 2) 'display)))
        (should (equal (assq 'min-width arrow) '(min-width (1))))
        (should (= (cadr (assq 'height arrow)) 0.5))))))

(ert-deftest cooked-glyph-scaling-leaves-a-box-drawing-image-whole ()
  "A box-drawing run drawn as cooked\='s own image is never scaled.

The image of `┌──┐\=' is one `display\=' spanning four cells and fits them by
construction.  The font\='s glyphs for the same characters can be any size at
all -- here every one is reported twice its cell -- and scaling one character
would replace its share of the picture with a shrunk glyph while the rest of the
run went on drawing the whole four-cell image.  The CJK character after it is
drawn from the font and is still scaled."
  (cooked-tests--with-session
      '("/bin/sh" "-c"
        "printf '\\342\\224\\214\\342\\224\\200\\342\\224\\200\\342\\224\\220 \\346\\274\\242\\n'; sleep 5")
    (cooked-tests--cell)
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'display))))
    (let* ((start (point-min))
           (end (save-excursion (goto-char start) (line-end-position)))
           (before (mapcar (lambda (i) (get-text-property (+ start i) 'display))
                           (number-sequence 0 3)))
           (cooked-glyph-scale-floor 0.5)
           (inhibit-read-only t))
      (should (car-safe (car before)))
      (cooked-tests--with-glyph-font '(15 5 10)
        (cl-letf (((symbol-function 'cooked--glyph-metrics)
                   (lambda (beg _end _window _metrics)
                     (if (eq (char-after beg) ?漢) '(30 15 5 15) '(20 15 5 15)))))
          (cooked--scale-offenders start end (selected-window)
                                   (make-hash-table :test #'equal))))
      (dotimes (i 4)
        (should (eq (get-text-property (+ start i) 'display) (nth i before))))
      (should (assq 'height (get-text-property (+ start 5) 'display))))))

(ert-deftest cooked-glyph-scaling-measures-nothing-on-a-terminal-frame ()
  "A terminal frame has no font to fit a glyph inside, so nothing is measured.

`font-at\=' answers nil off a window frame, and the walk used to ask it about
every character of every non-uniform row on every drain anyway, for a scale it
could never apply.  Batch Emacs is such a frame: a row of box drawing and CJK
reaches the walk twice, and no character is measured either time."
  (with-temp-buffer
    (cooked-mode)
    (let ((inhibit-read-only t)
          (window (cooked-tests--display-buffer))
          (cooked-glyph-scale-floor 0.5)
          (metrics (make-hash-table :test #'equal))
          (measured 0)
          (asked 0))
      (insert "│ 漢字 →\n")
      (cl-letf* ((real-metrics (symbol-function 'cooked--glyph-metrics))
                 (real-font (symbol-function 'cooked--default-font))
                 ((symbol-function 'cooked--glyph-metrics)
                  (lambda (&rest args)
                    (cl-incf measured)
                    (apply real-metrics args)))
                 ((symbol-function 'cooked--default-font)
                  (lambda (&rest args) (cl-incf asked) (apply real-font args))))
        (dotimes (_ 2)
          (cooked--scale-offenders (point-min) (line-end-position)
                                   window metrics)))
      (should (= measured 0))
      (should (= asked 1))
      (should-not (next-single-property-change (point-min) 'display)))))

(ert-deftest cooked-a-cluster-that-cannot-be-measured-is-asked-about-once ()
  "A nil measurement is remembered, and so is every other.

`font-at\=' answers nil for a character on a frame with no font for it, and the
cache could not hold nil, so the same character was shaped again on every
drain.  Batch Emacs answers nil for everything, which makes it the case."
  (with-temp-buffer
    (insert "漢")
    (let ((window (cooked-tests--display-buffer))
          (metrics (make-hash-table :test #'equal))
          (asked 0))
      (cl-letf* ((real (symbol-function 'font-at))
                 ((symbol-function 'font-at)
                  (lambda (&rest args) (cl-incf asked) (apply real args))))
        (dotimes (_ 2)
          (should-not (cooked--glyph-metrics (point-min) (1+ (point-min))
                                             window metrics))))
      (should (= asked 1)))))

(ert-deftest cooked-glyph-metrics-are-bounded-like-the-wrap-memo ()
  "The metrics table is emptied past `cooked-wrap-cache-limit\=' measurements.

It is keyed by face and cluster, and a truecolour stream mints a face for
nearly every run it colours, so without a bound it grew until the font changed.
Twelve distinct faces against a limit of four leave at most five measurements
behind, counting across faces rather than per face."
  (with-temp-buffer
    (let ((metrics (make-hash-table :test #'equal))
          (cooked-wrap-cache-limit 4))
      (dotimes (i 12)
        (insert (propertize "x" 'face `(:foreground ,(format "#0000%02x" i)))))
      (cl-letf (((symbol-function 'font-at) (lambda (&rest _) nil)))
        (dotimes (i 12)
          (let ((pos (+ (point-min) i)))
            (cooked--glyph-metrics pos (1+ pos) nil metrics))))
      (let ((held 0))
        (maphash (lambda (_face table)
                   (when (hash-table-p table)
                     (cl-incf held (hash-table-count table))))
                 metrics)
        (should (<= held 5))))))

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
  "An update placing image ID as a COLS by ROWS rectangle on screen row 0.

Twelve bytes per cell, matching `cooked--apply-image-deco\=': the id, then the
cell\='s row and column within the picture, then the rectangle this placement was
laid at.  The rectangle is per placement rather than per image, so it is here
rather than in `:images\=' -- see `cooked--image-spec\='."
  (let* ((u16 (lambda (n) (list (logand n 255) (logand (ash n -8) 255))))
         (packed (apply #'unibyte-string
                        (cl-loop for c below cols
                                 append (append
                                         (list (logand id 255)
                                               (logand (ash id -8) 255)
                                               (logand (ash id -16) 255)
                                               (logand (ash id -24) 255))
                                         (funcall u16 0)
                                         (funcall u16 c)
                                         (funcall u16 cols)
                                         (funcall u16 rows))))))
    (list :scrolled nil
          :rows (list (cons 0 (list (make-string cols ?\s)
                                    nil
                                    (list (list 0 (cons 'image packed))))))
          :images (and data
                       (list (list id 'png data (* cols 10) (* rows 20))))
          :height 12 :used 1 :head 0
          :cursor '(0 0 t block) :alt nil
          :app-cursor nil :keys 'legacy :mode 'raw :events nil :exit nil)))

(defun cooked-tests--image-cell (id crow ccol cols rows)
  "The twelve bytes `cooked--apply-image-deco\=' reads for one cell."
  (let ((u16 (lambda (n) (list (logand n 255) (logand (ash n -8) 255)))))
    (apply #'unibyte-string
           (append (list (logand id 255) (logand (ash id -8) 255)
                         (logand (ash id -16) 255) (logand (ash id -24) 255))
                   (funcall u16 crow) (funcall u16 ccol)
                   (funcall u16 cols) (funcall u16 rows)))))

(defun cooked-tests--image-update-broken (id cols rows hole &optional data)
  "Like `cooked-tests--image-update\=', with column HOLE overwritten by a letter.

What the grid does to a picture when a program writes over the middle of it: the
overwritten cell holds a character of its own and is no longer part of the
placement, so it contributes no record and the run arrives as *two* decoration
spans at their own offsets.  Reproducing that shape here rather than driving a
child is the point -- it is the input `cooked--apply-image-deco\=' has to break
its runs against."
  (let ((text (make-string cols ?\s))
        (left nil)
        (right nil))
    (aset text hole ?X)
    (dotimes (c cols)
      (unless (= c hole)
        (let ((bytes (cooked-tests--image-cell id 0 c cols rows)))
          (if (< c hole) (push bytes left) (push bytes right)))))
    (list :scrolled nil
          :rows (list (cons 0 (list text
                                    nil
                                    (list (list 0 (cons 'image (apply #'concat (nreverse left))))
                                          (list (1+ hole)
                                                (cons 'image (apply #'concat (nreverse right))))))))
          :images (and data (list (list id 'png data (* cols 10) (* rows 20))))
          :height 12 :used 1 :head 0
          :cursor '(0 0 t block) :alt nil
          :app-cursor nil :keys 'legacy :mode 'raw :events nil :exit nil)))

(ert-deftest cooked-a-row-of-image-cells-shares-one-run-wide-slice ()
  "One `display\=' interval over the row, cutting a slice as wide as the run.

The invariant, and it is the same one
`cooked-adjacent-box-glyphs-share-only-a-run-wide-image\=' pins for glyphs.
Emacs merges a span of characters whose `display\=' values are `eq\=' into a
single displayed image, and whether that is a hazard or the point depends
entirely on how wide the image is: a *cell*-wide slice shared across three cells
would collapse the row to one cell of picture, while a slice sized to exactly
the three cells it is put over draws one image occupying precisely the pixels
those three cells did.  So the merge is asked for here rather than avoided.

The old spelling of this test asserted the opposite -- that each cell carried
its own slice advancing a cell per column -- and it was reading the mechanism
for the requirement.  What must survive is that the *grid* addresses the picture
one cell at a time, so that an overwrite, a scroll and a rewrap need no special
case; that is a property of the wire records and of where the runs break, not of
how many `put-text-property\=' calls the buffer ends up with.
`cooked-an-image-run-broken-by-text-is-two-runs-at-their-own-columns\=' is the
half that actually pins it, and this one is what a full-screen picture costs:
1944 `display\=' intervals over a 24x80 frame become 48.

Read the width back off the slice, which is what makes the merge observable from
batch at all -- nothing here rasterizes, so the only evidence a run is drawn
run-wide is that it says it is."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 300")
    (should (cooked-tests--settle (lambda () cooked--session)))
    (cooked-tests--cell)
    (cooked--apply (cooked-tests--image-update 7 3 1 (cooked-tests--png)))
    (let ((beg (point-min)))
      ;; One step of the walk covers all three cells, for both properties.
      (should (equal (next-single-property-change beg 'display) (+ beg 3)))
      (should (equal (next-single-property-change beg 'cooked-deco) (+ beg 3)))
      (dotimes (col 3)
        (should (eq (get-text-property (+ beg col) 'display)
                    (get-text-property beg 'display)))
        (should (eq (get-text-property (+ beg col) 'cooked-deco)
                    (get-text-property beg 'cooked-deco))))
      ;; ...and the slice under it is three cells wide and one tall, at the
      ;; run's own origin in the picture.  (slice X Y W H), the cell being 10x20.
      (let ((display (get-text-property beg 'display)))
        (should (equal (car display) '(slice 0 0 30 20)))
        (should (eq (car-safe (cadr display)) 'image))))))

(ert-deftest cooked-an-image-run-broken-by-text-is-two-runs-at-their-own-columns ()
  "The half of the per-cell model that has to survive the coalescing.

A picture with a character written over the middle of it is three spans, not
one: the overwritten cell is no longer part of the placement and so sends no
record at all, and the cells either side of it are runs whose columns within the
picture skip past it.  Each has to be drawn at its *own* start column, or the
right-hand fragment repaints the left of the picture over itself -- which is
exactly what a run-wide slice gets wrong if the runs are not cut where the grid
cut them.

Driven from the wire rather than through a child, because what is under test is
where `cooked--apply-image-deco\=' breaks a run and that is a property of the
records it is handed."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 300")
    (should (cooked-tests--settle (lambda () cooked--session)))
    (cooked-tests--cell)
    (cooked--apply (cooked-tests--image-update-broken 7 5 1 2 (cooked-tests--png)))
    (let ((beg (point-min)))
      ;; Columns 0-1, then the letter, then columns 3-4.
      (should (equal (next-single-property-change beg 'display) (+ beg 2)))
      (should-not (get-text-property (+ beg 2) 'display))
      (should (equal (car (get-text-property beg 'display))
                     '(slice 0 0 20 20)))
      ;; The second run's slice starts at column 3 of the picture -- 30 pixels
      ;; in -- and not at 0, which is the whole point of cutting it here.
      (should (equal (car (get-text-property (+ beg 3) 'display))
                     '(slice 30 0 20 20)))
      (should (equal (next-single-property-change (+ beg 3) 'display)
                     (+ beg 5))))))

(defun cooked-tests--image-update-twice (id cols rows &optional data)
  "One span holding TWO adjacent placements of ID, each COLS wide.

The case that makes the run-break check load-bearing rather than defensive.  A
decoration span\='s records cover every character it covers, so a *gap* inside one
cannot arise -- but two placements of the same picture side by side on one row
are contiguous characters, and therefore one span, whose column sequence
*restarts*: 0 1 2 0 1 2.  Every other field agrees across the seam, so the
column is the only thing that can find it."
  (let* ((u16 (lambda (n) (list (logand n 255) (logand (ash n -8) 255))))
         (cell (lambda (c)
                 (append (list (logand id 255) (logand (ash id -8) 255)
                               (logand (ash id -16) 255) (logand (ash id -24) 255))
                         (funcall u16 0) (funcall u16 c)
                         (funcall u16 cols) (funcall u16 rows))))
         (packed (apply #'unibyte-string
                        (append (cl-loop for c below cols append (funcall cell c))
                                (cl-loop for c below cols append (funcall cell c))))))
    (list :scrolled nil
          :rows (list (cons 0 (list (make-string (* 2 cols) ?\s)
                                    nil
                                    (list (list 0 (cons 'image packed))))))
          :images (and data (list (list id 'png data (* cols 10) (* rows 20))))
          :height 12 :used 1 :head 0
          :cursor '(0 0 t block) :alt nil)))

(ert-deftest cooked-two-placements-of-one-picture-do-not-merge-into-one-run ()
  "The run break has to find a column that restarts, not only one that skips.

`cooked-an-image-run-broken-by-text-is-two-runs-at-their-own-columns\=' does not
reach this, and that is worth saying plainly: text over the middle of a picture
ends the *span*, so the two fragments arrive as two record arrays and the
coalescing loop never sees the discontinuity at all.  Two placements side by
side are one span, one array, and the only field that differs across the seam is
the column -- which is exactly the comparison this pins.

Merged, the second placement would be sliced as though it were columns 3-5 of
the first: one six-cell run at `(slice 0 0 60 20)\=', drawing the left half of the
picture stretched across both copies."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 300")
    (should (cooked-tests--settle (lambda () cooked--session)))
    (cooked-tests--cell)
    (cooked--apply (cooked-tests--image-update-twice 7 3 1 (cooked-tests--png)))
    (let ((beg (point-min)))
      ;; Two runs of three, not one of six.
      (should (equal (next-single-property-change beg 'display) (+ beg 3)))
      (should (equal (next-single-property-change (+ beg 3) 'display) (+ beg 6)))
      ;; And each is sliced from the picture's own left edge.
      (should (equal (car (get-text-property beg 'display)) '(slice 0 0 30 20)))
      (should (equal (car (get-text-property (+ beg 3) 'display))
                     '(slice 0 0 30 20))))))

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
   (list (list id 'png (make-string bytes ?x) 10 20))))

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

(defun cooked-tests--image-cells-without-display ()
  "Buffer positions carrying an image `cooked-deco\=' and no `display\=' property.

The invariant every image path has to keep: the placement and the picture are
put on the same characters at the same moment, so a cell that claims to be part
of a picture and shows none is a cell whose image data went missing under it."
  (let ((bad nil)
        (pos (point-min)))
    (while (< pos (point-max))
      (let ((deco (get-text-property pos 'cooked-deco)))
        (when (and (eq (car-safe deco) 'image)
                   (not (get-text-property pos 'display)))
          (push pos bad)))
      (setq pos (1+ pos)))
    (nreverse bad)))

(ert-deftest cooked-every-image-cell-that-is-drawn-carries-its-picture ()
  "The invariant the rest of the image path is judged against, and the probe for
it.  A cell carrying an `(image ID ...)\=' `cooked-deco\=' and no `display\=' is a
cell that claims to be part of a picture and shows none -- correct geometry,
correct cursor, nothing drawn, which is what a placement of an id whose data
went missing underneath it looks like.

Both directions, because a probe that cannot fail proves nothing about the
suite that leans on it: a rendered picture has one on every cell, and a
placement of an id this buffer holds no data for has one on none.  The second
is `cooked-image-placement-without-data-renders-as-blanks\=' seen from here, and
it stays right for an id the buffer was never told about -- what must not
happen is reaching that state for an id it was told about and dropped, which is
`cooked-a-replayed-payload-draws-after-its-id-was-evicted\='."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 300")
    (should (cooked-tests--settle (lambda () cooked--session)))
    (cooked-tests--cell)
    (cooked--apply (cooked-tests--image-update 7 3 1 (cooked-tests--png)))
    (should-not (cooked-tests--image-cells-without-display))
    (cooked--apply (cooked-tests--image-update 99 3 1 nil))
    (should (= (length (cooked-tests--image-cells-without-display)) 3))))

(ert-deftest cooked-a-replayed-payload-draws-after-its-id-was-evicted ()
  "End to end, with a child transmitting real kitty graphics.

Twenty distinct one-pixel pictures, each drawn over the last -- an animation,
in miniature, and the shape `viu\=' draws a gif in.  Nineteen of them are then
showing nowhere, so the cap spends them; the child sends the first one\='s bytes
again on the next loop, and it has to arrive as a picture.  Before the module
was told about eviction it arrived as the id it had minted the first time
round, whose data this buffer no longer had, and the cells drew nothing.

Properties only -- batch Emacs draws no pixels, and none are needed: the
failure is entirely in whether a cell that says it is part of a picture has a
`display\=' property."
  ;; `stty raw -echo\=' for the reason `cooked-tests--with-echoing-child\=' uses it:
  ;; in cooked mode the line discipline would hold an APC with no newline in it
  ;; until one arrived, and echo it a second time when it did.
  (cooked-tests--with-session '("/bin/sh" "-c" "stty raw -echo; exec cat")
    (should (cooked-tests--settle (lambda () (eq cooked--mode 'raw))))
    (cooked-tests--cell)
    (let ((frames (cl-loop for n below 20
                           collect (concat "\r" (cooked-tests--kitty-rgb n)))))
      ;; `cat\=' echoes what it is sent, so the child\='s output is ours to compose
      ;; without any shell quoting in the middle.
      (dolist (frame frames)
        (cooked--send cooked--session frame))
      (should (cooked-tests--settle
               (lambda () (= (hash-table-count cooked--image-data) 20))))
      (should-not (cooked-tests--image-cells-without-display))
      ;; Only the last frame is on screen; the specs for the rest are held by
      ;; nothing once the collector has been round, which is what makes them the
      ;; ones the cap spends.
      (garbage-collect)
      (let ((first (car cooked--image-order)))
        ;; The cap is put back before the replay arrives: eviction runs as an
        ;; image is installed, which is before the row displaying it is
        ;; rendered, so a cap below the size of one picture would spend the
        ;; replayed frame on its way in and prove nothing.
        (let ((cooked-image-cache-size 1))
          (cooked--evict-images))
        (should-not (gethash first cooked--image-data))
        ;; The loop comes round: the same bytes again, about which the module has
        ;; been told we kept nothing.  A new id, and the payload with it.  The
        ;; trailing word is how the replay is waited for -- what it draws is the
        ;; question under test, so it cannot also be the signal that it arrived.
        (cooked--send cooked--session (concat (car frames) "done"))
        (should (cooked-tests--settle
                 (lambda () (string-match-p "done" (cooked-tests--text)))))
        (should-not (memq first (cooked--image-ids-between (point-min) (point-max))))
        (should-not (cooked-tests--image-cells-without-display))))))

(defun cooked-tests--kitty-rgb (n)
  "A kitty transmission of a one-pixel RGB image whose colour is N.

Raw pixels rather than a PNG: the payload is three bytes, so twenty distinct
pictures cost twenty distinct colours and no encoder."
  (format "\e_Ga=T,f=24,s=1,v=1,i=%d;%s\e\\"
          (1+ n)
          (base64-encode-string (unibyte-string n 0 0) t)))

(defun cooked-tests--kitty-rgb-block (w h)
  "A kitty transmission of a W by H picture of raw RGB pixels.

No `c=\=' or `r=\=': the pixels are all that says how many cells this covers,
which is what makes it a measurement against the cell size rather than a
request."
  (format "\e_Ga=T,f=24,s=%d,v=%d,i=1;%s\e\\"
          w h (base64-encode-string (make-string (* w h 3) 0) t)))

(ert-deftest cooked-a-replayed-payload-follows-the-cell-it-is-replayed-at ()
  "A font change must not leave two rectangles for one picture.

A transmission that names no cell rectangle is measured into one from its pixels,
and ids are content-addressed, so a looping animation replays bytes the module
already knows.  The rectangle used to be recorded against the *image*, which gave
one field two answers across a font change: whichever transmission wrote it last
decided how every row's slices were cut, and mid-gif the frames alternated between
the two sizes.  The module worked around it by forgetting every picture when the
cell moved, so each frame crossed the boundary again -- megabytes apiece -- purely
to be remeasured.

The rectangle rides each placement now, so both answers can be true at once: the
replayed bytes are recognised and no payload crosses, the new placement is laid at
the rectangle the new cell implies, and the row written before the change keeps the
one it was written with.  Resizing rows and columns alone does not move a cell and
is deliberately not this."
  (cooked-tests--with-session '("/bin/sh" "-c" "stty raw -echo; exec cat")
    (should (cooked-tests--settle (lambda () (eq cooked--mode 'raw))))
    (cooked-tests--cell 10 20)
    (cooked--resize cooked--session cooked--rows cooked--cols 10 20)
    (let ((frame (cooked-tests--kitty-rgb-block 20 40)))
      ;; 20x40 pixels is two cells by two at a 10x20 cell, and one by one once the
      ;; cell doubles.
      (cooked--send cooked--session frame)
      (should (cooked-tests--settle
               (lambda () (= (hash-table-count cooked--image-data) 1))))
      (let ((first (car cooked--image-order))
            (was (point-min)))
        (should (equal (nthcdr 4 (get-text-property was 'cooked-deco)) '(2 2)))
        ;; The font doubles.  Rows and columns reach the module by this same call
        ;; and are unchanged, which is the case the module must not spend a
        ;; retransmission on.
        (cooked-tests--cell 20 40)
        (cooked--resize cooked--session cooked--rows cooked--cols 20 40)
        (cooked--rescale-deco)
        ;; The loop comes round with the same bytes.  The trailing word is how the
        ;; replay is waited for, since what it draws is the question under test.
        (cooked--send cooked--session (concat "\r" frame "done"))
        (should (cooked-tests--settle
                 (lambda () (string-match-p "done" (cooked-tests--text)))))
        ;; One picture, and no second copy of two megabytes of it.
        (should (= (hash-table-count cooked--image-data) 1))
        (should (equal cooked--image-order (list first)))
        ;; The replayed row is laid at the new cell's rectangle, under the id it
        ;; already had...
        (let ((deco (get-text-property (line-beginning-position) 'cooked-deco)))
          (should (equal (nth 1 deco) first))
          (should (equal (nthcdr 4 deco) '(1 1))))
        ;; ...and the row written before the change keeps the rectangle it was
        ;; written with, which is the half that used to be overwritten.
        (should (equal (nthcdr 4 (get-text-property was 'cooked-deco)) '(2 2)))
        (should-not (cooked-tests--image-cells-without-display))))))

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
mismatched until this runs.

Read at the *second* cell of the three, which is a second claim riding along:
the run's `display\=' value covers the whole run, so the middle cell answers with
the run's slice -- 3 cells wide and one tall -- rather than with one of its own.
Both numbers in it move with the cell size, which is what is under test here."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 300")
    (should (cooked-tests--settle (lambda () cooked--session)))
    (cooked-tests--cell)
    (cooked--apply (cooked-tests--image-update 7 3 1 (cooked-tests--png)))
    (should (equal (car (get-text-property (1+ (point-min)) 'display))
                   '(slice 0 0 30 20)))
    (cooked-tests--cell 12 26)
    (cooked--rescale-deco)
    (should (equal (car (get-text-property (1+ (point-min)) 'display))
                   '(slice 0 0 36 26)))
    ;; And declines to walk the buffer again for a size it is already at.
    (cl-letf (((symbol-function 'next-single-property-change)
               (lambda (&rest _) (error "walked"))))
      (cooked--rescale-deco))))

(ert-deftest cooked-the-image-order-tail-tracks-its-list-through-every-writer ()
  "`cooked--image-order-tail\=' is a second copy of a fact -- which cons is last --
and the only thing that makes it safe is that nothing sets the list without it.
So this pins the invariant at each of the three writers rather than trusting the
call sites: an append, a forget taking an id out of the middle, and an eviction
pass putting back what it declined to spend.

A drifted tail does not fail loudly.  It appends to a cons that is no longer in
the list, so the id is recorded nowhere the eviction pass can see it, and the
cap silently stops bounding anything."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 300")
    (should (cooked-tests--settle (lambda () cooked--session)))
    (cl-flet ((tail-is-true ()
                (should (eq cooked--image-order-tail (last cooked--image-order)))))
      (let ((cooked-image-cache-size nil))
        (dolist (id '(1 2 3 4))
          (cooked-tests--install-image id 400)
          (tail-is-true)))
      (should (equal cooked--image-order '(1 2 3 4)))
      ;; Out of the middle, and off the end -- the end being the case that moves
      ;; the tail, and so the one a `delq' alone would get wrong.
      (cooked--forget-image 2)
      (tail-is-true)
      (should (equal cooked--image-order '(1 3 4)))
      (cooked--forget-image 4)
      (tail-is-true)
      (should (equal cooked--image-order '(1 3)))
      ;; And an append after the tail has moved lands where it belongs, which is
      ;; the failure a drifted tail actually produces.
      (let ((cooked-image-cache-size nil))
        (cooked-tests--install-image 5 400))
      (tail-is-true)
      (should (equal cooked--image-order '(1 3 5)))
      ;; The eviction pass detaches the queue and puts it back; the tail has to
      ;; come back with it.
      (let ((cooked-image-cache-size 500))
        (cooked--evict-images))
      (tail-is-true)
      ;; Emptied entirely, where the tail must go back to nil rather than name a
      ;; cons nothing holds.
      (dolist (id (copy-sequence cooked--image-order))
        (cooked--forget-image id))
      (should-not cooked--image-order)
      (tail-is-true))))

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
                   '(slice 0 0 36 26)))))

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
                   '(slice 0 0 30 20)))
    ;; And the same on every later drain: one picture, one scale.
    (cooked--apply (cooked-tests--image-update 7 3 1 nil))
    (should (equal (car (get-text-property (1+ (point-min)) 'display))
                   '(slice 0 0 30 20)))))

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
    (should (equal (get-text-property (point-min) 'cooked-deco) '(image 7 0 0 3 1)))
    ;; A window turns up; `cooked--sync-size' sees the cell move and repairs.
    (cooked-tests--cell)
    (cooked--rescale-deco)
    (should (equal (car (get-text-property (1+ (point-min)) 'display))
                   '(slice 0 0 30 20)))))

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
buffer shows is the answer having reached the child, which is the claim.

The frame is said to show images: a batch Emacs has only a terminal frame, and
there the probe is refused -- see `cooked-graphics-answers-follow-inline-images'."
  (cl-letf (((symbol-function 'cooked--frame-shows-images-p) #'always))
    (cooked-tests--with-session
        (list "/bin/sh" "-c"
              "printf '\\033_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\\033\\\\'; cat")
      (should (cooked-tests--settle
               (lambda () (string-match-p "_Gi=31;OK" (cooked-tests--text)))
               8)))))

(defconst cooked-tests--graphics-probes
  "\\033[c\\033[?1;1S\\033_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\\033\\\\"
  "DA1, the XTSMGRAPHICS register count and a kitty probe, for `printf'.")

(defun cooked-tests--graphics-prober (out)
  "Shell sending the graphics probes on each `q' it reads, logging the rest to OUT.

Replies arrive on the same stdin as the trigger, so they are told apart by
content: none of the three answers, refused or not, contains a `q'.  One byte
at a time through `dd' because a reply has no line ending to read up to."
  (list "/bin/sh" "-c"
        (format (concat "stty raw -echo; "
                        "while c=$(dd bs=1 count=1 2>/dev/null); do "
                        "if [ \"$c\" = q ]; then printf '%s'; "
                        "else printf '%%s' \"$c\" >> %s; fi; done")
                cooked-tests--graphics-probes out)))

(defun cooked-tests--graphics-replies (out)
  "Trigger the probes in this session, and return the replies logged to OUT.
Settles on the kitty reply, which is the last of the three to be sent."
  (with-temp-file out)
  (cooked--send cooked--session "q")
  (should (cooked-tests--settle
           (lambda () (string-match-p "_Gi=31;[^\033]*\033\\\\\\'"
                                      (cooked-tests--contents out)))))
  (cooked-tests--contents out))

(ert-deftest cooked-graphics-answers-follow-inline-images ()
  "Every answer that claims graphics withdraws the claim when images are turned
off, and makes it again when they come back on -- through the variable watcher,
with nothing but the toggle to set it off."
  (let ((out (make-temp-file "cooked-graphics"))
        (cooked-inline-images t))
    (unwind-protect
        (cl-letf (((symbol-function 'cooked--frame-shows-images-p) #'always))
          (cooked-tests--with-session (cooked-tests--graphics-prober out)
            (let ((shown (cooked-tests--graphics-replies out)))
              (should (string-match-p "\033\\[\\?62;4;22c" shown))
              (should (string-match-p "\033\\[\\?1;0;[0-9]+S" shown))
              (should (string-match-p "_Gi=31;OK" shown)))
            (setq cooked-inline-images nil)
            (let ((hidden (cooked-tests--graphics-replies out)))
              (should (string-match-p "\033\\[\\?62;22c" hidden))
              (should (string-match-p "\033\\[\\?1;3S" hidden))
              (should (string-match-p "_Gi=31;ENOTSUPPORTED" hidden)))
            (setq cooked-inline-images t)
            (should (string-match-p "\033\\[\\?62;4;22c"
                                    (cooked-tests--graphics-replies out)))))
      (delete-file out))))

(ert-deftest cooked-graphics-answers-drop-sixel-on-a-terminal-frame ()
  "A buffer shown only on a frame that cannot display images drops the `4' from
DA1, and a graphical window showing it too brings it back.

The frames are stood in for through `cooked--frame-shows-images-p', batch Emacs
having only the one terminal frame, and the window hook is called rather than
waited for: `window-buffer-change-functions' runs from redisplay, which a batch
session does not do.  What this covers is the decision and its wiring to the
core; that the hook fires on a real frame change is Emacs' own promise."
  (let ((out (make-temp-file "cooked-graphics-tty"))
        (graphical t))
    (unwind-protect
        (cl-letf (((symbol-function 'cooked--frame-shows-images-p)
                   (lambda (_frame) graphical)))
          (cooked-tests--with-session (cooked-tests--graphics-prober out)
            ;; Displayed nowhere yet, so the frame the session started from
            ;; answered, and it was graphical.
            (should (string-match-p "\033\\[\\?62;4;22c"
                                    (cooked-tests--graphics-replies out)))
            (cooked-tests--display-buffer)
            (setq graphical nil)
            (cooked--sync-graphics-everywhere)
            (should (string-match-p "\033\\[\\?62;22c"
                                    (cooked-tests--graphics-replies out)))
            ;; Buried: no window says anything, so the answer stays where it was
            ;; rather than being guessed from whichever frame is selected.
            (set-window-buffer (selected-window) (get-buffer-create " *cooked-other*"))
            (setq graphical t)
            (cooked--sync-graphics-everywhere)
            (should (string-match-p "\033\\[\\?62;22c"
                                    (cooked-tests--graphics-replies out)))
            (set-window-buffer (selected-window) buffer)
            (cooked--sync-graphics-everywhere)
            (should (string-match-p "\033\\[\\?62;4;22c"
                                    (cooked-tests--graphics-replies out)))))
      (delete-file out))))

(ert-deftest cooked-window-hooks-walk-the-sessions-once ()
  "A window change walks the cooked buffers once per frame, rather than once for
attention and again for graphics, and walks no buffer that is not cooked.  A
theme change syncs the cursor color of the frames showing a cooked buffer, once
each, rather than every frame once per cooked buffer."
  (let* ((sessions (list (generate-new-buffer "*cooked-a*") (generate-new-buffer "*cooked-b*")))
         (others (cl-loop repeat 20 collect (generate-new-buffer " *cooked-other*")))
         (left (generate-new-buffer "*cooked-left*"))
         (window-buffer (window-buffer (selected-window)))
         (walks 0) (attended nil) (synced 0))
    (unwind-protect
        (progn
          (dolist (buffer (cons left sessions))
            (with-current-buffer buffer (cooked-mode)))
          ;; A buffer that left the mode, and one that was killed, are not walked.
          (with-current-buffer left (fundamental-mode))
          (let ((dead (generate-new-buffer "*cooked-dead*")))
            (with-current-buffer dead (cooked-mode))
            (kill-buffer dead))
          (should (equal (seq-filter (lambda (buffer) (memq buffer sessions)) (buffer-list))
                         (seq-filter (lambda (buffer)
                                       (string-prefix-p "*cooked-" (buffer-name buffer)))
                                     (cooked--buffers))))
          (cl-letf* ((real-buffers (symbol-function 'cooked--buffers))
                     ((symbol-function 'cooked--buffers)
                      (lambda () (cl-incf walks) (funcall real-buffers)))
                     ((symbol-function 'cooked--update-buffer-attention)
                      (lambda () (push (current-buffer) attended)))
                     ((symbol-function 'cooked--sync-cursor-color)
                      (lambda (_frame) (cl-incf synced))))
            (run-hook-with-args 'window-buffer-change-functions (selected-frame))
            (should (= walks 1))
            (should-not (seq-difference sessions attended))
            (should-not (seq-intersection (cons left others) attended))
            ;; Nothing shows a cooked buffer: nothing to sync on a theme change.
            (setq synced 0)
            (cooked--flush-face-cache)
            (should (= synced 0))
            (set-window-buffer (selected-window) (car sessions))
            (cooked--flush-face-cache)
            (should (= synced 1))))
      (set-window-buffer (selected-window) window-buffer)
      (mapc #'kill-buffer (append sessions others (list left))))))

;;;; Containment
;;
;; Every one of these binds `cooked-debug' back to nil against the fixture's own
;; binding, and has to: under debug the containment they are about re-signals by
;; design, which would put the deliberate error into the process filter and end
;; the batch run rather than fail one test.  The fixture turning it *on* is what
;; makes the rest of the suite mean anything; these are the exception that
;; proves it.

(ert-deftest cooked-a-signalling-row-layer-does-not-end-the-drain ()
  "`cooked-row-rendered-functions' is the loudest seam there is -- once per
damaged row per drain -- so a layer that signals there signals continuously.
The buffer has to go on rendering regardless, because the text was already
correct before the layer was asked."
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle (lambda () cooked--session)))
    ;; Two entries, and the assertion is on the *second*: the drain surviving
    ;; on its own proves nothing here, because `cooked--on-wake' has an outer
    ;; guard that resyncs a failed redisplay and the text would arrive that way
    ;; regardless.  What only per-entry containment can give is the entry after
    ;; the broken one still running.
    (let* ((cooked-debug nil)
           (painted 0)
           (cooked-row-rendered-functions
            (list (lambda (_beg _end) (error "cooked-tests: deliberate row failure"))
                  (lambda (_beg _end) (cl-incf painted)))))
      (cooked--send cooked--session "hello\n")
      (should (cooked-tests--settle
               (lambda () (string-match-p "hello" (cooked-tests--text)))))
      (should (> painted 0)))
    ;; And the session is not wedged once the layer is gone.
    (cooked--send cooked--session "afterwards\n")
    (should (cooked-tests--settle
             (lambda () (string-match-p "afterwards" (cooked-tests--text)))))))

(ert-deftest cooked-a-signalling-scan-layer-does-not-end-the-drain ()
  "The same for the scrollback scan, which is the seam an optional layer is
allowed to touch the filesystem from."
  (cooked-tests--with-session '("/bin/sh" "-c" "for i in $(seq 60); do echo line $i; done; sleep 5")
    ;; The second entry is the assertion, for the reason the row test gives:
    ;; the transcript arriving proves only that `cooked--on-wake' resynced.
    (let* ((cooked-debug nil)
           (scanned 0)
           (cooked-link-scan-functions
            (list (lambda (_beg _end) (error "cooked-tests: deliberate scan failure"))
                  (lambda (_beg _end) (cl-incf scanned)))))
      (should (cooked-tests--settle
               (lambda () (string-match-p "line 60" (cooked-tests--text)))))
      ;; The scan hook runs from `cooked--fontify-region' now, so it is
      ;; redisplay that asks for it -- and batch mode does not redisplay.
      (cooked-tests--fontify)
      (should (> scanned 0)))))

(ert-deftest cooked-a-signalling-seam-entry-costs-only-its-own-contribution ()
  "The whole reason `cooked--run-seam' is not `run-hook-with-args': that one
contains nothing, so the first entry to signal would take every entry after it."
  (with-temp-buffer
    (cooked-mode)
    (let* ((cooked-debug nil)
           (ran nil)
           (seam (list (lambda () (error "cooked-tests: deliberate"))
                       (lambda () (push 'second ran)))))
      (let ((cooked-tests--seam seam))
        (cooked--run-seam 'cooked-tests--seam))
      (should (equal ran '(second))))))

(ert-deftest cooked-a-signalling-seam-entry-is-no-answer-rather-than-no-seam ()
  "`until-success' and the containment compose: an entry that signals has given
no answer, so the next one is asked instead of the seam falling silent."
  (with-temp-buffer
    (cooked-mode)
    (let* ((cooked-debug nil)
           (cooked-tests--seam (list (lambda () (error "cooked-tests: deliberate"))
                                     (lambda () 'answer))))
      (should (eq (cooked--run-seam-until-success 'cooked-tests--seam) 'answer)))))

(ert-deftest cooked-a-broken-seam-is-reported-once-and-then-goes-quiet ()
  "A seam on the drain path fires per row per drain, so an unrated `message' is
a broken layer taking the echo area away from everything else Emacs has to say."
  (with-temp-buffer
    (cooked-mode)
    (let* ((cooked-debug nil)
           (said 0)
           (cooked-tests--seam (list (lambda () (error "cooked-tests: deliberate")))))
      (cl-letf (((symbol-function 'message) (lambda (&rest _) (cl-incf said))))
        (dotimes (_ 5) (cooked--run-seam 'cooked-tests--seam)))
      (should (= said 1))
      ;; A different entry on the same seam is still heard from: the key is the
      ;; pair, not the hook, so one broken layer silences only itself.
      (let ((cooked-tests--seam
             (list (lambda () (error "cooked-tests: a different one")))))
        (cl-letf (((symbol-function 'message) (lambda (&rest _) (cl-incf said))))
          (cooked--run-seam 'cooked-tests--seam))
        (should (= said 2))))))

(ert-deftest cooked-the-cap-never-spends-the-picture-being-drawn ()
  "Eviction runs from `cooked--install-images', which is called before both
render passes -- so every id in the arriving drain reads as undisplayed, being
displayed by rows that do not exist yet.  They are the most evictable entries in
the table at exactly the moment they must not be touched.

The loop stops when the bytes come down, and an id it declines to spend does not
bring them down: a run of still-displayed ids walks it to the far end and spends
the picture the caller is about to draw.  `cooked--image-spec' answers nil for an
id with no data, so those cells get a `cooked-deco' and no `display' -- a blank
rectangle of exactly the right size in exactly the right place, which is what a
2MB-a-frame gif against a 64MB cap actually did."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 300")
    (should (cooked-tests--settle (lambda () cooked--session)))
    (cooked-tests--cell)
    ;; A cap two frames wide, and one frame already in it that reads as displayed
    ;; -- which is the state the collector leaves behind under any real load.
    (let ((cooked-image-cache-size 200))
      (cooked--apply (cooked-tests--image-update 1 3 1 (cooked-tests--png)))
      (should (gethash 1 cooked--image-data))
      ;; The next drain arrives with the cap already met.  The picture it carries
      ;; must survive it, whatever eviction decides about anything older.
      (cooked--apply (cooked-tests--image-update 2 3 1 (make-string 300 ?x)))
      (should (gethash 2 cooked--image-data))
      (should-not (cooked-tests--image-cells-without-display)))))

(ert-deftest cooked-a-line-written-back-unchanged-is-not-rewritten ()
  "A child that erases a line and writes the same text back leaves the row alone.

The core compares the row with its copy of what Emacs holds and leaves it out of
the drain, so the buffer text is never deleted and reinserted.  A marker in the
middle of the row is the witness: a rewrite collapses it to the start of the
row, and an untouched row keeps it where it was.  The write to row 2 afterwards
is only there to say the rewrite has arrived."
  (cooked-tests--with-session
      '("/bin/sh" "-c"
        "printf 'status'; sleep 0.3; printf '\\033[1;1H\\033[2Kstatus\\033[2;1Hdone'; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "status" (cooked-tests--text)))))
    (let ((marker (save-excursion
                    (goto-char (cooked--screen-start-position))
                    (copy-marker (+ (point) 3)))))
      (should (cooked-tests--settle
               (lambda () (string-match-p "done" (cooked-tests--text)))))
      (should (= (- marker (cooked--screen-start-position)) 3)))))

(ert-deftest cooked-a-row-the-guard-trimmed-is-forgotten-by-the-core ()
  "Each row the width guard shortens is reported to the core by its screen index.

The core would otherwise match a later repaint of the same cells against the
text it sent, which is no longer what the buffer holds."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'one\\ntwo'; sleep 5")
    (cooked-tests--display-buffer)
    (should (cooked-tests--settle
             (lambda () (string-match-p "two" (cooked-tests--text)))))
    (let ((cooked-rejoin-wrapped-lines t)
          (unsent nil))
      (cl-letf (((symbol-function 'cooked--guard-row-width) (lambda (&rest _) t))
                ((symbol-function 'cooked--row-unsent)
                 (lambda (_session row) (push row unsent))))
        (cooked--redraw cooked--session)
        (cooked--apply (cooked--drain cooked--session t)))
      (should (member 0 unsent))
      (should (member 1 unsent)))))

(ert-deftest cooked-a-theme-change-makes-the-core-send-every-row-again ()
  "A theme change leaves faces resolved against the old theme on every row.

So the core is told its copy of the screen is out of date, and a child
repainting the same cells afterwards gets them in the new colours."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'one'; sleep 5")
    (let ((unsent nil)
          (session cooked--session))
      (cl-letf (((symbol-function 'cooked--row-unsent)
                 (lambda (handle row) (push (cons handle row) unsent))))
        (cooked--flush-face-cache))
      (should (member (cons session nil) unsent)))))

(ert-deftest cooked-a-zoom-makes-the-core-send-every-row-again ()
  "Rows rendered under one layout are sent again once the layout moves.

The width guard measured, scaled and trimmed them against the font that has
just gone, and the core\='s copy of the screen would leave every one of them out
of a drain until its cells changed -- so a zoom that kept the grid size left
the rows on screen scaled for the old font for as long as a program repainted
the same frame.  The stamp moving is what says so, and nothing is sent while it
stays put."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'one\\ntwo'; sleep 5")
    (cooked-tests--display-buffer)
    (should (cooked-tests--settle
             (lambda () (string-match-p "two" (cooked-tests--text)))))
    (let ((cooked-rejoin-wrapped-lines t))
      (cooked--wrap-cache (selected-window))
      (cooked--apply (cooked--drain cooked--session t))
      (cooked--wrap-cache (selected-window))
      (should-not (plist-get (cooked--drain cooked--session t) :rows))
      (text-scale-increase 1)
      (cooked--wrap-cache (selected-window))
      (let ((rows (plist-get (cooked--drain cooked--session t) :rows)))
        (should (assq 0 rows))))))

(ert-deftest cooked-turning-box-drawing-off-redraws-the-screen-at-once ()
  "An option that changes how the same cells are drawn reaches the screen now.

A border already drawn as a bitmap stayed one after
`cooked-box-drawing-images\=' was turned off, because nothing renders a row
again until the child sends different cells for it.  Its `:set\=' redraws every
running screen instead."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\342\\224\\214\\342\\224\\200\\342\\224\\220\\n'; sleep 5")
    (cooked-tests--cell)
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'display))))
    (unwind-protect
        (progn
          (customize-set-variable 'cooked-box-drawing-images nil)
          (should (string-prefix-p "┌─┐" (cooked-tests--text)))
          (should-not (get-text-property (point-min) 'display)))
      (customize-set-variable 'cooked-box-drawing-images t))))

;;;; Edits: part of a row replaced in place

(defun cooked-tests--screen-row-text (row)
  "The buffer text of screen ROW."
  (save-excursion
    (cooked--goto-screen-row row)
    (buffer-substring-no-properties (point) (line-end-position))))

(defun cooked-tests--cell-marker (row column)
  "A marker at COLUMN characters into screen ROW."
  (save-excursion
    (cooked--goto-screen-row row)
    (copy-marker (+ (point) column))))

(defun cooked-tests--marker-column (marker row)
  "How many characters into screen ROW MARKER sits."
  (save-excursion
    (cooked--goto-screen-row row)
    (- marker (point))))

(ert-deftest cooked-an-edit-turns-a-spinner-without-rewriting-the-row ()
  "One changed cell is replaced in place, and a marker elsewhere on the row stays."
  (cooked-tests--with-session
      '("/bin/sh" "-c"
        "printf 'working | on the build'; sleep 0.4; printf '\\033[1;9H/\\033[3;1Hsync'; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "build" (cooked-tests--text)))))
    (let ((marker (cooked-tests--cell-marker 0 14)))
      (should (cooked-tests--settle
               (lambda () (string-match-p "sync" (cooked-tests--text)))))
      (should (equal (cooked-tests--screen-row-text 0) "working / on the build"))
      (should (= (cooked-tests--marker-column marker 0) 14)))))

(ert-deftest cooked-an-edit-grows-the-tail-of-a-progress-bar ()
  "A bar\'s tail is replaced in place, and its label keeps its markers."
  (cooked-tests--with-session
      '("/bin/sh" "-c"
        "printf 'downloading the thing  [##        ]'; sleep 0.4; printf '\\033[1;26H###\\033[3;1Hsync'; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "##" (cooked-tests--text)))))
    (let ((marker (cooked-tests--cell-marker 0 4)))
      (should (cooked-tests--settle
               (lambda () (string-match-p "sync" (cooked-tests--text)))))
      (should (equal (cooked-tests--screen-row-text 0) "downloading the thing  [####      ]"))
      (should (= (cooked-tests--marker-column marker 0) 4)))))

(ert-deftest cooked-an-edit-beside-a-wide-character-counts-characters ()
  "The replaced text is found by characters, which a wide character is one of."
  (cooked-tests--with-session
      '("/bin/sh" "-c"
        "printf '\\344\\270\\200\\344\\272\\214 x and some more text'; sleep 0.4; printf '\\033[1;6Hy\\033[3;1Hsync'; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "more" (cooked-tests--text)))))
    (let ((marker (cooked-tests--cell-marker 0 1)))
      (should (cooked-tests--settle
               (lambda () (string-match-p "sync" (cooked-tests--text)))))
      (should (equal (cooked-tests--screen-row-text 0) "一二 y and some more text"))
      (should (= (cooked-tests--marker-column marker 0) 1)))))

(ert-deftest cooked-an-edit-beside-box-glyphs-replaces-the-whole-run ()
  "A change inside a run of box glyphs replaces the run, never half of one.

Lisp draws a glyph run as one decoration over the whole run, so an edit that
replaced part of one would leave the rest carrying a decoration drawn for a run
that no longer exists.  Filling the gap between two borders joins them into one
run, and every glyph of it has to carry the same decoration afterwards."
  (cooked-tests--with-session
      '("/bin/sh" "-c"
        "printf 'status: \\342\\224\\200\\342\\224\\200\\342\\224\\200\\342\\224\\200 \\342\\224\\200\\342\\224\\200\\342\\224\\200\\342\\224\\200 old'; sleep 0.4; printf '\\033[1;13H\\342\\224\\200\\033[3;1Hsync'; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "old" (cooked-tests--text)))))
    (let ((marker (cooked-tests--cell-marker 0 3)))
      (should (cooked-tests--settle
               (lambda () (string-match-p "sync" (cooked-tests--text)))))
      (should (equal (cooked-tests--screen-row-text 0)
                     (concat "status: " (make-string 9 ?─) " old")))
      (should (= (cooked-tests--marker-column marker 0) 3))
      (save-excursion
        (cooked--goto-screen-row 0)
        (let* ((bol (point))
               (deco (get-text-property (+ bol 8) 'cooked-deco)))
          (should deco)
          (dotimes (i 9)
            (should (eq (get-text-property (+ bol 8 i) 'cooked-deco) deco))))))))

(ert-deftest cooked-an-edit-before-the-cursor-keeps-the-prompts-padding ()
  "An edit inside a prompt leaves the space the cursor stands after in place."
  (cooked-tests--with-session
      '("/bin/sh" "-c"
        "printf 'ready now$ '; sleep 0.4; printf '\\0337\\033[1;1HR\\0338'; exec cat")
    (should (cooked-tests--settle
             (lambda () (string-match-p "ready" (cooked-tests--text)))))
    (should (cooked-tests--settle
             (lambda ()
               (let ((case-fold-search nil))
                 (string-match-p "Ready" (cooked-tests--text))))))
    (should (cooked--input-start-position))
    (should (equal (buffer-substring-no-properties
                    (save-excursion (cooked--goto-screen-row 0) (point))
                    (cooked--input-start-position))
                   "Ready now$ "))))

(provide 'cooked-tests-render)
;;; cooked-tests-render.el ends here

(ert-deftest cooked-a-theme-change-resolves-renditions-again-without-the-core-resending-them ()
  "Faces are resolved from the renditions Lisp already holds, not asked for again.

The core announces each rendition id once, as a drain\='s `:styles\=', and a theme
change must not need it to announce them again: the buffer keeps the renditions
and forgets only the faces made from them, so the next repaint of the same text
comes out in the new theme\='s colours from ids the core already sent."
  (cooked-tests--with-session
      '("/bin/sh" "-c"
        "printf '\\033[31mred\\033[0m'; read _; printf '\\033[31mred\\033[0m'; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "red" (cooked-tests--text)))))
    (let* ((start (cooked--screen-start-position))
           (before (get-text-property start 'face))
           (announced nil))
      (should before)
      (cl-letf* ((original (symbol-function 'cooked--install-styles))
                 ((symbol-function 'cooked--install-styles)
                  (lambda (styles)
                    (when styles (push styles announced))
                    (funcall original styles)))
                 ((symbol-function 'cooked--color)
                  (let ((color (symbol-function 'cooked--color)))
                    (lambda (spec)
                      (if (eql spec 1) "#123456" (funcall color spec))))))
        (cooked--flush-face-cache)
        (should-not (seq-some #'identity cooked--style-faces))
        (cooked--send cooked--session "\n")
        ;; The line after the echoed newline is drawn with the rendition id the core
        ;; announced for the first one.
        (should (cooked-tests--settle
                 (lambda ()
                   (save-excursion
                     (goto-char (point-max))
                     (and (search-backward "red" start t)
                          (> (point) start)
                          (equal (plist-get (get-text-property (point) 'face)
                                            :foreground)
                                 "#123456"))))))
        (should-not announced)))))
