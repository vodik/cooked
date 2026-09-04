;;; cooked-keys.el --- Key encoding and keymaps for cooked terminals -*- lexical-binding: t; -*-

;;; Commentary:

;; Everything between a key press and the bytes the child receives: how an Emacs
;; event is spelled in whichever protocol the child negotiated, which keys are
;; forwarded to it at all, and which are held back for Emacs.
;;
;; Not opt-in, unlike `cooked-next-error' and its neighbours; `cooked-mode'
;; requires this, exactly as it requires cooked-mouse.el and for the reason that
;; file gives: a self-contained subject that had grown too large to keep sharing
;; a file with the mode itself.  The keyboard is the same case, larger -- eleven
;; hundred lines of `cooked-mode.el', across three sections, one of which was
;; named "Suspending: peek" for the hundred lines of it that were about
;; suspending rather than for the four hundred that were keymap construction.
;; The mouse had had the treatment; the keyboard had not.
;;
;; The seam is encoding against state.  What a key *becomes* is here.  *When* a
;; map is installed is not: `cooked--refresh-keymap', `cooked--state-keymap',
;; `cooked--policy' and the hooks around them stay in cooked-mode.el with the
;; rest of the state machine.  This file builds the maps; that file decides
;; which one the buffer is wearing.  Peek is where the line is easiest to see --
;; `cooked-peek-map' is a keymap and lives here, while `cooked-toggle-peek' and
;; `cooked--resume-forwarding' are transitions and do not.  `cooked--forwarding-map'
;; sits just on this side of that line: which *spelling* of a forwarding map a
;; frame needs is a fact about how a key is written down, not about what the
;; child is doing.
;;
;; The maps are defined *below* the options that configure them, which reads
;; backwards and has to: a `defvar' that builds itself from an option's value
;; needs the option to exist first.  See `cooked--passthrough-setter', which is
;; the other half of that arrangement.

;;; Code:

(require 'cl-lib)
(require 'cooked)
(require 'cooked-util)
(require 'cooked-mouse)

;; Defined by the native core at `module-load' time, so the byte-compiler cannot
;; see them; cooked.el and cooked-mode.el declare their own sets the same way.
(declare-function cooked--bracketed-paste-p "ext:cooked-core")
(declare-function cooked--foreground-pid "ext:cooked-core")
(declare-function cooked--pid "ext:cooked-core")

;; Owned by cooked-mode.el, which requires this file.  Point management around a
;; send, the two halves of stepping out of forwarding, and the commands
;; `cooked--build-input-map' binds -- all of them state this layer only reaches
;; into, never maintains, which is the one shape a back-edge here is allowed to
;; have.
(declare-function cooked--snap-to-cursor "cooked-mode")
(declare-function cooked--resume-forwarding "cooked-mode")
(declare-function cooked--refresh-keymap "cooked-mode")
(declare-function cooked--peek-resume-and-send "cooked-mode")
(declare-function cooked-send-input "cooked-mode")
(declare-function cooked-newline "cooked-mode")
(declare-function cooked-delete-char-or-eof "cooked-mode")
(declare-function cooked-previous-input "cooked-mode")
(declare-function cooked-next-input "cooked-mode")
(declare-function cooked-beginning-of-line "cooked-mode")

;;;; Key encoding

(defconst cooked--key-encodings
  '((up          csi     "A")
    (down        csi     "B")
    (right       csi     "C")
    (left        csi     "D")
    (home        csi     "H")
    (end         csi     "F")
    (f1          ss3     "P")
    (f2          ss3     "Q")
    (f3          ss3     "R")
    (f4          ss3     "S")
    (prior       tilde   5)
    (next        tilde   6)
    (insert      tilde   2)
    (deletechar  tilde   3)
    (f5          tilde   15)
    (f6          tilde   17)
    (f7          tilde   18)
    (f8          tilde   19)
    (f9          tilde   20)
    (f10         tilde   21)
    (f11         tilde   23)
    (f12         tilde   24)
    (return      literal 13)
    (tab         literal 9)
    (escape      literal 27)
    (backspace   literal 127)
    ;; Shift+TAB is reported by Emacs as `backtab\=', not as `S-tab\=' -- see
    ;; `cooked--encode-event\=', which restores the shift `event-modifiers\=' leaves
    ;; out so this falls out of the ordinary modifier logic after all.  The
    ;; explicit fallback is the classical, un-negotiated spelling; terminfo calls
    ;; it `kcbt\='.  It is the one entry whose fallback is not simply its code
    ;; point as a character.
    (backtab     literal 9 "\e[Z"))
  "Every non-character key cooked speaks for, as (SYMBOL KIND PAYLOAD [FALLBACK]).

One table rather than the five parallel ones this replaced, and the reason is
worth stating because the five looked like a reasonable decomposition.  Four of
them named how a key is spelled *modified* -- CSI final, SS3 final, tilde
number, code point -- and the fifth, `cooked--special-keys\=', listed the
unmodified spelling for all twenty-seven.  But that fifth table was derivable
from the other four in every single entry, so it was a denormalization
maintained by hand; and because `cooked--encode-event\=' consulted it last, after
the four tables that between them covered all twenty-seven keys, its clause
there could never fire at all.  A table nothing can reach is not a fallback, it
is a place for a mistake to live.

KIND says both how the key is spelled and what a modifier does to it:

  `csi\='      PAYLOAD is the final byte.  Unmodified, \\='ESC [ FINAL\\=', or
              \\='ESC O FINAL\\=' under DECCKM; modified, \\='ESC [ 1 ; MOD FINAL\\='.
  `ss3\='      PAYLOAD is the final byte.  Unmodified \\='ESC O FINAL\\=', and
              modified \\='ESC [ 1 ; MOD FINAL\\=' -- F1-F4 leave SS3 behind the
              moment they are modified.
  `tilde\='    PAYLOAD is the number N in \\='ESC [ N ~\\=', which takes a modifier
              as \\='ESC [ N ; MOD ~\\='.
  `literal\='  PAYLOAD is the code point for the negotiated encodings, and the
              unmodified spelling is that code point as a character unless
              FALLBACK says otherwise.  See `cooked--encode-literal\=' for why a
              modifier here is spelled out only when the child opted in.

`cooked--key-sequence\=' derives the unmodified spelling, so the two can no
longer disagree.  The symbols are also exactly the set `cooked--raw-keymap\='
binds explicitly, which is the table\='s other consumer.")

(defun cooked--key-sequence (entry)
  "The unmodified, un-negotiated escape sequence ENTRY names.

ENTRY is a `cooked--key-encodings\=' row.  This is what used to be written out a
second time in `cooked--special-keys\='; deriving it is what keeps the two
spellings of one key from drifting apart."
  (pcase entry
    (`(,_ csi ,final) (concat "\e[" final))
    (`(,_ ss3 ,final) (concat "\eO" final))
    (`(,_ tilde ,n) (format "\e[%d~" n))
    (`(,_ literal ,_ ,fallback) fallback)
    (`(,_ literal ,code) (string code))))

(defun cooked--modifier-param (mods)
  "Return xterm's modifier parameter for MODS: 1 plus a bit per held modifier."
  (+ 1
     (if (memq 'shift mods) 1 0)
     (if (memq 'meta mods) 2 0)
     (if (memq 'control mods) 4 0)))

(defun cooked--encode-literal (entry code param mods)
  "Encode the `literal' key ENTRY with modifiers, given its code point CODE.

CODE is the kitty/modifyOtherKeys code point, and PARAM the xterm modifier
parameter, with MODS the modifier list.  Falls back to `cooked--key-sequence'
when the child has negotiated nothing, since that is what every terminal has
always sent and what every program still understands -- a bare byte for most
keys here, but `backtab' falls back to its own classical, three-byte spelling
instead."
  (let ((seq (cooked--key-sequence entry)))
    (cond
     ((= param 1) (if (memq 'meta mods) (concat "\e" seq) seq))
     ((eq cooked--keys 'modify-other) (format "\e[27;%d;%d~" param code))
     ((eq cooked--keys 'kitty) (format "\e[%d;%du" code param))
     ;; Nothing negotiated: meta has a classical spelling, the rest do not.
     ((memq 'meta mods) (concat "\e" seq))
     (t seq))))

(defun cooked--encode-event (event)
  "Bytes the child should receive for EVENT, or nil.

Note that Emacs reports a capital letter as shift plus the lowercase one, so the
shift modifier has to be applied here — reading `event-basic-type' alone turns
every capital into a lowercase letter."
  ;; `event-modifiers' first, and not merely for readability: on a symbolic event
  ;; such as `S-up' it is what parses and caches `event-symbol-elements', which
  ;; `event-basic-type' only reads.  Ask the other way round and the first press of
  ;; every modified key decodes as nil.
  ;;
  ;; One lookup and one dispatch on the entry's KIND.  This used to be five
  ;; tables tried in order under a `cl-block', which needed a paragraph of
  ;; comment to explain why the ordering was safe -- the rule being that the
  ;; first table holding a key is the one that answers for it, which nothing
  ;; stated and only the tables' contents made true.  With one entry per key
  ;; there is no ordering left to get wrong: a key is in the table or it is not,
  ;; and if it is not it falls through to the plain-character case below.
  (let* ((mods (event-modifiers event))
         (basic (event-basic-type event))
         ;; `backtab' is the mirror image of the capital-letter case above: Emacs
         ;; bakes its shift into the base symbol and reports none in `mods' at
         ;; all, for `backtab' alone or with other modifiers held alongside it
         ;; (`C-backtab' still reports only `(control)').  Restore it before
         ;; `param' is computed, or the `literal' entry for `backtab' has a code
         ;; point that no modifier ever reaches.
         (mods (if (eq basic 'backtab) (cons 'shift mods) mods))
         (param (cooked--modifier-param mods))
         (modified (> param 1)))
    (pcase (assq basic cooked--key-encodings)
      (`(,_ csi ,final)
       (cond (modified (format "\e[1;%d%s" param final))
             (cooked--app-cursor (concat "\eO" final))
             (t (concat "\e[" final))))
      ;; F1-F4 leave SS3 behind the moment they are modified.
      (`(,_ ss3 ,final)
       (if modified (format "\e[1;%d%s" param final) (concat "\eO" final)))
      (`(,_ tilde ,n)
       (if modified (format "\e[%d;%d~" n param) (format "\e[%d~" n)))
      ((and `(,_ literal ,code . ,_) entry)
       (cooked--encode-literal entry code param mods))
      ;; Not in the table at all: a plain character, or nothing we can spell.
      (_
       (when (characterp basic)
         (let ((char (cond ((memq 'control mods) (logand (upcase basic) #x1f))
                           ((memq 'shift mods) (upcase basic))
                           (t basic))))
           (if (memq 'meta mods) (concat "\e" (string char)) (string char))))))))

(defun cooked-send-key ()
  "Send the key that invoked this command straight to the child.

Bound under whatever `cooked--keys' says was actually negotiated, unless
`cooked-key-protocol-overrides' has a program-wide guess to stand in for a
negotiation that never happened -- see `cooked--assumed-key-protocol'."
  (interactive)
  (let ((cooked--keys (or (cooked--assumed-key-protocol) cooked--keys)))
    (when-let* ((bytes (cooked--encode-event last-command-event)))
      (cooked--snap-to-cursor)
      (cooked--send-to-child bytes))))

(defun cooked-send-meta-key ()
  "Send the key that invoked this command to the child, with Meta applied.

Bound only under the ESC prefix of `cooked--meta-overlay\=', where a Meta chord
arrives as two events and the modifier is gone by the time a command runs:
`M-t\=' is looked up as `ESC t\=', so `last-command-event\=' is a bare `?t\='.  Put
the modifier back and hand the reconstructed event to `cooked-send-key\=', so
that a negotiated protocol spells it as a modifier parameter rather than as a
leading ESC -- which is the whole reason not to simply send \"\\e\" and the key.

`event-apply-modifier\=' is what Emacs\=' own `event-apply-meta-modifier\=' uses,
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
  "Minibuffer map for `cooked-send-string\='.

`RET\=' sends what has been typed, so the newline a here-document or a
multi-line send needs has nowhere else to come from; `S-RET\=' inserts one, the
same split every chat client makes.

Both spellings, unconditionally, because nothing here can tell whether the
first will arrive.  This is Emacs\=' own keyboard, not the child\='s: what
`cooked--keys\=' negotiated says what the program *inside* the terminal may
send us, and has no bearing on whether the terminal Emacs is itself running in
reports a shift modifier on `RET\='.  A GUI frame does; a terminal one does
only if it speaks a protocol that can, which is between Emacs and its own
terminal.  So `M-RET\=' is bound alongside as the spelling that always
survives.  `C-j\=' is not: `minibuffer-local-map\=' binds it to
`exit-minibuffer\=', and taking that away would be a worse trade than the one
it fixes.  `C-q C-j\=' inserts a newline anywhere and is unaffected by either.")

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

(defun cooked--bracketed-paste (text)
  "TEXT wrapped in the bracketed-paste markers, made safe to wrap.

Any end marker inside TEXT is dropped.  One left in would close the bracket
early and hand whatever followed it to the child as if it had been typed —
which is how a copied line runs something you never read.  The child is told
where the paste ends; nothing in the middle gets to say otherwise."
  (concat "\e[200~" (string-replace "\e[201~" "" text) "\e[201~"))

(defun cooked--send-paste (text)
  "Hand TEXT to the child as a paste."
  (cond
   ((cooked--bracketed-paste-p cooked--session)
    (cooked--snap-to-cursor)
    (cooked--send-to-child (cooked--bracketed-paste text)))
   ((and cooked-paste-confirm-lines
         (string-search "\n" text)
         (not (y-or-n-p
               (format "Paste %d lines, which %s will run as each arrives?"
                       (1+ (cl-count ?\n text))
                       (or cooked--title "The child")))))
    (message "Paste cancelled"))
   (t
    (cooked--snap-to-cursor)
    ;; Newlines go as carriage returns because that is what the Return key
    ;; transmits, and a line editor bound to CR is what is reading them.
    (cooked--send-to-child (string-replace "\n" "\r" text)))))

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
\(`cooked--title', `cooked--alt', `default-directory').

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

(defvar-local cooked--foreground-name nil
  "Cached (PID . NAME) for the child's foreground process group.
`process-attributes' is not free, and the pid is what says whether it is stale.")

(defun cooked--foreground-program ()
  "Name of the program in the child's foreground process group, or nil.

Not the session's own command: that is usually a shell, and what the user is
looking at is whatever the shell put in the foreground.  So a `claude' typed at
a cooked shell answers `claude' here, which is the case an override has to be
able to name."
  (when-let* ((session (cooked--live-session))
              (pid (cooked--foreground-pid session)))
    (if (eq pid (car cooked--foreground-name))
        (cdr cooked--foreground-name)
      (cdr (setq cooked--foreground-name
                 (cons pid (alist-get 'comm (process-attributes pid))))))))

(defvar-local cooked--foreground-label nil
  "Name of the program the child last had in the foreground, for the mode line.

Maintained from `cooked--refresh-keymap\=' rather than read when the mode line
asks, for the same reason `cooked--attention\=' is: `cooked--mode-line\=' runs
from an `:eval\=' on every redisplay, and the answer costs a `tcgetpgrp\=' and,
on a miss, a `process-attributes\=' -- which its own cache exists because it is
not free.  Recomputing that per frame to render one word would be paying a
syscall for a string that changes when the policy does.

Every transition worth naming already passes through that refresh: termios
flipping as a full-screen program takes the tty, and an OSC 133 `C\=' as a
marked command starts.  What it misses is one quiet command following another
at an unmarked shell, where nothing changes state -- so the label is a
best-effort hint, and is allowed to be.")

(defun cooked--update-foreground-label ()
  "Refresh `cooked--foreground-label\=' for what the child is running now.

Nil when the foreground process group is the session\='s own child -- the shell
cooked spawned, sitting at its prompt.  Naming it there would put `zsh\=' in the
mode line for the whole life of every session, which is a word that is always
true and never news.

Deliberately *not* keyed on who owns the line.  A canonical tty is not a shell
prompt: `cat\=' and `sleep\=' hold one too, and cooked reads those as `edit\='
because they genuinely are a line being edited.  Those are exactly the cases
where the program\='s name is the only thing on screen saying what the line will
be read by -- so the test is which process, not which policy."
  (setq cooked--foreground-label
        (and cooked--session
             (let ((foreground (cooked--foreground-pid cooked--session)))
               (and foreground
                    (not (eql foreground (cooked--pid cooked--session)))
                    (cooked--foreground-program))))))

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
   ((when-let* ((encoding (alist-get action cooked--override-encodings)))
      (let ((cooked--keys encoding))
        (cooked--encode-event event))))))

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
follow the buffer to its own prompt and displace `cooked-newline'."
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
             cooked--override-map-alist nil)))))

(defcustom cooked-key-protocol-overrides '(("\\`claude\\'" . kitty))
  "Protocol to assume a program speaks, for one that never negotiates one.

An alist of (CONDITION . PROTOCOL).  CONDITION is as in `cooked-key-overrides'.
PROTOCOL is `kitty' or `modify-other' -- one of the values `cooked--keys' takes
when a child negotiates one of them for real, via `CSI ? u'.

This is the blanket version of `cooked-key-overrides': rather than re-spelling
one named key, it makes `cooked-send-key' behave, for every key with a
`literal' encoding in `cooked--key-encodings', exactly as if the child had
negotiated PROTOCOL -- the right tool once a whole program is known to accept
a protocol it simply
never asks for, rather than one specific key found to need nudging around its
absence.  Consulted only while the child owns the keyboard, and only when
`cooked--keys' is still `legacy': a real negotiation is always believed over a
guess about what a program probably wants, never overridden by one.

A `cooked-key-overrides' entry for the same key still wins over this: it is
consulted first, from a keymap that sits above the ordinary passthrough map
this only ever adjusts.

The default covers Claude Code, which decides whether the kitty protocol is
available by matching TERM and TERM_PROGRAM against terminals it knows rather
than by asking: it never sends the `CSI ? u' query cooked stands ready to
answer.  So `cooked--keys' stays `legacy' and the modified forms of the
`literal' keys in `cooked--key-encodings' are never sent -- although Claude
decodes them without
difficulty once they arrive, having only ever needed to expect them, not to
have negotiated them.

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

(defun cooked--assumed-key-protocol ()
  "Protocol `cooked-key-protocol-overrides' assumes for what is running now.

nil when nothing matches, when the child owns nothing right now to assume it
for, or when `cooked--keys' says a real negotiation already answered the
question -- see `cooked-key-protocol-overrides'."
  (and cooked-key-protocol-overrides
       (eq cooked--keys 'legacy)
       (not (cooked--input-state-p))
       (not (cooked--suspended-p))
       (cdr (seq-find (lambda (entry) (cooked--override-applies-p (car entry)))
                      cooked-key-protocol-overrides))))

(defconst cooked--escape-key ?\C-c
  "Prefix reserved for cooked's own commands while the child owns the keyboard.
Everything `cooked-raw-map' and `cooked-alt-map' cover is otherwise forwarded
verbatim, ESC included, so \\`M-x' reaches the child as ESC x — exactly as in
any other terminal.  \\`C-c M-x' is the way back out; see `cooked-meta-x'.
On a graphical frame, where a Meta chord is one event rather than two bytes,
that takes a keymap of its own -- see `cooked--build-meta-overlay'.

`cooked-semi-map' is the exception, and deliberately so: it keeps ESC and the
whole Meta space for Emacs, which is what makes evil's insert state a state you
can leave.  See `cooked-semi-exceptions'.")

(defun cooked-meta-x ()
  "Run \\`M-x' in Emacs rather than sending it to the child.

While the child owns the keyboard every key is forwarded, ESC included, so plain
\\`M-x' arrives at the child as ESC x — which is what you want inside vim, and
not at all what you want when you meant Emacs.  \\`C-c M-x' is the escape hatch.

Whatever \\`M-x' is globally bound to is what runs, so `counsel-M-x', `helm-M-x'
and the rest keep working."
  (interactive)
  (let ((command (or (global-key-binding (kbd "M-x")) #'execute-extended-command)))
    (setq this-command command)
    (call-interactively command)))

;;;; The maps the child is typed through
;;
;; Four passthrough maps and a peek map, all built by one builder from one
;; question: which of the 0-127 range does this state keep for Emacs?  `alt' and
;; `command' keep nothing but `C-c', because both are positive signals about
;; what is running; `raw' and `semi' keep a customizable handful, because one is
;; a guess and the other is a state the user chose.  `cooked--state-keymap' in
;; cooked-mode.el is what picks between them.
;;
;; The 0-127 range is the whole question only because a terminal frame spells
;; every key inside it.  A graphical frame does not, so the three maps that
;; forward everything are worn through `cooked--forwarding-map', which answers
;; with a child of the map that binds the Meta space as well.

(defun cooked--exception-code (key)
  "The character code KEY names, signalling an error if it does not name one.

Only a single, unmodified control character in the 0-127 range is meaningful
here: passthrough is a raw-byte forwarding loop over exactly that range, not a
general keymap, so a modified chord such as `M-x' would silently do nothing
even if accepted -- see `cooked-raw-exceptions' for why."
  (let ((keys (kbd key)))
    (unless (and (stringp keys) (= (length keys) 1) (< (aref keys 0) 128))
      (error "cooked: %S does not name a single unmodified control character" key))
    (aref keys 0)))

(defun cooked--build-passthrough-map (exceptions &optional reserve-meta)
  "A keymap that forwards to the child, except EXCEPTIONS and `C-c'.
EXCEPTIONS is a list of character codes, as from `cooked--exception-code';
each is simply left unbound here, so it falls through to whatever
`cooked-mode-map'/`comint-mode-map'/`global-map' -- or `evil', if it has
installed a higher-priority keymap of its own -- would otherwise do with it.

With RESERVE-META, ESC and every Meta-modified key are left unbound too.  That
is one exception expressed as a rule rather than a list, and it has to be:
`kbd' spells Meta as a modifier bit on a GUI frame and as a leading ESC on a
terminal, so no list of character codes can name `M-x' in both -- while leaving
ESC itself unbound makes Emacs' own `meta-prefix-char' handling the thing that
answers, in whichever spelling the frame produces.  The cost is the one thing
ESC is otherwise good for here: a forwarded ESC has no latency, and a prefix
key waits.  See `cooked-semi-map', which is where that trade is worth making.

Without it the Meta space is not bound here either, for the same reason read
the other way: ESC being a key of its own is what stops it being the prefix
`M-t' would have to be stored under.  That is invisible on a terminal frame,
where Meta chords arrive as two forwarded bytes, and is why
`cooked--build-meta-overlay' exists for the frame where it is not."
  (let ((map (make-sparse-keymap)))
    (define-key map [remap self-insert-command] #'cooked-send-key)
    (dolist (code (number-sequence 0 127))
      (unless (or (eq code cooked--escape-key)
                  (and reserve-meta (eq code meta-prefix-char))
                  (memq code exceptions))
        (define-key map (vector code) #'cooked-send-key)))
    ;; Bind the modified variants explicitly, not for completeness but for
    ;; correctness: when `S-return' has no binding Emacs shift-translates it to
    ;; `return' and runs *that* binding, with `last-command-event' already flattened.
    ;; By the time `cooked-send-key' looks, the shift is gone and unrecoverable.
    (dolist (entry cooked--key-encodings)
      (dolist (prefix '("" "S-" "C-" "M-" "C-S-" "M-S-" "C-M-"))
        (unless (and reserve-meta (string-search "M-" prefix))
          (define-key map (vector (intern (concat prefix (symbol-name (car entry)))))
                      #'cooked-send-key))))
    ;; Everything else cooked binds under `C-c' -- its own commands, and the
    ;; ones that write to the child out of band -- lives on `cooked-mode-map'
    ;; instead of here, so it survives peeking too; see the `set-keymap-parent'
    ;; block below `define-derived-mode'.
    (dolist (event cooked--mouse-events)
      (define-key map (vector event) #'cooked-mouse-event))
    map))

(defvar cooked--meta-overlays nil
  "Alist of (MAP . OVERLAY), the cache behind `cooked--forwarding-map\='.

Keyed by the map object rather than by name, and safe to keep across a
customization because `cooked--replace-keymap\=' rebuilds a map\='s bindings
without replacing the map itself -- so a cached overlay\='s parent stays the
map the user just changed.")

(defun cooked--build-meta-overlay (map)
  "A child of MAP that forwards the Meta space as well.

MAP itself cannot carry that space.  `define-key\=' and `lookup-key\=' both
translate a Meta character into ESC plus the character, so `M-t\=' is stored and
found under an ESC prefix and nowhere else -- which means binding the Meta
space at all and forwarding ESC as a key of its own are mutually exclusive
within one keymap.  On a terminal frame that costs nothing: Escape and `t\=' are
two separately-forwarded bytes there, and the child sees `ESC t\=' either way.
On a graphical frame `M-t\=' is a single event, unbound by MAP, and reaches
Emacs\=' own binding for it instead -- which is the bug this exists to fix.

So the overlay makes ESC the prefix, and gives the Escape key back its
zero-latency spelling through `[escape]\=' -- the symbol a graphical frame
actually sends, which only decays to a bare ESC byte when nothing binds it.
`ESC O\=' and `ESC [\=' are left out of the prefix map, as `vterm\=' and `eat\='
also leave them out: they begin the escape sequences every other key arrives
as, and a binding here would swallow one that had not been decoded yet.

The whole Meta space forwards, MAP\='s exceptions included.  Those name
unmodified control characters -- `C-g\=', `C-u\=' -- and reserving `M-C-g\='
along with them would take a key from the child on the strength of a binding
Emacs does not have."
  (let ((overlay (make-sparse-keymap))
        (esc (make-sparse-keymap)))
    (dolist (code (number-sequence 0 127))
      (unless (memq code '(?O ?\[))
        (define-key esc (vector code) #'cooked-send-meta-key)))
    (define-key overlay (vector meta-prefix-char) esc)
    (define-key overlay [escape] #'cooked-send-key)
    (set-keymap-parent overlay map)
    overlay))

(defun cooked--forwarding-map (map)
  "MAP as it should be worn on the selected frame.

MAP itself on a terminal frame, where it already forwards the Meta space a
byte at a time; its `cooked--build-meta-overlay\=' child on a graphical frame,
where it does not.  Asked at `use-local-map\=' time by `cooked--state-keymap\=',
so a buffer shown on both frame types at once wears whichever answer the last
refresh reached -- the alternative being to pay the overlay\='s one real cost,
Escape waiting for a Meta chord, on the terminal frames that never needed it."
  (if (not (display-graphic-p))
      map
    (or (cdr (assq map cooked--meta-overlays))
        (let ((overlay (cooked--build-meta-overlay map)))
          (push (cons map overlay) cooked--meta-overlays)
          overlay))))

(defun cooked--replace-keymap (map fresh)
  "Give MAP the bindings of FRESH, keeping MAP\='s own identity.

Every map in this file is reachable from a variable that other maps have as
their parent and that `cooked--state-keymap\=' hands to `use-local-map\=', so a
`:set\=' that rebuilt one by assigning a new keymap would leave every one of
those pointing at the old object.  Replacing the bindings in place is what lets
`cooked-raw-exceptions\=' and friends be customised in a running session.

`set-keymap-parent\=' stores the parent as the list\='s own terminating cdr
rather than in a separate slot, so a plain `(setcdr map (cdr fresh))\=' would
silently drop it; save and restore it around the replacement."
  (let ((parent (keymap-parent map)))
    (setcdr map (cdr fresh))
    (set-keymap-parent map parent)))

(defun cooked--passthrough-setter (map &optional reserve-meta)
  "A `defcustom\=' `:set\=' rebuilding MAP as a passthrough map for its value.

The value is a list of key strings naming the control characters to keep for
Emacs; RESERVE-META means what it does in `cooked--build-passthrough-map\='.
MAP is named rather than passed, and checked for at call time, because the maps
are defined below the options that configure them -- the option has to exist
first for the `defvar\=' to read it."
  (lambda (symbol value)
    (set-default symbol value)
    (when (and (boundp map) (keymapp (symbol-value map)))
      (cooked--replace-keymap
       (symbol-value map)
       (cooked--build-passthrough-map (mapcar #'cooked--exception-code value)
                                      reserve-meta)))))

(defcustom cooked-raw-exceptions '("C-g" "C-x" "C-h" "C-u" "C-l")
  "Keys kept for Emacs during a raw read outside the alternate screen.

During such a read -- `cooked--policy' returns `raw' -- these stay bound to
their ordinary Emacs command instead of forwarding to the child.

Only in `raw', which is now the degraded state: with the OSC 133 integration
working the policy is `command' instead, and that keeps nothing back -- see
`cooked-command-map'.  This list is the hedge for a session where the shell
never spoke.

`raw' is treated less aggressively than `alt' (see `cooked-alt-map', which has
no equivalent list) because it is a fuzzier state: non-shell REPLs with their
own raw-mode line editors, single-keypress prompts, and -- the case that
matters most -- any shell session without cooked's OSC 133 integration wired
up, where `cooked--policy' cannot tell a raw program from a shell editing its
own prompt line and must guess `raw'.  In that last case the user is, from
their own point of view, just sitting at an ordinary prompt, so losing the
universal quit key outright is a worse trade than reserving a handful of
control characters most raw programs do not need for themselves.

Each entry names a single control character via `kbd', e.g. \"C-g\".  \\`C-y\=' is
deliberately not offered here even though it would otherwise be a plausible
candidate: it is both vim's scroll-up-a-line and readline's own yank, real
bindings a user relying on the child is actively using.  `M-x'/`M-o'/`M-y'
are not offerable at all, for a different reason -- they are Meta-modified
letters, which this list has no way to reach in the first place: a bare ESC
byte is forwarded the instant it is pressed, for the sake of a real
terminal's Escape key having no latency, so on a terminal frame `ESC' and the
letter that follows are two independently-forwarded bytes before Emacs' own
Meta-prefix logic ever runs.  A graphical frame reaches the same place by a
different route, `cooked--build-meta-overlay' binding the Meta space the one
way a keymap can.  `C-c M-x' remains the one escape hatch guaranteed to work
regardless of frame type.

`cooked-send-literal-key' (\\`C-c C-q') sends any one key through to the child
regardless of this list, for a raw program that wants one of these keys back."
  :type '(repeat string)
  :set (cooked--passthrough-setter 'cooked-raw-map)
  :group 'cooked)

(defvar cooked-raw-map
  (cooked--build-passthrough-map (mapcar #'cooked--exception-code cooked-raw-exceptions))
  "Keymap while the child is doing a raw, non-alt-screen read.")

(defvar cooked-command-map
  (cooked--build-passthrough-map nil)
  "Keymap while the shell has told us a command is running.

No exceptions, for the same reason `cooked-alt-map' has none: this is a
positive signal rather than a guess.  `cooked-raw-exceptions' exists to hedge
the case where cooked cannot tell a raw program from a shell editing its own
prompt line, and OSC 133 removes that doubt -- so `C-u' and `C-l' go to the
program that asked for them, as they would in any other terminal.  See
`cooked--policy'.")

(defvar cooked-alt-map
  (cooked--build-passthrough-map nil)
  "Keymap while the child holds the alternate screen.

Deliberately has no exceptions, customizable or otherwise, beyond `C-c': a
full-screen program can plausibly want any key for itself, including
`C-g'/`C-x'/`C-u'/`C-h' if the program happens to be `emacs -nw' or `vim'
itself.  `cooked-toggle-peek' (or, for `evil' users, the ordinary `C-z' escape
to `evil-emacs-state') is the way to reach Emacs here, rather than a static
list that would collide with whatever the program wants those keys for.")

(defcustom cooked-semi-exceptions '("C-g" "C-x" "C-h" "C-u" "C-l")
  "Control characters `cooked-semi-map' keeps for Emacs.

The same idea as `cooked-raw-exceptions', asked in a different place: that
list hedges a state cooked is unsure about, this one describes a state the
user has chosen.  ESC and the whole Meta space are held back as well, and are
not listed here -- see `cooked-semi-map'.

`cooked-send-literal-key' (\\`C-c C-q') sends any one of these through to the
child anyway, for the program that wants it back."
  :type '(repeat string)
  :set (cooked--passthrough-setter 'cooked-semi-map t)
  :group 'cooked)

(defvar cooked-semi-map
  (cooked--build-passthrough-map
   (mapcar #'cooked--exception-code cooked-semi-exceptions) t)
  "Keymap for forwarding that stops short of taking Emacs away.

The other passthrough maps answer \"the child needs every key\" and reserve `C-c'
only, which is right for a full-screen program and wrong for the state an
`evil' user spends most of their time in.  Insert state is supposed to be a
state you can leave: if ESC forwards, the way out is gone, and if every Meta
chord forwards, so is `M-x' and so is the non-normal leader most `evil'
configurations put on `M-SPC'.

So this map holds back three things: `cooked-semi-exceptions', ESC, and --
because ESC unbound is what makes Emacs treat it as `meta-prefix-char' again
-- the entire Meta space, without naming a key of it.  Everything else still
goes to the child, `C-a'/`C-e'/`C-k'/`C-r' included, which is the half that
matters: those are readline's and vim's, and a rule of \"Emacs wins wherever
Emacs has a binding\" would have taken all of them, `global-map' binding
almost every control character.  That is the same conclusion `vterm' and
`eat' reached -- `vterm-keymap-exceptions' and `eat-semi-char-non-bound-keys'
are both explicit lists over an otherwise total map, for this reason.

The cost is ESC's latency: unbound here, it waits to see whether a Meta chord
follows.  That is why the full maps keep forwarding it instead, and why this
map is not the default anywhere.  `cooked--build-meta-overlay' makes ESC a
prefix too, but only on a graphical frame and only for characters, where the
Escape key arrives as `escape' and is bound alongside; here the point is for
ESC to reach Emacs, so there is nothing to bind it to.

\\`C-c C-q' is the way through for any one key this map keeps --
`cooked-send-literal-key' reads the event itself rather than looking it up
here.")

(defvar cooked-peek-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap self-insert-command] #'cooked--peek-resume-and-send)
    (define-key map (kbd "RET") #'cooked--peek-resume-and-send)
    (define-key map (kbd "<return>") #'cooked--peek-resume-and-send)
    map)
  "Keymap while forwarding is suspended, in `still' or `frozen'.

A child of `cooked-mode-map', not `cooked-mode-map' itself: binding the
`self-insert-command' remap there would also reach `cooked-input-map', which
needs ordinary self-insertion to keep editing pending input at a real prompt.
Typing here can only mean the child is wanted back, so it ends peek and
forwards the key that was pressed instead, same as `cooked-raw-map'/
`cooked-alt-map' would have without the interruption -- see
`cooked--peek-resume-and-send'.  Everything else -- motion, search, yanking a
selection as a copy, `cooked-toggle-fold' -- falls through to `cooked-mode-map'
and `comint-mode-map' beneath it exactly as it always did.")

(defun cooked-send-literal-key ()
  "Send the next key to the child exactly, regardless of what it is bound to.

`cooked-raw-exceptions' (and, always, `C-c') keep some keys for Emacs while
the child owns the keyboard; this is the way back the other direction, for a
child that wants one of those keys for itself -- a readline-based REPL's own
\\`C-u\=', say.  Reaches \\`C-c\=' too: \\`C-c C-q C-c\=' sends a literal \\`C-c\=' byte.

Bound on `cooked-mode-map', so it also reaches the child while peeking -- ending
peek first, so the result is seen immediately -- but refuses once Emacs owns
the line -- see `cooked-send-string', which shares the reasoning."
  (interactive)
  (cooked--resume-forwarding)
  (when (cooked--input-state-p)
    (user-error "Emacs already owns the line; type directly instead"))
  (let* ((cooked--keys (or (cooked--assumed-key-protocol) cooked--keys))
         (bytes (cooked--encode-event (read-key "Send key: "))))
    (when bytes
      (cooked--snap-to-cursor)
      (cooked--send-to-child bytes))))

;;;; The map Emacs owns the line through

(defun cooked--build-input-map (delegated)
  "A fresh input-line keymap, with DELEGATED keys handed to the child.

Spelled as a builder rather than a literal for the same reason
`cooked--build-passthrough-map\=' is: `cooked-delegate-keys\=' can change at any
time, and rebuilding is the only way to put a key back that used to be
delegated.  Unbinding it instead would leave `TAB\=' bound to nothing rather
than to `completion-at-point\='."
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'cooked-send-input)
    (define-key map (kbd "<S-return>") #'cooked-newline)
    (define-key map (kbd "C-d") #'cooked-delete-char-or-eof)
    (define-key map (kbd "TAB") #'completion-at-point)
    (define-key map (kbd "M-p") #'cooked-previous-input)
    (define-key map (kbd "M-n") #'cooked-next-input)
    ;; The remap rather than `C-a' itself, so that whatever key a user has put
    ;; start-of-line on reaches it, and so that nothing is claimed in the maps
    ;; the child is being forwarded through -- `C-a' there is readline's own
    ;; start-of-line, or tmux's prefix, and it must arrive untouched.
    (define-key map [remap move-beginning-of-line] #'cooked-beginning-of-line)
    ;; Last, so a delegated key wins over the binding it replaces -- which is the
    ;; point of naming it.
    (dolist (key delegated)
      (define-key map (kbd key) #'cooked-delegate-this-key))
    map))

(defvar cooked-input-map
  ;; `cooked-delegate-keys' is defined below and cannot be read here; its `:set'
  ;; is what keeps the two in step from load onwards.
  (cooked--build-input-map '("C-r"))
  "Keymap while Emacs owns the input line.

Cooked's own `C-c'-prefixed commands (interrupt, EOF, paste, and the rest)
are not repeated here -- they live on `cooked-mode-map', this map's parent,
so the same set reaches `cooked-raw-map'/`cooked-alt-map' and a bare peek
without being declared three times over.")

(defun cooked-delegate-key (key)
  "Hand the pending input to the child\='s line editor, then send KEY to it.

The primitive behind `cooked-delegate-keys\=', and deliberately not a completion
feature: nothing here knows what KEY means.  Send `C-r\=' and you get fzf or
atuin; send the up arrow and you get the shell\='s own history, with
`share_history\=', `zsh-histdb\=' and every `bindkey\=' the user has
accumulated.  That is worth more than any of it could be reimplemented for,
because `comint-input-ring\=' here is fed only by `cooked--history-record\='
from what was typed in *this* buffer and so starts empty every session.

Three things have to happen in this order.

Ownership is dropped *first*.  The line is about to be echoed by the shell, and
a buffer that still believes it owns an input region would render it a second
time on top.  The text is left in place rather than deleted, for the reason
`cooked-send-input\=' leaves it: the echo redraws identical characters over the
same cells and nothing moves, where deleting it would empty the row for the one
redisplay it takes to come back.

The *whole* line is sent, not the part before point.  Sending the prefix would
silently drop whatever followed the cursor, and the left-arrows that avoid it
cost one byte each.

Then KEY, once the shell\='s cursor is back where the user\='s was."
  (unless (cooked--input-state-p)
    (user-error "The child already owns the line"))
  (pcase-let* ((`(,start . ,end) (cooked--input-region))
               (text (buffer-substring-no-properties start end))
               (after (- end (max start (min (point) end)))))
    (cooked--clear-input-region)
    (setq cooked--delegated t)
    (cooked--refresh-keymap)
    (cooked--send-to-child
     (concat text (apply #'concat (make-list after "\e[D")) key))))

(defun cooked-delegate-this-key ()
  "Delegate the pending input and send the key that invoked this command.
See `cooked-delegate-key\=' and `cooked-delegate-keys\='."
  (interactive)
  (let ((cooked--keys (or (cooked--assumed-key-protocol) cooked--keys)))
    (when-let* ((bytes (cooked--encode-event last-command-event)))
      (cooked-delegate-key bytes))))

(defcustom cooked-delegate-keys '("C-r")
  "Keys that hand the line to the child\='s line editor before being sent.

Each is a `kbd\=' string, bound in `cooked-input-map\=' -- so they apply only
where Emacs owns the line, which is the only place there is anything to hand
over.

`C-r\=' is the default because reverse history search is the clearest case for
delegating: the flow is search, accept, Enter, so the line goes back to the
shell at a point where Emacs editing was not going to be wanted again anyway,
and the alternative is a history ring that knows nothing of the shell\='s.

`TAB\=' is deliberately *not* here.  Delegation is a one-way door for the rest
of the line, and losing the Emacs input region must never be a side effect of a
key pressed fifty times an hour; `TAB\=' stays `completion-at-point\=' at every
level, and what answers it changes with the tier while what it means does not.
Putting it here is supported and reasonable -- it is how a shell with marks but
no completion channel reaches `git checkout <TAB>\=' -- but it should be chosen."
  :type '(repeat string)
  :set (lambda (symbol value)
         (set-default symbol value)
         (when (and (boundp 'cooked-input-map) (keymapp cooked-input-map))
           (cooked--replace-keymap cooked-input-map
                                   (cooked--build-input-map value))))
  :group 'cooked)

(provide 'cooked-keys)
;;; cooked-keys.el ends here
