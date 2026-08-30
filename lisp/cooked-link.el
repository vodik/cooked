;;; cooked-link.el --- URLs and OSC 8 hyperlinks in terminal output -*- lexical-binding: t; -*-

;;; Commentary:

;; Two ways a link gets into a cooked buffer, and they meet here.
;;
;; The child may *say* so, with `OSC 8' — the escape sequence `ls --hyperlink',
;; `gcc -fdiagnostics-urls', delta, gh and an increasing number of build tools emit.
;; That half is first-class and runs through the emulator: the native core attaches a
;; link id to the cells the sequence covers (see src/emu/link.rs), carries it through
;; wraps, rewraps and scrollback eviction exactly as it carries an underline colour,
;; and hands Lisp `(START END ID)' spans plus a table of `(ID . URI)'.  Nothing is
;; guessed, because nothing has to be.
;;
;; Or the text may merely *look* like a link, which is the overwhelmingly common case
;; and is a guess.  Emacs has made that guess well for thirty years, so this makes it
;; by calling `goto-address-fontify-region' over freshly-rendered rows rather than by
;; growing a regexp of its own.  What that buys, beyond the two regexps: `follow-link'
;; (so `mouse-1-click-follows-link' works with no help from us), `help-echo', the
;; `goto-address' context-menu entry, and the user's own customisations of
;; `goto-address-url-face' and friends, all of which a private implementation would
;; have had to reproduce and would have reproduced worse.
;;
;; Why calling it per row is safe, which is the only thing about the adapter that
;; needed checking.  goto-addr makes *overlays*, and every one of them carries
;; `evaporate t'.  `cooked--render-rows' deletes a damaged row before rewriting it, so
;; that row's overlays collapse to zero length and Emacs deletes them itself; nothing
;; is left behind as a husk, and there is no unfontify pass to own.  A row that is
;; redrawn is rescanned, which is what makes a link appear the moment the text does.
;;
;; `goto-address-prog-mode' is deliberately left off: it asks `(nth 8 (syntax-ppss))'
;; per candidate, which over raw terminal output is a question with no meaning and a
;; parse the buffer cannot answer.
;;
;; The one accepted gap, stated plainly because it is visible: a URL that the child
;; wrapped across a column boundary is not matched while it is on screen.  Each live
;; row is its own hard-newlined buffer line and `goto-address-url-regexp' stops at a
;; newline, so the two halves are two lines.  It becomes matchable once the row is
;; evicted, because `cooked-rejoin-wrapped-lines' joins a wrapped row onto the line
;; above it in the scrollback, and the scrollback pass then sees one string.  Anything
;; better means detecting links against the *grid* rather than the buffer, which is a
;; different design and a much larger one.
;;
;; File names are not detected here.  Deciding that `src/lib.rs' is a file rather than
;; a word means asking the filesystem, and asking it per candidate per redraw is a
;; syscall on the render hot path.  `cooked-file-link.el' is that feature, and it is
;; require-to-enable on the model of `cooked-osc-eval.el' and
;; `cooked-shell-completion.el': it sets the two nil-valued function variables below,
;; so the file being loaded *is* the feature being on.

;;; Code:

(require 'goto-addr)
(require 'browse-url)

(declare-function cooked--suspended-p "cooked")
(declare-function cooked--child-owns-keyboard-p "cooked")
(declare-function cooked-mouse-event "cooked-mouse")
(declare-function cooked-send-key "cooked-mode")
(defvar cooked--mouse-grab)

(defgroup cooked-link nil
  "Links in terminal output."
  :group 'cooked)

(defcustom cooked-detect-links t
  "Whether to scan rendered output for things that look like URLs.

The guess, not the `OSC 8' sequences — those are what the child actually said,
and are always honoured.  Turning this off leaves a real hyperlink clickable
and stops cooked running `goto-address-fontify-region' over rows as they are
drawn."
  :type 'boolean
  :group 'cooked-link)

(defcustom cooked-detect-links-on-alt-screen nil
  "Whether to scan the alternate screen for URLs as well.

Off, and the reasoning is worth having.  The alternate screen is a full-screen
program repainting continuously — the one place where a per-row regexp scan is
paid over and over for text that is about to be overwritten — and it is also
where the child is most likely to have grabbed the mouse for itself, so a link
under the pointer is the last thing a click there should mean.  A program that
wants a hyperlink on its own screen can say so with `OSC 8', which is honoured
on both screens regardless of this."
  :type 'boolean
  :group 'cooked-link)

(defface cooked-link '((t :inherit link))
  "Face for `OSC 8' hyperlinks whose text carries no styling of its own.

Only then.  A link the child coloured keeps the colour it asked for: it said
both things, and overriding the one with the other would make cooked's idea of
a link beat the program's idea of its own output.  Underlining every hyperlink
regardless is what a plain terminal does because it has nowhere else to put the
information; here the `mouse-face' and the `help-echo' carry it."
  :group 'cooked-link)

(defvar cooked-link-follow-function nil
  "Function tried before `browse-url' when following the thing at point.

Called with no arguments, with point at the candidate.  Returns non-nil if it
opened something, in which case nothing else is tried.  nil by default: this is
the seam `cooked-file-link.el' sets to add local-file linking, and with that
file not loaded there is no function to name and no second switch that could
disagree with its absence.")

(defvar cooked-link-scan-function nil
  "Function called over each batch of output that has settled into scrollback.

Called with two arguments, the start and end of the newly-appended region.
Run once per batch and never from the live-row path, which is what makes it
affordable for something that has to touch the filesystem to answer.  nil by
default; see `cooked-link-follow-function'.")

;;;; The table behind an OSC 8 id

(defvar-local cooked--link-uris nil
  "Hash table mapping this buffer's `OSC 8' link ids to their URIs.

Strong and buffer-local, like `cooked--image-data\=': the native core sends a
URI exactly once per distinct destination however many cells or drains name it,
so this holds the only copy Emacs has.  Bounded on the other side of the
boundary rather than here -- see `LinkStore\=' in src/emu/link.rs -- because
that is where the ids are minted.")

(defun cooked--install-links (links)
  "Record LINKS, a drain's `:links\=', before anything referring to them renders.

Each entry is (ID . URI).  Called from `cooked--apply\=' beside
`cooked--install-images\=' and for the identical reason: a link is a resource the
rows of this very drain name by id, so it has to be here before they render.
Events are dispatched after both render passes, so a link arriving as one would
arrive too late for the row that needed it."
  (when links
    (unless cooked--link-uris
      (setq cooked--link-uris (make-hash-table :test #'eq)))
    (pcase-dolist (`(,id . ,uri) links)
      (puthash id uri cooked--link-uris))))

(defun cooked-link-uri (&optional pos)
  "The `OSC 8' destination of the text at POS, or nil if it carries none."
  (when-let* ((table cooked--link-uris)
              (id (get-text-property (or pos (point)) 'cooked-link-id)))
    (gethash id table)))

;;;; Following

(defun cooked--link-forwarding-keys-p ()
  "Whether a key pressed now would be forwarded to the child."
  (and (cooked--child-owns-keyboard-p) (not (cooked--suspended-p))))

(defun cooked-follow-link (&optional event)
  "Open the link at point, or hand EVENT to the child if it owns the input.

The gate is not politeness, it is a documented guarantee.  A `keymap' text or
overlay property is consulted *before* `emulation-mode-map-alists\=', so the
binding this command sits on outranks `cooked--mouse-map\=' — and a plain click
while the child has grabbed the mouse belongs to the child, with Shift as the
sanctioned escape (see the README, and the `selection confusion\=' entry in
bugs.org).  The same holds for RET while keys are being forwarded.  So an
unshifted invocation in either of those states forwards exactly what it would
have forwarded had this binding not existed, and the shifted variant — `S-RET\='
and `S-mouse-2\=' — follows the link regardless, which is what keeps a link
reachable at all inside a full-screen program.

What gets opened, in order: an `OSC 8\=' destination, because the child said so
and nothing here has to guess; then `cooked-link-follow-function\=', which is
where local files are answered when that layer is loaded; then goto-addr's own
`goto-address-at-point\=', which handles both the URL and the mail case."
  (interactive (list last-nonmenu-event))
  ;; Both questions are asked of `last-input-event' rather than of EVENT: it is the
  ;; same object for every interactive route into here, and it is the one that is
  ;; still right when a caller passes no event at all.
  (let ((mouse (mouse-event-p last-input-event))
        (shift (memq 'shift (event-modifiers last-input-event))))
    (cond
     ((and (not shift) mouse (bound-and-true-p cooked--mouse-grab))
      (cooked-mouse-event))
     ((and (not shift) (not mouse) (cooked--link-forwarding-keys-p))
      (cooked-send-key))
     (t
      (when (and (consp event) (posn-point (event-end event)))
        (posn-set-point (event-end event)))
      (if-let* ((uri (cooked-link-uri)))
          (browse-url uri)
        (or (and cooked-link-follow-function
                 (funcall cooked-link-follow-function))
            (goto-address-at-point)))))))

(defun cooked-follow-link-at-point ()
  "Follow the link at point, whoever owns the keyboard.

The keyboard entry point that does not depend on point sitting inside a
highlighted span: bound on `cooked-mode-map\=' under \\`C-c RET', which is
goto-addr's own advertised key and reaches cooked's commands in every state
where Emacs is reading them at all.  It is what answers a file name that
nothing highlighted, since `cooked-link-follow-function\=' validates on demand."
  (interactive)
  (if-let* ((uri (cooked-link-uri)))
      (browse-url uri)
    (or (and cooked-link-follow-function
             (funcall cooked-link-follow-function))
        (goto-address-at-point))))

(defvar-keymap cooked-link-map
  :doc "Bindings carried by the text of a link.

Hung on the text as a `keymap' property for an `OSC 8' span, and substituted
for `goto-address-highlight-keymap' over goto-addr's own overlays, so both
kinds of link answer the same keys.  `C-c RET' is deliberately absent even
though goto-addr binds it and its `help-echo' advertises it: `C-c' is forwarded
to the child as the interrupt character, and a `C-c' prefix in a property at
point would make Emacs wait for a second key before letting SIGINT through.
The command lives on `cooked-mode-map' instead, where the state that decides
whether cooked's own `C-c' map is reachable at all already decides it."
  "<mouse-2>"   #'cooked-follow-link
  "S-<mouse-2>" #'cooked-follow-link
  "RET"         #'cooked-follow-link
  "S-<return>"  #'cooked-follow-link)

;;;; The OSC 8 pass

(defconst cooked--link-keys "mouse-2, C-c RET: follow link"
  "How to follow an OSC 8 span, worded like goto-addr's own.")

(defun cooked--link-help-echo (_window object pos)
  "`help-echo' for an OSC 8 span: where following it would actually go.

Called by redisplay with the span's OBJECT -- the buffer, or the string it was
found in -- and POS, the position within it.

OSC 8 is the one link kind whose text and destination are independent -- the
child chooses both -- so a span can read like one address and point at another,
and unlike a goto-addr match there is nothing on screen to check it against.
Showing the target is what kitty, VTE and iTerm2 all do about that, and it is
the whole of the defence: following is the user\='s own doing, so the thing to
protect is the decision rather than the act.

A function rather than the string it returns, because the id has to be resolved
against `cooked--link-uris\=' and doing that per span while rendering would put
a hash lookup and a `format\=' on the render path for every link in every
damaged row.  Hover is rare; drains are not."
  (let ((buffer (if (bufferp object) object (current-buffer))))
    (if-let* ((uri (and (buffer-live-p buffer)
                        (with-current-buffer buffer (cooked-link-uri pos)))))
        (format "%s\n%s" uri cooked--link-keys)
      cooked--link-keys)))

(defun cooked--render-link-spans (start spans)
  "Apply SPANS, a block's LINK-SPANS, to text inserted at START.

Each span is (FROM TO ID) with offsets in characters — see `Block' in
src/lib.rs.  The face is left alone whenever the run carries styling of its
own, since the child asked for both and its colours are the more specific
statement; only unstyled link text is given `cooked-link'.

Image cells are skipped.  They are blanks carrying a `display' slice, so a
`mouse-face' on one would highlight a rectangle of a picture and a keymap would
claim a click the image had a better claim to."
  ;; Guarded for the reason `cooked--apply-deco' is guarded: a link is a
  ;; convenience laid over text that has already been inserted, and no failure of
  ;; it may take the redisplay with it.
  (condition-case nil
      (pcase-dolist (`(,from ,to ,id) spans)
        (let ((beg (+ start from))
              (end (+ start to)))
          (unless (eq (car-safe (get-text-property beg 'cooked-deco)) 'image)
            (add-text-properties beg end
                                 (list 'cooked-link-id id
                                       'mouse-face 'highlight
                                       'follow-link t
                                       'help-echo #'cooked--link-help-echo
                                       'keymap cooked-link-map))
            (unless (get-text-property beg 'face)
              (put-text-property beg end 'face 'cooked-link)))))
    (error nil)))

;;;; The goto-addr pass

(defun cooked--fontify-links (beg end)
  "Scan BEG..END for things that look like URLs, and highlight what it finds.

`goto-address-fontify-region' does the whole of the work; what is here is the
three things cooked has to say about it.

`goto-address-highlight-keymap' is swapped for `cooked-link-map' by let-binding
it, because the overlay records the keymap's *value* at the moment it is put.
Without that a click on a link would beat the child's own mouse grab — a
`keymap' property outranks `emulation-mode-map-alists' — which is exactly the
guarantee `cooked-follow-link' exists to keep.

`goto-address-prog-mode' is bound off: it tests `(nth 8 (syntax-ppss))', which
over raw terminal output parses nothing meaningful.

And an explicit `OSC 8' span wins.  A match that starts inside one is dropped
rather than suppressed beforehand, since goto-addr offers no hook to filter
with and the alternative is reimplementing its scan to add one.  Overlays are
cheap and this only ever runs over a row or a batch."
  (when cooked-detect-links
    ;; Guarded like `cooked--apply-deco': this runs from inside the drain, over
    ;; text that is already correct without it, and `goto-address-url-regexp' is a
    ;; variable the user may have replaced.  A cosmetic pass must not be able to
    ;; abort a redisplay half-done.
    (condition-case nil
        (progn
          (let ((goto-address-highlight-keymap cooked-link-map)
                (goto-address-prog-mode nil))
            (goto-address-fontify-region beg end))
          (dolist (overlay (overlays-in beg end))
            (when (and (overlay-get overlay 'goto-address)
                       (get-text-property (overlay-start overlay) 'cooked-link-id))
              (delete-overlay overlay))))
      (error nil))))

(provide 'cooked-link)

;;; cooked-link.el ends here
