;;; cooked-module.el --- Loading the native core, and the terminfo it needs -*- lexical-binding: t; -*-

;;; Commentary:

;; Everything about getting cooked\='s two halves onto the same machine: finding the
;; native core, building it when the checkout is newer than the artifact,
;; downloading a prebuilt one where there is no checkout to build from, noticing
;; when a running Emacs is holding a core older than the Lisp that calls it, and
;; installing the terminfo entry the child is told about through TERM.
;;
;; The download is a command and never anything else.  It fetches a tarball
;; carrying the core, the compiled terminfo database and a version sidecar, and it
;; refuses everything that does not hash to a digest compiled into this file --
;; which is the difference between trusting whoever served the bytes and trusting
;; the package that named them.  The sidecar is read *before* `module-load\=', so a
;; core too old for this Lisp is refused rather than mapped, and Emacs being unable
;; to unload a module is why that ordering is the whole of the design rather than a
;; nicety.  It is also what changes terminfo staleness from mtime-vs-source to
;; version-vs-sidecar: a downloaded install has no terminfo/cooked.ti to be older
;; than.
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

(defcustom cooked-module-directory nil
  "Directory a downloaded native core is installed into, or nil for the default.

The default is `cooked/module/\=' under `user-emacs-directory\=', which is
deliberately outside the package tree.  A package manager owns everything under
its own directory and rewrites it on an upgrade, and one of those files would
be a .so this Emacs has mapped -- the SIGBUS `cooked--build-module\=' goes to
such lengths to avoid, dealt this time by an upgrade rather than by anything
cooked did.  Outside that tree the core also survives the upgrade, so a
reinstall does not leave the user with no terminal until they download again."
  :type '(choice (const :tag "cooked/module/ under user-emacs-directory" nil)
                 directory)
  :group 'cooked)

(defun cooked--module-directory ()
  "Absolute directory holding a downloaded core, its terminfo and its sidecar."
  (file-name-as-directory
   (expand-file-name (or cooked-module-directory
                         (locate-user-emacs-file "cooked/module")))))

(defun cooked--sidecar-file (directory)
  "Path of the version sidecar for an install in DIRECTORY."
  (expand-file-name "cooked-module.version" directory))

(defun cooked--read-sidecar (directory)
  "What DIRECTORY's sidecar says about the artifact beside it, or nil.

A plist: `:core\=' the version of the core, `:terminfo\=' the digest of the
terminfo source the database beside it was compiled from, `:platform\=' the tag
it was built for.  Written by `make dist\=' and moved into place by
`cooked--install-prebuilt\=', and it is the only thing a downloaded install can
be asked about itself -- there is no checkout beside it to compare against.

Read rather than evaluated, so a corrupt file is a parse error and never a form
that runs.  Anything unreadable, or read as something that is not a plist, is
reported as absent: an install whose sidecar cannot be understood is one we
decline to use, which is the same answer as having no sidecar at all.  That
ordering is deliberate everywhere it shows up here -- every failure path in
`cooked--install-prebuilt\=' ends in `sidecar absent\=' rather than `sidecar
stale\=', because absent is the state that describes a half-finished install
honestly.

The point of it existing is that it can be read *before* `module-load\='.
Asking a mapped core its version is a diagnosis and not a decision: Emacs
cannot unload a dynamic module, so a session that has mapped the wrong one is
married to it until it restarts.  The sidecar is the same question asked while
the answer can still change what happens."
  (let ((file (cooked--sidecar-file directory)))
    (when (file-readable-p file)
      (ignore-errors
        (let ((form (with-temp-buffer
                      (insert-file-contents file)
                      (goto-char (point-min))
                      (read (current-buffer)))))
          (and (plistp form) form))))))

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

(defconst cooked--terminfo-digest
  "5e5c3e8e82a09e29881a64c51361d2053c38db781a238745583ff0b9cfc9ffe5"
  "SHA-256 of the terminfo/cooked.ti this Lisp was written against.

The other half of the version-vs-sidecar staleness check in
`cooked--terminfo-usable-p\=', and a digest rather than a version number because
a version number has to be remembered.  Nothing has to remember this one:
`cooked-the-terminfo-digest-matches-the-source\=' recomputes it from the
checkout, so editing terminfo/cooked.ti and leaving this alone fails the suite
rather than a user's terminal.

A downloaded install cannot use it that way -- it has no checkout -- which is
exactly why the digest is what the sidecar records.  It is the one identifier
of a terminal description that survives being separated from the description.")

(defun cooked--terminfo-usable-p (database name)
  "Whether DATABASE describes NAME, from a compile this Lisp still recognises.

Staleness is the same hazard `cooked--module-stale-p\=' guards, arrived at the
same way: edit terminfo/cooked.ti, forget to rebuild, and every child is handed
a description of a terminal this is no longer.  Nothing downstream can catch it
-- a capability that is merely wrong reads as the child choosing not to use it
-- so it is caught here.

Which comparison answers that depends on what is on disk beside the database,
and the two cases are not variations of one rule.  In a checkout the source is
there and the compiled entry is a derived file, so the ordinary make question
-- is the output older than its input -- is exactly right, and it catches an
edit made a second ago.  A *downloaded* install has no terminfo/cooked.ti at
all: it carries the compiled database and nothing to compare it against, and an
mtime there answers a question nobody asked, since the file was written when
the tarball was unpacked.  So an install that carries a sidecar is judged on
what the sidecar says the database was compiled from, against
`cooked--terminfo-digest\='.  That is stricter than the mtime rule rather than a
weaker stand-in for it: it catches a database compiled from a *different*
description, not merely an older one.

Sidecar first when there is one, because it is the artifact stating what it is,
and mtime-vs-source only where no such statement exists.  With neither -- a
database somebody installed by hand, a checkout whose terminfo/ has been
stripped -- there is nothing to compare and the entry is taken at face value,
which is the answer this has always given in that case."
  (when-let* ((entry (cooked--terminfo-entry database name))
              (source (cooked--terminfo-source)))
    (if-let* ((sidecar (cooked--read-sidecar
                        (file-name-directory (directory-file-name database)))))
        (equal (plist-get sidecar :terminfo) cooked--terminfo-digest)
      (or (not (file-exists-p source))
          (not (time-less-p (file-attribute-modification-time (file-attributes entry))
                            (file-attribute-modification-time (file-attributes source))))))))

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

The order is shipped, then downloaded, then already built, then build.  What
ships is a compiled database in the package -- which asks nothing of the
machine, needs no `tic\=', and is read by every ncurses there has ever been, an
entry it cannot parse being skipped rather than fatal.

Downloaded comes second because it is the same thing arriving by another road:
the release artifact carries the compiled database beside the core, and it has
to, since a machine with no toolchain to build the core with is not reliably a
machine with a `tic\=' to compile a description with either.  It sits below the
checkout for the same reason the checkout's core does -- a tree you can see is
the one you meant -- and above `tic\=', because a database somebody shipped
deliberately beats one this machine can be talked into producing.

The two live in different directories on purpose.  `cooked/module/terminfo\=' is
unpacked from a tarball and judged against its sidecar; `cooked/terminfo\=' is
what `tic\=' wrote here and is judged against the source it was compiled from.
Pointing both at one directory would mix the two and leave the sidecar
answering for files it never described."
  (when (eq cooked--terminfo-database 'unset)
    (setq cooked--terminfo-database
          (let ((shipped (expand-file-name "terminfo/db" (cooked--root)))
                (downloaded (expand-file-name "terminfo" (cooked--module-directory)))
                (mine (locate-user-emacs-file "cooked/terminfo")))
            (cond
             ((cooked--terminfo-usable-p shipped cooked-term-name) shipped)
             ((cooked--terminfo-usable-p downloaded cooked-term-name) downloaded)
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

(defconst cooked--minimum-core-version "1.0.0"
  "Oldest core version this Lisp will map a downloaded artifact for.

Bumped when the Lisp starts calling something an older core does not provide.
It is the sidecar's `:core\=' that gets compared against it, so the comparison
happens before `module-load\=' and its answer is `refuse\=' rather than `warn\='.

Deliberately not the check `cooked--check-core-drift\=' declined to make, and
that docstring's argument against version comparison is untouched: in a
checkout the protocol moves whenever a defun is added and the version does not,
so the file is the right thing to ask about.  A downloaded artifact has no file
to ask about -- there are no sources beside it and no mtime that means
anything -- and its version is not a proxy for the protocol but a statement of
which release's protocol it implements, which is precisely what a release tag
is for.")

(defun cooked--prebuilt-core (&optional directory)
  "Path the downloaded core occupies in DIRECTORY, whether or not it is there."
  (expand-file-name (concat "libcooked" module-file-suffix)
                    (or directory (cooked--module-directory))))

(defun cooked--prebuilt-state (&optional directory)
  "How usable the downloaded install in DIRECTORY is, as a symbol.

  `absent\='      nothing installed there.
  `incomplete\='  a core with no sidecar, or one that will not read -- an
                install interrupted partway, or a directory somebody assembled
                by hand.  Refused rather than probed: the whole reason the
                sidecar is written last is so that this state is reachable, and
                treating it as good enough would throw that away.
  `stale\='       the sidecar names a core older than
                `cooked--minimum-core-version\='.
  `usable\='      map it.

A symbol rather than a boolean because the three refusals want different things
said to the user -- download it, download it again, finish the download -- and
by the time `cooked--load-module\=' has decided not to map anything, the
directory it decided that about is the only evidence left."
  (let* ((directory (or directory (cooked--module-directory)))
         (sidecar (cooked--read-sidecar directory))
         (version (plist-get sidecar :core)))
    (cond
     ((not (file-exists-p (cooked--prebuilt-core directory))) 'absent)
     ((not (stringp version)) 'incomplete)
     ((version< version cooked--minimum-core-version) 'stale)
     (t 'usable))))

(defun cooked--check-prebuilt (state)
  "Signal an error describing STATE, unless it is `usable\='.

The refusal that has to happen before `module-load\=', and the reason the
sidecar is read at all.  Mapping a stale core and warning about it afterwards
is a session that cannot be repaired -- Emacs cannot unload a module -- whereas
refusing leaves this same Emacs able to load the fresh one the moment
`cooked-download-module\=' has installed it, with no restart."
  (pcase state
    ('usable t)
    ('stale
     (error "%s %s" "cooked: the downloaded native core is older than this Lisp"
            "needs -- run M-x cooked-download-module"))
    ('incomplete
     (error "%s %s" "cooked: the downloaded native core has no readable version"
            "sidecar -- run M-x cooked-download-module"))
    (_
     (error "%s %s" "cooked: no native core, and no Rust sources to build one"
            "from -- run M-x cooked-download-module"))))

(defun cooked--source-core (root)
  "Path to the core a checkout under ROOT builds, or nil if there is no checkout.

Nil is the install this whole download apparatus exists for: Lisp and terminfo
on disk with no Cargo.toml above them, or with one and no toolchain to use it.

An artifact that is already built counts even where `cargo\=' has since gone
missing.  Mapping a file asks nothing of a toolchain, and the alternative --
ignoring a core sitting right there because the machine can no longer produce
another one -- would break the two-line try-it-out in the README on any machine
that installs Rust through a shell whose PATH Emacs did not inherit."
  (let ((core (expand-file-name (concat "target/release/libcooked" module-file-suffix)
                                root)))
    (and (file-exists-p (expand-file-name "Cargo.toml" root))
         (file-directory-p (expand-file-name "src" root))
         (or (file-exists-p core) (executable-find "cargo"))
         core)))

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

(defun cooked--map-core (file)
  "Map FILE as the native core and record that this session did.
Every `module-load\=' of ours goes through here, so that nothing can map a core
without `cooked--check-core-drift\=' being able to notice it later."
  (module-load file)
  (setq cooked--core-loaded
        (cons file (file-attribute-modification-time (file-attributes file)))))

(defun cooked--load-module ()
  "Load the native core, building or downloading nothing that was not asked for.

Three places a core can come from, in this order: `cooked-native-module\=' if it
is set, the checkout that produced it, and an artifact downloaded by
`cooked-download-module\='.

The checkout beats the download rather than the other way round.  A tree you
can see is the one you meant -- a developer who once downloaded an artifact and
is now editing src/ wants the thing they are editing, and their `.so\=' is
rebuilt out from under them by `cooked--module-stale-p\=' as it always was.  The
download's customer is the install where `cooked--source-core\=' returns nil,
which is the only case where the order could matter to anyone else.

Nothing here downloads and nothing here prompts.  A build is automatic because
the checkout that would do it is the checkout the user is standing in and the
sources are already on their disk; a download is not, because it fetches bytes
over the network and no amount of it being convenient makes that a thing to do
on somebody's behalf while they were opening a terminal.  So the download is a
command, and every path that finds no usable core ends by naming it."
  (unless module-file-suffix
    (error "cooked: this Emacs was built without dynamic module support"))
  (let* ((root (cooked--root))
         ;; Not a hardcoded \".so\": cargo names a cdylib \"libcooked.dylib\" on macOS,
         ;; which is exactly what `module-file-suffix' reports there.
         (source (and (null cooked-native-module) (cooked--source-core root)))
         (ours (and source t))
         (built (or cooked-native-module source (cooked--prebuilt-core))))
    (if (featurep 'cooked-core)
        (cooked--check-core-drift built)
      ;; Before `module-load', and that ordering is the point.  Once a core is
      ;; mapped this session is married to it, so the only useful place to
      ;; refuse a stale one is here, where refusing still leaves this Emacs
      ;; able to map the replacement without a restart.
      (unless (or cooked-native-module source)
        (cooked--check-prebuilt (cooked--prebuilt-state)))
      (when (or (not (file-exists-p built))
                (and ours (cooked--module-stale-p built root)))
        (cooked--build-module root built))
      (cooked--map-core built))))

;;; Downloading a prebuilt core

;; Loaded when a download is actually asked for.  `url' pulls in a dozen files
;; and every one of them is dead weight in the ordinary session, which builds
;; its core from a checkout and never comes near this.
(declare-function url-retrieve-synchronously "url")

(defconst cooked--prebuilt-release nil
  "Release tag whose artifacts `cooked--prebuilt-digests\=' pins, or nil for none.

Nil is the honest answer today.  No release of cooked has published a prebuilt
core, so there is nothing to download, and `cooked-download-module\=' says that
rather than guessing a tag and asking GitHub for a file nobody uploaded.
Publishing one is: `make dist\=' on each platform, upload the tarballs and the
SHA256SUMS from `make dist-checksums\=', then paste what `make dist-digests\='
printed into the two constants here.

Deliberately not `cooked-version\='.  The digests below can only be computed
after the artifacts they pin have been built, so this trails the tree by a
release and is bumped in the commit that lands the digest table.  A constant
required to equal the current version would be one nobody could ever set
correctly, and the version it could not be set to is the one an install would
then refuse to download.")

(defconst cooked--prebuilt-digests nil
  "SHA-256 of each artifact of `cooked--prebuilt-release\=', by asset name.

An alist, and the whole trust story.  What arrives over the network is checked
against a digest that came with the package -- from MELPA, from a git tag, from
whatever put this .el on disk -- so a compromised release host, a substituted
asset, a mirror somebody was talked into using and an intercepted TLS session
all produce bytes that do not hash to what is written here, and none of them
produce bytes that do.  The trust root moves from the CDN to the tarball this
file arrived in, which is the posture something about to be `dlopen\='ed into
your editor's address space deserves.

What it is not is a signature.  Whoever can write this constant can also write
the artifact it pins, so it defends the path between the release and the user
and not the release itself, and a reader who wants the stronger property should
read `cooked-download-module\=' before believing they have it.")

(defcustom cooked-prebuilt-url-format
  "https://github.com/vodik/cooked/releases/download/v%s/%s"
  "Where a prebuilt core is fetched from: a format of the release tag and asset.

Customizable so a mirror, a corporate artifact store or a fork can serve them,
and that is safe here in a way it would not be otherwise: the bytes are checked
against `cooked--prebuilt-digests\=' whatever host they came from, so pointing
this somewhere else changes who serves the artifact and not who is trusted for
it.  A URL that is not https is refused all the same -- the digest makes
interception futile rather than acceptable, and there is no reason to hand a
passive observer the fact of the download for free."
  :type 'string
  :group 'cooked)

(defun cooked--platform-tag ()
  "Tag naming this machine in an artifact name, like \"x86_64-linux\", or nil.

Arch from `system-configuration\=' rather than from `system-type\=', which does
not have it, normalizing the two spellings that differ only by convention.
Nil for anything not listed, which is a refusal to guess.  There is no artifact
for a platform nobody built one on, and the failure worth having there is a
message naming the platform, not a 404 on a URL that was never going to exist.

Android is named separately and not folded into Linux even though
`system-type\=' may say `gnu/linux\=' there, because a module linked against
bionic will not load against glibc -- an artifact that is wrong in that
particular way fails at `dlopen\=' with an error about a symbol, which is a long
way from the truth."
  (let ((arch (pcase (car (split-string system-configuration "-"))
                ("amd64" "x86_64")
                ("arm64" "aarch64")
                (other other)))
        (os (cond
             ((eq system-type 'darwin) "macos")
             ((or (eq system-type 'android)
                  (string-match-p "android" system-configuration))
              nil)
             ((eq system-type 'gnu/linux) "linux"))))
    (and arch os (format "%s-%s" arch os))))

(defun cooked--prebuilt-asset (release platform)
  "Name of the RELEASE artifact for PLATFORM."
  (format "cooked-%s-%s.tar.gz" release platform))

(defun cooked--pinned-digest (asset)
  "The digest pinned for ASSET, or signal because there is none.

The refusal that makes the rest of this worth writing.  An asset with no digest
is not a download to do carefully, it is a download to not do: the case a
verification declines to cover is exactly the case somebody arranges, and
\"could not verify, proceeding\" is a worse posture than no verification at all
because it reads to everyone downstream as though the check happened."
  (or (cdr (assoc asset cooked--prebuilt-digests))
      (error "cooked: no digest is pinned for %s, so nothing can vouch for it"
             asset)))

(defun cooked--file-digest (file)
  "SHA-256 of FILE's bytes, as lowercase hex.

Literally and unibyte.  `insert-file-contents\=' would decode, and the digest of
a decoded copy of a tarball is the digest of something that was never on the
wire and will never match what `sha256sum\=' printed on the release machine."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun cooked--verify-digest (file digest)
  "Signal unless FILE hashes to DIGEST.

No option to continue, and no caller that offers one.  A truncated download and
a substituted one are the same event from here -- bytes that are not the bytes
this package pinned -- and both are refused before anything opens the file."
  (let ((got (cooked--file-digest file)))
    (unless (equal got digest)
      (error "cooked: %s does not match the digest this package pins (%s, not %s)"
             (file-name-nondirectory file) got digest))))

(defun cooked--fetch (url destination)
  "Fetch URL into DESTINATION, or signal saying why not."
  (unless (string-prefix-p "https://" url)
    (error "cooked: refusing a download URL that is not https: %s" url))
  (require 'url)
  (let ((buffer (or (url-retrieve-synchronously url t t 120)
                    (error "cooked: no answer from %s" url))))
    (unwind-protect
        (with-current-buffer buffer
          (set-buffer-multibyte nil)
          (goto-char (point-min))
          (unless (looking-at-p "HTTP/[0-9.]+ 200")
            (error "cooked: %s answered %s" url
                   (buffer-substring (point) (line-end-position))))
          (unless (re-search-forward "\r?\n\r?\n" nil t)
            (error "cooked: no body in the answer from %s" url))
          ;; `jka-compr-inhibit' because DESTINATION is named .tar.gz, and
          ;; auto-compression is keyed on the name rather than on what is being
          ;; written: `write-region' would gzip the body on the way to disk, and
          ;; what the digest then hashes is not what the server sent.
          ;;
          ;; It usually gets away with it, which is the reason to bind this
          ;; rather than to reason about it.  jka-compr skips a body that
          ;; already begins with the gzip magic, so an artifact arriving intact
          ;; is written verbatim by luck.  A body that is *not* an artifact --
          ;; the HTML error page a proxy answers 200 with, a truncation that
          ;; lost the header -- is compressed instead, and the digest mismatch
          ;; that follows blames the download for something this line did.
          (let ((coding-system-for-write 'binary)
                (jka-compr-inhibit t))
            (write-region (point) (point-max) destination nil 'silent)))
      (kill-buffer buffer))))

(defun cooked--unpack (archive directory)
  "Unpack ARCHIVE into DIRECTORY.

The platform's `tar\=', rather than `tar-untar-buffer\=' or a header reader of our
own.  Emacs' own untar expands each member name against `default-directory\=' and
writes wherever that lands -- an absolute name or one reaching out through `..\='
escapes the directory it was pointed at -- so using it would mean writing those
checks here.  GNU and BSD tar both strip the leading slash and refuse the `..\=',
and are the code on this machine most likely to have had somebody look at it.

That choice is not what makes this safe, though, and it is worth being exact
about which step is load-bearing.  Nothing is unpacked that has not already
matched `cooked--prebuilt-digests\=', so by the time tar runs, the archive is
byte-for-byte the one the package pinned and its member names were chosen by
the release rather than by whoever served it.  `cooked--check-unpacked\=' is the
belt to that braces, and neither is a licence to unpack something unverified."
  (unless (executable-find "tar")
    (error "cooked: no tar on PATH to unpack the artifact with"))
  (unless (eq 0 (call-process "tar" nil nil nil "-xzf" archive "-C" directory))
    (error "cooked: could not unpack %s" (file-name-nondirectory archive))))

(defun cooked--check-unpacked (directory)
  "Signal unless DIRECTORY holds exactly what a cooked artifact holds.

Three names and no fourth.  The three are the reason the artifact is a tarball
rather than a bare .so: a machine with no toolchain to build the core is not
reliably a machine with a `tic\=' to compile a terminal description either, so
the database ships beside the core and inside the same digest.  The sidecar is
what makes the pair checkable afterwards.

Refusing a fourth name matters more than it looks.  It is the assertion that
the unpack put everything where it was supposed to and nothing where it was
not, and it is cheap enough that there is no reason to find out the other way."
  (let* ((core (concat "libcooked" module-file-suffix))
         (wanted (list core "cooked-module.version" "terminfo")))
    (dolist (name wanted)
      (unless (file-exists-p (expand-file-name name directory))
        (error "cooked: the artifact is missing %s" name)))
    (dolist (name (directory-files directory nil
                                   directory-files-no-dot-files-regexp))
      (unless (member name wanted)
        (error "cooked: unexpected file in the artifact: %s" name)))
    (unless (cooked--terminfo-entry (expand-file-name "terminfo" directory)
                                    "cooked-256color")
      (error "cooked: the artifact carries no compiled terminfo entry"))))

(defun cooked--install-prebuilt (staging directory)
  "Move the artifact unpacked in STAGING into DIRECTORY.

By rename, for the reason `cooked--build-module\=' and the Makefile's `module\='
target both state at length: rewriting a mapped .so in place hands every Emacs
holding it a SIGBUS at its next page fault, and Emacs' fatal-signal handler
exits without a core or a journal line to say what happened.  A rename swaps
which inode the name points at and leaves the old one alive for whoever still
has it mapped.  STAGING is a subdirectory of DIRECTORY so that every rename
here is within one filesystem and cannot degrade into a copy.

The order is the other half.  The sidecar is deleted first and written last, so
an install interrupted anywhere in between leaves a directory that reads as
`incomplete\=' rather than as a fresh core -- see `cooked--prebuilt-state\='.  The
old terminfo database is moved aside rather than deleted before the new one
lands, so the window in which there is no database at all is a rename wide."
  (let* ((core (concat "libcooked" module-file-suffix))
         (sidecar (cooked--sidecar-file directory))
         (terminfo (expand-file-name "terminfo" directory))
         (aside (concat terminfo ".old")))
    (when (file-exists-p sidecar)
      (delete-file sidecar))
    (rename-file (expand-file-name core staging)
                 (expand-file-name core directory) t)
    (when (file-directory-p aside)
      (delete-directory aside t))
    (when (file-directory-p terminfo)
      (rename-file terminfo aside))
    (rename-file (expand-file-name "terminfo" staging) terminfo)
    (when (file-directory-p aside)
      (delete-directory aside t))
    (rename-file (expand-file-name "cooked-module.version" staging) sidecar t)))

;;;###autoload
(defun cooked-download-module ()
  "Download and install this platform's prebuilt native core.

For the install that cannot build one: no Rust toolchain, or Lisp on disk with
no Cargo.toml above it.  A checkout goes on building its own and never reaches
this, and nothing calls it -- not `cooked--load-module\=', not loading this file,
not byte-compiling it.  Fetching from the network on somebody's behalf while
they were opening a terminal is not a thing to do, however convenient, so this
is a command and the failure paths that need it say its name.

What arrives is a tarball carrying the core, the compiled terminfo database and
a version sidecar, and it is checked against a digest compiled into this file
before anything opens it.  An asset with no pinned digest is not downloaded at
all; see `cooked--pinned-digest\=' for why that is the only defensible way for
this to fail.

The core is mapped straight away when this session has not already mapped one,
which is the practical payoff of reading the sidecar before `module-load\=': an
Emacs that refused a stale core at startup can be given a fresh one without
being restarted.  A session already married to a core is told to restart,
because Emacs cannot unload a module and there is nothing else to say."
  (interactive)
  (unless module-file-suffix
    (error "cooked: this Emacs was built without dynamic module support"))
  (let* ((release (or cooked--prebuilt-release
                      (user-error "%s %s"
                                  "cooked: no release publishes a prebuilt core"
                                  "yet -- build from source, or set cooked-native-module")))
         (platform (or (cooked--platform-tag)
                       (user-error "cooked: no prebuilt core is published for %s"
                                   system-configuration)))
         (asset (cooked--prebuilt-asset release platform))
         (digest (cooked--pinned-digest asset))
         (url (format cooked-prebuilt-url-format release asset))
         (directory (cooked--module-directory))
         (staging (expand-file-name ".staging" directory))
         (archive (make-temp-file "cooked-module" nil ".tar.gz")))
    (make-directory directory t)
    (unwind-protect
        (progn
          (when (file-directory-p staging)
            (delete-directory staging t))
          (make-directory staging t)
          (message "cooked: downloading %s..." url)
          (cooked--fetch url archive)
          (cooked--verify-digest archive digest)
          (cooked--unpack archive staging)
          (cooked--check-unpacked staging)
          (cooked--install-prebuilt staging directory))
      (ignore-errors (delete-file archive))
      (when (file-directory-p staging)
        (ignore-errors (delete-directory staging t))))
    ;; The database this session settled on was chosen before there was a
    ;; downloaded one to choose, and it is cached for the session.
    (setq cooked--terminfo-database 'unset)
    (if (featurep 'cooked-core)
        (message "cooked: core %s installed -- restart Emacs to use it" release)
      (cooked--check-prebuilt (cooked--prebuilt-state directory))
      (cooked--map-core (cooked--prebuilt-core directory))
      (message "cooked: core %s installed and loaded" release))))

(provide 'cooked-module)
;;; cooked-module.el ends here
