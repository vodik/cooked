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

(provide 'cooked-color)
;;; cooked-color.el ends here
