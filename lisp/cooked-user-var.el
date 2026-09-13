;;; cooked-user-var.el --- iTerm2's SetUserVar, as data the shell hands Emacs -*- lexical-binding: t; -*-

;;; Commentary:

;; Opt-in:
;;
;;   (use-package cooked
;;     :commands (cooked cooked-other-window)
;;     :config (require 'cooked-user-var))
;;
;; `OSC 1337 ; SetUserVar=<name>=<base64 value> ST' is iTerm2's, and WezTerm made
;; it the usual way for a shell to tell its terminal something the terminal has no
;; sequence for: which program is in the foreground, which host a prompt belongs
;; to, whether tmux is in the way.  With this loaded, each one is decoded into
;; `cooked-user-vars' in the session's buffer and `cooked-user-var-functions' is
;; run with the name and the value, so a WezTerm-style snippet in your rc works
;; unchanged and what it says is a buffer-local lookup away:
;;
;;   printf '\033]1337;SetUserVar=%s=%s\007' prog "$(printf vim | base64)"
;;
;;   (add-hook 'cooked-user-var-functions
;;             (lambda (name value)
;;               (when (equal name "prog") (setq-local my-prog value))))
;;
;; It is the safe sibling of `cooked-osc-eval', and the difference is the reason
;; this file is short: nothing the child sends here is ever run, looked up as a
;; function, or used as a path.  It is data, and only code you wrote decides what
;; it means.  What a hostile stream *can* do is send a lot of it -- the native core
;; lets an `OSC 1337' through at up to eight megabytes, because the same code
;; carries inline images -- so both the size of one variable and the number of
;; names are bounded, and a set over either bound is refused with a message rather
;; than dropped, since a silent drop looks like a snippet that never worked.
;;
;; Only `SetUserVar=' is handled.  The rest of iTerm2's private channel --
;; `CurrentDir', `ShellIntegrationVersion' -- is left alone, and `File=' never
;; reaches Lisp at all: the native core draws it.  The handler is appended to
;; `cooked-osc-handlers' rather than pushed, so a 1337 handler of your own that is
;; already there, or added later with `add-to-list', takes precedence over this one
;; instead of being silently displaced by it.

;;; Code:

(require 'cooked)
(require 'cooked-osc)

(defgroup cooked-user-var nil
  "Variables the shell sets with OSC 1337 SetUserVar."
  :group 'cooked)

(defcustom cooked-user-var-max-size 8192
  "Largest SetUserVar accepted, in characters of name plus base64 value.

Measured before decoding, as `cooked-clipboard-max-size\\=' is, so an oversized
set costs a length check and not a decode.  The name counts too: it is the
child\\='s string as much as the value is, and nothing else bounds it.  The
default is room for a long command line, which is the largest thing the usual
WezTerm snippets send."
  :type 'natnum)

(defcustom cooked-user-var-limit 64
  "How many distinct names `cooked-user-vars\\=' will hold in one buffer.

A set that would add a name past this is refused out loud; a set of a name
already held always goes through, so a snippet that updates the same few
variables at every prompt can never be locked out by a stream that invented
many more.  Refusing rather than evicting the oldest is for the same reason:
the variables a consumer depends on are the ones set first, at shell startup."
  :type 'natnum)

(defcustom cooked-user-var-functions nil
  "Abnormal hook run with NAME and VALUE each time the child sets a variable.

Both are strings; VALUE has been decoded from base64 and then from UTF-8.  It
runs in the session\\='s buffer after `cooked-user-vars\\=' has been updated,
and it runs on every set, not only on a change, because that is what WezTerm\\='s
`user-var-changed\\=' event does and snippets written for it expect.

Called from inside a drain, so keep it cheap and do not prompt: a mode-line
update or a `setq-local\\=' is what this is for.  An entry that signals is
reported once and does not stop the others -- see `cooked--run-seam\\='."
  :type 'hook)

(defvar-local cooked-user-vars nil
  "Alist of the variables the child has set with SetUserVar, NAME to VALUE.

Both are strings.  Bounded by `cooked-user-var-limit\\=' names and
`cooked-user-var-max-size\\=' per set.  Read one with `cooked-user-var\\='.")

(defun cooked-user-var (name &optional buffer)
  "Value the child last gave user variable NAME in BUFFER, or nil.
BUFFER defaults to the current buffer."
  (cdr (assoc name (buffer-local-value 'cooked-user-vars
                                       (or buffer (current-buffer))))))

(defun cooked-user-var--set (name data)
  "Store user variable NAME from base64 DATA and run the hook, or refuse.
Return non-nil when the variable was stored."
  (let ((size (+ (length name) (length data))))
    (cond
     ((> size cooked-user-var-max-size)
      (message "cooked: refused a %d-character user variable `%s' (see `cooked-user-var-max-size')"
               size (truncate-string-to-width name 40 nil nil t))
      nil)
     ((and (not (assoc name cooked-user-vars))
           (>= (length cooked-user-vars) cooked-user-var-limit))
      (message "cooked: refused user variable `%s', already holding %d (see `cooked-user-var-limit')"
               (truncate-string-to-width name 40 nil nil t) cooked-user-var-limit)
      nil)
     (t
      ;; Malformed base64 is dropped quietly, as OSC 52 drops it: that is the
      ;; child's bug, where an over-bound set may be a limit set too low.
      (when-let* ((value (cooked--decode-base64-utf8 data)))
        (setf (alist-get name cooked-user-vars nil nil #'equal) value)
        (cooked--run-seam 'cooked-user-var-functions name value)
        t)))))

(defun cooked-user-var--osc (parts)
  "Handle an OSC 1337 payload PARTS, acting only on SetUserVar.

The value is base64 and so never contains a `;\\=', but the parts are rejoined
anyway: splitting is the core\\='s generic treatment of every OSC, not something
this payload asked for.  The name ends at the first `=\\=' and may not be
empty, which is also how WezTerm reads it."
  (let ((payload (string-join parts ";")))
    (when (string-match "\\`SetUserVar=\\([^=]+\\)=" payload)
      (cooked-user-var--set (match-string 1 payload)
                            (substring payload (match-end 0))))))

(add-to-list 'cooked-osc-handlers '(1337 . cooked-user-var--osc) t)

(provide 'cooked-user-var)
;;; cooked-user-var.el ends here
