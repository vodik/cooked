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
(declare-function cooked--rename-to-title "cooked-mode")
(declare-function cooked--defer "cooked-mode")

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
  "Undo an OSC 10/11/12 set, from OSC 110, 111 or 112."
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

(defun cooked--set-directory (url)
  "Track the child's directory from an OSC 7 URL.

The name is refused if it is remote, and refused *before* `file-directory-p\='
rather than after.  That order is the whole point: this handler is always on --
OSC 7 needs no `require\=', unlike the command channel -- so a `cat\=' of a
hostile file can put a TRAMP name here, and asking whether that directory exists
is itself the connection.  A `default-directory\=' that has gone remote is also
not the end of it: `cooked-file-link\=' resolves the names it finds against it,
so one poisoned value turns every settled batch of scrollback into remote stats.
See `cooked--local-name\='.

The URL\='s authority is kept rather than skipped, in `cooked--host\='.  A shell
on another host reports its directory perfectly honestly and the path it sends
is perfectly real, which is exactly the problem: resolved here it names a
different file, or -- worse and more often -- a local file of the same name that
does exist, on a machine whose tree is kept in step with the one you ssh\='d to.
So a foreign host updates `cooked--host\=' and stops there, leaving
`default-directory\=' at the last place we could actually vouch for.

The path is percent-encoded, because that is what a URL is: a directory called
`100%20cake\=' has to arrive as `100%2520cake\=' or it decodes to a different
directory that does not exist.  Both emitters that reach this parser --
cooked\='s own snippets and a fish 4 doing its own reporting -- encode that way,
so there is one encoding on the wire and one decoding here."
  (when (string-match "\\`file://\\([^/]*\\)\\(/.*\\)\\'" url)
    (setq cooked--host (url-unhex-string (match-string 1 url)))
    (unless (cooked--foreign-host-p)
      (when-let* ((name (cooked--local-name (url-unhex-string (match-string 2 url))))
                  (dir (file-name-as-directory name)))
        (when (file-directory-p dir)
          (setq default-directory dir))))))

(provide 'cooked-osc)
;;; cooked-osc.el ends here
