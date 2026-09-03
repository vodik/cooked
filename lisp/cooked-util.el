;;; cooked-util.el --- Session handles, and the macros every layer uses -*- lexical-binding: t; -*-

;;; Commentary:

;; The bottom of the Lisp stack, below even `cooked.el\='.  Nothing here knows what a
;; terminal is: it is the customization group, the handle to the native core, and the
;; four macros the layers above reach for often enough that open-coding them was how
;; they drifted apart.
;;
;; It exists because the layering has a floor.  `cooked-face.el\=' and `cooked-deco.el\='
;; are required *by* `cooked.el\=', so they cannot require it back for a macro -- and
;; duplicating `cooked--dolist-buffers\=' into each of them is exactly the shape this
;; file was extracted to stop.

;;; Code:

(require 'cl-lib)

(defgroup cooked nil
  "A terminal emulator that yields to Emacs when the child wants a line."
  :group 'processes
  :prefix "cooked-")

(defvar cooked-debug nil
  "When non-nil, re-signal redisplay errors instead of reporting them.")
(declare-function cooked--pid "cooked-core")
(declare-function cooked--live-p "cooked-core")
(declare-function cooked--send "cooked-core")
;; `signal' refuses a symbol with no `error-conditions' property, so the native
;; core's `io_error' would otherwise itself fail with "Invalid error symbol"
;; the first time a pty operation errors.
(define-error 'cooked-error "cooked: I/O error")

(defvar-local cooked--session nil "Handle returned by `cooked--spawn'.")

(defun cooked-session-p (object)
  "Whether OBJECT is a session handle made by the native core.

Exists mostly so the `wrong-type-argument' the core signals names a
predicate that resolves.  The core does the real check, comparing the
user-pointer's finalizer against its own; Emacs itself cannot tell one
module's user-pointer from another's."
  (and (user-ptrp object) (ignore-errors (integerp (cooked--pid object)))))

(defmacro cooked--dolist-buffers (&rest body)
  "Run BODY once in each live cooked buffer, with that buffer current.

Several things have to reach every session at once — a theme change invalidating
the face caches, a frame focus change, the list of sessions to switch to — and
each of them was walking `buffer-list' and testing the major mode itself.  BODY
that needs the buffer as a value can say `current-buffer'.

BODY runs inside its own `condition-case', unless `cooked-debug': this is called
from global hooks (`window-selection-change-functions' and the like) that walk
every cooked buffer in one pass, so one buffer whose BODY signals must not abort
the pass and leave every buffer after it in that same `buffer-list' untouched."
  (declare (indent 0) (debug body))
  `(dolist (buffer (buffer-list))
     (when (buffer-live-p buffer)
       (with-current-buffer buffer
         (when (derived-mode-p 'cooked-mode)
           (if cooked-debug
               (progn ,@body)
             (condition-case err
                 (progn ,@body)
               (error
                (message "cooked: buffer-wide hook failed in %s: %S" buffer err)))))))))

(defmacro cooked--protect-hook (&rest body)
  "Run BODY, catching a signal rather than letting it escape.

Re-signals when `cooked-debug' is set.

For a function installed directly on `pre-command-hook', `post-command-hook'
or `pre-redisplay-functions' -- none of which guard their own entries as
defensively as a single caught `condition-case' at the drain boundary
covers.  A signal from `post-command-hook' is merely reported and the next
command still runs; one from `pre-redisplay-functions' is worse, since it
can recur on every subsequent redisplay of the frame it came from, which
is a substantially worse failure than a drain that skipped a frame and
resynced.  Everything reached by way of `cooked--drain-and-apply' already
has its own guard for the same reason; this is the same policy for the
handful of functions that reach the buffer from outside a drain."
  (declare (indent 0) (debug body))
  `(if cooked-debug
       (progn ,@body)
     (condition-case err
         (progn ,@body)
       (error (message "cooked: hook failed: %S" err)))))

(defvar-local cooked--seams-reported nil
  "Seams that have already reported a failure in this buffer.

Keys, compared with `equal\\=': what `cooked--protect-seam\\=' was given, which is
the hook symbol consed onto the entry for a layer and a bare symbol for one of
cooked\\='s own passes.  Per key rather than per seam, so one broken function
silences only itself and a second listener on the same hook is still heard from.

Per buffer, and cleared when a session starts: a layer that fails only against
one child\\='s output is worth hearing about again for the next one.")

(defmacro cooked--protect-seam (key &rest body)
  "Value of BODY, or nil if it signalled, reported once per buffer under KEY.

The call site for anything running from inside a drain that the buffer is
already correct without -- an optional layer\\='s contribution, or one of cooked\\='s
own cosmetic passes.  Three policies, and the five open-coded `condition-case\\='s
this replaced each got a different pair of them wrong.

*Re-signals under `cooked-debug\\='*, like `cooked--protect-hook\\=' and
`cooked--dolist-buffers\\='.  A developer who asked to see failures must not have
this one class of them swallowed anyway, which is what made a decoration layer
that signalled on every row impossible to debug from inside Emacs.

*Reports rather than discards.*  `(error nil)\\=' meant a layer that had never
worked was indistinguishable from a layer nobody had loaded.

*Reports once.*  The loudest of these seams fires per damaged row per drain, so
an unrated `message\\=' is a broken layer taking the echo area away from
everything else Emacs has to say.  See `cooked--seams-reported\\='.

Returns nil on failure, which is what makes it compose with
`cooked--run-seam-until-success\\=': an entry that signalled has given no answer,
so the next entry is asked."
  (declare (indent 1) (debug (form body)))
  `(if cooked-debug
       (progn ,@body)
     (condition-case err
         (progn ,@body)
       (error (cooked--seam-failed ,key err) nil))))

(defun cooked--seam-failed (key err)
  "Report ERR against KEY, once per buffer, and then stay quiet about it."
  (unless (member key cooked--seams-reported)
    (push key cooked--seams-reported)
    (message "cooked: %S failed and will not be reported again here: %S" key err)))

(defvar cooked--seam-running nil
  "The seam being walked, for `cooked--protect-seam\\=' to key a failure on.

A dynamic binding rather than something the wrapper closes over, and the reason
is worth a sentence because the closure is the obvious spelling.
`run-hook-wrapped\\=' hands the wrapper its arguments, so the only thing left to
capture is the seam\\='s own name -- and capturing it costs a closure per call, on
a path that runs once per damaged row per drain.  Measured byte-compiled at
1.14us per call against 0.50us with the wrapper hoisted to top level.  The CPU
time is immaterial either way; one closure per row per frame is garbage this
tree does not otherwise make.

Bound around the whole walk rather than per entry, and with `let\\=' rather than
`setq\\=', so a seam whose entry runs another seam -- a row listener that
refreshes the keymap, which asks `cooked-input-mode-functions\\=' -- unwinds to
the right name.")

(defun cooked--seam-notify (fn &rest args)
  "Apply FN to ARGS under containment, answering nil so the walk goes on."
  (cooked--protect-seam (cons cooked--seam-running fn) (apply fn args))
  nil)

(defun cooked--seam-answer (fn &rest args)
  "Apply FN to ARGS under containment, answering whatever it answered."
  (cooked--protect-seam (cons cooked--seam-running fn) (apply fn args)))


(defun cooked--run-seam (seam &rest args)
  "Call every function on abnormal hook SEAM with ARGS.  Always nil.

`run-hook-with-args\\=' is not what this is, and the difference is the whole
point: it contains nothing, so one broken entry would take the entries after it
*and* the drain around them with it.  Containment has to be per entry, and
`run-hook-wrapped\\=' is what makes that a wrapper rather than a reimplementation
of hook traversal -- including the `t\\=' element a buffer-local hook uses to
reach the global value, which a `dolist\\=' over the variable would call as a
function.

See `cooked--protect-seam\\=' for what each entry is protected from and how a
failure is reported."
  (let ((cooked--seam-running seam))
    (apply #'run-hook-wrapped seam #'cooked--seam-notify args)))

(defun cooked--run-seam-until-success (seam &rest args)
  "The first non-nil answer any function on abnormal hook SEAM gives to ARGS.

`run-hook-with-args-until-success\\=' semantics, with the per-entry containment
`cooked--run-seam\\=' explains -- and the interaction is the useful half: an entry
that signals returns nil through `cooked--protect-seam\\=', which is exactly \"no
answer\", so the next entry is asked rather than the whole seam falling silent
over one layer\\='s bug.

Not simulated: `run-hook-wrapped\\=' already returns the first non-nil value its
wrapper produced and stops there, so this is that function with a contained
wrapper and nothing else."
  (let ((cooked--seam-running seam))
    (apply #'run-hook-wrapped seam #'cooked--seam-answer args)))

(defmacro cooked--dolist-windows (var windows &rest body)
  "Run BODY with VAR bound to each still-live window of WINDOWS.

The list is always captured before a redraw and used after it, so a window
being gone by the time it is reached is ordinary rather than exceptional."
  (declare (indent 2) (debug (symbolp form body)))
  `(dolist (,var ,windows)
     (when (window-live-p ,var)
       ,@body)))

(defmacro cooked--cached (table key &rest body)
  "Value of BODY for KEY, memoized in the hash table held in TABLE.

TABLE is a symbol naming a variable, not an expression: the table is made on
first use and stored back, so no caller has to have been initialised first.
That is the whole reason this exists rather than a bare `with-memoization\='.
The caches it fronts are reached from paths that run before -- and without --
`cooked--start\=', `cooked--rescale-deco\=' from a `text-scale\=' change being the
one that actually bit, and a nil table there is a wrong-type error inside a
redisplay hook that nothing catches.

Only for caches whose key says everything about the value, which is what makes
one shared with the session before it harmless.  Anything keyed on something the
core hands out afresh per session -- an image id -- must be cleared when a
session starts instead; see `cooked--reset-images\='."
  (declare (indent 2) (debug (symbolp form body)))
  `(progn
     (unless (hash-table-p ,table)
       (setq ,table (make-hash-table :test #'equal)))
     (with-memoization (gethash ,key ,table) ,@body)))

(defmacro cooked--with-child-edit (&rest body)
  "Run BODY as an edit made on the child\='s behalf rather than by the user.

Two bindings, one reason each, and both follow from the same fact: the text
BODY touches belongs to the emulator, not to whoever is typing.

`inhibit-read-only\=', because the screen and the scrollback are protected
\(`cooked--protect\=') against a keystroke damaging a picture Emacs has no way to
repair -- and these edits are the writer that protection was never aimed at.

`buffer-undo-list\=', because a redraw deletes and reinserts whole rows on every
drain, and recording that is useless before it is harmful.  Undoing a row the
child painted would put back text the emulator\='s grid does not have, and every
later delta is computed against that grid, so nothing would ever mend the
disagreement.  Meanwhile a busy screen turns its whole text over several times a
second, and the list grows until Emacs warns that it has discarded megabytes --
which is the only sign a user ever gets that undo was recording the terminal.

What stays recorded is what the user typed at the prompt, the one piece of the
buffer that is theirs.  Run `cooked--check-undo-anchor\=' *after* the macro and
never inside it, wherever BODY moves the input line: inside, the discard would
land on the binding above and be thrown away with it while the anchor it records
stayed."
  (declare (indent 0) (debug body))
  `(let ((inhibit-read-only t)
         (buffer-undo-list t))
     ,@body))

(defun cooked--live-session ()
  "This buffer's session while there is still a child on the other end.

Nil once the child has exited, which is a state the buffer outlives: the
transcript stays, and `cooked--on-exit' clears `cooked--session' without
touching the keymap, so the raw map is still installed and every key still
resolves to a command that wants to write to the pty."
  (and cooked--session (cooked--live-p cooked--session) cooked--session))

(defun cooked--require-session ()
  "This buffer's live session, refusing rather than erroring when it is gone.

Every command that reaches into the native core goes through here.  Handing
nil to a function that expects a user-pointer shows the user
`wrong-type-argument' `user-ptrp' nil — a backtrace where the honest answer is
that the session is over."
  (or (cooked--live-session) (user-error "No live session")))

(defun cooked--send-to-child (bytes)
  "Send BYTES to the child, refusing if the session is over."
  (cooked--send (cooked--require-session) bytes))

(defun cooked--send-if-live (bytes)
  "Send BYTES if there is still a child, and do nothing if there is not.

For the writes that are not a keystroke: a device-status reply resolved
mid-drain, a focus notification from a global hook, a completion request.  There
the child having just exited is an ordinary race rather than something the user
asked for and should be told about — and signalling from inside a process filter
would abort the rest of the redisplay."
  (when-let* ((session (cooked--live-session)))
    (cooked--send session bytes)))

(defconst cooked--source-directory
  (file-name-directory
   (file-truename (or load-file-name buffer-file-name default-directory)))
  "Directory holding this file, captured at load time.

Through `file-truename\=' on the file rather than on the directory, because the
package managers symlink the .el files individually into a build directory that
is itself a real directory -- so resolving the directory answers with the build
tree, and only resolving the file lands in the clone.  `cooked--root\=' needs the
clone: that is where Cargo.toml, terminfo/ and shell-integration/ are.")

(defun cooked--root ()
  "Top of the source tree: the directory holding Cargo.toml.

Found by walking up from `cooked--source-directory\=' rather than by taking its
parent, which matters for the package managers: `straight\=' and `elpaca\=' load
the Lisp from a build directory of symlinks into the clone, and its parent is
the build root -- which has no Cargo.toml, no terminfo/ and no
shell-integration/, and would send `cooked--load-module\=' off to build a crate
that is not there.  `cooked--source-directory\=' has already resolved the link,
so the walk starts inside the clone, where all three are.

Falls back to the parent directory, which is the answer for a plain
`load-path\=' checkout and the only thing left to guess if the tree has been
split up by an installer.  See `cooked-native-module\=' for pointing at a
prebuilt artifact instead."
  (let ((dir (file-name-as-directory cooked--source-directory)))
    (or (locate-dominating-file dir "Cargo.toml")
        (file-name-directory (directory-file-name dir)))))

(defun cooked--local-name (name)
  "Return NAME, or nil having refused it for naming a remote file.

Every path cooked takes from the child is a string somebody else chose: an OSC 7
working directory, a file named over the command channel, a name parsed out of
output.  Under TRAMP such a string is not inert.  Visiting
\"/ssh:host:/etc/motd\" opens a connection to a host the sender picked and runs
that method\='s own transport program to get there, which is a command executed
on somebody else\='s say-so wearing the shape of a path.  \"/sudo::/etc/shadow\"
is the same move without leaving the machine.

The check has to come before anything that so much as looks at the file,
`file-exists-p\=' and `file-directory-p\=' included: those are the calls that
dispatch to the TRAMP handler, so asking whether the file is there is already
the connection this exists to refuse.

Here rather than in one of the layers because two of them need it and neither
can require the other -- `cooked-osc.el\=' for OSC 7, which is always on, and
`cooked-osc-eval.el\=' for the command channel, which is not.  That is what this
file is the floor for."
  (if (file-remote-p name)
      (progn (message "cooked: refused `%s' (a remote file name)" name) nil)
    name))

(provide 'cooked-util)
;;; cooked-util.el ends here
