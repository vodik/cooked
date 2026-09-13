;;; bench-prelude.el --- Compile and guard a graphical bench script  -*- lexical-binding: t; -*-

;;; Commentary:

;; What every script under scripts/ that measures something does before it
;; measures, in one place so that none of them can forget half of it.  There are
;; two halves.
;;
;; The first is compilation.  A script run as `emacs -Q -l scripts/bench-tree.el'
;; loads cooked from `lisp/*.el', interpreted, and its own spin loop interpreted
;; with it.  Nobody runs cooked that way: a styled 24x80 frame conses 14,112 cells
;; interpreted against 1,858 compiled, and its median apply is three times slower.
;; Every figure these scripts produced before this file existed was taken like
;; that, except one pair that was compiled by hand.  So `cooked-bench-script-start'
;; byte-compiles `lisp/*.el', tests/cooked-bench.el and the calling script into a
;; temporary directory, puts that directory first on `load-path', and loads the
;; script again from its `.elc'.
;;
;; The compilation runs in a separate Emacs, and it has to.  Compiling a file
;; evaluates its `require's, so compiling cooked-mode.el in this Emacs would load
;; cooked-render.el interpreted and provide its feature; the compiled file would
;; then never be loaded, because `require' sees the feature and returns.
;;
;; The `.elc' files go to a temporary directory rather than beside the sources,
;; which is the reverse of what `make bench' does and for the reason `make bench'
;; gives for its trap.  A `.elc' left in `lisp/' is preferred over its `.el' by the
;; next `make lisp-test', and a script running under gamescope is killed from
;; outside often enough that a trap in Lisp would not always run.
;;
;; The second half is the load guard, which is the one `make bench' uses:
;; `cooked-bench--load-ok-p' over `cooked-bench-load-fraction' of the CPUs, and
;; `COOKED_BENCH_FORCE' to run anyway.  A refusal is written to the script's
;; output file and exits 1, because under gamescope nothing on stdout survives,
;; and a `user-error' with `debug-on-error' set would open a debugger on a
;; headless frame that nobody can close.
;;
;; A script begins:
;;
;;   (eval-and-compile
;;     (unless (featurep 'bench-prelude)
;;       (load (expand-file-name "bench-prelude"
;;                               (file-name-directory
;;                                (or load-file-name
;;                                    (bound-and-true-p byte-compile-current-file))))
;;             nil t)))
;;   (cooked-bench-script-start "/tmp/cooked-tree.out")
;;
;; and everything after that runs compiled.  Put `(cooked-bench-script-provenance)'
;; in the script's output, so a recorded run says which files it loaded.

;;; Code:

(defconst cooked-bench-script--root
  (file-name-directory
   (directory-file-name
    (file-name-directory (file-truename (or load-file-name buffer-file-name)))))
  "Top of the source tree, the directory holding scripts/ and lisp/.")

(defvar cooked-bench-script--compiled nil
  "The directory the compiled script was loaded from, once it has been.

Nil during the first, interpreted, load of a script, and the directory during the
second, which is how `cooked-bench-script-start' tells the two apart: the
script's `.elc' calls it again at the same place, and that call must return
rather than compile and load a third time.")

(defvar cooked-bench-script--load nil
  "The (ONE-MINUTE . CPUS) load the guard judged, for the provenance line.")

(defun cooked-bench-script--refusal (sample forced)
  "The sentence refusing a run at load SAMPLE, or nil to let it go ahead.

SAMPLE is (ONE-MINUTE . CPUS), as `cooked-bench--load-sample' returns it, and
FORCED is the value of `COOKED_BENCH_FORCE'.  A load of 9.0 over 16 CPUs is
refused at the default fraction of one half, and nothing is refused while
FORCED is non-nil."
  (unless (or forced (cooked-bench--load-ok-p sample))
    (format "machine is busy (load %.2f over %d cpus, limit %.2f) -- quieten it, or set COOKED_BENCH_FORCE=1 to measure anyway"
            (car sample) (cdr sample)
            (* cooked-bench-load-fraction (cdr sample)))))

(defun cooked-bench-script--compile (script dir)
  "Byte-compile cooked, the batch bench and SCRIPT into DIR, in another Emacs.

Return nil on success and the compiler's output on failure.  `lisp/*.el' is
compiled with warnings as errors, as `make bench' compiles it.  The bench and
SCRIPT are not: they are harnesses, and a docstring one column too wide in one
of them should not stop a measurement of the other."
  (let* ((emacs (expand-file-name invocation-name invocation-directory))
         (default-directory cooked-bench-script--root)
         (dest (format "(setq byte-compile-dest-file-function (lambda (f) (expand-file-name (concat (file-name-base f) \".elc\") %S)))"
                       dir))
         (lisp (directory-files (expand-file-name "lisp") t "\\`[^.].*\\.el\\'"))
         (failure nil))
    (dolist (step (list (cons "(setq byte-compile-error-on-warn t)" lisp)
                        (list "nil"
                              (expand-file-name "tests/cooked-bench.el")
                              script)))
      (unless failure
        (with-temp-buffer
          (unless (zerop (apply #'call-process emacs nil t nil
                                "-Q" "--batch" "-L" "lisp" "-L" "tests" "-L" "scripts"
                                "-l" "bytecomp" "--eval" (car step) "--eval" dest
                                "-f" "batch-byte-compile" (cdr step)))
            (setq failure (buffer-string))))))
    failure))

(defun cooked-bench-script--finish (out code text)
  "Write TEXT to OUT and to stderr, then exit Emacs with CODE."
  (with-temp-file out (insert text "\n"))
  (message "%s" text)
  (kill-emacs code))

(defun cooked-bench-script-start (out)
  "Compile cooked and the calling script, refuse a busy machine, run compiled.

OUT is the file the script writes its results to, which is where a refusal or
a compile failure is written too.  Called from the top level of a script, after
this file is loaded and before anything else.  On the script's first,
interpreted, load this never returns: it loads the script's `.elc', which does
the measuring and ends in `kill-emacs', and exits itself if the `.elc' did not.
On the second load it returns nil at once.

cooked's `cooked--source-directory' is pointed back at the tree after the
compiled files load.  It is captured from `load-file-name', which is now the
temporary directory, and `cooked--root' walks up from it to find the native
core, terminfo/ and shell-integration/, none of which were copied."
  (unless cooked-bench-script--compiled
    (let* ((script (file-truename load-file-name))
           (dir (make-temp-file "cooked-bench-elc-" t)))
      (add-hook 'kill-emacs-hook (lambda () (delete-directory dir t)))
      (when-let* ((failure (cooked-bench-script--compile script dir)))
        (cooked-bench-script--finish
         out 1 (concat "cooked-bench: compilation failed, nothing measured\n" failure)))
      ;; Deferred native compilation would start compiling these `.elc' in the
      ;; background part way through the run, and swap the native code in under
      ;; the loop being timed.  `make bench' runs in batch, where it is off.
      (setq native-comp-jit-compilation nil)
      (push dir load-path)
      (require 'cooked-util)
      (setq cooked--source-directory
            (file-name-as-directory (expand-file-name "lisp" cooked-bench-script--root)))
      (require 'cooked-bench)
      (setq cooked-bench-script--load (cooked-bench--load-sample))
      (when-let* ((refusal (cooked-bench-script--refusal
                            cooked-bench-script--load (getenv "COOKED_BENCH_FORCE"))))
        (cooked-bench-script--finish out 1 (concat "cooked-bench: " refusal)))
      (setq cooked-bench-script--compiled dir)
      (load (expand-file-name (concat (file-name-base script) ".elc") dir) nil t)
      (kill-emacs 0))))

(defun cooked-bench-script-provenance ()
  "One line saying what this run loaded and the load it was judged at.

For example: `compiled: bench-tree.elc, cooked--apply from
/tmp/cooked-bench-elc-x1/cooked-render.elc; load 2.48 over 16 cpus, limit
8.00'.  Called from the top level of the compiled script, where
`load-file-name' names the script's own `.elc'.  A run whose line does not end
in `.elc' twice was not compiled, and its figures are not comparable with one
that was."
  (let ((sample cooked-bench-script--load))
    (format "compiled: %s, cooked--apply from %s (%s); load %s%s"
            (and load-file-name (file-name-nondirectory load-file-name))
            (symbol-file 'cooked--apply 'defun)
            (if (compiled-function-p (symbol-function 'cooked--apply))
                "byte-code" "INTERPRETED")
            (if sample
                (format "%.2f over %d cpus, limit %.2f"
                        (car sample) (cdr sample)
                        (* cooked-bench-load-fraction (cdr sample)))
              "unavailable")
            (if (and sample (not (cooked-bench--load-ok-p sample)))
                " -- BUSY, forced by COOKED_BENCH_FORCE"
              ""))))

(provide 'bench-prelude)
;;; bench-prelude.el ends here
