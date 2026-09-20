;;; cooked-util.el --- Session handles, and the macros every layer uses -*- lexical-binding: t; -*-

;;; Commentary:

;; The bottom of the Lisp stack.  Nothing here knows what a terminal is: it is the
;; customization group, the handle to the native core and the list of what the core
;; defines, the macros the layers above reach for often enough that open-coding them
;; was how they drifted apart, and a few helpers about windows, files and hosts that
;; more than one layer needs.
;;
;; Every other file requires this one, directly or through the base tier, and it
;; requires nothing of the package.

;;; Code:

(require 'cl-lib)
(require 'url-util)

(defgroup cooked nil
  "A terminal emulator that yields to Emacs when the child wants a line."
  :group 'processes
  :prefix "cooked-")

(defvar cooked-debug nil
  "When non-nil, re-signal redisplay errors instead of reporting them.")

(eval-and-compile
  (defconst cooked--core-functions
    '(cooked--alt-scroll-p cooked--answer-color-query
      cooked--bracketed-paste-p
      cooked--clear-to-prompt
      cooked--core-version cooked--drain cooked--feed cooked--filter-feed
      cooked--focus-events-p cooked--foreground-pid cooked--forget-history
      cooked--encode-key
      cooked--image-forget cooked--job-control cooked--key-table cooked--kill
      cooked--live-p cooked--make-filter cooked--pid
      cooked--osc-reply cooked--prompt-text cooked--ready cooked--redraw
      cooked--remove-rows cooked--reply cooked--reply-focus cooked--resize
      cooked--row-unsent
      cooked--sample-mode cooked--screen-text
      cooked--send cooked--send-key cooked--send-line cooked--send-mouse-report
      cooked--send-paste-text cooked--set-attended
      cooked--set-color-scheme cooked--set-frame-size cooked--set-graphics-shown
      cooked--set-hidden cooked--set-palette
      cooked--set-tuning cooked--signal cooked--spawn
      cooked--strip-paste-controls cooked--wire-layout)
    "Every function the native core defines, by name.

The core registers these when `cooked--load-module' loads it, so the
byte-compiler has never seen any of them.  Each file that calls one says
`(cooked--declare-core)' once, rather than keeping a list of its own that a
new defun in src/lib.rs would leave behind.  The test
`cooked-core-functions-match-lib-rs' holds this list and the Rust table in
step."))

(defmacro cooked--declare-core ()
  "Declare every function in `cooked--core-functions' to the byte-compiler.
Expands to one `declare-function' per name, so it has to be called at the top
level of each file that calls into the core."
  `(progn
     ,@(mapcar (lambda (name) `(declare-function ,name "ext:cooked-core"))
               cooked--core-functions)))

(cooked--declare-core)

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

(defun cooked-filter-p (object)
  "Whether OBJECT could be a VT filter handle made by `cooked--make-filter'.

The sibling of `cooked-session-p', and the predicate the core names when a
filter defun is handed something else.  Only a user-pointer can be a filter,
and that is as much as this can honestly say: Emacs cannot tell one module's
user-pointer from another's, and a filter has no accessor to ask the core
through the way `cooked-session-p' asks `cooked--pid'.  The core does the real
check -- the user-pointer's finalizer and the type tag inside it -- and this
exists so the `wrong-type-argument' it signals names a predicate that
resolves."
  (user-ptrp object))

(defvar cooked--buffers nil
  "Every buffer that has entered `cooked-mode', including some since killed.

Pushed onto by `cooked--register-buffer' and pruned by `cooked--buffers', which
is the only reader.  Pruned there rather than from `kill-buffer-hook', because a
buffer can also leave the mode by changing its major mode, and asking on the way
in catches both.")

(defun cooked--register-buffer ()
  "Record the current buffer as a cooked buffer, from `cooked-mode'."
  (unless (memq (current-buffer) cooked--buffers)
    (push (current-buffer) cooked--buffers)))

(defun cooked--buffers ()
  "The live cooked buffers, most recently selected first.

In `buffer-list' order, since the pickers built on this list offer the session
used last first.  Taking the order from `buffer-list' costs a `memq' per
buffer, where testing each buffer's major mode meant making it current, which
swaps in every one of its local variables."
  (setq cooked--buffers
        (cl-remove-if-not
         (lambda (buffer)
           (and (buffer-live-p buffer)
                (provided-mode-derived-p (buffer-local-value 'major-mode buffer)
                                         'cooked-mode)))
         cooked--buffers))
  (if (cdr cooked--buffers)
      (cl-remove-if-not (lambda (buffer) (memq buffer cooked--buffers)) (buffer-list))
    cooked--buffers))

(defmacro cooked--dolist-buffers (&rest body)
  "Run BODY once in each live cooked buffer, with that buffer current.

Several things have to reach every session at once — a theme change invalidating
the face caches, a frame focus change, the list of sessions to switch to — and
each of them was walking `buffer-list' and testing the major mode itself.  BODY
that needs the buffer as a value can say `current-buffer'.  The buffers are
those `cooked--buffers' returns, so a hook that walks them costs nothing for the
buffers that are not cooked ones.

BODY runs inside its own `condition-case', unless `cooked-debug': this is called
from global hooks (`window-selection-change-functions' and the like) that walk
every cooked buffer in one pass, so one buffer whose BODY signals must not abort
the pass and leave every buffer after it in that same `buffer-list' untouched."
  (declare (indent 0) (debug body))
  `(dolist (buffer (cooked--buffers))
     ;; Asked again per buffer: BODY run in an earlier one can kill a later one,
     ;; or change its major mode.
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
own cosmetic passes.  Three policies, which an open-coded `condition-case\\='
easily gets a different pair of wrong.

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
a path that runs once per damaged row per drain.  The CPU time is immaterial;
one closure per row per frame is garbage this tree does not otherwise make.

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

;;;; Reading the packed records the native core sends
;;
;; Three of the drain's fields arrive as unibyte strings of fixed-width little-endian
;; records rather than as lists -- style spans, box-glyph runs and image placements --
;; for the reason `Block::push_style' and `Deco::packed' give at length: Rust parses far
;; faster than Emacs renders, so a list would cons per record on the path that redraws
;; continuously.  What that buys on the wire it costs at the far end in decoding, and
;; these are the two functions that decoding is made of.
;;
;; Here rather than in any one reader because all three are in different files, and each
;; had spelled the same `logior'/`ash' ladder out for itself -- which is the shape this
;; file exists to stop.  `defsubst' rather than `defun' because they are called per
;; record on the render path, where a function call is a real fraction of the work.

(defsubst cooked--u16 (packed i)
  "The little-endian 16-bit integer at byte offset I of unibyte string PACKED."
  (logior (aref packed i) (ash (aref packed (1+ i)) 8)))

(defsubst cooked--u32 (packed i)
  "The little-endian 32-bit integer at byte offset I of unibyte string PACKED.

Always a fixnum: 32 bits fit with room to spare on a 64-bit Emacs, and on a
32-bit build the top bits spill into a bignum, which is slower to add to a
buffer position but no less correct."
  (logior (aref packed i)
          (ash (aref packed (+ i 1)) 8)
          (ash (aref packed (+ i 2)) 16)
          (ash (aref packed (+ i 3)) 24)))

(defmacro cooked--cached (table key &rest body)
  "Value of BODY for KEY, memoized in the hash table held in TABLE.

TABLE is a symbol naming a variable, not an expression: the table is made on
first use and stored back, so no caller has to have been initialised first.
That is the whole reason this exists rather than a bare `with-memoization'.
The caches it fronts are reached from paths that run before -- and without --
`cooked--start', `cooked--rescale-deco' from a `text-scale' change being the
one that actually bit, and a nil table there is a wrong-type error inside a
redisplay hook that nothing catches.

Only for caches whose key says everything about the value, which is what makes
one shared with the session before it harmless.  Anything keyed on something the
core hands out afresh per session -- an image id -- must be cleared when a
session starts instead; see `cooked--reset-images'."
  (declare (indent 2) (debug (symbolp form body)))
  `(progn
     (unless (hash-table-p ,table)
       (setq ,table (make-hash-table :test #'equal)))
     (with-memoization (gethash ,key ,table) ,@body)))

(defmacro cooked--cached-bounded (table limit key &rest body)
  "Value of BODY for KEY, memoized in TABLE, dropping TABLE past LIMIT entries.

`cooked--cached' for a cache whose key includes a dimension with no bound of
its own -- a run length, a window width -- where every value that dimension has
ever taken would otherwise be remembered for the life of the buffer.  Nothing
here is a size estimate or a proper LRU: once TABLE holds more than LIMIT
entries, it is emptied outright before the new one goes in, the same trade
`cooked--wrap-cache' already makes for the same reason -- see
`cooked-wrap-cache-limit'.  That is only sound when BODY is one of the cheap
tiers of a two-tier cache, i.e. when losing an entry costs recomputing it from
another, unbounded cache rather than redoing the expensive work from scratch;
callers pairing this with `cooked--cached' are relying on exactly that."
  (declare (indent 3) (debug (symbolp form form body)))
  `(progn
     (unless (hash-table-p ,table)
       (setq ,table (make-hash-table :test #'equal :size 64)))
     (or (gethash ,key ,table)
         (let ((cooked--cached-bounded-value (progn ,@body)))
           (when (> (hash-table-count ,table) ,limit)
             (clrhash ,table))
           (puthash ,key cooked--cached-bounded-value ,table)))))

(defmacro cooked--with-child-edit (&rest body)
  "Run BODY as an edit made on the child's behalf rather than by the user.

Two bindings, one reason each, and both follow from the same fact: the text
BODY touches belongs to the emulator, not to whoever is typing.

`inhibit-read-only', because the screen and the scrollback are protected
\(`cooked--protect') against a keystroke damaging a picture Emacs has no way to
repair -- and these edits are the writer that protection was never aimed at.

`buffer-undo-list', because a redraw deletes and reinserts whole rows on every
drain, and recording that is useless before it is harmful.  Undoing a row the
child painted would put back text the emulator's grid does not have, and every
later delta is computed against that grid, so nothing would ever mend the
disagreement.  Meanwhile a busy screen turns its whole text over several times a
second, and the list grows until Emacs warns that it has discarded megabytes --
which is the only sign a user ever gets that undo was recording the terminal.

What stays recorded is what the user typed at the prompt, the one piece of the
buffer that is theirs.  Run `cooked--check-undo-anchor' *after* the macro and
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
  "Send BYTES to the child, refusing if the session is over.

Every caller is a command the user invoked with a key — a submitted line, an
EOF, a job-control character, a key delegated to the child — so BYTES is
announced to the core as typing, and the frame that echoes it is drawn without
waiting out `cooked-min-redisplay-interval'.  Input sent on the user's behalf
rather than by them goes through `cooked--send-if-live', which says the
opposite."
  (cooked--send (cooked--require-session) bytes t))

(defun cooked--send-if-live (bytes)
  "Send BYTES if there is still a child, and do nothing if there is not.

For input the user did not type as such: a completion request, the interrupt
that abandons a secret prompt.  There the child having just exited is an
ordinary race rather than something the user asked for and should be told
about — and signalling from inside a process filter would abort the rest of the
redisplay.  A reply goes through `cooked--reply-if-live' instead.

Which is also why nothing here claims the keystroke exemption: these bytes have
no echo anybody is waiting on, and the frame they cause can wait its turn."
  (when-let* ((session (cooked--live-session)))
    (cooked--send session bytes)))

;;;; Replies

(defvar cooked--reply-batch nil
  "The replies owed during the events being handled, as (SESSION . REPLIES).

REPLIES is newest first.  Bound by `cooked--batching-replies' and nil
everywhere else, where a reply is queued the moment it is composed.")

(defmacro cooked--batching-replies (session &rest body)
  "Run BODY, then owe SESSION's child every reply BODY composed, as one string.

A palette sweep asks for 256 entries in one sequence and is answered once per
entry; queued one at a time, each would be its own write to the pty.  Held
here instead, they go out together, in the order they were composed.  The
replies are sent even if BODY signals, since the child is still waiting for
the ones composed before the error."
  (declare (indent 1) (debug t))
  (let ((batch (make-symbol "batch")))
    `(let* ((,batch (list ,session))
            (cooked--reply-batch ,batch))
       (unwind-protect
           (progn ,@body)
         (when-let* ((replies (cdr ,batch))
                     ((cooked--live-p (car ,batch))))
           (cooked--reply (car ,batch) (apply #'concat (nreverse replies))))))))

(defun cooked--queue-reply (session bytes)
  "Owe SESSION's child BYTES, a reply, without waiting for it to read them.

Replies are not keystrokes.  A child that has stopped reading -- a suspended
job, or a program hung in raw mode -- would otherwise stall Emacs on every
answer and every resize, so a reply joins a queue the core writes as the child
makes room, and one owed to a child that has not read in a long while is
dropped.  See `cooked--send' for input, which waits and then signals."
  (if (eq session (car cooked--reply-batch))
      (push bytes (cdr cooked--reply-batch))
    (cooked--reply session bytes)))

(defun cooked--reply-if-live (bytes)
  "Owe the child BYTES if there is still a child, and do nothing if not.

For what the terminal tells the child rather than what the user types: a
device-status reply resolved mid-drain, a focus report from a global hook, a
colour-scheme notification.  The child having just exited is an ordinary race
there, as it is for `cooked--send-if-live'."
  (when-let* ((session (cooked--live-session)))
    (cooked--queue-reply session bytes)))

(defun cooked--reply-osc (session code payload bell)
  "Answer an OSC query on SESSION with CODE and PAYLOAD, ended by BEL if BELL.

The reply is `ESC ] CODE ; PAYLOAD', framed by `cooked--osc-reply', which
refuses a PAYLOAD holding control characters that could close it early.  Pass
`cooked--osc-bell-terminated' as BELL, since a client that queried with BEL
will not recognise an ST-terminated answer."
  (cooked--queue-reply session (cooked--osc-reply code payload bell)))

(defvar cooked--redraw-hook nil
  "Run in a cooked buffer whose every row is about to be rendered again.

That is, from `cooked--forget-sent-rows' with REDRAW, whose callers all mean
that the same cells are about to be drawn differently.  A cache holding
something measured under the old drawing adds itself here to be emptied first,
since this file sits below the files that own those caches: the box-drawing
spec cache in cooked-deco.el holds an `:ascent' measured from a font the
layout stamp has just said is gone.")

(defun cooked--forget-sent-rows (&optional redraw)
  "Make the core send every live row again the next time it is damaged.

The core leaves a damaged row out of a drain when its cells match what it last
sent, which is right while the text Emacs holds for the row is still what that
drain rendered.  Anything that changes how the same cells are drawn breaks
that without touching a character.  An OSC 11 background set is one: the faces
on the rows were resolved against the old colours, and a full-screen program
that repaints its frame in reply expects to see it in the new ones.

With REDRAW the rows are damaged as well, so the next drain sends every one of
them whether the child repaints or not.  That is for a change a row has to be
rendered again to show at all, rather than one a repaint merely picks up: a
zoom leaves the glyph scaling on a row measured against the old font, and a
shell sitting at its prompt never repaints to replace it.  A theme change is
not one of those any more: a cell's colours are faces the theme moves under
it -- see `cooked--theme-changed' -- so the copy is cleared here without
REDRAW, and the rows come out in the new colours as they are.

The one way the copy is cleared, so that the theme, the layout stamp moving and
the options that change rendering all mean the same thing by it.  On
`cooked-theme-change-hook', which runs with each buffer current; from
`cooked--wrap-cache' when `cooked--layout-stamp' moves; and from
`cooked--set-rendering-option'."
  (when (user-ptrp cooked--session)
    (if redraw
        (progn
          (run-hooks 'cooked--redraw-hook)
          ;; Damaging every row forgets the copy too; see `Term::touch_all'.
          (cooked--redraw cooked--session))
      (cooked--row-unsent cooked--session nil))))

(declare-function cooked--drain-and-apply "cooked-render")

(defun cooked--set-rendering-option (symbol value)
  "Set SYMBOL to VALUE and redraw every live screen under it.

The `:set' behind the options that change how the same cells are drawn, such
as `cooked-box-drawing-images' and `cooked-glyph-scale-floor'.  Neither is
read anywhere but in rendering a row, so without this a screen already drawn
keeps the old answer: a border stays a bitmap after box drawing is turned off,
until the child happens to repaint it with different cells.

Drained here rather than left to the child, for the same reason
`cooked-refresh' drains: a customization is a request to see the result, and
an idle prompt would not show it until the next keystroke.  At load, when
`custom-declare-variable' calls this to set the default, there is no cooked
buffer to walk and nothing but the `set-default' happens."
  (set-default symbol value)
  (cooked--redraw-every-screen))

(defun cooked--redraw-every-screen ()
  "Render every live screen again now, in every cooked buffer.

For a change to how the same cells are drawn that has to show at once: see
`cooked--set-rendering-option' and `cooked--set-bold-is-bright'.  Each
buffer's rows are damaged and drained, rather than left for the child to
repaint, which it may never do."
  (cooked--dolist-buffers
    (when (user-ptrp cooked--session)
      (cooked--forget-sent-rows 'redraw)
      (cooked--drain-and-apply))))

(defconst cooked--source-directory
  (file-name-directory
   (file-truename (or load-file-name buffer-file-name default-directory)))
  "Directory holding this file, captured at load time.

Through `file-truename' on the file rather than on the directory, because the
package managers symlink the .el files individually into a build directory that
is itself a real directory -- so resolving the directory answers with the build
tree, and only resolving the file lands in the clone.  `cooked--root' needs the
clone: that is where Cargo.toml, terminfo/ and shell-integration/ are.")

(defun cooked--root ()
  "Top of the source tree: the directory holding Cargo.toml.

Found by walking up from `cooked--source-directory' rather than by taking its
parent, which matters for the package managers: `straight' and `elpaca' load
the Lisp from a build directory of symlinks into the clone, and its parent is
the build root -- which has no Cargo.toml, no terminfo/ and no
shell-integration/, and would send `cooked--load-module' off to build a crate
that is not there.  `cooked--source-directory' has already resolved the link,
so the walk starts inside the clone, where all three are.

Falls back to the parent directory, which is the answer for a plain
`load-path' checkout and the only thing left to guess if the tree has been
split up by an installer.  See `cooked-native-module' for pointing at a
prebuilt artifact instead."
  (let ((dir (file-name-as-directory cooked--source-directory)))
    (or (locate-dominating-file dir "Cargo.toml")
        (file-name-directory (directory-file-name dir)))))

(defun cooked--same-host-p (a b)
  "Whether host names A and B name the same machine, as far as anyone can tell.

Nil if either is nil, so an absent name never matches a present one.

Deliberately generous about spelling and about nothing else.  `HOST' from zsh
is usually short where `system-name' and a TRAMP prefix are fully qualified,
and the two spellings of one machine must not read as a move; but anything
beyond a shared first label is treated as a different machine, because both
callers would rather ask again than guess.  The generosity is one-sided in a
useful way -- it can only ever say `same' about two names sharing their first
label, never about two that do not."
  (and a b
       (let ((a (downcase a))
             (b (downcase b)))
         (or (equal a b)
             ;; Either side may carry the domain the other omits.
             (equal a (car (split-string b "\\.")))
             (equal (car (split-string a "\\.")) b)))))

(defun cooked--local-host-p (host)
  "Whether HOST, the authority of an OSC 7 URL, names this machine.

An empty authority does, being what a shell that has not bothered to name
itself sends, and so does `localhost'.  Otherwise the comparison with
`system-name' is `cooked--same-host-p': generous about spelling, since
`HOST' from zsh is usually short where `system-name' is fully qualified,
and ungenerous about everything else.  Anything not recognisably here is
elsewhere, because the cost of a false negative is a local file opened in
place of a remote one."
  (and host
       (or (member (downcase host) '("" "localhost" "localhost.localdomain"))
           (cooked--same-host-p host (system-name)))
       t))

(defun cooked--parse-file-url (url)
  "The (HOST . PATH) an OSC 7 `file://' URL names, both percent-decoded, or nil.

HOST is the empty string when the authority is empty.  The path is
percent-encoded on the wire because that is what a URL is: a directory called
`100%20cake' arrives as `100%2520cake', and decoding it once gives the name
back.  Nothing here looks at the file system; deciding what the path means is
the caller's, and has to come after `cooked--local-host-p' and
`cooked--local-name'.

The escapes are bytes of UTF-8, as every shell that sends one encodes them, so
they are decoded as UTF-8 after unescaping: `caf%C3%A9' is `café'.
`url-unhex-string' alone leaves the two bytes as two raw-byte characters, a
name that matches no directory.  A character sent unescaped is encoded first,
so the bytes decoded are the bytes the shell wrote."
  (when (and (stringp url)
             (string-match "\\`file://\\([^/]*\\)\\(/.*\\)\\'" url))
    (let ((host (match-string 1 url))
          (path (match-string 2 url)))
      ;; Both halves taken before either is unescaped, since
      ;; `url-unhex-string' matches and would replace the match data.
      (cl-flet ((unescape (part)
                  (decode-coding-string
                   (url-unhex-string (encode-coding-string part 'utf-8))
                   'utf-8)))
        (cons (unescape host) (unescape path))))))

(defun cooked--decode-base64 (data)
  "The bytes base64 DATA encodes, as a unibyte string, or nil if it is not base64.

The standard alphabet, since that is what `base64' and every shell snippet
emit: a clipboard write of `hello?>' arrives as `aGVsbG8/Pg==', and the URL
alphabet would refuse the `/' in it.  Missing padding is restored first,
because a sender that strips the trailing `=' is making a cosmetic choice
rather than sending something malformed.

Several payloads the child controls are base64 -- OSC 52, the user variables
of OSC 1337 and the shell's completion replies -- and each of them treats a
malformed one as the child's bug to be dropped quietly, which is the nil."
  (and (stringp data)
       (ignore-errors
         (base64-decode-string
          (concat data (make-string (% (- 4 (% (length data) 4)) 4) ?=))))))

(defun cooked--decode-base64-utf8 (data)
  "The text base64 DATA encodes as UTF-8, or nil if it is not base64.
See `cooked--decode-base64' for what is accepted."
  (when-let* ((bytes (cooked--decode-base64 data)))
    (decode-coding-string bytes 'utf-8)))

(defun cooked--local-name (name)
  "Return NAME, or nil having refused it for naming a remote file.

Every path cooked takes from the child is a string somebody else chose: an OSC 7
working directory, a file named over the command channel, a name parsed out of
output.  Under TRAMP such a string is not inert.  Visiting
\"/ssh:host:/etc/motd\" opens a connection to a host the sender picked and runs
that method's own transport program to get there, which is a command executed
on somebody else's say-so wearing the shape of a path.  \"/sudo::/etc/shadow\"
is the same move without leaving the machine.

The check has to come before anything that so much as looks at the file,
`file-exists-p' and `file-directory-p' included: those are the calls that
dispatch to the TRAMP handler, so asking whether the file is there is already
the connection this exists to refuse.

Here rather than in one of the layers because two of them need it and neither
can require the other -- `cooked-osc.el' for OSC 7, which is always on, and
`cooked-osc-eval.el' for the command channel, which is not.  That is what this
file is the floor for."
  (if (file-remote-p name)
      (progn (message "cooked: refused `%s' (a remote file name)" name) nil)
    name))

(defun cooked--same-file-p (a b)
  "Whether file names A and B name the same file, as its inode and device say.

Not `file-equal-p', which compares every attribute but the name, the times
included.  A directory's modification time moves whenever a file is made or
removed in it, so asking about a busy directory such as /tmp or a project
being built raced whatever was writing there: when a file was created in /tmp
between its two `stat' calls, `file-equal-p' said /tmp/ was not /tmp/.

Both names are resolved first, since `file-attributes' describes a symbolic
link rather than what it points at.  Nil if either does not exist."
  (when-let* ((one (file-attributes (file-truename a)))
              (other (file-attributes (file-truename b))))
    (and (equal (file-attribute-inode-number one)
                (file-attribute-inode-number other))
         (equal (file-attribute-device-number one)
                (file-attribute-device-number other)))))

;;;; Windows, and waiting until redisplay is over

(defun cooked--layout-window ()
  "The window this buffer's rows are laid out for, or nil if it has none.

The narrowest window showing the buffer, on any frame: the one
`cooked--window-size' hands the child, since a child sized to a larger window
would wrap and clip everything shown in the smaller one.  That makes it the
layout every rendered row is written for, and so the only window a row is
worth measuring against.

There is deliberately no `selected-window' fallback.  Everything that measures
this buffer's text defaults to the selected window -- `vertical-motion' and
`window-font-width' both do -- and the selected window is very often not one
of ours: the minibuffer while a completion session previews this buffer in
another window, or a neighbouring window while the frame is being resized.
Measuring a row against a window that shows someone else's buffer at someone
else's width is not a weaker measurement, it is a meaningless one, and
`cooked--guard-row-width' acts on the answer by deleting text.

The incumbent's width is carried rather than re-measured.  Asking it again per
candidate made the walk measure the same window once for every window after it,
and `window-max-chars-per-line' is not a cheap accessor: it selects the window
to do its measuring in.

Nothing is measured at all until there is a second window to compare against,
which is the ordinary case and stays free."
  (let (narrowest width)
    (dolist (window (get-buffer-window-list (current-buffer) nil t) narrowest)
      (cond ((null narrowest) (setq narrowest window))
            (t (unless width (setq width (window-max-chars-per-line narrowest)))
               (let ((chars (window-max-chars-per-line window)))
                 (when (< chars width)
                   (setq narrowest window width chars))))))))

(defconst cooked--default-font-probe (propertize " " 'face 'default)
  "The text `cooked--default-font' asks `font-at' about.
A constant, so that asking allocates nothing.")

(defun cooked--default-font (window)
  "The font this buffer's default face is drawn in on WINDOW, or nil.

The font a row is laid out against, which is not the frame's: after
`text-scale-increase' in a 15-pixel font, `face-attribute' on the frame
still answers the 15-pixel font while the buffer is drawn in a 26-pixel one.
`font-at' on a space in the default face answers as the display engine would,
through this buffer's `face-remapping-alist', so it has to be asked with the
buffer current.  That is the probe ghostel makes, for the same reason.

WINDOW nil means the selected window, as it does for `font-at' itself; only
the frame is taken from it, since the remapping is the buffer's.  Nil on a
terminal frame, which has no fonts to ask about."
  (let ((window (or window (selected-window))))
    (and (display-graphic-p (window-frame window))
         (font-at 0 window cooked--default-font-probe))))

(defun cooked--defer (function)
  "Call FUNCTION with no arguments, later, in the current buffer if it lives.

The window hooks run during redisplay, and a drain is not a redisplay-safe
thing to do from one: it inserts text, swaps the local map, recenters windows
and runs `cooked-state-change-hook', which is arbitrary user code."
  (let ((buffer (current-buffer)))
    (run-at-time 0 nil
                 (lambda ()
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer (funcall function)))))))

;;;; Giving up the region
;;
;; One function, and it is here rather than beside either of its callers because
;; it has two: the drain clears a selection the child has overwritten
;; (`cooked--capture-viewport', in cooked-render.el) and a mouse report clears
;; one because the click belonged to the child (`cooked--send-mouse', in
;; cooked-mouse.el).  Both files sit above this one and neither requires the
;; other, so the shared answer belongs below both -- which is also the whole of
;; why it did not travel with the pipeline it was extracted from.

;; Read and called only behind a guard that evil is loaded and on, and named
;; here so the byte-compiler reads them as the deliberate references they are;
;; see `cooked--deactivate-mark' and, for the same arrangement, `cooked--discard-undo'.
(declare-function evil-visual-state-p "ext:evil-states")
(declare-function evil-exit-visual-state "ext:evil-states")

(defun cooked--deactivate-mark ()
  "Give up the region, taking evil's visual state with it.

`deactivate-mark' on its own is only half of that under evil, and which half
depends on where it was called from.  What keeps evil in step is
`evil-visual-deactivate-hook', which decides from `this-command': from a
command there is one to decide with -- a mouse report is sent under
`cooked-mouse-event', which carries no `:keep-visual' property, so evil exits
visual state and the two agree.  From a drain there is not.  A process filter
runs between commands, `this-command' is whatever the user last ran or nothing
at all, and the hook falls through both of its arms: the mark goes, evil stays
in visual state, and the next \\`v' *leaves* visual state rather than entering
it -- the failure `cooked-evil--command-range' documents at length, arrived at
from the other side.

So ask evil outright instead of through a hook whose answer depends on how we
got here.  `evil-exit-visual-state' deactivates the mark itself on its way
back to the state visual state was entered from, and does it the same way
whether or not a command is running.

Silent when there is no region: every caller is somewhere the region is
incidental, so having none is the ordinary case rather than a failure."
  (cond ((and (bound-and-true-p evil-local-mode)
              (fboundp 'evil-visual-state-p)
              (evil-visual-state-p))
         (evil-exit-visual-state))
        (mark-active (deactivate-mark))))

(provide 'cooked-util)
;;; cooked-util.el ends here
