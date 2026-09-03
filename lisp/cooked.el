;;; cooked.el --- A terminal that hands the keyboard back -*- lexical-binding: t; -*-

;; Author: Simon Gomizelj <simongmzlj@gmail.com>
;; Version: 1.0.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: terminals, processes
;; URL: https://github.com/vodik/cooked

;;; Commentary:

;; A terminal emulator whose input model follows what the child actually wants.
;; The kernel's line discipline says when a program is doing a canonical read;
;; OSC 133 says when the shell is at a prompt.  In either case Emacs owns the
;; line and you edit it as you would any buffer.  Otherwise keys are forwarded
;; verbatim and the emulator behaves as a terminal.
;;
;;   (use-package cooked
;;     :load-path "/path/to/cooked/lisp"
;;     :commands (cooked cooked-other-window
;;                cooked-project cooked-project-other-window
;;                cooked-here cooked-here-other-window)
;;     :custom (cooked-buffer-name "*cooked: %s*")
;;     :config
;;     (require 'cooked-evil)             ; opt in to evil state syncing
;;     (require 'cooked-osc-eval)         ; opt in to the OSC 51 command channel
;;     (require 'cooked-shell-completion) ; opt in to the shell's own completion
;;     (require 'cooked-project))         ; opt in to project-scoped sessions
;;
;; Emulation happens in a Rust module, built on first use with cargo.
;;
;; This file is the core: rendering, colours, and the OSC handlers that are inert
;; enough to be on by default.  `cooked-mode' has the interaction; `cooked-evil',
;; `cooked-osc-eval', `cooked-shell-completion' and `cooked-project' are separate
;; because you should
;; choose them.

;; The buffer is the scrollback.  Rows that scroll off the emulator's screen are
;; handed over once and become ordinary buffer text; the lines after
;; `cooked--screen-start' are the live screen, rewritten from damage reports.
;;
;; Invariant: buffer text equals the grid, plus any pending input rendered at the
;; cursor.  Every redisplay lifts the pending input out, applies the grid, and puts
;; it back.
;;
;; The two ends therefore hold one structure between them, and the boundary is the
;; only place they can disagree.  So the geometry of it is reported rather than
;; re-derived: `cooked--grid' carries the emulator's own account of how tall the
;; grid is, how much of it is occupied, and how much of the line straddling the
;; boundary has already been handed over.  Emacs owns the buffer and makes every
;; edit; it just does not get a second opinion about the shape it is editing to.
;; `cooked--check-seam' is that boundary stated as an assertion.

;;; Code:

(require 'cl-lib)
(require 'face-remap)
(require 'cooked-util)
(require 'cooked-command)
(require 'cooked-face)
(require 'cooked-deco)
(require 'cooked-link)

;; `cooked-osc.el' requires this file, so what this file needs of it is declared
;; rather than required -- the same shape, and for the same reason, as the calls
;; upward into cooked-mode.el listed below.  Both are notifications: something
;; happened, and the layer that owns the meaning should react.
(declare-function cooked--spawn "cooked-core")
(declare-function cooked--drain "cooked-core")
(declare-function cooked--send "cooked-core")
(declare-function cooked--reply-osc "cooked-core")
(declare-function cooked--resize "cooked-core")
(declare-function cooked--forget-history "cooked-core")
(declare-function cooked--redraw "cooked-core")
(declare-function cooked--prompt-text "cooked-core")
(declare-function cooked--core-version "cooked-core")
(declare-function cooked--clear-to-prompt "cooked-core")
(declare-function cooked--signal "cooked-core")
(declare-function cooked--pid "cooked-core")
(declare-function cooked--bracketed-paste-p "cooked-core")
(declare-function cooked--live-p "cooked-core")
(declare-function cooked--sample-mode "cooked-core")
(declare-function cooked--set-attended "cooked-core")
(declare-function cooked--kill "cooked-core")

(declare-function cooked--handle-osc "cooked-osc")
(declare-function cooked--handle-title-stack "cooked-osc")

;;;; What the two ends exchange
;;
;; The native core reports its cursor as a four-element list and its geometry as
;; three keys of the drain's plist, both of which are the cheapest thing to build
;; across the module boundary.  Neither is a good thing to *read*: `(nth 3
;; cooked--cursor)' says nothing about what it holds, and a positional decode
;; repeated at twenty call sites is twenty chances to count wrong.  So the shapes
;; are decoded once, at the boundary in `cooked--apply', and everything above it
;; works in terms the reader can check.

(cl-defstruct (cooked-cursor (:constructor cooked--cursor-make) (:copier nil))
  "The child's cursor: where it is, and what it should look like."
  (row 0 :documentation "Screen row, zero-based.")
  (col 0 :documentation "Screen column, zero-based.")
  (visible t :documentation "Whether the child has asked for it to be shown.")
  (shape 'block :documentation "`block', `underline' or `bar', from DECSCUSR."))

(defun cooked--cursor-decode (spec)
  "Decode SPEC, the (ROW COL VISIBLE SHAPE) list the native core reports."
  (pcase-let ((`(,row ,col ,visible ,shape) spec))
    (cooked--cursor-make :row (or row 0) :col (or col 0)
                         :visible visible :shape (or shape 'block))))

(defun cooked--cursor-cell ()
  "The child's cursor as a (ROW . COL) screen cell."
  (cons (cooked-cursor-row cooked--cursor) (cooked-cursor-col cooked--cursor)))

(cl-defstruct (cooked-grid (:constructor cooked--grid-make) (:copier nil))
  "The emulator's own account of its grid, as of the last drain.

`cooked--rows' and `cooked--cols' are what Emacs *asked* the child for, which is
a different thing and can differ for as long as it takes a resize to land.  This
is what the grid actually is, so the buffer is shaped by the emulator rather
than by a second opinion of it."
  (height 24 :documentation "Rows the grid has.")
  (used 1 :documentation "Rows of it that are occupied — see `cooked--fit-screen'.")
  (head 0 :documentation "\
Characters of screen row 0's logical line that are already in the buffer, above
`cooked--screen-start'.  Non-zero exactly when the last row handed to scrollback
was wrapped and row 0 continues it, which is why the marker then sits mid-line.
See `cooked--check-seam'."))

(defvar-local cooked--wake nil "Pipe process Rust pokes when output is pending.")
(defvar-local cooked--rows 24
  "Rows Emacs last asked the child for.
The grid's own height is in `cooked--grid'.")
(defvar-local cooked--cols 80
  "Columns Emacs last asked the child for.  Not a measurement of the grid.")
(defvar-local cooked--screen-start nil
  "Marker at the first line of the live screen; everything before is scrollback.")

(defun cooked--screen-start-position ()
  "Where the live screen begins, or nil before a session has started one.

The marker is nil until `cooked--start\=' makes it and can outlive its buffer
text, so both have to be checked; doing that here keeps the check from being the
loudest thing at every call site."
  (and cooked--screen-start (marker-position cooked--screen-start)))

(defvar-local cooked--grid (cooked--grid-make)
  "The grid as the emulator last described it, a `cooked-grid'.")
(defvar-local cooked--cursor (cooked--cursor-make)
  "The child's cursor as of the last drain, a `cooked-cursor'.")
(defvar-local cooked--alt nil)
(defvar-local cooked--pin-screen-top nil
  "Non-nil while the live screen belongs at the top of the window.

Set when the child clears the display, and held until the screen scrolls again
-- which is when the grid has filled the window, and pinning its top is the same
view as following its bottom.  A single drain would not be enough: the cleared
screen holds one row, so the very next drain's ordinary recentring would put
that row at the foot of the window and pull the transcript straight back into
view, undoing the clear a keystroke later.")
(defvar-local cooked--input-mode nil
  "How this buffer is treating the keyboard and the render right now.

One of:

  nil      Forward everything the policy's map forwards, render live, follow
           the child's cursor.  The ordinary case, and the only one a
           non-`evil' user reaches without asking.
  `semi'   Forward, but hold back the keys that change what Emacs is doing --
           see `cooked-semi-map'.  Render live, follow the cursor.
  `still'  Forward nothing; the buffer is read-only and ordinary Emacs
           commands reach it.  The render stays live, but nothing moves the
           view: the child keeps drawing under a point that stays where the
           user put it.
  `frozen' As `still', and the render is deferred as well, so the picture
           being navigated cannot change at all.

These are three independent questions -- does a key forward, does the buffer
render, does the view follow -- and one flag cannot answer all three: collapse
them and stepping out to `evil' normal state stops the terminal dead.  See
`cooked--suspended-p', `cooked--frozen-p' and `cooked--follow-p', which are
what the rest of the code asks.

The mode is computed for a prompt too, and there the first question has no
content: Emacs owns the line, so the keyboard half of `still' and `frozen'
simply does not apply and only their claims about the render survive.  A child
can repaint a canonical tty for minutes on end -- `brew upgrade' does -- and
the view being held still while that happens is the whole point of the two
states.  `cooked--suspended-p' is where that exception lives, and it is the
only place it lives.")

(defvar-local cooked--peek-explicit nil
  "Whether `cooked-toggle-peek' was used to step out deliberately.
Kept apart from `cooked--input-mode' because the mode is recomputed from
scratch on every state change: a deliberate peek has to survive a `raw'<->`alt'
transition, and nothing else about the mode does.")

(defvar-local cooked--read-only nil
  "Whether the `buffer-read-only' in force is ours, from a suspended state.

Kept for the same reason `cooked--narrowed' is: a refresh that finds the buffer
no longer suspended should undo its own protection and nothing else.  Without
it, a `read-only-mode' the user turned on themselves was cleared by the next
state change that happened along.")

(defun cooked--suspended-p ()
  "Whether keys are being kept from the child rather than forwarded.

Both halves: the mode says to withhold, and there is a child holding the
keyboard to withhold from.  At a prompt there is not.  Emacs owns the line
outright, so nothing is being forwarded for a mode to suspend -- and the two
things this predicate gates besides the keymap, `buffer-read-only\=' and
`cooked-peek-map\=', would each break the line being edited rather than protect
it: one refuses the user\='s own typing outright, the other remaps
`self-insert-command\=' to raw bytes that go past cooked\='s line editor entirely.

So this stays the narrow question of who the keyboard belongs to.  The two that
generalise past it -- does the render run, does the view follow -- ask
`cooked--input-mode\=' directly; see `cooked--frozen-p\=' and `cooked--follow-p\='."
  (and (memq cooked--input-mode '(still frozen))
       (cooked--child-owns-keyboard-p)))

(defvar-local cooked--attention nil
  "Whether the user is looking at this buffer: nil, `here' or `away'.

nil until it has been on screen at all.  A buffer that has never been
displayed has no attention to lose -- one driven from Lisp, or a test -- and
counting it as abandoned would freeze nothing and thaw everything.

Maintained by `cooked--update-attention' from the window hooks rather than
computed on demand, because the interesting case cannot be seen from the
buffer afterwards: once another buffer takes over its window, a cooked buffer
is displayed nowhere, which is indistinguishable from never having been shown
except by having watched it happen.")

(defun cooked--frozen-p ()
  "Whether the render is being deferred.

Only while this buffer is the one under the user's eyes.  Freezing exists to
keep a picture still while it is being read; a buffer the user has left is not
being read, and a terminal that stopped updating because its window lost
selection is the complaint this whole distinction exists to answer.  The child
never stopped running either way -- the freeze only ever deferred the drain."
  (and (eq cooked--input-mode 'frozen)
       (not (eq cooked--attention 'away))))

(defun cooked--follow-p ()
  "Whether point and the window should track the child's cursor.

The mode alone, deliberately, and not `cooked--suspended-p\=': whether keys are
being withheld is a question about the child\='s keyboard, and a child that never
took the keyboard can still be repainting.  `brew upgrade\=' draws its progress
bars over a tty that stays canonical throughout, which leaves the policy at
`cooked\=' -- so gating the freeze on forwarding made `still\=' and `frozen\='
structurally unreachable in exactly the case a held view is worth most.

Point inside the pending input is the one thing this does not speak for; see
the `editing\=' binding in `cooked--apply\='."
  (not (memq cooked--input-mode '(still frozen))))

(defvar-local cooked--narrowed nil
  "Whether the restriction in force is ours, from `cooked--apply-alt-pin'.")
(defvar-local cooked--app-cursor nil
  "DECCKM: send cursor keys as SS3, which is what `smkx' asks for.")
(defvar-local cooked--keys 'legacy
  "How to spell modified Return, Tab, Escape and Backspace for this child.

One of `legacy', `modify-other' or `kitty', as negotiated by the child itself —
see `cooked--literal-codes' for why this cannot simply be assumed.")
(defvar-local cooked--title nil "Title the child last set, via OSC 0 or 2.")
(defvar-local cooked--title-stack nil
  "Titles saved by XTWINOPS 22, newest first.  See `cooked--handle-title-stack'.")
(defvar-local cooked--host nil
  "Host the child last reported over OSC 7, or nil for this machine.

The authority half of `file://HOST/PATH\=', which cooked used to match and throw
away.  Keeping it is what stops every path-shaped thing in the buffer being
answered locally: after an `ssh\=', the remote shell goes on reporting its
directory faithfully and the names it sends are real -- on the other host.  A
local `/home/you/src/thing\=' that happens to exist here is the failure case,
and it is the common one, because the layouts people ssh between are the ones
they keep in step.

Set by `cooked--set-directory\=' and read through `cooked--foreign-host-p\=';
see it for what declines and why.")
(defvar-local cooked--mode 'cooked)
(defvar-local cooked--exit nil)

;; Everything this file calls in cooked-mode.el, which is to say everything it
;; calls upward.  Each one is a notification that something changed and the layer
;; that owns keymaps, buffer names or the buffer's own life should react — never a
;; question asked of that layer, which is why the list is short and stays short.
;; Anything cooked.el needs an *answer* to belongs at this level instead; see
;; "Who owns the keyboard" below, which is where that rule moved the policy.
(declare-function cooked--refresh-keymap "cooked-mode")
(declare-function cooked--update-mouse-grab "cooked-mouse")
(declare-function cooked--set-mouse-state "cooked-mouse")
(declare-function cooked--set-mode "cooked-mode")
(declare-function cooked--on-exit "cooked-mode")
(declare-function cooked--defer "cooked-mode")
(declare-function cooked--rename-to-title "cooked-mode")
(defvar cooked-rejoin-wrapped-lines)
(declare-function cooked--kill "cooked-core")

(defun cooked--foreign-host-p ()
  "Whether the child last said it was somewhere other than this machine.

Nil until a shell says otherwise, which is the right default twice over: a
child that never sends OSC 7 is overwhelmingly a local one, and a hostile
stream cannot reach *more* of the buffer by staying quiet.

The comparison is deliberately generous about spelling -- `HOST\=' from zsh is
usually short where `system-name\=' is fully qualified, and the two naming the
same machine must not read as a move.  It is deliberately ungenerous about
everything else: anything that is not recognisably here is treated as
elsewhere, because the cost of a false negative is a local file opened in place
of a remote one, and the cost of a false positive is a completion table that
declines to guess."
  (and cooked--host
       (let ((host (downcase cooked--host))
             (self (downcase (system-name))))
         (not (or (member host '("" "localhost" "localhost.localdomain"))
                  (equal host self)
                  ;; Either side may carry the domain the other omits.
                  (equal host (car (split-string self "\\.")))
                  (equal (car (split-string host "\\.")) self))))))




(defcustom cooked-term-name "cooked-256color"
  "Value of TERM for the child, or nil to present as xterm-256color.

Shipping an entry is the honest option — it declares direct colour, which
xterm-256color does not, and withholds the capabilities we ignore — and it is
what alacritty, wezterm, foot and Emacs' own `term.el' all do.  The cost is
remote hosts that have never heard of it; see `cooked-install-terminfo-remote'.
The entry is installed under ~/.terminfo, needing no root, and we fall back to
xterm-256color if that is not possible."
  :type '(choice (const :tag "Present as xterm-256color" nil) string)
  :group 'cooked)

(defun cooked--terminfo-known-p (name)
  "Whether terminfo can describe NAME."
  (and name (eq 0 (call-process "infocmp" nil nil nil name))))

(defun cooked--terminfo ()
  "TERM to hand the child, installing our entry on first use."
  (let ((source (expand-file-name "terminfo/cooked.ti" (cooked--root))))
    (cond
     ((null cooked-term-name) "xterm-256color")
     ((cooked--terminfo-known-p cooked-term-name) cooked-term-name)
     ((and (executable-find "tic")
           (file-exists-p source)
           (eq 0 (call-process "tic" nil nil nil "-x" "-o"
                               (expand-file-name "~/.terminfo") source)))
      cooked-term-name)
     (t
      (message "cooked: could not install terminfo, presenting as xterm-256color")
      "xterm-256color"))))

(defun cooked--terminfo-directory (name)
  "Our own terminfo database, if the compiled entry for NAME is in it.

~/.terminfo is where `cooked--terminfo\=' installs the entry, and ncurses looks
there by default -- so this exists for the cases where the default is wrong.
Anything that changes HOME loses the entry silently: `sudo\=', `su -\=', a
service manager, a container that mounts a different home.  ncurses also skips
~/.terminfo outright for a privileged program.  Naming the directory is what
survives all of that.

The entry is looked for rather than assumed, and by wildcard rather than by
path: implementations disagree about whether the subdirectory is the first
letter of the name or its hex code, and a TERMINFO pointing at a database that
does not describe TERM is worse than not setting it -- it is the one variable
that can make a lookup fail which would otherwise have succeeded."
  (let ((database (expand-file-name "~/.terminfo")))
    (and name
         (file-directory-p database)
         (file-expand-wildcards (expand-file-name (concat "*/" name) database))
         database)))

(defun cooked--terminfo-search-path (database)
  "TERMINFO_DIRS naming DATABASE ahead of wherever the child would look anyway.

TERMINFO_DIRS rather than TERMINFO, and that is the whole of why this is a
function.  TERMINFO is not an override -- ncurses searches it *first* and falls
through on a miss, so a database of ours in that slot would answer for our entry
and step aside for everything else, which is what makes setting it safe.  But it
is also the variable a user may have set for their own database, and TERMINFO
holds exactly one directory: taking it would mean choosing between their entries
and ours.  TERMINFO_DIRS is a list and exists for precisely this, so there is
nothing to choose between.

The trailing empty entry is not a stray separator.  ncurses reads an empty
directory name as the compiled-in default, so this says \"ours, then whatever
you already had, then the system\" -- and dropping it would say \"ours, and
nothing else\" on an implementation stricter than the one this was written
against.

An inherited entry naming DATABASE itself is dropped rather than kept behind
ours.  ~/.terminfo is where ncurses looks by default, so having it on the
search path explicitly is a reasonable thing to have done, and a user who did
lands here with it already at the front -- which produced
`~/.terminfo:~/.terminfo:\=', a path that is not wrong so much as it is us not
reading what was already there.
Empty entries are never dropped: an empty name is the compiled-in default, not a
directory that could be a duplicate of anything."
  (let ((kept (cl-remove-if (lambda (dir)
                              (and (not (string-empty-p dir))
                                   (equal (expand-file-name dir) database)))
                            (split-string (or (getenv "TERMINFO_DIRS") "") ":"))))
    (concat database ":" (string-join kept ":"))))

(defun cooked-version ()
  "Version of cooked, as `Cargo.toml\=' declares it.

Read from the native core rather than kept here, so there is one place to
change it and no second copy to drift.  The Version header at the top of this
file is packaging metadata for `package.el\=' and is not consulted; keep it in
step by hand, as a package must.

Requires the core, which is loaded by then wherever this is called from --
`cooked--start\=' loads it before building the child environment."
  (cooked--load-module)
  (cooked--core-version))

;;;###autoload
(defun cooked-install-terminfo-remote (host)
  "Copy our terminfo entry to HOST so remote programs recognise TERM."
  (interactive "sHost: ")
  (unless (cooked--terminfo-known-p cooked-term-name)
    (cooked--terminfo))
  (let ((command (format "infocmp -x %s | ssh %s 'mkdir -p ~/.terminfo && tic -x -o ~/.terminfo -'"
                         (shell-quote-argument cooked-term-name)
                         (shell-quote-argument host))))
    (if (eq 0 (call-process-shell-command command))
        (message "cooked: installed %s on %s" cooked-term-name host)
      (user-error "cooked: failed to install terminfo on %s" host))))

(defcustom cooked-native-module nil
  "Path to the built native core, or nil to look under the source tree.
An escape hatch for installations where the compiled module does not sit beside
the Lisp — a system package, or a build directory somewhere else."
  :type '(choice (const :tag "Find it in the source tree" nil) file)
  :group 'cooked)

(defun cooked--module-stale-p (built root)
  "Whether BUILT is older than the Rust sources under ROOT that produced it.

Existence is not enough to go on.  The Lisp and the native core are two halves
of one protocol -- the drain's plist keys, the `BoxGlyph' bit layout, the set of
defuns `cooked-core' provides -- so a pull that touches src/ and lisp/ together
leaves a stale .so answering new Lisp.  What surfaces then is a void-function
or a nil where a row should be, several layers from the cause.

Only consulted when cooked owns the build.  `cooked-native-module' points at an
artifact somebody else is responsible for -- a system package, a build
directory elsewhere -- and there is no reason to expect our source tree to sit
beside it, let alone to rebuild over the top of it."
  (when-let* ((built-at (file-attribute-modification-time (file-attributes built))))
    (seq-find (lambda (source)
                (time-less-p built-at
                             (file-attribute-modification-time (file-attributes source))))
              (cons (expand-file-name "Cargo.toml" root)
                    (directory-files-recursively
                     (expand-file-name "src" root) (rx ".rs" eos))))))

(defvar cooked--core-loaded nil
  "(FILE . MTIME) of the native core this session loaded, or nil.

Emacs cannot unload a dynamic module, so a session is married to the core it
mapped for as long as it lives.  Recording which file that was, and when it was
built, is what lets `cooked--load-module\=' notice the artifact being rebuilt
underneath it -- see `cooked--check-core-drift\=' for why that is worth saying
out loud rather than letting it surface as something else entirely.")

(defun cooked--build-module (root built)
  "Build the native core under ROOT and install it at BUILT.

Installed by rename, never by letting cargo write BUILT directly, and that is
the whole reason this is a function rather than the `call-process\=' that used to
sit inline in `cooked--load-module\='.

rustc writes its output in place -- same inode, new contents -- and cargo
hardlinks the uplifted copy to the one under `deps/\='.  So a rebuild rewrites
the very bytes every *other* Emacs has mapped, and the kernel answers their next
page fault with SIGBUS.  Emacs\=' fatal-signal handler exits without dumping
core, so what those users see is the editor vanishing with nothing in
`coredumpctl\=' and nothing in the journal to say why.  This is the path that
matters, because it is the automatic one: it fires from `\\[cooked]\=' with
nobody having asked for a build.

So cargo is pointed at its own directory and the result is copied to a staging
name and renamed over BUILT.  A rename swaps which inode the name points at and
leaves the old one alive for whoever still has it mapped, so an Emacs running
the previous core goes on running against it -- `/proc/PID/maps\=' shows it as
`(deleted)\=' -- instead of being killed.  The staging copy is made in BUILT\='s
own directory so the rename cannot degrade into a cross-filesystem copy and
stop being atomic.  `elisp-tree-sitter\=' installs its own core this way, for
this reason.

Copied rather than moved.  Leaving cargo\='s artifact where cargo put it is what
keeps its fingerprint tracking honest, so the next build relinks only when
something changed.  `make module\=' does exactly this, and the two have to agree:
fixing one and leaving the other is how a bug like this survives being found."
  (let* ((default-directory root)
         ;; The Makefile spells this `?=', and this is the same bargain: an outer
         ;; CARGO_TARGET_DIR still wins, so a CI cache or a scratch build kept
         ;; deliberately away from the tree goes on working, and `target/cargo'
         ;; is the default both halves share.  Passed as an argument rather than
         ;; left to the environment because we have to know where to find what
         ;; cargo produced, and an argument cannot be overridden behind our back.
         (target (expand-file-name (or (getenv "CARGO_TARGET_DIR") "target/cargo")
                                   root))
         (out (expand-file-name (concat "release/libcooked" module-file-suffix)
                                target))
         (staging (concat built ".new")))
    (message "cooked: building native core...")
    (unless (zerop (call-process "cargo" nil "*cooked-build*" nil "build"
                                 "--release" "--target-dir" target))
      (pop-to-buffer "*cooked-build*")
      (error "cooked: cargo build failed"))
    ;; A cargo that exits 0 having produced nothing is not something to paper
    ;; over with a `module-load' of whatever stale file happens to be there.
    (unless (file-exists-p out)
      (error "cooked: cargo built no %s" (file-name-nondirectory out)))
    (make-directory (file-name-directory built) t)
    (copy-file out staging t)
    (rename-file staging built t)))

(defun cooked--check-core-drift (built)
  "Say so if BUILT was rebuilt after this session loaded it.

Installing by rename is what leaves a running session on the core it already
mapped, and that is exactly what stops it crashing -- but it also means the
session goes on answering with the old protocol while the Lisp beside it may
have been reloaded from a newer tree.  What surfaces then is a void-function
for a defun the new core provides, several layers away from the cause;
`cooked--sample-mode\=' arriving in a checkout whose loaded core predated it is
precisely what that looked like.

A message rather than an error, because there is nothing to be done about it
from here.  Emacs cannot unload a module, so the only cure is a restart, and
refusing to open a terminal would be a worse answer than opening one that
works.

Deliberately not a version comparison.  `cooked--core-version\=' exists and is
the obvious thing to reach for, but a version moves on a release while the
protocol moves whenever a defun is added -- so the drift that actually bites
happens with both halves reporting the same 1.0.0, and a check keyed on that
would have stayed silent through every instance of it.  What changed is the
file, so the file is what gets asked."
  (when-let* ((loaded cooked--core-loaded)
              ((equal (car loaded) built))
              (built-at (file-attribute-modification-time (file-attributes built)))
              ((time-less-p (cdr loaded) built-at)))
    (message "cooked: the native core was rebuilt after this session loaded it%s"
             " -- restart Emacs if anything looks wrong")))

(defun cooked--load-module ()
  "Load the native core, building it if necessary."
  (unless module-file-suffix
    (error "cooked: this Emacs was built without dynamic module support"))
  (let* ((root (cooked--root))
         (ours (null cooked-native-module))
         ;; Not a hardcoded \".so\": cargo names a cdylib \"libcooked.dylib\" on macOS,
         ;; which is exactly what `module-file-suffix' reports there.
         (built (or cooked-native-module
                    (expand-file-name (concat "target/release/libcooked" module-file-suffix)
                                      root))))
    (if (featurep 'cooked-core)
        (cooked--check-core-drift built)
      (when (or (not (file-exists-p built))
                (and ours (cooked--module-stale-p built root)))
        (cooked--build-module root built))
      (module-load built)
      (setq cooked--core-loaded
            (cons built (file-attribute-modification-time
                         (file-attributes built)))))))


;;;; Putting styled text in the buffer

(defun cooked--render-block (block &optional row)
  "Insert BLOCK at point, with its styling and decoration applied.

BLOCK is (TEXT STYLE-SPANS DECO-SPANS LINK-SPANS), the one shape rendered text
crosses the module boundary in -- see `cooked--drain\='.  TEXT is the whole run
of characters, and every span carries offsets in characters into it; spans
appear only where there is something to say, so a plain unstyled row carries no
list at all.

A STYLE-SPAN is (START END FG BG ATTRS UNDERLINE) and is the only one naming a
rendition.  A DECO-SPAN is (START DECO), what its characters display instead of
themselves, and a LINK-SPAN (START END ID) for an `OSC 8\=' hyperlink.  Neither
of the last two repeats the colours, because neither is drawn in colours of its
own: a box glyph takes them from the face at the position it sits on, which the
style span has just put there over exactly the same characters.  Links are
applied last, over the decorations, so they can see which cells turned out to
be an image and leave those alone.

One insert plus properties, rather than an insert per run: Emacs pays for every
`insert\=', and building a propertized string in Lisp and inserting that instead
measures three times slower, because `concat\=' on propertized strings makes
Emacs copy and merge property intervals over and over.

Colour rides on `face\=' alone.  `cooked-mode\=' clears `font-lock-defaults\=',
which comint leaves at (nil t) -- under that setting any fontification of the
buffer unfontifies it first and strips a bare `face\='.

ROW is the screen row BLOCK makes up, where the caller knows it: the live screen
does, scrollback does not.  It also stands in for the origin a shade glyph\='s
dither is phased against.  Scrollback passes neither and loses at most a seam on
that one glyph kind.

Returns the position the text was inserted at."
  (pcase-let ((`(,text ,styles ,decos ,links) block))
    (let ((start (point)))
      (insert text)
      (dolist (span styles)
        (pcase-let ((`(,from ,to ,fg ,bg ,attrs ,ul) span))
          (when-let* ((face (cooked--face fg bg attrs ul)))
            (put-text-property (+ start from) (+ start to) 'face face))))
      (dolist (span decos)
        (pcase-let ((`(,from ,deco) span))
          (cooked--apply-deco (+ start from) deco (and row start) row)))
      (when links
        (cooked--render-link-spans start links))
      start)))

;;;; Who owns the keyboard
;;
;; The question the whole package turns on, and the reason this is here rather than
;; in cooked-mode.el with the keymaps it selects: rendering has to ask it.  Applying
;; a drain means lifting the pending input out of the buffer, rewriting the screen
;; underneath it and putting it back — which is a question about ownership, asked
;; from inside the process filter, long before any key is pressed.
;;
;; So the state and the policy derived from it live at this level, and the layer
;; above binds keys to them.  What cooked.el still calls upward is only ever a
;; notification that something changed; `cooked--refresh-keymap' is the one that
;; matters, and it is the seam `cooked-state-change-hook' hangs off.

(defvar-local cooked--input-end nil
  "Marker after the pending input.

The far edge only.  The near edge is the buffer's process mark -- see
`cooked--input-mark' -- and this is the half comint has no counterpart for:
comint's input runs to `point-max', while cooked's has rendered screen rows
below it.")
(defvar-local cooked--undo-anchor nil
  "Where the pending input began when the undo history was last known good.
See `cooked--check-undo-anchor'.")
(defvar-local cooked--semantic nil
  "OSC 133 state: nil, `prompt', `input' or `output'.")
(defvar-local cooked--semantic-seen nil
  "Whether any OSC 133 mark has arrived in this session.

Latched, because `cooked--semantic' goes back to nil between `command-end' and
the next `prompt-start' and so cannot answer \"is the integration working?\".
Once a shell has spoken at all, it will keep speaking, and everything it does
not say becomes informative -- see `cooked--policy'.")
(defvar-local cooked--delegated nil
  "Whether this line has been handed to the child\='s own line editor.

Set by `cooked-delegate-key\=', and the reason delegation is a state rather than
a send: once the line is in the pty, the shell is echoing it and editing it, so
Emacs going on believing it owns an input region would render the line twice and
edit a copy the child will never see.

Cleared where the line ends -- a command starting or a fresh prompt -- so it
lasts exactly as long as the line it was about.  There is no way back before
then, and that is the honest cost: ZLE is still a line editor, so `C-a\=',
`C-w\=' and the arrows all still work, but they are the shell\='s now.  It is
vterm\='s ordinary state, entered on purpose and for one line.")
(defvar-local cooked--completion-nonce nil
  "Nonce from the prompt\='s OSC 51;CH announcement, or nil if it did not announce.

Kept here, in the always-on core, rather than with the completion layer that
consumes it, because it is two signals wearing one name.  To
`cooked-shell-completion\=' it is the token a request must carry.  To
`cooked--policy\=' it is a *license to own the input line*: the shell asserting,
for this line, that a widget is bound and reading -- which is the only
corroboration available once termios has gone dark behind an `ssh\='.  The
second reading has to work whether or not anyone loaded the first, so the
announcement is believed unconditionally and only the requests are opt-in.

Cleared at `command-start\=' by `cooked--apply-semantic\=', which is what keeps
it a claim about the present.  Without that, `ssh host\=' would leave the local
shell\='s nonce standing and the bare remote prompt would inherit a license
nothing on that host ever issued -- the precise failure the license exists to
rule out.")
(defvar-local cooked--completion-reply-capable nil
  "Whether the announcing shell can also answer completion requests.

Separate from `cooked--completion-nonce\=' because the two questions came apart:
framing a reply needs `base64\=', owning the input line does not.  A shell
without it announces anyway and says so here, so it keeps its editable line and
merely has nothing to offer `completion-at-point\='.")
(defvar-local cooked--prompt-continued nil
  "Whether the prompt now on screen continues the line already submitted.

Set by the OSC 133 `A;k=s\=' mark a shell puts on its `PS2\=' and cleared at the
next real prompt or at `command-start\='.  One boolean rather than a counter:
what reads it only asks whether the next submission extends the last one, and a
construct twenty lines deep is that question answered twenty times.

`cooked--send-input-string\=' is the reader.  Without this the record for
\"for x in 1 2; do ... done\" would say only `done\=', because each continuation
line is submitted separately and would overwrite the one before it.")
(defvar-local cooked--submitted-input nil
  "The last line submitted, waiting for the OSC 133 mark that says it started.")
(defvar-local cooked--marks nil
  "Hash of OSC 133 mark id to the buffer marker made for it.

The index a resize is repaired through, and nothing else reads it.  A mark
arrives with an anchor that resolves to a buffer position exactly once; a
*rewrap* then re-lays every live row at the new width and Emacs rebuilds them,
which leaves that position naming text that has moved.  The emulator keeps the
mark on the cell it landed on -- see `Extra::Mark' in src/emu/cell.rs -- and
reports the ones that moved as the drain's `:marks', so this is what pairs an id
back up with the marker to move.

The markers here are the *same objects* the command records hold, not copies:
`cooked--relocate-marks' moves one and every record built on it follows, which
is why `cooked-command' needed no new fields for any of this.

Pruned in `cooked--render-scrolled', where entries stop being reachable: a mark
below `cooked--screen-start' is in settled text the emulator will never speak
about again.")

(defun cooked--policy ()
  "How the buffer should behave right now.

One of `cooked\=', `prompt\=', `command\=', `raw\=' or `alt\='.

Derived rather than reported, because no single source knows the answer.  The
alt screen comes from the child\='s own output, the line discipline is sampled
from termios, and the prompt state comes from OSC 133 -- and the three disagree
routinely.  A shell sits in termios raw mode at every prompt, because readline
does its own editing; a full-screen program can start while the last OSC 133
mark still says `prompt-end\='.

Alt wins over everything.  It is the one state in which the child has taken the
screen over completely, so Emacs owns neither the keyboard nor the viewport --
and it is in-band, arriving at an exact position in the byte stream, where the
termios mode is sampled on a poll.

`prompt\=', `command\=' and `raw\=' are the same situation -- the child owns the
keyboard -- told apart by how well we know it.  With OSC 133 working, a raw read
that is not a prompt means the shell is running something, and it said so; that
is as positive a signal as the alt screen, so `command\=' keeps nothing back.
Without it, `raw\=' is a guess covering both a real full-screen program and a
shell editing its own prompt line, and `cooked-raw-exceptions\=' hedges against
the second.

`prompt\=' is a marked prompt with nothing corroborating the mark -- see
`cooked--ownership-license\='.  It keeps nothing back either, for the same
reason `command\=' does not: the shell said where it was, and a shell at its own
prompt wants every key.  It is the state a bare shell at the far end of an
`ssh\=' sits in, and everything the marks buy other than the keyboard --
extents, exit codes, `next-error\=', rerun -- works there unchanged."
  (cond (cooked--alt 'alt)
        ;; A password read forwards keys too; the minibuffer collects them.
        ((eq cooked--mode 'secret) 'raw)
        ;; OSC 133 before termios: `cooked--mode' is poll-sampled and
        ;; approximate, `cooked--semantic' is exact and in-band.  But a mark is
        ;; only a claim, so it takes the keyboard only with a license behind it.
        ((and (eq cooked--semantic 'input)
              (not cooked--delegated)
              (cooked--ownership-license))
         'cooked)
        ((eq cooked--mode 'cooked) 'cooked)
        ((eq cooked--semantic 'input) 'prompt)
        (cooked--semantic-seen 'command)
        (t 'raw)))

(defun cooked--ownership-license ()
  "Whether something corroborates the marked prompt enough to hand Emacs the line.

An OSC 133 `B\=' says a prompt is reading, and it says so in bytes, which is
what makes it survive an `ssh\=' -- and also what stops it corroborating itself.
After it arrives nothing says the far end is still at a prompt rather than three
seconds into a program that emitted no mark, and lifting the line out of a pty
that no line editor is reading is how keystrokes get eaten.

Two things corroborate it, and they are different in kind:

- *The child is ours.*  When the shell is on this machine, the pty is one Emacs
  spawned and can sample; termios bounds what a mark can be wrong about, and
  every local path the line might name is a path that is really there.
  `cooked--host\=' is how that is known, and it comes from the same snippet as
  the mark, so it is present exactly when the mark is.
- *A live announcement.*  `cooked--completion-nonce\=' is re-emitted per ZLE
  line from `zle-line-init\=' -- after the widget is bound and the keyboard is
  ZLE\='s, which is precisely the condition being claimed -- and cleared when a
  command starts.  It is the one signal that is both byte-transparent and
  self-corroborating, which is why it can license ownership from the far end of
  an `ssh\=' without the loophole it looks like.

What is deliberately *not* a license is the transport.  Keying decay to \"is
this remote\" would refuse a remote host running the full snippet, which reaches
the same certainty a local one does by the same bytes.  What `ssh\=' costs is
termios, and termios is an ownership signal, not a completion one.

Unlicensed, a marked prompt is not a broken state: the shell keeps its own line,
its own history and its own completion, and cooked keeps the extents, exit codes
and rerun that the marks were always the point of."
  (or (not (cooked--foreign-host-p))
      (and cooked--completion-nonce t)))

(defun cooked--secret-p ()
  "Whether the child is reading with echo off.
An overlay on the policy rather than one of its values: it says how input is
collected, not who owns the screen."
  (eq cooked--mode 'secret))

(defun cooked--input-state-p ()
  "Whether Emacs should be editing rather than passing keys through."
  (eq (cooked--policy) 'cooked))

(defun cooked--child-owns-keyboard-p ()
  "Whether the child, rather than Emacs, is the one being typed at.

Every policy but `cooked\=', which is to say `alt\=', `prompt\=', `command\=' and
`raw\=' -- said that way round on purpose.  Spelling it as a list of the states
that qualify is what left `command\=' out of three separate checks when it was
added: the answer is a property of not being at a prompt, so asking that
directly cannot go stale when another state arrives."
  (not (cooked--input-state-p)))

(defun cooked--input-mark ()
  "The marker where the pending input begins, or nil before a session.

This is the buffer\='s process mark, not a variable of our own.  comint\='s
entire command set navigates relative to `process-mark\=', so keeping the near
edge of the input region anywhere else is what made `comint-previous-input\='
answer \"Not at command line\" -- the mark it consults was one cooked never
maintained.  Storing it here rather than copying it into a private marker means
there is no second opinion to drift.

`cooked--wake\=' carries it.  The pipe is a doorbell the child rings and owns no
text, so its mark is free for this, and attaching it to the buffer is what
makes `get-buffer-process\=' answer at all.  The mark points nowhere whenever
the child owns the keyboard, so `cooked--input-region\=' is the guard callers
should go through."
  (and cooked--wake (process-mark cooked--wake)))

(defun cooked--set-input-mark (position)
  "Point the input mark at POSITION, or nowhere when POSITION is nil."
  (when-let* ((mark (cooked--input-mark)))
    (set-marker mark position)))

(defun cooked--clear-input-region ()
  "Forget the pending input region, leaving its text alone."
  (cooked--set-input-mark nil)
  (setq cooked--input-end nil))

(defun cooked--input-region ()
  "The pending input\='s bounds as (START . END), or nil when there is no region.

Both ends are set together by `cooked--restore-pending-input\=' and cleared
together by `cooked--clear-input-region\=', but either can also be left pointing
nowhere when its buffer text goes, so both have to be checked.  Callers that
want one end of a region that exists should take it from here rather than
repeating the pair of nil tests."
  (when-let* ((mark (cooked--input-mark))
              (start (marker-position mark))
              (end (and cooked--input-end (marker-position cooked--input-end))))
    (cons start end)))

(defun cooked--check-undo-anchor ()
  "Discard the undo history if the input line is no longer where it was.

Undo records exactly one thing in a cooked buffer: what the user has typed at
the prompt.  Everything else the buffer contains is written on the child\='s
behalf and kept out of the history by `cooked--with-child-edit\='.

What is left still has to be true, and undo entries name buffer positions.  Any
output at all rewrites the rows around the prompt and so moves the input line;
the entries recorded against the old position then describe screen text, which
undo would damage as readily as it would repair a typo.  The line\='s start is
therefore the whole validity condition -- while it holds still every entry
recorded against it is good, and the moment it moves they are worthless
together.

Cheap and idempotent by design, so every caller that can move the line calls it
without coordinating: the drain, `cooked--drain-and-apply\=' once more on the way
out in case the drain signalled partway, the two scrollback deletions, and
`cooked-refresh\='."
  (let ((start (cooked--input-start-position)))
    (unless (eql start cooked--undo-anchor)
      (setq cooked--undo-anchor start)
      (cooked--discard-undo))))

;; Read and assigned only under a guard that another package defined them, and
;; declared here so the byte-compiler reads those references as what they are
;; rather than as free variables; see `cooked--discard-undo'.
(defvar evil-undo-list-pointer)
(defvar undo-tree-mode)
(defvar buffer-undo-tree)

(defun cooked--discard-undo ()
  "Throw away the undo history, and everything else holding a piece of it.

`buffer-undo-list\=' is only the half of it, because undo is not a function of
the list alone.  A run of undos in progress is carried in `pending-undo-list\=',
a cons *inside* that list, and `undo-more\=' walks it without consulting the list
again; whether a run is in progress is decided by `last-command\=', which a drain
does not touch.  So: \\`u\=', a background job prints, and the next \\`u\=' undoes
conses describing text that has since moved -- in a buffer whose history is
supposedly empty, which is worse than the stale entries this was called to get
rid of.  Locally, because that variable is global: a drain runs from a process
filter, and clearing it outright would cut short an undo run in whatever other
buffer the user was actually in.

evil holds a cons of the list as well (`evil-undo-list-pointer\=', taken on
entering insert state so the whole insertion undoes as one step), and undo-tree
keeps a tree beside the list, treating the list as its staging area.  Neither
is ours to maintain and both are unreachable once the list they were taken from
is gone, so each is put back to the value its own package uses for nothing
recorded yet -- the state both are written to cope with, being the one they
start in.  Left alone they are a pointer into a list nobody holds any more and
a tree that goes on growing against positions that have moved.

Nothing at all where the user turned undo off themselves: nil would be
switching it back on for them, and there is nothing pointing into a list that
was never built."
  (unless (eq buffer-undo-list t)
    (setq buffer-undo-list nil)
    (setq-local pending-undo-list nil)
    (when (boundp 'evil-undo-list-pointer)
      (setq evil-undo-list-pointer nil))
    (when (bound-and-true-p undo-tree-mode)
      (setq buffer-undo-tree nil))))

(defun cooked--input-start-position ()
  "Where the pending input begins, or nil if there is no input region."
  (car (cooked--input-region)))

(defun cooked--pending-input ()
  "The text the user has typed but not yet submitted."
  (when-let* ((region (cooked--input-region)))
    (buffer-substring-no-properties (car region) (cdr region))))

(defvar cooked-snap-commands
  '(self-insert-command
    cooked-newline newline newline-and-indent
    yank yank-pop cooked-paste cooked-evil-paste
    evil-paste-before evil-paste-after evil-paste-from-register)
  "Commands that should act on the input region even if point drifted out of it.
See `cooked--snap-to-input'.

Plain `newline' is here because `evil-collection' binds S-RET to it directly
rather than to `cooked-newline', so it needs the same protection.

A remap would need its target named here too, and that is easy to miss: this
list is matched against `this-command', and a remap replaces `this-command'
outright rather than layering over it.  A `self-insert-command' remap once took
every ordinary keystroke out of this list, and what broke was not the feature
the remap was added for but the snap -- typing on the blank line below the
prompt silently landed outside the input markers again.  There is no such remap
now, and `cooked--guard-insertion' substitutes rather than remaps for exactly
this reason.

This list has a second reader, and adding to it now buys two things rather than
one.  `cooked--guard-insertion' keys the point-of-use termios sample off it, on
the reasoning that \"commands that act on the input region\" and \"commands that
could insert under a mode the child has already left\" are the same set -- so a
new insertion path is guarded by joining the list it had to join anyway.  Keep
it that way: a command that inserts and is left out of this list loses the snap
and the sample together, and the second failure is a password in the buffer
rather than a misplaced character.")

(defun cooked--snap-to-input ()
  "Move point into the pending-input region before an insertion command.

Point leaves the input line far more easily than it looks.  The screen is
rendered with a newline after the last row, so there is a blank line below the
prompt to sit on; and evil's normal state pulls the cursor back off the end of a
line, which at an empty prompt lands it on the last character of the prompt
itself.  Both are one keystroke away from the prompt at all times.

Typing from either place goes wrong quietly.  Before the region the prompt is
read-only, so the insert signals \"Text is read-only\"; after it the text lands
outside the markers `cooked-send-input' reads, so it sits in the buffer looking
submitted while the child is sent an empty line."
  (cooked--protect-hook
    (when (and (memq this-command cooked-snap-commands)
               (cooked--input-state-p))
      (when-let* ((region (cooked--input-region)))
        (cond ((< (point) (car region)) (goto-char (car region)))
              ((> (point) (cdr region)) (goto-char (cdr region))))))))

(defun cooked--take-pending-input ()
  "Remove the pending input from the buffer and return it."
  (when-let* ((region (cooked--input-region))
              (text (buffer-substring-no-properties (car region) (cdr region))))
    (delete-region (car region) (cdr region))
    text))

(defun cooked--restore-pending-input (text)
  "Re-insert TEXT at the cursor, re-establishing the input region.

The near edge goes on the process mark, whose insertion type stays nil so that
typing at the very start of the prompt lands inside the region rather than
pushing it along."
  (when (cooked--input-state-p)
    (save-excursion
      (goto-char (cooked--cursor-position))
      (cooked--set-input-mark (point))
      ;; comint brackets the last input with `comint-last-input-start'/`-end'.  The near
      ;; edge is this same position -- the OSC 133 `prompt-end' anchor names the row, but
      ;; only the input mark knows the column the prompt actually ended at.
      ;;
      ;; Re-set on every drain, and it has to be: this marker sits mid-row, and
      ;; `cooked--render-rows' deletes a damaged row from its start to end of line, so
      ;; anything inside collapses to the row's beginning.  `comint-last-input-end' does
      ;; not have the problem, sitting at the start of the output row -- a row boundary,
      ;; which survives -- and it is the one comint's output family actually measures
      ;; from.  `comint-last-input-start' is read only by `comint-output-filter's
      ;; echo suppression, which is comint's insertion path and never runs here.  If that
      ;; ever changes, this marker needs a cell rather than a position behind it.
      (set-marker comint-last-input-start (point))
      (when text (insert text))
      (setq cooked--input-end (copy-marker (point) t)))))

(defun cooked--point-after-input ()
  "Where point belongs after a redisplay."
  (or (and cooked--input-end (marker-position cooked--input-end))
      (cooked--cursor-position)))

(defun cooked--register-mark (id at batch-start)
  "A marker at ANCHOR AT, remembered under mark id ID.

The one place a semantic mark becomes a buffer position, so the one place that
position can be registered for a later resize to correct.  Falls through to a
plain marker when the emulator gave no id, which no live core does -- the guard
is for a `cooked-mode' buffer driven from Lisp by a test."
  (let ((marker (copy-marker (cooked--anchor-position at batch-start))))
    (when id
      (unless cooked--marks
        (setq cooked--marks (make-hash-table :test #'eql)))
      (puthash id marker cooked--marks))
    marker))

(defun cooked--relocate-marks (marks batch-start)
  "Move the markers MARKS names, each `(ID . ANCHOR)', to where the mark now is.

BATCH-START is where this drain's scrollback landed, for a `scrolled' anchor.

The repair for a resize, and the reason the emulator carries a mark on a cell at
all.  A scroll never needs it: rows leave the top of the grid and the text above
them in the buffer grows by exactly what left, so a live buffer position means
what it did.  A rewrap re-lays every logical line at the new width and Emacs
rebuilds every live row from it, and then nothing about the old positions holds
-- so `Delta::marks' reports where each mark ended up and this moves the marker
to meet it.

Because the records share these marker objects rather than copying them, moving
one here fixes every consumer at once: `cooked--command-region' and so
`next-error' and evil's command text objects, `cooked--prompt-starts' and so
`cooked-previous-command', `cooked--command-around' and so sticky scroll, and
the fringe marker per command that made the drift visible.

Before the events of the same drain, not after: a resize and a fresh mark can
land in one drain, and there the event's own anchor is the newer statement."
  (when (and marks cooked--marks)
    (pcase-dolist (`(,id . ,at) marks)
      (when-let* ((marker (gethash id cooked--marks)))
        (set-marker marker (cooked--anchor-position at batch-start))))))

(defun cooked--prune-marks ()
  "Forget the marks that have scrolled into permanent scrollback.

Called from `cooked--render-scrolled', which is the moment they get there.  A
mark below `cooked--screen-start' is on a row the emulator has handed over and
will never mention again -- it went to scrollback on the row it was attached to
-- so the entry can only grow the table.  The record that owns the marker keeps
it; what is dropped is the ability to relocate it, which nothing will ask for.

Here rather than on a timer or a size cap because this is the only path that
makes an entry unreachable, and it keeps the table at the handful of marks the
live screen carries rather than one per command of the session."
  (when-let* ((marks cooked--marks)
              (screen (cooked--screen-start-position)))
    (maphash (lambda (id marker)
               (when (or (not (marker-position marker))
                         (< (marker-position marker) screen))
                 (remhash id marks)))
             marks)))

(defun cooked--handle-semantic (event batch-start)
  "Track OSC 133 EVENT and the buffer markers that come with it.

Each mark carries an anchor saying where in the output it actually fell, which
`cooked--anchor-position' turns into a buffer position given BATCH-START, this
drain's scrollback insertion point.  The cursor is emphatically not a
substitute: by the time a drain is applied it is where the *last* thing in that
drain left it, so a script running several commands between two redisplays
would file all of their output under one region ending wherever it stopped.

Each mark also carries an id, which is how it goes on being placeable after the
anchor stops being true: `cooked--register-mark' files the marker under it and
`cooked--relocate-marks' moves it when a resize rewraps the grid.  The `.  ,id'
tails rather than a fourth pattern element so that a `cooked-mode' buffer driven
from Lisp -- which is to say a test -- can still hand these events over in their
older three-element shape."
  (setq cooked--semantic-seen t)
  (pcase event
    (`(prompt-start ,at . ,id)
     (setq cooked--semantic 'prompt
           ;; A fresh prompt is a fresh line, and Emacs may have it back.
           cooked--delegated nil
           ;; Where the prompt is about to be drawn, which is what
           ;; `cooked-previous-command' moves between and where the outer half of
           ;; an `evil' command text object starts.  The mark arrives before the
           ;; prompt itself, so this is column 0 of its first row.
           cooked--prompt-start (cooked--register-mark (car id) at batch-start)
           ;; Whatever was being continued is over: this prompt is a new line.
           cooked--prompt-continued nil))
    ;; A continuation prompt -- `PS2' -- is the same command still being typed.  It
    ;; deliberately does *not* touch `cooked--prompt-start': that marker is where the
    ;; construct began, which is what the command record is filed under and what
    ;; `cooked-previous-command' lands on.  Moving it here would start the record at
    ;; the last continuation line.  The `B' that follows still arrives, so Emacs owns
    ;; the continuation line exactly as it owns the first one.
    (`(prompt-continuation ,_ . ,_)
     (setq cooked--semantic 'prompt
           ;; A fresh line, whoever it continues, and Emacs may have it back.
           cooked--delegated nil
           cooked--prompt-continued t))
    (`(prompt-end ,_ . ,_)
     (setq cooked--semantic 'input)
     (cooked--refresh-keymap))
    ;; A second `C' with no prompt since the first is ignored, rather than moving the
    ;; start of the output region down to it.  Two shells both emitting the marks --
    ;; the `no-marks' negotiation exists to prevent exactly this, and says nothing
    ;; about what happens when it fails -- would otherwise file the command's output
    ;; from the later mark, losing whatever fell between them, and attribute the exit
    ;; code the first mark opened the record for to a region it does not describe.
    ;; `cooked--prompt-start' is the test rather than a counter of our own: it is set
    ;; by every `A' and cleared by the `C' that consumes it, so nil here means no
    ;; prompt has begun since a command started.  A shell that drops its `D' therefore
    ;; still recovers at its next prompt instead of never opening a record again.
    (`(command-start ,cmdline ,at . ,id)
     ;; Nothing at all for the duplicate, not even a marker: the id names a mark no
     ;; record will hold, so registering it would only put an entry in
     ;; `cooked--marks' for a resize to move on nobody's behalf.
     (unless (and cooked--command-start (marker-position cooked--command-start)
                  (null cooked--prompt-start))
       (let* ((marker (cooked--register-mark (car id) at batch-start))
              (start (marker-position marker)))
         (setq cooked--semantic 'output
               ;; The announcement covered the line that just ended.  Anything the
               ;; command spawns -- an `ssh', a nested shell, a REPL -- announces
               ;; for itself or does not announce at all.
               cooked--completion-nonce nil
               cooked--completion-reply-capable nil
               ;; The delegated line has been submitted; it was the shell's, and
               ;; now it is neither's.
               cooked--delegated nil
               cooked--command-start marker
               ;; What the shell said it was about to run, and only failing that what
               ;; we last submitted.  The shell's account wins where both exist: ours
               ;; is the text Emacs *sent*, glued together across the lines of a
               ;; multi-line construct by `cooked--send-input-string', while the
               ;; shell's is what its parser actually made of it.  And it is the only
               ;; account at all in every case where the shell kept the line -- a
               ;; remote prompt, a program reading input of its own, a `no-input-mark'
               ;; session -- where `cooked--submitted-input' is nil and the record
               ;; used to carry nothing.  See `State::cmdline' on the Rust side.
               cooked--command-input (or cmdline
                                         (prog1 cooked--submitted-input
                                           (setq cooked--submitted-input nil)))
               cooked--submitted-input nil
               ;; The prompt this was typed at stops being the live one here, and
               ;; becomes the running command's.
               cooked--command-prompt (prog1 cooked--prompt-start
                                        (setq cooked--prompt-start nil))
               ;; The construct has been submitted in full; the next line submitted
               ;; starts a command of its own.
               cooked--prompt-continued nil)
         ;; Output begins here, so this is where the input ended.  `comint-delete-output',
         ;; `comint-show-output' and `comint-write-output' all measure from it; it sat at
         ;; `point-min' until now, which is why deleting output flushed the whole buffer.
         (set-marker comint-last-input-end start)
         (set-marker comint-last-output-start start)
         (run-hook-with-args 'cooked-command-started-functions
                             (cooked--running-anchor)))
       (cooked--refresh-keymap)))
    (`(command-end ,code ,at . ,id)
     (setq cooked--semantic nil)
     (cooked--mark-command-end code (cooked--register-mark (car id) at batch-start)))))

;;;; Locating a cell in the buffer
;;
;; The grid outlives the text.  A redraw deletes and reinserts whole rows, so a
;; buffer position is not a stable way to say where something on the screen is,
;; while a (ROW . COL) cell is — and the two have to be converted into each other
;; constantly.  `cooked--goto-screen-row' is the primitive both directions rest
;; on, and row 0 is the awkward case in each of them.

(defun cooked--goto-screen-row (index &optional extend)
  "Move point to the start of screen row INDEX.

With EXTEND, add the lines needed to reach it; the screen region is trimmed
to its content, so a row below the cursor may not have a line yet.  Without
EXTEND this only moves point, which keeps queries free of side effects.

Row 0 begins at `cooked--screen-start' itself, which is not always the start of
a buffer line: when the last row handed to scrollback was wrapped it was written
without a newline, because row 0 continues it.  `forward-line' would snap back
to that line's beginning, and the caller would then delete the head it was
meant to continue — a whole row lost per eviction.  Rows below it are
unaffected: moving forward from a mid-line start lands on the next buffer
line, which is right,
because row 0 owns the remainder of the shared one."
  (goto-char cooked--screen-start)
  (let ((missing (if (zerop index) 0 (forward-line index))))
    ;; `forward-line' counts a final line that lacks a newline as one line
    ;; successfully moved, so it can report success while leaving point at that
    ;; line's end rather than at the start of the row we asked for.  Rendering
    ;; the next row then appends to the previous one — which is how a command's
    ;; output and the following prompt end up sharing a line.
    (unless (or (zerop index) (bolp))
      (setq missing (1+ missing)))
    (when (and extend (> missing 0))
      (goto-char (point-max))
      (insert (make-string missing ?\n)))
    missing))

(defun cooked--pad-to-cursor ()
  "Extend the cursor's row so it can hold the cursor column.

Rendered rows have trailing blanks trimmed, which loses the space at the
end of a prompt like \"$ \".  The input region would then begin one column
early, and the shell's echo of the submitted line would disagree with
what was displayed."
  (save-excursion
    (cooked--goto-screen-row (cooked-cursor-row cooked--cursor) 'extend)
    (let ((short (- (cooked-cursor-col cooked--cursor) (- (line-end-position) (point)))))
      (when (> short 0)
        (goto-char (line-end-position))
        (insert (make-string short ?\s))))))

(defun cooked--render-scrolled (block)
  "Append BLOCK to the scrollback above the live screen, returning where it went.

The return value is the buffer position the batch was inserted at, which is what
a `scrolled' anchor is an offset from — see `cooked--anchor-position'.  It stays
valid for the rest of the redisplay: everything rendered afterwards goes below
it.

The marker is advanced explicitly rather than by insertion type: rendering
screen row 0 also inserts at this position, and an auto-advancing marker would
drift into the screen region.

Widens first: history can arrive while the alt screen is up — a resize evicts
rows from the primary even when a full-screen program is showing — and the
insertion point is above the region `cooked--apply-alt-pin' confines us to.

No row index is passed to `cooked--render-block': scrollback has no screen
column to phase a shade glyph's dither against, which costs at most a seam on
that one glyph kind, exactly as a live row rendered without a known origin does."
  (save-restriction
    (widen)
    (save-excursion
      (goto-char cooked--screen-start)
      (let ((start (cooked--render-block block)))
        ;; Scrollback never changes again, so it is protected once, here, rather
        ;; than re-swept on every redisplay.
        (add-text-properties start (point)
                             '(cooked-scrollback t read-only t
                               front-sticky (read-only) rear-nonsticky (read-only)))
        ;; Once per batch, over the whole of it, and this is the pass that sees a
        ;; wrapped URL whole: `cooked-rejoin-wrapped-lines' has just joined a
        ;; continuation row onto the line above it, so the two halves the live
        ;; screen showed as two rows are one string here.
        (cooked--fontify-links start (point))
        ;; The optional file layer's seam, and the reason it is here rather than
        ;; in the row path: this text is settled and will never be rendered
        ;; again, so an answer that costs a `file-exists-p' is paid once instead
        ;; of once per redraw.
        ;; An optional layer touching the filesystem from inside the drain is
        ;; exactly the kind of extension point that must not be able to end a
        ;; redisplay -- the same containment `cooked--handle-osc' gives a
        ;; handler, for the same reason.
        (when cooked-link-scan-functions
          (cooked--run-seam 'cooked-link-scan-functions start (point)))
        (set-marker cooked--screen-start (point))
        ;; After the marker moves, so it names the seam these marks are now above.
        (cooked--prune-marks)
        start))))

;;;; The child's cursor, while Emacs has wandered off it

(defcustom cooked-cursor-shapes
  '((block . t) (underline . hbar) (bar . (bar . 2)))
  "How DECSCUSR shapes map onto `cursor-type'.

The child names a shape with `CSI Ps SP q'; vim and fish's vi-mode use it to
show which mode they are in.  Only the shape is honoured — DECSCUSR also
distinguishes blinking from steady, and whether your cursor blinks is
`blink-cursor-mode', which is yours to set and not the child's."
  :type '(alist :key-type symbol :value-type sexp)
  :group 'cooked)

(defun cooked--cursor-type ()
  "The `cursor-type' for the shape the child last asked for."
  (alist-get (cooked-cursor-shape cooked--cursor) cooked-cursor-shapes t))

;; The ghost cursor below deliberately does not follow the shape.  It is hollow to
;; say "not receiving your keystrokes", and that reading comes from the hollowness
;; rather than from the outline — Emacs has no meaningful hollow bar to draw anyway.

(defface cooked-ghost-cursor
  '((t :box (:line-width (-1 . -1))))
  "Face marking where the child's cursor is while point is somewhere else.

Drawn hollow on purpose.  A terminal draws its cursor hollow when the window
is unfocused, so the shape already reads as \"this cursor is not receiving
your keystrokes\" — which is exactly what is true of the child's cursor while
you are navigating with Emacs' own motions."
  :group 'cooked)

(defvar-local cooked--ghost-cursor nil
  "Overlay drawing the child's cursor, or nil when it is not being drawn.")

(defvar-local cooked--wandered nil
  "Whether a command has moved point off the child's cursor.

Tracked as a state set by commands rather than inferred by comparing point to
the cursor on each drain.  The comparison is order-dependent — streaming output
lets the cursor overtake point for a single drain — and inferring from it would
strand point for every drain after that.  See `cooked--apply'.")

(defvar-local cooked--point nil
  "Where cooked itself last put point in this buffer.

Kept because Emacs remembers a *position* on cooked's behalf and cooked's
positions do not survive a redraw.  A window that stops showing this buffer
leaves a point marker for it in `window-prev-buffers\=', and
`cooked--render-rows\=' deletes and reinserts whole rows, so by the time it
comes back that
marker has been dragged off whatever it was pointing at -- to the end of the
rebuilt region, which at a prompt is the empty line below it.  Emacs restores it
over the top of the position the drain maintained meanwhile, so cooked has to
hold its own answer.  The same reasoning as `cooked--wandered\=' holding a screen
cell rather than a position, one level up: a cell survives a redraw, a marker
does not, and an unwatched marker is not evidence about anything.

Written by the drain and by `cooked--track-wandering\=', which between them are
every way point moves that cooked has an opinion about; read by
`cooked--restore-point\=' when the buffer comes back on screen.")

(defun cooked--restore-point (window)
  "Put point back where cooked last had it, over a marker Emacs restored.

Called when this buffer returns to WINDOW.  What Emacs restores is the window
point it recorded when the buffer left, and for a cooked buffer that is a marker
every drain since has been dragging -- see `cooked--point\='.  The drain's own
answer is the one that means something: it re-seats a wandered point on its
cell and follows the child's cursor otherwise, and it does that whether or not
anyone is looking.

Declines when the recorded position is not in the accessible portion -- the alt
screen narrows, and a position from before it did is not this screen's."
  (when (and cooked--point
             (<= (point-min) cooked--point (point-max))
             (/= (point) cooked--point))
    (goto-char cooked--point)
    (when (window-live-p window)
      (set-window-point window cooked--point))))

(defun cooked--sync-cursor-type ()
  "Make `cursor-type\=' say what the child last asked for.

Written only on an actual change: reassigning the same value on every drain
perturbs the cursor\='s blink phase, which is one more contributor to flicker on
a line the child rewrites rapidly.

Called at the end of a drain, after the block that scrolls windows, and again
from `post-command-hook\='.  `evil\=' refreshes its own cursor from
`window-configuration-change-hook\=' and on every state change, and it advises
`select-window\=' -- which the render used to call, once per window, to
`recenter\=' through `with-selected-window\='.  Setting the cursor any earlier
let evil get the last word inside the very drain that hid it, which showed up
as a cursor jumping around a progress bar the child had asked to draw without
one.  Scrolling no longer selects anything, so that particular door is shut;
the ordering stays because the other two ways in are still open.

A hidden cursor is honoured by default: every full-screen program drawing a
frame, `less\=', and any progress bar worth the name relies on that.  Two cases
override it, and both are cases where point is the only cursor there is.  The
user has stepped out, which the mode alone answers -- `still\=' or `frozen\='.
Or Emacs is editing the line, which `cooked--input-state-p\=' alone is too wide
to say, because `brew upgrade\=' hides the cursor and repaints progress bars
without ever leaving canonical mode.  Under a shell that sends OSC 133 we know
which of the two it is, and while a command is running the child\='s `CSI ?25l\='
is about the picture it is painting and is honoured."
  (let ((shape (cond ((and cooked--cursor (cooked-cursor-visible cooked--cursor))
                      (cooked--cursor-type))
                     ((memq cooked--input-mode '(still frozen)) t)
                     ((and (cooked--input-state-p)
                           (not (eq cooked--semantic 'output)))
                      t))))
    (unless (equal cursor-type shape)
      (setq-local cursor-type shape))))

(defun cooked--ghost-cursor-visible-p ()
  "Whether the child's cursor should be drawn separately from point.

Not an alt-screen thing: `raw', `command' and every suspended state -- `evil'
normal state included -- are all cases where the child owns the keyboard and
point may be somewhere else, and the ghost is what keeps the way back visible
in each of them.

Nothing is drawn for a cursor the child has hidden, which is also the case in
which `cooked--sync-cursor-type' gives point a visible cursor of its own: there
is exactly one cursor on screen either way, and it is the one that will act on
the next keystroke."
  (and cooked--wandered
       ;; Only where the child owns the keyboard and the screen is its drawing.
       ;; At a prompt, point being elsewhere is ordinary editing, not a divergence.
       (cooked--child-owns-keyboard-p)
       ;; A hidden cursor stays hidden; nvim hides it during some redraws, and a
       ;; box left behind would be a cursor the child does not think it has.
       (cooked-cursor-visible cooked--cursor)))

(defun cooked--update-ghost-cursor ()
  "Draw, move, or remove the overlay marking the child's cursor."
  (if (not (cooked--ghost-cursor-visible-p))
      (when cooked--ghost-cursor
        (delete-overlay cooked--ghost-cursor)
        (setq cooked--ghost-cursor nil))
    (let* ((beg (cooked--cursor-position))
           (eol (save-excursion (goto-char beg) (line-end-position)))
           ;; Past the last character of its row the cursor has nothing to cover,
           ;; so the box rides on a stand-in space instead.
           (empty (>= beg eol)))
      (unless cooked--ghost-cursor
        (setq cooked--ghost-cursor (make-overlay beg beg nil t nil))
        ;; Above `hl-line-mode' and the region, which would otherwise paint over
        ;; the one thing on screen the user is aiming at.
        (overlay-put cooked--ghost-cursor 'priority 100))
      (move-overlay cooked--ghost-cursor beg (if empty beg (1+ beg)))
      (overlay-put cooked--ghost-cursor 'face (unless empty 'cooked-ghost-cursor))
      (overlay-put cooked--ghost-cursor 'after-string
                   (when empty (propertize " " 'face 'cooked-ghost-cursor))))))

;;;; Shaping the screen region
;;
;; What the buffer looks like between drains: how tall the live region is, what
;; the alternate screen does to the rest of the buffer, where the read-only text
;; ends, and the one place a row is allowed to disagree with the emulator about
;; its own width.

(defcustom cooked-alt-change-hook nil
  "Hook run in the buffer when the alternate screen goes up or comes down.

Read `cooked--alt' for which way it went.  Distinct from
`cooked-state-change-hook', which answers a different question -- who owns the
keyboard -- and misses this one whenever the child already owned it: a raw-mode
program opening a full-screen one changes the screen without changing hands.

For a layer that has drawn something on the *primary* screen and must take it
down while a full-screen program has the viewport.  `cooked-command-decorations'
is the case it exists for: its markers ride overlays on the live rows, and those
buffer positions are where the alt screen's own rows get rendered, so a marker
left up sits in the fringe beside a running program's frame claiming to be about
a command.  Coming back needs no hook -- restoring the primary marks every row
damaged, and a layer that re-applies per render is repainted by that."
  :type 'hook
  :group 'cooked)

(defun cooked--set-alt (on)
  "Adopt alternate-screen state ON, refreshing ownership when it changes.

The keymap has to follow this and not only the line discipline: a program can
take the screen while the shell's last OSC 133 mark still says `prompt-end',
and Emacs would otherwise keep editing an input region that no longer exists
and swallow the keys the program was waiting for."
  (let ((on (and on t)))
    (unless (eq on cooked--alt)
      (setq cooked--alt on)
      (cooked--refresh-keymap)
      (run-hooks 'cooked-alt-change-hook))))

(defun cooked--apply-alt-pin ()
  "Confine the buffer to the screen region while the alt screen is up.

Re-applied on every redraw rather than only on the transition: the accessible
end behaves like a marker that insertions push past, so rows appended at the
end of one redraw would fall outside the region by the next.

Only ever undoes its own restriction.  A narrowing the user made themselves is
none of our business, and widening it on the next drain would make `\\[narrow-to-region]'
unusable in a terminal buffer.

Which also means a deliberate `\\[widen]' lasts exactly until the next drain, this
being re-applied rather than merely established.  The way to read the transcript
behind a running program is therefore to stop the drains first: `\\[cooked-toggle-peek]'
freezes the render, and a widening made inside that peek stands until it is
resumed."
  (if (and cooked--alt (cooked--screen-start-position))
      (progn
        (narrow-to-region (cooked--screen-start-position) (point-max))
        (setq cooked--narrowed t))
    (cooked--release-alt-pin)))

(defun cooked--release-alt-pin ()
  "Undo the restriction `cooked--apply-alt-pin' put on the buffer, if any."
  (when cooked--narrowed
    (setq cooked--narrowed nil)
    (widen)))

(defvar cooked--pinning nil
  "Non-nil while `cooked--pin-alt-windows' is moving a window's start.
It runs from inside redisplay, which is entitled to start over for the very move
it makes; without this the two could take turns forever.")

(defun cooked--pin-alt-windows (&optional window _start)
  "Keep every window on this buffer showing the alt screen from its first row.

WINDOW, when live, is pinned alone -- that is how `pre-redisplay-functions\='
calls this, naming the window that is about to be drawn.  START is ignored: the
only start this accepts is the screen\='s.

`cooked--apply\=' already pins at the end of a drain, and that is not enough.  A
drain is the child talking, and nothing the *user* does to the window produces
one: a full-screen program sitting idle at its prompt draws nothing, so a wheel
notch scrolled the picture off the window and left it there.  Run from a command
hook, the pin becomes the continuous invariant it always meant to be.

Forcing, unlike the drain\='s pin, because the wheel moves point along with the
window and NOFORCE would let redisplay honour the point it left behind.  The
vscroll goes with the start, because `pixel-scroll-precision-mode\=' carries a
remainder that survives being told where the window starts.  And two hooks
rather than one, because `post-command-hook\=' runs in the buffer of the selected
window and a notch from a mouse is animated across a dozen redisplays inside the
one command.  See docs/DESIGN.md for what each of those cost to find."
  (cooked--protect-hook
    (unless cooked--pinning
      (let ((cooked--pinning t))
        (when cooked--alt
          (when-let* ((top (cooked--screen-start-position)))
            (dolist (w (if (window-live-p window)
                           (list window)
                         (get-buffer-window-list nil nil t)))
              (unless (= (window-start w) top)
                (set-window-start w top))
              (unless (zerop (window-vscroll w t))
                (set-window-vscroll w 0 t)))))))))

(defun cooked--fit-screen ()
  "Shape the screen region to the number of rows the emulator says it has.

One number, and the emulator's rather than ours.  Which one differs by screen:

On the alternate screen a terminal is a fixed rectangle, so the region holds the
grid's full height — trimming to content would fight a full-screen program, and
leaving the old lines in place is why a shrunk window kept showing stale rows.

On the primary it holds `:used' rows, which is where the emulator's own content
ends: everything down to the last row holding something, and never above the
cursor.  A terminal shows a fixed rectangle but a buffer should not carry two
dozen empty lines under the prompt, and a program drawing below the cursor is
inside `:used' by construction, so its layout survives.

Unconditional in both cases, and deliberately not conditioned on the tail being
*wholly blank*: that is a question about the buffer's text rather than about
the grid, and the two stop agreeing the moment a height shrink evicts rows.
The rows that left are inserted above as scrollback and the survivors
re-rendered from row 0 down, so the old lines below the new last row are not
blank — they are a stale
copy of the live screen, and a blankness test leaves the screen showing twice."
  (save-excursion
    (let ((rows (if cooked--alt
                    (cooked-grid-height cooked--grid)
                  (cooked-grid-used cooked--grid))))
      (if (and cooked--alt (> rows 0))
          ;; `extend' on the alt screen only: the rectangle must be exactly that
          ;; tall even where the program has drawn nothing, while the primary is
          ;; trimmed to content and has no business growing here.
          ;;
          ;; Extend to the *last* row and trim from its end, rather than
          ;; walking one row past the last and trimming from its start.  A row
          ;; is made to exist by inserting the newline that ends the row above
          ;; it, so asking for row ROWS left the region ROWS newline-terminated
          ;; lines and then an empty one at `point-max' — a real buffer line
          ;; below the bottom of the screen, which point can be moved onto and
          ;; which scrolls the whole picture up by one when it is.  Trimming to
          ;; `line-end-position' of the last row leaves that row unterminated,
          ;; exactly as the primary's last row already is, and is stable across
          ;; drains: the next one lands `bolp' on it and deletes nothing.
          (progn (cooked--goto-screen-row (1- rows) 'extend)
                 (delete-region (line-end-position) (point-max)))
        ;; Without `extend' a region already short enough reports the
        ;; shortfall and is left alone.
        (when (zerop (cooked--goto-screen-row rows))
          (delete-region (point) (point-max)))))))

(defun cooked--check-seam ()
  "Signal if the buffer disagrees with the emulator about the seam.

`:head' is how many characters of screen row 0's logical line are already in the
buffer, so `cooked--screen-start' must sit exactly that far into its line: the
two ends each hold half of one wrapped line and nothing else ties them
together.  A drift here is silent — the text reads fine until the next rewrap
resumes the line in the wrong column — which is what this exists to make loud.

Only meaningful while wrapped rows are being rejoined.  With
`cooked-rejoin-wrapped-lines' off every row handed over gets a newline of its
own and the marker is always at a line start, whatever the emulator carries.

Called under `cooked-debug' only.  It is a whole-line measurement on every
drain, and the invariant it guards is maintained in the native core rather than
here, so there is nothing for it to repair — see `Row::line_runs' in
src/emu/cell.rs."
  (when-let* ((start (and cooked-rejoin-wrapped-lines
                          (cooked--screen-start-position))))
    (let* ((head (save-excursion (goto-char start)
                                 (- start (line-beginning-position))))
           (want (cooked-grid-head cooked--grid)))
      (unless (= head want)
        (error "cooked: seam desync: buffer holds %d characters of row 0's line, emulator says %d"
               head want)))))

(defun cooked--protect (limit)
  "Make the screen read-only up to LIMIT, leaving anything after it editable.

Stickiness carries the whole design: `rear-nonsticky' leaves the far edge
open so typing at the start of the input region is accepted, while
`front-sticky' closes the near edge so nothing can be wedged in above the
transcript."
  (when (cooked--screen-start-position)
    (let ((beg (min (cooked--screen-start-position) limit)))
      (add-text-properties beg limit
                           '(read-only t front-sticky (read-only) rear-nonsticky (read-only)))
      (when (< limit (point-max))
        (remove-text-properties limit (point-max) '(read-only nil))))))

(defun cooked--row-mismeasured-p (start end window)
  "Whether the row START..END is one Emacs may render wider than Rust assumed.

The terminal's width model is Unicode East Asian Width, and `string-width' is
the same model, so a row whose `string-width' already exceeds `cooked--cols' is
genuinely long -- scrollback from a wider grid, predating a resize -- and should
soft-wrap rather than be trimmed.

Compared against `cooked--cols' rather than a fresh `window-max-chars-per-line':
the two agree only once `cooked--sync-size' has caught up with WINDOW's pixel
geometry, and a wake-driven drain can land in the gap during a resize drag.
There the row was rendered against the old width while a fresh measurement
already answers for the new one, which reads an ordinary render as a
too-wide row and waves it through to a silent, unmarked soft-wrap.

The frame check is a fast path.  A terminal frame has no shaping engine, so
plain ASCII cannot disagree there; a graphical one can turn `->' into a single
ligature glyph no per-character metric predicts."
  (and (<= (string-width (buffer-substring-no-properties start end)) cooked--cols)
       (or (display-graphic-p (window-frame window))
           (string-match-p (rx (not ascii))
                           (buffer-substring-no-properties start end)))))

(defun cooked--trim-to-one-line (start window)
  "Delete characters from the end of the row at START until it stops wrapping.

WINDOW is the window whose layout decides what wrapping means; it is passed
through to `vertical-motion', and nil there means the selected window.  See
`cooked--guard-row-width', the only caller, for why that choice matters.

Returns non-nil if anything went.  Rarely more than a character or two, since
the mismatch is usually a column.

`line-end-position' is captured before each `vertical-motion' and never after:
taken after, it measures the end of whatever line the motion landed on rather
than this row's own end, so a row that does not wrap at all still reads as short
of it -- and the loop then eats the newline above START and the row below."
  (let (trimmed eol)
    (while (progn (goto-char start)
                  (setq eol (line-end-position))
                  (vertical-motion 1 window)
                  (< (point) eol))
      (setq trimmed t)
      (delete-region (1- eol) eol))
    trimmed))

(defun cooked--guard-row-width (start)
  "Keep the screen row beginning at START to one screen line.

Every live row is its own hard-newlined buffer line, so Emacs softwrapping one
is never legitimate output: it means some character rendered wider than
`cooked--cols' assumed -- an ambiguous East-Asian width, a composed grapheme, a
font substitution, a ligature.  Rust's width model is not the place to chase
that, since it has to keep reporting the plain narrow classification curses
programs expect, so this catches what gets through on the one side that can
observe the truth: Emacs' own layout, by way of `vertical-motion'.

Measured against `cooked--layout-window' rather than the selected window, which
need not be showing this buffer at all -- a row measured against a foreign
window is trimmed to a width it was never written for.  A buffer displayed
nowhere is not measured, and gets its chance when it is displayed.

The cut is marked with the truncation bitmap `truncate-lines' would show, by
hand, because `cooked-rejoin-wrapped-lines' keeps `truncate-lines' off
buffer-wide so a genuinely wrapped scrollback line still reflows for free.

Trimming by character rather than by grapheme cluster is an accepted gap: a cut
between a base character and a combining mark is possible in principle and
vanishingly unlikely in practice, the trigger being a character whose own width
was mismeasured rather than an adjacent one."
  (let ((window (cooked--layout-window)))
    (when (and cooked-rejoin-wrapped-lines window (< start (line-end-position)))
      (goto-char start)
      (when (and (cooked--row-mismeasured-p start (line-end-position) window)
                 (cooked--trim-to-one-line start window))
        (goto-char start)
        (cooked--mark-truncation start (1- (line-end-position)) window)))))

(defcustom cooked-truncation-bitmap nil
  "Fringe bitmap `cooked--truncation-bitmap' draws for a trimmed row.

nil (the default) defers to the `truncation' entry in
`fringe-indicator-alist', the way Emacs's own truncation arrow does, so a
user who already rebound that indicator sees their own choice here too.  Set
this to a bitmap symbol -- one of `fringe-bitmaps', or one of your own from
`define-fringe-bitmap' -- to override it directly instead."
  :type '(choice (const :tag "Defer to fringe-indicator-alist" nil) symbol)
  :group 'cooked)

(defun cooked--mark-truncation (start cut window)
  "Mark the row from START to CUT as having had characters trimmed.

Where the marker goes depends on whether WINDOW -- the one the trim was measured
in -- has a fringe to put it in, and the difference is a column of the user\='s
text.  WINDOW\='s frame rather than the selected one answers that, since the two
are the same only when the buffer is displayed where it is being rendered from.

On a graphical frame the marker rides an overlay string rather than a `display\='
property on CUT itself.  A fringe `display\=' spec shows its bitmap \"instead of
the characters that have the display specification\", so putting one on a real
character silently costs the row one more character than the trim already did --
while the whole point of using the fringe is that it sits outside the text area
and costs nothing.  The overlay evaporates on its own, because
`cooked--render-rows\=' deletes the row before rewriting it.

The string goes at the *start* of the row as a `before-string\=', not at CUT as
an `after-string\='.  A fringe bitmap belongs to the screen line rather than to
the column it is anchored in, so either end draws the same picture -- but the
string still has to be placed, and the trim loop leaves the row as wide as it
can.  Anchoring at the cut therefore lands it flush with the right edge often
enough to matter, and redisplay opens an empty continuation line to put it on.
Column zero is never full.

On a terminal frame there is no fringe, so the marker has to cost a column,
exactly as `truncate-lines\=' spends the last one on `$\='.

Known gap: a graphical frame whose window has no right fringe has nowhere to
draw the bitmap, so the marker is invisible there.  See docs/DESIGN.md."
  (if (display-graphic-p (window-frame window))
      (let ((overlay (make-overlay start (1+ start))))
        (overlay-put overlay 'evaporate t)
        (overlay-put overlay 'cooked-truncation t)
        (overlay-put overlay 'before-string
                     (propertize " " 'display
                                 (list 'right-fringe (cooked--truncation-bitmap)))))
    (put-text-property cut (1+ cut) 'display
                       (string (cooked--truncation-glyph)))))

(defun cooked--truncation-bitmap ()
  "The fringe bitmap Emacs marks a line truncated on the right with.

Reads `cooked-truncation-bitmap' first; when that is nil, falls back to
`fringe-indicator-alist' so a user who rebound the indicator but never set
`cooked-truncation-bitmap' sees their own choice.  Its entry is (LEFT RIGHT)
and we are always the right-hand end."
  (or cooked-truncation-bitmap
      (let ((indicator (cdr (assq 'truncation fringe-indicator-alist))))
        (if (consp indicator) (nth 1 indicator) indicator))
      'right-arrow))

(defun cooked--truncation-glyph ()
  "The character a terminal frame marks a truncated line with.
Whatever the display table says, so a user who has rebound it sees their own
choice here too, and `$' — which is what Emacs itself falls back to — otherwise."
  (or (when-let* ((table (or buffer-display-table standard-display-table))
                  (glyph (display-table-slot table 'truncation)))
        (glyph-char glyph))
      ?$))

(defvar cooked-row-rendered-functions nil
  "Abnormal hook run with the bounds of each live row this drain rewrote.

Each entry is called as (BEG END) with the row\='s own buffer positions, once
per damaged row, from `cooked--notify-rows-rendered\=' at the end of the drain
rather than from `cooked--render-rows\=' as each row is written.

That delay is part of the contract rather than an implementation detail.  A
drain that evicts rows inserts their text above the live screen, which pushes
every marker below it forward by a whole row, so until `cooked--relocate-marks\='
runs every semantic mark on the screen names the row below the one it belongs
to.  Rendering happens inside that window, and a layer painting from a mark
there painted the row below once per scroll -- and since the correction that
followed moved the marker and not the paint, the mistake stuck.  BEG and END are
still exact: nothing between the render and the notification moves text.

This is the seam for a decoration that has to be re-applied rather than
persisted.  A damaged row is deleted before it is rewritten, so anything
anchored to its characters dies with it, and a resize damages every live row at
once.  `cooked--fontify-links\=' is the same shape one level down and needs no
hook, links being cooked\='s own business; this exists for the optional layers,
which cannot reach into the render path themselves.

Not called for alternate-screen rows: that grid is a rectangle the child owns
outright, with no scrollback and no command records of Emacs\=' own to re-apply.
Empty by default, and run through `cooked--run-seam\=', so an entry that signals
costs its own contribution and neither the rest of the hook nor the drain.")

(defun cooked--render-rows (rows &optional alt)
  "Rewrite damaged ROWS, an alist of (INDEX . BLOCK).

ALT says whether these rows belong to the alternate screen, and is passed in
rather than read from `cooked--alt' because that variable still holds the
*previous* drain's answer at this point in `cooked--apply' -- which would leave
the frame that restores the primary screen, and every link on it, unscanned.

Returns the (BEG . END) bounds of each live row it rewrote, in the order it
wrote them, for `cooked--notify-rows-rendered' to announce once the drain has
finished putting its markers right -- see `cooked-row-rendered-functions'.  The
positions stay exact while they wait: a row is rendered in place, so writing a
later row never moves an earlier one, and nothing between here and the
notification inserts or deletes anything either.  Nil for the alternate screen,
which has no such seam at all."
  (let (rendered)
    (save-excursion
      (pcase-dolist (`(,index . ,block) rows)
        (cooked--goto-screen-row index 'extend)
        (delete-region (point) (line-end-position))
        (let ((start (point)))
          (cooked--render-block block index)
          (cooked--guard-row-width start)
          ;; Per freshly-rendered row, and no unfontify pass to go with it:
          ;; goto-addr's overlays carry `evaporate t', so the `delete-region' above
          ;; has already taken this row's previous ones with it.  Skipped on the
          ;; alternate screen unless asked for -- see
          ;; `cooked-detect-links-on-alt-screen'.
          (when (or (not alt) cooked-detect-links-on-alt-screen)
            (cooked--fontify-links start (line-end-position)))
          ;; Links are cooked's own business and can be scanned the moment the
          ;; text is there; the optional layers cannot, because a mark on this
          ;; screen is not yet where it belongs.  So the bounds are only
          ;; remembered here.
          (when (and cooked-row-rendered-functions (not alt))
            (push (cons start (line-end-position)) rendered)))))
    (nreverse rendered)))

(defun cooked--notify-rows-rendered (bounds)
  "Hand BOUNDS, this drain\='s rewritten live rows, to the optional layers.

Separate from `cooked--render-rows' and called well after it, which is the
whole point of the split -- `cooked-row-rendered-functions' says why, and
`cooked--apply' is where the two halves are ordered against the marks.

Errors are contained per row: this runs from inside the process filter, over
text that is already correct without whatever the layer was going to add, so a
cosmetic pass must not be able to end a redisplay."
  (when cooked-row-rendered-functions
    (pcase-dolist (`(,beg . ,end) bounds)
      (cooked--run-seam 'cooked-row-rendered-functions beg end))))

;;;; Cells, anchors and positions

(defun cooked--cursor-position ()
  "Buffer position of the emulator cursor.
A pure query: it never extends the buffer, so it is safe to call before
`inhibit-read-only' is in effect."
  (save-excursion
    (cooked--goto-screen-row (cooked-cursor-row cooked--cursor))
    (min (+ (point) (cooked-cursor-col cooked--cursor)) (line-end-position))))

(defun cooked--anchor-position (anchor batch-start)
  "Buffer position ANCHOR names, or the cursor if it names nothing we can place.

ANCHOR is what the native core attached to a semantic mark, spelled in whichever
coordinate system survives the drain the mark arrived in — see `anchor_to_lisp'
in src/lib.rs:

  (scrolled . OFFSET)  characters into the scrollback this drain just
                       inserted, for a row that scrolled away while the
                       drain accumulated.  BATCH-START, from
                       `cooked--render-scrolled', is where that text begins.
  (screen ROW . COL)   a cell on the live grid, for a row still on it.

Both are resolvable only after the scrollback and the damaged rows have been
rendered, which is where `cooked--apply' dispatches events.

The fallback is the cursor.  That is precise enough whenever a drain carries a
single mark, and wrong in exactly the case anchors exist for: several marks in
one drain would all land on the same position."
  (pcase anchor
    (`(scrolled . ,offset)
     (if batch-start
         (min (+ batch-start offset) (point-max))
       (cooked--cursor-position)))
    (`(screen ,row . ,col)
     (save-excursion
       (cooked--goto-screen-row row)
       (min (+ (point) col) (line-end-position))))
    (_ (cooked--cursor-position))))

(defun cooked--screen-cell (&optional pos)
  "Screen row and column of POS, or nil if it is not on the screen.

The grid outlives the text: a redraw deletes and reinserts whole rows, so a
buffer position is not a stable way to remember where the user was looking,
while a cell is.

The inverse of `cooked--goto-screen-row', including its treatment of row 0:
when `cooked--screen-start' sits mid-line, the head before it belongs to
scrollback, so the column is measured from the marker rather than from the
line's beginning, which would count characters that are not on the screen
at all."
  (let ((pos (or pos (point)))
        (start (cooked--screen-start-position)))
    (when (and start (>= pos start))
      (save-excursion
        (goto-char pos)
        (if (< (line-beginning-position) start)
            (cons 0 (- pos start))
          (cons (count-lines start (line-beginning-position))
                (current-column)))))))

(defun cooked--goto-screen-cell (cell)
  "Move point to CELL, a (ROW . COL) pair, clamped to what the row holds."
  (cooked--goto-screen-row (car cell))
  (forward-char (min (cdr cell) (- (line-end-position) (point)))))

(defun cooked--at-child-cursor-p ()
  "Whether point is sitting where the child's cursor is."
  (and cooked--screen-start (marker-position cooked--screen-start)
       (= (point) (cooked--cursor-position))))

;;;; Session lifecycle

(defun cooked--window-size ()
  "Rows and columns to give the child.

A buffer can be displayed in several windows at once, across frames, but the
child has exactly one size.  Take the smallest: sizing to a larger window would
wrap and clip everything shown in the smaller one.

`window-max-chars-per-line' rather than `window-body-width', because the
latter counts the column reserved for the continuation glyph and measures
in the frame's canonical character width.  Both round the wrong way: claim
one column too many and the child wraps a line the window cannot fit,
which shows up as the last character folding onto a line of its own.

The column count comes from `cooked--layout-window' rather than from a second
minimum taken here.  They were computed separately and are the same quantity by
construction -- that window is *defined* as the narrowest one -- so a change to
what counts as narrowest had two places to land and only ever reached one."
  (let ((windows (get-buffer-window-list (current-buffer) nil t)))
    (if-let* ((layout (cooked--layout-window)))
        (cons (max 1 (apply #'min (mapcar #'cooked--window-rows windows)))
              (max 1 (window-max-chars-per-line layout)))
      (cons cooked--rows cooked--cols))))

(defun cooked--window-rows (window)
  "Rows of text WINDOW can actually show, rounding a partial row down.

`window-body-height' divides by the frame's *canonical* character height,
so it disagrees with the buffer whenever the default face is remapped —
`text-scale-mode' being the usual way — and it says nothing about
`line-spacing'.  Dividing the real pixel height by the real line height
gets both, and floors, so a row that is only half visible is not a row we
claim to have."
  (floor (window-body-height window t) (window-default-line-height window)))

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
`cooked--guard-row-width' acts on the answer by deleting text."
  (let (narrowest)
    (dolist (window (get-buffer-window-list (current-buffer) nil t) narrowest)
      (when (or (null narrowest)
                (< (window-max-chars-per-line window)
                   (window-max-chars-per-line narrowest)))
        (setq narrowest window)))))

(defcustom cooked-min-redisplay-interval 0.008
  "Floor, in seconds, on how often a session triggers a redisplay.

Without one, a child that rewrites the same line rapidly -- a spinner, a
progress meter -- drives one full Emacs redisplay per write, far more than
any of them are actually meant to be seen at, which shows up as flicker.
Modelled on `eat-minimum-latency', though a matching ceiling on the other
end is not needed: the native core always holds the latest terminal state
regardless of whether a redisplay was requested for it, and retries a
throttled one on every read cycle, so nothing is ever stranded behind this.

Lower it if the terminal feels less responsive than it should; raise it if
it still flickers.  Takes effect for sessions started after it is set."
  :type 'number
  :group 'cooked)

(defcustom cooked-backlog-limit 8000
  "Items awaiting collection before the child is left to block on its writes.

Counts scrolled-off lines plus undelivered events.  Raising it does not make
output render faster: throughput is bounded by how fast Emacs can insert text,
not by this queue.  What it changes is who waits.  Below the limit the child
runs ahead and finishes sooner while Emacs catches up; at the limit the reader
stops draining the pty, the pty's buffer fills, and the child blocks in `write'
exactly as it would against a slow terminal.  Nothing is ever dropped.

The cost of raising it is memory, and a larger worst-case pause when a big
backlog finally lands in one redisplay.  Tuned together with
`cooked-min-redisplay-interval': a longer interval leaves more to accumulate
between drains, so this fills sooner.

Takes effect for sessions started after it is set."
  :type 'natnum
  :group 'cooked)

(defcustom cooked-confirm-kill 'auto
  "Whether killing a live session asks first.

t makes both of the prompts a terminal buffer ought to have: killing the buffer
asks \"Buffer *cooked* has a running process; kill it?\", and
\\[save-buffers-kill-emacs] counts the session among the active processes it
warns about before exiting.  nil kills the child without a word.  `auto', the
default, asks only while something other than the shell's own prompt is on the
other end -- which is the case the warning exists for, and the one an idle shell
buffer is not.

Neither prompt is written here.  Both are Emacs' own -- `kill-buffer' runs
`kill-buffer-query-functions', whose default member is
`process-kill-buffer-query-function', and `save-buffers-kill-emacs' walks
`process-list' -- and each asks a *process* whether it minds being killed, via
`process-query-on-exit-flag'.  So this is spelt as the flag on `cooked--wake',
which is what puts the session in front of the machinery the user already has:
`confirm-kill-processes' still turns the exit prompt off globally, the session
still appears in the `*Process List*' that prompt pops up, and a
`kill-buffer-query-functions' entry of the user's own still gets its say.

vterm and term.el get this for free and never mention it: their child *is* an
Emacs process, and `make-process' leaves the flag t, so both always ask.  eat
has the same three answers under `eat-query-before-killing-running-terminal',
also defaulting to `auto', and drives them the same way -- clearing the flag
from its OSC 133 prompt handler and setting it again before a command runs.
Cooked's child is neither vterm's nor eat's: it belongs to the native core, and
the only process object Emacs has for it is the wakeup pipe, which was created
`:noquery' back when it was purely a doorbell.  Nothing was suppressing the
warning; there was simply no process standing for the session for Emacs to warn
about.  The flag hanging off the doorbell rather than the child is the same
substitution `cooked--start' already documents for comint's benefit, and it is
honest in the one way that matters here: the pipe is open for exactly as long as
the child is alive, and `cooked--on-exit' deletes it the moment it is not.

`auto' is safe where the shell says nothing.  It reads `cooked--policy', not a
shell hook, so a session with no OSC 133 integration at all never reaches the
`cooked' policy and is therefore always queried -- the same answer as t.  Going
quiet is something the shell has to ask for, by telling us it is at a prompt."
  :type '(choice (const :tag "Never ask" nil)
                 (const :tag "Ask only when the child owns the keyboard" auto)
                 (const :tag "Always ask while the child is alive" t))
  :group 'cooked)

(defun cooked--query-on-kill-p ()
  "Whether this session should be queried about before it is killed.
See `cooked-confirm-kill'."
  (pcase cooked-confirm-kill
    ('nil nil)
    ('auto (not (cooked--input-state-p)))
    (_ t)))

(defun cooked--sync-query-flag ()
  "Say whether this session minds being killed without a warning.

Called from `cooked--refresh-keymap', because under `auto' the answer is the
policy and a policy change is exactly what that function is told about.  The
flag is read at kill time and cannot be computed then -- `process-list' is all
`save-buffers-kill-emacs' has -- so it has to be kept current instead."
  (when (process-live-p cooked--wake)
    (set-process-query-on-exit-flag cooked--wake (cooked--query-on-kill-p))))

(defun cooked--start (argv &optional directory extra-env)
  "Spawn ARGV in the current buffer, optionally in DIRECTORY.
EXTRA-ENV is an alist prepended to the child\\='s environment.

A remote DIRECTORY is refused and the child starts in the home directory
instead.  The pty is always a local one, so a TRAMP name here is not somewhere
the child can be put: it reaches the module verbatim, the `chdir\\=' fails, and
`child_exec\\=' in src/pty.rs is right to treat that as fatal rather than exec
from wherever Emacs happened to be.  What that left was a buffer reading
\"[exited 127]\" and nothing else, which is the correct behaviour reported as an
unexplained number -- and it is reached by nothing more unusual than
\\[cooked] from a buffer visiting a remote file.

`cooked--local-name\\=' is what refuses it, rather than a `file-remote-p\\=' of
our own, because that is the chokepoint every other path from a string to the
filesystem already goes through, and its message is the one the user is told.

Only when DIRECTORY is non-nil: nil keeps its own meaning of leaving the child
wherever Emacs is, and is not a request to be second-guessed."
  (cooked--load-module)
  (cooked--reset-images)
  ;; A layer that failed against the last child's output is worth hearing about
  ;; again for this one; see `cooked--seams-reported'.
  (setq cooked--seams-reported nil)
  (pcase-let ((`(,rows . ,cols) (cooked--window-size)))
    (setq cooked--rows rows cooked--cols cols
          ;; Matches `cooked--sync-size' having already run once at exactly
          ;; this size: nothing has diverged from it yet, so its very next
          ;; invocation -- on the first real window or font event -- must not
          ;; read a stale `nil' here and mistake "never synced" for "resized",
          ;; forcing a redraw against native-core state nothing has spawned
          ;; a window for yet.
          cooked--last-size (cons rows cols)))
  (cooked--with-child-edit
    (erase-buffer)
    (insert (make-string cooked--rows ?\n))
    (setq cooked--screen-start (copy-marker (point-min) nil)))
  ;; The previous session's entries describe text `erase-buffer' has just taken
  ;; away, and the anchor that vouches for them cannot notice: a buffer being
  ;; reused for a second session puts the new prompt at exactly the position the
  ;; old one held, which is the one thing `cooked--check-undo-anchor' reads as
  ;; nothing having moved.  Cleared here rather than inside the macro above, for
  ;; the reason given there.
  (setq cooked--undo-anchor nil)
  (cooked--discard-undo)
  ;; Attached to the buffer, unlike a plain doorbell would be: `get-buffer-process'
  ;; answering is the whole of what comint needs from a process, since every one of
  ;; its commands works through `process-mark' and none of them through the process
  ;; itself.  `shell-maker' buys the same thing by spawning a `hexl' it never speaks
  ;; to; we already had a process object and were only withholding it.
  ;;
  ;; Nothing may ever write here: the read end belongs to Rust, and a stray
  ;; `process-send-string' would land in the wakeup channel.  `comint-input-sender'
  ;; is overridden in `cooked-mode' so comint's own submission path cannot.  The
  ;; sentinel is silenced because the default one inserts "Process ... finished"
  ;; into the buffer it is attached to, which is now the terminal.
  (setq cooked--wake
        (make-pipe-process :name (format "cooked-wake<%s>" (buffer-name))
                           :buffer (current-buffer)
                           ;; This pipe is also the session's stand-in for the
                           ;; "active processes exist" warning, and whether it
                           ;; wants one depends on what the child is doing, so
                           ;; the flag is kept current by
                           ;; `cooked--sync-query-flag' rather than fixed here.
                           :noquery t
                           :sentinel #'ignore
                           :filter (let ((buffer (current-buffer)))
                                     (lambda (_proc _string) (cooked--on-wake buffer)))))
  (set-marker-insertion-type (process-mark cooked--wake) nil)
  (cooked--sync-query-flag)
  (cooked--set-input-mark nil)
  (setq cooked--session
        (cooked--spawn argv (cooked--child-environment extra-env) cooked--rows cooked--cols cooked--wake
                      (when directory
                        (expand-file-name (or (cooked--local-name directory) "~")))
                      (round (* 1000 cooked-min-redisplay-interval))
                      cooked-backlog-limit))
  cooked--session)

(defun cooked--child-environment (&optional extra)
  "Environment alist for the child, with EXTRA taking precedence.

Every name this function sets is also stripped from the inherited environment,
so a value from whatever terminal started Emacs cannot shadow ours.  That is the
whole point of the exclusion list below: an inherited TERM_PROGRAM=iTerm.app
sitting beside our own TERM is worse than no answer at all, because the programs
that branch on it would take a path for a terminal that is not driving this pty.

TERMINFO_DIRS is the exception: it is *extended* rather than replaced, because
it is a search list and a user may have their own entries on it.  See
`cooked--terminfo-search-path\='."
  (let* ((term (cooked--terminfo))
         ;; Only alongside our own entry: if we fell back to xterm-256color there is
         ;; nothing of ours to find and so nothing to say.
         (database (and (equal term cooked-term-name)
                        (cooked--terminfo-directory term))))
    `(,@extra
      ("TERM" . ,term)
      ("COLORTERM" . "truecolor")
      ;; Identity, not capability -- what we can do is in the terminfo entry and
      ;; COLORTERM.  Nothing keys off "cooked" yet, so consumers fall through to
      ;; their defaults, which is the correct behaviour for a terminal they have
      ;; never heard of.  Set as a pair: they are read as one.
      ("TERM_PROGRAM" . "cooked")
      ("TERM_PROGRAM_VERSION" . ,(cooked-version))
      ,@(and database `(("TERMINFO_DIRS" . ,(cooked--terminfo-search-path database))))
      ;; LINES and COLUMNS are deliberately *not* set. ncurses treats them as
      ;; authoritative over the tty's own size (`use_env'), so a program started with
      ;; them pinned keeps its original geometry for life and ignores every SIGWINCH.
      ;; The winsize is the single source of truth; shells re-export these themselves.
      ,@(cl-loop for entry in process-environment
                 for split = (string-search "=" entry)
                 when (and split (not (member (substring entry 0 split)
                                              '("TERM" "COLORTERM" "TERM_PROGRAM"
                                                "TERM_PROGRAM_VERSION" "LINES"
                                                "COLUMNS" "TERMINFO_DIRS"))))
                 collect (cons (substring entry 0 split) (substring entry (1+ split)))))))


(defvar cooked--resyncing nil
  "Whether a resync is already under way, so a failing one cannot loop.
Bound for the dynamic extent of the repair rather than kept per buffer: it
answers \"am I inside one right now\", which is not something a buffer holds.")

(defvar-local cooked--draining nil
  "Whether a drain is already running in this buffer.
See `cooked--drain-and-apply', which is where re-entry is folded away.")

(defvar-local cooked--drain-pending nil
  "Whether a drain was asked for while one was already running.")

(defun cooked--drain-and-apply ()
  "Apply whatever the native core has accumulated since the last drain.

Re-entrant calls are folded into the drain already under way rather than
nested inside it.  `cooked--apply' decides `follow', `wandered' and the
windows that count as following *before* it rewrites the screen, and then
calls three things that can refresh the keymap -- `cooked--set-alt',
`cooked--set-mode' and `cooked--handle-event' for an OSC 133 mark.  A
refresh that lifts a freeze asks for a catch-up drain, so nesting there would
leave the outer `cooked--apply' finishing against an update, and a set of
captured positions, two drains stale.

Nothing is dropped by refusing: the request is remembered and honoured once
the outer drain has returned, which is also the only point at which draining
again is safe."
  (if cooked--draining
      (setq cooked--drain-pending t)
    ;; `unwind-protect' and `setq' rather than `let': `cooked--apply' runs the
    ;; layers' own hooks, which may change the current buffer, and a `let' on a
    ;; buffer-local restores into whichever buffer is current when the binding
    ;; unwinds.
    ;;
    ;; The invariant the captured buffer keeps: *the flags are cleared in the
    ;; buffer they were set in, whatever the current buffer has become by then*.
    ;; A bare `setq' has the same defect as `let' from the other direction -- it
    ;; writes wherever the buffer pointer happens to point *now* -- so a callee
    ;; that switched buffers without restoring would clear the flag in the wrong
    ;; buffer and leave this one draining forever, folding every later wake into
    ;; a drain that has already returned.  That is a frozen terminal no refresh
    ;; can mend, since `cooked-refresh' drains too.  Callees are meant not to
    ;; wander (see `cooked--handle-osc'), but this is the drain's own guarantee
    ;; and does not depend on their good behaviour.
    (let ((buffer (current-buffer)))
      (unwind-protect
          (progn
            (setq cooked--draining t
                  cooked--drain-pending nil)
            (cooked--apply (cooked--drain cooked--session cooked-rejoin-wrapped-lines))
            ;; Bounded in practice: the pending flag is set by a freeze lifting,
            ;; and a freeze that has lifted does not lift again.
            (while (and cooked--drain-pending cooked--session)
              (setq cooked--drain-pending nil)
              (cooked--apply (cooked--drain cooked--session cooked-rejoin-wrapped-lines))))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (setq cooked--draining nil
                  cooked--drain-pending nil)
            ;; Also in the cleanup, though `cooked--apply' ends with it: the drain
            ;; has assertions in it (`cooked--check-seam', `cooked--guard-row-width')
            ;; and a signal out of one leaves the screen half-rewritten with the
            ;; input line moved and the anchor still naming where it used to be.
            ;; Idempotent on the ordinary path, the anchor already matching by then
            ;; -- and inside the `with-current-buffer' for the same reason as the
            ;; flags: it is this buffer's anchor it exists to check.
            (cooked--check-undo-anchor)))))))

(defun cooked--on-wake (buffer)
  "Drain BUFFER's session and apply what changed.

An error here is otherwise invisible: Emacs swallows `process-filter' errors,
and
the symptom reaches the user as a buffer that stopped updating or a point that
jumped somewhere absurd.  Name it, then repair it — a drain that signalled
part-way through leaves the screen region disagreeing with the emulator's grid,
and no later delta mends that, because a delta only says what changed.

`cooked--resyncing' guards the repair rather than the failure: a resync that
itself fails must report and stop, not recurse a redisplay error into a loop of
them.  It is cleared once a resync completes, so this is once per failure and
not once per session.

Skipped entirely while `cooked--frozen-p': the native core keeps the
authoritative grid state regardless of whether Lisp ever asks for it, so
nothing is lost by deferring — `cooked--refresh-keymap' catches the buffer up
with one more call to `cooked--drain-and-apply' the moment the freeze lifts.
Note that `cooked--frozen-p' is false for a buffer whose window is not the
selected one, so leaving a frozen buffer resumes it rather than stranding it."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and cooked--session (not (cooked--frozen-p)))
        (if cooked-debug
            (cooked--drain-and-apply)
          (condition-case err
              (cooked--drain-and-apply)
            (error
             (message "cooked: redisplay failed: %S (point %s, cursor %S, screen-start %s)%s"
                      err (point) cooked--cursor
                      (cooked--screen-start-position)
                      (if cooked--resyncing "" "; resyncing"))
             (unless cooked--resyncing
               (let ((cooked--resyncing t))
                 (condition-case again
                     (cooked-refresh)
                   (error (message "cooked: resync failed too: %S" again))))))))))))

(defcustom cooked-clear-selection-on-output t
  "Whether output that rewrites the selected text takes the selection with it.

A region is a claim about particular text, and the child rewriting that text
makes the claim into a lie -- an invisible one, because the highlight stays.
`cooked--render-rows\=' deletes and reinserts each damaged row whole, so a mark
inside one collapses to that row\='s start and the region visibly warps under
live output; the drain re-pins point (see `cooked--apply\='), and nothing ever
did the same for the mark.  Every xterm-family terminal drops a selection whose
cells are overwritten, for the reason this does.

Only a mark in the live screen.  The scrollback is text the child has finished
with and can no longer reach, so a region up there still means what it did when
it was drawn.

nil keeps the mark wherever it is.  Defensible if you never select the live
screen; if you do, the region you are left holding is not the one you drew."
  :type 'boolean
  :group 'cooked)

;; Read and called only behind a guard that evil is loaded and on, and named
;; here so the byte-compiler reads them as the deliberate references they are;
;; see `cooked--deactivate-mark' and, for the same arrangement, `cooked--discard-undo'.
(declare-function evil-visual-state-p "evil-states")
(declare-function evil-exit-visual-state "evil-states")

(defun cooked--deactivate-mark ()
  "Give up the region, taking evil's visual state with it.

`deactivate-mark\=' on its own is only half of that under evil, and which half
depends on where it was called from.  What keeps evil in step is
`evil-visual-deactivate-hook\=', which decides from `this-command\=': from a
command there is one to decide with -- a mouse report is sent under
`cooked-mouse-event\=', which carries no `:keep-visual\=' property, so evil exits
visual state and the two agree.  From a drain there is not.  A process filter
runs between commands, `this-command\=' is whatever the user last ran or nothing
at all, and the hook falls through both of its arms: the mark goes, evil stays
in visual state, and the next \\`v\=' *leaves* visual state rather than entering
it -- the failure `cooked-evil--command-range\=' documents at length, arrived at
from the other side.

So ask evil outright instead of through a hook whose answer depends on how we
got here.  `evil-exit-visual-state\=' deactivates the mark itself on its way
back to the state visual state was entered from, and does it the same way
whether or not a command is running.

Silent when there is no region: every caller is somewhere the region is
incidental, so having none is the ordinary case rather than a failure."
  (cond ((and (bound-and-true-p evil-local-mode)
              (fboundp 'evil-visual-state-p)
              (evil-visual-state-p))
         (evil-exit-visual-state))
        (mark-active (deactivate-mark))))

(defun cooked--following-windows ()
  "Other windows on this buffer whose point should track the child's cursor.

The selected window's point *is* the buffer's point for as long as it stays
selected — Emacs keeps the two in sync on its own, which is what `follow' and
`wandered' below ride on.  No such thing happens for any other window
showing the same buffer: its `window-point' is a value Emacs stores and
redisplays from independently, touched only by `set-window-point', so a
second window on a busy cooked buffer would otherwise freeze wherever it
last happened to be pointed, deaf to every later drain.

A window's own point, not the buffer's, decides whether it is still
following, mirroring `follow' one level down: scrolling that window with the
wheel or a scrollbar does not move its point, so such a window is left alone
here for the same reason `follow' would leave the buffer's point alone for
the same case — it reads as the user choosing to look elsewhere, not as a
window that fell behind."
  (when-let* ((start (cooked--screen-start-position)))
    (seq-filter (lambda (w) (>= (window-point w) start))
                (delq (selected-window) (get-buffer-window-list nil nil t)))))

(defun cooked--install-resources (update)
  "Record the images and links UPDATE's rows refer to by id.

Before any rendering: this is the drain's third category -- neither a level
redisplay reads nor an occurrence to react to, but a resource the rows depend
on.  Touches no buffer text, so it needs no `inhibit-read-only'."
  (cooked--install-images (plist-get update :images))
  (cooked--install-links (plist-get update :links)))

(cl-defstruct (cooked-viewport (:constructor cooked--viewport-make) (:copier nil))
  "What the view looked like before a drain rewrote the screen under it.

Every field has to be read before the render, because afterwards the thing it
describes is gone: the pending input has been lifted out, the rows point and the
mark named have been deleted and reinserted, and which windows counted as
following has already been decided by the deletion dragging their point along.

Restored by `cooked--restore-viewport'."
  (editing nil :documentation "\
Point's offset within the pending input, or nil if it was not in there.

An offset rather than a position: the input is taken out and put back verbatim
around the child's cursor on every drain, so a buffer position cannot survive
that but an offset into the text can.  Without it, anything that drains while
the user is editing mid-line -- a background job printing a line, a completion
reply -- yanks them to the end of what they were typing.")
  (follow nil :documentation "\
Whether to track the child's cursor, or leave point where the user put it.

Asked of the mode and of where point is, not by comparing point against the
cursor: output arriving in chunks lets the cursor overtake point for a single
drain, which strands point at column 0 for every drain after it.")
  (wandered nil :documentation "\
The screen cell point sat on, when it had wandered off the cursor.

A redraw deletes and reinserts whole rows, so a buffer position would be dragged
to the start of whatever was rebuilt under it.  The cell survives that.")
  (stale-mark nil :documentation "\
Whether an active mark named screen text this drain is about to rewrite.

Unlike point the mark cannot be re-found afterwards -- there is no cell to look
it up by, only a claim about text that is about to stop being that text -- so
the question is asked while it still has an answer.  See
`cooked-clear-selection-on-output'.")
  (others nil :documentation "\
The other windows on this buffer that were following the child's cursor."))

(defun cooked--capture-viewport ()
  "Snapshot the view, before the render invalidates every part of it."
  (cooked--viewport-make
   :editing (when-let* ((region (cooked--input-region))
                        ((<= (car region) (point) (cdr region))))
              (- (point) (car region)))
   :follow (and (cooked--follow-p)
                (>= (point) (cooked--screen-start-position)))
   :wandered (and cooked--wandered (cooked--screen-cell))
   :stale-mark (and cooked-clear-selection-on-output
                    mark-active (mark)
                    (>= (mark) (cooked--screen-start-position)))
   :others (cooked--following-windows)))

(defun cooked--apply-levels (update)
  "Adopt UPDATE's levels: the state as of this drain, for redisplay to read."
  (setq cooked--cursor (cooked--cursor-decode (plist-get update :cursor))
        ;; Before `cooked--fit-screen', which is shaped by it.
        cooked--grid (cooked--grid-make :height (plist-get update :height)
                                        :used (plist-get update :used)
                                        :head (plist-get update :head))
        cooked--app-cursor (plist-get update :app-cursor)
        cooked--keys (plist-get update :keys)
        cooked--exit (plist-get update :exit))
  (cooked--set-alt (plist-get update :alt))
  (cooked--set-mode (plist-get update :mode)))

(defun cooked--place-point (viewport)
  "Put point where VIEWPORT says it belongs, now that the render is done.

`editing' outranks `follow' rather than sharing an arm with it: point inside the
pending input is a claim about the line being typed, and the end of that line is
only the right answer when point was there already.  Staying put outranks both
once the user has taken the keyboard back -- the child keeps redrawing under
them, and being yanked to its cursor mid-motion is what this exists to stop.
The ghost keeps the way back visible; `cooked--snap-to-cursor' takes it."
  (let ((editing (cooked-viewport-editing viewport)))
    (cond ((cooked-viewport-wandered viewport)
           (cooked--goto-screen-cell (cooked-viewport-wandered viewport)))
          ;; Clamped for the drain that ends the prompt, where
          ;; `cooked--restore-pending-input' declined and left no region for the
          ;; offset to be an offset into.
          (editing
           (goto-char (if-let* ((start (cooked--input-start-position)))
                          (min (+ start editing) (cooked--point-after-input))
                        (cooked--point-after-input))))
          ((cooked-viewport-follow viewport)
           (goto-char (cooked--point-after-input))))))

(defun cooked--scroll-windows (viewport)
  "Scroll every window on this buffer to what VIEWPORT and the new grid want.

Explicit rather than left to redisplay, and the honest reason is narrower than
it used to be stated here.  `scroll-conservatively' *is* a guarantee for the
selected window whatever moved its point: `redisplay_window' compares the
window's start against its point and has no idea whether a command or a process
filter did the moving.  What redisplay will not do is move a *non-selected*
window, whose `window-point' nothing here has touched, and what it will not
decide is the policy question -- whether the last line belongs at the foot of
the window with nothing below it, which is what `comint-scroll-show-maximum-
output' gates comint's own recentring on.

The selected window belongs in none of these lists unless it is actually showing
this buffer: output can arrive while the user's focus is elsewhere, and
scrolling that window would be a bug rather than a courtesy."
  (let ((here (and (eq (window-buffer (selected-window)) (current-buffer))
                   (list (selected-window))))
        (others (cooked-viewport-others viewport)))
    (if cooked--alt
        (cooked--pin-alt-screen (append here others))
      (cooked--scroll-transcript viewport here others))))

(defun cooked--pin-alt-screen (windows)
  "Put the alternate screen back at the top of each of WINDOWS.

A resize reaches the buffer in two steps: the window changes height the instant
Emacs notices (`cooked--sync-size'), while the buffer is not re-fitted to match
until the next drain's `cooked--fit-screen'.  Ordinary redisplay fills that gap
by pushing `window-start' down to keep point on screen, and nothing corrected
that once the buffer caught up -- so the window kept a scroll a now-irrelevant
redisplay had chosen, clipping the top of the screen.

Unconditional, and the restriction `cooked--apply-alt-pin' re-applies is what
makes that safe: every window here shows the screen region and nothing else, so
the region's top is the only start any of them can hold.  NOFORCE stays, because
forcing would drag point along with it."
  (let ((top (cooked--screen-start-position)))
    (cooked--dolist-windows w windows
      (set-window-start w top t))))

(defun cooked--pin-transcript-bottom (windows &optional pos)
  "Follow POS, defaulting to `point-max\=', with the bottom row of each of WINDOWS.

Factored out of `cooked--scroll-transcript\=' because a drain is not the only
thing that can grow the buffer\='s true end.  `cooked--on-exit\=' does too,
appending the \"[exited N]\=\" line from outside `cooked--scroll-windows\='
entirely, and it needs exactly this rather than a second copy of it.

Computed and NOFORCE, rather than the `recenter\=' this used to be.
`recenter\=' sets a forced start that redisplay then overrules through
`make-cursor-line-fully-visible\=', so the window landed where neither of them
had chosen; and it counts every screen line as the default font\='s height, so a
row taller than that -- an image slice, a Nerd Font prompt separator -- had to
be paid back afterwards in whole lines of scroll.  A NOFORCE start is a
suggestion redisplay may settle against instead, and the pixels are
`make-cursor-line-fully-visible\='s business, which is where they were always
handled correctly.  No `with-selected-window\=' either: nothing here needs the
window selected, and `select-window\=' is advised -- by `evil\=', to refresh its
cursor -- so a pair of them per window per drain was arbitrary code running in
the middle of a render.

Monotone, which is what stops this jittering.  The follow direction is taken
whenever the tail has grown, and the equality is the common case: a steady
stream whose tail is the same length leaves TOP exactly where it already is and
this writes nothing at all, at a drain rate whose floor is
`cooked-min-redisplay-interval\='.  The shrink direction is the one thing the
two-way pin was buying -- `comint-scroll-show-maximum-output\='s actual
semantics, no blank space below the last line -- and is taken only when the
*last* redisplay had the buffer\='s end on screen, so it fires when the grid
really has fewer used rows than before rather than every time
`vertical-motion\='s whole-line count disagrees with what redisplay laid out in
pixels.  That disagreement is permanent on a window whose rows differ in height,
and correcting for it once per drain is the oscillation itself."
  (let ((target (or pos (point-max))))
    (cooked--dolist-windows w windows
      (set-window-point w target)
      (let ((top (save-excursion
                   (goto-char target)
                   (vertical-motion (- (1- (window-body-height w))) w)
                   (point))))
        (when (or (> top (window-start w))
                  (and (< top (window-start w))
                       (let ((end (window-end w)))
                         (and end (>= end (point-max))))))
          (set-window-start w top t))))))

(defun cooked--scroll-transcript (viewport here others)
  "Scroll the transcript in HERE and OTHERS as VIEWPORT asks."
  (let* ((target (cooked--point-after-input))
         ;; Slack of one, because whether the last rendered row carries a
         ;; terminating newline depends on how the region was last shaped: rows
         ;; are made to exist by the newline ending the row above them, so the
         ;; bottom one has one only when `cooked--fit-screen' trimmed something
         ;; below it.  So this can flip from drain to drain, which used to mean
         ;; the pin alternated with whatever redisplay chose for itself.  It no
         ;; longer costs anything: a drain that declines to pin leaves point at
         ;; the buffer's end under `scroll-conservatively' 101 and
         ;; `scroll-margin' 0, and the minimal scroll redisplay makes to keep it
         ;; visible is the same start `cooked--pin-transcript-bottom' computes.
         (at-end (>= target (1- (point-max)))))
    ;; Only while the view is following at all: suspending exists to stop the
    ;; child's output moving what is being read, and a second window on the same
    ;; buffer is being read on the same terms.
    (when (cooked--follow-p)
      (cooked--dolist-windows w others
        (set-window-point w target)))
    (cond
     ;; The child cleared the display.  Its rows were archived rather than
     ;; dropped, so nothing scrolls out of view on its own, and recentring on the
     ;; cursor would leave the transcript filling the window above a blank screen
     ;; -- which is `clear' looking like it did nothing.
     ((and (cooked-viewport-follow viewport) cooked--pin-screen-top)
      (let ((top (cooked--screen-start-position)))
        (cooked--dolist-windows w (append here others)
          (set-window-start w top t))))
     ((and (cooked-viewport-follow viewport) at-end)
      (cooked--pin-transcript-bottom (append here others) target)))))

(defun cooked--apply (update)
  "Apply UPDATE, the plist returned by `cooked--drain'.

The order below is the whole of it, and every step depends on the one above:
resources before the rows that name them, the viewport before the render that
invalidates it, the render before the marks resolved against the text it wrote,
and the region shaped before anything measures it."
  (cooked--install-resources update)
  ;; `let*', emphatically: these initialisers delete and insert, and under plain
  ;; `let' they would run before the two bindings above them took effect -- so a
  ;; protected buffer would abort the redisplay half-done from inside the process
  ;; filter, and lifting the pending input would land in the undo history.  They
  ;; are the pair `cooked--with-child-edit' binds, spelled out because a body this
  ;; long is not worth nesting one level deeper.
  (let* ((inhibit-read-only t)
         (buffer-undo-list t)
         (viewport (cooked--capture-viewport))
         (pending (cooked--take-pending-input))
         ;; Where this drain's scrollback landed, for resolving a `scrolled'
         ;; anchor against.  nil when the drain evicted nothing.
         (batch-start (when-let* ((scrolled (plist-get update :scrolled)))
                        (cooked--render-scrolled scrolled)))
         (rendered (cooked--render-rows (plist-get update :rows)
                                        (plist-get update :alt))))
    (cooked--apply-levels update)
    ;; Cleared before the events, so a drain that both scrolls and then clears
    ;; stays pinned.
    (when batch-start (setq cooked--pin-screen-top nil))
    ;; After both render passes and before the events: a mark's anchor is
    ;; resolved against text that has to be in the buffer before it can be
    ;; pointed at, and a drain that both resizes and carries a fresh mark should
    ;; end with the fresh mark's own anchor.
    (cooked--relocate-marks (plist-get update :marks) batch-start)
    (dolist (event (plist-get update :events))
      (cooked--handle-event event batch-start))
    ;; After both, which is the ordering `cooked-row-rendered-functions' is
    ;; documented against.
    (cooked--notify-rows-rendered rendered)
    (cooked--fit-screen)
    (cooked--pad-to-cursor)
    (when cooked-debug (cooked--check-seam))
    (cooked--restore-pending-input pending)
    (cooked--protect (or (and (cooked--input-state-p) (cooked--input-start-position))
                         (point-max)))
    (cooked--apply-alt-pin)
    ;; Before the point block, not after it: under evil this leaves visual state,
    ;; and evil adjusts point on the way into normal state -- so cooked's own pin
    ;; has to be the last thing to speak about where point ends up.
    (when (cooked-viewport-stale-mark viewport) (cooked--deactivate-mark))
    (cooked--place-point viewport)
    ;; Recorded, not merely left in the buffer: a window not showing this buffer
    ;; has a stale point marker Emacs will restore on the way back, over the top
    ;; of this.  See `cooked--point'.
    (setq cooked--point (point))
    (cooked--scroll-windows viewport)
    ;; After the window block, not before it: see `cooked--sync-cursor-type'.
    (cooked--sync-cursor-type)
    (cooked--update-ghost-cursor)
    (when cooked--exit (cooked--on-exit cooked--exit)))
  ;; Both outside the `let*', and in this order.  The binding above is what kept
  ;; this drain out of the undo history, and a discard has to reach the buffer's
  ;; own list rather than that binding -- which is also why the trim cannot run
  ;; inside: it moves the input line, and the `cooked--check-undo-anchor' it does
  ;; for itself would then update the anchor against a discard that was thrown
  ;; away with the binding, leaving the history vouched for by an anchor nothing
  ;; ever cleared.  See `cooked--with-child-edit'.
  (cooked--trim-scrollback)
  (cooked--check-undo-anchor))

(defun cooked--handle-event (event batch-start)
  "Dispatch a single EVENT from the emulator.

BATCH-START is where this drain's scrollback was inserted, which the semantic
marks need to place their anchors; see `cooked--anchor-position'.

Events are occurrences only.  State the redisplay depends on rides the drain's
own fields instead — `:alt' and the rest — so that nothing arrives twice with
two chances to disagree."
  (pcase event
    (`(bell) (ding))
    (`(osc ,code ,bell . ,parts) (cooked--handle-osc code bell parts))
    (`(reply . ,bytes) (cooked--send-if-live bytes))
    (`(title-stack ,push) (cooked--handle-title-stack push))
    ;; `CSI 3 J', the tail of what `clear' sends.  Honoured unconditionally: it is
    ;; only reachable by something already holding the terminal, every other terminal
    ;; honours it, and it is precisely what the user typed `clear' to get.  The
    ;; command history is not lost with it: that lives in comint's ring, not here.
    (`(erase-scrollback)
     (cooked--discard-scrollback (cooked--screen-start-position)))
    (`(display-cleared) (setq cooked--pin-screen-top t))
    ;; Decoded into a record at the boundary, like the cursor and the grid; see
    ;; `cooked-mouse-state'.  cooked-mouse.el owns it because it is the only
    ;; reader, and re-gates its own keymap on the way through.
    (`(mouse ,enabled ,sgr ,drag ,motion)
     (cooked--set-mouse-state enabled sgr drag motion))
    ((or `(prompt-start ,_ . ,_) `(prompt-continuation ,_ . ,_)
         `(prompt-end ,_ . ,_)
         `(command-start ,_ ,_ . ,_) `(command-end ,_ ,_ . ,_))
     (cooked--handle-semantic event batch-start))
    (_ nil)))

(defcustom cooked-scrollback-lines 10000
  "How many lines of transcript to keep above the live screen, or nil for all.

Rows that scroll off the emulator\='s screen become ordinary buffer text and are
never taken back, so without a cap a session grows for as long as it runs: one
`yes\=', one chatty build, one `tail -f\=' left overnight, and the buffer is the
largest thing in your Emacs.  Every other terminal emulator caps this, and this
is cooked\='s version of `vterm-max-scrollback\=' or `eat-term-scrollback-size\='.

Counted in lines of the buffer above `cooked--screen-start\=', which is not
quite the same as rows the child printed: `cooked-rejoin-wrapped-lines\=' joins
a wrapped row onto the line above, so one long line of output is one line here
however many screen rows it took.  That is the honest unit, being the one the
buffer is actually made of.

Trimming is not free -- it releases images, prunes command records and tells the
emulator its seam moved -- so it happens in batches once the buffer is over the
cap by a margin rather than a line at a time.  A little over the cap is normal
and expected.

nil keeps everything, which is what you want if the session is a transcript you
mean to save, and is a decision to make deliberately."
  :type '(choice (const :tag "Keep everything" nil) natnum)
  :group 'cooked)

(defconst cooked--scrollback-slack 0.1
  "How far over `cooked-scrollback-lines\=' the buffer may go before a trim.

A fraction of the cap.  Trimming on the very first line over would delete on
almost every drain of a flood, and each deletion costs a walk of the text being
cut to find the images in it -- so the buffer is allowed to overshoot and the
cost is paid once for many lines instead of many times for one.")

(defun cooked--trim-scrollback ()
  "Cut the transcript back to `cooked-scrollback-lines\=' if it has outgrown it.

Runs at the end of every drain, and does nothing on all but a few of them: the
line count is only taken once the buffer holds enough characters to have that
many lines at all, and the deletion only happens once it is over the cap by
`cooked--scrollback-slack\='.

Cuts at a line beginning, because `cooked--discard-scrollback\=' hands the
emulator a seam and half a line is not one."
  (save-restriction
    (widen)
    (when-let* ((cap cooked-scrollback-lines)
                (screen (cooked--screen-start-position))
                (threshold (+ cap (max 1 (round (* cap cooked--scrollback-slack)))))
                ;; A line above the screen carries at least its own newline, so
                ;; there cannot be THRESHOLD of them in fewer than THRESHOLD
                ;; characters.  That makes this a sound way to skip the count
                ;; rather than a guess at how wide a line is: the gate this
                ;; replaced asked for `(* cap 40)' characters, which for anything
                ;; narrower than 40 columns never opened, and the cap it is here
                ;; to enforce simply did not hold -- a flood of `line1234' sat at
                ;; five times the cap and was never trimmed.
                ((>= (- screen (point-min)) threshold))
                ;; `line-number-at-pos' walks from `point-min', which is affordable
                ;; precisely because the cap bounds what it walks: the buffer this
                ;; runs against is a capped one, and an uncapped session never
                ;; reaches here at all.  Measured at 15us for a cap of 1000 against
                ;; the 8ms redisplay floor, and a bounded `forward-line' walk back
                ;; from the screen -- O(cap) rather than O(buffer) -- was tried and
                ;; is five times slower, this being a C-level scan for newlines.
                ((> (line-number-at-pos screen t) threshold)))
      (save-excursion
        (goto-char screen)
        (forward-line (- cap))
        (when (> (point) (point-min))
          (cooked--discard-scrollback (point)))))))

(defun cooked--discard-scrollback (end)
  "Delete scrollback from `point-min' up to END, and tell the emulator.

The only sanctioned way to delete above `cooked--screen-start', and worth
routing every future caller — a scrollback cap, a `clear' handler — through
rather than open-coding.  The scrollback is the one piece of state the two ends
co-own: Emacs holds the text, while the emulator holds a count of how much of
its top row's line already left for Emacs, so that a rewrap resumes that line
where the buffer wraps it.  A wrapped line can span the boundary being cut, so
a deletion that does not say so leaves the emulator continuing a line that is
no longer there — and the desync is silent until the next resize.

Widens first, so it still clears while a full-screen program has the buffer
narrowed to the alt screen — where `point-min' is the top of the screen and
this would otherwise quietly do nothing."
  ;; Before the deletion, while the positions still mean something.  A record whose
  ;; whole region is in the text being cut would survive as an empty region sitting
  ;; at the cut -- indistinguishable from a command that genuinely printed nothing,
  ;; which is exactly what the records exist to describe -- and `\[cooked-previous-command]'
  ;; and folding walk them.
  (setq cooked--commands
        (seq-filter (lambda (command) (> (cooked--command-end-position command) end))
                    cooked--commands))
  ;; Same shape, one line down: an image belongs to the rows displaying it, so
  ;; the ids in the text about to go are the candidates and the walk afterwards
  ;; decides which of them this was the last of.
  (let (images)
    (save-restriction
      (widen)
      (setq images (cooked--release-images (point-min) end))
      (cooked--with-child-edit
        (delete-region (point-min) end)))
    (cooked--collect-images images))
  ;; Everything below just moved up by the length of what went.
  (cooked--check-undo-anchor)
  (when cooked--session
    (cooked--forget-history cooked--session)
    ;; `cooked--grid' is a snapshot of the last drain, and this is the one thing that
    ;; changes the emulator's seam without one.  Left stale it describes a head that was
    ;; just deleted, which `cooked--check-seam' would rightly call a desync — and which
    ;; anything else reading the seam before the next drain would believe.
    (setf (cooked-grid-head cooked--grid) 0)))

(defun cooked--discard-scrollback-region (beg end)
  "Delete scrollback between BEG and END, telling the emulator only if it must.

The narrower sibling of `cooked--discard-scrollback\=', for deleting one
command\='s output out of the middle rather than everything above a point.

What the two ends co-own is exactly one number: how much of the emulator\='s top
row\='s line has already left for Emacs.  A cut that finishes short of
`cooked--screen-start\=' cannot change it -- the text row 0 continues is still
there, still ending where it did -- so it needs no bookkeeping at all, and
saying so is what makes deleting scrolled-off output possible.  A cut that
reaches the seam does remove that head, and then this owes the emulator the same
news `cooked--discard-scrollback\=' gives it."
  (when-let* ((screen (cooked--screen-start-position))
              ((< beg end)))
    (let ((end (min end screen)))
      (when (< beg end)
        (let ((at-seam (= end screen))
              images)
          (save-restriction
            (widen)
            (setq images (cooked--release-images beg end))
            (cooked--with-child-edit
              (delete-region beg end)))
          (cooked--collect-images images)
          (cooked--check-undo-anchor)
          (when (and at-seam cooked--session)
            (cooked--forget-history cooked--session)
            (setf (cooked-grid-head cooked--grid) 0)))))))

(defun cooked-clear-scrollback ()
  "Delete everything above the current prompt.

comint's \\[cooked-clear-scrollback] read literally, and the seam between the emulator's grid
and Emacs\=' scrollback is not the user's business: whether what is above the
prompt has scrolled off the grid yet or is still on it, it goes.  Scrollback
alone was the old behaviour and looked inert at exactly the moment it is reached
for -- a few commands into a session nothing has scrolled off at all, and every
line on screen is a row the emulator still holds.

Each side is asked for its own half.  `cooked--clear-to-prompt\=' removes the
rows, because rows have one owner and only the emulator knows which of them are
above the prompt; the scrollback is buffer text, so Emacs deletes that itself;
and the drain repaints what moved -- the shape of `cooked-delete-output\='.

The prompt line and anything typed at it stay, and end up at the top.  comint
deletes its prompt because there it is only text; here it is a row the shell is
still drawing on, and taking it would corrupt a redisplay cooked cannot repair.

On the alternate screen the grid belongs to a running program rather than to a
transcript, so only the scrollback goes -- see `cooked--clear-to-prompt\='."
  (interactive)
  (when cooked--session
    (cooked--clear-to-prompt cooked--session))
  (cooked--discard-scrollback (cooked--screen-start-position))
  (when cooked--session
    (cooked--drain-and-apply)))

(defun cooked-refresh ()
  "Rebuild the live screen from the emulator.

The way back from a redisplay that failed part-way.  An ordinary drain only
reports what changed since the last one, so it cannot repair a buffer holding
some rows of a drain that signalled halfway through applying them — the screen
region and the emulator's grid simply stay out of step, and every later delta is
applied on top of the disagreement.  This throws the screen region away and asks
the native core to re-send all of it.

The scrollback above is untouched, and so is the emulator's carry count with it:
only the region below `cooked--screen-start' is rebuilt."
  (interactive)
  (when cooked--session
    (save-restriction
      (widen)
      (cooked--with-child-edit
        (cooked--release-alt-pin)
        (delete-region (cooked--screen-start-position) (point-max))
        ;; They pointed into the text just deleted; `cooked--restore-pending-input'
        ;; puts them back at the cursor on the drain below.
        (cooked--clear-input-region)))
    ;; Here rather than left to the drain below, which would see the rebuilt
    ;; input line start where the old one did and conclude that nothing moved --
    ;; while every entry in the history was recorded against text this has just
    ;; deleted and the child is about to re-send.  Outside the macro, for the
    ;; reason given there.
    (cooked--check-undo-anchor)
    (cooked--redraw cooked--session)
    (cooked--drain-and-apply)))


;;;; Entry points

;; Here rather than in cooked-mode.el, where the rest of the interaction lives,
;; because this is the file an installation names: `package.el' autoloads from it
;; and a `:load-path' install autoloads `cooked' from "cooked".  An autoload that
;; forwards to a second file does not chain -- Emacs signals rather than following
;; it -- so the commands themselves have to be reachable from here, and they pull
;; the interaction layer in when first called.

(declare-function cooked--display "cooked-mode")
(declare-function cooked--start-session "cooked-mode")
(declare-function cooked--live-buffers "cooked-mode")

(defcustom cooked-display-action '(display-buffer-same-window
                                   display-buffer-pop-up-window)
  "Action `\\[cooked]' passes to `pop-to-buffer\='.

The selected window first, the way `vterm\=' and `eat\=' do it: a terminal is
usually what you want to be looking at, whereas the fallback `display-buffer\='
uses -- reuse a window, else split -- would put it beside the buffer you
invoked it from as often as not.  Splitting is still the second choice, for
when the selected window will not take it (a dedicated or side window), and
`\\[cooked-other-window]\=' remains the way to ask for the split on purpose.

Here rather than in cooked-mode.el with the other session options, because
every command that reads it is here or in cooked-project.el, and each reads it
as an *argument* -- evaluated before the callee\='s `require\=' of cooked-mode
could have run.  Defined beside its readers, an autoloaded `\\[cooked]\=' in an
Emacs that has never loaded the interaction layer finds a value rather than a
void variable."
  :type 'sexp :group 'cooked)

(defconst cooked-other-window-action '(display-buffer-pop-up-window)
  "Display action every `-other-window\=' command in cooked passes.

A constant rather than the literal written out at each of them: there are three
pairs of commands whose two halves differ in nothing else -- here, and the two
in cooked-project.el -- so the literal was the only thing saying they agree,
three times over.  Deliberately not a `defcustom\=': the customisable choice is
`cooked-display-action\=', and a command whose whole name is `other-window\='
has already been told what to do.")

(defun cooked--open-session (new command action)
  "Display a session using ACTION, starting one unless a live one may be reused.

The body `cooked\=' and `cooked-other-window\=' share; NEW and COMMAND mean what
they do there.  cooked-project.el has its own, which differs in looking for a
session already rooted at a particular directory rather than for any at all."
  (require 'cooked-mode)
  (cooked--display (or (unless new (car (cooked--live-buffers)))
                       (cooked--start-session command))
                   action))

;;;###autoload
(defun cooked (&optional new command)
  "Switch to a terminal session, starting one if needed.

With a prefix argument, or NEW non-nil, always start another session rather than
reusing a live one.  COMMAND overrides `cooked-shell'."
  (interactive "P")
  (cooked--open-session new command cooked-display-action))

;;;###autoload
(defun cooked-other-window (&optional new command)
  "Like `cooked', but display the session in another window.

NEW and COMMAND mean what they do there."
  (interactive "P")
  (cooked--open-session new command cooked-other-window-action))

(provide 'cooked)
;;; cooked.el ends here
