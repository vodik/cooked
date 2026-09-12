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
    (110 . cooked--osc-color-reset)
    (111 . cooked--osc-color-reset)
    (112 . cooked--osc-color-reset)
    (51 . cooked--osc-emacs)
    (52 . cooked--osc-clipboard)
    (9 . cooked--osc-progress)
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
  (setq cooked--title title)
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
            (last (cons cooked--title cooked--title-stack)
                  cooked--title-stack-limit))
    ;; An underflowing pop is the child's bug, not ours; leave the title alone.
    (when cooked--title-stack
      (cooked--set-title (pop cooked--title-stack)))))

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

;;;; OSC 9;4 — how far along the child says it is
;;
;; ConEmu's progress report, and the one sequence on this axis that everything
;; modern emits: cargo, npm, winget, and every coding agent that has grown a
;; progress bar.  `ESC ] 9 ; 4 ; STATE ; PERCENT ST', where STATE is a single
;; digit and PERCENT is an optional 0-100.
;;
;; OSC 9 with anything else after it is iTerm2's one-shot desktop notification,
;; which cooked does not implement; the `4' test below is what keeps the two
;; apart, and it is the reason this handler is registered for the whole of OSC 9
;; rather than for some sub-code the dispatch does not have.
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
  "Answer or apply the OSC 10, 11 or 12 request PARTS.

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
not every window in the Emacs running it.

A `background\=' set also remaps `fringe\=', not just `default\=': the fringe is
its own face, styled by the Emacs theme rather than by anything a shell can
see, so without this a child that paints its own background leaves the fringe
sitting in whatever shade the Emacs theme picked -- visibly split down the
window edge from the terminal background right next to it."
  (when-let* ((color (cooked--parse-osc-color spec)))
    (cooked--reset-default-color kind)
    (push (cons kind (pcase kind
                       ('foreground (list (face-remap-add-relative 'default :foreground color)))
                       ('background (list (face-remap-add-relative 'default :background color)
                                          (face-remap-add-relative 'fringe :background color)))
                       ('cursor (list (face-remap-add-relative 'cursor :background color)))))
          cooked--color-remaps)
    ;; Every cell face resolves against `default', so the memoized ones are stale the
    ;; moment the remap lands.
    (cooked--flush-face-cache)))

(defun cooked--reset-default-color (kind)
  "Drop any OSC 10/11/12 remap of KIND, restoring the theme's own color."
  (when-let* ((cookies (alist-get kind cooked--color-remaps)))
    (mapc #'face-remap-remove-relative cookies)
    (setq cooked--color-remaps (assq-delete-all kind cooked--color-remaps))
    (cooked--flush-face-cache)))

(defun cooked--osc-color-reset (_parts)
  "Undo an OSC 10/11/12 set, from OSC 110, 111 or 112.

Three codes and no fourth: OSC 104, \"reset the palette\", is deliberately not
handled and `oc\=' has been dropped from terminfo/cooked.ti to say so.  There is
no palette here to reset -- OSC 4 is declined for the reason that entry gives,
that Emacs owns colour and a per-buffer 256-entry palette is the wrong seam --
so the only colours a child can have changed are the three defaults above, and
each of those already has its own undo."
  (when-let* ((kind (alist-get (- cooked--osc-code 100) cooked--osc-color-sources)))
    (cooked--reset-default-color kind)))

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
  "Put the child's OSC 52 selection, from PARTS, on the kill ring."
  (let ((data (car (last parts))))
    (when (and cooked-clipboard-write data (not (equal data "?")))
      (if (> (length data) cooked-clipboard-max-size)
          ;; Refuse out loud: a silent drop looks like the copy simply failed.
          (message "cooked: refused a %d-character clipboard write (see `cooked-clipboard-max-size')"
                   (length data))
        (when-let* ((text (ignore-errors (base64-decode-string data t))))
          (kill-new (decode-coding-string text 'utf-8))
          (message "cooked: copied %d characters" (length text)))))))

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
  (when (string-match "\\`file://\\([^/]*\\)\\(/.*\\)\\'" url)
    (setq cooked--host (url-unhex-string (match-string 1 url)))
    (let ((path (url-unhex-string (match-string 2 url))))
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
            (setq default-directory dir)))))
    (cooked--update-buffer-name)))

(provide 'cooked-osc)
;;; cooked-osc.el ends here
