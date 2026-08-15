;;; cooked-module.el --- Loading the native core, and the terminfo it needs -*- lexical-binding: t; -*-

;;; Commentary:

;; Everything about getting cooked\='s two halves onto the same machine: finding the
;; native core, building it when the checkout is newer than the artifact, noticing
;; when a running Emacs is holding a core older than the Lisp that calls it, and
;; installing the terminfo entry the child is told about through TERM.
;;
;; None of it is about terminals.  It sat in `cooked.el\=' between the wire protocol
;; and the renderer, which is where it was first written rather than where it
;; belongs: nothing in the drain path calls any of it, and nothing here knows what a
;; grid or a buffer is.  Its only dependency is `cooked--root\=', which is why this
;; can sit directly on `cooked-util.el\=' and below everything else.
;;
;; The one thing to understand before changing `cooked--build-module\=': installing
;; by rename rather than by writing over the loaded file is load-bearing, not
;; tidiness.  See the Makefile\='s `module\=' target, which states the same rule from
;; the other side -- an in-place rewrite of a mapped .so is a SIGBUS that takes the
;; editor down with no core and nothing in the journal.

;;; Code:

(require 'cooked-util)

;; Provided by the native core, which this file is what loads.
(declare-function cooked--core-version "ext:cooked-core")

(defcustom cooked-term-name "cooked-256color"
  "Value of TERM for the child, or nil to present as xterm-256color.

Shipping an entry is the honest option — it declares direct colour, which
xterm-256color does not, and withholds the capabilities we ignore — and it is
what alacritty, wezterm, foot and Emacs' own `term.el' all do.  The cost is
remote hosts that have never heard of it; see `cooked-install-terminfo-remote'.
Usually nothing is installed at all: the compiled entry ships beside the source
and is handed to the child in TERMINFO, which asks nothing of the machine.
Where that is not understood the entry is compiled under ~/.terminfo, needing
no root, and we fall back to xterm-256color if even that is not possible.
`cooked-install-terminfo\=' puts it on disk deliberately, for the boundaries an
environment does not cross."
  :type '(choice (const :tag "Present as xterm-256color" nil) string)
  :group 'cooked)

(defun cooked--terminfo-source ()
  "The terminfo source we compile from."
  (expand-file-name "terminfo/cooked.ti" (cooked--root)))

(defun cooked--terminfo-entry (database name)
  "The compiled file for NAME in DATABASE, or nil.

By wildcard rather than by path: ncurses is built with the subdirectory named
either for the first letter of the entry or for its hex code, and which one a
database uses is a property of the `tic\=' that wrote it.  Looking for the file
sidesteps having to know, which matters most for the copy we ship -- it carries
both spellings, because it was written on somebody else\='s machine."
  (car (file-expand-wildcards (expand-file-name (concat "*/" name) database))))

(defun cooked--terminfo-usable-p (database name)
  "Whether DATABASE describes NAME, from a compile no older than the source.

Staleness is the same hazard `cooked--module-stale-p\=' guards, arrived at the
same way: edit terminfo/cooked.ti, forget to rebuild, and every child is handed
a description of a terminal this is no longer.  Nothing downstream can catch it
-- a capability that is merely wrong reads as the child choosing not to use it
-- so it is caught here, where the two files can still be compared."
  (when-let* ((entry (cooked--terminfo-entry database name))
              (source (cooked--terminfo-source)))
    (or (not (file-exists-p source))
        (not (time-less-p (file-attribute-modification-time (file-attributes entry))
                          (file-attribute-modification-time (file-attributes source)))))))

(defun cooked--terminfo-install (&optional database)
  "Compile our entry into DATABASE, returning it, or nil on failure.

DATABASE defaults to ours under `user-emacs-directory\='."
  (let ((source (cooked--terminfo-source))
        (database (or database (locate-user-emacs-file "cooked/terminfo"))))
    (and (executable-find "tic")
         (file-exists-p source)
         (progn (make-directory database t) t)
         (eq 0 (call-process "tic" nil nil nil "-x" "-o" database source))
         database)))

(defvar cooked--terminfo-database 'unset
  "Cached answer from `cooked--terminfo-database\=', or `unset\='.

Once per session, because the answer involves a `tic\=' that would otherwise be
attempted afresh for every child on a machine that has no `tic\=' to attempt it
with.")

(defun cooked--terminfo-database ()
  "The database to hand the child in TERMINFO, or nil if we have none.

Ours goes in TERMINFO rather than on TERMINFO_DIRS, and the earlier reluctance
to take that slot does not survive contact with what is actually in it: nothing.
TERMINFO is unset in every environment this has been looked at in, ncurses
falls through to ~/.terminfo and the system database on a miss, so a name we do
not describe still resolves, and a user who really does keep a database there
can put it back on TERMINFO_DIRS themselves.  One variable, one directory, and
no merging.

The order is shipped, then already built, then build.  What ships is a
compiled database in the package -- which asks nothing of the machine, needs no
`tic\=', and is read by every ncurses there has ever been, an entry it cannot
parse being skipped rather than fatal."
  (when (eq cooked--terminfo-database 'unset)
    (setq cooked--terminfo-database
          (let ((shipped (expand-file-name "terminfo/db" (cooked--root)))
                (mine (locate-user-emacs-file "cooked/terminfo")))
            (cond
             ((cooked--terminfo-usable-p shipped cooked-term-name) shipped)
             ((cooked--terminfo-usable-p mine cooked-term-name) mine)
             ((cooked--terminfo-install mine))))))
  cooked--terminfo-database)

(defun cooked--terminfo ()
  "TERM to hand the child, or xterm-256color if we cannot describe ourselves."
  (cond
   ((null cooked-term-name) "xterm-256color")
   ((cooked--terminfo-database) cooked-term-name)
   (t
    (message "cooked: could not install terminfo, presenting as xterm-256color")
    "xterm-256color")))

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
(defun cooked-install-terminfo ()
  "Compile our terminfo entry into ~/.terminfo.

Ordinarily unnecessary, and that is the point of it being a command rather than
something loading cooked does to your home directory: our own database is named
in TERMINFO, so no child of ours has to find one anywhere else.

What cannot read TERMINFO is anything starting from an environment this one did
not reach -- `ssh localhost\=', a tmux server older than this Emacs, a program
under a service manager.  ~/.terminfo is where those look, and this is how the
entry gets there."
  (interactive)
  (if (cooked--terminfo-install (expand-file-name "~/.terminfo"))
      (message "cooked: installed %s under ~/.terminfo" cooked-term-name)
    (user-error "cooked: could not install terminfo (is `tic' on PATH?)")))

;;;###autoload
(defun cooked-install-terminfo-remote (host)
  "Copy our terminfo entry to HOST so remote programs recognise TERM."
  (interactive "sHost: ")
  (let* ((database (or (cooked--terminfo-database)
                       (user-error "cooked: no terminfo entry of our own to copy")))
         ;; Read out of our database rather than out of whatever the ambient
         ;; TERMINFO happens to name, which since we stopped installing into
         ;; ~/.terminfo is usually nothing at all.
         (command (format "TERMINFO=%s infocmp -x %s | ssh %s 'mkdir -p ~/.terminfo && tic -x -o ~/.terminfo -'"
                          (shell-quote-argument database)
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

(provide 'cooked-module)
;;; cooked-module.el ends here
