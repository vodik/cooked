;;; cooked-mouse.el --- Mouse reporting for cooked terminals -*- lexical-binding: t; -*-

;;; Commentary:

;; Everything about the mouse: which of Emacs' events become which report, when
;; the child is allowed to see them at all, and the wheel's two answers -- a real
;; report when the child asked for one, arrow keys when it is on the alternate
;; screen and asked only for that.
;;
;; Not opt-in: the drain pipeline and the keymaps require it.  It sits on the
;; screen, which turns a click into a cell, and on cooked-osc.el, which dispatches
;; the OSC 22 pointer shape here.
;;
;; Reports are only sent when the child asked for them; otherwise the click does
;; what it does in any Emacs buffer, so selecting text still works.  The whole of
;; that gate is `cooked--mouse-grab', and `cooked--update-mouse-grab' is what
;; `cooked--refresh-keymap' calls to keep it current.
;;
;; Two gates sit beside it, and both are about which click rather than when.  A
;; position means something to a child only if the pointer was over the window
;; that child is being typed in -- which is not the same question as "did this
;; command run", because Emacs settles a click's bindings in the buffer under the
;; pointer and then runs it in the buffer that was current.  And a release means
;; something only if the press was reported too.  Between them they are what lets
;; a click move focus to another terminal rather than being eaten by this one;
;; see `ours' and `owed' in `cooked-mouse-event'.

;;; Code:

(require 'cl-lib)
(require 'cooked-util)
(require 'cooked-state)
(require 'cooked-deco)
(require 'cooked-screen)
(require 'cooked-osc)

(cooked--declare-core)

(defconst cooked--mouse-buttons
  '((mouse-1 . 0) (mouse-2 . 1) (mouse-3 . 2)
    ;; A GUI frame spells the wheel `wheel-up'; a terminal spells the same notch
    ;; `mouse-4', because that is what X10 numbered it.  Both reach here.
    (wheel-up . 64) (wheel-down . 65) (mouse-4 . 64) (mouse-5 . 65)
    (wheel-left . 66) (wheel-right . 67) (mouse-6 . 66) (mouse-7 . 67))
  "Terminal button numbers for Emacs mouse events.")

(defconst cooked--wheel-events
  '(wheel-up wheel-down wheel-left wheel-right mouse-4 mouse-5 mouse-6 mouse-7)
  "Events carrying a wheel notch rather than a button that can be held.")

(defconst cooked--button-events
  '(down-mouse-1 mouse-1 drag-mouse-1
    down-mouse-2 mouse-2 drag-mouse-2
    down-mouse-3 mouse-3 drag-mouse-3)
  "Events for a button that can be pressed, dragged and released.")

(defconst cooked--mouse-wheel-numbers
  (delete-dups (mapcar (lambda (event) (alist-get event cooked--mouse-buttons))
                       cooked--wheel-events))
  "Button numbers standing for a wheel notch rather than a button held down.

Derived from the two tables above rather than written out again.  A notch is
whatever `cooked--wheel-events\=' maps to, and the literal `(64 65 66 67)\=' this
replaces was a second copy of that fact with nothing keeping it in step.")

(defconst cooked--mouse-x10-offset 32
  "What X10 adds to every field of a report, so no field can be a control byte.
Coordinates are 1-based on top of it, which is where the 33s come from.")

(defconst cooked--mouse-motion-bit 32
  "Bit set in a button number to say the report is motion rather than a press.

The same value as `cooked--mouse-x10-offset\=' and emphatically not the same
thing: this one is part of the button number, in SGR as much as in X10, while
that one is how X10 spells a field.  Two 32s three lines apart, each meaning
something the other does not, is what the names are for.")

(defconst cooked--mouse-no-button 3
  "Button number for \"nothing held\".
What a release reports in X10, which has no field to name the button being let
go of, and what a 1003 child is told when the pointer moves with nothing down.")

(defconst cooked--mouse-events
  (append cooked--button-events cooked--wheel-events)
  "Every mouse event cooked forwards to the child, in either map that does it.

One list because there are two maps -- `cooked--mouse-map\=' here and the one
`cooked--build-passthrough-map\=' makes -- and they must agree about what a
mouse event is.  Spelled out separately, they drifted: the passthrough map
listed only the vertical wheel, so `wheel-left\=' and `wheel-right\=' reached a
child that had asked for the mouse and vanished for one doing an ordinary raw
read.")

(defconst cooked--mouse-map
  (let ((map (make-sparse-keymap)))
    (dolist (event cooked--mouse-events)
      (define-key map (vector event) #'cooked-mouse-event))
    ;; Reached only where `track-mouse' is on outside a gesture, which cooked
    ;; arranges only under `cooked-mouse-hover-motion'; see `cooked-mouse-hover'.
    (define-key map [mouse-movement] #'cooked-mouse-hover)
    map)
  "Mouse bindings for when the child has asked to receive them.

Lives in `emulation-mode-map-alists' rather than in `cooked-raw-map' because a
major mode's local map is near the bottom of Emacs' lookup order, under every
enabled minor mode.  `pixel-scroll-precision-mode' binds `wheel-up' and
`wheel-down' in its own minor-mode map, so on a GUI frame it would take the
wheel before the local map was ever consulted and scroll the buffer out from
under a program that had asked for those notches.  On a terminal frame the
wheel arrives as `mouse-4'/`mouse-5', which pixel-scroll does not bind.

The `drag-mouse-N' variants have to be here as well as `down-mouse-N'/`mouse-N'.
Emacs does not deliver a plain `mouse-1' when the pointer moved between press
and release; it delivers `drag-mouse-1' instead.  Unbound, that would fall
through to the global `mouse-set-region', so the child would never learn the
button had come up and would see it held forever.

Modified variants are deliberately absent: `C-wheel-up' should keep scaling
text, and shift-scrolling should keep working, as they do in any other buffer.
Shift is more than a convenience here: `S-down-mouse-1' reaching
`mouse-drag-region' is the universal escape hatch for selecting text out of a
program that has grabbed the mouse, and it works precisely because this map
never claims it.")

(defconst cooked--wheel-map
  (let ((map (make-sparse-keymap)))
    (dolist (event cooked--wheel-events)
      (define-key map (vector event) #'cooked-mouse-event))
    map)
  "Wheel bindings for an alt screen the child never asked for the mouse on.

The alternate screen is a rectangle the size of the window, and
`cooked--apply-alt-pin\=' narrows the buffer to exactly that rectangle -- so a
wheel notch there has nowhere to scroll to.  What it could do is move the
picture off the window, which is the thing `cooked--pin-alt-windows\=' then
exists to undo, one command later and visibly.  Claiming the notch instead makes
the question not arise: see the `here\=' and `wheel\=' arm of
`cooked-mouse-event\='.

Only the wheel, and a map of its own rather than a wider gate on
`cooked--mouse-map\=', because everything else that map claims is a claim about
the *child* wanting the mouse.  A click on a suspended terminal still selects
text like any other buffer\='s, which is the whole of what
`cooked--mouse-grab\=' turning off is for.

Whether the notch is actually swallowed is decided in the command rather than
here, by asking whether the buffer is still restricted to the screen: a
deliberate \\[widen] inside a peek is how the transcript behind a full-screen
program is read, and the wheel has to work again the moment it happens.  A
keymap gate is recomputed only when something calls
`cooked--update-mouse-grab\=', which a bare `widen\=' does not.")

(cl-defstruct (cooked-mouse-state (:constructor cooked--mouse-state-make)
                                  (:copier nil))
  "What the child has asked for about the mouse, as of the last drain.

The same wire shape `cooked-cursor\=' and `cooked-grid\=' get, decoded at the same
boundary and for the same reason -- see \"What the two ends exchange\" in
cooked-state.el.

Never mutated in place.  `cooked--set-mouse-state\=' replaces it wholesale on
every `mouse\=' event, which is what makes `cooked--mouse-state-none\=' safe to
share as the default across every buffer that has never been told anything."
  (enabled nil :documentation "Whether the child asked for mouse reports at all.")
  (sgr nil :documentation "\
Whether to encode reports as SGR (1006), in cells or in pixels.")
  (drag nil :documentation "\
DEC mode 1002: report the pointer while a button is held.")
  (motion nil :documentation "\
DEC mode 1003: report the pointer whether or not a button is held.

Kept apart from `drag\=' even though cooked drives both from the same tracking
loop, because the child asked two different questions and `cooked--mouse-track\='
can only honestly answer one of them; see its docstring.  The other one is
`cooked-mouse-hover\=', and only under `cooked-mouse-hover-motion\='.")
  (pixels nil :documentation "\
DEC mode 1016: SGR reports carry the pointer\='s pixel instead of its cell.

Never set without `sgr\=': the core keeps the coordinate modes mutually
exclusive, as xterm does, so 1016 is a unit for the SGR form rather than a form
of its own.  See `cooked--mouse-report\='."))

(defconst cooked--mouse-state-none (cooked--mouse-state-make)
  "The state of a child that has asked for nothing.

The default value of `cooked--mouse-state\=', so that `buffer-local-value\='
answers a struct for *any* buffer -- including one that is not a cooked buffer
at all, which `cooked-mouse-event\=' is handed whenever a drag ends over another
window.  A nil there would be a wrong-type error inside a mouse command; one
shared immutable struct is nil-safety at the source rather than a guard at each
reader.")

(defvar-local cooked--mouse-state cooked--mouse-state-none
  "What the child last asked for about the mouse; see `cooked-mouse-state'.")

(defun cooked--set-mouse-state (enabled sgr drag motion pixels)
  "Adopt ENABLED, SGR, DRAG, MOTION and PIXELS, and re-gate the keymap.

The five fields of the drain\='s `mouse\=' event, in the order it carries them.

Called from `cooked--handle-event\=', which is in cooked-render.el and requires
this file, so the call is an ordinary one -- but it is still a notification that
something changed rather than a question asked upward, which is why the state
and the keymap it gates both live on this side of it."
  (setq cooked--mouse-state (cooked--mouse-state-make
                             :enabled enabled :sgr sgr :drag drag :motion motion
                             :pixels pixels))
  ;; The keymap that outranks `pixel-scroll-precision-mode' is gated on this, so
  ;; it has to move when the child changes its mind about the mouse.
  (cooked--update-mouse-grab))

(defvar-local cooked--mouse-grab nil
  "Whether the child both wants the mouse and owns the keyboard.
Gates `cooked--mouse-map'; nil everywhere else, so the entry in
`emulation-mode-map-alists' is inert outside a session that asked for it.

Deliberately not a slot on `cooked-mouse-state\=', and the omission is not an
oversight.  Two independent reasons: `cooked--mouse-map-alist\=' puts this
*symbol* into `emulation-mode-map-alists\=', which Emacs evaluates as a
variable, and `cooked-link.el\=' reads it through `bound-and-true-p\=', being a
base-tier file that cannot require this one.  It is also a *derived* value
rather than something the child said, which is what that struct holds.")

(defvar-local cooked--wheel-grab nil
  "Whether the wheel belongs to an alternate screen nobody else has claimed.

Gates `cooked--wheel-map\='.  Mutually exclusive with `cooked--mouse-grab\=' by
construction: a child that asked for the mouse is already being sent its
notches, and this is only for the alternate screens where nobody is.")

(defvar cooked--mouse-map-alist
  `((cooked--mouse-grab . ,cooked--mouse-map)
    (cooked--wheel-grab . ,cooked--wheel-map))
  "The `emulation-mode-map-alists' entry activating cooked's mouse keymaps.")

(defvar-local cooked--mouse-held nil
  "Terminal button numbers the child has been told are down, newest first.

A press and its release are one gesture, and only the press is guaranteed to
land on a cell of ours: let go below the last row, or over the fringe, and
`posn-point' is nil.  Dropping the release there would leave the child holding a
button it can never put down, so this is what says a release is owed.  It also
supplies the button a motion report has to name -- 1002 asks which button is
being dragged, and the event Emacs hands us for a movement names none.")

(defvar-local cooked--mouse-last-cell nil
  "Cell of the last report sent, as a (ROW . COL) cons.

Two jobs, both about a report that would otherwise be wrong or wasted: it stands
in for a release the pointer carried off the screen, and it is what makes motion
reporting affordable -- Emacs manufactures a `mouse-movement' event per pixel,
and the child only cares about the ones that changed cell.")

(defvar-local cooked--mouse-tracking nil
  "Non-nil while `cooked--mouse-track' is following a gesture in this buffer.

What keeps `cooked--update-hover-tracking' from writing the variable
`track-mouse' under a binding it does not own.  The macro of the same name sets
the variable from C and restores the old value on the way out, into whichever
binding is current at that moment -- so a drain that made the variable
buffer-local mid-drag would have the restore land in the new local binding,
leaving the global value the macro had set stuck at t and every buffer in the
session generating motion events nobody asked for.")

(defcustom cooked-mouse-hover-motion nil
  "Whether to report the pointer to a child that asked for any-motion (1003).

Off by default, and not because the reports are expensive -- one per cell
crossed, and only while the pointer is actually moving.  The cost that needs
opting into is Emacs\=' rather than cooked\='s: the only way to receive motion
with no button held is to leave the variable `track-mouse' on for as long as
the child wants it, and Emacs then manufactures a `mouse-movement' event per
glyph crossed -- per pixel over an image, which is how a panel\='s box drawing
is shown -- and `read-key-sequence' reads every one.  `cooked--hover-translate'
answers them inside that read, so none of them is a command with hooks behind
it, but each is still an event read and a redisplay checked, and that cost has
not been measured on a graphical frame.

Off, a 1003 child is still told where the pointer goes while a button is held,
which is the half `cooked--mouse-track' serves unconditionally.  On, programs
that highlight what is under the pointer -- htop with its mouse support, menus
in TUI toolkits -- see it move without a click.

The variable is set buffer-locally, and only in a terminal whose child both
asked for 1003 and currently has the mouse, so nothing changes in any other
buffer.  Set through customize and it reaches live terminals at once."
  :type 'boolean
  :group 'cooked
  :set (lambda (symbol value)
         (set-default symbol value)
         ;; Guarded because `custom-declare-variable' runs this at load, before
         ;; the function below exists.
         (when (fboundp 'cooked--update-hover-tracking)
           (cooked--dolist-buffers (cooked--update-hover-tracking)))))

(defcustom cooked-alternate-scroll-lines 3
  "Cursor keys sent per wheel notch under alternate scroll (DEC mode 1007).
Three is xterm's figure."
  :type 'natnum
  :group 'cooked)

(defun cooked--alt-scroll-active-p ()
  "Whether a wheel notch should be sent to the child as cursor keys.

DEC mode 1007, which is what makes the wheel scroll in `less', `man' and
`git log' — programs that never ask for the mouse."
  (and cooked--session (cooked--alt-scroll-p cooked--session)))

(defun cooked--update-mouse-grab ()
  "Recompute whether `cooked--mouse-map' should be in force."
  ;; Alternate scroll has to be here as well as the child's own request: it
  ;; exists precisely for children that did *not* ask for the mouse, so gating
  ;; the keymap on `enabled' alone would leave the whole feature unreachable.
  ;;
  ;; Suspended forwarding has to be here too: it hands the buffer back to
  ;; ordinary Emacs commands, and a click should select text like any other
  ;; buffer's, not get reinterpreted as a mouse report to a child that still
  ;; owns the keyboard as far as `cooked--input-state-p' alone can tell.  Both
  ;; `still' and `frozen' count -- the render being live in `still' says nothing
  ;; about who a click belongs to.
  (setq cooked--mouse-grab (and (or (cooked-mouse-state-enabled cooked--mouse-state)
                                    (cooked--alt-scroll-active-p))
                                (not (cooked--input-state-p))
                                (not (cooked--suspended-p))))
  ;; The wheel outlives all three of those conditions: an alternate screen is a
  ;; rectangle whether or not the child wanted the mouse, and whether or not the
  ;; keyboard is suspended for a peek.  See `cooked--wheel-map'.
  (setq cooked--wheel-grab (and cooked--alt (not cooked--mouse-grab) t))
  (cooked--update-hover-tracking)
  ;; The pointer shape a child set is shown under the same gate, so every path
  ;; that moves the gate has to move the pointer with it.  Beside the hover
  ;; call rather than inside it: that one stands down while a gesture is being
  ;; followed, and the pointer has no reason to.  The two do not otherwise
  ;; meet -- Emacs reads a `pointer' property whenever the mouse moves, whether
  ;; or not `track-mouse' is delivering the movement as events.
  (cooked--sync-pointer-shape))

(defun cooked--update-hover-tracking ()
  "Turn the variable `track-mouse' on here exactly while hover is to be reported.

That is: the user opted in with `cooked-mouse-hover-motion\=', the child asked
for any-motion, and it has the mouse -- `cooked--mouse-grab\=' rather than
`enabled\=', so a peek or a prompt that hands clicks back to Emacs hands the
pointer back too.

Off means the local binding is removed rather than set to nil, so that the
global value is what governs again and a buffer that never had hover on never
acquires a local binding it has no use for.  Skipped while a gesture is being
followed; `cooked--mouse-track' calls this again once it has let go of the
variable.  See `cooked--mouse-tracking\='.

Turning it on also puts `cooked--hover-translate\=' on `key-translation-map\=',
which is what keeps the movements this lets in out of the middle of a key."
  (unless cooked--mouse-tracking
    (if (and cooked-mouse-hover-motion cooked--mouse-grab
             (cooked-mouse-state-motion cooked--mouse-state))
        (progn
          ;; Installed the first time hover is on anywhere, and never over a
          ;; translation some other package has put there.  It answers nothing
          ;; in a buffer whose child does not have the mouse.
          (unless (lookup-key key-translation-map [mouse-movement])
            (define-key key-translation-map [mouse-movement]
                        #'cooked--hover-translate))
          (setq-local track-mouse t))
      (kill-local-variable 'track-mouse))))

(defun cooked--mouse-cell-width (posn)
  "Width in pixels of one cell of the screen POSN is over.

`cooked--last-cell\=' first, because it is the width `CSI 16 t\=' reported and
the width every decoration was cut to, so a pointer measured against anything
else could land in a different cell from the one the child and the picture
agree on.  A terminal frame has no pixel size there, and its frame reports one
character as one unit instead: `posn-object-x-y\=' counts in characters on such
a frame, so 1 is the right divisor rather than a guess."
  (let ((width (car-safe cooked--last-cell))
        (window (posn-window posn)))
    (if (and (natnump width) (> width 0))
        width
      (frame-char-width (cond ((windowp window) (window-frame window))
                              ((framep window) window))))))

(defun cooked--mouse-glyph (posn)
  "Where POSN points on the screen text, as (POS CELLS . DX), or nil for no text.

POS is `posn-point\='.  CELLS is how many cells to the right of POS\='s own cell
the pointer is, and DX how many pixels into that cell.  Nil when POSN is over a
fringe or margin, whose `posn-point\=' is the position of the row beside it and
not a cell the pointer is in: a click in the left fringe used to report
column 0.

Emacs names a position per glyph, and three kinds of glyph are wider than the
one cell POS stands for, so the offset into the glyph is what recovers the rest:

- A decoration drawn as one image over a run of cells.  POS is the run\='s
  first character, so a click in the middle of an empty panel of box-drawing
  characters used to report the panel\='s left border.  Twenty cells of 9-pixel
  cells with the pointer 50 pixels in is CELLS 5 and DX 5.
- The newline ending a row, whose trailing blanks are never inserted.  Its
  glyph stretches to the window\='s edge, so a click ten cells past the text of
  `ls\=' used to report the column where the text stopped.
- A character whose glyph is wider than its cells, a fallback font\='s, which
  would otherwise report the part that overhangs as the next column.  DX is
  clamped to the cells the character stands on, so a two-cell character still
  reports both of its cells and a one-cell one only its own.

The width of a run or character is `string-width\=' of its text without its
properties, which is the cells the grid gave it.  Not the difference of two
`current-column\='s: that counts an image as its pixels divided by the frame\='s
character width, which is a different number once `text-scale-mode\=' has
changed the cell."
  (let ((pos (posn-point posn)))
    (when (and pos (null (posn-area posn)))
      (let* ((width (cooked--mouse-cell-width posn))
             (dx (max 0 (or (car (posn-object-x-y posn)) 0)))
             (cells (unless (save-excursion (goto-char pos) (eolp))
                      ;; One `display' value over a run is one glyph, which is
                      ;; how `cooked--apply-deco' draws it.
                      (let ((end (if (and (get-text-property pos 'cooked-deco)
                                          (get-text-property pos 'display))
                                     (next-single-property-change
                                      pos 'display nil
                                      (save-excursion (goto-char pos)
                                                      (line-end-position)))
                                   (1+ pos))))
                        (max 1 (string-width
                                (buffer-substring-no-properties pos end))))))
             (dx (if cells (min dx (1- (* cells width))) dx)))
        (cons pos (cons (/ dx width) (% dx width)))))))

(defun cooked--mouse-cell (posn &optional glyph)
  "Screen row and column of POSN, or nil if it is outside the screen.

GLYPH is what `cooked--mouse-glyph\=' answers for POSN, for a caller that
already has it.

A posn rather than an event because the interesting end of an event is not
always the same one: `drag-mouse-1\=' is a release, and where the button came up
is `event-end\='.  Reading `event-start\=' there reported the release at the cell
the press was already reported in, which is a gesture with no extent at all.

`cooked--screen-cell\=' rather than a count of lines and columns from the marker:
row 0 does not always begin its buffer line — when the row handed to scrollback
last was wrapped, `cooked--screen-start\=' sits mid-line — and a plain
`current-column\=' there counts the characters ahead of the marker, which are
scrollback and not on the screen at all.  Reporting those to the child puts
every click on row 0 to the right of where it was made.

The column never passes the last one the child was given: a window a few
pixels wider than its grid has blank space past it that is not a cell."
  (when-let* ((glyph (or glyph (cooked--mouse-glyph posn)))
              (cell (cooked--screen-cell (car glyph))))
    (cons (car cell)
          (min (+ (cdr cell) (cadr glyph))
               (max (cdr cell) (1- cooked--cols))))))

(defun cooked--mouse-offset (posn &optional glyph)
  "Where in its cell POSN points, as (DX . DY) pixels, if the child wants to know.

GLYPH is what `cooked--mouse-glyph\=' answers for POSN, for a caller that
already has it.  Nil unless the child asked for pixel reports, so that a session
reporting cells pays nothing for a measurement it would throw away.

Only the offset *within* the cell is taken from Emacs; the cell it sits in is
still `cooked--mouse-cell\='s, and `cooked--mouse-report\=' scales that by the
cell size.  Adding `posn-x-y\=' to the screen\='s origin instead would have to
find that origin in pixels, and it is not a constant: row 0 is wherever
`cooked--screen-start\=' happens to be drawn, which moves with scrollback,
`window-start\=' and the header line.  A glyph-relative offset needs none of
that, and `cooked--mouse-glyph\=' has already divided the part of it that is
whole cells out into the column."
  (when (cooked-mouse-state-pixels cooked--mouse-state)
    (when-let* ((glyph (or glyph (cooked--mouse-glyph posn))))
      (cons (cddr glyph) (or (cdr (posn-object-x-y posn)) 0)))))

(defun cooked--mouse-report (button row col pressed &optional offset)
  "Encode a report for BUTTON at ROW/COL, PRESSED or not.

SGR is preferred wherever the child asked for it, because X10 cannot count
past column 223.

Under DEC mode 1016 the coordinates are pixels: ROW and COL scaled by the cell
size last reported to the child, plus OFFSET, the (DX . DY) returned by
`cooked--mouse-offset\='.  Counted from 1, as xterm counts them, so that
pixel P lies in cell (P - 1) / WIDTH -- the size `CSI 16 t\=' answers with is
what the child will divide by, so it is the size multiplied by here rather
than a fresh measurement of the window that could disagree with it.  With no
OFFSET, which is a report whose position stood in for the pointer\='s (a
wheel notch over the fringe, a release carried off the screen), the cell\='s
top-left pixel is sent.  DY is clamped into the row because a row holding a
taller fallback glyph is drawn taller than the cell, and its excess must not
read as the row below.  DX needs no clamp here, because `cooked--mouse-glyph\='
has already clamped it to the cells its character stands on and moved the whole
cells into COL.

On a terminal frame there is no cell size, and the report degrades to cells
counted from 1: a unit of one pixel per cell is the only claim that is not
invented.  DECRQM still answers that 1016 is set, because the core answers it
and cannot know what kind of frame the buffer is shown on.  What a child does
learn is that `CSI 16 t\=' reports no size, and a child cannot scale pixels
without asking that first.  The size is the one `cooked--sync-size\=' measured
in `cooked--layout-window\=', so a buffer shown on a graphical and a terminal
frame at once reports in whichever unit that window\='s frame has."
  (cond
   ((cooked-mouse-state-pixels cooked--mouse-state)
    (pcase-let* ((`(,width . ,height) cooked--last-cell)
                 (measured (and (natnump width) (natnump height)
                                (> width 0) (> height 0)))
                 (`(,dx . ,dy) (or (and measured offset) '(0 . 0))))
      (cooked--csi-private
       "<" (if pressed "M" "m") button
       (+ 1 (* col (if measured width 1)) (max 0 dx))
       (+ 1 (* row (if measured height 1))
          (if measured (min (max 0 dy) (1- height)) 0)))))
   ((cooked-mouse-state-sgr cooked--mouse-state)
    (cooked--csi-private "<" (if pressed "M" "m") button (1+ col) (1+ row)))
   (t
    (concat (cooked--csi "M")
            (string (+ cooked--mouse-x10-offset
                       (if pressed button cooked--mouse-no-button))
                    (+ cooked--mouse-x10-offset 1 col)
                    (+ cooked--mouse-x10-offset 1 row))))))

(defun cooked--send-mouse (button row col pressed &optional offset keep-region)
  "Send one report for BUTTON at ROW/COL, PRESSED or not, and drop the region.

OFFSET is where in the cell the pointer is, for a child reporting pixels; see
`cooked--mouse-report\='.  With KEEP-REGION, leave the region alone; only hover
motion asks for that.

Deactivating the mark is the point of routing every report through here.  A
click that the child answers is the child\='s click, and leaving a region behind
it is what made a selection impossible to get rid of: nothing here ever cleared
one, so a region set before the child grabbed the mouse survived every
subsequent click, and `cooked--snap-to-cursor\=' then walked point away from a
mark that stayed put -- growing a region the user never drew and could only
escape by leaving the buffer.

Through `cooked--deactivate-mark\=' rather than `deactivate-mark\=' so that a
report fired while evil is in visual state says so to evil as well.  A bare
`deactivate-mark\=' happens to do the right thing from here -- evil reads
`this-command\=', and there is one -- but only by depending on a fact about the
caller that the drain, which clears the same selection for the same reason, does
not share.  One answer for both beats two that agree by accident.

Hover is the exception because it is not a click.  The pointer drifting across
the window after a shifted drag has selected text -- the escape hatch for
selecting out of a program that grabbed the mouse -- would otherwise take the
selection away before it could be copied."
  (unless keep-region
    (cooked--deactivate-mark))
  (setq cooked--mouse-last-cell (cons row col))
  (cooked--send-to-child (cooked--mouse-report button row col pressed offset)))

(defvar mwheel-coalesce-scroll-events)
(defvar last-event-device)
(declare-function device-class "frame" (frame name))

(defvar-local cooked--scroll-pending 0.0
  "Wheel travel in pixels not yet forwarded to the child as a whole row.")

(defun cooked--wheel-presses (event)
  "How many notches EVENT is worth to the child.  Ported from ghostel.

One, normally.  A wheel notch is a notch and the child is told once.

The case this exists for is `mwheel-coalesce-scroll-events\=' nil, which
`pixel-scroll-precision-mode\=' and ultra-scroll both set: every trackpad tick
then arrives as its own event carrying a *pixel* delta, and forwarding one
report per event floods a child that asked for mouse tracking with dozens of
notches per row of travel.  Pixels are accumulated instead and one press is sent
per row actually crossed, with the remainder carried -- so a slow drag scrolls
smoothly in Emacs and one line at a time in the child, which is the only thing
the child can express.

The two guards are the non-obvious part and both are ghostel\='s.

*A real mouse is excluded by device class*, not by the delta.  X11 and pgtk
report a wheel notch as several rows of pixels with no line count, which
arithmetic alone cannot tell from a fast trackpad swipe -- so a notch would be
accumulated, rounded, and a click would go missing.  `device-class\=' is how
the question gets asked instead.

*And the floor of one press is `nth 3\=', not a constant.* macOS reports a
notch as one line and *fewer pixels than a row* when `line-spacing\=' is set,
so the row arithmetic yields zero and the notch would vanish.  Taking the larger
of the two means a sub-row trackpad tick still accumulates -- its line count is
0 -- while a notch that undershoots a row still reports once."
  (if-let* ((delta (cooked--wheel-pixel-delta event)))
      (let* ((row (let ((window (posn-window (event-start event))))
                    (if (windowp window)
                        (with-selected-window window (default-line-height))
                      (default-line-height))))
             (pending (+ cooked--scroll-pending delta))
             (rows (truncate pending row)))
        (setq cooked--scroll-pending (- pending (* rows row)))
        (max (abs rows) (min 1 (or (nth 3 event) 0))))
    1))

(defun cooked--wheel-pixel-delta (event)
  "The vertical pixel delta EVENT carries, if it is travel rather than a notch.

Nil for a notch, which is whatever `cooked--wheel-presses\=' counts as one:
an event with no delta, one Emacs has already coalesced, and one from a device
that reports itself as a mouse."
  (let ((delta (cdr-safe (nth 4 event))))
    (and delta
         (boundp 'mwheel-coalesce-scroll-events)
         (not mwheel-coalesce-scroll-events)
         (not (and (fboundp 'device-class)
                   (eq (device-class last-event-frame last-event-device) 'mouse)))
         delta)))

(defun cooked--report-button (button row col pressed &optional offset)
  "Report BUTTON at ROW/COL as PRESSED or released, remembering that it is held.
OFFSET is passed on to `cooked--send-mouse\='."
  (cond ((memq button cooked--mouse-wheel-numbers)) ; a notch cannot be held
        (pressed (unless (memq button cooked--mouse-held)
                   (push button cooked--mouse-held)))
        (t (setq cooked--mouse-held (delq button cooked--mouse-held))))
  (cooked--send-mouse button row col pressed offset))

(defun cooked--report-motion (row col &optional offset keep-region)
  "Report the pointer arriving at ROW/COL, if it is a cell it was not already in.
OFFSET and KEEP-REGION are passed on to `cooked--send-mouse\='.

`cooked--mouse-motion-bit\=' is added to the button being dragged, or to
`cooked--mouse-no-button\=' where nothing is held.  Suppressing
a repeat of the last cell is not an optimisation so much as the contract: Emacs
tracks the pointer by pixel, and a child that asked for cells would otherwise
receive several dozen identical reports per cell crossed."
  (unless (equal cooked--mouse-last-cell (cons row col))
    (cooked--send-mouse (+ cooked--mouse-motion-bit
                           (or (car cooked--mouse-held) cooked--mouse-no-button))
                        row col t offset keep-region)))

(defun cooked--mouse-track (window)
  "Follow the pointer into the child until the gesture ends, over WINDOW.

Emacs manufactures `mouse-movement\=' events only inside `track-mouse\=', and only
for as long as that form is running; no keymap can ask for them.  So the press
that begins a drag runs the rest of the gesture itself, exactly as
`mouse-drag-region\=' does for Emacs\=' own selection.  Without it the child got a
press and, whenever the user let go, a release, with nothing in between -- so a
program that highlights as you drag highlighted nothing until the end.

Whatever ends the loop is pushed back rather than acted on, so the release
returns through `cooked-mouse-event\=' by its ordinary binding and there is only
one place that knows how to report a button coming up.

Only the drag half of 1003 is served here: any-motion with no button down means
tracking the pointer for as long as the child asks, which is an event read per
glyph crossed anywhere in the frame whether or not the user is doing anything.
A `track-mouse\=' bounded by a gesture is the affordable part, and it is the
part every 1003 client also gets from 1002; the rest is
`cooked--hover-translate\=' and `cooked-mouse-hover\=', behind
`cooked-mouse-hover-motion\='.

The form\='s own binding of `track-mouse\=' is why `cooked--mouse-tracking\=' is
set around it, and why hover tracking is recomputed after it: a drain during the
drag may have changed what the child wants, and the update it would have made
was skipped."
  (setq cooked--mouse-tracking t)
  (unwind-protect
      (cooked--mouse-track-1 window)
    (setq cooked--mouse-tracking nil)
    (cooked--update-hover-tracking)))

(defun cooked--mouse-track-1 (window)
  "The loop of `cooked--mouse-track\=' over WINDOW, inside `track-mouse\='."
  (track-mouse
    (let (event)
      (while (progn (setq event (read-event))
                    (and (consp event) (eq (event-basic-type event) 'mouse-movement)))
        (let ((posn (event-start event)))
          ;; A drag that wanders into another window is still the child\='s drag,
          ;; but the cells under it are somebody else\='s buffer: report nothing
          ;; rather than a position translated out of the wrong text.
          (when (eq (posn-window posn) window)
            (when-let* ((cell (cooked--mouse-cell posn)))
              (cooked--report-motion (car cell) (cdr cell)
                                     (cooked--mouse-offset posn))))))
      (push event unread-command-events))))

(defvar-local cooked--hover-glyph nil
  "The glyph hover last measured and the cell it was, as (KEY . CELL).

KEY is what the cell was derived from: the buffer\='s modification tick, the
screen\='s start, the grid\='s width, and the position and cell offset
`cooked--mouse-glyph\=' answered.  While all of those hold, the cell does too,
and `cooked--hover-cell\=' hands it back without counting the lines above it.")

(defun cooked--hover-cell (glyph)
  "The screen cell of GLYPH, a `cooked--mouse-glyph\=' answer, remembered.

Emacs sends a movement per pixel over an image and per column past a row\='s
end, so a pointer crossing a decorated panel arrives dozens of times in one
cell.  `cooked--report-motion\=' drops every repeat, but only after being handed
a cell, and a cell is a `count-lines\=' from the top of the screen.  Asking
whether the glyph is the one just measured is a comparison of five integers."
  (let ((key (list (buffer-chars-modified-tick) (cooked--screen-start-position)
                   cooked--cols (car glyph) (cadr glyph))))
    (if (equal key (car cooked--hover-glyph))
        (cdr cooked--hover-glyph)
      (cdr (setq cooked--hover-glyph
                 (cons key (cooked--mouse-cell nil glyph)))))))

(defun cooked--hover-report (posn)
  "Report POSN as hover to the child under it, and say whether it takes hover.

Non-nil when the buffer under POSN is a terminal whose user opted in with
`cooked-mouse-hover-motion\=' and whose child asked for any-motion and has the
mouse, whether or not the movement was worth a report.  That buffer is asked
rather than the current one, for the reason `cooked-mouse-event\=' gives, and
it is asked again whether it wants motion, since some other package leaving
`track-mouse\=' on globally would otherwise deliver hover to a child the user
never opted into.

A pointer over no text -- past the last row, over the fringe -- reports nothing
rather than a cell it is not in.  Repeats of the last cell are dropped by
`cooked--report-motion\=', and repeats of the last glyph before that, by
`cooked--hover-cell\='."
  (when-let* ((target (cooked--mouse-buffer (posn-window posn))))
    (with-current-buffer target
      (when (and cooked-mouse-hover-motion cooked--mouse-grab
                 (cooked-mouse-state-motion cooked--mouse-state))
        (when-let* ((glyph (cooked--mouse-glyph posn))
                    (cell (cooked--hover-cell glyph)))
          (cooked--report-motion (car cell) (cdr cell)
                                 (cooked--mouse-offset posn glyph) t))
        t))))

(defun cooked--hover-translate (_prompt)
  "Take a `mouse-movement\=' out of the key being read, reporting it if it is hover.

On `key-translation-map\=' under `[mouse-movement]\=', where
`cooked--update-hover-tracking\=' puts it.  Answers the empty key, which deletes
the movement from the sequence, or nil to leave it alone.

A movement is ordinary input to `read-key-sequence\=', and nothing in Emacs
keeps one out of the middle of a key.  With `track-mouse\=' left on for hover, a
pointer twitch after \\`C-c' made the key \\`C-c <mouse-movement>', which is
undefined, and the \\`C-c' was lost -- and \\`C-c' is the only way back to Emacs
from a full-screen program.  The same went for \\`C-x', \\`C-h' and \\`ESC'.  A
translation map is consulted between the keys of a sequence, which a keymap
binding is not: binding the movement under each prefix would still end the key
there.  So a movement after the first key of a sequence is always deleted.

A movement that starts one is deleted too when it is ours to answer: the binding
it would reach is `cooked-mouse-hover\=', and it either was reported as hover or
would have fallen back to a command that does nothing.  That keeps hover out of
the command loop altogether.  Before, every glyph crossed was a command, with
`pre-command-hook\=' and `post-command-hook\=' behind it: \\[universal-argument]
was spent on the movement rather than on the command it was typed for,
`tooltip-hide\=' took down a link\='s help on the first glyph, and
`cooked--track-wandering\=' counted the lines above point each time.

A movement some other binding wants is left alone.  `mouse-drag-region\=' reads
the drag it selects text with as bound movements in a transient map, and the
shifted drag is how text is selected out of a program that has the mouse."
  (let ((event last-input-event))
    (when (and (mouse-movement-p event) cooked--mouse-grab)
      (let* ((ours (eq (key-binding (vector event)) #'cooked-mouse-hover))
             (reported (and ours (cooked--hover-report (event-start event)))))
        (and (or reported
                 ;; Everything read so far, the movement included, minus the
                 ;; movements: a key already begun is one being cut in half.
                 (seq-some (lambda (key) (not (mouse-movement-p key)))
                           (this-command-keys-vector))
                 (and ours
                      (memq (cooked--mouse-fallback-binding event (vector event))
                            '(nil ignore ignore-preserving-kill-region))))
             [])))))

(defun cooked-mouse-hover ()
  "Report the pointer moving with no button held to a child that asked for 1003.

Bound to `mouse-movement\=' in `cooked--mouse-map\=', which Emacs delivers
outside a gesture only where `track-mouse\=' is on, which
`cooked--update-hover-tracking\=' arranges only under
`cooked-mouse-hover-motion\='.  A movement during a drag never reaches here:
`cooked--mouse-track\=' reads those itself.

Rarely a command in practice.  `cooked--hover-translate\=' answers the movement
before any binding is looked up whenever it is hover, and whenever declining it
would do nothing, so what is left to run here is a movement over some other
buffer whose own binding wants it -- which goes to that binding.

`this-command\=' is handed back to `last-command\=' so that a movement between
two commands is invisible to anything asking what ran before -- a `kill-region\='
followed by another still appends, as it would with the pointer at rest."
  (interactive)
  (let ((event last-input-event))
    (setq this-command last-command)
    (unless (cooked--hover-report (event-start event))
      (cooked--mouse-fallback event))))

(defun cooked--alt-scroll-keys (button &optional lines)
  "Cursor keys standing in for LINES of wheel travel of BUTTON.

LINES defaults to `cooked-alternate-scroll-lines\=', which is what one notch is
worth.  Only the vertical notches translate; a horizontal one has no cursor-key
spelling a pager would understand, so it sends nothing."
  (if-let* ((final (cond ((= button (alist-get 'wheel-up cooked--mouse-buttons)) "A")
                         ((= button (alist-get 'wheel-down cooked--mouse-buttons)) "B"))))
      (let ((key (cooked--cursor-key final)))
        (mapconcat #'identity (make-list (or lines cooked-alternate-scroll-lines) key)))
    ""))

(defun cooked--mouse-buffer (window)
  "The live cooked buffer WINDOW is showing, if it is showing one."
  (when-let* ((buffer (and (windowp window) (window-buffer window))))
    (and (buffer-local-value 'cooked--session buffer) buffer)))

(defun cooked-mouse-event ()
  "Forward the mouse to the child under the pointer, or fall back to Emacs.

Which child that is takes deciding.  Emacs settles a click\='s bindings in the
buffer under the pointer but runs the command in the buffer that was current all
along, so with two terminals side by side this command routinely runs in the one
the user is *not* pointing at.  Everything below therefore happens in the buffer
the pointer names -- which is also what makes an unfocused terminal behave like
any other Emacs buffer, receiving the click that focuses it and scrolling under
the wheel without being focused at all.

The exception is a gesture already in flight: a button this buffer\='s child was
told went down is owed a release here whatever window the pointer has wandered
into by the time it comes up."
  (interactive)
  (let* ((event last-input-event)
         (basic (event-basic-type event))
         (modifiers (event-modifiers event))
         (button (cdr (assq basic cooked--mouse-buttons)))
         (wheel (memq basic cooked--wheel-events))
         ;; A wheel notch is always a press.  Emacs reports it as a click, which
         ;; the `down' test alone would encode as a release — and a release of
         ;; buttons 64/65 is a report every application discards, so the scroll
         ;; would vanish on the way to a child that had asked for it.
         (pressed (or wheel (memq 'down modifiers)))
         ;; `drag-mouse-1' is a release that happens to know where it started;
         ;; the end is the half that has not been reported yet.
         (posn (if (memq 'drag modifiers) (event-end event) (event-start event)))
         (window (posn-window posn))
         ;; The gesture-in-flight test, read here because it is a fact about the
         ;; buffer this command was dispatched in rather than the one the pointer
         ;; is over.  A drag out of a terminal ends in that terminal.
         (owed (and button (not pressed) (memq button cooked--mouse-held)))
         (target (if owed (current-buffer) (cooked--mouse-buffer window)))
         ;; A press the child is going to hear about takes the window too, so one
         ;; click both focuses a terminal and reaches the program in it, the way
         ;; one click on any other buffer both focuses it and acts.  Not the
         ;; wheel: scrolling an unfocused buffer does not focus it in Emacs
         ;; either.  A press the child will *not* hear about is left alone, so
         ;; that `mouse-drag-region' does the selecting and the selecting means
         ;; what it usually means.
         (select (and target pressed (not wheel)
                      (not (eq window (selected-window)))
                      ;; Nil-safe for any buffer by the shared default; see
                      ;; `cooked--mouse-state-none'.
                      (cooked-mouse-state-enabled
                       (buffer-local-value 'cooked--mouse-state target)))))
    (if (null target)
        (cooked--mouse-fallback event)
      (when select (select-window window))
      (with-current-buffer target
        (let* (;; Whether the pointer is over this buffer, as opposed to naming
               ;; the far end of a drag that started in it.
               (here (eq target (and (windowp window) (window-buffer window))))
               (cell
                (and (cooked-mouse-state-enabled cooked--mouse-state) button
                     (or (and here (or pressed (memq button cooked--mouse-held))
                              (cooked--mouse-cell posn))
                         ;; A notch has nowhere to land when the pointer is over a
                         ;; part of the window with no text under it.  Scrolling
                         ;; Emacs instead would move the buffer out from under a
                         ;; program that asked to receive the wheel, so the cursor's
                         ;; cell stands in — the child cares about the direction.
                         (and here wheel (cooked--cursor-cell))
                         ;; And a release owed to the child is owed wherever the
                         ;; pointer ended up: let go past the last row, or over
                         ;; another window entirely, and there is no cell here, but
                         ;; the button is still down as far as the child knows.
                         ;; Report it where it was last seen rather than handing
                         ;; the tail of the child's gesture to Emacs.
                         (and (not pressed) (memq button cooked--mouse-held)
                              (or cooked--mouse-last-cell (cooked--cursor-cell))))))
               ;; Only a cell that is the pointer's own has a pixel offset to go
               ;; with it; one standing in for the pointer reports its corner.
               (offset (and cell here (cooked-mouse-state-pixels cooked--mouse-state)
                            (equal cell (cooked--mouse-cell posn))
                            (cooked--mouse-offset posn))))
          (cond
           ;; Checked before the mouse report: `cooked--alt-scroll-active-p' is
           ;; already false when the child asked for the mouse, so the two can
           ;; never both apply.
           ;;
           ;; A trackpad's pixels are worth a line per row of travel, as they
           ;; would be scrolling any other buffer, and not a notch's worth per
           ;; event: under `pixel-scroll-precision-mode' every tick is an event
           ;; of its own, and three lines apiece flooded `less'.
           ((and here wheel button (cooked--alt-scroll-active-p))
            (cooked--send-to-child
             (cooked--alt-scroll-keys button
                                      (and (cooked--wheel-pixel-delta event)
                                           (cooked--wheel-presses event)))))
           ;; Nowhere to scroll to: the buffer is restricted to the screen the
           ;; child is drawing, so every notch here can only move the picture off
           ;; the window.  Asked of the restriction rather than of `cooked--alt'
           ;; alone, because a `widen' inside a peek is how the transcript behind
           ;; a full-screen program is read; see `cooked--wheel-map'.
           ((and here wheel (null cell) (cooked--screen-restricted-p))
            nil)
           ((null cell)
            (cooked--mouse-fallback event))
           (t
            ;; A wheel notch may be worth more than one report, or none at all,
            ;; when the pointing device speaks in pixels; everything else is
            ;; worth exactly one.  See `cooked--wheel-presses'.
            (dotimes (_ (if wheel (cooked--wheel-presses event) 1))
              (cooked--report-button button (car cell) (cdr cell) pressed offset))
            ;; Take the whole gesture or none of it: having reported a press to a
            ;; child that asked where the pointer goes, the motion is ours to
            ;; deliver, and the only way to be given it is to sit in `track-mouse'
            ;; until the button is up.  `here' because the only cell reportable
            ;; from another window is a release, and there is no gesture left to
            ;; follow once the button is up.
            (when (and pressed here (not wheel)
                       (or (cooked-mouse-state-drag cooked--mouse-state)
                           (cooked-mouse-state-motion cooked--mouse-state)))
              (cooked--mouse-track window)))))))))

(defun cooked--mouse-fallback (event)
  "Run whatever EVENT would do without cooked's binding.

The whole active-map stack, not `global-map\='.  `lookup-key\=' on the global map
alone skips every minor-mode map, the local map and any `keymap\=' property
under the pointer -- so the one binding this most needed to find was the one it
could never reach: `pixel-scroll-precision-mode\=' puts `wheel-up\=' and
`wheel-down\=' in a minor-mode map, and outranking that map is the entire reason
`cooked--mouse-map-alist\=' sits in `emulation-mode-map-alists\='.  Declining a
notch therefore scrolled by the global `mwheel-scroll\=' rather than by the
pixel-precise command the user had turned on, or -- where the mode had rebound
the event to something the global map does not bind at all -- did nothing.

Cooked\='s own maps are lifted out of the stack for the lookup rather than
guarded against afterwards.  They are the binding being declined, so leaving
them in place would find this command again and recurse; removing the one entry
that carries them answers exactly the question being asked, which is what the
event would have done had cooked never claimed it.

The click\='s own position is handed to `key-binding\=' so that the `keymap\='
property and the local map consulted are the ones under the *pointer*.  Emacs
settles a click\='s binding in the buffer the pointer is over and then runs it in
the buffer that was current, and that is the half of the question a plain
`lookup-key\=' cannot even ask."
  (let ((command (cooked--mouse-fallback-binding event)))
    (when (and (commandp command) (not (eq command #'cooked-mouse-event)))
      (setq last-command-event event
            this-command command)
      (call-interactively command))))

(defun cooked--mouse-fallback-binding (event &optional keys)
  "What EVENT would be bound to without cooked\='s mouse maps.

KEYS is the key it ends, by default `this-command-keys-vector\=', which carries
the prefix a click in the mode line is read with.  The lookup
`cooked--mouse-fallback\=' makes; see there."
  (let ((emulation-mode-map-alists
         (remq 'cooked--mouse-map-alist emulation-mode-map-alists)))
    (key-binding (or keys (this-command-keys-vector)) nil nil
                 (and (consp event) (event-start event)))))

;; Pointer shape, OSC 22.
;;
;; kitty's protocol, which ghostty and foot also read: a child that reports the
;; mouse can say what the pointer should look like over it -- a hand over a
;; button, a resize arrow over a split -- by CSS cursor name.  Emacs has its own
;; short list of pointers, so only the names with an equivalent are shown and
;; the rest are remembered and not drawn.
;;
;; It is shown only while the child is being sent mouse reports.  kitty applies
;; it regardless, and that is the one place this departs from the protocol on
;; purpose: with reporting off, a click selects text in the ordinary Emacs way,
;; and an Emacs pointer is the honest thing to show over text Emacs will select.

(defcustom cooked-allow-pointer-shape t
  "Whether the child may set the mouse pointer over its screen, via OSC 22.

On by default, unlike `cooked-allow-color-set\=', because what it can reach is
narrower: the pointer changes over this terminal\='s own grid and only while
the child is being sent mouse reports, so a hostile stream can do no more than
draw a hand over text it already controls.  When off, sets are ignored and a
query is told that no shape is supported, which is the truth about what a set
would then do.  Turning it off removes a shape already on show at once."
  :type 'boolean
  :group 'cooked)

(defconst cooked--pointer-shapes
  '(("text" . text) ("xterm" . text)
    ("pointer" . hand) ("hand" . hand) ("hand1" . hand) ("hand2" . hand)
    ("default" . arrow) ("left_ptr" . arrow)
    ("ew-resize" . hdrag) ("col-resize" . hdrag)
    ("e-resize" . hdrag) ("w-resize" . hdrag) ("sb_h_double_arrow" . hdrag)
    ("ns-resize" . vdrag) ("row-resize" . vdrag)
    ("n-resize" . vdrag) ("s-resize" . vdrag) ("sb_v_double_arrow" . vdrag)
    ("wait" . hourglass) ("progress" . hourglass) ("watch" . hourglass))
  "OSC 22 shape names Emacs can show, each with the `pointer\=' value showing it.

The CSS names kitty specifies, plus the X11 cursor-font spellings it permits as
aliases, restricted to the ones with an Emacs pointer to stand for them.
`crosshair\=', `grab\=', `not-allowed\=' and the diagonal resizes have none, so
they are absent and a query answers 0 for them.  `nhdrag\=' and `modeline\=' go
the other way: Emacs has them and CSS has no name that means them.")

(defconst cooked--pointer-stack-limit 16
  "How many shapes each screen's OSC 22 stack holds before dropping its bottom.
Sixteen is the minimum kitty requires of a terminal.")

(defconst cooked--pointer-name-regexp "\\`[a-z0-9_-]\\{1,32\\}\\'"
  "What an OSC 22 name may look like to be kept on a stack.

kitty\='s spec limits names to lowercase letters, digits, `_\=' and `-\=', and the
longest in `cooked--pointer-shapes\=', `sb_v_double_arrow\=', is 17 of them, so
32 is room to spare.  A name outside that is refused rather than kept, because
`__current__\=' reads the top of the stack back to the child: a push of
`rm -rf ~ x\=' followed by that query would otherwise put the command on the
child\='s input.")

(defvar-local cooked--pointer-stacks nil
  "OSC 22 shape stacks, an alist of `main\=' or `alt\=' to names, top first.

One per screen, as the protocol asks: a full-screen program that pushes a shape
and exits without popping it leaves it on the alternate screen\='s stack, so the
shell underneath does not inherit it.  A drain applies its events after its
screen switch, so an OSC 22 sent in the same drain as the switch lands on the
stack of the screen the drain ends on.  That is the price of deciding this in
Lisp, and a small one: a program sets a shape as the pointer moves, long after
it took the screen.

Names are kept whether or not `cooked--pointer-shapes\=' knows them, which is
what keeps a push and its pop paired for a child that pushes a shape Emacs
cannot draw.  A name that fails `cooked--pointer-name-regexp\=' is kept as nil
for the same reason: it holds its place for the pop, shows Emacs\=' own pointer,
and a query of `__current__\=' answers 0 for it.")

(defvar-local cooked--pointer-overlay nil
  "Overlay carrying the child\='s pointer over the screen, or nil if none is.")

(defun cooked--pointer-screen ()
  "Which of `cooked--pointer-stacks\=' the child is drawing on."
  (if cooked--alt 'alt 'main))

(defun cooked--osc-pointer-shape (parts)
  "Set, push, pop or query the pointer shape, from the OSC 22 payload PARTS.

The payload is an operation character and a comma-separated list of names:
`=\=' or nothing sets the top of the stack to the first name, `>\=' pushes each
name in turn, `<\=' pops one and ignores the names, and `?\=' asks about each.
A query is always answered, knob or not, with 1 or 0 per name -- or, for
`__current__\=', the name on top of the stack, and 0 when it is empty.

A set with no name at all, `ESC ] 22 ; ST\=', is kitty\='s reset to the default
pointer.  It replaces the top of the stack with nil, as kitty does, so a
program that pushed a shape and reset it can still pop it without taking the
shape underneath with it.  On an empty stack there is nothing to reset.

A push onto a full stack drops the bottom entry, which is kitty\='s rule: the
oldest shape is the one least likely to be popped back to."
  (let* ((payload (string-join parts ";"))
         (op (and (> (length payload) 0)
                  (memq (aref payload 0) '(?= ?> ?< ??))
                  (aref payload 0)))
         (names (mapcar (lambda (name)
                          (and (let ((case-fold-search nil))
                                 (string-match-p cooked--pointer-name-regexp name))
                               name))
                        (split-string (if op (substring payload 1) payload) "," t)))
         (screen (cooked--pointer-screen))
         (stack (alist-get screen cooked--pointer-stacks)))
    (if (eq op ??)
        (cooked--reply-osc
         cooked--session 22
         (mapconcat (lambda (name) (cooked--pointer-query name (car stack)))
                    names ",")
         cooked--osc-bell-terminated)
      (when cooked-allow-pointer-shape
        (let ((new (pcase op
                     (?< (cdr stack))
                     (?> (seq-take (append (reverse names) stack)
                                   cooked--pointer-stack-limit))
                     ;; The first name only, or nil, the default pointer, for none.
                     (_ (if (or names stack) (cons (car names) (cdr stack)) stack)))))
          ;; A program with hover reporting re-sends its shape on every motion,
          ;; and nearly all of those name the shape already on top.
          (unless (equal new stack)
            (setf (alist-get screen cooked--pointer-stacks) new)
            (cooked--sync-pointer-shape)))))))

(defun cooked--pointer-query (name current)
  "The OSC 22 query answer for NAME, with CURRENT the name on top of the stack.

`__default__\=' and `__grabbed__\=' ask what the pointer is when no child shape is
in force, with and without mouse reporting.  cooked changes nothing for either,
so both are Emacs\=' own pointer over buffer text.

A shape is supported only where it can be seen: on a text terminal there is no
pointer to change, so a buffer shown only on tty frames answers 0 for every
name, as it does with `cooked-allow-pointer-shape\=' off."
  (pcase name
    ("__current__" (or current "0"))
    ((or "__default__" "__grabbed__") "text")
    (_ (if (and cooked-allow-pointer-shape
                (assoc name cooked--pointer-shapes)
                (cooked--pointer-displayable-p))
           "1"
         "0"))))

(defun cooked--pointer-displayable-p ()
  "Whether a frame this buffer is on can show a mouse pointer at all.

The frames of the windows showing it, or the selected frame when there are none,
since that is where a buffer not yet displayed is about to appear.  Any one
graphical frame is enough: that is where the pointer would be seen."
  (seq-some #'display-graphic-p
            (or (mapcar #'window-frame (get-buffer-window-list nil nil t))
                (list (selected-frame)))))

(defun cooked--sync-pointer-shape (&optional allow)
  "Show the child\='s pointer shape over the screen if it may be, or remove it.

ALLOW, when given, is `(VALUE)\=' and stands in for
`cooked-allow-pointer-shape\=', for the variable watcher, which runs before the
new value is in place.

Shown while the child is being sent mouse reports: the reporting gate is
`cooked--mouse-grab\=', and `enabled\=' is asked as well because that gate also
opens for alternate scroll, where the child asked for nothing about the mouse.

An overlay rather than a text property, and from `cooked--screen-start\=' to
the end: the rows under it are deleted and reinserted on every redraw, which
would take a text property with them, while an overlay whose end advances
simply takes the new text in.  Its start does not follow a scroll by itself --
scrollback is inserted at the start and would be taken in too -- so
`cooked--apply\=' calls this after every drain to put it back on the marker.

It is moved only when its bounds differ.  `move-overlay\=' to the bounds it
already has still counts as a change to the buffer\='s overlays, and that costs
redisplay the shortcuts it takes for a buffer whose text and overlays are as it
last drew them -- on every drain, which is the path those shortcuts are for.
`overlay-put\=' of the value already there costs nothing, so it is not guarded.

An overlay property outranks a text property, so over a command line the
child\='s shape replaces the `pointer hand\=' that
`cooked-command-decorations\=' puts on its text.  That is right for as long as
it lasts: the shape is shown only while the child is sent the clicks, and a
click there is the child\='s, not a decoration\='s.

Past the end of a row\='s text there is no buffer position for any property to
sit on, and Emacs shows `void-text-area-pointer\=' there.  That variable is read
in whatever buffer is current when the pointer moves, not the one under it, so
setting it here would repaint the void of every window while this one was
selected; the blank tail of a short row keeps Emacs\=' own pointer instead."
  (let ((pointer (and (if allow (car allow) cooked-allow-pointer-shape)
                      cooked--session
                      cooked--mouse-grab
                      (cooked-mouse-state-enabled cooked--mouse-state)
                      (cdr (assoc (car (alist-get (cooked--pointer-screen)
                                                  cooked--pointer-stacks))
                                  cooked--pointer-shapes))))
        (start (cooked--screen-start-position)))
    (if (and pointer start)
        (save-restriction
          (widen)
          (if cooked--pointer-overlay
              (unless (and (eql (overlay-start cooked--pointer-overlay) start)
                           (eql (overlay-end cooked--pointer-overlay) (point-max)))
                (move-overlay cooked--pointer-overlay start (point-max)))
            ;; Front-advance nil and rear-advance t: a row reinserted at either
            ;; end of the screen lands inside the overlay rather than beside it.
            (setq cooked--pointer-overlay (make-overlay start (point-max) nil nil t)))
          (overlay-put cooked--pointer-overlay 'pointer pointer))
      (when cooked--pointer-overlay
        (delete-overlay cooked--pointer-overlay)
        (setq cooked--pointer-overlay nil)))))

(defun cooked--sync-pointer-shape-on-toggle (symbol newval operation where)
  "Follow SYMBOL, the pointer shape knob, to NEWVAL, as a variable watcher.

WHERE is the buffer a buffer-local OPERATION applies to, and nil for the default
value, which reaches every buffer that has not made the variable local.  Without
this a shape on show when the knob went off stayed until the next drain.

`kill-local-variable\=' arrives as `makunbound\=' with NEWVAL nil, while the
value the buffer is left with is the default one, so that is what it syncs to."
  (unless (eq operation 'defvaralias)
    (if where
        (when (buffer-live-p where)
          (with-current-buffer where
            (when (derived-mode-p 'cooked-mode)
              (cooked--sync-pointer-shape
               (list (if (eq operation 'makunbound) (default-value symbol) newval))))))
      (cooked--dolist-buffers
        (unless (local-variable-p 'cooked-allow-pointer-shape)
          (cooked--sync-pointer-shape (list newval)))))))

(defun cooked--reset-pointer-shapes ()
  "Empty both OSC 22 stacks, on RIS, as the protocol requires."
  (setq cooked--pointer-stacks nil)
  (cooked--sync-pointer-shape))

(provide 'cooked-mouse)
;;; cooked-mouse.el ends here
