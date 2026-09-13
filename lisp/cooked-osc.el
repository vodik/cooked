;;; cooked-osc.el --- What an OSC sequence means to Emacs -*- lexical-binding: t; -*-

;;; Commentary:

;; Almost every OSC is passed through verbatim by the native core, so teaching cooked a
;; new sequence is Lisp rather than Rust -- an entry in `cooked-osc-handlers\='.
;;
;; Two are excepted, and for the same reason: they are already the core\='s own business,
;; so a handler here could only be a second opinion about state Rust already holds.  OSC
;; 133 decides who owns the keyboard.  OSC 8 is grid state -- a link id is carried per
;; cell and arrives as the drain\='s `:links\=', which `cooked-link.el\=' installs -- and
;; `State::osc\=' in src/emu/term/osc.rs returns before raising an event for either.
;;
;; The division the core draws: it interprets what changes *the terminal* -- the
;; alternate screen, mouse and paste modes, device replies -- and nothing else.  What a
;; sequence means to Emacs is Emacs\=' business, and that is this file: titles, the
;; working directory, the default colours, notifications, the clipboard, and the OSC 51
;; channel\='s two nil-valued hooks.
;;
;; Two of these are refused by default and say so in their own docstrings, for the same
;; reason: anything that can write to the terminal can send one.  See
;; `cooked-allow-color-set\=' and `cooked-allow-notifications\='.

;;; Code:

(require 'cooked)
(require 'url-util)

;; Calls upward into cooked-mode.el, and into the core for the handlers that
;; answer a query rather than merely observing it.
(declare-function cooked--reply-osc "ext:cooked-core")
(declare-function cooked--set-color-scheme "ext:cooked-core")
(declare-function cooked--update-buffer-name "cooked-mode")
(declare-function cooked--defer "cooked-mode")
(declare-function cooked--foreground-program "cooked-keys")

;; Loaded on demand by `cooked--remote-directory' and nowhere else: requiring
;; TRAMP at load time would put a large library into every session that only
;; ever runs a local shell, for a branch most of them never take.
(defvar tramp-default-method)

;;;; OSC dispatch
;;
;; Everything except OSC 133 arrives here verbatim, so a new integration is a
;; handler in this alist rather than a change to the native core.

(defvar cooked-osc-handlers
  '((0 . cooked--osc-title)
    (2 . cooked--osc-title)
    (7 . cooked--osc-cwd)
    (10 . cooked--osc-color)
    (11 . cooked--osc-color)
    (12 . cooked--osc-color)
    (17 . cooked--osc-color)
    (19 . cooked--osc-color)
    (4 . cooked--osc-palette)
    (110 . cooked--osc-color-reset)
    (111 . cooked--osc-color-reset)
    (112 . cooked--osc-color-reset)
    (51 . cooked--osc-emacs)
    (52 . cooked--osc-clipboard)
    (9 . cooked--osc-9)
    (22 . cooked--osc-pointer-shape)
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
  "Run the handler for OSC CODE with PARTS.

BELL is non-nil when the sequence arrived terminated by BEL rather than ST.

`cooked-osc-handlers' is a documented extension point called from the middle
of a drain, so this dispatch site owns the guarantee that a handler cannot
damage the drain around it: `cooked--protect-seam' for one that *fails*, and
`save-current-buffer' for one that *relocates*.  The seam key names the code
and the handler both, so two handlers failing on different codes are reported
separately rather than the first silencing the rest.  The second is not
hypothetical -- `cooked--osc-emacs' can reach `find-file', which
`switch-to-buffer's -- and an unrestored switch leaves the rest of
`cooked--apply' rewriting a buffer that has no screen."
  (when-let* ((handler (alist-get code cooked-osc-handlers)))
    (cooked--protect-seam (list 'cooked-osc-handlers code handler)
      (save-current-buffer
        (let ((cooked--osc-bell-terminated bell)
              (cooked--osc-code code))
          (funcall handler parts))))))

(defun cooked--osc-title (parts)
  "Show the child's title, from the OSC 0 or 2 payload PARTS."
  (cooked--set-title (string-join parts ";")))

(defun cooked--set-title (title)
  "Set the child's title to TITLE and show it."
  (setq cooked-title title)
  (cooked--update-buffer-name)
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
            (last (cons cooked-title cooked--title-stack)
                  cooked--title-stack-limit))
    ;; An underflowing pop is the child's bug, not ours; leave the title alone.
    (when cooked--title-stack
      (cooked--set-title (pop cooked--title-stack)))))

;;;; XTWINOPS — the window the child is laid out for
;;
;; Two things a child may ask about the window beyond the title stack above: to
;; change its size, and how big the frame around it is.  The native core answers
;; everything it can measure itself -- `18t' and `14t' are the grid -- and passes
;; these on because the frame and the window layout are Emacs', not the grid's.

(defcustom cooked-resize-requests nil
  "What a child's request to resize the terminal does.

XTWINOPS `CSI 8 ; ROWS ; COLS t' asks for a size, and DECSLPP (`CSI ROWS t'
with ROWS of 24 or more) for a row count alone.  `resize -s' sends the first.

nil      Refuse.  Nothing moves and nothing is sent back, which is what
         xterm does with `allowWindowOps' off; the child reads its real
         size back with `CSI 18 t' and learns the answer that way.
`window' Resize the window the child is laid out for toward the request,
         as far as the windows around it allow.  The frame is never
         touched, so a buffer that fills its frame cannot move at all.

Refused by default because anything that can write to the terminal can send
one, and the windows it would move are yours: a program you ran over ssh does
not get to rearrange the layout you were working in."
  :type '(choice (const :tag "Refuse" nil)
                 (const :tag "Resize the layout window" window))
  :group 'cooked)

(defun cooked--handle-resize-request (rows cols)
  "Resize this buffer's layout window toward ROWS by COLS, if allowed.

Either may be nil, meaning leave that dimension as it is.  See
`cooked-resize-requests', which decides whether anything happens at all.

Only `cooked--layout-window' moves, even when several windows show the buffer:
its size is the one the child has, so it is the one a request is about.  The
columns are capped below the next narrowest window for the same reason, since a
layout window grown past another stops being the layout window, and the child
would be handed the other one's width instead of what it asked for.

Nothing here tells the child.  The window changing size is noticed by
`window-size-change-functions' like any other resize, and that path sends the
SIGWINCH -- so the child is told once, in the one place a size is ever
reported from, and the size it is told is the one the window really took.

That is also what keeps a request from looping.  The resize is computed
against the window as it stands and clamped by `window-resizable', so asking
again for a size already reached, or for one the layout cannot give, resizes
nothing and so produces no SIGWINCH for a child to react to with another
request."
  (when-let* (((eq cooked-resize-requests 'window))
              (window (cooked--layout-window)))
    (when rows
      (cooked--resize-window-by
       window nil
       (- (* rows (window-default-line-height window))
          (window-body-height window t))))
    (when cols
      (let* ((others (delq window (get-buffer-window-list (current-buffer) nil t)))
             (cap (and others
                       (apply #'min (mapcar #'window-max-chars-per-line others))))
             (cols (if cap (min cols cap) cols)))
        (cooked--resize-window-by
         window t
         (* (- cols (window-max-chars-per-line window))
            (window-font-width window 'default)))))))

(defun cooked--resize-window-by (window horizontal pixels)
  "Resize WINDOW by up to PIXELS, HORIZONTAL or not, never touching the frame.

Pixelwise, because the child counts rows in `window-default-line-height' and
columns in the default face's width, and either can differ from the frame's
canonical character size under `text-scale-mode'.  A partial row or column the
clamp leaves behind is floored away by `cooked--window-size' like any other."
  (let ((delta (window-resizable window pixels horizontal nil t)))
    (unless (zerop delta)
      (window-resize window delta horizontal nil t))))

(defun cooked--handle-frame-size (pixels)
  "Answer XTWINOPS `19t', or `15t' when PIXELS: the frame's text area.

In cells, `CSI 9 ; ROWS ; COLS t'; in pixels, `CSI 5 ; HEIGHT ; WIDTH t'.  The
frame is the one showing the layout window, or the selected one when the
buffer is shown nowhere.  Both measure the text area, so the pixel answer is
the cell answer times a cell, the way `14t' and `18t' agree.

The pixel form is silent on a terminal frame, by the rule `14t' follows: a
terminal has no pixels, and answering zero would be a claim rather than an
absence."
  (let ((frame (if-let* ((window (cooked--layout-window)))
                   (window-frame window)
                 (selected-frame))))
    (cond ((not pixels)
           (cooked--send-if-live
            (format "\e[9;%d;%dt" (frame-text-lines frame) (frame-text-cols frame))))
          ((display-graphic-p frame)
           (cooked--send-if-live
            (format "\e[5;%d;%dt"
                    (frame-text-height frame) (frame-text-width frame)))))))

(defun cooked--osc-cwd (parts)
  "Track the child's directory, from the OSC 7 payload PARTS."
  (cooked--set-directory (string-join parts ";")))

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
same reason the OSC 51 command channel is a separate file you have to require.

The cursor color is the one that is not this buffer's alone.  Emacs has one per
frame, so an OSC 12 set is worn by the frame while this buffer is in its
selected window, the hollow cursors of the frame's other windows included, and
taken off again when it is not."
  :type 'boolean
  :group 'cooked)

(defcustom cooked-allow-notifications nil
  "Whether the child may raise desktop notifications, via OSC 9, 99 or 777.

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

Built once per notification rather than re-split per key looked up: a
notification is asked four questions, and each would otherwise rescan META."
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
  "Raise a notification from PARTS, the older `777;notify;TITLE;BODY\=' form."
  (when (equal (car parts) "notify")
    (when cooked-allow-notifications
      (cooked--notify (nth 1 parts) (string-join (nthcdr 2 parts) ";")))))

;;;; OSC 9 — two protocols under one number
;;
;; iTerm2 took OSC 9 for a one-line notification, `ESC ] 9 ; MESSAGE ST', with
;; no title and no options.  ConEmu took the same number for a family of
;; commands, `ESC ] 9 ; N ; ... ST' with N from 1 to 12, of which only `9;4',
;; progress, is anything cooked shows -- and `9;9;PATH' is a working directory,
;; which would make a nonsense notification if the two were told apart by the
;; `4' alone.
;;
;; So the test is the shape of the first field, not its value: all digits is
;; ConEmu's, whether or not cooked implements that command, and anything else
;; is a message.  The cost is that iTerm2 cannot notify with a bare number such
;; as `ESC ] 9 ; 42 ST', which is ConEmu's reading of it too and the reading
;; that is safe to get wrong: a lost notification is quieter than a working
;; directory on the desktop.

(defun cooked--osc-9 (parts)
  "Route OSC 9 PARTS to ConEmu's progress report or to iTerm2's notification.

A first field of nothing but digits is a ConEmu command: `4\=' is handed to
`cooked--osc-progress\=', and the other eleven are dropped rather than read as
text.  Anything else is iTerm2's message, which may itself contain `;\=' and so
is joined back together, and goes through `cooked-allow-notifications\=' and
`cooked-notification-rate\=' like OSC 99 and 777.  An empty message is dropped
too: there is nothing to say, and a bare `ESC ] 9 ST\=' is not a request."
  (cond
   ((or (null parts) (string-match-p (rx bos (+ digit) eos) (car parts)))
    (cooked--osc-progress parts))
   (cooked-allow-notifications
    (let ((text (string-join parts ";")))
      (unless (string-empty-p text)
        (cooked--notify "" text))))))

;;;; OSC 9;4 — how far along the child says it is
;;
;; ConEmu's progress report, and the one sequence on this axis that everything
;; modern emits: cargo, npm, winget, and every coding agent that has grown a
;; progress bar.  `ESC ] 9 ; 4 ; STATE ; PERCENT ST', where STATE is a single
;; digit and PERCENT is an optional 0-100.
;;
;; `cooked--osc-9' above has already decided this is ConEmu's rather than
;; iTerm2's; the `4' test below is what separates progress from the other
;; eleven ConEmu commands, none of which cooked acts on.
;;
;; Nothing the child sends reaches the mode line as text.  The payload is parsed
;; down to a symbol from a closed set and an integer, and `cooked--progress' can
;; hold nothing else -- so the rendering in cooked-mode-line.el is built out of
;; cooked's own vocabulary, and a hostile payload's only reachable outcome is
;; that it is refused.  That is a stronger guarantee than sanitising would be,
;; and it is deliberate: this is the same shape of channel as the OSC 7 payload
;; that turned out to be able to name a TRAMP host.

(defconst cooked--progress-states
  '(("0" . nil) ("1" . set) ("2" . error) ("3" . indeterminate) ("4" . paused))
  "ConEmu's `st' digit mapped onto the state cooked records.

Keyed by the string rather than by a number, so that `01', `1.0', ` 1' and the
empty string are all simply absent from the table instead of being rounded into
a state by `string-to-number' -- which answers 0, \"remove the indicator\", for
every one of them and for `not-a-number' besides.

`0' maps to nil because \"remove\" is not a fifth thing to display: it is the
absence of the other four, and giving it a symbol of its own would mean every
reader downstream had to know to treat that symbol as nothing.")

(defvar-local cooked--progress nil
  "What the child last said about its progress, or nil if it said nothing.

A cons of STATE and PERCENT.  STATE is one of `set\=', `error\=',
`indeterminate\=' or `paused\=' -- never a string, and never anything the child
chose.  PERCENT is an integer from 0 to 100, or nil when there is no number to
show: `indeterminate\=' never carries one, and `error\=' and `paused\=' need
not.

Read by `cooked--mode-line-progress\=', which is the only consumer.  Buffer-local
because a progress report is one session's news and the mode line is per
buffer.")

(defun cooked--progress-percent (field)
  "PERCENT from FIELD, ConEmu's `pr', or the symbol `bad' if it is not a number.

Three answers rather than two.  nil means the child sent no number, which is
legal for every state that takes one and is how `ESC ] 9 ; 4 ; 2 ST' says \"the
thing I was doing failed\" without restating how far it had got.  `bad\=' means
it sent something that is not a number, which is a different situation entirely
and one the caller refuses outright.

`string-to-number\=' cannot tell those apart -- it answers 0 for the empty
string, for `nan\=', and for a megabyte of NUL bytes -- so the digits are
checked before it is asked.  Out of range is clamped rather than refused, on
rockorager.dev's rule for the sequence and because a build tool that computes
101% has a rounding bug, not a hostile intent."
  (cond
   ((or (null field) (string-empty-p field)) nil)
   ((string-match-p (rx bos (+ digit) eos) field)
    (min 100 (string-to-number field)))
   (t 'bad)))

(defun cooked--osc-progress (parts)
  "Record the child's progress from PARTS, the OSC 9 payload after the code.

PARTS is ConEmu's `4', the state digit, and an optional percentage.  Anything
else -- a fifth field, a state outside 0-4, a percentage that is not a number --
leaves `cooked--progress\=' exactly as it was rather than guessing at what was
meant.  Refusing to act is the only safe reading of a malformed report: the
alternative is a stream that can park a wrong number in the mode line and then
stop sending, leaving it there.

A state that takes a percentage and arrives without one keeps the percentage
already on show.  That is what makes the two-sequence idiom work -- `1;70\='
while the work runs, then a bare `2\=' when it fails -- and it reads as
`[err 70%]\=', which says more than `[err]\=' does.  `indeterminate\=' drops it
instead, because a pulsing state with a stale number beside it is a lie about
which of the two the child meant."
  (when (and (equal (car parts) "4") (<= 2 (length parts) 3))
    (let ((state (assoc (nth 1 parts) cooked--progress-states))
          (percent (cooked--progress-percent (nth 2 parts))))
      (when (and state (not (eq percent 'bad)))
        (let ((carried (or percent (cdr cooked--progress))))
          (cooked--set-progress
           (cdr state)
           (pcase (cdr state)
             ('indeterminate nil)
             ;; `set' is the one state whose whole content is the number, so it
             ;; is the one that cannot be left without one.  Zero rather than a
             ;; refusal, which is what Windows Terminal does with the same
             ;; report, and it is only reachable at all when a child opens with
             ;; a bare `9;4;1' -- having said it is making progress before it
             ;; has made any.
             ('set (or carried 0))
             (_ carried))))))))

(defun cooked--set-progress (state percent)
  "Show STATE and PERCENT as this buffer's progress, or clear it when STATE is nil.

The mode line is asked to repaint here rather than left to notice on its own: a
child that reports 100% and then goes quiet produces no further output, so
nothing else would ever wake redisplay and the last number the user saw would be
whatever happened to be on screen when something else last changed."
  (setq cooked--progress (and state (cons state percent)))
  (force-mode-line-update))

(defun cooked--reset-progress ()
  "Drop any progress indicator, on RIS.

Called from the `reset\=' event rather than from anything in this file, because
RIS is `ESC c\=' and not an OSC at all.  It has to be reachable from Lisp: the
indicator is the one piece of a session's visible state that lives entirely in
Emacs, so a reset that Rust handled by itself would clear the screen and leave
the mode line still claiming a build was 60% through -- and there would be no
second thing for the user to type, `reset\=' being the thing you type when
something is stuck."
  (cooked--set-progress nil nil))

(defvar-local cooked--color-remaps nil
  "Alist of color kind to face remapping cookie, so OSC 110/111 can undo a set.")

(defvar-local cooked--cursor-color nil
  "The cursor color an OSC 12 set asked for, or nil.
Not a face remap like the other two; see `cooked--sync-cursor-color'.")

(defconst cooked--osc-color-sources
  '((10 . foreground) (11 . background) (12 . cursor)
    (17 . highlight-background) (19 . highlight-foreground))
  "Which color each OSC code asks about.

17 and 19 are xterm's selection colours, and the `region' face is what Emacs
selects with, so that is where they are read from.  18 is the Tektronix cursor
and has no entry: a chained query walks past it without an answer, as it walks
past any code nobody here can speak for.")

(defconst cooked--osc-settable-colors '(foreground background cursor)
  "The kinds in `cooked--osc-color-sources' that a set may change.

The selection colours are answered and never set.  A child repainting its own
background is a request about its own terminal; a child repainting `region'
would be restyling a face every other buffer shares, for a selection the child
cannot even see, and a buffer-local remap of it would still be a second opinion
about what the user chose.")

(defun cooked--default-color (kind)
  "The color this buffer renders for KIND, a kind in `cooked--osc-color-sources'.

Falls back through the frame and then to plain black or white.  On a tty frame
the face returns `unspecified-fg'/`unspecified-bg', which `color-values' cannot
read; answering approximately still beats not answering, which is the bug this
exists to fix."
  (let ((color (pcase kind
                 ('foreground (or (face-foreground 'default nil t)
                                  (frame-parameter nil 'foreground-color)))
                 ('background (or (face-background 'default nil t)
                                  (frame-parameter nil 'background-color)))
                 ;; The frame's own colour, not what it wears for some other
                 ;; buffer that set one.
                 ('cursor (or cooked--cursor-color
                              (cooked--frame-cursor-color (selected-frame))
                              (face-foreground 'default nil t)))
                 ;; Inheriting through `default', because a theme whose `region'
                 ;; sets only a background draws selected text in the default
                 ;; foreground, and that is the true answer to 19.
                 ('highlight-background (face-background 'region nil t))
                 ('highlight-foreground (face-foreground 'region nil t)))))
    (if (and color (color-values color))
        color
      (let ((dark (eq (frame-parameter nil 'background-mode) 'dark)))
        (if (memq kind '(background highlight-background))
            (if dark "black" "white")
          (if dark "white" "black"))))))

(defun cooked--color-scheme ()
  "Whether this buffer renders dark or light, as `dark\=' or `light\='.

Derived from `cooked--default-color\=', which is what OSC 11 answers from, rather
than from `frame-background-mode\=' — and that is the whole point.  A child told
the scheme changed reacts by querying OSC 11 for the actual background, so two
readings of one value cannot be allowed to contradict each other.

`color-dark-p\=' is what `frame--current-background-mode\=' uses to derive
`frame-background-mode\=' in the first place, gamma correction and empirical
cutoff included, so with nothing remapped this agrees with Emacs\=' own answer
rather than approximating it."
  (if (color-dark-p (mapcar (lambda (v) (/ v 65535.0))
                            (color-values (cooked--default-color 'background))))
      'dark
    'light))

(defun cooked--sync-color-scheme ()
  "Tell this buffer\\='s child which way the theme now points.

On `cooked-theme-change-hook\\=', which `cooked--flush-face-cache\\=' runs once per
session with that buffer current — so this needs no machinery of its own.  The
core holds the answer so it can answer `CSI ? 996 n\\=' itself, and hands back the
bytes a mode 2031 subscriber is owed, which are nil far more often than not.

Sent rather than left to ride the drain because a theme change produces no child
output, so nothing would ever wake one; see `cooked--set-color-scheme\\='."
  (when-let* ((session (cooked--live-session))
              (bytes (cooked--set-color-scheme session (cooked--color-scheme))))
    (cooked--send-if-live bytes)))

(add-hook 'cooked-theme-change-hook #'cooked--sync-color-scheme)

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
  "Answer or apply the OSC 10, 11, 12, 17 or 19 request PARTS.

A `?' is a query and is answered from the buffer's own faces.  Anything else is
a set, which needs `cooked-allow-color-set' and is only ever honoured for the
kinds in `cooked--osc-settable-colors'.  Several may be chained — `ESC ] 10 ; ?
; ? ST' asks for the foreground and then the background — so each part advances
the code."
  (let ((code cooked--osc-code))
    (dolist (part parts)
      (when-let* ((kind (alist-get code cooked--osc-color-sources)))
        (if (equal part "?")
            (when-let* ((payload (cooked--color-to-osc (cooked--default-color kind))))
              (cooked--reply-osc cooked--session code payload
                                 cooked--osc-bell-terminated))
          (when (and cooked-allow-color-set
                     (memq kind cooked--osc-settable-colors))
            (cooked--set-default-color kind part))))
      (setq code (1+ code)))))

(defun cooked--set-default-color (kind spec)
  "Remap this buffer's default KIND to SPEC, if it parses.
Buffer-local rather than frame-wide: a child gets to repaint its own terminal,
not every window in the Emacs running it.  The cursor is the exception, because
Emacs has no buffer-local cursor colour to give it; see `cooked--cursor-color'.

A `background\=' set also remaps `fringe\=', not just `default\=': the fringe is
its own face, styled by the Emacs theme rather than by anything a shell can
see, so without this a child that paints its own background leaves the fringe
sitting in whatever shade the Emacs theme picked -- visibly split down the
window edge from the terminal background right next to it."
  (when-let* ((color (cooked--parse-osc-color spec)))
    (if (eq kind 'cursor)
        (cooked--set-cursor-color color)
      (cooked--reset-default-color kind)
      (cooked--remap-default-color kind color))))

(defun cooked--remap-default-color (kind color)
  "Remap this buffer's `default' KIND, `foreground' or `background', to COLOR."
  (push (cons kind (pcase kind
                     ('foreground (list (face-remap-add-relative 'default :foreground color)))
                     ('background (list (face-remap-add-relative 'default :background color)
                                        (face-remap-add-relative 'fringe :background color)))))
        cooked--color-remaps)
  ;; Every cell face resolves against `default', so the memoized ones are stale the
  ;; moment the remap lands.
  (cooked--flush-face-cache)
  ;; A reversed screen swapped the colours as they were, and the newest remap
  ;; outranks it; see `cooked--apply-reverse-screen'.
  (cooked--apply-reverse-screen))

(defun cooked--reset-default-color (kind)
  "Drop any OSC 10/11/12 remap of KIND, restoring the theme's own color."
  (if (eq kind 'cursor)
      (cooked--set-cursor-color nil)
    (when-let* ((cookies (alist-get kind cooked--color-remaps)))
      (mapc #'face-remap-remove-relative cookies)
      (setq cooked--color-remaps (assq-delete-all kind cooked--color-remaps))
      (cooked--flush-face-cache)
      (cooked--apply-reverse-screen))))

(defun cooked--osc-color-reset (_parts)
  "Undo an OSC 10/11/12 set, from OSC 110, 111 or 112.

Three codes and no fourth: OSC 104, \"reset the palette\", is deliberately not
handled and `oc\=' has been dropped from terminfo/cooked.ti to say so.  There is
no palette here to reset -- OSC 4 answers queries but declines every set, for
the reason that entry gives, that Emacs owns colour and a per-buffer 256-entry
palette is the wrong seam -- so the only colours a child can have changed are
the three defaults above, and each of those already has its own undo."
  (when-let* ((kind (alist-get (- cooked--osc-code 100) cooked--osc-color-sources)))
    (cooked--reset-default-color kind)))

;;;; OSC 12 — the cursor, worn by the frame
;;
;; The other two defaults are face remaps, and OSC 12 used to be one too: a
;; buffer-local remap of the `cursor' face.  It never reached the screen.  Emacs
;; draws every cursor in its frame's `cursor-color' parameter, which the `cursor'
;; face feeds only through the frame-wide face, so a remap changed what the
;; buffer's faces said and not a single pixel.  That was checked in a headless
;; pgtk frame, a red OSC 12 over a blue frame cursor, and no red pixel appeared
;; in either the box or the hollow cursor.
;;
;; So the frame wears the colour while a cooked buffer that set one is in its
;; selected window, and takes its own back the moment that stops.  Neither vterm
;; nor eat does even that much; both ignore OSC 12 sets.  Two things follow from
;; there being one colour per frame.  While
;; the cooked window is selected, the hollow cursors other windows on the frame
;; draw are in its colour too; those are the cursors of windows you are not
;; typing in, and the alternative of declining OSC 12 outright costs the cursor
;; you are.  And the colour given back is whatever the frame had when the child's
;; went on, unless something else -- a theme, `set-cursor-color' -- has changed
;; it since, in which case that newer colour is the one given back.

(defun cooked--set-cursor-color (color)
  "Make COLOR, or nil for none, this buffer\='s OSC 12 cursor color.
Applied at once to every frame whose selected window shows this buffer."
  (setq cooked--cursor-color color)
  (cooked--sync-cursor-color-everywhere))

(defun cooked--frame-cursor-color (frame)
  "FRAME\='s own cursor color, beneath any OSC 12 color it is wearing.

The frame parameter `cooked--cursor-color\=' records what is worn, as a cons of
the color put on and the color it replaced.  When the frame\='s `cursor-color\='
no longer matches the first, something other than `cooked--sync-cursor-color\='
changed it, and that newer color is the frame\='s own."
  (let ((current (frame-parameter frame 'cursor-color))
        (worn (frame-parameter frame 'cooked--cursor-color)))
    (if (and worn (equal (car worn) current)) (cdr worn) current)))

(defun cooked--sync-cursor-color (frame)
  "Put on or take off FRAME\='s OSC 12 cursor color, for its selected window.
What is taken off is replaced by `cooked--frame-cursor-color\='.

From `window-selection-change-functions\=' and
`window-buffer-change-functions\=', whose global values run once per frame."
  (when (frame-live-p frame)
    (let* ((color (buffer-local-value 'cooked--cursor-color
                                      (window-buffer (frame-selected-window frame))))
           (current (frame-parameter frame 'cursor-color))
           (own (cooked--frame-cursor-color frame)))
      (cond (color
             (unless (equal color current)
               (set-frame-parameter frame 'cursor-color color))
             (set-frame-parameter frame 'cooked--cursor-color
                                  (cons (frame-parameter frame 'cursor-color) own)))
            ((frame-parameter frame 'cooked--cursor-color)
             (set-frame-parameter frame 'cooked--cursor-color nil)
             (unless (equal own current)
               (set-frame-parameter frame 'cursor-color own)))))))

(defun cooked--sync-cursor-color-everywhere (&rest _)
  "Run `cooked--sync-cursor-color\=' on every frame.
On `cooked-theme-change-hook\=' too, since a theme that sets the `cursor\=' face
repaints the frame\='s cursor without any window changing."
  (mapc #'cooked--sync-cursor-color (frame-list)))

(add-hook 'cooked-theme-change-hook #'cooked--sync-cursor-color-everywhere)

;;;; OSC 4 — the palette, answered and never changed
;;
;; Setting an entry stays declined, for the reason `ccc' and `initc' give in
;; terminfo/cooked.ti: Emacs owns colour, and a per-buffer 256-entry palette is the
;; wrong seam.  But a query has a true answer regardless, because every index already
;; resolves to one Emacs colour in `cooked--color' -- the sixteen through the
;; `ansi-color-' faces, the rest through the xterm cube and ramp.  Theme-picking
;; tools read palette entries before they draw, and each one left unanswered costs
;; them a timeout.
;;
;; No knob: an answer reveals the theme and nothing else, which OSC 10 and 11
;; already do.

(defun cooked--osc-palette (parts)
  "Answer the OSC 4 queries in PARTS, and ignore its sets.

PARTS alternate index and specification, so `ESC ] 4 ; 1 ; ? ; 196 ; ? ST'
asks for two entries and gets two replies, each of the form `4;N;rgb:...'.  A
specification other than `?' is a set, which gets no reply and changes
nothing -- what xterm does with allowColorOps off -- and a malformed or
out-of-range index is skipped without disturbing the pairs after it.

The colour comes from `cooked--color', the function that paints cells, so the
answer is whatever a cell in that colour is actually drawn in rather than a
second table that could disagree with it."
  (while parts
    (let ((index (pop parts))
          (spec (pop parts)))
      (when (and (equal spec "?")
                 (string-match-p "\\`[0-9]\\{1,3\\}\\'" index))
        (let ((n (string-to-number index)))
          (when-let* (((<= n 255))
                      ;; A tty frame can leave an `ansi-color-' face reading as
                      ;; `unspecified-fg', which has no value to report; the
                      ;; fallback palette is then the nearest true answer.
                      (payload (or (cooked--color-to-osc (cooked--color n))
                                   (and (< n 16)
                                        (cooked--color-to-osc
                                         (aref cooked-color-names n))))))
            (cooked--reply-osc cooked--session 4 (format "%d;%s" n payload)
                               cooked--osc-bell-terminated)))))))

;;;; DECSCNM — the whole screen in reverse video
;;
;; Mode 5 arrives as a level on every drain, `:reverse', and is drawn here rather
;; than in the cells: the emulator never touches a row for it, because the cells
;; that change are exactly the ones in the default colours, and those are the
;; buffer's `default' face.  Swapping that face's two colours reverses them all at
;; once and leaves a cell with a colour of its own alone, which is what xterm does.
;;
;; This is screen state the child owns, like SGR 7 across the whole screen, and so
;; it has no knob.  `flash' in our terminfo is a set, a 100ms pause and a reset,
;; which is how vim's `visualbell' reaches it.
;;
;; The cursor is deliberately left alone, although xterm swaps it too.  The obvious
;; worry is a cursor in the theme's foreground vanishing into the reversed
;; background, and Emacs already prevents that: a cursor drawn in its face's own
;; background colour is drawn in the foreground instead.  That was checked in a
;; headless pgtk frame -- black text on white, a black cursor, `default' swapped --
;; and box, bar, hbar and end-of-line cursors all came out white.  Nor could the
;; swap be done here if it were wanted: the cursor's colour is the frame's
;; `cursor-color' parameter, and the same frame showed a buffer-local remap of the
;; `cursor' face having no effect at all.  Setting the frame parameter would repaint
;; the cursor in every other buffer on the frame.

(defvar-local cooked--reverse-screen nil
  "Whether the child has asked for the screen in reverse video, DEC mode 5.")

(defvar-local cooked--reverse-screen-remaps nil
  "The face remapping cookies drawing `cooked--reverse-screen', or nil.")

(defun cooked--screen-color (kind)
  "The color this buffer draws for KIND, `foreground' or `background'.

Unlike `cooked--default-color', an OSC 10 or 11 set counts: that remap is the
color the child sees, so it is the one reverse video swaps.  Read back from the
cookie `face-remap-add-relative' returned, whose tail is the attribute plist it
was given."
  (or (when-let* ((cookie (car (alist-get kind cooked--color-remaps))))
        (plist-get (cdr cookie) (if (eq kind 'foreground) :foreground :background)))
      (cooked--default-color kind)))

(defun cooked--apply-reverse-screen ()
  "Redraw the remap for `cooked--reverse-screen' against the colors of the moment.

Removed and added again rather than left in place, for two reasons.  The colors
it swaps are resolved when it is added, so a theme change or an OSC 10/11 set
leaves it swapping the old ones.  And `face-remap-add-relative' gives the newest
remap priority, so an OSC 11 set made while the screen is reversed would
otherwise paint over the swap.  `fringe' follows the background for the reason
`cooked--set-default-color' gives.

One remap per attribute, and not one carrying both.  `face-remap-order' ranks a
spec with fewer attributes above one with more, whatever order they were added
in, so a two-attribute swap would lose to a one-attribute OSC 11 set however
recently it was made.  Specs of one attribute each tie, and a tie goes to the
newest."
  (mapc #'face-remap-remove-relative cooked--reverse-screen-remaps)
  (setq cooked--reverse-screen-remaps
        (when cooked--reverse-screen
          (let ((foreground (cooked--screen-color 'foreground))
                (background (cooked--screen-color 'background)))
            (list (face-remap-add-relative 'default :foreground background)
                  (face-remap-add-relative 'default :background foreground)
                  (face-remap-add-relative 'fringe :background foreground))))))

(defun cooked--set-reverse-screen (on)
  "Adopt DECSCNM state ON from the drain, remapping only when it changes."
  (let ((on (and on t)))
    (unless (eq on cooked--reverse-screen)
      (setq cooked--reverse-screen on)
      (cooked--apply-reverse-screen))))

(defun cooked--refresh-reverse-screen ()
  "Swap the new theme's colors, if the screen is reversed.
On `cooked-theme-change-hook'."
  (when cooked--reverse-screen
    (cooked--apply-reverse-screen)))

(add-hook 'cooked-theme-change-hook #'cooked--refresh-reverse-screen)

;;;; OSC 51 — the child asking Emacs to do something
;;
;; Only the dispatch lives here; two of the three arms are somebody else's.  `A'
;; annotates the prompt and is inert data, so it is always on.  `E' is a command
;; channel driven by bytes on the terminal — anything that can write there can pull
;; the trigger: `cat' of a hostile file, output from a compromised host over ssh, a
;; build log quoting text somebody else chose — so it is off until you load
;; `cooked-osc-eval' and say you want it.
;;
;; What an `E' payload *means* is deliberately not known here.  It is
;; `E<version>;<verb>[;<arg>]' and the verbs are a closed set, but both facts belong
;; to the layer that implements them: this arm's whole job is to notice the letter,
;; refuse it when nobody is listening, and hand the rest over.  A core that parsed
;; the verbs would have to be taught each new one.  `C' carries completion candidates, which
;; are harmless in the same way `A' is, but answering them means asking the shell —
;; a blocking round trip here and a `compadd' shadow there — so it too waits to be
;; loaded, as `cooked-shell-completion'.
;;
;; Both arms dispatch through a nil-valued function variable rather than calling a
;; named function, and that is the point rather than a style: with the layer
;; unloaded there is no function to name, so "not required" and "off" cannot come
;; apart.

(defvar cooked-osc-eval-functions nil
  "Abnormal hook handling the OSC 51;E command channel, run with the payload.

The payload is everything after the `E\=', so `E1;F;/tmp/x\=' arrives as
\"1;F;/tmp/x\": a version, a verb, and at most one argument.  Parsing it is the
layer\='s business rather than this file\='s.

Empty means the channel is closed and requests are ignored -- and that
emptiness is load-bearing rather than incidental: it is what
`cooked--osc-emacs\=' reads to tell \"nobody is listening\" from \"somebody
refused\", and so what raises the once-per-buffer notice pointing at
`cooked-osc-eval\='.  Requiring that file is how you opt in, and the point of
the split is that opting in is something you do on purpose rather than inherit.

Deliberately a `defvar\=' and not a `defcustom\=' with `:type \='hook\=', unlike
every other seam here: this is the one place terminal output becomes action, and
a customize interface would be a way to open the channel without ever loading
the file whose whole job is to make that a decision.")

(defvar cooked-osc-completion-functions nil
  "Abnormal hook handling an OSC 51;C *reply*, run with the payload.

Empty means the completion layer is not loaded, and a reply arriving anyway is
dropped unread.  Harmless: nothing asked for it, because asking is that layer\='s
job.

The announcement is deliberately not routed through here.  It is handled below,
unconditionally, because `cooked--policy\=' reads it as a license to own the
input line and that reading has to hold in a session that never loads the
completion layer at all.  `cooked-shell-completion\=' sets this; see
`cooked-shell-completion-functions\=' for the other half of the same switch.")

(defun cooked--osc-announce (payload)
  "Record the prompt\='s OSC 51;CH announcement from PAYLOAD, minus its leading H.

Inert by construction -- a version number and a nonce -- which is what makes it
safe to believe with no opt-in in front of it.

Version first, so a newer shell snippet paired with an older Emacs declines
rather than misreading the protocol.  An unrecognised shape clears the nonce
instead of leaving the last one standing: a garbled announcement is the shell
failing to make a claim, and the safe reading of no claim is no license."
  (pcase (split-string payload ";")
    (`("" "2" ,nonce . ,rest)
     (setq cooked--completion-nonce nonce
           ;; Field 3 is the reply capability, absent in snippets that predate
           ;; it -- which could only announce when they could also reply, so
           ;; their silence means capable.
           cooked--completion-reply-capable (not (equal (car rest) "0"))))
    (_ (setq cooked--completion-nonce nil
             cooked--completion-reply-capable nil))))

(defvar-local cooked--eval-refused nil
  "Whether this buffer has already reported an ignored OSC 51;E request.")

(defun cooked--osc-emacs (parts)
  "Handle the OSC 51 payload PARTS.

E asks Emacs to run something; C is the completion channel."
  (let ((payload (string-join parts ";")))
    (unless (string-empty-p payload)
      (pcase (aref payload 0)
        (?E (cond
             (cooked-osc-eval-functions
              ;; Deferred, for the reason `cooked--defer' states: this runs from
              ;; inside a drain, which keeps working with the buffer and its
              ;; locals after we return.  The commands on the other side are
              ;; ordinary interactive ones -- they manage windows, run
              ;; `find-file-hook', and can prompt (`large-file-warning-threshold',
              ;; a `magit-status' repo prompt), and a `y-or-n-p' from a process
              ;; filter recurses the command loop through a half-applied redraw.
              ;; Nothing waits for a reply -- OSC 51;E is fire-and-forget -- so
              ;; the only thing deferral costs is a trip round the event loop,
              ;; and same-time timers keep the order the requests arrived in.
              ;;
              ;; The `C' arm below stays synchronous on purpose: it is a `setq'
              ;; of inert data that later parts of this same drain read.
              (let ((request (substring payload 1)))
                (cooked--defer
                 (lambda () (cooked--run-seam 'cooked-osc-eval-functions request)))))
             ;; Once per buffer: silence looks like a bug to someone porting their
             ;; vterm configuration, but a stream can send these as fast as it likes.
             ((not cooked--eval-refused)
              (setq cooked--eval-refused t)
              (message "cooked: ignoring an OSC 51 command; (require 'cooked-osc-eval) to enable"))))
        (?C (let ((rest (substring payload 1)))
              (if (and (not (string-empty-p rest)) (eq (aref rest 0) ?H))
                  (cooked--osc-announce (substring rest 1))
                (when cooked-osc-completion-functions
                  (cooked--run-seam 'cooked-osc-completion-functions rest)))))
        (_ nil)))))

;;;; OSC 52 — clipboard
;;
;; `ESC ] 52 ; TARGETS ; DATA ST'.  TARGETS is any run of xterm's selection
;; letters -- `c' the clipboard, `p' PRIMARY, `q' SECONDARY, `s' the select
;; target, `0' to `7' the cut buffers -- and empty means `s0'.  DATA is base64
;; to write, or `?' to ask for the contents back.
;;
;; A query is answered *always*, and that is the part that was missing: a program
;; that asks blocks on the answer -- neovim's OSC 52 paste provider prints
;; "Waiting for OSC 52 response" and sits there -- so a refusal has to be spoken
;; as an empty payload rather than left as silence.  What goes in the answer is
;; for `cooked-clipboard-read' to decide; the reply path is the same under every
;; setting, and the same one `cooked--osc-color' uses.

(defcustom cooked-clipboard-write t
  "Whether the child may write to the shared clipboard via OSC 52.

This covers the selections Emacs shares with everything else: the kill ring
for the `c\=' and `s\=' targets, PRIMARY for `p\=' and SECONDARY for `q\='.  The
eight cut buffers `0\=' to `7\=' are not among them -- they are private to the
buffer, see `cooked-clipboard-read\=' -- and are written regardless.

Reading is a separate question, answered by `cooked-clipboard-read\='."
  :type 'boolean
  :group 'cooked)

(defcustom cooked-clipboard-read nil
  "What an OSC 52 query gets back from the clipboard.

Every query is answered under every setting, because a program that asks waits
for the reply; these settings only decide whether the reply has anything in it.
Anything that can write to the terminal can ask -- a `cat\=' of a hostile file,
output from a compromised host -- which is why the default hands over nothing.

nil answers every query with an empty payload.

`private\=' answers the cut buffers `0\=' to `7\=' with what OSC 52 last wrote to
them in this buffer, and the shared selections with nothing.  The cut buffers
never reach the kill ring, so a program can round-trip its own text through
them without being able to read anything you copied.  This is eat\='s middle
ground.

`ask\=' prompts, naming the program in the foreground, before answering a shared
selection; the cut buffers are answered as under `private\='.  The prompt waits
until the handler has returned rather than running inside the process filter,
and a query that arrives while one is already open is refused rather than
stacked behind it.

t answers `c\=' and `s\=' from the kill ring, which is the system clipboard
when `interprogram-paste-function\=' is set, `p\=' from PRIMARY and `q\=' from
SECONDARY, with no prompt."
  :type '(choice (const :tag "Answer with nothing" nil)
                 (const :tag "Only the private cut buffers" private)
                 (const :tag "Ask each time" ask)
                 (const :tag "Answer from the clipboard" t))
  :group 'cooked)

(defcustom cooked-clipboard-max-size 100000
  "Largest OSC 52 payload, in base64 characters, in either direction.
Anything writing to the terminal can push to the clipboard, so this bounds how
much of the kill ring a runaway or hostile stream can take over.  It bounds
replies to `cooked-clipboard-read\=' too: a selection that would encode to more
is answered with an empty payload and a message, so the child still hears back
and is not handed megabytes it would have to swallow before its next read."
  :type 'natnum
  :group 'cooked)

(defvar-local cooked--cut-buffers nil
  "The eight OSC 52 cut buffers, as a vector of byte strings, or nil if unused.

Filled by writes to targets `0\=' to `7\=' and read back by queries when
`cooked-clipboard-read\=' is `private\=', `ask\=' or t.  Buffer-local, and never
copied to the kill ring: that is what makes answering from them leak nothing
the child did not put there itself.  The bytes are kept as decoded rather than
as the base64 that arrived, so a read re-encodes them canonically and a
malformed write cannot come back out verbatim.")

(defvar-local cooked--clipboard-prompting nil
  "Whether an OSC 52 prompt under `ask\=' is open for this buffer.")

(defun cooked--osc-52-targets (spec)
  "The selection targets named by SPEC, an OSC 52 first field, as characters.

Unknown letters are dropped, and a SPEC that names nothing known means `s0\=',
which is what xterm does with an empty one."
  (or (seq-filter (lambda (c) (string-search (string c) "cpqs01234567"))
                  (delete-dups (string-to-list spec)))
      (list ?s ?0)))

(defun cooked--osc-52-cut-buffer (target)
  "Index of the cut buffer TARGET names, or nil if it names a shared selection."
  (and (<= ?0 target ?7) (- target ?0)))

(defun cooked--osc-52-shared-contents (target)
  "The text of the shared selection TARGET, or nil if there is none."
  (ignore-errors
    (pcase target
      (?p (gui-get-selection 'PRIMARY))
      (?q (gui-get-selection 'SECONDARY))
      (_ (current-kill 0 t)))))

(defun cooked--osc-52-reply (target payload)
  "Answer an OSC 52 query for TARGET with PAYLOAD, base64 or the empty string.

The reply names TARGET, one letter from the query\='s own field, because a
client that asked about `p\=' matches its answer on that letter."
  (when-let* ((session (cooked--live-session)))
    (cooked--reply-osc session 52 (concat (string target) ";" payload)
                       cooked--osc-bell-terminated)))

(defun cooked--osc-52-encode (text)
  "TEXT as the base64 an OSC 52 reply carries, or the empty string for nil.

A payload longer than `cooked-clipboard-max-size\=' is replaced by the empty
string too, with a message.  The bound is measured on the base64, as it is for
writes, so one number caps both directions.  Replying with nothing rather than
not replying is the point: the child is still waiting, and a truncated payload
would decode to text the user never copied."
  (if (stringp text)
      (let ((payload (base64-encode-string
                      (if (multibyte-string-p text)
                          (encode-coding-string (substring-no-properties text) 'utf-8)
                        text)
                      t)))
        (if (<= (length payload) cooked-clipboard-max-size)
            payload
          (message "cooked: answered a clipboard read with nothing, as its %d characters exceed `cooked-clipboard-max-size'"
                   (length payload))
          ""))
    ""))

(defun cooked--osc-52-query (targets)
  "Answer the OSC 52 query for TARGETS, exactly once.

xterm answers with the first selection named, and so does this.  Under `ask\='
the reply leaves this function in a deferred prompt, carrying the terminator it
was asked with, since `cooked--osc-bell-terminated\=' is unbound by then."
  (let* ((target (car targets))
         (index (cooked--osc-52-cut-buffer target)))
    (cond
     ((null cooked-clipboard-read)
      (cooked--osc-52-reply target ""))
     (index
      (cooked--osc-52-reply
       target (cooked--osc-52-encode (and cooked--cut-buffers
                                          (aref cooked--cut-buffers index)))))
     ((eq cooked-clipboard-read 'private)
      (cooked--osc-52-reply target ""))
     ((eq cooked-clipboard-read 'ask)
      (if cooked--clipboard-prompting
          (cooked--osc-52-reply target "")
        (setq cooked--clipboard-prompting t)
        (let ((bell cooked--osc-bell-terminated))
          (cooked--defer
           (lambda ()
             (unwind-protect
                 (let ((cooked--osc-bell-terminated bell))
                   (cooked--osc-52-reply
                    target
                    (if (condition-case nil
                            (y-or-n-p
                             (format "Let %s read the %s? "
                                     (or (cooked--foreground-program) "the child")
                                     (pcase target
                                       (?p "primary selection")
                                       (?q "secondary selection")
                                       (_ "clipboard"))))
                          (quit nil))
                        (cooked--osc-52-encode
                         (cooked--osc-52-shared-contents target))
                      "")))
               (setq cooked--clipboard-prompting nil)))))))
     (t
      (cooked--osc-52-reply
       target (cooked--osc-52-encode (cooked--osc-52-shared-contents target)))))))

(defun cooked--osc-52-write (targets data)
  "Put the base64 DATA into each of TARGETS.

A cut buffer is written under every setting, since it is this buffer\='s own and
putting it on the kill ring would be wrong under any of them.  The shared
selections need `cooked-clipboard-write\=', and the kill ring is written once
however many of `c\=' and `s\=' were named."
  (if (> (length data) cooked-clipboard-max-size)
      ;; Refuse out loud: a silent drop looks like the copy simply failed.
      (message "cooked: refused a %d-character clipboard write (see `cooked-clipboard-max-size')"
               (length data))
    (when-let* ((bytes (cooked--decode-base64 data)))
      (let ((text (decode-coding-string bytes 'utf-8))
            (killed nil))
        (dolist (target targets)
          (if-let* ((index (cooked--osc-52-cut-buffer target)))
              (aset (or cooked--cut-buffers
                        (setq cooked--cut-buffers (make-vector 8 nil)))
                    index bytes)
            (when cooked-clipboard-write
              (pcase target
                (?p (gui-set-selection 'PRIMARY text))
                (?q (gui-set-selection 'SECONDARY text))
                (_ (unless killed
                     (setq killed t)
                     (kill-new text)
                     (message "cooked: copied %d characters" (length text))))))))))))

(defun cooked--osc-clipboard (parts)
  "Write or answer the child\='s OSC 52 request, from PARTS."
  (let ((targets (cooked--osc-52-targets (if (cdr parts) (car parts) "")))
        (data (car (last parts))))
    (cond
     ((null data) nil)
     ((equal data "?") (cooked--osc-52-query targets))
     (t (cooked--osc-52-write targets data)))))

;;;; OSC 7 — the working directory
;;
;; The one handler that has to answer a question about somebody else's machine.
;; A shell you have ssh'd out to goes on reporting its directory faithfully, and
;; the names it sends are real -- on the other host.  Resolving them here names a
;; different file, or, worse and far more often, a local file of the same name
;; that does exist, in a checkout kept deliberately in step with the remote one.
;;
;; So there are two branches below and they trust different things.  The local
;; branch trusts nothing about the payload and checks the directory is there.
;; The remote branch cannot check anything without paying for a connection, so it
;; instead refuses to let the payload decide *where* the connection would go.

(defcustom cooked-remote-directory 'tramp
  "What an OSC 7 report from another host does to `default-directory\='.

`tramp\=' rewrites the reported path into a TRAMP name for the host the child
says it is on, so \\[find-file] at a shell you ssh\='d out to opens the file you
meant -- in this Emacs, with your own configuration and your own language server
-- instead of a same-named local file or nothing at all.

nil leaves `default-directory\=' at the last place cooked could vouch for, which
is what it did before this existed and is still the right answer if you would
rather a foreign prompt resolve nothing.

Neither setting lets the byte stream choose the host or the method: see
`cooked--remote-directory\=' for what is and is not taken from the payload."
  :type '(choice (const :tag "Rewrite as a TRAMP path" tramp)
                 (const :tag "Leave `default-directory' alone" nil))
  :group 'cooked)

(defcustom cooked-tramp-default-method nil
  "TRAMP method for a name built from an OSC 7 report, or nil for TRAMP\='s own.

Only consulted when there is no remote connection to inherit one from -- an
ordinary outbound `ssh\=' from a local buffer.  A `cd\=' reported by a shell we
are already talking to over TRAMP keeps that connection\='s method, and its hops.

nil means `tramp-default-method\=', which is \"scp\" in a stock Emacs.  \"ssh\"
is the usual reason to set this: it multiplexes over one connection where scp
opens a new one per file."
  :type '(choice (const :tag "`tramp-default-method'" nil) string)
  :group 'cooked)

(defconst cooked--host-name-regexp
  (rx bos (any alnum) (opt (* (any alnum ?. ?- ?_)) (any alnum)) eos)
  "A host name cooked is willing to write into a TRAMP file name.

Letters, digits, dots, hyphens and underscores, and it may not start or end with
punctuation.  Not an attempt to validate a host name -- resolution is TRAMP\='s
problem and a name that does not resolve merely fails.  It is there to keep
TRAMP\='s *own* syntax out of a position where it would be read as syntax; see
`cooked--remote-directory\='.  An IPv6 literal does not match and is declined,
which costs a rare case a rewrite it would otherwise have got.")

(defun cooked--remote-directory (path)
  "PATH on the host the child last reported, as a TRAMP directory name, or nil.

*The host comes from `cooked--host\=' and the method never comes from the
payload.*  That is the hostile-`cat\=' defence carried across rather than
dropped.  OSC 7 is always on -- no `require\=' in front of it, unlike the
command channel -- so any program that can write to the terminal can send one,
and a name assembled out of what it sent would be a way to make Emacs dial a
machine
of the sender\='s choosing.  `cooked--local-name\=' is what refuses that on the
local branch, and cannot be what refuses it here, because here the answer is a
remote name by construction.

`cooked--host\=' is not payload-free either -- it is the authority half of the
same URL -- and the point is that it does not need to be.  It is the host the
child is *claiming to be*, which cooked has already told the rest of the buffer
to distrust: `cooked--foreign-host-p\=' is what makes the mode line say so,
makes completion decline, and makes `cooked-file-link\=' resolve nothing.  A
hostile
stream therefore buys exactly one thing it did not have before, a TRAMP name
pointing at the host it already announced, and pays for it by announcing it.

What it must not buy is a *method*, and that is the whole of what the two guards
below are for.  Both halves of the URL are attacker-chosen strings, and TRAMP
file-name syntax is punctuation:

- The authority is matched as `[^/]*\=' and percent-decoded, so `file://
  a%7Csudo%3A/etc\=' would arrive as the host `a|sudo:\=' and, formatted
  straight into `/ssh:%s:\=', produce `/ssh:a|sudo::/etc\=' -- a second hop to
  root that nothing in the path half was needed for.  The regexp
  `cooked--host-name-regexp\=' is what stops that, and declining outright is the
  answer rather than quoting,
  because a host containing TRAMP punctuation is not a host anyone has.
- The path is appended after a *complete* `/method:host:\=' prefix, which is the
  position where TRAMP stops parsing and starts taking bytes: a payload path of
  `/ssh:evil:/tmp\=' becomes the localname `/ssh:evil:/tmp\=' on our host, a
  file that merely does not exist, and not a hop to `evil\='.

An existing remote prefix is reused rather than rebuilt, and that is the whole
of what keeps a multi-hop connection alive.  A buffer already at
`/ssh:jump|ssh:host:\=' has to stay two hops across a `cd\=': formatting a fresh
`/ssh:host:\=' would flatten it to one and dial a machine that is very likely
not reachable directly, which is the failure that makes a bastion setup useless
rather than merely slower.  Reusing it also keeps the user and the method the
user actually connected with.

The prefix is taken as `default-directory\=' *minus its localname*, and not as
`file-remote-p\=' of it, which is the obvious spelling and is wrong: TRAMP
reassembles that return value from the dissected name and leaves the `hop\='
slot out, so `/ssh:jump|ssh:host:/tmp/\=' comes back as plain `/ssh:host:\='.
The
flattening is silent and the result is a perfectly well-formed name for a
machine the bastion exists because you cannot reach.  Subtracting the localname
keeps whatever was actually there, hops and all, without cooked having to know
how TRAMP spells any of it.

Reused only while that prefix still names the host the child does, though.  An
`ssh\=' *from* the far shell moves `cooked--host\=' on and leaves the prefix
where it was, and inheriting it then would hang the new host\='s paths off the
old host\='s connection -- the same class of wrong-file error this whole handler
exists to avoid, arrived at from the other side.  `cooked--same-host-p\=' is the
comparison, shared with `cooked--foreign-host-p\=' so that a short name from zsh
and a fully qualified one in the prefix agree about being one machine."
  (when-let* ((prefix
               (or (and (cooked--same-host-p (file-remote-p default-directory 'host)
                                             cooked--host)
                        (when-let* ((local (file-remote-p default-directory 'localname)))
                          (substring default-directory
                                     0 (- (length default-directory) (length local)))))
                   (and (string-match-p cooked--host-name-regexp cooked--host)
                        ;; Only here, and only on this branch: reading
                        ;; `tramp-default-method' is the one thing that needs the
                        ;; library, and an inherited prefix already carries a method.
                        (progn
                          (require 'tramp)
                          (format "/%s:%s:"
                                  (or cooked-tramp-default-method tramp-default-method)
                                  cooked--host))))))
    ;; The trailing slash is appended as a string operation, and
    ;; `file-name-as-directory' is not used on either half, because both would
    ;; dispatch to TRAMP.  On the finished name that is the same reassembly
    ;; described above and it would undo the prefix reuse two lines up -- the hop
    ;; survives being carried across and then vanishes on the way out.  On PATH
    ;; alone it hands a handler a string the payload wrote, which is the one thing
    ;; this function exists not to do.  A slash needs neither.
    (concat prefix path (unless (string-suffix-p "/" path) "/"))))

(defun cooked--set-directory (url)
  "Track the child's directory from an OSC 7 URL.

On this machine, the name is refused if it is remote, and refused *before*
`file-directory-p\=' rather than after.  That order is the whole point: a `cat\='
of a hostile file can put a TRAMP name in the path half, and asking whether that
directory exists is itself the connection.  See `cooked--local-name\='.

On another machine the path is rewritten into a TRAMP name -- see
`cooked-remote-directory\=' for turning that off, and `cooked--remote-directory\='
for why the payload can choose the path but not the host or the method.  There
is deliberately *no* `file-directory-p\=' on that branch, and it is not an
oversight to be tidied up later: validating would open a synchronous TRAMP
connection on every single `cd\=', which is the difference between a feature that
costs nothing and one that stalls the shell.  The shell\='s report is trusted
instead, on the grounds that it is the one party that actually knows -- and a
wrong `default-directory\=' costs a failed `find-file\=', where a connection per
`cd\=' costs every prompt.

Which branch runs is `cooked--foreign-host-p\=', so the URL\='s authority is kept
rather than skipped: it is not decoration, it is the thing that decides whether
a path means a file here or a file somewhere else.

The path is percent-encoded, because that is what a URL is: a directory called
`100%20cake\=' has to arrive as `100%2520cake\=' or it decodes to a different
directory that does not exist.  Both emitters that reach this parser --
cooked\='s own snippets and a fish 4 doing its own reporting -- encode that way,
so there is one encoding on the wire and one decoding here.

Ends by offering the buffer a rename, foreign host or not: `cooked--host\='
changed either way, and a `cooked-buffer-name\=' with %h or %p in it wants to
know about both kinds of move, not just the ones that touch
`default-directory\='."
  (pcase-let ((`(,host . ,path) (cooked--parse-file-url url)))
    (when path
      (setq cooked--host host)
      (if (cooked--foreign-host-p)
          (when-let* (((eq cooked-remote-directory 'tramp))
                      ;; Already a directory name: see the end of
                      ;; `cooked--remote-directory' for why the slash cannot be
                      ;; put on here with `file-name-as-directory'.
                      (name (cooked--remote-directory path)))
            (setq default-directory name))
        (when-let* ((name (cooked--local-name path))
                    (dir (file-name-as-directory name)))
          (when (file-directory-p dir)
            (setq default-directory dir))))
      (cooked--update-buffer-name))))

(provide 'cooked-osc)
;;; cooked-osc.el ends here
