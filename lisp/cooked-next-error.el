;;; cooked-next-error.el --- next-error over a command's output -*- lexical-binding: t; -*-

;;; Commentary:

;; Opt-in, and worth understanding before you do:
;;
;;   (use-package cooked
;;     :commands (cooked cooked-other-window)
;;     :config (require 'cooked-next-error))
;;
;; With this loaded, \\[next-error] (`M-g M-n', `M-g M-p') walks the errors and
;; warnings in the most recently finished command's output, the same way it
;; walks a `*compilation*' buffer -- so `make', a build script, a linter, all
;; of it, run as an ordinary interactive command at the prompt rather than
;; through `compile'.
;;
;; This is deliberately not `compilation-mode' or `compilation-shell-minor-mode'.
;; Both come with machinery built for a buffer that only ever grows at
;; `point-max' and is reparsed incrementally as text arrives -- `compilation-locs'
;; (a weak hash of file structures whose leaves are markers into that buffer),
;; `compilation--parsed' (a marker recording how far the incremental parse has
;; got), an `after-change-functions' hook that keeps both current.  None of that
;; matches how this buffer behaves: `cooked--render-rows' deletes and reinserts
;; whole rows to repaint the live screen, which collapses any marker sitting in
;; one, and a command's output can sit finished-but-still-live for as long as it
;; takes for something to push it off the bottom of the grid.  Trusting a marker,
;; or a cache built against text that has since been repainted, is exactly the
;; failure mode to avoid.
;;
;; So this reparses from scratch on every call, using `compilation-parse-errors'
;; -- the pattern-matching engine `compilation-error-regexp-alist' drives, with
;; none of the incremental caching wrapped around it -- inside a fresh,
;; throwaway `compilation-locs' that is thrown away again the moment the call
;; returns.  What survives between calls is a (FILE LINE COLUMN) tuple naming
;; the error last visited, not a position: a tuple is still meaningful after a
;; repaint, where a marker would not be.  Command output here is one shell
;; command's worth, so the reparse is cheap enough to not be worth avoiding.

;;; Code:

(require 'cooked)
(require 'compile)
(require 'cl-lib)

(defvar-local cooked-next-error--current nil
  "The (FILE LINE COLUMN) key of the error last visited, or nil.

A tuple rather than a marker or an index into a cached match list: the match
list itself is rebuilt from scratch on every call (see the file commentary),
and a stored index would silently point at the wrong error if the rebuilt list
came out a different length -- output the child appended, an intervening
`cooked-delete-output', a straddling command whose live tail has since scrolled
into the safe prefix.  A tuple degrades honestly instead: if it is not found in
the fresh list, navigation just starts over from the nearer end.")

(defun cooked-next-error--command ()
  "The finished command `cooked-next-error-function' should search.

The command whose output point is inside, if any -- so parking in an older
command's scrollback and pressing \\[next-error] searches that one rather than
whatever ran most recently.  Otherwise the most recently finished command,
which is the ordinary \"I just ran make\" case.

Refuses outright, rather than guessing, when neither exists and something is
still running: parsing a command's output before `cooked--mark-command-end'
has recorded where it ends would mean parsing a moving target, and unlike the
text-object case in bugs.org (\"vic/vac\"), this is reached from an ordinary
interactive command, so a signal here is safe -- it cannot strand evil in a
stale visual selection the way one there did."
  (or (cooked--command-at (point))
      (car cooked--commands)
      (if cooked--command-start
          (user-error "cooked-next-error: command still running")
        (user-error "cooked-next-error: no command has finished yet"))))

(defun cooked-next-error--safe-region (command)
  "The prefix of COMMAND's output that is safe to parse, as a cons of positions.

Safe means already in protected scrollback -- `cooked--command-end-position'
below `cooked--screen-start-position' -- which `cooked--render-scrolled' never
revisits.  At or above the screen start, a drain can still rewrite the row a
match was found in before the error is ever visited, so a command whose output
straddles the boundary is clamped to its scrollback prefix and searched best
effort, rather than refusing outright: refusing would make \\[next-error]
useless for exactly the multi-screen build log it is most wanted for.

The cost of that choice, worth being honest about: a command whose output has
not yet scrolled off the live screen at all offers no safe prefix and searches
as empty, however finished it is.  See the `bugs.org' entry this implements
for why that is not a bug -- it is the same invariant the resize corruption
report settled."
  (let* ((region (cooked--command-region command))
         (beg (car region))
         (end (cdr region))
         (screen (cooked--screen-start-position)))
    (cons beg (if screen (min end screen) end))))

(defun cooked-next-error--parse-region (start end)
  "Parse errors in START..END and return them as a list of (POSITION . MESSAGE).

Reparses unconditionally: no attempt is made to reuse a previous call's text
properties or markers, per the file commentary.  `compilation-locs' is
rebound to a fresh hash table for the duration, the same initialization
`compilation-setup' gives a real compilation buffer, so
`compilation-parse-errors' has somewhere to build its file structures without
leaking them past this call or colliding with a real compilation buffer's own
table."
  (when (> end start)
    (let ((inhibit-read-only t)
          (compilation-locs (make-hash-table :test 'equal :weakness 'value))
          (case-fold-search compilation-error-case-fold-search))
      (save-excursion
        (save-restriction
          (widen)
          ;; Old properties from a previous call would otherwise make
          ;; `compilation-error-properties' think this text is already parsed
          ;; and skip it -- nothing here persists them, so nothing should be
          ;; left lying around to be misread that way.
          (compilation--remove-properties start end)
          (compilation-parse-errors start end)))
      (let (matches (pos start))
        (while (< pos end)
          (let ((msg (get-text-property pos 'compilation-message)))
            (when msg (push (cons pos msg) matches)))
          (setq pos (next-single-property-change pos 'compilation-message nil end)))
        (nreverse matches)))))

(defun cooked-next-error--key (loc)
  "A (FILE LINE COLUMN) key for LOC, stable across a fresh reparse."
  (let* ((spec (compilation--file-struct->file-spec (compilation--loc->file-struct loc)))
         (file (car spec))
         (dir (cadr spec)))
    (list (if (stringp file) (expand-file-name file (or dir default-directory)) file)
          (compilation--loc->line loc)
          (compilation--loc->col loc))))

(defun cooked-next-error--locate (matches key)
  "Index in MATCHES whose location matches KEY, or nil."
  (when key
    (cl-position-if (lambda (m)
                       (equal (cooked-next-error--key
                               (compilation--message->loc (cdr m)))
                              key))
                     matches)))

(defun cooked-next-error--visit (position message)
  "Visit the source location of MESSAGE, found at POSITION in this buffer."
  (let* ((loc (compilation--message->loc message))
         (end-loc (compilation--message->end-loc message))
         (marker (copy-marker position)))
    (compilation--update-markers loc marker compilation-error-screen-columns
                                 compilation-first-column)
    (compilation-goto-locus marker (compilation--loc->marker loc)
                            (and end-loc (compilation--loc->marker end-loc)))))

(defun cooked-next-error-function (n reset)
  "`next-error-function' for a cooked buffer.

Move by N errors, from the first when RESET is non-nil.  See the file
commentary."
  (let* ((command (cooked-next-error--command))
         (region (cooked-next-error--safe-region command))
         (matches (cooked-next-error--parse-region (car region) (cdr region))))
    (unless matches
      (if (< (cdr region) (cdr (cooked--command-region command)))
          (user-error "cooked-next-error: no errors found (output has not scrolled into history yet)")
        (user-error "cooked-next-error: no errors found")))
    (when reset (setq cooked-next-error--current nil))
    (let* ((from (and cooked-next-error--current
                      (cooked-next-error--locate matches cooked-next-error--current)))
           (index (+ (or from -1) (if (and (zerop n) (not from)) 1 n))))
      (when (< index 0) (user-error "cooked-next-error: no previous error"))
      (when (>= index (length matches)) (user-error "cooked-next-error: no next error"))
      (let* ((match (nth index matches))
             (loc (compilation--message->loc (cdr match))))
        (setq cooked-next-error--current (cooked-next-error--key loc))
        (cooked-next-error--visit (car match) (cdr match))))))

(defun cooked-next-error--setup ()
  "Make this buffer a `next-error' target over its own commands' output."
  (setq-local next-error-function #'cooked-next-error-function))

(add-hook 'cooked-mode-hook #'cooked-next-error--setup)

(provide 'cooked-next-error)
;;; cooked-next-error.el ends here
