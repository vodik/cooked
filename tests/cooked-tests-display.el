;;; cooked-tests-display.el --- where a session lands, and what Emacs asks of it -*- lexical-binding: t; -*-

;;; Commentary:

;; The buffer's dealings with Emacs' own subsystems, as opposed to with the
;; child: the `display-buffer' action `\\[cooked]' passes, `revert-buffer',
;; the buffer list's directory column, isearch's view of a fold, and the two
;; buffer-locals that keep a grid a grid.
;;
;; Also the subsystems that ask a buffer what its parts are -- imenu, outline
;; and bookmarks, all answered from the OSC 133 command records -- and the
;; absence `desktop' is deliberately left as.
;;
;; Most of these need no session.  They are questions about a cooked buffer, and
;; `cooked-mode' in a temp buffer is the whole of the fixture -- the shape
;; `cooked-tests-sticky-scroll.el' uses for the same reason.  The exceptions are
;; the ones whose answer is about a *live* session: a bookmark reusing a shell
;; that is still in the directory, and a running session being left out of a
;; saved desktop file.

;;; Code:

(require 'cooked-tests-helpers)
;; `cooked-mode' configures the first three of these without loading any of
;; them -- the point of the variables being set and nothing more -- so the tests
;; that drive them have to do the loading a user's own `imenu', `bookmark-set'
;; or `outline-minor-mode' would.  `desktop' is here for the opposite reason:
;; what is asserted about it is an absence, and an absence is only worth
;; asserting once the library that would have to contain it is loaded.
(require 'imenu)
(require 'bookmark)
(require 'outline)
(require 'desktop)

;;;; `cooked-display-action'

(ert-deftest cooked-display-action-is-a-well-formed-action ()
  "A `display-buffer' ACTION is (FUNCTIONS . ALIST), and for a long time this
one was not.  Written flat, as (display-buffer-same-window
display-buffer-pop-up-window), it parsed as FUNCTIONS = the *symbol*
`display-buffer-same-window' and ALIST = (display-buffer-pop-up-window) -- an
alist entry `assq' never asks for and so drops without a word.  The split was
therefore never the second choice its docstring promises it is.

Stated as a parse rather than as the literal value, because the literal is what
was wrong: the point is that the second function is reachable as a function and
that the alist is an alist."
  (dolist (action (list cooked-display-action cooked-other-window-action))
    (let ((functions (car action))
          (alist (cdr action)))
      (should (or (functionp functions)
                  (and (listp functions) (seq-every-p #'functionp functions))))
      (should (seq-every-p #'consp alist))))
  (should (equal (car cooked-display-action)
                 '(display-buffer-same-window display-buffer-pop-up-window))))

(ert-deftest cooked-display-action-splits-when-the-window-will-not-take-it ()
  "The consequence, from the outside.  With the selected window dedicated to
someone else's buffer, `display-buffer-same-window' declines and
`display-buffer-pop-up-window' -- the second choice -- has to run.  Under the
malformed value there was no second choice, so the request fell through to
`display-buffer-fallback-action', which reuses a window the user was reading
something else in: the exact behaviour the docstring says this action exists to
avoid.

`pop-up-windows' nil is what makes the two answers differ rather than merely
arrive by different routes.  The fallback's own splitting entry,
`display-buffer--maybe-pop-up-frame-or-window', is gated on that option, while
`display-buffer-pop-up-window' named outright is not -- so with it off the
malformed action lands on `display-buffer-in-previous-window' and the correct
one still splits.  A user who has turned splitting off in general has not asked
cooked to start taking over their other windows."
  (let ((frame (selected-frame))
        (pop-up-windows nil)
        (dedicated (get-buffer-create "*cooked-tests-dedicated*"))
        (neighbour (get-buffer-create "*cooked-tests-neighbour*"))
        (session (get-buffer-create "*cooked-tests-session*")))
    (unwind-protect
        (progn
          (delete-other-windows)
          (set-window-buffer (selected-window) dedicated)
          (let ((other (split-window)))
            (set-window-buffer other neighbour)
            (set-window-dedicated-p (selected-window) t)
            (let ((before (length (window-list frame))))
              (display-buffer session cooked-display-action)
              ;; Split, not reused: the neighbour still shows what it did.
              (should (eq (window-buffer other) neighbour))
              (should (= (length (window-list frame)) (1+ before)))
              (should (get-buffer-window session frame)))))
      (set-window-dedicated-p (selected-window) nil)
      (mapc #'kill-buffer (list dedicated neighbour session))
      (delete-other-windows))))

;;;; The subsystems `cooked-mode' answers for

(ert-deftest cooked-mode-answers-revert-buffer ()
  "`revert-buffer' has no file to re-read here, so without a
`revert-buffer-function' it signals in a cooked buffer.  Repainting from the
emulator's grid is what reverting means for a terminal, and `cooked-refresh'
already is that."
  (with-temp-buffer
    (cooked-mode)
    (should (functionp revert-buffer-function))
    (let (called)
      (cl-letf (((symbol-function 'cooked-refresh) (lambda () (setq called t))))
        (revert-buffer nil t))
      (should called))))

(ert-deftest cooked-mode-names-a-directory-for-the-buffer-list ()
  "`C-x C-b' and ibuffer print `list-buffers-directory' for a buffer with no
file, and cooked has an honest answer for it -- `default-directory', which OSC 7
keeps on the child's own working directory.  It has to keep up with that:
`cooked--update-buffer-name' is where every directory report already ends, so it
is where this is refreshed, and it happens whether or not the user asked for
buffer names to track the child."
  (with-temp-buffer
    (cooked-mode)
    (should (equal list-buffers-directory default-directory))
    (let ((cooked-buffer-name-auto-update nil)
          (default-directory (file-name-as-directory (expand-file-name "~"))))
      (cooked--update-buffer-name)
      (should (equal list-buffers-directory default-directory)))))

(ert-deftest cooked-mode-pins-the-paragraph-direction ()
  "A grid is not prose.  `cooked--mouse-cell' turns a click's column back into a
cell, the ghost cursor is placed by column, and `cooked--guard-row-width' asks
`vertical-motion' where a row ends -- all three assume the COLth character of a
row is at column COL.  Bidi reordering decides that per paragraph from the
text's own first strong character, so one line of RTL output would flip a row
under all three at once."
  (with-temp-buffer
    (cooked-mode)
    (should (eq bidi-paragraph-direction 'left-to-right))
    ;; Not `bidi-display-reordering', which Emacs documents as internal and
    ;; which switches off character-level shaping that is not in anyone's way.
    (should-not (local-variable-p 'bidi-display-reordering))))

(ert-deftest cooked-mode-tears-sessions-down-when-emacs-exits ()
  "Killing the buffer reaps the child; exiting Emacs kills no buffers, so
without this hook `Session::shutdown''s SIGHUP-then-SIGKILL escalation never
runs and a child with `trap \\='\\=' HUP' outlives the Emacs that started it.
The generated shell startup files leak the same way."
  (with-temp-buffer
    (cooked-mode)
    (should (memq #'cooked--kill-emacs kill-emacs-hook))))

;;;; Folds

(ert-deftest cooked-a-fold-can-be-opened-by-isearch ()
  "Invisible text with no `isearch-open-invisible' is text isearch will not
show, so it skips every match inside a folded command's output rather than
revealing it -- a search for something plainly visible in the transcript
silently finding nothing, on the one command whose output you happened to fold.

The spec is a symbol registered in `buffer-invisibility-spec' rather than a bare
t, which is invisible only for as long as that spec is left at its default."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--make-command "$ " "some-command" "needle\n" 0)
    (goto-char (point-max))
    (forward-line -1)
    (cooked-toggle-fold)
    (let ((fold (seq-find (lambda (o) (overlay-get o 'cooked-fold))
                          (overlays-in (point-min) (point-max)))))
      (should fold)
      (should (eq (overlay-get fold 'invisible) 'cooked-fold))
      (should (memq 'cooked-fold buffer-invisibility-spec))
      (should (invisible-p (overlay-start fold)))
      ;; Both halves of isearch's contract: stepping through opens the fold for
      ;; the duration, stopping inside it opens it for good.
      (should (eq (overlay-get fold 'isearch-open-invisible) #'delete-overlay))
      (let ((temporary (overlay-get fold 'isearch-open-invisible-temporary)))
        (should (functionp temporary))
        (funcall temporary fold nil)
        (should-not (invisible-p (overlay-start fold)))
        (funcall temporary fold t)
        (should (invisible-p (overlay-start fold)))))))

;;;; The subsystems that ask a buffer what its parts are

(ert-deftest cooked-imenu-indexes-the-commands-and-not-the-text ()
  "The index is built from the OSC 133 records, so it costs one entry per
command and nothing per line of output -- and it can say things no scan of the
text could, an exit status among them.

Four commands, of which two share a command line and two share a name: the
failure is distinguished by its status, the repeat by a `uniquify'-shaped
suffix.  The second matters more than it looks.  `imenu' resolves the entry
the user picked by looking the *name* back up, so two identical names are one
reachable entry and one that silently jumps to the other -- which for a
terminal, where running the same command twice is the ordinary thing to do, is
most of the index."
  (with-temp-buffer
    (cooked-mode)
    (let ((commands (list (cooked-tests--make-command "$ " "make -j8" "ok\n" 0)
                          (cooked-tests--make-command "$ " "make -j8" "boom\n" 2)
                          (cooked-tests--make-command "$ " "ls" "a b\n" 0)
                          (cooked-tests--make-command "$ " "ls" "a b\n" 0))))
      (let ((index (cooked--imenu-index)))
        (should (equal (mapcar #'car index)
                       '("make -j8" "make -j8 [exit 2]" "ls" "ls<2>")))
        ;; Buffer order, and each entry lands on the prompt the command was
        ;; typed at -- where `cooked-previous-command' also lands, and the only
        ;; place a command that printed nothing has to be found by.
        (should (equal (mapcar #'cdr index)
                       (mapcar #'cooked--command-prompt-position commands)))
        (should (equal (mapcar #'cdr index) (sort (mapcar #'cdr index) #'<))))
      ;; Rebuilt on every use rather than cached against a buffer that is
      ;; rewritten at drain rate.
      (should imenu-auto-rescan)
      (should (eq imenu-create-index-function #'cooked--imenu-index)))))

(ert-deftest cooked-imenu-names-an-unreported-command-by-its-prompt-line ()
  "A shell that sends no `cmdline_url=' leaves the record with no `input', and
a command typed while the child owned the keyboard leaves it with none either.
The prompt line is still in the buffer and still says what was run -- with the
prompt on the front of it, which is how the user reads it too.

Whitespace is collapsed on the way, so a command typed over several lines is
one entry rather than a name with newlines in it, and a record with nothing at
all behind it is named rather than left as an empty string the completing read
cannot be pointed at."
  (with-temp-buffer
    (cooked-mode)
    (goto-char (point-max))
    (let ((prompt (point-marker)))
      (insert "$ typed-without-cooked\n")
      (let ((start (point-marker)))
        (insert "output\n")
        (push (cooked--command-make :start start :end (point-marker) :code 0
                                    :input nil :prompt prompt)
              cooked--commands)))
    (should (equal (mapcar #'car (cooked--imenu-index))
                   '("$ typed-without-cooked")))
    (setf (cooked-command-input (car cooked--commands)) "for f in *\ndo\n  echo $f\ndone")
    (should (equal (mapcar #'car (cooked--imenu-index))
                   '("for f in * do echo $f done")))
    ;; Neither account, and a prompt line that has since been repainted away.
    (setf (cooked-command-input (car cooked--commands)) nil)
    (let ((inhibit-read-only t))
      (delete-region (point-min) (point-max)))
    (should (equal (mapcar #'car (cooked--imenu-index))
                   (list cooked--imenu-unnamed)))))

(ert-deftest cooked-outline-headings-are-the-prompts-the-shell-marked ()
  "`outline-search-function' rather than `outline-regexp', because what makes a
line a heading here is what the shell said about it and not how it looks: a
regexp would miss every prompt that is not the one it was written for and
claim every line of output that is.

The contract is `re-search-forward's, and all four of its corners are exercised
-- at or after point going forward, strictly before it going backward, BOUND
rejecting a heading whose line falls outside it, and MOVE deciding where a
failed search leaves point."
  (with-temp-buffer
    (cooked-mode)
    (let* ((one (cooked-tests--make-command "$ " "first" "out one\n" 0))
           (two (cooked-tests--make-command "$ " "second" "out two\n" 0))
           (heads (list (cooked--command-prompt-position one)
                        (cooked--command-prompt-position two))))
      (should (equal (cooked--outline-headings) heads))
      ;; LOOKING-AT, which is the whole of `outline-on-heading-p'.
      (goto-char (car heads))
      (should (cooked--outline-search nil nil nil t))
      (should (equal (match-beginning 0) (car heads)))
      (forward-line 1)
      (should-not (cooked--outline-search nil nil nil t))
      ;; Forward, twice, then off the end.
      (goto-char (point-min))
      (should (cooked--outline-search))
      (should (equal (match-beginning 0) (nth 0 heads)))
      (should (cooked--outline-search))
      (should (equal (match-beginning 0) (nth 1 heads)))
      (should-not (cooked--outline-search))
      ;; Without MOVE a failure leaves point where it was; with it, at the end
      ;; it was heading for.
      (let ((here (point)))
        (should-not (cooked--outline-search))
        (should (equal (point) here))
        (should-not (cooked--outline-search nil t))
        (should (equal (point) (point-max))))
      ;; Backward is strict, so a search from a heading finds the one above it
      ;; rather than itself.
      (goto-char (nth 1 heads))
      (should (cooked--outline-search nil nil t))
      (should (equal (point) (nth 0 heads)))
      (should-not (cooked--outline-search nil nil t))
      (should-not (cooked--outline-search nil t t))
      (should (equal (point) (point-min)))
      ;; BOUND: the second heading's line does not fit under a bound in the
      ;; middle of it, and does under one past its end.
      (goto-char (nth 0 heads))
      (forward-line 1)
      (should-not (cooked--outline-search (1+ (nth 1 heads))))
      (should (cooked--outline-search (save-excursion (goto-char (nth 1 heads))
                                                      (pos-eol))))
      (should (equal (match-beginning 0) (nth 1 heads))))))

(ert-deftest cooked-outline-mode-folds-a-command-by-its-prompt ()
  "The point of the search function, from the outside: `outline-minor-mode'
over a transcript hides a command's output under the prompt it was typed at,
which is also what makes speedbar and `outline-cycle' work here.

Every heading is level 1.  The transcript is a sequence and not a tree, and a
level below the prompt would fold exactly nothing extra -- a heading already
hides everything up to the next one."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--make-command "$ " "first" "out one\n" 0)
    (cooked-tests--make-command "$ " "second" "out two\n" 0)
    (outline-minor-mode 1)
    (unwind-protect
        (progn
          (goto-char (point-min))
          (should (outline-on-heading-p))
          (should (= (funcall outline-level) 1))
          (outline-hide-subtree)
          ;; The prompt line is still readable; its output is not.
          (should-not (invisible-p (point)))
          (should (invisible-p (save-excursion (forward-line 1) (point))))
          ;; And the next command is untouched, which is what "level 1" means.
          (outline-next-heading)
          (should-not (invisible-p (point)))
          (outline-show-all)
          (should-not (invisible-p (save-excursion (goto-char (point-min))
                                                   (forward-line 1)
                                                   (point)))))
      (outline-minor-mode -1))))

(ert-deftest cooked-mode-declines-a-global-visual-line-mode ()
  "`global-visual-line-mode' is installed from `after-change-major-mode-hook',
so it runs after `cooked-mode''s own body and would overrule the
`truncate-lines' cooked derives from `cooked-rejoin-wrapped-lines' -- soft
wrapping a grid, and breaking `cooked--guard-row-width''s one assumption,
which is that a row ends where `vertical-motion' says it does.

Turning the minor mode off rather than re-asserting the variable is what makes
it stay off: the call leaves the buffer marked as having decided for itself,
which is the flag the globalized mode consults before enabling anywhere.  The
second `run-hooks' is that claim, made the way Emacs would make it."
  (let ((was global-visual-line-mode))
    (unwind-protect
        (progn
          (global-visual-line-mode 1)
          (dolist (rejoin '(t nil))
            (with-temp-buffer
              (let ((cooked-rejoin-wrapped-lines rejoin))
                (cooked-mode))
              (should-not visual-line-mode)
              (should-not word-wrap)
              (should (eq truncate-lines (not rejoin)))
              (run-hooks 'after-change-major-mode-hook)
              (should-not visual-line-mode)
              (should (eq truncate-lines (not rejoin))))))
      (global-visual-line-mode (if was 1 -1)))))

(ert-deftest cooked-the-forwarding-map-is-built-for-one-kind-of-frame ()
  "A Meta chord is one event on a graphical frame and two forwarded bytes on a
terminal one, and no keymap answers both -- `cooked--build-meta-overlay' says
why.  So the map the buffer wears is a fact about a frame, and
`cooked--keymap-frame-type' is that fact written down where the next window
selection can compare against it.

The maps that do not forward have nothing to be stale about, and record
nothing, which is what keeps a buffer at a prompt from being asked twice."
  (with-temp-buffer
    (cooked-mode)
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil)))
      (should (eq (cooked--state-keymap nil 'raw) cooked-raw-map))
      (should (eq cooked--keymap-frame-type 'text))
      (should-not (cooked--keymap-frame-stale-p)))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
      (should (cooked--keymap-frame-stale-p))
      (let ((map (cooked--state-keymap nil 'raw)))
        (should-not (eq map cooked-raw-map))
        (should (eq (keymap-parent map) cooked-raw-map))
        (should (eq cooked--keymap-frame-type 'graphic))
        (should-not (cooked--keymap-frame-stale-p))
        ;; The overlay is cached for the life of Emacs, so moving back and
        ;; forth costs a lookup rather than a keymap.
        (should (eq map (cooked--state-keymap nil 'raw)))))
    (cooked--state-keymap nil 'cooked)
    (should-not cooked--keymap-frame-type)
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
      (should-not (cooked--keymap-frame-stale-p)))))

(ert-deftest cooked-a-buffer-selected-on-another-kind-of-frame-re-wears-its-map ()
  "Nothing else notices.  On a daemon serving one graphical frame and one
terminal frame the buffer moves between them with no state change of its own,
so the map built for the frame it was last refreshed on stays on until
something unrelated installs one -- leaving \\`M-x' either eaten by the child
or answered by Emacs, whichever is wrong there.

`cooked--window-selection-changed' already runs at that moment for focus
reporting.  What it must not do is rebuild anything on the ordinary selection
change, so the three cases are all here: same frame type, a buffer that has
just *lost* the selection rather than gained it, and the one that asks for a
refresh -- deferred, because this hook runs inside redisplay."
  (with-temp-buffer
    (cooked-mode)
    (cooked-tests--display-buffer)
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil)))
      (cooked--state-keymap nil 'raw))
    (let (deferred refreshed)
      (cl-letf (((symbol-function 'cooked--defer) (lambda (f) (setq deferred f)))
                ((symbol-function 'cooked--refresh-keymap)
                 (lambda (&rest _) (setq refreshed t))))
        (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil)))
          (cooked--window-selection-changed (selected-frame))
          (should-not deferred))
        (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
          ;; Displayed nowhere: this hook runs in the buffer being left as well,
          ;; and the map belongs to the frame being typed into.
          (set-window-buffer (selected-window) (get-buffer-create "*cooked-tests-elsewhere*"))
          (cooked--window-selection-changed (selected-frame))
          (should-not deferred)
          (cooked-tests--display-buffer)
          (cooked--window-selection-changed (selected-frame))
          (should deferred)
          (funcall deferred)
          (should refreshed))))
    (kill-buffer "*cooked-tests-elsewhere*")))

(ert-deftest cooked-a-bookmark-records-where-the-shell-was ()
  "A position cannot be what a bookmark into a terminal means: the buffer is
transient, the child does not outlive Emacs, and the row it was set on has
scrolled away by morning.  The directory and the command line do survive, so
those are what is written -- and they have to survive the bookmark file, which
is `prin1' and `read'."
  (with-temp-buffer
    (cooked-mode)
    (setq-local default-directory (file-name-as-directory (expand-file-name "~")))
    (let ((command (cooked-tests--make-command "$ " "cargo test" "ok\n" 0)))
      (goto-char (cooked--command-start-position command)))
    (let ((record (cooked--bookmark-record)))
      (should (stringp (car record)))
      (should (string-search "cargo test" (car record)))
      (should (equal (bookmark-prop-get record 'directory) default-directory))
      (should (equal (bookmark-prop-get record 'filename) default-directory))
      (should (equal (bookmark-prop-get record 'command) "cargo test"))
      (should (eq (bookmark-prop-get record 'handler) #'cooked-bookmark-jump))
      (should (equal (read (prin1-to-string record)) record))
      ;; And the whole of `bookmark-set' over it, which adds the defaults and
      ;; is what would signal on a record of the wrong shape.
      (should (bookmark-make-record)))))

(ert-deftest cooked-a-bookmark-reuses-a-live-session-and-says-so-when-it-cannot ()
  "The session being gone is the ordinary case rather than the failure, so the
handler starts one; a session already in that directory is reused instead,
which is the rule `cooked-project' also reuses by and the one that does not
leave a shell behind per jump.

The failure is the directory being gone, and it is said out loud rather than
papered over by starting a shell somewhere else."
  (cooked-tests--with-session (list "/bin/sh")
    (should (cooked-tests--settle (lambda () (cooked--live-p cooked--session))))
    (let ((record (cooked--bookmark-record))
          (buffer (current-buffer)))
      (save-current-buffer
        (cooked-bookmark-jump record)
        (should (eq (current-buffer) buffer)))
      (should-error (cooked-bookmark-jump
                     `("gone" (directory . "/nonexistent/cooked/")
                       (handler . cooked-bookmark-jump)))
                    :type 'user-error))))

(ert-deftest cooked-a-terminal-is-left-out-of-the-desktop-file ()
  "The reasoned decline, kept honest by a test.

A cooked buffer visits no file and sets no `desktop-save-buffer', so it is
already left out of a desktop file and cannot break one on load.  What
registering a handler would buy is a restore, and the only restore worth
anything spawns a shell -- at the one moment where \"start eight children
nobody asked for\" is a plausible outcome, sometimes minutes later off an idle
timer.  The alternative, a session-less placeholder, is litter: nothing turns
such a buffer back into a session.  A bookmark is the same capability chosen
one at a time, by hand.

So this asserts the absence, and reads the saved file back with `read' rather
than searching it for a string -- the suite has buffers with cooked in their
file names, and the claim is about a buffer being restored in `cooked-mode'
and not about the letters."
  (cooked-tests--with-session (list "/bin/sh")
    (should (cooked-tests--settle (lambda () (cooked--live-p cooked--session))))
    (should-not desktop-save-buffer)
    (should-not (assq 'cooked-mode desktop-buffer-mode-handlers))
    (let ((directory (make-temp-file "cooked-tests-desktop-" t)))
      (unwind-protect
          (let ((desktop-base-file-name "desktop")
                (desktop-base-lock-name "desktop.lock")
                (desktop-restore-frames nil))
            (desktop-save directory)
            (with-temp-buffer
              (insert-file-contents (expand-file-name "desktop" directory))
              (goto-char (point-min))
              (let (form forms)
                (while (setq form (condition-case nil (read (current-buffer))
                                    (end-of-file nil)))
                  (push form forms))
                ;; It parsed -- which is the half of "does not break the
                ;; desktop file" worth asserting -- and named no cooked buffer.
                (should forms)
                (should-not
                 (seq-find (lambda (f)
                             (and (eq (car-safe f) 'desktop-create-buffer)
                                  (member ''cooked-mode f)))
                           forms)))))
        (delete-directory directory t)))))

(provide 'cooked-tests-display)
;;; cooked-tests-display.el ends here
