;;; cooked-tests-input.el --- Keys, mouse, pasting and who owns the keyboard -*- lexical-binding: t; -*-

;;; Commentary:

;; The input half: how a key event becomes bytes, when those bytes are sent at
;; all rather than editing an Emacs buffer, and the mouse and paste paths that
;; hang off the same question.

;;; Code:

(require 'cooked-tests-helpers)

(ert-deftest cooked-raw-mode-passes-keys-through ()
  (cooked-tests--with-session '("/bin/sh" "-c" "stty -icanon -echo; sleep 5")
    (should (cooked-tests--settle (lambda () (eq cooked--mode 'raw))))
    (should-not (cooked--input-state-p))
    (should (eq (current-local-map) (cooked--forwarding-map cooked-raw-map)))))

(ert-deftest cooked-alt-mode-installs-the-alt-map-and-still-forwards-everything ()
  "The alternate screen means a full-screen program has taken over completely,
so nothing beyond `C-c' is reserved there -- unlike plain `raw', it has no
customizable exceptions at all."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\033[?1049h'; stty raw -echo; cat -v")
    (should (cooked-tests--settle (lambda () cooked--alt)))
    (should (eq (current-local-map) (cooked--forwarding-map cooked-alt-map)))
    (dolist (key '("C-g" "C-x" "C-h" "C-u" "C-l"))
      (should (eq (lookup-key cooked-alt-map (kbd key)) #'cooked-send-key)))))

(ert-deftest cooked-policy-keeps-nothing-back-once-the-shell-has-spoken ()
  "`cooked-raw-exceptions' hedges a state cooked cannot read: a raw program and
a shell editing its own prompt line look alike.  OSC 133 removes the doubt, so
once any mark has arrived the hedge is off and `C-u'/`C-l' -- readline's
kill-line and every shell's clear-screen -- go to the child like anything else."
  (cooked-tests--with-session '("/bin/sh" "-c" "stty -icanon -echo; exec cat")
    (should (cooked-tests--settle (lambda () (eq (cooked--policy) 'raw))))
    ;; No mark has arrived, so the exceptions still apply.
    (should (eq (lookup-key cooked-raw-map (kbd "C-u")) nil))
    (should-not (eq (key-binding (kbd "C-u")) #'cooked-send-key))

    ;; One mark is enough: the shell is talking, so its silence is informative.
    (cooked--handle-semantic '(command-start nil nil) nil)
    (should cooked--semantic-seen)
    (should (eq (cooked--policy) 'command))
    (cooked--refresh-keymap)
    (should (eq (key-binding (kbd "C-u")) #'cooked-send-key))
    (should (eq (key-binding (kbd "C-l")) #'cooked-send-key))
    ;; C-c is still ours, in every state.
    (should-not (eq (key-binding (kbd "C-c C-c")) #'cooked-send-key))))

(ert-deftest cooked-command-state-still-reaches-cookeds-own-commands ()
  "`cooked-command-map' is a child of `cooked-mode-map' like the others, or
stepping out would be impossible from the one state that forwards the most."
  (should (eq (keymap-parent cooked-command-map) cooked-mode-map))
  (should (eq (lookup-key cooked-command-map (kbd "C-c C-v")) #'cooked-toggle-peek)))

(ert-deftest cooked-raw-exceptions-are-not-bound-to-forward ()
  "The default `cooked-raw-exceptions' leave a handful of keys for Emacs even
though the child is reading raw, unlike the alternate screen (see the test
above), which has none."
  (dolist (key '("C-g" "C-x" "C-h" "C-u" "C-l"))
    (should-not (eq (lookup-key cooked-raw-map (kbd key)) #'cooked-send-key))))

(ert-deftest cooked-raw-exceptions-can-be-customized ()
  "Rebuilds `cooked-raw-map' in place -- in place because the map already has
`cooked-mode-map' as its keymap parent, set once when the major mode is
defined, and a fresh keymap object handed to `setq' would lose it."
  (let ((original cooked-raw-exceptions))
    (unwind-protect
        (progn
          (customize-set-variable 'cooked-raw-exceptions '("C-w"))
          (should-not (eq (lookup-key cooked-raw-map (kbd "C-w")) #'cooked-send-key))
          (should (eq (lookup-key cooked-raw-map (kbd "C-g")) #'cooked-send-key))
          (should (eq (keymap-parent cooked-raw-map) cooked-mode-map)))
      (customize-set-variable 'cooked-raw-exceptions original))))

(ert-deftest cooked-yank-key-still-forwards-despite-the-exceptions-list ()
  "Plain `C-y' is both vim's scroll-up-a-line and readline's own yank -- real
bindings a user relying on the child is actively using -- so it is kept out
of `cooked-raw-exceptions' regardless of what the list otherwise contains."
  (should (eq (lookup-key cooked-raw-map (kbd "C-y")) #'cooked-send-key))
  (should (eq (lookup-key cooked-alt-map (kbd "C-y")) #'cooked-send-key)))

(ert-deftest cooked-send-literal-key-forces-a-reserved-key-through ()
  "`C-c C-q' is the way back for a raw program that wants one of
`cooked-raw-exceptions' for itself, such as readline's own `C-g'."
  (cooked-tests--with-echoing-child ""
    (cl-letf (((symbol-function 'read-key) (lambda (&rest _) ?\C-g)))
      (call-interactively #'cooked-send-literal-key))
    (should (cooked-tests--settle
             (lambda () (string-search "^G" (cooked-tests--text)))))))

(ert-deftest cooked-send-literal-key-can-force-a-literal-c-c-through ()
  "`C-c' is cooked's own permanent prefix, but `cooked-send-literal-key' can
still put a literal `C-c' byte on the wire for a child that wants it."
  (cooked-tests--with-echoing-child ""
    (cl-letf (((symbol-function 'read-key) (lambda (&rest _) ?\C-c)))
      (call-interactively #'cooked-send-literal-key))
    (should (cooked-tests--settle
             (lambda () (string-search "^C" (cooked-tests--text)))))))

(ert-deftest cooked-send-escape-sends-escape-past-insert-state ()
  "`C-c <escape>' puts ESC on the wire, for the insert state that keeps ESC."
  (cooked-tests--with-echoing-child ""
    (call-interactively #'cooked-send-escape)
    (should (cooked-tests--settle
             (lambda () (string-search "^[" (cooked-tests--text)))))))

(ert-deftest cooked-toggle-peek-freezes-the-render-and-thaws-on-exit ()
  "Peeking suspends forwarding and drawing; toggling again resumes both and
catches the buffer up on whatever the child produced meanwhile."
  (cooked-tests--with-echoing-child ""
    (call-interactively #'cooked-toggle-peek)
    (should (cooked--suspended-p))
    (should (eq (current-local-map) cooked-peek-map))
    (should buffer-read-only)
    (cooked--send-to-child "frozen")
    ;; Give a real drain every chance to land, so the negative assertion means
    ;; something rather than just being too soon to tell -- `cooked-tests--pump'
    ;; rather than `cooked-tests--settle', which would force the very drain
    ;; this is testing is suppressed.
    (cooked-tests--pump 0.3)
    (should-not (string-search "frozen" (cooked-tests--text)))
    (call-interactively #'cooked-toggle-peek)
    (should-not (cooked--suspended-p))
    (should (eq (current-local-map) (cooked--forwarding-map cooked-raw-map)))
    (should-not buffer-read-only)
    (should (cooked-tests--settle
             (lambda () (string-search "frozen" (cooked-tests--text)))))))

(ert-deftest cooked-toggle-peek-refuses-at-a-prompt ()
  "Peeking is meaningless once Emacs already owns the line."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '$ '; cat")
    (should (cooked-tests--settle
             (lambda () (and (cooked--input-state-p) (cooked--input-start-position)))))
    (cooked--refresh-keymap)
    (should-error (call-interactively #'cooked-toggle-peek) :type 'user-error)))

(ert-deftest cooked-semi-map-forwards-what-the-child-needs-and-keeps-the-rest ()
  "The hybrid's whole point is where it draws the line.  Readline's and vim's
control keys still forward -- a rule of \"Emacs wins wherever Emacs has a
binding\" would have taken all of them, `global-map' binding almost every
control character.  ESC, the Meta space and `cooked-semi-exceptions' do not,
so insert state stays a state you can leave."
  (dolist (key '("C-a" "C-e" "C-k" "C-r" "C-w" "C-d" "TAB" "<up>"))
    (should (eq (lookup-key cooked-semi-map (kbd key)) #'cooked-send-key)))
  ;; Left unbound here, so they fall through to Emacs.  ESC unbound is what
  ;; makes Emacs treat it as `meta-prefix-char' again, which is how the whole
  ;; Meta space comes back without naming a key of it.
  ;; Not `cooked-send-key' rather than not bound at all: these maps are
  ;; parented onto `cooked-mode-map', so `lookup-key' answers for the whole
  ;; chain, and what matters is that nothing here forwards them.
  (dolist (key '("C-g" "C-x" "C-h" "C-u" "C-l" "ESC" "M-x" "M-SPC" "M-<up>"))
    (should-not (eq (lookup-key cooked-semi-map (kbd key)) #'cooked-send-key)))
  ;; The full maps keep forwarding ESC: a TUI needs it, and forwarding it the
  ;; instant it is pressed is what keeps a real Escape key from waiting.
  (dolist (map (list cooked-raw-map cooked-alt-map))
    (should (eq (lookup-key map (kbd "ESC")) #'cooked-send-key)))
  ;; `C-c' is reserved in every one of them, hybrid included.
  (dolist (map (list cooked-raw-map cooked-alt-map cooked-semi-map))
    (should-not (eq (lookup-key map (kbd "C-c")) #'cooked-send-key)))
  ;; And cooked's own commands are still reachable, being on the shared parent.
  (should (eq (lookup-key cooked-semi-map (kbd "C-c C-c")) #'cooked-interrupt)))

(ert-deftest cooked-meta-chords-forward-on-a-graphical-frame ()
  "A terminal frame sends a Meta chord as two bytes and the passthrough maps
forward both, so `M-t' arrives without anyone binding it.  A graphical frame
sends one event that no list of character codes can name, and the map worn
there has to bind it -- through an ESC prefix, because that is the only place
`define-key' will store a Meta character."
  (let ((map (cooked--build-meta-overlay cooked-alt-map)))
    (dolist (key '("M-t" "M-x" "M-SPC" "C-M-t" "M-ESC"))
      (should (eq (lookup-key map (kbd key)) #'cooked-send-meta-key)))
    ;; The Escape key keeps its own zero-latency spelling: `escape' is what a
    ;; graphical frame sends, and it only decays to a bare ESC when unbound.
    (should (eq (lookup-key map [escape]) #'cooked-send-key))
    ;; `ESC O' and `ESC [' begin the sequences every other key arrives as.
    (dolist (key '("M-O" "M-["))
      (should-not (lookup-key map (kbd key))))
    ;; And the parent still answers for everything it always did.
    (should (eq (lookup-key map (kbd "C-a")) #'cooked-send-key))
    (should (eq (lookup-key map (kbd "<up>")) #'cooked-send-key))
    (should-not (eq (lookup-key map (kbd "C-c")) #'cooked-send-key))
    (should (eq (lookup-key map (kbd "C-c C-v")) #'cooked-toggle-peek))))

(ert-deftest cooked-forwarding-map-leaves-a-terminal-frame-alone ()
  "The overlay's one cost is that ESC becomes a prefix and so has to wait for
what follows.  A terminal frame never needed it -- the two bytes are already
forwarded separately -- so it keeps the plain map, and the same overlay is
reused rather than rebuilt when a graphical frame does ask."
  (should-not (display-graphic-p))
  (should (eq (cooked--forwarding-map cooked-alt-map) cooked-alt-map))
  (should (eq (lookup-key cooked-alt-map (kbd "ESC")) #'cooked-send-key))
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
    (let ((cooked--meta-overlays nil))
      (let ((first (cooked--forwarding-map cooked-alt-map)))
        (should-not (eq first cooked-alt-map))
        (should (eq (keymap-parent first) cooked-alt-map))
        (should (eq (cooked--forwarding-map cooked-alt-map) first))))))

(ert-deftest cooked-send-meta-key-puts-the-modifier-back ()
  "Arriving as `ESC t' leaves `last-command-event' a bare `?t', with the
modifier gone by the time a command runs.  Putting it back rather than simply
sending an ESC byte is what lets a negotiated protocol spell it as a modifier
parameter -- here, with nothing negotiated, it is the classical `ESC t'."
  (cooked-tests--with-echoing-child ""
    (let ((last-command-event ?t))
      (call-interactively #'cooked-send-meta-key))
    (should (cooked-tests--settle
             (lambda () (string-search "^[t" (cooked-tests--text)))))))

(ert-deftest cooked-evil-normal-state-keeps-the-render-live ()
  "`C-z' into normal state is the key an evil user presses to do anything at
all -- reach a leader, scroll, get to another window -- and it used to stop
the terminal dead until they came back.  Normal state suspends forwarding and
stops the view chasing the cursor; the child keeps drawing throughout."
  :tags '(evil)
  (skip-unless (require 'evil nil t))
  (require 'cooked-evil)
  (evil-mode 1)
  (cooked-tests--with-echoing-child ""
    (should (eq (bound-and-true-p evil-state) 'emacs))
    (evil-normal-state)
    (should (eq cooked--input-mode 'still))
    (should (cooked--suspended-p))
    (should-not (cooked--frozen-p))
    (should (eq (current-local-map) cooked-peek-map))
    (should buffer-read-only)
    (cooked--send-to-child "live")
    (should (cooked-tests--settle
             (lambda () (string-search "live" (cooked-tests--text)))))
    ;; And back: emacs state hands the keyboard over again.
    (evil-emacs-state)
    (should-not (cooked--suspended-p))
    (should (eq (current-local-map) (cooked--forwarding-map cooked-raw-map)))
    (should-not buffer-read-only)))

(ert-deftest cooked-evil-insert-state-resumes-forwarding-from-normal-state ()
  "The hole in latching the freeze onto emacs state: nothing thawed a buffer
left in insert state, because the thaw hung on *entering* emacs state and the
auto-resume needs `self-insert-command', which is not what a letter runs in
normal state.  Deriving the mode from evil's state has no such hole."
  :tags '(evil)
  (skip-unless (require 'evil nil t))
  (require 'cooked-evil)
  (evil-mode 1)
  (cooked-tests--with-echoing-child ""
    (evil-normal-state)
    (should (cooked--suspended-p))
    (evil-insert-state)
    (should (eq cooked--input-mode 'semi))
    (should-not (cooked--suspended-p))
    (should (eq (current-local-map) cooked-semi-map))
    (should-not buffer-read-only)))

(ert-deftest cooked-frozen-render-resumes-when-the-user-looks-away ()
  "Holding a picture still is worth something only while someone is looking at
it.  A terminal that stayed stopped because its window lost selection is the
complaint the whole distinction exists to answer."
  (cooked-tests--with-echoing-child ""
    (call-interactively #'cooked-toggle-peek)
    (should (cooked--frozen-p))
    (setq cooked--attention 'away)
    (should-not (cooked--frozen-p))
    (should (eq cooked--input-mode 'frozen))
    (cooked--send-to-child "away")
    (should (cooked-tests--settle
             (lambda () (string-search "away" (cooked-tests--text)))))))

(ert-deftest cooked-typing-while-peeking-resumes-forwarding-and-sends-the-key ()
  "Typing during peek can only mean the child is wanted back: it ends peek and
forwards the character that was pressed, rather than silently self-inserting
into a frozen buffer that goes nowhere."
  (cooked-tests--with-echoing-child ""
    (switch-to-buffer (current-buffer))
    (call-interactively #'cooked-toggle-peek)
    (should (cooked--suspended-p))
    (cooked-tests--type "x")
    (should-not (cooked--suspended-p))
    (should (eq (current-local-map) (cooked--forwarding-map cooked-raw-map)))
    (should (cooked-tests--settle
             (lambda () (string-search "x" (cooked-tests--text)))))))

(ert-deftest cooked-return-while-peeking-resumes-forwarding-and-sends-cr ()
  "RET means the same thing as typing while peeking: give the child its
keyboard back, and send the key that was pressed."
  (cooked-tests--with-echoing-child ""
    (switch-to-buffer (current-buffer))
    (call-interactively #'cooked-toggle-peek)
    (cooked-tests--type "RET")
    (should-not (cooked--suspended-p))
    (should (cooked-tests--settle
             (lambda () (string-search "^M" (cooked-tests--text)))))))

(ert-deftest cooked-peeking-is-read-only-even-at-point-max ()
  "`cooked--protect' deliberately leaves `(point-max)' itself open, for a
prompt about to accept typed input -- and peek is exactly the state that lets
point wander there via ordinary navigation with nothing forwarding to stop
it.  `buffer-read-only' during peek is what closes that gap for anything
other than the typing/RET case `cooked-peek-map' already handles specially."
  (cooked-tests--with-echoing-child ""
    (call-interactively #'cooked-toggle-peek)
    (goto-char (point-max))
    (cooked-tests--with-kill "oops"
      (should-error (call-interactively #'yank) :type 'buffer-read-only))
    (should (cooked--suspended-p))))

(ert-deftest cooked-actions-that-write-bytes-end-peek-first ()
  "Sending anything to the child while peeking would otherwise be invisible
until a separate step lifted the freeze; ending peek first is what lets the
result land where it can be seen."
  (cooked-tests--with-echoing-child ""
    (dolist (act (list (lambda () (cooked-send-eof))
                        (lambda () (cooked-tests--with-kill "x" (cooked-paste)))
                        (lambda () (cooked-send-string "x"))
                        (lambda ()
                          (cl-letf (((symbol-function 'read-key) (lambda (&rest _) ?x)))
                            (call-interactively #'cooked-send-literal-key)))))
      (call-interactively #'cooked-toggle-peek)
      (should (cooked--suspended-p))
      (funcall act)
      (should-not (cooked--suspended-p)))))

(ert-deftest cooked-suspend-ends-peek-first ()
  (cooked-tests--with-echoing-child ""
    (call-interactively #'cooked-toggle-peek)
    (should (cooked--suspended-p))
    (cooked-suspend)
    (should-not (cooked--suspended-p))))

(ert-deftest cooked-interrupt-ends-peek-first ()
  (cooked-tests--with-echoing-child ""
    (call-interactively #'cooked-toggle-peek)
    (should (cooked--suspended-p))
    (cooked-interrupt)
    (should-not (cooked--suspended-p))))

(defun cooked-tests--stopped-p (pid)
  "Whether PID is a stopped job -- `T' in the state `ps' reports for it."
  (string-prefix-p "T" (string-trim
                        (shell-command-to-string (format "ps -o stat= -p %s" pid)))))

(defun cooked-tests--foreground-job ()
  "The foreground pid once it is something other than the shell itself."
  (let ((shell (cooked--pid cooked--session)))
    (cooked-tests--settle
     (lambda () (let ((fg (cooked--foreground-pid cooked--session)))
                  (and fg (not (equal fg shell)))))
     6)
    (cooked--foreground-pid cooked--session)))

(ert-deftest cooked-suspend-stops-the-job-with-isig-on ()
  "The ordinary path: the tty still acts on its `susp' character, so writing
that byte is the whole of it and the line discipline does the rest."
  :tags '(zsh)
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-zsh
    (cooked--send cooked--session "sleep 60\r")
    (let ((job (cooked-tests--foreground-job)))
      (should job)
      (should-not (cooked-tests--stopped-p job))
      (cooked-suspend)
      (should (cooked-tests--settle (lambda () (cooked-tests--stopped-p job)) 4)))))

(ert-deftest cooked-suspend-stops-the-job-with-isig-off ()
  "Regression: \\[cooked-suspend] did nothing at all on macOS to a program that
had cleared ISIG.

With ISIG off there is no byte to write -- the line discipline would hand it
straight to the child instead of raising anything -- so `cooked--send-job-control'
falls back on the signal itself.  That signal was spelled 20, which is SIGTSTP
on Linux and SIGCHLD on the BSDs, and SIGCHLD is ignored by default: the job
carried on and the keystroke looked broken.  The number is the core's to pick
now; this side names it.

`stty raw -isig' is the smallest thing that reproduces it, and it is exactly
what a full-screen program does when it wants ^Z as a byte of its own."
  :tags '(zsh)
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-zsh
    (cooked--send cooked--session "sh -c 'stty raw -isig; sleep 60'\r")
    (let ((job (cooked-tests--foreground-job)))
      (should job)
      (should (cooked-tests--settle
               (lambda () (not (plist-get (cooked--job-control cooked--session) :isig)))
               4))
      (should-not (cooked-tests--stopped-p job))
      (cooked-suspend)
      (should (cooked-tests--settle (lambda () (cooked-tests--stopped-p job)) 4)))))

(ert-deftest cooked-mode-line-names-the-input-mode ()
  "Stepping out used to have no mode-line indicator at all, which made it easy
to forget you had done it and wonder why keys had stopped reaching the child.
Now that stepping out has degrees, the indicator has to say which one: a
deferred render and a live one that simply is not being followed are very
different things to be looking at."
  (cooked-tests--with-echoing-child ""
    (should-not (string-search "frozen" (cooked--mode-line)))
    (call-interactively #'cooked-toggle-peek)
    (should (string-search "frozen" (cooked--mode-line)))
    (call-interactively #'cooked-toggle-peek)
    (should-not (string-search "frozen" (cooked--mode-line)))
    (dolist (case '((still . " still") (semi . " semi") (nil . nil)))
      (let ((cooked--input-mode (car case)))
        (if (cdr case)
            (should (string-search (cdr case) (cooked--mode-line)))
          (should-not (string-match-p "still\\|semi\\|frozen" (cooked--mode-line))))))))

(ert-deftest cooked-mode-line-names-the-program-without-shell-integration ()
  "The `bare' session is exactly where naming the program matters most.

A title is the shell's own summary and needs the snippet loaded; the foreground
process group needs nothing at all.  So the fallback is what tells `htop' from a
shell editing its own line -- the pair the state word alone has never been able
to separate, and the one this whole indicator is judged on."
  (with-temp-buffer
    (setq-local cooked--mode 'raw
                cooked--alt nil
                cooked--semantic nil
                cooked--semantic-seen nil
                cooked--host nil
                cooked--line-record nil
                cooked--exit nil
                cooked-title nil
                cooked--foreground-label "htop")
    (should (equal (substring-no-properties (cooked--mode-line)) " raw htop"))
    ;; A title outranks it: the shell knows the arguments, `comm\= knows a name.
    (setq-local cooked-title "make -j8 world")
    (should (equal (substring-no-properties (cooked--mode-line))
                   " raw make -j8 world"))
    ;; Never both -- two accounts of one thing, and only room for the better.
    (should-not (string-search "htop" (cooked--mode-line)))
    ;; And no title at all when the buffer is already named after it.
    (let ((cooked-buffer-name-auto-update t)
          (cooked-buffer-name "*cooked: %t*"))
      (should (equal (substring-no-properties (cooked--mode-line)) " raw htop")))
    ;; But turning auto-update on buys nothing if the template never shows the
    ;; title -- suppressing it here would just lose it from both places.
    (let ((cooked-buffer-name-auto-update t)
          (cooked-buffer-name "*cooked: %p*"))
      (should (equal (substring-no-properties (cooked--mode-line))
                     " raw make -j8 world")))))

(ert-deftest cooked-mode-line-names-a-job-but-not-the-shell-itself ()
  "The suppression is keyed on which process, not on which policy.

`tcgetpgrp' answers with a process *group*, and an interactive shell doing job
control puts each job in one of its own -- so the shell at its prompt is its own
foreground group and every command it runs is not.  That is the whole test: `zsh'
in the mode line for the life of every session is a word always true and never
news, while the job's name is the only thing on screen saying what the line
being typed will be read by.

`sleep' rather than a full-screen program on purpose.  It leaves the tty
canonical, so cooked reads it as `edit' -- correctly, it is a line being edited
-- and that is exactly the case the state word alone cannot distinguish from a
shell prompt."
  :tags '(zsh)
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-zsh
    (cooked--refresh-keymap)
    ;; Assertions on the segments rather than the whole indicator: whether the
    ;; input mode contributes a `semi\=' tag is evil\='s business and orthogonal
    ;; to this, and a suite that has loaded evil must not fail this test.
    (should-not cooked--foreground-label)
    (should (string-prefix-p " edit" (substring-no-properties (cooked--mode-line))))
    (should-not (string-search "zsh" (cooked--mode-line)))
    (goto-char cooked--input-end)
    (insert "sleep 20")
    (cooked-send-input)
    (should (cooked-tests--settle (lambda () cooked--foreground-label)))
    (cooked--refresh-keymap)
    (should (equal cooked--foreground-label "sleep"))
    (should (string-search "sleep" (cooked--mode-line)))))

(ert-deftest cooked-mode-line-asks-the-os-nothing ()
  "`cooked--mode-line' runs from an `:eval' on every redisplay, so it must be a
pure function of buffer-locals.  The foreground program is the one fact in it
that has to come from outside, and it is cached for exactly that reason -- a
`tcgetpgrp' and a `process-attributes' per frame to render one word is a cost
nobody asked for, and easy to reintroduce by inlining the obvious call."
  (with-temp-buffer
    (setq-local cooked--mode 'raw
                cooked--alt nil
                cooked--semantic nil
                cooked--semantic-seen nil
                cooked--host nil
                cooked--line-record nil
                cooked--exit nil
                cooked-title nil
                cooked--foreground-label "htop")
    (cl-letf (((symbol-function 'process-attributes)
               (lambda (&rest _) (ert-fail "mode line called process-attributes")))
              ((symbol-function 'cooked--foreground-pid)
               (lambda (&rest _) (ert-fail "mode line called cooked--foreground-pid"))))
      (should (equal (substring-no-properties (cooked--mode-line)) " raw htop")))))

(ert-deftest cooked-mode-line-stops-describing-a-dead-session ()
  "Buffer-locals do not decay.  A child that exited ten minutes ago leaves
`cooked--mode', `cooked--semantic' and the rest holding whatever they last
said, so an indicator that keeps reading them is not showing stale information
-- it is showing wrong information in the same clothes as the live kind.  The
exit status is the only thing about a dead session still true."
  (with-temp-buffer
    (setq-local cooked--mode 'raw
                cooked--alt nil
                cooked--semantic nil
                cooked--semantic-seen nil
                cooked--host nil
                cooked--line-record nil
                cooked-title nil
                cooked--foreground-label "htop"
                cooked--input-mode 'frozen
                cooked--exit 0)
    (should (equal (substring-no-properties (cooked--mode-line)) " exited 0"))
    (setq-local cooked--exit 130)
    (should (equal (substring-no-properties (cooked--mode-line)) " exited 130"))
    ;; None of the live vocabulary survives, including the freeze -- there is
    ;; nothing left to keep keys from and nothing left to defer.
    (should-not (string-match-p "raw\\|htop\\|frozen" (cooked--mode-line)))))

(ert-deftest cooked-evil-visual-state-freezes-the-render ()
  "A selection is a claim about a region of text, and text rewritten
underneath it makes the claim a lie -- so visual state defers the render where
normal state does not."
  :tags '(evil)
  (skip-unless (require 'evil nil t))
  (require 'cooked-evil)
  (evil-mode 1)
  (cooked-tests--with-echoing-child ""
    (evil-visual-state)
    (should (eq cooked--input-mode 'frozen))
    (should (cooked--frozen-p))
    (cooked--send-to-child "frozen")
    (cooked-tests--pump 0.3)
    (should-not (string-search "frozen" (cooked-tests--text)))
    ;; Motions and operators are not `self-insert-command' or RET, so
    ;; navigating and selecting must not be mistaken for wanting to type.
    (ignore-errors (evil-next-line))
    (should (cooked--suspended-p))
    (evil-normal-state)
    (should (cooked--suspended-p))
    ;; ...and the freeze it leaves behind catches up the moment it lifts.
    (should (cooked-tests--settle
             (lambda () (string-search "frozen" (cooked-tests--text)))))))

(ert-deftest cooked-evil-visual-state-freezes-a-canonical-child-too ()
  "The other half of the reported bug.  The freeze used to be reachable only
while the child owned the keyboard, so a program repainting a tty it never took
out of canonical mode could rewrite the screen under a selection that existed to
hold it still.

The keyboard half of `frozen' does not come with it: Emacs owns the line here,
so the buffer stays writable and `cooked-input-map' stays installed.  Making the
buffer read-only, or handing it `cooked-peek-map' whose `self-insert' remap
sends raw bytes past cooked's line editor, would break the very prompt the user
is typing at."
  :tags '(evil)
  (skip-unless (require 'evil nil t))
  (require 'cooked-evil)
  (evil-mode 1)
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle
             (lambda () (and (cooked--input-state-p) (cooked--input-start-position)))))
    (evil-visual-state)
    (should (eq cooked--input-mode 'frozen))
    (should (cooked--frozen-p))
    (should-not (cooked--suspended-p))
    (should-not buffer-read-only)
    (should (eq (current-local-map) cooked-input-map))
    ;; `cooked-tests--pump' rather than `cooked-tests--settle', which would force
    ;; the very drain this asserts is being deferred.
    (cooked--send-to-child "frozen\n")
    (cooked-tests--pump 0.3)
    (should-not (string-search "frozen" (cooked-tests--text)))
    ;; And it catches up the moment the selection is gone.
    (evil-insert-state)
    (should (cooked-tests--settle
             (lambda () (string-search "frozen" (cooked-tests--text)))))))

(ert-deftest cooked-evil-replace-state-forwards-like-insert-state ()
  "Evil's replace state overtypes rather than self-inserting in the usual
buffers, so it is worth checking explicitly rather than assuming insert
state's handling covers it."
  :tags '(evil)
  (skip-unless (require 'evil nil t))
  (require 'cooked-evil)
  (evil-mode 1)
  (cooked-tests--with-echoing-child ""
    (switch-to-buffer (current-buffer))
    (evil-normal-state)
    (should (cooked--suspended-p))
    (evil-replace-state)
    (should-not (cooked--suspended-p))
    (cooked-tests--type "x")
    (should (cooked-tests--settle
             (lambda () (string-search "x" (cooked-tests--text)))))))

(ert-deftest cooked-paste-brackets-when-the-child-asked-for-it ()
  "A child that turned bracketed paste on is told where the paste begins and
ends, so its line editor takes the whole thing as one insertion."
  (cooked-tests--with-echoing-child "printf '\\033[?2004h'; "
    (should (cooked--bracketed-paste-p cooked--session))
    (cooked-tests--with-kill "hello" (cooked-paste))
    (should (cooked-tests--settle
             (lambda ()
               (string-search "^[[200~hello^[[201~" (cooked-tests--text)))))))

(ert-deftest cooked-paste-sends-plain-text-when-it-did-not ()
  (cooked-tests--with-echoing-child ""
    (should-not (cooked--bracketed-paste-p cooked--session))
    (cooked-tests--with-kill "hello" (cooked-paste))
    (should (cooked-tests--settle
             (lambda () (string-search "hello" (cooked-tests--text)))))))

(ert-deftest cooked-submitted-input-cannot-close-its-own-bracket ()
  "A multi-line submission is bracketed too, and gets the same guard.

The submission path spelled the wrapping out for itself instead of going through
`cooked--bracketed-paste', and so never stripped the end marker.  Reaching it
takes nothing exotic: the text is whatever sits in the input region, and a paste
into that region carries whatever was on the kill ring.  Left unstripped, the
bracket closed early and the shell took the rest as keystrokes -- which is the
bug `cooked-paste-cannot-be-made-to-close-its-own-bracket' already rules out for
the other path."
  (cooked-tests--with-echoing-child "printf '\\033[?2004h'; "
    (should (cooked--bracketed-paste-p cooked--session))
    (cooked--send-input-string "a\n\e[201~; rm -rf /")
    (should (cooked-tests--settle
             (lambda () (string-search "; rm -rf /^[[201~" (cooked-tests--text)))))
    (should (string-search "^[[200~a" (cooked-tests--text)))
    (should-not (string-search "^[[201~; rm" (cooked-tests--text)))))

(ert-deftest cooked-paste-cannot-be-made-to-close-its-own-bracket ()
  "An end marker inside the pasted text would close the bracket early and hand
what followed to the child as if it had been typed — how a copied line runs
something nobody read.  It cannot survive.

Two guards now stand between the marker and the child and the outer one fires
first: `cooked--strip-paste-controls' turns the ESC into a space, so what the
child sees is the harmless remains of the sequence rather than nothing at all.
`cooked--bracketed-paste' would still drop a marker that reached it, which is
what the assertion below is about — no second `^[[201~' before cooked's own."
  (cooked-tests--with-echoing-child "printf '\\033[?2004h'; "
    (cooked-tests--with-kill "a\e[201~; rm -rf /" (cooked-paste))
    (should (cooked-tests--settle
             (lambda ()
               (string-search "^[[200~a [201~; rm -rf /^[[201~"
                              (cooked-tests--text)))))
    (should-not (string-search "^[[201~; rm" (cooked-tests--text)))))

(ert-deftest cooked-paste-strips-the-control-bytes-xterm-strips ()
  "Every byte on xterm's list becomes a space; tab, newline and CR do not.

The list is xterm's `disallowedPasteControls' default -- NUL BS ENQ EOT ESC
DEL, plus the tty driver's own special characters -- and this pins it as a
list rather than as one example of it, because the whole point is that no
member of it reaches the child.  Tab, LF and CR are on the other side of the
line on purpose: a paste is expected to carry lines and indentation, and the
newline hazard is answered by confirming rather than by mangling."
  (let ((strip "\000\010\005\004\033\177\003\034\025\032\027\026\022\017\021\023"))
    (should (equal (cooked--strip-paste-controls strip)
                   (make-string (length strip) ?\s)))
    (should (equal (cooked--strip-paste-controls "a\tb\nc\rd") "a\tb\nc\rd"))
    ;; Replaced rather than dropped, so the length is a tell that something
    ;; was in the text at all.
    (should (equal (cooked--strip-paste-controls "rm\033x\003y") "rm x y"))))

(ert-deftest cooked-paste-does-not-hand-the-child-an-escape-or-an-interrupt ()
  "A pasted ESC or C-c must not reach a child that did not ask for bracketing.

`cat -v' spells both out, so their absence from the buffer is the assertion:
what arrives is spaces where they were.  Unbracketed is the dangerous case --
the child is reading the paste as if it were typing, and an ESC in a copied
line is how a paste turns into key presses nobody read."
  (cooked-tests--with-echoing-child ""
    (should-not (cooked--bracketed-paste-p cooked--session))
    (cooked-tests--with-kill "a\e[Ab\C-cc" (cooked-paste))
    (should (cooked-tests--settle
             (lambda () (string-search "a [Ab c" (cooked-tests--text)))))
    (should-not (string-search "^[" (cooked-tests--text)))
    (should-not (string-search "^C" (cooked-tests--text)))))

(ert-deftest cooked-paste-strips-control-bytes-under-bracketed-paste-too ()
  "Bracketing does not make the bytes safe, so the strip is not conditional.

xterm strips regardless of the mode, and the reason is that the bracket is a
promise to a *cooperating reader*: it says nothing to the tty driver, which
acts on an interrupt byte before any reader sees it, and nothing to a program
that never implemented the protocol but is being pasted into anyway.  The
markers cooked writes itself are of course still there -- they are the only
ESCs in the buffer afterwards."
  (cooked-tests--with-echoing-child "printf '\\033[?2004h'; "
    (should (cooked--bracketed-paste-p cooked--session))
    (cooked-tests--with-kill "a\e[Ab\C-cc" (cooked-paste))
    (should (cooked-tests--settle
             (lambda ()
               (string-search "^[[200~a [Ab c^[[201~" (cooked-tests--text)))))
    (should-not (string-search "^C" (cooked-tests--text)))))

(ert-deftest cooked-paste-confirms-lines-the-child-would-run ()
  "Without bracketed paste an embedded newline is Enter, so a refused
confirmation must send nothing at all."
  (cooked-tests--with-echoing-child ""
    (cooked-tests--with-kill "one\ntwo"
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
        (cooked-paste))
      (cooked-tests--settle (lambda () nil) 0.2)
      (should-not (string-search "one" (cooked-tests--text)))

      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
        (cooked-paste))
      ;; Carriage return, which is what Enter transmits and what `cat -v' shows
      ;; as ^M — the newline was translated rather than sent as a line feed.
      (should (cooked-tests--settle
               (lambda () (string-search "one^Mtwo" (cooked-tests--text))))))))

(ert-deftest cooked-paste-at-a-prompt-yanks-into-the-pending-line ()
  "At a prompt the line is being edited in the buffer, so a paste belongs there
— where it can be corrected before it is submitted — not at the child."
  ;; A prompt of its own, so a redisplay lands and the input markers exist; a
  ;; child that prints nothing never gives Emacs a reason to place them.
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '$ '; cat")
    (should (cooked-tests--settle
             (lambda () (and (cooked--input-state-p) (cooked--input-start-position)))))
    (cooked--refresh-keymap)
    (cooked-tests--with-kill "echo hi" (cooked-paste))
    (should (equal (cooked--pending-input) "echo hi"))))

(ert-deftest cooked-yank-at-a-prompt-cannot-send-the-shell-an-escape ()
  "A control byte yanked into the pending line reaches the child as a space.

At a prompt `cooked-paste' is `yank', so the text sits in the buffer until RET
and the strip that `cooked--send-paste' applies was never on its way.  A kill of
\"a ESC [ A b C-c c\" then reached the shell as an up-arrow and an interrupt.
The child here is `cat -v' on a canonical tty, so an ESC that got through would
be spelled out as ^[ twice, once by the echo and once by cat, and a C-c would
kill it before it printed anything."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '$ '; cat -v")
    (should (cooked-tests--settle
             (lambda () (and (cooked--input-state-p) (cooked--input-start-position)))))
    (cooked--refresh-keymap)
    (cooked-tests--with-kill "a\e[Ab\C-cc" (cooked-paste))
    (should (equal (cooked--pending-input) "a\e[Ab\C-cc"))
    (cooked-send-input)
    (should (cooked-tests--settle
             (lambda () (string-match-p "^a \\[Ab c$" (cooked-tests--text)))))
    (should-not (string-search "^[" (cooked-tests--text)))
    (should-not (string-search "^C" (cooked-tests--text)))))

(ert-deftest cooked-a-typed-escape-at-a-prompt-reaches-the-shell ()
  "Only pasted text is stripped: a yanked ESC goes as a space, a typed one as ESC.

The whole submitted line used to be stripped, so an ESC entered with
\\[quoted-insert] became a space as well, where xterm, kitty, foot and ghostty
filter what was pasted and never what was typed.  A yank now marks what it
inserts.  The mark has to survive a drain, which lifts the line out and puts it
back, and must not spread to the character typed straight after the yank.  The
child is `cat -v' on a canonical tty, so the ESC that got through is spelled ^[
at the end of its line and the one that did not is a space."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '$ '; cat -v")
    (should (cooked-tests--settle
             (lambda () (and (cooked--input-state-p) (cooked--input-start-position)))))
    (cooked--refresh-keymap)
    (cooked-tests--with-kill "a\eb" (cooked-paste))
    (cooked--drain-and-apply)
    (goto-char cooked--input-end)
    (let ((unread-command-events (list ?\e)))
      (call-interactively #'quoted-insert))
    (should (equal (cooked--pending-input) "a\eb\e"))
    (cooked-send-input)
    (should (equal (ring-ref comint-input-ring 0) "a b\e"))
    (should (cooked-tests--settle
             (lambda () (string-match-p "^a b\\^\\[$" (cooked-tests--text)))))
    (should-not (string-search "a^[b" (cooked-tests--text)))))

(ert-deftest cooked-primary-selection-and-text-drops-are-pastes ()
  "The primary selection and a dropped text reach the child as a bracketed paste.

`mouse-yank-primary' and `dnd-insert-text', which every port's text drop ends
in, both inserted straight into the buffer, so while a program owned the
keyboard the text sat in the transcript and the program never saw it.  At a
prompt each joins the pending line, marked as pasted so its control bytes are
stripped on submission."
  (cooked-tests--with-echoing-child "printf '\\033[?2004h'; "
    (should (cooked--bracketed-paste-p cooked--session))
    (set-window-buffer (selected-window) (current-buffer))
    (should (eq (key-binding [remap mouse-yank-primary]) #'cooked-mouse-yank-primary))
    (cl-letf (((symbol-function 'gui-get-primary-selection) (lambda () "a\eprimary")))
      (call-interactively #'cooked-mouse-yank-primary))
    (should (cooked-tests--settle
             (lambda ()
               (string-search "^[[200~a primary^[[201~" (cooked-tests--text)))))
    (should (eq (dnd-insert-text (selected-window) 'copy "a\edropped") 'copy))
    (should (cooked-tests--settle
             (lambda ()
               (string-search "^[[200~a dropped^[[201~" (cooked-tests--text))))))
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '$ '; cat")
    (should (cooked-tests--settle
             (lambda () (and (cooked--input-state-p) (cooked--input-start-position)))))
    (set-window-buffer (selected-window) (current-buffer))
    (cl-letf (((symbol-function 'gui-get-primary-selection) (lambda () "primary ")))
      (call-interactively #'cooked-mouse-yank-primary))
    (dnd-insert-text (selected-window) 'copy "dropped")
    (should (equal (cooked--pending-input) "primary dropped"))
    ;; Every character of it is marked.
    (should-not (text-property-not-all (cooked--input-start-position)
                                       cooked--input-end 'cooked-pasted t))))

(ert-deftest cooked-terminal-frame-paste-goes-to-the-child-bracketed ()
  "An `xterm-paste' event reaches the child, not the buffer, in every state.

On `emacs -nw' the host terminal's paste is decoded into (xterm-paste TEXT),
and its global binding inserts TEXT with `yank' called as a function, which no
remap sees.  The binding has to be found through the state map the buffer is
actually wearing, so it is looked up there rather than on `cooked-mode-map'."
  (cooked-tests--with-echoing-child "printf '\\033[?2004h'; "
    (should (cooked--bracketed-paste-p cooked--session))
    (require 'term/xterm)
    ;; Global first, so the assertion below is about this buffer outranking it.
    (should (eq (lookup-key global-map [xterm-paste]) #'xterm-paste))
    (should (eq (key-binding [xterm-paste]) #'cooked-xterm-paste))
    (let ((kill-ring nil)
          (xterm-store-paste-on-kill-ring t))
      (cooked-xterm-paste '(xterm-paste "a\ehello"))
      (should (equal (car kill-ring) "a\ehello")))
    (should (cooked-tests--settle
             (lambda ()
               (string-search "^[[200~a hello^[[201~" (cooked-tests--text)))))))

(ert-deftest cooked-evil-normal-state-pastes-into-the-child ()
  "`p' is the key a vim user's hand reaches for, and inside a full-screen program
it is the only route to the kill ring: the program's own `p' pastes its own
registers and has never heard of Emacs'."
  :tags '(evil)
  (skip-unless (require 'evil nil t))
  (require 'cooked-evil)
  (evil-mode 1)
  (cooked-tests--with-echoing-child "printf '\\033[?2004h'; "
    ;; What `C-z' out of emacs state gets you, which is when `p' is reachable.
    (evil-normal-state)
    (should (eq (key-binding (kbd "p")) #'cooked-evil-paste))
    (cooked-tests--with-kill "hello"
      (call-interactively (key-binding (kbd "p"))))
    (should (cooked-tests--settle
             (lambda ()
               (string-search "^[[200~hello^[[201~" (cooked-tests--text)))))))

(ert-deftest cooked-evil-normal-state-paste-stays-evils-own-at-a-prompt ()
  "The pending line is ordinary editable text, so `p' keeps evil's semantics
there rather than shipping the kill off to a child that is not reading."
  :tags '(evil)
  (skip-unless (require 'evil nil t))
  (require 'cooked-evil)
  (evil-mode 1)
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '$ '; cat")
    (should (cooked-tests--settle
             (lambda () (and (cooked--input-state-p) (cooked--input-start-position)))))
    (cooked--refresh-keymap)
    (evil-normal-state)
    (cooked-tests--with-kill "echo hi"
      (call-interactively #'cooked-evil-paste))
    (should (equal (cooked--pending-input) "echo hi"))))

(defmacro cooked-tests--with-prompt-input (input &rest body)
  "Run BODY at a live prompt with INPUT typed at it, on screen.

On screen because `execute-kbd-macro' runs commands in the selected window's
buffer, so nothing about a start-of-line binding can be exercised from a buffer
that is displayed nowhere."
  (declare (indent 1))
  `(cooked-tests--with-session '("/bin/sh" "-c" "printf '$ '; cat")
     (should (cooked-tests--settle
              (lambda () (and (cooked--input-state-p)
                              (cooked--input-start-position)))))
     (cooked--refresh-keymap)
     (cooked-tests--display-buffer)
     ;; The suite is one Emacs and the evil tests above leave `evil-mode' on
     ;; globally, so this has to say which state it means.  Emacs state, which
     ;; is what "applies to emacs mode as well" names: normal-state letters are
     ;; motions rather than text, and insert-state \`C-a' is evil's own
     ;; `evil-paste-last-insertion' -- neither is the binding under test.
     (when (bound-and-true-p evil-local-mode) (evil-emacs-state))
     (cooked-tests--type ,input)
     ,@body))

(ert-deftest cooked-beginning-of-line-stops-at-the-command ()
  "Column 0 of the prompt row is inside the prompt, which is read-only: a
motion that lands there has found the start of a line and not the start of
anything that can be typed at."
  (cooked-tests--with-prompt-input "e c h o SPC h i"
    (should (equal (cooked--pending-input) "echo hi"))
    (let ((start (cooked--input-start-position)))
      (should (> start (line-beginning-position)))
      (should (eq (key-binding (kbd "C-a")) #'cooked-beginning-of-line))
      (cooked-tests--type "C-a")
      (should (= (point) start))
      ;; From there the same key goes on to column 0 -- comint's double-tap read
      ;; the other way round, and the whole of what `0' and `gI' keep in evil.
      (cooked-tests--type "C-a")
      (should (bolp))
      (should (< (point) start)))))

(ert-deftest cooked-beginning-of-line-is-stock-off-the-prompt-row ()
  "Only the row the prompt ends on is special.  On the output above it the
command is `move-beginning-of-line\' again, and nothing drags point down to a
prompt that is on another line."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'hello\\n$ '; cat")
    (should (cooked-tests--settle
             (lambda () (and (cooked--input-state-p)
                             (cooked--input-start-position)))))
    (cooked--refresh-keymap)
    (cooked-tests--display-buffer)
    (when (bound-and-true-p evil-local-mode) (evil-emacs-state))
    (goto-char (point-min))
    (end-of-line)
    (should (equal (buffer-substring-no-properties (point-min) (point)) "hello"))
    (should-not (cooked--input-line-start))
    (cooked-tests--type "C-a")
    (should (= (point) (point-min)))))

(ert-deftest cooked-beginning-of-line-honours-its-defcustom ()
  "The knob is read by the command, not by the binding, so turning it off needs
no reload -- and turning it off has to give the stock command back exactly."
  (cooked-tests--with-prompt-input "e c h o"
    (let ((cooked-beginning-of-line-skips-prompt nil))
      (should-not (cooked--input-line-start))
      (cooked-tests--type "C-a")
      (should (bolp)))))

(ert-deftest cooked-evil-caret-goes-to-the-command-not-the-prompt ()
  "\\`^' means the first non-blank of the *command*, so the blank it skips is
one the user typed and not the space after the prompt's `$'."
  :tags '(evil)
  (skip-unless (require 'evil nil t))
  (require 'cooked-evil)
  (evil-mode 1)
  (cooked-tests--with-prompt-input "SPC e c h o"
    (should (equal (cooked--pending-input) " echo"))
    (let ((start (cooked--input-start-position)))
      (evil-normal-state)
      (cooked-tests--type "^")
      (should (= (point) (1+ start)))
      ;; `0' is left stock deliberately: it is the way back to column 0.
      (cooked-tests--type "0")
      (should (bolp)))))

(ert-deftest cooked-evil-caret-composes-with-an-operator ()
  "The reason `^' is an `evil-define-motion' with a type rather than a command
that moves point: without the exclusive range `d^' and `c^' delete nothing, or
the wrong thing."
  :tags '(evil)
  (skip-unless (require 'evil nil t))
  (require 'cooked-evil)
  (evil-mode 1)
  (should (eq (evil-get-command-property 'cooked-evil-first-non-blank :type)
              'exclusive))
  (cooked-tests--with-prompt-input "SPC e c h o"
    (evil-normal-state)
    ;; Point put on the last character rather than left wherever the state
    ;; change dropped it -- normal state adjusts the cursor off the end of a
    ;; line only when it is entered from insert state, and what is being
    ;; asserted here is the operator's range, not that adjustment.
    (goto-char (1- (cdr (cooked--input-region))))
    ;; `d^' takes everything back to the command's start, exclusive of point;
    ;; the leading blank is not part of the command.
    (cooked-tests--type "d ^")
    (should (equal (cooked--pending-input) " o"))))

(ert-deftest cooked-evil-insert-line-enters-insert-at-the-command ()
  "\\`I' computes a position and changes state in one command, so it needs its
own wrapper rather than point put back afterwards."
  :tags '(evil)
  (skip-unless (require 'evil nil t))
  (require 'cooked-evil)
  (evil-mode 1)
  (cooked-tests--with-prompt-input "SPC e c h o"
    (let ((start (cooked--input-start-position)))
      (evil-normal-state)
      (cooked-tests--type "I")
      (should (eq evil-state 'insert))
      (should (= (point) (1+ start)))
      (cooked-tests--type "x")
      (should (equal (cooked--pending-input) " xecho")))))

(ert-deftest cooked-comint-bol-reaches-cookeds-own ()
  "\\`C-c C-a' is inherited live from `comint-mode-map', and comint's
implementation half-works here by coincidence -- `comint-bol' reads input fields
cooked does not set, so only the repeat press reaches the command, and only
because cooked's input mark is the process mark comint asks for."
  (with-temp-buffer
    (cooked-mode)
    (should (eq (key-binding (kbd "C-c C-a")) #'cooked-beginning-of-line))))

(ert-deftest cooked-secret-mode-is-detected-and-prompts ()
  ;; The prompt entering secret mode schedules is not what this is about, and
  ;; a wait that pumps past its debounce would raise it: in batch, a
  ;; `read-passwd' on stdin.  Pushed out past the end of the test instead; the
  ;; session's cleanup cancels it.
  (let ((cooked-secret-debounce 60))
    (cooked-tests--with-session
        '("/bin/sh" "-c"
          "printf 'Password: '; stty -echo; read p; stty echo; \
           if [ \"$p\" = hunter2 ]; then printf '\\nACCEPTED\\n'; else printf '\\nDENIED\\n'; fi; sleep 5")
      (should (cooked-tests--settle (lambda () (eq cooked--mode 'secret))))
      (let ((cooked-password-function (lambda (_prompt) "hunter2")))
        (cooked--prompt-secret (current-buffer)))
      (should (cooked-tests--settle
               (lambda () (string-match-p "ACCEPTED" (cooked-tests--text)))))
      ;; The child received it, but it was never echoed into the buffer.
      (should-not (string-match-p "hunter2" (buffer-substring-no-properties
                                             (point-min) (point-max)))))))

(ert-deftest cooked-a-source-supplied-secret-is-not-cleared-in-place ()
  "The string `cooked-password-function' hands over must come back unharmed.

An auth-source backend caches plaintext by design, and is free to answer a
lookup with the very string sitting in that cache rather than a copy of it.
Zeroing that string does not destroy a secret -- it destroys the cache, in
place, and the next lookup for the same host answers with NULs, which is a
failure the user gets to debug somewhere else entirely.

So the cache here is a real one: the same string object is handed out and then
looked at again afterwards.  Before the split, this test read seven NULs."
  (let* ((cache (list (cons "sudo" (copy-sequence "hunter2"))))
         (cooked-password-function (lambda (_prompt) (cdr (assoc "sudo" cache))))
         ;; Only the direct call below may answer.  The prompt secret mode
         ;; schedules would answer too if a wait pumped past its debounce, and
         ;; could take the child out of secret mode before the wait saw it.
         (cooked-secret-debounce 60))
    (cooked-tests--with-session
        '("/bin/sh" "-c"
          "printf 'Password: '; stty -echo; read p; stty echo; \
           if [ \"$p\" = hunter2 ]; then printf '\\nACCEPTED\\n'; else printf '\\nDENIED\\n'; fi; sleep 5")
      (should (cooked-tests--settle (lambda () (eq cooked--mode 'secret))))
      (cooked--prompt-secret (current-buffer))
      ;; The child really got the password: the copy is what went out, so this
      ;; also rules out the fix having sent the wrong string.
      (should (cooked-tests--settle
               (lambda () (string-match-p "ACCEPTED" (cooked-tests--text)))))
      (should (equal (cdr (assoc "sudo" cache)) "hunter2")))))

(ert-deftest cooked-a-password-source-may-answer-with-auth-sources-secret-function ()
  "auth-source hands out `:secret' as a function, and a source may pass it on.

`copy-sequence' signals on a function, and that used to escape the prompt with
the child still blocked in its read.  The function is called for the string
now.  An answer that is neither is dropped and `read-passwd' asks instead."
  (let ((cooked-secret-debounce 60))
    (cooked-tests--with-session
        '("/bin/sh" "-c"
          "printf 'Password: '; stty -echo; read p; stty echo; \
           if [ \"$p\" = hunter2 ]; then printf '\\nACCEPTED\\n'; else printf '\\nDENIED\\n'; fi; \
           printf 'Again: '; stty -echo; read p; stty echo; printf '\\nGOT %s\\n' \"$p\"; sleep 5")
      (should (cooked-tests--settle (lambda () (eq cooked--mode 'secret))))
      (let ((cooked-password-function
             (lambda (_prompt) (let ((cached "hunter2")) (lambda () cached)))))
        (cooked--prompt-secret (current-buffer)))
      (should (cooked-tests--settle
               (lambda () (string-match-p "ACCEPTED" (cooked-tests--text)))))
      (should (cooked-tests--settle
               (lambda () (and (string-match-p "Again" (cooked-tests--text))
                               (eq cooked--mode 'secret)))))
      (let ((cooked-password-functions (list (lambda (_prompt) 'not-a-password)))
            (asked nil))
        (cl-letf (((symbol-function 'cooked--read-passwd)
                   (lambda (_prompt) (setq asked t) (copy-sequence "typed"))))
          (cooked--prompt-secret (current-buffer)))
        (should asked))
      (should (cooked-tests--settle
               (lambda () (string-match-p "GOT typed" (cooked-tests--text))))))))

(ert-deftest cooked-the-wire-copy-is-cleared-even-when-the-write-throws ()
  "The other half of the split: what cooked allocated is zeroed regardless.

A child that exited between the prompt and the answer makes the PTY write
signal, and the copy is live at that moment, so the clear has to be in an
`unwind-protect' nested inside the one guarding the source string rather than
sequenced after the writes.  Stubbing the write is the only way to see both at
once: the copy handed to it comes back all NULs, and the source string the
password function supplied comes back intact."
  (let* ((source (copy-sequence "hunter2"))
         (wire nil)
         (cooked-password-function (lambda (_prompt) source)))
    (cooked-tests--with-session
        '("/bin/sh" "-c" "printf 'Password: '; stty -echo; sleep 5")
      (should (cooked-tests--settle (lambda () (eq cooked--mode 'secret))))
      (cl-letf (((symbol-function 'cooked--send-to-child)
                 (lambda (text) (setq wire text) (error "The child is gone"))))
        (should-error (cooked--prompt-secret (current-buffer))))
      (should (equal wire (make-string 7 0)))
      (should (equal source "hunter2")))))

(ert-deftest cooked-a-secret-prompt-is-held-back-while-the-user-is-elsewhere ()
  "A password read must not seize the minibuffer of a buffer nobody is in.

`read-passwd' prompts in whatever frame is selected, so a prompt raised for an
off-screen session lands under the cursor wherever the user actually is -- and
the next thing they type there is sent to *this* child with a newline after it.
Late is fine; redirecting live keystrokes is not.

Asserted on whether a read was *raised*, not on `cooked--secret-timer' being
nil: the timer clears itself as it fires, so a scheduled prompt and a withheld
one leave that variable looking identical a moment later.  Answering through
`cooked-password-function' is what makes the difference visible -- and keeps a
regression here a failing assertion rather than a batch Emacs blocked forever
in a `read-passwd' nobody can answer."
  (let ((asked nil))
    (let ((cooked-password-function (lambda (_prompt) (setq asked t) "")))
      (cooked-tests--with-session '("/bin/sh" "-c" "printf 'Password: '; stty -echo; sleep 5")
        (setq cooked--attention 'away)
        (should (cooked-tests--settle (lambda () (eq cooked--mode 'secret))))
        ;; Well past `cooked-secret-debounce', so a scheduled read would have run.
        (cooked-tests--pump 0.3)
        (should-not asked)
        ;; The mode moved and the keymap swapped regardless: only the read is
        ;; withheld, and the child is still blocked waiting for it.
        (should (eq cooked--mode 'secret))
        (should-not cooked--secret-timer)))))

(ert-deftest cooked-a-held-secret-prompt-is-raised-when-attention-returns ()
  "The other half: held is held until the user comes back, not dropped.

Spelled through `cooked--update-attention' rather than by calling
`cooked--resume-secret' directly, because the wiring between them is the part
that can rot -- a resume nothing calls looks exactly like this test passing."
  (let ((answered nil))
    (let ((cooked-password-function (lambda (_prompt) (setq answered t) "hunter2")))
      (cooked-tests--with-session
          '("/bin/sh" "-c" "printf 'Password: '; stty -echo; read p; printf '\\nGOT\\n'; sleep 5")
        (setq cooked--attention 'away)
        (should (cooked-tests--settle (lambda () (eq cooked--mode 'secret))))
        (should-not answered)
        ;; Coming back.  `cooked--update-attention\=' walks live sessions and reads
        ;; the window itself, so the buffer has to actually be in one.
        (set-window-buffer (selected-window) (current-buffer))
        (cooked--update-attention)
        (should (eq cooked--attention 'here))
        (should (cooked-tests--settle (lambda () answered)))
        (should (cooked-tests--settle
                 (lambda () (string-match-p "GOT" (cooked-tests--text)))))))))

(ert-deftest cooked-returning-does-not-disturb-a-secret-read-already-on-screen ()
  "Leaving the buffer with the minibuffer up and coming back must not re-ask.

`cooked--schedule-secret' begins with `cooked--cancel-secret', which bumps the
epoch and dismisses the read on screen -- correct when the child has stopped
asking, and destructive when the user is halfway through answering.  So the
resume path has to decline while a read is in flight, and this pins the guard
rather than the timer it protects."
  ;; Debounce pushed past the end of the test, for the reason
  ;; `cooked-secret-mode-is-detected-and-prompts' gives.
  (let ((cooked-secret-debounce 60))
    (cooked-tests--with-session '("/bin/sh" "-c" "printf 'Password: '; stty -echo; sleep 5")
      (should (cooked-tests--settle (lambda () (eq cooked--mode 'secret))))
      (cooked--cancel-secret)
      ;; Stand in for a live read: `cooked--secret-read' holds the minibuffer for as
      ;; long as `cooked--read-passwd' is inside it.
      (let ((epoch cooked--secret-epoch))
        (setq cooked--secret-read (current-buffer))
        (unwind-protect
            (progn
              (cooked--resume-secret)
              (should-not cooked--secret-timer)
              ;; The epoch is the tell: a resume that went through would have moved
              ;; it, and the read in flight would then refuse to send its answer.
              (should (= epoch cooked--secret-epoch)))
          (setq cooked--secret-read nil))))))

(ert-deftest cooked-a-stale-cooked-mode-cannot-leak-a-typed-secret ()
  "Typing must never insert under a `cooked--mode' the child has moved on from.

The window this closes: a child that turns echo off *without printing anything*
-- `read -s' with no prompt, `stty -echo' -- changes nothing the pty ever
reports, so `cooked--mode' stays `cooked' until the next termios sample.
Emacs still owns the line, and every character of the password the user is
already typing is rendered into the buffer, sent on RET, and left in the
scrollback and the undo history.

Spelled without waiting for a sample, deliberately: the point is the state
between the child's `tcsetattr' and cooked noticing it, so the test puts the
buffer in exactly that state -- a real child really in secret mode, and a
`cooked--mode' that still says otherwise -- and then types one character."
  ;; The poll notices the child's `stty\=' during the pump below and puts up the
  ;; secret prompt for it -- which is the feature working, and in batch is a
  ;; `read-passwd\=' with nobody to answer it.  Answered from here instead; the
  ;; timer fires inside the pump and so inside this binding.
  (let ((cooked-password-function (lambda (_prompt) "")))
    (cooked-tests--with-session '("/bin/sh" "-c" "stty -echo; sleep 5")
      ;; No output, so nothing here can be waited for; the child needs only enough
      ;; time to reach its `stty\='.
      (cooked-tests--pump 0.3)
      ;; The stale state, built rather than waited for -- and built by putting the
      ;; clock back, because the pump above is longer than the poll interval, so
      ;; the timer has already noticed.  Cancelling its prompt is part of the
      ;; reconstruction: the window under test is the one before anything had.
      (setq cooked--mode 'cooked)
      (cooked--cancel-secret)
      (cooked--refresh-keymap)
      (should (cooked--input-state-p))
      (goto-char (point-max))
      (cooked-tests--run-command 'self-insert-command)
      (cooked--cancel-secret)
      (should-not (string-match-p "p" (buffer-substring-no-properties
                                       (point-min) (point-max))))
      ;; And the reason it did not: the sample that refused the insertion also
      ;; updated the mode, so the secret prompt was on its way.
      (should (eq cooked--mode 'secret)))))

(ert-deftest cooked-a-stale-cooked-mode-forwards-rather-than-looping ()
  "The refusal must forward the key and return, not re-dispatch it.

The bug this rules out is not a wrong character but a command loop that never
ends.  An earlier draft pushed the key back onto `unread-command-events' for
Emacs to look up again under the corrected keymap, which is only bounded while
every map that key can reach binds something other than the pusher.  Where the
*policy* moves without the *mode*
moving, `cooked--set-mode' short-circuits, no refresh runs, the key lands in
the same map it came from, and the command re-dispatches itself forever --
taking the editor with it rather than signalling.

So `cooked--guard-insertion' *substitutes* instead: it rewrites `this-command'
to `cooked-send-key' and the loop runs that, once.  Nothing is ever queued and
no key is looked up twice, which is what makes one keystroke cost exactly one
invocation.  Spelled against `raw'
rather than `secret' so that what is asserted is the forwarding itself, with
no password prompt in the way."
  (cooked-tests--with-session '("/bin/sh" "-c" "stty raw -echo; cat -v")
    (should (cooked-tests--settle (lambda () (eq cooked--mode 'raw))))
    ;; Put the clock back, exactly as above.
    (setq cooked--mode 'cooked)
    (cooked--refresh-keymap)
    (should (cooked--input-state-p))
    (goto-char (point-max))
    ;; Returns at all, which is half the assertion: a re-dispatching draft never
    ;; reaches the next line.  The other half is what it ran instead.
    (should (eq (cooked-tests--run-command 'self-insert-command ?z)
                'cooked-send-key))
    ;; And the mode is corrected on the way.
    (should (eq cooked--mode 'raw))
    ;; Forwarded, not inserted: `cat -v' echoes it back, so it arrives as the
    ;; child's own output rather than as text Emacs typed into the buffer.
    (should (cooked-tests--settle
             (lambda () (string-match-p "z" (cooked-tests--text)))))))

(defun cooked-tests--run-command (command &optional event)
  "Run COMMAND the way the command loop would, hooks and all.

`call-interactively\' on its own is not enough for anything guarded from
`pre-command-hook\': the hook is the command loop\'s job, so a test that skips
it exercises the command without the guard that protects it -- and would pass
just as happily with the guard deleted.  Binding `this-command\' and running the
hook by hand is the smallest faithful model, including the part that matters
here, which is that the hook is allowed to substitute `this-command\' and the
loop runs whatever it finds afterwards.  EVENT is the key typed, defaulting to
`?p'; it matters only for the commands that read `last-command-event'."
  (let ((this-command command)
        (last-command-event (or event ?p)))
    (run-hooks 'pre-command-hook)
    (call-interactively this-command)
    this-command))

(ert-deftest cooked-a-stale-cooked-mode-cannot-leak-a-pasted-secret ()
  "Pasting must never insert under a `cooked--mode' the child has moved on from.

The same window `cooked-a-stale-cooked-mode-cannot-leak-a-typed-secret' closes,
reached by the other door and arguably the likelier one: a password manager puts
the secret on the clipboard and the user pastes it at the `sudo' prompt rather
than typing it, so the whole secret lands in the buffer in a single edit rather
than a character at a time.

Both doors are checked here because they are guarded differently.
`cooked-paste' is cooked's own and asks `cooked--input-state-p' for itself,
so all it needed was a current answer; `yank' is a foreign command that would
insert wherever point is, so `cooked--guard-insertion' substitutes the
equivalent that goes through the child.  A fix that covered only one of them
would leave the other open."
  (let ((cooked-password-function (lambda (_prompt) "")))
    (dolist (command '(cooked-paste yank))
      (cooked-tests--with-session '("/bin/sh" "-c" "stty -echo; sleep 5")
        (cooked-tests--pump 0.3)
        (setq cooked--mode 'cooked)
        (cooked--cancel-secret)
        (cooked--refresh-keymap)
        (should (cooked--input-state-p))
        (goto-char (point-max))
        (kill-new "hunter2")
        (cooked-tests--run-command command)
        (cooked--cancel-secret)
        (should-not (string-match-p "hunter2" (cooked-tests--text)))
        (should (eq cooked--mode 'secret))))))

(ert-deftest cooked-a-foreign-inserter-is-substituted-not-refused ()
  "`yank' at a line the child has taken becomes `cooked-paste', not an error.

The substitution is the half of `cooked--guard-insertion' that keeps the user
able to act.  Refusing would be safe and useless: a paste that signals leaves
them to work out that pressing it again would have worked, and a password
manager's clipboard entry is often good for exactly one use.  So the intent
survives the correction -- a paste is still a paste, it just reaches the child
rather than the buffer.

Spelled against `raw' so the assertion is the substitution itself, with no
password prompt in the way."
  (cooked-tests--with-session '("/bin/sh" "-c" "stty raw -echo; cat -v")
    (should (cooked-tests--settle (lambda () (eq cooked--mode 'raw))))
    (setq cooked--mode 'cooked)
    (cooked--refresh-keymap)
    (should (cooked--input-state-p))
    (goto-char (point-max))
    (kill-new "zz")
    (should (eq (cooked-tests--run-command 'yank) 'cooked-paste))
    (should (eq cooked--mode 'raw))
    ;; Reached the child rather than the buffer: `cat -v\=' echoes it back, so it
    ;; arrives as the child\='s own output.
    (should (cooked-tests--settle
             (lambda () (string-match-p "zz" (cooked-tests--text)))))))

(ert-deftest cooked-a-silent-secret-read-is-still-detected ()
  "`read -s' with no prompt at all must still raise the secret prompt.

The feature that a timer is kept for.  A child that turns echo off without
printing anything leaves nothing on the pty to wake the reader, so nothing but
the periodic termios sample can notice it -- there is no output to ride in on
and no keystroke to hang the question off.  `cooked--guard-insertion' covers
the window before the sample lands, but only for a user who types or pastes
into it; it does not replace the sample, and this is the test that says so."
  (let* ((asked nil)
         (cooked-password-function (lambda (prompt) (setq asked prompt) "")))
    (cooked-tests--with-session '("/bin/sh" "-c" "stty -echo; sleep 5")
      ;; No keystroke anywhere in this test: detection has to be proactive.
      (should (cooked-tests--settle (lambda () (eq cooked--mode 'secret))))
      (cooked-tests--pump 0.2)
      (should asked))))

(ert-deftest cooked-secret-prompt-text-is-recovered ()
  ;; Debounce pushed past the end of the test, for the reason
  ;; `cooked-secret-mode-is-detected-and-prompts' gives.
  (let ((cooked-secret-debounce 60))
    (cooked-tests--with-session '("/bin/sh" "-c" "printf 'Enter passphrase: '; stty -echo; sleep 5")
      (should (cooked-tests--settle (lambda () (eq cooked--mode 'secret))))
      (should (equal (cooked--prompt-text cooked--session) "Enter passphrase:")))))

(ert-deftest cooked-wheel-notches-are-reported-as-presses ()
  "Emacs calls a notch a click; encoding that as a release loses the scroll.
Applications discard a release of buttons 64/65, so a wheel report that goes out
as `m' rather than `M' reaches the child and is thrown away."
  (let ((cooked--mouse-state (cooked--mouse-state-make :sgr t)))
    (should (equal (cooked--mouse-report 64 3 5 t) "\e[<64;6;4M")))
  ;; X10 is worse than merely ignored: a release cannot say which way the wheel
  ;; turned, because it reports button 3 for every button.
  (let ((cooked--mouse-state cooked--mouse-state-none))
    (should-not (equal (cooked--mouse-report 64 3 5 t)
                       (cooked--mouse-report 65 3 5 t)))
    (should (equal (cooked--mouse-report 64 3 5 nil)
                   (cooked--mouse-report 65 3 5 nil)))))

(ert-deftest cooked-wheel-reaches-a-child-that-asked-for-the-mouse ()
  "The whole path: alt screen, mouse tracking on, wheel event in, report out."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\033[?1049h\\033[?1000h\\033[?1006h'; stty raw; cat -v")
    (should (cooked-tests--settle
             (lambda () (and cooked--alt
                             (cooked-mouse-state-enabled cooked--mouse-state)))))
    (should (eq (cooked--policy) 'alt))
    ;; The alt map owns the wheel while the child does; otherwise Emacs would
    ;; scroll the buffer out from under a full-screen program.
    (should (eq (current-local-map) (cooked--forwarding-map cooked-alt-map)))
    (should (eq (key-binding (vector 'wheel-up)) #'cooked-mouse-event))
    (should (eq (key-binding (vector 'mouse-5)) #'cooked-mouse-event))
    ;; With no cell under the pointer the notch still goes out, at the cursor,
    ;; rather than falling through to `mwheel-scroll'.
    (cooked-tests--displayed
      (let ((last-input-event (list 'wheel-up (cooked-tests--posn nil) 1)))
        (cooked-mouse-event)))
    ;; Case matters and nothing else here distinguishes press from release:
    ;; `case-fold-search' is t by default, which would let "M" match the "m"
    ;; this test exists to rule out.
    (let ((case-fold-search nil))
      (should (cooked-tests--settle
               (lambda () (string-match-p "\\[<64;[0-9]+;[0-9]+M" (cooked-tests--text)))))
      (should-not (string-match-p "\\[<64;[0-9]+;[0-9]+m" (cooked-tests--text))))))

(ert-deftest cooked-wheel-outranks-a-minor-mode-that-claims-it ()
  "The GUI failure: `pixel-scroll-precision-mode' binds `wheel-up' in a
minor-mode map, which sits above the major mode's local map in Emacs' lookup
order.  A terminal frame never showed this because there the wheel arrives as
`mouse-4', which pixel-scroll does not bind."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\033[?1049h\\033[?1000h\\033[?1006h'; stty raw; cat -v")
    (should (cooked-tests--settle
             (lambda () (and cooked--alt
                             (cooked-mouse-state-enabled cooked--mouse-state)))))
    (should cooked--mouse-grab)
    ;; Stand in for pixel-scroll rather than loading it: what matters is that
    ;; *some* enabled minor mode claims the same event, which is the position in
    ;; the lookup order that beat us.
    (defvar cooked-tests--greedy-mode)
    (let* ((greedy (let ((m (make-sparse-keymap)))
                     (define-key m (vector 'wheel-up) #'ignore)
                     (define-key m (vector 'wheel-down) #'ignore)
                     m))
           (cooked-tests--greedy-mode t)
           (minor-mode-map-alist
            (cons (cons 'cooked-tests--greedy-mode greedy) minor-mode-map-alist)))
      ;; Sanity: the stand-in really does outrank the major mode's local map.
      (should (eq (lookup-key cooked-raw-map (vector 'wheel-up)) #'cooked-mouse-event))
      (should (eq (key-binding (vector 'wheel-up)) #'cooked-mouse-event))
      (should (eq (key-binding (vector 'mouse-4)) #'cooked-mouse-event)))
    ;; And it stands down the moment the child stops asking for the mouse, so a
    ;; plain prompt scrolls the transcript as any buffer would.
    (cooked-tests--mouse)
    (cooked--update-mouse-grab)
    (should-not cooked--mouse-grab)))

(ert-deftest cooked-wandering-off-the-cursor-shows-a-ghost-and-snaps-back ()
  "Emacs motions in alt mode leave the child's cursor where it was.
The ghost marks the way back, the redraw stops yanking point around, and the
next keystroke sent to the child is what takes it."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\033[?1049h'; printf 'alpha\\r\\nbravo\\r\\ncharlie'; \
                        stty raw; cat -v")
    (should (cooked-tests--settle (lambda () cooked--alt)))
    (should (cooked-tests--settle
             (lambda () (string-match-p "charlie" (cooked-tests--text)))))
    ;; Point starts on the child's cursor, so there is nothing to disambiguate.
    (should (cooked--at-child-cursor-p))
    (cooked--track-wandering)
    (should-not cooked--wandered)
    (should-not cooked--ghost-cursor)

    ;; Wander, as an evil motion would.
    (goto-char (point-min))
    (cooked--track-wandering)
    (should cooked--wandered)
    (should cooked--ghost-cursor)
    ;; The ghost marks the child's cursor, not point.
    (should (= (overlay-start cooked--ghost-cursor) (cooked--cursor-position)))
    (should-not (= (point) (cooked--cursor-position)))

    ;; A redraw must leave a wandered point alone rather than following the cursor.
    (let ((cell (cooked--screen-cell)))
      (cooked--apply (cooked--drain cooked--session))
      (should cooked--wandered)
      (should (equal (cooked--screen-cell) cell)))

    ;; Typing hands the keyboard back, and point goes with it.
    (let ((last-command-event ?x))
      (cooked-send-key))
    (should-not cooked--wandered)
    (should (cooked--at-child-cursor-p))
    (should-not cooked--ghost-cursor)))

(ert-deftest cooked-no-ghost-cursor-at-a-prompt ()
  "Point off the cursor is ordinary editing in the cooked state, not a divergence."
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle (lambda () (eq cooked--mode 'cooked))))
    (should (eq (cooked--policy) 'cooked))
    (goto-char (point-min))
    (cooked--track-wandering)
    (should-not cooked--wandered)
    (should-not cooked--ghost-cursor)))

(ert-deftest cooked-policy-derives-ownership-from-all-three-signals ()
  "The alt screen outranks the line discipline and the OSC 133 prompt state.

The `seen' column is not decoration.  A session that has never had a mark is a
different situation from one that is merely between them, and the indicator says
so: everything else here can be inferred afresh each prompt, but \"this host has
no integration at all\" only exists as a latch."
  (with-temp-buffer
    (pcase-dolist (`(,mode ,alt ,semantic ,seen ,policy ,owns ,indicator)
                   ;; mode      alt  semantic  seen  policy   owns  mode line
                   '((cooked    nil  nil       nil   cooked   t     " edit bare")
                     (cooked    nil  output    t     cooked   t     " edit")
                     ;; No `bare\=' beside `raw\=': that word is reached only
                     ;; through the fallback, which is this same condition.
                     (raw       nil  nil       nil   raw      nil   " raw")
                     ;; A mark has arrived and this is not a prompt, so the shell
                     ;; is running something and said so: `command', not a guess.
                     (raw       nil  output    t     command  nil   " run")
                     ;; A shell prompt: termios says raw, OSC 133 says otherwise.
                     (raw       nil  input     t     cooked   t     " edit")
                     (secret    nil  nil       nil   raw      nil   " secret bare")
                     ;; The case that used to strand the keyboard in Emacs: a
                     ;; full-screen program starting straight from a prompt.
                     (raw       t    input     t     alt      nil   " alt")
                     (cooked    t    input     t     alt      nil   " alt")
                     (raw       t    nil       nil   alt      nil   " alt bare")))
      (setq-local cooked--mode mode
                  cooked--alt alt
                  cooked--semantic semantic
                  cooked--semantic-seen seen
                  cooked--host nil
                  cooked--line-record nil
                  cooked-title nil
                  cooked--foreground-label nil
                  cooked--exit nil)
      (should (eq (cooked--policy) policy))
      (should (eq (and (cooked--input-state-p) t) owns))
      (should (equal (substring-no-properties (cooked--mode-line)) indicator)))))

(ert-deftest cooked-a-mark-alone-does-not-buy-the-keyboard ()
  "A `133;B' is a claim, and claims cross an ssh as easily as facts do.

The local case is unchanged and must stay that way: the child is ours, so the
mark is corroborated by the pty it arrived on and Emacs keeps the line.  What
changes is the far end -- a bare shell there announces nothing, and handing
Emacs a line editor it cannot see is how keystrokes get eaten and how a
completion table ends up offering local paths for a remote filesystem.

The announcement buys it back, deliberately.  Decay keys on what corroborates
the claim, not on the transport: a remote host running the full snippet reaches
the same certainty a local one does, by the same bytes."
  (with-temp-buffer
    (setq-local cooked--mode 'raw
                cooked--alt nil
                cooked--semantic 'input
                cooked--semantic-seen t
                cooked--host nil
                cooked--line-record nil
                cooked-title nil
                cooked--foreground-label nil
                cooked--exit nil)
    ;; Local: the child is ours, and nothing about this changes.
    (should (eq (cooked--policy) 'cooked))
    (should (cooked--input-state-p))
    ;; A local session spends no columns saying it is local.
    (should (equal (substring-no-properties (cooked--mode-line)) " edit"))
    ;; Behind an ssh, with only the core marks.
    (setq-local cooked--host "other.example")
    (should (eq (cooked--policy) 'prompt))
    (should-not (cooked--input-state-p))
    (should (cooked--child-owns-keyboard-p))
    ;; And it says so, both halves: which host, and that the shell has its own
    ;; line.  This used to read `raw\=', which is what made a remote session
    ;; look like cooked misbehaving rather than like a shell doing its job.
    (should (equal (substring-no-properties (cooked--mode-line)) " @other prompt"))
    ;; And it keeps nothing back, for the reason `command' does not: the shell
    ;; said where it was, and a shell at its own prompt wants every key.
    (should (eq (cooked--state-keymap nil 'prompt) cooked-command-map))
    ;; The same remote host, running the full snippet.
    (setf (cooked-line-completion-nonce (cooked--line)) "1234")
    (should (eq (cooked--policy) 'cooked))
    (should (cooked--input-state-p))
    ;; The host stays named -- it is still not this machine, and that is what
    ;; every path in the buffer now means -- but the state word moves.
    (should (equal (substring-no-properties (cooked--mode-line)) " @other edit"))))

(ert-deftest cooked-delegation-hands-the-whole-line-to-the-shell ()
  "The line reaches ZLE, the cursor is put back, and Emacs stops owning it.

The whole line goes, not the part before point: sending the prefix alone would
silently drop whatever followed the cursor, and the left-arrows that avoid that
cost one byte each."
  :tags '(zsh)
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-zsh
    (goto-char cooked--input-end)
    (insert "echo hello")
    ;; Point between `hell' and `o', so there is a suffix to preserve.
    (backward-char 1)
    (let (sent)
      (cl-letf (((symbol-function 'cooked--send-to-child)
                 (lambda (bytes) (setq sent bytes))))
        (cooked-delegate-key "\C-r"))
      ;; The full line, then one left-arrow for the one character after point.
      (should (equal sent "echo hello\e[D\C-r")))
    ;; Ownership is gone, and the keys now go where the line did.
    (should (cooked-line-delegated (cooked--line)))
    (should-not (cooked--input-state-p))
    (should (eq (cooked--policy) 'prompt))
    (should (cooked--child-owns-keyboard-p))
    ;; Refusing twice, because the second call has nothing left to hand over.
    (should-error (cooked-delegate-key "\C-r") :type 'user-error)))

(ert-deftest cooked-delegation-strips-control-bytes-from-the-line ()
  "The line handed to the shell is typing, so an ESC yanked into it is a space.

An ESC the user typed into the line is sent as it is, as a terminal would send
it, and so is the key that follows, since sending a key is the point."
  :tags '(zsh)
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-zsh
    (goto-char cooked--input-end)
    (insert "echo " (cooked--mark-pasted "\e[A") "hi\e")
    (let (sent)
      (cl-letf (((symbol-function 'cooked--send-to-child)
                 (lambda (bytes) (setq sent bytes))))
        (cooked-delegate-key "\C-r"))
      (should (equal sent "echo  [Ahi\e\C-r")))))

(ert-deftest cooked-delegation-lasts-exactly-one-line ()
  "Delegation is a one-way door for the rest of the line and no further.
A fresh prompt is a fresh line, and Emacs may have it back."
  :tags '(zsh)
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-zsh
    (goto-char cooked--input-end)
    (insert "true")
    (cl-letf (((symbol-function 'cooked--send-to-child) #'ignore))
      (cooked-delegate-key "\C-r"))
    (should (cooked-line-delegated (cooked--line)))
    (cooked--handle-semantic '(prompt-start (screen 0 . 0)) nil)
    (should-not (cooked-line-delegated (cooked--line)))))

(ert-deftest cooked-delegate-keys-put-back-what-they-replaced ()
  "`TAB' is not delegated by default, and naming it must not be a one-way
change: taking it out again has to leave `completion-at-point' behind rather
than nothing."
  (let ((original cooked-delegate-keys))
    (unwind-protect
        (progn
          (should (eq (lookup-key cooked-input-map (kbd "TAB")) #'completion-at-point))
          (should (eq (lookup-key cooked-input-map (kbd "C-r")) #'cooked-delegate-this-key))
          (customize-set-variable 'cooked-delegate-keys '("TAB"))
          (should (eq (lookup-key cooked-input-map (kbd "TAB")) #'cooked-delegate-this-key))
          (should-not (lookup-key cooked-input-map (kbd "C-r")))
          ;; The parent survives the rebuild, or `C-c' and every mode-map command
          ;; would go with it.
          (should (keymap-parent cooked-input-map)))
      (customize-set-variable 'cooked-delegate-keys original))
    (should (eq (lookup-key cooked-input-map (kbd "TAB")) #'completion-at-point))
    (should (eq (lookup-key cooked-input-map (kbd "C-r")) #'cooked-delegate-this-key))))

(ert-deftest cooked-evil-enter-yields-to-an-open-completion ()
  "Enter belonged to the completion popup while one was showing, and did not.

The override that makes insert-state Enter submit has to sit on an evil
auxiliary keymap to outrank `evil-collection-comint', and evil reaches those
through `emulation-mode-map-alists' -- which Emacs searches *before*
`minor-mode-overriding-map-alist', where `completion-in-region-mode' puts the
UI's keymap.  So corfu's `RET' never saw the key: the popup stayed up and the
half-completed line went to the shell underneath it.

No corfu here on purpose.  What is being pinned is the precedence contract --
an active `completion-in-region-mode' keymap wins Enter -- and every in-buffer
completion UI, the built-in one included, is on the far side of that same test."
  :tags '(evil evil-collection)
  (skip-unless (require 'evil nil t))
  (skip-unless (require 'evil-collection nil t))
  (require 'cooked-evil)
  (evil-mode 1)
  ;; At a prompt, which is the only place an in-buffer completion shows: over a
  ;; child that owns the keyboard, Enter is forwarded ahead of both.
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle (lambda () (eq cooked--mode 'cooked))))
    (let ((map (make-sparse-keymap)))
      ;; Both spellings: a GUI frame's Enter is `<return>', and leaving it out
      ;; here would let the fall-through run past this map to the passthrough one
      ;; and test nothing.
      (define-key map (kbd "RET") #'ignore)
      (define-key map (kbd "<return>") #'ignore)
      (evil-insert-state)
      (should (eq (key-binding (kbd "RET")) #'cooked-send-input))
      ;; Stand a completion up the way `completion-in-region-mode' does.
      (setq-local completion-in-region-mode-predicate (lambda () t))
      (completion-in-region-mode 1)
      (setq-local minor-mode-overriding-map-alist
                  (list (cons 'completion-in-region-mode map)))
      (dolist (key '("RET" "<return>" "C-m"))
        (should (eq (key-binding (kbd key)) #'ignore)))
      ;; And Enter comes back the moment the popup is gone, rather than staying
      ;; surrendered for the rest of the line.
      (completion-in-region-mode -1)
      (should (eq (key-binding (kbd "RET")) #'cooked-send-input)))))

(ert-deftest cooked-comint-commands-are-remapped ()
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle (lambda () (eq cooked--mode 'cooked))))
    ;; evil-collection binds `repl-submit' to `comint-send-input'; the remap is
    ;; what makes that reach us.
    (should (eq (key-binding [remap comint-send-input]) #'cooked-send-input))
    (should (eq (key-binding [remap comint-interrupt-subjob]) #'cooked-interrupt))
    (should (keymap-parent cooked-input-map))))

(ert-deftest cooked-evil-follows-keyboard-ownership ()
  "Evil must not interpret keys a TUI needs.

State syncing lives in `cooked-evil', which is opt-in, so the test has to opt in
the same way a user's configuration does — without it `cooked-state-change-hook'
has no handler and nothing drives evil at all."
  :tags '(evil zsh)
  (skip-unless (and (executable-find "zsh") (require 'evil nil t)))
  (require 'cooked-evil)
  (evil-mode 1)
  (cooked-tests--with-shell ("zsh" :name "*cooked-evil*" :settle (lambda () (eq cooked--semantic 'input)))
    (should (eq (current-local-map) cooked-input-map))
    (should (eq evil-state 'insert))
    ;; RET submits from insert state by falling through to `cooked-input-map'.
    (should (eq (key-binding (kbd "RET")) #'cooked-send-input))
    ;; In normal state RET is evil's own, as in any other buffer: cooked no
    ;; longer installs a state-specific binding for it.
    (evil-normal-state)

    ;; A raw full-screen program takes the keyboard, and evil steps aside.
    ;; The shell restores canonical mode before exec'ing, so this is briefly
    ;; still an input state; wait for the program itself to go raw.
    (cooked--send cooked--session "stty raw -echo; sleep 1; stty sane\r")
    ;; With the shell's integration working this is `command' rather than
    ;; `raw' -- a positive signal, so nothing is held back.
    (should (cooked-tests--settle
             (lambda () (and (eq cooked--semantic 'output)
                             (eq (current-local-map) (cooked--forwarding-map cooked-command-map))))))
    (should (eq evil-state 'emacs))

    ;; ...and hands it back at the next prompt.
    (should (cooked-tests--settle
             (lambda () (and (eq cooked--semantic 'input)
                             (eq (current-local-map) cooked-input-map)))))
    (should (eq evil-state 'insert))))

(ert-deftest cooked-cursor-visibility-follows-the-child ()
  "`stty raw' is load-bearing: a hidden cursor is honoured only while the child
is the one being typed at.  See
`cooked-a-canonical-child-hiding-its-cursor-leaves-emacs-one'."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "stty raw -echo; printf 'x\\033[?25l'; sleep 5")
    (should (cooked-tests--settle (lambda () (null cursor-type))))
    (should-not (cooked-cursor-visible cooked--cursor))))

(ert-deftest cooked-a-canonical-child-hiding-its-cursor-leaves-emacs-one ()
  "The reported bug: `brew upgrade' hides the cursor and repaints progress bars
over a tty it never takes out of canonical mode.  The policy stays `cooked'
throughout, so Emacs owns the line the whole time the child is drawing -- and
honouring the child's `CSI ?25l' there left the command line being typed at with
no cursor at all.  The child has said nothing about Emacs' point; at a prompt
point is the only cursor there is."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'working\\033[?25l'; cat")
    (should (cooked-tests--settle
             (lambda () (and cooked--cursor
                             (not (cooked-cursor-visible cooked--cursor))
                             (cooked--input-state-p)))))
    ;; No suspension anywhere near it -- this is the ordinary prompt state, which
    ;; is exactly why the old gate could not reach it.
    (should-not (cooked--suspended-p))
    (should cursor-type)
    ;; And still one cursor on screen: the ghost belongs to a child that owns the
    ;; keyboard, and at a prompt point being elsewhere is ordinary editing.
    (should-not (cooked--ghost-cursor-visible-p))))

(ert-deftest cooked-a-running-command-may-hide-the-cursor-under-a-canonical-tty ()
  "The other side of `cooked-a-canonical-child-hiding-its-cursor-leaves-emacs-one'.

That fix keyed on `cooked--input-state-p', which answers yes the moment termios
says canonical -- and a command run from a shell that never puts the tty in raw
mode is canonical too.  So a progress bar drawn by a *running* command kept a
cursor Emacs had been told not to draw.  OSC 133 is what tells the two apart:
while a command is running the mark says `output', and there the child's
`CSI ?25l' is about its own picture and is honoured; at the prompt either side
of it the cursor comes back."
  :tags '(zsh)
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-zsh
    (cooked--send-input-string "printf \'GO\\033[?25l\'; sleep 2")
    (should (cooked-tests--settle
             (lambda () (and (eq cooked--semantic 'output)
                             cooked--cursor
                             (not (cooked-cursor-visible cooked--cursor))))
             8))
    ;; Canonical throughout -- this is the case the previous gate answered wrongly.
    (should (cooked--input-state-p))
    (should-not cursor-type)
    ;; And back at the next prompt, without the child saying anything about it.
    (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input)) 8))
    (should cursor-type)))

(ert-deftest cooked-stepping-out-of-a-canonical-command-brings-the-cursor-back ()
  "Stepping out is the escape hatch from the test above: whatever the child
said, a user navigating the buffer needs a cursor.  Gated on
`cooked--input-mode' alone rather than `cooked--suspended-p', which cannot be
true under policy `cooked' at all -- the child repainting a canonical tty
never took the keyboard to be suspended from, which is why
`cooked-toggle-peek' refuses here and `evil' normal state is the door.  Driven
through `cooked-input-mode-functions', the seam evil itself uses."
  :tags '(zsh)
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-zsh
    (cooked--send-input-string "printf \'GO\\033[?25l\'; sleep 3")
    (should (cooked-tests--settle
             (lambda () (and (eq cooked--semantic 'output)
                             cooked--cursor
                             (not (cooked-cursor-visible cooked--cursor))))
             8))
    (should-not cursor-type)
    (let ((cooked-input-mode-functions (list (lambda () 'still))))
      (cooked--refresh-keymap)
      (should (eq cooked--input-mode 'still))
      (should cursor-type))
    (cooked--refresh-keymap)
    (should-not cursor-type)))

(ert-deftest cooked-input-history-recalls-submissions ()
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle
             (lambda () (and (eq cooked--mode 'cooked) (cooked--input-start-position)))))
    (dolist (line '("first" "second"))
      (cooked--replace-input line)
      (cooked-send-input)
      ;; The input region, not the text: a submitted line stays on screen until
      ;; the echo redraws over it, so its text is there the instant Enter is
      ;; pressed and says nothing about whether the child has answered.  The
      ;; region coming back is a drain having been applied.
      (should (cooked-tests--settle
               (lambda () (and (cooked--input-region)
                               (string-match-p line (cooked-tests--text)))))))

    ;; The binding that used to signal "Not at command line".
    (should (eq (key-binding [remap comint-previous-input]) #'cooked-previous-input))

    (cooked-previous-input)
    (should (equal (cooked--pending-input) "second"))
    (cooked-previous-input)
    (should (equal (cooked--pending-input) "first"))
    (cooked-next-input)
    (should (equal (cooked--pending-input) "second"))
    ;; Stepping past the newest entry restores what was being typed.
    (cooked-next-input)
    (should (equal (cooked--pending-input) ""))))

(ert-deftest cooked-submitting-leaves-the-line-on-screen ()
  "Regression: Enter used to blank the line for as long as the round trip took.

The pending input is Emacs\' text, and deleting it on submission emptied the
prompt immediately, while what puts the line back is the child echoing it --
a round trip away, with at least one redisplay in between.  The line vanished
and reappeared.  It stays put now, and the echo redraws that row over the top
of the same characters.  The region goes either way: what has been submitted
is not editable."
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle
             (lambda () (and (eq cooked--mode 'cooked) (cooked--input-start-position)))))
    (cooked--replace-input "echo hi")
    (cooked-send-input)
    ;; No pump: this is the state the user is looking at while the child thinks.
    (should (string-match-p "echo hi" (cooked-tests--text)))
    (should-not (cooked--input-region))
    ;; And the echo lands on top of it rather than beside it.  `cat' says the
    ;; line twice by nature -- the kernel echoes it and the child prints it --
    ;; so what is being ruled out is two copies on one row.
    (should (cooked-tests--settle (lambda () (cooked--input-region))))
    (should (equal (cooked--pending-input) ""))
    (should-not (string-match-p "echo hi.*echo hi" (cooked-tests--text)))))

(ert-deftest cooked-history-lives-in-comints-ring ()
  "The ring is the storage, not a private list kept beside it -- which is what
makes `comint-input-ignoredups', the ring size, and the history isearch
`comint-mode' installs all along apply to cooked too."
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle
             (lambda () (and (eq cooked--mode 'cooked) (cooked--input-start-position)))))
    (should (ring-empty-p comint-input-ring))
    (cooked--replace-input "echo one")
    (cooked-send-input)
    (should (equal (ring-ref comint-input-ring 0) "echo one"))
    ;; Repeats do not stack up.
    (cooked--replace-input "echo one")
    (cooked-send-input)
    (should (= (ring-length comint-input-ring) 1))
    ;; Blank submissions are not history.
    (cooked-send-input)
    (should (= (ring-length comint-input-ring) 1))))

(ert-deftest cooked-history-recall-leaves-the-rendered-rows-alone ()
  "comint's own `comint-goto-input' deletes from the process mark to `point-max',
assuming input is the last thing in the buffer.  cooked has rendered screen rows
below the prompt, so recall has to work between the two ends of the input region
instead -- this is the regression guard for using comint's version by mistake."
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle
             (lambda () (and (eq cooked--mode 'cooked) (cooked--input-start-position)))))
    (cooked--replace-input "echo one")
    (cooked-send-input)
    (should (cooked-tests--settle
             (lambda () (string-match-p "echo one" (cooked-tests--text)))))
    (let ((before (cooked-tests--text)))
      (cooked-previous-input 1)
      (should (equal (cooked--pending-input) "echo one"))
      ;; Everything above the input region is still there.
      (should (string-prefix-p (string-trim-right before)
                               (string-trim-right (cooked-tests--text)))))))

(ert-deftest cooked-history-preserves-work-in-progress ()
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle
             (lambda () (and (eq cooked--mode 'cooked) (cooked--input-start-position)))))
    (cooked--replace-input "remembered")
    (cooked-send-input)
    ;; See `cooked-input-history-recalls-submissions': the region, not the text.
    (should (cooked-tests--settle
             (lambda () (and (cooked--input-region)
                             (string-match-p "remembered" (cooked-tests--text))))))
    (cooked--replace-input "half-typed")
    (cooked-previous-input)
    (should (equal (cooked--pending-input) "remembered"))
    (cooked-next-input)
    (should (equal (cooked--pending-input) "half-typed"))))

(ert-deftest cooked-arrow-keys-follow-application-cursor-mode ()
  "Regression: DECCKM was ignored, so arrows reached full-screen programs in the
CSI encoding while ncurses (via `smkx') expects SS3, and nothing happened."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (setq cooked--app-cursor nil)
    (should (equal (cooked--encode-event 'up) "\e[A"))
    (should (equal (cooked--encode-event 'left) "\e[D"))
    (setq cooked--app-cursor t)
    (should (equal (cooked--encode-event 'up) "\eOA"))
    (should (equal (cooked--encode-event 'left) "\eOD"))
    ;; Keys outside the cursor cluster are unaffected by the mode.
    (should (equal (cooked--encode-event 'next) "\e[6~"))))

(ert-deftest cooked-application-cursor-mode-round-trips ()
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '\\033[?1h'; sleep 5")
    (should (cooked-tests--settle (lambda () cooked--app-cursor)))
    (should (equal (cooked--encode-event 'up) "\eOA"))))

(ert-deftest cooked-mouse-reports-reach-the-child ()
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '\\033[?1000h\\033[?1006h'; exec cat")
    (should (cooked-tests--settle
             (lambda () (cooked-mouse-state-enabled cooked--mouse-state))))
    (should (cooked-mouse-state-sgr cooked--mouse-state))
    (should (equal (cooked--mouse-report 0 4 9 t) "\e[<0;10;5M"))
    (should (equal (cooked--mouse-report 0 4 9 nil) "\e[<0;10;5m"))
    (should (equal (cooked--mouse-report 64 0 0 t) "\e[<64;1;1M"))))

(ert-deftest cooked-mouse-x10-encoding-when-sgr-is-off ()
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '\\033[?1000h'; exec cat")
    (should (cooked-tests--settle
             (lambda () (cooked-mouse-state-enabled cooked--mouse-state))))
    (should-not (cooked-mouse-state-sgr cooked--mouse-state))
    ;; X10 biases coordinates by 32 and is 1-based, so column 0 is ?!.
    (should (equal (cooked--mouse-report 0 0 0 t) "\e[M !!"))
    (should (equal (cooked--mouse-report 0 2 4 t) "\e[M %#"))
    ;; Release is button 3 in X10, which cannot say which button was let go.
    (should (equal (cooked--mouse-report 0 0 0 nil) "\e[M#!!"))))

(ert-deftest cooked-mouse-sgr-pixels-survives-the-ffi ()
  "Mode 1016 reaches Lisp as SGR in pixels, not as a third encoding to guess at."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\033[?1000h\\033[?1006h\\033[?1016h'; exec cat")
    (should (cooked-tests--settle
             (lambda () (cooked-mouse-state-pixels cooked--mouse-state))))
    (should (cooked-mouse-state-sgr cooked--mouse-state))
    (should (cooked-mouse-state-enabled cooked--mouse-state))))

(ert-deftest cooked-mouse-pixel-reports-scale-the-reported-cell ()
  "A pixel report is the cell times the size `CSI 16 t' answers, plus the offset.
Counted from 1 as xterm counts, so the child dividing by that same size lands
back in the cell the pointer was in."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--mouse :enabled t :sgr t :pixels t)
    (setq-local cooked--last-cell '(9 . 20))
    ;; Row 3, column 5, four pixels right and seven down inside it.
    (should (equal (cooked--mouse-report 0 3 5 t '(4 . 7)) "\e[<0;50;68M"))
    (should (equal (cooked--mouse-report 0 3 5 nil '(4 . 7)) "\e[<0;50;68m"))
    (let ((x 50) (y 68))
      (should (= (/ (1- x) 9) 5))
      (should (= (/ (1- y) 20) 3)))
    ;; No offset is a position standing in for the pointer: the cell's corner.
    (should (equal (cooked--mouse-report 64 3 5 t) "\e[<64;46;61M"))
    ;; A glyph taller than the cell must not report into the row below it, and
    ;; an image's ascent can put the pointer above its top.  A wide glyph's
    ;; offset is real, though, and passes through.
    (should (equal (cooked--mouse-report 0 3 5 t '(4 . 25)) "\e[<0;50;80M"))
    (should (equal (cooked--mouse-report 0 3 5 t '(14 . -2)) "\e[<0;60;61M"))
    ;; A terminal frame has no pixels to report; cells counted from 1 are the
    ;; only unit that is not made up.
    (setq-local cooked--last-cell '(nil . nil))
    (should (equal (cooked--mouse-report 0 3 5 t '(4 . 7)) "\e[<0;6;4M"))))

(ert-deftest cooked-mouse-click-reports-its-pixel ()
  "A click in a 1016 child carries where in the cell it landed, end to end."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\033[?1049h\\033[?1000h\\033[?1016h'; \
                        printf 'alpha\\r\\nbravo'; stty raw; cat -v")
    (should (cooked-tests--settle
             (lambda () (and cooked--alt
                             (cooked-mouse-state-pixels cooked--mouse-state)))))
    (should (cooked-tests--settle
             (lambda () (string-match-p "bravo" (cooked-tests--text)))))
    (let* ((pos (save-excursion (goto-char (point-min))
                                (search-forward "bravo") (- (point) 3)))
           (cell (cooked--screen-cell pos))
           (posn (list (selected-window) pos '(0 . 0) 0 nil pos nil nil
                       '(4 . 7) '(9 . 20))))
      (should cell)
      (cooked-tests--displayed
        ;; Batch has no graphical window to measure, so the size a real frame
        ;; would have reported is set by hand, immediately before the click.
        (setq-local cooked--last-cell '(9 . 20))
        (let ((last-input-event (list 'down-mouse-1 posn)))
          (cooked-mouse-event)))
      (let ((case-fold-search nil))
        (should (cooked-tests--settle
                 (lambda ()
                   (string-match-p (format "\\[<0;%d;%dM"
                                           (+ 1 (* 9 (cdr cell)) 4)
                                           (+ 1 (* 20 (car cell)) 7))
                                   (cooked-tests--text)))))))))

(ert-deftest cooked-screen-cell-counts-a-drawn-run-by-its-cells ()
  "A cell after a decoration drawn wider than its cells is still its own column.

`current-column' counts a `display' image as its pixels over the frame's
character width, so once `text-scale-mode' made the cell wider than the frame's
character, the column after a run of box drawing came out too far right, and a
click there was reported to the child in the wrong cell.  A `space' of five
columns over the three cells of `│ │' stands in for the zoomed image, which
batch cannot draw."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\033[?1049h\\033[?1000h│ │x中y'; stty raw; exec sleep 30")
    (should (cooked-tests--settle
             (lambda () (string-match-p "│ │x中y" (cooked-tests--text)))))
    (let* ((run (save-excursion (goto-char (cooked--screen-start-position))
                                (search-forward "│ │") (match-beginning 0)))
           (x (+ run 3)))
      (let ((inhibit-read-only t))
        (put-text-property run x 'display '(space :width 5)))
      (should (equal (cooked--screen-cell x) '(0 . 3)))
      ;; A wide character counts both of its cells.
      (should (equal (cooked--screen-cell (+ x 2)) '(0 . 6)))
      (should (equal (cooked--mouse-cell nil (list x 0)) '(0 . 3))))))

(ert-deftest cooked-a-screen-cell-and-its-position-convert-both-ways ()
  "Going to a cell lands where `cooked--screen-cell' reads that cell back.

A view the user has wandered away from is remembered as a cell and restored
from one after every drain.  The cell is counted in cells and the restore used
to move by characters, so on a row with a wide character it landed further
right each time: column 4 of `日本XYZ' is `X', and four characters along is
`Z'.  The second half of a wide character goes to the character, as the
core's `chars_before' has it, and a box-drawing run counts its cells whatever
it is drawn as."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\033[?1049h日本XYZ\\r\\n│ │x中y─┼─z'; stty raw; exec sleep 30")
    (should (cooked-tests--settle
             (lambda () (string-match-p "│ │x中y─┼─z" (cooked-tests--text)))))
    (let ((inhibit-read-only t)
          (run (save-excursion (goto-char (cooked--screen-start-position))
                               (search-forward "│ │") (match-beginning 0))))
      ;; Drawn wider than its cells, as a zoomed box-drawing image is.
      (put-text-property run (+ run 3) 'display '(space :width 5)))
    ;; Characters before each column from 0 to one past the row, and the column
    ;; each of those positions reads back as.
    (pcase-dolist (`(,row ,chars ,cells)
                   '((0 (0 0 1 1 2 3 4 5 5) (0 0 2 2 4 5 6 7 7))
                     (1 (0 1 2 3 4 4 5 6 7 8 9 10 10)
                        (0 1 2 3 4 4 6 7 8 9 10 11 11))))
      (let ((start (save-excursion (cooked--goto-screen-row row) (point))))
        (dotimes (col (length chars))
          (ert-info ((format "row %d, column %d" row col))
            (cooked--goto-screen-cell (cons row col))
            (should (= (- (point) start) (nth col chars)))
            (should (equal (cooked--screen-cell) (cons row (nth col cells))))
            ;; And a position read as a cell goes back to itself.
            (let ((pos (point)))
              (cooked--goto-screen-cell (cooked--screen-cell))
              (should (= (point) pos)))))))))

(ert-deftest cooked-mouse-is-left-to-emacs-when-unrequested ()
  "A child that never asked for mouse reports must not steal the click."
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle #'cooked--input-start-position))
    ;; The child never enabled reporting, so `cooked-mouse-event' takes the
    ;; fallback branch and the click behaves as it would in any buffer.
    (should-not (cooked-mouse-state-enabled cooked--mouse-state))
    (should (eq (lookup-key cooked-raw-map [mouse-1]) #'cooked-mouse-event))))

(defmacro cooked-tests--displayed (&rest body)
  "Run BODY with the current buffer showing in the selected window.

`cooked-mouse-event' routes an event to the buffer the pointer names, so a test
that hands it a posn has to put the buffer somewhere a pointer could be."
  (declare (indent 0))
  `(save-window-excursion
     (set-window-buffer (selected-window) (current-buffer))
     ,@body))

(defun cooked-tests--posn (pos)
  "A mouse position over buffer POS in the selected window, or over no text.

Synthesised rather than recorded because the whole point of these tests is the
shape of the event: `posn-point' is nil for a click past the last row or on the
fringe, and that nil is the case that used to hand the tail of the child's
gesture back to Emacs."
  (list (selected-window) (or pos 'text) '(0 . 0) 0 nil pos nil nil nil))

(ert-deftest cooked-drag-reports-its-release-where-the-button-came-up ()
  "Emacs does not deliver `mouse-1' when the pointer moved between press and
release -- it delivers `drag-mouse-1', whose interesting end is `event-end'.
Unbound, that fell through to the global `mouse-set-region': the child was left
holding a button forever, and the region it never asked for appeared in one jump."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\033[?1049h\\033[?1000h\\033[?1006h'; \
                        printf 'alpha\\r\\nbravo'; stty raw; cat -v")
    (should (cooked-tests--settle
             (lambda () (and cooked--alt
                             (cooked-mouse-state-enabled cooked--mouse-state)))))
    (should (cooked-tests--settle
             (lambda () (string-match-p "bravo" (cooked-tests--text)))))
    (should (eq (key-binding (vector 'drag-mouse-1)) #'cooked-mouse-event))
    (let* ((from (save-excursion (goto-char (point-min))
                                 (search-forward "alpha") (- (point) 5)))
           (to (save-excursion (goto-char (point-min))
                               (search-forward "bravo") (- (point) 5)))
           (a (cooked--screen-cell from))
           (b (cooked--screen-cell to)))
      (should a)
      (should b)
      (should-not (equal a b))
      ;; 1000 only, so no tracking loop: the press returns and the release
      ;; arrives as an ordinary event, which is the path being tested.
      (cooked-tests--displayed
        (let ((last-input-event (list 'down-mouse-1 (cooked-tests--posn from))))
          (cooked-mouse-event))
        (let ((last-input-event (list 'drag-mouse-1 (cooked-tests--posn from)
                                      (cooked-tests--posn to))))
          (cooked-mouse-event)))
      ;; Case matters: "m" is the release this test exists to demand.
      (let ((case-fold-search nil))
        (should (cooked-tests--settle
                 (lambda ()
                   (string-match-p (format "\\[<0;%d;%dm" (1+ (cdr b)) (1+ (car b)))
                                   (cooked-tests--text)))))
        (should (string-match-p (format "\\[<0;%d;%dM" (1+ (cdr a)) (1+ (car a)))
                                (cooked-tests--text)))))))

(defconst cooked-tests--hover-child
  '("/bin/sh" "-c" "printf '\\033[?1049h\\033[?1003h\\033[?1006h'; \
                    printf 'alpha\\r\\nbravo'; stty raw -echo; cat -v")
  "A child on the alt screen asking for any-motion reports in SGR.

Without the tty's own echo, so that one report is one match in the text.")

(ert-deftest cooked-hover-tracking-follows-the-option-and-the-child ()
  "`track-mouse' is on in a terminal only while the user opted in, the child
asked for 1003 and the child has the mouse -- and off means no local binding at
all, so the global value governs everywhere else."
  (cooked-tests--with-session cooked-tests--hover-child
    (should (cooked-tests--settle
             (lambda () (cooked-mouse-state-motion cooked--mouse-state))))
    (should cooked--mouse-grab)
    (let ((cooked-mouse-hover-motion nil))
      (cooked--update-hover-tracking)
      (should-not (local-variable-p 'track-mouse)))
    (let ((cooked-mouse-hover-motion t))
      (cooked--update-hover-tracking)
      (should (local-variable-p 'track-mouse))
      (should (eq track-mouse t))
      (should-not (default-value 'track-mouse))
      ;; A movement per pixel, not per glyph: a shade run is one stretch glyph,
      ;; and hover across it used to report only the cell it entered.
      (should (local-variable-p 'mouse-fine-grained-tracking))
      (should (eq mouse-fine-grained-tracking t))
      (should-not (default-value 'mouse-fine-grained-tracking))
      ;; The child dropping to 1002 takes hover away with it.
      (cooked--set-mouse-state t t t nil nil)
      (should-not (local-variable-p 'track-mouse))
      (should-not (local-variable-p 'mouse-fine-grained-tracking))
      (cooked--set-mouse-state t t nil t nil)
      (should (eq track-mouse t))
      ;; So does the child losing the mouse, as a peek or a prompt makes it.
      (let ((cooked--mouse-state cooked--mouse-state-none))
        (cooked--update-mouse-grab))
      (should-not (local-variable-p 'track-mouse)))))

(ert-deftest cooked-hover-movements-stay-out-of-evils-own-key-reads ()
  "With `cooked-evil-normal-state-render' nil the child keeps the mouse in normal
state, and hover with it.  evil reads an operator's motion and \\`r''s character
with `read-key-sequence' afresh, where `cooked-mouse-hover' is not what a
movement reaches, so a movement read there used to be taken as the key: \\`r'
then failed for want of a character, and \\`y' followed by \\`w' abandoned the
yank.  A movement nothing is bound to is now deleted from those reads too."
  :tags '(evil)
  (skip-unless (require 'evil nil t))
  (require 'cooked-evil)
  (evil-mode 1)
  (let ((cooked-evil-normal-state-render nil)
        (cooked-mouse-hover-motion t))
    (cooked-tests--with-session cooked-tests--hover-child
      (should (cooked-tests--settle
               (lambda () (and (cooked-mouse-state-motion cooked--mouse-state)
                               (string-match-p "bravo" (cooked-tests--text))))))
      (cooked-tests--display-buffer)
      (unwind-protect
          (let* ((pos (save-excursion (goto-char (point-min))
                                      (search-forward "bravo") (- (point) 3)))
                 (movement (list 'mouse-movement (cooked-tests--posn pos))))
            (evil-normal-state)
            (should cooked--mouse-grab)
            (should (eq track-mouse t))
            (let ((unread-command-events (list movement ?a)))
              (should (eq (evil-read-key) ?a)))
            (goto-char pos)
            (kill-new "before")
            (execute-kbd-macro (vector ?y movement ?w))
            (should (eq evil-state 'normal))
            (should (equal (substring-no-properties (current-kill 0)) "avo")))
        (evil-emacs-state)))))

(ert-deftest cooked-hover-tracking-and-the-pointer-shape-share-one-gate ()
  "The OSC 22 pointer and hover reporting both follow `cooked--mouse-grab', but
only hover stands down while a gesture is being followed: the pointer a child
set over a button stays while that button is dragged."
  (cooked-tests--with-session cooked-tests--hover-child
    (should (cooked-tests--settle
             (lambda () (cooked-mouse-state-motion cooked--mouse-state))))
    (let ((cooked-mouse-hover-motion t)
          (cooked--osc-bell-terminated t))
      (cooked--osc-pointer-shape '("pointer"))
      (cooked--update-mouse-grab)
      (should (eq track-mouse t))
      (should (eq (overlay-get cooked--pointer-overlay 'pointer) 'hand))
      ;; Mid-gesture, a re-gate leaves `track-mouse' to the gesture and still
      ;; answers for the pointer.
      (let ((cooked--mouse-tracking t))
        (cooked--set-mouse-state t t nil nil nil)
        (should (eq track-mouse t))
        (should (eq (overlay-get cooked--pointer-overlay 'pointer) 'hand)))
      ;; Losing the mouse takes both away together.
      (let ((cooked--mouse-state cooked--mouse-state-none))
        (cooked--update-mouse-grab))
      (should-not (local-variable-p 'track-mouse))
      (should-not cooked--pointer-overlay))))

(ert-deftest cooked-hover-reports-once-per-cell-and-keeps-the-region ()
  "A movement with nothing held is button 3 plus the motion bit, 35.  The same
cell twice is one report, and the region a shifted drag left behind survives the
pointer drifting afterwards."
  (cooked-tests--with-session cooked-tests--hover-child
    (should (cooked-tests--settle
             (lambda () (and cooked--alt (cooked-mouse-state-motion cooked--mouse-state)))))
    (should (cooked-tests--settle
             (lambda () (string-match-p "bravo" (cooked-tests--text)))))
    (should (eq (lookup-key cooked--mouse-map [mouse-movement]) #'cooked-mouse-hover))
    (let* ((cooked-mouse-hover-motion t)
           (from (save-excursion (goto-char (point-min))
                                 (search-forward "alpha") (- (point) 5)))
           (to (save-excursion (goto-char (point-min))
                               (search-forward "bravo") (- (point) 5)))
           (a (cooked--screen-cell from))
           (b (cooked--screen-cell to))
           (pattern (lambda (cell)
                      (format "\\[<35;%d;%dM" (1+ (cdr cell)) (1+ (car cell))))))
      (should (and a b (not (equal a b))))
      (cooked-tests--displayed
        (set-mark from)
        (activate-mark)
        (dolist (pos (list from from to))
          (let ((last-input-event (list 'mouse-movement (cooked-tests--posn pos))))
            (cooked-mouse-hover)))
        (should mark-active))
      (should (cooked-tests--settle
               (lambda () (string-match-p (funcall pattern b) (cooked-tests--text)))))
      (let ((text (cooked-tests--text)))
        (should (= 1 (how-many (funcall pattern a) (point-min) (point-max))))
        (should (string-match-p (funcall pattern a) text))))))

(ert-deftest cooked-hover-under-1016-reports-its-pixel ()
  "Hover passes the pointer's place in its glyph on, as a click does, so a child
that asked for pixels is not handed the corner of every cell it hovers over."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\033[?1049h\\033[?1003h\\033[?1016h'; \
                        printf 'alpha\\r\\nbravo'; stty raw -echo; cat -v")
    (should (cooked-tests--settle
             (lambda () (and cooked--alt
                             (cooked-mouse-state-motion cooked--mouse-state)
                             (cooked-mouse-state-pixels cooked--mouse-state)))))
    (should (cooked-tests--settle
             (lambda () (string-match-p "bravo" (cooked-tests--text)))))
    (let* ((cooked-mouse-hover-motion t)
           (pos (save-excursion (goto-char (point-min))
                                (search-forward "bravo") (- (point) 3)))
           (cell (cooked--screen-cell pos))
           (posn (list (selected-window) pos '(0 . 0) 0 nil pos nil nil
                       '(4 . 7) '(9 . 20))))
      (should cell)
      (cooked-tests--displayed
        ;; As in `cooked-mouse-click-reports-its-pixel': batch has no frame to
        ;; measure, so the size a real one would have reported is set by hand.
        (setq-local cooked--last-cell '(9 . 20))
        (let ((last-input-event (list 'mouse-movement posn)))
          (cooked-mouse-hover)))
      (let ((case-fold-search nil))
        (should (cooked-tests--settle
                 (lambda ()
                   (string-match-p (format "\\[<35;%d;%dM"
                                           (+ 1 (* 9 (cdr cell)) 4)
                                           (+ 1 (* 20 (car cell)) 7))
                                   (cooked-tests--text)))))))))

(ert-deftest cooked-hover-is-not-reported-without-the-option ()
  "Some other package leaving `track-mouse' on globally must not deliver hover
to a child the user never opted into."
  (cooked-tests--with-session cooked-tests--hover-child
    (should (cooked-tests--settle
             (lambda () (string-match-p "bravo" (cooked-tests--text)))))
    (let ((cooked-mouse-hover-motion nil)
          (from (save-excursion (goto-char (point-min))
                                (search-forward "alpha") (- (point) 5))))
      (cooked-tests--displayed
        (let ((last-input-event (list 'mouse-movement (cooked-tests--posn from))))
          (cooked-mouse-hover)))
      (should-not cooked--mouse-last-cell))))

(defmacro cooked-tests--with-hover (&rest body)
  "Run BODY in a live terminal reporting hover, with `from' over its text.

The child is `cooked-tests--hover-child', the option is on, `track-mouse' is
on in the buffer as it would be, and the buffer is in the selected window."
  (declare (indent 0))
  `(cooked-tests--with-session cooked-tests--hover-child
     (should (cooked-tests--settle
              (lambda () (and cooked--alt (cooked-mouse-state-motion cooked--mouse-state)))))
     (should (cooked-tests--settle
              (lambda () (string-match-p "bravo" (cooked-tests--text)))))
     (let ((cooked-mouse-hover-motion t)
           (key-translation-map (copy-keymap key-translation-map))
           (from (save-excursion (goto-char (point-min))
                                 (search-forward "alpha") (- (point) 5))))
       (ignore from)
       (cooked--update-mouse-grab)
       (should (eq track-mouse t))
       (cooked-tests--displayed
         ,@body))))

(ert-deftest cooked-hover-does-not-break-a-prefix-key ()
  "A movement is ordinary input to `read-key-sequence', so a pointer twitch
after \\`C-c' made \\`C-c <mouse-movement>', which is undefined, and \\`C-c' was
gone -- the only way back to Emacs from a full-screen program.  The movement is
taken out of the key, and still reported."
  (cooked-tests--with-hover
    (let ((over-text (list 'mouse-movement (cooked-tests--posn from)))
          (over-nothing (list 'mouse-movement (cooked-tests--posn nil))))
      (dolist (movements (list (list over-text) (list over-nothing over-text)))
        (let* ((unread-command-events `(?\C-c ,@movements ?\C-v))
               (keys (read-key-sequence nil)))
          (should (equal (vconcat keys) [?\C-c ?\C-v]))
          (should (eq (key-binding keys) #'cooked-toggle-peek))))
      (should (equal cooked--mouse-last-cell (cooked--screen-cell from))))))

(ert-deftest cooked-hover-is-not-a-command ()
  "Every movement used to be a turn of the command loop.  That spent a
\\[universal-argument] on the movement, ran `tooltip-hide' from
`pre-command-hook' so a link's help vanished on the first glyph crossed, and
counted lines in `post-command-hook'.  A movement that is hover never becomes a
key at all -- and one that some other binding wants still does."
  (cooked-tests--with-hover
    (let ((movement (list 'mouse-movement (cooked-tests--posn from))))
      (let ((unread-command-events (list movement ?\C-c ?\C-v)))
        (should (equal (vconcat (read-key-sequence nil)) [?\C-c ?\C-v])))
      ;; Through the command loop itself: no command ran for the movement.
      (let ((hidden 0)
            (pre-command-hook pre-command-hook))
        (cl-letf (((symbol-function 'tooltip-hide)
                   (lambda (&rest _) (setq hidden (1+ hidden)))))
          (add-hook 'pre-command-hook #'tooltip-hide)
          (execute-kbd-macro (vector movement movement)))
        (should (= hidden 0)))
      ;; A drag in `mouse-drag-region' reads its movements through a map of
      ;; its own, and gets them.
      (let ((overriding-terminal-local-map (make-sparse-keymap))
            (unread-command-events (list movement)))
        (define-key overriding-terminal-local-map [mouse-movement] #'forward-char)
        (should (equal (vconcat (read-key-sequence nil)) (vector movement)))))))

(ert-deftest cooked-hover-repeats-do-not-count-lines ()
  "Emacs sends a movement per pixel over an image, so a pointer crossing a
decorated panel arrives many times in one cell.  The cell is a `count-lines'
away, and a repeat of the glyph just measured does not pay it again."
  (cooked-tests--with-hover
    (let ((movement (list 'mouse-movement (cooked-tests--posn from)))
          (counted 0))
      (cl-letf* ((count (symbol-function 'count-lines))
                 ((symbol-function 'count-lines)
                  (lambda (&rest args)
                    (setq counted (1+ counted))
                    (apply count args))))
        (should (cooked--hover-report (event-start movement)))
        (should (> counted 0))
        (setq counted 0)
        (should (cooked--hover-report (event-start movement)))
        (should (= counted 0))))))

(ert-deftest cooked-literal-key-skips-the-pointer-moving ()
  "`read-key' returns a movement like any key, so with hover on the pointer
drifting while \\`C-c C-q' waited was the key sent, and the real one was lost."
  (cooked-tests--with-hover
    (let ((unread-command-events
           (list (list 'mouse-movement (cooked-tests--posn nil)) ?a))
          sent)
      (cl-letf (((symbol-function 'cooked--send-to-child)
                 (lambda (text) (push text sent))))
        (cooked-send-literal-key))
      (should (equal sent '("a"))))))

(ert-deftest cooked-a-drag-does-not-leave-track-mouse-on-globally ()
  "The `track-mouse' form restores the old value into whichever binding is
current when it exits.  A drain that made the variable buffer-local mid-drag
used to receive that restore, leaving the global value the form had set stuck
at t -- and every buffer generating motion events from then on."
  (cooked-tests--with-session cooked-tests--hover-child
    (should (cooked-tests--settle
             (lambda () (string-match-p "bravo" (cooked-tests--text)))))
    (let ((cooked-mouse-hover-motion t)
          (from (save-excursion (goto-char (point-min))
                                (search-forward "alpha") (- (point) 5))))
      ;; Start from 1002, so there is no local binding when the drag begins.
      (cooked--set-mouse-state t t t nil nil)
      (should-not (local-variable-p 'track-mouse))
      (cooked-tests--displayed
        (let ((unread-command-events
               (list (list 'mouse-movement (cooked-tests--posn from))
                     (list 'mouse-1 (cooked-tests--posn from)))))
          ;; The child asks for 1003 while the pointer is being followed.
          (cl-letf* ((report (symbol-function 'cooked--report-motion))
                     ((symbol-function 'cooked--report-motion)
                      (lambda (&rest args)
                        ;; A drag reads a movement per pixel too, for the shade
                        ;; runs hover needs it for.
                        (should (eq mouse-fine-grained-tracking t))
                        (cooked--set-mouse-state t t t t nil)
                        (apply report args))))
            (cooked--mouse-track (selected-window)))))
      (should-not (default-value 'track-mouse))
      (should-not (default-value 'mouse-fine-grained-tracking))
      (should (local-variable-p 'track-mouse))
      (should (eq track-mouse t)))))

(defmacro cooked-tests--with-two-terminals (a b &rest body)
  "Run BODY with two live cooked buffers bound to A and B, side by side.
A is the selected window's; B is the other's.  Both children take the alt
screen and ask for SGR mouse reporting, and for focus events -- which cost the
tests that do not care about them nothing, since no focus report is sent in
batch unless `frame-focus-state' is stubbed; see
`cooked-a-click-that-focuses-a-terminal-reports-focus-first'."
  (declare (indent 2))
  `(cooked-tests--with-session
       '("/bin/sh" "-c" "printf '\033[?1049h\033[?1000h\033[?1006h\033[?1004h'; \
                         stty raw; cat -v")
     (let ((,a (current-buffer)))
       (cooked-tests--with-session
           '("/bin/sh" "-c" "printf '\033[?1049h\033[?1000h\033[?1006h\033[?1004h'; \
                             stty raw; cat -v")
         (let ((,b (current-buffer)))
           (dolist (buffer (list ,a ,b))
             (with-current-buffer buffer
               (should (cooked-tests--settle
                        (lambda () (and cooked--alt
                                        (cooked-mouse-state-enabled cooked--mouse-state)
                                        (cooked--focus-events-p cooked--session)))))
               (should cooked--mouse-grab)))
           (save-window-excursion
             (set-window-buffer (selected-window) ,a)
             (let ((window (split-window)))
               (set-window-buffer window ,b)
               (select-window (get-buffer-window ,a))
               ,@body)))))))

(defun cooked-tests--other-window-event (window kind pos)
  "A KIND event over buffer position POS in WINDOW.

Synthesised like `cooked-tests--posn', but naming a window the test does not
have selected: what these tests are about is which buffer such an event ends up
being handled in."
  (list kind (list window pos '(0 . 0) 0 nil pos nil nil nil) 1))

(defun cooked-tests--child-heard (buffer)
  "The first mouse report or cursor key BUFFER's child echoed, or nil."
  (with-current-buffer buffer
    (cooked-tests--settle (lambda () nil) 0.3)
    (save-excursion
      (goto-char (point-min))
      (when (re-search-forward "\\[<[0-9;]+[Mm]\\|\\[[AB]" nil t)
        (match-string-no-properties 0)))))

(ert-deftest cooked-a-click-on-another-terminal-focuses-and-reaches-it ()
  "One click on an unfocused terminal both selects it and reaches its child.

Emacs settles a click's bindings in the buffer under the pointer but runs the
command in the buffer that was current all along, so the click on B arrived in
A: A's child was told about a cell A's screen made of a position in B's buffer,
and the click that should have selected B was spent doing it.  Routing the event
to the buffer the pointer names answers both halves -- anything less costs two
clicks to press a button in an unfocused TUI, where one would do in any other
Emacs buffer."
  (cooked-tests--with-two-terminals a b
    (with-current-buffer a
      (execute-kbd-macro
       (vector (cooked-tests--other-window-event window 'down-mouse-1 3)
               (cooked-tests--other-window-event window 'mouse-1 3))))
    (should (eq (window-buffer (selected-window)) b))
    (should-not (cooked-tests--child-heard a))
    ;; The press, and the release that completes it: a child left holding a
    ;; button it never saw go down is the other half of getting this wrong.
    (let ((case-fold-search nil)
          (heard (with-current-buffer b (cooked-tests--text))))
      (should (string-match-p "\\[<0;[0-9]+;[0-9]+M" heard))
      (should (string-match-p "\\[<0;[0-9]+;[0-9]+m" heard)))))

(ert-deftest cooked-a-click-that-focuses-a-terminal-reports-focus-first ()
  "The child is told it gained focus before it is told about the click.

`cooked-mouse-event' selects the window inline and reports the button a few
lines later, but the `CSI I' that says so comes from `cooked--report-focus' on
`window-selection-change-functions' -- which Emacs runs during redisplay, after
the command has returned.  So the child reads the press, and under
`cooked--mouse-track' the whole drag, while still believing it has no keyboard.
Every real terminal focuses before the window manager delivers the click, and a
TUI that re-arms on FocusGained -- nvim's autocmds, tmux's redraw -- acts on the
click in the wrong state.

`frame-focus-state' is nil for a batch frame, so a focus report can never be
observed here without saying the frame has focus; the half under test is the
window selection, which is left real.  The selection hook is run by hand
afterwards because batch never redisplays, and running it after the click is
exactly the ordering being asserted."
  (cooked-tests--with-two-terminals a b
    (cl-letf (((symbol-function 'frame-focus-state) (lambda (&rest _) t)))
      ;; B is unfocused and its child knows: the report saying so went out when
      ;; the split put it there.  Nothing ran it in batch, so say it here.
      (with-current-buffer b (setq-local cooked--focused nil))
      (with-current-buffer a
        (execute-kbd-macro
         (vector (cooked-tests--other-window-event window 'down-mouse-1 3)
                 (cooked-tests--other-window-event window 'mouse-1 3))))
      (should (eq (window-buffer (selected-window)) b))
      (with-current-buffer b
        (run-hook-with-args 'window-selection-change-functions (selected-frame))
        ;; Both reports are on the child's input by now; this waits for the echo
        ;; of whichever came second, and asserts on neither.
        (cooked-tests--settle (lambda () nil) 0.5))
      (let* ((case-fold-search nil)
             (heard (with-current-buffer b (cooked-tests--text)))
             (focus (string-match "\\[I" heard))
             (press (string-match "\\[<0;[0-9]+;[0-9]+M" heard)))
        (should focus)
        (should press)
        (should (< focus press))))))

(ert-deftest cooked-the-wheel-reaches-an-unfocused-terminal ()
  "A notch over an unfocused terminal goes to that terminal's child, and
leaves the focus where it was -- the way scrolling any other Emacs buffer does
not require selecting it first."
  (cooked-tests--with-two-terminals a b
    (with-current-buffer a
      (execute-kbd-macro
       (vector (cooked-tests--other-window-event window 'wheel-down 3))))
    (should (eq (window-buffer (selected-window)) a))
    (should-not (cooked-tests--child-heard a))
    (let ((case-fold-search nil))
      (should (string-match-p "\\[<65;[0-9]+;[0-9]+M"
                              (with-current-buffer b (cooked-tests--text)))))))

(ert-deftest cooked-the-wheel-does-not-scroll-a-screen-there-is-nothing-below ()
  "A notch on an alternate screen the child never asked for the mouse on is
swallowed rather than handed to Emacs.

The buffer is narrowed to the screen the child is drawing, so scrolling can only
move the picture off the window -- and putting it back is `cooked--pin-alt-windows'
undoing, one command later, a scroll the user watched happen.  Claiming the notch
is what stops it happening.  `still' because that is the state the wheel used to
escape through: forwarding is suspended, so `cooked--mouse-grab' is off and the
notch reached `mwheel-scroll'.

The escape hatch is the restriction, not the mode: widening is how the transcript
behind a full-screen program is read, and the second half asserts the wheel comes
straight back when it happens."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "for i in $(seq 40); do printf 'line%s\n' $i; done; \
                        printf '\033[?1049h'; printf 'top\n'; sleep 5")
    (should (cooked-tests--settle (lambda () cooked--alt)))
    (set-window-buffer (selected-window) (current-buffer))
    (setq cooked--input-mode 'still)
    (cooked--update-mouse-grab)
    (should-not cooked--mouse-grab)
    (should cooked--wheel-grab)
    (should (cooked--screen-restricted-p))
    (let ((start (window-start (selected-window)))
          (window (selected-window)))
      (execute-kbd-macro
       (vector (cooked-tests--other-window-event window 'wheel-down (point-min))))
      (should (= (window-start window) start))
      ;; Widened, the buffer has somewhere to scroll to again and the notch is
      ;; Emacs\=' to act on.
      (widen)
      (should-not (cooked--screen-restricted-p)))))

(ert-deftest cooked-a-drag-that-leaves-the-window-releases-where-it-left ()
  "A drag out of the terminal is still the child's drag, and its release is
still owed -- but `event-end' is then a position in somebody else's buffer, and
`cooked--screen-cell' measures whatever number it finds against this buffer's
screen.  So letting go over another window reported the button up at a cell
nobody had dragged to, chosen by how far into the other buffer the pointer
happened to be."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\033[?1049h\033[?1000h\033[?1006h'; \
                        printf 'alpha\r\nbravo'; stty raw; cat -v")
    (should (cooked-tests--settle
             (lambda () (and cooked--alt
                             (cooked-mouse-state-enabled cooked--mouse-state)))))
    (should (cooked-tests--settle
             (lambda () (string-match-p "bravo" (cooked-tests--text)))))
    (let* ((from (save-excursion (goto-char (point-min))
                                 (search-forward "alpha") (- (point) 5)))
           ;; A position in the *other* buffer, chosen to be one this buffer
           ;; would also read as a cell: that is what makes a stray report
           ;; visible rather than merely absent.
           (astray (save-excursion (goto-char (point-min))
                                   (search-forward "bravo") (- (point) 5)))
           (a (cooked--screen-cell from))
           (b (cooked--screen-cell astray))
           (elsewhere (generate-new-buffer "*cooked-test-elsewhere*")))
      (should-not (equal a b))
      (unwind-protect
          (save-window-excursion
            (set-window-buffer (selected-window) (current-buffer))
            (let ((window (split-window)))
              (set-window-buffer window elsewhere)
              (with-current-buffer elsewhere (insert (make-string 200 ?x)))
              (let ((last-input-event
                     (list 'down-mouse-1 (cooked-tests--posn from))))
                (cooked-mouse-event))
              (let ((last-input-event
                     (list 'drag-mouse-1 (cooked-tests--posn from)
                           (list window astray '(0 . 0) 0 nil astray
                                 nil nil nil))))
                (cooked-mouse-event))))
        (kill-buffer elsewhere))
      ;; Case matters: "m" is the release, "M" the press already sent.
      (let ((case-fold-search nil))
        (should (cooked-tests--settle
                 (lambda ()
                   (string-match-p (format "\\[<0;%d;%dm" (1+ (cdr a)) (1+ (car a)))
                                   (cooked-tests--text)))))
        (should-not (string-match-p (format "\\[<0;%d;%d[Mm]" (1+ (cdr b)) (1+ (car b)))
                                    (cooked-tests--text)))
        ;; And the child is not left holding a button it can never put down.
        (should-not cooked--mouse-held)))))

(ert-deftest cooked-a-report-to-the-child-gives-up-the-region ()
  "A click the child answers is the child's click.

Nothing used to clear the mark, so a region set before the child grabbed the
mouse survived every click inside the window; `cooked--snap-to-cursor' then
walked point away from a mark that stayed put, growing a region the user never
drew and could only escape by leaving the buffer."
  (with-temp-buffer
    (cooked-mode)
    (insert "alpha bravo\n")
    (set-mark (point-min))
    (activate-mark)
    (should mark-active)
    (let (sent)
      (cl-letf (((symbol-function 'cooked--send-to-child)
                 (lambda (text) (push text sent))))
        (cooked--send-mouse 0 1 2 t))
      (should sent))
    (should-not mark-active)))

(ert-deftest cooked-a-mouse-report-in-visual-state-leaves-evil-agreeing ()
  "The seam between cooked owning the click and evil owning the selection.
Reported as suspect and it holds up: `evil-visual-deactivate-hook' decides from
`this-command', a mouse report is sent under `cooked-mouse-event', and that
command carries no `:keep-visual' property -- so evil exits visual state along
with the mark and the two stay in step.

Asserted anyway, and asserted on evil's state rather than on the mark, because
the failure this rules out is invisible from the buffer: evil left believing in
a visual state with no region under it, after which the next \\`v' *leaves*
visual state rather than entering it."
  :tags '(evil)
  (skip-unless (require 'evil nil t))
  (require 'cooked-evil)
  (evil-mode 1)
  (with-temp-buffer
    (cooked-mode)
    (insert "alpha bravo\ncharlie delta\n")
    (goto-char (point-min))
    (evil-visual-state)
    (should (evil-visual-state-p))
    (should mark-active)
    (cl-letf (((symbol-function 'cooked--send-to-child) #'ignore))
      (let ((this-command 'cooked-mouse-event))
        (cooked--send-mouse 0 1 2 t)))
    (should-not mark-active)
    (should-not (evil-visual-state-p))))

(ert-deftest cooked-a-mouse-report-does-not-depend-on-there-being-a-command ()
  "And it holds up for a reason cooked should not be relying on.  `this-command'
is what kept the two in step above, and the drain clears the same selection for
the same reason with no command to read -- so both go through
`cooked--deactivate-mark', which asks evil outright.  Driven here with
`this-command' bound to nil, which is what a process filter sees."
  :tags '(evil)
  (skip-unless (require 'evil nil t))
  (require 'cooked-evil)
  (evil-mode 1)
  (with-temp-buffer
    (cooked-mode)
    (insert "alpha bravo\ncharlie delta\n")
    (goto-char (point-min))
    (evil-visual-state)
    (cl-letf (((symbol-function 'cooked--send-to-child) #'ignore))
      (let ((this-command nil))
        (cooked--send-mouse 0 1 2 t)))
    (should-not mark-active)
    (should-not (evil-visual-state-p))))

(ert-deftest cooked-output-clearing-a-selection-takes-evils-visual-state-with-it ()
  "The drain half, which is where a bare `deactivate-mark' does come apart: no
command is running, so `evil-visual-deactivate-hook' falls through both of its
arms and leaves evil in a visual state the user cannot see out of.

Reachable only with the render left live in visual state.  `frozen' is the
default precisely so that a selection is never rewritten underneath -- there is
no drain at all then, which
`cooked-evil-visual-state-freezes-the-render' is the proof of."
  :tags '(evil)
  (skip-unless (require 'evil nil t))
  (require 'cooked-evil)
  (evil-mode 1)
  (let ((cooked-evil-visual-state-render 'still))
    (cooked-tests--with-session '("/bin/sh" "-c" "printf 'alpha\\n'; exec cat")
      (should (cooked-tests--settle
               (lambda () (string-match-p "alpha" (cooked-tests--text)))))
      (goto-char (point-max))
      (evil-visual-state)
      (should (evil-visual-state-p))
      (should mark-active)
      (should-not (cooked--frozen-p))
      (cooked--send cooked--session "bravo\n")
      (should (cooked-tests--settle
               (lambda () (string-match-p "bravo" (cooked-tests--text)))))
      (should-not mark-active)
      (should-not (evil-visual-state-p)))))

(ert-deftest cooked-drag-and-any-motion-modes-survive-the-ffi ()
  "1002 and 1003 are not merely \"the mouse\": they say the child wants to be told
where the pointer went, and flattening them into one enabled bit left the sender
unable to know whether motion reports were asked for at all."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\033[?1002h\\033[?1006h'; exec cat")
    (should (cooked-tests--settle (lambda () (cooked-mouse-state-drag cooked--mouse-state))))
    (should (cooked-mouse-state-enabled cooked--mouse-state))
    (should (cooked-mouse-state-sgr cooked--mouse-state))
    (should-not (cooked-mouse-state-motion cooked--mouse-state)))
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '\\033[?1003h'; exec cat")
    (should (cooked-tests--settle (lambda () (cooked-mouse-state-motion cooked--mouse-state))))
    (should (cooked-mouse-state-enabled cooked--mouse-state))
    (should-not (cooked-mouse-state-drag cooked--mouse-state))))

(ert-deftest cooked-motion-reports-carry-the-motion-bit ()
  "32 added to the button being dragged, and 3 for no button at all."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--mouse :sgr t)
    (let (sent)
      (cl-letf (((symbol-function 'cooked--send-to-child)
                 (lambda (text) (push text sent))))
        (cooked--report-motion 4 9)
        (should (equal (car sent) "\e[<35;10;5M"))
        ;; The same cell twice is nothing the child needs to hear: Emacs tracks
        ;; the pointer by pixel, and this is what keeps that affordable.
        (cooked--report-motion 4 9)
        (should (equal (length sent) 1))
        (cooked--report-button 0 4 9 t)
        (cooked--report-motion 5 9)
        (should (equal (car sent) "\e[<32;10;6M"))
        ;; And the release puts the button down again, so motion goes back to 3.
        (cooked--report-button 0 5 9 nil)
        (cooked--report-motion 6 9)
        (should (equal (car sent) "\e[<35;10;7M"))))))

(ert-deftest cooked-a-release-off-the-screen-still-reaches-the-child ()
  "Let go past the last row and `posn-point' is nil, but the button is still down
as far as the child knows.  Falling through to Emacs there left it held forever."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--mouse :enabled t :sgr t)
    (setq cooked--mouse-held '(0) cooked--mouse-last-cell '(4 . 9))
    (let (sent)
      (cl-letf (((symbol-function 'cooked--send-to-child)
                 (lambda (text) (push text sent))))
        (let ((last-input-event (list 'drag-mouse-1 (cooked-tests--posn nil)
                                      (cooked-tests--posn nil))))
          (cooked-mouse-event)))
      (should (equal sent '("\e[<0;10;5m"))))
    (should-not cooked--mouse-held)))

(defmacro cooked-tests--with-mouse-rows (rows &rest body)
  "Run BODY in a cooked buffer whose screen is ROWS, one string each.

No session: the screen marker is put at the top by hand, the grid is 80
columns, and cells are 9 by 20 pixels, as a graphical frame would have
reported them."
  (declare (indent 1))
  `(with-temp-buffer
     (cooked-mode)
     (insert (mapconcat #'identity ,rows "\n"))
     (setq-local cooked--screen-start (copy-marker (point-min))
                 cooked--cols 80
                 cooked--last-cell '(9 . 20))
     ,@body))

(defun cooked-tests--glyph-posn (pos dx &optional area)
  "A posn over buffer POS, DX pixels into its glyph, in AREA of the window.
AREA nil is the text area; `left-fringe' is the fringe beside POS's row."
  (list (selected-window) (or area pos) '(0 . 0) 0 nil pos nil nil
        (cons dx 7) '(9 . 20)))

(ert-deftest cooked-mouse-cell-inside-a-decoration-run-is-the-pointers-own ()
  "Emacs draws a run of box-drawing cells as one image and names the run's first
character for every pixel of it, so a click in an empty panel reported the panel's
left border.  The offset into the image recovers the cell."
  (cooked-tests--with-mouse-rows '("ab" "┌────────┐")
    (let* ((start (save-excursion (goto-char (point-min)) (forward-line 1) (point)))
           (image '(image :type xbm :width 90 :height 20)))
      ;; One `display' value over the whole run, as `cooked--apply-deco' puts it.
      (add-text-properties start (+ start 10)
                           (list 'cooked-deco '(glyph nil 0 1) 'display image))
      (should (equal (cooked--mouse-cell (cooked-tests--glyph-posn start 50))
                     '(1 . 5)))
      (should (equal (cooked--mouse-cell (cooked-tests--glyph-posn start 0))
                     '(1 . 0)))
      ;; The last pixel of the run is its last cell, and no further.
      (should (equal (cooked--mouse-cell (cooked-tests--glyph-posn start 89))
                     '(1 . 9)))
      (should (equal (cooked--mouse-cell (cooked-tests--glyph-posn start 400))
                     '(1 . 9)))
      ;; A pixel report is the same cell plus what is left of the offset.
      (cooked-tests--mouse :enabled t :sgr t :pixels t)
      (let ((posn (cooked-tests--glyph-posn start 50)))
        (should (equal (cooked--mouse-offset posn) '(5 . 7)))))))

(ert-deftest cooked-mouse-cell-past-a-rows-end-and-over-the-fringe ()
  "Rows are inserted without their trailing blanks, so a click past the text lands
on the newline, whose glyph runs to the window's edge.  It reported the column
the text ended at.  And a fringe posn names the row beside it, which reported
column 0 of that row for a pointer over no cell at all."
  (cooked-tests--with-mouse-rows '("ls" "x")
    ;; Ten cells past the end of `ls', the pointer four pixels into the tenth.
    (should (equal (cooked--mouse-cell (cooked-tests--glyph-posn 3 94)) '(0 . 12)))
    ;; The last row has no newline and ends the buffer; the same holds there.
    (should (equal (cooked--mouse-cell (cooked-tests--glyph-posn 5 20)) '(1 . 3)))
    ;; A window wider than its grid does not report a column the child lacks.
    (should (equal (cooked--mouse-cell (cooked-tests--glyph-posn 3 9000)) '(0 . 79)))
    (should-not (cooked--mouse-cell (cooked-tests--glyph-posn 1 0 'left-fringe)))
    (should-not (cooked--mouse-cell (cooked-tests--glyph-posn 1 0 'right-margin)))
    ;; End to end in cell mode: the click is reported where it was made, and a
    ;; click in the fringe is left to Emacs rather than reported at column 0.
    (cooked-tests--mouse :enabled t :sgr t)
    (let (sent fallback)
      (cl-letf (((symbol-function 'cooked--send-to-child)
                 (lambda (text) (push text sent)))
                ((symbol-function 'cooked--mouse-buffer)
                 (lambda (_window) (current-buffer)))
                ((symbol-function 'cooked--mouse-fallback)
                 (lambda (event) (push event fallback))))
        (cooked-tests--displayed
          (let ((last-input-event (list 'down-mouse-1 (cooked-tests--glyph-posn 3 94))))
            (cooked-mouse-event))
          (let ((last-input-event
                 (list 'down-mouse-1 (cooked-tests--glyph-posn 1 0 'left-fringe))))
            (cooked-mouse-event))))
      (should (equal sent '("\e[<0;13;1M")))
      (should (= (length fallback) 1)))))

(ert-deftest cooked-mouse-offset-stays-inside-the-characters-cells ()
  "A fallback font can draw a character wider than the cells it stands on, and
the overhang reported into the next column.  A two-cell character keeps both."
  (cooked-tests--with-mouse-rows '("a中b")
    (cooked-tests--mouse :enabled t :sgr t :pixels t)
    ;; `a' is one cell: 30 pixels into its glyph is still its last pixel.
    (let ((posn (cooked-tests--glyph-posn 1 30)))
      (should (equal (cooked--mouse-cell posn) '(0 . 0)))
      (should (equal (cooked--mouse-offset posn) '(8 . 7))))
    ;; The wide character's right half is its second cell.
    (let ((posn (cooked-tests--glyph-posn 2 12)))
      (should (equal (cooked--mouse-cell posn) '(0 . 2)))
      (should (equal (cooked--mouse-offset posn) '(3 . 7))))
    (let ((posn (cooked-tests--glyph-posn 2 40)))
      (should (equal (cooked--mouse-cell posn) '(0 . 2)))
      (should (equal (cooked--mouse-offset posn) '(8 . 7))))))


(ert-deftest cooked-alternate-scroll-sends-cursor-keys ()
  "A pager that never asked for the mouse still gets the wheel."
  (with-temp-buffer
    (cooked-mode)
    (setq-local cooked--app-cursor nil)
    (let ((cooked-alternate-scroll-lines 3))
      (should (equal (cooked--alt-scroll-keys 64) "\e[A\e[A\e[A"))
      (should (equal (cooked--alt-scroll-keys 65) "\e[B\e[B\e[B")))
    ;; Application cursor mode changes the spelling, as it does for the arrow keys.
    (setq-local cooked--app-cursor t)
    (let ((cooked-alternate-scroll-lines 1))
      (should (equal (cooked--alt-scroll-keys 64) "\eOA")))
    ;; Horizontal notches have no cursor-key spelling and send nothing.
    (should (equal (cooked--alt-scroll-keys 66) ""))))

(ert-deftest cooked-alternate-scroll-sends-a-trackpads-rows-not-its-events ()
  "Under `pixel-scroll-precision-mode' every trackpad tick is an event carrying a
few pixels, and alternate scroll sent three lines for each of them, so a gentle
swipe in `less' scrolled pages.  Travel is a line per row crossed, carried
between events as a mouse report's notches are."
  (with-temp-buffer
    (cooked-mode)
    (setq-local cooked--app-cursor nil)
    (let ((cooked-alternate-scroll-lines 3)
          (cooked--scroll-pending 0.0)
          (mwheel-coalesce-scroll-events nil)
          sent)
      (cl-letf (((symbol-function 'cooked--alt-scroll-active-p) (lambda () t))
                ((symbol-function 'cooked--mouse-buffer) (lambda (_) (current-buffer)))
                ((symbol-function 'cooked--send-to-child)
                 (lambda (text) (push text sent)))
                ((symbol-function 'default-line-height) (lambda () 20))
                ((symbol-function 'device-class) nil))
        (fmakunbound 'device-class)
        (cooked-tests--displayed
          (dolist (pixels '(8 14 45))
            (let ((last-input-event
                   (list 'wheel-down (cooked-tests--posn nil) 0 0 (cons 0 pixels))))
              (cooked-mouse-event)))
          ;; 8 pixels is under a row, 22 has crossed one, and 67 has crossed three.
          (should (equal (reverse sent) '("" "\e[B" "\e[B\e[B")))
          ;; A notch is still a notch's worth, which is what the option is for.
          (setq sent nil)
          (let ((mwheel-coalesce-scroll-events t)
                (last-input-event
                 (list 'wheel-down (cooked-tests--posn nil) 1 1 '(0 . 40))))
            (cooked-mouse-event))
          (should (equal sent '("\e[B\e[B\e[B"))))))))


(ert-deftest cooked-alternate-scroll-grabs-the-wheel-without-mouse-mode ()
  "The keymap gate must widen, or the whole feature is unreachable."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--mouse)
    (setq-local cooked--semantic nil cooked--mode 'raw)
    (cl-letf (((symbol-function 'cooked--alt-scroll-active-p) (lambda () t)))
      (cooked--update-mouse-grab)
      (should cooked--mouse-grab))
    (cl-letf (((symbol-function 'cooked--alt-scroll-active-p) (lambda () nil)))
      (cooked--update-mouse-grab)
      (should-not cooked--mouse-grab))))

(ert-deftest cooked-focus-install-survives-other-packages-advice ()
  "`after-focus-change-function' holds one function, not a hook.

`add-hook' on it conses onto whatever is already there — doom-modeline puts
advice on it — leaving a list where Emacs expects something callable, and the
next focus change signals `invalid-function'."
  (let ((after-focus-change-function after-focus-change-function))
    (add-function :after after-focus-change-function #'ignore)
    ;; Twice, as a second session in the same Emacs would.
    (cooked--install-global-hooks)
    (cooked--install-global-hooks)
    (should (functionp after-focus-change-function))
    (should-not (proper-list-p after-focus-change-function))
    ;; The real check: it can actually be called.
    (funcall after-focus-change-function)))

(ert-deftest cooked-focus-is-not-reported-until-the-child-asks ()
  (cooked-tests--with-session '("/bin/cat")
    (should-not (cooked--focus-events-p cooked--session))
    ;; No mode set, so a focus change must put nothing on the child's input.
    ;;
    ;; Seeded to the opposite of what the frame actually reports, so that
    ;; `cooked--report-focus' sees a change at all.  Hardcoding nil did not: batch Emacs
    ;; reports no focus either, `(eq focused cooked--focused)' held, and the function
    ;; returned at its first guard without ever reaching the mode check this is about --
    ;; so the test passed with that check deleted outright.
    (setq-local cooked--focused (not (cooked--focused-p)))
    ;; Watched at the point the bytes would be written rather than in the buffer.  The
    ;; buffer cannot see this: `ESC [ I' is a control sequence, so even when it is wrongly
    ;; sent and `cat' echoes it straight back, the emulator consumes it and renders
    ;; nothing -- an empty buffer is what both the working and the broken case look like.
    ;; Waiting longer does not help; there is nothing to wait for.
    (let (sent)
      (cl-letf (((symbol-function 'cooked--reply-if-live)
                 (lambda (&rest _) (setq sent t))))
        (cooked--report-focus))
      (should-not sent))))

(ert-deftest cooked-focus-reports-once-per-change ()
  (cooked-tests--with-session
   '("/bin/sh" "-c" "printf '\\033[?1004h'; exec cat")
   (should (cooked-tests--settle
            (lambda () (cooked--focus-events-p cooked--session))))
   (let ((sent nil))
     (cl-letf (((symbol-function 'cooked--reply)
                (lambda (_s text) (push text sent))))
       ;; Losing focus reports once; asking again while still unfocused is silent.
       (setq-local cooked--focused t)
       (cl-letf (((symbol-function 'cooked--focused-p) (lambda () nil)))
         (cooked--report-focus)
         (cooked--report-focus))
       (should (equal sent (list "\e[O")))
       (cl-letf (((symbol-function 'cooked--focused-p) (lambda () t)))
         (cooked--report-focus))
       (should (equal sent (list "\e[I" "\e[O")))))))

(ert-deftest cooked-cursor-shape-follows-decscusr ()
  "vim and fish vi-mode signal their mode with `CSI Ps SP q'."
  (cooked-tests--with-session
   '("/bin/sh" "-c" "printf '\\033[5 q'; sleep 5")
   (should (cooked-tests--settle (lambda () (eq (cooked-cursor-shape cooked--cursor) 'bar))))
   (should (equal cursor-type '(bar . 2)))))

(ert-deftest cooked-hidden-cursor-survives-the-render-selecting-a-window ()
  "A child that hid its cursor must still have none after a drain that scrolls.

The render used to `recenter' through `with-selected-window', and `evil'
advises `select-window' to refresh its own cursor -- so setting `cursor-type'
before that block let evil overwrite it inside the very same drain.  Because the
write is skipped when the value has not changed, no later drain repaired it
either, and a progress bar drawn without a cursor got one anyway, jumping about.

`cooked--pin-transcript-bottom' computes the window start instead of selecting
the window to recentre it, so that particular route in is now structurally
impossible.  The test stays: evil refreshes its cursor from
`window-configuration-change-hook' and on every state change too, and the
ordering in `cooked--sync-cursor-type' is what those still need.

The buffer has to be shown in a window for any of that to run, which is why the
older visibility test never saw it."
  :tags '(evil)
  (skip-unless (require 'evil nil t))
  (let ((buffer (generate-new-buffer "*cooked-cursor*")))
    (unwind-protect
        (progn
          (set-window-buffer (selected-window) buffer)
          (with-current-buffer buffer
            (cooked-mode)
            (evil-local-mode 1)
            ;; Raw, so the hidden cursor is honoured at all: at a prompt Emacs
            ;; owns the line and keeps a cursor of its own regardless.
            (cooked--start
             '("/bin/sh" "-c" "stty raw -echo; printf 'working\033[?25l'; exec cat"))
            (cooked--refresh-keymap)
            (should (cooked-tests--settle
                     (lambda () (string-match-p "working" (cooked-tests--text)))))
            (should-not (cooked-cursor-visible cooked--cursor))
            (should-not cursor-type)
            ;; And it stays gone across further drains, which is where the
            ;; write-only-on-change guard used to make the damage permanent.
            (cooked--send-to-child "x")
            (should (cooked-tests--settle
                     (lambda () (string-match-p "x" (cooked-tests--text)))))
            (should-not cursor-type)))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer))))

(ert-deftest cooked-cursor-shape-does-not-fight-an-invisible-cursor ()
  (with-temp-buffer
    (cooked-mode)
    ;; Through `cooked--sync-cursor-type', which is where visibility and shape actually
    ;; meet.  Spelling that meeting out here as `(and visible (cooked--cursor-type))'
    ;; asserted nothing: `and' short-circuits on the nil, so the shape lookup this test
    ;; is named for never ran, and the `should' restated the fixture the line above set.
    (setq-local cooked--cursor (cooked--cursor-make :visible nil :shape 'bar))
    (cooked--sync-cursor-type)
    ;; Emacs' own cursor (`t'), never the `bar' the child asked for: a cursor the child
    ;; has hidden contributes no shape, and the line is Emacs' to draw a cursor on.
    (should (eq cursor-type t))
    (setq-local cooked--cursor (cooked--cursor-make :shape 'underline))
    (cooked--sync-cursor-type)
    (should (eq cursor-type 'hbar))))

(ert-deftest cooked-send-eof-reaches-the-child ()
  "C-c C-d must end input even when the line is not empty."
  (cooked-tests--with-session '("/bin/sh" "-c" "cat; printf 'SAW-EOF\\n'; sleep 5")
    (should (cooked-tests--settle (lambda () (eq cooked--mode 'cooked))))
    (should (eq (lookup-key cooked-raw-map (kbd "C-c C-d")) #'cooked-send-eof))
    (should (eq (lookup-key cooked-input-map (kbd "C-c C-d")) #'cooked-send-eof))
    (cooked--send cooked--session "partial line\n")
    (should (cooked-tests--settle
             (lambda () (string-match-p "partial line" (cooked-tests--text)))))
    (cooked-send-eof)
    (should (cooked-tests--settle
             (lambda () (string-match-p "SAW-EOF" (cooked-tests--text)))))))

(ert-deftest cooked-shifted-keys-are-not-flattened ()
  "Regression: Emacs reports S as shift+s, so reading `event-basic-type' alone
turned every capital letter into a lowercase one."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (setq cooked--app-cursor nil)
    (should (equal (cooked--encode-event ?S) "S"))
    (should (equal (cooked--encode-event ?A) "A"))
    (should (equal (cooked--encode-event ?s) "s"))
    (should (equal (cooked--encode-event ?!) "!"))
    ;; Control and meta still survive.
    (should (equal (cooked--encode-event ?\C-a) "\C-a"))
    (should (equal (cooked--encode-event ?\M-x) "\ex"))))

(ert-deftest cooked-an-event-in-none-of-the-tables-encodes-as-nil ()
  "An event no table spells has no encoding, and nil is how that is said.

The contract the fall-through rests on, pinned rather than assumed: nil means
`cooked-send-key' has nothing to forward, and the tables are searched in order
on the understanding that the first one holding a key answers for it.  Written
as a `cond' whose clauses were the lookups themselves, a table that hit but
produced nil would have carried on to the next one and encoded the key as a
different key; `cl-block' is what makes a hit terminal instead."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (setq cooked--app-cursor nil)
    ;; A mouse event is a list, and `event-basic-type' answers with a symbol no
    ;; table carries -- the shape a key reaches the end of the search in.
    (should-not (cooked--encode-event '(mouse-1 (nil 1 (0 . 0) 0))))
    (should-not (cooked--encode-event 'wheel-up))
    (should-not (cooked--encode-event 'f30))
    ;; Including with modifiers, which is the case that would otherwise have
    ;; found a code point in a `literal' `cooked--key-encodings' entry on the way past.
    (should-not (cooked--encode-event 'C-f30))))

(ert-deftest cooked-modified-arrows-use-xterm-parameters ()
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (setq cooked--app-cursor nil)
    (should (equal (cooked--encode-event 'up) "\e[A"))
    (should (equal (cooked--encode-event 'S-up) "\e[1;2A"))
    (should (equal (cooked--encode-event 'M-up) "\e[1;3A"))
    (should (equal (cooked--encode-event 'C-up) "\e[1;5A"))
    (should (equal (cooked--encode-event 'C-S-right) "\e[1;6C"))
    ;; DECCKM only applies to the unmodified form.
    (setq cooked--app-cursor t)
    (should (equal (cooked--encode-event 'up) "\eOA"))
    (should (equal (cooked--encode-event 'C-up) "\e[1;5A"))))

(ert-deftest cooked-modified-special-keys-are-encoded ()
  "Regression: the special-key branch applied only the meta modifier, so
Shift+Return, Control+Return, Shift+F5 and Shift+PageDown were all sent as their
unmodified selves, and Shift+TAB produced nothing at all."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (setq cooked--app-cursor nil)
    ;; Shift+TAB has a real terminfo entry (kcbt), so it needs no negotiation.
    (should (equal (cooked--encode-event 'backtab) "\e[Z"))
    ;; Tilde-style keys take the modifier as a second parameter.
    (should (equal (cooked--encode-event 'f5) "\e[15~"))
    (should (equal (cooked--encode-event 'S-f5) "\e[15;2~"))
    (should (equal (cooked--encode-event 'S-next) "\e[6;2~"))
    ;; F1-F4 are SS3 until modified, then CSI like everything else.
    (should (equal (cooked--encode-event 'f1) "\eOP"))
    (should (equal (cooked--encode-event 'S-f1) "\e[1;2P"))

    ;; Return and friends have no classical modified form, so they follow whatever
    ;; the child negotiated — and send the bare byte when it negotiated nothing.
    (setq cooked--keys 'legacy)
    (should (equal (cooked--encode-event 'return) "\r"))
    (should (equal (cooked--encode-event 'S-return) "\r"))
    (should (equal (cooked--encode-event 'M-return) "\e\r"))

    (setq cooked--keys 'modify-other)
    (should (equal (cooked--encode-event 'S-return) "\e[27;2;13~"))
    (should (equal (cooked--encode-event 'C-return) "\e[27;5;13~"))
    (should (equal (cooked--encode-event 'C-tab) "\e[27;5;9~"))
    ;; Unmodified stays plain regardless of what was negotiated.
    (should (equal (cooked--encode-event 'return) "\r"))

    (setq cooked--keys 'kitty)
    (should (equal (cooked--encode-event 'S-return) "\e[13;2u"))
    (should (equal (cooked--encode-event 'C-return) "\e[13;5u"))
    (should (equal (cooked--encode-event 'return) "\r"))))

(ert-deftest cooked-backtab-follows-negotiation-like-any-other-literal-key ()
  "Regression: `backtab' carries its shift in the base symbol, not in
`event-modifiers' -- so a naive param computation saw it as unmodified, and it
could never be spelled any way but the classical `ESC [ Z', negotiation or
override notwithstanding.  A program that switched itself to the kitty
protocol without negotiating (Claude Code) is no longer listening for that."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    ;; Nothing negotiated: the classical spelling, same as before this existed.
    (setq cooked--keys 'legacy)
    (should (equal (cooked--encode-event 'backtab) "\e[Z"))
    ;; Held alongside another modifier, Emacs still hides the shift -- `mods' is
    ;; `(control)', not `(control shift)' -- but the fallback stays the bare
    ;; classical sequence either way, same as the other literal keys above.
    (should (equal (cooked--encode-event 'C-backtab) "\e[Z"))
    (should (equal (cooked--encode-event 'M-backtab) "\e\e[Z"))

    ;; xterm sends Shift+Tab as `ESC [ Z' under modifyOtherKeys too, and spells
    ;; it only with another modifier held beside Shift.
    (setq cooked--keys 'modify-other)
    (should (equal (cooked--encode-event 'backtab) "\e[Z"))
    (should (equal (cooked--encode-event 'C-backtab) "\e[27;6;9~"))

    (setq cooked--keys 'kitty)
    (should (equal (cooked--encode-event 'backtab) "\e[9;2u"))
    (should (equal (cooked--encode-event 'C-backtab) "\e[9;6u"))
    ;; And the override path, which is what this was actually for: forcing the
    ;; kitty spelling on a `backtab' works now, where it used to be a no-op
    ;; because `cooked--encode-event' never had a branch that read `cooked--keys'
    ;; for this key at all.
    (setq cooked--keys nil)
    (should (equal (cooked--override-bytes-for :kitty 'backtab) "\e[9;2u"))))

(defmacro cooked-tests--with-kitty-flags (flags &rest body)
  "Run BODY as if the child had pushed kitty FLAGS, which cooked honours."
  (declare (indent 1))
  `(let ((cooked--keys 'kitty)
         (cooked--kitty-flags ,flags)
         (cooked--app-cursor nil))
     ,@body))

(ert-deftest cooked-kitty-disambiguate-follows-kittys-text-key-table ()
  "Bit 1 against the example table in kitty's keyboard protocol document.

Before flags 4, 8 and 16 were honoured this bit covered only the `literal'
keys, which left Control and Meta chords -- the ambiguity the bit is named for
-- spelled exactly as a legacy terminal spells them.

The table's key is `i', which is the one letter whose Control chords cannot be
checked here: Emacs folds C-i into TAB before any keymap sees it, on either
kind of frame, and a terminal frame's Tab key is the same byte.  Taking it as
Tab is what every terminal before kitty did, so those columns are checked on
`c' instead, where the table's rule is the same rule."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (cooked-tests--with-kitty-flags 1
      (should (equal (cooked--encode-event ?i) "i"))
      (should (equal (cooked--encode-event ?I) "I"))
      (should (equal (cooked--encode-event ?\M-i) "\e[105;3u"))
      (should (equal (cooked--encode-event ?\M-I) "\e[105;4u"))
      (should (equal (cooked--encode-event ?\C-c) "\e[99;5u"))
      (should (equal (cooked--encode-event ?\C-\M-c) "\e[99;7u"))
      (should (equal (cooked--encode-event ?\C-\S-c) "\e[99;6u"))
      (should (equal (cooked--encode-event ?\C-i) "\t"))
      (should (equal (cooked--encode-event ?\C-\s) "\e[32;5u"))
      ;; Escape is always an escape code; Return, Tab and Backspace stay bare
      ;; unmodified, so `reset' can still be typed after a crash.
      (should (equal (cooked--encode-event 'escape) "\e[27u"))
      (should (equal (cooked--encode-event 'M-escape) "\e[27;3u"))
      (should (equal (cooked--encode-event 'return) "\r"))
      (should (equal (cooked--encode-event 'tab) "\t"))
      (should (equal (cooked--encode-event 'backspace) "\177"))
      (should (equal (cooked--encode-event 'S-return) "\e[13;2u"))
      (should (equal (cooked--encode-event 'backtab) "\e[9;2u"))
      ;; A terminal frame's TAB, CR and DEL are the keys, not C-i, C-m and C-?;
      ;; its ESC is half of every Meta chord and goes as the byte.
      (should (equal (cooked--encode-event 9) "\t"))
      (should (equal (cooked--encode-event 13) "\r"))
      (should (equal (cooked--encode-event 127) "\177"))
      (should (equal (cooked--encode-event 27) "\e"))
      ;; Non-text keys leave SS3 behind, DECCKM or not, and F3 is not a CPR.
      (let ((cooked--app-cursor t))
        (should (equal (cooked--encode-event 'up) "\e[A"))
        (should (equal (cooked--encode-event 'f1) "\e[P")))
      (should (equal (cooked--encode-event 'C-up) "\e[1;5A"))
      (should (equal (cooked--encode-event 'f3) "\e[13~"))
      (should (equal (cooked--encode-event 'S-f3) "\e[13;2~"))
      (should (equal (cooked--encode-event 'f5) "\e[15~"))
      (should (equal (cooked--encode-event 'C-next) "\e[6;5~"))
      ;; The keypad is keys of its own: text where the cap has text, codes
      ;; where it does not.
      (should (equal (cooked--encode-event 'kp-1) "1"))
      (should (equal (cooked--encode-event 'C-kp-1) "\e[57400;5u"))
      (should (equal (cooked--encode-event 'kp-home) "\e[57423u"))
      (should (equal (cooked--encode-event 'kp-enter) "\e[57414u")))))

(ert-deftest cooked-kitty-alternate-keys-report-the-shifted-key ()
  "Bit 4: the shifted key after a colon, and only with Shift held.

kitty's document: ctrl+shift+a is `CSI 97 : 65 ; 6 u', never `CSI 65'.  The
base-layout key is never sent -- an Emacs event has no physical key to name --
which the protocol allows."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (cooked-tests--with-kitty-flags #b101
      (should (equal (cooked--encode-event ?\C-\S-a) "\e[97:65;6u"))
      (should (equal (cooked--encode-event ?\M-A) "\e[97:65;4u"))
      ;; No Shift, no shifted key.
      (should (equal (cooked--encode-event ?\C-a) "\e[97;5u"))
      ;; Only on a key that was going to be an escape code anyway.
      (should (equal (cooked--encode-event ?A) "A"))
      ;; Not on a key that produces no text.
      (should (equal (cooked--encode-event 'S-return) "\e[13;2u"))
      (should (equal (cooked--encode-event 'S-up) "\e[1;2A")))
    ;; Without the bit, the same chord has no alternate.
    (cooked-tests--with-kitty-flags 1
      (should (equal (cooked--encode-event ?\C-\S-a) "\e[97;6u")))))

(ert-deftest cooked-kitty-report-all-keys-sends-text-as-escape-codes ()
  "Bit 8: every key an escape code, Return, Tab and Backspace included.

And bit 16 beside it, which is the only way the text survives: kitty's
document gives shift+a as `CSI 97 ; 2 ; 65 u'."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (cooked-tests--with-kitty-flags #b1000
      (should (equal (cooked--encode-event ?a) "\e[97u"))
      (should (equal (cooked--encode-event ?A) "\e[97;2u"))
      (should (equal (cooked--encode-event 'return) "\e[13u"))
      (should (equal (cooked--encode-event 'tab) "\e[9u"))
      (should (equal (cooked--encode-event 'backspace) "\e[127u"))
      (should (equal (cooked--encode-event 9) "\e[9u"))
      (should (equal (cooked--encode-event 'escape) "\e[27u"))
      (should (equal (cooked--encode-event 'kp-1) "\e[57400u"))
      (should (equal (cooked--encode-event 'up) "\e[A")))
    (cooked-tests--with-kitty-flags #b11000
      (should (equal (cooked--encode-event ?A) "\e[97;2;65u"))
      (should (equal (cooked--encode-event ?a) "\e[97;;97u"))
      (should (equal (cooked--encode-event ?é) "\e[233;;233u"))
      (should (equal (cooked--encode-event 'kp-1) "\e[57400;;49u"))
      ;; Control prevents text, and keys that produce none carry none: kitty's
      ;; Enter with every flag on is `CSI 13 u'.
      (should (equal (cooked--encode-event ?\C-a) "\e[97;5u"))
      (should (equal (cooked--encode-event 'return) "\e[13u"))
      (should (equal (cooked--encode-event 'kp-enter) "\e[57414u")))
    ;; Everything at once.
    (cooked-tests--with-kitty-flags #b11101
      (should (equal (cooked--encode-event ?A) "\e[97:65;2;65u"))
      (should (equal (cooked--encode-event ?\C-\S-a) "\e[97:65;6u")))))

(ert-deftest cooked-kitty-associated-text-alone-changes-nothing ()
  "Bit 16 is an enhancement to bit 8 and undefined without it.

Under bit 1 alone, every key that produces text is sent as that text, and
every escape code it does send is for a chord Control or Meta has already
taken the text from -- so there is nowhere for the field to go."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (cooked-tests--with-kitty-flags #b10001
      (should (equal (cooked--encode-event ?a) "a"))
      (should (equal (cooked--encode-event ?A) "A"))
      (should (equal (cooked--encode-event ?\M-a) "\e[97;3u")))))

(ert-deftest cooked-kitty-guess-re-spells-only-the-literal-keys ()
  "`cooked-key-protocol-overrides' binds `kitty' with no flags behind it.

That is a guess about a program that never asked, and it must go on meaning
what it meant before the protocol proper was implemented: Shift+Return and
Shift+Tab re-spelled, Escape and every Control chord untouched."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (cooked-tests--with-kitty-flags 0
      (should-not (cooked--kitty-negotiated-p))
      (should (equal (cooked--encode-event 'S-return) "\e[13;2u"))
      (should (equal (cooked--encode-event 'escape) "\e"))
      (should (equal (cooked--encode-event ?\C-a) "\C-a"))
      (should (equal (cooked--encode-event ?\M-x) "\ex")))))

(ert-deftest cooked-kitty-flags-arrive-with-the-drain ()
  "The flags a child pushes reach `cooked--kitty-flags', masked to what is
honoured: bit 2 asks for release events Emacs never delivers."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\033[>31u'; sleep 5")
    (should (cooked-tests--settle (lambda () (eq cooked--keys 'kitty))))
    (should (= cooked--kitty-flags 29))))

(defmacro cooked-tests--with-modify-other-keys (level &rest body)
  "Run BODY as if the child had set modifyOtherKeys LEVEL, 0 meaning a guess."
  (declare (indent 1))
  `(let ((cooked--keys 'modify-other)
         (cooked--modify-other-keys ,level)
         (cooked--kitty-flags 0)
         (cooked--app-cursor nil))
     ,@body))

(ert-deftest cooked-modify-other-keys-level-2-spells-every-modified-key ()
  "Level 2 against xterm: `ModifyOtherKeys' in input.c, and the us-pc105 table
in xterm's modified-keys FAQ, whose Mode 2 column every expected value here is
read from.  Before, only the `literal' keys were re-spelled, so `C-;' went out
as a bare ESC -- the ambiguity the level exists to remove."
  (cooked-tests--with-modify-other-keys 2
    (should (eq (cooked--modify-other-level) 2))
    ;; The task's own four.
    (should (equal (cooked--encode-event ?\C-\;) "\e[27;5;59~"))
    (should (equal (cooked--encode-event ?\C-.) "\e[27;5;46~"))
    (should (equal (cooked--encode-event ?\C-,) "\e[27;5;44~"))
    (should (equal (cooked--encode-event ?\M-\C-a) "\e[27;7;97~"))
    ;; Control and Meta re-spell anything, keys with a control byte included.
    (should (equal (cooked--encode-event ?\C-a) "\e[27;5;97~"))
    (should (equal (cooked--encode-event ?\M-a) "\e[27;3;97~"))
    (should (equal (cooked--encode-event ?\C-1) "\e[27;5;49~"))
    (should (equal (cooked--encode-event ?\C-\s) "\e[27;5;32~"))
    (should (equal (cooked--encode-event ?\C-é) "\e[27;5;233~"))
    ;; Shift alone re-spells a letter, sent as its capital, and the space bar ...
    (should (equal (cooked--encode-event ?A) "\e[27;2;65~"))
    (should (equal (cooked--encode-event ?\C-\S-a) "\e[27;6;65~"))
    (should (equal (cooked--encode-event (aref (kbd "S-SPC") 0)) "\e[27;2;32~"))
    ;; ... but not a key that shifting already made unambiguous, and nothing
    ;; unmodified.
    (should (equal (cooked--encode-event ?!) "!"))
    (should (equal (cooked--encode-event ?É) "É"))
    (should (equal (cooked--encode-event ?a) "a"))
    ;; The literal keys are as they were, but for Shift+Tab, which is `ESC [ Z'
    ;; unless something besides Shift is held.
    (should (equal (cooked--encode-event 'backtab) "\e[Z"))
    (should (equal (cooked--encode-event 'S-tab) "\e[Z"))
    (should (equal (cooked--encode-event 'C-backtab) "\e[27;6;9~"))
    (should (equal (cooked--encode-event 'S-return) "\e[27;2;13~"))
    (should (equal (cooked--encode-event 'M-escape) "\e[27;3;27~"))
    (should (equal (cooked--encode-event 'return) "\r"))
    ;; Function and cursor keys are not the protocol's.
    (should (equal (cooked--encode-event 'C-up) "\e[1;5A"))
    ;; A terminal frame's TAB and ESC are keys, not C-i and a Control chord.
    (should (equal (cooked--encode-event 9) "\t"))
    (should (equal (cooked--encode-event 27) "\e"))))

(ert-deftest cooked-modify-other-keys-level-1-leaves-what-already-means-something ()
  "Level 1 against xterm's `allowedCharModifiers' and the Mode 1 column of the
same table, with Meta following metaSendsEscape as xterm's manual says it
does at this level."
  (cooked-tests--with-modify-other-keys 1
    ;; The task's pair: a chord with a control byte keeps it, one without is
    ;; re-spelled.
    (should (equal (cooked--encode-event ?\C-a) "\C-a"))
    (should (equal (cooked--encode-event ?\C-\;) "\e[27;5;59~"))
    ;; X's table, not a five-bit mask: these have bytes and keep them.
    (should (equal (cooked--encode-event ?\C-2) "\0"))
    (should (equal (cooked--encode-event ?\C-3) "\e"))
    (should (equal (cooked--encode-event ?\C-/) "\037"))
    (should (equal (cooked--encode-event ?\C-\S-a) "\C-a"))
    (should (equal (cooked--encode-event ?\C-1) "\e[27;5;49~"))
    ;; Shift alone and Meta alone never re-spell.
    (should (equal (cooked--encode-event ?A) "A"))
    (should (equal (cooked--encode-event ?\M-a) "\ea"))
    (should (equal (cooked--encode-event ?\M-\C-a) "\e\C-a"))
    ;; Where the rest re-spells, Meta counts in the parameter.
    (should (equal (cooked--encode-event ?\M-\C-\;) "\e[27;7;59~"))
    ;; Return and Tab under Shift or Control, but Meta takes itself and Control
    ;; out first, as xterm's `filterAltMeta' does.
    (should (equal (cooked--encode-event 'S-return) "\e[27;2;13~"))
    (should (equal (cooked--encode-event 'C-tab) "\e[27;5;9~"))
    (should (equal (cooked--encode-event 'M-return) "\e\r"))
    (should (equal (cooked--encode-event 'C-M-return) "\e\r"))
    (should (equal (cooked--encode-event 'M-S-return) "\e[27;2;13~"))
    ;; Shift+Tab is `ESC [ Z' at this level whatever else is held.
    (should (equal (cooked--encode-event 'backtab) "\e[Z"))
    (should (equal (cooked--encode-event 'C-backtab) "\e[Z"))
    ;; Escape only with Meta and Control or Shift; Backspace never.
    (should (equal (cooked--encode-event 'S-escape) "\e"))
    (should (equal (cooked--encode-event 'C-S-escape) "\e"))
    (should (equal (cooked--encode-event 'C-M-escape) "\e[27;7;27~"))
    (should (equal (cooked--encode-event 'C-backspace) "\177"))
    ;; Super has no bit in xterm's parameter, and is dropped from a chord.
    (should (equal (cooked--encode-event (aref (kbd "C-s-;") 0)) "\e[27;5;59~"))))

(ert-deftest cooked-modify-other-keys-guessed-re-spells-only-the-literal-keys ()
  "`modify-other' with no level is `cooked-key-protocol-overrides' guessing,
and a guess goes on meaning what it meant: Return and friends re-spelled,
every Control chord untouched."
  (cooked-tests--with-modify-other-keys 0
    (should-not (cooked--modify-other-level))
    (should (equal (cooked--encode-event 'S-return) "\e[27;2;13~"))
    (should (equal (cooked--encode-event 'C-backspace) "\e[27;5;127~"))
    (should (equal (cooked--encode-event ?\C-a) "\C-a"))
    (should (equal (cooked--encode-event ?\M-x) "\ex"))))

(ert-deftest cooked-legacy-control-chords-follow-x11 ()
  "Control makes a byte only where X11 makes one, and otherwise sends the key.
Masking every character to five bits sent `C-;' as ESC and `C-/' as SI."
  (let ((cooked--keys 'legacy) (cooked--app-cursor nil))
    (should (equal (cooked--encode-event ?\C-\;) ";"))
    (should (equal (cooked--encode-event ?\C-.) "."))
    (should (equal (cooked--encode-event ?\C-/) "\037"))
    (should (equal (cooked--encode-event ?\C-2) "\0"))
    (should (equal (cooked--encode-event ?\C-7) "\037"))
    (should (equal (cooked--encode-event ?\C-8) "\177"))
    (should (equal (cooked--encode-event ?\C-?) "\177"))
    (should (equal (cooked--encode-event ?\C-\S-a) "\C-a"))
    (should (equal (cooked--encode-event ?\M-\C-a) "\e\C-a"))))

(ert-deftest cooked-modify-other-keys-level-arrives-with-the-drain ()
  "The level a child sets reaches `cooked--modify-other-keys', level 1 included."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\033[>4;1m'; sleep 5")
    (should (cooked-tests--settle (lambda () (eq cooked--keys 'modify-other))))
    (should (= cooked--modify-other-keys 1))
    (should (equal (cooked--encode-event ?\C-\;) "\e[27;5;59~"))))

(ert-deftest cooked-control-chords-on-printable-keys-reach-the-child ()
  "A graphical frame's `C-;' and `C-S-a' are events of their own; unbound, the
first reached Emacs and the second lost its shift to translation, so no
protocol could spell either.  `C-S-c' stays out, since forwarding it would
take cooked's own prefix back through a shift."
  (should (eq (lookup-key cooked-alt-map (kbd "C-;")) #'cooked-send-key))
  (should (eq (lookup-key cooked-alt-map (kbd "C-S-a")) #'cooked-send-key))
  (should-not (eq (lookup-key cooked-alt-map (kbd "C-S-c")) #'cooked-send-key))
  (should (eq (lookup-key (cooked--build-meta-overlay cooked-alt-map) (kbd "C-M-;"))
              #'cooked-send-meta-key)))

(ert-deftest cooked-super-hyper-and-kittys-own-keys-reach-a-kitty-child ()
  "Through the command loop, the keys kitty spells and nothing else did reach it.

`cooked--modifier-param' summed Shift, Meta and Control, so \\`s-a' and \\`H-a'
went out as a plain `a', and no map bound them anyway.  \\`C-M-S-<up>' was not
among the modified spellings the maps bind, so Emacs shift-translated it to
\\`C-M-<up>' and the Shift was gone before `cooked-send-key' ran.  F13 and Pause
encoded to nothing.  While nothing is negotiated the Super chord and Pause stay
Emacs', since no other protocol can spell them."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\033[?1049h\\033[>1u'; stty raw -echo; cat -v")
    (should (cooked-tests--settle (lambda () (cooked--kitty-negotiated-p))))
    (cooked-tests--display-buffer)
    (let ((cooked--app-cursor nil))
      (dolist (key '("s-A" "S-s-a" "H-a" "C-M-S-<up>" "s-<up>" "<f13>" "<pause>" "C-é"))
        (ert-info ((format "%s under kitty" key))
          (should (eq (key-binding (kbd key)) #'cooked-send-key))))
      (execute-kbd-macro
       (vconcat (kbd "s-A") (kbd "C-M-S-<up>") (kbd "H-a") (kbd "<f13>") (kbd "<pause>")))
      (should (cooked-tests--settle
               (lambda ()
                 (string-search "^[[97;10u^[[1;8A^[[97;17u^[[57376u^[[57362u"
                                (cooked-tests--text))))))
    ;; Evil insert state keeps Super for Emacs, as it keeps Meta.
    (should-not (eq (lookup-key cooked-semi-map (kbd "s-A")) #'cooked-send-key))
    ;; With no flags, Super and Pause fall through to Emacs again while the keys a
    ;; legacy spelling exists for still forward.  Read per key, so no map is rebuilt.
    (let ((cooked--kitty-flags 0))
      (dolist (key '("s-A" "<pause>"))
        (should-not (eq (key-binding (kbd key)) #'cooked-send-key)))
      (dolist (key '("C-M-S-<up>" "<f13>" "<menu>"))
        (should (eq (key-binding (kbd key)) #'cooked-send-key))))))

(ert-deftest cooked-super-chords-emacs-binds-stay-with-emacs-under-kitty ()
  "Through the command loop, a Super or Hyper chord Emacs binds runs Emacs'
binding while a kitty child runs, and one it does not bind reaches the child.
Every chord used to go to the child, so \\`s-v' stopped pasting.  Decided on
each lookup: binding a chord mid-session takes it back, and unbinding it hands
it over again, with no map rebuilt."
  (let* ((ran nil)
         (command (lambda () (interactive) (push (this-command-keys-vector) ran))))
    (unwind-protect
        (cooked-tests--with-session
            '("/bin/sh" "-c" "printf '\\033[?1049h\\033[>1u'; stty raw -echo; cat -v")
          (should (cooked-tests--settle (lambda () (cooked--kitty-negotiated-p))))
          (cooked-tests--display-buffer)
          (global-set-key (kbd "s-v") command)
          (global-set-key (kbd "H-<up>") command)
          (should (eq (key-binding (kbd "s-v")) command))
          (should (eq (key-binding (kbd "s-j")) #'cooked-send-key))
          ;; The Meta overlay a graphical frame wears holds Super chords of its
          ;; own, under its ESC prefix.
          (global-set-key (kbd "M-s-v") command)
          (let ((local (current-local-map)))
            (unwind-protect
                (progn
                  (use-local-map (cooked--build-meta-overlay local))
                  (should (eq (key-binding (kbd "M-s-v")) command))
                  (should (eq (key-binding (kbd "M-s-j")) #'cooked-send-meta-key)))
              (use-local-map local)))
          (execute-kbd-macro (vconcat (kbd "s-v") (kbd "H-<up>") (kbd "s-j")))
          (should (equal (reverse ran) (list (kbd "s-v") (kbd "H-<up>"))))
          (should (cooked-tests--settle
                   (lambda () (string-search "^[[106;9u" (cooked-tests--text)))))
          (should-not (string-search "^[[118;9u" (cooked-tests--text)))
          ;; Unbound again, the chord is the child's at once.
          (global-unset-key (kbd "s-v"))
          (execute-kbd-macro (kbd "s-v"))
          (should (cooked-tests--settle
                   (lambda () (string-search "^[[118;9u" (cooked-tests--text))))))
      (global-unset-key (kbd "s-v"))
      (global-unset-key (kbd "H-<up>"))
      (global-unset-key (kbd "M-s-v")))))

(ert-deftest cooked-meta-chords-beyond-ascii-forward-on-a-graphical-frame ()
  "A graphical frame's \\`M-é' is one event, and the overlay's ESC map bound
only 0-127, so it reached Emacs.  The ESC map is now a full keymap."
  (let ((map (cooked--build-meta-overlay cooked-alt-map)))
    (dolist (key '("M-é" "M-中" "M-x"))
      (should (eq (lookup-key map (kbd key)) #'cooked-send-meta-key)))
    (dolist (key '("M-O" "M-["))
      (should-not (lookup-key map (kbd key)))))
  (let ((map (cooked--build-meta-overlay cooked-raw-map (list (aref (kbd "M-é") 0)))))
    (should-not (lookup-key map (kbd "M-é")))))

(defun cooked-tests--terminfo-keys ()
  "Every key capability of terminfo/cooked.ti, as (NAME . BYTES)."
  (with-temp-buffer
    (insert-file-contents (cooked--terminfo-source))
    (let (keys)
      (while (re-search-forward "^\t\\(k[A-Za-z0-9]+\\)=\\(.*\\),$" nil t)
        (let ((value (match-string 2)) (bytes nil) (at 0))
          (while (< at (length value))
            (pcase (aref value at)
              (?\\ (setq at (1+ at))
                   (push (pcase (aref value at) (?E 27) (c c)) bytes))
              (?^ (setq at (1+ at))
                  (push (if (eq (aref value at) ??) 127 (logand (aref value at) 31))
                        bytes))
              (c (push c bytes)))
            (setq at (1+ at)))
          (push (cons (match-string 1) (concat (nreverse bytes))) keys)))
      (nreverse keys))))

(defconst cooked-tests--terminfo-key-events
  (append
   '(("kbs" . backspace) ("kcbt" . backtab) ("kcub1" . left) ("kcud1" . down)
     ("kcuf1" . right) ("kcuu1" . up) ("kdch1" . deletechar) ("kend" . end)
     ("khome" . home) ("kich1" . insert) ("knp" . next) ("kpp" . prior)
     ("kind" . S-down) ("kri" . S-up) ("kent" . kp-enter) ("kbeg" . kp-begin)
     ("ka1" . kp-home) ("ka2" . kp-up) ("ka3" . kp-prior) ("kb1" . kp-left)
     ("kb2" . kp-5) ("kb3" . kp-right) ("kc1" . kp-end) ("kc2" . kp-down)
     ("kc3" . kp-next) ("kp5" . kp-begin) ("kpADD" . kp-add) ("kpSUB" . kp-subtract)
     ("kpMUL" . kp-multiply) ("kpDIV" . kp-divide) ("kpDOT" . kp-decimal)
     ("kpCMA" . kp-separator) ("kpZRO" . kp-0))
   ;; F1-F12, then the same twelve shifted, with Control, with Control and
   ;; Shift, with Meta, and three with Meta and Shift, as xterm numbers them.
   (cl-loop for n from 1 to 63
            collect (cons (format "kf%d" n)
                          (intern (format "%s%s"
                                          (nth (/ (1- n) 12) '("" "S-" "C-" "C-S-" "M-" "M-S-"))
                                          (format "f%d" (1+ (% (1- n) 12))))))
            into fkeys
            finally return (cons '("kf13" . f13) (assoc-delete-all "kf13" fkeys)))
   (cl-loop for (cap . key) in '(("DC" . deletechar) ("END" . end) ("HOM" . home)
                                 ("IC" . insert) ("LFT" . left) ("NXT" . next)
                                 ("PRV" . prior) ("RIT" . right) ("UP" . up)
                                 ("DN" . down))
            append (cl-loop for (suffix . mods) in '(("" . "S-") ("3" . "M-") ("4" . "M-S-")
                                                     ("5" . "C-") ("6" . "C-S-") ("7" . "C-M-"))
                            collect (cons (concat "k" cap suffix)
                                          (intern (concat mods (symbol-name key))))))
   '(("kmous") ("kxIN") ("kxOUT")))
  "The event each key capability in terminfo/cooked.ti is the spelling of.

nil for the three that describe reports cooked sends of its own accord, a
mouse report and the two focus reports, rather than a key.  `kf13' is `f13'
itself, where the other shifted function keys are named by their chord, so
that the `shifted' row the table spells it with is checked as well.")

(ert-deftest cooked-terminfo-keys-are-what-cooked-sends ()
  "Every key the entry declares is what cooked sends for that key.

The terminfo audit checked modes and queries, and nothing checked the ~160 key
capabilities: `kf5' could lose its row in `cooked--key-encodings' and every
test pass, while ncurses waited on a sequence that never arrived.  Under `smkx'
each capability is the key's spelling exactly.  Under `rmkx' the keypad and
cursor keys go back to their other spelling and every other key is unchanged.
A capability with no entry in `cooked-tests--terminfo-key-events' fails, so a
new one is checked from the day it is added."
  (let ((source (cooked--terminfo-source))
        (cooked--keys 'legacy))
    (skip-unless (file-exists-p source))
    (pcase-dolist (`(,name . ,bytes) (cooked-tests--terminfo-keys))
      (ert-info ((format "`%s' is %S" name bytes))
        (let ((entry (assoc name cooked-tests--terminfo-key-events)))
          (should entry)
          (when-let* ((event (cdr entry)))
            (let ((cooked--app-cursor t))
              (should (equal (cooked--encode-event event) bytes)))
            (unless (string-prefix-p "\eO" bytes)
              (let ((cooked--app-cursor nil))
                (should (equal (cooked--encode-event event) bytes))))))))))

(ert-deftest cooked-key-override-actions-encode-to-their-bytes ()
  "Every `cooked-key-overrides' action form, and the reason each one exists:
nobody should have to write `ESC [ 13;2 u' out by hand to bind Shift+Return."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    ;; Named bytes.
    (should (equal (cooked--override-bytes-for :newline 'S-return) "\n"))
    (should (equal (cooked--override-bytes-for :return 'S-return) "\r"))
    (should (equal (cooked--override-bytes-for :meta-return 'S-return) "\e\r"))
    (should (equal (cooked--override-bytes-for :tab 'S-return) "\t"))
    (should (equal (cooked--override-bytes-for :escape 'S-return) "\e"))
    ;; Protocol keywords re-spell the key that was pressed.
    (should (equal (cooked--override-bytes-for :kitty 'S-return) "\e[13;2u"))
    (should (equal (cooked--override-bytes-for :modify-other 'S-return)
                   "\e[27;2;13~"))
    (should (equal (cooked--override-bytes-for :kitty 'C-return) "\e[13;5u"))
    ;; A literal string is the escape hatch.
    (should (equal (cooked--override-bytes-for "\e[200~" 'S-return) "\e[200~"))))

(ert-deftest cooked-key-override-does-not-become-the-negotiated-encoding ()
  "Regression guard on the whole design: an override is a statement about one
program, not a discovery about what the child asked for.  If it leaked into
`cooked--keys', every *other* modified key would start being spelled in a
protocol the child never negotiated -- which is the rubbish-in-the-input case
cooked exists to avoid."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (setq cooked--keys 'legacy)
    (should (equal (cooked--override-bytes-for :kitty 'S-return) "\e[13;2u"))
    (should (eq cooked--keys 'legacy))
    ;; And the ordinary path is still spelling keys the legacy way.
    (should (equal (cooked--encode-event 'S-return) "\r"))))

(ert-deftest cooked-key-override-matches-the-foreground-program ()
  "The child cooked spawned is a shell; the program an override names is
whatever that shell put in the foreground.  Matching the session's own argv
would miss every `claude' typed at a cooked prompt, which is the case this
feature is for."
  (let ((cooked-key-overrides '(("\\`cat\\'" . (("<S-return>" . :newline))))))
    (cooked-tests--with-session
        '("/bin/sh" "-c" "stty raw -echo; printf '\033[?1049h'; exec cat -v")
      (should (cooked-tests--settle (lambda () (eq (cooked--policy) 'alt))))
      (cooked--refresh-keymap)
      (should (equal (cooked--foreground-program) "cat"))
      (should (eq (key-binding (kbd "<S-return>")) #'cooked-send-override))
      ;; Above the state map, which still has its own binding for the key.
      (should (eq (lookup-key cooked-alt-map (kbd "<S-return>")) #'cooked-send-key)))))

(ert-deftest cooked-key-override-is-inert-when-emacs-owns-the-line ()
  "Overrides take keys away from Emacs, so they may only apply while the child
owns the keyboard.  Regression: an override on `<S-return>' that followed the
buffer to its own prompt would displace `cooked-newline', and Shift+Return would
stop composing a multi-line command."
  (let ((cooked-key-overrides '(("." . (("<S-return>" . :newline))))))
    (cooked-tests--with-session '("/bin/sh" "-c" "exec cat")
      ;; A canonical read: Emacs owns the line.
      (should (cooked-tests--settle (lambda () (cooked--input-state-p))))
      (cooked--refresh-keymap)
      (should-not cooked--override-map-alist)
      (should (eq (key-binding (kbd "<S-return>")) #'cooked-newline))))
  ;; And while peeking, which hands the buffer back to ordinary Emacs commands.
  (let ((cooked-key-overrides '(("." . (("<S-return>" . :newline))))))
    (cooked-tests--with-session
        '("/bin/sh" "-c" "stty raw -echo; printf '\033[?1049h'; exec cat -v")
      (should (cooked-tests--settle (lambda () (eq (cooked--policy) 'alt))))
      (cooked--refresh-keymap)
      (should cooked--override-map-alist)
      (call-interactively #'cooked-toggle-peek)
      (should (cooked--suspended-p))
      (should-not cooked--override-map-alist))))

(ert-deftest cooked-key-protocol-override-matches-the-foreground-program ()
  "The blanket version of `cooked-key-overrides': a program-wide guess at what
`cooked--keys' would have been, for a child that never negotiates one for real."
  (let ((cooked-key-protocol-overrides '(("\\`cat\\'" . kitty))))
    (cooked-tests--with-session
        '("/bin/sh" "-c" "stty raw -echo; printf '\033[?1049h'; exec cat -v")
      (should (cooked-tests--settle (lambda () (eq (cooked--policy) 'alt))))
      (should (equal (cooked--foreground-program) "cat"))
      (should (eq (cooked--assumed-key-protocol) 'kitty))
      ;; It only ever adjusts the ordinary path, not the negotiated state itself.
      (should (eq cooked--keys 'legacy))
      (let ((sent nil))
        (cl-letf (((symbol-function 'cooked--send)
                   (lambda (_s text) (push text sent))))
          (let ((last-command-event 'backtab))
            (cooked-send-key))
          (should (equal sent '("\e[9;2u"))))))))

(ert-deftest cooked-key-protocol-override-yields-to-a-real-negotiation ()
  "A guess about what a program probably wants is never trusted over what it
actually asked for -- if that ever happened, this would be indistinguishable
from a bug that silently ignored `CSI ? u'."
  (let ((cooked-key-protocol-overrides '(("\\`cat\\'" . kitty))))
    (cooked-tests--with-session '("/bin/cat")
      (should (cooked-tests--settle (lambda () (eq cooked--mode 'cooked))))
      (setq cooked--keys 'modify-other)
      (should-not (cooked--assumed-key-protocol))
      (let ((sent nil))
        (cl-letf (((symbol-function 'cooked--send)
                   (lambda (_s text) (push text sent))))
          (let ((last-command-event 'S-return))
            (cooked-send-key))
          (should (equal sent '("\e[27;2;13~"))))))))

(ert-deftest cooked-key-protocol-override-is-inert-when-emacs-owns-the-line ()
  "Same gating as `cooked-key-overrides', and for the same reason: this is
still keys being taken away from Emacs' own idea of what they mean."
  (let ((cooked-key-protocol-overrides '(("." . kitty))))
    (cooked-tests--with-session '("/bin/sh" "-c" "exec cat")
      (should (cooked-tests--settle (lambda () (cooked--input-state-p))))
      (should-not (cooked--assumed-key-protocol)))))

(ert-deftest cooked-key-override-still-wins-over-the-protocol-override ()
  "The two mechanisms can coexist: a specific `cooked-key-overrides' entry is
consulted first, from a keymap above the ordinary passthrough path the
protocol override adjusts, so it is never shadowed by a blanket guess."
  (let ((cooked-key-overrides '(("\\`cat\\'" . (("<S-return>" . :newline)))))
        (cooked-key-protocol-overrides '(("\\`cat\\'" . kitty))))
    (cooked-tests--with-session
        '("/bin/sh" "-c" "stty raw -echo; printf '\033[?1049h'; exec cat -v")
      (should (cooked-tests--settle (lambda () (eq (cooked--policy) 'alt))))
      (cooked--refresh-keymap)
      ;; The named key still resolves to the specific override, not `cooked-send-key'
      ;; -- so the blanket protocol guess never gets a chance to run for it at all.
      (should (eq (key-binding (kbd "<S-return>")) #'cooked-send-override))
      ;; A key the specific override says nothing about still falls through to the
      ;; ordinary path, where the blanket guess applies.
      (should (eq (key-binding (kbd "<backtab>")) #'cooked-send-key))
      (should (eq (cooked--assumed-key-protocol) 'kitty)))))

(ert-deftest cooked-key-protocol-override-default-covers-claude-code ()
  "The default is deliberately one program wide.

Claude Code never negotiates a keyboard protocol: it enables the kitty
protocol for its own use from a list of terminal names it recognises in the
environment, and never sends the `CSI ? u' query cooked answers, but reads a
kitty-formatted sequence regardless of that decision.  Cooked will not claim to
be one of those terminals, so the override is the honest way through -- see
`cooked-key-protocol-overrides'."
  (should (equal (alist-get "\\`claude\\'" cooked-key-protocol-overrides
                            nil nil #'equal)
                 'kitty))
  ;; Nothing else is claimed by default, and `cooked-key-overrides' -- the
  ;; narrower, per-key mechanism -- claims nothing at all: Claude Code's needs
  ;; are covered by the blanket protocol guess above instead.
  (should (= 1 (length cooked-key-protocol-overrides)))
  (should-not cooked-key-overrides))

(ert-deftest cooked-typing-snaps-into-the-input-region ()
  "Regression, from two directions.

The screen is rendered with a newline after the last row, so there is a blank
line below the prompt; typing there used to land outside the input markers, and
`cooked-send-input' would then submit an empty line while the text sat in the
buffer looking accepted.  Before the region, the prompt is read-only, so typing
signalled \"Text is read-only\" — which is exactly where evil's normal state
leaves the cursor at an empty prompt, since it pulls back off the end of a line."
  :tags '(zsh)
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-shell ("zsh" :name "*cooked-snap*" :settle (lambda () (eq cooked--semantic 'input)))
    (switch-to-buffer buffer)

    ;; Below the input region: the blank line the screen render leaves.
    (goto-char (point-max))
    (should (> (point) (marker-position cooked--input-end)))
    (cooked-tests--type "e c h o")
    (should (equal (cooked--pending-input) "echo"))

    ;; Before it: inside the read-only prompt, where evil parks the cursor.
    (cooked-kill-input)
    (goto-char (1- (cooked--input-start-position)))
    (cooked-tests--type "h i")
    (should (equal (cooked--pending-input) "hi"))))

(ert-deftest cooked-editing-mid-line-survives-a-drain ()
  "A drain must not move point out of the line the user is typing.

`cooked--apply' lifts the pending input out of the buffer and rebuilds it around
the child's new cursor, so the buffer position point had cannot survive -- and
what it used to do instead was send point to the end of the line, on the grounds
that following the cursor is what carries it.  That is right only when point was
at the end already.  Nothing about completion here on purpose: completion is
merely the thing that forces a drain on demand while point is deliberately
elsewhere, and the same happens for a background job printing a line."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'ready$ '; exec cat")
    (should (cooked-tests--settle
             (lambda () (and (string-match-p "ready" (cooked-tests--text))
                             (cooked--input-start-position)))))
    (goto-char cooked--input-end)
    (insert "hello world")
    (goto-char (- (point) 6))
    (let ((offset (- (point) (cooked--input-start-position))))
      ;; A drain carrying nothing at all is still a lift and a rebuild.
      (cooked--drain-and-apply)
      (should (equal (cooked--pending-input) "hello world"))
      (should (= (- (point) (cooked--input-start-position)) offset))
      ;; And the offset is what is held, not the position: output that moves the
      ;; line moves point with it, still six characters from the end.
      (cooked--send-to-child "noise\n")
      (should (cooked-tests--settle
               (lambda () (string-match-p "noise" (cooked-tests--text)))))
      (should (equal (cooked--pending-input) "hello world"))
      (should (= (- (point) (cooked--input-start-position)) offset)))))

(ert-deftest cooked-a-drain-still-follows-a-point-at-the-end-of-the-line ()
  "The everyday case the mid-line fix must not cost: point at the end of what is
being typed stays at the end, and point out in the scrollback stays where the
user parked it."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'ready$ '; exec cat")
    (should (cooked-tests--settle
             (lambda () (and (string-match-p "ready" (cooked-tests--text))
                             (cooked--input-start-position)))))
    (goto-char cooked--input-end)
    (insert "hello")
    (cooked--drain-and-apply)
    (should (= (point) (marker-position cooked--input-end)))))

(ert-deftest cooked-c-c-m-x-escapes-back-to-emacs ()
  "In raw state every key including ESC goes to the child, so plain M-x arrives
there as ESC x.  C-c M-x is the way back to Emacs, and a completion framework's
remap of `execute-extended-command', as counsel-mode makes, still applies."
  (should (eq (lookup-key cooked-raw-map (kbd "C-c M-x")) #'execute-extended-command))
  (should (eq (lookup-key cooked-input-map (kbd "C-c M-x")) #'execute-extended-command))
  ;; Plain M-x is still the child's in raw state — that is the behaviour C-c M-x
  ;; exists to work around, not one to break.
  (should (eq (lookup-key cooked-raw-map (kbd "ESC")) #'cooked-send-key))
  (with-temp-buffer
    (let ((map (make-sparse-keymap)))
      (set-keymap-parent map cooked-raw-map)
      (define-key map [remap execute-extended-command] #'ignore)
      (use-local-map map)
      (should (eq (key-binding (kbd "C-c M-x")) #'ignore)))))

(ert-deftest cooked-modified-keys-survive-shift-translation ()
  "Without a binding of its own, Emacs translates S-return to return before the
command runs, flattening the event past recovery.  The binding is the fix."
  (should (eq (lookup-key cooked-raw-map [S-return]) #'cooked-send-key))
  (should (eq (lookup-key cooked-raw-map [C-return]) #'cooked-send-key))
  (should (eq (lookup-key cooked-raw-map [backtab]) #'cooked-send-key))
  (should (eq (lookup-key cooked-raw-map [S-f5]) #'cooked-send-key))
  ;; At a prompt the same key composes a multi-line command instead.
  (should (eq (lookup-key cooked-input-map [S-return]) #'cooked-newline)))

(ert-deftest cooked-shift-return-composes-multiple-lines ()
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle (lambda () (eq cooked--mode 'cooked))))
    (cooked--restore-pending-input nil)
    (goto-char cooked--input-end)
    (insert "first")
    (cooked-newline)
    (insert "second")
    (should (equal (cooked--pending-input) "first\nsecond"))))

(ert-deftest cooked-shift-reaches-the-child ()
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle (lambda () (eq cooked--mode 'cooked))))
    (cooked--send cooked--session (cooked--encode-event ?S))
    (cooked--send cooked--session (cooked--encode-event ?H))
    (cooked--send cooked--session "\r")
    (should (cooked-tests--settle
             (lambda () (string-match-p "SH" (cooked-tests--text)))))))

(ert-deftest cooked-transcript-navigation-works-in-both-states ()
  "Jumping between commands sends nothing to the child, so a running program
must not take the binding away."
  (dolist (map (list cooked-input-map cooked-raw-map cooked-alt-map))
    (should (eq (lookup-key map (kbd "C-c C-p")) #'cooked-previous-command))
    (should (eq (lookup-key map (kbd "C-c C-n")) #'cooked-next-command))
    (should (eq (lookup-key map (kbd "C-c TAB")) #'cooked-toggle-fold))))

(ert-deftest cooked-navigation-lands-on-prompts-and-skips-nothing ()
  "Stepping back used to land on each command's *output*, which for a command
that printed nothing is the beginning of the next prompt -- so a quiet command,
and every failing one, was stepped straight over and looked as though it had
never been recorded.  It always was; there was nowhere to stand."
  :tags '(zsh)
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-zsh
    (dolist (line '("echo one" "false" "echo two"))
      (let ((before (length cooked--commands)))
        (cooked--replace-input line)
        (cooked-send-input)
        (should (cooked-tests--settle
                 (lambda () (> (length cooked--commands) before)) 8))))
    ;; Back to a prompt, so the last command's own prompt line is complete.
    (should (cooked-tests--settle
             (lambda () (and (eq cooked--semantic 'input)
                             (cooked--input-start-position)))
             8))
    (goto-char (point-max))
    (let ((lines nil))
      (dotimes (_ 4)
        (cooked-previous-command)
        (push (buffer-substring-no-properties (line-beginning-position)
                                              (line-end-position))
              lines))
      ;; Four steps back from the bottom: the live prompt, then one landing per
      ;; command, each on the line the command was typed on.
      (should (= (length (delete-dups (copy-sequence lines))) 4))
      (should (seq-some (lambda (l) (string-suffix-p "false" l)) lines))
      (should (seq-some (lambda (l) (string-suffix-p "echo one" l)) lines))
      (should (seq-some (lambda (l) (string-suffix-p "echo two" l)) lines)))))

(ert-deftest cooked-navigation-falls-back-to-output-without-an-a-mark ()
  "A shell that sends `C' and `D' but no `A' has told us where output began and
nothing about the prompt.  Navigation then means what it always did."
  (cooked-tests--with-session
      '("/bin/sh" "-c"
        "printf '\033]133;C\007first\n\033]133;D;0\007\
\033]133;C\007second\n\033]133;D;0\007'; sleep 5")
    (should (cooked-tests--settle (lambda () (= (length cooked--commands) 2))))
    (should-not (cooked--command-prompt-position (car cooked--commands)))
    ;; With no `A' mark anywhere, every record falls back to its output start,
    ;; so the two lists coincide -- which is the whole of what "means what it
    ;; always did" says.  Spelled out here rather than against a helper, since
    ;; the only thing that ever wanted it was this assertion.
    (should (equal (cooked--prompt-starts)
                   (sort (mapcar #'cooked--command-start-position cooked--commands)
                         #'<)))))

(ert-deftest cooked-evil-command-text-objects-take-the-output-and-the-command ()
  "`ic' is what the command printed; `ac' adds the prompt it was typed at and
the line itself.  Neither reaches the following prompt, which a linewise range
ending one past the output would otherwise swallow."
  :tags '(evil zsh)
  (skip-unless (require 'evil nil t))
  (skip-unless (executable-find "zsh"))
  (require 'cooked-evil)
  (evil-mode 1)
  (cooked-tests--with-zsh
    (dolist (line '("echo alpha" "false"))
      (let ((before (length cooked--commands)))
        (cooked--replace-input line)
        (cooked-send-input)
        (should (cooked-tests--settle
                 (lambda () (> (length cooked--commands) before)) 8))))
    (should (cooked-tests--settle
             (lambda () (and (eq cooked--semantic 'input)
                             (cooked--input-start-position)))
             8))
    (let* ((record (car (last cooked--commands)))     ; "echo alpha", the oldest
           (inner (cooked--command-region record))
           (outer (cooked--command-region record t))
           (inner-text (buffer-substring-no-properties (car inner) (cdr inner)))
           (outer-text (buffer-substring-no-properties (car outer) (cdr outer))))
      (should (equal inner-text "alpha"))
      (should (string-suffix-p "echo alpha\nalpha" outer-text))
      (should-not (string-search "false" outer-text)))
    ;; A command that printed nothing has an outer half and no inner one.
    (let ((quiet (car cooked--commands)))
      (goto-char (cooked--command-prompt-position quiet))
      (should (string-suffix-p "false" (buffer-substring-no-properties
                                        (line-beginning-position)
                                        (line-end-position))))
      (should (eq (cooked--command-around (point)) quiet))
      ;; Empty, and exclusive so that it stays empty: a linewise range of no
      ;; width expands to the whole line its ends sit on, which here is the
      ;; *next* command's prompt.
      (let ((inner (cooked-evil--command-range 1 nil)))
        (should inner)
        (should (= (nth 0 inner) (nth 1 inner)))
        (should (eq (evil-type inner) 'exclusive)))
      (should (cooked-evil--command-range 1 t)))))

(ert-deftest cooked-evil-inner-command-on-a-silent-command-leaves-visual-state-sane ()
  "`ic' on a command that printed nothing used to signal, and a signal in a text
object is not just unidiomatic: Emacs runs no `post-command-hook' after a
command that signalled, so `evil-visual-post-command' never reconciled the
selection and evil was left believing in a visual state the user could not see
-- the terminal being frozen under `cooked-evil-visual-state-render'.  The next
`v' then *exited* that state instead of entering it, `i' put the buffer in
insert state, and the `c' went to the shell as a keystroke.  Two `vic' in a row
have to leave evil in visual state."
  :tags '(evil zsh)
  (skip-unless (require 'evil nil t))
  (skip-unless (executable-find "zsh"))
  (require 'cooked-evil)
  (evil-mode 1)
  ;; The other half of the same contract: no command at point at all is nil,
  ;; which evil reads as "no such object" and answers with a silent no-op.
  (should-not (with-temp-buffer (cooked-mode) (cooked-evil--command-range 1 nil)))
  (cooked-tests--with-zsh
    (let ((before (length cooked--commands)))
      (cooked--replace-input "false")
      (cooked-send-input)
      (should (cooked-tests--settle
               (lambda () (> (length cooked--commands) before)) 8)))
    (should (cooked-tests--settle
             (lambda () (and (eq cooked--semantic 'input)
                             (cooked--input-start-position)))
             8))
    (let ((quiet (car cooked--commands)))
      (goto-char (cooked--command-prompt-position quiet))
      (evil-normal-state)
      ;; Through the command loop and on screen, since that is the only way the
      ;; keys reach the buffer's own keymap and the only way `post-command-hook'
      ;; runs at all -- which is the whole of what went wrong.
      (cooked-tests--display-buffer)
      ;; An unexpected signal out of either of these is the bug itself; ert
      ;; reports it without any `should-not-error' to help it.
      (dotimes (_ 2)
        (cooked-tests--type "v i c"))
      (should (evil-visual-state-p))
      (should-not (evil-insert-state-p))
      ;; And nothing of the `c' reached the shell, which is where it went once
      ;; the second `v' had dropped out of visual state and the `i' had put the
      ;; buffer in insert state: the pending line is still empty.
      (should (equal "" (string-trim (buffer-substring-no-properties
                                      (cooked--input-start-position)
                                      (point-max))))))))

(ert-deftest cooked-evil-command-text-object-covers-what-is-still-running ()
  "A build that has not finished has no record yet, only the live markers --
and `yac' on it is exactly what one wants while it is running."
  :tags '(evil zsh)
  (skip-unless (require 'evil nil t))
  (skip-unless (executable-find "zsh"))
  (require 'cooked-evil)
  (evil-mode 1)
  (cooked-tests--with-zsh
    (cooked--replace-input "echo running; sleep 5")
    (cooked-send-input)
    (should (cooked-tests--settle
             (lambda () (and cooked--command-start
                             (string-search "running" (cooked-tests--text))))
             8))
    (goto-char (marker-position cooked--command-start))
    (let* ((range (cooked-evil--command-range 1 t))
           (text (buffer-substring-no-properties (nth 0 range) (nth 1 range))))
      (should (string-search "sleep 5" text))
      (should (string-search "running" text)))))

(ert-deftest cooked-evil-text-objects-are-scoped-to-cooked-buffers ()
  "Ours in a cooked buffer, and only there: the rest of the family has to keep
meaning what it means, in this buffer and every other one."
  :tags '(evil)
  (skip-unless (require 'evil nil t))
  (require 'cooked-evil)
  (evil-mode 1)
  (with-temp-buffer
    (cooked-mode)
    (evil-visual-state)
    (should (eq (key-binding (kbd "ic")) #'cooked-evil-inner-command))
    (should (eq (key-binding (kbd "ac")) #'cooked-evil-outer-command))
    ;; Untouched, which a keymap on `i' rather than on `ic' would not have left.
    (should (eq (key-binding (kbd "iw")) #'evil-inner-word))
    (should (eq (key-binding (kbd "ip")) #'evil-inner-paragraph))
    (evil-normal-state)
    (should (eq (key-binding (kbd "[[")) #'cooked-previous-command))
    (should (eq (key-binding (kbd "]]")) #'cooked-next-command)))
  (with-temp-buffer
    (fundamental-mode)
    (evil-visual-state)
    (should-not (eq (key-binding (kbd "ic")) #'cooked-evil-inner-command))
    (evil-normal-state)))

(ert-deftest cooked-a-hidden-cursor-comes-back-when-forwarding-stops ()
  "A full-screen program hides the cursor while it draws, and Emacs honours
that -- rightly, while the child is the one being typed at.  The moment
forwarding stops, point is the only cursor there is, and navigating a buffer
whose cursor has been turned off is navigating blind."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "stty raw -echo; printf '\033[?25l'; cat")
    (should (cooked-tests--settle
             (lambda () (and cooked--cursor
                             (not (cooked-cursor-visible cooked--cursor))))))
    (should-not cursor-type)
    (call-interactively #'cooked-toggle-peek)
    (should cursor-type)
    ;; And the ghost is not drawn for a cursor the child says it does not have,
    ;; so there is one cursor on screen either way.
    (should-not (cooked--ghost-cursor-visible-p))
    (call-interactively #'cooked-toggle-peek)
    (should-not cursor-type)))

(ert-deftest cooked-evil-normal-state-gives-a-hidden-cursor-back ()
  "The same, reached the way an evil user reaches it."
  :tags '(evil)
  (skip-unless (require 'evil nil t))
  (require 'cooked-evil)
  (evil-mode 1)
  (cooked-tests--with-session
      '("/bin/sh" "-c" "stty raw -echo; printf '\033[?25l'; cat")
    (should (cooked-tests--settle
             (lambda () (and cooked--cursor
                             (not (cooked-cursor-visible cooked--cursor))))))
    (evil-emacs-state)
    (should-not cursor-type)
    (evil-normal-state)
    (should cursor-type)
    (evil-emacs-state)
    (should-not cursor-type)))

(ert-deftest cooked-arrow-keys-reach-the-child-from-evil-insert-state ()
  "`evil-collection-comint' binds the arrow keys for insert state on an
auxiliary keymap that evil consults ahead of `cooked-semi-map', so they arrive
at `cooked-previous-input' rather than being forwarded.  At a shell editing its
own line that used to be answered with \"Not at an input prompt\"; the history
being asked for is the child's, and `<up>' is how a terminal asks for it."
  (cooked-tests--with-echoing-child ""
    (should-not (cooked--input-state-p))
    (cooked-previous-input)
    (should (cooked-tests--settle
             (lambda () (string-search "^[[A" (cooked-tests--text)))))
    (cooked-next-input)
    (should (cooked-tests--settle
             (lambda () (string-search "^[[B" (cooked-tests--text)))))))

;; Regression: `cooked--mouse-cell' used to count columns with `current-column',
;; which measures from the start of the buffer line.  On screen row 0 that line
;; begins above `cooked--screen-start' whenever the row handed over last was
;; wrapped, so the characters already in scrollback were counted as screen
;; columns and every click on row 0 was reported to the child that far to the
;; right.  It now shares `cooked--screen-cell' with the rest of the file, which
;; measures from the marker in exactly that case.
(ert-deftest cooked-mouse-columns-are-measured-from-the-seam-not-the-line ()
  (cooked-tests--with-straddling-line
    (let ((head (cooked-grid-head cooked--grid))
          (start (cooked--screen-start-position)))
      ;; The arrangement the bug needs: row 0 continues a line whose beginning is
      ;; already in the scrollback, so the marker sits mid-line.
      (should (> head 0))
      (should (> start (save-excursion (goto-char start) (line-beginning-position))))
      ;; Three columns into row 0 is column 3, not 3 + head.
      (let ((cell (cooked--screen-cell (+ start 3))))
        (should (equal cell '(0 . 3)))))))

;; Regression: every command that reached the native core did so with whatever
;; `cooked--session' happened to hold.  `cooked--on-exit' clears it without
;; touching the keymap, so after the child exits the raw map is still installed
;; and each of these resolved to a native call on nil -- reported to the user as
;; `wrong-type-argument user-ptrp nil' rather than as the session being over.
(ert-deftest cooked-commands-refuse-politely-once-the-child-is-gone ()
  (with-temp-buffer
    (cooked-mode)
    (setq cooked--session nil)
    (dolist (command '(cooked-send-eof cooked-interrupt cooked-suspend))
      (let ((result (condition-case err (progn (funcall command) 'no-error)
                      (user-error (cadr err))
                      (error (list 'wrong-error err)))))
        (should (equal result "No live session"))))))

;; The pending input is not thrown away by a C-c that could not be delivered.
(ert-deftest cooked-a-refused-interrupt-keeps-the-pending-input ()
  (with-temp-buffer
    (cooked-mode)
    ;; No session, so no wake pipe and no process mark to put the near edge on;
    ;; stand one in, since what is under test is that a refused interrupt leaves
    ;; the region alone rather than where the region happens to live.
    (setq cooked--session nil
          cooked--wake (make-pipe-process :name "cooked-test-mark"
                                          :buffer (current-buffer)
                                          :noquery t
                                          :sentinel #'ignore :filter #'ignore)
          cooked--input-end (copy-marker (point-min)))
    (cooked--set-input-mark (point-min))
    (unwind-protect
        (progn
          (should-error (cooked-interrupt) :type 'user-error)
          (should (cooked--input-start-position))
          (should cooked--input-end))
      (delete-process cooked--wake))))

(ert-deftest cooked-mode-map-carries-cookeds-own-commands ()
  "Peeking installs `cooked-peek-map', a child of `cooked-mode-map' with none
of the state maps' forwarding -- so cooked's own commands have to live on the
parent, not just in `cooked-raw-map'/`cooked-alt-map'/`cooked-input-map', or
they would evaporate while peeking."
  (dolist (binding '(("C-c C-c" . cooked-interrupt)
                      ("C-c C-d" . cooked-send-eof)
                      ("C-c C-e" . cooked-send-string)
                      ("C-c M-x" . execute-extended-command)
                      ("C-c C-z" . cooked-suspend)
                      ("C-c C-y" . cooked-paste)
                      ("C-c C-q" . cooked-send-literal-key)
                      ("C-c <escape>" . cooked-send-escape)
                      ("C-c ESC ESC" . cooked-send-escape)
                      ("C-c C-v" . cooked-toggle-peek)
                      ("C-c C-p" . cooked-previous-command)
                      ("C-c C-n" . cooked-next-command)
                      ("C-c TAB" . cooked-toggle-fold)
                      ("C-c C-l" . cooked-refresh)
                      ("C-c C-\\" . cooked-quit)
                      ("C-c M-o" . cooked-clear-scrollback)
                      ("C-c SPC" . cooked-newline)))
    (should (eq (lookup-key cooked-mode-map (kbd (car binding))) (cdr binding)))))

(defun cooked-tests--comint-c-c-keys ()
  "Every key sequence `comint-mode-map' binds under the `C-c' prefix."
  (let (keys)
    (letrec ((walk (lambda (map prefix)
                     (map-keymap
                      (lambda (event def)
                        (let ((key (vconcat prefix (vector event))))
                          (if (keymapp def)
                              (funcall walk def key)
                            (push key keys))))
                      map))))
      (funcall walk (lookup-key comint-mode-map (kbd "C-c")) (kbd "C-c")))
    keys))

(ert-deftest cooked-no-c-c-key-reaches-a-comint-command-that-needs-a-process ()
  "cooked has no Emacs process object for the child, so every comint command
that works through `process-mark' is either meaningless here or actively
destructive -- `comint-clear-buffer' erases the live screen region, and
`comint-quit-subjob' would `quit-process' the wakeup pipe.

Walking `comint-mode-map' rather than a fixed list is deliberate: a future
Emacs that adds a `C-c' binding to comint fails here on upgrade, instead of
shipping a key that silently does the wrong thing."
  (dolist (map (list cooked-raw-map cooked-alt-map cooked-input-map cooked-peek-map))
    (dolist (key (cooked-tests--comint-c-c-keys))
      (let ((binding (lookup-key map key)))
        (when (and binding (symbolp binding))
          (should-not
           (memq binding '(comint-quit-subjob comint-clear-buffer comint-accumulate))))))))

(ert-deftest cooked-the-input-mark-is-the-process-mark ()
  "One marker, not two kept in step: the near edge of the input region *is*
`process-mark', which is what makes comint's own commands correct here rather
than merely non-erroring."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'ready$ '; exec cat")
    (should (cooked-tests--settle #'cooked--input-start-position))
    (let ((proc (get-buffer-process (current-buffer))))
      (should proc)
      (should (comint-after-pmark-p))
      (should (= (cooked--input-start-position) (marker-position (process-mark proc))))
      ;; and still agreeing after the region has moved under typing
      (goto-char cooked--input-end)
      (insert "echo hi")
      (should (= (cooked--input-start-position) (marker-position (process-mark proc)))))))

(ert-deftest cooked-eof-follows-the-tty-too ()
  "`stty eof ^X' is as real as `stty intr ^X'.  EOF is not a signal, so it has
no ISIG half and nothing to fall back to -- but which byte to send is still the
tty's to say, not ours to assume."
  (cooked-tests--with-session '("/bin/sh" "-c" "exec cat")
    (cooked-tests--pump 0.4)
    (should (= (cooked--eof-byte) ?\C-d)))
  (cooked-tests--with-session '("/bin/sh" "-c" "stty eof ^X; exec cat")
    (cooked-tests--pump 0.6)
    (should (= (plist-get (cooked--job-control cooked--session) :eof) ?\C-x))
    (should (= (cooked--eof-byte) ?\C-x)))
  ;; Disabled: nothing to read, so the conventional byte beats sending nothing.
  (cooked-tests--with-session '("/bin/sh" "-c" "stty eof undef; exec cat")
    (cooked-tests--pump 0.6)
    (should-not (plist-get (cooked--job-control cooked--session) :eof))
    (should (= (cooked--eof-byte) ?\C-d))))

(ert-deftest cooked-job-control-follows-the-tty-not-a-hardcoded-signal ()
  "A terminal writes the character in `c_cc' and lets the line discipline
decide; it does not send a signal.  Reading that character is what makes
`stty intr ^X' work at all."
  (cooked-tests--with-session '("/bin/sh" "-c" "stty intr ^X; exec cat")
    (cooked-tests--pump 0.6)
    (let ((jc (cooked--job-control cooked--session)))
      (should (plist-get jc :isig))
      (should (= (plist-get jc :intr) ?\C-x))))
  ;; ISIG cleared: the byte would reach the child verbatim, so there is nothing to
  ;; write that means "interrupt" and the signal is the honest fallback.
  (cooked-tests--with-session '("/bin/sh" "-c" "stty -isig; exec cat")
    (cooked-tests--pump 0.6)
    (should-not (plist-get (cooked--job-control cooked--session) :isig)))
  ;; A disabled character has no byte at all.
  (cooked-tests--with-session '("/bin/sh" "-c" "stty intr undef; exec cat")
    (cooked-tests--pump 0.6)
    (should-not (plist-get (cooked--job-control cooked--session) :intr))))

(ert-deftest cooked-toggle-peek-does-not-lose-cookeds-own-commands ()
  "Regression: peeking used to install a bare `cooked-mode-map' with none of
cooked's own C-c-prefixed commands, so `C-c C-c'/`C-c C-v' and the rest were
unreachable until you left peek again -- including the toggle back out,
which left non-evil users stuck with no keyboard way out of peek at all."
  (cooked-tests--with-echoing-child ""
    (call-interactively #'cooked-toggle-peek)
    (should (eq (key-binding (kbd "C-c C-c")) #'cooked-interrupt))
    (should (eq (key-binding (kbd "C-c C-v")) #'cooked-toggle-peek))
    (should (eq (key-binding (kbd "C-c C-y")) #'cooked-paste))
    (call-interactively #'cooked-toggle-peek)
    (should-not (cooked--suspended-p))))

(ert-deftest cooked-send-string-and-send-literal-keys-refuse-at-a-prompt ()
  "Both write to the child out of band; doing that while Emacs owns the line
would arrive ahead of whatever pending input is still sitting unsent in the
buffer, so both refuse there rather than silently confusing the two."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '$ '; cat")
    (should (cooked-tests--settle
             (lambda () (and (cooked--input-state-p) (cooked--input-start-position)))))
    (cooked--refresh-keymap)
    (should-error (cooked-send-string "ls") :type 'user-error)
    (cl-letf (((symbol-function 'read-key) (lambda (&rest _) ?a)))
      (should-error (call-interactively #'cooked-send-literal-key) :type 'user-error))
    (should-error (call-interactively #'cooked-send-escape) :type 'user-error)))

(ert-deftest cooked-mouse-grab-is-suspended-while-peeking ()
  "A click during peek should select text like any other buffer's, not be
reinterpreted as a mouse report to a child that still owns the keyboard as
far as `cooked--input-state-p' alone can tell."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\033[?1000h\\033[?1006h'; stty raw -echo; cat -v")
    (should (cooked-tests--settle
             (lambda () (and (cooked-mouse-state-enabled cooked--mouse-state)
                       (not (cooked--input-state-p))))))
    (should cooked--mouse-grab)
    (call-interactively #'cooked-toggle-peek)
    (should-not cooked--mouse-grab)
    (call-interactively #'cooked-toggle-peek)
    (should cooked--mouse-grab)))

;;;; Re-entrancy, attention and the state that outlives the child
;;
;; What 0b288bc opened up by decoupling `cooked--frozen-p' from
;; `cooked--input-mode': drains that could nest inside `cooked--apply', a
;; minibuffer that read as walking away, and a suspended buffer whose child
;; exited under it.

(ert-deftest cooked-a-drain-inside-a-drain-is-folded-into-the-outer-one ()
  "`cooked--apply' decides what is following, and where point has wandered to,
before it rewrites the screen; a drain that starts in the middle of one leaves
it finishing against an update two drains stale.  It can: `cooked--set-alt',
`cooked--set-mode' and an OSC 133 mark all refresh the keymap from inside the
apply, and a refresh that lifts a freeze drains to catch up.

The nested request is made here rather than waited for, so the assertion is
about the guard and not about a race: what a refresh does mid-apply is exactly
this call."
  (cooked-tests--with-echoing-child ""
    (let ((depth 0) (deepest 0) (applies 0) (nested nil))
      (cl-letf* ((apply-fn (symbol-function 'cooked--apply))
                 ((symbol-function 'cooked--apply)
                  (lambda (update)
                    (setq depth (1+ depth)
                          applies (1+ applies)
                          deepest (max deepest depth))
                    (unwind-protect
                        (progn
                          (unless nested
                            (setq nested t)
                            (cooked--drain-and-apply))
                          (funcall apply-fn update))
                      (setq depth (1- depth))))))
        (cooked--drain-and-apply))
      (should (= deepest 1))
      ;; Folded, not dropped: the request is honoured once the outer drain is
      ;; done with the buffer.
      (should (= applies 2)))))

(ert-deftest cooked-reaching-for-the-minibuffer-is-not-walking-away ()
  "A freeze lifts when the user stops looking, and `M-x' is not that.  The
mini-window being the selected one made every command prompt -- `M-x', `C-x b',
evil's `:' -- thaw a peek out from under someone still reading it."
  (cooked-tests--with-echoing-child ""
    (switch-to-buffer (current-buffer))
    ;; Nothing in the way: with no minibuffer active this is the ordinary answer.
    (should (eq (cooked--user-window) (selected-window)))
    (call-interactively #'cooked-toggle-peek)
    (setq cooked--attention 'here)
    (should (cooked--frozen-p))
    (let ((buffer (current-buffer))
          (mini (minibuffer-window)))
      (cl-letf (((symbol-function 'selected-window) (lambda () mini))
                ((symbol-function 'minibuffer-selected-window)
                 (lambda () (get-buffer-window buffer t))))
        (cooked--update-attention)))
    (should (eq cooked--attention 'here))
    (should (cooked--frozen-p))))

(ert-deftest cooked-a-child-that-exits-while-suspended-hands-the-buffer-back ()
  "`cooked--on-exit' used to clear the session without touching the keymap, so a
child that died while the buffer was peeked left it read-only under
`cooked-peek-map' -- and nothing was left that could thaw it."
  (cooked-tests--with-session '("/bin/sh" "-c" "stty raw -echo; sleep 0.2; exit 3")
    (should (cooked-tests--settle (lambda () (eq cooked--mode 'raw))))
    (call-interactively #'cooked-toggle-peek)
    (should buffer-read-only)
    (should (cooked-tests--settle
             (lambda () (string-match-p "\\[exited 3\\]" (cooked-tests--text)))))
    (should-not cooked--session)
    (should-not cooked--input-mode)
    (should-not cooked--peek-explicit)
    (should-not buffer-read-only)))

(ert-deftest cooked-evil-normal-state-does-not-outlive-the-child ()
  "The same for the state an evil user is actually in: normal state is
read-only while the child owns the keyboard, and there is no child to own it
once it has exited."
  :tags '(evil)
  (skip-unless (require 'evil nil t))
  (require 'cooked-evil)
  (evil-mode 1)
  (cooked-tests--with-session '("/bin/sh" "-c" "stty raw -echo; sleep 0.2; exit 0")
    (should (cooked-tests--settle (lambda () (eq cooked--mode 'raw))))
    (evil-normal-state)
    (should buffer-read-only)
    (should (cooked-tests--settle
             (lambda () (string-match-p "\\[exited 0\\]" (cooked-tests--text)))))
    (should-not cooked--input-mode)
    (should-not buffer-read-only)))

(ert-deftest cooked-a-quiet-refresh-stays-quiet-through-a-nested-one ()
  "QUIET says \"evil asked for this, do not tell evil about it\".  It used to
hold for one frame only, so a refresh nested inside it -- a drain's own
`cooked--set-mode' -- ran `cooked-state-change-hook' after all, and
`cooked-evil-sync' put the user back into emacs state a keystroke after they
left it."
  (cooked-tests--with-echoing-child ""
    (let* ((runs 0)
           (nested nil)
           (cooked-state-change-hook (list (lambda () (setq runs (1+ runs)))))
           (cooked-input-mode-functions
            (list (lambda ()
                    ;; Where a nested refresh comes from in the real thing.
                    (unless nested
                      (setq nested t)
                      (cooked--refresh-keymap))
                    nil))))
      (cooked--refresh-keymap t)
      (should nested)
      (should (= runs 0))
      ;; And a loud one still announces a change of ownership -- which is the
      ;; only thing the hook has ever claimed to be about; see
      ;; `cooked-state-change-hook'.
      (setq nested t)
      (cooked--set-mode 'cooked)
      (should (cooked--input-state-p))
      (should (= runs 1)))))

(ert-deftest cooked-a-refresh-only-clears-the-read-only-it-set-itself ()
  "Suspending makes the buffer read-only; `read-only-mode' makes it read-only
for reasons of its own, and a refresh that wrote the flag unconditionally
threw the second away on the next state change."
  (cooked-tests--with-echoing-child ""
    (should-not buffer-read-only)
    (read-only-mode 1)
    (cooked--refresh-keymap)
    (should buffer-read-only)
    (read-only-mode -1)
    ;; Ours is still ours, and still lifts.
    (call-interactively #'cooked-toggle-peek)
    (should buffer-read-only)
    (call-interactively #'cooked-toggle-peek)
    (should-not buffer-read-only)))

(ert-deftest cooked-a-second-window-is-not-caught-up-while-suspended ()
  "A window other than the selected one is caught up by `set-window-point' on
every drain, which is what keeps it from freezing where it last pointed.  While
the buffer is suspended that is the one thing it must not do: the user is
reading, and the render carrying on underneath them is precisely what
suspending exists to hold still.  Asserted on the call rather than on the
resulting position, which a redraw moves on its own by rewriting the rows the
marker sits in."
  (cooked-tests--with-echoing-child ""
    (switch-to-buffer (current-buffer))
    (let ((other (split-window))
          (caught 0))
      (unwind-protect
          (cl-letf* ((set-point (symbol-function 'set-window-point))
                     ((symbol-function 'set-window-point)
                      (lambda (window position)
                        (when (eq window other) (setq caught (1+ caught)))
                        (funcall set-point window position))))
            (set-window-buffer other (current-buffer))
            (set-window-point other (point-max))
            (setq caught 0)
            (call-interactively #'cooked-toggle-peek)
            ;; Suspended, but still drawing: the freeze lifts for a buffer the
            ;; user is not looking at, which is what makes the drain below land.
            (setq cooked--attention 'away)
            (cooked--send-to-child "one")
            (should (cooked-tests--settle
                     (lambda () (string-search "one" (cooked-tests--text)))))
            (should (= caught 0))
            ;; And it is caught up again the moment forwarding resumes.
            (call-interactively #'cooked-toggle-peek)
            (cooked--send-to-child "two")
            (should (cooked-tests--settle
                     (lambda () (string-search "two" (cooked-tests--text)))))
            (should (> caught 0)))
        (delete-window other)))))

(ert-deftest cooked-the-state-change-hook-fires-only-when-ownership-changes ()
  "The hook means \"who owns the keyboard changed\", and used to run for every
refresh: a `raw'<->`alt' transition, a deliberate peek, and every termios poll
that moved `cooked--mode' between two states the child owns either way."
  (cooked-tests--with-echoing-child ""
    (let* ((runs 0)
           (cooked-state-change-hook (list (lambda () (setq runs (1+ runs))))))
      ;; The child owns the keyboard throughout all of this: on the alternate
      ;; screen the policy is `alt' whatever the line discipline is doing, which
      ;; is exactly the case a full-screen program spends its life in.
      (cooked--set-alt t)
      (cooked--set-mode 'cooked)
      (cooked--set-mode 'raw)
      (call-interactively #'cooked-toggle-peek)
      (call-interactively #'cooked-toggle-peek)
      (cooked--set-alt nil)
      (should (= runs 0))
      ;; A real change is still announced.
      (cooked--set-mode 'cooked)
      (setq cooked--semantic 'input)
      (cooked--refresh-keymap)
      (should (cooked--input-state-p))
      (should (= runs 1)))))

(ert-deftest cooked-evil-normal-state-survives-the-child-touching-its-termios ()
  "`V' in normal state stopped starting a selection on the alternate screen.
Every refresh ran `cooked-state-change-hook', `cooked-evil-sync' answered it by
putting evil into `cooked-evil-child-state', and a full-screen program changes
its termios settings routinely -- so a keystroke after `C-z' the user was back
in emacs state, where `V' is forwarded to the child like any other key."
  :tags '(evil)
  (skip-unless (require 'evil nil t))
  (require 'cooked-evil)
  (evil-mode 1)
  (cooked-tests--with-session
      '("/bin/sh" "-c" "stty raw -echo; printf '\033[?1049h'; cat")
    (should (cooked-tests--settle (lambda () cooked--alt)))
    ;; The child took the keyboard, so evil is where it belongs for a TUI.
    (should (eq evil-state 'emacs))
    (evil-normal-state)
    (should (eq (key-binding "V") #'evil-visual-line))
    (cooked--set-mode 'cooked)
    (cooked--set-mode 'raw)
    (should (eq evil-state 'normal))
    (should (eq cooked--input-mode 'still))
    (should (eq (key-binding "V") #'evil-visual-line))
    ;; And a selection, once started, is not dropped by the next poll either.
    (evil-visual-state)
    (should (eq cooked--input-mode 'frozen))
    (cooked--set-mode 'cooked)
    (should (eq evil-state 'visual))
    (should (eq cooked--input-mode 'frozen))))

(ert-deftest cooked-c-z-out-of-a-full-screen-program-lands-in-normal-state ()
  "`C-z' is `evil-exit-emacs-state', which returns to whatever state the user
was in when the child took the keyboard -- insert state, if they were typing at
a prompt, which is the ordinary way to start a program.  Insert state forwards
through `cooked-semi-map', so `C-z' appeared to do nothing at all: every key,
\\`V' included, still went to the child.  Normal state is where `C-z' has to
land, and the insert state being remembered belonged to a prompt that is no
longer on screen."
  :tags '(evil)
  (skip-unless (require 'evil nil t))
  (require 'cooked-evil)
  (evil-mode 1)
  (cooked-tests--with-session
      '("/bin/sh" "-c" "sleep 0.3; stty raw -echo; printf '\033[?1049h'; cat")
    (should (cooked-tests--settle (lambda () (cooked--input-state-p))))
    ;; Typing at the prompt, which is where a program gets started from.
    (evil-insert-state)
    (should (eq evil-state 'insert))
    (should (cooked-tests--settle (lambda () cooked--alt)))
    ;; The child took the keyboard, so evil is in emacs state for it.
    (should (eq evil-state 'emacs))
    (call-interactively (key-binding (kbd "C-z")))
    (should (eq evil-state 'normal))
    (should (eq cooked--input-mode 'still))
    (should (eq (key-binding "V") #'evil-visual-line))
    ;; And the way back in is unchanged.
    (call-interactively (key-binding (kbd "C-z")))
    (should (eq evil-state 'emacs))
    (should-not cooked--input-mode)))

(ert-deftest cooked-a-drain-leaves-nothing-of-the-output-in-the-undo-history ()
  "The bug this whole seam exists for: every drain deletes and reinserts the rows
it redraws, and recording that used to grow `buffer-undo-list' until Emacs
warned that `undo-outer-limit' had discarded megabytes of it.  A command that
prints two hundred lines is two hundred rows of churn, and none of it is the
user's to undo -- so what is left afterwards is the empty history the anchor
reset leaves behind, anchored at the new prompt."
  :tags '(zsh)
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-zsh
    (let ((before (length cooked--commands)))
      (cooked--replace-input "seq 1 200")
      (cooked-send-input)
      (should (cooked-tests--settle
               (lambda () (> (length cooked--commands) before)) 8)))
    (should (cooked-tests--settle
             (lambda () (and (eq cooked--semantic 'input)
                             (cooked--input-start-position)))
             8))
    (should (string-search "200" (cooked-tests--text)))
    (should-not (cooked-tests--undo-entries))
    (should (eql cooked--undo-anchor (cooked--input-start-position)))))

(ert-deftest cooked-a-drain-with-no-input-line-records-nothing-and-discards-nothing ()
  "A full-screen program has no input region at all, so there is no anchor to
compare and nothing that could be said to have moved -- and a drain must still
be silent, which is the half `cooked--check-undo-anchor' cannot demonstrate:
with the anchor nil at both ends, a history that survived unchanged proves the
rows were never recorded in the first place.  Twice, because the second drain is
where an anchor of nil comparing unequal to itself would show up."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\033[?1049h'; stty raw -echo; exec cat")
    (should (cooked-tests--settle (lambda () cooked--alt)))
    (should-not (cooked--input-start-position))
    (should-not cooked--undo-anchor)
    (let ((sentinel (list (cons 1 2))))
      (setq buffer-undo-list sentinel)
      (cooked--send-to-child (make-string 200 ?x))
      (should (cooked-tests--settle (lambda () (string-search "xxx" (cooked-tests--text)))))
      (cooked--drain-and-apply)
      (cooked--drain-and-apply)
      (should-not cooked--undo-anchor)
      ;; `eq', not `equal': nothing was consed onto it and nothing replaced it.
      (should (eq buffer-undo-list sentinel)))))

(ert-deftest cooked-undo-at-a-prompt-takes-back-the-line-and-nothing-above-it ()
  "What undo is scoped to, stated from the user's side: the typed line goes and
the transcript above it -- which no history entry has ever named -- is untouched."
  :tags '(zsh)
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-zsh
    (cooked-tests--display-buffer)
    (cooked-tests--type "e c h o SPC h i")
    (should (equal "echo hi" (cooked--pending-input)))
    (let ((above (buffer-substring-no-properties
                  (point-min) (cooked--input-start-position))))
      (undo-boundary)
      (undo)
      (should (equal "" (cooked--pending-input)))
      (should (equal above (buffer-substring-no-properties
                            (point-min) (cooked--input-start-position)))))))

(ert-deftest cooked-undo-turned-off-by-the-user-stays-off-across-a-drain ()
  "`t' is a decision, not an empty history: a buffer where undo was turned off
must come out of a drain -- and out of the anchor reset inside it -- still off,
since nil there would be switching it back on for them."
  :tags '(zsh)
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-zsh
    (setq buffer-undo-list t)
    (let ((before (length cooked--commands)))
      (cooked--replace-input "seq 1 50")
      (cooked-send-input)
      (should (cooked-tests--settle
               (lambda () (> (length cooked--commands) before)) 8)))
    (should (cooked-tests--settle
             (lambda () (and (eq cooked--semantic 'input)
                             (cooked--input-start-position)))
             8))
    (should (eq buffer-undo-list t))))

(ert-deftest cooked-a-discard-takes-what-was-pointing-into-the-history-with-it ()
  "Half-undone is the dangerous state: `pending-undo-list' is a cons inside the
list and `undo-more' walks it without ever consulting the list again, so a drain
that emptied the list and left the pointer would have the next `C-/' of a run in
progress undoing entries about text that has moved.  evil's own pointer goes the
same way and for the same reason."
  :tags '(zsh)
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-zsh
    (cooked--replace-input "hello")
    (undo-boundary)
    (should (cooked-tests--undo-entries))
    (setq pending-undo-list buffer-undo-list)
    (when (boundp 'evil-undo-list-pointer)
      (setq evil-undo-list-pointer buffer-undo-list))
    (cooked--discard-undo)
    (should-not buffer-undo-list)
    (should-not pending-undo-list)
    (when (boundp 'evil-undo-list-pointer)
      (should-not evil-undo-list-pointer))
    ;; Locally, so that a drain running from a process filter cannot cut short an
    ;; undo run in whatever buffer the user was actually in.
    (should (local-variable-p 'pending-undo-list))
    (should-not (default-value 'pending-undo-list))))

(ert-deftest cooked-a-restarted-session-does-not-inherit-the-old-ones-history ()
  "`cooked--start' erases the buffer, and a second session in it puts the new
prompt at the same position the old one held -- the one movement the anchor
cannot see, which would leave the previous session's entries vouched for and
pointing into text that no longer exists."
  (with-temp-buffer
    (cooked-mode)
    (cooked--start '("/bin/sh" "-c" "exec sleep 5"))
    (unwind-protect
        (progn
          (setq buffer-undo-list (list (cons 1 2))
                cooked--undo-anchor 1)
          (cooked--start '("/bin/sh" "-c" "exec sleep 5"))
          (should-not cooked--undo-anchor)
          (should-not (cooked-tests--undo-entries)))
      (cooked--cleanup))))

(ert-deftest cooked-refresh-does-not-leave-entries-against-the-screen-it-rebuilt ()
  "`cooked-refresh' throws the whole screen region away and has the child re-send
it.  The prompt lands back where it was, so the next drain's anchor check sees
nothing move -- while every entry recorded before it names text that has been
deleted and rebuilt underneath."
  :tags '(zsh)
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-zsh
    (cooked--replace-input "hello")
    (should (cooked-tests--undo-entries))
    (cooked-refresh)
    (should-not (cooked-tests--undo-entries))
    (should (cooked-tests--settle
             (lambda () (and (eq cooked--semantic 'input)
                             (cooked--input-start-position)))
             8))))

(ert-deftest cooked-thawing-a-frozen-alt-exit-leaves-the-undo-anchor-honest ()
  "`cooked--refresh-keymap' has exactly one `cooked--clear-input-region' call of
its own, right at the end, with no `cooked--check-undo-anchor' next to it.
Every site that can make that call do something -- move the tracked start from
a real position to nowhere -- runs inside `cooked--apply', bracketed by exactly
one `cooked--check-undo-anchor' after `cooked--with-child-edit' unwinds; a
frozen peek is the one place a transition can be *seen* outside that bracket,
since the drain reporting it is deferred rather than dropped -- but the nested
`cooked--drain-and-apply' this function makes on the way out of `frozen' pays
for that deferral with the very same guarantee, run before this function's own
call. So by the time it runs, a transition made visible only by thawing has
already been reconciled, and this function's own call has nothing left to do.

Proven the sharp way: freeze while an alt-screen program is up, feed the child
the bytes that leave alt while the freeze hides them from the drain that would
otherwise apply immediately, then thaw with a second `cooked-toggle-peek' --
the same call `cooked--resume-forwarding' makes.  If the reasoning above were
wrong, the anchor would be left naming the alt-screen position while the start
moved back to a real prompt out from under it, and either the discard would be
skipped when it was owed or a real prompt's own history would go with it."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "read a; printf '\\033[?1049h'; read b; printf '\\033[?1049l\\n$ '; exec cat")
    (should (cooked-tests--settle
             (lambda () (and (eq cooked--mode 'cooked) (cooked--input-start-position)))))
    (cooked--send-to-child "a\n")
    (should (cooked-tests--settle (lambda () cooked--alt)))
    (call-interactively #'cooked-toggle-peek)
    (should (cooked--frozen-p))
    (cooked--send-to-child "b\n")
    ;; Frozen, so the process filter's own drain is skipped and this sits
    ;; undrained -- `cooked-tests--pump', not `cooked-tests--settle', which
    ;; would force the very drain being deferred.
    (cooked-tests--pump 0.3)
    (should cooked--alt)
    (call-interactively #'cooked-toggle-peek)
    (should (cooked-tests--settle (lambda () (not cooked--alt))))
    (should (cooked--input-state-p))
    (should-not (cooked-tests--undo-entries))
    (should (eql cooked--undo-anchor (cooked--input-start-position)))))

(ert-deftest cooked-evil-u-at-a-prompt-undoes-the-line-and-says-so-elsewhere ()
  "\\`u' is scoped like the history it drives.  At a prompt it is evil's own undo
over the line being typed; over a full-screen program there is nothing of the
user's on screen, and plain `evil-undo' -- `(interactive \"*p\")' -- answers
\"Buffer is read-only\" there, which is a fact about the buffer and not about the
undo.  The read-only comes from `cooked-evil-normal-state-render' being `still',
which is the default, so this is what a user meets."
  :tags '(evil zsh)
  (skip-unless (require 'evil nil t))
  (skip-unless (executable-find "zsh"))
  (require 'cooked-evil)
  (evil-mode 1)
  (cooked-tests--with-zsh
    (cooked-tests--display-buffer)
    (cooked-tests--type "e c h o SPC h i")
    (should (equal "echo hi" (cooked--pending-input)))
    (evil-normal-state)
    (should (eq (key-binding "u") #'cooked-evil-undo))
    (let ((above (buffer-substring-no-properties
                  (point-min) (cooked--input-start-position))))
      (undo-boundary)
      ;; Through the command loop: an unexpected signal out of here is the bug.
      (cooked-tests--type "u")
      (should (equal "" (cooked--pending-input)))
      (should (equal above (buffer-substring-no-properties
                            (point-min) (cooked--input-start-position))))
      (should (evil-normal-state-p)))))

(ert-deftest cooked-evil-visual-u-over-the-childs-text-reports-and-stays-put ()
  "\\`u' in visual state is `evil-downcase', not undo, and `downcase-region' over
a rendered row signals -- out of visual state, which is the failure
`cooked-evil--command-range' documents: no `post-command-hook' runs after a
command that signalled, so evil is left believing in a selection nothing will
reconcile and the next \\`v' leaves visual state instead of entering it.
Reporting and returning leaves the selection standing, the text alone, and the
state something the user can still see out of."
  :tags '(evil zsh)
  (skip-unless (require 'evil nil t))
  (skip-unless (executable-find "zsh"))
  (require 'cooked-evil)
  (evil-mode 1)
  (cooked-tests--with-zsh
    (let ((before (length cooked--commands)))
      (cooked--replace-input "echo ALPHA")
      (cooked-send-input)
      (should (cooked-tests--settle
               (lambda () (> (length cooked--commands) before)) 8)))
    (should (cooked-tests--settle
             (lambda () (and (eq cooked--semantic 'input)
                             (cooked--input-start-position)))
             8))
    (cooked-tests--display-buffer)
    (let ((record (car cooked--commands))
          (text (cooked-tests--text)))
      (goto-char (car (cooked--command-region record)))
      (should (string-search "ALPHA" (buffer-substring-no-properties
                                      (line-beginning-position)
                                      (line-end-position))))
      (evil-normal-state)
      (dolist (key '("u" "U" "~"))
        (cooked-tests--type (concat "v " key))
        (should (evil-visual-state-p))
        (should (equal text (cooked-tests--text)))
        (cooked-tests--type "ESC")))
    ;; And the line being typed is still ordinary editable text, where the same
    ;; three keys mean what they mean anywhere else.
    (goto-char (cooked--input-start-position))
    (cooked--replace-input "ALPHA")
    (goto-char (cooked--input-start-position))
    (evil-normal-state)
    (cooked-tests--type "v $ u")
    (should (equal "alpha" (cooked--pending-input)))))

(ert-deftest cooked-a-path-is-one-word-through-both-chains ()
  "Asserted through `thing-at-point' *and* `mouse-start-end', which disagree.

Stolen wholesale from ghostel, and the discipline is the point rather than the
two functions: a double-click does not go through `thing-at-point' at all.  It
goes through `mouse-start-end' with a click count of 1, which classifies by
syntax class directly and has its own rules about which classes extend.  A
syntax table that satisfies one and not the other is the normal way to get this
half right and ship it broken."
  (with-temp-buffer
    (set-syntax-table cooked-mode-syntax-table)
    (dolist (subject '("~/src/foo/bar.txt" "api.example.com" "a-b_c.d" "/etc/passwd"
                       ;; A URL's query and fragment, a login, and a file name
                       ;; with a `+': everything past the scheme's colon, which
                       ;; stays a boundary.
                       "//api.example.com/v1/items?id=42&x=%20#frag"
                       "simon@host.example.com" "a+b.txt"))
      (erase-buffer)
      (insert "before " subject " after")
      (let ((beg (+ (point-min) (length "before ")))) 
        (goto-char (1+ beg))
        ;; The keyboard/programmatic chain.
        (should (equal (thing-at-point 'word t) subject))
        ;; The actual double-click chain: `mouse-start-end' with count 1.
        (pcase-let ((`(,from ,to) (mouse-start-end (point) (point) 1)))
          (should (equal (buffer-substring-no-properties from to) subject)))))))

(ert-deftest cooked-output-words-are-wide-and-prompt-words-are-narrow ()
  "A double-click in output takes a login whole; M-DEL at the prompt stops at `='.

One buffer holds both, because the two used to be one syntax table: widening
words for selection made \\[backward-kill-word] after `--author=simon' kill the
whole flag.  The input region now carries `cooked-input-syntax-table' as a
`syntax-table' property, and each way text gets into the region has to leave it
there: typing, which inherits nothing at the start of the line and is covered
before the next command runs; a drain, which lifts the line out and puts it
back; and history, which replaces it."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf 'mail simon@example.com\\n$ '; exec cat")
    (should (cooked-tests--settle
             (lambda () (and (string-match-p "example" (cooked-tests--text))
                             (cooked--input-start-position)))))
    (cl-flet ((kills-at-end ()
                (goto-char cooked--input-end)
                (let ((kill-ring nil))
                  (backward-kill-word 1)
                  (car kill-ring))))
      ;; Output: the wide words, through the double-click's own chain.
      (goto-char (point-min))
      (search-forward "simon@")
      (pcase-let ((`(,from ,to) (mouse-start-end (point) (point) 1)))
        (should (equal (buffer-substring-no-properties from to)
                       "simon@example.com")))
      ;; Typed, then the hook the command loop runs before M-DEL.
      (goto-char cooked--input-end)
      (insert "git log --author=simon")
      (run-hooks 'pre-command-hook)
      (should (equal (kills-at-end) "simon"))
      ;; A flag is still one word at the prompt, `=' going with it.
      (should (equal (kills-at-end) "--author="))
      ;; Across a drain.
      (cooked--replace-input "echo --author=simon")
      (cooked--drain-and-apply)
      (should (eq (get-text-property (cooked--input-start-position) 'syntax-table)
                  cooked-input-syntax-table))
      (should (equal (kills-at-end) "simon"))
      ;; From history.
      (cooked--replace-input "git log --author=simon")
      (cooked-send-input)
      (should (cooked-tests--settle (lambda () (cooked--input-region))))
      (cooked-previous-input)
      (should (equal (cooked--pending-input) "git log --author=simon"))
      (should (equal (kills-at-end) "simon"))
      ;; And the output is still wide after all of it.
      (goto-char (point-min))
      (search-forward "simon@")
      (pcase-let ((`(,from ,to) (mouse-start-end (point) (point) 1)))
        (should (equal (buffer-substring-no-properties from to)
                       "simon@example.com"))))))

(ert-deftest cooked-a-box-border-does-not-join-two-panes ()
  "A double-click in a two-pane TUI must not take the border with it.

Worth saying that this passes with `cooked-word-boundary-string' emptied, and
is kept anyway: box-drawing characters are *symbol* constituents in Emacs' own
table, so they already end a word and cooked is agreeing rather than fixing.
The test guards the outcome against a future default -- or a user's own wider
`cooked-word-constituent-string' -- quietly making furniture part of a word.
The next test is the one that pins cooked's own behaviour."
  (with-temp-buffer
    (set-syntax-table cooked-mode-syntax-table)
    (dolist (border '(?│ ?─ ?├ ?┼))
      (erase-buffer)
      (insert (format "left%cright" border))
      (goto-char (+ (point-min) 2))
      (should (equal (thing-at-point 'word t) "left"))
      (pcase-let ((`(,from ,to) (mouse-start-end (point) (point) 1)))
        (should (equal (buffer-substring-no-properties from to) "left"))))))

(ert-deftest cooked-a-boundary-beats-a-constituent ()
  "The ordering between the two customs, which is the only thing arbitrating them.

A character named in both strings must end up a boundary, or the defaults are a
trap: widening `cooked-word-constituent-string' would silently swallow
furniture, and there would be no way to take a character back once the
constituent set had claimed it.  `cooked--realize-syntax-table' gets this by
applying the boundaries second, and nothing else says so."
  (let ((constituents cooked-word-constituent-string)
        (boundaries cooked-word-boundary-string))
    (unwind-protect
        (with-temp-buffer
          (set-syntax-table cooked-mode-syntax-table)
          ;; `$', not a box-drawing character, and the reason is a finding in
          ;; its own right: `forward-word' consults
          ;; `find-word-boundary-function-table' as well as the syntax table,
          ;; and that inserts a boundary wherever the *script* changes.  U+2502
          ;; is a different script from `a', so it ends a word even when its
          ;; syntax class is `w' -- making the box-drawing half of
          ;; `cooked-word-boundary-string' doubly belt-and-braces, and making it
          ;; useless for demonstrating an ordering that is about syntax alone.
          (insert "a$b")
          (goto-char (point-min))
          ;; Claim it as a word constituent, with nothing taking it back.
          ;; Boundaries are cleared *first*: they are applied second and would
          ;; otherwise still be holding `$' from the default.
          (customize-set-variable 'cooked-word-boundary-string "")
          (customize-set-variable 'cooked-word-constituent-string "./~-_$")
          (should (equal (thing-at-point 'word t) "a$b"))
          ;; ...and naming it a boundary as well must take it straight back.
          (customize-set-variable 'cooked-word-boundary-string "$")
          (should (equal (thing-at-point 'word t) "a"))
          (pcase-let ((`(,from ,to) (mouse-start-end (point) (point) 1)))
            (should (equal (buffer-substring-no-properties from to) "a"))))
      (customize-set-variable 'cooked-word-constituent-string constituents)
      (customize-set-variable 'cooked-word-boundary-string boundaries))))

(ert-deftest cooked-a-boundary-customize-reaches-a-live-buffer ()
  "Realized into the table object, not rebuilt, or a preference means nothing.

A rebuilt table would be picked up by the *next* `cooked-mode', which is not
what changing a setting should mean.  The other half is that removing a
character has to work too -- that is what `cooked--syntax-overridden' is for,
and it is the half a naive in-place realization gets wrong."
  (let ((constituents cooked-word-constituent-string)
        (boundaries cooked-word-boundary-string))
    (unwind-protect
        (with-temp-buffer
          (set-syntax-table cooked-mode-syntax-table)
          (insert "a.b")
          (goto-char (point-min))
          (should (equal (thing-at-point 'word t) "a.b"))
          ;; Take `.' out of the constituents; this very buffer must follow.
          (customize-set-variable 'cooked-word-constituent-string "/~-_")
          (should (equal (thing-at-point 'word t) "a"))
          ;; And putting it back must restore it, rather than leaving `.'
          ;; stranded in whatever class the removal left behind.
          (customize-set-variable 'cooked-word-constituent-string "./~-_")
          (should (equal (thing-at-point 'word t) "a.b"))
          ;; Same for a boundary going away.
          (erase-buffer) (insert "a$b") (goto-char (point-min))
          (should (equal (thing-at-point 'word t) "a"))
          (customize-set-variable 'cooked-word-boundary-string "│")
          (should (equal (thing-at-point 'word t) "a$b")))
      (customize-set-variable 'cooked-word-constituent-string constituents)
      (customize-set-variable 'cooked-word-boundary-string boundaries))))

(ert-deftest cooked-a-plain-selection-freezes-the-render ()
  "cooked froze for evil's visual state and for nothing else.

So a plain \\[set-mark-command], a `consult-line' selection or a mouse drag
was clobbered by the next drain -- the case this covers, and the reason the
freeze cannot be evil's to own: the claim a selection makes about a region is
the same claim whatever put it there."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (should (cooked-tests--settle (lambda () cooked--session)))
    (should-not (eq cooked--input-mode 'frozen))
    (let ((transient-mark-mode t))
      (goto-char (point-min))
      (push-mark (point) t t)
      (goto-char (point-max))
      (should (use-region-p))
      ;; Driven through `cooked--track-selection' rather than asserted straight
      ;; off `use-region-p', because the wiring is the half that was missing:
      ;; the input mode is derived rather than latched, so it is only right as
      ;; often as something recomputes it, and `activate-mark-hook' fires while
      ;; the region is still empty.
      (cooked--track-selection)
      (should (eq cooked--input-mode 'frozen))
      (deactivate-mark)
      (cooked--track-selection)
      (should-not (eq cooked--input-mode 'frozen)))))

(ert-deftest cooked-selection-protection-can-be-switched-off ()
  "nil is the old behaviour, for anyone who only selects finished output."
  (let ((cooked-selection-render nil))
    (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
      (should (cooked-tests--settle (lambda () cooked--session)))
      (let ((transient-mark-mode t))
        (goto-char (point-min))
        (push-mark (point) t t)
        (goto-char (point-max))
        (should (use-region-p))
        (cooked--track-selection)
        (should-not (eq cooked--input-mode 'frozen))))))

(ert-deftest cooked-an-inactive-mark-is-not-a-selection ()
  "`use-region-p', not `mark-active'.

With `transient-mark-mode' off a mark is permanently active and is not a
selection anyone is looking at; freezing the render for it would freeze the
terminal for the rest of the session."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (should (cooked-tests--settle (lambda () cooked--session)))
    (let ((transient-mark-mode nil))
      (goto-char (point-min))
      (push-mark (point) t t)
      (goto-char (point-max))
      (should-not (use-region-p))
      (cooked--track-selection)
      (should-not (eq cooked--input-mode 'frozen)))))

(ert-deftest cooked-a-wheel-notch-is-one-press-and-a-trackpad-is-not ()
  "A trackpad tick is pixels; a notch is a notch.  Ported from ghostel.

With `mwheel-coalesce-scroll-events' nil -- which
`pixel-scroll-precision-mode' and ultra-scroll both set -- every tick arrives
as its own event carrying a pixel delta, and one report per event floods a child
that asked for mouse tracking with dozens of notches per row of travel."
  (with-temp-buffer
    (let ((cooked--scroll-pending 0.0)
          (mwheel-coalesce-scroll-events t))
      ;; Coalescing on: Emacs has already done the work, one event is one notch.
      (should (= (cooked--wheel-presses
                  '(wheel-down (nil 0 (0 . 0) 0 nil 0 nil nil (0 . 40)) 1 1 (0 . 40)))
                 1)))
    (let ((cooked--scroll-pending 0.0)
          (mwheel-coalesce-scroll-events nil)
          (line 20))
      (cl-letf (((symbol-function 'default-line-height) (lambda () line))
                ;; No `device-class', so the mouse guard does not fire and the
                ;; pixel path is taken -- which is what is under test.
                ((symbol-function 'device-class) nil))
        (fmakunbound 'device-class)
        ;; A sub-row tick reports nothing and is carried.
        (should (= (cooked--wheel-presses
                    '(wheel-down (nil 0 (0 . 0) 0 nil 0 nil nil (0 . 8)) 0 0 (0 . 8)))
                   0))
        (should (> cooked--scroll-pending 0))
        ;; Enough further travel to cross a row reports exactly once.
        (should (= (cooked--wheel-presses
                    '(wheel-down (nil 0 (0 . 0) 0 nil 0 nil nil (0 . 14)) 0 0 (0 . 14)))
                   1))
        ;; And the remainder is carried rather than lost or double-counted.
        (should (< cooked--scroll-pending line))))))

(ert-deftest cooked-a-notch-narrower-than-a-row-still-reports ()
  "macOS reports a notch as one line and fewer pixels than a row when
`line-spacing' is set, so the row arithmetic yields zero and the notch would
vanish.  The floor is the event's own line count, not a constant -- which is
what keeps a sub-row *trackpad* tick at zero while this reports once."
  (with-temp-buffer
    (let ((cooked--scroll-pending 0.0)
          (mwheel-coalesce-scroll-events nil))
      (cl-letf (((symbol-function 'default-line-height) (lambda () 20)))
        (fmakunbound 'device-class)
        ;; LINES 1, but only 12 pixels of a 20-pixel row.
        (should (= (cooked--wheel-presses
                    '(wheel-down (nil 0 (0 . 0) 0 nil 0 nil nil (0 . 12)) 1 1 (0 . 12)))
                   1))))))

(ert-deftest cooked-the-lone-esc-filter-wraps-once-and-composes ()
  "Wrapping is idempotent and does not discard what was already there.

Two details that look like paranoia and are not.  The entry is read with
`assq' rather than `lookup-key', because `lookup-key' resolves a
`menu-item' filter to the map behind it and would silently drop another
package's wrapper -- evil's, in the case that matters.  And ours is
recognised by its `:filter' symbol rather than by identity, because
`define-key' copies the list, so identity never matches and every call would
wrap again."
  (skip-unless (not (display-graphic-p)))
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (should (cooked-tests--settle (lambda () cooked--session)))
    (let ((entry (cdr (assq ?\e (cdr input-decode-map)))))
      (should (eq (car-safe entry) 'menu-item))
      (should (eq (cadr (memq :filter entry)) 'cooked--tty-esc))
      ;; Whatever was underneath is carried, not replaced.
      (let ((inner (nth 2 entry)))
        (cooked--tty-esc-init)
        (cooked--tty-esc-init)
        (let ((again (cdr (assq ?\e (cdr input-decode-map)))))
          (should (eq (cadr (memq :filter again)) 'cooked--tty-esc))
          ;; Still one deep: the inner entry is not another of ours.
          (should (equal (nth 2 again) inner)))))))

(ert-deftest cooked-the-lone-esc-filter-keeps-out-of-the-childs-way ()
  "ESC is how you leave insert mode in the vim inside the terminal.

The departure from ghostel, and the reason for it: a translation reaching the
child would be a bug nobody would connect to this setting.  Where Emacs owns the
line there is no such claim on the byte."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (should (cooked-tests--settle (lambda () cooked--session)))
    (let ((map '(keymap)))
      ;; Child reading the keyboard: the byte is the child's, untranslated.
      (cl-letf (((symbol-function 'cooked--child-owns-keyboard-p) (lambda () t)))
        (should (eq (cooked--tty-esc map) map)))
      ;; And switched off entirely, nothing is translated either.
      (cl-letf (((symbol-function 'cooked--child-owns-keyboard-p) (lambda () nil))
                (cooked-tty-escape-delay nil))
        (should (eq (cooked--tty-esc map) map))))))

(ert-deftest cooked-evil-does-not-blank-a-row-of-spaces ()
  "A whitespace-only line in a cooked buffer is a *screen row*, not slack.

Entering evil insert state hangs `evil-maybe-remove-spaces' on
`post-command-hook' and arms it; leaving calls it directly, and it deletes the
whitespace from a line holding nothing else.  In an ordinary buffer that is a
kindness.  Here the spaces are cells the child put there, so blanking them is
data loss -- the grid says eight columns and the buffer then says none, about a
row neither can re-derive.

Not a corner case: a frame of any picture is mostly blank rows, and it was found
by the first bench fixture to contain one."
  :tags '(evil)
  (skip-unless (require 'evil nil t))
  (require 'cooked-evil)
  (with-temp-buffer
    (delay-mode-hooks (cooked-mode))
    (insert "top\n        \nbot\n")
    (goto-char 6)
    (evil-local-mode 1)
    (evil-insert-state)
    (evil-normal-state)
    (should (equal (nth 1 (split-string (buffer-substring-no-properties
                                         (point-min) (point-max))
                                        "\n"))
                   "        "))))

(ert-deftest cooked-a-remote-password-prompt-is-caught-by-the-regex ()
  "The arm that reaches a child the termios probe cannot see.

`ssh -t host sudo ...' puts the *far* tty into secret mode; the local one this
session owns never changes, so the detector never fires and the password is
typed into the buffer in the clear.  Gated on the host being foreign, because
matching a regex against local output would false-positive on any program
displaying a file that mentions a password.  Remote means a foreign host, or
one of `cooked-password-remote-programs' in the foreground."
  ;; `sleep 5; :' rather than `sleep 5': a shell execs a lone last command, and
  ;; the foreground program then becomes `sleep' a moment after the start --
  ;; which made the `sh' gate below pass or fail on how soon the test got there.
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5; :")
    (should (cooked-tests--settle (lambda () cooked--session)))
    (erase-buffer)
    ;; What `ssh' and `sudo' actually print.  A prefix in front of the word --
    ;; `user@host password: ' -- is *not* matched by
    ;; `comint-password-prompt-regexp', which anchors the prompt, and using one
    ;; here tested the test rather than the code.
    (insert "simon@host's password: ")
    (goto-char (point-max))
    (cl-letf (((symbol-function 'cooked--cursor-position) (lambda () (point-max))))
      ;; Local: no regex is even attempted, and nothing is armed.  The session is
      ;; `sh\=', which is not a remote client.
      (cl-letf (((symbol-function 'cooked--foreign-host-p) (lambda () nil)))
        (should-not (cooked--secret-prompt-on-row-p))
        ;; A remote client in the foreground opens the gate with no OSC 7 at all,
        ;; which is `ssh -t host sudo …\='.
        (let ((cooked-password-remote-programs '("sh")))
          (should (cooked--secret-prompt-on-row-p))))
      ;; Foreign: caught.
      (cl-letf (((symbol-function 'cooked--foreign-host-p) (lambda () t)))
        (should (cooked--secret-prompt-on-row-p))
        ;; A row that is not a prompt is not caught, foreign or not.
        (erase-buffer)
        (insert "just some output about passwords in general")
        (should-not (cooked--secret-prompt-on-row-p))
        ;; And sudo's form, since the two shapes are what this is for.
        (erase-buffer)
        (insert "[sudo] password for simon: ")
        (should (cooked--secret-prompt-on-row-p))))))

(defmacro cooked-tests--with-remote-prompt (script &rest body)
  "Run BODY in a session whose SCRIPT stands in for a remote password prompt.

`/bin/sh' plays `ssh': it is named in `cooked-password-remote-programs' for
the duration, so the regex arm's gate opens exactly as it does for a real
`ssh -t host sudo …', and its `stty -icanon -echo' is the raw mode `ssh' puts
the local tty in.  `asked' counts the reads, answered through
`cooked-password-function' so that no `read-passwd' can block batch Emacs,
and the debounce is short so the real timer is what raises them."
  (declare (indent 1))
  `(let* ((asked 0)
          (cooked-password-function (lambda (_prompt) (setq asked (1+ asked)) "hunter2"))
          (cooked-password-remote-programs '("sh"))
          (cooked-secret-debounce 0.05))
     (cooked-tests--with-session (list "/bin/sh" "-c" ,script)
       ,@body)))

(ert-deftest cooked-a-remote-password-prompt-is-read-once-and-sent-once ()
  "The regex arm, end to end: rising edge, timer, read, send, and then quiet.

The prompt stays on the cursor row for a second after it is answered, which is
the round trip to a real far end drawn out, and every wait below forces a drain
while it does.  Each of those drains sees a remote child and a matching row, so
only the answered cell keeps the next one from reading the password again and
handing it to whatever the far end runs next.

Before the arm had edges it could not read at all: it scheduled a read that
declined because the tty was not in secret mode."
  (cooked-tests--with-remote-prompt
      "stty -icanon -echo; printf '[sudo] password for simon: '; read p; sleep 1; \
       if [ \"$p\" = hunter2 ]; then printf '\\nACCEPTED\\n'; else printf '\\nDENIED\\n'; fi; sleep 5"
    (should (cooked-tests--settle (lambda () (= asked 1))))
    (should (eq cooked--mode 'raw))
    ;; Still on the prompt row, and drained across the rest of the second.
    (should (cooked-tests--settle
             (lambda () (string-match-p "ACCEPTED" (cooked-tests--text)))))
    (should (= asked 1))
    (should-not (string-match-p "hunter2" (cooked-tests--text)))))

(ert-deftest cooked-a-remote-password-retry-at-the-foot-of-the-screen-is-asked-again ()
  "A retry that lands on the cell just answered is still a new prompt.

At the bottom of the screen, `Sorry, try again.' and the next prompt scroll the
answered one away and leave the cursor on the same (ROW . COL) it was on.  The
scroll is what says the line under that cell is a different one; without it the
retry is taken for the prompt already answered and never read."
  (cooked-tests--with-remote-prompt
      "stty -icanon -echo; i=0; while [ $i -lt 80 ]; do echo; i=$((i+1)); done; \
       printf '[sudo] password for simon: '; read p; sleep 0.5; \
       printf '\\nSorry, try again.\\n[sudo] password for simon: '; read q; sleep 0.5; \
       printf '\\nDONE\\n'; sleep 5"
    (should (cooked-tests--settle
             (lambda () (string-match-p "DONE" (cooked-tests--text)))))
    (should (= asked 2))))

(ert-deftest cooked-a-password-the-termios-arm-read-is-not-asked-for-again ()
  "The two arms must not both answer one prompt, and the right one answers it.

`ssh' reads its own password with the local tty in secret mode, and once it has
it switches that tty to raw while `simon@host's password: ' is still the cursor
row.  With `ssh' in the foreground the regex arm is open, so the moment the
tty leaves secret mode it sees a matching row -- and only the cell the termios
read left behind says that row was already answered.

The first half is a race as well.  The prompt is printed before the tty goes
into secret mode, and the termios sample that notices trails the text by 50ms,
longer than the default debounce, so the regex arm's timer fires first.  Read
there, the password goes out while cooked still believes it owns the line, and
with `read-passwd' on screen instead of a function answering, the termios
arm's own schedule would dismiss the read the user is typing into.  So the
read is attributed: at the default debounce, it has to be the termios arm's."
  (cooked-tests--with-remote-prompt
      "printf 'Password: '; stty -echo; read p; stty -icanon; sleep 1; \
       printf '\\nDONE\\n'; sleep 5"
    (let* ((origins nil)
           (cooked-secret-debounce 0.03)
           (cooked-password-function
            (lambda (_prompt) (push cooked--secret-asking origins) "hunter2")))
      (should (cooked-tests--settle (lambda () origins)))
      (should (cooked-tests--settle (lambda () (eq cooked--mode 'raw))))
      (should (cooked-tests--settle
               (lambda () (string-match-p "DONE" (cooked-tests--text)))))
      (should (equal origins '(termios))))))

(ert-deftest cooked-a-held-remote-password-prompt-is-announced-once ()
  "An off-screen session says it is waiting once, then asks when you return.

The regex arm used to re-arm on every drain the prompt sat through, and away
from the buffer each re-arm posted the message again."
  (let ((announced 0))
    (cooked-tests--with-remote-prompt
        "stty -icanon -echo; printf '[sudo] password for simon: '; read p; \
         printf '\\nGOT\\n'; sleep 5"
      (setq cooked--attention 'away)
      (cl-letf* ((real-message (symbol-function 'message))
                 ((symbol-function 'message)
                  (lambda (format &rest args)
                    (when (string-match-p "asking for a password" format)
                      (setq announced (1+ announced)))
                    (apply real-message format args))))
        (should (cooked-tests--settle (lambda () (= announced 1))))
        ;; Well past the debounce, and a drain on every turn.
        (cooked-tests--settle #'ignore 0.5)
        (should (= announced 1))
        (should (= asked 0)))
      (set-window-buffer (selected-window) (current-buffer))
      (cooked--update-attention)
      (should (cooked-tests--settle
               (lambda () (string-match-p "GOT" (cooked-tests--text)))))
      (should (= asked 1)))))

(ert-deftest cooked-password-sources-compose-and-defer-to-the-single-slot ()
  "The chain is asked first, and `cooked-password-function' is the last word.

A single slot cannot compose -- a second source means writing a dispatcher, and
every user wanting two writes the same one.  The existing slot keeps working and
keeps its meaning as the answer of last resort."
  (let ((asked nil))
    (let ((cooked-password-functions
           (list (lambda (_p) (push 'first asked) nil)
                 (lambda (_p) (push 'second asked) "from-the-chain")
                 (lambda (_p) (push 'third asked) "never-reached")))
          (cooked-password-function (lambda (_p) (push 'slot asked) "from-the-slot")))
      (should (equal (cooked--password-from-sources "Password:") "from-the-chain"))
      ;; Stopped at the first answer; the slot was never consulted.
      (should (equal (nreverse asked) '(first second))))
    ;; Every entry declining falls through to the slot.
    (setq asked nil)
    (let ((cooked-password-functions (list (lambda (_p) nil)))
          (cooked-password-function (lambda (_p) (push 'slot asked) "from-the-slot")))
      (should (equal (cooked--password-from-sources "Password:") "from-the-slot"))
      (should (equal asked '(slot))))
    ;; And an entry that signals is contained: the next one is still asked.
    (let ((cooked-password-functions
           (list (lambda (_p) (error "a broken auth-source backend"))
                 (lambda (_p) "survived")))
          (cooked-password-function nil))
      (should (equal (cooked--password-from-sources "Password:") "survived")))))
(ert-deftest cooked-evil-does-not-expand-an-abbrev-in-the-childs-text ()
  "`evil-maybe-expand-abbrev' rewrites a word the child printed.

It hangs on `evil-insert-state-exit-hook' whenever `abbrev-mode' is on, and
`expand-abbrev' asks about the word before point without any notion of whose
word it is.  Point over a rendered row is over the child's text, so a row
reading `teh' comes back reading `the' -- a row the emulator's grid still
believes says the other thing.

Run under `inhibit-read-only', which is not a contrivance but the condition
that makes this class silent: `cooked--refresh-keymap' runs
`cooked-state-change-hook' -- and so `cooked-evil-sync', and so every evil
state transition cooked itself forces -- from inside the drain, where
`cooked--apply' has bound it.  Without the binding the `read-only' property
answers for this, and the answer is a signal; with it, nothing answers."
  :tags '(evil)
  (skip-unless (require 'evil nil t))
  (require 'cooked-evil)
  (with-temp-buffer
    (delay-mode-hooks (cooked-mode))
    (abbrev-mode 1)
    (define-abbrev local-abbrev-table "teh" "the")
    (evil-local-mode 1)
    (evil-insert-state)
    (insert "top\nteh\nbot\n")
    (add-text-properties (point-min) (point-max) cooked--read-only-props)
    (goto-char 8)
    (let ((inhibit-read-only t) (buffer-undo-list t))
      (evil-normal-state))
    (should (equal (buffer-substring-no-properties (point-min) (point-max))
                   "top\nteh\nbot\n"))))

(ert-deftest cooked-evil-does-not-pad-the-childs-rows-out-to-a-column ()
  "`evil-cleanup-insert-state' pads short rows with spaces the child never sent.

A visual-block \\`I' or \\`A' leaves `evil-insert-vcount' set, and the branch that
reads it walks every line of the block calling `move-to-column ... t' -- the
FORCE argument, which inserts spaces when the line is shorter than the column.
On the way out of insert state that turns a two-column row into a four-column
one, and the emulator, which was told nothing, keeps computing every later
delta against the row it still thinks is there.

Refused by switching `evil-insert-vcount' off for the call rather than by
refusing the call, so the fine-grained undo step it also ends -- bookkeeping
about the user's own pending input -- still happens.  Under `inhibit-read-only'
for the reason `cooked-evil-does-not-expand-an-abbrev-in-the-childs-text'
gives."
  :tags '(evil)
  (skip-unless (require 'evil nil t))
  (require 'cooked-evil)
  (with-temp-buffer
    (delay-mode-hooks (cooked-mode))
    (insert "abcdef\nab\nabcdef\n")
    (add-text-properties (point-min) (point-max) cooked--read-only-props)
    (goto-char (point-min))
    (evil-local-mode 1)
    (setq evil-insert-count nil
          evil-insert-lines nil
          evil-insert-skip-empty-lines nil
          evil-insert-vcount (list 1 4 3)
          evil-insert-repeat-info '(nil))
    (let ((inhibit-read-only t) (buffer-undo-list t))
      (evil-cleanup-insert-state))
    (should (equal (buffer-substring-no-properties (point-min) (point-max))
                   "abcdef\nab\nabcdef\n"))))

(ert-deftest cooked-state-change-hook-runs-inside-the-childs-edit ()
  "The premise the whole whitespace sweep rests on, pinned so it cannot drift.

`cooked--apply' binds `inhibit-read-only' and `buffer-undo-list' so the
emulator can rewrite rows the user may not, and `cooked--refresh-keymap' runs
`cooked-state-change-hook' from inside that -- an OSC 133 `prompt-end' or the
alternate screen going up reaches the hook without ever leaving the drain.
Whatever the hook calls therefore edits with the protection off and the history
disabled, which is why an edit made there is neither refused nor recorded, and
why `cooked-evil--no-unbidden-edit' has to stop evil before it starts rather
than let the `read-only' property answer.

If this ever stops being true the sweep can be reconsidered; while it is true,
every layer invited onto that hook inherits it."
  (cooked-tests--with-session
      (list "/bin/sh" "-c" "stty raw -echo; printf '\\033[?1049h'; sleep 5")
    (let ((seen 'never))
      (add-hook 'cooked-state-change-hook
                (lambda () (setq seen (list inhibit-read-only (eq buffer-undo-list t))))
                nil t)
      (should (cooked-tests--settle (lambda () (not (eq seen 'never)))))
      (should (equal seen '(t t))))))

(ert-deftest cooked-evil-insert-state-forwards-what-a-program-needs ()
  "Insert state over a child that owns the keyboard forwards like emacs state.

`cooked-semi-map' was worn as the local map, and evil's insert state maps and
evil-collection's auxiliary maps outrank every local map, so `S-<return>' inside
a full-screen program inserted a newline into the read-only screen instead of
reaching the program, and `C-r', `C-w' and `C-o' ran evil's commands.  The
forwarding now sits above evil while the semi map is worn, under each policy in
which the child owns the keyboard.  It leaves alone what insert state keeps for
Emacs, and at a prompt it is not there at all."
  :tags '(evil evil-collection)
  (skip-unless (require 'evil nil t))
  (skip-unless (require 'evil-collection nil t))
  (require 'cooked-evil)
  (evil-mode 1)
  ;; Where `S-<return>' was lost: evil-collection's comint bindings.
  (cooked-tests--with-evil-collection (comint)
    (cooked-tests--with-echoing-child ""
      (cooked-tests--assert-forwarded 'raw)
      (cooked--handle-semantic '(command-start nil nil) nil)
      (cooked--refresh-keymap)
      (cooked-tests--assert-forwarded 'command))
    (cooked-tests--with-session
        '("/bin/sh" "-c" "printf '\\033[?1049h'; stty raw -echo; cat -v")
      (should (cooked-tests--settle (lambda () cooked--alt)))
      (cooked-tests--assert-forwarded 'alt)
      ;; And what the forwarded keys send, from insert state.
      (evil-insert-state)
      (cooked-tests--with-kitty-flags 1
        (let ((last-command-event 'S-return))
          (call-interactively (key-binding (kbd "S-<return>")))))
      (should (cooked-tests--settle
               (lambda () (string-search "^[[13;2u" (cooked-tests--text)))))
      ;; A graphical frame's Delete key is `delete', not the `deletechar' a
      ;; terminal decodes, and is spelled the same.
      (let ((last-command-event 'delete))
        (call-interactively (key-binding (kbd "<delete>"))))
      (should (cooked-tests--settle
               (lambda () (string-search "^[[3~" (cooked-tests--text))))))
    ;; At a prompt Emacs owns the line, and insert state is evil's and cooked's.
    (cooked-tests--with-session '("/bin/cat")
      (should (cooked-tests--settle (lambda () (eq cooked--mode 'cooked))))
      (evil-insert-state)
      (should-not cooked--semi-map-worn)
      (dolist (key cooked-tests--keys-a-program-needs)
        (ert-info ((format "%s in insert state at a prompt" key))
          (should-not (eq (key-binding (kbd key)) #'cooked-send-key))))
      (should (eq (key-binding (kbd "C-w")) #'evil-delete-backward-word))
      (should (eq (key-binding (kbd "RET")) #'cooked-send-input)))))

(ert-deftest cooked-evil-insert-state-at-a-prompt-keeps-cookeds-keys ()
  "At a prompt insert-state `S-<return>' adds a line and `C-r' goes to the shell.

A readline user expects Shift+Return to compose a second line and \\`C-r' to
search the shell's history, which is what `cooked-input-map' binds them to.
evil-collection's `newline' and evil's `evil-paste-from-register' outranked it,
since both sit on keymaps above every local map.  A key taken out of
`cooked-delegate-keys' is evil's again, and one added later is cooked's, and
while the child owns the keyboard none of this applies."
  :tags '(evil evil-collection)
  (skip-unless (require 'evil nil t))
  (skip-unless (require 'evil-collection nil t))
  (require 'cooked-evil)
  (evil-mode 1)
  (cooked-tests--with-evil-collection (comint)
    (cooked-tests--with-session '("/bin/cat")
      (should (cooked-tests--settle (lambda () (eq cooked--mode 'cooked))))
      (evil-insert-state)
      (should (eq (key-binding (kbd "S-<return>")) #'cooked-newline))
      (should (eq (key-binding (kbd "S-RET")) #'cooked-newline))
      (should (eq (key-binding (kbd "C-r")) #'cooked-delegate-this-key))
      (should (eq (key-binding (kbd "RET")) #'cooked-send-input))
      (should (eq (key-binding (kbd "C-w")) #'evil-delete-backward-word))
      (let ((original cooked-delegate-keys))
        (unwind-protect
            (progn
              (customize-set-variable 'cooked-delegate-keys '("C-t"))
              (should (eq (key-binding (kbd "C-r")) #'evil-paste-from-register))
              (should (eq (key-binding (kbd "C-t")) #'cooked-delegate-this-key)))
          (customize-set-variable 'cooked-delegate-keys original)))
      (should (eq (key-binding (kbd "C-r")) #'cooked-delegate-this-key))
      ;; Normal state keeps evil's own `C-r', which is redo.
      (evil-normal-state)
      (should (eq (key-binding (kbd "C-r")) #'evil-redo)))))

(ert-deftest cooked-evil-hybrid-insert-off-leaves-evils-insert-keys ()
  "With `cooked-evil-hybrid-insert' nil, evil's insert-state keys stay evil's.

The docstring said insert state then behaved like emacs state, and it did not:
the policy's map is worn as the local map, below evil's insert state map.  What
it now says is what this pins: a key evil binds in insert state runs evil's
command, and every other key reaches the child."
  :tags '(evil)
  (skip-unless (require 'evil nil t))
  (require 'cooked-evil)
  (evil-mode 1)
  (let ((cooked-evil-hybrid-insert nil))
    (cooked-tests--with-echoing-child ""
      (evil-insert-state)
      (cooked--refresh-keymap t)
      (should-not cooked--semi-map-worn)
      (should (eq (key-binding (kbd "C-r")) #'evil-paste-from-register))
      (should (eq (key-binding (kbd "<escape>")) #'evil-normal-state))
      (should (eq (key-binding (kbd "a")) #'cooked-send-key))
      (should (eq (key-binding (kbd "C-f")) #'cooked-send-key)))))

(ert-deftest cooked-evil-follows-a-new-toggle-key ()
  "The key evil leaves insert state with is kept from the child after it changes.

The forwarding above evil's insert state unbound `evil-toggle-key' once, when
cooked-evil loaded, so a toggle key set afterwards went to the child and \\`C-z'
stayed kept back from it."
  :tags '(evil)
  (skip-unless (require 'evil nil t))
  (require 'cooked-evil)
  (evil-mode 1)
  (let ((original evil-toggle-key))
    (unwind-protect
        (cooked-tests--with-echoing-child ""
          (evil-insert-state)
          (should cooked--semi-map-worn)
          (should (eq (key-binding (kbd "C-z")) #'evil-emacs-state))
          (should (eq (key-binding (kbd "C-]")) #'cooked-send-key))
          (customize-set-variable 'evil-toggle-key "C-]")
          (should (eq (key-binding (kbd "C-]")) #'evil-emacs-state))
          (should (eq (key-binding (kbd "C-z")) #'cooked-send-key)))
      (customize-set-variable 'evil-toggle-key original))))

(ert-deftest cooked-semi-map-leaves-emacs-its-control-chords ()
  "Evil insert state keeps `C-;' and `C-SPC' for Emacs; the raw map forwards them.

On a graphical frame those are events no character code names, and binding them
in every passthrough map took them from embark, avy and the mark in the one map
that exists to keep Emacs reachable.  The raw map still forwards them, so a
protocol can spell them, and an exception of \"C-;\" takes one back: before, the
exception lists accepted nothing outside 0-127."
  (dolist (key '("C-;" "C-SPC" "C-S-a"))
    (should-not (eq (lookup-key cooked-semi-map (kbd key)) #'cooked-send-key))
    (should (eq (lookup-key cooked-raw-map (kbd key)) #'cooked-send-key)))
  (should-error (cooked--exception-event "C-x C-f"))
  (let ((saved cooked-raw-exceptions)
        (global (current-global-map))
        (map (make-composed-keymap nil (current-global-map))))
    (define-key map (kbd "C-;") #'ignore)
    (unwind-protect
        (progn
          (use-global-map map)
          (customize-set-variable 'cooked-raw-exceptions
                                  (append saved '("C-;" "M-o")))
          (should-not (lookup-key cooked-raw-map (kbd "C-;")))
          ;; A Meta chord is kept where a graphical frame binds it, and the
          ;; Meta chords around it still forward.
          (let ((overlay (cooked--build-meta-overlay
                          cooked-raw-map (cooked--meta-exceptions cooked-raw-map))))
            (should-not (eq (lookup-key overlay (kbd "M-o")) #'cooked-send-meta-key))
            (should (eq (lookup-key overlay (kbd "M-p")) #'cooked-send-meta-key)))
          (cooked-tests--with-echoing-child ""
            (should (eq (cooked--policy) 'raw))
            (should (eq (key-binding (kbd "C-;")) #'ignore))))
      (customize-set-variable 'cooked-raw-exceptions saved)
      (use-global-map global)))
  (should (eq (lookup-key cooked-raw-map (kbd "C-;")) #'cooked-send-key)))

(ert-deftest cooked-whitespace-tidiers-leave-the-childs-rows-alone ()
  "Nothing that tidies whitespace edits a row the child wrote.

A row ending in coloured spaces is text the child put in cells, not slack.
`delete-trailing-whitespace', `whitespace-cleanup' and the save hook an
editorconfig `trim_trailing_whitespace' turns on all meet the `read-only'
property `cooked--protect' puts on it, and each either finds nothing to delete
or signals.  At a prompt the pending line is the user's own text, and trimming
it there is theirs to ask for."
  (require 'whitespace)
  (require 'editorconfig)
  (cooked-tests--with-session
      '("/bin/sh" "-c"
        "printf 'abc\\033[41m   \\033[m\\r\\n\\033[42m      \\033[m\\r\\nX'; stty raw -echo; cat -v")
    (should (cooked-tests--settle
             (lambda () (string-search "abc   \n      \nX" (cooked-tests--text)))))
    (let ((rows (cooked-tests--text)))
      (dolist (tidy (list #'delete-trailing-whitespace
                          #'whitespace-cleanup
                          ;; What editorconfig turns on, and what it then runs.
                          (lambda ()
                            (funcall editorconfig-trim-whitespaces-mode 1)
                            (run-hooks 'before-save-hook))))
        (ert-info ((format "%S" tidy))
          (ignore-errors (funcall tidy))
          (should (equal (cooked-tests--text) rows)))))))

(ert-deftest cooked-mode-is-special-enough-to-be-left-alone ()
  "What excuses cooked from every globalized whitespace tidier at once.

`ws-butler-global-mode', which is the one actually installed here, turns
`ws-butler-mode' on in every buffer except those whose major mode has a
`mode-class' of `special' -- and `ws-butler-mode' would otherwise put a
`ws-butler-chg' property on every row the child writes, on every drain, and
trim the lot on the first save.  The same `mode-class' convention is what
`define-globalized-minor-mode' users check generally.

cooked puts it itself rather than inheriting it from `comint-mode', which
`define-derived-mode' copies only when the mode function first runs.  So a
fresh Emacs is asked, before any cooked buffer exists: an inherited class would
answer nil there, and would be dropped by a move away from comint unnoticed."
  (let* ((emacs (expand-file-name invocation-name invocation-directory))
         (lisp (expand-file-name "lisp" (cooked--root)))
         (script "(progn (require 'cooked-mode)
                         (prin1 (get 'cooked-mode 'mode-class)))")
         (output (with-output-to-string
                   (with-current-buffer standard-output
                     (call-process emacs nil t nil
                                   "-Q" "--batch" "-L" lisp "--eval" script)))))
    (should (eq (car (read-from-string output)) 'special)))
  (with-temp-buffer
    (delay-mode-hooks (cooked-mode))
    (should (eq (get 'cooked-mode 'mode-class) 'special))))

;;;; Input methods

(defun cooked-tests--ime-received (method keys expected shell setup)
  "What a child owning the keyboard read when KEYS were typed through METHOD.

The child is `cat' into a file, after SHELL, so the answer is the bytes the
program got rather than anything drawn.  SETUP is a function called in the
buffer once the child owns the keyboard, to put it in the state under test.
Waits until the file holds EXPECTED, and returns what it holds either way."
  (let ((out (make-temp-file "cooked-ime")))
    (unwind-protect
        (cooked-tests--with-session
            (list "/bin/sh" "-c" (format "%sstty raw -echo; exec cat > %s" shell out))
          (switch-to-buffer (current-buffer))
          (should (cooked-tests--settle (lambda () (eq cooked--mode 'raw))))
          (funcall setup)
          (should (cooked--child-owns-keyboard-p))
          (set-input-method method)
          (unwind-protect
              (execute-kbd-macro keys)
            (deactivate-input-method))
          (let ((read (lambda ()
                        (decode-coding-string
                         (with-temp-buffer
                           (set-buffer-multibyte nil)
                           (insert-file-contents-literally out)
                           (buffer-string))
                         'utf-8))))
            (cooked-tests--settle (lambda () (equal (funcall read) expected)) 2)
            (funcall read)))
      (delete-file out))))

(defconst cooked-tests--ime-cases
  '(("german-postfix" "ae" "ä")
    ("chinese-py" "ni1" "你")
    ("korean-hangul" "gks " "한 "))
  "Input methods, the keys typed through each, and the text they compose.
One Quail method that returns its composition as events, one whose Quail
conversion picks a candidate, and hangul, which inserts what it composes.")

(defun cooked-tests--ime-check (shell setup)
  "Check each of `cooked-tests--ime-cases' composes for a child after SHELL and SETUP."
  (pcase-dolist (`(,method ,keys ,expected) cooked-tests--ime-cases)
    (should (equal (list method (cooked-tests--ime-received
                                 method keys expected shell setup))
                   (list method expected)))))

(ert-deftest cooked-ime-composes-for-a-raw-child ()
  "An input method sends the composed text to a child reading raw.

Quail saw the read-only screen at point and sent `ae' for ä and `ni1' for 你,
and hangul signalled `text-read-only' and lost the keys."
  (cooked-tests--ime-check "" #'ignore))

(ert-deftest cooked-ime-composes-for-a-child-on-the-alternate-screen ()
  "An input method sends the composed text to a program on the alternate screen."
  (cooked-tests--ime-check
   "printf '\\033[?1049h'; "
   (lambda ()
     (should (cooked-tests--settle (lambda () (eq (cooked--policy) 'alt)))))))

(ert-deftest cooked-ime-composes-for-a-command-the-shell-marked ()
  "An input method sends the composed text to a command running after a shell mark."
  (cooked-tests--ime-check
   ""
   (lambda ()
     (cooked--handle-semantic '(command-start nil nil) nil)
     (cooked--refresh-keymap)
     (should (eq (cooked--policy) 'command)))))

(ert-deftest cooked-ime-composes-for-a-child-from-evil-insert-state ()
  "An input method composes for the child from evil's insert state, and after it.

Evil turns the method off in normal state and on again in insert state without
running `input-method-activate-hook', so the wrapper has to find its way back
by itself before the next key."
  :tags '(evil)
  (skip-unless (require 'evil nil t))
  (require 'cooked-evil)
  (evil-mode 1)
  (cooked-tests--ime-check
   ""
   (lambda ()
     (evil-insert-state)
     (should cooked--semi-map-worn)))
  (should (equal (cooked-tests--ime-received
                  "german-postfix" (vconcat [escape] "iae") "ä" ""
                  (lambda () (evil-insert-state)))
                 "ä")))

(ert-deftest cooked-ime-composes-in-the-input-line-at-a-prompt ()
  "At a prompt the input method edits the input line as in any buffer."
  (pcase-dolist (`(,method ,keys ,expected) cooked-tests--ime-cases)
    (cooked-tests--with-session '("/bin/sh" "-c" "printf '$ '; exec cat")
      (switch-to-buffer (current-buffer))
      (should (cooked-tests--settle
               (lambda () (and (cooked--input-state-p)
                               (string-search "$" (buffer-string))))))
      (set-input-method method)
      (unwind-protect
          (execute-kbd-macro keys)
        (deactivate-input-method))
      (should (equal (buffer-substring-no-properties
                      (line-beginning-position) (line-end-position))
                     (concat "$ " expected))))))

(ert-deftest cooked-ime-holds-the-drain-until-the-composition-ends ()
  "Output that arrives while a method composes is drawn when it stops, not under it.

A wake during the composition must not rewrite the row the preedit is on, and
must not be lost either: the core sends no further wake until Emacs drains, so
the catch-up is what keeps the buffer updating afterwards."
  (cooked-tests--with-echoing-child ""
    (let (during)
      (setq-local input-method-function
                  (lambda (key)
                    (cooked--send-to-child "held")
                    (cooked-tests--pump 0.3)
                    (setq during (buffer-string))
                    (list key)))
      (cooked-ime--install)
      (should (eq input-method-function #'cooked-ime--compose))
      (should (equal (funcall input-method-function ?x) '(?x)))
      (should-not (string-search "held" during))
      (should (string-search "held" (buffer-string)))
      (cooked--send-to-child "after")
      (cooked-tests--pump 0.3)
      (should (string-search "heldafter" (buffer-string))))))

(provide 'cooked-tests-input)
;;; cooked-tests-input.el ends here
