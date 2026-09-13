;;; cooked-osc-context.el --- OSC 3008 contexts in the mode line -*- lexical-binding: t; -*-

;;; Commentary:

;; Opt-in:
;;
;;   (use-package cooked
;;     :commands (cooked cooked-other-window)
;;     :config (require 'cooked-osc-context))
;;
;; systemd 258 and later announce, on the terminal they take over, when a tool
;; starts and stops speaking for somebody else: `run0' acquiring root,
;; `systemd-nspawn' booting a container, `systemd-vmspawn' a VM.  The wire format
;; is UAPI.15, `OSC 3008 ; start=<id> *(; field=value) ST' and a matching
;; `OSC 3008 ; end=<id> ST'
;; (https://uapi-group.org/specifications/specs/osc_context/).  With this loaded,
;; the innermost context worth mentioning is named in the mode line -- so a shell
;; `run0' handed you says so, without anybody scraping a `#' out of the prompt.
;;
;; Contexts nest, and on a stock systemd box they nest a great deal: the
;; profile.d snippet systemd ships opens a `shell' context at every bash prompt
;; and a `command' context around every command line, so the stack under a
;; `run0 bash' typed at such a prompt is shell, command, elevate.  That is why
;; this shows the innermost *interesting* context rather than the innermost one,
;; and why `cooked-osc-context-labels' names the types worth a label instead of
;; the ones to hide.
;;
;; It is also what makes the stack heal itself.  The spec says a `start=' for an
;; id already open is an update that implicitly ends everything opened inside
;; it, and that prompt snippet re-sends its shell's `start=' every time a prompt
;; is drawn -- so a `run0' killed before it could say `end=' is forgotten at the
;; next prompt of the shell that ran it, which is the moment its absence becomes
;; true.
;;
;; A layer and not the core for the reason the spec itself gives: the whole
;; channel is auxiliary information, a label in the mode line is UI, and there is
;; nothing for Rust to hold -- the core already passes OSC 3008 through as an
;; ordinary `(osc ...)' event, so this is an entry in `cooked-osc-handlers\=' and
;; nothing more.
;;
;; No byte the child sent reaches the mode line.  The payload is parsed down to a
;; symbol from a closed set, exactly as OSC 9;4 is, and the id is kept only to be
;; compared with the next one.  `user=', `hostname=', `container=' and the rest
;; are ignored: they would make a better label, and they are also the child
;; choosing what the mode line says, which is the thing this file exists not to
;; allow.

;;; Code:

(require 'cooked)
(require 'cooked-mode)
(require 'seq)

(defface cooked-osc-context '((t :inherit shadow))
  "Face for a container, VM or remote context in the mode line.

As quiet as the `@host' beside it, because it is the same kind of fact: where
the keystrokes are going, not a warning about them."
  :group 'cooked)

(defface cooked-osc-context-elevate '((t :inherit error))
  "Face for an `elevate' context in the mode line -- a shell running as root.

The one context that is a hazard rather than a location.  The spec's own example
of a use for it is tinting such output red, and this is the mode-line half of
that idea."
  :group 'cooked)

(defcustom cooked-osc-context-labels
  '((elevate . "root")
    (container . "container")
    (vm . "vm")
    (remote . "remote"))
  "Context types worth naming in the mode line, each with the label to show.

The innermost open context whose type appears here is shown; any other type is
passed over as though it were not open, so the stock systemd prompt snippet's
`shell' and `command' contexts do not hide the `elevate' underneath them.  An
empty list shows nothing and leaves the stack still being kept.

The types are the spec's twelve: `boot', `container', `vm', `elevate',
`chpriv', `subcontext', `remote', `shell', `command', `app', `service' and
`session'.  `elevate' is labelled `root' because that is the only thing
systemd sends it for: its `osc_context_open_chpriv' says `elevate' when the
target user is `root' or `0', `subcontext' when it is the caller already, and
`chpriv' for anyone else.  `chpriv' is left out by default because running as
`nobody' is not something the mode line needs to shout about.  `remote' is kept
for other senders -- systemd 261 itself sends none, and an ssh login to a
systemd host arrives from `pam_systemd' as a `session', which is left out
because the `@host' OSC 7 already puts in the mode line says the same thing.
Add either if it is:

  (add-to-list \\='cooked-osc-context-labels \\='(chpriv . \"user\"))

A label is cooked's text, not the child's, and is shown verbatim; a `%' in one
is escaped for you."
  :type '(alist :key-type (choice (const elevate) (const chpriv)
                                  (const container) (const vm) (const remote)
                                  (const session) (const subcontext)
                                  (const service) (const boot) (const app)
                                  (const shell) (const command))
                :value-type string)
  :group 'cooked)

(defconst cooked-osc-context--types
  (mapcar (lambda (type) (cons (format "type=%s" type) type))
          '(boot container vm elevate chpriv subcontext
            remote shell command app service session))
  "Every `type=' field the spec defines, spelled whole, mapped to its symbol.

Keyed by the entire field rather than by its value so that one `assoc' is both
the parse and the validation: `type=elevate ' with a trailing space, `TYPE=vm'
and `type=root' are simply not in the table, and a context opened with one of
them is kept with no type -- it still nests, and still ends what it should when
it ends, but it is never shown.")

(defconst cooked-osc-context--depth 32
  "How many contexts one buffer keeps open before refusing the next.

The spec asks for a limit without naming one, and says to keep the outermost
contexts and drop the newest rather than the other way round -- otherwise a
child could push its elevation off the bottom of the stack by opening enough
`subcontext's on top of it.  Thirty-two is far past any honest nesting: the
stock prompt snippet costs two per shell level.")

(defvar-local cooked-osc-context--stack nil
  "Open OSC 3008 contexts in this buffer, innermost first.

Each entry is (ID . TYPE).  ID is the child's own identifier, at most 64
printable ASCII characters, and is only ever compared with the next `start='
or `end=' -- it never reaches the screen.  TYPE is a symbol from
`cooked-osc-context--types', or nil when the context did not declare one this
file recognises.

Deliberately left alone by RIS.  The spec says a terminal reset must not touch
the stack, so that a program running inside a context cannot hide it from the
user by resetting the terminal -- and `reset' is the first thing anyone types
in a terminal that looks wrong.")

(defun cooked-osc-context--parse-head (head)
  "The (VERB . ID) that HEAD, the first field of an OSC 3008 payload, carries.

VERB is `start' or `end'.  nil for anything else, including an id outside the
spec's 1 to 64 printable characters -- checked here rather than trusted, because
the id is kept in the stack for as long as the context stays open."
  (when (string-match (rx bos (group (or "start" "end")) "="
                          (group (** 1 64 (any " -~")))
                          eos)
                      head)
    (cons (if (equal (match-string 1 head) "start") 'start 'end)
          (match-string 2 head))))

(defun cooked-osc-context--close (id)
  "Drop the context ID and every context opened inside it.

Non-nil when ID was open.  An inner context cannot outlive the one it was opened
in: the spec says as much for a `start=' that updates a context, and says
nothing about an `end=' that names one that is not innermost -- but the only way
to reach that case honestly is an inner tool that died without saying `end=',
and keeping its context would leave a stale `root' in the mode line of a shell
that is no longer root."
  (when-let* ((tail (seq-position cooked-osc-context--stack id
                                  (lambda (entry id) (equal (car entry) id)))))
    (setq cooked-osc-context--stack (nthcdr (1+ tail) cooked-osc-context--stack))
    t))

(defun cooked-osc-context--handle (parts)
  "Open, update or close a context from PARTS, the OSC 3008 payload.

A `start=' for an id not yet open pushes it; for one already open it replaces
its type and ends everything inside it, as the spec's update rule says.  An
`end=' closes the context it names and everything inside it, and is ignored for
an id that is not open.  Fields other than `type=' are ignored, as are fields
this file does not recognise -- the spec asks for leniency, and a malformed
field costs only the type it might have declared.

A head that does not parse leaves the stack untouched, since a sequence that
cannot say which context it means cannot safely be applied to any of them.

The mode line is repainted only when the context it names has changed.  The
stock prompt snippet opens two or three contexts per command, and nearly none
of them change the label: a `command\=' opened inside a `shell\=' shows nothing
before and after."
  (let ((shown (cooked-osc-context--current)))
    (pcase (cooked-osc-context--parse-head (or (car parts) ""))
      (`(start . ,id)
       (let ((type (seq-some (lambda (field)
                               (cdr (assoc field cooked-osc-context--types)))
                             (cdr parts))))
         (cooked-osc-context--close id)
         (when (< (length cooked-osc-context--stack) cooked-osc-context--depth)
           (push (cons id type) cooked-osc-context--stack))))
      (`(end . ,id)
       (cooked-osc-context--close id)))
    (unless (eq shown (cooked-osc-context--current))
      (force-mode-line-update))))

(defun cooked-osc-context--current ()
  "The type of the innermost open context `cooked-osc-context-labels' names."
  (seq-some (lambda (entry)
              (and (assq (cdr entry) cooked-osc-context-labels) (cdr entry)))
            cooked-osc-context--stack))

(defun cooked-osc-context--mode-line ()
  "The context segment of the mode line, or nil.

Nothing once the child has exited, for the reason `cooked--mode-line' gives:
the stack of a dead session is not stale information but wrong information, and
a `root' beside `exited 0' would say the buffer is still somewhere it is not."
  (unless cooked--exit
    (when-let* ((type (cooked-osc-context--current)))
      (let ((label (alist-get type cooked-osc-context-labels)))
        (concat " "
                (propertize
                 (cooked--mode-line-quote label)
                 'face (if (eq type 'elevate)
                           'cooked-osc-context-elevate
                         'cooked-osc-context)
                 'help-echo
                 (format "cooked: inside an OSC 3008 `%s' context" type)))))))

(defconst cooked-osc-context--segment '(:eval (cooked-osc-context--mode-line))
  "The mode-line construct this file puts in front of cooked's own segment.")

(defun cooked-osc-context--setup ()
  "Put the context segment ahead of cooked's own in this buffer's mode line.

Ahead of it, and so of the `@host' and the state word, because a shell running
as root is the one thing in that row a user most needs to have read first.
`mode-line-process' rather than a new slot in `cooked--mode-line', so that the
core segment knows nothing about a layer that may not be loaded; the check
keeps a second run of the hook from adding it twice."
  (unless (equal (car-safe mode-line-process) cooked-osc-context--segment)
    (setq-local mode-line-process
                (list cooked-osc-context--segment mode-line-process))))

(setf (alist-get 3008 cooked-osc-handlers) #'cooked-osc-context--handle)
(add-hook 'cooked-mode-hook #'cooked-osc-context--setup)
;; Sessions already running when this was loaded: their contexts from before
;; the load are lost, but anything opened from here on is shown.
(dolist (buffer (buffer-list))
  (with-current-buffer buffer
    (when (derived-mode-p 'cooked-mode)
      (cooked-osc-context--setup))))

(provide 'cooked-osc-context)
;;; cooked-osc-context.el ends here
