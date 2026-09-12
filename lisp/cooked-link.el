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

(require 'seq)
(require 'goto-addr)
(require 'browse-url)
(require 'thingatpt)
;; The seam helpers below -- `cooked--protect-seam' and
;; `cooked--run-seam-until-success' -- live here.  The first is a *macro*, so
;; without this the file compiles a call to a function that does not exist and
;; the guard it is supposed to install is simply absent: the body then runs
;; unprotected from inside the process filter and signals `void-function' there.
;; cooked.el requires this file, so cooked-util.el is the one place in the graph
;; it can be reached from.
(require 'cooked-util)

;; What was here until recently was four `declare-function's -- `cooked--suspended-p',
;; `cooked--child-owns-keyboard-p', `cooked-mouse-event' and `cooked-send-key' -- plus
;; a `defvar' for `cooked--mouse-grab'.  Two of those are input-ownership *policy
;; questions*, and this file is base tier, where `docs/DESIGN.md' says a file "carries
;; notifications upward, never questions."  A link layer deciding whether a click
;; belongs to the child is that rule broken outright: the answer depends on the mouse
;; grab, on whether keys are being forwarded and on whether the session is suspended,
;; none of which this file has any business knowing.
;;
;; `cooked-link-delegate-function' inverts it.  This file states the *occasion* -- an
;; unshifted invocation, which is the one the child could plausibly own -- and the
;; layer that already owns input decides and acts.  See `cooked--link-delegate' in
;; cooked-keys.el, which is where the grab and the forwarding state already live.

(defvar cooked-link-delegate-function nil
  "Function offered an unshifted link invocation before the link is followed.

Called with one argument, the event that invoked the command, and returns
non-nil if it *took* the event -- forwarded it to the child, or otherwise
handled it -- in which case no link is followed.  nil means the invocation
belongs to Emacs and the link is opened.

Set from above by whichever layer owns input; unset, every invocation follows
the link, which is the right answer for a buffer with no child in it.  The
shifted variants never reach here at all: `S-RET' and `S-mouse-2' are the
sanctioned escape and must keep working whatever the child has grabbed.")

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

(defvar cooked-link-follow-functions nil
  "Abnormal hook tried before `browse-url' when following the thing at point.

Each entry is called with no arguments, with point at the candidate, and
returns non-nil if it opened something -- at which point nothing after it is
tried.  Run through `cooked--run-seam-until-success', so an entry that signals
has given no answer and the next one is asked rather than the whole seam
falling silent over one layer's bug.

Empty by default: this is the seam `cooked-file-link.el' adds itself to for
local-file linking, and with that file not loaded there is nothing on the hook
and no second switch that could disagree with its absence.")

(defvar cooked-link-scan-functions nil
  "Abnormal hook run over each batch of output that has settled into scrollback.

Each entry is called with two arguments, the start and end of the newly-appended
region, and its value is ignored.  Run once per batch and never from the
live-row path, which is what makes it affordable for something that has to touch
the filesystem to answer.  Empty by default; see
`cooked-link-follow-functions'.

Run through `cooked--run-seam', so one entry signalling costs its own
contribution and nothing else's.")

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

(defun cooked--open-link-at-point ()
  "Open whatever at point counts as a link, in the order the sources rank.

An `OSC 8\=' destination first, because the child named it and nothing here has
to guess; then `cooked-link-follow-functions\=', which is where local files are
answered when that layer is loaded; then goto-addr\='s own
`goto-address-at-point\=', which handles both the URL and the mail case.

The shared tail of `cooked-follow-link\=' and `cooked-follow-link-at-point\=',
which differ only in what they do *before* deciding to open anything."
  (if-let* ((uri (cooked-link-uri)))
      (browse-url uri)
    (or (cooked--run-seam-until-success 'cooked-link-follow-functions)
        (goto-address-at-point))))

(defun cooked-follow-link (&optional event)
  "Open the link at point, or hand EVENT to the child if it owns the input.

The gate is not politeness, it is a documented guarantee.  A `keymap' text or
overlay property is consulted *before* `emulation-mode-map-alists\=', so the
binding this command sits on outranks `cooked--mouse-map\=' — and a plain click
while the child has grabbed the mouse belongs to the child, with Shift as the
sanctioned escape -- see the README.  Without that rule a click meant for the
program underneath would follow a link instead, which is the confusion the
shifted variant exists to settle.  The same holds for RET while keys are being
forwarded.  So an
unshifted invocation in either of those states forwards exactly what it would
have forwarded had this binding not existed, and the shifted variant — `S-RET\='
and `S-mouse-2\=' — follows the link regardless, which is what keeps a link
reachable at all inside a full-screen program.

Once it does decide to open something, `cooked--open-link-at-point\=' says what
that is."
  (interactive (list last-nonmenu-event))
  ;; The shift test is asked of `last-input-event' rather than of EVENT: it is the
  ;; same object for every interactive route into here, and it is the one that is
  ;; still right when a caller passes no event at all.  The delegate is handed that
  ;; same object for the same reason.
  (unless (and (not (memq 'shift (event-modifiers last-input-event)))
               cooked-link-delegate-function
               (funcall cooked-link-delegate-function last-input-event))
    (when (and (consp event) (posn-point (event-end event)))
      (posn-set-point (event-end event)))
    (cooked--open-link-at-point)))

(defun cooked-follow-link-at-point ()
  "Follow the link at point, whoever owns the keyboard.

The keyboard entry point that does not depend on point sitting inside a
highlighted span: bound on `cooked-mode-map\=' under \\`C-c RET', which is
goto-addr's own advertised key and reaches cooked's commands in every state
where Emacs is reading them at all.  It is what answers a file name that
nothing highlighted, since `cooked-link-follow-functions\=' validates on demand."
  (interactive)
  (cooked--open-link-at-point))

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

(defun cooked-link--osc-8-claim-p (pos)
  "Whether an `OSC 8\=' span covers POS."
  (get-text-property pos 'cooked-link-id))

(defun cooked-link--goto-addr-claim-p (pos)
  "Whether the detected-URL pass has claimed POS.

A text property since the pass stopped making overlays -- see
`cooked--fontify-links\='."
  (get-text-property pos 'cooked-link-url))

(defvar cooked-link-claim-functions
  (list (cons 'osc-8 #'cooked-link--osc-8-claim-p)
        (cons 'goto-addr #'cooked-link--goto-addr-claim-p))
  "Sources that can claim a span as a link, in order of precedence.

An alist of (SYMBOL . PREDICATE); PREDICATE is called with a buffer position
and answers whether that source has claimed it.  Earlier entries outrank later
ones, and `cooked-link--claimed-p\=' is the arbiter.

The list is *data the layers contribute to* rather than an ordering written
into this file, and the difference is not cosmetic.  The ranking used to be a
constant here reading `OSC 8\=' > goto-addr > \"guessed shape\" -- but guessed
shape is `cooked-file-link.el\='s output, so the base layer was naming a
category that does not exist unless an optional layer above it happens to be
loaded.  A source now registers itself, at the rank it belongs at, from the
file that produces it.

The two entries here are the two this file produces, in the order they have
always ranked: what the child named outright first, then what goto-addr read
out of the text.  A layer that *guesses* -- from a shape, from the filesystem
-- appends itself, because guessing is the only kind that can be wrong about
what the text even is.")

(defun cooked-link--claimed-p (pos &optional source)
  "Which source, if any, has already made the text at POS a link.

Returns the claiming source\='s symbol, or nil.  With SOURCE, answers only for
sources ranked *above* it: a source asks before claiming, and must not be told
that it has claimed the position itself -- nor be blocked by something it
outranks.  The walk therefore stops at SOURCE\='s own entry.

Deliberately *not* the question `cooked--fontify-links\=' asks when it drops a
goto-addr overlay: that one is specifically about an `OSC 8\=' span having
claimed the same characters, and widening it to \"claimed\" would have it
delete overlays sitting over file names too."
  (catch 'claimed
    (pcase-dolist (`(,symbol . ,predicate) cooked-link-claim-functions)
      (when (eq symbol source) (throw 'claimed nil))
      (when (funcall predicate pos) (throw 'claimed symbol)))
    nil))

(defun cooked-link--propertize (beg end &rest extra)
  "Make BEG..END behave as a link, carrying EXTRA over the common properties.

The three every link kind shares -- the highlight, `follow-link\=' for
`mouse-1-click-follows-link\=', and the keymap that answers RET and mouse-2 --
spelled once, so two kinds cannot drift into answering different keys.  EXTRA
is a plist for what the caller\='s own kind adds: its id, its `help-echo\=', its
face."
  (add-text-properties beg end
                       (append extra
                               (list 'mouse-face 'highlight
                                     'follow-link t
                                     'keymap cooked-link-map))))

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
  (cooked--protect-seam 'cooked--render-link-spans
    (pcase-dolist (`(,from ,to ,id) spans)
      (let ((beg (+ start from))
            (end (+ start to)))
        (unless (eq (car-safe (get-text-property beg 'cooked-deco)) 'image)
          (cooked-link--propertize beg end
                                   'cooked-link-id id
                                   'help-echo #'cooked--link-help-echo)
          (unless (get-text-property beg 'face)
            (put-text-property beg end 'face 'cooked-link)))))))

;;;; The goto-addr pass

(defvar cooked--url-scheme-regexp nil
  "Cached (SCHEMES . REGEXP) for `thing-at-point-uri-schemes\='.")

(defun cooked--url-scheme-regexp ()
  "The scheme alternation `thing-at-point\=' would have built, built once."
  (let ((schemes thing-at-point-uri-schemes))
    (if (eq (car cooked--url-scheme-regexp) schemes)
        (cdr cooked--url-scheme-regexp)
      (cdr (setq cooked--url-scheme-regexp
                 (cons schemes (regexp-opt schemes)))))))

(defconst cooked-link--url-properties
  '(cooked-link-url face mouse-face follow-link help-echo keymap)
  "The properties the detected-URL pass owns, and the only ones it removes.

Named once so unfontifying cannot drift from fontifying and leave a stray
`mouse-face' highlighting text that is no longer a link.")

(defun cooked-link--unfontify-urls (beg end)
  "Remove the detected-URL pass's own properties from BEG..END.

`goto-address-fontify' begins with `goto-address-unfontify' and this is the
same move, but it has to be *narrower*: an overlay could simply be deleted,
where these properties share their names with the ones an `OSC 8' span sets.
So only runs actually carrying `cooked-link-url' are cleared, which leaves an
explicit hyperlink -- and cooked-file-link.el's spans -- untouched."
  (let ((pos beg))
    (while (< pos end)
      (let ((next (or (next-single-property-change pos 'cooked-link-url nil end)
                      end)))
        (when (get-text-property pos 'cooked-link-url)
          (remove-list-of-text-properties pos next cooked-link--url-properties))
        (setq pos next)))))

(defun cooked-link--fontify-url-match (beg end url face mouse-face help-echo)
  "Make BEG..END a detected link to URL, unless something outranks it."
  (unless (cooked-link--claimed-p beg 'goto-addr)
    (cooked-link--propertize beg end
                             'cooked-link-url url
                             'help-echo help-echo
                             'mouse-face mouse-face
                             'face (and goto-address-fontify-p face))))

(defun cooked--fontify-links (beg end)
  "Scan BEG..END for things that look like URLs, and highlight what it finds.

Text properties, not overlays, and that is the substance of this rather than a
detail.  goto-addr makes an overlay per match; on a *live* terminal row that is
the expensive form twice over -- redisplay assembles the overlay list per
window per redisplay, and `note_mouse_highlight' walks `overlays_at' on every
motion event over the buffer.  cooked's own `OSC 8' path has always used
properties, so this also stops one buffer answering the same question two
different ways.  REPORT.org §7 ranks it fourth of the borrowables.

What replacing `goto-address-fontify-region' costs is the scan itself, which is
reproduced here rather than called -- goto-addr offers no hook to filter its
matches with, and the filtering is the point.  Everything observable is kept:
both regexps, `bounds-of-thing-at-point' for the URL bounds where goto-addr
uses it and the raw match for mail where it does not, `goto-address-fontify-p',
`goto-address-fontify-maximum-size', and the user's own
`goto-address-url-face', `goto-address-mail-face' and the two mouse faces.
What is not kept is the button.el wiring (`button', `action', `category'):
`cooked-link-map' already answers RET and mouse-2, which is the interaction
those existed to provide.

`thing-at-point-beginning-of-url-regexp' is bound because thingatpt does not
cache it.  `bounds-of-thing-at-point' is asked about every match, and with that
variable nil -- its default -- the well-formed-URL check runs `regexp-opt' over
ninety-odd schemes for each one: a millisecond and 170 KB of garbage per row
carrying a URL, which is a full GC every few keystrokes at a prompt.  The bound
value is literally the expression thingatpt would have evaluated, so nothing
about the match changes; ffap binds the same variable for the same purpose.

An explicit `OSC 8' span still wins, but now by being *asked* rather than by
having its overlays deleted afterwards: `cooked-link--claimed-p' is consulted
per match with `goto-addr' as the asking source, so the precedence is the one
`cooked-link-claim-functions' states and nothing is created only to be undone."
  (when cooked-detect-links
    ;; Guarded like `cooked--apply-deco': this runs over text that is already
    ;; correct without it, and `goto-address-url-regexp' is a variable the user
    ;; may have replaced.  A cosmetic pass must not abort a redisplay half-done.
    (cooked--protect-seam 'cooked--fontify-links
      (let ((inhibit-read-only t))
      ;; Scrollback carries `read-only', and this pass writes *text properties*
      ;; now where it used to make overlays -- which touch no text and so never
      ;; needed this.  `cooked--fontify-region' binds it too, but a cosmetic pass
      ;; that signals `text-read-only' from inside redisplay is a bad enough
      ;; failure to be worth being self-sufficient about.
      (when (or (eq t goto-address-fontify-maximum-size)
                (< (- end beg) goto-address-fontify-maximum-size))
        (let ((thing-at-point-beginning-of-url-regexp
               (or thing-at-point-beginning-of-url-regexp
                   (cooked--url-scheme-regexp))))
          (cooked-link--unfontify-urls beg end)
          (save-excursion
            (goto-char beg)
            (while (re-search-forward goto-address-url-regexp end t)
              ;; goto-addr takes the bounds from thingatpt rather than from its
              ;; own match, and the difference is real: the regexp swallows
              ;; trailing punctuation that `bounds-of-thing-at-point' trims.
              (when-let* ((bounds (save-excursion
                                    (goto-char (match-beginning 0))
                                    (bounds-of-thing-at-point 'url))))
                (cooked-link--fontify-url-match
                 (car bounds) (cdr bounds)
                 (buffer-substring-no-properties (car bounds) (cdr bounds))
                 goto-address-url-face goto-address-url-mouse-face
                 "mouse-2, C-c RET: follow URL"))))
          (save-excursion
            (goto-char beg)
            (while (re-search-forward goto-address-mail-regexp end t)
              (cooked-link--fontify-url-match
               (match-beginning 0) (match-end 0)
               (concat "mailto:" (match-string-no-properties 0))
               goto-address-mail-face goto-address-mail-mouse-face
               "mouse-2, C-c RET: mail this address")))))))))

;;;; thing-at-point, which is how everything else finds a link

;; ROADMAP §3 asked for `embark-target-finders' entries.  This is the same feature
;; one layer down and without the dependency: embark's file and URL finders go
;; through `thing-at-point', so a provider installed here answers `embark-act',
;; `browse-url-at-point', ffap and `find-file's `M-n' at once, and answers them in
;; a plain Emacs with no embark installed.
;;
;; The providers are *collected* rather than installed here.  `url' is this file's
;; to contribute and `filename'/`existing-filename' are cooked-file-link.el's, which
;; is an optional layer above cooked.el -- so the installation point straddles the
;; tier boundary and belongs in cooked-mode.el's setup, with each layer contributing
;; its own.  That straddle is the point, not an awkwardness to design around: the
;; alternative is the base layer naming a provider only an upper layer can supply,
;; which is the same mistake `cooked-link-claim-functions' exists to undo.

(defvar cooked-thing-at-point-providers nil
  "Entries for `thing-at-point-provider-alist\=', contributed by each link layer.
An alist of (THING . FUNCTION); cooked-mode.el installs them buffer-locally.")

(defvar cooked-bounds-of-thing-at-point-providers nil
  "Entries for `bounds-of-thing-at-point-provider-alist\=', as above.

Kept separate rather than derived, because the two alists are consulted
independently: a caller asking only for bounds -- which is what embark does to
highlight a target -- must not fall back to thingatpt's own idea of where a
thing ends when this layer knows better.")

(defvar cooked-file-name-at-point-functions nil
  "Entries for `file-name-at-point-functions\=', contributed by each link layer.

Empty unless cooked-file-link.el is loaded -- naming a file is that layer's
whole job -- but the variable lives here so cooked-mode.el has one place to
install from whether or not the layer is present.")

(defun cooked-link--osc-8-bounds (&optional pos)
  "Bounds of the `OSC 8\=' span covering POS, or nil.

The span is delimited by the `cooked-link-id\=' property rather than by
anything in the text, which is what makes it correct across a soft wrap and
across a row boundary: the id travels with the row through eviction, so a
destination broken over three screen rows still answers as one thing."
  (let ((pos (or pos (point))))
    (when-let* ((id (get-text-property pos 'cooked-link-id)))
      (cons (or (previous-single-property-change (1+ pos) 'cooked-link-id) (point-min))
            (or (next-single-property-change pos 'cooked-link-id) (point-max))))))

(defun cooked-link--url-at-point ()
  "The `OSC 8\=' destination at point, for `thing-at-point-provider-alist\='.

Only the OSC 8 case is answered here, and returning nil for everything else is
deliberate: thingatpt\='s own `url\=' thing already reads a bare URL out of the
text, and it reads more schemes than goto-addr does.  What it cannot know is
that these particular characters carry a destination that is not written in
them -- an `OSC 8\=' span\='s text is frequently a label, so the URL is nowhere
on screen.  Answering only that case adds the knowledge without displacing
anything."
  (cooked-link-uri))

(defun cooked-link--url-bounds-at-point ()
  "Bounds of the `OSC 8\=' span at point, for the bounds provider alist."
  (and (cooked-link-uri) (cooked-link--osc-8-bounds)))

(add-to-list 'cooked-thing-at-point-providers
             (cons 'url #'cooked-link--url-at-point))
(add-to-list 'cooked-bounds-of-thing-at-point-providers
             (cons 'url #'cooked-link--url-bounds-at-point))

(provide 'cooked-link)

;;; cooked-link.el ends here
