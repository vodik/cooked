;;; cooked-osc-eval.el --- the OSC 51 command channel for cooked -*- lexical-binding: t; -*-

;;; Commentary:

;; Opt-in, and worth understanding before you do:
;;
;;   (use-package cooked
;;     :commands (cooked cooked-other-window)
;;     :config (require 'cooked-osc-eval))
;;
;; This lets the shell ask the Emacs running it to do things:
;;
;;   find_file src/main.rs        # opens it in the same Emacs
;;   find_file_other_window x.c   # the same, in another window
;;
;; The reason it is a separate file is that this is a command channel driven by
;; bytes on a terminal, and a terminal will happily print whatever it is given.
;; `cat' of a hostile file, output from a compromised host over ssh, a build log
;; quoting text somebody else chose — all of them can pull the trigger.  Loading
;; this file is the moment you accept that trade; leaving it unloaded is a real
;; and reasonable answer.
;;
;; The wire format is `OSC 51 ; E <version> ; <verb> [ ; <arg> ] ST', and the verbs
;; are a closed set: there is no name to intern, and nothing here maps a string the
;; child sent onto a function.  That is the design, and it is eat's rather than
;; vterm's.  An allowlist of names settles *which* function runs and can say nothing
;; about what it is pointed at, which is the half that bites: `find-file' is a
;; reasonable thing to grant right up until the name handed to it is
;; `/ssh:host:/etc/motd' and visiting it dials out.  A closed set has no such gap,
;; because each verb is cooked's own code and validates its own argument.
;;
;; Every verb takes at most one argument, which is the rest of the payload verbatim.
;; So there are no quoting rules at all, and a path with a `;' or a `"' in it needs
;; no escaping — it simply arrives.
;;
;; The exception is `!', which is the escape hatch: an arbitrary named command, from
;; `cooked-eval-commands', which is empty until you fill it.  That is a second
;; deliberate step on top of loading this file, and it is where `compile' goes if you
;; decide you want it.

;;; Code:

(require 'cooked)
;; `cooked-clear-scrollback', which the `K' verb is a remote way of typing.
(require 'cooked-scrollback)

(declare-function magit-status "ext:magit-status")

(defconst cooked-osc-eval-protocol-version 1
  "Wire version this file speaks, sent as `OSC 51;E<version>;...'.

Checked before the verb, so a shell snippet newer than the Emacs it is talking
to is declined rather than half-understood.  `cooked-shell-completion' versions
its own channel the same way and for the same reason.")

(defun cooked-osc-eval-visit-file (name)
  "Visit NAME, unless it is a remote file name."
  (when-let* ((local (cooked--local-name name)))
    (find-file local)))

(defun cooked-osc-eval-visit-file-other-window (name)
  "Visit NAME in another window, unless it is a remote file name."
  (when-let* ((local (cooked--local-name name)))
    (find-file-other-window local)))

(defun cooked-osc-eval-dired (name)
  "Open Dired on NAME, unless it is a remote file name."
  (when-let* ((local (cooked--local-name name)))
    (dired local)))

(defcustom cooked-eval-commands nil
  "Commands the child may invoke through the OSC 51;E `!' verb, by name.

Empty by default, which closes the one part of the channel that is open-ended:
the verbs cooked implements itself need no entry here, so an empty list costs
nothing and leaves nothing to be pointed somewhere unexpected.  Filling it is a
second decision on top of loading `cooked-osc-eval\\=' at all.

`compile\\=' and `recompile\\=' are the obvious candidates and the reason for the
caution: they run arbitrary shell commands, so adding them turns any text that
reaches your terminal into remote code execution.  Add them only if you accept
that:

  (add-to-list \\='cooked-eval-commands \\='(\"compile\" . compile))

`magit-status\\=' is worth spelling out separately because it looks like a
viewer rather than an executor: running git against a repository someone else
chose is closer to `compile\\=' than it appears -- `git status' executes
`core.fsmonitor' from that repository\\='s own .git/config, and other git
operations honour `core.pager' and `core.sshCommand' the same way.  Add it back
only having read that:

  (add-to-list \\='cooked-eval-commands \\='(\"magit-status\" . magit-status))

Whatever goes here is called with the strings the child sent and nothing else
checks them, which the built-in verbs cannot say -- so prefer a wrapper of your
own over the bare command when the argument is a path.  See
`cooked--local-name\\='."
  :type '(alist :key-type string :value-type function)
  :group 'cooked)

(defun cooked-osc-eval-named (payload)
  "Run the allowlisted command named by PAYLOAD, a quoted argument list.

The `!' verb, and the only part of the channel that dispatches on a name the
child chose.  Nothing runs unless `cooked-eval-commands\\=' names it, and that is
empty until you say otherwise."
  (let* ((args (ignore-errors (split-string-and-unquote payload)))
         (name (car args))
         (command (cdr (assoc name cooked-eval-commands))))
    (cond
     ((null args) nil)
     ((null command)
      (message "cooked: refused `%s' (not in `cooked-eval-commands')" name))
     (t (apply command (cdr args))))))

(defun cooked-osc-eval-request (payload)
  "Run the OSC 51;E request described by PAYLOAD.

PAYLOAD is `<version>;<verb>[;<arg>]' -- everything after the `E\\=', which
`cooked--osc-emacs\\=' hands over without interpreting.  The argument is taken
verbatim, `;\\=' and all, because every verb takes at most one and so there is
nothing to disambiguate.

Anything unrecognised is refused with a message rather than signalled: this
runs from a timer the drain queued, where an error is a backtrace the user did
not ask for and cannot act on."
  (pcase (split-string payload ";")
    (`(,version ,verb . ,rest)
     (let ((arg (string-join rest ";")))
       (cond
        ((not (equal version (number-to-string cooked-osc-eval-protocol-version)))
         (message "cooked: ignoring an OSC 51;E request in protocol version %s"
                  version))
        (t
         (pcase verb
           ("F" (cooked-osc-eval-visit-file arg))
           ("O" (cooked-osc-eval-visit-file-other-window arg))
           ("D" (cooked-osc-eval-dired arg))
           ("K" (cooked-clear-scrollback))
           ("!" (cooked-osc-eval-named arg))
           (_ (message "cooked: ignoring an unknown OSC 51;E verb `%s'" verb)))))))
    (_ nil)))

(add-hook 'cooked-osc-eval-functions #'cooked-osc-eval-request)

(provide 'cooked-osc-eval)
;;; cooked-osc-eval.el ends here
