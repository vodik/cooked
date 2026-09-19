;;; cooked-keys.el --- What a key becomes on its way to the child -*- lexical-binding: t; -*-

;;; Commentary:

;; Everything between a key press and the bytes the child receives: how an Emacs
;; event is spelled in whichever protocol the child negotiated -- or the one
;; `cooked-key-protocol-overrides' assumes for a program that never negotiates --
;; the commands that send a key, a string or a paste, and the per-program
;; overrides that rebind a key to bytes of its own.
;;
;; Which keys are forwarded at all is cooked-keymaps.el, and which map is
;; installed when is `cooked--refresh-keymap' in cooked-mode.el.  Both sit above
;; this file.  What it needs below it is the session state, the child's cursor,
;; which every send snaps point back to, and peek, which every out-of-band send
;; resumes.

;;; Code:

(require 'cl-lib)
(require 'cooked-util)
(require 'cooked-state)
(require 'cooked-cursor)
(require 'cooked-pending)
(require 'cooked-peek)

(cooked--declare-core)

;;;; Key encoding
;;
;; The spelling itself is the core's, in src/emu/term/keypress.rs, and reaches the
;; child through `cooked--send-key'.  Which protocol the child negotiated, at which
;; level, with which kitty flags, and whether DECCKM and DECKPAM are set are all the
;; child's to change at any moment; spelled from this side they were read as of the
;; last drain, so a key pressed after a `CSI > 1 u' and before the next drain went out
;; in the encoding the child had just stopped reading.  What is left here is the half
;; that is Emacs': which key an event names, and which protocol to assume for a program
;; that reads one without ever asking for it.

(defconst cooked--key-names
  '(up down right left home end
    f1 f2 f3 f4 prior next insert deletechar
    f5 f6 f7 f8 f9 f10 f11 f12
    return tab escape backspace backtab begin
    kp-0 kp-1 kp-2 kp-3 kp-4 kp-5 kp-6 kp-7 kp-8 kp-9
    kp-decimal kp-add kp-subtract kp-multiply kp-divide kp-separator kp-enter
    kp-home kp-up kp-prior kp-left kp-begin kp-right kp-end kp-down kp-next
    kp-insert kp-delete
    f13 f14 f15 f16 f17 f18 f19 f20 f21 f22 f23 f24
    menu pause print)
  "Every non-character key cooked speaks for, by the symbol Emacs names it with.

The spelling of each is the core's, in `NamedKey'; this list is the same set of
names in the same order, because `cooked--build-passthrough-map' has to bind
every one of them, in every modified spelling, before the module is loaded and
so before `cooked--key-table' could be asked.  The test
`cooked-key-names-match-the-core' holds the two against each other, so a key
added on one side and forgotten on the other fails rather than encoding to
nothing.")

(defconst cooked--kitty-only-keys '(pause print)
  "Keys with no spelling outside the kitty keyboard protocol.

Pause and Print Screen send nothing in xterm and have no capability in
terminfo, and inventing a sequence for them would put bytes in a program's
input that it never agreed to read.  The protocol gives each a code point of
its own, so `cooked--build-passthrough-map' binds them only while it is
negotiated; see `cooked--kitty-only'.")

(defconst cooked--key-event-aliases
  '((delete . deletechar))
  "Keys a graphical frame names differently, as (EVENT . SYMBOL).

SYMBOL is the `cooked--key-names' entry the key is spelled by, and EVENT is the
name a graphical frame gives the same key.  A terminal frame decodes the Delete
key's `ESC [ 3 ~' as `deletechar', but a graphical frame reports it as
`delete' and translates that to `deletechar' through `local-function-key-map'
only when nothing binds `delete' -- and `comint-mode-map' does.  So Delete in a
full-screen program ran `delete-forward-char' on a read-only row instead of
reaching the child.

`cooked--build-passthrough-map' binds each EVENT beside its row, in every
modified spelling, and `cooked--key-parts' reads EVENT as SYMBOL, so
\\`C-<delete>' is sent as `ESC [ 3 ; 5 ~' on either frame.  Every other key is
named alike on both.")

(defun cooked--key-parts (event)
  "The key EVENT names and the modifiers it was held with, or nil.

A cons (KEY . MODS), where KEY is a character -- the key `event-basic-type'
reports, with no modifier folded into it -- or one of `cooked--key-names', and
MODS a list of `event-modifiers' symbols.  That is what `cooked--send-key'
takes.  nil for an event this terminal has no key in: a mouse event, whose
`event-basic-type' is a symbol no table carries, or a key such as `f30' that
no protocol spells.

`event-modifiers' is asked first, and not merely for readability: on a symbolic
event such as `S-up' it is what parses and caches `event-symbol-elements',
which `event-basic-type' only reads.  Ask the other way round and the first
press of every modified key decodes as nil."
  (let* ((mods (event-modifiers event))
         (basic (event-basic-type event))
         (basic (alist-get basic cooked--key-event-aliases basic))
         ;; Emacs bakes `backtab''s shift into the base symbol and reports none
         ;; in MODS at all, for `backtab' alone or with other modifiers held
         ;; alongside it (`C-backtab' still reports only `(control)').  Restore
         ;; it, or the key has a code point no modifier ever reaches.
         (mods (if (eq basic 'backtab) (cons 'shift mods) mods))
         ;; And the other way round: where a frame names the key `S-tab', it is
         ;; still the Shift+Tab X calls `ISO_Left_Tab', which every protocol
         ;; spells as `backtab' rather than as a Tab with a modifier.
         (basic (if (and (eq basic 'tab) (memq 'shift mods)) 'backtab basic)))
    ;; A terminal frame delivers Tab, Return, Backspace and NUL as the bare
    ;; bytes, which Emacs names by the letter they are typed with: a TAB read
    ;; there is `C-i', and a protocol told that would send `ESC [ 105 ; 5 u'
    ;; for every Tab.  A graphical frame reports the key itself and this does
    ;; not arise; a terminal frame cannot tell the two apart, and every
    ;; terminal before kitty sent Tab for both, so the key is taken to be Tab.
    ;; ESC is the exception left alone: there it is both the Escape key and the
    ;; first half of every Meta chord, and the core sends it as the byte.
    (pcase (and (integerp event) (logand event (1- (ash 1 22))))
      ((and code (or 9 13 127))
       (cons (pcase code (9 'tab) (13 'return) (127 'backspace))
             (remq 'control mods)))
      (0 (cons ?\s mods))
      ;; Emacs names ESC `C-[', which no protocol may re-spell: the core reads
      ;; the bare character 27 as the byte and sends it as the byte.
      (27 (cons 27 (remq 'control mods)))
      (_ (and (or (characterp basic) (memq basic cooked--key-names))
              (cons basic mods))))))

(defun cooked--send-key-event (event)
  "Send the key EVENT names to the child, or return nil if it names none.

The bytes are the core's: `cooked--send-key' spells the key against the
protocol the child holds at the moment of the write, and writes it in the same
step.  The protocol `cooked-key-protocol-overrides' guesses for the program in
the foreground goes with it, and the core applies that only where the child
negotiated nothing of its own."
  (when-let* ((parts (cooked--key-parts event)))
    (cooked--snap-to-cursor)
    (cooked--send-key (cooked--require-session) (car parts) (cdr parts)
                      (cooked--assumed-key-protocol))))

(defun cooked--encode-key-event (event &optional assumed)
  "The bytes the child would receive for the key EVENT names, or nil.

ASSUMED is a protocol to assume for a program that negotiated none, as for
`cooked--send-key'.  For the two callers that have to compose the key with
other bytes and write them together; everything else sends the key through
`cooked--send-key-event'."
  (when-let* ((parts (cooked--key-parts event)))
    (cooked--encode-key (cooked--require-session) (car parts) (cdr parts) assumed)))

;;;; The kitty keyboard protocol, as negotiated

(defconst cooked--kitty-disambiguate 1
  "Kitty keyboard flag 1: spell ambiguous keys, Escape and chords, as escape codes.")

(defconst cooked--kitty-all-keys 8
  "Kitty keyboard flag 8: report every key as an escape code, text keys included.")

(defconst cooked--kitty-negotiated
  (logior cooked--kitty-disambiguate cooked--kitty-all-keys)
  "The kitty flags either of which means the child asked for the protocol itself.

Flag 8 turns the protocol on as surely as flag 1 does, since reporting every key
as an escape code disambiguates them all by construction, while flags 4 and 16
only add a field to an escape code something else already chose to send.  The
core makes the same test in `KittyFlags::enables_encoding'.")

(defun cooked--kitty-negotiated-p ()
  "Whether the child asked for the kitty protocol itself, so all of it applies.

See `cooked--kitty-negotiated' for which flags say so.  What it rules out is a
`kitty' that nobody negotiated, which `cooked-key-protocol-overrides' assumes
for a program that reads the protocol without ever asking for it.

Read from the drain's copy of the flags, which is right for what asks: this
decides which keys `cooked--build-passthrough-map' takes away from Emacs, and
a keymap is rebuilt on a drain anyway.  What the child is *sent* is spelled
against the flags it holds at the moment of the write, which is the core's to
read."
  (and (eq cooked--keys 'kitty)
       (/= 0 (logand cooked--kitty-flags cooked--kitty-negotiated))))

(defun cooked-send-key ()
  "Send the key that invoked this command straight to the child.

Spelled in whatever the child negotiated, or in the protocol
`cooked-key-protocol-overrides' assumes for a program that never negotiated one
-- see `cooked--assumed-key-protocol'."
  (interactive)
  (cooked--send-key-event last-command-event))

(defun cooked-send-meta-key ()
  "Send the key that invoked this command to the child, with Meta applied.

Bound only under the ESC prefix `cooked--build-meta-overlay' makes, where a
Meta chord arrives as two events and the modifier is gone by the time a command
runs: `M-t' is looked up as `ESC t', so `last-command-event' is a bare
`?t'.  Put the modifier back and hand the reconstructed event to
`cooked-send-key', so that a negotiated protocol spells it as a modifier
parameter rather than as a leading ESC -- which is the whole reason not to
simply send \"\\e\" and the key.

`event-apply-modifier' is what Emacs' own `event-apply-meta-modifier' uses,
and it answers for symbols as well as characters."
  (interactive)
  (let ((last-command-event
         (event-apply-modifier last-command-event 'meta 27 "M-")))
    (cooked-send-key)))

(defvar cooked-send-string-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map minibuffer-local-map)
    (define-key map (kbd "S-<return>") #'newline)
    (define-key map (kbd "M-RET") #'newline)
    map)
  "Minibuffer map for `cooked-send-string'.

`RET' sends what has been typed, so the newline a here-document or a
multi-line send needs has nowhere else to come from; `S-RET' inserts one, the
same split every chat client makes.

Both spellings, unconditionally, because nothing here can tell whether the
first will arrive.  This is Emacs' own keyboard, not the child's: what
`cooked--keys' negotiated says what the program *inside* the terminal may
send us, and has no bearing on whether the terminal Emacs is itself running in
reports a shift modifier on `RET'.  A GUI frame does; a terminal one does
only if it speaks a protocol that can, which is between Emacs and its own
terminal.  So `M-RET' is bound alongside as the spelling that always
survives.  `C-j' is not: `minibuffer-local-map' binds it to
`exit-minibuffer', and taking that away would be a worse trade than the one
it fixes.  `C-q C-j' inserts a newline anywhere and is unaffected by either.")

(defun cooked-send-string (string)
  "Send STRING to the child.

Bound on `cooked-mode-map', not just `cooked-raw-map'/`cooked-alt-map', so it
also reaches the child while peeking -- ending peek first, so the result is
seen immediately rather than held behind the freeze -- but refuses once Emacs
owns the line: a string sent out of band would arrive at the child ahead of
whatever pending input is still sitting unsent in the buffer."
  (interactive (list (read-from-minibuffer "Send: " nil cooked-send-string-map)))
  (cooked--resume-forwarding)
  (when (cooked--input-state-p)
    (user-error "Emacs already owns the line; type directly instead"))
  (cooked--snap-to-cursor)
  (cooked--send-to-child string))

(defcustom cooked-paste-confirm-lines t
  "Whether to confirm a multi-line paste the child cannot tell is a paste.

A line editor reads an embedded newline as Enter, so several lines pasted into a
child that has not asked for bracketed paste run one after another, immediately,
with no chance to read them first.  Terminals have warned about this for years
and the hazard here is the same one.

A child that *has* asked for bracketed paste is never confirmed: it is told
where the paste begins and ends and inserts it as one edit, which is the whole
point of the protocol."
  :type 'boolean
  :group 'cooked)

;; The strip list, the bracketing and the mode that chooses between them are the
;; core's, in src/emu/term/paste.rs: `cooked--strip-paste-controls',
;; `cooked--bracketed-paste' and `cooked--send-paste-text'.  What is stripped is
;; security-relevant and what brackets is mode-dependent, and both were spelled
;; out here while the mode they answer to lived there -- one list to keep in step
;; across two languages, and a window between reading the mode and writing the
;; bytes.  This file keeps the parts that are questions about Emacs: which parts
;; of a line were pasted, and whether to ask the user first.

(defun cooked--strip-pasted-controls (text)
  "TEXT with control bytes stripped from the parts that were pasted.

A pasted part is one carrying the `cooked-pasted' property that
`cooked--mark-pasted' puts on a yank, a drop or a history entry, and it goes
through `cooked--strip-paste-controls'.  Everything else is what the user typed
and is left alone, as xterm, kitty, foot and ghostty leave it: a line holding a
yanked \"a ESC [ A\" followed by an ESC typed with \\[quoted-insert] goes to the
shell as \"a  [A\" and then the ESC.

The result carries no properties, since it is on its way to the child."
  (let ((pieces nil)
        (from 0)
        (end (length text)))
    (while (< from end)
      (let* ((to (next-single-property-change from 'cooked-pasted text end))
             (piece (substring-no-properties text from to)))
        (push (if (get-text-property from 'cooked-pasted text)
                  (cooked--strip-paste-controls piece)
                piece)
              pieces)
        (setq from to)))
    (apply #'concat (nreverse pieces))))

(defun cooked--send-paste (text)
  "Hand TEXT to the child as a paste.

The stripping, the bracketing and the choice between them are
`cooked--send-paste-text's, made together against the mode the child holds at
the moment of the write.  What is left here is the one question the core cannot
answer: whether to paste at all.

A child that has not asked for bracketed paste cannot tell a paste from typing,
so a line editor reads every embedded newline as Enter and runs the lines one
after another with no chance to read them first.  That is a question for the
user, and `cooked-paste-confirm-lines' is where the answer is configured.  The
line count is taken before the strip because the strip leaves newlines alone,
which is what makes a paste worth confirming in the first place.

The mode is asked twice -- here, and again under the lock when the bytes are
written -- and the second answer is the one that decides how the text is
framed.  A child that turns bracketing off in between gets an unbracketed paste
the user was not asked about, which is the same small window this had when the
framing was on this side too; a child that turns it on gets a bracketed paste
that was confirmed unnecessarily, which costs a question and nothing else."
  (if (and cooked-paste-confirm-lines
           (not (cooked--bracketed-paste-p (cooked--require-session)))
           (string-search "\n" text)
           (not (y-or-n-p
                 (format "Paste %d lines, which %s will run as each arrives?"
                         (1+ (cl-count ?\n text))
                         (or cooked-title "The child")))))
      (message "Paste cancelled")
    (cooked--snap-to-cursor)
    (cooked--send-paste-text (cooked--require-session) text)))

(defun cooked-paste ()
  "Paste the most recent kill.

At an input prompt this is `yank', because the pending line is being edited in
the buffer: the text lands there and can be corrected before it is submitted.

While the child owns the keyboard there is no buffer to yank into — the text is
the child's to receive, and goes to it directly.  Bracketed when the child asked
for bracketed paste, so its line editor treats the whole thing as one insertion
rather than as very fast typing; see `cooked-paste-confirm-lines' for what
happens when it did not ask.

This is the way to get Emacs' kill ring — and so the system clipboard, which
`current-kill' consults exactly as `yank' does — into a full-screen program.  A
program's own paste key pastes its own registers, which is a different thing
entirely and cannot reach anything Emacs copied.

Ends peek first when peeking, so the paste is seen landing rather than held
behind the freeze."
  (interactive)
  (cooked--resume-forwarding)
  (unless (cooked--live-session)
    (user-error "No live session"))
  (if (cooked--input-state-p)
      (call-interactively #'yank)
    (let ((text (current-kill 0)))
      (if (string-empty-p text)
          (message "Nothing to paste")
        (cooked--send-paste text)))))

(defvar xterm-store-paste-on-kill-ring)  ; term/xterm.el, loaded on a tty frame
(declare-function xterm-paste "term/xterm" (event))

(defun cooked-xterm-paste (event)
  "Paste the text a terminal frame's host terminal delivered in EVENT.

On `emacs -nw' a paste in the host terminal arrives as one `xterm-paste'
event, of the form (xterm-paste TEXT), which term/xterm.el decodes from the
bracketed-paste markers.  Its global binding, `xterm-paste', inserts TEXT
into the current buffer with `yank', called as a function, so the remap that
turns `yank' into `cooked-paste' never sees it.  Pasting into a running vim
therefore put the text into the cooked buffer instead of into vim.

At an input prompt this does what `xterm-paste' does, since the line is
being edited in the buffer.  Its `yank' marks the text as pasted, see
`cooked--mark-pasted', and `cooked--send-input-string' strips the control
bytes from it when the line is submitted.  While the child owns the keyboard
TEXT goes to it through `cooked--send-paste', bracketed if the child asked,
with the same control-byte strip as `cooked-paste'.  TEXT is put on the kill
ring first when `xterm-store-paste-on-kill-ring' says so, as `xterm-paste'
would."
  (interactive "e")
  (if (cooked--input-state-p)
      (xterm-paste event)
    (cooked--resume-forwarding)
    (unless (cooked--live-session)
      (user-error "No live session"))
    (let ((text (nth 1 event)))
      (when (and (boundp 'xterm-store-paste-on-kill-ring)
                 xterm-store-paste-on-kill-ring)
        (kill-new text))
      (unless (string-empty-p text)
        (cooked--send-paste text)))))

(defun cooked--deliver-paste (text)
  "Put TEXT on the line as a paste, wherever the line is being edited.

At an input prompt Emacs owns the line, so TEXT is inserted into the pending
input, marked as pasted by `cooked--mark-pasted', where it can still be edited
and where `cooked-send-input' will find it.  Point is kept inside the region
first, since a drop or a click can leave it on the read-only prompt.  Sending
TEXT to the child instead would type it underneath the line Emacs is showing,
and the two would be submitted together.  Otherwise the child owns the line and
TEXT goes through `cooked--send-paste', bracketed if the child asked.

This is the way in for text that does not come from the kill ring: a drop, the
primary selection, and a history entry.  Signals a `user-error' when the
child has exited, since there is no line to put anything on."
  (unless (cooked--live-session)
    (user-error "No live session"))
  (if (cooked--input-state-p)
      (progn
        (unless (cooked--input-region)
          (cooked--restore-pending-input nil))
        (when-let* ((region (cooked--input-region)))
          (goto-char (max (car region) (min (point) (cdr region)))))
        (insert (cooked--mark-pasted text)))
    (cooked--send-paste text)))

(defun cooked-mouse-yank-primary ()
  "Paste the primary selection, as a middle-click does in other terminals.

Bound in place of `mouse-yank-primary' wherever a user has put that, since
its own insertion goes into the buffer at the click whoever owns the keyboard.
While vim runs the text then sat in the cooked buffer, where the next repaint
overwrote it, and vim never saw it.  Through `cooked--deliver-paste' instead,
so at a prompt it joins the pending line at point and otherwise it reaches the
child as a paste.  \\[cooked-paste], on `mouse-2' by default, is the kill
ring's counterpart."
  (interactive)
  (cooked--resume-forwarding)
  (let ((text (gui-get-primary-selection)))
    (unless (string-empty-p text)
      (cooked--deliver-paste text))))

(defun cooked--dnd-insert-text (insert window action text)
  "Deliver a text drop on a live cooked buffer as a paste.

Around advice for `dnd-insert-text', which every port's drop handler ends
in for text, and for a URL that no `dnd-protocol-alist' entry claimed.
INSERT is the original function, called with WINDOW, ACTION and TEXT for a drop
on any other buffer.  It inserts TEXT at point in WINDOW's buffer with plain
`insert', so while a program owned the keyboard a drop landed in the
transcript rather than reaching the program.  Here it goes through
`cooked--deliver-paste', and ACTION is returned as `dnd-insert-text'
returns it."
  (let ((buffer (and (windowp window) (window-buffer window))))
    (if (and buffer (with-current-buffer buffer (cooked--live-session)))
        (with-current-buffer buffer
          (cooked--deliver-paste text)
          action)
      (funcall insert window action text))))

(with-eval-after-load 'dnd
  (advice-add 'dnd-insert-text :around #'cooked--dnd-insert-text))

;;;; Per-program key overrides

(defconst cooked--override-bytes
  '((:newline . "\n") (:return . "\r") (:meta-return . "\e\r")
    (:tab . "\t") (:escape . "\e"))
  "Bytes each named `cooked-key-overrides' action stands for.
Names rather than literals so an override can be written without anyone having
to know that Meta+Return is spelled ESC CR.")

(defconst cooked--override-encodings
  '((:kitty . kitty) (:modify-other . modify-other))
  "Protocols a `cooked-key-overrides' action can name.

Maps each to the `cooked--keys' value it stands for.

These re-spell the key that was pressed, so `<S-return>' with `:kitty' sends
`ESC [ 13;2 u' without anyone writing that out.  Unlike everything else cooked
sends, this is not backed by a negotiation -- see `cooked-key-overrides'.")

(defcustom cooked-key-overrides nil
  "Keys that mean something particular to a particular program.

An alist of (CONDITION . BINDINGS), consulted only while the child owns the
keyboard -- at a prompt Emacs owns the line, and `cooked-newline' already binds
Shift+Return there.

CONDITION is either a regexp matched against the name of the program in the
child's foreground process group -- `claude' matches whether it was started as
the session's command or typed at the session's shell -- or a function of no
arguments called in the buffer, for a test the process name cannot express
\(`cooked-title', `cooked--alt', `default-directory').

BINDINGS is an alist of (KEY . ACTION), KEY as `kbd' spells it.  ACTION is:

  a keyword naming bytes  `:newline', `:return', `:meta-return', `:tab',
                          `:escape' -- see `cooked--override-bytes'
  a protocol keyword      `:kitty' or `:modify-other', which re-spell the
                          key that was pressed in that protocol
  a string                sent to the child verbatim
  a symbol                run as an ordinary command, e.g. `cooked-newline'

Where several entries match, the first one to bind a key wins.

This exists for a program that never negotiates a keyboard protocol it still
expects -- see `cooked-key-protocol-overrides' for the reasoning, and for
Claude Code, whose Shift+Return and Shift+Tab are the reason this and it both
exist.  Empty by default now that Claude Code's own needs are covered there
instead: it takes every key it binds through the one protocol it assumes, so
nothing here has to name them one at a time.  What is left for this alist is
the narrower case a blanket protocol guess cannot cover -- a specific byte a
program wants regardless of protocol, or a key with no negotiated encoding at
all to re-spell in the first place.

Nothing here changes `cooked--keys': what cooked sends of its own accord still
follows the negotiation and nothing else, as with
`cooked-key-protocol-overrides'
-- and the same as a real one, a `:kitty' or `:modify-other' action here sends a
sequence the child never negotiated, on your say-so that it understands one
anyway."
  :type '(alist :key-type (choice (regexp :tag "Foreground program matching")
                                  (function :tag "Predicate"))
                :value-type
                (alist :key-type (string :tag "Key")
                       :value-type (choice (const :tag "Newline (LF)" :newline)
                                           (const :tag "Return (CR)" :return)
                                           (const :tag "Meta+Return (ESC CR)" :meta-return)
                                           (const :tag "Tab" :tab)
                                           (const :tag "Escape" :escape)
                                           (const :tag "Re-spell as kitty" :kitty)
                                           (const :tag "Re-spell as modifyOtherKeys"
                                                  :modify-other)
                                           (string :tag "Literal bytes")
                                           (function :tag "Command"))))
  :group 'cooked)

(defvar-local cooked--override-map nil
  "Keymap for the overrides that apply to what is running right now.")

(defvar-local cooked--override-map-alist nil
  "The `emulation-mode-map-alists' entry activating `cooked--override-map'.

Buffer-local, unlike `cooked--mouse-map-alist': the mouse map is one keymap
shared by every session and switched on with a variable, while this one is built
from whatever this buffer's child happens to be running.  nil deactivates it,
which is also how the whole feature stays inert in a buffer with no overrides.")

(defvar-local cooked--override-actions nil
  "What `cooked-send-override' should send, keyed by the key that invoked it.

The bindings could have been closures over their own bytes, but a keymap full of
anonymous functions describes itself badly: \\[describe-key] on an overridden key
should name a command you can look up.")

(defvar-local cooked--assumed-key-protocol-cache nil
  "Cached answer of `cooked--assumed-key-protocol'.

Rebuilt in `cooked--update-key-overrides', the same place and on the same
events that rebuild the override map, since both answer the same question --
what the child is running now, and whether it owns the keyboard to be asked
about at all.  Reading it straight off the alist instead ran `seq-find' over
`cooked-key-protocol-overrides' on every key this buffer ever sent.")

(defun cooked--override-applies-p (condition)
  "Whether CONDITION selects what the child is running now."
  (if (functionp condition)
      (funcall condition)
    (when-let* ((program (cooked--foreground-program)))
      (string-match-p condition program))))

(defun cooked--override-bytes-for (action event)
  "Bytes ACTION sends for EVENT, or nil if it sends none.

A protocol keyword re-spells EVENT itself, which is what saves an override from
having to write `ESC [ 13;2 u' out by hand.  `cooked--keys' is bound rather than
consulted: the override is a statement about this one program, and must not
become cooked's idea of what the child negotiated."
  (cond
   ((stringp action) action)
   ((alist-get action cooked--override-bytes))
   ((when-let* ((protocol (alist-get action cooked--override-encodings)))
      (cooked--encode-key-event event protocol)))))

(defun cooked-send-override ()
  "Send the bytes `cooked-key-overrides' gives for the key that invoked this."
  (interactive)
  (when-let* ((action (alist-get (this-command-keys-vector)
                                 cooked--override-actions nil nil #'equal))
              (bytes (cooked--override-bytes-for action last-command-event)))
    (cooked--snap-to-cursor)
    (cooked--send-to-child bytes)))

(defun cooked--build-override-map ()
  "Keymap and action table for the overrides matching what is running.
Returns nil when nothing matches, which is the common case."
  (let ((map (make-sparse-keymap))
        (actions nil)
        (any nil))
    (dolist (entry cooked-key-overrides)
      (when (cooked--override-applies-p (car entry))
        (pcase-dolist (`(,key . ,action) (cdr entry))
          (let ((keys (kbd key)))
            ;; An earlier entry wins, so a general rule can be written under a
            ;; specific one without quietly taking it over.
            (unless (lookup-key map keys)
              (setq any t)
              (if (and (symbolp action) (not (keywordp action)))
                  (define-key map keys action)
                ;; `vconcat' because `kbd' answers a string for an ASCII chord and
                ;; a vector for a symbolic key, while the lookup side is always a
                ;; vector -- and `key-parse', which would say this directly, is
                ;; newer than the Emacs this package supports.
                (push (cons (vconcat keys) action) actions)
                (define-key map keys #'cooked-send-override)))))))
    (when any (cons map actions))))

(defun cooked--update-key-overrides ()
  "Rebuild the override map for what the child is running now.

Gated exactly as `cooked--update-mouse-grab' gates the mouse, and for the same
reason: these are keys being taken away from Emacs, so they may only apply while
the child owns the keyboard.  Without that, an override on `<S-return>' would
follow the buffer to its own prompt and displace `cooked-newline'.

Also rebuilds `cooked--assumed-key-protocol-cache': a different customisation,
`cooked-key-protocol-overrides', but the same question -- what the child is
running and whether it owns the keyboard -- so it is invalidated by exactly the
events that invalidate this map."
  (let ((live (and cooked-key-overrides
                   (not (cooked--input-state-p))
                   (not (cooked--suspended-p)))))
    (pcase (and live (cooked--build-override-map))
      (`(,map . ,actions)
       (setq cooked--override-map map
             cooked--override-actions actions
             cooked--override-map-alist `((cooked--override-map . ,map))))
      (_
       (setq cooked--override-map nil
             cooked--override-actions nil
             cooked--override-map-alist nil))))
  (setq cooked--assumed-key-protocol-cache (cooked--compute-assumed-key-protocol)))

(defcustom cooked-key-protocol-overrides '(("\\`claude\\'" . kitty))
  "Protocol to assume a program speaks, for one that never negotiates one.

An alist of (CONDITION . PROTOCOL).  CONDITION is as in `cooked-key-overrides'.
PROTOCOL is `kitty' or `modify-other' -- one of the values `cooked--keys' takes
when a child negotiates one of them for real, via `CSI ? u'.

This is the blanket version of `cooked-key-overrides': rather than re-spelling
one named key, it makes `cooked-send-key' behave, for Return, Tab, Escape,
Backspace and Shift+Tab, exactly as if the child had negotiated PROTOCOL -- the
right tool once a whole program is known to accept a protocol it simply never
asks for, rather than one specific key found to need nudging around its
absence.  Consulted only while the child owns the keyboard, and applied by the
core only while the child has negotiated nothing itself: a real negotiation is
always believed over a guess about what a program probably wants, never
overridden by one.

A `cooked-key-overrides' entry for the same key still wins over this: it is
consulted first, from a keymap that sits above the ordinary passthrough map
this only ever adjusts.

The default covers Claude Code, which decides whether the kitty protocol is
available by matching TERM and TERM_PROGRAM against terminals it knows rather
than by asking: it never sends the `CSI ? u' query cooked stands ready to
answer.  So nothing is negotiated and the modified forms of Return, Tab,
Escape, Backspace and Shift+Tab are never sent -- although Claude decodes them
without difficulty once they arrive, having only ever needed to expect them,
not to have negotiated them.

The override is therefore the missing half of a negotiation nobody started.
The other way through would be to answer the sniff -- report a TERM from
Claude's list -- and cooked will not: it reports what it actually implements,
which is the whole point of shipping a terminfo entry.  This configures your
keyboard rather than misreporting cooked's identity."
  :type '(alist :key-type (choice (regexp :tag "Foreground program matching")
                                  (function :tag "Predicate"))
                :value-type (choice (const :tag "Kitty keyboard protocol" kitty)
                                    (const :tag "xterm modifyOtherKeys" modify-other)))
  :group 'cooked)

(defun cooked--compute-assumed-key-protocol ()
  "Recompute what `cooked--assumed-key-protocol' answers, ignoring the cache.

nil when nothing matches, or when the child owns nothing right now to assume it
for.  Whether the guess applies at all is the core's: a real negotiation is
always believed over it, and the core is the end that knows whether one has
happened since the last drain.  See `cooked-key-protocol-overrides'."
  (and cooked-key-protocol-overrides
       (not (cooked--input-state-p))
       (not (cooked--suspended-p))
       (cdr (seq-find (lambda (entry) (cooked--override-applies-p (car entry)))
                      cooked-key-protocol-overrides))))

(defun cooked--assumed-key-protocol ()
  "Protocol `cooked-key-protocol-overrides' assumes for what is running now.

Answered from `cooked--assumed-key-protocol-cache' rather than walking
`cooked-key-protocol-overrides' afresh: every key press asks this, by way of
`cooked--send-key-event', and `cooked--update-key-overrides' already keeps the
cache current on every event that could move the answer.  See
`cooked--compute-assumed-key-protocol' for what it holds."
  cooked--assumed-key-protocol-cache)

(provide 'cooked-keys)
;;; cooked-keys.el ends here
