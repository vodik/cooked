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
;; and is a guess.  Emacs has made that guess well for thirty years, so the guess is
;; goto-addr's rather than a regexp of this file's own: `goto-address-url-regexp' and
;; `goto-address-mail-regexp', `goto-address-fontify-p',
;; `goto-address-fontify-maximum-size', and the four faces the user may have
;; customised, all of which a private implementation would have had to reproduce and
;; would have reproduced worse.  `follow-link' and `help-echo' are set here, so
;; `mouse-1-click-follows-link' and the tooltip work as they do under
;; `goto-address-mode'.
;;
;; What is *not* borrowed is the scan.  `cooked--fontify-links' reproduces
;; `goto-address-fontify-region' rather than calling it, because a match has to be
;; filtered -- an explicit `OSC 8' span outranks a guess about the same characters --
;; and goto-addr offers no hook to filter with; and because what it leaves behind is
;; text properties where goto-addr makes an overlay per match, which on a live
;; terminal row is the expensive form twice over.  See `cooked--fontify-links' for
;; both, and for the button.el wiring that is deliberately dropped.  Two further
;; things follow from owning the scan.  `goto-address-prog-mode' is not consulted at
;; all, which is the answer this file always wanted: it asks `(nth 8 (syntax-ppss))'
;; per candidate, a question with no meaning over raw terminal output and a parse the
;; buffer cannot answer.  And nothing here ever enables `goto-address-mode', so its
;; context-menu entry is not among what this buys.
;;
;; When the scan runs, which is the only thing about the arrangement that needed
;; checking.  `cooked--fontify-region' is handed to `jit-lock-register', so the scan
;; happens at redisplay over the chunk jit-lock asks about: rows a flood pushed past
;; unseen are never scanned at all.  A row that is rewritten is unfontified again, so
;; jit-lock comes back for it the next time it is displayed, which is what makes a
;; link appear the moment the text does -- and because the marks are properties on
;; that row's own characters, `cooked--render-rows' deleting the row takes them with
;; it.  Text that stays put and is merely rescanned is cleared first by
;; `cooked-link--unfontify-urls', narrowly, so that an `OSC 8' span sharing those
;; property names survives.  `cooked--sync-fontification' has why this moved off the
;; render path and what registering jit-lock costs when there is nothing to scan.
;;
;; A URL the child wrapped across a column boundary used to be the one accepted gap:
;; each live row is its own hard-newlined buffer line, `goto-address-url-regexp' stops
;; at a newline, and so the two halves were two lines.  It closed without detecting
;; against the grid, which was the expensive answer this file had assumed was the only
;; one.  The emulator already knew -- `Row::wrapped' -- and was telling Emacs only on
;; the way out to scrollback, where `cooked-rejoin-wrapped-lines' joins the logical
;; line and the gap closed on its own.  That one bit now rides the drain's row table
;; too, `cooked--mark-row-wrap' puts it on the newline, and the scan matches against
;; the rejoined *string* when there is one to build.  See "Soft wrap" below, which is
;; ghostel's arrangement taken whole.
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
;; This file is base tier, so cooked-util.el is the one place in the graph those
;; can be reached from.
(require 'cooked-util)

;; Whether a click or a RET on a link belongs to the child is an input-ownership
;; question: the answer depends on the mouse grab, on whether keys are being
;; forwarded and on whether the session is suspended, none of which a base-tier
;; file has any business knowing.  So `cooked-link-delegate-function' inverts it.
;; This file states the *occasion* -- an unshifted invocation, which is the one the
;; child could plausibly own -- and the layer that owns input decides and acts.  See
;; `cooked--link-delegate' in cooked-keymaps.el.

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
and stops `cooked--fontify-links' scanning at all; with no scan layer loaded
either, `cooked--sync-fontification' then drops the jit-lock registration, so
nothing about the guess is paid for."
  :type 'boolean
  :group 'cooked-link)

(defcustom cooked-detect-links-on-alt-screen nil
  "Whether to scan the alternate screen for URLs as well.

Off, and the reasoning is worth having.  The alternate screen is a full-screen
program repainting continuously — the one place where a regexp scan is paid
over and over for text that is about to be overwritten — and it is also
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
        ;; The detected URL as the scan recorded it, before goto-addr is asked to
        ;; read it out of the text again.  For an ordinary match the two agree; for
        ;; one the child wrapped across a row they cannot, because the text at
        ;; point is half of it and `goto-address-at-point' would open that half.
        (when-let* ((url (get-text-property (point) 'cooked-link-url)))
          (browse-url url)
          t)
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

Hung on the text as a `keymap' property by `cooked-link--propertize', which is
what marks an `OSC 8' span and a detected URL alike, so both kinds of link
answer the same keys.  It stands where `goto-address-highlight-keymap' would
have: the detected-URL pass sets its own properties rather than making
goto-addr's overlays, so that variable is never consulted.

`C-c RET' is deliberately absent even though goto-addr binds it and its
`help-echo' advertises it: `C-c' is forwarded to the child as the interrupt
character, and a `C-c' prefix in a property at point would make Emacs wait for
a second key before letting SIGINT through.
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

;;;; Soft wrap: putting a logical line back together to match against
;;
;; A screen row is one buffer line, so a URL the terminal ran out of columns for
;; is two buffer lines with a newline in the middle -- and a regexp that would
;; have matched it whole matches only as far as the break.  That was cooked's one
;; documented detection gap (REPORT.org §6's matrix), and the half of it that was
;; missing was never the matching: it was that the buffer had no way to tell a
;; line the child ended from a line the grid ran out of room for.  The emulator
;; has always known -- `Row::wrapped' -- and used it only on the way out to
;; scrollback, where `cooked-rejoin-wrapped-lines' rejoins the logical line and
;; the gap closes on its own.  It now rides the drain's row table as well, and
;; `cooked--mark-row-wrap' puts it on the newline as `cooked-wrap'.
;;
;; ghostel's approach, and cooked takes it whole because the alternative does not
;; exist here: cooked cannot hand the joined text to `goto-address-fontify-region'
;; and be done, since it stopped calling that function at all -- the scan is its
;; own (see `cooked--fontify-links'), and what it scans is a *string* with the
;; wrap newlines taken out, mapped back to buffer positions afterwards.
;;
;; Four pieces, all of them ghostel's shape: the joined region with its
;; offset-to-position chunk map (`ghostel--wrap-joined-region', links.el:334), the
;; binary search back (:369), the per-row fragments a match is marked in (:384),
;; and the shared id that makes those fragments one link (:417).  The fifth is the
;; row cap below.
;;
;; The whole of it is paid only when there is something to join.  A region with no
;; `cooked-wrap' in it -- every region on a screen of ordinary short lines -- costs
;; one `text-property-not-all' to find that out, and then takes the path it always
;; took.

(defconst cooked-link--join-rows 50
  "How many soft-wrapped rows are joined into one candidate for detection.

Output like a minified JSON blob is one logical line megabytes long, and joining
all of it would build a string of that size on every scan and then hand the
regexp engine a single token to chew through.  ghostel's number, for ghostel's
reason (`ghostel--soft-wrap-row-limit'): fifty rows is longer than any URL and
far shorter than a runaway line.

Counted per logical line rather than per region, so a screen of ordinary output
never approaches it.  Not a defcustom: the cap is a bound on the worst case
rather than a preference, and a URL long enough to need more than fifty rows of
a terminal is not a URL anyone typed.")

(defun cooked-link--wrap-at (pos end)
  "Position of the first soft-wrap newline in POS..END, or nil.

The `eq' test is not redundant with the property search.  `cooked-wrap' is put
on a newline and nothing else, but a yank carries text properties with the text,
so a region can hold a copy of one sitting on an ordinary character -- and
joining there would delete a character rather than a line break."
  (when-let* ((at (text-property-not-all pos end 'cooked-wrap nil))
              ((eq (char-after at) ?\n)))
    at))

(defun cooked-link--join-wrapped (beg end)
  "Return (STRING . CHUNKS) for BEG..END with its soft-wrap newlines removed.

STRING is the region as the child wrote it, so a value split across rows is one
token again.  CHUNKS maps it back: a vector of (OFFSET . POSITION) pairs, one
per piece, ascending -- see `cooked-link--wrap-position'.

Nil when nothing in the region is soft-wrapped, and that is the contract rather
than an optimisation.  The caller takes its old path on nil, so the ordinary
scan is unchanged and the only thing a screen of short lines pays for this
feature is the property search that answers nil.

`cooked-link--join-rows' bounds the run of rows joined into one line.  The count
is per logical line: a hard newline inside a piece ends the line it was counting
and the row after it starts a new one from zero."
  (let ((chunks nil)
        (parts nil)
        (joined nil)
        (offset 0)
        (rows 0)
        (pos beg))
    (while (< pos end)
      (let* ((wrap (cooked-link--wrap-at pos end))
             (join (and wrap (< rows cooked-link--join-rows)))
             ;; Three pieces: up to the wrap when joining, through it when the cap
             ;; says stop -- so the newline stays in the string and no match can
             ;; span it -- and the rest of the region when there is no wrap left.
             (piece (buffer-substring-no-properties
                     pos (cond (join wrap) (wrap (1+ wrap)) (t end)))))
        (when join (setq joined t))
        (push (cons offset pos) chunks)
        (push piece parts)
        (setq rows (cond ((not join) 0)
                         ((string-search "\n" piece) 1)
                         (t (1+ rows)))
              offset (+ offset (length piece))
              pos (if wrap (1+ wrap) end))))
    (when joined
      (cons (string-join (nreverse parts)) (vconcat (nreverse chunks))))))

(defun cooked-link--wrap-position (offset chunks)
  "The buffer position for string OFFSET, given CHUNKS.

Binary search rather than a walk, which is what keeps a region of many rows
cheap to map: the scan asks this twice per match, and a linear map would make a
screenful of matches quadratic in the rows joined.

An OFFSET landing exactly on a chunk boundary answers with the *later* chunk,
which is the right answer for a match beginning there and one character past the
newline for a match ending there.  Nothing downstream is hurt by the second
case: `cooked-link--wrap-fragments' stops at the wrap it has already passed, so
the fragment list is the same either way."
  (unless (zerop (length chunks))
    (let ((low 0)
          (high (1- (length chunks))))
      (while (< low high)
        (let ((mid (/ (+ low high 1) 2)))
          (if (<= (car (aref chunks mid)) offset)
              (setq low mid)
            (setq high (1- mid)))))
      (let ((chunk (aref chunks low)))
        (+ (cdr chunk) (- offset (car chunk)))))))

(defun cooked-link--wrap-fragments (beg end)
  "The buffer ranges covering BEG..END, split at the soft wraps inside it.

Each element is a (START . STOP) cons, and the wrap newlines are left out: a
link property covering a row break would put `mouse-face' on the gap between two
rows and hand the keymap a click on nothing."
  (let ((fragments nil)
        (pos beg))
    (while (< pos end)
      (let ((wrap (cooked-link--wrap-at pos end)))
        (if wrap
            (progn
              (when (< pos wrap) (push (cons pos wrap) fragments))
              (setq pos (1+ wrap)))
          (push (cons pos end) fragments)
          (setq pos end))))
    (nreverse fragments)))

(defun cooked-link-logical-line-bounds (beg end)
  "BEG..END widened to whole soft-wrapped logical lines, as (FROM . TO).

`cooked--fontify-region' rounds jit-lock's chunk out to whole *buffer* lines so
a candidate straddling a chunk boundary is matched by one half or the other.
That is not enough once a logical line can be several buffer lines: a boundary
between two soft-wrapped rows would split the very candidate this whole section
exists to put back together.

Bounded by `cooked-link--join-rows' in each direction, for the reason that
constant gives -- and because without a bound a screenful of one logical line
would make every chunk cover the screen, which is the cost jit-lock's chunking
is there to avoid."
  (let ((from beg)
        (to end))
    (save-excursion
      (let ((rows 0))
        (goto-char from)
        (while (and (< rows cooked-link--join-rows)
                    (> (point) (point-min))
                    (eq (char-before) ?\n)
                    (get-text-property (1- (point)) 'cooked-wrap))
          (forward-line -1)
          (setq from (point)
                rows (1+ rows))))
      (let ((rows 0))
        (goto-char to)
        (while (and (< rows cooked-link--join-rows)
                    (< (point) (point-max))
                    (eq (char-after) ?\n)
                    (get-text-property (point) 'cooked-wrap))
          (forward-line 1)
          (end-of-line)
          (setq to (point)
                rows (1+ rows)))))
    (cons from to)))

;;;; The goto-addr pass

(defvar cooked--url-scheme-regexp-memo nil
  "Cached (SCHEMES . REGEXP) for `thing-at-point-uri-schemes\='.")

(defun cooked--url-scheme-regexp ()
  "The scheme alternation `thing-at-point\=' would have built, built once."
  (let ((schemes thing-at-point-uri-schemes))
    (if (eq (car cooked--url-scheme-regexp-memo) schemes)
        (cdr cooked--url-scheme-regexp-memo)
      (cdr (setq cooked--url-scheme-regexp-memo
                 (cons schemes (regexp-opt schemes)))))))

(defconst cooked-link--url-properties
  '(cooked-link-url cooked-link-fragment face mouse-face follow-link help-echo keymap)
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

(defun cooked-link--fontify-wrapped-match (beg end url face mouse-face help-echo)
  "Make BEG..END a detected link to URL, one fragment per row it spans.

The soft-wrap counterpart of `cooked-link--fontify-url-match\=', and the two
differ in exactly two things: the newlines between the rows are left unmarked,
and every fragment carries the same `cooked-link-fragment\=' id so that what is
drawn as three highlighted pieces is still one link to everything that asks.
`cooked-link--detected-bounds\=' is what asks.

A fresh cons per match, compared with `eq\=': two occurrences of the same URL on
the same row are two links, and comparing the URL string instead would have said
they were one."
  (unless (cooked-link--claimed-p beg 'goto-addr)
    (let ((id (cons 'cooked-link-detected url)))
      (pcase-dolist (`(,from . ,to) (cooked-link--wrap-fragments beg end))
        (cooked-link--propertize from to
                                 'cooked-link-url url
                                 'cooked-link-fragment id
                                 'help-echo help-echo
                                 'mouse-face mouse-face
                                 'face (and goto-address-fontify-p face))))))

(defun cooked-link--scan (beg end match)
  "Run goto-addr's two patterns over BEG..END, calling MATCH for each hit.

MATCH is called as (BEG END URL FACE MOUSE-FACE HELP-ECHO), which is
`cooked-link--fontify-url-match\='s own signature -- so the ordinary scan passes
that function straight in and the soft-wrap scan passes a closure that maps the
positions back into the buffer the text came from first.

Split out for that second caller and for nothing else.  What the two share is
everything that makes the scan a faithful reproduction of
`goto-address-fontify-region\=' -- both regexps, `bounds-of-thing-at-point\=' for
the URL bounds and the raw match for mail, the two faces and the two help
strings -- and it is a reproduction precisely because goto-addr offers no hook
to filter its matches with.  Having a second copy of it for the wrapped case
would be a second thing to keep faithful."
  (save-excursion
    (goto-char beg)
    (while (re-search-forward goto-address-url-regexp end t)
      ;; goto-addr takes the bounds from thingatpt rather than from its own
      ;; match, and the difference is real: the regexp swallows trailing
      ;; punctuation that `bounds-of-thing-at-point' trims.
      (when-let* ((bounds (save-excursion
                            (goto-char (match-beginning 0))
                            (bounds-of-thing-at-point 'url))))
        (funcall match (car bounds) (cdr bounds)
                 (buffer-substring-no-properties (car bounds) (cdr bounds))
                 goto-address-url-face goto-address-url-mouse-face
                 "mouse-2, C-c RET: follow URL"))))
  (save-excursion
    (goto-char beg)
    (while (re-search-forward goto-address-mail-regexp end t)
      (funcall match (match-beginning 0) (match-end 0)
               (concat "mailto:" (match-string-no-properties 0))
               goto-address-mail-face goto-address-mail-mouse-face
               "mouse-2, C-c RET: mail this address"))))

(defun cooked-link--scan-joined (joined)
  "Scan JOINED, a rejoined region's text, and mark what it finds in the buffer.

JOINED is `cooked-link--join-wrapped\='s (STRING . CHUNKS).  The string is put in
a temporary buffer rather than matched with `string-match\=', because the scan
asks `bounds-of-thing-at-point\=' where each URL really ends and thingatpt reads
a buffer.  Matching the string directly would mean either giving that up or
reimplementing it, and giving it up is what puts the trailing bracket of
\"(https://example.com/x)\" inside the link.

The source buffer's syntax table goes with the text.  thingatpt's idea of a word
constituent is the current table's, so a scratch buffer left in
`fundamental-mode\=' could disagree with the real one about where a URL ends --
about which the honest thing to say is that it does not today, and that a
one-line guarantee is cheaper than knowing whether it ever will."
  (let ((chunks (cdr joined))
        (source (current-buffer))
        (table (syntax-table)))
    (with-temp-buffer
      (set-syntax-table table)
      (insert (car joined))
      (cooked-link--scan
       (point-min) (point-max)
       (lambda (mbeg mend url face mouse-face help-echo)
         ;; Buffer positions are one-based and the chunk map is in string
         ;; offsets, which is the whole of the conversion.
         (let ((from (cooked-link--wrap-position (1- mbeg) chunks))
               (to (cooked-link--wrap-position (1- mend) chunks)))
           (with-current-buffer source
             (cooked-link--fontify-wrapped-match
              from to url face mouse-face help-echo))))))))

(defun cooked-link--detected-bounds (&optional pos)
  "Bounds of the detected-URL span covering POS, or nil.

The run of `cooked-link-url\=', extended across any soft wrap the match was
broken over: the fragments of one match share a `cooked-link-fragment\=' id, so
the extension is exact rather than a guess from the text being adjacent.  An
unwrapped match carries no id and the run is the whole answer, which is why the
common case walks nothing.

Returns the outer bounds, newlines included.  What the *properties* deliberately
skip is a different question from what the link *is*: `thing-at-point\=' and
embark want the extent of the thing, and the thing spans the break."
  (let ((pos (or pos (point))))
    (when (get-text-property pos 'cooked-link-url)
      (let ((from (or (previous-single-property-change
                       (1+ pos) 'cooked-link-url)
                      (point-min)))
            (to (or (next-single-property-change pos 'cooked-link-url)
                    (point-max)))
            (id (get-text-property pos 'cooked-link-fragment)))
        (when id
          (while (and (> from (point-min))
                      (eq (char-before from) ?\n)
                      (eq (get-text-property (- from 2) 'cooked-link-fragment) id))
            (setq from (or (previous-single-property-change
                            (1- from) 'cooked-link-url)
                           (point-min))))
          (while (and (< to (point-max))
                      (eq (char-after to) ?\n)
                      (eq (get-text-property (1+ to) 'cooked-link-fragment) id))
            (setq to (or (next-single-property-change
                          (1+ to) 'cooked-link-url)
                         (point-max)))))
        (cons from to)))))

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
`cooked-link-claim-functions' states and nothing is created only to be undone.

A soft-wrapped region takes a second path, and only then.  When something in
BEG..END carries `cooked-wrap' the scan runs over the rejoined *string* instead
of over the buffer -- see `cooked-link--scan-joined', and the commentary above
`cooked-link--join-rows' for why -- and every match is marked one row at a time.
When nothing does, which is every region of ordinary short lines, the cost of
having asked is one `text-property-not-all' and the path is the one it always
was."
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
          (if-let* ((joined (cooked-link--join-wrapped beg end)))
              (cooked-link--scan-joined joined)
            (cooked-link--scan beg end #'cooked-link--fontify-url-match))))))))

;;;; thing-at-point, which is how everything else finds a link

;; ROADMAP §3 asked for `embark-target-finders' entries.  This is the same feature
;; one layer down and without the dependency: embark's file and URL finders go
;; through `thing-at-point', so a provider installed here answers `embark-act',
;; `browse-url-at-point', ffap and `find-file's `M-n' at once, and answers them in
;; a plain Emacs with no embark installed.
;;
;; The providers are *collected* rather than installed here.  `url' is this file's
;; to contribute and `filename'/`existing-filename' are cooked-file-link.el's, which
;; is an optional layer on top of `cooked-mode' -- so the installation point straddles the
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
anything.

One other case has the same shape and so is answered here too: a detected URL
the child wrapped across a row.  thingatpt would read it out of the text like
any other, and the text has a row break in the middle of it -- so what it would
answer is the first fragment.  The scan knows the whole URL and has already
written it down; see `cooked-link--fontify-wrapped-match'.  An *unwrapped*
detected URL is still left to thingatpt, which reads it correctly and reads more
schemes than goto-addr does."
  (or (cooked-link-uri)
      (and (get-text-property (point) 'cooked-link-fragment)
           (get-text-property (point) 'cooked-link-url))))

(defun cooked-link--url-bounds-at-point ()
  "Bounds of the link at point, for the bounds provider alist.

The two cases `cooked-link--url-at-point' answers, in the same order and for the
same reasons."
  (cond ((cooked-link-uri) (cooked-link--osc-8-bounds))
        ((get-text-property (point) 'cooked-link-fragment)
         (cooked-link--detected-bounds))))

(add-to-list 'cooked-thing-at-point-providers
             (cons 'url #'cooked-link--url-at-point))
(add-to-list 'cooked-bounds-of-thing-at-point-providers
             (cons 'url #'cooked-link--url-bounds-at-point))

(provide 'cooked-link)

;;; cooked-link.el ends here
