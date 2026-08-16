;;; cooked-tests.el --- End-to-end tests against a real child -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cooked)
(require 'cooked-mode)

(defmacro cooked-tests--with-session (argv &rest body)
  "Run BODY in a live cooked buffer running ARGV."
  (declare (indent 1))
  `(let ((buffer (generate-new-buffer "*cooked-test*")))
     (unwind-protect
         (with-current-buffer buffer
           (cooked-mode)
           (cooked--start ,argv)
           (cooked--refresh-keymap)
           ,@body)
       (with-current-buffer buffer (cooked--cleanup))
       (kill-buffer buffer))))

(defun cooked-tests--settle (predicate &optional seconds)
  "Pump the event loop until PREDICATE holds or SECONDS elapse."
  (let ((deadline (+ (float-time) (or seconds 5))))
    (while (and (< (float-time) deadline) (not (funcall predicate)))
      (accept-process-output nil 0.05)
      (when cooked--session (cooked--apply (cooked--drain cooked--session))))
    (funcall predicate)))

(defun cooked-tests--text ()
  "Visible buffer text with trailing blank lines removed."
  (string-trim-right (buffer-substring-no-properties (point-min) (point-max))))

(ert-deftest cooked-module-loads-and-defines-its-api ()
  (cooked--load-module)
  (should (featurep 'cooked-core))
  (dolist (fn '(cooked--spawn cooked--drain cooked--send cooked--resize cooked--redraw))
    (should (fboundp fn))))

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

(defmacro cooked-tests--with-fake-zdotdir (files &rest body)
  "Run BODY with ZDOTDIR pointing at a directory built from FILES.
FILES is an alist of (NAME . CONTENTS)."
  (declare (indent 1))
  `(let* ((home (make-temp-file "cooked-fake-zdot-" t))
          (process-environment (cons (concat "ZDOTDIR=" home) process-environment)))
     (unwind-protect
         (progn
           (pcase-dolist (`(,name . ,contents) ,files)
             (with-temp-file (expand-file-name name home) (insert contents)))
           ,@body)
       (delete-directory home t))))

(ert-deftest cooked-shell-invocation-cleans-up-after-itself ()
  (pcase-let ((`(,_argv ,_env ,scratch) (cooked--shell-invocation "/bin/zsh")))
    (should (file-directory-p scratch))
    ;; zsh reads every startup file from ZDOTDIR, so all of them need a stub.
    (dolist (file '(".zshenv" ".zprofile" ".zshrc" ".zlogin"))
      (should (file-exists-p (expand-file-name file scratch))))
    (let ((cooked--scratch scratch))
      (cooked--remove-scratch)
      (should-not (file-exists-p scratch))
      (should-not cooked--scratch))))

(ert-deftest cooked-zsh-sources-the-users-zshenv ()
  "Regression: ZDOTDIR pointed at a directory with only a .zshrc, so the user's
own ~/.zshenv — where PATH and friends usually live — was never read."
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-fake-zdotdir
      '((".zshenv" . "export COOKED_ZSHENV_WITNESS=yes\n")
        (".zshrc" . "export COOKED_ZSHRC_WITNESS=yes\n"))
    (let ((buffer (generate-new-buffer "*cooked-zshenv*")))
      (unwind-protect
          (with-current-buffer buffer
            (cooked-mode)
            (pcase-let ((`(,argv ,env ,scratch)
                         (cooked--shell-invocation (executable-find "zsh"))))
              (setq cooked--scratch scratch)
              (cooked--start argv nil env))
            (cooked--refresh-keymap)
            (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input))))
            (cooked--send cooked--session "echo env=$COOKED_ZSHENV_WITNESS rc=$COOKED_ZSHRC_WITNESS\r")
            (should (cooked-tests--settle
                     (lambda () (string-match-p "env=yes rc=yes" (cooked-tests--text)))))
            ;; And ZDOTDIR is handed back, so nested shells still find the real config.
            ;; Compared against the actual paths, not a literal /tmp: macOS puts temp
            ;; files under $TMPDIR in /var/folders.
            (let ((user-zdotdir (getenv "ZDOTDIR")))
              (cooked--send cooked--session "echo zdot=$ZDOTDIR\r")
              (should (cooked-tests--settle
                       (lambda () (string-match-p (concat "zdot=" (regexp-quote user-zdotdir))
                                                  (cooked-tests--text)))))
              (should-not (string-match-p (concat "zdot=" (regexp-quote cooked--scratch))
                                          (cooked-tests--text)))))
        (with-current-buffer buffer (cooked--cleanup))
        (kill-buffer buffer)))))

(ert-deftest cooked-zsh-survives-a-theme-that-rebuilds-the-prompt ()
  "Regression: the 133;B mark was appended to PS1 once at source time, so any
theme rebuilding PS1 from its own precmd dropped it — and with it the whole
hand-the-keyboard-back feature.  Exit codes broke the same way, because our
precmd then ran after the theme's and read its status instead of the command's."
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-fake-zdotdir
      '((".zshrc" . "__theme_precmd() { PS1='theme%% ' }\n\
autoload -Uz add-zsh-hook\n\
add-zsh-hook precmd __theme_precmd\n"))
    (let ((buffer (generate-new-buffer "*cooked-theme*")))
      (unwind-protect
          (with-current-buffer buffer
            (cooked-mode)
            (pcase-let ((`(,argv ,env ,scratch)
                         (cooked--shell-invocation (executable-find "zsh"))))
              (setq cooked--scratch scratch)
              (cooked--start argv nil env))
            (cooked--refresh-keymap)
            ;; Only an OSC 133;B can put us here.
            (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input))))
            ;; And the exit code still belongs to the command, not the theme's hook.
            (cooked--replace-input "exit 7")
            (cooked--send cooked--session "(exit 7)\r")
            (should (cooked-tests--settle
                     (lambda () (eql (cooked-last-exit-code) 7)))))
        (with-current-buffer buffer (cooked--cleanup))
        (kill-buffer buffer)))))

(ert-deftest cooked-cleanup-kills-the-child-without-waiting-for-gc ()
  "Clearing the Lisp variable only drops a reference; nothing guarantees a
collection ever runs, so the child has to be killed explicitly."
  (let ((buffer (generate-new-buffer "*cooked-kill*")) pid)
    (unwind-protect
        (with-current-buffer buffer
          (cooked-mode)
          (cooked--start '("/bin/sh" "-c" "sleep 300"))
          (setq pid (cooked--pid cooked--session))
          (should (zerop (call-process "kill" nil nil nil "-0" (number-to-string pid))))
          (cooked--cleanup)
          (should-not cooked--session)
          (should-not (zerop (call-process "kill" nil nil nil "-0" (number-to-string pid)))))
      (kill-buffer buffer))))

(ert-deftest cooked-core-refuses-values-that-are-not-sessions ()
  "The core compares a user-pointer's finalizer against its own before casting.
Emacs cannot tell one module's user-pointer from another's, so without that check
a foreign handle would be reinterpreted as a session."
  ;; No session here, so nothing else has pulled the core in yet.
  (cooked--load-module)
  (should-error (cooked--send 42 "x") :type 'wrong-type-argument)
  (should-error (cooked--send "not a session" "x") :type 'wrong-type-argument)
  (should-error (cooked--pid nil) :type 'wrong-type-argument)
  (should-error (cooked--kill (make-marker)) :type 'wrong-type-argument))

(ert-deftest cooked-raw-mode-passes-keys-through ()
  (cooked-tests--with-session '("/bin/sh" "-c" "stty -icanon -echo; sleep 5")
    (should (cooked-tests--settle (lambda () (eq cooked--mode 'raw))))
    (should-not (cooked--input-state-p))
    (should (eq (current-local-map) cooked-raw-map))))

(defmacro cooked-tests--with-echoing-child (setup &rest body)
  "Run BODY against a raw child that echoes what it receives, visibly.
SETUP is shell run before it, for turning bracketed paste on.  `cat -v' spells
control characters out, so what the child was actually sent can be read straight
off the buffer."
  (declare (indent 1))
  `(cooked-tests--with-session
       (list "/bin/sh" "-c" (concat ,setup "stty raw -echo; cat -v"))
     (should (cooked-tests--settle (lambda () (eq cooked--mode 'raw))))
     (should-not (cooked--input-state-p))
     ,@body))

(defmacro cooked-tests--with-kill (text &rest body)
  "Run BODY with TEXT as the most recent kill and no clipboard in the way."
  (declare (indent 1))
  `(let* ((interprogram-paste-function nil)
          (kill-ring (list ,text))
          (kill-ring-yank-pointer kill-ring))
     ,@body))

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
             (lambda () (and (cooked--input-state-p) cooked--input-start))))
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
             (lambda () (and (cooked--input-state-p) cooked--input-start))))
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

(ert-deftest cooked-osc-133-drives-the-input-state ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "stty -icanon -echo; printf '\\033]133;A\\007$ \\033]133;B\\007'; sleep 5")
    ;; Raw mode would normally mean pass-through; the shell's mark overrides it.
    (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input))))
    (should (eq cooked--mode 'raw))
    (should (cooked--input-state-p))
    (should (eq (current-local-map) cooked-input-map))))

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
    ;; The raw map owns the wheel while the child does; otherwise Emacs would
    ;; scroll the buffer out from under a full-screen program.
    (should (eq (current-local-map) cooked-raw-map))
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

(ert-deftest cooked-alt-screen-takes-the-keyboard-from-a-prompt ()
  "Entering the alt screen must swap the keymap even mid-prompt."
  (with-temp-buffer
    (cooked-mode)
    (setq-local cooked--mode 'raw cooked--semantic 'input cooked--alt nil)
    (cooked--refresh-keymap)
    (should (eq (current-local-map) cooked-input-map))
    (cooked--set-alt t)
    (should (eq (current-local-map) cooked-raw-map))
    (cooked--set-alt nil)
    (should (eq (current-local-map) cooked-input-map))))

;; MARKER is pushed into real scrollback by the lines that follow it — the point
;; being that it is history, not screen content, which the alt screen hides anyway.
(defconst cooked-tests--scrollback-then-alt
  "printf 'MARKER\\n'; seq 1 60; printf '\\033[?1049h'; printf 'inalt\\n'; ")

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

(ert-deftest cooked-exit-status-is-reported ()
  (cooked-tests--with-session '("/bin/sh" "-c" "exit 9")
    (should (cooked-tests--settle
             (lambda () (string-match-p "\\[exited 9\\]" (cooked-tests--text)))))))

(defun cooked-tests--run-until-dead (argv seconds)
  "Run ARGV in a cooked buffer and pump for up to SECONDS, killing it if alive.
Returns non-nil when the buffer killed itself along the way."
  (let ((buffer (generate-new-buffer "*cooked-test*")))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (cooked-mode)
            (cooked--start argv))
          (let ((deadline (+ (float-time) seconds)))
            (while (and (< (float-time) deadline) (buffer-live-p buffer))
              (accept-process-output nil 0.05)
              ;; Timers, so the deferred kill actually fires.
              (sit-for 0)
              (when (buffer-live-p buffer)
                (with-current-buffer buffer
                  (when cooked--session
                    (cooked--apply (cooked--drain cooked--session)))))))
          (not (buffer-live-p buffer)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (cooked--cleanup))
        (kill-buffer buffer)))))

(ert-deftest cooked-buffer-is-kept-on-exit-by-default ()
  (should-not (cooked-tests--run-until-dead '("/bin/sh" "-c" "exit 0") 1)))

(ert-deftest cooked-buffer-can-close-itself-on-exit ()
  (let ((cooked-kill-buffer-on-exit t))
    (should (cooked-tests--run-until-dead '("/bin/sh" "-c" "exit 3") 5))))

(ert-deftest cooked-buffer-can-close-itself-only-on-success ()
  (let ((cooked-kill-buffer-on-exit 'on-success))
    (should (cooked-tests--run-until-dead '("/bin/sh" "-c" "exit 0") 5))
    (should-not (cooked-tests--run-until-dead '("/bin/sh" "-c" "exit 3") 1))))

(ert-deftest cooked-buffer-close-can-be-decided-by-a-function ()
  (let ((cooked-kill-buffer-on-exit (lambda (code) (eql code 7))))
    (should (cooked-tests--run-until-dead '("/bin/sh" "-c" "exit 7") 5))
    (should-not (cooked-tests--run-until-dead '("/bin/sh" "-c" "exit 8") 1))))

(ert-deftest cooked-real-bash-reaches-input-state-at-its-prompt ()
  "The headline case: a real interactive shell, whose prompt is raw-mode."
  (skip-unless (executable-find "bash"))
  (let ((buffer (generate-new-buffer "*cooked-bash*")))
    (unwind-protect
        (with-current-buffer buffer
          (cooked-mode)
          (pcase-let ((`(,argv ,env ,_scratch) (cooked--shell-invocation (executable-find "bash"))))
            (cooked--start argv nil env))
          (cooked--refresh-keymap)
          ;; The shell's own line editor puts the tty in raw mode...
          (should (cooked-tests--settle (lambda () (eq cooked--mode 'raw))))
          ;; ...yet OSC 133 still hands the line to Emacs.
          (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input))))
          (should (cooked--input-state-p))
          (should (eq (current-local-map) cooked-input-map))
          ;; Submitting runs the command and the output is attributed to it.
          (cooked--restore-pending-input nil)
          (goto-char cooked--input-end)
          (insert "echo marker-ok")
          (cooked-send-input)
          (should (cooked-tests--settle
                   (lambda () (string-match-p "marker-ok" (cooked-tests--text)))))
          (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input)))))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer))))

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
      (should (get-text-property pos 'font-lock-face))
      (should (equal (plist-get (get-text-property pos 'font-lock-face) :foreground)
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
    (should (marker-position cooked--input-start))
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

(ert-deftest cooked-comint-commands-are-remapped ()
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle (lambda () (eq cooked--mode 'cooked))))
    ;; evil-collection binds `repl-submit' to `comint-send-input'; the remap is
    ;; what makes that reach us.
    (should (eq (key-binding [remap comint-send-input]) #'cooked-send-input))
    (should (eq (key-binding [remap comint-interrupt-subjob]) #'cooked-interrupt))
    (should (keymap-parent cooked-input-map))))

(ert-deftest cooked-zsh-reports-command-exit-codes ()
  "Regression: `local status=$?' fails in zsh, which silently killed OSC 133;D."
  (skip-unless (executable-find "zsh"))
  (let ((buffer (generate-new-buffer "*cooked-zsh*")))
    (unwind-protect
        (with-current-buffer buffer
          (cooked-mode)
          (pcase-let ((`(,argv ,env ,_scratch) (cooked--shell-invocation (executable-find "zsh"))))
            (cooked--start argv nil env))
          (cooked--refresh-keymap)
          (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input))))
          (should-not (string-match-p "read-only variable" (cooked-tests--text)))
          (cooked--restore-pending-input nil)
          (goto-char cooked--input-end)
          (insert "(exit 42)")
          (cooked-send-input)
          (should (cooked-tests--settle (lambda () (cooked-last-exit-code))))
          (should (equal (cooked-last-exit-code) 42))
          ;; A command that printed nothing still gets a record.
          (should (= 1 (length cooked--commands)))
          ;; And a second one with output is tagged in the text too.
          (cooked--restore-pending-input nil)
          (goto-char cooked--input-end)
          (insert "echo out-marker")
          (cooked-send-input)
          (should (cooked-tests--settle
                   (lambda () (equal (cooked-last-exit-code) 0))))
          (should (string-match-p "out-marker" (cooked-tests--text))))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer))))

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
          (should (cooked-tests--settle
                   (lambda () (and (eq cooked--semantic 'output)
                                   (eq (current-local-map) cooked-raw-map)))))
          (should (eq evil-state 'emacs))

          ;; ...and hands it back at the next prompt.
          (should (cooked-tests--settle
                   (lambda () (and (eq cooked--semantic 'input)
                                   (eq (current-local-map) cooked-input-map)))))
          (should (eq evil-state 'insert)))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer))))

(ert-deftest cooked-prompt-trailing-space-is-preserved ()
  "Trimming trailing blanks would put the input one column left of the prompt."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'ready$ '; exec cat")
    (should (cooked-tests--settle
             (lambda () (string-match-p "ready" (cooked-tests--text)))))
    (should (marker-position cooked--input-start))
    (goto-char cooked--input-start)
    (should (equal (char-before) ?\s))
    (should (equal (buffer-substring-no-properties (line-beginning-position)
                                                   cooked--input-start)
                   "ready$ "))))

(ert-deftest cooked-cursor-visibility-follows-the-child ()
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'x\\033[?25l'; sleep 5")
    (should (cooked-tests--settle (lambda () (null cursor-type))))
    (should-not (nth 2 cooked--cursor))))

(ert-deftest cooked-input-history-recalls-submissions ()
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle
             (lambda () (and (eq cooked--mode 'cooked) cooked--input-start))))
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

(ert-deftest cooked-history-preserves-work-in-progress ()
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle
             (lambda () (and (eq cooked--mode 'cooked) cooked--input-start))))
    (cooked--replace-input "remembered")
    (cooked-send-input)
    (should (cooked-tests--settle
             (lambda () (string-match-p "remembered" (cooked-tests--text)))))
    (cooked--replace-input "half-typed")
    (cooked-previous-input)
    (should (equal (cooked--pending-input) "remembered"))
    (cooked-next-input)
    (should (equal (cooked--pending-input) "half-typed"))))

(ert-deftest cooked-resize-reaches-sessions-in-other-buffers ()
  "`window-size-change-functions' runs per frame, not per buffer."
  (cooked-tests--with-session '("/bin/sh" "-c" "while true; do sleep 0.1; done")
    (should (cooked-tests--settle (lambda () cooked--session)))
    (let ((buffer (current-buffer)))
      (set-window-buffer (selected-window) buffer)
      (setq cooked--last-size nil)
      ;; Run the global hook from a different current buffer, as Emacs does.
      (with-temp-buffer
        (cooked--frame-size-changed (selected-frame)))
      (with-current-buffer buffer
        (should cooked--last-size)
        (should (= (car cooked--last-size)
                   (cooked--window-rows (get-buffer-window buffer))))
        (should (= (cdr cooked--last-size)
                   (window-max-chars-per-line (get-buffer-window buffer))))))))

(ert-deftest cooked-terminfo-is-installed-and-used ()
  "The child should see a TERM that describes what we actually implement."
  (skip-unless (executable-find "tic"))
  (should (equal (cooked--terminfo) cooked-term-name))
  (should (cooked--terminfo-known-p cooked-term-name))
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '%s|%s\\n' \"$TERM\" \"$(tput colors)\"; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p (regexp-quote cooked-term-name)
                                        (cooked-tests--text)))))
    ;; The entry resolves on the child's side, not just ours.
    (should (string-match-p "|256" (cooked-tests--text)))))

(ert-deftest cooked-terminfo-falls-back-when-unavailable ()
  (let ((cooked-term-name nil))
    (should (equal (cooked--terminfo) "xterm-256color"))))

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
    (should (marker-position cooked--input-start))))

(ert-deftest cooked-cursor-position-does-not-mutate ()
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle (lambda () cooked--input-start)))
    ;; Ask for a row far below the trimmed screen; it must not extend the buffer.
    (let ((cooked--cursor (list (+ 5 cooked--rows) 0 t))
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
    (should (cooked-tests--settle (lambda () cooked--input-start)))
    ;; The child never enabled reporting, so `cooked-mouse-event' takes the
    ;; fallback branch and the click behaves as it would in any buffer.
    (should-not cooked--mouse)
    (should (eq (lookup-key cooked-raw-map [mouse-1]) #'cooked-mouse-event))))

(ert-deftest cooked-does-not-pin-lines-and-columns ()
  "Regression: exporting LINES/COLUMNS makes ncurses ignore the tty size, so a
full-screen program keeps its startup geometry and never honours SIGWINCH."
  (let ((env (cooked--child-environment)))
    (should-not (assoc "LINES" env))
    (should-not (assoc "COLUMNS" env)))
  ;; Also stripped when inherited from the Emacs that launched us.
  (let* ((process-environment (append '("LINES=11" "COLUMNS=22") process-environment))
         (env (cooked--child-environment)))
    (should-not (assoc "LINES" env))
    (should-not (assoc "COLUMNS" env))))

(ert-deftest cooked-full-screen-programs-redraw-after-a-resize ()
  "End to end: htop must move its footer when the terminal grows."
  (skip-unless (executable-find "htop"))
  (let ((buffer (generate-new-buffer "*cooked-htop*")))
    (unwind-protect
        (with-current-buffer buffer
          (cooked-mode)
          (setq cooked--rows 20 cooked--cols 90 cooked--last-size '(20 . 90))
          (cooked--start '("htop" "-d" "5"))
          (cooked--refresh-keymap)
          (cl-flet ((footer-row ()
                      (save-excursion
                        (goto-char (marker-position cooked--screen-start))
                        (let ((i 0) found)
                          (while (and (not found) (not (eobp)))
                            (when (string-match-p "F10" (buffer-substring-no-properties
                                                         (line-beginning-position)
                                                         (line-end-position)))
                              (setq found i))
                            (setq i (1+ i))
                            (forward-line 1))
                          found))))
            (should (cooked-tests--settle (lambda () (eql (footer-row) 19)) 8))
            (setq cooked--rows 40 cooked--last-size '(40 . 90))
            (cooked--resize cooked--session 40 90)
            (should (cooked-tests--settle (lambda () (eql (footer-row) 39)) 8))
            (should (= (count-lines (marker-position cooked--screen-start) (point-max)) 40))))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer))))

;;;; Generic OSC dispatch

(ert-deftest cooked-osc-handlers-are-extensible-without-rust ()
  "The point of the passthrough: a new sequence is a few lines of Lisp."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '\\033]12345;hello;there\\007'; sleep 5")
    (let* ((seen nil)
           (cooked-osc-handlers (cons (cons 12345 (lambda (parts) (setq seen parts)))
                                      cooked-osc-handlers)))
      (should (cooked-tests--settle (lambda () seen)))
      (should (equal seen '("hello" "there"))))))

(ert-deftest cooked-osc-title-reaches-the-mode-line ()
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '\\033]2;my-title\\007'; sleep 5")
    (should (cooked-tests--settle (lambda () (equal cooked--title "my-title"))))
    (should (string-match-p "my-title" (cooked--mode-line)))))

(ert-deftest cooked-osc-handler-errors-do-not-break-redisplay ()
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '\\033]2;boom\\007'; printf 'after\\n'; sleep 5")
    (let ((cooked-osc-handlers '((2 . (lambda (_parts) (error "deliberate"))))))
      ;; The handler blows up, but output after it still renders.
      (should (cooked-tests--settle
               (lambda () (string-match-p "after" (cooked-tests--text))))))))

;;;; OSC 51 — the Emacs command channel
;;
;; Opt-in, so these load it explicitly.  `cooked-osc-51-is-closed-until-opted-in'
;; below covers the other half: that it really is closed until you do.

(require 'cooked-osc-eval)

(ert-deftest cooked-osc-51-is-closed-until-opted-in ()
  "The command channel is the one place terminal output becomes action, so it
must do nothing at all until the user has loaded `cooked-osc-eval' on purpose."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let ((cooked-osc-eval-function nil)
          (ran nil))
      (let ((cooked-eval-commands `(("find-file" . ,(lambda (&rest _) (setq ran t))))))
        (cooked--osc-emacs '("E\"find-file\" \"/tmp/x\""))
        (should-not ran))
      ;; The annotation half is inert, so it keeps working without opting in.
      (cooked--osc-emacs '("Asimon@host:~"))
      (should (equal cooked--annotation "simon@host:~")))))

(ert-deftest cooked-osc-51-runs-allowlisted-commands ()
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let* ((called nil)
           (cooked-eval-commands `(("noted" . ,(lambda (&rest args) (setq called args))))))
      (cooked--osc-emacs '("E\"noted\" \"one\" \"two\""))
      (should (equal called '("one" "two"))))))

(ert-deftest cooked-osc-51-refuses-anything-not-allowlisted ()
  "The allowlist is the entire defence: output from a hostile host reaches here."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let ((cooked-eval-commands '(("find-file" . ignore)))
          (danger nil))
      (cl-letf (((symbol-function 'shell-command)
                 (lambda (&rest _) (setq danger t))))
        (cooked--osc-emacs '("E\"shell-command\" \"rm -rf /\""))
        (should-not danger))
      ;; Nor by interning a name that merely exists as a function.
      (cl-letf (((symbol-function 'delete-file)
                 (lambda (&rest _) (setq danger t))))
        (cooked--osc-emacs '("E\"delete-file\" \"/tmp/x\""))
        (should-not danger)))))

(ert-deftest cooked-osc-51-does-not-run-shell-commands-by-default ()
  "`compile' would turn any terminal output into arbitrary execution."
  (should-not (assoc "compile" cooked-eval-commands))
  (should-not (assoc "recompile" cooked-eval-commands)))

(ert-deftest cooked-osc-51-rejoins-payloads-split-on-semicolons ()
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let* ((got nil)
           (cooked-eval-commands `(("open" . ,(lambda (path) (setq got path))))))
      ;; The emulator split this into two parts; the handler must put it back.
      (cooked--osc-emacs '("E\"open\" \"/tmp/a" "b\""))
      (should (equal got "/tmp/a;b")))))

(ert-deftest cooked-osc-51-annotation-is-recorded ()
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (cooked--osc-emacs '("Asimon@ryzen:~/src"))
    (should (equal cooked--annotation "simon@ryzen:~/src"))))

(ert-deftest cooked-find-file-works-end-to-end-from-the-shell ()
  "The headline trick: a shell function opens a buffer in the Emacs running it."
  (skip-unless (executable-find "zsh"))
  (let ((buffer (generate-new-buffer "*cooked-zsh*"))
        (target (make-temp-file "cooked-open")))
    (unwind-protect
        (with-current-buffer buffer
          (cooked-mode)
          (pcase-let ((`(,argv ,env ,_scratch) (cooked--shell-invocation (executable-find "zsh"))))
            (cooked--start argv nil env))
          (cooked--refresh-keymap)
          (should (cooked-tests--settle (lambda () (eq cooked--semantic 'input))))
          (let ((opened nil))
            (let ((cooked-eval-commands `(("find-file" . ,(lambda (f) (setq opened f))))))
              (cooked--replace-input (format "find_file %s" target))
              (cooked-send-input)
              (should (cooked-tests--settle (lambda () opened) 8))
              (should (equal opened target)))))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer)
      (delete-file target))))

;;;; OSC 52 — clipboard

(ert-deftest cooked-osc-52-copies-to-the-kill-ring ()
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '\\033]52;c;aGVsbG8gd29ybGQ=\\007'; sleep 5")
    (let ((kill-ring nil))
      (should (cooked-tests--settle
               (lambda () (equal (car kill-ring) "hello world")))))))

(ert-deftest cooked-osc-52-never-answers-a-read ()
  "Replying to a query would hand the clipboard to whatever asked."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let ((kill-ring '("secret")))
      (cooked--osc-clipboard '("c" "?"))
      ;; Nothing added, and nothing written back to the child.
      (should (equal kill-ring '("secret"))))))

(ert-deftest cooked-osc-52-can-be-refused-entirely ()
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let ((cooked-clipboard-write nil)
          (kill-ring nil))
      (cooked--osc-clipboard '("c" "aGVsbG8="))
      (should-not kill-ring))))

;;;; OSC 10/11/12 — the default colors
;;
;; The child is put in raw mode first: the reply carries no newline, so a canonical
;; read would sit on it forever, and echo would put it in the buffer instead.

(defun cooked-tests--reply-to (query out)
  "Shell that sends QUERY, then copies whatever comes back into OUT."
  (list "/bin/sh" "-c"
        (format "stty raw -echo; printf '%s'; cat > %s" query out)))

(defun cooked-tests--contents (file)
  "Contents of FILE, or the empty string if it has none yet."
  (with-temp-buffer
    (ignore-errors (insert-file-contents file))
    (buffer-string)))

(ert-deftest cooked-osc-11-answers-a-background-query ()
  "Theme-aware programs block on this before picking a light or dark palette,
so a terminal that never answers costs them their whole timeout on startup."
  (let ((out (make-temp-file "cooked-osc11")))
    (unwind-protect
        (cooked-tests--with-session (cooked-tests--reply-to "\\033]11;?\\007" out)
          (should (cooked-tests--settle
                   (lambda () (string-match-p "rgb:" (cooked-tests--contents out)))))
          (should (string-match-p
                   "\\`\033\\]11;rgb:[0-9a-f]\\{4\\}/[0-9a-f]\\{4\\}/[0-9a-f]\\{4\\}\007\\'"
                   (cooked-tests--contents out))))
      (delete-file out))))

(ert-deftest cooked-osc-color-reply-echoes-the-terminator-it-was-asked-with ()
  "A client that queried with ST does not recognise a BEL-terminated answer."
  (let ((out (make-temp-file "cooked-osc10")))
    (unwind-protect
        (cooked-tests--with-session (cooked-tests--reply-to "\\033]10;?\\033\\\\" out)
          (should (cooked-tests--settle
                   (lambda () (string-match-p "rgb:" (cooked-tests--contents out)))))
          (should (string-suffix-p "\033\\" (cooked-tests--contents out)))
          (should (string-prefix-p "\033]10;rgb:" (cooked-tests--contents out))))
      (delete-file out))))

(ert-deftest cooked-osc-color-answers-each-part-of-a-chained-query ()
  "`ESC ] 10 ; ? ; ? ST' asks for the foreground and then the background."
  (let ((out (make-temp-file "cooked-osc-chain")))
    (unwind-protect
        (cooked-tests--with-session (cooked-tests--reply-to "\\033]10;?;?\\007" out)
          (should (cooked-tests--settle
                   (lambda () (string-match-p "11;rgb:" (cooked-tests--contents out)))))
          (should (string-match-p "\\`\033\\]10;rgb:[^\007]+\007\033\\]11;rgb:"
                                  (cooked-tests--contents out))))
      (delete-file out))))

(ert-deftest cooked-osc-color-sets-are-refused-by-default ()
  "Anything that can write to the terminal can send one, so it is opt-in."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let ((cooked--osc-code 11)
          (cooked--osc-bell-terminated t))
      (cooked--osc-color '("#ff0000"))
      (should-not cooked--color-remaps)
      (let ((cooked-allow-color-set t))
        (cooked--osc-color '("#ff0000"))
        (should (alist-get 'background cooked--color-remaps))
        ;; Buffer-local, not frame-wide: the child repaints its own terminal only.
        (should (member '(:background "#ff0000")
                        (alist-get 'default face-remapping-alist))))
      ;; OSC 111 puts the theme's own background back.
      (let ((cooked--osc-code 111))
        (cooked--osc-color-reset nil))
      (should-not cooked--color-remaps))))

(ert-deftest cooked-osc-color-parses-the-xterm-spellings ()
  "Channels are scaled by width, not zero-padded: rgb:f/f/f is white."
  (should (equal (cooked--parse-osc-color "rgb:ffff/0000/0000") "#ffff00000000"))
  (should (equal (cooked--parse-osc-color "rgb:f/0/0") "#ffff00000000"))
  (should (equal (cooked--parse-osc-color "#ff0000") "#ff0000"))
  (should-not (cooked--parse-osc-color "rgb:fffff/0/0"))
  (should-not (cooked--parse-osc-color "not-a-color")))

(ert-deftest cooked-clear-scrollback-keeps-the-live-screen ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "for i in $(seq 60); do printf 'line%s\\n' $i; done; exec cat")
    (should (cooked-tests--settle
             (lambda () (string-match-p "line60" (cooked-tests--text)))))
    (should (string-match-p "line1\n" (cooked-tests--text)))
    (cooked-clear-scrollback)
    (should-not (string-match-p "line1\n" (cooked-tests--text)))
    (should (string-match-p "line60" (cooked-tests--text)))))

(defconst cooked-tests--erase-scrollback-script
  "for i in $(seq 60); do printf 'line%s\\n' $i; done; sleep 1; printf '\\033[3J'; exec cat"
  "Print enough to fill scrollback, settle, then the child erases it.

The `sleep' matters: it lets a test observe the buffer in its pre-erase state
before the `CSI 3 J' this is testing for ever arrives, rather than racing to
read output that a fast child overwrites before the test gets a look at it.")

(ert-deftest cooked-child-erase-scrollback-is-ignored-by-default ()
  "`CSI 3 J' is xterm's `clear -x'; a program should not be able to wipe
history just because it can write to the terminal.  Unlike `2 J', real
xterm's `3 J' never touches the visible screen either, only scrollback."
  (should-not cooked-honor-erase-scrollback)
  (cooked-tests--with-session (list "/bin/sh" "-c" cooked-tests--erase-scrollback-script)
    (should (cooked-tests--settle
             (lambda () (string-match-p "line60" (cooked-tests--text)))))
    (should (string-match-p "line1\n" (cooked-tests--text)))
    ;; Give the child's `3 J', sent after its sleep, time to arrive and be ignored.
    (cooked-tests--settle #'ignore 1.5)
    (should (string-match-p "line1\n" (cooked-tests--text)))
    (should (string-match-p "line60" (cooked-tests--text)))))

(ert-deftest cooked-child-erase-scrollback-can-be-honored ()
  (let ((cooked-honor-erase-scrollback t))
    (cooked-tests--with-session (list "/bin/sh" "-c" cooked-tests--erase-scrollback-script)
      (should (cooked-tests--settle
               (lambda () (string-match-p "line60" (cooked-tests--text)))))
      (should (string-match-p "line1\n" (cooked-tests--text)))
      (should (cooked-tests--settle
               (lambda () (not (string-match-p "line1\n" (cooked-tests--text))))
               3))
      ;; The live screen is untouched: real xterm's `3 J' never erases it.
      (should (string-match-p "line60" (cooked-tests--text))))))

;;;; Packaging

(ert-deftest cooked-buffer-names-are-configurable-and-unique ()
  (let ((cooked-buffer-name "*cooked: %s*"))
    (should (string-match-p "\\*cooked: .+\\*" (cooked--buffer-name "/tmp/")))
    (let ((buffer (generate-new-buffer (cooked--buffer-name "/tmp/"))))
      (unwind-protect
          ;; A second session in the same directory must not collide.
          (should-not (equal (buffer-name buffer) (cooked--buffer-name "/tmp/")))
        (kill-buffer buffer))))
  (let ((cooked-buffer-name (lambda (dir) (format "term[%s]" dir))))
    (should (equal (cooked--buffer-name "/tmp/") "term[/tmp/]"))))

(ert-deftest cooked-title-renames-the-buffer-only-when-asked ()
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '\\033]2;running-thing\\007'; sleep 5")
    (let ((original (buffer-name)))
      (should (cooked-tests--settle (lambda () (equal cooked--title "running-thing"))))
      ;; Default is off: a name that moves under you is hard to find again.
      (should (equal (buffer-name) original)))))

(ert-deftest cooked-live-buffers-finds-running-sessions ()
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (should (memq (current-buffer) (cooked--live-buffers)))))

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

(defun cooked-tests--type (keys)
  "Run KEYS through the command loop, so `pre-command-hook' applies."
  (execute-kbd-macro (kbd keys)))

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
          (goto-char (1- (marker-position cooked--input-start)))
          (cooked-tests--type "h i")
          (should (equal (cooked--pending-input) "hi")))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer))))

(ert-deftest cooked-window-rows-round-a-partial-row-down ()
  "A row only half on screen is not a row the child can use."
  (let* ((window (selected-window))
         (line (window-default-line-height window))
         (rows (cooked--window-rows window)))
    (should (integerp rows))
    ;; The claimed rows must fit in the pixels actually available.
    (should (<= (* rows line) (window-body-height window t)))
    ;; And be the largest number that does.
    (should (> (* (1+ rows) line) (window-body-height window t)))))

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

;;;; Completion

(ert-deftest cooked-completion-offers-programs-then-files ()
  (cooked-tests--with-session '("/bin/sh" "-c" "printf 'ready$ '; exec cat")
    (should (cooked-tests--settle
             (lambda () (and (string-match-p "ready" (cooked-tests--text))
                             cooked--input-start))))
    ;; First word: programs on PATH.
    (goto-char cooked--input-end)
    (insert "ls")
    (pcase-let ((`(,start ,end ,table . ,_) (cooked-completion-at-point)))
      (should (= start (marker-position cooked--input-start)))
      (should (= end (point)))
      (should (member "ls" (all-completions "ls" table))))
    ;; Later words complete as file names, relative to the child's directory.
    (insert " REA")
    (pcase-let ((`(,start ,end ,table . ,_) (cooked-completion-at-point)))
      (should (> start (marker-position cooked--input-start)))
      (should (= end (point)))
      (let ((default-directory (file-name-directory
                                (directory-file-name cooked--source-directory))))
        (should (member "README.md" (all-completions "REA" table)))))))

(ert-deftest cooked-size-follows-the-smallest-window ()
  "One child, possibly several windows: the largest would wrap in the smallest."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (let ((buffer (current-buffer)))
      (delete-other-windows)
      (set-window-buffer (selected-window) buffer)
      (let* ((tall (cdr (cooked--window-size)))
             (other (split-window (selected-window) nil 'right)))
        (set-window-buffer other buffer)
        ;; Two windows now, each narrower than the original single one.
        (should (= (length (get-buffer-window-list buffer nil t)) 2))
        (pcase-let ((`(_ . ,cols) (cooked--window-size)))
          (should (< cols tall))
          (should (= cols (apply #'min (mapcar #'window-max-chars-per-line
                                               (get-buffer-window-list buffer nil t))))))
        (delete-window other)))))

(defconst cooked-tests--two-stage-output-script
  "for i in $(seq 40); do printf 'line%s\\n' $i; done; sleep 1; printf 'AFTER\\n'; exec cat"
  "Enough lines to build real scrollback, then more output after a pause a
test can settle across — see `cooked-tests--erase-scrollback-script'.")

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

(ert-deftest cooked-completion-is-a-normal-capf ()
  "So corfu, cape and friends work without knowing about cooked."
  (cooked-tests--with-session '("/bin/cat")
    (should (cooked-tests--settle (lambda () cooked--input-start)))
    (should (memq #'cooked-completion-at-point completion-at-point-functions))
    (should (eq (lookup-key cooked-input-map (kbd "TAB")) #'completion-at-point))))

(ert-deftest cooked-completion-declines-outside-the-input-line ()
  "Raw-mode programs get their own TAB; we must not complete over them."
  (cooked-tests--with-session '("/bin/sh" "-c" "stty -icanon -echo; sleep 5")
    (should (cooked-tests--settle (lambda () (eq cooked--mode 'raw))))
    (should-not (cooked-completion-at-point))))

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

(defmacro cooked-tests--with-straddling-line (&rest body)
  "Run BODY with a 4x10 session holding one 59-character line.
Six rows of one logical line through a four-row screen: two rows have gone to
Emacs while the rest is still on the grid, so the line spans the seam between
them — the arrangement every seam bug needs."
  (declare (indent 0))
  `(let ((buffer (generate-new-buffer "*cooked-seam*")))
     (unwind-protect
         (with-current-buffer buffer
           (cooked-mode)
           (setq cooked--rows 4 cooked--cols 10 cooked--last-size '(4 . 10))
           (cooked--start '("/bin/sh" "-c"
                            "printf '%s' 00000000001111111111222222222233333333334444444444555555555; \
                             sleep 5"))
           (cooked--refresh-keymap)
           (should (cooked-tests--settle
                    (lambda () (string-match-p "555555555" (cooked-tests--text)))))
           ,@body)
       (with-current-buffer buffer (cooked--cleanup))
       (kill-buffer buffer))))

(defun cooked-tests--resize (rows cols)
  "Resize the session to ROWS by COLS and let the redraw land."
  (setq cooked--last-size nil cooked--rows rows cooked--cols cols)
  (cooked--resize cooked--session rows cols)
  (cooked-tests--settle (lambda () nil) 0.3))

(defun cooked-tests--unwrapped ()
  "Buffer text with the line structure taken out."
  (string-replace "\n" "" (cooked-tests--text)))

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
      (should (string-match-p whole (cooked-tests--unwrapped))))))

(ert-deftest cooked-clearing-scrollback-across-the-seam-keeps-the-screen ()
  "`cooked-clear-scrollback' can cut a line in half: its head is scrollback and
its tail is the top of the screen.  The screen must survive intact, and the
emulator must be told, so the next rewrap does not resume a line that is gone."
  (cooked-tests--with-straddling-line
    (cooked-clear-scrollback)
    (should (string-prefix-p "2222222222" (cooked-tests--text)))

    (cooked-tests--resize 4 30)
    (should (string-match-p "222222222233333333334444444444555555555"
                            (cooked-tests--unwrapped)))
    (should-not (string-match-p "0000000000" (cooked-tests--text)))))

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

;; `cooked--guard-row-width' exists to catch a live row Emacs softwraps despite
;; every such row being meant as one hard-newlined buffer line -- the symptom of
;; a character's real rendered width disagreeing with what `cooked--cols'
;; assumed for it. Batch Emacs has no real display, so `vertical-motion' never
;; actually simulates a softwrap here regardless of window width or content
;; (confirmed empirically: even a 27-character line in a 4-column window lands
;; `vertical-motion' at the true end of the line, not partway through) -- the
;; same limitation `cooked-new-output-recenters-a-following-window' documents
;; for `recenter'. These tests mock `vertical-motion' to report a wrap after a
;; fixed number of characters, which exercises the trim-and-mark mechanics
;; `cooked--guard-row-width' actually owns, in place of the wrap detection
;; itself, which is just a direct call to Emacs' own primitive.

(defmacro cooked-tests--with-mocked-wrap (limit &rest body)
  "Run BODY with `vertical-motion' reporting a wrap after LIMIT characters."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'vertical-motion)
              (lambda (&rest _) (goto-char (min (point-max) (+ (point) ,limit))))))
     ,@body))

(ert-deftest cooked-guard-row-width-trims-a-row-that-would-softwrap ()
  (with-temp-buffer
    (cooked-mode)
    (let ((cooked-rejoin-wrapped-lines t)
          (inhibit-read-only t))
      (insert (make-string 5 ?x) "é" (make-string 20 ?y) "\n")
      (cooked-tests--with-mocked-wrap 10 (cooked--guard-row-width (point-min)))
      (goto-char (point-min))
      (should (= (- (line-end-position) (point-min)) 10))
      (should (equal (get-text-property (1- (line-end-position)) 'display)
                      '(right-fringe right-truncation))))))

(ert-deftest cooked-guard-row-width-leaves-a-row-that-fits-alone ()
  (with-temp-buffer
    (cooked-mode)
    (let ((cooked-rejoin-wrapped-lines t)
          (inhibit-read-only t))
      (insert "é\n")
      (cooked-tests--with-mocked-wrap 10 (cooked--guard-row-width (point-min)))
      (should (equal (buffer-string) "é\n"))
      (should-not (get-text-property (point-min) 'display)))))

(ert-deftest cooked-guard-row-width-skips-pure-ascii-rows ()
  "A misclassified width has to come from a character cooked and Emacs could
ever disagree about, which a plain ASCII row cannot be -- skipped as a cheap
fast path, exercised here by leaving a row Emacs would (per the mock) report
as wrapped untouched, since it never contains anything but ASCII."
  (with-temp-buffer
    (cooked-mode)
    (let ((cooked-rejoin-wrapped-lines t)
          (inhibit-read-only t)
          (text (concat (make-string 40 ?x) "\n")))
      (insert text)
      (cooked-tests--with-mocked-wrap 10 (cooked--guard-row-width (point-min)))
      (should (equal (buffer-string) text)))))

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

(ert-deftest cooked-transcript-navigation-works-in-both-states ()
  "Jumping between commands sends nothing to the child, so a running program
must not take the binding away."
  (dolist (map (list cooked-input-map cooked-raw-map))
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
          (let ((newest (marker-position (plist-get (car cooked--commands) :start))))
            (should (= (point) newest))))
      (with-current-buffer buffer (cooked--cleanup))
      (kill-buffer buffer))))

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
               (buffer-substring-no-properties (marker-position (plist-get older :start))
                                               (marker-position (plist-get older :end)))))
      (should (string-match-p
               "second"
               (buffer-substring-no-properties (marker-position (plist-get newer :start))
                                               (marker-position (plist-get newer :end)))))
      ;; And the regions are distinct rather than collapsed onto one another.
      (should (< (marker-position (plist-get older :start))
                 (marker-position (plist-get newer :start))))
      (should (<= (marker-position (plist-get older :end))
                  (marker-position (plist-get newer :start)))))))

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
                 (start (marker-position (plist-get record :start))))
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

(ert-deftest cooked-box-drawing-gets-a-display-property ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\342\\224\\214\\342\\224\\200\\342\\224\\220\\n'") ; ┌─┐
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'display))))))

(ert-deftest cooked-box-drawing-images-disabled-falls-back-to-plain-text ()
  (let ((cooked-box-drawing-images nil))
    (cooked-tests--with-session
        '("/bin/sh" "-c" "printf '\\342\\224\\214\\342\\224\\200\\342\\224\\220\\n'") ; ┌─┐
      (should (cooked-tests--settle
               (lambda () (string-match-p "┌" (cooked-tests--text)))))
      (should-not (get-text-property (point-min) 'display)))))

(ert-deftest cooked-box-drawing-rescales-on-zoom ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\342\\224\\214\\342\\224\\200\\342\\224\\220\\n'") ; ┌─┐
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'display))))
    ;; Zoom regenerates the image in place, purely from the `cooked-box-glyph'
    ;; property already in the buffer — no round-trip to the native core, so this
    ;; holds regardless of whether batch Emacs' font backend reports a different
    ;; pixel size than the one it started with.
    (let ((before (get-text-property (point-min) 'display)))
      (text-scale-increase 1)
      (should-not (eq before (get-text-property (point-min) 'display))))))

;; `image-scaling-factor' defaults to `auto', which scales images by cell-width/10
;; on most GUI font sizes.  These bitmaps are generated at exactly the cell size, so
;; any scaling breaks the pixel-exactness the whole feature exists for — the glyphs
;; stop meeting at cell boundaries and blur back into looking like font characters.
;; An inline `xbm' whose `:data' is raw bits is only a valid spec with
;; `:data-width', `:data-height' and `:stride' (see (elisp) XBM Images).  Get that
;; wrong and Emacs rejects the whole spec and silently falls back to drawing the
;; character with the font, so every other box-drawing test here still passes while
;; nothing renders.  Asserted on the spec rather than via `image-size' because that
;; needs a graphic display and this suite runs in batch.
(ert-deftest cooked-box-drawing-image-spec-is-a-valid-inline-xbm ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\342\\224\\214\\342\\224\\200\\342\\224\\220\\n'") ; ┌─┐
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'display))))
    (let* ((image (get-text-property (point-min) 'display))
           (plist (cdr image))
           (width (plist-get plist :data-width)))
      (should (stringp (plist-get plist :data)))
      (should (natnump width))
      (should (natnump (plist-get plist :data-height)))
      ;; Stride is bits per row, rounded up to a whole number of bytes.
      (should (equal (plist-get plist :stride) (* 8 (ceiling width 8))))
      ;; The data must hold at least stride*height bits.
      (should (>= (* 8 (length (plist-get plist :data)))
                  (* (plist-get plist :stride) (plist-get plist :data-height)))))))

(ert-deftest cooked-box-drawing-images-opt-out-of-auto-scaling ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\342\\224\\214\\342\\224\\200\\342\\224\\220\\n'") ; ┌─┐
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'display))))
    (let ((image (get-text-property (point-min) 'display)))
      (should (eq (car image) 'image))
      (should (equal (plist-get (cdr image) :scale) 1)))))

;; The two features meet here: box glyphs live in the scrollback, and the alt pin
;; narrows the buffer away from it.  A zoom while a full-screen program is up must
;; still reach the glyphs above the restriction, or they stay at the old pixel size
;; and only reveal it — mismatched against their neighbours — once the pin lifts.
(ert-deftest cooked-box-drawing-rescales-above-the-alt-screen-pin ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\342\\224\\214\\342\\224\\200\\342\\224\\220\\n'") ; ┌─┐
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'display))))
    (let ((glyph (point-min))
          (before (get-text-property (point-min) 'display)))
      ;; Pin the buffer to a screen region starting below the glyph, as entering the
      ;; alt screen does.
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert "\n"))
      (setq cooked--screen-start (copy-marker (point-max)))
      (setq cooked--alt t)
      (let ((cooked-alt-screen-pin 'narrow))
        (cooked--apply-alt-pin))
      (should cooked--narrowed)
      (should (< glyph (point-min)))
      (text-scale-increase 1)
      (save-restriction
        (widen)
        (should-not (eq before (get-text-property glyph 'display)))))))

;; Distinct from the alt-pin test above: there, the glyph reaches "scrollback" by
;; the marker moving past it in place, never leaving the buffer.  Here it genuinely
;; scrolls off the top of the screen and round-trips through `scrolled_rows', the
;; flood path that used to flatten glyphs to plain styled text for cost reasons.
(ert-deftest cooked-box-drawing-survives-scrolling-into-history ()
  (cooked-tests--with-session
      (list "/bin/sh" "-c"
            (concat "printf '\\342\\224\\214\\342\\224\\200\\342\\224\\220\\n'" ; ┌─┐
                    "; for i in $(seq 40); do printf 'line%s\\n' $i; done; exec cat"))
    (should (cooked-tests--settle
             (lambda () (string-match-p "line40" (cooked-tests--text)))))
    ;; More lines were printed than fit on screen, so the box-drawing row has
    ;; actually scrolled away rather than merely being relabeled in place.
    (should (< (point-min) (marker-position cooked--screen-start)))
    (save-excursion
      (goto-char (point-min))
      (should (search-forward "┌" (marker-position cooked--screen-start) t))
      (should (get-text-property (match-beginning 0) 'display)))))

;; The one test that crosses the boundary: the dash field is a hand-kept mirror
;; between `BoxGlyph' in src/emu/glyph.rs and the `cooked--box-dash-*' constants, and
;; nothing else here would notice the two drifting apart.  ┄ is U+2504, whose only
;; difference from a solid ─ is the dash count — exactly what used to be dropped.
(ert-deftest cooked-box-dash-descriptors-survive-the-round-trip ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf '\\342\\224\\204\\n'") ; ┄
    (should (cooked-tests--settle
             (lambda () (get-text-property (point-min) 'cooked-box-glyph))))
    (let ((bits (car (get-text-property (point-min) 'cooked-box-glyph))))
      (should (= 3 (cooked--box-dashes bits)))
      ;; ...and it is still a light horizontal line underneath.
      (should (= 1 (cooked--box-weight bits 4)))
      (should (= 1 (cooked--box-weight bits 6)))
      (should (= 0 (cooked--box-weight bits 0))))))

;; The rasterizer is a pure function of a descriptor and a pixel size, so these
;; assert on the bitmap itself rather than going through a session and a display
;; property.  That is the only way to see any of this in batch: the defects below —
;; a dash that is not dashed, a dither that steps at the cell boundary, a diagonal
;; that misses the corner its neighbour has to meet — are all invisible to a test
;; that only checks a `display' property exists.

(defun cooked-tests--glyph-grid (bits width height &optional phase)
  "The boolean pixel grid `cooked--render-box-glyph' would pack, for BITS."
  (let ((grid (cooked--box-bitmap-make width height)))
    (if (/= 0 (logand bits cooked--box-kind-block))
        (cooked--box-draw-block grid width height bits (or phase 0))
      (cooked--box-draw-line grid width height bits))
    grid))

(defun cooked-tests--line-bits (up down left right &optional dash)
  "A line descriptor, mirroring `BoxGlyph::line' in src/emu/glyph.rs.
DASH is the raw 2-bit code, not a dash count."
  (logior up (ash down 2) (ash left 4) (ash right 6)
          (ash (or dash 0) cooked--box-dash-shift)))

(defun cooked-tests--row-runs (grid y width)
  "Lengths of the set runs in row Y of GRID, left to right."
  (let ((runs nil) (run 0))
    (dotimes (x width)
      (if (aref (aref grid y) x)
          (setq run (1+ run))
        (when (> run 0) (push run runs))
        (setq run 0)))
    (when (> run 0) (push run runs))
    (nreverse runs)))

;; Before this, every dashed codepoint was classified as its solid counterpart, so
;; ┄ and ─ produced byte-identical bitmaps and no amount of drawing could have told
;; them apart.
(ert-deftest cooked-box-dashed-lines-break-into-the-right-number-of-dashes ()
  (let ((width 9) (height 20))
    (let ((solid (cooked-tests--glyph-grid
                  (cooked-tests--line-bits 0 0 1 1) width height)))
      (should (equal (cooked-tests--row-runs solid (/ height 2) width) (list width))))
    ;; Dash codes 1/2/3 are 2, 3 and 4 dashes.
    (dolist (case '((1 . 2) (2 . 3) (3 . 4)))
      (let* ((grid (cooked-tests--glyph-grid
                    (cooked-tests--line-bits 0 0 1 1 (car case)) width height))
             (runs (cooked-tests--row-runs grid (/ height 2) width)))
        (should (equal (length runs) (cdr case)))
        ;; Every dash has to survive as at least one pixel.
        (should (cl-every (lambda (run) (>= run 1)) runs))))))

(ert-deftest cooked-box-dashed-lines-follow-the-stroke-axis ()
  (let* ((width 9) (height 20)
         (vertical (cooked-tests--glyph-grid
                    (cooked-tests--line-bits 1 1 0 0 2) width height))
         (column (/ width 2))
         (rows (let ((n 0))
                 (dotimes (y height) (when (aref (aref vertical y) column) (setq n (1+ n))))
                 n)))
    ;; Gaps came out of the column, not out of nothing and not out of a row.
    (should (< rows height))
    (should (> rows 0))))

;; The gap has to straddle the cell boundary, or two dashed cells side by side fuse
;; their edge dashes into one double-length dash at every seam.
(ert-deftest cooked-box-dashes-tile-across-the-cell-boundary ()
  (let* ((width 9) (height 20)
         (grid (cooked-tests--glyph-grid
                (cooked-tests--line-bits 0 0 1 1 2) width height))
         (row (/ height 2)))
    ;; A cell that ends set and starts set would join across the seam.
    (should-not (and (aref (aref grid row) 0)
                     (aref (aref grid row) (1- width))))))

;; A 9-pixel cell is odd, so a dither phased from cell-local coordinates repeats a
;; column at every seam: the last column of one cell and the first of the next are
;; both set, drawing a doubled line down the join between two ▒ cells.
(ert-deftest cooked-box-shade-dither-tiles-across-an-odd-cell-width ()
  (let* ((width 9) (height 8)
         (medium (logior cooked--box-kind-block cooked--box-direction-shade (ash 2 3)))
         (unphased (cooked-tests--glyph-grid medium width height 0))
         ;; The phase the next cell along gets at this width.
         (phase (logand width 1))
         (phased (cooked-tests--glyph-grid medium width height phase)))
    (should (= phase 1))
    (should-not (equal unphased phased))
    ;; Walking off the right edge of one cell into the left edge of the next must
    ;; alternate exactly as it does inside a cell.
    (dotimes (y height)
      (should-not (eq (aref (aref unphased y) (1- width))
                      (aref (aref phased y) 0))))))

(ert-deftest cooked-box-shade-phase-is-zero-unless-it-can-matter ()
  (let ((window (selected-window))
        (medium (logior cooked--box-kind-block cooked--box-direction-shade (ash 2 3)))
        (solid (cooked-tests--line-bits 0 0 1 1)))
    ;; Nothing but a shade is phase-sensitive, so nothing else doubles its cache.
    (should (= 0 (cooked--box-phase solid window 3 5)))
    ;; Nor is a shade whose column is unknown.
    (should (= 0 (cooked--box-phase medium window nil 5)))))

;; A diagonal has to reach the two corners it shares with its neighbours, or a run
;; of ╱ breaks at every cell join — and it has to put a pixel on every scanline, or
;; the stroke itself comes apart at a cell's aspect ratio.
(ert-deftest cooked-box-diagonals-are-connected-and-reach-their-corners ()
  (let* ((width 9) (height 20)
         (forward (cooked-tests--glyph-grid cooked--box-diag-forward width height))
         (backward (cooked-tests--glyph-grid cooked--box-diag-backward width height)))
    (dotimes (y height)
      (should (cooked-tests--row-runs forward y width))
      (should (cooked-tests--row-runs backward y width)))
    ;; ╱ runs bottom-left to top-right, ╲ top-left to bottom-right.
    (should (aref (aref forward 0) (1- width)))
    (should (aref (aref forward (1- height)) 0))
    (should (aref (aref backward 0) 0))
    (should (aref (aref backward (1- height)) (1- width)))))

(ert-deftest cooked-box-cross-is-the-union-of-both-diagonals ()
  (let* ((width 9) (height 20)
         (forward (cooked-tests--glyph-grid cooked--box-diag-forward width height))
         (backward (cooked-tests--glyph-grid cooked--box-diag-backward width height))
         (cross (cooked-tests--glyph-grid
                 (logior cooked--box-diag-forward cooked--box-diag-backward)
                 width height)))
    (dotimes (y height)
      (dotimes (x width)
        (should (eq (and (aref (aref cross y) x) t)
                    (and (or (aref (aref forward y) x)
                             (aref (aref backward y) x))
                         t)))))))

;; Cells are not square and the font size moves, so the stroke has to stay connected
;; at any geometry, not just the one that happened to be tested.
(ert-deftest cooked-box-diagonals-stay-connected-at-any-cell-size ()
  (dolist (size '((4 . 3) (5 . 20) (9 . 20) (20 . 5) (16 . 32)))
    (let* ((width (car size)) (height (cdr size))
           (grid (cooked-tests--glyph-grid cooked--box-diag-forward width height)))
      (dotimes (y height)
        (should (cooked-tests--row-runs grid y width)))
      (dotimes (x width)
        (should (let ((set nil))
                  (dotimes (y height) (when (aref (aref grid y) x) (setq set t)))
                  set))))))

(provide 'cooked-tests)
;;; cooked-tests.el ends here
