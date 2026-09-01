;;; cooked-mouse.el --- Mouse reporting for cooked terminals -*- lexical-binding: t; -*-

;;; Commentary:

;; Everything about the mouse: which of Emacs' events become which report, when
;; the child is allowed to see them at all, and the wheel's two answers -- a real
;; report when the child asked for one, arrow keys when it is on the alternate
;; screen and asked only for that.
;;
;; Not opt-in, unlike `cooked-next-error' and its neighbours; `cooked-mode'
;; requires this.  It is a separate file because it is a self-contained subject
;; that had grown to a fifth of `cooked-mode.el' -- it depends on nothing that
;; file defines, which is what made it separable.
;;
;; Reports are only sent when the child asked for them; otherwise the click does
;; what it does in any Emacs buffer, so selecting text still works.  The whole of
;; that gate is `cooked--mouse-grab', and `cooked--update-mouse-grab' is what
;; `cooked-mode.el' calls to keep it current.
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

(require 'cooked)
(require 'cooked-util)

;; Defined by the native core at `module-load' time, so the byte-compiler cannot
;; see it; cooked.el and cooked-mode.el declare what they need of that set the
;; same way.
(declare-function cooked--alt-scroll-p "cooked-core")

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
    map)
  "Mouse bindings for when the child has asked to receive them.

Lives in `emulation-mode-map-alists' rather than in `cooked-raw-map' because a
major mode's local map is near the bottom of Emacs' lookup order, under every
enabled minor mode.  `pixel-scroll-precision-mode' binds `wheel-up' and
`wheel-down' in its own minor-mode map, so on a GUI frame it took the wheel
before the local map was ever consulted — and scrolled the buffer out from
under a program that had asked for those notches.  A terminal frame did not
show this, because there the wheel arrives as `mouse-4'/`mouse-5', which
pixel-scroll does not bind.

The `drag-mouse-N' variants have to be here as well as `down-mouse-N'/`mouse-N',
and their absence was a bug with two faces.  Emacs does not deliver a plain
`mouse-1' when the pointer moved between press and release; it delivers
`drag-mouse-1' instead.  Unbound, that fell through to the global
`mouse-set-region', so the child never learned the button had come up -- it saw
a button held forever -- while Emacs set a region behind its back, which is why
a drag appeared in one jump at the end instead of following the pointer.

Modified variants are deliberately absent: `C-wheel-up' should keep scaling
text, and shift-scrolling should keep working, as they do in any other buffer.
Shift is more than a convenience here: `S-down-mouse-1' reaching
`mouse-drag-region' is the universal escape hatch for selecting text out of a
program that has grabbed the mouse, and it works precisely because this map
never claims it.")

(defvar-local cooked--mouse-grab nil
  "Whether the child both wants the mouse and owns the keyboard.
Gates `cooked--mouse-map'; nil everywhere else, so the entry in
`emulation-mode-map-alists' is inert outside a session that asked for it.")

(defvar cooked--mouse-map-alist `((cooked--mouse-grab . ,cooked--mouse-map))
  "The `emulation-mode-map-alists' entry activating `cooked--mouse-map'.")

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
  ;; Alternate scroll has to be here as well as `cooked--mouse': it exists precisely
  ;; for children that did *not* ask for the mouse, so gating the keymap on
  ;; `cooked--mouse' alone would leave the whole feature unreachable.
  ;;
  ;; Suspended forwarding has to be here too: it hands the buffer back to
  ;; ordinary Emacs commands, and a click should select text like any other
  ;; buffer's, not get reinterpreted as a mouse report to a child that still
  ;; owns the keyboard as far as `cooked--input-state-p' alone can tell.  Both
  ;; `still' and `frozen' count -- the render being live in `still' says nothing
  ;; about who a click belongs to.
  (setq cooked--mouse-grab (and (or cooked--mouse (cooked--alt-scroll-active-p))
                                (not (cooked--input-state-p))
                                (not (cooked--suspended-p)))))

(defun cooked--mouse-cell (posn)
  "Screen row and column of POSN, or nil if it is outside the screen.

A posn rather than an event because the interesting end of an event is not
always the same one: `drag-mouse-1' is a release, and where the button came up
is `event-end'.  Reading `event-start' there reported the release at the cell
the press was already reported in, which is a gesture with no extent at all.

`cooked--screen-cell' rather than a count of lines and columns from the marker:
row 0 does not always begin its buffer line — when the row handed to scrollback
last was wrapped, `cooked--screen-start' sits mid-line — and a plain
`current-column' there counts the characters ahead of the marker, which are
scrollback and not on the screen at all.  Reporting those to the child puts
every click on row 0 to the right of where it was made."
  (when-let* ((pos (posn-point posn)))
    (cooked--screen-cell pos)))

(defun cooked--mouse-report (button row col pressed)
  "Encode a report for BUTTON at ROW/COL, PRESSED or not.

SGR is preferred wherever the child asked for it, because X10 cannot count
past column 223."
  (if cooked--mouse-sgr
      (format "\e[<%d;%d;%d%s" button (1+ col) (1+ row) (if pressed "M" "m"))
    (format "\e[M%c%c%c" (+ 32 (if pressed button 3)) (+ 33 col) (+ 33 row))))

(defun cooked--send-mouse (button row col pressed)
  "Send one report for BUTTON at ROW/COL, PRESSED or not, and drop the region.

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
not share.  One answer for both beats two that agree by accident."
  (cooked--deactivate-mark)
  (setq cooked--mouse-last-cell (cons row col))
  (cooked--send-to-child (cooked--mouse-report button row col pressed)))

(defun cooked--report-button (button row col pressed)
  "Report BUTTON at ROW/COL as PRESSED or released, remembering that it is held."
  (cond ((memq button '(64 65 66 67)))   ; a notch is not a button you can hold
        (pressed (unless (memq button cooked--mouse-held)
                   (push button cooked--mouse-held)))
        (t (setq cooked--mouse-held (delq button cooked--mouse-held))))
  (cooked--send-mouse button row col pressed))

(defun cooked--report-motion (row col)
  "Report the pointer arriving at ROW/COL, if it is a cell it was not already in.

32 is the motion bit, added to the button being dragged; 3 stands for \"no
button\", which is what a 1003 child is told when nothing is held.  Suppressing
a repeat of the last cell is not an optimisation so much as the contract: Emacs
tracks the pointer by pixel, and a child that asked for cells would otherwise
receive several dozen identical reports per cell crossed."
  (unless (equal cooked--mouse-last-cell (cons row col))
    (cooked--send-mouse (+ 32 (or (car cooked--mouse-held) 3)) row col t)))

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

Only the drag half of 1003 is served: any-motion with no button down would mean
tracking the pointer for as long as the child asks, which costs an event per
pixel across the whole frame whether or not the user is doing anything.  A
`track-mouse\=' bounded by a gesture is the affordable part, and it is the part
every 1003 client also gets from 1002."
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
              (cooked--report-motion (car cell) (cdr cell))))))
      (push event unread-command-events))))

(defun cooked--alt-scroll-keys (button)
  "Cursor keys standing in for a wheel notch of BUTTON.

Only the vertical notches translate; a horizontal one has no cursor-key
spelling a pager would understand, so it sends nothing."
  (if-let* ((final (cond ((= button 64) "A") ((= button 65) "B"))))
      (let ((key (if cooked--app-cursor (concat "\eO" final) (concat "\e[" final))))
        (mapconcat #'identity (make-list cooked-alternate-scroll-lines key)))
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
                      (buffer-local-value 'cooked--mouse target))))
    (if (null target)
        (cooked--mouse-fallback event)
      (when select (select-window window))
      (with-current-buffer target
        (let* (;; Whether the pointer is over this buffer, as opposed to naming
               ;; the far end of a drag that started in it.
               (here (eq target (and (windowp window) (window-buffer window))))
               (cell
                (and cooked--mouse button
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
                              (or cooked--mouse-last-cell (cooked--cursor-cell)))))))
          (cond
           ;; Checked before the mouse report: `cooked--alt-scroll-p' is already
           ;; false when the child asked for the mouse, so the two can never both
           ;; apply.
           ((and here wheel button (cooked--alt-scroll-active-p))
            (cooked--send-to-child (cooked--alt-scroll-keys button)))
           ((null cell)
            (cooked--mouse-fallback event))
           (t
            (cooked--report-button button (car cell) (cdr cell) pressed)
            ;; Take the whole gesture or none of it: having reported a press to a
            ;; child that asked where the pointer goes, the motion is ours to
            ;; deliver, and the only way to be given it is to sit in `track-mouse'
            ;; until the button is up.  `here' because the only cell reportable
            ;; from another window is a release, and there is no gesture left to
            ;; follow once the button is up.
            (when (and pressed here (not wheel)
                       (or cooked--mouse-drag cooked--mouse-motion))
              (cooked--mouse-track window)))))))))

(defun cooked--mouse-fallback (event)
  "Run whatever EVENT would do without cooked's binding."
  (let ((command (lookup-key global-map (this-command-keys-vector))))
    (when (commandp command)
      (setq last-command-event event
            this-command command)
      (call-interactively command))))

(provide 'cooked-mouse)
;;; cooked-mouse.el ends here
