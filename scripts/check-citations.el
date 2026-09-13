;;; check-citations.el --- Check that cited symbol names exist  -*- lexical-binding: t; -*-

;;; Commentary:

;; The comments in this tree are unusually detailed, and that is deliberate:
;; they carry the reasoning a diff cannot, and people act on what they say.  A
;; comment that names a function is therefore an assertion, and it is the one
;; assertion in the tree that nothing checks -- everything else that pins a
;; claim gets checked by a build step.  A sweep of the prose found eleven
;; citations of a function, variable or test that does not exist, and nine of
;; them were mechanically detectable.  This is the machine that detects them.

;; The interesting half is the test names.  A renamed defun breaks its callers,
;; so a stale citation of one usually arrives with a compile error attached; a
;; renamed `ert-deftest' breaks nothing at all, so a docstring naming it can be
;; wrong for as long as nobody reads it.  One test name managed to be wrong in
;; both directions inside a month -- cited before it existed, and then cited
;; again after it had been renamed away.

;; Existence is decided by loading the suite and asking Emacs, not by grepping
;; for `defun'.  That is the whole reason this is Lisp and not the fifteen
;; lines of shell it was scoped as.  Grep has to reimplement the naming rules
;; of every defining macro, and the two that bit the original sweep are exactly
;; the ones grep gets wrong: `cl-defstruct' mints an accessor per slot that
;; appears nowhere as a `defun', and `defvar-local' is not spelled `defvar'.
;; `define-derived-mode' is a third -- it mints a keymap, a hook, a syntax
;; table and a mode variable from a form that names none of them.  After a
;; load, all of those simply answer `fboundp' or `boundp', and no rule has to
;; be written down here to be got wrong later.  Loading also settles the
;; module's own defuns for free: the symbols `src/lib.rs' registers are
;; `fboundp' once `cooked-module' has pulled the core in, so this file needs no
;; separate list of them that could drift away from lib.rs.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'subr-x)

(defvar cooked-citations--root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name)))
  "Top of the source tree, derived from where this file was loaded from.")

(defvar cooked-citations--count 0
  "How many stale citations have been reported so far.")

(defun cooked-citations--report (file line fmt &rest args)
  "Report one stale citation at FILE and LINE, described by FMT and ARGS."
  (cl-incf cooked-citations--count)
  (message "%s:%d: %s" (file-relative-name file cooked-citations--root) line
           (apply #'format fmt args)))

(defun cooked-citations--files (dir suffix)
  "Return the files under DIR whose name ends in SUFFIX, recursively, sorted."
  (let ((full (expand-file-name dir cooked-citations--root)))
    (when (file-directory-p full)
      (sort (directory-files-recursively full (concat (regexp-quote suffix) "\\'"))
            #'string<))))

;;; Pulling citations out of prose.

;; A citation ending in a file extension is a path, and the filesystem is a
;; better oracle for it than the obarray.  This catches the other way the prose
;; goes stale: a file renamed or merged away, still cited by its old name.
(defconst cooked-citations--path-re "\\.\\(el\\|elc\\|rs\\|ti\\|org\\|toml\\|sh\\)\\'"
  "Extensions that make a citation a path rather than a symbol.")

;; A token is trimmed of the punctuation prose wraps it in before it is looked
;; up: the closing quote of the `foo' convention, a sentence's full stop, a
;; possessive.  A trailing hyphen goes too, because a comment that writes
;; "`cooked-render-' and friends" means the prefix and not a symbol.  What
;; survives has to have a hyphen and then something after "cooked", so the
;; project's own name in running prose is never mistaken for a citation of
;; something that ought to exist.
(defconst cooked-citations--token-re
  "cooked-[a-zA-Z0-9<>=*/+!?.-]*[a-zA-Z0-9<>=*/+!?]"
  "Regexp for the longest thing in prose that could be a citation.
Underscores are deliberately not symbol constituents here.  Emacs Lisp
spells its names with hyphens, and everything in this tree that uses an
underscore is the shell half -- `COOKED_SHELL_INTEGRATION_FEATURES', the
`cooked_precmd' hook the integration snippets install -- which lives in
`shell-integration/' and has nothing to do with the obarray.")

(defun cooked-citations--tokens-in (text)
  "Return the citation-shaped tokens in TEXT, in order of appearance."
  ;; Case-sensitively, which is not a detail: `string-match' folds case by
  ;; default, and with folding on this regexp swallows every
  ;; `COOKED_SHELL_INTEGRATION_FEATURES' in the session tests' shell fixtures.
  (let ((case-fold-search nil) (start 0) (out '()))
    (while (string-match cooked-citations--token-re text start)
      (setq start (match-end 0))
      (push (string-remove-suffix "'s" (match-string 0 text)) out))
    (nreverse out)))

;; Inside a string, only the `foo' convention counts as a citation.  A comment
;; is prose all the way through and every token in it is a claim about the
;; tree, but a string is as often data as it is prose -- the session tests
;; alone contain a shell script defining a cooked-theme function, a
;; `make-temp-file' prefix spelled cooked-terminfo, and a list of buffer names
;; -- and reading
;; those as citations produced two dozen findings that were all noise.  A
;; docstring that means to point at a symbol says so with the quotes, because
;; that is what makes it a live link under `describe-function'; requiring them
;; costs nothing real and removes the entire class.
(defconst cooked-citations--quoted-re "`\\([^`\n']+\\)'"
  "Regexp for a symbol written in the Elisp \\=`foo\\=' quoting convention.")

(defun cooked-citations--unwrap (text)
  "Rejoin the symbols TEXT broke across a line at a hyphen.
The prose here wraps a long name mid-symbol and lets the trailing hyphen
carry the join, so the half at the end of one comment line and the half at
the start of the next are one citation and have to be looked up as one.
Joining outside a quoted span cannot invent a finding, since nothing here
adds the quotes that would make the result a citation."
  (replace-regexp-in-string "-\n[ \t]*\\(?:;+[ \t]*\\)?" "-" text))

(defun cooked-citations--quoted-tokens-in (text)
  "Return the citation-shaped tokens that TEXT quotes in the \\=`foo\\=' style."
  (setq text (cooked-citations--unwrap text))
  (let ((case-fold-search nil) (start 0) (out '()))
    (while (string-match cooked-citations--quoted-re text start)
      (setq start (match-end 0))
      (setq out (nconc out (cooked-citations--tokens-in (match-string 1 text)))))
    out))

;; Comments and strings are found with the reader's own syntax parsing rather
;; than with a regexp, so that a `;' inside a string and a quotation mark
;; inside a comment each land where they belong.  Strings are read as well as
;; comments and not just the ones in a docstring position, because an `error'
;; or a `user-error' that names a function is prose about a symbol just as much
;; as a docstring is, and goes stale in exactly the same way.
(defun cooked-citations--insert-lisp (file)
  "Insert FILE into the current buffer and give it Lisp syntax.
The syntax table is not optional.  A `with-temp-buffer' is in
`fundamental-mode', where `;' is punctuation and `\\' is not an escape, so
`parse-partial-sexp' finds no comments at all there and desynchronises on the
first odd quotation mark inside one.  That is not a hypothetical: without this
line the checker silently treated every comment in the tree as code, which is
the one arrangement in which it reports almost nothing and looks like it works."
  (insert-file-contents file)
  (delay-mode-hooks (emacs-lisp-mode)))

(defun cooked-citations--prose-regions ()
  "Return (BEG END KIND) for each comment and string in the current buffer.
KIND is `comment' or `string'."
  (let ((regions '()) (pos (point-min)) (state nil))
    (while (< pos (point-max))
      ;; A COMMENTSTOP of `syntax-table' stops the parse at each entry into and
      ;; exit from a comment or a string, which is precisely the boundary set
      ;; wanted here, so the loop never has to know how either is spelled.
      (setq state (parse-partial-sexp pos (point-max) nil nil state 'syntax-table))
      (setq pos (point))
      (when (nth 8 state)
        (let ((beg (nth 8 state)) (kind (if (nth 3 state) 'string 'comment)))
          (setq state (parse-partial-sexp pos (point-max) nil nil state 'syntax-table))
          (setq pos (point))
          (push (list beg pos kind) regions))))
    (cooked-citations--coalesce (nreverse regions))))

;; Emacs Lisp comment syntax ends a comment at the newline, so a paragraph of
;; `;;' lines arrives here as one region per line.  That has to be undone before
;; anything reads it, because this tree wraps a long name mid-symbol and lets
;; the trailing hyphen carry the join -- a citation split over two lines is
;; visible to nothing that looks at either line alone, and the result is not a
;; false positive but a silent miss, which is worse in a check people are meant
;; to trust.
(defun cooked-citations--coalesce (regions)
  "Merge REGIONS that are consecutive lines of one comment block."
  (let ((out '()))
    (pcase-dolist (`(,beg ,end ,kind) regions)
      (pcase (car out)
        ((and `(,pbeg ,pend comment)
              (guard (and (eq kind 'comment)
                          (string-match-p "\\`[ \t\n]*\\'"
                                          (buffer-substring-no-properties pend beg)))))
         (setcar out (list pbeg end 'comment)))
        (_ (push (list beg end kind) out))))
    (nreverse out)))

(defun cooked-citations--code-tokens (file)
  "Return the citation-shaped tokens appearing in FILE outside its prose."
  (with-temp-buffer
    (cooked-citations--insert-lisp file)
    (let ((code '()) (pos (point-min)))
      ;; The complement of the prose regions is the code, and taking it that way
      ;; rather than by a second parse keeps the two halves from ever
      ;; disagreeing about where a docstring ends.
      (pcase-dolist (`(,beg ,end ,_kind) (cooked-citations--prose-regions))
        (push (buffer-substring-no-properties pos beg) code)
        (setq pos end))
      (push (buffer-substring-no-properties pos (point-max)) code)
      (mapcan #'cooked-citations--tokens-in (nreverse code)))))

(defun cooked-citations--collect (file)
  "Return an alist of (TOKEN . LINE) for every citation in FILE's prose."
  (with-temp-buffer
    (cooked-citations--insert-lisp file)
    (let ((out '()))
      (pcase-dolist (`(,beg ,end ,kind) (cooked-citations--prose-regions))
        (let ((line (line-number-at-pos beg))
              (text (buffer-substring-no-properties beg end)))
          (dolist (tok (append
                        (cooked-citations--quoted-tokens-in text)
                        ;; A file can be cited without the quotes -- "see
                        ;; cooked-render.el" -- and that citation goes stale
                        ;; the same way, so unquoted tokens are still looked at
                        ;; when they end in a source extension.  Only then: a
                        ;; comment that mentions /tmp/cooked-ceiling.out is
                        ;; naming a file this run has not created yet, and one
                        ;; that writes "comint-shaped, cooked-implemented" is
                        ;; writing English.
                        (when (eq kind 'comment)
                          (cl-remove-if-not
                           (lambda (tok)
                             (string-match-p cooked-citations--path-re tok))
                           (cooked-citations--tokens-in text)))))
            (push (cons tok line) out))))
      (nreverse out))))

;;; Deciding whether a citation names something real.

(defvar cooked-citations--in-code nil
  "Hash of every citation-shaped token that appears in code somewhere.")


(defun cooked-citations--known-path-p (name)
  "Return non-nil if NAME names a file that exists somewhere in the tree.
Bare basenames are searched for, because the prose cites `cooked-render.el'
far more often than it cites `lisp/cooked-render.el', and insisting on the
directory would turn every one of those into a finding."
  (let ((base (file-name-nondirectory name)))
    (or (file-exists-p (expand-file-name name cooked-citations--root))
        (cl-some (lambda (dir)
                   (file-exists-p
                    (expand-file-name base (expand-file-name dir cooked-citations--root))))
                 '("." "lisp" "tests" "src" "scripts" "docs" "terminfo"
                   "shell-integration" "src/emu" "src/emu/term" "src/emu/parser"
                   "src/platform")))))

;; Any one of these being true is enough.  `facep' and `cl-find-class' are here
;; because a face and a `cl-defstruct' type name get cited the way a function
;; does, and neither of them is `fboundp'.
;; Prose points at a family of names with a trailing star -- "the
;; `cooked--attr-*' constants", "the `cooked--box-dash-*' mirror" -- and means
;; every name with that prefix.  It is a real citation and it goes stale like
;; any other, so it is checked as a prefix rather than skipped.
(defun cooked-citations--known-prefix-p (prefix)
  "Return non-nil if any known name begins with PREFIX."
  (or (catch 'found
        (maphash (lambda (tok _) (when (string-prefix-p prefix tok) (throw 'found t)))
                 cooked-citations--in-code)
        nil)
      (catch 'found
        (mapatoms (lambda (sym)
                    (when (and (string-prefix-p prefix (symbol-name sym))
                               (cooked-citations--known-symbol-p (symbol-name sym)))
                      (throw 'found t))))
        nil)))

(defun cooked-citations--known-symbol-p (name)
  "Return non-nil if NAME names something that exists after loading the suite."
  (let ((sym (intern-soft name)))
    (and sym
         (or (fboundp sym) (boundp sym) (facep sym)
             (ert-test-boundp sym)
             (cl-find-class sym)
             ;; Two things are real without being bound or callable, and each
             ;; says so with a property of its own: a `define-error' condition,
             ;; like `cooked-error', and a `define-fringe-bitmap' bitmap, like
             ;; `cooked-command-bar'.  Not any property at all, because a
             ;; symbol picks one up from much that is not a definition --
             ;; `function-history' is left behind by a function that was
             ;; defined and then removed, which is a rename's old name.
             (get sym 'error-conditions)
             (get sym 'fringe)
             ;; A feature, cited by its bare name.  Prose here says "the
             ;; autoloads in `cooked-project'" as often as it says
             ;; `cooked-project.el', and both mean the file.
             (memq sym features)
             (cooked-citations--known-path-p (concat name ".el"))))))

;; The obarray is authoritative about what exists but silent about two things.
;; It does not know a symbol that is only ever a *text property* -- the runs
;; `cooked-link' stamps carry `cooked-link-url', a real and load-bearing name
;; that no form anywhere defines -- and it does not know a file the suite never
;; loads, which on a machine without evil installed is `cooked-evil.el' and,
;; because its commands are autoloaded rather than required, `cooked-project.el'
;; too.  Both gaps produce confident nonsense, and a checker that calls
;; `cooked-link-url' missing has found nothing and cost its reader five minutes.
;;
;; So a token also counts as real if it appears anywhere in the tree's *code*,
;; outside the prose.  That is a weaker oracle, deliberately: the question this
;; check exists to answer is whether the prose still points at something the
;; tree contains, and a name the code still uses is exactly that.  It gives up
;; nothing on the category that recurs, either, because a renamed `ert-deftest'
;; leaves its old name in no code anywhere -- being referred to from nothing but
;; prose is the very property that made it invisible in the first place.
(defun cooked-citations--load-code-tokens ()
  "Fill `cooked-citations--in-code' from every source file in the tree."
  (setq cooked-citations--in-code (make-hash-table :test #'equal))
  (dolist (file (append (cooked-citations--files "lisp" ".el")
                        (cooked-citations--files "tests" ".el")
                        (cooked-citations--files "scripts" ".el")))
    (dolist (tok (cooked-citations--code-tokens file))
      (puthash tok t cooked-citations--in-code)))
  ;; The core's own defuns.  `src/lib.rs' is the register of them, and it is
  ;; read rather than left to `fboundp' because the module is loaded lazily by
  ;; `cooked--load-module': a batch session that merely *loads* the Lisp has
  ;; never called it, so every `cooked--drain' in every docstring would be
  ;; reported missing.  Reading lib.rs also means the list cannot drift, since
  ;; there is no second copy of it here to forget to update.
  (let ((lib (expand-file-name "src/lib.rs" cooked-citations--root)))
    (when (file-exists-p lib)
      (with-temp-buffer
        (insert-file-contents lib)
        (goto-char (point-min))
        (while (re-search-forward "\"\\(cooked-[^\"]*\\)\"" nil t)
          (puthash (match-string 1) t cooked-citations--in-code))))))

(defun cooked-citations--check-lisp ()
  "Report every stale citation in the Lisp sources."
  (cooked-citations--load-code-tokens)
  (dolist (file (append (cooked-citations--files "lisp" ".el")
                        (cooked-citations--files "tests" ".el")
                        (cooked-citations--files "scripts" ".el")))
    ;; One report per distinct token per file.  A symbol that was renamed tends
    ;; to be cited in the same file several times over, and a checker that
    ;; prints all of them buries the other findings.
    (let ((seen (make-hash-table :test #'equal)))
      (pcase-dolist (`(,tok . ,line) (cooked-citations--collect file))
        (unless (gethash tok seen)
          (puthash tok t seen)
          (unless (cond
                   ((string-match-p cooked-citations--path-re tok)
                    (cooked-citations--known-path-p tok))
                   ((string-suffix-p "*" tok)
                    (cooked-citations--known-prefix-p (string-remove-suffix "*" tok)))
                   ;; A token with a dot in it that is not a source file is a
                   ;; runtime artifact or a version number, not a symbol.
                   ((string-match-p "\\." tok) t)
                   (t (or (gethash tok cooked-citations--in-code)
                          (cooked-citations--known-symbol-p tok))))
            (cooked-citations--report file line "cites `%s', which does not exist"
                                      tok)))))))

;;; The Rust half.

;; Rust prose cites three shapes that can be checked without a compiler: a path
;; with a slash in it, which the filesystem settles; `Type::method', which is
;; settled the same way the Lisp half settles a symbol, against the set of names
;; the sources actually use; and a Lisp name, `cooked--drain', which is settled
;; by the Lisp half's own oracle.  Every whole-line comment is read, plain `//'
;; as well as `///' and `//!', and in the integration tests under tests/ as
;; well as src/: a plain comment explains as much as a doc comment does, and
;; rustdoc checks neither a plain comment nor a test crate.  A comment trailing
;; code on the same line is not read, since telling it from a `//' inside a
;; string would take a Rust lexer.

(defconst cooked-citations--rust-backtick-re "`\\([^`\n]+\\)`"
  "Regexp for a backticked span inside a Rust doc comment.")

(defconst cooked-citations--rust-path-re
  "\\`[A-Za-z_][A-Za-z0-9_]*\\(::[A-Za-z_][A-Za-z0-9_]*\\)+\\'"
  "Regexp for a `module::item' or `Type::method' citation.")

(defun cooked-citations--rust-files ()
  "Return the Rust sources: the crate under src/ and the test crates under tests/."
  (append (cooked-citations--files "src" ".rs")
          (cooked-citations--files "tests" ".rs")))

(defun cooked-citations--rust-comment-line-p ()
  "Return non-nil if point is on a line that is wholly a `//' comment."
  (save-excursion
    (beginning-of-line)
    (looking-at-p "[ \t]*//")))

(defun cooked-citations--rust-names ()
  "Return (ITEMS . IDENTS) for the Rust sources.
ITEMS holds the names of items this tree declares -- modules, types, traits,
functions -- and answers \"is the head of this path ours?\".  IDENTS holds
every identifier appearing anywhere in Rust code, and answers \"does this name
still exist?\" the way the Lisp half does, without having to model Rust\='s
namespaces, its macro-generated associated constants, or its trait methods."
  (let ((items (make-hash-table :test #'equal))
        (idents (make-hash-table :test #'equal)))
    ;; The crate names itself in its own docs, and it is declared in Cargo.toml
    ;; rather than in any source file.
    (puthash "cooked" t items)
    (dolist (file (cooked-citations--rust-files))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (re-search-forward
                (concat "^[ \t]*\\(?:pub\\(?:([^)]*)\\)?[ \t]+\\)?"
                        "\\(?:const[ \t]+\\|static[ \t]+\\|unsafe[ \t]+\\|async[ \t]+\\|"
                        "extern[ \t]+\"[^\"]*\"[ \t]+\\)*"
                        "\\(?:fn\\|struct\\|enum\\|trait\\|type\\|mod\\|union\\|impl\\)"
                        "[ \t]+\\([A-Za-z_][A-Za-z0-9_]*\\)")
                nil t)
          ;; Not `impl std::fmt::Display for ...': the head of a qualified
          ;; path in an impl belongs to somebody else's crate, and admitting
          ;; `std' here would make every `std::...' citation in the tree look
          ;; like something this checker is entitled to have an opinion about.
          (unless (or (looking-at-p "::") (cooked-citations--rust-comment-line-p))
            (puthash (match-string 1) t items)))
        (goto-char (point-min))
        (while (re-search-forward "[A-Za-z_][A-Za-z0-9_]*" nil t)
          (unless (cooked-citations--rust-comment-line-p)
            (puthash (match-string 0) t idents)))))
    (cons items idents)))

(defun cooked-citations--check-rust-path (file line span)
  "Report SPAN at FILE and LINE if it is a path naming no file in the tree."
  (let* ((path (car (split-string span "[ \t(]" t)))
         (base (file-name-nondirectory path)))
    (when (and (string-match-p cooked-citations--path-re path)
               (not (file-exists-p (expand-file-name path cooked-citations--root)))
               ;; Rust prose cites a sibling the way `mod' does, relative to the
               ;; citing file's own directory: `term/perform.rs' from inside
               ;; src/emu/.  Matching the tail of any real path is loose, but the
               ;; alternative is resolving Rust's module tree, and a rename still
               ;; fails this because the basename goes with it.
               (not (cl-some (lambda (real)
                               (string-suffix-p (concat "/" path) real))
                             (cooked-citations--rust-files)))
               (not (cooked-citations--known-path-p base)))
      (cooked-citations--report file line "cites path `%s', which does not exist" path))))

(defun cooked-citations--terminfo-names ()
  "Return the entry names terminfo/cooked.ti declares, such as cooked-direct.
Rust prose cites them the way it cites a Lisp name, and they are not symbols."
  (let ((file (expand-file-name "terminfo/cooked.ti" cooked-citations--root))
        (names '()))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (while (re-search-forward "^\\([a-z][^|,\n]*\\)|" nil t)
          (push (match-string 1) names))))
    names))

(defun cooked-citations--check-rust-lisp (file line span terminfo)
  "Report each Lisp name in SPAN, at FILE and LINE, that does not exist.
TERMINFO is the entry names `cooked-citations--terminfo-names' found."
  (dolist (tok (cooked-citations--tokens-in span))
    (unless (cond
             ((string-match-p cooked-citations--path-re tok)
              (cooked-citations--known-path-p tok))
             ((member tok terminfo) t)
             ((string-suffix-p "*" tok)
              (cooked-citations--known-prefix-p (string-remove-suffix "*" tok)))
             ((string-match-p "\\." tok) t)
             (t (or (gethash tok cooked-citations--in-code)
                    (cooked-citations--known-symbol-p tok))))
      (cooked-citations--report file line "cites `%s', which does not exist" tok))))

(defun cooked-citations--check-rust ()
  "Report stale `Type::method', path and Lisp citations in Rust comments."
  (pcase-let ((`(,items . ,idents) (cooked-citations--rust-names))
              (terminfo (cooked-citations--terminfo-names)))
    (dolist (file (cooked-citations--rust-files))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (re-search-forward "^[ \t]*//[/!]?\\(.*\\)$" nil t)
          (let ((doc (match-string 1))
                (line (line-number-at-pos (match-beginning 0)))
                (start 0))
            ;; A Lisp name is quoted either way in Rust prose: `foo' by the
            ;; Lisp convention, `foo` by the Rust one.
            (let ((lisp-start 0))
              (while (string-match "`\\([^`'\n]+\\)['`]" doc lisp-start)
                (setq lisp-start (match-end 0))
                (cooked-citations--check-rust-lisp
                 file line (match-string 1 doc) terminfo)))
            (while (string-match cooked-citations--rust-backtick-re doc start)
              (setq start (match-end 0))
              (let ((span (match-string 1 doc)))
                (cond
                 ((string-match-p "/" span)
                  (cooked-citations--check-rust-path file line span))
                 ((string-match-p cooked-citations--rust-path-re span)
                  (let ((segments (split-string span "::")))
                    ;; Only paths whose head this tree declares are checked.
                    ;; `std::io::Error', `nix::unistd::execvpe', `Option::None'
                    ;; and `u16::MAX' are all citations of somebody else's API:
                    ;; nothing here can say whether they are current, and
                    ;; guessing produced twenty findings and no information.
                    ;; They are rustdoc's business, and the intra-doc link
                    ;; warnings are now quiet enough for rustdoc to do it.
                    (when (gethash (car segments) items)
                      (dolist (seg (cdr segments))
                        (unless (gethash seg idents)
                          (cooked-citations--report
                           file line "cites `%s', whose `%s' does not exist"
                           span seg)))))))))))))))

(defun cooked-citations-batch ()
  "Entry point: check every citation and report what is stale.
Advisory: this never exits non-zero.  See the Makefile target for why."
  (setq cooked-citations--count 0)
  (cooked-citations--check-lisp)
  (cooked-citations--check-rust)
  (message "check-citations: %d stale citation%s"
           cooked-citations--count (if (= cooked-citations--count 1) "" "s")))

(provide 'check-citations)
;;; check-citations.el ends here
