;;; cooked-color.el --- The colours a buffer draws with, as the child sees them -*- lexical-binding: t; -*-

;;; Commentary:

;; The native core has no default foreground or background at all: those are
;; whatever this buffer's faces resolve to under the user's theme.  So everything
;; a child can ask or change about them is answered here -- OSC 10, 11 and 12
;; for the defaults and the cursor, OSC 4 for the palette, the light or dark
;; scheme the core reports for mode 2031, and DECSCNM, which draws the whole
;; screen with the two defaults swapped.
;;
;; It sits on cooked-osc.el, which dispatches the OSC queries to it, and is read
;; by the drain pipeline for DECSCNM.

;;; Code:

(require 'face-remap)
(require 'cooked-util)
(require 'cooked-face)
(require 'cooked-osc)

(declare-function cooked--reblend-shades "cooked-deco")

(cooked--declare-core)

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

(defvar-local cooked--color-remaps nil
  "Alist of color kind to face remapping cookie, so OSC 110/111 can undo a set.")

(defvar-local cooked--cursor-color nil
  "The cursor color an OSC 12 set asked for, or nil.
Not a face remap like the other two; see `cooked--sync-cursor-color'.")

(defconst cooked--osc-color-sources
  '((10 . foreground) (11 . background) (12 . cursor)
    (13 . pointer-foreground) (14 . pointer-background)
    (15 . tek-foreground) (16 . tek-background)
    (17 . highlight-background) (18 . tek-cursor) (19 . highlight-foreground))
  "Which color each OSC code asks about.

Every code xterm answers from 10 to 19, because a child that asks one of them
alone waits for the answer.  13 and 14 are the mouse pointer, which Emacs draws
in the `mouse' face's background over the default background.  15, 16 and 18
are the colours of xterm's Tektronix window.  There is no such window here, so
they are the colours the Tektronix window would have taken them from: the
default foreground and background, and the cursor.  17 and 19 are xterm's
selection colours, and the `region' face is what Emacs selects with, so that is
where they are read from.")

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
                 ('pointer-foreground (or (face-background 'mouse nil t)
                                          (frame-parameter nil 'mouse-color)))
                 ('pointer-background (cooked--default-color 'background))
                 ('tek-foreground (cooked--default-color 'foreground))
                 ('tek-background (cooked--default-color 'background))
                 ('tek-cursor (cooked--default-color 'cursor))
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
  "Whether this buffer renders dark or light, as `dark' or `light'.

Derived from `cooked--child-color', which is what OSC 11 answers from, rather
than from `frame-background-mode' — and that is the whole point.  A child told
the scheme changed reacts by querying OSC 11 for the actual background, so two
readings of one value cannot be allowed to contradict each other.

`color-dark-p' is what `frame--current-background-mode' uses to derive
`frame-background-mode' in the first place, gamma correction and empirical
cutoff included, so with nothing remapped this agrees with Emacs' own answer
rather than approximating it."
  (if (color-dark-p (mapcar (lambda (v) (/ v 65535.0))
                            (color-values (cooked--child-color 'background))))
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
    (cooked--reply-if-live bytes)))

(add-hook 'cooked-theme-change-hook #'cooked--sync-color-scheme)

;;;; The palette the core answers from
;;
;; A colour query has one true answer and Lisp is the only one who knows it, but knowing
;; it is not the same as having to be woken for it.  So the answers are pushed down --
;; the ten colours OSC 10 to 19 name and all 256 palette entries -- and the core replies
;; to every colour query where it arrives, as it already replies to `CSI ? 996 n' from
;; the colour scheme.  A start-up probe costs the child nothing but the reply, instead of
;; a wake, a drain and a reply batch behind `cooked-min-redisplay-interval'.
;;
;; One owner each: the core answers, and this file owns the values and the policy.  A
;; sequence that *sets* a colour still comes here, because whether a set is honoured is
;; `cooked-allow-color-set' and the answer to a `?' chained after it turns on that; the
;; set is applied or refused, the palette is pushed again, and the core is asked for the
;; reply through `cooked--answer-color-query'.  So nothing in Lisp composes a colour
;; reply, and there is one reading of the fields and one formatter.

(defvar cooked--palette-cube nil
  "The rgb triples of xterm colour indices 16 to 255, built on first use.

Those are a pure function of the index -- see `cooked--xterm-256' -- so, unlike
the sixteen below them, they follow no theme and are worth building once for
every session and every push that follows.")

(defvar-local cooked--pushed-palette nil
  "What `cooked--sync-palette' last told the core, so it can skip saying it again.

The cursor colour is one of the answers, and it moves with the selected window,
so the push runs on every window change in every session.  Nearly all of those
have nothing to report, and the comparison is what keeps them from marshalling
266 colours across the module boundary to say so.")

(defun cooked--palette-colors ()
  "The 256 palette entries a child may ask for, index 0 first.

Each is `color-values' of what `cooked--color' answers, which is the function
that paints cells: what a query is told is the colour a cell in that index is
actually drawn in, rather than a second table that could disagree with it.

An entry that resolves to nothing falls back to `cooked-color-names' -- a tty
frame can leave an `ansi-color-' face reading as `unspecified-fg', which has no
value to report -- and is nil only if that fails too, which the core answers
with silence, as this file did."
  (append (cl-loop for index below 16
                   collect (or (color-values (cooked--color index))
                               (color-values (aref cooked-color-names index))))
          (or cooked--palette-cube
              (setq cooked--palette-cube
                    (cl-loop for index from 16 below 256
                             collect (color-values (cooked--xterm-256 index)))))))

(defun cooked--palette-defaults ()
  "The ten colours OSC 10 to 19 ask about, in that order.

`cooked--child-color' is what each of them answers, with one difference: the
two defaults are given unswapped, as `cooked--screen-color' has them, because
reverse video is the child's own mode and the core exchanges the pair at the
query rather than trusting a level that may have moved since this ran."
  (cl-loop for code from 10 to 19
           for kind = (alist-get code cooked--osc-color-sources)
           collect (color-values
                    (if (memq kind '(foreground background))
                        (cooked--screen-color kind)
                      (cooked--default-color kind)))))

(defun cooked--sync-palette ()
  "Tell this buffer\\='s child the colours Emacs draws it with.

Everything that can move one of these answers ends up here: a theme, through
`cooked-theme-change-hook\\='; an OSC 10, 11 or 12 set or reset, which reaches
that same hook through `cooked--flush-face-cache\\='; the frame\\='s cursor colour,
through `cooked--resync-palettes\\=' on the window hooks `cooked--sync-cursor-color\\='
already runs on; and the spawn, so a child that probes in its first instant is
answered.

The one thing not covered is `set-cursor-color\\=' by itself, which changes a
frame parameter and runs no hook at all: a query between that and the next
window change is answered with the cursor colour the frame had before it."
  (when-let* ((session (cooked--live-session)))
    (let ((palette (cons (cooked--palette-defaults) (cooked--palette-colors))))
      (unless (equal palette cooked--pushed-palette)
        (setq cooked--pushed-palette palette)
        (cooked--set-palette session (car palette) (cdr palette))))))

(defun cooked--resync-palettes (&rest _)
  "Tell every session the colours it draws with now.

For the changes that are not the buffer\\='s own: the frame\\='s cursor colour is
what OSC 12 answers with, and it moves when another window is selected or shows
something else.  `cooked--sync-palette\\=' compares before it pushes, so the
ordinary window change costs each session a handful of face lookups and no call
into the core."
  (cooked--dolist-buffers (cooked--sync-palette)))

(add-hook 'cooked-theme-change-hook #'cooked--sync-palette)

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
  "Apply the OSC 10 to 19 sets in PARTS, and have the core answer its queries.

Several requests may be chained -- `ESC ] 10 ; ? ; ? ST\\=' asks for the
foreground and then the background -- so each part is about the next code along.
A `?\\=' is a query; anything else is a set, which needs `cooked-allow-color-set\\='
and is only ever honoured for the kinds in `cooked--osc-settable-colors\\='.

A sequence of nothing but queries never arrives here at all: the core holds
every colour these codes name and answers where the query lands.  What arrives
is a sequence holding a set, because whether the set is honoured is policy and
the answer to a `?\\=' chained after it depends on the outcome.  So the sets are
applied first, the palette is pushed, and the core is asked for the reply --
which keeps one formatter and one reading of the fields, and keeps the reply in
its place in the order, since it is this turn that releases it."
  (let ((code cooked--osc-code))
    (dolist (part parts)
      (when-let* (((not (equal part "?")))
                  (kind (alist-get code cooked--osc-color-sources))
                  ((and cooked-allow-color-set
                        (memq kind cooked--osc-settable-colors))))
        (cooked--set-default-color kind part))
      (setq code (1+ code))))
  ;; Unconditional, and cheap because only a sequence holding a set reaches here: a set
  ;; that landed has already pushed through the face cache flush, and saying it again is
  ;; how this function does not have to know that.
  (cooked--sync-palette)
  (when-let* ((bytes (cooked--answer-color-query cooked--session cooked--osc-code parts
                                                 cooked--osc-bell-terminated)))
    (cooked--queue-reply cooked--session bytes)))

(defun cooked--set-default-color (kind spec)
  "Remap this buffer's default KIND to SPEC, if it parses.
Buffer-local rather than frame-wide: a child gets to repaint its own terminal,
not every window in the Emacs running it.  The cursor is the exception, because
Emacs has no buffer-local cursor colour to give it; see `cooked--cursor-color'.

A `background' set also remaps `fringe', not just `default': the fringe is
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
handled and `oc' has been dropped from terminfo/cooked.ti to say so.  There is
no palette here to reset -- OSC 4 answers queries but declines every set, for
the reason that entry gives, that Emacs owns colour and a per-buffer 256-entry
palette is the wrong seam -- so the only colours a child can have changed are
the three defaults above, and each of those already has its own undo."
  (when-let* ((kind (alist-get (- cooked--osc-code 100) cooked--osc-color-sources)))
    (cooked--reset-default-color kind)
    ;; The colour the core answers with has just moved back; see `cooked--osc-color'
    ;; for why this says so here rather than relying on the face cache flush.
    (cooked--sync-palette)))

;;;; OSC 12 — the cursor, worn by the frame
;;
;; The other two defaults are face remaps, but OSC 12 cannot be one.  Emacs
;; draws every cursor in its frame's `cursor-color' parameter, which the `cursor'
;; face feeds only through the frame-wide face, so a buffer-local remap of
;; `cursor' changes what the buffer's faces say and not a single pixel.
;;
;; So the frame wears the colour while a cooked buffer that set one is in its
;; selected window, and takes its own back the moment that stops.  Two things
;; follow from there being one colour per frame.  While the cooked window is
;; selected, the hollow cursors other windows on the frame
;; draw are in its colour too; those are the cursors of windows you are not
;; typing in, and the alternative of declining OSC 12 outright costs the cursor
;; you are.  And the colour given back is whatever the frame had when the child's
;; went on, unless something else -- a theme, `set-cursor-color' -- has changed
;; it since, in which case that newer colour is the one given back.

(defun cooked--set-cursor-color (color)
  "Make COLOR, or nil for none, this buffer's OSC 12 cursor color.
Applied at once to every frame whose selected window shows this buffer."
  (setq cooked--cursor-color color)
  (cooked--sync-cursor-color-everywhere))

(defun cooked--frame-cursor-color (frame)
  "FRAME's own cursor color, beneath any OSC 12 color it is wearing.

The frame parameter `cooked--cursor-color' records what is worn, as a cons of
the color put on and the color it replaced.  When the frame's `cursor-color'
no longer matches the first, something other than `cooked--sync-cursor-color'
changed it, and that newer color is the frame's own."
  (let ((current (frame-parameter frame 'cursor-color))
        (worn (frame-parameter frame 'cooked--cursor-color)))
    (if (and worn (equal (car worn) current)) (cdr worn) current)))

(defun cooked--sync-cursor-color (frame)
  "Put on or take off FRAME's OSC 12 cursor color, for its selected window.
What is taken off is replaced by `cooked--frame-cursor-color'.

The frame's half alone; `cooked--cursor-color-changed' is what the two window
hooks run, and it tells the sessions afterwards."
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
  "Run `cooked--sync-cursor-color' on every frame, then re-tell every session."
  (mapc #'cooked--sync-cursor-color (frame-list))
  (cooked--resync-palettes))

(defun cooked--cursor-color-changed (frame)
  "Put FRAME\\='s OSC 12 colour on or take it off, then re-tell every session.

The hook function, where `cooked--sync-cursor-color\\=' is the frame\\='s half alone.
OSC 12 answers with the colour of the frame whose window is selected, so a
selection change moves the answer for every session and not only for the buffer
that gained or lost the window."
  (cooked--sync-cursor-color frame)
  (cooked--resync-palettes))

(defun cooked--sync-cursor-color-here ()
  "Sync the cursor color of each frame whose selected window shows this buffer.

On `cooked-theme-change-hook', since a theme that sets the `cursor' face
repaints the frame's cursor without any window changing.  That hook runs once
in every cooked buffer, so syncing every frame from it did the whole job once
per buffer.  A frame wears a color only while its selected window shows the
buffer that set it, so the frames showing this buffer are all this run has to
look at, and the runs in the other buffers cover the rest."
  (dolist (window (get-buffer-window-list nil nil t))
    (when (eq window (frame-selected-window (window-frame window)))
      (cooked--sync-cursor-color (window-frame window))))
  ;; After the frames, not before: the palette push reads the cursor colour the
  ;; syncing above has just put on, and `cooked-theme-change-hook' makes no promise
  ;; about the order of its own entries.
  (cooked--sync-palette))

(add-hook 'cooked-theme-change-hook #'cooked--sync-cursor-color-here)

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
;;
;; There is no handler here any more.  `cooked--palette-colors' is where the 256
;; answers are decided and the core is told all of them, and since a set changes
;; nothing there is never anything for Lisp to decide about an OSC 4 -- so the whole
;; sequence, queries and sets together, is finished where it arrives.

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
  "Whether the screen is drawn in reverse video, DEC mode 5.
The child's own setting, `cooked--reverse-screen-level', except while a flash
is held; see `cooked--set-reverse-screen'.")

(defvar-local cooked--reverse-screen-level nil
  "Whether the child wants the screen in reverse video, as of the last drain.")

(defvar-local cooked--reverse-screen-toggles 0
  "The drain's count of DECSCNM changes, as of the last drain.")

(defvar-local cooked--flash-timer nil
  "The timer ending a flash `cooked--set-reverse-screen' is holding, or nil.")

(defconst cooked--flash-seconds 0.1
  "How long a flash that arrived inside one drain is shown for.
The pause `flash' in our terminfo makes between its set and its reset.")

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

(defun cooked--child-color (kind)
  "The color KIND is, as a query from the child is answered.

For the two defaults that is the color the buffer draws: an OSC 10 or 11 set
counts, and under DECSCNM the two are swapped, as xterm swaps its own.  So a
child that set its background to #ff0000 and asks for it back is told #ff0000,
and not the theme's color, which `face-background' reads without the remap.
Every other kind is `cooked--default-color''s."
  (pcase kind
    ((or 'foreground 'background)
     (let ((other (if (eq kind 'foreground) 'background 'foreground)))
       (cooked--screen-color (if cooked--reverse-screen-level other kind))))
    (_ (cooked--default-color kind))))

(defun cooked--reversible-color (kind)
  "The color `cooked--apply-reverse-screen' swaps in for KIND.

`cooked--screen-color', except on a text terminal that has not said what its
default colors are.  There `cooked--default-color' can only guess black or
white, but the names `unspecified-fg' and `unspecified-bg' stand for the
terminal's own pair, and Emacs draws a face whose foreground is the default
background in standout.  So the swap comes out as the terminal's real colors
reversed: for example, light grey on black becomes black on light grey rather
than black on white.  Checked by running `emacs -nw' under `script' against
xterm-direct, where every cell of the remapped buffer went out under SGR 7."
  (let ((name (if (eq kind 'foreground) "unspecified-fg" "unspecified-bg")))
    (if (and (tty-type)
             (not (alist-get kind cooked--color-remaps))
             (equal (face-attribute 'default
                                    (if (eq kind 'foreground) :foreground :background)
                                    nil t)
                    name))
        name
      (cooked--screen-color kind))))

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
          (let ((foreground (cooked--reversible-color 'foreground))
                (background (cooked--reversible-color 'background)))
            (list (face-remap-add-relative 'default :foreground background)
                  (face-remap-add-relative 'default :background foreground)
                  (face-remap-add-relative 'fringe :background foreground)))))
  (cooked--apply-concealed))

(defun cooked--apply-concealed ()
  "Hide concealed default-coloured text in the colors this buffer draws now.

Called wherever those colors move -- an OSC 10/11 set or reset, DECSCNM, a theme
change -- so text already concealed on the screen stays hidden rather than
showing in the colors of the moment it was drawn.  See `cooked--face-build'."
  (let ((foreground (cooked--screen-color 'foreground))
        (background (cooked--screen-color 'background)))
    (if cooked--reverse-screen
        (cooked--remap-concealed background foreground)
      (cooked--remap-concealed foreground background))))

(defun cooked--set-reverse-screen (on &optional toggles)
  "Adopt DECSCNM state ON from the drain, remapping only when it changes.

TOGGLES is the drain's count of changes to the mode.  A count that moved while
the level ended the drain where it began is a flash whose set and reset both
landed between two drains -- which a drain held by a synchronised frame, or by
load, makes likely, since `flash' pauses only 100ms.  Adopting the level alone
would draw nothing at all, so the reversal is drawn instead and held for
`cooked--flash-seconds' before the level is.  For example, `vim''s
`visualbell' sends ESC [ ? 5 h, pauses, then ESC [ ? 5 l, and a drain that
reads both in one go still flashes the screen once."
  (let ((on (and on t))
        (was cooked--reverse-screen-level))
    (setq cooked--reverse-screen-level on)
    (when (and toggles (/= toggles cooked--reverse-screen-toggles))
      (setq cooked--reverse-screen-toggles toggles)
      (when (eq on was)
        (when cooked--flash-timer
          (cancel-timer cooked--flash-timer))
        (cooked--draw-reverse-screen (not on))
        (setq cooked--flash-timer
              (run-at-time cooked--flash-seconds nil
                           #'cooked--end-flash (current-buffer)))))
    ;; A held flash is left alone by the drains that arrive while it shows; its end
    ;; draws whatever level the last of them left.
    (unless cooked--flash-timer
      (cooked--draw-reverse-screen on))))

(defun cooked--end-flash (buffer)
  "End the flash held in BUFFER, drawing the screen the way the child has it now."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq cooked--flash-timer nil)
      (cooked--draw-reverse-screen cooked--reverse-screen-level))))

(defun cooked--draw-reverse-screen (on)
  "Draw the screen in reverse video if ON, remapping only when that changes."
  (unless (eq on cooked--reverse-screen)
    (setq cooked--reverse-screen on)
    (cooked--apply-reverse-screen)
    ;; A shade in the default colours was blended from them as they were.
    (cooked--reblend-shades)))

(defun cooked--refresh-reverse-screen ()
  "Swap the new theme's colors, if the screen is reversed.
On `cooked-theme-change-hook'."
  (when cooked--reverse-screen
    (cooked--apply-reverse-screen)))

(add-hook 'cooked-theme-change-hook #'cooked--refresh-reverse-screen)
(add-hook 'cooked-theme-change-hook #'cooked--apply-concealed)

(provide 'cooked-color)
;;; cooked-color.el ends here
