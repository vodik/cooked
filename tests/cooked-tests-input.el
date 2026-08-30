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
    (should (eq (current-local-map) cooked-raw-map))))

(ert-deftest cooked-alt-mode-installs-the-alt-map-and-still-forwards-everything ()
  "The alternate screen means a full-screen program has taken over completely,
so nothing beyond `C-c' is reserved there -- unlike plain `raw', it has no
customizable exceptions at all."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\033[?1049h'; stty raw -echo; cat -v")
    (should (cooked-tests--settle (lambda () cooked--alt)))
    (should (eq (current-local-map) cooked-alt-map))
    (dolist (key '("C-g" "C-x" "C-h" "C-u" "C-l"))
      (should (eq (lookup-key cooked-alt-map (kbd key)) #'cooked-send-key)))))

(ert-deftest cooked-policy-keeps-nothing-back-once-the-shell-has-spoken ()
  "`cooked-raw-exceptions\=' hedges a state cooked cannot read: a raw program and
a shell editing its own prompt line look alike.  OSC 133 removes the doubt, so
once any mark has arrived the hedge is off and `C-u\='/`C-l\=' -- readline\='s
kill-line and every shell\='s clear-screen -- go to the child like anything else."
  (cooked-tests--with-session '("/bin/sh" "-c" "stty -icanon -echo; exec cat")
    (should (cooked-tests--settle (lambda () (eq (cooked--policy) 'raw))))
    ;; No mark has arrived, so the exceptions still apply.
    (should (eq (lookup-key cooked-raw-map (kbd "C-u")) nil))
    (should-not (eq (key-binding (kbd "C-u")) #'cooked-send-key))

    ;; One mark is enough: the shell is talking, so its silence is informative.
    (cooked--handle-semantic '(command-start nil) nil)
    (should cooked--semantic-seen)
    (should (eq (cooked--policy) 'command))
    (cooked--refresh-keymap)
    (should (eq (key-binding (kbd "C-u")) #'cooked-send-key))
    (should (eq (key-binding (kbd "C-l")) #'cooked-send-key))
    ;; C-c is still ours, in every state.
    (should-not (eq (key-binding (kbd "C-c C-c")) #'cooked-send-key))))

(ert-deftest cooked-command-state-still-reaches-cookeds-own-commands ()
  "`cooked-command-map\=' is a child of `cooked-mode-map\=' like the others, or
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
    (should (eq (current-local-map) cooked-raw-map))
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

(ert-deftest cooked-evil-normal-state-keeps-the-render-live ()
  "`C-z' into normal state is the key an evil user presses to do anything at
all -- reach a leader, scroll, get to another window -- and it used to stop
the terminal dead until they came back.  Normal state suspends forwarding and
stops the view chasing the cursor; the child keeps drawing throughout."
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
    (should (eq (current-local-map) cooked-raw-map))
    (should-not buffer-read-only)))

(ert-deftest cooked-evil-insert-state-resumes-forwarding-from-normal-state ()
  "The hole in latching the freeze onto emacs state: nothing thawed a buffer
left in insert state, because the thaw hung on *entering* emacs state and the
auto-resume needs `self-insert-command', which is not what a letter runs in
normal state.  Deriving the mode from evil's state has no such hole."
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
    (should (eq (current-local-map) cooked-raw-map))
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

(ert-deftest cooked-evil-visual-state-freezes-the-render ()
  "A selection is a claim about a region of text, and text rewritten
underneath it makes the claim a lie -- so visual state defers the render where
normal state does not."
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

(ert-deftest cooked-paste-cannot-be-made-to-close-its-own-bracket ()
  "An end marker inside the pasted text would close the bracket early and hand
what followed to the child as if it had been typed — how a copied line runs
something nobody read.  It is dropped."
  (cooked-tests--with-echoing-child "printf '\\033[?2004h'; "
    (cooked-tests--with-kill "a\e[201~; rm -rf /" (cooked-paste))
    (should (cooked-tests--settle
             (lambda ()
               (string-search "^[[200~a; rm -rf /^[[201~" (cooked-tests--text)))))
    (should-not (string-search "^[[201~; rm" (cooked-tests--text)))))

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

(ert-deftest cooked-evil-normal-state-pastes-into-the-child ()
  "`p' is the key a vim user's hand reaches for, and inside a full-screen program
it is the only route to the kill ring: the program's own `p' pastes its own
registers and has never heard of Emacs'."
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
                                           (point-min) (point-max))))))

(ert-deftest cooked-secret-prompt-text-is-recovered ()
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'Enter passphrase: '; stty -echo; sleep 5")
    (should (cooked-tests--settle (lambda () (eq cooked--mode 'secret))))
    (should (equal (cooked--prompt-text cooked--session) "Enter passphrase:"))))

(ert-deftest cooked-wheel-notches-are-reported-as-presses ()
  "Emacs calls a notch a click; encoding that as a release loses the scroll.
Applications discard a release of buttons 64/65, so a wheel report that goes out
as `m' rather than `M' reaches the child and is thrown away."
  (let ((cooked--mouse-sgr t))
    (should (equal (cooked--mouse-report 64 3 5 t) "\e[<64;6;4M")))
  ;; X10 is worse than merely ignored: a release cannot say which way the wheel
  ;; turned, because it reports button 3 for every button.
  (let ((cooked--mouse-sgr nil))
    (should-not (equal (cooked--mouse-report 64 3 5 t)
                       (cooked--mouse-report 65 3 5 t)))
    (should (equal (cooked--mouse-report 64 3 5 nil)
                   (cooked--mouse-report 65 3 5 nil)))))

(ert-deftest cooked-wheel-reaches-a-child-that-asked-for-the-mouse ()
  "The whole path: alt screen, mouse tracking on, wheel event in, report out."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\033[?1049h\\033[?1000h\\033[?1006h'; stty raw; cat -v")
    (should (cooked-tests--settle (lambda () (and cooked--alt cooked--mouse))))
    (should (eq (cooked--policy) 'alt))
    ;; The alt map owns the wheel while the child does; otherwise Emacs would
    ;; scroll the buffer out from under a full-screen program.
    (should (eq (current-local-map) cooked-alt-map))
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
    (should (cooked-tests--settle (lambda () (and cooked--alt cooked--mouse))))
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
    (setq cooked--mouse nil)
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

The `seen\=' column is not decoration.  A session that has never had a mark is a
different situation from one that is merely between them, and the indicator says
so: everything else here can be inferred afresh each prompt, but \"this host has
no integration at all\" only exists as a latch."
  (with-temp-buffer
    (pcase-dolist (`(,mode ,alt ,semantic ,seen ,policy ,owns ,indicator)
                   ;; mode      alt  semantic  seen  policy   owns  mode line
                   '((cooked    nil  nil       nil   cooked   t     " edit bare")
                     (cooked    nil  output    t     cooked   t     " edit")
                     (raw       nil  nil       nil   raw      nil   " raw bare")
                     ;; A mark has arrived and this is not a prompt, so the shell
                     ;; is running something and said so: `command', not a guess.
                     (raw       nil  output    t     command  nil   " raw")
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
                  cooked--completion-nonce nil
                  cooked--title nil
                  cooked--exit nil)
      (should (eq (cooked--policy) policy))
      (should (eq (and (cooked--input-state-p) t) owns))
      (should (equal (substring-no-properties (cooked--mode-line)) indicator)))))

(ert-deftest cooked-a-mark-alone-does-not-buy-the-keyboard ()
  "A `133;B\=' is a claim, and claims cross an ssh as easily as facts do.

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
                cooked--completion-nonce nil
                cooked--title nil
                cooked--exit nil)
    ;; Local: the child is ours, and nothing about this changes.
    (should (eq (cooked--policy) 'cooked))
    (should (cooked--input-state-p))
    ;; Behind an ssh, with only the core marks.
    (setq-local cooked--host "other.example")
    (should (eq (cooked--policy) 'prompt))
    (should-not (cooked--input-state-p))
    (should (cooked--child-owns-keyboard-p))
    ;; And it keeps nothing back, for the reason `command' does not: the shell
    ;; said where it was, and a shell at its own prompt wants every key.
    (should (eq (cooked--state-keymap nil 'prompt) cooked-command-map))
    ;; The same remote host, running the full snippet.
    (setq-local cooked--completion-nonce "1234")
    (should (eq (cooked--policy) 'cooked))
    (should (cooked--input-state-p))))

(ert-deftest cooked-delegation-hands-the-whole-line-to-the-shell ()
  "The line reaches ZLE, the cursor is put back, and Emacs stops owning it.

The whole line goes, not the part before point: sending the prefix alone would
silently drop whatever followed the cursor, and the left-arrows that avoid that
cost one byte each."
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
    (should cooked--delegated)
    (should-not (cooked--input-state-p))
    (should (eq (cooked--policy) 'prompt))
    (should (cooked--child-owns-keyboard-p))
    ;; Refusing twice, because the second call has nothing left to hand over.
    (should-error (cooked-delegate-key "\C-r") :type 'user-error)))

(ert-deftest cooked-delegation-lasts-exactly-one-line ()
  "Delegation is a one-way door for the rest of the line and no further.
A fresh prompt is a fresh line, and Emacs may have it back."
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-zsh
    (goto-char cooked--input-end)
    (insert "true")
    (cl-letf (((symbol-function 'cooked--send-to-child) #'ignore))
      (cooked-delegate-key "\C-r"))
    (should cooked--delegated)
    (cooked--handle-semantic '(prompt-start (screen 0 . 0)) nil)
    (should-not cooked--delegated)))

(ert-deftest cooked-delegate-keys-put-back-what-they-replaced ()
  "`TAB\=' is not delegated by default, and naming it must not be a one-way
change: taking it out again has to leave `completion-at-point\=' behind rather
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
auxiliary keymap to outrank `evil-collection-comint\=', and evil reaches those
through `emulation-mode-map-alists\=' -- which Emacs searches *before*
`minor-mode-overriding-map-alist\=', where `completion-in-region-mode\=' puts the
UI\='s keymap.  So corfu\='s `RET\=' never saw the key: the popup stayed up and the
half-completed line went to the shell underneath it.

No corfu here on purpose.  What is being pinned is the precedence contract --
an active `completion-in-region-mode\=' keymap wins Enter -- and every in-buffer
completion UI, the built-in one included, is on the far side of that same test."
  (skip-unless (require 'evil nil t))
  (skip-unless (require 'evil-collection nil t))
  (require 'cooked-evil)
  (evil-mode 1)
  (cooked-tests--with-echoing-child ""
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
  (skip-unless (and (executable-find "zsh") (require 'evil nil t)))
  (require 'cooked-evil)
  (evil-mode 1)
  (let ((buffer (generate-new-buffer "*cooked-evil*")))
    (unwind-protect
        (with-current-buffer buffer
          (cooked-mode)
          (pcase-let ((`(,argv ,env ,_scratch) (cooked--shell-invocation (executable-find "zsh"))))
            (cooked--start argv nil env))
          (cooked--refresh-keymap)
          (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input))))
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
                                   (eq (current-local-map) cooked-command-map)))))
          (should (eq evil-state 'emacs))

          ;; ...and hands it back at the next prompt.
          (should (cooked-tests--settle
                   (lambda () (and (eq cooked--semantic 'input)
                                   (eq (current-local-map) cooked-input-map)))))
          (should (eq evil-state 'insert)))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer))))

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
  "The other side of `cooked-a-canonical-child-hiding-its-cursor-leaves-emacs-one\='.

That fix keyed on `cooked--input-state-p\=', which answers yes the moment termios
says canonical -- and a command run from a shell that never puts the tty in raw
mode is canonical too.  So a progress bar drawn by a *running* command kept a
cursor Emacs had been told not to draw.  OSC 133 is what tells the two apart:
while a command is running the mark says `output\=', and there the child\='s
`CSI ?25l\=' is about its own picture and is honoured; at the prompt either side
of it the cursor comes back."
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
`cooked--input-mode\=' alone rather than `cooked--suspended-p\=', which cannot be
true under policy `cooked\=' at all -- the child repainting a canonical tty
never took the keyboard to be suspended from, which is why
`cooked-toggle-peek\=' refuses here and `evil\=' normal state is the door.  Driven
through `cooked-input-mode-function\=', the seam evil itself uses."
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-zsh
    (cooked--send-input-string "printf \'GO\\033[?25l\'; sleep 3")
    (should (cooked-tests--settle
             (lambda () (and (eq cooked--semantic 'output)
                             cooked--cursor
                             (not (cooked-cursor-visible cooked--cursor))))
             8))
    (should-not cursor-type)
    (let ((cooked-input-mode-function (lambda () 'still)))
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
makes `comint-input-ignoredups\=', the ring size, and the history isearch
`comint-mode\=' installs all along apply to cooked too."
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
  "comint\='s own `comint-goto-input\=' deletes from the process mark to `point-max\=',
assuming input is the last thing in the buffer.  cooked has rendered screen rows
below the prompt, so recall has to work between the two ends of the input region
instead -- this is the regression guard for using comint\='s version by mistake."
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
    (should (cooked-tests--settle (lambda () cooked--mouse)))
    (should cooked--mouse-sgr)
    (should (equal (cooked--mouse-report 0 4 9 t) "\e[<0;10;5M"))
    (should (equal (cooked--mouse-report 0 4 9 nil) "\e[<0;10;5m"))
    (should (equal (cooked--mouse-report 64 0 0 t) "\e[<64;1;1M"))))

(ert-deftest cooked-mouse-x10-encoding-when-sgr-is-off ()
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '\\033[?1000h'; exec cat")
    (should (cooked-tests--settle (lambda () cooked--mouse)))
    (should-not cooked--mouse-sgr)
    ;; X10 biases coordinates by 32 and is 1-based, so column 0 is ?!.
    (should (equal (cooked--mouse-report 0 0 0 t) "\e[M !!"))
    (should (equal (cooked--mouse-report 0 2 4 t) "\e[M %#"))
    ;; Release is button 3 in X10, which cannot say which button was let go.
    (should (equal (cooked--mouse-report 0 0 0 nil) "\e[M#!!"))))

(ert-deftest cooked-mouse-is-left-to-emacs-when-unrequested ()
  "A child that never asked for mouse reports must not steal the click."
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle #'cooked--input-start-position))
    ;; The child never enabled reporting, so `cooked-mouse-event' takes the
    ;; fallback branch and the click behaves as it would in any buffer.
    (should-not cooked--mouse)
    (should (eq (lookup-key cooked-raw-map [mouse-1]) #'cooked-mouse-event))))

(defmacro cooked-tests--displayed (&rest body)
  "Run BODY with the current buffer showing in the selected window.

`cooked-mouse-event\=' routes an event to the buffer the pointer names, so a test
that hands it a posn has to put the buffer somewhere a pointer could be."
  (declare (indent 0))
  `(save-window-excursion
     (set-window-buffer (selected-window) (current-buffer))
     ,@body))

(defun cooked-tests--posn (pos)
  "A mouse position over buffer POS in the selected window, or over no text.

Synthesised rather than recorded because the whole point of these tests is the
shape of the event: `posn-point\=' is nil for a click past the last row or on the
fringe, and that nil is the case that used to hand the tail of the child\='s
gesture back to Emacs."
  (list (selected-window) (or pos 'text) '(0 . 0) 0 nil pos nil nil nil))

(ert-deftest cooked-drag-reports-its-release-where-the-button-came-up ()
  "Emacs does not deliver `mouse-1\=' when the pointer moved between press and
release -- it delivers `drag-mouse-1\=', whose interesting end is `event-end\='.
Unbound, that fell through to the global `mouse-set-region\=': the child was left
holding a button forever, and the region it never asked for appeared in one jump."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\033[?1049h\\033[?1000h\\033[?1006h'; \
                        printf 'alpha\\r\\nbravo'; stty raw; cat -v")
    (should (cooked-tests--settle (lambda () (and cooked--alt cooked--mouse))))
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

(defmacro cooked-tests--with-two-terminals (a b &rest body)
  "Run BODY with two live cooked buffers bound to A and B, side by side.
A is the selected window\='s; B is the other\='s.  Both children take the alt
screen and ask for SGR mouse reporting."
  (declare (indent 2))
  `(cooked-tests--with-session
       '("/bin/sh" "-c" "printf '\033[?1049h\033[?1000h\033[?1006h'; stty raw; cat -v")
     (let ((,a (current-buffer)))
       (cooked-tests--with-session
           '("/bin/sh" "-c" "printf '\033[?1049h\033[?1000h\033[?1006h'; \
                             stty raw; cat -v")
         (let ((,b (current-buffer)))
           (dolist (buffer (list ,a ,b))
             (with-current-buffer buffer
               (should (cooked-tests--settle
                        (lambda () (and cooked--alt cooked--mouse))))
               (should cooked--mouse-grab)))
           (save-window-excursion
             (set-window-buffer (selected-window) ,a)
             (let ((window (split-window)))
               (set-window-buffer window ,b)
               (select-window (get-buffer-window ,a))
               ,@body)))))))

(defun cooked-tests--other-window-event (window kind pos)
  "A KIND event over buffer position POS in WINDOW.

Synthesised like `cooked-tests--posn\=', but naming a window the test does not
have selected: what these tests are about is which buffer such an event ends up
being handled in."
  (list kind (list window pos '(0 . 0) 0 nil pos nil nil nil) 1))

(defun cooked-tests--child-heard (buffer)
  "The first mouse report or cursor key BUFFER\='s child echoed, or nil."
  (with-current-buffer buffer
    (cooked-tests--settle (lambda () nil) 0.3)
    (save-excursion
      (goto-char (point-min))
      (when (re-search-forward "\\[<[0-9;]+[Mm]\\|\\[[AB]" nil t)
        (match-string-no-properties 0)))))

(ert-deftest cooked-a-click-on-another-terminal-focuses-and-reaches-it ()
  "One click on an unfocused terminal both selects it and reaches its child.

Emacs settles a click\='s bindings in the buffer under the pointer but runs the
command in the buffer that was current all along, so the click on B arrived in
A: A\='s child was told about a cell A\='s screen made of a position in B\='s buffer,
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

(ert-deftest cooked-the-wheel-reaches-an-unfocused-terminal ()
  "A notch over an unfocused terminal goes to that terminal\='s child, and
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

(ert-deftest cooked-a-drag-that-leaves-the-window-releases-where-it-left ()
  "A drag out of the terminal is still the child\='s drag, and its release is
still owed -- but `event-end\=' is then a position in somebody else\='s buffer, and
`cooked--screen-cell\=' measures whatever number it finds against this buffer\='s
screen.  So letting go over another window reported the button up at a cell
nobody had dragged to, chosen by how far into the other buffer the pointer
happened to be."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\033[?1049h\033[?1000h\033[?1006h'; \
                        printf 'alpha\r\nbravo'; stty raw; cat -v")
    (should (cooked-tests--settle (lambda () (and cooked--alt cooked--mouse))))
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
  "A click the child answers is the child\='s click.

Nothing used to clear the mark, so a region set before the child grabbed the
mouse survived every click inside the window; `cooked--snap-to-cursor\=' then
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
    (should (cooked-tests--settle (lambda () cooked--mouse-drag)))
    (should cooked--mouse)
    (should cooked--mouse-sgr)
    (should-not cooked--mouse-motion))
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '\\033[?1003h'; exec cat")
    (should (cooked-tests--settle (lambda () cooked--mouse-motion)))
    (should cooked--mouse)
    (should-not cooked--mouse-drag)))

(ert-deftest cooked-motion-reports-carry-the-motion-bit ()
  "32 added to the button being dragged, and 3 for no button at all."
  (with-temp-buffer
    (cooked-mode)
    (setq-local cooked--mouse-sgr t)
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
  "Let go past the last row and `posn-point\=' is nil, but the button is still down
as far as the child knows.  Falling through to Emacs there left it held forever."
  (with-temp-buffer
    (cooked-mode)
    (setq-local cooked--mouse t cooked--mouse-sgr t)
    (setq cooked--mouse-held '(0) cooked--mouse-last-cell '(4 . 9))
    (let (sent)
      (cl-letf (((symbol-function 'cooked--send-to-child)
                 (lambda (text) (push text sent))))
        (let ((last-input-event (list 'drag-mouse-1 (cooked-tests--posn nil)
                                      (cooked-tests--posn nil))))
          (cooked-mouse-event)))
      (should (equal sent '("\e[<0;10;5m"))))
    (should-not cooked--mouse-held)))

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

(ert-deftest cooked-alternate-scroll-grabs-the-wheel-without-mouse-mode ()
  "The keymap gate must widen, or the whole feature is unreachable."
  (with-temp-buffer
    (cooked-mode)
    (setq-local cooked--mouse nil cooked--semantic nil cooked--mode 'raw)
    (cl-letf (((symbol-function 'cooked--alt-scroll-active-p) (lambda () t)))
      (cooked--update-mouse-grab)
      (should cooked--mouse-grab))
    (cl-letf (((symbol-function 'cooked--alt-scroll-active-p) (lambda () nil)))
      (cooked--update-mouse-grab)
      (should-not cooked--mouse-grab))))

(ert-deftest cooked-focus-install-survives-other-packages-advice ()
  "`after-focus-change-function\=' holds one function, not a hook.

`add-hook\=' on it conses onto whatever is already there — doom-modeline puts
advice on it — leaving a list where Emacs expects something callable, and the
next focus change signals `invalid-function\='."
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
      (cl-letf (((symbol-function 'cooked--send-if-live)
                 (lambda (&rest _) (setq sent t))))
        (cooked--report-focus))
      (should-not sent))))

(ert-deftest cooked-focus-reports-once-per-change ()
  (cooked-tests--with-session
   '("/bin/sh" "-c" "printf '\\033[?1004h'; exec cat")
   (should (cooked-tests--settle
            (lambda () (cooked--focus-events-p cooked--session))))
   (let ((sent nil))
     (cl-letf (((symbol-function 'cooked--send)
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

The render `recenter\='s through `with-selected-window\=', and `evil\=' advises
`select-window\=' to refresh its own cursor -- so setting `cursor-type\=' before
that block let evil overwrite it inside the very same drain.  Because the write
is skipped when the value has not changed, no later drain repaired it either,
and a progress bar drawn without a cursor got one anyway, jumping about.

The buffer has to be shown in a window for any of that to run, which is why the
older visibility test never saw it."
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
`cooked--send-key' has nothing to forward, and the tables are searched in order
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
    (should-not (cooked--encode-event 'f20))
    ;; Including with modifiers, which is the case that would otherwise have
    ;; found a code point in `cooked--literal-codes' on the way past.
    (should-not (cooked--encode-event 'C-f20))))

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

    (setq cooked--keys 'modify-other)
    (should (equal (cooked--encode-event 'backtab) "\e[27;2;9~"))
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
          (let ((last-command-event 'backtab))
            (cooked-send-key))
          (should (equal sent '("\e[27;2;9~"))))))))

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
  (skip-unless (executable-find "zsh"))
  (let ((buffer (generate-new-buffer "*cooked-snap*")))
    (unwind-protect
        (with-current-buffer buffer
          (cooked-mode)
          (pcase-let ((`(,argv ,env ,scratch)
                       (cooked--shell-invocation (executable-find "zsh"))))
            (setq cooked--scratch scratch)
            (cooked--start argv nil env))
          (cooked--refresh-keymap)
          (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input))))
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
          (should (equal (cooked--pending-input) "hi")))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer))))

(ert-deftest cooked-editing-mid-line-survives-a-drain ()
  "A drain must not move point out of the line the user is typing.

`cooked--apply' lifts the pending input out of the buffer and rebuilds it around
the child\='s new cursor, so the buffer position point had cannot survive -- and
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
there as ESC x.  C-c M-x is the way back to Emacs, and honours whatever the user
has bound M-x to."
  (should (eq (lookup-key cooked-raw-map (kbd "C-c M-x")) #'cooked-meta-x))
  (should (eq (lookup-key cooked-input-map (kbd "C-c M-x")) #'cooked-meta-x))
  ;; Plain M-x is still the child's in raw state — that is the behaviour C-c M-x
  ;; exists to work around, not one to break.
  (should (eq (lookup-key cooked-raw-map (kbd "ESC")) #'cooked-send-key))
  (let (ran)
    (cl-letf (((symbol-function 'execute-extended-command) (lambda (&rest _) (interactive) (setq ran t))))
      (call-interactively #'cooked-meta-x)
      (should ran))))

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
    (should (equal (cooked--prompt-starts) (cooked--command-starts)))))

(ert-deftest cooked-evil-command-text-objects-take-the-output-and-the-command ()
  "`ic' is what the command printed; `ac' adds the prompt it was typed at and
the line itself.  Neither reaches the following prompt, which a linewise range
ending one past the output would otherwise swallow."
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
                      ("C-c M-x" . cooked-meta-x)
                      ("C-c C-z" . cooked-suspend)
                      ("C-c C-y" . cooked-paste)
                      ("C-c C-q" . cooked-send-literal-key)
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
  "`stty eof ^X\=' is as real as `stty intr ^X\='.  EOF is not a signal, so it has
no ISIG half and nothing to fall back to -- but which byte to send is still the
tty\='s to say, not ours to assume."
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

(ert-deftest cooked-send-string-and-send-literal-key-refuse-at-a-prompt ()
  "Both write to the child out of band; doing that while Emacs owns the line
would arrive ahead of whatever pending input is still sitting unsent in the
buffer, so both refuse there rather than silently confusing the two."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '$ '; cat")
    (should (cooked-tests--settle
             (lambda () (and (cooked--input-state-p) (cooked--input-start-position)))))
    (cooked--refresh-keymap)
    (should-error (cooked-send-string "ls") :type 'user-error)
    (cl-letf (((symbol-function 'read-key) (lambda (&rest _) ?a)))
      (should-error (call-interactively #'cooked-send-literal-key) :type 'user-error))))

(ert-deftest cooked-mouse-grab-is-suspended-while-peeking ()
  "A click during peek should select text like any other buffer's, not be
reinterpreted as a mouse report to a child that still owns the keyboard as
far as `cooked--input-state-p' alone can tell."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\033[?1000h\\033[?1006h'; stty raw -echo; cat -v")
    (should (cooked-tests--settle
             (lambda () (and cooked--mouse (not (cooked--input-state-p))))))
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
           (cooked-input-mode-function
            (lambda ()
              ;; Where a nested refresh comes from in the real thing.
              (unless nested
                (setq nested t)
                (cooked--refresh-keymap))
              nil)))
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

(provide 'cooked-tests-input)
;;; cooked-tests-input.el ends here
