;;; cooked-tests-menu.el --- the menu, and the commands it names -*- lexical-binding: t; -*-

;;; Commentary:

;; The menu is the one part of the tree the byte-compiler cannot check.  Its
;; guards are quoted data, so `make lint' will happily compile an item naming a
;; command that does not exist or a predicate spelled wrong, and the first
;; report would be a menu that errors inside redisplay.  So the tests here are
;; not about the menu's shape for its own sake: `cooked-menu-names-only-real-commands'
;; and `cooked-menu-guards-survive-a-bare-buffer' are the compiler for this
;; structure, and everything else is the usual kind of test.
;;
;; The commands the menu exists to name are covered here too rather than beside
;; the fringe markers that used to own three of them -- `cooked-rerun-command',
;; `cooked-copy-command' and `cooked-copy-output' answer from a command record
;; and nothing else, so they moved out of `cooked-command-decorations.el' when
;; the menu needed to name them whether that file was loaded or not.

;;; Code:

(require 'cooked-tests-helpers)

(defun cooked-tests--menu ()
  "The `Cooked\=' menu keymap."
  (lookup-key cooked-mode-map [menu-bar cooked]))

(defun cooked-tests--menu-items (&optional keymap)
  "Every menu item in KEYMAP, submenus flattened in, as (NAME CALLBACK . PLIST).

Separators and the submenu items themselves are dropped: what every caller here
wants is the leaves, since those are what carry a command and a guard."
  (let (items)
    (map-keymap
     (lambda (_key binding)
       (when (and (consp binding) (eq (car binding) 'menu-item))
         (let ((callback (nth 2 binding)))
           (if (keymapp callback)
               (setq items (append items (cooked-tests--menu-items callback)))
             (push (cdr binding) items)))))
     (or keymap (cooked-tests--menu)))
    (nreverse items)))

(defun cooked-tests--menu-plist (name)
  "The property list of the menu item called NAME."
  (cddr (assoc name (cooked-tests--menu-items))))

(defun cooked-tests--menu-guards (item)
  "The guard forms ITEM carries: its `:enable\=', `:visible\=' and toggle."
  (let ((plist (cddr item)))
    (delq nil (list (plist-get plist :enable)
                    (plist-get plist :visible)
                    (cdr (plist-get plist :button))))))

;;;; What is no longer inherited

(ert-deftest cooked-menu-comint-menus-are-shadowed ()
  "comint's three arrive with the parent keymap and each is wrong here: In/Out
walks `field' properties cooked never sets, Signals acts on the wakeup pipe,
and Complete asks a process that is not the child."
  (dolist (menu '(inout signals completion))
    (should (lookup-key comint-mode-map (vector 'menu-bar menu)))
    (should-not (lookup-key cooked-mode-map (vector 'menu-bar menu)))))

(ert-deftest cooked-menu-comint-menus-stay-shadowed-through-the-state-maps ()
  "The map actually installed is never `cooked-mode-map' itself -- it is one of
the state maps, which reach it as a parent.  A shadow that only worked one
level down would have looked right in every other test here."
  (dolist (map (list cooked-input-map cooked-semi-map cooked-raw-map
                     cooked-command-map cooked-alt-map cooked-peek-map))
    (dolist (menu '(inout signals completion))
      (should-not (lookup-key map (vector 'menu-bar menu))))
    (should (keymapp (lookup-key map [menu-bar cooked])))))

(ert-deftest cooked-menu-is-the-only-menu-the-menu-bar-draws ()
  "Asserted where redisplay actually asks: `menu_bar_items' walks the local
`[menu-bar]' map with `map_keymap_canonical', and canonicalizing resolves the
shadowing -- comint's three come back nil and `menu_bar_item' drops a nil
binding without adding anything.  So this is the rendered menu bar, not merely
what `lookup-key' would answer.

What it deliberately does not claim: `mouse-menu-non-singleton' counts these
same nil entries as submenus, so it sees four and hands back the wrapper.
\\`mouse-1' on the mode name gives one `Cooked' submenu to step into rather
than the items themselves."
  (with-temp-buffer
    (cooked-mode)
    (let (drawn)
      (map-keymap (lambda (key binding) (when binding (push key drawn)))
                  (keymap-canonicalize (lookup-key (current-local-map) [menu-bar])))
      (should (equal drawn '(cooked))))))


;;;; The compiler the menu does not otherwise get

(ert-deftest cooked-menu-names-only-real-commands ()
  "Every callback on the menu is a command that exists.

`make lint' cannot say this: the menu form is quoted data, so a typo in an item
compiles clean and fails when someone clicks it."
  (dolist (item (cooked-tests--menu-items))
    (let ((callback (nth 1 item)))
      (should (symbolp callback))
      (should (fboundp callback))
      (should (commandp callback)))))

(ert-deftest cooked-menu-guards-survive-a-bare-buffer ()
  "A menu is opened during redisplay, and a guard that signals there takes the
frame with it.  The hardest case is the emptiest one: `cooked-mode' with no
session, no records and no window -- which is also every menu opened in the
instant before the child has started."
  (with-temp-buffer
    (cooked-mode)
    (dolist (item (cooked-tests--menu-items))
      (dolist (guard (cooked-tests--menu-guards item))
        (should (memq (condition-case error (progn (eval guard t) 'ok)
                        (error error))
                      '(ok)))))))

(ert-deftest cooked-menu-greys-out-what-a-childless-buffer-cannot-do ()
  "The state word in the mode line and the greying here answer the same
question, and a buffer with no live child is where they came apart:
`cooked--input-state-p' answers t with no session at all -- the policy falls
through to `cooked', Emacs owning a line there is nobody to send -- so every
command that writes to a child was offered as though one were listening."
  (with-temp-buffer
    (cooked-mode)
    (dolist (name '("Send Input" "Paste to Terminal" "Refresh the Screen"))
      (should-not (eval (plist-get (cooked-tests--menu-plist name) :enable) t)))))

(ert-deftest cooked-menu-offers-the-input-verbs-at-a-live-prompt ()
  "The other half of the same claim, and the one no fixture can fake: a real
shell at a real prompt, where every one of these is exactly what the menu
should be offering."
  (skip-unless (executable-find "zsh"))
  (cooked-tests--with-zsh
    (dolist (name '("Send Input" "Insert Newline" "Previous Input"
                    "Complete at Point" "Paste to Terminal" "Interrupt"))
      (should (eval (plist-get (cooked-tests--menu-plist name) :enable) t)))))

(ert-deftest cooked-menu-offers-the-command-verbs-where-there-is-a-command ()
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (let ((guard (plist-get (cooked-tests--menu-plist "Copy Its Output") :enable)))
      (should-not (eval guard t))
      (cooked-tests--make-command "$ " "echo hi" "hi\n" 0)
      (goto-char (point-min))
      (should (eval guard t)))))

;;;; The keys the menu is a second face of

(ert-deftest cooked-menu-comint-commands-that-touch-the-process-are-remapped ()
  "The standing guard against re-inheriting one of these.  They do not fail
against `cooked--wake' -- they succeed: `comint-kill-subjob' kills the pipe the
child rings and leaves the child running behind a buffer that has stopped
hearing from it."
  (dolist (command '(comint-send-eof comint-kill-subjob comint-continue-subjob
                     comint-show-output comint-write-output))
    (should (lookup-key cooked-mode-map (vector 'remap command)))))

(ert-deftest cooked-menu-last-command-has-a-key ()
  "It had none: the mode line's exit status was a click away from it, which is
a control no keyboard can reach and no terminal frame draws."
  (should (eq (lookup-key cooked-mode-map (kbd "C-c C->")) #'cooked-goto-last-command)))

(ert-deftest cooked-middle-click-pastes-to-the-child ()
  "What `mouse-2' does in every other terminal.  comint's `comint-insert-input'
finds no input field here -- cooked sets none -- and falls through to the global
binding, which inserts the X selection into the buffer instead."
  (should (eq (lookup-key cooked-mode-map [mouse-2]) #'cooked-paste))
  ;; And it takes nothing from the link span, whose `keymap' property is
  ;; consulted before any of this.
  (should (eq (lookup-key cooked-link-map [mouse-2]) #'cooked-follow-link)))

;;;; The commands themselves

(ert-deftest cooked-show-output-goes-to-the-command-at-point ()
  "The inherited `comint-show-output' walks `field' properties, and with none in
the buffer `field-beginning' answers `point-min' -- so it scrolled to the top of
the scrollback, silently, which is why this exists rather than the menu entry
simply being dropped."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (cooked-tests--make-command "$ " "echo one" "one\n" 0)
    (let ((second (cooked-tests--make-command "$ " "echo two" "two\n" 0)))
      (goto-char (cooked--command-start-position second))
      (cooked-show-output)
      (should (= (window-start) (cooked--command-start-position second)))
      (should-not (= (window-start) (point-min))))))

(ert-deftest cooked-show-output-answers-from-the-prompt-too ()
  "`cooked--command-around' is the reason: after `cooked-previous-command' point
is on the prompt, which is outside every output region there is."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (cooked-tests--make-command "$ " "echo one" "one\n" 0)
    (let ((second (cooked-tests--make-command "$ " "echo two" "two\n" 0)))
      (goto-char (cooked--command-prompt-position second))
      (cooked-show-output)
      (should (= (window-start) (cooked--command-start-position second))))))

(ert-deftest cooked-write-output-writes-the-command-at-point ()
  "comint's version writes from the last input end to the process mark, so it
can only ever mean the newest command -- and raises midway through one, where
the input mark points nowhere."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (let ((first (cooked-tests--make-command "$ " "echo one" "one\n" 0))
          (file (make-temp-file "cooked-write-output")))
      (cooked-tests--make-command "$ " "echo two" "two\n" 0)
      (unwind-protect
          (progn
            (goto-char (cooked--command-start-position first))
            (cooked-write-output file)
            ;; No trailing newline: `cooked--command-region' pulls the end back
            ;; off the next prompt's first column, so one command's output does
            ;; not reach into the line below it.
            (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                           "one"))
            ;; And with OUTER, the record: the form worth pasting into a bug
            ;; report, prompt and command line included.
            (cooked-write-output file t)
            (should (string-search "echo one"
                                   (with-temp-buffer (insert-file-contents file)
                                                     (buffer-string)))))
        (delete-file file)))))

(ert-deftest cooked-copy-command-kills-the-input-line ()
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (let ((command (cooked-tests--make-command "$ " "echo copy-me" "copy-me\n" 0)))
      (cooked-copy-command command)
      (should (equal (current-kill 0) "echo copy-me")))))

(ert-deftest cooked-copy-output-kills-the-output-region ()
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (let ((command (cooked-tests--make-command "$ " "echo out-text" "out-text\n" 0)))
      (cooked-copy-output command)
      (should (string-search "out-text" (current-kill 0))))))

(ert-deftest cooked-copy-output-answers-for-point-when-given-nothing ()
  "The optional argument is what lets a fringe click name the record it was
painted for; without one these fall back to point, which is what makes them
worth putting on a menu at all."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (let ((command (cooked-tests--make-command "$ " "echo here" "here\n" 0)))
      (goto-char (cooked--command-start-position command))
      (cooked-copy-output)
      (should (string-search "here" (current-kill 0))))))

(ert-deftest cooked-command-verbs-refuse-where-there-is-no-command ()
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (should-error (cooked-copy-output) :type 'user-error)
    (should-error (cooked-show-output) :type 'user-error)))

(ert-deftest cooked-rerun-refuses-a-busy-prompt ()
  "Resending only makes sense at an empty prompt.  With the child owning the
line there is nothing to submit to, and with a line half-typed the submission
would run that line with this one appended -- which is worse than doing
nothing, because it looks like it worked."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (let ((command (cooked-tests--make-command "$ " "echo hi" "hi\n" 0)))
      (cl-letf (((symbol-function 'cooked--input-state-p) (lambda () nil)))
        (should-error (cooked-rerun-command command) :type 'user-error)))))

(ert-deftest cooked-rerun-refuses-a-command-with-no-input ()
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (goto-char (point-max))
    (insert "no input recorded\n")
    (let ((command (cooked--command-make :start (copy-marker (point-min))
                                         :end (copy-marker (point-max))
                                         :code 0 :input nil :prompt nil)))
      (should-error (cooked-rerun-command command) :type 'user-error))))

(ert-deftest cooked-toggle-rejoin-wrapped-lines-moves-both-halves ()
  "The variable and `truncate-lines' are two halves of one answer: a menu item
that set only the first would change what happens to output arriving from now
on and leave this buffer wrapping the way it was."
  (with-temp-buffer
    (cooked-mode)
    (let ((cooked-rejoin-wrapped-lines cooked-rejoin-wrapped-lines))
      (let ((before cooked-rejoin-wrapped-lines))
        (cooked-toggle-rejoin-wrapped-lines)
        (should (eq cooked-rejoin-wrapped-lines (not before)))
        (should (eq truncate-lines before))))))

;;;; The context menu

(ert-deftest cooked-context-menu-acts-on-the-click-not-on-point ()
  "The whole reason it exists: `context-menu-local' copies the menu above into
every right-click, and every guard on it resolves from point -- which for a
right-click is wrong by the distance the mouse travelled."
  (with-temp-buffer
    (cooked-mode)
    (let ((window (cooked-tests--display-buffer)))
      (let ((first (cooked-tests--make-command "$ " "echo one" "one\n" 0)))
        (cooked-tests--make-command "$ " "echo two" "two\n" 0)
        (goto-char (point-max))
        (let* ((position (cooked--command-start-position first))
               (click `(down-mouse-3 (,window ,position (0 . 0) 0)))
               (menu (cooked--context-menu (make-sparse-keymap) click))
               ;; `lookup-key' answers with the item's binding, not the
               ;; `menu-item' form around it -- here the closure over the
               ;; record, which is the whole point of the entry.
               (verb (lookup-key menu [cooked-context-copy-command])))
          (should (commandp verb))
          (call-interactively verb)
          (should (equal (current-kill 0) "echo one")))))))

(ert-deftest cooked-context-menu-adds-nothing-where-there-is-no-command ()
  (with-temp-buffer
    (cooked-mode)
    (let* ((window (cooked-tests--display-buffer))
           (click `(down-mouse-3 (,window ,(point-min) (0 . 0) 0)))
           (menu (cooked--context-menu (make-sparse-keymap) click)))
      (should-not (lookup-key menu [cooked-context-copy-command])))))

(provide 'cooked-tests-menu)
;;; cooked-tests-menu.el ends here
