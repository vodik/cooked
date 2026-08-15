;;; cooked.el --- A terminal that hands the keyboard back -*- lexical-binding: t; -*-

;; Author: Simon <simongmzlj@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: terminals, processes
;; URL: https://github.com/simon/cooked

;;; Commentary:

;; A terminal emulator whose input model follows what the child actually wants.
;; The kernel's line discipline says when a program is doing a canonical read;
;; OSC 133 says when the shell is at a prompt.  In either case Emacs owns the
;; line and you edit it as you would any buffer.  Otherwise keys are forwarded
;; verbatim and the emulator behaves as a terminal.
;;
;;   (use-package cooked
;;     :load-path "/path/to/cooked/lisp"
;;     :commands (cooked cooked-other-window)
;;     :custom (cooked-buffer-name "*cooked: %s*")
;;     :config
;;     (require 'cooked-evil)        ; opt in to evil state syncing
;;     (require 'cooked-osc-eval))   ; opt in to the OSC 51 command channel
;;
;; Emulation happens in a Rust module, built on first use with cargo.
;;
;; This file is the core: rendering, colours, and the OSC handlers that are inert
;; enough to be on by default.  `cooked-mode' has the interaction; `cooked-evil'
;; and `cooked-osc-eval' are separate because you should choose them.

;; The buffer is the scrollback.  Rows that scroll off the emulator's screen are
;; handed over once and become ordinary buffer text; the last `cooked--rows' lines
;; are the live screen, rewritten from damage reports.
;;
;; Invariant: buffer text equals the grid, plus any pending input rendered at the
;; cursor.  Every redisplay lifts the pending input out, applies the grid, and puts
;; it back.

;;; Code:

(require 'cl-lib)
(require 'face-remap)
(require 'url-util)

(defgroup cooked nil
  "A terminal emulator that yields to Emacs when the child wants a line."
  :group 'processes
  :prefix "cooked-")

(defconst cooked--attr-bold 1)
(defconst cooked--attr-faint 2)
(defconst cooked--attr-italic 4)
(defconst cooked--attr-underline 8)
(defconst cooked--attr-blink 16)
(defconst cooked--attr-reverse 32)
(defconst cooked--attr-conceal 64)
(defconst cooked--attr-strike 128)

(defcustom cooked-color-names
  ["black" "red3" "green3" "yellow3" "blue2" "magenta3" "cyan3" "gray90"
   "gray50" "red" "green" "yellow" "blue" "magenta" "cyan" "white"]
  "Fallback palette for the sixteen ANSI colors.
Consulted only where the corresponding `ansi-color-' face gives no foreground,
so a theme that styles those faces wins."
  :type '(vector (repeat :inline t string))
  :group 'cooked)

(defconst cooked--ansi-faces
  [ansi-color-black ansi-color-red ansi-color-green ansi-color-yellow
   ansi-color-blue ansi-color-magenta ansi-color-cyan ansi-color-white
   ansi-color-bright-black ansi-color-bright-red ansi-color-bright-green
   ansi-color-bright-yellow ansi-color-bright-blue ansi-color-bright-magenta
   ansi-color-bright-cyan ansi-color-bright-white]
  "Faces the theme is expected to style, indexed by ANSI color number.")

(defvar-local cooked--session nil "Handle returned by `cooked--spawn'.")
(defvar-local cooked--wake nil "Pipe process Rust pokes when output is pending.")
(defvar-local cooked--rows 24)
(defvar-local cooked--cols 80)
(defvar-local cooked--screen-start nil
  "Marker at the first line of the live screen; everything before is scrollback.")
(defvar-local cooked--cursor '(0 0 t))
(defvar-local cooked--alt nil)
(defvar-local cooked--app-cursor nil
  "DECCKM: send cursor keys as SS3, which is what `smkx' asks for.")
(defvar-local cooked--keys 'legacy
  "How to spell modified Return, Tab, Escape and Backspace for this child.

One of `legacy', `modify-other' or `kitty', as negotiated by the child itself —
see `cooked--literal-codes' for why this cannot simply be assumed.")
(defvar-local cooked--title nil "Title the child last set, via OSC 0 or 2.")
(defvar-local cooked--hyperlink nil "Current OSC 8 hyperlink target, if any.")
(defvar-local cooked--annotation nil "Prompt annotation from OSC 51;A.")
(defvar-local cooked--mouse nil "Whether the child asked for mouse reports.")
(defvar-local cooked--mouse-sgr nil "Whether to encode mouse reports as SGR (1006).")
(defvar-local cooked--mode 'cooked)
(defvar-local cooked--exit nil)
(defvar-local cooked--face-cache nil)

;; Rendering lives here, interaction in cooked-mode.el, and redisplay has to call
;; into it: applying an update needs to know who owns the keyboard.
(defvar cooked--input-start)
(declare-function cooked--take-pending-input "cooked-mode")
(declare-function cooked--restore-pending-input "cooked-mode")
(declare-function cooked--point-after-input "cooked-mode")
(declare-function cooked--input-state-p "cooked-mode")
(declare-function cooked--set-mode "cooked-mode")
(declare-function cooked--semantic "cooked-mode")
(declare-function cooked--on-exit "cooked-mode")
(declare-function cooked--rename-to-title "cooked-mode")
(defvar cooked-rejoin-wrapped-lines)

(declare-function cooked--spawn "cooked-core")
(declare-function cooked--drain "cooked-core")
(declare-function cooked--send "cooked-core")
(declare-function cooked--reply-osc "cooked-core")
(declare-function cooked--resize "cooked-core")
(declare-function cooked--mode "cooked-core")
(declare-function cooked--prompt-text "cooked-core")
(declare-function cooked--signal "cooked-core")
(declare-function cooked--pid "cooked-core")
(declare-function cooked--live-p "cooked-core")
(declare-function cooked--bracketed-paste-p "cooked-core")
(declare-function cooked--kill "cooked-core")

;; `signal' refuses a symbol with no `error-conditions' property, so the native
;; core's `io_error' would otherwise itself fail with "Invalid error symbol"
;; the first time a pty operation errors.
(define-error 'cooked-error "cooked: I/O error")

(defun cooked-session-p (object)
  "Whether OBJECT is a session handle made by the native core.

Exists mostly so the `wrong-type-argument' the core signals names a
predicate that resolves.  The core does the real check, comparing the
user-pointer's finalizer against its own; Emacs itself cannot tell one
module's user-pointer from another's."
  (and (user-ptrp object) (ignore-errors (integerp (cooked--pid object)))))

(defconst cooked--source-directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory holding this file, captured at load time.")

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

(defun cooked--root ()
  "Top of the source tree."
  (file-name-directory (directory-file-name cooked--source-directory)))

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

(defun cooked--load-module ()
  "Load the native core, building it if necessary."
  (unless (featurep 'cooked-core)
    (unless module-file-suffix
      (error "cooked: this Emacs was built without dynamic module support"))
    (let* ((root (cooked--root))
           ;; Not a hardcoded \".so\": cargo names a cdylib \"libcooked.dylib\" on macOS,
           ;; which is exactly what `module-file-suffix' reports there.
           (built (or cooked-native-module
                      (expand-file-name (concat "target/release/libcooked" module-file-suffix)
                                        root))))
      (unless (file-exists-p built)
        (message "cooked: building native core...")
        (let ((default-directory root))
          (unless (zerop (call-process "cargo" nil "*cooked-build*" nil "build" "--release"))
            (pop-to-buffer "*cooked-build*")
            (error "cooked: cargo build failed"))))
      (module-load built))))

;;;; Colors and faces

(defun cooked--xterm-256 (index)
  "Hex string for xterm 256-color INDEX at or above 16."
  (if (>= index 232)
      (let ((v (+ 8 (* 10 (- index 232)))))
        (format "#%02x%02x%02x" v v v))
    (let* ((n (- index 16))
           (step (lambda (c) (if (zerop c) 0 (+ 55 (* 40 c))))))
      (format "#%02x%02x%02x"
              (funcall step (/ n 36))
              (funcall step (% (/ n 6) 6))
              (funcall step (% n 6))))))

(defun cooked--color (spec)
  "Emacs color for SPEC: nil, an index, or a list of R G B."
  (cond ((null spec) nil)
        ((consp spec) (apply #'format "#%02x%02x%02x" spec))
        ((< spec 16) (or (face-foreground (aref cooked--ansi-faces spec) nil t)
                         (aref cooked-color-names spec)))
        (t (cooked--xterm-256 spec))))

(defun cooked--flush-face-cache (&rest _)
  "Forget resolved colors so a new theme applies to subsequent output."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and (derived-mode-p 'cooked-mode) (hash-table-p cooked--face-cache))
        (clrhash cooked--face-cache)))))

;; `enable-theme-functions' arrived in Emacs 29, and `add-hook' on an unbound variable
;; quietly defines it rather than failing — so on 28 this looked fine and did nothing.
(if (boundp 'enable-theme-functions)
    (progn
      (add-hook 'enable-theme-functions #'cooked--flush-face-cache)
      (add-hook 'disable-theme-functions #'cooked--flush-face-cache))
  (advice-add 'enable-theme :after #'cooked--flush-face-cache)
  (advice-add 'disable-theme :after #'cooked--flush-face-cache))

(defun cooked--face (fg bg attrs)
  "Face plist for FG, BG and the ATTRS bitmask, memoized per buffer."
  (let ((key (list fg bg attrs)))
    (or (gethash key cooked--face-cache)
        (puthash key
                 (let* ((reverse (/= 0 (logand attrs cooked--attr-reverse)))
                        (fg* (cooked--color (if reverse bg fg)))
                        (bg* (cooked--color (if reverse fg bg)))
                        (face nil))
                   (when fg* (setq face (plist-put face :foreground fg*)))
                   (when bg* (setq face (plist-put face :background bg*)))
                   (when (/= 0 (logand attrs cooked--attr-bold))
                     (setq face (plist-put face :weight 'bold)))
                   (when (/= 0 (logand attrs cooked--attr-faint))
                     (setq face (plist-put face :weight 'light)))
                   (when (/= 0 (logand attrs cooked--attr-italic))
                     (setq face (plist-put face :slant 'italic)))
                   (when (/= 0 (logand attrs cooked--attr-underline))
                     (setq face (plist-put face :underline t)))
                   (when (/= 0 (logand attrs cooked--attr-strike))
                     (setq face (plist-put face :strike-through t)))
                   (when (/= 0 (logand attrs cooked--attr-conceal))
                     (setq face (plist-put face :foreground (or bg* (face-background 'default)))))
                   face)
                 cooked--face-cache))))

(defun cooked--insert-runs (runs)
  "Insert RUNS, each (TEXT FG BG ATTRS), with faces applied.

Both `face' and `font-lock-face' are set.  comint leaves `font-lock-defaults'
at (nil t), so any fontification of this buffer unfontifies it first and would
strip a bare `face' property — taking every colour with it."
  (dolist (run runs)
    (pcase-let ((`(,text ,fg ,bg ,attrs) run))
      (let ((start (point)))
        (insert text)
        (when-let* ((face (cooked--face fg bg attrs)))
          (add-text-properties start (point) (list 'face face 'font-lock-face face)))))))

;;;; Rendering

(defun cooked--goto-screen-row (index &optional extend)
  "Move point to the start of screen row INDEX.
With EXTEND, add the lines needed to reach it; the screen region is trimmed to
its content, so a row below the cursor may not have a line yet.  Without EXTEND
this only moves point, which keeps queries free of side effects."
  (goto-char cooked--screen-start)
  (let ((missing (forward-line index)))
    ;; `forward-line' counts a final line that lacks a newline as one line
    ;; successfully moved, so it can report success while leaving point at that
    ;; line's end rather than at the start of the row we asked for.  Rendering
    ;; the next row then appends to the previous one — which is how a command's
    ;; output and the following prompt end up sharing a line.
    (unless (bolp)
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
    (cooked--goto-screen-row (nth 0 cooked--cursor) 'extend)
    (let ((short (- (nth 1 cooked--cursor) (- (line-end-position) (point)))))
      (when (> short 0)
        (goto-char (line-end-position))
        (insert (make-string short ?\s))))))

(defun cooked--render-scrolled (rows)
  "Append ROWS to the scrollback above the live screen.
The marker is advanced explicitly rather than by insertion type:
rendering screen row 0 also inserts at this position, and an
auto-advancing marker would drift into the screen region."
  (save-excursion
    (goto-char cooked--screen-start)
    ;; ROWS arrives pre-assembled as (TEXT SPAN...), so this is one insert of plain
    ;; text plus a property call only where styling exists.  Note that building a
    ;; propertized string in Lisp and inserting that instead measures three times
    ;; slower: `concat' on propertized strings makes Emacs copy and merge property
    ;; intervals over and over.
    (pcase-let ((`(,text . ,spans) rows))
      (let ((start (point)))
        (insert text)
        (dolist (span spans)
          (pcase-let ((`(,from ,to ,fg ,bg ,attrs) span))
            (when-let* ((face (cooked--face fg bg attrs)))
              (add-text-properties (+ start from) (+ start to)
                                   (list 'face face 'font-lock-face face)))))
        ;; Scrollback never changes again, so it is protected once, here, rather
        ;; than re-swept on every redisplay.
        (add-text-properties start (point)
                             '(cooked-scrollback t read-only t
                               front-sticky (read-only) rear-nonsticky (read-only)))))
    (set-marker cooked--screen-start (point))))

(defun cooked--fit-screen ()
  "Shape the screen region to the emulator.

On the alternate screen a terminal is a fixed rectangle, so the region must hold
exactly `cooked--rows' lines — trimming to content would fight a full-screen
program, and leaving the old lines in place is why a shrunk window kept showing
stale rows."
  (if cooked--alt
      (save-excursion
        (cooked--goto-screen-row cooked--rows 'extend)
        (delete-region (point) (point-max)))
    (cooked--trim-screen)))

(defun cooked--trim-screen ()
  "Drop blank lines below the cursor so the buffer reads as a transcript.
A terminal shows a fixed rectangle; a buffer should not carry two dozen empty
lines under the prompt.  Only wholly blank tails are removed, so full-screen
programs that draw below the cursor keep their layout."
  (unless cooked--alt
    (save-excursion
      (cooked--goto-screen-row (1+ (nth 0 cooked--cursor)))
      (let ((start (point)))
        (when (and (< start (point-max))
                   (string-blank-p (buffer-substring-no-properties start (point-max))))
          (delete-region start (point-max)))))))

(defun cooked--protect (limit)
  "Make the screen read-only up to LIMIT, leaving anything after it editable.

Stickiness carries the whole design: `rear-nonsticky' leaves the far edge
open so typing at the start of the input region is accepted, while
`front-sticky' closes the near edge so nothing can be wedged in above the
transcript."
  (when (and cooked--screen-start (marker-position cooked--screen-start))
    (let ((beg (min (marker-position cooked--screen-start) limit)))
      (add-text-properties beg limit
                           '(read-only t front-sticky (read-only) rear-nonsticky (read-only)))
      (when (< limit (point-max))
        (remove-text-properties limit (point-max) '(read-only nil))))))

(defun cooked--render-rows (rows)
  "Rewrite damaged ROWS, an alist of (INDEX . RUNS)."
  (save-excursion
    (pcase-dolist (`(,index . ,runs) rows)
      (cooked--goto-screen-row index 'extend)
      (delete-region (point) (line-end-position))
      (cooked--insert-runs runs))))

(defun cooked--cursor-position ()
  "Buffer position of the emulator cursor.
A pure query: it never extends the buffer, so it is safe to call before
`inhibit-read-only' is in effect."
  (save-excursion
    (cooked--goto-screen-row (nth 0 cooked--cursor))
    (min (+ (point) (nth 1 cooked--cursor)) (line-end-position))))

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
which shows up as the last character folding onto a line of its own."
  (let ((windows (get-buffer-window-list (current-buffer) nil t)))
    (if windows
        (cons (max 1 (apply #'min (mapcar #'cooked--window-rows windows)))
              (max 1 (apply #'min (mapcar #'window-max-chars-per-line windows))))
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

(defun cooked--start (argv &optional directory extra-env)
  "Spawn ARGV in the current buffer, optionally in DIRECTORY.
EXTRA-ENV is an alist prepended to the child's environment."
  (cooked--load-module)
  (setq cooked--face-cache (make-hash-table :test #'equal))
  (pcase-let ((`(,rows . ,cols) (cooked--window-size)))
    (setq cooked--rows rows cooked--cols cols))
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (make-string cooked--rows ?\n))
    (setq cooked--screen-start (copy-marker (point-min) nil)))
  (setq cooked--wake
        (make-pipe-process :name (format "cooked-wake<%s>" (buffer-name))
                           :buffer nil
                           :noquery t
                           :filter (let ((buffer (current-buffer)))
                                     (lambda (_proc _string) (cooked--on-wake buffer)))))
  (setq cooked--session
        (cooked--spawn argv (cooked--child-environment extra-env) cooked--rows cooked--cols cooked--wake
                      (and directory (expand-file-name directory))))
  cooked--session)

(defun cooked--child-environment (&optional extra)
  "Environment alist for the child, with EXTRA taking precedence."
  `(,@extra
    ("TERM" . ,(cooked--terminfo))
    ("COLORTERM" . "truecolor")
    ("INSIDE_EMACS" . ,(format "%s,cooked" emacs-version))
    ;; LINES and COLUMNS are deliberately *not* set. ncurses treats them as
    ;; authoritative over the tty's own size (`use_env'), so a program started with
    ;; them pinned keeps its original geometry for life and ignores every SIGWINCH.
    ;; The winsize is the single source of truth; shells re-export these themselves.
    ,@(cl-loop for entry in process-environment
               for split = (string-search "=" entry)
               when (and split (not (member (substring entry 0 split)
                                            '("TERM" "COLORTERM" "INSIDE_EMACS" "LINES" "COLUMNS"))))
               collect (cons (substring entry 0 split) (substring entry (1+ split))))))

(defvar cooked-debug nil
  "When non-nil, re-signal redisplay errors instead of reporting them.")

(defun cooked--on-wake (buffer)
  "Drain BUFFER's session and apply what changed.

An error here is otherwise invisible: Emacs swallows process-filter errors, and
the symptom reaches the user as a buffer that stopped updating or a point that
jumped somewhere absurd.  Name it instead."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when cooked--session
        (if cooked-debug
            (cooked--apply (cooked--drain cooked--session cooked-rejoin-wrapped-lines))
          (condition-case err
              (cooked--apply (cooked--drain cooked--session cooked-rejoin-wrapped-lines))
            (error
             (message "cooked: redisplay failed: %S (point %s, cursor %S, screen-start %s)"
                      err (point) cooked--cursor
                      (and cooked--screen-start (marker-position cooked--screen-start))))))))))

(defun cooked--apply (update)
  "Apply UPDATE, the plist returned by `cooked--drain'."
  ;; `let*', emphatically: these initialisers delete and insert, and under plain
  ;; `let' they would run before `inhibit-read-only' took effect, so a protected
  ;; buffer aborts the redisplay half-done from inside the process filter.
  ;; `let*', emphatically: these initialisers delete and insert, and under plain
  ;; `let' they would run before `inhibit-read-only' took effect, so a protected
  ;; buffer aborts the redisplay half-done from inside the process filter.
  (let* ((inhibit-read-only t)
         (pending (cooked--take-pending-input))
         ;; Follow the cursor unless the user has gone up into the scrollback to
         ;; read.  Comparing point against the cursor instead is order-dependent:
         ;; output arriving in chunks lets the cursor overtake point for a single
         ;; drain, and point is then stranded for every drain after it — landing
         ;; at column 0 of whichever line it was on.
         (follow (>= (point) (marker-position cooked--screen-start))))
    (when-let* ((scrolled (plist-get update :scrolled)))
      (cooked--render-scrolled scrolled))
    (cooked--render-rows (plist-get update :rows))
    (setq cooked--cursor (plist-get update :cursor)
          cooked--alt (plist-get update :alt)
          cooked--app-cursor (plist-get update :app-cursor)
          cooked--keys (plist-get update :keys)
          cooked--exit (plist-get update :exit))
    (cooked--set-mode (plist-get update :mode))
    (dolist (event (plist-get update :events))
      (cooked--handle-event event))
    (cooked--fit-screen)
    (cooked--pad-to-cursor)
    (setq-local cursor-type (if (nth 2 cooked--cursor) t nil))
    (cooked--restore-pending-input pending)
    (cooked--protect (if (and (cooked--input-state-p) cooked--input-start)
                        (marker-position cooked--input-start)
                      (point-max)))
    (when follow (goto-char (cooked--point-after-input)))
    (when cooked--exit (cooked--on-exit cooked--exit))))

(defun cooked--handle-event (event)
  "Dispatch a single EVENT from the emulator."
  (pcase event
    (`(bell) (ding))
    (`(osc ,code ,bell . ,parts) (cooked--handle-osc code bell parts))
    (`(reply . ,bytes) (cooked--send cooked--session bytes))
    (`(alt-screen . ,on) (setq cooked--alt on))
    (`(mouse ,enabled ,sgr) (setq cooked--mouse enabled cooked--mouse-sgr sgr))
    ((or `(prompt-start) `(prompt-end) `(command-start) `(command-end . ,_))
     (cooked--semantic event))
    (_ nil)))

;;;; OSC dispatch
;;
;; Everything except OSC 133 arrives here verbatim, so a new integration is a
;; handler in this alist rather than a change to the native core.

(defvar cooked-osc-handlers
  '((0 . cooked--osc-title)
    (2 . cooked--osc-title)
    (7 . cooked--osc-cwd)
    (8 . cooked--osc-hyperlink)
    (10 . cooked--osc-color)
    (11 . cooked--osc-color)
    (12 . cooked--osc-color)
    (110 . cooked--osc-color-reset)
    (111 . cooked--osc-color-reset)
    (112 . cooked--osc-color-reset)
    (51 . cooked--osc-emacs)
    (52 . cooked--osc-clipboard))
  "Alist of OSC code to a function taking the remaining payload parts.
Add to this to teach cooked a new escape sequence without touching Rust.

A handler that answers a query calls `cooked--reply-osc' rather than framing
the reply itself, passing `cooked--osc-bell-terminated' straight through.")

(defvar cooked--osc-bell-terminated nil
  "Whether the OSC being handled ended with BEL rather than ST.

Bound around each handler.  It is not an argument because handlers are a
documented extension point and most of them never reply; a handler that does
hands this back to `cooked--reply-osc' without interpreting it.")

(defvar cooked--osc-code nil
  "Code of the OSC being handled, bound around each handler.
Handlers registered for a range of codes — the colour ones — need to know
which of them they were called for.")

(defun cooked--handle-osc (code bell parts)
  "Run the handler for OSC CODE with PARTS, which arrived BELL-terminated."
  (when-let* ((handler (alist-get code cooked-osc-handlers)))
    (condition-case err
        (let ((cooked--osc-bell-terminated bell)
              (cooked--osc-code code))
          (funcall handler parts))
      (error (message "cooked: OSC %s handler failed: %S" code err)))))

(defun cooked--osc-title (parts)
  "Show the child's title, from OSC 0 or 2."
  (setq cooked--title (string-join parts ";"))
  (cooked--rename-to-title)
  (force-mode-line-update))

(defun cooked--osc-cwd (parts)
  "Track the child's directory, from OSC 7."
  (cooked--set-directory (string-join parts ";")))

(defun cooked--osc-hyperlink (parts)
  "Record the current OSC 8 hyperlink target."
  (setq cooked--hyperlink (let ((uri (string-join (cdr parts) ";")))
                            (unless (string-empty-p uri) uri))))

;;;; OSC 10/11/12 — the default colors
;;
;; Theme-aware programs ask the terminal for its background before choosing a light or
;; dark palette, and a terminal that never answers costs them their whole timeout on
;; every startup.  We are the only ones who can answer: Rust has no default fg/bg at
;; all — `Color::Default' is an unresolved marker — because the real value is whatever
;; the buffer's `default' face resolves to under the user's theme.

(defcustom cooked-allow-color-set nil
  "Whether the child may change this buffer's default foreground and background.

Queries are always answered; this is about OSC 10/11/12 requests that *set* a
color.  Anything that can write to the terminal can send one — a `cat' of a
hostile file, output from a compromised host — so it is off by default, for the
same reason the OSC 51 command channel is a separate file you have to require."
  :type 'boolean
  :group 'cooked)

(defvar-local cooked--color-remaps nil
  "Alist of color kind to face remapping cookie, so OSC 110/111/112 can undo a set.")

(defconst cooked--osc-color-sources
  '((10 . foreground) (11 . background) (12 . cursor))
  "Which default color each OSC code asks about.")

(defun cooked--default-color (kind)
  "The color this buffer renders for KIND: foreground, background or cursor.

Falls back through the frame and then to plain black or white.  On a tty frame
the face returns `unspecified-fg'/`unspecified-bg', which `color-values' cannot
read; answering approximately still beats not answering, which is the bug this
exists to fix."
  (let ((color (pcase kind
                 ('foreground (or (face-foreground 'default nil t)
                                  (frame-parameter nil 'foreground-color)))
                 ('background (or (face-background 'default nil t)
                                  (frame-parameter nil 'background-color)))
                 ('cursor (or (frame-parameter nil 'cursor-color)
                              (face-foreground 'default nil t))))))
    (if (and color (color-values color))
        color
      (let ((dark (eq (frame-parameter nil 'background-mode) 'dark)))
        (if (eq kind 'background)
            (if dark "black" "white")
          (if dark "white" "black"))))))

(defun cooked--color-to-osc (color)
  "Format COLOR as xterm's `rgb:RRRR/GGGG/BBBB', 16 bits per channel.
That is exactly what `color-values' returns, so no rescaling is involved."
  (when-let* ((values (color-values color)))
    (apply #'format "rgb:%04x/%04x/%04x" values)))

(defun cooked--parse-osc-color (spec)
  "Turn an X or xterm color SPEC into something Emacs understands, or nil.
Accepts `rgb:R/G/B' with one to four hex digits per channel, `#RGB' forms, and
plain color names."
  (cond
   ((string-match "\\`rgb:\\([0-9a-fA-F]+\\)/\\([0-9a-fA-F]+\\)/\\([0-9a-fA-F]+\\)\\'" spec)
    (let ((parts (list (match-string 1 spec) (match-string 2 spec) (match-string 3 spec))))
      ;; Channels are scaled by width, not padded: "rgb:f/f/f" is white, not #0f0f0f.
      (when (cl-every (lambda (p) (<= 1 (length p) 4)) parts)
        (apply #'format "#%04x%04x%04x"
               (mapcar (lambda (p)
                         (let ((v (string-to-number p 16))
                               (max (1- (ash 1 (* 4 (length p))))))
                           (/ (* v 65535) max)))
                       parts)))))
   ((color-values spec) spec)))

(defun cooked--osc-color (parts)
  "Answer or apply an OSC 10, 11 or 12 request.

A `?' is a query and is answered from the buffer's own faces.  Anything else is
a set, which needs `cooked-allow-color-set'.  Several may be chained — `ESC ] 10
; ? ; ? ST' asks for the foreground and then the background — so each part
advances the code."
  (let ((code cooked--osc-code))
    (dolist (part parts)
      (when-let* ((kind (alist-get code cooked--osc-color-sources)))
        (if (equal part "?")
            (when-let* ((payload (cooked--color-to-osc (cooked--default-color kind))))
              (cooked--reply-osc cooked--session code payload
                                 cooked--osc-bell-terminated))
          (when cooked-allow-color-set
            (cooked--set-default-color kind part))))
      (setq code (1+ code)))))

(defun cooked--set-default-color (kind spec)
  "Remap this buffer's default KIND to SPEC, if it parses.
Buffer-local rather than frame-wide: a child gets to repaint its own terminal,
not every window in the Emacs running it."
  (when-let* ((color (cooked--parse-osc-color spec)))
    (cooked--reset-default-color kind)
    (push (cons kind (pcase kind
                       ('foreground (face-remap-add-relative 'default :foreground color))
                       ('background (face-remap-add-relative 'default :background color))
                       ('cursor (face-remap-add-relative 'cursor :background color))))
          cooked--color-remaps)
    ;; Every cell face resolves against `default', so the memoized ones are stale the
    ;; moment the remap lands.
    (cooked--flush-face-cache)))

(defun cooked--reset-default-color (kind)
  "Drop any OSC 10/11/12 remap of KIND, restoring the theme's own color."
  (when-let* ((cookie (alist-get kind cooked--color-remaps)))
    (face-remap-remove-relative cookie)
    (setq cooked--color-remaps (assq-delete-all kind cooked--color-remaps))
    (cooked--flush-face-cache)))

(defun cooked--osc-color-reset (_parts)
  "Undo an OSC 10/11/12 set, from OSC 110, 111 or 112."
  (when-let* ((kind (alist-get (- cooked--osc-code 100) cooked--osc-color-sources)))
    (cooked--reset-default-color kind)))

;;;; OSC 51 — the child asking Emacs to do something
;;
;; Only the harmless half lives here.  `A' annotates the prompt and is inert, so it
;; costs nothing to support.  `E' is a command channel driven by bytes on the
;; terminal — anything that can write there can pull the trigger: `cat' of a hostile
;; file, output from a compromised host over ssh, a build log quoting text somebody
;; else chose — so it is off until you load `cooked-osc-eval' and say you want it.

(defvar cooked-osc-eval-function nil
  "Function handling the OSC 51;E command channel, called with the payload.

Nil means the channel is closed and requests are ignored.
`cooked-osc-eval' sets it; requiring that file is how you opt in, and the
point of the split is that opting in is something you do on purpose
rather than inherit.")

(defvar-local cooked--eval-refused nil
  "Whether this buffer has already reported an ignored OSC 51;E request.")

(defun cooked--osc-emacs (parts)
  "Handle OSC 51: E asks Emacs to run something, A annotates the prompt."
  (let ((payload (string-join parts ";")))
    (unless (string-empty-p payload)
      (pcase (aref payload 0)
        (?E (cond
             (cooked-osc-eval-function
              (funcall cooked-osc-eval-function (substring payload 1)))
             ;; Once per buffer: silence looks like a bug to someone porting their
             ;; vterm configuration, but a stream can send these as fast as it likes.
             ((not cooked--eval-refused)
              (setq cooked--eval-refused t)
              (message "cooked: ignoring an OSC 51 command; (require 'cooked-osc-eval) to enable"))))
        (?A (setq cooked--annotation (substring payload 1)))
        (_ nil)))))

(defun cooked-clear-scrollback ()
  "Delete everything above the live screen."
  (interactive)
  (let ((inhibit-read-only t))
    (delete-region (point-min) (marker-position cooked--screen-start))))

;;;; OSC 52 — clipboard

(defcustom cooked-clipboard-write t
  "Whether the child may put text on the kill ring via OSC 52.
Reads are never answered regardless: replying to a query would hand the
clipboard's contents to any program that asks for them."
  :type 'boolean
  :group 'cooked)

(defcustom cooked-clipboard-max-size 100000
  "Largest OSC 52 payload accepted onto the kill ring, in base64 characters.
Anything writing to the terminal can push to the clipboard, so this bounds how
much of the kill ring a runaway or hostile stream can take over."
  :type 'natnum
  :group 'cooked)

(defun cooked--osc-clipboard (parts)
  "Put the child's OSC 52 selection on the kill ring."
  (let ((data (car (last parts))))
    (when (and cooked-clipboard-write data (not (equal data "?")))
      (if (> (length data) cooked-clipboard-max-size)
          ;; Refuse out loud: a silent drop looks like the copy simply failed.
          (message "cooked: refused a %d-character clipboard write (see `cooked-clipboard-max-size')"
                   (length data))
        (when-let* ((text (ignore-errors (base64-decode-string data t))))
          (kill-new (decode-coding-string text 'utf-8))
          (message "cooked: copied %d characters" (length text)))))))

(defun cooked--set-directory (url)
  "Track the child's directory from an OSC 7 URL."
  (when (string-match "\\`file://[^/]*\\(/.*\\)\\'" url)
    (let ((dir (file-name-as-directory (url-unhex-string (match-string 1 url)))))
      (when (file-directory-p dir)
        (setq default-directory dir)))))

(provide 'cooked)
;;; cooked.el ends here
