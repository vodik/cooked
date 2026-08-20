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
      (should (cooked-tests--settle
               (lambda () (string-match-p line (cooked-tests--text))))))

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
    (should (cooked-tests--settle
             (lambda () (string-match-p "remembered" (cooked-tests--text)))))
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

(ert-deftest cooked-previous-command-lands-on-command-starts ()
  (skip-unless (executable-find "zsh"))
  (let ((buffer (generate-new-buffer "*cooked-nav*")))
    (unwind-protect
        (with-current-buffer buffer
          (cooked-mode)
          (pcase-let ((`(,argv ,env ,_scratch) (cooked--shell-invocation (executable-find "zsh"))))
            (cooked--start argv nil env))
          (cooked--refresh-keymap)
          (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input))))
          ;; Settle on the record appearing, not on the text.  Waiting for
          ;; "first-marker" matched the *echo* of the line being typed, so the second
          ;; command went out before the first had a record — the assertion below then
          ;; failed roughly two runs in five.
          (dolist (line '("echo first-marker" "echo second-marker"))
            (let ((before (length cooked--commands)))
              (cooked--replace-input line)
              (cooked-send-input)
              (should (cooked-tests--settle
                       (lambda () (> (length cooked--commands) before))))))
          (should (= (length cooked--commands) 2))
          ;; From the end, stepping back reaches the newest command's output.
          (goto-char (point-max))
          (cooked-previous-command)
          (let ((newest (cooked--command-start-position (car cooked--commands))))
            (should (= (point) newest))))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer))))

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

(provide 'cooked-tests-input)
;;; cooked-tests-input.el ends here
