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
(require 'cooked-peek)

(cooked--declare-core)

;;;; Key encoding

(defconst cooked--key-encodings
  `((up          csi     "A")
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
    (backtab     literal 9 ,(cooked--csi "Z"))
    ;; `begin\=' is here for the keypad's centre key rather than for itself: no
    ;; ordinary keyboard sends it, but `kbeg\=' is what terminfo calls that key
    ;; and this is the row `kp-begin\=' falls back to.
    (begin       csi     "E")
    ;; The keypad.  Nineteen capabilities -- `ka1\=' through `kc3\=', `kbeg\=',
    ;; `kp5\=', `kent\=' and the `kpADD\=' family -- were declared in
    ;; terminfo/cooked.ti and none of them were ever sent, because this table
    ;; had no keypad row at all.  After `keypad(true)\=' ncurses waited on
    ;; getch for sequences that could not arrive.
    ;;
    ;; Emacs reports the same physical key under two names depending on
    ;; NumLock, so both halves are listed: `kp-7\=' and `kp-home\=' are one
    ;; key and share the SS3 final `w\='.  What differs is the *other*
    ;; spelling -- the digit half falls back to the character on the key cap,
    ;; the editing half to whatever the equivalent main-keyboard key sends,
    ;; named here as a symbol so that a modifier reaches the spelling that key
    ;; already has rather than a keypad form nothing decodes.
    (kp-0        keypad  "p" "0")
    (kp-1        keypad  "q" "1")
    (kp-2        keypad  "r" "2")
    (kp-3        keypad  "s" "3")
    (kp-4        keypad  "t" "4")
    (kp-5        keypad  "u" "5")
    (kp-6        keypad  "v" "6")
    (kp-7        keypad  "w" "7")
    (kp-8        keypad  "x" "8")
    (kp-9        keypad  "y" "9")
    (kp-decimal  keypad  "n" ".")
    (kp-add      keypad  "k" "+")
    (kp-subtract keypad  "m" "-")
    (kp-multiply keypad  "j" "*")
    (kp-divide   keypad  "o" "/")
    (kp-separator keypad "l" ",")
    (kp-enter    keypad  "M" "\r")
    (kp-home     keypad  "w" home)
    (kp-up       keypad  "x" up)
    (kp-prior    keypad  "y" prior)
    (kp-left     keypad  "t" left)
    (kp-begin    keypad  "E" begin)
    (kp-right    keypad  "v" right)
    (kp-end      keypad  "q" end)
    (kp-down     keypad  "r" down)
    (kp-next     keypad  "s" next)
    (kp-insert   keypad  "p" insert)
    (kp-delete   keypad  "n" deletechar))
  "Every non-character key cooked speaks for, as (SYMBOL KIND PAYLOAD [FALLBACK]).

One table rather than parallel ones per spelling, because the unmodified
spelling of every key is derivable from its modified one: a separate table of
unmodified spellings would be a denormalization maintained by hand, and one
consulted after the others could never be reached at all.

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
  `keypad\='   PAYLOAD is the SS3 final byte the key sends under application
              keypad -- \='ESC O PAYLOAD\=', which is what `ka1\=' and its
              nineteen neighbours in terminfo/cooked.ti spell out.  FALLBACK is
              the other spelling, the one `rmkx\=' asks for: a string for the
              keys with a character on the cap, or the symbol of the row this
              key stands in for when NumLock is off.  See
              `cooked--app-keypad-p\=' for which of the two is sent.

`cooked--key-sequence\=' derives the unmodified spelling, so the two can no
longer disagree.  The symbols are also exactly the set
`cooked--build-passthrough-map\=' binds explicitly, in every modified spelling,
for each of the maps it builds -- which is the table\='s other consumer.")

(defconst cooked--key-event-aliases
  '((delete . deletechar))
  "Keys a graphical frame names differently, as (EVENT . SYMBOL).

SYMBOL is the `cooked--key-encodings\=' row the key is spelled by, and EVENT is
the name a graphical frame gives the same key.  A terminal frame decodes the
Delete key\='s `ESC [ 3 ~\=' as `deletechar\=', but a graphical frame reports it
as `delete\=' and translates that to `deletechar\=' through
`local-function-key-map\=' only when nothing binds `delete\=' -- and
`comint-mode-map\=' does.  So Delete in a full-screen program ran
`delete-forward-char\=' on a read-only row instead of reaching the child.

`cooked--build-passthrough-map\=' binds each EVENT beside its row, in every
modified spelling, and `cooked--encode-event\=' reads EVENT as SYMBOL, so
\\`C-<delete>\=' is sent as `ESC [ 3 ; 5 ~\=' on either frame.  Every other row
of the table is named alike on both.")

(defun cooked--key-sequence (entry)
  "The unmodified, un-negotiated escape sequence ENTRY names.

ENTRY is a `cooked--key-encodings\=' row.  Deriving the unmodified spelling
rather than writing it out a second time is what keeps the two spellings of one
key from drifting apart."
  (pcase entry
    (`(,_ csi ,final) (cooked--csi final))
    (`(,_ ss3 ,final) (cooked--ss3 final))
    (`(,_ tilde ,n) (cooked--csi "~" n))
    (`(,_ keypad ,_ ,plain)
     (if (symbolp plain)
         (cooked--key-sequence (assq plain cooked--key-encodings))
       plain))
    (`(,_ literal ,_ ,fallback) fallback)
    (`(,_ literal ,code) (string code))))

(defun cooked--modifier-param (mods)
  "Return xterm's modifier parameter for MODS: 1 plus a bit per held modifier."
  (+ 1
     (if (memq 'shift mods) 1 0)
     (if (memq 'meta mods) 2 0)
     (if (memq 'control mods) 4 0)))

(defun cooked--app-keypad-p ()
  "Whether the keypad should send the SS3 spelling `smkx\=' asked for.

DECKPAM is the mode that actually governs this, and it is read here from
DECCKM instead -- `cooked--app-cursor\=' -- because the core tracks DECKPAM
without reporting it to Lisp, so there is nothing here to read.  The
substitution is exact for everything that drives the keypad the way terminfo
describes it: `smkx\=' is `ESC [ ? 1 h ESC =\=' and `rmkx\=' is
`ESC [ ? 1 l ESC >\=', so every program that turns the keypad on through the
entry turns both modes on in the same breath and off again in the same breath.

They part only for a child that sends a bare `ESC =\=' with no `ESC [ ? 1 h\='
beside it, which no capability in terminfo/cooked.ti describes and which
nothing reaches through ncurses.  One function rather than the variable at each
call site, so that the day the core reports DECKPAM there is a single line to
change."
  cooked--app-cursor)

(defun cooked--encode-literal (entry code param mods)
  "Encode the `literal' key ENTRY with modifiers, given its code point CODE.

CODE is the kitty/modifyOtherKeys code point, and PARAM the xterm modifier
parameter, with MODS the modifier list.  Falls back to `cooked--key-sequence'
when the child has negotiated nothing, since that is what every terminal has
always sent and what every program still understands -- a bare byte for most
keys here, but `backtab' falls back to its own classical, three-byte spelling
instead."
  (let ((seq (cooked--key-sequence entry))
        (level (cooked--modify-other-level)))
    (cond
     ((= param 1) (cooked--meta-prefixed mods seq))
     ;; A level the child set says which of these keys it covers; a guess from
     ;; `cooked-key-protocol-overrides\=' has no level and covers them all, as it
     ;; always has.
     ((and (eq cooked--keys 'modify-other)
           (or (not level) (cooked--modify-other-p level code mods)))
      (cooked--csi "~" 27 param code))
     ((eq cooked--keys 'kitty) (cooked--csi "u" code param))
     ;; Nothing negotiated, or a key level 1 leaves alone: meta has a classical
     ;; spelling, the rest do not.
     (t (cooked--meta-prefixed mods seq)))))

(defun cooked--encode-entry (entry param mods)
  "Bytes for the `cooked--key-encodings\=' row ENTRY, held with MODS.

PARAM is the xterm modifier parameter `cooked--modifier-param\=' derived from
MODS, and both are passed because the two are wanted in different places: the
parameter goes into a CSI, the list decides whether a leading ESC is what Meta
becomes.

A function of its own rather than the body of `cooked--encode-event\=' because
the keypad answers by deferring: a modified `kp-home\=' is a modified `home\=',
and saying so means dispatching on that row from inside this one."
  (let ((modified (> param 1)))
    (pcase entry
      (`(,_ csi ,final)
       (if modified (cooked--csi final 1 param) (cooked--cursor-key final)))
      ;; F1-F4 leave SS3 behind the moment they are modified.
      (`(,_ ss3 ,final)
       (if modified (cooked--csi final 1 param) (cooked--ss3 final)))
      (`(,_ tilde ,n)
       (if modified (cooked--csi "~" n param) (cooked--csi "~" n)))
      (`(,_ keypad ,final ,plain)
       (cond
        ;; The whole of what `smkx\=' buys: `ESC O w\=' for the upper-left
        ;; key, which is `ka1\=', and eighteen more like it.
        ((and (not modified) (cooked--app-keypad-p)) (cooked--ss3 final))
        ;; NumLock off: this key *is* the editing key it stands in for, so a
        ;; modifier reaches that key's spelling.  Terminfo declares no modified
        ;; keypad capability, and inventing `ESC [ 1 ; 5 w\=' to fill the gap
        ;; would send a sequence nothing decodes.
        ((symbolp plain)
         (cooked--encode-entry (assq plain cooked--key-encodings) param mods))
        ;; A character on the key cap, so it behaves as that character does --
        ;; including under a negotiated protocol, where `C-kp-add\=' is spelled
        ;; from the code point of `+\=' exactly as `C-+\=' would be.
        (t (cooked--encode-literal entry (aref plain 0) param mods))))
      (`(,_ literal ,code . ,_)
       (cooked--encode-literal entry code param mods)))))

;;;; xterm's modifyOtherKeys, as negotiated

(defun cooked--control-char (char)
  "The byte Control turns CHAR into, or nil where Control makes no byte.

This is X11's table, from `XkbToControl\=' in libX11, and xterm's too, since
xterm takes the byte from `XLookupString\=': `@\=' through `~\=' and the space
bar are masked to their low five bits, `2\=' is NUL, `3\=' through `7\=' are ESC
through US, `8\=' and `?\=' are DEL, and `/\=' is US.  Every other character has
no control form, and Control on it sends the character itself.

The obvious rule, masking any character to five bits, is wrong on both sides of
that line.  It sent `C-;\=' as a bare ESC, which a child reads as the start of
an escape sequence, and `C-/\=' as SI rather than the US every shell binds to
undo.  modifyOtherKeys needs the real table for a second reason: level 1 is
defined by it, re-spelling exactly the chords that have no byte here."
  (cond ((or (<= ?@ char ?~) (= char ?\s)) (logand char #x1f))
        ((= char ?2) 0)
        ((<= ?3 char ?7) (+ 27 (- char ?3)))
        ((memq char '(?8 ??)) 127)
        ((= char ?/) 31)))

(defun cooked--modify-other-level ()
  "The modifyOtherKeys level the child negotiated, or nil if it negotiated none.

nil while `cooked--keys\=' is `modify-other\=' means that value was assumed by
`cooked-key-protocol-overrides\=' or `cooked-key-overrides\=' rather than asked
for, and then only the `literal\=' keys are re-spelled, exactly as for a kitty
guess and for the reason `cooked--kitty-negotiated-p\=' gives: `C-a\=' sent as
`ESC [ 27 ; 5 ; 97 ~\=' to a program that never asked is not a Control-a."
  (and (eq cooked--keys 'modify-other)
       (memq cooked--modify-other-keys '(1 2))
       cooked--modify-other-keys))

(defun cooked--modify-other-p (level code mods)
  "Whether modifyOtherKeys LEVEL spells CODE, held with MODS, as an escape.

CODE is the character the key types, shifted -- `A\=' for shift+a, which is the
keysym xterm reads and the number it sends -- or the code point of a `literal\='
key in `cooked--key-encodings\='.  The rules are `ModifyOtherKeys\=' and
`allowedCharModifiers\=' in xterm\='s input.c (patch 411), checked against the
us-pc105 table in xterm\='s modified-keys FAQ.

Level 2 re-spells any key held with Control or Meta.  Shift alone re-spells
only the keys Control would otherwise turn into a byte -- the letters and
`@[\\]^_\=' with their shifted partners -- and the space bar, since shift+1
already types a `!\=' nobody could mistake.  So shift+a is
`ESC [ 27 ; 2 ; 65 ~\=' and `!\=' stays `!\='.  Return, Tab, Escape and
Backspace are re-spelled under any modifier.  xterm leaves Control+Backspace
alone, since Control there flips Backspace between BS and DEL, a switch cooked
does not have; spelling it out loses nothing a child that asked for this can
misread.

Level 1 leaves alone every chord that already means something.  Control
re-spells a key only where `cooked--control-char\=' finds no byte for it, so
`C-a\=' stays SOH while `C-;\=' becomes `ESC [ 27 ; 5 ; 59 ~\='.  Shift alone
re-spells nothing, and neither does Meta: xterm\='s manual says Meta at this
level follows metaSendsEscape, which is how cooked always spells it.  Return
and Tab are the exception, and re-spelled under Shift or Control, while Escape
and Backspace never are.  Where a chord is re-spelled Meta still counts in its
parameter, so nothing held is lost; where it is not, Meta is the leading ESC
it always was."
  (let ((ctrl (memq 'control mods))
        (shift (memq 'shift mods))
        (meta (memq 'meta mods)))
    (pcase level
      (2 (if (memq code '(9 13 27 127))
             (or ctrl shift meta)
           (or ctrl meta
               (and shift (or (<= #x40 code #x7f) (= code ?\s))))))
      (1 (pcase code
           ((or 9 13) (or ctrl shift))
           ((or 27 127) nil)
           (_ (and ctrl (not (cooked--control-char code)))))))))

(defun cooked--encode-char (char mods)
  "The bytes for the text key CHAR held with MODS, when no protocol spells it.

CHAR is the unshifted key, as `event-basic-type\=' reports it.  Shift becomes a
capital, Control the byte `cooked--control-char\=' names or nothing, and Meta a
leading ESC."
  (let* ((char (if (memq 'shift mods) (upcase char) char))
         (char (or (and (memq 'control mods) (cooked--control-char char))
                   char)))
    (cooked--meta-prefixed mods (string char))))

(defun cooked--encode-modify-other (basic mods param level)
  "Encode BASIC held with MODS for a child that negotiated modifyOtherKeys LEVEL.

BASIC and MODS are as `cooked--kitty-event\=' names the key, and PARAM the xterm
modifier parameter derived from MODS.  A key in `cooked--key-encodings\=' goes
the way it always has, with `cooked--encode-literal\=' asking LEVEL about the
four keys the protocol re-spells; a text key is `ESC [ 27 ; PARAM ; CODE ~\='
where `cooked--modify-other-p\=' says so, and its classical bytes where not.

Narrower than xterm where an Emacs event lacks the fact, as the kitty encoder
is: shift+1 arrives as a bare `!\=', so Control+Shift+1 is sent as Control+`!\='
with parameter 5 rather than xterm\='s 6, and C-i, C-m and C-[ merge into Tab,
Return and Escape."
  (if-let* ((entry (assq basic cooked--key-encodings)))
      (cooked--encode-entry entry param mods)
    (when (characterp basic)
      (let ((code (if (memq 'shift mods) (upcase basic) basic)))
        (if (cooked--modify-other-p level code mods)
            (cooked--csi "~" 27 param code)
          (cooked--encode-char basic mods))))))

;;;; The kitty keyboard protocol, as negotiated

(defconst cooked--kitty-keypad-codes
  '((kp-0 . 57399) (kp-1 . 57400) (kp-2 . 57401) (kp-3 . 57402)
    (kp-4 . 57403) (kp-5 . 57404) (kp-6 . 57405) (kp-7 . 57406)
    (kp-8 . 57407) (kp-9 . 57408) (kp-decimal . 57409) (kp-divide . 57410)
    (kp-multiply . 57411) (kp-subtract . 57412) (kp-add . 57413)
    (kp-enter . 57414) (kp-separator . 57416) (kp-left . 57417)
    (kp-right . 57418) (kp-up . 57419) (kp-down . 57420) (kp-prior . 57421)
    (kp-next . 57422) (kp-home . 57423) (kp-end . 57424) (kp-insert . 57425)
    (kp-delete . 57426) (kp-begin . 57427))
  "The private-use code point kitty gives each keypad key.

From the functional key table in kitty's keyboard protocol document.  The
keypad is the one part of `cooked--key-encodings\=' the protocol spells
differently from the legacy terminal: a keypad key is a key of its own there,
not the main-keyboard key it stands in for, so that `kp-home\=' and `home\='
can be told apart.")

(defconst cooked--kitty-disambiguate 1
  "Kitty keyboard flag 1: spell ambiguous keys, Escape and chords, as escape codes.")

(defconst cooked--kitty-alternate-keys 4
  "Kitty keyboard flag 4: report the shifted key alongside the key itself.")

(defconst cooked--kitty-all-keys 8
  "Kitty keyboard flag 8: report every key as an escape code, text keys included.")

(defconst cooked--kitty-associated-text 16
  "Kitty keyboard flag 16: report the text a key produces alongside its code.")

(defconst cooked--kitty-negotiated
  (logior cooked--kitty-disambiguate cooked--kitty-all-keys)
  "The kitty flags either of which means the child asked for the protocol itself.

Flag 8 turns the protocol on as surely as flag 1 does, since reporting every key
as an escape code disambiguates them all by construction, while flags 4 and 16
only add a field to an escape code something else already chose to send.  The
core makes the same test in `State::key_encoding\='.")

(defun cooked--kitty-flag-p (bit)
  "Whether the child's kitty flags include BIT."
  (/= 0 (logand cooked--kitty-flags bit)))

(defun cooked--kitty-negotiated-p ()
  "Whether the child asked for the kitty protocol itself, so all of it applies.

See `cooked--kitty-negotiated\=' for which flags say so.  What it rules out is a
`kitty\=' that nobody negotiated, which `cooked-key-protocol-overrides\=' binds
for a program that reads the protocol without ever asking for it.  That guess
re-spells only the `literal\=' keys: a Claude Code sent Escape as
`ESC [ 27 u\=' on the strength of a match against its process name would be the
rubbish-in-the-input case the negotiation exists to prevent."
  (and (eq cooked--keys 'kitty)
       (cooked--kitty-flag-p cooked--kitty-negotiated)))

(defun cooked--kitty-text-p (char)
  "Whether CHAR may be reported as associated text: not a C0 or C1 control."
  (and char (>= char #x20) (not (<= #x7f char #x9f))))

(defun cooked--kitty-csi-u (code param &optional shifted text)
  "The kitty sequence for key CODE held with modifier parameter PARAM.

That is `ESC [ CODE : SHIFTED ; PARAM ; TEXT u\=', with each optional part left
out when it has nothing to say: SHIFTED is the shifted key bit 4 reports, and
TEXT the character bit 16 reports.  PARAM is omitted at 1, which is its default,
unless TEXT follows it -- then its field is left empty rather than dropped, so
that the text is not read as a modifier.  kitty's own example is shift+a,
`ESC [ 97 ; 2 ; 65 u\=', and the same key with no modifier would be
`ESC [ 97 ; ; 97 u\='.

The base-layout key, which the protocol puts after SHIFTED, is never sent: it
names the physical key on a US layout, and an Emacs event carries no physical
key.  The protocol makes both alternates optional."
  (let ((key (if shifted (format "%d:%d" code shifted) code)))
    (cond (text (cooked--csi "u" key (if (> param 1) param "") text))
          ((> param 1) (cooked--csi "u" key param))
          (t (cooked--csi "u" key)))))

(defun cooked--encode-kitty-char (char mods param)
  "Encode the text key CHAR, held with MODS, for a child that negotiated kitty.

CHAR is the unshifted key, as `event-basic-type\=' reports it, and PARAM the
modifier parameter.  Plain text, shifted or not, goes as the text itself unless
bit 8 asked for every key as an escape code; Control or Meta makes it an escape
code under bit 1 alone, which is what disambiguation means for a text key.
kitty's table for `i\=' is the whole of the rule: `i\=', `I\=', then
`ESC [ 105 ; 3 u\=' for alt, `105 ; 5\=' for ctrl, `105 ; 4\=' for shift+alt,
`105 ; 7\=' for ctrl+alt and `105 ; 6\=' for ctrl+shift.

Associated text is reported only where the key still produces text, which
Control and Meta both prevent.  The shifted key is reported only with Shift
held and only where shifting changed something.  Both are narrower than kitty
for a key whose shifted glyph is not its upper case: Emacs reports shift+1 as a
bare `!\=' with no Shift, so it is sent as the key `!\=', and nothing here can
recover that it was a `1\=' -- a fact about the keyboard layout that an Emacs
event does not carry."
  (let* ((ctrl (memq 'control mods))
         (meta (memq 'meta mods))
         (shift (memq 'shift mods))
         (text (if shift (upcase char) char)))
    (if (and (not ctrl) (not meta) (not (cooked--kitty-flag-p cooked--kitty-all-keys)))
        (string text)
      (cooked--kitty-csi-u
       char param
       (and (cooked--kitty-flag-p cooked--kitty-alternate-keys) shift (/= text char) text)
       (and (cooked--kitty-flag-p cooked--kitty-associated-text) (not ctrl) (not meta)
            (cooked--kitty-text-p text) text)))))

(defun cooked--encode-kitty-entry (entry mods param)
  "Encode the `cooked--key-encodings\=' row ENTRY for a negotiated kitty child.

MODS and PARAM are as for `cooked--encode-entry\=', which this departs from in
four places, each of them the protocol's rule that a key which produces no
text is `CSI number ; modifier u\=' or `CSI 1 ; modifier FINAL\=':

  Escape is always an escape code, `ESC [ 27 u\=' unmodified.  Return, Tab and
  Backspace stay bare bytes unmodified, so that `reset\=' can still be typed
  after a program dies with the mode on -- until bit 8, which takes that away
  too.
  F1-F4 and the cursor keys drop SS3, even under DECCKM and even unmodified.
  F3 is `ESC [ 13 ~\=', since `ESC [ 1 ; MOD R\=' is a cursor position report.
  The keypad is a set of keys of its own; see `cooked--kitty-keypad-codes\='."
  (let ((modified (> param 1))
        (all (cooked--kitty-flag-p cooked--kitty-all-keys)))
    (pcase entry
      (`(escape . ,_) (cooked--kitty-csi-u 27 param))
      (`(,_ literal ,code . ,_)
       (if (or modified all)
           (cooked--kitty-csi-u code param)
         (cooked--key-sequence entry)))
      (`(f3 . ,_) (if modified (cooked--csi "~" 13 param) (cooked--csi "~" 13)))
      (`(,_ ,(or 'csi 'ss3) ,final)
       (if modified (cooked--csi final 1 param) (cooked--csi final)))
      (`(,key keypad ,_ ,plain)
       (let ((code (alist-get key cooked--kitty-keypad-codes))
             (char (and (stringp plain) (aref plain 0))))
         (if (and (cooked--kitty-text-p char) (not all)
                  (not (memq 'control mods)) (not (memq 'meta mods)))
             ;; A printable character on the cap types that character, shifted
             ;; or not, as a main-keyboard text key would.
             plain
           (cooked--kitty-csi-u
            code param nil
            (and (cooked--kitty-flag-p cooked--kitty-associated-text) (cooked--kitty-text-p char)
                 (not (memq 'control mods)) (not (memq 'meta mods))
                 char)))))
      (_ (cooked--encode-entry entry param mods)))))

(defun cooked--kitty-event (event basic mods)
  "BASIC and MODS for EVENT as the kitty protocol would name the key, or nil.

modifyOtherKeys names keys the same way and asks this too; the kitty protocol
is where the question first came up.

A cons (BASIC . MODS), or nil for a key that has to go as the byte it arrived
as.  Emacs names a control character by the letter it is typed with, so a TAB
read from a terminal frame is `C-i\=' -- and the kitty protocol, told that,
sends `ESC [ 105 ; 5 u\=' for every Tab.  A graphical frame reports the key as
`tab\=' and this does not arise; a terminal frame cannot tell the two apart, and
every terminal before kitty sent Tab for both, so the key is taken to be Tab.
Return and Backspace are the same case, and NUL is Control plus the space bar
rather than Control plus `@\='.

ESC is the exception that is left alone.  On a terminal frame it is both the
Escape key and the first half of every Meta chord, which arrive as two separate
keys; sent as `ESC [ 27 u\=', a Meta chord would reach the child as an Escape
followed by a letter.  The graphical frame, where Escape is a key of its own,
reports it as `escape\=' and gets the protocol's spelling."
  (pcase (and (integerp event) (logand event (1- (ash 1 22))))
    (27 nil)
    ((and code (or 9 13 127))
     (cons (pcase code (9 'tab) (13 'return) (127 'backspace))
           (remq 'control mods)))
    (0 (cons ?\s mods))
    (_ (cons basic mods))))

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
  ;; One lookup and one dispatch on the entry's KIND.  With one entry per key
  ;; there is no ordering to get wrong: a key is in the table or it is not,
  ;; and if it is not it falls through to the plain-character case below.
  (let* ((mods (event-modifiers event))
         (basic (event-basic-type event))
         (basic (alist-get basic cooked--key-event-aliases basic))
         ;; `backtab' is the mirror image of the capital-letter case above: Emacs
         ;; bakes its shift into the base symbol and reports none in `mods' at
         ;; all, for `backtab' alone or with other modifiers held alongside it
         ;; (`C-backtab' still reports only `(control)').  Restore it before
         ;; `param' is computed, or the `literal' entry for `backtab' has a code
         ;; point that no modifier ever reaches.
         (mods (if (eq basic 'backtab) (cons 'shift mods) mods))
         (param (cooked--modifier-param mods)))
    (pcase (and (or (cooked--kitty-negotiated-p) (cooked--modify-other-level))
                (cooked--kitty-event event basic mods))
      ;; A protocol proper, when the child asked for one: every key it spells
      ;; differently goes through here, and the rest is deferred back to
      ;; `cooked--encode-entry' from inside.
      (`(,basic . ,mods)
       (let ((param (cooked--modifier-param mods)))
         (if-let* ((level (cooked--modify-other-level)))
             (cooked--encode-modify-other basic mods param level)
           (if-let* ((entry (assq basic cooked--key-encodings)))
               (cooked--encode-kitty-entry entry mods param)
             (when (characterp basic)
               (cooked--encode-kitty-char basic mods param))))))
      (_
       (if-let* ((entry (assq basic cooked--key-encodings)))
           (cooked--encode-entry entry param mods)
         ;; Not in the table at all: a plain character, or nothing we can spell.
         (when (characterp basic)
           (cooked--encode-char basic mods)))))))

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

Bound only under the ESC prefix `cooked--build-meta-overlay\=' makes, where a
Meta chord arrives as two events and the modifier is gone by the time a command
runs: `M-t\=' is looked up as `ESC t\=', so `last-command-event\=' is a bare
`?t\='.  Put the modifier back and hand the reconstructed event to
`cooked-send-key\=', so that a negotiated protocol spells it as a modifier
parameter rather than as a leading ESC -- which is the whole reason not to
simply send \"\\e\" and the key.

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
where the paste ends; nothing in the middle gets to say otherwise.

Kept even though `cooked--strip-paste-controls' has already turned every ESC
in a paste into a space, which leaves no marker for this to find: the two
guards answer to different callers, and a marker assembled without an ESC --
or a future caller that skips the strip -- must still not close the bracket."
  (let ((end (cooked--csi "~" 201)))
    (concat (cooked--csi "~" 200) (string-replace end "" text) end)))

(defconst cooked--paste-strip-regexp
  "[\000\010\005\004\033\177\003\034\025\032\021\023\027\026\022\017]"
  "Bytes replaced by a space in anything pasted to the child.

This is xterm's list, whose `disallowedPasteControls' resource defaults to
`BS,DEL,ENQ,EOT,ESC,NUL,STTY' (xterm's own \\=`main.h\\=',
`DEF_DISALLOWED_PASTE_CONTROLS'): NUL, BS, ENQ, EOT, ESC and DEL, plus --
that is what the `STTY' keyword means -- the tty driver's own special
characters, which xterm reads live with `tcgetattr'.

Those are spelled out here at their conventional values rather than read
from the child's termios: VINTR C-c, VQUIT C-\\, VKILL C-u, VSUSP C-z,
VSTART C-q, VSTOP C-s, VWERASE C-w, VLNEXT C-v, VREPRINT C-r, VDISCARD
C-o.  cooked's core samples the child's termios but exposes only the mode
it implies, not `c_cc', and a program that has remapped its interrupt key
is rare enough not to be worth the plumbing -- ghostty made the same call
and wrote the same caveat down.

What is deliberately *not* here is as important: TAB, LF and CR go through
untouched, because a paste is expected to contain lines and indentation.
LF is dealt with separately by `cooked--send-paste', and is the one byte a
paste can carry that runs something -- which is why it is confirmed rather
than mangled.")

(defun cooked--strip-paste-controls (text)
  "TEXT with the bytes in `cooked--paste-strip-regexp' turned into spaces.

Unconditional, and in particular not conditional on bracketed paste, which
is the same posture as xterm.  Bracketing tells a *cooperating* reader
where the paste ends; it does nothing about a byte the tty driver acts on
before any reader sees it, and nothing at all about a program that does
not implement the protocol but is being pasted into anyway.  A copied ESC
sequence pasted into a shell can arrive as key presses, a copied C-c can
kill the command the user meant to paste into, and neither is visible in
the text they copied.

Turned into spaces rather than dropped, again as xterm does: the byte
count survives, so a paste that was tampered with looks wrong rather than
looking like something shorter that was pasted on purpose."
  (replace-regexp-in-string cooked--paste-strip-regexp " " text t t))

(defun cooked--send-paste (text)
  "Hand TEXT to the child as a paste.

The control bytes go first and unconditionally -- see
`cooked--strip-paste-controls' -- so everything below is about newlines,
which are the one thing a paste is expected to contain and the one thing
that makes it run."
  (let ((text (cooked--strip-paste-controls text)))
    (cond
     ((cooked--bracketed-paste-p cooked--session)
      (cooked--snap-to-cursor)
      (cooked--send-to-child (cooked--bracketed-paste text)))
     ((and cooked-paste-confirm-lines
           (string-search "\n" text)
           (not (y-or-n-p
                 (format "Paste %d lines, which %s will run as each arrives?"
                         (1+ (cl-count ?\n text))
                         (or cooked-title "The child")))))
      (message "Paste cancelled"))
     (t
      (cooked--snap-to-cursor)
      ;; Newlines go as carriage returns because that is what the Return key
      ;; transmits, and a line editor bound to CR is what is reading them.
      (cooked--send-to-child (string-replace "\n" "\r" text))))))

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
  "Paste the text a terminal frame\='s host terminal delivered in EVENT.

On `emacs -nw\=' a paste in the host terminal arrives as one `xterm-paste\='
event, of the form (xterm-paste TEXT), which term/xterm.el decodes from the
bracketed-paste markers.  Its global binding, `xterm-paste\=', inserts TEXT
into the current buffer with `yank\=', called as a function, so the remap that
turns `yank\=' into `cooked-paste\=' never sees it.  Pasting into a running vim
therefore put the text into the cooked buffer instead of into vim.

At an input prompt this does what `xterm-paste\=' does, since the line is
being edited in the buffer; `cooked--send-input-string\=' strips the control
bytes when it is submitted.  While the child owns the keyboard TEXT goes to it
through `cooked--send-paste\=', bracketed if the child asked, with the same
control-byte strip as `cooked-paste\='.  TEXT is put on the kill ring first
when `xterm-store-paste-on-kill-ring\=' says so, as `xterm-paste\=' would."
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

(provide 'cooked-keys)
;;; cooked-keys.el ends here
