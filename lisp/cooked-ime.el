;;; cooked-ime.el --- Emacs input methods into a child that owns the keyboard -*- lexical-binding: t; -*-

;;; Commentary:

;; An Emacs Lisp input method composes by editing the buffer: Quail methods
;; such as `chinese-py' and `german-postfix' hold their preedit under an overlay
;; at point, and `korean-hangul' inserts the syllable it is building with
;; `self-insert-command'.  At a prompt that is the input line, ordinary text, and
;; composition works unaided.  While the child owns the keyboard, point sits on
;; the screen, which is read-only and front-sticky, and both kinds give up.
;; `quail-input-method' sees the read-only text and returns the key untouched,
;; so `german-postfix' sent `ae' where `ä' was typed, and hangul tests
;; `buffer-read-only' itself, signals `text-read-only', and loses the key.
;;
;; `cooked-ime--compose' wraps `input-method-function' in every cooked buffer.
;; It lets the method edit the screen for the length of one composition, takes
;; back whatever the method left inserted, sends that text to the child, and
;; hands on the events the method returned, which the forwarding map sends as
;; keys.  While it runs, `cooked-inhibit-redraw-functions' holds the drain off,
;; since a redraw would rewrite the row under the preedit; it drains once the
;; composition ends.  This is ghostel's `ghostel-ime-mode', always on here,
;; because nothing is gained by typing the wrong characters into a program.

;;; Code:

(require 'cooked-util)
(require 'cooked-state)
(require 'cooked-render)
(require 'cooked-keys)

(defvar-local cooked-ime--original nil
  "The `input-method-function' the active input method installed.
Kept by `cooked-ime--install' while `cooked-ime--compose' stands in for it.")

(defvar cooked-ime--composing nil
  "The buffer an input method is composing in, for the extent of a composition.")

(defun cooked-ime--composing-p (buffer)
  "Whether an input method is composing in BUFFER.
On `cooked-inhibit-redraw-functions', so no drain runs beneath a preedit."
  (eq cooked-ime--composing buffer))

(defun cooked-ime--compose (key)
  "Compose KEY with the input method, for the child if it owns the keyboard.

At a prompt the method runs as it would anywhere, since the input line is the
user's text.  Elsewhere it runs with the screen writable at the child's cursor,
and text it inserted and left behind, as `korean-hangul' leaves 한 when a space
ends the syllable, is deleted and sent to the child.  The events it returns go
back to the command loop either way: `german-postfix' turning `a e' into ä
returns the event ä, which the forwarding map sends as the key it is.

`buffer-read-only' is bound as well as `inhibit-read-only' because hangul tests
the variable and not the text.  The drain is held off for the composition and
made once it ends; see `cooked-inhibit-redraw-functions'."
  (let ((original cooked-ime--original)
        (buffer (current-buffer)))
    (if (or (null original) (eq original #'list))
        ;; `list' is what a method that is not composing leaves in place, and
        ;; the command loop reads it as no input method at all.
        (list key)
      (let ((forward (and (cooked--live-session) (cooked--child-owns-keyboard-p)))
            start inserted events done)
        (unwind-protect
            (let ((cooked-ime--composing buffer))
              (if (not forward)
                  (setq events (funcall original key))
                (cooked--snap-to-cursor)
                (setq start (point))
                (cooked--with-child-edit
                  (let ((buffer-read-only nil))
                    (setq events (funcall original key)))))
              (setq done t))
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              ;; Taken back even from a composition that was quit, which would
              ;; otherwise leave a half-built syllable in the grid's rows.
              (when (and start (> (point) start))
                (setq inserted (buffer-substring-no-properties start (point)))
                (cooked--with-child-edit
                  (delete-region start (point))))
              (when (and done inserted)
                (cooked-send-string inserted))
              (cooked--on-wake buffer))))
        events))))

(defun cooked-ime--install ()
  "Put `cooked-ime--compose' in front of the input method just activated."
  (when (and (derived-mode-p 'cooked-mode)
             input-method-function
             (not (memq input-method-function (list #'list #'cooked-ime--compose))))
    (setq cooked-ime--original input-method-function)
    (setq-local input-method-function #'cooked-ime--compose)))

(defun cooked-ime--reinstall ()
  "Put the wrapper back if an input method was activated without telling anyone.

Evil activates the method on entering insert state with
`input-method-activate-hook' bound to nil, and the method sets
`input-method-function' afresh, so without this the first key typed in insert
state would reach the method unwrapped.  Run late on `post-command-hook', after
the command that changed state, and so before the next key is read."
  (when current-input-method
    (cooked-ime--install)))

(defun cooked-ime--uninstall ()
  "Give the input method its own `input-method-function' back."
  (when (and (eq input-method-function #'cooked-ime--compose) cooked-ime--original)
    (setq-local input-method-function cooked-ime--original))
  (setq cooked-ime--original nil))

(defun cooked-ime-setup ()
  "Wrap the input method of the current cooked buffer, now and whenever one starts."
  (add-hook 'input-method-activate-hook #'cooked-ime--install nil t)
  (add-hook 'input-method-deactivate-hook #'cooked-ime--uninstall nil t)
  (add-hook 'post-command-hook #'cooked-ime--reinstall 90 t)
  (add-hook 'cooked-inhibit-redraw-functions #'cooked-ime--composing-p nil t)
  (cooked-ime--install))

(provide 'cooked-ime)
;;; cooked-ime.el ends here
