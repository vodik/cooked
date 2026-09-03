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
either a slash in it or an extension on it to qualify.")

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

`ffap-file-exists-string' rather than `file-exists-p' so that ffap's own
`ffap-alist'-free notion of a readable name applies, including its handling of
a remote `default-directory'.

Nothing resolves once the child has said it is on another host.  A build log
from a remote tree is full of names that exist here too, at the same paths, in
a checkout that is not the one that produced the log -- so the link would open,
land in a real file, and be the wrong file.  Highlighting nothing says less
than cooked knows, and everything it says is true."
  (and (not (string-empty-p name))
       (not (cooked--foreign-host-p))
       (or (ffap-file-exists-string name)
           (when-let* ((project (project-current nil))
                       (root (project-root project))
                       (default-directory root))
             (ffap-file-exists-string name)))))

(defun cooked-file-link--at-point ()
  "The file under point as (FILE LINE COL), or nil.

`ffap-string-at-point' with the `file' mode only.  Nothing here consults
`ffap-alist', `ffap-url-at-point' or `ffap-machine-p' -- see this file's
Commentary for why that last one in particular."
  (when-let* ((string (ffap-string-at-point 'file)))
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
              (unless (or (get-text-property from 'cooked-link-id)
                          (seq-some (lambda (o) (overlay-get o 'goto-address))
                                    (overlays-at from)))
                (let ((file (with-memoization (gethash name known)
                              (or (cooked-file-link--exists name) 'none))))
                  (unless (eq file 'none)
                    (add-text-properties
                     from to
                     (list 'cooked-file-link file
                           'mouse-face 'highlight
                           'follow-link t
                           'help-echo "mouse-2, C-c RET: visit this file"
                           'keymap cooked-link-map
                           'face 'cooked-link))))))))))))

(add-hook 'cooked-link-follow-functions #'cooked-file-link-follow)
(add-hook 'cooked-link-scan-functions #'cooked-file-link-scan)

(provide 'cooked-file-link)

;;; cooked-file-link.el ends here
