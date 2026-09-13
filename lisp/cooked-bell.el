;;; cooked-bell.el --- What a BEL from the child does -*- lexical-binding: t; -*-

;;; Commentary:

;; A bell rings when the session is on screen and leaves a mark on it when it is
;; not, the way tmux's `monitor-bell' does.  The drain hands each BEL to
;; `cooked-bell-function'; the mode line and the buffer annotation report the
;; mark; `cooked--update-attention' clears it when the buffer is looked at.
;;
;; It needs nothing but cooked-util.el.

;;; Code:

(require 'cooked-util)

;;;; The bell
;;
;; BEL used to be a bare `ding': unconditional, unthrottled, and the same whether
;; or not anyone could see the buffer.  `cat' on a binary rang it dozens of times
;; in a row, and a build that rings to say it has finished did so while you were
;; reading another buffer, where a ding says nothing about which session wants
;; you.  tmux's `monitor-bell' is the behaviour worth having: ring when the
;; session is on screen, and otherwise leave a mark on it that stays until you
;; come and look.

(defcustom cooked-bell-function #'cooked-bell-default
  "Function called, in the session's buffer and with no arguments, on each BEL.

Called once per BEL the child sends, so a function that makes a noise has to
do its own rate limiting; the default does.  A signal from it is caught and
reported once, like any other seam inside a drain.

Set it to `ignore' to silence the bell entirely, or to `ding' for the old
behaviour of ringing on every one.  Which noise a ring makes is still
`ring-bell-function', which cooked leaves alone: that is the user's setting
for all of Emacs, and a terminal has no business overriding it."
  :type '(choice (const :tag "Ring when visible, mark when hidden" cooked-bell-default)
                 (const :tag "Ring on every BEL" ding)
                 (const :tag "Nothing" ignore)
                 function)
  :group 'cooked)

(defvar-local cooked-bell-pending nil
  "Whether this session rang unseen, and has not been looked at since.

Set by `cooked-bell-default' and cleared by `cooked--update-attention' when the
buffer is next the selected window's.  Read by the mode line and by
`cooked-buffer-annotation', which is how a bell reaches a terminal picker.")

(defconst cooked--bell-interval 0.5
  "The fewest seconds between two audible bells.")

(defvar cooked--bell-last nil
  "When `cooked-bell-default' last rang, as a `float-time', or nil.

Global rather than buffer-local, because the noise is: two sessions ringing
together are one beep to the person hearing them, and a rate limit per buffer
would let a dozen of them sound a dozen times.")

(defun cooked-bell-default ()
  "Ring if this buffer is visible in the selected frame, and mark it if not.

The default `cooked-bell-function'.  A visible buffer rings `ding' at most
once every `cooked--bell-interval' seconds, so a burst of BELs -- a binary
through `cat', a shell completing against nothing -- is one ring rather than
a rattle.  Dropped rather than deferred: the bells in a burst all say the same
thing, and a late one would arrive after whatever it was about.

A buffer not visible in the selected frame rings nothing, since a beep with
no session attached to it cannot tell you where to look.  It sets
`cooked-bell-pending' instead, which the mode line shows wherever else the
buffer is displayed and which the annotation carries into a picker.  Visible in
some window of the selected frame is enough to ring, even an unselected one:
the output that rang is on screen for you to read."
  (if (get-buffer-window (current-buffer))
      (let ((now (float-time)))
        (unless (and cooked--bell-last
                     (< (- now cooked--bell-last) cooked--bell-interval))
          (setq cooked--bell-last now)
          (ding)))
    (unless cooked-bell-pending
      (setq cooked-bell-pending t)
      (force-mode-line-update))))

(provide 'cooked-bell)
;;; cooked-bell.el ends here
