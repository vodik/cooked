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
;; sequence means to Emacs is Emacs\=' business, and that is this file: titles and the
;; buffer name built from them, the working directory, notifications, progress, the
;; clipboard, and the OSC 51 channel\='s two nil-valued hooks.  The colours are
;; cooked-color.el, which this file dispatches to.
;;
;; Notifications are refused by default and say so in their docstring: anything that
;; can write to the terminal can send one.  See `cooked-allow-notifications\=', and
;; `cooked-allow-color-set\=' for the same rule applied to the colours.

;;; Code:

(require 'url-util)
(require 'cooked-util)
(require 'cooked-state)
(require 'cooked-link)

(cooked--declare-core)

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
    (13 . cooked--osc-color)
    (14 . cooked--osc-color)
    (15 . cooked--osc-color)
    (16 . cooked--osc-color)
    (17 . cooked--osc-color)
    (18 . cooked--osc-color)
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

;;;; The buffer's name
;;
;; Built from the directory OSC 7 reports and the title OSC 0 and 2 set, and
;; renamed from those two handlers.

(defcustom cooked-buffer-name "*cooked: %p*"
  "How session buffers are named.

A string is used as a `format-spec' template:

  %p    the abbreviated working directory
  %t    the child's OSC 2 title, empty until it sets one
  %h    the child's host, empty for a local session

A function is called with three arguments, DIR TITLE HOST -- the same three
values, already abbreviated/defaulted to \"\" -- and should return a name.
Either way the result is uniquified, so several sessions can coexist.

Only a rename (see `cooked-buffer-name-auto-update') can supply a title or
host; the initial name is always formatted with TITLE and HOST empty, since
neither is known before the child has said anything."
  :type '(choice (string :tag "Format")
                 (function :tag "Function of DIR, TITLE and HOST"))
  :group 'cooked)

(defcustom cooked-buffer-name-auto-update nil
  "Whether to rename the buffer as the child's directory or title change.

Off by default: a buffer whose name changes under you is hard to find again and
breaks anything holding on to the old name.  Turn it on for the vterm-like
behaviour of showing the running command in the buffer list -- or, with a
`cooked-buffer-name' that mixes %p, %t and %h, to keep the directory and the
title current side by side.  Every OSC 7 (directory) and OSC 0/2 (title) update
re-renders the name, whether or not the template actually uses that piece."
  :type 'boolean :group 'cooked)

(defun cooked--format-buffer-name (dir title host)
  "Apply `cooked-buffer-name' to DIR, TITLE and HOST."
  (if (functionp cooked-buffer-name)
      (funcall cooked-buffer-name dir title host)
    (format-spec cooked-buffer-name
                 `((?p . ,dir) (?t . ,title) (?h . ,host)))))

(defun cooked--buffer-name (&optional directory)
  "A fresh, unique buffer name for a session in DIRECTORY."
  (generate-new-buffer-name
   (cooked--format-buffer-name
    (abbreviate-file-name (or directory default-directory)) "" "")))

(defun cooked--buffer-name-shows-title-p ()
  "Whether the active `cooked-buffer-name' template would print the title.

Used by the mode line to decide whether printing the title again would be
redundant.  Nil when `cooked-buffer-name-auto-update' is off, since then
nothing renames the buffer at all.  Also nil when `cooked-buffer-name' is a
function -- there is no way to know without calling it, and a mode-line query
is not license to run one for its side effects."
  (and cooked-buffer-name-auto-update
       (stringp cooked-buffer-name)
       (string-match-p "%[-0<>^_]*[0-9.]*t" cooked-buffer-name)))

(defun cooked--update-buffer-name ()
  "Rename the buffer after the child's directory or title, when asked to.

Called on every OSC 7 and OSC 0/2, not just when the template's own fields
changed: `cooked-buffer-name' can be a function that looks at other buffer
state, so there is no cheap way to know in advance whether this particular
update would change the name.  The `equal' check below is what keeps a quiet
child from being renamed to the name it already has.

Also where `list-buffers-directory' is kept current, outside the
`cooked-buffer-name-auto-update' gate: this is the one place both OSC 7 and
OSC 0/2 already pass through, and what the buffer list prints in its directory
column is not the user's choice about buffer names."
  (setq-local list-buffers-directory default-directory)
  (when cooked-buffer-name-auto-update
    (let ((name (cooked--format-buffer-name
                 (abbreviate-file-name default-directory)
                 cooked-title
                 (or cooked--host ""))))
      (unless (equal name (buffer-name))
        (rename-buffer (generate-new-buffer-name name))))))

;;;; OSC 9, 99 and 777 — notifications

(defcustom cooked-allow-notifications nil
  "Whether the child may raise desktop notifications, via OSC 9, 99 or 777.

Off by default, for the same reason `cooked-allow-color-set' is: anything that
can write to the terminal can send one.  A `cat' of a hostile file, a build log
quoting attacker-controlled text, or output from a compromised host all reach
your desktop if this is on."
  :type 'boolean
  :group 'cooked)

(defcustom cooked-notification-rate '(3 . 10)
  "Cap on notifications as a cons of COUNT and SECONDS.
Notifications past the cap are dropped silently.  A child that means well
sends one when a long build finishes; a child that does not sends thousands.
The cap is shared by every session, so ten buffers still raise at most COUNT."
  :type '(cons natnum natnum)
  :group 'cooked)

(defconst cooked--notification-limits '(120 . 500)
  "Maximum title and body length, in characters.")

(defvar cooked--notification-times nil
  "Timestamps of recent notifications from any session, newest first.

Global rather than buffer-local, as `cooked--bell-last' is and for the same
reason: the desktop is one place, and a cap per buffer would let a dozen
sessions each fill it.  See `cooked-notification-rate'.")

(defvar cooked--notification-markup nil
  "Whether the notification server interprets markup in a body, once known.

nil until a notification has been raised, then a list of one boolean, so that
a server that answered no is not asked again.")

(defvar-local cooked--notification-chunks nil
  "Partial OSC 99 notifications, as an alist of id to (TITLE . BODY).")

(defconst cooked--notification-chunk-limits '(8 . 4096)
  "How many partial notifications to hold, and the most text each may accumulate.

A child can open a chunked notification and never close it, so both are
bounded: without that, `cooked--notification-chunks' is a buffer-local leak the
child controls.")

(defun cooked--notification-clean (text limit)
  "TEXT without control or format characters, cut to at most LIMIT characters.

Format characters, Unicode's class Cf, draw nothing and still change what is
drawn.  U+202E RIGHT-TO-LEFT OVERRIDE before `txt.exe' shows `exe.txt', so a
child could make a notification read as something it does not say.  The
joiners U+200C and U+200D are the exception, being how an emoji sequence such
as a family is spelled, and they cannot reorder anything.  C1
controls, U+0080 to U+009F, go with the C0 ones.  The scan stops once LIMIT
characters are kept, so a megabyte of OSC 9 costs no more than its first
screenful."
  (let ((text (or text ""))
        (index 0)
        (kept nil)
        (count 0))
    (while (and (< index (length text)) (< count limit))
      (let ((char (aref text index)))
        (unless (and (memq (get-char-code-property char 'general-category) '(Cc Cf))
                     (not (memq char '(#x200c #x200d))))
          (push char kept)
          (setq count (1+ count))))
      (setq index (1+ index)))
    (concat (nreverse kept))))

(defun cooked--notification-allowed-p ()
  "Whether another notification is within `cooked-notification-rate'."
  (pcase-let* ((`(,count . ,seconds) cooked-notification-rate)
               (cutoff (- (float-time) seconds)))
    (setq cooked--notification-times
          (seq-take (seq-filter (lambda (at) (> at cutoff))
                                cooked--notification-times)
                    count))
    (< (length cooked--notification-times) count)))

(defun cooked--notification-escape (text)
  "TEXT with the three characters that open markup written as entities.

A server advertising `body-markup' reads the body as a subset of HTML, so
`<img src=\"file:///etc/passwd\">' in a child's message would be
fetched and drawn, and `<a href>' made clickable.  Escaped, both are shown
as the text they are."
  (replace-regexp-in-string
   "[&<>]"
   (lambda (match) (pcase match ("&" "&amp;") ("<" "&lt;") (_ "&gt;")))
   text t t))

(defun cooked--notify (title body)
  "Raise a notification with TITLE and BODY from this buffer, within the cap.

The text is cleaned here, but the notification is raised from a timer, by
`cooked--raise-notification'.  This runs inside a drain, and a desktop
notification is a synchronous D-Bus call that a slow or still-starting
notification service can hold for seconds, with the child's output
waiting behind it."
  (when (cooked--notification-allowed-p)
    (push (float-time) cooked--notification-times)
    (run-at-time 0 nil #'cooked--raise-notification
                 ;; Cleaned too: a buffer named after the title holds the child's text.
                 (cooked--notification-clean (buffer-name) (car cooked--notification-limits))
                 (cooked--notification-clean title (car cooked--notification-limits))
                 (cooked--notification-clean body (cdr cooked--notification-limits)))))

(declare-function notifications-notify "notifications" (&rest params))
(declare-function notifications-get-capabilities "notifications" (&optional bus))

(defun cooked--raise-notification (buffer title body)
  "Show TITLE and BODY, sent from the buffer named BUFFER, on the desktop.

The buffer leads the title, as in `*cooked*<2>: Build failed', because a
notification that does not say which session sent it cannot be acted on.  The
body is escaped when the server would read markup in it.

Shown with `message' instead when there is no desktop to show it on:
Emacs built without D-Bus, or a terminal Emacs over ssh with no session bus,
where every call signals.  Falling back on each failure, rather than giving up
after the first, means a notification is never lost without a trace."
  (let ((title (if (string-empty-p title)
                   buffer
                 (format "%s: %s" buffer title))))
    (unless (and (featurep 'dbusbind)
                 (require 'notifications nil t)
                 (condition-case nil
                     (progn
                       (unless cooked--notification-markup
                         (setq cooked--notification-markup
                               (list (and (memq :body-markup
                                                (notifications-get-capabilities))
                                          t))))
                       (notifications-notify
                        :title title
                        :body (if (car cooked--notification-markup)
                                  (cooked--notification-escape body)
                                body))
                       t)
                   (error nil)))
      ;; Never as a format string: the text is the child's.
      (message "%s" (string-trim (concat title " " body))))))

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

kitty's protocol: `ESC ] 99 ; METADATA ; PAYLOAD ST', where METADATA is a
set of KEY=VALUE pairs.  `i' identifies a notification, `p' says whether
the payload is its title or its body, and `d=0' means more chunks follow."
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
  "Raise a notification from PARTS, the older `777;notify;TITLE;BODY' form."
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

A first field of nothing but digits is a ConEmu command: `4' is handed to
`cooked--osc-progress', and the other eleven are dropped rather than read as
text.  Anything else is iTerm2's message, which may itself contain `;' and so
is joined back together, and goes through `cooked-allow-notifications' and
`cooked-notification-rate' like OSC 99 and 777.  An empty message is dropped
too: there is nothing to say, and a bare `ESC ] 9 ST' is not a request."
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
;; and it is deliberate: this is the same shape of channel as an OSC 7 payload,
;; which can name a TRAMP host.

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

A cons of STATE and PERCENT.  STATE is one of `set', `error',
`indeterminate' or `paused' -- never a string, and never anything the child
chose.  PERCENT is an integer from 0 to 100, or nil when there is no number to
show: `indeterminate' never carries one, and `error' and `paused' need
not.

Read by `cooked--mode-line-progress', which is the only consumer.  Buffer-local
because a progress report is one session's news and the mode line is per
buffer.")

(defun cooked--progress-percent (field)
  "PERCENT from FIELD, ConEmu's `pr', or the symbol `bad' if it is not a number.

Three answers rather than two.  nil means the child sent no number, which is
legal for every state that takes one and is how `ESC ] 9 ; 4 ; 2 ST' says \"the
thing I was doing failed\" without restating how far it had got.  `bad' means
it sent something that is not a number, which is a different situation entirely
and one the caller refuses outright.

`-1' is nil as well.  It is how tmux says no number: it hands on every report
through its `Spb' as a state and a percentage, and a report that came without
one goes out as `9;4;3;-1'.

`string-to-number' cannot tell those apart -- it answers 0 for the empty
string, for `nan', and for a megabyte of NUL bytes -- so the digits are
checked before it is asked.  Out of range is clamped rather than refused, on
rockorager.dev's rule for the sequence and because a build tool that computes
101% has a rounding bug, not a hostile intent."
  (cond
   ((member field '(nil "" "-1")) nil)
   ((string-match-p (rx bos (+ digit) eos) field)
    (min 100 (string-to-number field)))
   (t 'bad)))

(defun cooked--osc-progress (parts)
  "Record the child's progress from PARTS, the OSC 9 payload after the code.

PARTS is ConEmu's `4', the state digit, and an optional percentage.  Anything
else -- a fifth field, a state outside 0-4, a percentage that is not a number --
leaves `cooked--progress' exactly as it was rather than guessing at what was
meant.  Refusing to act is the only safe reading of a malformed report: the
alternative is a stream that can park a wrong number in the mode line and then
stop sending, leaving it there.

A state that takes a percentage and arrives without one keeps the percentage
already on show.  That is what makes the two-sequence idiom work -- `1;70'
while the work runs, then a bare `2' when it fails -- and it reads as
`[err 70%]', which says more than `[err]' does.  `indeterminate' drops it
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
whatever happened to be on screen when something else last changed.

A report that changes nothing asks for nothing.  cargo and npm resend the same
percentage many times a second while a slow step runs, and each repaint would
re-evaluate every mode line showing this buffer to draw the text already there."
  (let ((progress (and state (cons state percent))))
    (unless (equal progress cooked--progress)
      (setq cooked--progress progress)
      (force-mode-line-update))))

(defun cooked--reset-progress ()
  "Drop any progress indicator, on RIS and when a command is over.

Called from the `reset' event rather than from anything in this file, because
RIS is `ESC c' and not an OSC at all.  It has to be reachable from Lisp: the
indicator is the one piece of a session's visible state that lives entirely in
Emacs, so a reset that Rust handled by itself would clear the screen and leave
the mode line still claiming a build was 60% through -- and there would be no
second thing for the user to type, `reset' being the thing you type when
something is stuck.

Also called from `cooked--end-of-command', for the report nobody finished: a
build interrupted at the keyboard, or an agent that crashed, never sends the
`0' that removes its bar, and the shell prompting again is the proof it is
gone."
  (cooked--set-progress nil nil))

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

The payload is everything after the `E', so `E1;F;/tmp/x' arrives as
\"1;F;/tmp/x\": a version, a verb, and at most one argument.  Parsing it is the
layer's business rather than this file's.

Empty means the channel is closed and requests are ignored -- and that
emptiness is load-bearing rather than incidental: it is what
`cooked--osc-emacs' reads to tell \"nobody is listening\" from \"somebody
refused\", and so what raises the once-per-buffer notice pointing at
`cooked-osc-eval'.  Requiring that file is how you opt in, and the point of
the split is that opting in is something you do on purpose rather than inherit.

Deliberately a `defvar' and not a `defcustom' with `:type \\='hook', unlike
every other seam here: this is the one place terminal output becomes action, and
a customize interface would be a way to open the channel without ever loading
the file whose whole job is to make that a decision.")

(defvar cooked-osc-completion-functions nil
  "Abnormal hook handling an OSC 51;C *reply*, run with the payload.

Empty means the completion layer is not loaded, and a reply arriving anyway is
dropped unread.  Harmless: nothing asked for it, because asking is that layer's
job.

The announcement is deliberately not routed through here.  It is handled below,
unconditionally, because `cooked--policy' reads it as a license to own the
input line and that reading has to hold in a session that never loads the
completion layer at all.  `cooked-shell-completion' sets this; see
`cooked-shell-completion-functions' for the other half of the same switch.")

(defun cooked--osc-announce (payload)
  "Record the prompt's OSC 51;CH announcement from PAYLOAD, minus its leading H.

Inert by construction -- a version number and a nonce -- which is what makes it
safe to believe with no opt-in in front of it.

Version first, so a newer shell snippet paired with an older Emacs declines
rather than misreading the protocol.  An unrecognised shape clears the nonce
instead of leaving the last one standing: a garbled announcement is the shell
failing to make a claim, and the safe reading of no claim is no license."
  (pcase (split-string payload ";")
    (`("" "2" ,nonce . ,rest)
     (setf (cooked-line-completion-nonce (cooked--line)) nonce
           ;; Field 3 is the reply capability, absent in snippets that predate
           ;; it -- which could only announce when they could also reply, so
           ;; their silence means capable.
           (cooked-line-completion-reply-capable (cooked--line))
           (not (equal (car rest) "0"))))
    (_ (setf (cooked-line-completion-nonce (cooked--line)) nil
             (cooked-line-completion-reply-capable (cooked--line)) nil))))

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
for the `c' and `s' targets, PRIMARY for `p' and SECONDARY for `q'.  The
eight cut buffers `0' to `7' are not among them -- they are private to the
buffer, see `cooked-clipboard-read' -- and are written whenever that lets
them be read back.

A write of nothing, or of something that is not base64, clears PRIMARY and
SECONDARY, as xterm clears a selection, and leaves the kill ring alone.

Reading is a separate question, answered by `cooked-clipboard-read'."
  :type 'boolean
  :group 'cooked)

(defcustom cooked-clipboard-read nil
  "What an OSC 52 query gets back from the clipboard.

Every query is answered under every setting, because a program that asks waits
for the reply; these settings only decide whether the reply has anything in it.
Anything that can write to the terminal can ask -- a `cat' of a hostile file,
output from a compromised host -- which is why the default hands over nothing.

nil answers every query with an empty payload, and keeps nothing a write puts
in a cut buffer, since nothing could read it.

`private' answers the cut buffers `0' to `7' with what OSC 52 last wrote to
them in this buffer, and the shared selections with nothing.  The cut buffers
never reach the kill ring, so a program can round-trip its own text through
them without being able to read anything you copied.  This is eat's middle
ground.

`ask' prompts, naming the buffer and the program in the foreground, before
answering a shared selection; the cut buffers are answered as under `private'.
The prompt waits until the handler has returned rather than running inside the
process filter, and a query that arrives while one is already open is refused
rather than stacked behind it.  It wants a typed `yes', after discarding
input already queued, so a `y' meant for the program cannot answer it.
The program is only what the child calls itself, and `ssh' for anything
remote, so the buffer is the better guide to who is asking.

t answers `c' and `s' from the kill ring, which is the system clipboard
when `interprogram-paste-function' is set, `p' from PRIMARY and `q' from
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
replies to `cooked-clipboard-read' too: a selection that would encode to more
is answered with an empty payload and a message, so the child still hears back
and is not handed megabytes it would have to swallow before its next read.

A value above `cooked--osc-52-core-limit' counts as that limit.  The native
core drops any OSC longer than a mebibyte before Lisp sees it, so a write past
it could only vanish without the message a refusal promises."
  :type 'natnum
  :group 'cooked)

(defconst cooked--osc-52-core-limit (- (ash 1 20) 16)
  "The longest OSC 52 payload the native core is sure to hand to Lisp.

The core refuses any OSC with more than its `OSC_PAYLOAD_LIMIT', one mebibyte,
after the code.  For OSC 52 that is the targets, a semicolon and the data, and
the targets name at most the twelve selections `cpqs01234567'.  Thirteen less
than a mebibyte is therefore always delivered, and this is the multiple of four
below that, which a padded base64 payload always is.")

(defvar-local cooked--clipboard-refused nil
  "The size of the reply last refused for `cooked-clipboard-max-size', or nil.

Kept so that a program asking again and again for the same oversized selection
gets one message rather than one per query: a paste provider polling the
clipboard would otherwise take the echo area over.")

(defun cooked--osc-52-max-size ()
  "The effective OSC 52 bound: `cooked-clipboard-max-size', capped at the core's."
  (min cooked-clipboard-max-size cooked--osc-52-core-limit))

(defvar-local cooked--cut-buffers nil
  "The eight OSC 52 cut buffers, as a vector of byte strings, or nil if unused.

Filled by writes to targets `0' to `7' while `cooked-clipboard-read' is
`private', `ask' or t, and read back by queries under the same settings.
Buffer-local, and never copied to the kill ring: that is what makes answering
from them leak nothing the child did not put there itself.  The bytes are kept
as decoded rather than as the base64 that arrived, so a read re-encodes them
canonically and a malformed write cannot come back out verbatim.")

(defvar-local cooked--clipboard-prompting nil
  "Whether an OSC 52 prompt under `ask' is open for this buffer.")

(defun cooked--osc-52-targets (spec)
  "The selection targets named by SPEC, an OSC 52 first field, as characters.

Unknown letters are dropped, and a SPEC that names nothing known means `s0',
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

(defun cooked--osc-52-reply (targets payload)
  "Answer an OSC 52 query for TARGETS with PAYLOAD, base64 or the empty string.

The reply names every one of TARGETS, as xterm echoes the targets it
understood, because a client that asked about `cp' matches its answer on
that field.  They are the letters `cooked--osc-52-targets' kept, so nothing
the child sent comes back unless it is one of those twelve."
  (when-let* ((session (cooked--live-session)))
    (cooked--reply-osc session 52 (concat (concat targets) ";" payload)
                       cooked--osc-bell-terminated)))

(defun cooked--osc-52-contents (target)
  "The text TARGET holds, a cut buffer's or a shared selection's, or nil."
  (if-let* ((index (cooked--osc-52-cut-buffer target)))
      (and cooked--cut-buffers (aref cooked--cut-buffers index))
    (cooked--osc-52-shared-contents target)))

(defun cooked--osc-52-answers-p (target)
  "Whether a query can be answered from TARGET under `cooked-clipboard-read'.

A cut buffer can when it holds something, under any setting but nil.  A shared
selection can under t when it holds something, and under `ask' whatever it
holds, since looking is what the prompt asks leave for."
  (and cooked-clipboard-read
       (if (or (cooked--osc-52-cut-buffer target)
               (eq cooked-clipboard-read t))
           (not (member (cooked--osc-52-contents target) '(nil "")))
         (eq cooked-clipboard-read 'ask))))

(defun cooked--osc-52-encode (text)
  "TEXT as the base64 an OSC 52 reply carries, or the empty string for nil.

A payload longer than `cooked-clipboard-max-size' is replaced by the empty
string too, with a message.  The bound is measured on the base64, as it is for
writes, so one number caps both directions.  Replying with nothing rather than
not replying is the point: the child is still waiting, and a truncated payload
would decode to text the user never copied.

The length is worked out before anything is encoded, from `string-bytes',
since padded base64 of N bytes is always 4 * ceiling(N / 3) characters.  A
ten-megabyte kill is refused without first building the thirty megabytes of
UTF-8 and base64 it would take to measure.  For text Emacs holds as UTF-8 the
count is exact; a raw byte in a multibyte string is two bytes inside Emacs and
one on the wire, so text with raw bytes in it can be refused a little early."
  (if (stringp text)
      (let ((size (* 4 (ceiling (string-bytes text) 3))))
        (cond
         ((<= size (cooked--osc-52-max-size))
          (setq cooked--clipboard-refused nil)
          (base64-encode-string
           (if (multibyte-string-p text)
               (encode-coding-string (substring-no-properties text) 'utf-8)
             text)
           t))
         (t
          (unless (eql size cooked--clipboard-refused)
            (setq cooked--clipboard-refused size)
            (message "cooked: answered a clipboard read with nothing, as its %d characters exceed `cooked-clipboard-max-size'"
                     size))
          "")))
    ""))

(defun cooked--osc-52-ask (program target)
  "Whether the user lets PROGRAM read the shared selection TARGET.

A child can print \"[y/n]\" and then query, so the `y' the user types for
the child must not be the answer.  Input already queued is discarded first, and
the question is a `yes-or-no-p', with `use-short-answers' bound to nil,
because a single `y' arriving a moment after the prompt opens cannot finish a
typed `yes'.  A `read-multiple-choice' would also discard typeahead, but a
keystroke racing the prompt would still answer it; this is also the prompt
Emacs uses for other questions that are expensive to get wrong, such as
killing the child in `cooked-kill-session'."
  (discard-input)
  (let ((use-short-answers nil))
    (yes-or-no-p
     (format "Let %s in %s read the %s? "
             (or program "the child")
             (buffer-name)
             (pcase target
               (?p "primary selection")
               (?q "secondary selection")
               (_ "clipboard"))))))

(defun cooked--osc-52-query (targets)
  "Answer the OSC 52 query for TARGETS, exactly once.

The answer comes from the first of TARGETS, in the order named, that
`cooked--osc-52-answers-p' allows, as xterm falls through the selections it
was asked for to the first that has something.  With none, the reply is empty.
Under `ask' the reply leaves this function in a deferred prompt, carrying the
terminator it was asked with, since `cooked--osc-bell-terminated' is unbound
by then.  The program is named as it was when the query arrived, since by the
time the prompt runs a short-lived `cat' may have exited and handed the
foreground back to the shell.  Any error inside the prompt is an empty reply
rather than none, because the child is still waiting for one."
  (let ((target (seq-find #'cooked--osc-52-answers-p targets)))
    (cond
     ((null target)
      (cooked--osc-52-reply targets ""))
     ((or (cooked--osc-52-cut-buffer target)
          (eq cooked-clipboard-read t))
      (cooked--osc-52-reply
       targets (cooked--osc-52-encode (cooked--osc-52-contents target))))
     (t
      (if cooked--clipboard-prompting
          (cooked--osc-52-reply targets "")
        (setq cooked--clipboard-prompting t)
        (let ((bell cooked--osc-bell-terminated)
              (program (ignore-errors (cooked--foreground-program))))
          (cooked--defer
           (lambda ()
             (unwind-protect
                 (let ((cooked--osc-bell-terminated bell))
                   (cooked--osc-52-reply
                    targets
                    (condition-case err
                        (if (cooked--osc-52-ask program target)
                            (cooked--osc-52-encode
                             (cooked--osc-52-shared-contents target))
                          "")
                      (quit "")
                      (error
                       (message "cooked: answered a clipboard read with nothing: %s"
                                (error-message-string err))
                       ""))))
               (setq cooked--clipboard-prompting nil))))))))))

(defun cooked--osc-52-write (targets data)
  "Put the base64 DATA into each of TARGETS.

A cut buffer is this buffer's own, so `cooked-clipboard-write' does not
cover it, and putting it on the kill ring would be wrong under any setting.  It
is kept only while `cooked-clipboard-read' lets a query read it back, since
otherwise it is up to eight payloads held for nothing.  The shared selections
need `cooked-clipboard-write', and the kill ring is written once however many
of `c' and `s' were named.

DATA that is empty, or not base64, clears each target instead, which is what
xterm does with it.  The kill ring has no way to be cleared, so a `c' or
`s' with nothing in it is left alone rather than handed an empty kill."
  ;; Measured as the padded length, which is what a read-back re-encodes to, so
  ;; an unpadded write that fits is one whose contents can also be read back.
  (if (> (* 4 (ceiling (length data) 4)) (cooked--osc-52-max-size))
      ;; Refuse out loud: a silent drop looks like the copy simply failed.
      (message "cooked: refused a %d-character clipboard write (see `cooked-clipboard-max-size')"
               (length data))
    (let* ((bytes (cooked--decode-base64 data))
           (bytes (and bytes (not (string-empty-p bytes)) bytes))
           (text (and bytes (decode-coding-string bytes 'utf-8)))
           (killed nil))
      (dolist (target targets)
        (if-let* ((index (cooked--osc-52-cut-buffer target)))
            (when (and cooked-clipboard-read (or bytes cooked--cut-buffers))
              (aset (or cooked--cut-buffers
                        (setq cooked--cut-buffers (make-vector 8 nil)))
                    index bytes))
          (when cooked-clipboard-write
            (pcase target
              (?p (gui-set-selection 'PRIMARY text))
              (?q (gui-set-selection 'SECONDARY text))
              (_ (when (and text (not killed))
                   (setq killed t)
                   (kill-new text)
                   (message "cooked: copied %d characters" (length text)))))))))))

(defun cooked--osc-clipboard (parts)
  "Write or answer the child's OSC 52 request, from PARTS."
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

(defun cooked--osc-cwd (parts)
  "Track the child's directory, from the OSC 7 payload PARTS."
  (cooked--set-directory (string-join parts ";")))

(defcustom cooked-remote-directory 'tramp
  "What an OSC 7 report from another host does to `default-directory'.

`tramp' rewrites the reported path into a TRAMP name for the host the child
says it is on, so \\[find-file] at a shell you ssh'd out to opens the file you
meant -- in this Emacs, with your own configuration and your own language server
-- instead of a same-named local file or nothing at all.

nil leaves `default-directory' at the last place cooked could vouch for, which
is what it did before this existed and is still the right answer if you would
rather a foreign prompt resolve nothing.

Neither setting lets the byte stream choose the host or the method: see
`cooked--remote-directory' for what is and is not taken from the payload."
  :type '(choice (const :tag "Rewrite as a TRAMP path" tramp)
                 (const :tag "Leave `default-directory' alone" nil))
  :group 'cooked)

(defcustom cooked-tramp-default-method nil
  "TRAMP method for a name built from an OSC 7 report, or nil for TRAMP's own.

Only consulted when there is no remote connection to inherit one from -- an
ordinary outbound `ssh' from a local buffer.  A `cd' reported by a shell we
are already talking to over TRAMP keeps that connection's method, and its hops.

nil means `tramp-default-method', which is \"scp\" in a stock Emacs.  \"ssh\"
is the usual reason to set this: it multiplexes over one connection where scp
opens a new one per file."
  :type '(choice (const :tag "`tramp-default-method'" nil) string)
  :group 'cooked)

(defconst cooked--host-name-regexp
  (rx bos (any alnum) (opt (* (any alnum ?. ?- ?_)) (any alnum)) eos)
  "A host name cooked is willing to write into a TRAMP file name.

Letters, digits, dots, hyphens and underscores, and it may not start or end with
punctuation.  Not an attempt to validate a host name -- resolution is TRAMP's
problem and a name that does not resolve merely fails.  It is there to keep
TRAMP's *own* syntax out of a position where it would be read as syntax; see
`cooked--remote-directory'.  An IPv6 literal does not match and is declined,
which costs a rare case a rewrite it would otherwise have got.")

(defun cooked--tramp-prefix (name)
  "NAME without its localname, hops included, or nil when NAME is local.

/ssh:jump|ssh:host:/tmp/ gives /ssh:jump|ssh:host:.  See
`cooked--remote-directory' for why this subtracts the localname rather than
asking `file-remote-p' for the prefix, which would leave the hop out."
  (when-let* ((local (file-remote-p name 'localname)))
    (substring name 0 (- (length name) (length local)))))

(defvar-local cooked--spawn-connection nil
  "The TRAMP prefix this session was started over, and the host it reported.

A cons (PREFIX . HOST), or nil for a session started on this machine.
`cooked--start-session' sets it with HOST nil when it starts a shell over
ssh, and `cooked--set-directory' fills HOST in from the first report naming
another machine.  The shell started over /ssh:prod: that reports ip-10-0-0-1
leaves (\"/ssh:prod:\" . \"ip-10-0-0-1\"), which is what lets
`cooked--remote-prefix' treat the alias and the reported name as one host.

The first report is trusted to come from the far end of that connection because
the spawn sends it itself, from `cooked--remote-cd', before the far shell
starts.  Only an absolute directory is reported there, so a session started in
a directory under ~ waits for its shell's own first report instead.")

(defun cooked--remote-prefix (host)
  "The TRAMP prefix, `/METHOD:HOST:' or longer, that names HOST, or nil.

Two ways to get one, and `cooked--remote-directory' has why each is shaped as
it is.  The prefix `default-directory' already carries is reused whenever it
names HOST, hops and user and method included.  Otherwise one is built, but
only for `cooked--host' -- the host the child has already announced -- and
only if that name passes `cooked--host-name-regexp'.  A HOST that is neither
the connection in use nor the announced host gets nil, so no caller can make
Emacs dial a machine by passing a name through here.

Whether the prefix in `default-directory' names HOST is decided by name, and
a name is all either side has.  So an ssh-config alias reads as a move: a buffer
at `/ssh:prod:' whose shell reports `ip-10-0-0-1', `prod' being that
machine's alias, looks the same as one whose shell has gone on from prod to a
second machine of that name.  The second is the case worth getting right, since
keeping `/ssh:prod:' there would open a file of the same name on the wrong
machine.  So both get a prefix built for `ip-10-0-0-1', which may not resolve
from here and names no user.

A session started over the connection is the exception, because it knows which
host its own connection reaches: the first host that session reported is
the one at the end of the ssh it ran.  `cooked--spawn-connection' keeps that
pair, and a HOST matching it gets the prefix the session was started with, hops
and user included, wherever `default-directory' has been since.  So
\\[cooked] at `/ssh:prod:/srv/' keeps `/ssh:prod:' when its shell says
`ip-10-0-0-1', and again after an `ssh' onward and back.  For a buffer
that got its prefix any other way, a `Host ip-10-0-0-1' entry in
~/.ssh/config, with the alias's HostName and User, makes the built name
work."
  (or (and (cooked--same-host-p host (cdr cooked--spawn-connection))
           (car cooked--spawn-connection))
      (and (cooked--same-host-p (file-remote-p default-directory 'host) host)
           (cooked--tramp-prefix default-directory))
      (and (cooked--same-host-p host cooked--host)
           (string-match-p cooked--host-name-regexp cooked--host)
           ;; Only here, and only on this branch: reading
           ;; `tramp-default-method' is the one thing that needs the
           ;; library, and an inherited prefix already carries a method.
           (progn
             (require 'tramp)
             (format "/%s:%s:"
                     (or cooked-tramp-default-method tramp-default-method)
                     cooked--host)))))

(defun cooked--remote-directory (path)
  "PATH on the host the child last reported, as a TRAMP directory name, or nil.

*The host comes from `cooked--host' and the method never comes from the
payload.*  That is the hostile-`cat' defence carried across rather than
dropped.  OSC 7 is always on -- no `require' in front of it, unlike the
command channel -- so any program that can write to the terminal can send one,
and a name assembled out of what it sent would be a way to make Emacs dial a
machine
of the sender's choosing.  `cooked--local-name' is what refuses that on the
local branch, and cannot be what refuses it here, because here the answer is a
remote name by construction.

`cooked--host' is not payload-free either -- it is the authority half of the
same URL -- and the point is that it does not need to be.  It is the host the
child is *claiming to be*, which cooked has already told the rest of the buffer
to distrust: `cooked--foreign-host-p' is what makes the mode line say so,
makes completion decline, and makes `cooked-file-link' resolve nothing.  A
hostile
stream therefore buys exactly one thing it did not have before, a TRAMP name
pointing at the host it already announced, and pays for it by announcing it.

What it must not buy is a *method*, and that is the whole of what the two guards
below are for.  Both halves of the URL are attacker-chosen strings, and TRAMP
file-name syntax is punctuation:

- The authority is matched as `[^/]*' and percent-decoded, so `file://
  a%7Csudo%3A/etc' would arrive as the host `a|sudo:' and, formatted
  straight into `/ssh:%s:', produce `/ssh:a|sudo::/etc' -- a second hop to
  root that nothing in the path half was needed for.  The regexp
  `cooked--host-name-regexp' is what stops that, and declining outright is the
  answer rather than quoting,
  because a host containing TRAMP punctuation is not a host anyone has.
- The path is appended after a *complete* `/method:host:' prefix, which is the
  position where TRAMP stops parsing and starts taking bytes: a payload path of
  `/ssh:evil:/tmp' becomes the localname `/ssh:evil:/tmp' on our host, a
  file that merely does not exist, and not a hop to `evil'.

An existing remote prefix is reused rather than rebuilt, and that is the whole
of what keeps a multi-hop connection alive.  A buffer already at
`/ssh:jump|ssh:host:' has to stay two hops across a `cd': formatting a fresh
`/ssh:host:' would flatten it to one and dial a machine that is very likely
not reachable directly, which is the failure that makes a bastion setup useless
rather than merely slower.  Reusing it also keeps the user and the method the
user actually connected with.

The prefix is taken as `default-directory' *minus its localname*, and not as
`file-remote-p' of it, which is the obvious spelling and is wrong: TRAMP
reassembles that return value from the dissected name and leaves the `hop'
slot out, so `/ssh:jump|ssh:host:/tmp/' comes back as plain `/ssh:host:'.
The
flattening is silent and the result is a perfectly well-formed name for a
machine the bastion exists because you cannot reach.  Subtracting the localname
keeps whatever was actually there, hops and all, without cooked having to know
how TRAMP spells any of it.

Reused only while that prefix still names the host the child does, though.  An
`ssh' *from* the far shell moves `cooked--host' on and leaves the prefix
where it was, and inheriting it then would hang the new host's paths off the
old host's connection -- the same class of wrong-file error this whole handler
exists to avoid, arrived at from the other side.  `cooked--same-host-p' is the
comparison, shared with `cooked--foreign-host-p' so that a short name from zsh
and a fully qualified one in the prefix agree about being one machine."
  (when-let* ((prefix (cooked--remote-prefix cooked--host)))
    ;; The trailing slash is appended as a string operation, and
    ;; `file-name-as-directory' is not used on either half, because both would
    ;; dispatch to TRAMP.  On the finished name that is the same reassembly
    ;; described above and it would undo the prefix reuse two lines up -- the hop
    ;; survives being carried across and then vanishes on the way out.  On PATH
    ;; alone it hands a handler a string the payload wrote, which is the one thing
    ;; this function exists not to do.  A slash needs neither.
    (concat prefix path (unless (string-suffix-p "/" path) "/"))))

(defvar-local cooked--directory-report nil
  "The last OSC 7 URL acted on, with the `default-directory' it left, or nil.

A cons of the two strings.  The shell sends its report at every prompt whether
or not it moved, so most reports repeat the one before; see
`cooked--set-directory' for why the directory is kept beside the URL.")

(defun cooked--set-directory (url)
  "Track the child's directory from an OSC 7 URL.

On this machine, the name is refused if it is remote, and refused *before*
`file-directory-p' rather than after.  That order is the whole point: a `cat'
of a hostile file can put a TRAMP name in the path half, and asking whether that
directory exists is itself the connection.  See `cooked--local-name'.

On another machine the path is rewritten into a TRAMP name -- see
`cooked-remote-directory' for turning that off, and `cooked--remote-directory'
for why the payload can choose the path but not the host or the method.  There
is deliberately *no* `file-directory-p' on that branch, and it is not an
oversight to be tidied up later: validating would open a synchronous TRAMP
connection on every single `cd', which is the difference between a feature that
costs nothing and one that stalls the shell.  The shell's report is trusted
instead, on the grounds that it is the one party that actually knows -- and a
wrong `default-directory' costs a failed `find-file', where a connection per
`cd' costs every prompt.

Which branch runs is `cooked--foreign-host-p', so the URL's authority is kept
rather than skipped: it is not decoration, it is the thing that decides whether
a path means a file here or a file somewhere else.

The path is percent-encoded, because that is what a URL is: a directory called
`100%20cake' has to arrive as `100%2520cake' or it decodes to a different
directory that does not exist.  Both emitters that reach this parser --
cooked's own snippets and a fish 4 doing its own reporting -- encode that way,
so there is one encoding on the wire and one decoding here.

Ends by offering the buffer a rename, foreign host or not: `cooked--host'
changed either way, and a `cooked-buffer-name' with %h or %p in it wants to
know about both kinds of move, not just the ones that touch
`default-directory'.

A report identical to the last one does nothing: no `file-directory-p', which
is a stat per prompt, and no rename.  The directory it left is part of what
must match, because \\[cd] in the buffer moves `default-directory' without the
shell moving, and the shell's next report of the same place has to put it
back."
  (pcase-let ((`(,host . ,path)
               (unless (equal cooked--directory-report (cons url default-directory))
                 (cooked--parse-file-url url))))
    (when path
      (when (and cooked--spawn-connection
                 (null (cdr cooked--spawn-connection))
                 (not (cooked--local-host-p host)))
        (setq cooked--spawn-connection (cons (car cooked--spawn-connection) host)))
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
      (cooked--update-buffer-name)
      (setq cooked--directory-report (cons url default-directory)))))

;;;; file: URLs, from OSC 8 and from the text

;; OSC 7 and a file hyperlink are the same URL with different jobs.  One says
;; where the shell is and the other names a file to open, but the host half means
;; the same thing in both, and so does the danger: the path half is a string the
;; child chose, and under TRAMP a path can be a connection.  So a link is opened
;; through the same two checks a `cd' is -- `cooked--local-name' on this machine,
;; `cooked--remote-prefix' on another -- and it lives here, beside them, rather
;; than in cooked-link.el, which is below the state both of them read.
;;
;; Emacs' own handler gets neither.  `browse-url-emacs' ignores the host, so
;; `ls --hyperlink' over ssh opens the same path on this machine, and it hands
;; the path to `find-file' as it stands, so `file:///ssh:elsewhere:/tmp' dials
;; elsewhere.  It also ignores the line, which is most of why a tool bothers to
;; link a file at all.

(defcustom cooked-file-url-display #'find-file-other-window
  "How a followed `file:' link is opened.

`find-file-other-window' by default, for the reason
`cooked-file-link-display' gives: the terminal is usually the window you are
in."
  :type 'function
  :group 'cooked)

(defun cooked--file-url-position (spec)
  "LINE and COLUMN from SPEC, a `file:' URL's fragment, as a list, or nil.

The fragment is where the tools that put a line in a file link disagree most.
`L12' is GitHub's and what most editors' \"copy link\" produce, a bare
`12' is kitty's and ripgrep's `kitty' format, and a column rides after a
`C', a `:' or a `,' depending on who wrote it.  A range, `L12-L20',
opens at its start.
Anything else is a fragment that means something to somebody else and is
ignored rather than misread as a line."
  (when (and spec
             (string-match
              "\\`L?\\([0-9]+\\)\\(?:[C:,]\\([0-9]+\\)\\)?\\(?:-.*\\)?\\'" spec))
    (list (string-to-number (match-string 1 spec))
          (when (match-string 2 spec)
            (string-to-number (match-string 2 spec))))))

(defun cooked--file-url-split (path local)
  "PATH less a trailing `:LINE' or `:LINE:COL', as (PATH LINE COL).

The other place a line turns up: delta's and several build tools' link
formats append it to the path.  A file can end in `:12' too, so on this
machine -- LOCAL non-nil -- a PATH that exists as it stands is kept whole.
Another machine is not asked, since asking is the connection; there the suffix
is read as a line, and a file really named that way is the rare case that pays."
  (if (or (not (string-match
                "\\`\\(.*?\\):\\([0-9]+\\)\\(?::\\([0-9]+\\)\\)?\\'" path))
          (and local (file-exists-p path)))
      (list path nil nil)
    (list (match-string 1 path)
          (string-to-number (match-string 2 path))
          (when (match-string 3 path)
            (string-to-number (match-string 3 path))))))

(defun cooked--file-url-target (url)
  "The (FILE LINE COL) a `file:' URL names, or nil having refused it.

Both authority forms are accepted: `file:///x' and `file://host/x' are
what `ls --hyperlink' and ripgrep send, and `file:/x' is the short spelling
RFC 8089 allows.  The fragment is split off before the path is decoded, so a
`#' that is part of a file name -- sent as `%23' -- stays in the name.

A local host has its path put through `cooked--local-name' before anything so
much as looks at it.  Another host is opened only through
`cooked--remote-prefix', which answers for the connection already in use or
the host the child has announced, and for nothing else: a link naming a third
machine is refused, because following it would be the byte stream choosing
where Emacs connects.  The path is appended after that complete prefix, where
TRAMP has stopped reading syntax.  `cooked-remote-directory' set to nil
refuses every remote link, as it refuses every remote `cd'."
  (when (string-match "\\`\\([^#]*\\)\\(?:#\\(.*\\)\\)?\\'" url)
    (let* ((fragment (match-string 2 url))
           (base (match-string 1 url))
           (parsed (cooked--parse-file-url
                    (if (string-match "\\`file:\\(/[^/].*\\)\\'" base)
                        (concat "file://" (match-string 1 base))
                      base))))
      (pcase-let ((`(,host . ,path) parsed))
        (cond
         ((not path)
          (message "cooked: refused `%s' (not a file URL cooked can read)" url)
          nil)
         ((cooked--local-host-p host)
          (when-let* ((name (cooked--local-name path)))
            (pcase-let ((`(,file ,line ,col) (cooked--file-url-split name t)))
              (if-let* ((position (cooked--file-url-position fragment)))
                  (cons name position)
                (list file line col)))))
         ((not (eq cooked-remote-directory 'tramp))
          (message "cooked: refused `%s' (remote file links are off)" url)
          nil)
         ((not (and (string-match-p cooked--host-name-regexp host)
                    (cooked--remote-prefix host)))
          (message "cooked: refused `%s' (%s is not this terminal's host)"
                   url host)
          nil)
         (t
          (let ((prefix (cooked--remote-prefix host)))
            (pcase-let ((`(,file ,line ,col) (cooked--file-url-split path nil)))
              (if-let* ((position (cooked--file-url-position fragment)))
                  (cons (concat prefix path) position)
                (list (concat prefix file) line col))))))))))

(defun cooked--browse-file-url (url &rest _)
  "Open the file URL names, at its line if it names one.

The `file:' entry in `cooked-link-url-handlers'.  Every `file:' URL is
claimed, the ones refused included: a refusal that fell through would reach
`browse-url-emacs', which opens exactly what this declined."
  (pcase-let ((`(,file ,line ,col) (cooked--file-url-target url)))
    (when file
      (funcall cooked-file-url-display file)
      (when line
        (goto-char (point-min))
        (forward-line (1- line))
        (when col
          (move-to-column (max 0 (1- col))))))))

(unless (assoc "\\`file:" cooked-link-url-handlers)
  (setq cooked-link-url-handlers
        (append cooked-link-url-handlers
                (list (cons "\\`file:" #'cooked--browse-file-url)))))

(provide 'cooked-osc)
;;; cooked-osc.el ends here
