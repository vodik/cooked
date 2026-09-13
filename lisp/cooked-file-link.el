;;; cooked-file-link.el --- Local file names as links in terminal output -*- lexical-binding: t; -*-

;;; Commentary:

;; Optional, and require-to-enable: nothing requires this file, and loading it *is*
;; the feature being on, on the model `cooked-osc-eval.el' and
;; `cooked-shell-completion.el' already set.  It sets the two nil-valued function
;; variables `cooked-link.el' owns, at the top level, so "not required" and "off" are
;; one state rather than two that can disagree.
;;
;;   (require 'cooked-file-link)
;;
;; Why it is not in the core, which is the whole argument for the split.  A URL is
;; decidable from the text: `https://example.com' is a URL because it is shaped like
;; one, and `goto-address-url-regexp' costs a regexp match.  A *file name* is not.
;; `src/lib.rs' is a link if that file exists and a word if it does not, and the only
;; thing that can tell you which is the filesystem.  Asking it per candidate per
;; redraw is a `file-exists-p' syscall on the render hot path -- for every damaged row
;; of every frame of a program repainting sixty times a second -- which is a cost the
;; core must not carry for a feature not everybody wants.
;;
;; So this is lazy in both directions.  A row is examined only once it has settled
;; into the scrollback, where it will never be rendered again, through
;; `cooked-link-scan-functions'; and a candidate under point is resolved on demand when
;; you follow it, through `cooked-link-follow-functions'.  Nothing validates a live
;; row.
;;
;; What is borrowed, and what is deliberately not.  `ffap-string-at-point' and
;; `ffap-file-exists-string' are used, and nothing else from ffap: `ffap-machine-p'
;; and the URL-guessing half of `ffap-alist' are never called, because
;; `ffap-machine-p' can `open-network-stream' under its `ping' strategy.  Shipped
;; defaults never ping, but a user who has set `ffap-machine-p-known' to `ping' would
;; be handing a redraw a network round trip, and a render path must not contain a
;; call that *can* block on the network under somebody's configuration.
;;
;; `compilation-error-regexp-alist' is read rather than reimplemented -- and read
;; rather than run.  It is a ~150-entry tool-specific dispatch table built for a
;; stateful whole-buffer engine (`compilation-parse-errors'), and scanning all of it
;; per row would be both expensive and a false-positive machine.  A curated subset is
;; probed with `string-match' against a candidate that has *already* been identified
;; as an existing file, purely to recover the line and column beside it.  next-error
;; integration is a separate entry and a separate agent's; it uses the same table
;; through the engine that owns it.  The duplication is deliberate: two readers of one
;; table by two paths, and no shared utility pretending they are one thing.

;;; Code:

(require 'cooked)
(require 'cooked-link)
(require 'ffap)
(require 'compile)
(require 'project)

(defcustom cooked-file-link-highlight t
  "Whether file names in settled scrollback are highlighted as links.

Off leaves the feature reachable but silent: \\`C-c RET' still opens the file
under point, because that path validates on demand and costs nothing until it
is asked."
  :type 'boolean
  :group 'cooked-link)

(defcustom cooked-file-link-scan-limit 400
  "Longest batch of scrollback, in lines, that is scanned for file names.

A batch is one drain's worth of evicted rows, so this is normally one or two.
The cap is for the flood: `cat' of a large file arrives as tens of thousands of
lines at once, and nobody is reading those for links.  A prefilter means a line
with no path-shaped token in it costs no syscall at all, so this is the second
bound rather than the one that usually matters."
  :type 'natnum
  :group 'cooked-link)

(defcustom cooked-file-link-display #'find-file-other-window
  "How a followed file name is opened.

`find-file-other-window' by default rather than `find-file': the terminal is
usually the window you are in, and taking it over to show a file is a
disruption you then have to undo.  It is also the shape `cooked--osc-emacs'
already gives the shell's own `find_file'."
  :type 'function
  :group 'cooked-link)

(defcustom cooked-file-link-error-rules '(gnu gcc-include)
  "Keys into `compilation-error-regexp-alist-alist' probed for a line and column.

A deliberately short list.  The full table is tool-specific and enormous, and
matching all of it against every candidate is a false-positive risk rather than
thoroughness -- an entry written for one compiler's output will happily match a
sentence from another program.  These two cover the `FILE:LINE:COL: message'
convention nearly everything follows, and the plain `FILE:LINE:COL' with no
message at all is handled directly by `cooked-file-link--split'.

Entries whose FILE, LINE or COLUMN are not plain group numbers (or a cons of
two, as `gnu' spells a range) are skipped: those forms are instructions to
`compilation-parse-errors', which is not running here."
  :type '(repeat symbol)
  :group 'cooked-link)

;;;; Finding a file name

(defconst cooked-file-link--candidate-regexp
  (rx (any "~/." alnum)
      (* (any "~/._+-" alnum))
      (or (seq "/" (+ (any "~/._+-" alnum)))
          (seq "." (+ alnum)))
      (* (any "~/._+-" alnum))
      (? ":" (+ digit) (? ":" (+ digit))))
  "Prefilter for something that might name a file.

A regexp, not an answer: everything it matches is still handed to the
filesystem.  Its whole job is to keep `file-exists-p' off the ninety-odd
percent of terminal output that contains no path-shaped token at all, which is
what makes scanning a batch of scrollback affordable.  Something has to have
either a slash in it or an extension on it to qualify.

A number with a point in it has an extension by that rule, so `1.5\=' and
`192.168.0.1\=' match too.  `cooked-file-link-scan\=' drops those itself, by
`cooked-file-link--number-regexp\=', because an Emacs regexp has no lookahead
to say \"but not only digits\" with.")

(defconst cooked-file-link--number-regexp "\\`[0-9.]+\\'"
  "A candidate that is only digits and points: a version, a ratio, an address.

Nothing a program prints as `3.14\=' or `10.0.0.1\=' is meant as a file, and
each would otherwise cost a `file-exists-p\=' per scan.  Following one under
point still asks, since there you pointed at it.")

(defun cooked-file-link--split (string)
  "Split STRING into its file name and any trailing :LINE:COL, as (NAME LINE COL).

Twice, because that is how the convention nests and how `ffap-file-at-point'
strips it: `foo.c:12:3' is a file with a line and a column, and each pass takes
one number off the end."
  (let ((line nil) (col nil))
    (when (string-match "\\`\\(.*\\):\\([0-9]+\\)\\'" string)
      (setq col (string-to-number (match-string 2 string))
            string (match-string 1 string)))
    (when (string-match "\\`\\(.*\\):\\([0-9]+\\)\\'" string)
      (setq line (string-to-number (match-string 2 string))
            string (match-string 1 string)))
    ;; One number is a line, not a column: `foo.c:12'.
    (unless line
      (setq line col col nil))
    (list string line col)))

(defun cooked-file-link--exists (name)
  "NAME as an existing file, resolved against the places a terminal means.

`default-directory' first, which cooked keeps on the child's own working
directory from OSC 7, so a relative path printed by a program running in a
subdirectory resolves the way it would if you typed it at that prompt.  Then
the project root, which is what makes the paths in a `make' or `cargo' log at
the top of a tree resolve from anywhere inside it -- the project.el integration
the report asked for, and it is one `let' rather than a mechanism.

Each place costs one `file-exists-p\=', and a miss is most of what a scan
does, so the count is the thing to keep down.  `ffap-file-exists-string\=' is
called with NOMODIFY: without it a miss also tries `NAME.gz\=' and `NAME.Z\=',
which made six calls of two, and it returns the compressed name while this
returned `NAME\=' -- so a directory holding only `foo.gz\=' linked a `foo\='
that opened an empty buffer.  And the root is not asked when it would be the
same question again: at the project root itself, which is where `tree\=' and
most builds run, or for an absolute NAME, which `default-directory\=' does not
touch.  The root is compared as a string, since asking the filesystem whether
two directories are one would cost the stat being saved.

Nothing resolves once the child has said it is on another host.  A build log
from a remote tree is full of names that exist here too, at the same paths, in
a checkout that is not the one that produced the log -- so the link would open,
land in a real file, and be the wrong file.  Highlighting nothing says less
than cooked knows, and everything it says is true.

Nothing resolves against a remote `default-directory\=' either, and that is a
second condition rather than a restatement of the first.  It is the cost guard
where the host check is the correctness one: every candidate on this path is a
`file-exists-p\=' in disguise, and against a TRAMP name each one is a round trip
to another machine.  Scrollback settles in batches of hundreds of lines, so what
that buys is a stall per batch for the rest of the session.  The two conditions
also do not imply each other in either direction -- \\[cooked] from a buffer
visiting a remote file starts with a remote `default-directory\=' and no OSC 7 at
all, and `cooked-remote-directory\=' set to nil leaves a foreign host with a
local one."
  (and (not (string-empty-p name))
       (not (cooked--foreign-host-p))
       (not (file-remote-p default-directory))
       ;; Expanded, because `ffap-file-exists-string' returns the name it was *given*,
       ;; not where it found it.  Unexpanded, the project-root branch below would hand
       ;; back a bare `src/lib.rs' for the caller to resolve against the child's
       ;; `default-directory', the one directory it is known not to be in.
       (or (when (ffap-file-exists-string name t) (expand-file-name name))
           (when-let* (((not (file-name-absolute-p name)))
                       (project (project-current nil))
                       (root (file-name-as-directory
                              (expand-file-name (project-root project))))
                       ((not (string= root (file-name-as-directory
                                            (expand-file-name default-directory)))))
                       (default-directory root))
             (when (ffap-file-exists-string name t) (expand-file-name name))))))

(defun cooked-file-link--string-at-point ()
  "`ffap-string-at-point\=' in its `file\=' mode, read across soft wraps.

ffap stops at the end of the buffer line, and on the live screen a buffer line
is a row: a path the terminal ran out of columns for would be answered as the
half point is in, and `find-file\=' would be offered that half.  So when the
logical line under point is wrapped, ffap is asked about the line as the child
wrote it, joined by `cooked-link--join-wrapped\=' and put in a scratch buffer,
and `ffap-string-at-point-region\=' is mapped back to this buffer\='s
positions.  With nothing wrapped, or a region active -- where ffap takes the
region as it stands -- this is ffap\='s own call and costs one property search.

Wrapped rows in scrollback carry no flag when `cooked-rejoin-wrapped-lines\=' is
nil, and a path wrapped there is still answered a row at a time."
  (let* ((line (cooked-link-logical-line-bounds (line-beginning-position)
                                                (line-end-position)))
         (joined (and (not (use-region-p))
                      (cooked-link--join-wrapped (car line) (cdr line)))))
    (if (not joined)
        (ffap-string-at-point 'file)
      (let* ((chunks (cdr joined))
             (pos (point))
             ;; The row point is in: the last piece starting at or before it.
             (chunk (seq-reduce (lambda (found chunk)
                                  (if (<= (cdr chunk) pos) chunk found))
                                chunks (aref chunks 0)))
             (table (syntax-table))
             string beg end)
        (with-temp-buffer
          (set-syntax-table table)
          (insert (car joined))
          (goto-char (+ 1 (car chunk) (- pos (cdr chunk))))
          (setq string (ffap-string-at-point 'file)
                beg (1- (car ffap-string-at-point-region))
                end (1- (cadr ffap-string-at-point-region))))
        ;; The end is mapped from the last character rather than from the
        ;; offset after it, which on a row boundary would name the character
        ;; after the wrap newline -- see `cooked-link--wrap-position'.
        (setq ffap-string-at-point-region
              (if (< beg end)
                  (list (cooked-link--wrap-position beg chunks)
                        (1+ (cooked-link--wrap-position (1- end) chunks)))
                (let ((pos (cooked-link--wrap-position beg chunks)))
                  (list pos pos))))
        string))))

(defun cooked-file-link--at-point ()
  "The file under point as (FILE LINE COL), or nil.

`ffap-string-at-point' with the `file' mode only.  Nothing here consults
`ffap-alist', `ffap-url-at-point' or `ffap-machine-p' -- see this file's
Commentary for why that last one in particular."
  (when-let* ((string (cooked-file-link--string-at-point)))
    (pcase-let ((`(,name ,line ,col) (cooked-file-link--split string)))
      (when-let* ((file (cooked-file-link--exists name)))
        (pcase-let ((`(,rule-line ,rule-col) (cooked-file-link--position name)))
          (list file (or line rule-line) (or col rule-col)))))))

(defun cooked-file-link--group (spec)
  "The plain match-group number SPEC names, or nil if it is not one.
SPEC is a `compilation-error-regexp-alist' field: a group number, a cons of two
for a range, or a form only `compilation-parse-errors' can evaluate."
  (cond ((natnump spec) spec)
        ((and (consp spec) (natnump (car spec))) (car spec))))

(defun cooked-file-link--position (name)
  "LINE and COLUMN for NAME from the compilation rules, as a list, or (nil nil).

Probed against the text of the line point is on, and only after NAME has been
established as a file that exists -- the rules are a way of reading the numbers
beside a known file name, never a way of deciding that something is one.  A
match whose own FILE group disagrees with NAME is dropped, which is what stops
a rule that matched some other part of the line from contributing numbers."
  (let ((line (buffer-substring-no-properties
               (line-beginning-position) (line-end-position)))
        (found (list nil nil)))
    (catch 'done
      (dolist (key cooked-file-link-error-rules (list nil nil))
        (when-let* ((rule (cdr (assq key compilation-error-regexp-alist-alist)))
                    (regexp (car rule))
                    (file (cooked-file-link--group (nth 1 rule)))
                    ((string-match regexp line))
                    ((equal (match-string file line) name)))
          (setq found
                (list (when-let* ((group (cooked-file-link--group (nth 2 rule)))
                                  (text (match-string group line)))
                        (string-to-number text))
                      (when-let* ((group (cooked-file-link--group (nth 3 rule)))
                                  (text (match-string group line)))
                        (string-to-number text))))
          (throw 'done found))))))

;;;; The two seams

(defun cooked-file-link-follow ()
  "Open the file under point, if there is one.  `cooked-link-follow-functions'."
  (when-let* ((found (cooked-file-link--at-point)))
    (pcase-let ((`(,file ,line ,col) found))
      (funcall cooked-file-link-display file)
      (when line
        (goto-char (point-min))
        (forward-line (1- line))
        (when col
          (move-to-column col)))
      t)))

(defun cooked-file-link--claim-p (beg end)
  "Whether this layer has claimed any of BEG..END as a file name.

The entry `cooked-link-claim-functions\=' carries for the guessing tier.  The
property is the one `cooked-file-link-scan\=' puts down, so the answer is about
spans this layer actually made rather than about text it merely could have
matched."
  (text-property-not-all beg end 'cooked-file-link nil))

(defun cooked-file-link-scan (beg end)
  "Highlight existing file names between BEG and END.

An entry on `cooked-link-scan-functions\='.

Runs once per batch of settled scrollback and never on a live row, which is the
whole reason it may touch the filesystem at all.  Answers are memoised for the
batch, so a build log naming one file forty times costs one `stat'.

Text properties rather than overlays, unlike the goto-addr pass: this text is
frozen -- `cooked--render-scrolled' has just marked it read-only and nothing
rewrites it -- so there is no lifetime for an `evaporate' to manage, and a
property costs less than an overlay per match on a batch that can be thousands
of lines long.  A match that already carries an `OSC 8' link, or that goto-addr
has claimed as a URL, is left alone: what the child said outranks what this
guessed."
  (when (and cooked-file-link-highlight
             (<= (count-lines beg end) cooked-file-link-scan-limit))
    (let ((known (make-hash-table :test #'equal)))
      (save-excursion
        (goto-char beg)
        (while (re-search-forward cooked-file-link--candidate-regexp end t)
          (let* ((from (match-beginning 0))
                 (to (match-end 0))
                 (string (match-string-no-properties 0)))
            (pcase-let ((`(,name ,_line ,_col) (cooked-file-link--split string)))
              ;; What the child named, and what goto-addr read out of the text,
              ;; both outrank what this guessed from its shape.  Asking as
              ;; `guessed' rather than anonymously is what makes that a fact
              ;; about this layer's own rank rather than one written into the
              ;; base layer -- see `cooked-link-claim-functions'.
              (unless (or (string-match-p cooked-file-link--number-regexp name)
                          (cooked-link--claimed-p from to 'guessed))
                (let ((file (with-memoization (gethash name known)
                              (or (cooked-file-link--exists name) 'none))))
                  (unless (eq file 'none)
                    (cooked-link--propertize
                     from to
                     'cooked-file-link file
                     'help-echo "mouse-2, C-c RET: visit this file"
                     'face 'cooked-link)))))))))))

(add-hook 'cooked-link-follow-functions #'cooked-file-link-follow)
(add-hook 'cooked-link-scan-functions #'cooked-file-link-scan)

;; Registered at the *end*, which is this layer's rank and not an accident of load
;; order: a guess from the shape of the text is the only claim that can be wrong
;; about what the text even is, so everything that read a destination outright
;; outranks it.  `add-to-list' with APPEND, and keyed on the symbol, so loading this
;; file twice does not stack two entries.
(unless (assq 'guessed cooked-link-claim-functions)
  (setq cooked-link-claim-functions
        (append cooked-link-claim-functions
                (list (cons 'guessed #'cooked-file-link--claim-p)))))

;;;; thing-at-point, the half only this layer can supply

;; `filename' and `existing-filename' cannot be contributed from cooked-link.el:
;; deciding that `src/lib.rs' is a file rather than a word means asking the
;; filesystem, which is exactly the feature this optional layer *is*.  So the two
;; alists get their entries from two different tiers, and cooked-mode.el installs
;; whatever is present when a buffer is set up.  Nothing here is conditional on
;; embark: embark's file finder goes through `thing-at-point', so it and
;; `browse-url-at-point', ffap and `find-file's `M-n' all light up together.

(defun cooked-file-link--filename-at-point ()
  "The file name under point, whether or not it exists.

`filename\=' rather than `existing-filename\=': the caller asked what the text
*is*, not whether it resolves, so the split is done and the name returned
without a `stat\='.  `cooked-file-link--exists\=' is the other provider\='s job."
  (when-let* ((string (cooked-file-link--string-at-point)))
    (car (cooked-file-link--split string))))

(defun cooked-file-link--existing-filename-at-point ()
  "The file under point, resolved, or nil if nothing there is a file.

Returns the *resolved* name -- `cooked-file-link--exists\=' has already tried
`default-directory\=' and then the project root -- because a bare `src/lib.rs\='
handed to `find-file\=' from some other buffer would not find anything.  What
makes the answer useful is that it is absolute."
  (car (cooked-file-link--at-point)))

(defun cooked-file-link--filename-bounds-at-point ()
  "Bounds of the file name under point, or nil.

`ffap-string-at-point\=' records what it matched in
`ffap-string-at-point-region\=', so the bounds come from the same pass that
produced the string rather than from a second, possibly disagreeing, one.  The
trailing `:LINE:COL\=' is included: it is part of the thing the user pointed at,
and a caller wanting only the name has the `filename\=' provider for that."
  (when (cooked-file-link--string-at-point)
    (let ((region ffap-string-at-point-region))
      (when (and (car region) (cadr region))
        (cons (car region) (cadr region))))))

(defun cooked-file-link--file-name-at-point ()
  "Entry for `file-name-at-point-functions\='.

What `find-file\=' offers as the `M-n\=' default, and what ffap consults.  The
existing file rather than the guess, because this hook\='s callers use the answer
to *open* something."
  (cooked-file-link--existing-filename-at-point))

(dolist (entry (list (cons 'filename #'cooked-file-link--filename-at-point)
                     (cons 'existing-filename
                           #'cooked-file-link--existing-filename-at-point)))
  (add-to-list 'cooked-thing-at-point-providers entry))

(dolist (thing '(filename existing-filename))
  (add-to-list 'cooked-bounds-of-thing-at-point-providers
               (cons thing #'cooked-file-link--filename-bounds-at-point)))

(add-to-list 'cooked-file-name-at-point-functions
             #'cooked-file-link--file-name-at-point)

(provide 'cooked-file-link)

;;; cooked-file-link.el ends here
