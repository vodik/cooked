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

(defmacro cooked--dolist-windows (var windows &rest body)
  "Run BODY with VAR bound to each still-live window of WINDOWS.

The list is always captured before a redraw and used after it, so a window
being gone by the time it is reached is ordinary rather than exceptional."
  (declare (indent 2) (debug (symbolp form body)))
  `(dolist (,var ,windows)
     (when (window-live-p ,var)
       ,@body)))

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
