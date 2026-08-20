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
;; handed over once and become ordinary buffer text; the lines after
;; `cooked--screen-start' are the live screen, rewritten from damage reports.
;;
;; Invariant: buffer text equals the grid, plus any pending input rendered at the
;; cursor.  Every redisplay lifts the pending input out, applies the grid, and puts
;; it back.
;;
;; The two ends therefore hold one structure between them, and the boundary is the
;; only place they can disagree.  So the geometry of it is reported rather than
;; re-derived: `cooked--grid' carries the emulator's own account of how tall the
;; grid is, how much of it is occupied, and how much of the line straddling the
;; boundary has already been handed over.  Emacs owns the buffer and makes every
;; edit; it just does not get a second opinion about the shape it is editing to.
;; `cooked--check-seam' is that boundary stated as an assertion.

;;; Code:

(require 'cl-lib)
(require 'face-remap)
(require 'url-util)
(require 'cooked-glyph)

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
(defconst cooked--attr-underline-shift 8
  "Bit position of the underline-style field.  See `Attrs' in src/emu/cell.rs.")
(defconst cooked--attr-underline-style (ash 7 cooked--attr-underline-shift))

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

(defcustom cooked-box-drawing-images t
  "Whether to render box-drawing and block-element characters as generated bitmaps.

On by default: most monospace fonts draw ─│┌┐└┘├┤┬┴┼ and the block-shade
characters (▀▄█▌▐░▒▓ etc.) with glyph-to-glyph inconsistencies, highly visible
in full-screen programs like htop, ranger and fzf that rely on these
characters forming continuous borders.  Cooked classifies these characters in
its native core and renders them as small generated bitmaps sized to the
current font and colored from the active theme — the same approach VTE, Kitty
and Alacritty take.

Falls back to plain colored text, exactly as when this is nil, if Emacs lacks
XBM image support or bitmap generation fails for a glyph."
  :type 'boolean
  :group 'cooked)

;;;; What the two ends exchange
;;
;; The native core reports its cursor as a four-element list and its geometry as
;; three keys of the drain's plist, both of which are the cheapest thing to build
;; across the module boundary.  Neither is a good thing to *read*: `(nth 3
;; cooked--cursor)' says nothing about what it holds, and a positional decode
;; repeated at twenty call sites is twenty chances to count wrong.  So the shapes
;; are decoded once, at the boundary in `cooked--apply', and everything above it
;; works in terms the reader can check.

(cl-defstruct (cooked-cursor (:constructor cooked--cursor-make) (:copier nil))
  "The child's cursor: where it is, and what it should look like."
  (row 0 :documentation "Screen row, zero-based.")
  (col 0 :documentation "Screen column, zero-based.")
  (visible t :documentation "Whether the child has asked for it to be shown.")
  (shape 'block :documentation "`block', `underline' or `bar', from DECSCUSR."))

(defun cooked--cursor-decode (spec)
  "Decode SPEC, the (ROW COL VISIBLE SHAPE) list the native core reports."
  (pcase-let ((`(,row ,col ,visible ,shape) spec))
    (cooked--cursor-make :row (or row 0) :col (or col 0)
                         :visible visible :shape (or shape 'block))))

(defun cooked--cursor-cell ()
  "The child's cursor as a (ROW . COL) screen cell."
  (cons (cooked-cursor-row cooked--cursor) (cooked-cursor-col cooked--cursor)))

(cl-defstruct (cooked-grid (:constructor cooked--grid-make) (:copier nil))
  "The emulator's own account of its grid, as of the last drain.

`cooked--rows' and `cooked--cols' are what Emacs *asked* the child for, which is
a different thing and can differ for as long as it takes a resize to land.  This
is what the grid actually is, so the buffer is shaped by the emulator rather
than by a second opinion of it."
  (height 24 :documentation "Rows the grid has.")
  (used 1 :documentation "Rows of it that are occupied — see `cooked--fit-screen'.")
  (head 0 :documentation "\
Characters of screen row 0's logical line that are already in the buffer, above
`cooked--screen-start'.  Non-zero exactly when the last row handed to scrollback
was wrapped and row 0 continues it, which is why the marker then sits mid-line.
See `cooked--check-seam'."))

(cl-defstruct (cooked-command (:constructor cooked--command-make) (:copier nil))
  "One command the shell ran, as delimited by its OSC 133 marks.

A record rather than only text properties: a command that printed nothing spans
an empty region, which no text property can describe, and the records are what
folding and navigation walk."
  (start nil :documentation "Marker where the command's output began.")
  (end nil :documentation "Marker where it ended.")
  (code 0 :documentation "Exit status.")
  (input nil :documentation "The command line itself, or nil if we never saw it.

The text cooked submitted, not a position recovered afterwards.  A marker would
not survive: the input row is repainted on every keystroke and again when the
shell echoes the line, and `cooked--render-rows' deletes a damaged row whole, so
any marker inside it collapses to the row's start -- taking the prompt with it.
Nil for a command Emacs did not submit, such as one typed while the child owned
the keyboard, or one the shell ran itself."))

(defun cooked--command-start-position (command)
  "Buffer position where COMMAND's output begins."
  (marker-position (cooked-command-start command)))

(defun cooked--command-end-position (command)
  "Buffer position where COMMAND's output ends."
  (marker-position (cooked-command-end command)))

(defun cooked--command-input (command)
  "The line COMMAND was invoked with, or nil if cooked did not submit it."
  (cooked-command-input command))

(defvar-local cooked--session nil "Handle returned by `cooked--spawn'.")
(defvar-local cooked--wake nil "Pipe process Rust pokes when output is pending.")
(defvar-local cooked--rows 24
  "Rows Emacs last asked the child for.
The grid's own height is in `cooked--grid'.")
(defvar-local cooked--cols 80
  "Columns Emacs last asked the child for.  Not a measurement of the grid.")
(defvar-local cooked--screen-start nil
  "Marker at the first line of the live screen; everything before is scrollback.")

(defun cooked--screen-start-position ()
  "Where the live screen begins, or nil before a session has started one.

The marker is nil until `cooked--start' makes it and can outlive its buffer
text, so every reader has to check both; doing that in one place keeps the
check from being the loudest thing at each call site."
  (and cooked--screen-start (marker-position cooked--screen-start)))

(defvar-local cooked--grid (cooked--grid-make)
  "The grid as the emulator last described it, a `cooked-grid'.")
(defvar-local cooked--cursor (cooked--cursor-make)
  "The child's cursor as of the last drain, a `cooked-cursor'.")
(defvar-local cooked--alt nil)
(defvar-local cooked--pin-screen-top nil
  "Non-nil when this drain should put the live screen at the top of the window.

Set by the child clearing the display and cleared as soon as the window block at
the end of `cooked--apply\=' has acted on it: it says something about this drain,
not about the buffer.")
(defvar-local cooked--input-mode nil
  "How this buffer is treating the keyboard and the render right now.

One of:

  nil      Forward everything the policy's map forwards, render live, follow
           the child's cursor.  The ordinary case, and the only one a
           non-`evil' user reaches without asking.
  `semi'   Forward, but hold back the keys that change what Emacs is doing --
           see `cooked-semi-map'.  Render live, follow the cursor.
  `still'  Forward nothing; the buffer is read-only and ordinary Emacs
           commands reach it.  The render stays live, but nothing moves the
           view: the child keeps drawing under a point that stays where the
           user put it.
  `frozen' As `still', and the render is deferred as well, so the picture
           being navigated cannot change at all.

These are three independent questions -- does a key forward, does the buffer
render, does the view follow -- that used to be answered by one flag, which is
why stepping out to `evil' normal state stopped the terminal dead.  See
`cooked--suspended-p', `cooked--frozen-p' and `cooked--follow-p', which are
what the rest of the code asks.")

(defvar-local cooked--peek-explicit nil
  "Whether `cooked-toggle-peek' was used to step out deliberately.
Kept apart from `cooked--input-mode' because the mode is recomputed from
scratch on every state change: a deliberate peek has to survive a `raw'<->`alt'
transition, and nothing else about the mode does.")

(defvar-local cooked--read-only nil
  "Whether the `buffer-read-only' in force is ours, from a suspended state.

Kept for the same reason `cooked--narrowed' is: a refresh that finds the buffer
no longer suspended should undo its own protection and nothing else.  Without
it, a `read-only-mode' the user turned on themselves was cleared by the next
state change that happened along.")

(defun cooked--suspended-p ()
  "Whether keys are being kept from the child rather than forwarded."
  (memq cooked--input-mode '(still frozen)))

(defvar-local cooked--attention nil
  "Whether the user is looking at this buffer: nil, `here' or `away'.

nil until it has been on screen at all.  A buffer that has never been
displayed has no attention to lose -- one driven from Lisp, or a test -- and
counting it as abandoned would freeze nothing and thaw everything.

Maintained by `cooked--update-attention' from the window hooks rather than
computed on demand, because the interesting case cannot be seen from the
buffer afterwards: once another buffer takes over its window, a cooked buffer
is displayed nowhere, which is indistinguishable from never having been shown
except by having watched it happen.")

(defun cooked--frozen-p ()
  "Whether the render is being deferred.

Only while this buffer is the one under the user's eyes.  Freezing exists to
keep a picture still while it is being read; a buffer the user has left is not
being read, and a terminal that stopped updating because its window lost
selection is the complaint this whole distinction exists to answer.  The child
never stopped running either way -- the freeze only ever deferred the drain."
  (and (eq cooked--input-mode 'frozen)
       (not (eq cooked--attention 'away))))

(defun cooked--follow-p ()
  "Whether point and the window should track the child's cursor."
  (not (cooked--suspended-p)))

(defvar-local cooked--narrowed nil
  "Whether the restriction in force is ours, from `cooked-alt-screen-pin'.")
(defvar-local cooked--app-cursor nil
  "DECCKM: send cursor keys as SS3, which is what `smkx' asks for.")
(defvar-local cooked--keys 'legacy
  "How to spell modified Return, Tab, Escape and Backspace for this child.

One of `legacy', `modify-other' or `kitty', as negotiated by the child itself —
see `cooked--literal-codes' for why this cannot simply be assumed.")
(defvar-local cooked--title nil "Title the child last set, via OSC 0 or 2.")
(defvar-local cooked--title-stack nil
  "Titles saved by XTWINOPS 22, newest first.  See `cooked--handle-title-stack'.")
(defvar-local cooked--hyperlink nil "Current OSC 8 hyperlink target, if any.")
(defvar-local cooked--annotation nil "Prompt annotation from OSC 51;A.")
(defvar-local cooked--mouse nil "Whether the child asked for mouse reports.")
(defvar-local cooked--mouse-sgr nil "Whether to encode mouse reports as SGR (1006).")
(defvar-local cooked--mode 'cooked)
(defvar-local cooked--exit nil)
(defvar-local cooked--face-cache nil)
(defvar-local cooked--box-ascent-cache nil
  "Line-box height -> the `:ascent' that lands a bitmap on it, per buffer.

Separate from `cooked--box-glyph-cache' because it memoizes a `font-info' call
rather than a bitmap, and that call is far too costly to repeat per character
on a full-screen repaint.  Keyed by height alone: the answer depends only on
the font's ascent relative to the line box.")

(defvar-local cooked--box-glyph-cache nil
  "Descriptor+pixel-size -> raw XBM bitmap, memoized per buffer.

Colorless by construction: the cached value is a shape only, colorized live
via :foreground/:background at `create-image' time, so unlike
`cooked--face-cache' this needs no theme-change invalidation — only pixel-size
changes (zoom, font change) miss the cache key, naturally, with no extra
plumbing.")

;; Everything this file calls in cooked-mode.el, which is to say everything it
;; calls upward.  Each one is a notification that something changed and the layer
;; that owns keymaps, buffer names or the buffer's own life should react — never a
;; question asked of that layer, which is why the list is short and stays short.
;; Anything cooked.el needs an *answer* to belongs at this level instead; see
;; "Who owns the keyboard" below, which is where that rule moved the policy.
(declare-function cooked--refresh-keymap "cooked-mode")
(declare-function cooked--update-mouse-grab "cooked-mode")
(declare-function cooked--set-mode "cooked-mode")
(declare-function cooked--on-exit "cooked-mode")
(declare-function cooked--rename-to-title "cooked-mode")
(declare-function cooked--completion-forget-nonce "cooked-completion")
(defvar cooked-rejoin-wrapped-lines)

(declare-function cooked--spawn "cooked-core")
(declare-function cooked--drain "cooked-core")
(declare-function cooked--send "cooked-core")
(declare-function cooked--reply-osc "cooked-core")
(declare-function cooked--resize "cooked-core")
(declare-function cooked--forget-history "cooked-core")
(declare-function cooked--redraw "cooked-core")
(declare-function cooked--prompt-text "cooked-core")
(declare-function cooked--signal "cooked-core")
(declare-function cooked--pid "cooked-core")
(declare-function cooked--bracketed-paste-p "cooked-core")
(declare-function cooked--live-p "cooked-core")
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

(defmacro cooked--dolist-buffers (&rest body)
  "Run BODY once in each live cooked buffer, with that buffer current.

Several things have to reach every session at once — a theme change invalidating
the face caches, a frame focus change, the list of sessions to switch to — and
each of them was walking `buffer-list' and testing the major mode itself.  BODY
that needs the buffer as a value can say `current-buffer'."
  (declare (indent 0) (debug body))
  `(dolist (buffer (buffer-list))
     (when (buffer-live-p buffer)
       (with-current-buffer buffer
         (when (derived-mode-p 'cooked-mode)
           ,@body)))))

(defmacro cooked--dolist-windows (var windows &rest body)
  "Run BODY with VAR bound to each still-live window of WINDOWS.

The list is always captured before a redraw and used after it, so a window
being gone by the time it is reached is ordinary rather than exceptional."
  (declare (indent 2) (debug (symbolp form body)))
  `(dolist (,var ,windows)
     (when (window-live-p ,var)
       ,@body)))

(defun cooked--live-session ()
  "This buffer's session while there is still a child on the other end.

Nil once the child has exited, which is a state the buffer outlives: the
transcript stays, and `cooked--on-exit' clears `cooked--session' without
touching the keymap, so the raw map is still installed and every key still
resolves to a command that wants to write to the pty."
  (and cooked--session (cooked--live-p cooked--session) cooked--session))

(defun cooked--require-session ()
  "This buffer's live session, refusing rather than erroring when it is gone.

Every command that reaches into the native core goes through here.  Handing
nil to a function that expects a user-pointer shows the user
`wrong-type-argument user-ptrp nil' — a backtrace where the honest answer is
that the session is over."
  (or (cooked--live-session) (user-error "No live session")))

(defun cooked--send-to-child (bytes)
  "Send BYTES to the child, refusing if the session is over."
  (cooked--send (cooked--require-session) bytes))

(defun cooked--send-if-live (bytes)
  "Send BYTES if there is still a child, and do nothing if there is not.

For the writes that are not a keystroke: a device-status reply resolved
mid-drain, a focus notification from a global hook, a completion request.  There
the child having just exited is an ordinary race rather than something the user
asked for and should be told about — and signalling from inside a process filter
would abort the rest of the redisplay."
  (when-let* ((session (cooked--live-session)))
    (cooked--send session bytes)))

(defconst cooked--source-directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory holding this file, captured at load time.")

(defcustom cooked-alt-screen-pin 'narrow
  "What the buffer does while a full-screen program owns the alternate screen.

`narrow' confines the buffer to the screen region, which is how a terminal
behaves: scrollback is unreachable until the program exits.  `follow' leaves
the whole buffer accessible, so you can scroll up and read the transcript
behind a running program -- possible only because Emacs, not the emulator,
owns the history.

Under `narrow' a deliberate \\[widen] is undone by the next redraw; quit the
program to get the transcript back."
  :type '(choice (const :tag "Narrow to the alt screen" narrow)
                 (const :tag "Allow scrolling into scrollback" follow))
  :group 'cooked)

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
  "Forget resolved colors so a new theme applies to subsequent output.

Deliberately does not touch `cooked--box-glyph-cache': that cache holds
colorless shape bitmaps, colorized live at display time, so it has nothing a
theme change could make stale."
  (cooked--dolist-buffers
    (when (hash-table-p cooked--face-cache)
      (clrhash cooked--face-cache))))

;; `enable-theme-functions' arrived in Emacs 29, and `add-hook' on an unbound variable
;; quietly defines it rather than failing — so on 28 this looked fine and did nothing.
(if (boundp 'enable-theme-functions)
    (progn
      (add-hook 'enable-theme-functions #'cooked--flush-face-cache)
      (add-hook 'disable-theme-functions #'cooked--flush-face-cache))
  (advice-add 'enable-theme :after #'cooked--flush-face-cache)
  (advice-add 'disable-theme :after #'cooked--flush-face-cache))

(defconst cooked--underline-styles
  [nil line line wave line line]
  "Emacs `:underline' styles, indexed by the SGR 4:x subparameter.

Emacs renders only `line' and `wave', so double, dotted and dashed all fall
back to a plain line rather than being approximated with overlays.")

(defun cooked--underline-spec (attrs ul)
  "The `:underline' value for the ATTRS bitmask with underline colour UL.

Plain t whenever there is nothing to say beyond \='underlined\=', so the common
case produces exactly the face plist it did before styled underlines existed."
  (let ((style (aref cooked--underline-styles
                     (min 5 (ash (logand attrs cooked--attr-underline-style)
                                 (- cooked--attr-underline-shift)))))
        (color (and ul (cooked--color ul))))
    (cond ((and (null color) (memq style '(nil line))) t)
          (t (append (and color (list :color color))
                     (and (eq style 'wave) (list :style 'wave)))))))

(defconst cooked--attr-face-properties
  `((,cooked--attr-bold :weight bold)
    (,cooked--attr-faint :weight light)
    (,cooked--attr-italic :slant italic)
    (,cooked--attr-strike :strike-through t))
  "SGR attribute bits that map straight onto a face property and a constant value.

The attributes needing more than a constant — underline, whose style and colour
are a whole sub-protocol, and conceal, which resolves against the background
that was just computed — are handled separately in `cooked--face'.")

(defsubst cooked--attr-p (attrs bit)
  "Whether BIT is set in the ATTRS bitmask."
  (/= 0 (logand attrs bit)))

(defun cooked--face (fg bg attrs &optional ul)
  "Face plist for FG, BG, the ATTRS bitmask and underline colour UL.
Memoized per buffer."
  (let ((key (list fg bg attrs ul)))
    (or (gethash key cooked--face-cache)
        (puthash key (cooked--face-build fg bg attrs ul) cooked--face-cache))))

(defun cooked--face-build (fg bg attrs ul)
  "The face plist `cooked--face' memoizes.  See it for the arguments."
  (let* ((reverse (cooked--attr-p attrs cooked--attr-reverse))
         (fg* (cooked--color (if reverse bg fg)))
         (bg* (cooked--color (if reverse fg bg)))
         (face nil))
    (when fg* (setq face (plist-put face :foreground fg*)))
    (when bg* (setq face (plist-put face :background bg*)))
    (pcase-dolist (`(,bit ,property ,value) cooked--attr-face-properties)
      (when (cooked--attr-p attrs bit)
        (setq face (plist-put face property value))))
    (when (cooked--attr-p attrs cooked--attr-underline)
      (setq face (plist-put face :underline (cooked--underline-spec attrs ul))))
    ;; Last, and after the foreground it overrides: concealed text is drawn in the
    ;; background colour, which is only known once reverse video has been settled.
    (when (cooked--attr-p attrs cooked--attr-conceal)
      (setq face (plist-put face :foreground (or bg* (face-background 'default)))))
    face))

;;;; Box-drawing / block-element bitmaps
;;
;; The rasterizer itself is cooked-glyph.el, which knows nothing about terminals:
;; it turns a shape descriptor and a pixel size into raw XBM bits.  What is left
;; here is everything that depends on this buffer — caching a bitmap against the
;; window's current cell size, colouring it from the cell's own attributes, and
;; hanging the result on buffer text.
;;
;; Rendering is a themed XBM mask: the bitmap itself is colorless shape data,
;; colorized live via :foreground/:background at `create-image' time, so
;; `cooked--box-glyph-cache' never needs the theme-flush treatment
;; `cooked--face-cache' gets — only pixel-size (zoom, font change) is part of its
;; cache key.

(defun cooked--box-glyph-bits (bits window &optional phase)
  "Cached raw bitmap for glyph descriptor BITS at WINDOW's current cell size.

PHASE joins the cache key, since two cells of the same glyph at opposite phases
are genuinely different bitmaps.  It is non-zero only for shade glyphs at an odd
cell size, so in practice nothing else pays for the extra variant.

Sized from `window-font-width'/`window-default-line-height' rather than
`frame-char-width'/`frame-char-height': the latter ignore `text-scale-mode's
per-buffer face remapping, so zooming just this buffer would desync bitmap
size from font size — the very misalignment this feature exists to remove.

Height comes from `window-default-line-height', not `window-font-height', for
the reason `cooked--window-rows' already gives: the line box is what a row
actually occupies and includes `line-spacing', while the font height does not.
A bitmap sized to the font leaves exactly `line-spacing' pixels of background
beneath every glyph, breaking the continuous vertical borders this exists to
produce — the same defect `indent-bars' documents for box characters."
  (let* ((width (window-font-width window 'default))
         (height (window-default-line-height window))
         (phase (or phase 0))
         (key (list bits width height phase)))
    (or (gethash key cooked--box-glyph-cache)
        (puthash key (cooked--render-box-glyph bits width height phase)
                 cooked--box-glyph-cache))))

(defun cooked--box-glyph-ascent (window height)
  "`:ascent' placing a HEIGHT-pixel bitmap exactly on WINDOW's line box.

A percentage rather than `center' now that the bitmap spans the whole line box:
`center' balances the image around the text's midline, which splits any
`line-spacing' evenly above and below and lifts the glyph off the box it was
sized to fill.  Anchoring the font's own ascent instead keeps the extra space
where Emacs actually puts it — below the baseline.

Falls back to `center' if the font reports no metrics, which is the previous
behaviour and still correct whenever `line-spacing' is nil."
  (unless cooked--box-ascent-cache ; `cooked--rescale-box-glyphs' is not error-guarded
    (setq cooked--box-ascent-cache (make-hash-table :test #'equal)))
  (let ((key (list 'ascent height)))
    (or (gethash key cooked--box-ascent-cache)
        (puthash key
                 (let ((base (ignore-errors
                               (aref (font-info (face-font 'default nil window)) 8))))
                   (if (and (natnump base) (> height 0) (<= base height))
                       (round (* 100 base) height)
                     'center))
                 cooked--box-ascent-cache))))

(defun cooked--box-phase (bits window column row)
  "Dither phase for glyph BITS drawn at screen COLUMN and ROW of WINDOW.

Bit 0 is the parity of the cell's left edge in pixels, bit 1 the parity of its
top edge — which is all `cooked--box-draw-shade' needs, its patterns having
period 2 on both axes.  An even cell size makes the corresponding bit constantly
0, so the common case adds no cache variants at all.

Always 0 for anything but a shade, so no other glyph doubles its cached
variants, and 0 as well when COLUMN is unknown.  ROW may be nil where the caller
has no row index, which costs at most a horizontal seam on an odd line height.

Derived from the cell size at every call rather than remembered: the phase of a
given cell changes when the font does, so a value cached alongside the glyph
would be stale the moment the buffer is zoomed."
  (if (not (and column (cooked--box-shade-p bits)))
      0
    (logior (logand (* column (window-font-width window 'default)) 1)
            (ash (logand (* (or row 0) (window-default-line-height window)) 1) 1))))

(defun cooked--box-glyph-image (bits fg bg attrs &optional window phase)
  "Image spec for glyph BITS, colored from FG/BG/ATTRS like `cooked--face'.

`:scale 1' is load-bearing, not a default being restated.
`image-scaling-factor' is `auto', which scales every image by cell-width/10
once a cell is wider than
10 pixels — true of most GUI font sizes.  These bitmaps are already generated
at exactly the cell size, so letting that apply would resample a pixel-exact
10x20 stroke up to 12x24 inside a 10x20 cell: borders stop meeting at the cell
edge and the strokes blur into something no better than the font glyphs this
replaces."
  (let* ((window (or window (get-buffer-window (current-buffer)) (selected-window)))
         (reverse (cooked--attr-p attrs cooked--attr-reverse))
         (fg* (or (cooked--color (if reverse bg fg)) (face-foreground 'default nil t)))
         (bg* (or (cooked--color (if reverse fg bg)) (face-background 'default nil t))))
    ;; `:data-width'/`:data-height'/`:stride' are what an inline `xbm' actually
    ;; requires when `:data' is raw bits, per (elisp) XBM Images -- and they are not
    ;; interchangeable with `:width'/`:height', which scale an already-decoded image
    ;; rather than describe the bit layout.  Emacs accepts only three `:data' shapes:
    ;; a vector of per-row strings, a whole XBM *file* in a string, or bare bits with
    ;; these three properties.  A packed (WIDTH HEIGHT DATA) list is none of them.
    (pcase-let ((`(,width ,height ,data) (cooked--box-glyph-bits bits window phase)))
      (create-image data 'xbm t
                    :data-width width :data-height height
                    :stride (* 8 (ceiling width 8)) ; bits per row, byte-aligned
                    :foreground fg* :background bg* :scale 1
                    ;; `image-transform-smoothing' defaults on, which interpolates
                    ;; edge pixels.  These bitmaps are pixel art meant to butt up
                    ;; against their neighbours, and a smoothed edge column reads as
                    ;; a faint seam between adjacent glyphs rather than a join.
                    :transform-smoothing nil
                    :ascent (cooked--box-glyph-ascent window height)))))

(defun cooked--overlay-box-glyphs (start glyphs fg bg attrs &optional origin row)
  "Overlay a generated bitmap `display' property on each glyph in GLYPHS.

GLYPHS is the packed unibyte string `cooked--insert-runs' describes: two
little-endian bytes per character.  Packed rather than a list because this runs
on every damaged row of every frame, and box drawing is what full-screen
programs are made of — a list would cons per character of each redraw.

Box-drawing characters are always single-column and a merged run can mix
shapes, so this is one `display' property per character rather than one
spanning the whole run.  Also stashes `cooked-box-glyph', the raw descriptor
plus its colors and its place on the screen, so `cooked--rescale-box-glyphs' can
regenerate at a new zoom level without asking the native core for anything — and
without having to work out where each glyph sat all over again.

ORIGIN is the buffer position of screen column 0 on this row, and ROW the row's
index; together they place a shade glyph's dither in absolute screen space.
ORIGIN is passed in rather than taken from `line-beginning-position' because row
0 does not always start a buffer line — it continues the wrapped row above it,
as `cooked--goto-screen-row' explains.  A preceding double-width character still
puts the column out by one, which costs a seam in a rare case and is not worth a
per-row width scan to avoid."
  (condition-case nil
      (let ((pos start)
            (window (or (get-buffer-window (current-buffer)) (selected-window))))
        (dotimes (i (/ (length glyphs) 2))
          (let* ((bits (logior (aref glyphs (* 2 i))
                               (ash (aref glyphs (1+ (* 2 i))) 8)))
                 (column (and origin (- pos origin)))
                 (phase (cooked--box-phase bits window column row)))
            (put-text-property pos (1+ pos) 'cooked-box-glyph
                               (list bits fg bg attrs column row))
            (put-text-property pos (1+ pos) 'display
                               (cooked--box-glyph-image bits fg bg attrs window phase)))
          (setq pos (1+ pos))))
    ;; A cosmetic feature must never break rendering: any failure here leaves the
    ;; plain face-only text `cooked--insert-runs' already inserted.
    (error nil)))

(defun cooked--rescale-box-glyphs ()
  "Regenerate on-screen box-glyph bitmaps for the buffer's current zoom level.
Reuses the `cooked-box-glyph' property `cooked--overlay-box-glyphs' stashed, so
this never needs the native core — the classified shape and its colors already
survive in the buffer.

Widens first: `cooked-alt-screen-pin' confines the buffer to the screen region
while a full-screen program is up, and a zoom during that would otherwise
rescale only the alt frame — leaving every glyph in the scrollback above it
stuck at the previous font size, visibly mismatched once the pin is released."
  (when (derived-mode-p 'cooked-mode)
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (let ((window (selected-window))
              (inhibit-read-only t)) ; the live screen (and scrollback) are read-only text
          (while (< (point) (point-max))
            (let ((spec (get-text-property (point) 'cooked-box-glyph))
                  (next (or (next-single-property-change (point) 'cooked-box-glyph)
                            (point-max))))
              (when spec
                ;; A tail pattern rather than two more elements: a buffer rendered
                ;; before the screen position was stashed still holds four-element
                ;; specs, and a zoom must not error on them.
                (pcase-let* ((`(,bits ,fg ,bg ,attrs . ,where) spec)
                             (phase (cooked--box-phase
                                     bits window (car where) (cadr where))))
                  (put-text-property (point) (1+ (point)) 'display
                                     (cooked--box-glyph-image
                                      bits fg bg attrs window phase))))
              (goto-char next))))))))

(defun cooked--rescale-box-glyphs-on-zoom (_symbol _newval operation where)
  "React to `text-scale-mode-amount' changing so bitmaps track the zoom level.

A variable watcher rather than advice on `text-scale-set' or
`text-scale-mode-hook': in current Emacs, `text-scale-increase'/`-decrease' are
native subrs that do not reliably dispatch back through the Lisp-visible
`text-scale-set' symbol, so advice on it can silently never fire, and a
define-minor-mode body is not guaranteed to re-run its hook on every amount
change once the mode is already active. The buffer-local amount variable
itself is the one thing every zoom entry point actually sets."
  (when (eq operation 'set)
    (with-current-buffer (or where (current-buffer))
      (when (derived-mode-p 'cooked-mode)
        (cooked--rescale-box-glyphs)))))

(add-variable-watcher 'text-scale-mode-amount #'cooked--rescale-box-glyphs-on-zoom)

;;;; Putting styled text in the buffer

(defun cooked--insert-runs (runs &optional row)
  "Insert RUNS, each (TEXT FG BG ATTRS GLYPHS), with faces applied.

Colour rides on `face' alone.  `cooked-mode' clears `font-lock-defaults',
which comint leaves at (nil t) — under that setting any fontification of the
buffer unfontifies it first and strips a bare `face', which is why this used to
set `font-lock-face' alongside it.

GLYPHS is nil for a plain-text run, or a unibyte string of raw box-glyph
descriptors (see src/emu/glyph.rs) classified by the native core, packed
little-endian in two bytes per character of TEXT.  When present, and
`cooked-box-drawing-images' allows it, each character additionally gets a
generated bitmap `display' property so it renders as a pixel-exact shape
instead of whatever the font happens to draw for that codepoint.

ROW is the screen row these runs make up, where the caller knows it.  Point on
entry is that row's screen column 0, which is the origin a shade glyph's dither
is phased against — and is not the same as the row's line beginning, since row 0
can continue a wrapped line."
  (let ((origin (point)))
    (dolist (run runs)
      (pcase-let ((`(,text ,fg ,bg ,attrs ,glyphs ,ul) run))
        (let ((start (point))
              (face (cooked--face fg bg attrs ul)))
          (insert text)
          (when face
            (put-text-property start (point) 'face face))
          (when (and glyphs cooked-box-drawing-images (image-type-available-p 'xbm))
            (cooked--overlay-box-glyphs start glyphs fg bg attrs origin row)))))))

;;;; Who owns the keyboard
;;
;; The question the whole package turns on, and the reason this is here rather than
;; in cooked-mode.el with the keymaps it selects: rendering has to ask it.  Applying
;; a drain means lifting the pending input out of the buffer, rewriting the screen
;; underneath it and putting it back — which is a question about ownership, asked
;; from inside the process filter, long before any key is pressed.
;;
;; So the state and the policy derived from it live at this level, and the layer
;; above binds keys to them.  What cooked.el still calls upward is only ever a
;; notification that something changed; `cooked--refresh-keymap' is the one that
;; matters, and it is the seam `cooked-state-change-hook' hangs off.

(defvar-local cooked--input-end nil
  "Marker after the pending input.

The far edge only.  The near edge is the buffer's process mark -- see
`cooked--input-mark' -- and this is the half comint has no counterpart for:
comint's input runs to `point-max', while cooked's has rendered screen rows
below it.")
(defvar-local cooked--semantic nil
  "OSC 133 state: nil, `prompt', `input' or `output'.")
(defvar-local cooked--semantic-seen nil
  "Whether any OSC 133 mark has arrived in this session.

Latched, because `cooked--semantic' goes back to nil between `command-end' and
the next `prompt-start' and so cannot answer \"is the integration working?\".
Once a shell has spoken at all, it will keep speaking, and everything it does
not say becomes informative -- see `cooked--policy'.")
(defvar-local cooked--command-start nil
  "Marker where the running command's output began.")
(defvar-local cooked--command-input nil
  "The running command's own line, as cooked submitted it.")
(defvar-local cooked--submitted-input nil
  "The last line submitted, waiting for the OSC 133 mark that says it started.")
(defvar-local cooked--commands nil
  "Finished `cooked-command' records, newest first.")

(defun cooked--policy ()
  "How the buffer should behave right now: `cooked', `command', `raw' or `alt'.

Derived rather than reported, because no single source knows the answer.  The
alt screen comes from the child's own output, the line discipline is sampled
from termios, and the prompt state comes from OSC 133 -- and the three
disagree routinely.  A shell sits in termios raw mode at every prompt, because
readline does its own editing; a full-screen program can start while the last
OSC 133 mark still says `prompt-end'.

Alt wins over everything.  It is the one state in which the child has taken the
screen over completely, so Emacs owns neither the keyboard nor the viewport --
and it is in-band, arriving at an exact position in the byte stream, where the
termios mode is sampled on a poll and is only approximately timed.

`command' and `raw' are the same situation -- the child owns the keyboard --
told apart by how well we know it.  With the OSC 133 integration working, a raw
read that is not a prompt means the shell is running something, and it said so;
that is as positive a signal as the alt screen, so `command' keeps nothing back.
Without it, `raw' is a guess covering both a real full-screen program and a
shell editing its own prompt line, and `cooked-raw-exceptions' hedges against
the second.  Making that hedge conditional is the point: it costs the shell
`C-u' and `C-l', and there is no reason to pay when the shell is telling us
exactly what is going on."
  (cond (cooked--alt 'alt)
        ;; A password read forwards keys too; the minibuffer collects them.
        ((eq cooked--mode 'secret) 'raw)
        ((eq cooked--mode 'cooked) 'cooked)
        ((eq cooked--semantic 'input) 'cooked)
        (cooked--semantic-seen 'command)
        (t 'raw)))

(defun cooked--secret-p ()
  "Whether the child is reading with echo off.
An overlay on the policy rather than one of its values: it says how input is
collected, not who owns the screen."
  (eq cooked--mode 'secret))

(defun cooked--input-state-p ()
  "Whether Emacs should be editing rather than passing keys through."
  (eq (cooked--policy) 'cooked))

(defun cooked--child-owns-keyboard-p ()
  "Whether the child, rather than Emacs, is the one being typed at.

Every policy but `cooked', which is to say `alt', `command' and `raw' -- said
that way round on purpose.  Spelling it as a list of the states that qualify is
what left `command' out of three separate checks when it was added: the answer
is a property of not being at a prompt, so asking that directly cannot go stale
when another state arrives."
  (not (cooked--input-state-p)))

(defun cooked--input-mark ()
  "The marker where the pending input begins, or nil before a session.

This is the buffer's process mark, not a variable of our own.  comint's entire
command set navigates relative to `process-mark', so keeping the near edge of
the input region anywhere else is what made `comint-previous-input' answer
\"Not at command line\" -- the mark it consults was one cooked never maintained.
Storing it here rather than copying it into a private marker means there is no
second opinion to drift: one concept, one marker.

`cooked--wake' carries it.  The pipe is a doorbell the child rings, and it owns
no text, so its mark is free for this; attaching it to the buffer is what makes
`get-buffer-process' answer at all.  The mark points nowhere whenever the child
owns the keyboard, so `marker-position' is nil then and `cooked--input-region'
is the guard callers should go through."
  (and cooked--wake (process-mark cooked--wake)))

(defun cooked--set-input-mark (position)
  "Point the input mark at POSITION, or nowhere when POSITION is nil."
  (when-let* ((mark (cooked--input-mark)))
    (set-marker mark position)))

(defun cooked--clear-input-region ()
  "Forget the pending input region, leaving its text alone."
  (cooked--set-input-mark nil)
  (setq cooked--input-end nil))

(defun cooked--input-region ()
  "The pending input's bounds as (START . END), or nil when there is no region.

Both ends are set together by `cooked--restore-pending-input' and cleared
together by `cooked--clear-input-region', but either can also be left pointing
nowhere when its buffer text goes, so both have to be checked.  Callers that
want one end of a region that exists should take it from here rather than
repeating the pair of nil tests."
  (when-let* ((mark (cooked--input-mark))
              (start (marker-position mark))
              (end (and cooked--input-end (marker-position cooked--input-end))))
    (cons start end)))

(defun cooked--input-start-position ()
  "Where the pending input begins, or nil if there is no input region."
  (car (cooked--input-region)))

(defun cooked--pending-input ()
  "The text the user has typed but not yet submitted."
  (when-let* ((region (cooked--input-region)))
    (buffer-substring-no-properties (car region) (cdr region))))

(defvar cooked-snap-commands
  '(self-insert-command cooked-newline newline newline-and-indent
    yank yank-pop cooked-paste cooked-evil-paste
    evil-paste-before evil-paste-after evil-paste-from-register)
  "Commands that should act on the input region even if point drifted out of it.
See `cooked--snap-to-input'.

Plain `newline' is here because `evil-collection' binds S-RET to it directly
rather than to `cooked-newline', so it needs the same protection.")

(defun cooked--snap-to-input ()
  "Move point into the pending-input region before an insertion command.

Point leaves the input line far more easily than it looks.  The screen is
rendered with a newline after the last row, so there is a blank line below the
prompt to sit on; and evil's normal state pulls the cursor back off the end of a
line, which at an empty prompt lands it on the last character of the prompt
itself.  Both are one keystroke away from the prompt at all times.

Typing from either place goes wrong quietly.  Before the region the prompt is
read-only, so the insert signals \"Text is read-only\"; after it the text lands
outside the markers `cooked-send-input' reads, so it sits in the buffer looking
submitted while the child is sent an empty line."
  (when (and (memq this-command cooked-snap-commands)
             (cooked--input-state-p))
    (when-let* ((region (cooked--input-region)))
      (cond ((< (point) (car region)) (goto-char (car region)))
            ((> (point) (cdr region)) (goto-char (cdr region)))))))

(defun cooked--take-pending-input ()
  "Remove the pending input from the buffer and return it."
  (when-let* ((region (cooked--input-region))
              (text (buffer-substring-no-properties (car region) (cdr region))))
    (delete-region (car region) (cdr region))
    text))

(defun cooked--restore-pending-input (text)
  "Re-insert TEXT at the cursor, re-establishing the input region.

The near edge goes on the process mark, whose insertion type stays nil so that
typing at the very start of the prompt lands inside the region rather than
pushing it along."
  (when (cooked--input-state-p)
    (save-excursion
      (goto-char (cooked--cursor-position))
      (cooked--set-input-mark (point))
      ;; comint brackets the last input with `comint-last-input-start'/`-end'.  The near
      ;; edge is this same position -- the OSC 133 `prompt-end' anchor names the row, but
      ;; only the input mark knows the column the prompt actually ended at.
      ;;
      ;; Re-set on every drain, and it has to be: this marker sits mid-row, and
      ;; `cooked--render-rows' deletes a damaged row from its start to end of line, so
      ;; anything inside collapses to the row's beginning.  `comint-last-input-end' does
      ;; not have the problem, sitting at the start of the output row -- a row boundary,
      ;; which survives -- and it is the one comint's output family actually measures
      ;; from.  `comint-last-input-start' is read only by `comint-output-filter's
      ;; echo suppression, which is comint's insertion path and never runs here.  If that
      ;; ever changes, this marker needs a cell rather than a position behind it.
      (set-marker comint-last-input-start (point))
      (when text (insert text))
      (setq cooked--input-end (copy-marker (point) t)))))

(defun cooked--point-after-input ()
  "Where point belongs after a redisplay."
  (or (and cooked--input-end (marker-position cooked--input-end))
      (cooked--cursor-position)))

(defun cooked--handle-semantic (event batch-start)
  "Track OSC 133 EVENT and the buffer markers that come with it.

Each mark carries an anchor saying where in the output it actually fell, which
`cooked--anchor-position' turns into a buffer position given BATCH-START, this
drain's scrollback insertion point.  The cursor is emphatically not a
substitute: by the time a drain is applied it is where the *last* thing in that
drain left it, so a script running several commands between two redisplays
would file all of their output under one region ending wherever it stopped."
  (setq cooked--semantic-seen t)
  (pcase event
    (`(prompt-start ,_) (setq cooked--semantic 'prompt))
    (`(prompt-end ,_)
     (setq cooked--semantic 'input)
     (cooked--refresh-keymap))
    (`(command-start ,at)
     (let ((start (cooked--anchor-position at batch-start)))
       (setq cooked--semantic 'output
             cooked--command-start (copy-marker start)
             ;; Whatever we last submitted is what is now running.
             cooked--command-input (prog1 cooked--submitted-input
                                     (setq cooked--submitted-input nil)))
       ;; Output begins here, so this is where the input ended.  `comint-delete-output',
       ;; `comint-show-output' and `comint-write-output' all measure from it; it sat at
       ;; `point-min' until now, which is why deleting output flushed the whole buffer.
       (set-marker comint-last-input-end start)
       (set-marker comint-last-output-start start))
     ;; The shell has left the prompt, so its completion widget is not reading and
     ;; the nonce it announced is spent.  The shell would refuse a request built on
     ;; it anyway; not sending one is better, since those bytes would land in
     ;; whatever is now running.
     (cooked--completion-forget-nonce)
     (cooked--refresh-keymap))
    (`(command-end ,code ,at)
     (setq cooked--semantic nil)
     (cooked--mark-command-end code (cooked--anchor-position at batch-start)))))

(defun cooked--mark-command-end (code end)
  "Record exit CODE for the command that just finished, whose output ends at END."
  (when (and cooked--command-start (marker-position cooked--command-start))
    (let ((beg (marker-position cooked--command-start))
          (end (min (point-max) end))
          (code (or code 0)))
      (when (< beg end)
        (put-text-property beg end 'cooked-exit-code code))
      (push (cooked--command-make :start (copy-marker beg) :end (copy-marker end)
                                  :code code :input cooked--command-input)
            cooked--commands)))
  (setq cooked--command-start nil cooked--command-input nil))

;;;; Locating a cell in the buffer
;;
;; The grid outlives the text.  A redraw deletes and reinserts whole rows, so a
;; buffer position is not a stable way to say where something on the screen is,
;; while a (ROW . COL) cell is — and the two have to be converted into each other
;; constantly.  `cooked--goto-screen-row' is the primitive both directions rest
;; on, and row 0 is the awkward case in each of them.

(defun cooked--goto-screen-row (index &optional extend)
  "Move point to the start of screen row INDEX.

With EXTEND, add the lines needed to reach it; the screen region is trimmed
to its content, so a row below the cursor may not have a line yet.  Without
EXTEND this only moves point, which keeps queries free of side effects.

Row 0 begins at `cooked--screen-start' itself, which is not always the start of
a buffer line: when the last row handed to scrollback was wrapped it was written
without a newline, because row 0 continues it.  `forward-line' would snap back
to that line's beginning, and the caller would then delete the head it was
meant to continue — a whole row lost per eviction.  Rows below it are
unaffected: moving forward from a mid-line start lands on the next buffer
line, which is right,
because row 0 owns the remainder of the shared one."
  (goto-char cooked--screen-start)
  (let ((missing (if (zerop index) 0 (forward-line index))))
    ;; `forward-line' counts a final line that lacks a newline as one line
    ;; successfully moved, so it can report success while leaving point at that
    ;; line's end rather than at the start of the row we asked for.  Rendering
    ;; the next row then appends to the previous one — which is how a command's
    ;; output and the following prompt end up sharing a line.
    (unless (or (zerop index) (bolp))
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
    (cooked--goto-screen-row (cooked-cursor-row cooked--cursor) 'extend)
    (let ((short (- (cooked-cursor-col cooked--cursor) (- (line-end-position) (point)))))
      (when (> short 0)
        (goto-char (line-end-position))
        (insert (make-string short ?\s))))))

(defun cooked--render-scrolled (rows)
  "Append ROWS to the scrollback above the live screen, returning where they went.

The return value is the buffer position the batch was inserted at, which is what
a `scrolled' anchor is an offset from — see `cooked--anchor-position'.  It stays
valid for the rest of the redisplay: everything rendered afterwards goes below
it.

The marker is advanced explicitly rather than by insertion type:
rendering screen row 0 also inserts at this position, and an
auto-advancing marker would drift into the screen region.

Widens first: history can arrive while the alt screen is up — a resize evicts
rows from the primary even when a full-screen program is showing — and the
insertion point is above the region `cooked-alt-screen-pin' confines us to."
  (save-restriction
    (widen)
    (save-excursion
      (goto-char cooked--screen-start)
      ;; ROWS arrives pre-assembled as (TEXT STYLE-SPANS GLYPH-SPANS), so this is one
      ;; insert of plain text plus property calls only where styling or glyphs exist.
      ;; Note that building a propertized string in Lisp and inserting that instead
      ;; measures three times slower: `concat' on propertized strings makes Emacs copy
      ;; and merge property intervals over and over.
      (pcase-let ((`(,text ,spans ,glyph-spans) rows))
        (let ((start (point)))
          (insert text)
          (dolist (span spans)
            (pcase-let ((`(,from ,to ,fg ,bg ,attrs ,ul) span))
              (when-let* ((face (cooked--face fg bg attrs ul)))
                (put-text-property (+ start from) (+ start to) 'face face))))
          ;; Box-drawing that scrolled into history is rasterized exactly as it would
          ;; be live, via the same `cooked--overlay-box-glyphs' the screen region uses
          ;; — there is no screen column here to phase a shade glyph's dither against,
          ;; which costs at most a seam on that one glyph kind, same as a live row
          ;; rendered without a known origin.
          (when (and glyph-spans cooked-box-drawing-images (image-type-available-p 'xbm))
            (dolist (span glyph-spans)
              (pcase-let ((`(,from ,_to ,fg ,bg ,attrs ,glyphs) span))
                (cooked--overlay-box-glyphs (+ start from) glyphs fg bg attrs))))
          ;; Scrollback never changes again, so it is protected once, here, rather
          ;; than re-swept on every redisplay.
          (add-text-properties start (point)
                               '(cooked-scrollback t read-only t
                                 front-sticky (read-only) rear-nonsticky (read-only)))
          (set-marker cooked--screen-start (point))
          start)))))

;;;; The child's cursor, while Emacs has wandered off it

(defcustom cooked-cursor-shapes
  '((block . t) (underline . hbar) (bar . (bar . 2)))
  "How DECSCUSR shapes map onto `cursor-type'.

The child names a shape with `CSI Ps SP q'; vim and fish's vi-mode use it to
show which mode they are in.  Only the shape is honoured — DECSCUSR also
distinguishes blinking from steady, and whether your cursor blinks is
`blink-cursor-mode', which is yours to set and not the child's."
  :type '(alist :key-type symbol :value-type sexp)
  :group 'cooked)

(defun cooked--cursor-type ()
  "The `cursor-type' for the shape the child last asked for."
  (alist-get (cooked-cursor-shape cooked--cursor) cooked-cursor-shapes t))

;; The ghost cursor below deliberately does not follow the shape.  It is hollow to
;; say "not receiving your keystrokes", and that reading comes from the hollowness
;; rather than from the outline — Emacs has no meaningful hollow bar to draw anyway.

(defface cooked-ghost-cursor
  '((t :box (:line-width (-1 . -1))))
  "Face marking where the child's cursor is while point is somewhere else.

Drawn hollow on purpose.  A terminal draws its cursor hollow when the window
is unfocused, so the shape already reads as \"this cursor is not receiving
your keystrokes\" — which is exactly what is true of the child's cursor while
you are navigating with Emacs' own motions."
  :group 'cooked)

(defvar-local cooked--ghost-cursor nil
  "Overlay drawing the child's cursor, or nil when it is not being drawn.")

(defvar-local cooked--wandered nil
  "Whether a command has moved point off the child's cursor.

Tracked as a state set by commands rather than inferred by comparing point to
the cursor on each drain.  The comparison is order-dependent — streaming output
lets the cursor overtake point for a single drain — and inferring from it would
strand point for every drain after that.  See `cooked--apply'.")

(defun cooked--sync-cursor-type ()
  "Make `cursor-type' say what the child last asked for.

Written only on an actual change: reassigning the same value on every drain
perturbs the cursor's blink phase, one more contributor to flicker on a line the
child rewrites rapidly.

Called at the *end* of a drain, after the block that scrolls windows, and again
from `post-command-hook'.  `evil' advises `select-window' to refresh its own
cursor, and refreshes it again from `window-configuration-change-hook' and on
every state change; the render selects windows in order to `recenter' them.  Set
any earlier and evil gets the last word inside the very drain that hid the
cursor -- and because this writes only on a change, the next drain computes the
same value, skips the write, and never repairs it.  The visible result was a
cursor jumping around a progress bar the child had asked to draw without one."
  (let ((shape (and cooked--cursor
                    (cooked-cursor-visible cooked--cursor)
                    (cooked--cursor-type))))
    (unless (equal cursor-type shape)
      (setq-local cursor-type shape))))

(defun cooked--ghost-cursor-visible-p ()
  "Whether the child's cursor should be drawn separately from point."
  (and cooked--wandered
       ;; Only where the child owns the keyboard and the screen is its drawing.
       ;; At a prompt, point being elsewhere is ordinary editing, not a divergence.
       (cooked--child-owns-keyboard-p)
       ;; A hidden cursor stays hidden; nvim hides it during some redraws, and a
       ;; box left behind would be a cursor the child does not think it has.
       (cooked-cursor-visible cooked--cursor)))

(defun cooked--update-ghost-cursor ()
  "Draw, move, or remove the overlay marking the child's cursor."
  (if (not (cooked--ghost-cursor-visible-p))
      (when cooked--ghost-cursor
        (delete-overlay cooked--ghost-cursor)
        (setq cooked--ghost-cursor nil))
    (let* ((beg (cooked--cursor-position))
           (eol (save-excursion (goto-char beg) (line-end-position)))
           ;; Past the last character of its row the cursor has nothing to cover,
           ;; so the box rides on a stand-in space instead.
           (empty (>= beg eol)))
      (unless cooked--ghost-cursor
        (setq cooked--ghost-cursor (make-overlay beg beg nil t nil))
        ;; Above `hl-line-mode' and the region, which would otherwise paint over
        ;; the one thing on screen the user is aiming at.
        (overlay-put cooked--ghost-cursor 'priority 100))
      (move-overlay cooked--ghost-cursor beg (if empty beg (1+ beg)))
      (overlay-put cooked--ghost-cursor 'face (unless empty 'cooked-ghost-cursor))
      (overlay-put cooked--ghost-cursor 'after-string
                   (when empty (propertize " " 'face 'cooked-ghost-cursor))))))

;;;; Shaping the screen region
;;
;; What the buffer looks like between drains: how tall the live region is, what
;; the alternate screen does to the rest of the buffer, where the read-only text
;; ends, and the one place a row is allowed to disagree with the emulator about
;; its own width.

(defun cooked--set-alt (on)
  "Adopt alternate-screen state ON, refreshing ownership when it changes.

The keymap has to follow this and not only the line discipline: a program can
take the screen while the shell's last OSC 133 mark still says `prompt-end',
and Emacs would otherwise keep editing an input region that no longer exists
and swallow the keys the program was waiting for."
  (let ((on (and on t)))
    (unless (eq on cooked--alt)
      (setq cooked--alt on)
      (cooked--refresh-keymap))))

(defun cooked--apply-alt-pin ()
  "Confine the buffer to the screen region while the alt screen is up.

Re-applied on every redraw rather than only on the transition: the accessible
end behaves like a marker that insertions push past, so rows appended at the
end of one redraw would fall outside the region by the next.

Only ever undoes its own restriction.  A narrowing the user made themselves is
none of our business, and widening it on the next drain would make `\\[narrow-to-region]'
unusable in a terminal buffer."
  (if (and cooked--alt (eq cooked-alt-screen-pin 'narrow)
           (cooked--screen-start-position))
      (progn
        (narrow-to-region (cooked--screen-start-position) (point-max))
        (setq cooked--narrowed t))
    (cooked--release-alt-pin)))

(defun cooked--release-alt-pin ()
  "Undo the restriction `cooked--apply-alt-pin' put on the buffer, if any."
  (when cooked--narrowed
    (setq cooked--narrowed nil)
    (widen)))

(defun cooked--fit-screen ()
  "Shape the screen region to the number of rows the emulator says it has.

One number, and the emulator's rather than ours.  Which one differs by screen:

On the alternate screen a terminal is a fixed rectangle, so the region holds the
grid's full height — trimming to content would fight a full-screen program, and
leaving the old lines in place is why a shrunk window kept showing stale rows.

On the primary it holds `:used' rows, which is where the emulator's own content
ends: everything down to the last row holding something, and never above the
cursor.  A terminal shows a fixed rectangle but a buffer should not carry two
dozen empty lines under the prompt, and a program drawing below the cursor is
inside `:used' by construction, so its layout survives.

Unconditional in both cases.  This used to delete only a *wholly blank* tail on
the primary, which is a question about the buffer's text rather than about the
grid, and the two stop agreeing the moment a height shrink evicts rows: the rows
that left were inserted above as scrollback and the survivors re-rendered from
row 0 down, but the old lines below the new last row are not blank — they are a
stale copy of the live screen — so nothing removed them and the screen appeared
twice."
  (save-excursion
    (let ((rows (if cooked--alt
                    (cooked-grid-height cooked--grid)
                  (cooked-grid-used cooked--grid))))
      ;; `extend' on the alt screen only: the rectangle must be exactly that tall even
      ;; where the program has drawn nothing, while the primary is trimmed to content
      ;; and has no business growing here.  Without `extend' a region already short
      ;; enough reports the shortfall and is left alone.
      (when (zerop (cooked--goto-screen-row rows (and cooked--alt 'extend)))
        (delete-region (point) (point-max))))))

(defun cooked--check-seam ()
  "Signal if the buffer disagrees with the emulator about the seam.

`:head' is how many characters of screen row 0's logical line are already in the
buffer, so `cooked--screen-start' must sit exactly that far into its line: the
two ends each hold half of one wrapped line and nothing else ties them
together.  A drift here is silent — the text reads fine until the next rewrap
resumes the line in the wrong column — which is what this exists to make loud.

Only meaningful while wrapped rows are being rejoined.  With
`cooked-rejoin-wrapped-lines' off every row handed over gets a newline of its
own and the marker is always at a line start, whatever the emulator carries.

Called under `cooked-debug' only.  It is a whole-line measurement on every
drain, and the invariant it guards is maintained in the native core rather than
here, so there is nothing for it to repair — see `Row::line_runs' in
src/emu/cell.rs."
  (when-let* ((start (and cooked-rejoin-wrapped-lines
                          (cooked--screen-start-position))))
    (let* ((head (save-excursion (goto-char start)
                                 (- start (line-beginning-position))))
           (want (cooked-grid-head cooked--grid)))
      (unless (= head want)
        (error "cooked: seam desync: buffer holds %d characters of row 0's line, emulator says %d"
               head want)))))

(defun cooked--protect (limit)
  "Make the screen read-only up to LIMIT, leaving anything after it editable.

Stickiness carries the whole design: `rear-nonsticky' leaves the far edge
open so typing at the start of the input region is accepted, while
`front-sticky' closes the near edge so nothing can be wedged in above the
transcript."
  (when (cooked--screen-start-position)
    (let ((beg (min (cooked--screen-start-position) limit)))
      (add-text-properties beg limit
                           '(read-only t front-sticky (read-only) rear-nonsticky (read-only)))
      (when (< limit (point-max))
        (remove-text-properties limit (point-max) '(read-only nil))))))

(defun cooked--guard-row-width (start)
  "Keep the screen row beginning at START to one screen line.

Every live row is its own hard-newlined buffer line — `cooked--render-rows'
always starts one at `cooked--goto-screen-row' and never joins it to its
neighbours — so Emacs softwrapping one is never legitimate output. It only
happens when some character's real rendered width disagreed with what
`cooked--cols' assumed for it: an ambiguous East-Asian-width character, a
composed grapheme, a font substitution, a ligature, anything. Rust's width
model is not the place to chase that — it has to stay the plain narrow
classification curses programs expect it to report — so this catches
whatever gets through on the one side that can actually observe the truth:
Emacs' own layout.

Only checked when a mismatch is even possible, as a cheap fast path: a plain
ASCII row can still disagree on a graphical frame, where font shaping can turn
`->' or `!=' into a single ligature glyph no narrower-font metric predicts —
but never in a terminal frame, which has no shaping engine to disagree with
Rust in the first place. Non-ASCII content is checked on both, since an
ambiguous-width or composed character can mismatch either way.

`vertical-motion' is that layout decision, reused rather than re-derived
from pixel widths, so this is correct regardless of cause. A row found to
wrap is trimmed from the end, one character at a time — rarely more than
one or two, since the mismatch is usually a column or so — until it no
longer does, and the cut is marked with the same right-fringe truncation
bitmap plain `truncate-lines' would show. That has to be done by hand:
`cooked-rejoin-wrapped-lines' (which see) keeps `truncate-lines' off
buffer-wide precisely so a *genuinely* wrapped scrollback line can still
softwrap and reflow for free, and this must not fight that.

Trimming by character rather than by grapheme cluster is an accepted gap: a
cut that lands between a base character and a combining mark is possible in
principle and vanishingly unlikely in practice, since the trigger is a
character whose own width was already mismeasured, not an adjacent one."
  (when (and cooked-rejoin-wrapped-lines (< start (line-end-position)))
    (goto-char start)
    (when (or (display-graphic-p)
              (string-match-p (rx (not ascii)) (buffer-substring-no-properties start (line-end-position))))
      (let (trimmed)
        ;; `line-end-position' has to be captured before `vertical-motion' moves
        ;; point, not after: taken after, it measures the end of whatever line
        ;; `vertical-motion' landed on rather than the row's own end, so a row that
        ;; does not wrap at all still reads as short of it (that next buffer line's
        ;; end is almost always past a one-line hop) — a false positive on every
        ;; non-ASCII row followed by a non-blank one, not just a genuinely
        ;; mismeasured one. The loop then deletes real characters, and once the
        ;; row is empty keeps going: `end-of-line' at START stops moving, so the
        ;; delete starts eating the newline above START and then the row below.
        (let (eol)
          (while (progn (goto-char start)
                        (setq eol (line-end-position))
                        (vertical-motion 1)
                        (< (point) eol))
            (setq trimmed t)
            (delete-region (1- eol) eol)))
        (when trimmed
          (goto-char start)
          (cooked--mark-truncation (1- (line-end-position))))))))

(defun cooked--mark-truncation (cut)
  "Mark the row ending at CUT as having had characters trimmed off it.

Where the marker goes depends on whether there is a fringe to put it in, and the
difference is a column of the user's text:

On a graphical frame it rides an overlay's `after-string' rather than a
`display' property on CUT itself.  A fringe `display' spec shows its bitmap
\"instead of the characters that have the display specification\" (see Other
Display Specs in the Elisp manual), so putting one on a real character silently
costs the row one more character than the trim already did — while the point of
using the fringe is that it sits outside the text area and costs nothing, which
is how `truncate-lines' draws its own arrow.  The overlay evaporates on its own:
`cooked--render-rows' deletes the row before rewriting it, which empties it.

On a terminal frame there is no fringe, so the bitmap could never be drawn and
the character was disappearing with nothing shown in its place.  There a marker
has to cost a column, exactly as `truncate-lines' spends the last one on `$', so
the `display' property on CUT is right — it just has to name something visible.

Known gap: a graphical frame whose window has no right fringe (`fringe-mode' 0,
or a side window that gave it up) has nowhere to draw the bitmap, so the marker
is invisible there.  Emacs has the same problem with its own indicators and
solves it per-window; this runs per row during a drain, for a buffer that can be
in several windows at once with different fringes, so there is no one answer."
  (if (display-graphic-p)
      (let ((overlay (make-overlay cut (1+ cut))))
        (overlay-put overlay 'evaporate t)
        (overlay-put overlay 'cooked-truncation t)
        (overlay-put overlay 'after-string
                     (propertize " " 'display
                                 (list 'right-fringe (cooked--truncation-bitmap)))))
    (put-text-property cut (1+ cut) 'display
                       (string (cooked--truncation-glyph)))))

(defun cooked--truncation-bitmap ()
  "The fringe bitmap Emacs marks a line truncated on the right with.

Taken from `fringe-indicator-alist' rather than named outright, so a user who
has rebound the indicator sees their own choice here too.  Its entry is
\(LEFT RIGHT) and we are always the right-hand end.

This was `right-truncation' for a long time, which is not a fringe bitmap and
never was — `truncation' names the *indicator*, `right-arrow' the bitmap it
resolves to — so the marker silently drew nothing at all."
  (let ((indicator (cdr (assq 'truncation fringe-indicator-alist))))
    (or (if (consp indicator) (nth 1 indicator) indicator)
        'right-arrow)))

(defun cooked--truncation-glyph ()
  "The character a terminal frame marks a truncated line with.
Whatever the display table says, so a user who has rebound it sees their own
choice here too, and `$' — which is what Emacs itself falls back to — otherwise."
  (or (when-let* ((table (or buffer-display-table standard-display-table))
                  (glyph (display-table-slot table 'truncation)))
        (glyph-char glyph))
      ?$))

(defun cooked--render-rows (rows)
  "Rewrite damaged ROWS, an alist of (INDEX . RUNS)."
  (save-excursion
    (pcase-dolist (`(,index . ,runs) rows)
      (cooked--goto-screen-row index 'extend)
      (delete-region (point) (line-end-position))
      (let ((start (point)))
        (cooked--insert-runs runs index)
        (cooked--guard-row-width start)))))

;;;; Cells, anchors and positions

(defun cooked--cursor-position ()
  "Buffer position of the emulator cursor.
A pure query: it never extends the buffer, so it is safe to call before
`inhibit-read-only' is in effect."
  (save-excursion
    (cooked--goto-screen-row (cooked-cursor-row cooked--cursor))
    (min (+ (point) (cooked-cursor-col cooked--cursor)) (line-end-position))))

(defun cooked--anchor-position (anchor batch-start)
  "Buffer position ANCHOR names, or the cursor if it names nothing we can place.

ANCHOR is what the native core attached to a semantic mark, spelled in whichever
coordinate system survives the drain the mark arrived in — see `anchor_to_lisp'
in src/lib.rs:

  (scrolled . OFFSET)  characters into the scrollback this drain just
                       inserted, for a row that scrolled away while the
                       drain accumulated.  BATCH-START, from
                       `cooked--render-scrolled', is where that text begins.
  (screen ROW . COL)   a cell on the live grid, for a row still on it.

Both are resolvable only after the scrollback and the damaged rows have been
rendered, which is where `cooked--apply' dispatches events.

The fallback is the cursor, which is where every mark used to land — precise
enough whenever a drain carries a single mark, and wrong in exactly the case
anchors exist for."
  (pcase anchor
    (`(scrolled . ,offset)
     (if batch-start
         (min (+ batch-start offset) (point-max))
       (cooked--cursor-position)))
    (`(screen ,row . ,col)
     (save-excursion
       (cooked--goto-screen-row row)
       (min (+ (point) col) (line-end-position))))
    (_ (cooked--cursor-position))))

(defun cooked--screen-cell (&optional pos)
  "Screen row and column of POS, or nil if it is not on the screen.

The grid outlives the text: a redraw deletes and reinserts whole rows, so a
buffer position is not a stable way to remember where the user was looking,
while a cell is.

The inverse of `cooked--goto-screen-row', including its treatment of row 0:
when `cooked--screen-start' sits mid-line, the head before it belongs to
scrollback, so the column is measured from the marker rather than from the
line's beginning, which would count characters that are not on the screen
at all."
  (let ((pos (or pos (point)))
        (start (cooked--screen-start-position)))
    (when (and start (>= pos start))
      (save-excursion
        (goto-char pos)
        (if (< (line-beginning-position) start)
            (cons 0 (- pos start))
          (cons (count-lines start (line-beginning-position))
                (current-column)))))))

(defun cooked--goto-screen-cell (cell)
  "Move point to CELL, a (ROW . COL) pair, clamped to what the row holds."
  (cooked--goto-screen-row (car cell))
  (forward-char (min (cdr cell) (- (line-end-position) (point)))))

(defun cooked--at-child-cursor-p ()
  "Whether point is sitting where the child's cursor is."
  (and cooked--screen-start (marker-position cooked--screen-start)
       (= (point) (cooked--cursor-position))))

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

(defcustom cooked-min-redisplay-interval 0.008
  "Floor, in seconds, on how often a session triggers a redisplay.

Without one, a child that rewrites the same line rapidly -- a spinner, a
progress meter -- drives one full Emacs redisplay per write, far more than
any of them are actually meant to be seen at, which shows up as flicker.
Modelled on `eat-minimum-latency', though a matching ceiling on the other
end is not needed: the native core always holds the latest terminal state
regardless of whether a redisplay was requested for it, and retries a
throttled one on every read cycle, so nothing is ever stranded behind this.

Lower it if the terminal feels less responsive than it should; raise it if
it still flickers.  Takes effect for sessions started after it is set."
  :type 'number
  :group 'cooked)

(defcustom cooked-backlog-limit 8000
  "Items awaiting collection before the child is left to block on its writes.

Counts scrolled-off lines plus undelivered events.  Raising it does not make
output render faster: throughput is bounded by how fast Emacs can insert text,
not by this queue.  What it changes is who waits.  Below the limit the child
runs ahead and finishes sooner while Emacs catches up; at the limit the reader
stops draining the pty, the pty's buffer fills, and the child blocks in `write'
exactly as it would against a slow terminal.  Nothing is ever dropped.

The cost of raising it is memory, and a larger worst-case pause when a big
backlog finally lands in one redisplay.  Tuned together with
`cooked-min-redisplay-interval': a longer interval leaves more to accumulate
between drains, so this fills sooner.

Takes effect for sessions started after it is set."
  :type 'natnum
  :group 'cooked)

(defun cooked--start (argv &optional directory extra-env)
  "Spawn ARGV in the current buffer, optionally in DIRECTORY.
EXTRA-ENV is an alist prepended to the child's environment."
  (cooked--load-module)
  (setq cooked--face-cache (make-hash-table :test #'equal))
  (setq cooked--box-glyph-cache (make-hash-table :test #'equal))
  (setq cooked--box-ascent-cache (make-hash-table :test #'equal))
  (pcase-let ((`(,rows . ,cols) (cooked--window-size)))
    (setq cooked--rows rows cooked--cols cols))
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (make-string cooked--rows ?\n))
    (setq cooked--screen-start (copy-marker (point-min) nil)))
  ;; Attached to the buffer, unlike a plain doorbell would be: `get-buffer-process'
  ;; answering is the whole of what comint needs from a process, since every one of
  ;; its commands works through `process-mark' and none of them through the process
  ;; itself.  `shell-maker' buys the same thing by spawning a `hexl' it never speaks
  ;; to; we already had a process object and were only withholding it.
  ;;
  ;; Nothing may ever write here: the read end belongs to Rust, and a stray
  ;; `process-send-string' would land in the wakeup channel.  `comint-input-sender'
  ;; is overridden in `cooked-mode' so comint's own submission path cannot.  The
  ;; sentinel is silenced because the default one inserts "Process ... finished"
  ;; into the buffer it is attached to, which is now the terminal.
  (setq cooked--wake
        (make-pipe-process :name (format "cooked-wake<%s>" (buffer-name))
                           :buffer (current-buffer)
                           :noquery t
                           :sentinel #'ignore
                           :filter (let ((buffer (current-buffer)))
                                     (lambda (_proc _string) (cooked--on-wake buffer)))))
  (set-marker-insertion-type (process-mark cooked--wake) nil)
  (cooked--set-input-mark nil)
  (setq cooked--session
        (cooked--spawn argv (cooked--child-environment extra-env) cooked--rows cooked--cols cooked--wake
                      (and directory (expand-file-name directory))
                      (round (* 1000 cooked-min-redisplay-interval))
                      cooked-backlog-limit))
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

(defvar cooked--resyncing nil
  "Whether a resync is already under way, so a failing one cannot loop.
Bound for the dynamic extent of the repair rather than kept per buffer: it
answers \"am I inside one right now\", which is not something a buffer holds.")

(defvar-local cooked--draining nil
  "Whether a drain is already running in this buffer.
See `cooked--drain-and-apply', which is where re-entry is folded away.")

(defvar-local cooked--drain-pending nil
  "Whether a drain was asked for while one was already running.")

(defun cooked--drain-and-apply ()
  "Apply whatever the native core has accumulated since the last drain.

Re-entrant calls are folded into the drain already under way rather than
nested inside it.  `cooked--apply' decides `follow', `wandered' and the
windows that count as following *before* it rewrites the screen, and then
calls three things that can refresh the keymap -- `cooked--set-alt',
`cooked--set-mode' and `cooked--handle-event' for an OSC 133 mark.  A
refresh that lifts a freeze asks for a catch-up drain, so nesting there would
leave the outer `cooked--apply' finishing against an update, and a set of
captured positions, two drains stale.

Nothing is dropped by refusing: the request is remembered and honoured once
the outer drain has returned, which is also the only point at which draining
again is safe."
  (if cooked--draining
      (setq cooked--drain-pending t)
    ;; `unwind-protect' and `setq' rather than `let': `cooked--apply' selects
    ;; other windows to recenter them, which changes the current buffer, and a
    ;; `let' on a buffer-local restores into whichever buffer is current when
    ;; the binding unwinds.
    (unwind-protect
        (progn
          (setq cooked--draining t
                cooked--drain-pending nil)
          (cooked--apply (cooked--drain cooked--session cooked-rejoin-wrapped-lines))
          ;; Bounded in practice: the pending flag is set by a freeze lifting,
          ;; and a freeze that has lifted does not lift again.
          (while (and cooked--drain-pending cooked--session)
            (setq cooked--drain-pending nil)
            (cooked--apply (cooked--drain cooked--session cooked-rejoin-wrapped-lines))))
      (setq cooked--draining nil
            cooked--drain-pending nil))))

(defun cooked--on-wake (buffer)
  "Drain BUFFER's session and apply what changed.

An error here is otherwise invisible: Emacs swallows process-filter errors, and
the symptom reaches the user as a buffer that stopped updating or a point that
jumped somewhere absurd.  Name it, then repair it — a drain that signalled
part-way through leaves the screen region disagreeing with the emulator's grid,
and no later delta mends that, because a delta only says what changed.

`cooked--resyncing' guards the repair rather than the failure: a resync that
itself fails must report and stop, not recurse a redisplay error into a loop of
them.  It is cleared once a resync completes, so this is once per failure and
not once per session.

Skipped entirely while `cooked--frozen-p': the native core keeps the
authoritative grid state regardless of whether Lisp ever asks for it, so
nothing is lost by deferring — `cooked--refresh-keymap' catches the buffer up
with one more call to `cooked--drain-and-apply' the moment the freeze lifts.
Note that `cooked--frozen-p' is false for a buffer whose window is not the
selected one, so leaving a frozen buffer resumes it rather than stranding it."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and cooked--session (not (cooked--frozen-p)))
        (if cooked-debug
            (cooked--drain-and-apply)
          (condition-case err
              (cooked--drain-and-apply)
            (error
             (message "cooked: redisplay failed: %S (point %s, cursor %S, screen-start %s)%s"
                      err (point) cooked--cursor
                      (cooked--screen-start-position)
                      (if cooked--resyncing "" "; resyncing"))
             (unless cooked--resyncing
               (let ((cooked--resyncing t))
                 (condition-case again
                     (cooked-refresh)
                   (error (message "cooked: resync failed too: %S" again))))))))))))

(defun cooked--following-windows ()
  "Other windows on this buffer whose point should track the child's cursor.

The selected window's point *is* the buffer's point for as long as it stays
selected — Emacs keeps the two in sync on its own, which is what `follow' and
`wandered' below ride on.  No such thing happens for any other window
showing the same buffer: its `window-point' is a value Emacs stores and
redisplays from independently, touched only by `set-window-point', so a
second window on a busy cooked buffer would otherwise freeze wherever it
last happened to be pointed, deaf to every later drain.

A window's own point, not the buffer's, decides whether it is still
following, mirroring `follow' one level down: scrolling that window with the
wheel or a scrollbar does not move its point, so such a window is left alone
here for the same reason `follow' would leave the buffer's point alone for
the same case — it reads as the user choosing to look elsewhere, not as a
window that fell behind."
  (when-let* ((start (cooked--screen-start-position)))
    (seq-filter (lambda (w) (>= (window-point w) start))
                (delq (selected-window) (get-buffer-window-list nil nil t)))))

(defun cooked--apply (update)
  "Apply UPDATE, the plist returned by `cooked--drain'."
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
         (follow (and (cooked--follow-p)
                      (>= (point) (cooked--screen-start-position))))
         ;; Keeping the alt screen's top row pinned to the window is not
         ;; following: the region is sized to the window, so it is the whole
         ;; picture rather than an end of output to chase.  A suspended buffer
         ;; still wants that pin -- the user is reading the screen, and a redraw
         ;; that let the window scroll off it would be the same disturbance
         ;; suspending the follow exists to prevent.
         (anchor (or follow (cooked--suspended-p)))
         ;; A redraw deletes and reinserts whole rows, so a wandered point would
         ;; be dragged to the start of whatever was rebuilt underneath it.  The
         ;; cell survives that; the buffer position does not.
         (wandered (and cooked--wandered (cooked--screen-cell)))
         ;; Captured before the redraw for the same reason `follow' is: once the
         ;; screen region is rewritten, every window's old point either points at
         ;; text that no longer means what it did or has already been dragged
         ;; along by the deletion, so which windows counted as "following" has to
         ;; be decided now, not after.
         (other-follows (cooked--following-windows))
         ;; Where this drain's scrollback landed, for resolving a `scrolled' anchor
         ;; against.  nil when the drain evicted nothing, in which case no anchor can
         ;; refer to it either.
         (batch-start (when-let* ((scrolled (plist-get update :scrolled)))
                        (cooked--render-scrolled scrolled))))
    (cooked--render-rows (plist-get update :rows))
    (setq cooked--cursor (cooked--cursor-decode (plist-get update :cursor))
          ;; Before `cooked--fit-screen' below, which is shaped by it.
          cooked--grid (cooked--grid-make :height (plist-get update :height)
                                          :used (plist-get update :used)
                                          :head (plist-get update :head))
          cooked--app-cursor (plist-get update :app-cursor)
          cooked--keys (plist-get update :keys)
          cooked--exit (plist-get update :exit))
    (cooked--set-alt (plist-get update :alt))
    (cooked--set-mode (plist-get update :mode))
    ;; After both render passes: a mark's anchor is resolved against text that has to
    ;; be in the buffer before it can be pointed at.
    (dolist (event (plist-get update :events))
      (cooked--handle-event event batch-start))
    (cooked--fit-screen)
    (cooked--pad-to-cursor)
    ;; After the region has been shaped, so it measures what was actually drawn.
    (when cooked-debug (cooked--check-seam))
    (cooked--restore-pending-input pending)
    (cooked--protect (or (and (cooked--input-state-p) (cooked--input-start-position))
                         (point-max)))
    ;; After the region has settled, so the bounds match what was just drawn.
    (cooked--apply-alt-pin)
    ;; Staying put beats following the cursor once the user has taken the
    ;; keyboard back: the child keeps redrawing under them, and being yanked to
    ;; its cursor mid-motion is the behaviour this exists to stop.  The ghost
    ;; keeps the way back visible; `cooked--snap-to-cursor' takes it.
    (cond (wandered (cooked--goto-screen-cell wandered))
          (follow (goto-char (cooked--point-after-input))))
    ;; Explicit rather than left to redisplay, for two separate reasons: a
    ;; non-selected window is never the one `goto-char' above just moved, so
    ;; nothing else here would touch it; and even the selected window's
    ;; `scroll-conservatively' is not a redisplay guarantee once output arrives
    ;; from a process filter rather than a command. `comint-postoutput-scroll-
    ;; to-bottom' recenters explicitly for exactly that reason — this mirrors
    ;; it, in place of the `comint-output-filter-functions' hook cooked cannot
    ;; use, having replaced comint's own insertion with `cooked--apply' outright.
    ;;
    ;; The alt screen takes a different path: that region is sized to the window
    ;; exactly (`cooked--fit-screen'), so a full-screen program's own cursor
    ;; position is never an "end of output" to scroll toward — the whole screen
    ;; is meant to be on screen by construction, but a resize reaches here in two
    ;; steps rather than one. The window changes height the instant Emacs notices
    ;; (`cooked--sync-size'), while the buffer is not re-fitted to match until this
    ;; drain's `cooked--fit-screen' above runs. Ordinary redisplay fills that gap
    ;; on its own terms, pushing `window-start' down to keep point on screen in
    ;; the meantime — and nothing corrected that once the buffer caught up, so the
    ;; window kept the scroll a now-irrelevant redisplay had chosen, clipping the
    ;; top of the screen. Pin it back to the region's start on every drain, not
    ;; only the transition, the same way `cooked--apply-alt-pin' re-narrows on
    ;; every drain rather than only when `cooked--alt' flips.
    ;; The selected window only belongs in any of these lists if it is actually
    ;; showing this buffer — output can arrive from a process filter while the
    ;; user's focus is on an entirely different window, and scrolling that one
    ;; would be a bug, not a courtesy.
    (let ((here (and (eq (window-buffer (selected-window)) (current-buffer))
                     (list (selected-window)))))
      (if cooked--alt
          (when anchor
            (let ((top (cooked--screen-start-position)))
              (cooked--dolist-windows w (append here other-follows)
                (set-window-start w top t))))
        (let* ((target (cooked--point-after-input))
               ;; A rendered row always ends with a newline, even the cursor's own
               ;; — see `cooked--insert-runs' — so the cursor at the true end of
               ;; output sits one short of `point-max', not on it.
               (at-end (>= target (1- (point-max)))))
          ;; Only while the view is following at all: suspending exists to stop
          ;; the child's own output moving what is being read, and a second
          ;; window on the same buffer is being read on the same terms.
          (when (cooked--follow-p)
            (cooked--dolist-windows w other-follows
              (set-window-point w target)))
          (when (and follow at-end)
            (cooked--dolist-windows w (append here other-follows)
              (with-selected-window w (recenter (- -1 scroll-margin))))))))
    ;; After the window block, not before it: see `cooked--sync-cursor-type'.
    (cooked--sync-cursor-type)
    (cooked--update-ghost-cursor)
    (when cooked--exit (cooked--on-exit cooked--exit))))

(defun cooked--handle-event (event batch-start)
  "Dispatch a single EVENT from the emulator.

BATCH-START is where this drain's scrollback was inserted, which the semantic
marks need to place their anchors; see `cooked--anchor-position'.

Events are occurrences only.  State the redisplay depends on rides the drain's
own fields instead — `:alt' and the rest — so that nothing arrives twice with
two chances to disagree."
  (pcase event
    (`(bell) (ding))
    (`(osc ,code ,bell . ,parts) (cooked--handle-osc code bell parts))
    (`(reply . ,bytes) (cooked--send-if-live bytes))
    (`(title-stack ,push) (cooked--handle-title-stack push))
    (`(erase-scrollback)
     (cooked--discard-scrollback (cooked--screen-start-position)))
    (`(display-cleared) (setq cooked--pin-screen-top t))
    (`(mouse ,enabled ,sgr)
     (setq cooked--mouse enabled cooked--mouse-sgr sgr)
     ;; The keymap that outranks `pixel-scroll-precision-mode' is gated on this,
     ;; so it has to move when the child changes its mind about the mouse.
     (cooked--update-mouse-grab))
    ((or `(prompt-start ,_) `(prompt-end ,_) `(command-start ,_) `(command-end ,_ ,_))
     (cooked--handle-semantic event batch-start))
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
    (52 . cooked--osc-clipboard)
    (99 . cooked--osc-notify)
    (777 . cooked--osc-notify-777))
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
  (cooked--set-title (string-join parts ";")))

(defun cooked--set-title (title)
  "Set the child's title to TITLE and show it."
  (setq cooked--title title)
  (cooked--rename-to-title)
  (force-mode-line-update))

(defconst cooked--title-stack-limit 8
  "How many titles `cooked--title-stack' will hold.

A child can push without ever popping — `smcup' pushes on every entry to the
alternate screen — so the stack is bounded and drops from the bottom.  Eight is
past any real nesting of full-screen programs.")

(defun cooked--handle-title-stack (push)
  "Push the current title when PUSH, otherwise pop and restore one.

XTWINOPS 22 and 23, which `smcup' and `rmcup' send around the alternate screen:
without them a full-screen program that sets a title leaves it behind on exit."
  (if push
      (setq cooked--title-stack
            (last (cons cooked--title cooked--title-stack)
                  cooked--title-stack-limit))
    ;; An underflowing pop is the child's bug, not ours; leave the title alone.
    (when cooked--title-stack
      (cooked--set-title (pop cooked--title-stack)))))

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

(defcustom cooked-allow-notifications nil
  "Whether the child may raise desktop notifications, via OSC 99 or OSC 777.

Off by default, for the same reason `cooked-allow-color-set\=' is: anything that
can write to the terminal can send one.  A `cat\=' of a hostile file, a build log
quoting attacker-controlled text, or output from a compromised host all reach
your desktop if this is on."
  :type 'boolean
  :group 'cooked)

(defcustom cooked-notification-rate '(3 . 10)
  "Cap on notifications as a cons of COUNT and SECONDS.
Notifications past the cap are dropped silently.  A child that means well
sends one when a long build finishes; a child that does not sends thousands."
  :type '(cons natnum natnum)
  :group 'cooked)

(defconst cooked--notification-limits '(120 . 500)
  "Maximum title and body length, in characters.")

(defvar-local cooked--notification-times nil
  "Timestamps of recent notifications, newest first.
See `cooked-notification-rate\='.")

(defvar-local cooked--notification-chunks nil
  "Partial OSC 99 notifications, as an alist of id to (TITLE . BODY).")

(defconst cooked--notification-chunk-limits '(8 . 4096)
  "How many partial notifications to hold, and the most text each may accumulate.

A child can open a chunked notification and never close it, so both are
bounded: without that, `cooked--notification-chunks\=' is a buffer-local leak the
child controls.")

(defun cooked--notification-clean (text limit)
  "TEXT with control characters removed, truncated to LIMIT characters."
  (truncate-string-to-width
   (replace-regexp-in-string "[[:cntrl:]]" "" (or text ""))
   limit))

(defun cooked--notification-allowed-p ()
  "Whether another notification is within `cooked-notification-rate\='."
  (pcase-let* ((`(,count . ,seconds) cooked-notification-rate)
               (cutoff (- (float-time) seconds)))
    (setq cooked--notification-times
          (seq-take (seq-filter (lambda (at) (> at cutoff))
                                cooked--notification-times)
                    count))
    (< (length cooked--notification-times) count)))

(defun cooked--notify (title body)
  "Raise a desktop notification with TITLE and BODY, subject to the rate limit."
  (when (cooked--notification-allowed-p)
    (push (float-time) cooked--notification-times)
    (let ((title (cooked--notification-clean
                  title (car cooked--notification-limits)))
          (body (cooked--notification-clean
                 body (cdr cooked--notification-limits))))
      ;; `notifications-notify\=' needs D-Bus, which a terminal Emacs may not have.
      (if (and (fboundp 'notifications-notify) (featurep 'dbusbind))
          (notifications-notify :title (if (string-empty-p title) "cooked" title)
                                :body body)
        ;; Never as a format string: the text is the child's.
        (message "%s" (string-trim (concat title " " body)))))))

(defun cooked--osc-99-metadata (meta)
  "Parse META, OSC 99's colon-separated KEY=VALUE list, into an alist.

Built once per notification rather than re-split per key looked up, which is
what asking it four questions used to cost."
  (mapcar (lambda (field)
            (let ((split (string-search "=" field)))
              (if split
                  (cons (substring field 0 split) (substring field (1+ split)))
                (cons field ""))))
          (split-string (or meta "") ":" t)))

(defun cooked--osc-notify (parts)
  "Raise a desktop notification from OSC 99 PARTS.

kitty's protocol: `ESC ] 99 ; METADATA ; PAYLOAD ST\=', where METADATA is a
set of KEY=VALUE pairs.  `i\=' identifies a notification, `p\=' says whether
the payload is its title or its body, and `d=0\=' means more chunks follow."
  (when cooked-allow-notifications
    (pcase-let* ((meta (cooked--osc-99-metadata (car parts)))
                 (payload (string-join (cdr parts) ";"))
                 (id (or (alist-get "i" meta nil nil #'equal) ""))
                 (body-p (equal (alist-get "p" meta nil nil #'equal) "body"))
                 (more (equal (alist-get "d" meta nil nil #'equal) "0"))
                 (cap (cdr cooked--notification-chunk-limits))
                 (cell (or (assoc id cooked--notification-chunks)
                           (car (push (cons id (cons "" "")) cooked--notification-chunks)))))
      ;; Bound both the number of open notifications and the text each accumulates.
      (setq cooked--notification-chunks
            (seq-take cooked--notification-chunks
                      (car cooked--notification-chunk-limits)))
      (pcase-let ((`(,title . ,body) (cdr cell)))
        (setcdr cell (if body-p
                         (cons title (truncate-string-to-width (concat body payload) cap))
                       (cons (truncate-string-to-width (concat title payload) cap) body))))
      (unless more
        (setq cooked--notification-chunks
              (assoc-delete-all id cooked--notification-chunks))
        (cooked--notify (cadr cell) (cddr cell))))))

(defun cooked--osc-notify-777 (parts)
  "Raise a notification from the older OSC 777 form, `777;notify;TITLE;BODY\='."
  (when (equal (car parts) "notify")
    (when cooked-allow-notifications
      (cooked--notify (nth 1 parts) (string-join (nthcdr 2 parts) ";")))))

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
;; Only the harmless half lives here.  `A' annotates the prompt and `C' carries
;; completion candidates; both are inert data, so they cost nothing to support.  `E'
;; is a command channel driven by bytes on the terminal — anything that can write
;; there can pull the trigger: `cat' of a hostile file, output from a compromised host
;; over ssh, a build log quoting text somebody else chose — so it is off until you
;; load `cooked-osc-eval' and say you want it.

;; Not opt-in, unlike the eval channel: candidates are a list of strings that only
;; ever reach a completion table.  `cooked-completion' is loaded with the mode.
(declare-function cooked--completion-handle "cooked-completion")

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
        (?C (cooked--completion-handle (substring payload 1)))
        (_ nil)))))

(defun cooked--discard-scrollback (end)
  "Delete scrollback from `point-min' up to END, and tell the emulator.

The only sanctioned way to delete above `cooked--screen-start', and worth
routing every future caller — a scrollback cap, a `clear' handler — through
rather than open-coding.  The scrollback is the one piece of state the two ends
co-own: Emacs holds the text, while the emulator holds a count of how much of
its top row's line already left for Emacs, so that a rewrap resumes that line
where the buffer wraps it.  A wrapped line can span the boundary being cut, so
a deletion that does not say so leaves the emulator continuing a line that is
no longer there — and the desync is silent until the next resize.

Widens first, so it still clears while a full-screen program has the buffer
narrowed to the alt screen — where `point-min' is the top of the screen and
this would otherwise quietly do nothing."
  (save-restriction
    (widen)
    (let ((inhibit-read-only t))
      (delete-region (point-min) end)))
  (when cooked--session
    (cooked--forget-history cooked--session)
    ;; `cooked--grid' is a snapshot of the last drain, and this is the one thing that
    ;; changes the emulator's seam without one.  Left stale it describes a head that was
    ;; just deleted, which `cooked--check-seam' would rightly call a desync — and which
    ;; anything else reading the seam before the next drain would believe.
    (setf (cooked-grid-head cooked--grid) 0)))

(defun cooked--discard-scrollback-region (beg end)
  "Delete scrollback between BEG and END, telling the emulator only if it must.

The narrower sibling of `cooked--discard-scrollback\=', for deleting one
command\='s output out of the middle rather than everything above a point.

What the two ends co-own is exactly one number: how much of the emulator\='s top
row\='s line has already left for Emacs.  A cut that finishes short of
`cooked--screen-start\=' cannot change it -- the text row 0 continues is still
there, still ending where it did -- so it needs no bookkeeping at all, and
saying so is what makes deleting scrolled-off output possible.  A cut that
reaches the seam does remove that head, and then this owes the emulator the same
news `cooked--discard-scrollback\=' gives it."
  (when-let* ((screen (cooked--screen-start-position))
              ((< beg end)))
    (let ((end (min end screen)))
      (when (< beg end)
        (let ((at-seam (= end screen)))
          (save-restriction
            (widen)
            (let ((inhibit-read-only t))
              (delete-region beg end)))
          (when (and at-seam cooked--session)
            (cooked--forget-history cooked--session)
            (setf (cooked-grid-head cooked--grid) 0)))))))

(defun cooked-clear-scrollback ()
  "Delete everything above the live screen."
  (interactive)
  (cooked--discard-scrollback (cooked--screen-start-position)))

(defun cooked-refresh ()
  "Rebuild the live screen from the emulator.

The way back from a redisplay that failed part-way.  An ordinary drain only
reports what changed since the last one, so it cannot repair a buffer holding
some rows of a drain that signalled halfway through applying them — the screen
region and the emulator's grid simply stay out of step, and every later delta is
applied on top of the disagreement.  This throws the screen region away and asks
the native core to re-send all of it.

The scrollback above is untouched, and so is the emulator's carry count with it:
only the region below `cooked--screen-start' is rebuilt."
  (interactive)
  (when cooked--session
    (save-restriction
      (widen)
      (let ((inhibit-read-only t))
        (cooked--release-alt-pin)
        (delete-region (cooked--screen-start-position) (point-max))
        ;; They pointed into the text just deleted; `cooked--restore-pending-input'
        ;; puts them back at the cursor on the drain below.
        (cooked--clear-input-region)))
    (cooked--redraw cooked--session)
    (cooked--drain-and-apply)))

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
