;;; cooked-comint.el --- a VT filter for any comint buffer -*- lexical-binding: t; -*-

;;; Commentary:

;; `cooked-mode' is a terminal, and `cooked-process.el' hands a build's output to a
;; consumer that never wanted one.  This is the third thing the emulator can be: a
;; filter on somebody else's comint buffer, which already works and would only like to
;; be told what the escape sequences in it meant.  `M-x shell', `run-python',
;; `sql-interactive-mode', `inferior-ess', `gud' -- all of them are comint, and all of
;; them read their child's output today with `ansi-color', which is a regexp over
;; colours and blind to everything else.
;;
;; The whole of the mechanism is `comint-preoutput-filter-functions', a string-to-string
;; hook.  Nothing here inserts anything, moves `process-mark', or has an opinion about
;; `comint-last-input-end', field boundaries or `comint-move-point-for-output'.  comint
;; does all of that afterwards exactly as it always did; the only difference is which
;; string it is handed.
;;
;; ## A sibling of cooked-process.el, not a layer on cooked.el
;;
;; This file requires `cooked-util', `cooked-face' and `cooked-module' and nothing else
;; of cooked's.
;; That is a constraint rather than an accident, and `cooked-tests-comint' has a test
;; that fails if it is ever broken.  There is no session here: no pty, no grid, no
;; keymap, no input region, no `cooked-mode'.  Requiring `cooked.el' would pull all of
;; that in behind a filter whose entire job is to be one function on a hook -- and, more
;; to the point, it would put a *second* thing in the buffer that believes it knows
;; where the process mark should be.  See docs/DESIGN.md's layering section.
;;
;; What it does share is the two things worth sharing.  The parse is the emulator's own,
;; through `cooked--filter-feed' -- so an escape sequence split across two reads costs
;; nothing, which is the entire argument for owning a parser rather than a regexp.  And
;; the colours go through `cooked--do-style-spans', the same packed span format, the
;; same rendition ids and the same per-buffer faces the terminal uses, so a rendition
;; looks the same in a shell buffer as it does in a cooked one.
;;
;; ## What the child's control characters actually do here
;;
;; `cooked-process.el' states the case this exists for:
;;
;;   $ printf 'abcdefghij\rXYZ\n'
;;   XYZ           # comint: the CR deleted to the start of the line
;;   XYZdefghij    # here: the CR moved the cursor and XYZ overwrote
;;
;; The resolution happens in Rust, in a one-row line buffer -- src/emu/stream.rs, whose
;; commentary is the other half of this one.  CR sets the column, BS steps back, TAB
;; advances to a stop, `CSI K' erases, `CSI G' addresses, `CSI X' blanks, `CSI P' and
;; `CSI @' close and open a gap.  A line is handed over the instant its newline arrives,
;; so there is none of the retirement latency a grid would impose, and the *open* line is
;; handed over at the end of every chunk, so a prompt appears when the child writes it
;; rather than when the next line ends.
;;
;; `comint-inhibit-carriage-motion' is therefore set: comint's own pass would find
;; nothing to do, and what it does to a `\r' is the wrong thing anyway.
;;
;; ## The one edit this makes to the buffer
;;
;; An open line is shown before it is finished, so a `\r' that rewrites it has to take
;; back what was already shown.  `cooked-comint--emit' deletes exactly those characters
;; from immediately before the process mark -- and only after checking that they are
;; still the characters it put there.  Between two chunks comint may well have inserted
;; the user's input, which is what happens at every prompt; the check notices, the
;; deletion does not happen, and the core starts the child's next output on a line of
;; its own, the prompt's line having been ended by the input.  Nothing is ever deleted
;; that this file did not write.

;;; Code:

(require 'comint)
(require 'cooked-util)
(require 'cooked-face)
(require 'cooked-module)

(cooked--declare-core)

(defcustom cooked-comint-track-directory t
  "Whether `OSC 7' from the child sets `default-directory'.

A shell that reports its working directory this way -- cooked's own snippets do,
and fish 4 does it unprompted -- makes `shell-dirtrack-mode' and its regexps
unnecessary: the shell says where it is instead of Emacs guessing from what was
typed.  Set this to nil to keep the guessing, or to keep the directory still."
  :type 'boolean
  :group 'cooked)

(defvar-local cooked-comint--core-filter nil
  "This buffer's parser handle, from `cooked--make-filter', or nil before output.

Buffer-local because the state it holds is the child's: a pen that persists
across chunks, an open line, and a table of hyperlink destinations.  Made by
`cooked-comint--core' when the first chunk arrives rather than when the mode
is turned on; that docstring says why.")

(defvar-local cooked-comint--open ""
  "The characters of the open line this filter last handed to comint.

What makes a retraction safe.  The core says how many characters of it are no
longer true; this says what they were, so that the deletion can be declined
when the buffer no longer ends in them -- which is what comint inserting the
user's input looks like from here.  Empty whenever the last thing emitted ended
a line, which is most of the time.")

(defvar-local cooked-comint--open-start nil
  "A marker where `cooked-comint--open' begins in the buffer, or nil.

The text is not enough to tell that the buffer still ends in the open line
when the open line has no text.  A prompt of `\\t' or `ESC [ 5 C' leaves one,
and the buffer ends in the empty string whatever comint inserts after it.  So
the place is kept too: comint inserting the user\='s input at the process mark
leaves a marker before the input, and the distance to the mark stops being the
open line\='s length.

Placed by `cooked-comint--place-open-start' once comint has inserted what the
filter returned, since the open line may begin inside that text.  Nil while
that is still to happen, and `cooked-comint--intact-p' then goes by the text
alone.")

(defvar-local cooked-comint--placing nil
  "Whether the filter has returned text whose open line is not yet placed.
See `cooked-comint--open-start'.")

;;;; Output

(defun cooked-comint--tail (text)
  "The open line TEXT leaves behind: everything after its last newline.

Read off TEXT rather than tracked, because after an insert the buffer's own
answer to \"what is the unfinished line?\" is exactly this, and the two must not
be able to disagree.

Found by stepping `string-search' from one newline to the next, which scans
in C and visits each newline once.  Emacs has no search from the end of a
string, and the regexp this replaced, a match for the characters before the
end, was retried from every position of every line: a chunk of 800 lines of 80
columns cost it 20 ms, and a 10,000-character line then a prompt cost 375 ms."
  (let ((start 0)
        newline)
    (while (setq newline (string-search "\n" text start))
      (setq start (1+ newline)))
    (cons (substring text start)
          ;; Whether TEXT closed a line at all, which decides whether the
          ;; previous open line is finished or merely extended.
          (> start 0))))

(defun cooked-comint--intact-p (mark)
  "Whether `cooked-comint--open' is still the text just before MARK.

Asked of the place as well as the text: the open line must begin at
`cooked-comint--open-start\=' when that is known.  A prompt with no text on
its line otherwise matches the end of any buffer.

The one question that decides whether anything may be deleted.  A nil answer
is not an error and not rare: comint inserts what the user typed at the process
mark, so at every prompt the characters this filter emitted for that prompt have
something after them by the time the child speaks again.

Widened, because comint has not widened yet -- the preoutput filters run before
the `save-restriction' in `comint-output-filter' -- and the process mark is
allowed to be outside a narrowing."
  (save-restriction
    (widen)
    (let ((from (- mark (length cooked-comint--open)))
          (start (and cooked-comint--open-start
                      (marker-position cooked-comint--open-start))))
      (and (>= from (point-min))
           (or (null start) (= start from))
           (string= cooked-comint--open
                    (buffer-substring-no-properties from mark))))))

(defun cooked-comint--propertize (text styles links)
  "Apply STYLES and LINKS to TEXT and return it.

STYLES is the packed span format `Block::push_style' writes and
`cooked--do-style-spans' walks, the terminal's own format read by its own
walker, naming renditions by the ids the filter announced beside it -- which
`cooked-comint--emit' has installed in this buffer by the time this runs.

Both `face' and `font-lock-face' are set, to the same value, and that pair is
argued out at length in `cooked-process--text': neither alone covers both
consumers.  A buffer that fontifies strips a bare `face' from every region it
touches, and a buffer with no font-lock at all never installs the
`char-property-alias-alist' entry that would make `font-lock-face' visible.
`ansi-color' picks one of the two by asking whether `font-lock-mode' is on *at
the moment the text arrives*, which is wrong under any later change of mind;
setting both costs one extra property interval and is correct under every
ordering, because the alias is consulted only where `face' is absent.

A LINKS entry is (START END URI) for an `OSC 8' hyperlink, and the destination
arrives as the URI itself rather than as an id: an id resolves through a table
belonging to a session, and there is none here.  It becomes `help-echo' and
nothing more.  A keymap would be the obvious next step and is deliberately not
taken -- this is a buffer whose keys belong to comint, and binding RET or mouse
clicks over the child's output would take them from it."
  (cooked--do-style-spans (from to face _link styles)
    (when face
      (put-text-property from to 'face face text)
      (put-text-property from to 'font-lock-face face text)))
  (pcase-dolist (`(,from ,to ,uri) links)
    (put-text-property from to 'help-echo uri text))
  text)

(defun cooked-comint--set-directory (url)
  "Track the child's working directory from an OSC 7 URL.

A foreign host is refused, and refused *before* anything looks at the path.
The order is the whole of the care this needs, and `cooked--set-directory'
explains it from the terminal's side: a `cat' of a hostile file can put any
URL here, and `file-directory-p' on a TRAMP name is itself the connection.
`cooked--local-name' is the second guard, for a path that names a remote file
without saying so in the authority."
  (pcase-let ((`(,host . ,path) (and cooked-comint-track-directory
                                     (cooked--parse-file-url url))))
    ;; A named host that is not this one is reporting honestly about a directory
    ;; that is not ours to resolve: the same path here would name a different
    ;; file, or -- worse and more often -- a local file of the same name on a
    ;; tree kept roughly in step with it.  Which names are this one is the same
    ;; question the terminal asks, answered by the same function.
    (when (and path (cooked--local-host-p host))
      (when-let* ((name (cooked--local-name path))
                  (dir (file-name-as-directory name))
                  ((file-directory-p dir)))
        (setq default-directory dir)))))

(defun cooked-comint--emit (string)
  "Resolve STRING through this filter, returning what comint should insert.

The retraction is the only thing here that touches the buffer, and it happens
before the return value is inserted at the same place: the core reports how many
characters of the open line it is taking back, and they are deleted from
immediately before the process mark.  The core is told first, in RETRACT-P,
whether they are still there to delete -- so a chunk arriving after comint
inserted the user's input starts a line of its own after that input rather than
correcting the prompt before it, and the deletion below cannot run at all.

Nothing is deleted that this filter did not emit, and nothing is deleted across
a newline: `cooked-comint--open' holds one unfinished line at most."
  (let* ((proc (get-buffer-process (current-buffer)))
         (mark (and proc (process-mark proc)))
         (intact (and mark
                      (progn
                        ;; Before the first text, the open line is the empty one
                        ;; at the mark, whatever the buffer held before this mode.
                        (unless (or cooked-comint--open-start cooked-comint--placing)
                          (setq cooked-comint--open-start (copy-marker mark)))
                        (cooked-comint--intact-p mark))))
         (result (cooked--filter-feed cooked-comint--core-filter string intact)))
    (unless intact
      ;; The core gave the old line up before parsing, whether or not anything came
      ;; of the chunk, so the open line is now an empty one at the mark.  Forgotten
      ;; here and not only when there is text, or a chunk that only moved the cursor
      ;; would leave the check failing, and the next chunk would give up the line the
      ;; move was on.
      (cooked-comint--forget-open-line)
      (when mark
        (setq cooked-comint--open-start (copy-marker mark))))
    (if (null result)
        ""
      (pcase-let* ((`(,retract ,text ,styles ,links ,directory ,table) result)
                   (`(,tail . ,closed) (cooked-comint--tail text)))
        (when (> retract 0)
          (save-restriction
            (widen)
            (let ((inhibit-read-only t))
              (delete-region (- mark retract) mark))))
        (setq cooked-comint--open
              (if (or closed (not intact))
                  ;; The old line is finished, by a newline in TEXT or by the
                  ;; user's input, which the core gave it up for before parsing.
                  ;; Either way the open line is the one TEXT started.
                  tail
                ;; The line was extended rather than finished, so what comint now
                ;; holds for it is what was left after the retraction plus what is
                ;; about to be inserted.
                (concat (substring cooked-comint--open
                                   0 (- (length cooked-comint--open) retract))
                        tail)))
        (when cooked-comint--open-start
          (set-marker cooked-comint--open-start nil)
          (setq cooked-comint--open-start nil))
        (setq cooked-comint--placing t)
        (when directory (cooked-comint--set-directory directory))
        (cooked--install-styles table)
        (cooked-comint--propertize text styles links)))))

(defun cooked-comint--place-open-start (_string)
  "Mark where the open line begins, now comint has inserted it.

On `comint-output-filter-functions\=', which comint runs after every insertion
with the process mark moved past the text, so the open line is the
`cooked-comint--open\=' characters before the mark.  Only once per text the
filter returned: a later run, for a chunk the filter swallowed whole, would
find the user\='s input before the mark and place the open line after it."
  (when-let* ((cooked-comint--placing)
              (proc (get-buffer-process (current-buffer))))
    (setq cooked-comint--placing nil
          cooked-comint--open-start
          (save-restriction
            (widen)
            (copy-marker (- (process-mark proc) (length cooked-comint--open)))))))

(defun cooked-comint--core ()
  "This buffer's parser handle, loading the native core for it if need be.

Called for the first chunk of output and not when the mode is turned on.  The
global mode turns this one on from `after-change-major-mode-hook' in every
comint buffer, and loading there would make every `M-x shell' signal at mode
setup on an install with no core.  Loading here never builds, either: in a
checkout whose core is out of date, `cooked--load-module' would otherwise run
`cargo build' inside a process filter, with the shell's output held up behind
it.

A core that cannot be had turns the mode off, says why once, and returns nil,
so the chunk and every later one reach comint as they would without this file."
  (or cooked-comint--core-filter
      (condition-case err
          (progn
            (cooked--load-module 'no-build)
            (setq cooked-comint--core-filter (cooked--make-filter)))
        (error
         (message "cooked-comint: %s; leaving %s to comint"
                  (error-message-string err) (buffer-name))
         (cooked-comint-mode -1)
         nil))))

(defun cooked-comint--filter (string)
  "Hand STRING to the emulator, on `comint-preoutput-filter-functions'.

Guarded, because comint has no guard of its own here: a signal from a preoutput
filter propagates out of the process filter, where Emacs discards it, and the
symptom is a buffer that quietly stops filling.  A failure gives the chunk back
untouched, so the worst case is the escape sequences comint would have shown
before this file existed."
  (condition-case err
      (if (cooked-comint--core)
          (cooked-comint--emit string)
        string)
    (error
     (message "cooked-comint: %S" err)
     string)))

;;;; The mode

;;;###autoload
(define-minor-mode cooked-comint-mode
  "Read this comint buffer's output with cooked's terminal emulator.

Carriage returns, backspaces, tabs and erases are resolved against the line
they address rather than deleted or passed through, so a child that overwrites
part of a line shows what it meant to show; the child's colours arrive as
faces; and `OSC 7' sets `default-directory' without a prompt regexp having to
guess at it.

A whole VT parser rather than a regexp, which matters for the ordinary reason
that a chunk of output can end in the middle of an escape sequence -- and for
the extraordinary one that a regexp cannot resolve a cursor movement at all.

Turning this on stops `ansi-color' from processing this buffer's output, there
being nothing left for it to find.  Turning it off does not start it again once
output has arrived: the buffer already holds text this filter resolved, and the
two would then disagree about what is in it.

The native core is loaded when the first output arrives, not here, and a core
that is missing or needs building turns this off again; see
`cooked-comint--core'."
  :lighter " cooked"
  (if cooked-comint-mode
      (progn
        (setq cooked-comint--core-filter nil)
        (cooked-comint--forget-open-line)
        (add-hook 'comint-output-filter-functions #'cooked-comint--place-open-start nil t)
        ;; comint's own pass over the chunk, which deletes to the start of the line
        ;; where a terminal overwrites.  There is nothing left for it to find in any
        ;; case: the string it would scan has had its carriage returns spent.
        (setq-local comint-inhibit-carriage-motion t)
        ;; `ansi-color-process-output' is in comint's *default* value of
        ;; `comint-output-filter-functions', not in any buffer's own copy, so there is
        ;; nothing here to remove -- a buffer-local `remove-hook' cannot reach a global
        ;; entry, and removing it globally would be this buffer deciding for every other
        ;; one.  Its own switch is what turns it off, and it is buffer-local here.  It
        ;; would find nothing to do in any case: the escape sequences are spent by the
        ;; time it looks.  This is about not walking every chunk twice to discover that.
        (setq-local ansi-color-for-comint-mode nil)
        (add-hook 'comint-preoutput-filter-functions #'cooked-comint--filter nil t))
    (remove-hook 'comint-preoutput-filter-functions #'cooked-comint--filter t)
    (remove-hook 'comint-output-filter-functions #'cooked-comint--place-open-start t)
    (kill-local-variable 'comint-inhibit-carriage-motion)
    ;; With no filter made, nothing in the buffer was resolved here, so there is
    ;; nothing for `ansi-color' to disagree with.  This is the path a missing core
    ;; takes, and without it that buffer would show escape sequences raw.
    (unless cooked-comint--core-filter
      (kill-local-variable 'ansi-color-for-comint-mode))
    (setq cooked-comint--core-filter nil)
    (cooked-comint--forget-open-line)))

(defun cooked-comint--forget-open-line ()
  "Forget the open line, its text and its place both."
  (when cooked-comint--open-start
    (set-marker cooked-comint--open-start nil))
  (setq cooked-comint--open ""
        cooked-comint--open-start nil
        cooked-comint--placing nil))

(defun cooked-comint--turn-on ()
  "Enable `cooked-comint-mode' if this buffer is a comint buffer.

Not in a `cooked-mode' buffer, which derives from `comint-mode' and is a
terminal already.  Its output reaches the grid through its own wake filter, so
`comint-preoutput-filter-functions' never runs there, and turning this on would
only make a parser nothing feeds and add a second \" cooked\" to the mode line."
  (when (and (derived-mode-p 'comint-mode)
             (not (derived-mode-p 'cooked-mode)))
    (cooked-comint-mode 1)))

;;;###autoload
(define-globalized-minor-mode cooked-comint-global-mode
  cooked-comint-mode cooked-comint--turn-on
  :group 'cooked)

(provide 'cooked-comint)
;;; cooked-comint.el ends here
