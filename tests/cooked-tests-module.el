;;; cooked-tests-module.el --- Provisioning the native core -*- lexical-binding: t; -*-

;;; Commentary:

;; The half of `cooked-module.el' that is not about terminals at all: what has to
;; be true of an artifact before this Emacs maps it, and what has to be true of a
;; download before it becomes an artifact.
;;
;; Nothing here reaches the network, and that is a property of the code under test
;; rather than of the tests: every step between the bytes arriving and the core
;; being mapped -- the digest, the unpack, the shape check, the install, the
;; sidecar -- takes a file, so all of it can be driven from a temp directory.  The
;; one function that does open a socket is `cooked--fetch', and the two tests that
;; go near it replace it with one that fails if it is called at all.
;;
;; The load path is the one that matters.  A stale core mapped and then complained
;; about is a session that cannot be repaired: Emacs cannot unload a dynamic
;; module.  So `cooked-a-stale-sidecar-is-refused-before-the-core-is-mapped' does
;; not check for a warning, it checks that `module-load' was never reached.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cooked-module)

(defun cooked-tests--sidecar (directory &rest plist)
  "Write PLIST as DIRECTORY's version sidecar, creating DIRECTORY."
  (make-directory directory t)
  (write-region (concat (prin1-to-string plist) "\n") nil
                (cooked--sidecar-file directory) nil 'silent))

(defun cooked-tests--fake-artifact (directory &rest plist)
  "Populate DIRECTORY as an unpacked artifact: a core, a database, a sidecar.

The core is a file with the right name and nothing in it.  Every check under
test here happens before `module-load', which is the whole point of them, so a
plausible .so would only be a slower way to write the same fixture.  PLIST
defaults to a sidecar this Lisp accepts."
  (make-directory (expand-file-name "terminfo/c" directory) t)
  (write-region "not a real core\n" nil
                (cooked--prebuilt-core directory) nil 'silent)
  (write-region "not a real entry\n" nil
                (expand-file-name "terminfo/c/cooked-256color" directory)
                nil 'silent)
  (apply #'cooked-tests--sidecar directory
         (or plist (list :core "1.0.0"
                         :terminfo cooked--terminfo-digest
                         :platform "x86_64-linux"))))

(defmacro cooked-tests--with-temp-directory (var &rest body)
  "Run BODY with VAR bound to a fresh directory, removed afterwards."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((,var (file-name-as-directory (make-temp-file "cooked-module" t))))
     (unwind-protect (progn ,@body)
       (delete-directory ,var t))))

(ert-deftest cooked-the-terminfo-digest-matches-the-source ()
  "`cooked--terminfo-digest' still describes the terminfo/cooked.ti in the tree.

The reason the sidecar records a digest rather than a version number: a version
number has to be remembered and this does not.  Edit the description, leave the
constant alone, and the failure is here rather than on the machine of somebody
who downloaded a database compiled from a description this Lisp no longer
expects -- where the symptom would be a capability that is merely wrong, which
reads as the child declining to use it.

Skipped where there is no checkout, which is the install the whole download
apparatus exists for and the one place this question cannot be asked."
  (let ((source (cooked--terminfo-source)))
    (skip-unless (file-exists-p source))
    (should (equal cooked--terminfo-digest (cooked--file-digest source)))))

(ert-deftest cooked-an-artifact-with-no-pinned-digest-is-not-downloaded ()
  "An asset absent from the table is refused, not fetched and hoped about.

The failure mode this check exists to not have.  A verification that carries on
when it cannot verify is worse than none: it reads to everyone downstream as
though the bytes were checked, and the case it declines to cover -- no digest
for this asset -- is exactly the case somebody arranges."
  (let ((cooked--prebuilt-digests '(("cooked-9.9.9-x86_64-linux.tar.gz" . "ab"))))
    (should (equal "ab" (cooked--pinned-digest "cooked-9.9.9-x86_64-linux.tar.gz")))
    (should-error (cooked--pinned-digest "cooked-9.9.9-aarch64-macos.tar.gz"))))

(ert-deftest cooked-an-artifact-that-is-not-the-pinned-bytes-is-refused ()
  "A substituted artifact and a truncated one are the same event from here.

Both are bytes that are not the bytes this package pinned, and there is no
third answer available to either: the digest is checked before anything opens
the file, so a mismatch cannot become a partial install."
  (cooked-tests--with-temp-directory dir
    (let ((file (expand-file-name "artifact.bin" dir)))
      (write-region "the bytes that were published\n" nil file nil 'silent)
      (let ((digest (cooked--file-digest file)))
        (should-not (cooked--verify-digest file digest))
        ;; Substituted: different bytes, same length, same name.
        (write-region "the bytes somebody else\226s\n" nil file nil 'silent)
        (should-error (cooked--verify-digest file digest))
        ;; Truncated: a download that died halfway through.
        (write-region "the bytes that were pub" nil file nil 'silent)
        (should-error (cooked--verify-digest file digest))
        (write-region "the bytes that were published\n" nil file nil 'silent)
        (should-not (cooked--verify-digest file digest))))))

(ert-deftest cooked-a-fetched-artifact-lands-as-the-bytes-that-were-served ()
  "The body is written verbatim, header stripped and nothing else touched.

Not a network test: `url-retrieve-synchronously' is replaced with one that
hands back a response buffer, which is all `cooked--fetch' ever sees of the
network anyway.  What it is a test of is the two ways the bytes can be mangled
between the socket and the digest, both of which are keyed on something other
than the content.  `write-region' would encode them, and auto-compression --
keyed on the destination being named .tar.gz -- would gzip them.

Both bodies are here because the second hazard hides behind the first.  A real
gzip member is written verbatim whatever this does, since jka-compr declines to
compress data that already carries the magic; it is the body that is *not* an
artifact -- the error page a proxy answered 200 with -- that gets compressed on
the way to disk, and then fails its digest with a story about tampering."
  ;; Before the stub, not after: `cooked--fetch' requires `url' itself, and a
  ;; load arriving in the middle of the `cl-letf' would define the real function
  ;; over the stub and send this test at the network after all.
  (require 'url)
  (cooked-tests--with-temp-directory dir
    (let* ((body (with-temp-buffer
                   (set-buffer-multibyte nil)
                   (insert "\037\213\010\000\000\000\000\000\000\003")
                   (insert "\313\310\344\002\000\175\073\126\147\003\000\000\000")
                   (buffer-string)))
           (destination (expand-file-name "artifact.tar.gz" dir))
           (url "https://example.invalid/cooked.tar.gz")
           (served nil))
      (cl-letf (((symbol-function 'url-retrieve-synchronously)
                 (lambda (&rest _)
                   (let ((buffer (generate-new-buffer " *cooked-test-http*")))
                     (with-current-buffer buffer
                       (set-buffer-multibyte nil)
                       (insert "HTTP/1.1 200 OK\r\n")
                       (insert "Content-Type: application/gzip\r\n\r\n")
                       (insert served))
                     buffer))))
        (dolist (bytes (list body "<html>404 from a proxy that said 200</html>"))
          (setq served bytes)
          (cooked--fetch url destination)
          (should (equal (cooked--file-digest destination)
                         (secure-hash 'sha256 bytes)))))
      ;; And a URL that is not https is refused before any of that happens.
      (should-error (cooked--fetch "http://example.invalid/x.tar.gz" destination)))))

(ert-deftest cooked-a-sidecar-that-does-not-read-is-absent-rather-than-trusted ()
  "Unreadable, missing and not-a-plist are one answer, and it is the safe one.

An install whose sidecar cannot be understood is one to decline, and declining
is what having no sidecar already means -- so there is no fourth state to
handle and no path on which a corrupt file reads as a fresh core.  It is
`read' rather than `eval', too: a corrupt sidecar is a parse error and never a
form that runs."
  (cooked-tests--with-temp-directory dir
    (should-not (cooked--read-sidecar dir))
    (write-region "" nil (cooked--sidecar-file dir) nil 'silent)
    (should-not (cooked--read-sidecar dir))
    (write-region "(:core \"1.0.0\"" nil (cooked--sidecar-file dir) nil 'silent)
    (should-not (cooked--read-sidecar dir))
    (write-region "\"1.0.0\"\n" nil (cooked--sidecar-file dir) nil 'silent)
    (should-not (cooked--read-sidecar dir))
    (cooked-tests--sidecar dir :core "1.2.3")
    (should (equal "1.2.3" (plist-get (cooked--read-sidecar dir) :core)))))

(ert-deftest cooked-the-state-of-an-install-is-read-off-its-sidecar ()
  "The four states, and the ordering that makes `incomplete' reachable.

`cooked--install-prebuilt' deletes the sidecar first and writes it last, so an
install interrupted anywhere in between is a core with no sidecar.  That has to
be a refusal rather than a shrug, because the alternative -- mapping whatever
is there when the file that would have described it is missing -- is precisely
the outcome the ordering was designed to prevent."
  (cooked-tests--with-temp-directory dir
    (should (eq 'absent (cooked--prebuilt-state dir)))
    (write-region "" nil (cooked--prebuilt-core dir) nil 'silent)
    (should (eq 'incomplete (cooked--prebuilt-state dir)))
    (cooked-tests--sidecar dir :terminfo "whatever")
    (should (eq 'incomplete (cooked--prebuilt-state dir)))
    (cooked-tests--sidecar dir :core "0.0.1")
    (should (eq 'stale (cooked--prebuilt-state dir)))
    (cooked-tests--sidecar dir :core cooked--minimum-core-version)
    (should (eq 'usable (cooked--prebuilt-state dir)))))

(defmacro cooked-tests--with-no-checkout (mapped &rest body)
  "Run BODY as an install with no sources, recording loads in MAPPED.

Two things have to be pretended.  There is a checkout here -- the suite is
running out of one -- and `cooked--load-module' rightly prefers it, so
`cooked--source-core' is made to answer as it does where the whole point of
the download is that it cannot.  And the suite has already mapped a core, which
sends `cooked--load-module' down the drift branch instead of the one under
test, so `featurep' is made to answer for `cooked-core' as it does in a session
that has not.

`module-load' records instead of mapping, because what these tests assert is
that it was not reached.  Watching for a warning would pass just as happily on
the code that maps the stale core and then complains about it, which is the
version of this that cannot be recovered from without restarting Emacs."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((,mapped nil)
         (cooked--core-loaded nil)
         (cooked-native-module nil)
         (featurep* (symbol-function 'featurep)))
     (cl-letf (((symbol-function 'cooked--source-core) (lambda (_root) nil))
               ((symbol-function 'featurep)
                (lambda (feature &rest rest)
                  (unless (eq feature 'cooked-core)
                    (apply featurep* feature rest))))
               ((symbol-function 'module-load)
                (lambda (file) (setq ,mapped file))))
       ,@body)))

(ert-deftest cooked-a-stale-sidecar-is-refused-before-the-core-is-mapped ()
  "Nothing is mapped when the sidecar says the core is too old, or says nothing.

The ordering is the entire design.  Emacs cannot unload a dynamic module, so a
session that has mapped the wrong core is married to it until it restarts,
and the only useful place to notice is before the mapping -- where refusing
leaves this same Emacs able to load the replacement the moment
`cooked-download-module' has installed one, with no restart."
  (cooked-tests--with-temp-directory dir
    (cooked-tests--with-no-checkout mapped
      (let ((cooked-module-directory dir))
        ;; Nothing installed at all.
        (should-error (cooked--load-module))
        (should-not mapped)
        ;; A core older than this Lisp calls for.
        (cooked-tests--fake-artifact dir :core "0.0.1")
        (should-error (cooked--load-module))
        (should-not mapped)
        ;; A core with no sidecar to vouch for it: an interrupted install.
        (delete-file (cooked--sidecar-file dir))
        (should-error (cooked--load-module))
        (should-not mapped)
        ;; And a sidecar that will not parse, which is the same answer.
        (write-region "(:core" nil (cooked--sidecar-file dir) nil 'silent)
        (should-error (cooked--load-module))
        (should-not mapped)))))

(ert-deftest cooked-a-fresh-downloaded-core-is-mapped-where-there-is-no-checkout ()
  "The other side of the refusal: a sidecar that vouches for the core loads it.

Worth asserting alongside the refusals, because a gate that never opens is
indistinguishable from a broken download and would be found by users rather
than here."
  (cooked-tests--with-temp-directory dir
    (cooked-tests--with-no-checkout mapped
      (let ((cooked-module-directory dir))
        (cooked-tests--fake-artifact dir)
        (cooked--load-module)
        (should (equal mapped (cooked--prebuilt-core dir)))
        (should (equal (car cooked--core-loaded) (cooked--prebuilt-core dir)))))))

(ert-deftest cooked-a-downloaded-terminfo-is-judged-against-its-sidecar ()
  "Staleness moves from mtime-vs-source to version-vs-sidecar, and has to.

A downloaded install carries the compiled database and no terminfo/cooked.ti to
compare it against, so the mtime rule has nothing to answer: the entry's mtime
is when the tarball was unpacked, which says nothing about what it was compiled
from.  The sidecar does, and the digest it records is a stricter question than
the mtime ever asked -- it catches a database compiled from a *different*
description and not merely an older one."
  (cooked-tests--with-temp-directory dir
    (let ((database (expand-file-name "terminfo" dir)))
      (cooked-tests--fake-artifact dir)
      (should (cooked--terminfo-usable-p database "cooked-256color"))
      ;; Compiled from some other description than the one this Lisp expects.
      (cooked-tests--sidecar dir :core "1.0.0" :terminfo "not the digest")
      (should-not (cooked--terminfo-usable-p database "cooked-256color"))
      ;; An entry the database does not describe is not usable either, sidecar
      ;; or no sidecar.
      (cooked-tests--sidecar dir :core "1.0.0" :terminfo cooked--terminfo-digest)
      (should-not (cooked--terminfo-usable-p database "cooked-nonesuch"))
      ;; And with the sidecar gone the old rule is back: no source to be older
      ;; than, so the entry is taken at face value.
      (delete-file (cooked--sidecar-file dir))
      (cl-letf (((symbol-function 'cooked--terminfo-source)
                 (lambda () (expand-file-name "nowhere/cooked.ti" dir))))
        (should (cooked--terminfo-usable-p database "cooked-256color"))))))

(ert-deftest cooked-an-artifact-has-to-carry-the-terminfo-and-nothing-extra ()
  "Three names and no fourth.

The database is in the tarball because a machine with no toolchain to build the
core is not reliably a machine with a `tic' to compile a description either,
and a download shipping only the .so leaves the child with no terminal
description at all.  Refusing a fourth name is the assertion that the unpack
put everything where it was meant to and nothing where it was not."
  (cooked-tests--with-temp-directory dir
    (should-error (cooked--check-unpacked dir))
    (cooked-tests--fake-artifact dir)
    (should-not (cooked--check-unpacked dir))
    ;; The core alone is not an artifact.
    (delete-directory (expand-file-name "terminfo" dir) t)
    (should-error (cooked--check-unpacked dir))
    (cooked-tests--fake-artifact dir)
    ;; A terminfo directory with no compiled entry in it is not one either.
    (delete-file (expand-file-name "terminfo/c/cooked-256color" dir))
    (should-error (cooked--check-unpacked dir))
    (cooked-tests--fake-artifact dir)
    (write-region "" nil (expand-file-name "surprise" dir) nil 'silent)
    (should-error (cooked--check-unpacked dir))))

(ert-deftest cooked-installing-an-artifact-never-leaves-a-stale-sidecar ()
  "The install lands by rename, and its failures land as `incomplete'.

Rename because the .so may be mapped into another Emacs, and rewriting those
bytes in place is the SIGBUS that takes an editor down with nothing in the
journal -- the rule `cooked--build-module' and the Makefile's `module' target
both state at length.  Sidecar last because the states this can be interrupted
into have to be honest: a core with no sidecar is refused, a core with an old
sidecar describing a new .so would not be."
  (cooked-tests--with-temp-directory dir
    (let ((staging (expand-file-name ".staging" dir)))
      ;; An older install already sitting there, to be replaced.
      (cooked-tests--fake-artifact dir :core "0.0.1" :terminfo "old")
      (write-region "old entry\n" nil
                    (expand-file-name "terminfo/c/cooked-256color" dir) nil 'silent)
      (cooked-tests--fake-artifact staging)
      (cooked--install-prebuilt staging dir)
      (should (eq 'usable (cooked--prebuilt-state dir)))
      (should (equal cooked--terminfo-digest
                     (plist-get (cooked--read-sidecar dir) :terminfo)))
      (should-not (file-exists-p (expand-file-name "terminfo.old" dir)))
      (should-not (file-exists-p (expand-file-name "cooked-module.version" staging)))
      ;; An install that dies partway leaves no sidecar behind, so the next
      ;; load refuses rather than trusting the one that described the last core.
      (cooked-tests--fake-artifact staging)
      (delete-file (cooked--prebuilt-core staging))
      (should-error (cooked--install-prebuilt staging dir))
      (should (eq 'incomplete (cooked--prebuilt-state dir))))))

(ert-deftest cooked-an-artifact-survives-the-tarball-it-ships-in ()
  "What `make dist' writes is what `cooked--check-unpacked' accepts.

Both subdirectory spellings have to come through, for the reason both are
written in the first place: ncurses names them either for the entry's first
letter or for its hex code, and which one the `tic' that wrote ours chose says
nothing about the ncurses that will read it.  A tarball is the only reason
there is an unpack step at all -- the database is several files, so the
artifact could never have been a bare .so."
  :tags '(tar)
  (skip-unless (executable-find "tar"))
  (cooked-tests--with-temp-directory dir
    (let ((source (expand-file-name "source" dir))
          (target (expand-file-name "target" dir))
          (archive (expand-file-name "artifact.tar.gz" dir)))
      (cooked-tests--fake-artifact source)
      (make-directory (expand-file-name "terminfo/63" source) t)
      (write-region "not a real entry\n" nil
                    (expand-file-name "terminfo/63/cooked-256color" source)
                    nil 'silent)
      (make-directory target t)
      (should (eq 0 (call-process "tar" nil nil nil "-czf" archive "-C" source
                                  (concat "libcooked" module-file-suffix)
                                  "cooked-module.version" "terminfo")))
      (cooked--unpack archive target)
      (should-not (cooked--check-unpacked target))
      (should (cooked--terminfo-entry (expand-file-name "terminfo" target)
                                      "cooked-256color"))
      (should (file-exists-p (expand-file-name "terminfo/63/cooked-256color" target))))))

(ert-deftest cooked-nothing-is-downloaded-while-no-release-publishes-one ()
  "The mechanism is built and the endpoint is not wired, and it says so.

No release of cooked has published a prebuilt core, so `cooked--prebuilt-release'
is nil and the command refuses before it composes a URL.  The refusal is
checked with `cooked--fetch' replaced by one that fails if it is called, which
is also how this test earns the claim in this file's Commentary that the suite
touches no network."
  (cl-letf (((symbol-function 'cooked--fetch)
             (lambda (&rest _) (error "The suite must not reach the network"))))
    (let ((cooked--prebuilt-release nil))
      (should-error (cooked-download-module) :type 'user-error))
    ;; And with a release named but no digest pinned for it, which is the state
    ;; a half-finished release process leaves behind.
    (let ((cooked--prebuilt-release "9.9.9")
          (cooked--prebuilt-digests nil))
      (should-error (cooked-download-module)))))

(ert-deftest cooked-the-platform-tag-names-an-asset-a-release-could-carry ()
  "The tag is the one half of the asset name the Makefile does not compute.

`make dist' derives it from uname and this derives it from
`system-configuration', so the two can disagree -- and the symptom of
disagreeing is a 404 that reads like a missing release.  Nothing here can check
the Makefile, so what is checked is the shape and the normalizations both
sides make."
  (let ((tag (cooked--platform-tag)))
    (skip-unless tag)
    (should (string-match-p "\\`[^-]+-\\(linux\\|macos\\)\\'" tag))
    (should-not (string-match-p "\\`\\(amd64\\|arm64\\)-" tag))
    (should (equal (cooked--prebuilt-asset "1.2.3" tag)
                   (format "cooked-1.2.3-%s.tar.gz" tag)))))

(provide 'cooked-tests-module)
;;; cooked-tests-module.el ends here
