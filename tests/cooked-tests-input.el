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
    (let ((last-input-event '(wheel-up nil 1)))
      (cooked-mouse-event))
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
  "The alt screen outranks the line discipline and the OSC 133 prompt state."
  (with-temp-buffer
    (pcase-dolist (`(,mode ,alt ,semantic ,policy ,owns ,indicator)
                   ;; mode      alt  semantic   policy    owns   mode line
                   '((cooked    nil  nil        cooked    t      " edit")
                     (cooked    nil  output     cooked    t      " edit")
                     (raw       nil  nil        raw       nil    " raw")
                     (raw       nil  output     raw       nil    " raw")
                     ;; A shell prompt: termios says raw, OSC 133 says otherwise.
                     (raw       nil  input      cooked    t      " edit")
                     (secret    nil  nil        raw       nil    " secret")
                     ;; The case that used to strand the keyboard in Emacs: a
                     ;; full-screen program starting straight from a prompt.
                     (raw       t    input      alt       nil    " alt")
                     (cooked    t    input      alt       nil    " alt")
                     (raw       t    nil        alt       nil    " alt")))
      (setq-local cooked--mode mode
                  cooked--alt alt
                  cooked--semantic semantic
                  cooked--title nil
                  cooked--exit nil)
      (should (eq (cooked--policy) policy))
      (should (eq (and (cooked--input-state-p) t) owns))
      (should (equal (cooked--mode-line) indicator)))))

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
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'x\\033[?25l'; sleep 5")
    (should (cooked-tests--settle (lambda () (null cursor-type))))
    (should-not (cooked-cursor-visible cooked--cursor))))

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
    (setq-local cooked--focused nil)
    (cooked--report-focus)
    (should (cooked-tests--settle (lambda () (equal (cooked-tests--text) ""))))))

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
            (cooked--start '("/bin/sh" "-c" "printf 'working\033[?25l'; exec cat"))
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
    (setq-local cooked--cursor (cooked--cursor-make :visible nil :shape 'bar))
    (should (null (and (cooked-cursor-visible cooked--cursor) (cooked--cursor-type))))
    (setq-local cooked--cursor (cooked--cursor-make :shape 'underline))
    (should (eq (cooked--cursor-type) 'hbar))))

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
      (should-error (cooked-evil--command-range 1 nil) :type 'user-error)
      (should (cooked-evil--command-range 1 t)))))

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

(provide 'cooked-tests-input)
;;; cooked-tests-input.el ends here
