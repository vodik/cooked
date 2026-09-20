;;; cooked-keymaps.el --- Which keys reach the child, and which Emacs keeps -*- lexical-binding: t; -*-

;;; Commentary:

;; The maps a cooked buffer wears: `cooked-raw-map', `cooked-command-map' and
;; `cooked-alt-map' for a child that owns the keyboard, `cooked-semi-map' for
;; evil's insert state, `cooked-peek-map' while stepping out, and
;; `cooked-input-map' while Emacs owns the line.  With them are the two
;; questions a key raises on the way in -- whether an ESC on a tty is a key or
;; the start of a Meta chord, and whether a RET or a click on a link belongs to
;; the child.
;;
;; What a key becomes is cooked-keys.el; which map is installed when is
;; `cooked--refresh-keymap' in cooked-mode.el.  This file builds the maps, and
;; sits on the commands they bind.

;;; Code:

(require 'cl-lib)
(require 'cooked-util)
(require 'cooked-state)
(require 'cooked-cursor)
(require 'cooked-link)
(require 'cooked-mouse)
(require 'cooked-peek)
(require 'cooked-keys)
(require 'cooked-input)

(cooked--declare-core)

(defconst cooked--escape-key ?\C-c
  "Prefix reserved for cooked's own commands while the child owns the keyboard.
Everything `cooked-raw-map' and `cooked-alt-map' cover is otherwise forwarded
verbatim, ESC included, so \\`M-x' reaches the child as ESC x — exactly as in
any other terminal.  \\`C-c M-x' is the way back out, bound on `cooked-mode-map'
to `execute-extended-command' itself so that a completion framework's remap of
it -- `counsel-M-x' -- still applies.
On a graphical frame, where a Meta chord is one event rather than two bytes,
that takes a keymap of its own -- see `cooked--build-meta-overlay'.

`cooked-semi-map' is the exception, and deliberately so: it keeps ESC and the
whole Meta space for Emacs, which is what makes evil's insert state a state you
can leave.  See `cooked-semi-exceptions'.

A `defconst' where every other key cooked keeps back is a `defcustom', because
this one is a prefix rather than a key.  Every command cooked has is spelled
under it in `cooked-mode-map', so an option would have to rebuild that map and
its menu's key echoes as well as the passthrough maps, and the one binding
documented everywhere as the way back out would stop being a fact.  The
exceptions lists are what a user changes instead.")

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

(defun cooked--exception-event (key)
  "The one event KEY names, signalling an error if it names more or fewer.

Any key a passthrough map binds on its own can be kept back: a control
character such as `C-g', a Control chord no character names such as `C-;', a
function key such as `<f5>', or a Meta chord such as `M-x'.  Each is left
unbound wherever the maps would otherwise bind it, which for a Meta chord on a
graphical frame is `cooked--build-meta-overlay'.  A sequence such as `C-x C-f'
is refused, since the maps forward one event at a time and never see a second."
  (let ((keys (kbd key)))
    (unless (= (length keys) 1)
      (error "cooked: %S does not name a single key" key))
    (aref keys 0)))

(defun cooked--control-chord-events (exceptions)
  "The Control chords on printable keys that no character code in 0-127 names.

On a graphical frame `C-;' and `C-S-a' are events of their own, outside
the range `cooked--build-passthrough-map' binds a code at a time.  Left
unbound, `C-;' reached whatever Emacs binds globally, and `C-S-a' was
shift-translated to `C-a' with the shift gone before `cooked-send-key' could
look -- so neither could be spelled by a protocol that has a spelling for it,
which is what modifyOtherKeys and the kitty protocol both exist to provide.
With no protocol they send what xterm sends: the key itself where Control
makes no byte, and the control byte where it does.  A terminal frame never
produces these events, so nothing changes there.

Control on a Latin-1 key is here too, so that \\`C-é' on a French keyboard is
`ESC [ 233 ; 5 u' to a kitty child rather than undefined in Emacs.  A key
beyond Latin-1 is not: a keymap can bind every character only without a
modifier, through a char-table, and Control on one of those stays Emacs'.

The events in EXCEPTIONS are left out, and so are those that stand in for one,
as is the one standing in for `cooked--escape-key': `C-S-g' is `C-g' with a
shift Emacs would otherwise translate away, and forwarding it would take the key
back from the binding the exception was made to keep."
  (let (events)
    ;; Not the capitals: Emacs spells Control on one as `C-S-' and the
    ;; lowercase letter, which is the shifted chord the letters below add.
    (dolist (char (append (number-sequence ?\s ?@) (number-sequence ?\[ ?~)
                          (number-sequence #xa0 #xff)))
      (let ((ctrl (event-apply-modifier char 'control 26 "C-")))
        (when (and (>= ctrl 128) (not (memq ctrl exceptions)))
          (push ctrl events))
        ;; The shift bit by hand: `event-apply-modifier' shifts a control
        ;; character by upcasing it, which makes `C-a' into `C'.  Not `C-S-i'
        ;; or `C-S-m' either, which are `S-TAB' and `S-RET' as events and are
        ;; the literal keys' to answer for.
        (when (and (<= ?a char ?z)
                   (not (memq char '(?i ?m)))
                   (not (memq ctrl exceptions))
                   (not (eq ctrl cooked--escape-key)))
          (push (logior ctrl (ash 1 25)) events))))
    (nreverse events)))

(defconst cooked--modifier-sets
  '(() (shift) (control) (meta) (control shift) (meta shift) (control meta)
    (control meta shift))
  "Every combination of Shift, Control and Meta, the modifiers xterm spells.

`cooked--build-passthrough-map' binds each key of `cooked--key-names'
under all of them.  A combination left out is shift-translated when it has no
binding: \\`C-M-S-<up>' used to run as \\`C-M-<up>', and a child that asked
for `ESC [ 1 ; 8 A' got `ESC [ 1 ; 7 A' instead.")

(defun cooked--kitty-binding (binding)
  "BINDING while the child has negotiated the kitty protocol, and nil otherwise.

The `:filter' of `cooked--kitty-only', read on every key, so a binding made
with it follows the negotiation without the map being rebuilt."
  (and (cooked--kitty-negotiated-p) binding))

(defun cooked--kitty-only (command)
  "A binding of COMMAND that holds only while the kitty protocol is negotiated.

For the keys no other protocol can spell: a chord held with Super or Hyper, and
a key such as `pause' that has no sequence outside kitty's table.  The kitty
protocol gives them all a spelling, `ESC [ 97 ; 9 u' for \\`s-a' and
`ESC [ 57362 u' for Pause, but to a child that negotiated nothing \\`s-a'
could only be sent as a plain `a', as xterm sends it, and Pause as nothing.
Taking the key from Emacs to send that would be all loss -- \\`s-v' is a
paste on macOS -- so while nothing is negotiated the binding is nil, and the
key falls through to whatever Emacs binds it to.  A Super or Hyper chord goes
further, and stays Emacs' while Emacs binds it; see `cooked--kitty-chord'."
  `(menu-item "" ,command :filter cooked--kitty-binding))

(defvar cooked--asking-emacs-about-chord nil
  "Non-nil while `cooked--kitty-chord-binding' asks what Emacs binds a chord to.

Every Super and Hyper chord answers nil while this is set, so the lookup made
from inside the filter sees past cooked's own binding to the one under it,
instead of calling the same filter again.")

(defun cooked--kitty-chord-binding (key binding)
  "BINDING for the Super or Hyper chord KEY, if a kitty child should have it.

That is while the kitty protocol is negotiated and nothing else in the active
keymaps binds KEY, which is how a terminal treats its own shortcuts: it takes
the ones it has and passes the rest through.  \\`s-v' bound to a paste in the
user's config stays a paste with Claude Code running, while an unbound \\`s-j'
reaches the child as `ESC [ 106 ; 9 u'.  An `undefined' binding counts as
none, since it exists only to shadow one.

Asked on every lookup rather than when the map is built, so a chord bound or
unbound after the session started goes the right way at once."
  (and (cooked--kitty-negotiated-p)
       (not cooked--asking-emacs-about-chord)
       (memq (let ((cooked--asking-emacs-about-chord t))
               (key-binding key))
             '(nil undefined))
       binding))

(defun cooked--kitty-chord (command event)
  "A binding of COMMAND for EVENT, a Super or Hyper chord, for a kitty child only.

Like `cooked--kitty-only', and yielding besides to any binding Emacs has for
the chord; see `cooked--kitty-chord-binding'.  EVENT is the chord as it is
looked up from the top of the active maps: a binding stored under an ESC
prefix is passed the Meta event its prefix spells.  Each chord needs a filter
of its own because a filter is told only the binding, not the key it was
reached by."
  `(menu-item "" ,command
              :filter ,(apply-partially #'cooked--kitty-chord-binding (vector event))))

(defun cooked--super-chord-events (exceptions)
  "The chords on printable keys held with Super or Hyper, but for EXCEPTIONS.

Every character from space to `~' with either modifier, as a graphical frame
delivers it: \\`s-A' for Super+Shift+a, since Emacs folds Shift into the
capital.
The same with Control, which `cooked--control-chord-events' spells, and
\\`S-s-a' as well, which is what `kbd' makes of that name and would
otherwise be shift-translated to \\`s-a'.  Meta is left to
`cooked--build-meta-overlay', where a Meta character has to be bound."
  (let (events)
    (dolist (modifier '((super 23 "s-") (hyper 24 "H-")))
      (dolist (char (append (number-sequence ?\s ?~)
                            (mapcar (lambda (char) (logior char (ash 1 25)))
                                    (number-sequence ?a ?z))
                            (mapcar (lambda (char) (event-apply-modifier char 'control 26 "C-"))
                                    (number-sequence ?\s ?~))
                            (cooked--control-chord-events nil)))
        (let ((event (apply #'event-apply-modifier char modifier)))
          (unless (memq event exceptions)
            (push event events)))))
    (delete-dups (nreverse events))))

(defun cooked--build-passthrough-map (exceptions &optional reserve-chords)
  "A keymap that forwards to the child, except EXCEPTIONS and `C-c'.
EXCEPTIONS is a list of events, as from `cooked--exception-event'; each is
simply left unbound here, so it falls through to whatever
`cooked-mode-map'/`comint-mode-map'/`global-map' -- or `evil', if it has
installed a higher-priority keymap of its own -- would otherwise do with it.

With RESERVE-CHORDS, ESC, every Meta-modified key, every chord held with Super
or Hyper, and every Control chord no character code names are left unbound too.
Those are the chords Emacs packages live on -- `M-x', a leader on `M-SPC',
embark on `C-;', a mark on `C-SPC', the macOS Command key on `s-' -- and
holding them back is one exception expressed as a rule rather than a list.  For
Meta it has to be: `kbd' spells Meta as a modifier bit on a GUI frame and as a
leading ESC on a terminal, so no list of character codes can name `M-x' in both
-- while leaving ESC itself unbound makes Emacs' own `meta-prefix-char'
handling the thing that answers, in whichever spelling the frame produces.  The
cost is the one thing ESC is otherwise good for here: a forwarded ESC has no
latency, and a prefix key waits.  See `cooked-semi-map', which is where that
trade is worth making.  The Control chords cost nothing on a terminal frame,
which never produces them: there `C-SPC' is NUL and still forwards.

Without it the Meta space is not bound here either, for the same reason read
the other way: ESC being a key of its own is what stops it being the prefix
`M-t' would have to be stored under.  That is invisible on a terminal frame,
where Meta chords arrive as two forwarded bytes, and is why
`cooked--build-meta-overlay' exists for the frame where it is not.  Super and
Hyper are bound through `cooked--kitty-chord', since only the kitty protocol can
spell them, and a chord Emacs binds is left to Emacs."
  ;; `define-key' throughout rather than `keymap-set', and not a modernisation
  ;; someone has yet to do: every key here is an event computed by
  ;; `event-convert-list' or a character code counted out, and `keymap-set'
  ;; takes only a key string, which each would have to be turned into and
  ;; parsed back out of.
  (let ((map (make-sparse-keymap))
        (kitty-only (cooked--kitty-only #'cooked-send-key)))
    ;; First, because `define-key' puts each new binding at the head of the list
    ;; and a lookup walks it: the keys typed most are bound last, below, and are
    ;; found before this long tail of chords that are hardly ever pressed.
    (unless reserve-chords
      (dolist (event (cooked--super-chord-events exceptions))
        (define-key map (vector event) (cooked--kitty-chord #'cooked-send-key event)))
      (dolist (key (append cooked--key-names
                           (mapcar #'car cooked--key-event-aliases)))
        (dolist (extra '((super) (hyper)))
          (dolist (mods cooked--modifier-sets)
            (let ((event (event-convert-list (append extra mods (list key)))))
              (unless (memq event exceptions)
                (define-key map (vector event)
                            (cooked--kitty-chord #'cooked-send-key event))))))))
    (define-key map [remap self-insert-command] #'cooked-send-key)
    (dolist (code (number-sequence 0 127))
      (unless (or (eq code cooked--escape-key)
                  (and reserve-chords (eq code meta-prefix-char))
                  (memq code exceptions))
        (define-key map (vector code) #'cooked-send-key)))
    (unless reserve-chords
      (dolist (event (cooked--control-chord-events exceptions))
        (define-key map (vector event) #'cooked-send-key)))
    ;; Shift+Space too, the one printable key whose shifted form is no character
    ;; of its own.  Unbound, Emacs translates it to a plain space with the shift
    ;; gone, so a kitty child reporting every key never gets its `CSI 32;2u'.
    (unless (memq ?\S-\s exceptions)
      (define-key map (vector ?\S-\s) #'cooked-send-key))
    ;; Bind the modified variants explicitly, not for completeness but for
    ;; correctness: when `S-return' has no binding Emacs shift-translates it to
    ;; `return' and runs *that* binding, with `last-command-event' already flattened.
    ;; By the time `cooked-send-key' looks, the shift is gone and unrecoverable.
    ;; A graphical frame's own names for a row are bound the same way, since
    ;; `delete' reaches `deletechar' only when nothing binds it.
    (dolist (key (append cooked--key-names
                         (mapcar #'car cooked--key-event-aliases)))
      (dolist (mods cooked--modifier-sets)
        (let ((event (event-convert-list (append mods (list key)))))
          (unless (or (and reserve-chords
                           ;; The Escape key a graphical frame sends is ESC
                           ;; under another name, and is reserved with it.
                           (or (memq 'meta mods) (eq key 'escape)))
                      (memq event exceptions))
            (define-key map (vector event)
                        ;; A key with no spelling but kitty's is kitty's alone.
                        (if (memq key cooked--kitty-only-keys)
                            kitty-only
                          #'cooked-send-key))))))
    ;; Everything else cooked binds under `C-c' -- its own commands, and the
    ;; ones that write to the child out of band -- lives on `cooked-mode-map'
    ;; instead of here, so it survives peeking too; see the `set-keymap-parent'
    ;; block below `define-derived-mode'.
    (dolist (event cooked--mouse-events)
      (define-key map (vector event) #'cooked-mouse-event))
    ;; The wheel beside the text too, or a notch on the fringe of a child doing
    ;; a raw read is `mwheel-scroll' while the same notch a column to the right
    ;; is the child's; see `cooked--bind-wheel-areas'.
    (cooked--bind-wheel-areas map)))

(defvar cooked--meta-overlays nil
  "Alist of (MAP . OVERLAY), the cache behind `cooked--forwarding-map'.

Keyed by the map object rather than by name, and safe to keep across a
customization because a rebuild replaces the generated map *under* a public
one and never the public map itself -- so a cached overlay's parent stays the
map the user just changed.  See `cooked--public-keymap'.")

(defun cooked--build-meta-overlay (map &optional exceptions)
  "A child of MAP that forwards the Meta space as well, but for EXCEPTIONS.

MAP itself cannot carry that space.  `define-key' and `lookup-key' both
translate a Meta character into ESC plus the character, so `M-t' is stored and
found under an ESC prefix and nowhere else -- which means binding the Meta
space at all and forwarding ESC as a key of its own are mutually exclusive
within one keymap.  On a terminal frame that costs nothing: Escape and t are
two separately-forwarded bytes there, and the child sees `ESC t' either way.
On a graphical frame `M-t' is a single event, unbound by MAP, and reaches
Emacs' own binding for it instead -- which is the bug this exists to fix.

So the overlay makes ESC the prefix, and gives the Escape key back its
zero-latency spelling through `[escape]' -- the symbol a graphical frame
actually sends, which only decays to a bare ESC byte when nothing binds it.
`ESC O' and `ESC [' are left out of the prefix map, as `vterm' and `eat'
also leave them out: they begin the escape sequences every other key arrives
as, and a binding here would swallow one that had not been decoded yet.

The prefix covers every character, not only 0-127, so that \\`M-é' is
forwarded as `ESC é' like \\`M-e' -- the ESC map is a full keymap, whose
char-table answers for all of them at once.  Chords held with Super or Hyper
are bound as `cooked--build-passthrough-map' binds them, through
`cooked--kitty-chord'.

EXCEPTIONS are MAP's, as events, and only a Meta chord among them is kept
back here: an exception of `M-x' leaves `ESC x' unbound, so the chord
falls through to Emacs.  The rest of the Meta space forwards whatever MAP keeps.
An exception of `C-g' names an unmodified control character, and reserving
`C-M-g' along with it would take a key from the child on the strength of a
binding Emacs does not have."
  (let ((overlay (make-sparse-keymap)))
    (define-key overlay (vector meta-prefix-char)
                (cooked--build-meta-prefix-map exceptions))
    (define-key overlay [escape] #'cooked-send-key)
    (set-keymap-parent overlay map)
    overlay))

(defun cooked--build-meta-prefix-map (&optional exceptions)
  "The ESC prefix map of a Meta overlay, leaving the Meta chords in EXCEPTIONS out.

The only half of `cooked--build-meta-overlay' that depends on the exceptions
list, and so the only half `cooked--passthrough-setter' rebuilds: the overlay
itself keeps its identity, because a buffer may be wearing it."
  (let ((esc (make-keymap)))
    (dolist (event (cooked--super-chord-events nil))
      (define-key esc (vector event)
                  (cooked--kitty-chord #'cooked-send-meta-key
                                       (event-apply-modifier event 'meta 27 "M-"))))
    (set-char-table-range (nth 1 esc) t #'cooked-send-meta-key)
    (dolist (code (cooked--control-chord-events nil))
      (define-key esc (vector code) #'cooked-send-meta-key))
    ;; Unbound by storing nil, which in a char-table is no binding at all.
    (dolist (event (append '(?O ?\[)
                           (seq-keep (lambda (event)
                                       (and (memq 'meta (event-modifiers event))
                                            (event-convert-list
                                             (append (remq 'meta (event-modifiers event))
                                                     (list (event-basic-type event))))))
                                     exceptions)))
      (define-key esc (vector event) nil))
    esc))

(defun cooked--frame-keymap-type (&optional frame)
  "Which spelling of Meta a keymap worn on FRAME has to answer.

`graphic' where a Meta chord is a single event and `text' where it is two
forwarded bytes -- the only thing about a frame that a cooked keymap depends
on, named so that the dependency can be compared rather than re-derived.  See
`cooked--keymap-frame-type'."
  (if (display-graphic-p frame) 'graphic 'text))

(defvar-local cooked--keymap-frame-type nil
  "Frame type the local map now installed was built for, or nil.

Nil where the answer does not depend on a frame: `cooked-input-map' and
`cooked-peek-map' are worn as they are, and a buffer wearing one of them
cannot be stale however its windows move.

Set by `cooked--forwarding-map', which is the one place the frame is asked
about, and cleared by `cooked--state-keymap' before it chooses -- so the
record cannot drift from what was actually installed by anyone adding a state
that forwards or by anyone taking one away.")

(defvar cooked-raw-map)                 ; Both below, the map built from the option.
(defvar cooked-raw-exceptions)

(defun cooked--meta-exceptions (map)
  "The exceptions, as events, that MAP's Meta overlay has to leave out.

Only `cooked-raw-map' has any.  `cooked-alt-map' and `cooked-command-map'
keep nothing back by design, and `cooked-semi-map' is never worn through an
overlay, since it holds the whole Meta space back itself."
  (and (eq map cooked-raw-map)
       (mapcar #'cooked--exception-event cooked-raw-exceptions)))

(defun cooked--forwarding-map (map)
  "MAP as it should be worn on the selected frame.

MAP itself on a terminal frame, where it already forwards the Meta space a
byte at a time; its `cooked--build-meta-overlay' child on a graphical frame,
where it does not.  Asked at `use-local-map' time by `cooked--state-keymap',
so a buffer shown on both frame types at once wears whichever answer the last
refresh reached -- the alternative being to pay the overlay's one real cost,
Escape waiting for a Meta chord, on the terminal frames that never needed it.

Which answer that is, is recorded in `cooked--keymap-frame-type', because a
daemon serving one graphical frame and one terminal frame moves the buffer
between the two with no state change of its own to notice it:
`cooked--window-selection-changed' compares the record against the frame the
buffer has just been selected in and asks for a refresh only when they differ."
  (let ((type (cooked--frame-keymap-type)))
    (setq cooked--keymap-frame-type type)
    (if (eq type 'text)
        map
      (or (cdr (assq map cooked--meta-overlays))
          (let ((overlay (cooked--build-meta-overlay
                          map (cooked--meta-exceptions map))))
            (push (cons map overlay) cooked--meta-overlays)
            overlay)))))

(defun cooked--public-keymap (generated)
  "An empty keymap over GENERATED, for the user to bind in and keep.

Three of the maps here are rebuilt whenever the option that shapes them is set
-- `cooked-raw-map', `cooked--semi-forwarding-map' and `cooked-input-map' --
and each is also a variable the user is invited to bind in.  Those two cannot
be the same object: a rebuild replaces everything the builder made, which used
to take a `keymap-set' the user had made with it, silently, on the next
`setopt' of the list.

So the public map holds nothing of its own.  Everything the builder made lives
in GENERATED, its parent, which is what `cooked--regenerate-keymap' swaps; a
user's binding lands in the public map, in front of the generated one it
shadows, which is also the order a user expects.  The map object stays the one
`use-local-map' was handed and the one `cooked--meta-overlays' is keyed by."
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map generated)
    map))

(defun cooked--generated-keymap (map)
  "The generated half of MAP, the map its option's `:set' replaces.

MAP itself keeps only the user's bindings, so this is where a parent has to be
stored as well: `cooked-mode-map' is set as the parent of this map and not of
MAP, or the next rebuild would name the map it just retired.  See
`cooked--public-keymap'."
  (keymap-parent map))

(defun cooked--regenerate-keymap (map fresh)
  "Put FRESH under MAP as its generated half, in place of the one there now.

MAP, its bindings and whatever sat beneath the old generated map all survive,
so this is the whole of a rebuild: no map is edited, and nothing holding MAP as
its parent -- `cooked-semi-map', a Meta overlay, evil's minor-mode keymap --
has to hear about it."
  (set-keymap-parent fresh (keymap-parent (cooked--generated-keymap map)))
  (set-keymap-parent map fresh))

(defun cooked--passthrough-setter (map &optional reserve-chords)
  "A `defcustom' `:set' rebuilding MAP's generated half for its value.

The value is a list of key strings naming the keys to keep for Emacs;
RESERVE-CHORDS means what it does in `cooked--build-passthrough-map'.  MAP is
named rather than passed, and checked for at call time, because the maps are
defined below the options that configure them -- the option has to exist first
for the `defvar' to read it.

A Meta overlay already built for MAP has its ESC prefix rebuilt too, since a
Meta chord among the exceptions is left out there rather than in MAP.  The rest
of the overlay does not depend on the list, and the overlay object itself must
not change: a buffer may be wearing it right now."
  (lambda (symbol value)
    (set-default symbol value)
    (when (and (boundp map) (keymapp (symbol-value map)))
      (let ((events (mapcar #'cooked--exception-event value))
            (keymap (symbol-value map)))
        (cooked--regenerate-keymap
         keymap (cooked--build-passthrough-map events reserve-chords))
        (when-let* ((overlay (cdr (assq keymap cooked--meta-overlays))))
          (define-key overlay (vector meta-prefix-char)
                      (cooked--build-meta-prefix-map events)))))))

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

Each entry names a single key via `kbd', e.g. \"C-g\", or \"C-;\" for a Control
chord a graphical frame would otherwise forward.  \\`C-y' is deliberately not
offered here even though it would otherwise be a plausible candidate: it is both
vim's scroll-up-a-line and readline's own yank, real bindings a user relying on
the child is actively using.  A Meta chord such as \"M-x\" is accepted, and is
kept on a graphical frame, where `cooked--build-meta-overlay' is what binds the
Meta space and leaves it out.  On a terminal frame it cannot be: a bare ESC byte
is forwarded the instant it is pressed, for the sake of a real terminal's Escape
key having no latency, so `ESC' and the letter that follows are two
independently-forwarded bytes before Emacs' own Meta-prefix logic ever runs.
`C-c M-x' remains the one escape hatch guaranteed to work regardless of frame
type.

`cooked-send-literal-key' (\\`C-c C-q') sends any one key through to the child
regardless of this list, for a raw program that wants one of these keys back."
  :type '(repeat string)
  :set (cooked--passthrough-setter 'cooked-raw-map)
  :group 'cooked)

(defvar cooked-raw-map
  (cooked--public-keymap
   (cooked--build-passthrough-map
    (mapcar #'cooked--exception-event cooked-raw-exceptions)))
  "Keymap while the child is doing a raw, non-alt-screen read.

What `cooked-raw-exceptions' shapes is the generated map beneath this one, so a
`keymap-set' here stays put across a `setopt' of the list and shadows what the
list left forwarding; see `cooked--public-keymap'.")

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
  "Keys `cooked-semi-map' keeps for Emacs, besides the chords it always keeps.

The same idea as `cooked-raw-exceptions', asked in a different place: that
list hedges a state cooked is unsure about, this one describes a state the
user has chosen.  ESC, the whole Meta space and the Control chords no character
names -- `C-;', `C-SPC' on a graphical frame -- are held back as well, and are
not listed here -- see `cooked-semi-map'.  Entries are `kbd' strings naming one
key each, as for `cooked-raw-exceptions'.

`cooked-send-literal-key' (\\`C-c C-q') sends any one of these through to the
child anyway, for the program that wants it back."
  :type '(repeat string)
  :set (cooked--passthrough-setter 'cooked--semi-forwarding-map t)
  :group 'cooked)

(defvar cooked--semi-forwarding-map
  (cooked--public-keymap
   (cooked--build-passthrough-map
    (mapcar #'cooked--exception-event cooked-semi-exceptions) t))
  "What `cooked-semi-map' forwards, with nothing but its generated half beneath.

`cooked-semi-map' is this and `cooked-mode-map' beneath it.  Kept apart because
evil needs the forwarding alone: cooked-evil.el puts it above evil's insert
state maps, and `cooked-mode-map' would put `comint-mode-map''s `<delete>' and
its Meta bindings above them too.  The chain ends at the generated map, which
`cooked-semi-exceptions' rebuilds; see `cooked--public-keymap'.")

(defvar cooked-semi-map
  (make-composed-keymap cooked--semi-forwarding-map)
  "Keymap for forwarding that stops short of taking Emacs away.

The other passthrough maps answer \"the child needs every key\" and reserve `C-c'
only, which is right for a full-screen program and wrong for the state an
`evil' user spends most of their time in.  Insert state is supposed to be a
state you can leave: if ESC forwards, the way out is gone, and if every Meta
chord forwards, so is `M-x' and so is the non-normal leader most `evil'
configurations put on `M-SPC'.

So this map holds back four things: `cooked-semi-exceptions'; ESC; the entire
Meta space, because ESC unbound is what makes Emacs treat it as
`meta-prefix-char' again; and the Control chords a graphical frame has with no
character behind them, which is where embark, avy and a mark on `C-SPC' live.
Everything else still goes to the child, `C-a'/`C-e'/`C-k'/`C-r' included,
which is the half that matters: those are readline's and vim's, and a rule of
\"Emacs wins wherever Emacs has a binding\" would have taken all of them,
`global-map' binding almost every control character.  That is the same
conclusion `vterm' and `eat' reached -- `vterm-keymap-exceptions' and
`eat-semi-char-non-bound-keys' are both explicit lists over an otherwise total
map, for this reason.

The cost is ESC's latency: unbound here, it waits to see whether a Meta chord
follows.  That is why the full maps keep forwarding it instead, and why this
map is not the default anywhere.  `cooked--build-meta-overlay' makes ESC a
prefix too, but only on a graphical frame and only for characters, where the
Escape key arrives as `escape' and is bound alongside; here the point is for
ESC to reach Emacs, so there is nothing to bind it to.

The bindings live in `cooked--semi-forwarding-map', which this composes, so
evil can wear them without this map's parent; see `cooked--semi-map-worn'.

\\`C-c C-q' is the way through for any one key this map keeps --
`cooked-send-literal-key' reads the event itself rather than looking it up
here.")

(defvar-local cooked--semi-map-worn nil
  "Whether `cooked-semi-map' is the local map, set by `cooked--state-keymap'.

A variable because evil asks it as one.  Evil's insert state maps sit in
`emulation-mode-map-alists', above every local map, so from insert state
`S-<return>', `C-r' and `C-w' ran evil's commands and never reached the
child.  cooked-evil.el hangs `cooked--semi-forwarding-map' on an evil
minor-mode keymap switched by this variable, which Emacs reads on every key,
so the forwarding sits above evil exactly while this map is worn and never
at a prompt.")

(defun cooked--peek-resume-and-send ()
  "End peek and forward the key that invoked this command to the child.

Bound in `cooked-peek-map' wherever a key would otherwise self-insert or
submit a line: typing while peeking can only mean one thing, so there is no
reason to make resuming forwarding a separate step from it.  `cooked-send-key'
already snaps point to the child's cursor before sending, which is also
exactly where the ghost cursor was pointing the whole time peek was frozen."
  (interactive)
  (cooked--resume-forwarding)
  (cooked-send-key))

(defvar-keymap cooked-peek-map
  :doc "Keymap while forwarding is suspended, in `still' or `frozen'.

A child of `cooked-mode-map', not `cooked-mode-map' itself: binding the
`self-insert-command' remap there would also reach `cooked-input-map', which
needs ordinary self-insertion to keep editing pending input at a real prompt.
Typing here can only mean the child is wanted back, so it ends peek and
forwards the key that was pressed instead, same as `cooked-raw-map'/
`cooked-alt-map' would have without the interruption -- see
`cooked--peek-resume-and-send'.  Everything else -- motion, search, yanking a
selection as a copy, `cooked-toggle-fold' -- falls through to `cooked-mode-map'
and `comint-mode-map' beneath it exactly as it always did."
  "<remap> <self-insert-command>" #'cooked--peek-resume-and-send
  "RET" #'cooked--peek-resume-and-send
  "<return>" #'cooked--peek-resume-and-send)

(defun cooked-send-literal-key ()
  "Send the next key to the child exactly, regardless of what it is bound to.

`cooked-raw-exceptions' (and, always, `C-c') keep some keys for Emacs while
the child owns the keyboard; this is the way back the other direction, for a
child that wants one of those keys for itself -- a readline-based REPL's own
\\`C-u', say.  Reaches \\`C-c' too: \\`C-c C-q C-c' sends a literal \\`C-c' byte.

Bound on `cooked-mode-map', so it also reaches the child while peeking -- ending
peek first, so the result is seen immediately -- but refuses once Emacs owns
the line -- see `cooked-send-string', which shares the reasoning."
  (interactive)
  (cooked--send-forced-key
   (lambda ()
     (let ((event (read-key "Send key: ")))
       ;; With hover on, the pointer drifting while the key is awaited is a key
       ;; too, and `read-key' returns it; the key meant for the child would then
       ;; reach Emacs instead.
       (while (mouse-movement-p event)
         (setq event (read-key "Send key: ")))
       event))))

(defun cooked-send-escape ()
  "Send the Escape key to the child, whatever ESC is bound to here.

The inverse of \\`C-c C-c' in a terminal.  There, a key the child owns needs
the prefix to reach Emacs; in evil's insert state ESC is Emacs' -- it is how
insert state is left -- so it is Escape for the child that needs the prefix.
\\`C-c <escape>' on a graphical frame.  A terminal frame cannot tell that
from the start of \\`C-c M-x', so there it is \\`C-c ESC ESC', which a
graphical frame accepts as well.

Sent as the `escape' key rather than as a bare byte, so a child that
negotiated the kitty keyboard protocol gets its spelling of it.  Otherwise
as `cooked-send-literal-key': ends peek first, and refuses once Emacs owns
the line."
  (interactive)
  (cooked--send-forced-key (lambda () 'escape)))

(defun cooked--send-forced-key (read)
  "Send the event READ returns to the child, past every binding.
READ is called only once forwarding has resumed and the line is known to be
the child's, so a prompt it shows is not left waiting for nothing."
  (cooked--resume-forwarding)
  (when (cooked--input-state-p)
    (user-error "Emacs already owns the line; type directly instead"))
  (cooked--send-key-event (funcall read)))

;;;; The map Emacs owns the line through

(defun cooked--build-input-map (delegated)
  "A fresh input-line keymap, with DELEGATED keys handed to the child.

Spelled as a builder rather than a literal for the same reason
`cooked--build-passthrough-map' is: `cooked-delegate-keys' can change at any
time, and rebuilding is the only way to put back a key that was
delegated.  Unbinding it instead would leave `TAB' bound to nothing rather
than to `completion-at-point'."
  (let ((map (define-keymap
               "RET" #'cooked-send-input
               "S-<return>" #'cooked-newline
               ;; The spelling `evil-collection' binds beside `S-<return>', so
               ;; the two answer the same at a prompt; see
               ;; `cooked-evil--prompt-keys'.
               "S-RET" #'cooked-newline
               "C-d" #'cooked-delete-char-or-eof
               "TAB" #'completion-at-point
               "M-p" #'cooked-previous-input
               "M-n" #'cooked-next-input
               ;; The remap rather than `C-a' itself, so that whatever key a
               ;; user has put start-of-line on reaches it, and so that nothing
               ;; is claimed in the maps the child is being forwarded through --
               ;; `C-a' there is readline's own start-of-line, or tmux's prefix,
               ;; and it must arrive untouched.
               "<remap> <move-beginning-of-line>" #'cooked-beginning-of-line)))
    ;; Last, so a delegated key wins over the binding it replaces -- which is the
    ;; point of naming it.
    (dolist (key delegated)
      (keymap-set map key #'cooked-delegate-this-key))
    map))

(defvar cooked-input-map
  ;; `cooked-delegate-keys' is defined below and cannot be read here; its `:set'
  ;; is what keeps the two in step from load onwards.
  (cooked--public-keymap (cooked--build-input-map '("C-r")))
  "Keymap while Emacs owns the input line.

Cooked's own `C-c'-prefixed commands (interrupt, EOF, paste, and the rest)
are not repeated here -- they live on `cooked-mode-map', reached through this
map's generated half, so the same set reaches `cooked-raw-map'/`cooked-alt-map'
and a bare peek without being declared three times over.

`cooked-delegate-keys' shapes that generated half and not this map, so a
`keymap-set' here survives a change to the option; see
`cooked--public-keymap'.")

(defun cooked-delegate-key (key)
  "Hand the pending input to the child's line editor, then send KEY to it.

The primitive behind `cooked-delegate-keys', and deliberately not a completion
feature: nothing here knows what KEY means.  Send `C-r' and you get fzf or
atuin; send the up arrow and you get the shell's own history, with
`share_history', `zsh-histdb' and every `bindkey' the user has
accumulated.  That is worth more than any of it could be reimplemented for,
because `comint-input-ring' here is fed only by `cooked--history-record'
from what was typed in *this* buffer and so starts empty every session.

Three things have to happen in this order.

Ownership is dropped *first*.  The line is about to be echoed by the shell, and
a buffer that still believes it owns an input region would render it a second
time on top.  The text is left in place rather than deleted, for the reason
`cooked-send-input' leaves it: the echo redraws identical characters over the
same cells and nothing moves, where deleting it would empty the row for the one
redisplay it takes to come back.

The *whole* line is sent, not the part before point.  Sending the prefix would
silently drop whatever followed the cursor, and the left-arrows that avoid it
cost one byte each.

Then KEY, once the shell's cursor is back where the user's was.  Getting it
there is the child's own left arrow, spelled once through `cooked--encode-key'
and repeated: under DECCKM the shell reads `ESC O D' for that key, not the
`ESC [ D' a hand-written escape would send, and a line editor that never sees
the byte it asked for leaves the cursor short of where the rest of the line
expects it.

The pasted parts of the line are stripped of control bytes on the way, as a
submitted line's are by `cooked--send-input-string', because the line reaches
the line editor as typing: an ESC yanked into it would be read as the start of a
key sequence.  What was typed goes as typed, and KEY is not stripped, since
sending a control key is what it is for."
  (unless (cooked--input-state-p)
    (user-error "The child already owns the line"))
  (pcase-let* ((`(,start . ,end) (cooked--input-region))
               (text (cooked--strip-pasted-controls
                      (cooked--input-substring start end)))
               (after (- end (max start (min (point) end))))
               (left (cooked--encode-key (cooked--require-session) 'left nil
                                         (cooked--assumed-key-protocol))))
    (cooked--clear-input-region)
    (setf (cooked-line-delegated (cooked--line)) t)
    (cooked--request-refresh)
    (cooked--send-to-child
     (concat text (apply #'concat (make-list after left)) key))))

(defun cooked-delegate-this-key ()
  "Delegate the pending input and send the key that invoked this command.
See `cooked-delegate-key' and `cooked-delegate-keys'."
  (interactive)
  (when-let* ((bytes (cooked--encode-key-event last-command-event
                                               (cooked--assumed-key-protocol))))
    (cooked-delegate-key bytes)))

(defcustom cooked-delegate-keys '("C-r")
  "Keys that hand the line to the child's line editor before being sent.

Each is a `kbd' string, bound in `cooked-input-map' -- so they apply only
where Emacs owns the line, which is the only place there is anything to hand
over.

`C-r' is the default because reverse history search is the clearest case for
delegating: the flow is search, accept, Enter, so the line goes back to the
shell at a point where Emacs editing was not going to be wanted again anyway,
and the alternative is a history ring that knows nothing of the shell's.

`TAB' is deliberately *not* here.  Delegation is a one-way door for the rest
of the line, and losing the Emacs input region must never be a side effect of a
key pressed fifty times an hour; `TAB' stays `completion-at-point' at every
level, and what answers it changes with the tier while what it means does not.
Putting it here is supported and reasonable -- it is how a shell with marks but
no completion channel reaches `git checkout <TAB>' -- but it should be chosen."
  :type '(repeat string)
  :set (lambda (symbol value)
         (set-default symbol value)
         (when (and (boundp 'cooked-input-map) (keymapp cooked-input-map))
           (cooked--regenerate-keymap cooked-input-map
                                      (cooked--build-input-map value))))
  :group 'cooked)

;;;; A real `escape' on a tty

(defcustom cooked-tty-escape-delay 0.01
  "How long to wait for a byte after ESC before calling it a lone ESC, or nil.

On a graphical frame Emacs already distinguishes the ESC *key* from the ESC
*byte* that starts an escape sequence, and binds the first as `escape'.  On a
terminal frame it cannot: both arrive as the same byte, and the only thing
telling them apart is that a sequence's remaining bytes follow immediately.  So
a tty Emacs has no `escape' event at all, and configuration keyed on one --
which is most evil configuration -- silently does nothing there.

This is the same wait a terminal Emacs already makes for `ESC' as Meta, spelled
so that the answer is an event rather than a prefix.  10ms is ghostel's number
and is below the threshold at which a delay on a *deliberate* keypress is
noticeable; it is never paid on a real escape sequence, because the following
byte is already in the queue.

nil disables the translation entirely."
  :type '(choice (const :tag "No `escape' event on a tty" nil) number)
  :group 'cooked)

(defun cooked--tty-esc (map)
  "Translate a lone ESC to `escape', or answer MAP to decode as usual.

The `:filter' of a `menu-item' entry on ESC in `input-decode-map'.

*Only where the child is not reading the keyboard*, which is a deliberate
departure from ghostel.  ESC is how you leave insert mode in the vim running
inside the terminal, and a translation that reached it would be a bug of exactly
the kind nobody would connect to this setting.  Where Emacs owns the line there
is no such claim on the byte, and an `escape' event is strictly more than a tty
had before.

The `[27 27]' guard is ghostel's and is not optional: the first ESC of a fast
pair is already committed by the time the second decodes, so translating the
second leaves `ESC ESC' looking for an unbound `ESC <escape>' instead of
reaching its own binding."
  (if (and cooked-tty-escape-delay
           cooked--session
           (not (cooked--child-owns-keyboard-p))
           (let* ((keys (this-single-command-keys))
                  (len (length keys)))
             (and (> len 0)
                  (eq (aref keys (1- len)) ?\e)
                  (not (and (> len 1) (eq (aref keys (- len 2)) ?\e)))))
           (sit-for cooked-tty-escape-delay))
      [escape]
    map))

(defun cooked--tty-esc-init (&optional frame)
  "Install the lone-ESC filter on FRAME's terminal, if it is a text one.

Re-wraps when another package has replaced the entry since, and composes rather
than replaces -- whatever was there is wrapped, so evil's own filter still runs,
and at most one translation delay is paid per key.

Two details that look like paranoia and are not, both ghostel's.  The entry is
read *structurally* with `assq' rather than with `lookup-key', because
`lookup-key' resolves a `menu-item' filter to the map behind it, silently
dropping another package's wrapper on the way past.  And our own wrapper is
recognised by its `:filter' symbol rather than by identity, because
`define-key' copies the `menu-item' list and identity would never match, so
every call would wrap again.

Inert outside a cooked buffer with a live child, so nothing uninstalls it."
  (let ((terminal (frame-terminal frame)))
    (when (eq (terminal-live-p terminal) t)
      (with-selected-frame (or frame (selected-frame))
        (let* ((cell (assq ?\e (cdr input-decode-map)))
               (raw (if cell (cdr cell) (lookup-key input-decode-map [?\e]))))
          (unless (and (eq (car-safe raw) 'menu-item)
                       (eq (cadr (memq :filter raw)) 'cooked--tty-esc))
            (define-key input-decode-map (vector ?\e)
              `(menu-item "" ,raw :filter cooked--tty-esc))))))))

;;;; Who owns a click or a RET on a link

;; cooked-link.el is base tier and cannot ask this: the answer depends on the mouse
;; grab, on whether keys are being forwarded and on whether the session is suspended,
;; and a base-tier file reaching upward for policy is the one thing `docs/DESIGN.md'
;; rules out.  So the link layer states the occasion and this file, which already owns
;; every one of those three states, decides.

(defun cooked--link-delegate (event)
  "Hand EVENT to the child if the child owns it, and say whether that happened.

`cooked-link-delegate-function', so the answer is nil when the invocation
belongs to Emacs and the link should be followed.

The gate is not politeness, it is a documented guarantee.  A `keymap' text or
overlay property is consulted *before* `emulation-mode-map-alists', so the
binding `cooked-follow-link' sits on outranks `cooked--mouse-map' -- and a
plain click while the child has grabbed the mouse belongs to the child, with
Shift as the sanctioned escape.  Without that rule a click meant for the
program underneath would follow a link instead.  The same holds for RET while
keys are being forwarded.

Only the unshifted case reaches here; cooked-link.el filters the rest, because
`S-RET' and a shifted click following the link regardless of state is what
keeps a link reachable at all inside a full-screen program."
  (cond
   ((mouse-event-p event)
    (when (bound-and-true-p cooked--mouse-grab)
      ;; Taken, but not forwarded again: under `cooked--mouse-falling-back' this
      ;; click has already been through `cooked-mouse-event' and was declined
      ;; there, and the only reason it reached a link binding at all is that the
      ;; fallback cannot lift a `keymap' text property out of the lookup.
      (unless cooked--mouse-falling-back (cooked-mouse-event))
      t))
   ((and (cooked--child-owns-keyboard-p) (not (cooked--suspended-p)))
    (cooked-send-key)
    t)))

(setq cooked-link-delegate-function #'cooked--link-delegate)

(provide 'cooked-keymaps)
;;; cooked-keymaps.el ends here
