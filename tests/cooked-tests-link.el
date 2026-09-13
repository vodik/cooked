;;; cooked-tests-link.el --- Links in terminal output -*- lexical-binding: t; -*-

;;; Commentary:

;; Both halves of link detection, end to end: the `OSC 8' sequences a program
;; actually emits, and the guess `cooked--fontify-links' makes about text that merely
;; looks like a URL, using goto-addr's regexps and faces over a scan of its own.  The
;; pure-Rust half -- interning, eviction, what closes a link and what must not -- is
;; tested in src/emu/link.rs and src/emu/term/tests/osc.rs; what is here is what only a
;; real buffer can show: that the id reaches the text, that the two passes agree about
;; who wins, and that a link cannot steal a click from a child holding the mouse.

;;; Code:

(require 'cooked-tests-helpers)
(require 'cooked-link)

(defun cooked-tests--link-at (string)
  "Position of STRING in the buffer, or nil."
  (save-excursion
    (goto-char (point-min))
    (when (search-forward string nil t)
      (match-beginning 0))))

(ert-deftest cooked-osc-8-makes-the-text-a-link ()
  (cooked-tests--with-session
      '("/bin/sh" "-c"
        "printf 'see \\033]8;;https://example.com/\\033\\\\here\\033]8;;\\033\\\\ ok\\n'; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "see here ok" (cooked-tests--text)))))
    (let ((in (cooked-tests--link-at "here"))
          (out (cooked-tests--link-at "see")))
      (should (equal (cooked-link-uri in) "https://example.com/"))
      (should (get-text-property in 'mouse-face))
      (should (eq (get-text-property in 'keymap) cooked-link-map))
      ;; And only the text the sequence covered: the run boundary is the link's,
      ;; not the style's, which is what `Run::link' exists to carry.
      (should-not (cooked-link-uri out))
      (should-not (get-text-property out 'cooked-link-id)))))

(ert-deftest cooked-osc-8-survives-being-coloured-mid-link ()
  ;; The regression this whole feature is one line away from: OSC 8 is not an SGR
  ;; attribute, so `ESC[0m' must not close it.  Guarded in Rust as well
  ;; (`an_sgr_reset_does_not_close_a_hyperlink'); asserted here because this is the
  ;; shape a real program emits -- a link it colours as it prints it.
  (cooked-tests--with-session
      '("/bin/sh" "-c"
        "printf '\\033]8;;https://example.com/\\033\\\\\\033[31mred\\033[0mplain\\033]8;;\\033\\\\\\n'; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "redplain" (cooked-tests--text)))))
    (should (equal (cooked-link-uri (cooked-tests--link-at "red"))
                   "https://example.com/"))
    (should (equal (cooked-link-uri (cooked-tests--link-at "plain"))
                   "https://example.com/"))))

(ert-deftest cooked-osc-8-keeps-the-childs-own-colour ()
  (cooked-tests--with-session
      '("/bin/sh" "-c"
        "printf '\\033[31m\\033]8;;https://example.com/\\033\\\\red\\033]8;;\\033\\\\\\033[0m\\n'; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "red" (cooked-tests--text)))))
    (let ((face (get-text-property (cooked-tests--link-at "red") 'face)))
      (should (equal (plist-get face :foreground) (aref cooked-color-names 1)))
      (should-not (eq face 'cooked-link)))))

(ert-deftest cooked-a-bare-url-is-fontified-by-goto-addr ()
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf 'go to https://example.com/ now\\n'; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "example.com" (cooked-tests--text)))))
    ;; The scan is redisplay's now, and batch mode does not redisplay.
    (cooked-tests--fontify)
    (let ((at (cooked-tests--link-at "https://example.com/")))
      ;; Text properties, not overlays.  An overlay per match on a live row is
      ;; the expensive form twice over -- redisplay assembles the overlay list
      ;; per window per redisplay, and `note_mouse_highlight' walks
      ;; `overlays_at' on every motion.  See `cooked--fontify-links'.
      (should-not (overlays-at at))
      (should (equal (get-text-property at 'cooked-link-url)
                     "https://example.com/"))
      (should (get-text-property at 'follow-link))
      (should (get-text-property at 'mouse-face))
      ;; The keymap is ours, not goto-addr's: a `keymap' property outranks
      ;; `emulation-mode-map-alists', so the gate has to be in the command that
      ;; property names.  See `cooked-follow-link'.
      (should (eq (get-text-property at 'keymap) cooked-link-map)))))

(ert-deftest cooked-the-url-guess-creates-no-overlays-at-all ()
  "The whole point of the conversion, asserted as an absence.

An overlay per detected URL is paid twice on a live row: redisplay assembles
the overlay list per window per redisplay, and `note_mouse_highlight\=' walks
`overlays_at\=' on every motion event.  A build log is mostly URLs, so this is
not a rounding error -- REPORT.org §7 ranks it fourth of the borrowables."
  (cooked-tests--with-session
      '("/bin/sh" "-c"
        "printf 'a https://one.example/ b https://two.example/ c d@e.example\\n'; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "two.example" (cooked-tests--text)))))
    (cooked-tests--fontify)
    ;; All three found ...
    (should (equal (get-text-property (cooked-tests--link-at "https://one.example/")
                                      'cooked-link-url)
                   "https://one.example/"))
    (should (equal (get-text-property (cooked-tests--link-at "d@e.example")
                                      'cooked-link-url)
                   "mailto:d@e.example"))
    ;; ... and not one overlay anywhere.
    (should-not (overlays-in (point-min) (point-max)))))

(ert-deftest cooked-unfontifying-the-guess-cannot-strip-an-explicit-link ()
  "Rescanning must clear only what the guess itself put down.

`goto-address-fontify\=' opens with `goto-address-unfontify\=', and an overlay
could simply be deleted.  Properties cannot: the guess sets `mouse-face\=',
`keymap\=' and `help-echo\=' under the same names an `OSC 8\=' span sets them,
so a blanket `remove-text-properties\=' over the region would silently
de-link every real hyperlink on it.  Only runs carrying `cooked-link-url\='
may be cleared."
  (cooked-tests--with-session
      '("/bin/sh" "-c"
        "printf '\\033]8;;https://real.example/\\033\\\\LABEL\\033]8;;\\033\\\\ and https://guess.example/\\n'; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "guess.example" (cooked-tests--text)))))
    (cooked-tests--fontify)
    (let ((osc (cooked-tests--link-at "LABEL")))
      (should (equal (cooked-link-uri osc) "https://real.example/"))
      (should (eq (get-text-property osc 'keymap) cooked-link-map))
      ;; Scan the whole buffer again, as a redisplay over rewritten text would.
      (cooked--fontify-links (point-min) (point-max))
      (should (equal (cooked-link-uri osc) "https://real.example/"))
      (should (eq (get-text-property osc 'keymap) cooked-link-map))
      (should (get-text-property osc 'mouse-face))
      ;; And the guess is still there too, exactly once.
      (should (equal (get-text-property (cooked-tests--link-at "https://guess.example/")
                                        'cooked-link-url)
                     "https://guess.example/")))))

(ert-deftest cooked-the-url-guess-declines-the-cursors-own-row ()
  "A spinner rewrites its row a hundred times a second; do not guess at it.

Each rewrite marks the row unfontified, so without this the scan is made again
on every frame, over text nobody has finished writing.  What must still hold is
that declining is a *deferral*: the text on the rows above is scanned as
normal."
  (cooked-tests--with-session
      '("/bin/sh" "-c"
        "printf 'settled https://above.example/\\n'; printf 'live https://cursor.example/'; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "cursor.example" (cooked-tests--text)))))
    (cooked-tests--fontify)
    ;; The finished row above was scanned.
    (should (equal (get-text-property (cooked-tests--link-at "https://above.example/")
                                      'cooked-link-url)
                   "https://above.example/"))
    ;; The cursor is sitting on the second row, so it was declined -- and
    ;; remembered, which is what makes the deferral safe.
    (should-not (get-text-property (cooked-tests--link-at "https://cursor.example/")
                                   'cooked-link-url))
    (should cooked--held-link-row)))

(ert-deftest cooked-a-held-row-is-scanned-once-the-cursor-leaves-it ()
  "The deferral must not become a loss.

A URL printed with no newline after it sits on the cursor\='s own row, so it is
declined -- and if nothing ever asked again it would never be a link at all.
`cooked--release-held-link-row\=' runs from `cooked--apply\=', the moment the
cursor can have moved, and puts the row back on jit-lock\='s unfontified list."
  (cooked-tests--with-session
      '("/bin/sh" "-c"
        "printf 'here https://later.example/'; sleep 0.3; printf '\\nand on\\n'; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "later.example" (cooked-tests--text)))))
    (cooked-tests--fontify)
    (let ((at (cooked-tests--link-at "https://later.example/")))
      (should-not (get-text-property at 'cooked-link-url))
      ;; The newline arrives, the cursor moves to the next row, and the drain
      ;; releases the hold.
      (should (cooked-tests--settle
               (lambda () (string-match-p "and on" (cooked-tests--text)))))
      (should-not cooked--held-link-row)
      (cooked-tests--fontify)
      (should (equal (get-text-property at 'cooked-link-url)
                     "https://later.example/")))))

(ert-deftest cooked-a-url-scrolled-far-back-is-linked-when-its-chunk-is-shown ()
  "Scrolling back must not lose links to the cursor\='s hold.

The row the cursor sits on is declined by splitting the chunk around it, and
that split used to be made whether or not the row was in the chunk at all.  A
chunk far above the cursor was then scanned from its start all the way down to
the cursor, and once that span passed `goto-address-fontify-maximum-size\=' it
was not scanned at all -- while jit-lock marked it done.  So a URL 180 KB back
never became a link.  `cooked-tests--fontify\=' fontifies the whole buffer,
which holds the cursor\='s row inside the one chunk, so this has to ask for a
chunk of its own the way scrolling there does."
  (cooked-tests--with-session
      '("/bin/sh" "-c"
        "printf 'old https://scrolled.example/\\n'; awk 'BEGIN { for (i = 0; i < 2400; i++) printf \"%079d\\n\", i }'; printf 'done'; sleep 5")
    (should (cooked-tests--settle
             (lambda () (save-excursion
                          (goto-char (point-max))
                          (search-backward "done" nil t)))
             10))
    (let ((at (cooked-tests--link-at "https://scrolled.example/")))
      (should at)
      (should (> (- (point-max) at) goto-address-fontify-maximum-size))
      (jit-lock-fontify-now at (+ at 500))
      (should (equal (get-text-property at 'cooked-link-url)
                     "https://scrolled.example/")))))

(ert-deftest cooked-an-explicit-link-wins-over-the-guess ()
  ;; The text is a URL *and* an OSC 8 span pointing somewhere else.  What the child
  ;; said wins, and the guess is dropped rather than layered underneath it.
  (cooked-tests--with-session
      '("/bin/sh" "-c"
        "printf '\\033]8;;https://elsewhere.example/\\033\\\\https://example.com/\\033]8;;\\033\\\\\\n'; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "example.com" (cooked-tests--text)))))
    (let ((at (cooked-tests--link-at "https://example.com/")))
      (should (equal (cooked-link-uri at) "https://elsewhere.example/"))
      ;; And dropped by never being created: the guess asks
      ;; `cooked-link--claimed-p' as `goto-addr' before propertizing, where it
      ;; used to make overlays and delete them again afterwards.
      (should-not (get-text-property at 'cooked-link-url)))))

(ert-deftest cooked-a-link-does-not-steal-a-click-from-the-child ()
  ;; A `keymap' text property is consulted before `emulation-mode-map-alists', so
  ;; without the gate in `cooked-follow-link' a click on a link would beat an active
  ;; `cooked--mouse-grab' -- contradicting the guarantee that a plain click belongs to
  ;; the child while it holds the mouse, with Shift as the escape.
  (cooked-tests--with-session
      '("/bin/sh" "-c"
        "printf '\\033]8;;https://example.com/\\033\\\\here\\033]8;;\\033\\\\\\n'; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "here" (cooked-tests--text)))))
    (goto-char (cooked-tests--link-at "here"))
    ;; No posn on either event, and none is passed to the command: batch has no
    ;; window over the buffer to take one from, and what the gate reads is
    ;; `last-input-event'.  Point is already on the link, which is what a real click
    ;; would have set it to.
    (let ((forwarded nil)
          (browsed nil)
          (cooked--mouse-grab t))
      (cl-letf (((symbol-function 'cooked-mouse-event)
                 (lambda () (setq forwarded t)))
                ((symbol-function 'browse-url)
                 (lambda (&rest _) (setq browsed t))))
        (let ((last-input-event (list 'mouse-2 nil)))
          (cooked-follow-link))
        (should forwarded)
        (should-not browsed)
        ;; Shift is the sanctioned way through, so the link stays reachable.
        (setq forwarded nil)
        (let ((last-input-event (list 'S-mouse-2 nil)))
          (cooked-follow-link))
        (should browsed)
        (should-not forwarded)))))

(ert-deftest cooked-a-link-does-not-steal-return-from-the-child ()
  (cooked-tests--with-session
      '("/bin/sh" "-c"
        "printf '\\033]8;;https://example.com/\\033\\\\here\\033]8;;\\033\\\\\\n'; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "here" (cooked-tests--text)))))
    (goto-char (cooked-tests--link-at "here"))
    (let ((sent nil) (browsed nil))
      (cl-letf (((symbol-function 'cooked-send-key) (lambda () (setq sent t)))
                ((symbol-function 'browse-url) (lambda (&rest _) (setq browsed t)))
                ((symbol-function 'cooked--child-owns-keyboard-p) (lambda () t))
                ((symbol-function 'cooked--suspended-p) (lambda () nil)))
        (let ((last-input-event ?\r))
          (cooked-follow-link nil))
        (should sent)
        (should-not browsed)
        (let ((last-input-event 'S-return))
          (cooked-follow-link nil))
        (should browsed)))))

;;;; file: URLs

(defmacro cooked-tests--with-file-url-display (var &rest body)
  "Run BODY with `cooked-file-url-display' recording what it opens in VAR.
The file is visited without a window, and its buffer made current, so BODY can
ask where point landed."
  (declare (indent 1))
  `(let ((,var nil))
     (cl-letf (((symbol-value 'cooked-file-url-display)
                (lambda (file)
                  (setq ,var file)
                  (set-buffer (if (file-remote-p file)
                                  (get-buffer-create " *remote visit*")
                                (find-file-noselect file))))))
       ,@body)))

(ert-deftest cooked-osc-8-file-link-opens-at-the-line-it-names ()
  "What the change was for: a file hyperlink with a line in it lands on the line.

`browse-url-emacs\=' opens the file and drops the fragment, so `#L3\=' used to
arrive at the top of the file.  End to end, from the escape sequence, so the
OSC 8 branch of `cooked--open-link-at-point\=' is what is exercised."
  (let ((file (make-temp-file "cooked-link" nil ".txt" "one\ntwo\nthree\nfour\n")))
    (unwind-protect
        (cooked-tests--with-session
            `("/bin/sh" "-c"
              ,(format "printf '\\033]8;;file://%s#L3\\033\\\\here\\033]8;;\\033\\\\\\n'; sleep 5"
                       file))
          (should (cooked-tests--settle
                   (lambda () (string-match-p "here" (cooked-tests--text)))))
          (goto-char (cooked-tests--link-at "here"))
          (cooked-tests--with-file-url-display opened
            (save-current-buffer
              (cooked--open-link-at-point)
              (should (equal opened file))
              (should (= (line-number-at-pos) 3))
              (kill-buffer))))
      (delete-file file))))

(ert-deftest cooked-file-url-reads-a-line-wherever-the-tools-put-it ()
  "GitHub's `#L12\=', kitty's `#12\=', a column after `C\=' or `:\=', a range, the
short `file:/x\=' spelling, and delta's `:LINE:COL\=' on the end of the path."
  (let ((dir (make-temp-file "cooked-link" t)))
    (unwind-protect
        (with-temp-buffer
          (let ((plain (expand-file-name "plain.rs" dir))
                (colon (expand-file-name "odd:12" dir)))
            (should (equal (cooked--file-url-target (concat "file://" plain "#L12"))
                           (list plain 12 nil)))
            (should (equal (cooked--file-url-target (concat "file://" plain "#12"))
                           (list plain 12 nil)))
            (should (equal (cooked--file-url-target (concat "file://" plain "#L4C9"))
                           (list plain 4 9)))
            (should (equal (cooked--file-url-target (concat "file://" plain "#7:2"))
                           (list plain 7 2)))
            (should (equal (cooked--file-url-target (concat "file://" plain "#L5-L9"))
                           (list plain 5 nil)))
            (should (equal (cooked--file-url-target (concat "file:" plain))
                           (list plain nil nil)))
            (should (equal (cooked--file-url-target
                            (concat "file://localhost" plain ":30:4"))
                           (list plain 30 4)))
            ;; A fragment that is not a line is somebody else's, not a line.
            (should (equal (cooked--file-url-target (concat "file://" plain "#intro"))
                           (list plain nil nil)))
            ;; A `#' in the name arrives encoded and must stay in the name.
            (should (equal (cooked--file-url-target
                            (concat "file://" dir "/a%23b.txt#L2"))
                           (list (concat dir "/a#b.txt") 2 nil)))
            ;; A file that really ends in `:12' is kept whole on this machine,
            ;; where asking is free.
            (write-region "" nil colon)
            (should (equal (cooked--file-url-target (concat "file://" colon))
                           (list colon nil nil)))))
      (delete-directory dir t))))

(ert-deftest cooked-file-url-refuses-a-tramp-name-in-the-path ()
  "The hole `browse-url-emacs\=' leaves: it hands the path to `find-file\=' as it
stands, so a link to `file:///ssh:evil.example:/etc\=' -- which `cat\=' of a
hostile file can print -- would dial out when clicked.  Refused before anything
looks at it, and refused *by the handler*, so it cannot fall through to Emacs'
own and be opened there instead."
  (with-temp-buffer
    (cooked-tests--with-file-url-display opened
      (cl-letf (((symbol-function 'browse-url-emacs)
                 (lambda (url &rest _) (setq opened (list 'emacs url)))))
        (cooked-link-browse "file:///ssh:evil.example:/etc/motd")
        (should-not opened)
        (cooked-link-browse "file:///sudo::/etc/shadow#L1")
        (should-not opened)))))

(ert-deftest cooked-file-url-on-another-host-opens-over-tramp-or-not-at-all ()
  "`ls --hyperlink\=' over ssh names the far machine, and Emacs' handler opens the
same path here, which is a real file and the wrong one.  The host the child
announced over OSC 7 maps to TRAMP exactly as a `cd\=' does; a host the child
never announced is refused, since following it would let the byte stream choose
where Emacs connects; and `cooked-remote-directory\=' nil turns the lot off."
  (with-temp-buffer
    (setq-local cooked--host "other.example")
    (let ((default-directory "/tmp/")
          (cooked-tramp-default-method "ssh")
          (cooked-remote-directory 'tramp))
      (should (equal (cooked--file-url-target "file://other.example/srv/app/main.rs#L8")
                     (list "/ssh:other.example:/srv/app/main.rs" 8 nil)))
      ;; The far `HOST' is often the short name, and it is the same machine.
      (should (equal (cooked--file-url-target "file://other/srv/app/main.rs:8")
                     (list "/ssh:other.example:/srv/app/main.rs" 8 nil)))
      ;; A machine nobody announced.
      (should-not (cooked--file-url-target "file://evil.example/etc/motd"))
      ;; TRAMP punctuation in the authority, the same refusal OSC 7 makes.
      (should-not (cooked--file-url-target "file://a%7Csudo%3A/etc/shadow"))
      (let ((cooked-remote-directory nil))
        (should-not (cooked--file-url-target "file://other.example/srv/app/main.rs"))))
    ;; The connection already in use is reused, hops and user included, even
    ;; with no OSC 7 to have announced anything.
    (setq-local cooked--host nil)
    (let ((default-directory "/ssh:jump.example|ssh:me@other.example:/tmp/"))
      (should (equal (cooked--file-url-target "file://other.example/srv/x.rs#3")
                     (list "/ssh:jump.example|ssh:me@other.example:/srv/x.rs"
                           3 nil))))))

(ert-deftest cooked-link-browse-leaves-other-schemes-and-your-handlers-alone ()
  "`cooked-link-url-handlers\=' is spliced *after* the user's own list, so a
`file:\=' handler you configured still wins; and nothing but `file:\=' is
touched, so `mailto:\=' reaches `browse-url-mailto-function\=' as it always did."
  (with-temp-buffer
    (let ((mailed nil) (mine nil))
      (let ((browse-url-mailto-function (lambda (url &rest _) (setq mailed url))))
        (cooked-link-browse "mailto:someone@example.com")
        (should (equal mailed "mailto:someone@example.com")))
      (let ((browse-url-handlers
             (list (cons "\\`file:" (lambda (url &rest _) (setq mine url))))))
        (cooked-tests--with-file-url-display opened
          (cooked-link-browse "file:///tmp/x#L2")
          (should (equal mine "file:///tmp/x#L2"))
          (should-not opened))))))

(ert-deftest cooked-a-link-follows-when-no-layer-claims-the-input ()
  "The base layer alone must not decide who owns a click.

The point of `cooked-link-delegate-function\=' is that cooked-link.el is base
tier and, by `docs/DESIGN.md\='s rule, carries notifications upward and never
questions.  It used to ask `cooked--child-owns-keyboard-p\=' and
`cooked--suspended-p\=' through `declare-function\=', which is that rule broken.
With no delegate installed there is nothing above to answer, and the only
correct behaviour is to follow the link -- not to guess, and not to signal
`void-function\=' reaching for a layer that was never loaded."
  (cooked-tests--with-session
      '("/bin/sh" "-c"
        "printf '\\033]8;;https://example.com/\\033\\\\here\\033]8;;\\033\\\\\\n'; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "here" (cooked-tests--text)))))
    (goto-char (cooked-tests--link-at "here"))
    (let ((browsed nil)
          (cooked-link-delegate-function nil)
          ;; Set as a real grab would set it.  Nothing may consult it from down
          ;; here, and that is exactly what this asserts.
          (cooked--mouse-grab t))
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (&rest _) (setq browsed t))))
        (let ((last-input-event (list 'mouse-2 nil)))
          (cooked-follow-link))
        (should browsed)))))

(ert-deftest cooked-link-claims-are-ordered-by-what-the-layers-registered ()
  "Precedence is data the layers contribute, not a constant in the base layer.

The ranking used to be written into `cooked-link--claimed-p\=' as `OSC 8\=' >
goto-addr > \"guessed shape\" -- but guessed shape is cooked-file-link.el\='s
output, so the bottom of the stack was naming a category that does not exist
unless an optional layer above it is loaded.  Three things have to hold now:
each source answers for itself, a source asking is not told it claimed the
position itself, and a source is not blocked by one it outranks."
  (with-temp-buffer
    (insert "abcdefghij")
    (let* ((claimed nil)
           (cooked-link-claim-functions
            (list (cons 'osc-8 (lambda (pos _end) (memq pos claimed)))
                  (cons 'goto-addr (lambda (pos _end) (memq (1+ pos) claimed)))
                  (cons 'guessed (lambda (pos _end) (memq (+ 2 pos) claimed))))))
      ;; Nothing registered a claim yet.
      (should-not (cooked-link--claimed-p 1 2))
      ;; The top source claims, and is named -- the return value is the symbol,
      ;; so a caller can say *which* source outranked it rather than only that
      ;; one did.
      (setq claimed '(1))
      (should (eq (cooked-link--claimed-p 1 2) 'osc-8))
      ;; The guessing layer asks as itself and is still blocked, because OSC 8
      ;; outranks it.
      (should (eq (cooked-link--claimed-p 1 2 'guessed) 'osc-8))
      ;; ... and OSC 8 asking as itself is *not* told it claimed its own span.
      (should-not (cooked-link--claimed-p 1 2 'osc-8))
      ;; A claim held only by the lowest source does not block the ones above
      ;; it: the walk stops at the asking source's own entry.
      (setq claimed '(3))
      (should (eq (cooked-link--claimed-p 1 2) 'guessed))
      (should-not (cooked-link--claimed-p 1 2 'goto-addr))
      (should-not (cooked-link--claimed-p 1 2 'osc-8)))))

(ert-deftest cooked-the-file-link-layer-registers-itself-below-the-others ()
  "cooked-file-link.el appends its own rank rather than the base layer naming it."
  ;; Required here, not assumed: the suite loads the layer only from the tests
  ;; that use it, so a selector that runs none of those left it unloaded.
  (require 'cooked-file-link)
  (should (eq (car (car (last cooked-link-claim-functions))) 'guessed))
  (should (memq 'osc-8 (mapcar #'car cooked-link-claim-functions)))
  ;; Loading the layer twice must not stack a second entry.
  (let ((before (length cooked-link-claim-functions)))
    (load "cooked-file-link" nil t)
    (should (= (length cooked-link-claim-functions) before))))

(ert-deftest cooked-thing-at-point-answers-an-osc-8-destination ()
  "`thing-at-point\=' `url\=' returns what the child named, not what is on screen.

The case no generic provider can get right: an `OSC 8\=' span\='s *text* is
usually a label, so the destination appears nowhere in the buffer.  This is
also what makes ROADMAP §3 fall out with no embark dependency -- embark\='s URL
finder goes through `thing-at-point\=', so answering here answers there."
  (cooked-tests--with-session
      '("/bin/sh" "-c"
        "printf '\\033]8;;https://example.com/deep\\033\\\\LABEL\\033]8;;\\033\\\\\\n'; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "LABEL" (cooked-tests--text)))))
    (goto-char (cooked-tests--link-at "LABEL"))
    ;; The destination is not in the buffer text at all, which is the point.
    (should-not (string-match-p "example.com" (cooked-tests--text)))
    (should (equal (thing-at-point 'url) "https://example.com/deep"))
    ;; And the bounds are the whole span, so a caller highlighting the target
    ;; gets all of LABEL rather than a word of it.
    (pcase-let ((`(,beg . ,end) (bounds-of-thing-at-point 'url)))
      (should (equal (buffer-substring-no-properties beg end) "LABEL")))))

(ert-deftest cooked-thing-at-point-providers-are-buffer-local ()
  "The alists are global, so a cooked provider must not answer elsewhere.

`cooked-link--url-at-point\=' reads `cooked--link-uris\=', a table that exists
only in a cooked buffer; left installed globally it would be consulted for
every `thing-at-point\=' call in the session."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (should (assq 'url thing-at-point-provider-alist))
    (should (local-variable-p 'thing-at-point-provider-alist)))
  (with-temp-buffer
    (should-not (local-variable-p 'thing-at-point-provider-alist))
    (should-not (assq 'url (default-value 'thing-at-point-provider-alist)))))

(ert-deftest cooked-thing-at-point-providers-straddle-the-tier-boundary ()
  "`url\=' is the base layer\='s to give and the file things are the optional layer\='s.

The straddle is the finding REPORT.org §11 turned up, not an accident: the base
layer must not name a provider only an upper layer can supply, so both merely
contribute and cooked-mode.el installs what is present."
  ;; The base layer's, present whether or not anything is loaded above it.
  (should (assq 'url cooked-thing-at-point-providers))
  (cooked-tests--with-file-links
    (should (assq 'filename cooked-thing-at-point-providers))
    (should (assq 'existing-filename cooked-thing-at-point-providers))
    (should (memq #'cooked-file-link--file-name-at-point
                  cooked-file-name-at-point-functions))
    ;; Contributed once however many times the layer is loaded.
    (let ((before (length cooked-thing-at-point-providers)))
      (load "cooked-file-link" nil t)
      (should (= (length cooked-thing-at-point-providers) before)))))

(ert-deftest cooked-existing-filename-at-point-resolves-against-the-child ()
  "`existing-filename\=' answers with an absolute path, which is what openers need.

A bare `src/lib.rs\=' handed to `find-file\=' from another buffer finds nothing;
`cooked-file-link--exists\=' has already tried `default-directory\=' -- which
OSC 7 keeps on the child\='s own working directory -- and then the project root."
  (let* ((dir (make-temp-file "cooked-tap" t))
         (file (expand-file-name "here.txt" dir)))
    (unwind-protect
        (progn
          (with-temp-file file (insert "x"))
          (cooked-tests--with-file-links
           (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
            (setq default-directory dir)
            (erase-buffer)
            (insert "see here.txt for details")
            (goto-char (point-min))
            (search-forward "here.tx")
            (should (equal (thing-at-point 'existing-filename) file))
            (should (equal (thing-at-point 'filename) "here.txt"))
            ;; `file-name-at-point-functions' is the same answer by the route
            ;; `find-file's `M-n' and ffap take.
            (should (equal (run-hook-with-args-until-success
                            'file-name-at-point-functions)
                           file)))))
      (delete-directory dir t))))

(ert-deftest cooked-a-file-found-under-the-project-root-resolves-there ()
  "The project-root fallback has to say *where* it found the file.

`ffap-file-exists-string\=' returns the name it was given, not the directory it
found it in, so `cooked-file-link--exists\=' used to answer a bare `sub/f.txt\='
for a file that exists only under the project root -- and the caller then
resolved that against the child\='s `default-directory\=', which is the one
directory it had just been established not to be in.  A `make\=' log naming a
path relative to the top of the tree, read from a prompt in a subdirectory, is
the everyday shape of this."
  (cooked-tests--with-file-links
    (let* ((root (make-temp-file "cooked-proj" t))
           (sub (expand-file-name "deep/down" root))
           (target (expand-file-name "sub/f.txt" root)))
      (unwind-protect
          (progn
            (make-directory sub t)
            (make-directory (expand-file-name "sub" root) t)
            (with-temp-file target (insert "x"))
            ;; A project is whatever `project-current' finds; a .git makes one
            ;; without depending on which backends happen to be loaded.
            (make-directory (expand-file-name ".git" root) t)
            (with-temp-buffer
              ;; Standing in a subdirectory, where the name does *not* resolve.
              (setq-local default-directory (file-name-as-directory sub))
              (should-not (ffap-file-exists-string "sub/f.txt"))
              (let ((found (cooked-file-link--exists "sub/f.txt")))
                (should found)
                ;; The answer names the project root, not where we are standing.
                (should (file-equal-p found target))
                (should (file-name-absolute-p found)))))
        (delete-directory root t)))))

(ert-deftest cooked-a-link-survives-scrolling-into-the-scrollback ()
  ;; The id travels with the row through eviction, because both live and scrolled
  ;; rows go through the same `Row::runs' -- which is also why a cell's link needed no
  ;; work of its own to get there.
  (cooked-tests--with-session
      '("/bin/sh" "-c"
        "printf '\\033]8;;https://example.com/\\033\\\\marker\\033]8;;\\033\\\\\\n'; for i in $(seq 60); do printf 'line%s\\n' $i; done; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "line60" (cooked-tests--text)))))
    (let ((at (cooked-tests--link-at "marker")))
      (should (get-text-property at 'cooked-scrollback))
      (should (equal (cooked-link-uri at) "https://example.com/")))))

(ert-deftest cooked-links-can-be-switched-off ()
  (let ((cooked-detect-links nil))
    (cooked-tests--with-session
        '("/bin/sh" "-c" "printf 'go to https://example.com/ now\\n'; sleep 5")
      (should (cooked-tests--settle
               (lambda () (string-match-p "example.com" (cooked-tests--text)))))
      (should-not (get-text-property (cooked-tests--link-at "https://")
                                     'cooked-link-url)))))


(ert-deftest cooked-switching-link-detection-applies-to-text-already-shown ()
  "Customizing `cooked-detect-links\=' changes the links already on screen.

The guess runs once per stretch of text, from jit-lock, so a URL found before
the switch stayed clickable after it was turned off, and one shown while it was
off never became a link once it was turned back on.  The `OSC 8\=' span beside
it is what the child said, and survives both."
  (cooked-tests--with-session
      '("/bin/sh" "-c"
        "printf 'go to https://example.com/ or \\033]8;;https://osc.example/\\033\\\\here\\033]8;;\\033\\\\\\n'; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "or here" (cooked-tests--text)))))
    (let ((url (cooked-tests--link-at "https://"))
          (osc (cooked-tests--link-at "here")))
      (jit-lock-fontify-now (point-min) (point-max))
      (should (get-text-property url 'cooked-link-url))
      (unwind-protect
          (progn
            (customize-set-variable 'cooked-detect-links nil)
            (should-not (get-text-property url 'cooked-link-url))
            (should (equal (cooked-link-uri osc) "https://osc.example/"))
            (customize-set-variable 'cooked-detect-links t)
            (jit-lock-fontify-now (point-min) (point-max))
            (should (get-text-property url 'cooked-link-url))
            (should (equal (cooked-link-uri osc) "https://osc.example/")))
        (customize-set-variable 'cooked-detect-links t)))))

(ert-deftest cooked-the-url-scheme-regexp-is-built-once ()
  ;; `bounds-of-thing-at-point' is asked about every match, and thingatpt rebuilds
  ;; the ninety-scheme alternation on each call unless
  ;; `thing-at-point-beginning-of-url-regexp' is already set.  Binding it is the
  ;; whole of the fix, so what is pinned here is that no pass rebuilds it.
  (setq cooked--url-scheme-regexp-memo nil)
  (let ((built 0))
    (cl-letf* ((original (symbol-function 'regexp-opt))
               ((symbol-function 'regexp-opt)
                (lambda (&rest args) (setq built (1+ built)) (apply original args))))
      (with-temp-buffer
        (insert "go to https://example.com/some/long/path now\n")
        (cooked--fontify-links (point-min) (point-max))
        (cooked--fontify-links (point-min) (point-max))))
    (should (<= built 1))))

(ert-deftest cooked-fontifying-a-url-does-not-allocate-a-regexp-per-match ()
  ;; The cost that made this worth fixing was the garbage rather than the time: a
  ;; row with a URL allocated ~25000 string characters, so at the default
  ;; `gc-cons-threshold' typing a URL at a prompt collected every few keystrokes.
  ;; The first pass warms the cache; the second is the one a drain actually pays.
  (with-temp-buffer
    (insert "curl https://example.com/some/long/path\n")
    (cooked--fontify-links (point-min) (point-max))
    (let ((before (nth 4 (memory-use-counts))))
      (cooked--fontify-links (point-min) (point-max))
      (should (< (- (nth 4 (memory-use-counts)) before) 5000)))))


;;;; The optional file layer
;;
;; Required inside the tests rather than at the top, and with both seams let-bound
;; back around them: loading the file *is* the feature being on, so a bare `require'
;; here would turn local-file linking on for every other test in the suite.

(defmacro cooked-tests--with-file-links (&rest body)
  "Run BODY with `cooked-file-link' loaded and its seams confined to it."
  (declare (indent 0))
  `(progn
     (require 'cooked-file-link)
     (let ((cooked-link-follow-functions (list #'cooked-file-link-follow))
           (cooked-link-scan-functions (list #'cooked-file-link-scan)))
       ,@body)))

(ert-deftest cooked-file-links-are-off-until-the-layer-is-loaded ()
  ;; Not a proxy for absence but the entire mechanism by which the core notices it:
  ;; with the file unloaded there is no function to name, so the core has to consult the
  ;; variable and fall through to goto-addr rather than assume a layer is there.
  ;;
  ;; Binding both to nil is still how the unloaded state is reached -- `cooked-file-link'
  ;; sets them at top level, and five other tests in this file load it, so by then they
  ;; are set for the rest of the session.  What changed is that the assertion has to
  ;; survive the binding instead of restating it: this used to `should-not' one of the
  ;; two variables it had just bound to nil, which holds for any `let' at all.
  (let ((cooked-link-follow-functions nil)
        (cooked-link-scan-functions nil)
        (fell-through nil))
    (with-temp-buffer
      (insert "lisp/cooked-link.el:1:1: something\n")
      (goto-char (point-min))
      (cl-letf (((symbol-function 'goto-address-at-point)
                 (lambda (&rest _) (setq fell-through t))))
        (cooked-follow-link-at-point))
      (should fell-through))))

(ert-deftest cooked-file-link-follow-resolves-a-path-with-a-line-and-column ()
  (cooked-tests--with-file-links
    (let ((default-directory (file-name-directory
                              (directory-file-name
                               (file-name-directory (locate-library "cooked-link"))))))
      (with-temp-buffer
        (setq-local default-directory default-directory)
        (insert "lisp/cooked-link.el:12:3: warning: nothing\n")
        (goto-char (point-min))
        (search-forward "cooked-link.el")
        (goto-char (match-beginning 0))
        (let (visited)
          (cl-letf (((symbol-function 'find-file-other-window)
                     (lambda (file) (setq visited file) (set-buffer (get-buffer-create " *visit*")))))
            (should (cooked--run-seam-until-success 'cooked-link-follow-functions))
            (should (string-suffix-p "lisp/cooked-link.el" visited))))))))

(ert-deftest cooked-file-link-scan-stops-on-a-foreign-host ()
  "A build log from a remote tree is full of names that exist here too, at the
same paths, in a checkout that did not produce the log.  The link would open,
land in a real file, and be the wrong file."
  (cooked-tests--with-file-links
    (let ((root (file-name-directory
                 (directory-file-name
                  (file-name-directory (locate-library "cooked-link"))))))
      (with-temp-buffer
        (setq-local default-directory root)
        (should (cooked-file-link--exists "lisp/cooked-link.el"))
        (setq-local cooked--host "other.example")
        (should-not (cooked-file-link--exists "lisp/cooked-link.el"))
        (insert "built lisp/cooked-link.el\n")
        (cooked--run-seam 'cooked-link-scan-functions (point-min) (point-max))
        (goto-char (point-min))
        (search-forward "lisp/cooked-link.el")
        (should-not (get-text-property (match-beginning 0) 'cooked-file-link))))))

(ert-deftest cooked-a-compressed-file-does-not-make-its-plain-name-a-link ()
  "Only `notes.txt.gz\=' exists, so `notes.txt\=' is not a file.

`ffap-file-exists-string\=' tries the compression suffixes on a miss and
returns the name it found, and `cooked-file-link--exists\=' threw that away and
answered with the name it was asked about, so the link opened an empty buffer."
  (should (rassq 'jka-compr-handler file-name-handler-alist))
  (cooked-tests--with-file-links
    (let ((dir (make-temp-file "cooked-gz" t)))
      (unwind-protect
          (with-temp-buffer
            (setq-local default-directory (file-name-as-directory dir))
            (write-region "" nil (expand-file-name "notes.txt.gz" dir))
            (should-not (cooked-file-link--exists "notes.txt"))
            (insert "see notes.txt\n")
            (cooked--run-seam 'cooked-link-scan-functions (point-min) (point-max))
            (should-not (get-text-property (cooked-tests--link-at "notes.txt")
                                           'cooked-file-link)))
        (delete-directory dir t)))))

(ert-deftest cooked-a-missed-file-name-is-asked-for-once-per-place ()
  "A miss is most of what a scan does, so it costs one `file-exists-p\=' a place.

Six it used to be at the project root: the name, then `.gz\=' and `.Z\=', all
twice, the second time against a root that was the directory already asked.
A relative name in a subdirectory still gets its two places, an absolute one
only the one, and a number with a point in it is not a candidate at all."
  (cooked-tests--with-file-links
    (let* ((root (file-name-as-directory (make-temp-file "cooked-miss" t)))
           (sub (file-name-as-directory (expand-file-name "sub" root)))
           (calls 0)
           (count (lambda (&rest _) (cl-incf calls))))
      (make-directory sub)
      (make-directory (expand-file-name ".git" root))
      (advice-add 'file-exists-p :before count)
      (unwind-protect
          (with-temp-buffer
            (cl-flet ((asks (name)
                        (setq calls 0)
                        (should-not (cooked-file-link--exists name))
                        calls))
              (setq-local default-directory root)
              ;; Warm `project-current's cache, which asks for .git itself.
              (cooked-file-link--exists "warm.el")
              (should (= (asks "missing.el") 1))
              (setq-local default-directory sub)
              (cooked-file-link--exists "warm.el")
              (should (= (asks "missing.el") 2))
              (should (= (asks "/nowhere/missing.el") 1))
              (insert "version 1.5 on 192.168.0.1\n")
              (setq calls 0)
              (cooked--run-seam 'cooked-link-scan-functions (point-min) (point-max))
              (should (= calls 0))))
        (advice-remove 'file-exists-p count)
        (delete-directory root t)))))

(ert-deftest cooked-file-link-scan-highlights-only-what-exists ()
  (cooked-tests--with-file-links
    (let ((root (file-name-directory
                 (directory-file-name
                  (file-name-directory (locate-library "cooked-link"))))))
      (with-temp-buffer
        (setq-local default-directory root)
        (insert "built lisp/cooked-link.el and lisp/nothing-here.el\n")
        (cooked--run-seam 'cooked-link-scan-functions (point-min) (point-max))
        (goto-char (point-min))
        (search-forward "lisp/cooked-link.el")
        (should (get-text-property (match-beginning 0) 'cooked-file-link))
        (goto-char (point-min))
        (search-forward "lisp/nothing-here.el")
        (should-not (get-text-property (match-beginning 0) 'cooked-file-link))))))

(ert-deftest cooked-file-link-never-scans-a-flood ()
  (cooked-tests--with-file-links
    (let ((root (file-name-directory
                 (directory-file-name
                  (file-name-directory (locate-library "cooked-link"))))))
      (with-temp-buffer
        (setq-local default-directory root)
        (dotimes (_ (1+ cooked-file-link-scan-limit))
          (insert "lisp/cooked-link.el\n"))
        (cooked--run-seam 'cooked-link-scan-functions (point-min) (point-max))
        (should-not (text-property-not-all (point-min) (point-max)
                                           'cooked-file-link nil))))))

(ert-deftest cooked-file-link-prefilter-cannot-assemble-a-remote-name ()
  "The scan hands everything its prefilter matches to the filesystem, and
`ffap-file-exists-string\=' on a TRAMP name would connect.  Nothing is caught
downstream: what keeps a remote name from ever being built is the character set
in `cooked-file-link--candidate-regexp\=', which admits `:\=' only ahead of the
digits of a `:LINE:COL\=' suffix.  That is load-bearing and easy to widen by
accident, so it is pinned here rather than left to be rediscovered.

See `cooked--local-name\=' for what the connection would cost, and
`cooked--set-directory\=' for the other half -- a `default-directory\=' that has
gone remote would make even a relative name resolve over the wire."
  (cooked-tests--with-file-links
    (dolist (hostile '("/ssh:evil.example:/etc/motd"
                       "/sudo::/etc/shadow"
                       "/docker:box:/tmp/x"))
      (should-not (string-match-p (concat "\\`" cooked-file-link--candidate-regexp "\\'")
                                  hostile))
      ;; And what it *does* match out of one is a local prefix, never the whole.
      (when (string-match cooked-file-link--candidate-regexp hostile)
        (should-not (file-remote-p (match-string 0 hostile)))))
    ;; A name with a line and column still matches whole, or the prefilter would
    ;; have been narrowed into uselessness.
    (should (string-match-p (concat "\\`" cooked-file-link--candidate-regexp "\\'")
                            "src/main.rs:12:3"))))

(ert-deftest cooked-file-links-decline-against-a-remote-default-directory ()
  "The cost guard, distinct from the foreign-host correctness guard beside it.

Every candidate the scan produces becomes an `ffap-file-exists-string\=', and
against a TRAMP `default-directory\=' each one of those is a round trip.
Scrollback settles in batches of hundreds of lines, so a single remote
`default-directory\=' turns every batch for the rest of the session into a stall.

Asserted here without a foreign host in play, because that is the case the other
guard does not cover: \\[cooked] from a buffer visiting a remote file starts with
a remote `default-directory\=' and no OSC 7 at all.  The names used are ones that
would resolve locally, so a regression shows up as a link appearing rather than
as one silently still missing."
  (cooked-tests--with-file-links
   (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
     (let ((asked nil))
       (cl-letf (((symbol-function 'ffap-file-exists-string)
                  (lambda (&rest _) (setq asked t) nil)))
         (setq default-directory "/ssh:other.example:/srv/app/")
         (should-not cooked--host)
         (should-not (cooked--foreign-host-p))
         (should-not (cooked-file-link--exists "lib.rs"))
         (should-not (cooked-file-link--exists "/etc/passwd"))
         ;; Nothing was even asked, which is the point: the guard has to come
         ;; before the filesystem call, not filter its answer.
         (should-not asked)
         ;; And a local `default-directory' is untouched by any of this.
         (setq default-directory "/tmp/")
         (should-not (cooked-file-link--exists "lib.rs"))
         (should asked))))))

(ert-deftest cooked-a-bare-url-waits-for-something-to-look-at-it ()
  "The other half of `cooked-a-bare-url-is-fontified-by-goto-addr\='.

The guess is redisplay\='s work now, not the drain\='s, which is what stops a
child painting faster than Emacs redraws from being scanned once per frame it
paints.  Nothing has displayed this buffer, so nothing has guessed yet."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf 'go to https://example.com/ now\\n'; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "example.com" (cooked-tests--text)))))
    (should-not (text-property-not-all (point-min) (point-max)
                                       'cooked-link-url nil))
    ;; And it is only the looking that was missing.
    (cooked-tests--fontify)
    (should (text-property-not-all (point-min) (point-max)
                                   'cooked-link-url nil))))

(ert-deftest cooked-rewriting-a-row-still-gets-it-scanned ()
  "The outcome `cooked--render-block's `inhibit-modification-hooks' binding has
to leave standing: a row the child repaints is looked at again.

The binding covers the three property loops and stops at the row rewrite, which
is where `cooked--render-rows' says the notification lives -- rewriting the text
is what marks the row unfontified, and the property loops only fire the same
`after-change-functions' a few hundred more times a frame to say it again.  So
what is asserted here is the end of that chain rather than the hook: after a
repaint the rows read as unfontified, and the scan that redisplay would drive
finds the URLs that are there now rather than the ones that were.

It is a *re*paint and not a first render because only a repaint can tell the two
apart.  Freshly inserted text carries no `fontified' property at all and so
already reads as unfontified whatever hooks ran, which is why a first render and
scrollback would both pass this with the notification removed entirely.

Worth saying outright, since the binding was made with the opposite belief: a
blanket inhibit across the rewrite does *not* fail this test.  Emacs' `insert'
inherits no properties, so the new row is unmarked by construction and jit-lock
learns nothing from its own hook that the fresh text did not already say.  The
rewrite is still left outside the binding, because that is what
`cooked--render-rows' documents as the notification and a change hook a user has
added is entitled to see the edit -- but the safety is belt-and-braces rather
than the load-bearing thing the plan for this took it to be.

Both shapes of row, because they take different amounts of the inhibited path:
plain text applies style spans and nothing else, while box drawing also runs
`cooked--apply-deco' and is the case the hook cost was measured on -- see
`cooked--sync-fontification'."
  (cooked-tests--with-session
      '("/bin/sh" "-c"
        "printf 'go to https://one.example/ now\\n'; \
printf '\\342\\224\\200\\342\\224\\200\\342\\224\\200\\342\\224\\200 https://two.example/\\n'; \
read x; \
printf '\\033[1;1Hgo to https://three.example/ now'; \
printf '\\033[2;1H\\342\\224\\200\\342\\224\\200\\342\\224\\200\\342\\224\\200 https://four.example/'; \
printf '\\033[3;1H'; \
sleep 5")
    (cooked-tests--cell)
    (should (cooked-tests--settle
             (lambda () (string-match-p "two.example" (cooked-tests--text)))))
    ;; The child parks the cursor on a third row after the repaint, and that is
    ;; load-bearing rather than tidy: the URL guess declines the cursor's own
    ;; row -- see `cooked--link-hold-bounds' -- so leaving the cursor on row 2
    ;; would make this fail for a reason with nothing to do with the
    ;; `inhibit-modification-hooks' binding it is about.
    ;;
    ;; Look once, so both rows are marked fontified and the repaint has
    ;; something to take back.
    (cooked-tests--fontify)
    (should-not (text-property-any (point-min) (point-max) 'fontified nil))
    ;; Let the child repaint the two rows in place.
    (cooked--send-to-child "\n")
    (should (cooked-tests--settle
             (lambda () (string-match-p "four.example" (cooked-tests--text)))))
    ;; The decorated row really did take the property loops.
    (should (get-text-property (cooked-tests--link-at "─") 'display))
    (dolist (text '("three.example" "four.example"))
      (let ((pos (cooked-tests--link-at text)))
        (should pos)
        (should-not (get-text-property pos 'fontified))))
    ;; And the looking, when it happens, finds what is there now -- as text
    ;; properties rather than overlays; see `cooked--fontify-links'.
    (cooked-tests--fontify)
    (dolist (text '("three.example" "four.example"))
      (let ((pos (cooked-tests--link-at text)))
        (should (get-text-property pos 'cooked-link-url))))))

(ert-deftest cooked-a-repaint-announces-its-rewrite-and-not-its-properties ()
  "Where `cooked--render-block\='s `inhibit-modification-hooks\=' binding sits.

`cooked-rewriting-a-row-still-gets-it-scanned\=' holds with the binding gone and
with it widened, so this watches the hook itself.  A change hook sees the
rewrite -- the deletion and the insertion of the two repainted rows -- because a
hook a user has added is entitled to see an edit.  It does not see the faces and
glyphs applied to the new text, one call per span, because those are what the
binding is there to keep quiet.  A property change is the one call whose length
equals its extent, so on `go to https://...\=' with `to\=' in bold, the bold
span would arrive as a change of 2 over 2 characters inside the rewrite."
  (cooked-tests--with-session
      '("/bin/sh" "-c"
        "printf 'go \\033[1mto\\033[0m https://one.example/ now\\n'; \
printf '\\342\\224\\200\\342\\224\\200\\342\\224\\200\\342\\224\\200 https://two.example/\\n'; \
read x; \
printf '\\033[1;1Hgo \\033[1mto\\033[0m https://three.example/ now'; \
printf '\\033[2;1H\\342\\224\\200\\342\\224\\200\\342\\224\\200\\342\\224\\200 https://four.example/'; \
printf '\\033[3;1H'; \
sleep 5")
    (cooked-tests--cell)
    (should (cooked-tests--settle
             (lambda () (string-match-p "two.example" (cooked-tests--text)))))
    (let ((changes nil))
      (add-hook 'after-change-functions
                (lambda (beg end length) (push (list beg end length) changes))
                nil t)
      (cooked--send-to-child "\n")
      (should (cooked-tests--settle
               (lambda () (string-match-p "four.example" (cooked-tests--text)))))
      (should (get-text-property (cooked-tests--link-at "to") 'face))
      (should (get-text-property (cooked-tests--link-at "─") 'display))
      (let ((insertions (seq-filter (lambda (c) (zerop (nth 2 c))) changes)))
        ;; The rewrite is seen, and it covers both repainted rows.
        (should insertions)
        (dolist (text '("three.example" "four.example"))
          (let ((pos (cooked-tests--link-at text)))
            (should (seq-some (lambda (c) (<= (car c) pos (nth 1 c)))
                              insertions))))
        ;; No property change falls inside the text a repaint inserted.
        (should-not
         (seq-some (lambda (change)
                     (pcase-let ((`(,beg ,end ,length) change))
                       (and (> length 0)
                            (= length (- end beg))
                            (seq-some (lambda (i)
                                        (and (<= (car i) beg) (<= end (nth 1 i))))
                                      insertions))))
                   changes))))))

(ert-deftest cooked-the-scan-is-not-armed-when-it-has-nothing-to-scan ()
  "Registering jit-lock is not free: it hangs `jit-lock-after-change\=' on every
text property the renderer applies, which measured at +21% on plain rows and
+55% on box drawing with nothing ever being scanned.  So the registration
follows the work -- see `cooked--sync-fontification\='."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (should (memq #'cooked--fontify-region jit-lock-functions))
    ;; The alternate screen is a rectangle the child owns; the guess declines it
    ;; outright, so tracking its changes buys nothing at all.
    (cooked--set-alt t)
    (should-not (memq #'cooked--fontify-region jit-lock-functions))
    (cooked--set-alt nil)
    (should (memq #'cooked--fontify-region jit-lock-functions))
    ;; And a session with the guess switched off and no scan layer loaded.
    (let ((cooked-detect-links nil)
          (cooked-link-scan-functions nil))
      (cooked--sync-fontification)
      (should-not (memq #'cooked--fontify-region jit-lock-functions)))
    (cooked--sync-fontification)
    (should (memq #'cooked--fontify-region jit-lock-functions))))

(ert-deftest cooked-the-scan-hook-sees-only-settled-text ()
  "`cooked-link-scan-functions\=' is the seam an optional layer may touch the
filesystem from, which is affordable only because scrollback is final.  The
live screen is rewritten by the next drain, so an answer about it would be
bought again every redraw."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "for i in $(seq 40); do echo line $i; done; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "line 40" (cooked-tests--text)))))
    (let* ((seen nil)
           (cooked-link-scan-functions
            (list (lambda (beg end) (push (cons beg end) seen)))))
      (cooked-tests--fontify)
      (should seen)
      (let ((screen (cooked--screen-start-position)))
        (should screen)
        (pcase-dolist (`(,_beg . ,end) seen)
          (should (<= end screen)))))))

;;;; Soft wrap
;;
;; A narrow session, because that is the only way to make the terminal do the
;; wrapping: the child writes one line and the grid breaks it, which is exactly
;; the case the buffer could not tell from a line the child ended.  Twenty
;; columns is narrow enough for a URL to need three rows of it and wide enough
;; that the rows are still readable in a failure message.
;;
;; A trailing newline after the URL matters and is not decoration.  The URL scan
;; declines the cursor's own row -- see
;; `cooked-the-url-guess-declines-the-cursors-own-row' -- so a URL whose last row
;; the cursor is still sitting on is held back, and the test would be asserting
;; the hold rather than the join.

(defmacro cooked-tests--with-wrapped-line (text &rest body)
  "Run BODY with TEXT printed into a 6x20 session, followed by a newline."
  (declare (indent 1))
  `(let ((buffer (generate-new-buffer "*cooked-wrap*")))
     (unwind-protect
         (with-current-buffer buffer
           (cooked-mode)
           (setq cooked--rows 6 cooked--cols 20 cooked--last-size '(6 . 20))
           (cooked--start (list "/bin/sh" "-c"
                                (format "printf '%%s\\n' '%s'; sleep 5" ,text)))
           (cooked--refresh-keymap)
           (should (cooked-tests--settle
                    (lambda () (string-match-p "end" (cooked-tests--text)))))
           (cooked-tests--fontify)
           ,@body)
       (with-current-buffer buffer (cooked--cleanup))
       (kill-buffer buffer))))

(defun cooked-tests--url-runs ()
  "Every run of `cooked-link-url\\=' in the buffer, as (BEG END URL)."
  (let ((runs nil)
        (pos (point-min)))
    (while (< pos (point-max))
      (let ((next (or (next-single-property-change pos 'cooked-link-url)
                      (point-max))))
        (when-let* ((url (get-text-property pos 'cooked-link-url)))
          (push (list pos next url) runs))
        (setq pos next)))
    (nreverse runs)))

(defconst cooked-tests--wrapping-url
  "see https://example.com/a/very/long/path end"
  "A URL that needs three rows of a twenty-column terminal.")

(ert-deftest cooked-a-url-the-terminal-wrapped-is-matched-whole ()
  "cooked's one documented detection gap, closed.

Each live row is its own buffer line, so until the emulator started reporting
`Row::wrapped' for damaged rows this matched only as far as the first column
boundary -- `https://example' and nothing else.  The whole URL is now one match,
and the assertion is on the URL *recorded*, which is the thing a click opens."
  (cooked-tests--with-wrapped-line cooked-tests--wrapping-url
    (let ((runs (cooked-tests--url-runs)))
      (should runs)
      (dolist (run runs)
        (should (equal (nth 2 run) "https://example.com/a/very/long/path")))
      ;; More than one run, and that is the shape rather than an accident: the
      ;; wrap newlines are left unmarked, so one link is as many property runs as
      ;; it has rows.
      (should (> (length runs) 1)))))

(ert-deftest cooked-a-wrapped-links-row-breaks-carry-no-link-property ()
  "The newline between two rows of one link is not part of the link.

A `mouse-face' there would highlight the gap at the end of the row, and a
`keymap' would claim a click on nothing.  ghostel's `ghostel--wrap-fragments'
makes the same exclusion for the same reason."
  (cooked-tests--with-wrapped-line cooked-tests--wrapping-url
    (let ((runs (cooked-tests--url-runs)))
      (should (> (length runs) 1))
      ;; Between each pair of runs, exactly the wrap newline and nothing else.
      (cl-loop for (this next) on runs
               while next
               do (should (= (nth 1 this) (1- (car next))))
               do (should (eq (char-after (nth 1 this)) ?\n))
               do (should (get-text-property (nth 1 this) 'cooked-wrap))
               do (should-not (get-text-property (nth 1 this) 'mouse-face))
               do (should-not (get-text-property (nth 1 this) 'keymap))))))

(ert-deftest cooked-the-fragments-of-a-wrapped-link-are-one-thing ()
  "What is drawn as three pieces answers as one link.

The shared `cooked-link-fragment' id is what makes that exact -- adjacency in
the text would not, since two links can sit on consecutive rows -- and it is
what `thing-at-point' and embark need in order to act on the whole URL rather
than on the row point happens to be in."
  (cooked-tests--with-wrapped-line cooked-tests--wrapping-url
    (let* ((runs (cooked-tests--url-runs))
           (ids (mapcar (lambda (run)
                          (get-text-property (car run) 'cooked-link-fragment))
                        runs))
           (whole (cons (car (car runs)) (nth 1 (car (last runs))))))
      (should (car ids))
      (should (apply #'eq (car ids) (cdr ids)))
      ;; The bounds span every fragment and the breaks between them, which is the
      ;; extent of the thing even though the properties skip the breaks -- and
      ;; the same answer whichever fragment is asked.
      (goto-char (car (car runs)))
      (should (equal (cooked-link--detected-bounds) whole))
      (goto-char (car (car (last runs))))
      (should (equal (cooked-link--detected-bounds) whole)))))

(ert-deftest cooked-thing-at-point-answers-a-wrapped-url-whole ()
  "thingatpt reads a URL out of the text, and the text has a row break in it.

So this is the second case `cooked-link--url-at-point' answers, on the same
argument as the first: what thingatpt cannot know.  An unwrapped detected URL is
still left to it."
  (cooked-tests--with-wrapped-line cooked-tests--wrapping-url
    (goto-char (car (car (cooked-tests--url-runs))))
    (cooked--install-thing-at-point-providers)
    (should (equal (thing-at-point 'url)
                   "https://example.com/a/very/long/path"))))

(ert-deftest cooked-following-a-wrapped-link-opens-the-whole-url ()
  "`goto-address-at-point' would open the fragment point is in, reading the URL
out of the text being all it can do.  The scan already wrote the whole one down."
  (cooked-tests--with-wrapped-line cooked-tests--wrapping-url
    (let ((opened nil))
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (url &rest _) (setq opened url))))
        ;; The second row, so a fragment rather than the start of the match.
        (goto-char (car (nth 1 (cooked-tests--url-runs))))
        (cooked--open-link-at-point))
      (should (equal opened "https://example.com/a/very/long/path")))))

(ert-deftest cooked-a-line-the-child-ended-is-never-joined ()
  "The half that must not change, and the reason the flag had to come from the
emulator rather than be guessed from the geometry.  Two lines the child ended
are two things whatever they look like, and gluing them would invent a URL
nobody printed -- a real hazard rather than a tidy one, since the invented
destination names a host neither line did."
  (cooked-tests--with-wrapped-line "see https://a.example\n/evil/path end"
    (let ((runs (cooked-tests--url-runs)))
      (should runs)
      (dolist (run runs)
        (should-not (string-search "evil" (nth 2 run)))))))

(ert-deftest cooked-an-unwrapped-region-takes-the-path-it-always-took ()
  "The cost of the feature on a screen with nothing wrapped is one property
search, and the way that is guaranteed is that the join declines: with no
`cooked-wrap' in the region `cooked-link--join-wrapped' answers nil and the scan
runs over the buffer exactly as before."
  (cooked-tests--with-session
      '("/bin/sh" "-c" "printf 'go to https://example.com/ now\\n'; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "example.com" (cooked-tests--text)))))
    (should-not (cooked-link--join-wrapped (point-min) (point-max)))
    (cooked-tests--fontify)
    (let ((at (cooked-tests--link-at "https://example.com/")))
      (should (equal (get-text-property at 'cooked-link-url)
                     "https://example.com/"))
      ;; No id, because there was nothing to hold together.
      (should-not (get-text-property at 'cooked-link-fragment)))))

;; Edges of the join and of the precedence between the passes.

(ert-deftest cooked-an-osc-8-span-inside-a-url-keeps-its-own-properties ()
  "The guess asks whether any of its match is claimed, not just the first character.

A child can open an `OSC 8\=' span halfway through text that also reads as a
URL.  Asked only about the start, the guess found nothing there and laid its
`help-echo\=' over the span\='s tail, so hovering the explicit link showed goto-addr\='s
string instead of where the link goes."
  (cooked-tests--with-session
      '("/bin/sh" "-c"
        "printf 'https://example.com/\\033]8;;https://elsewhere.example/\\033\\\\tail\\033]8;;\\033\\\\\\n'; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "example.com/tail" (cooked-tests--text)))))
    (cooked-tests--fontify)
    (let ((tail (cooked-tests--link-at "tail")))
      (should (equal (cooked-link-uri tail) "https://elsewhere.example/"))
      (should (eq (get-text-property tail 'help-echo) #'cooked--link-help-echo))
      (should-not (text-property-not-all (cooked-tests--link-at "https://")
                                         (1+ (cooked-tests--link-at "tail"))
                                         'cooked-link-url nil)))))

(ert-deftest cooked-detected-bounds-just-after-a-leading-newline ()
  "Two characters back from a fragment is position 0 when a blank row starts the buffer.

`cooked-link--detected-bounds\=' looks past the newline before a fragment for
the row above, and at position 2 that look signalled `args-out-of-range\='."
  (with-temp-buffer
    (insert "\nhttps://example.com/")
    (add-text-properties 2 (point-max)
                         (list 'cooked-link-url "https://example.com/"
                               'cooked-link-fragment (cons 'cooked-link-detected nil)))
    (should (equal (cooked-link--detected-bounds 2) (cons 2 (point-max))))))

(ert-deftest cooked-only-a-url-that-crosses-a-wrap-is-marked-as-fragments ()
  "A URL in a wrapped region that fits on its row is an ordinary link.

The joined scan used to mark every match with a `cooked-link-fragment\=' id, so
the url provider answered an unwrapped URL from the property, which is the case
`cooked-link--url-at-point\=' says it leaves to thingatpt."
  (cooked-tests--with-wrapped-line "https://a.io/ https://example.com/a/long/path end"
    (let ((short (cooked-tests--link-at "https://a.io/"))
          ;; Found by column, since the row break is inside `https:'.
          (long (+ (cooked-tests--link-at "https://a.io/") 14)))
      (should (equal (get-text-property short 'cooked-link-url) "https://a.io/"))
      (should-not (get-text-property short 'cooked-link-fragment))
      (should (equal (get-text-property long 'cooked-link-url)
                     "https://example.com/a/long/path"))
      (should (get-text-property long 'cooked-link-fragment)))))

(ert-deftest cooked-thing-at-point-answers-a-wrapped-file-name-whole ()
  "A path the terminal wrapped is one file name, from whichever row you ask.

ffap reads to the end of the buffer line, which on the live screen is a row, so
point on the second row of `src/some/deeply/nested/file.txt\=' used to be
answered `nested/file.txt\=', and `find-file\=' offered that."
  (cooked-tests--with-file-links
    (cooked-tests--with-wrapped-line "see src/some/deeply/nested/file.txt end"
      (cooked--install-thing-at-point-providers)
      (let ((beg (cooked-tests--link-at "src/"))
            (end (+ (cooked-tests--link-at ".txt") 4)))
        ;; The row break really is inside the name.
        (should (< beg (cooked-tests--link-at "nested") end))
        (should (cooked-link--wrap-at beg end))
        (dolist (at (list (1+ beg) (cooked-tests--link-at "file")))
          (goto-char at)
          (should (equal (thing-at-point 'filename)
                         "src/some/deeply/nested/file.txt"))
          (should (equal (bounds-of-thing-at-point 'filename) (cons beg end))))))))

;; The join's own pieces, over a buffer written by hand.  A terminal cannot
;; produce a fifty-row logical line at any width a test would want to run at, and
;; the binary search is worth pinning at a size where a linear walk would have
;; passed by accident.

(defun cooked-tests--wrapped-buffer (rows text)
  "Insert ROWS lines of TEXT, joined by soft-wrap newlines, and mark them."
  (dotimes (row rows)
    (when (> row 0)
      (insert "\n")
      (put-text-property (1- (point)) (point) 'cooked-wrap t))
    (insert text)))

(ert-deftest cooked-joining-stops-at-the-row-cap ()
  "A minified blob is one logical line megabytes long, and joining all of it
would build that string on every scan and hand the regexp engine a single token
to chew through.  The cap is ghostel's fifty, counted per logical line."
  (with-temp-buffer
    (cooked-tests--wrapped-buffer (* 2 cooked-link--join-rows) "0123456789")
    (let ((joined (cooked-link--join-wrapped (point-min) (point-max))))
      (should joined)
      ;; Every newline but the ones the cap refused is gone: one refusal per
      ;; fifty rows joined, and the last stretch stops short of the cap.
      (should (= (cl-count ?\n (car joined))
                 (/ (1- (* 2 cooked-link--join-rows))
                    cooked-link--join-rows))))))

(ert-deftest cooked-the-offset-map-finds-the-row-an-offset-landed-in ()
  "The binary search, over enough rows that a walk would be the wrong shape.
Asserted against the buffer's own arithmetic for every row, which is the only
oracle worth having for a map."
  (with-temp-buffer
    (cooked-tests--wrapped-buffer 40 "0123456789")
    (let* ((joined (cooked-link--join-wrapped (point-min) (point-max)))
           (chunks (cdr joined)))
      (should (= (length (car joined)) 400))
      (dotimes (row 40)
        ;; Ten characters per row in the string; eleven in the buffer, the
        ;; eleventh being the wrap newline the join took out.
        (should (= (cooked-link--wrap-position (* row 10) chunks)
                   (+ (point-min) (* row 11))))))))

(ert-deftest cooked-a-wrap-flag-on-something-other-than-a-newline-is-ignored ()
  "A yank carries text properties with the text, so a buffer can hold a copy of
a `cooked-wrap' sitting on an ordinary character.  Joining there would delete a
character rather than a line break."
  (with-temp-buffer
    (insert "abcdef")
    (put-text-property 3 4 'cooked-wrap t)
    (should-not (cooked-link--join-wrapped (point-min) (point-max)))))

(ert-deftest cooked-a-url-an-edit-changed-is-found-again-whole ()
  "An edit that rewrites part of a URL leaves the guess covering the new URL.

The edit replaces only the characters that changed, and jit-lock is told
only about those; the link pass rounds out to the whole line, so the part of
the URL the edit did not touch is scanned again with the rest."
  (cooked-tests--with-session
      '("/bin/sh" "-c"
        "printf 'see https://example.com/aaa for the full report today\\n'; sleep 0.4; printf '\\033[1;25Hbbb\\033[3;1Hsync'; sleep 5")
    (should (cooked-tests--settle
             (lambda () (string-match-p "aaa" (cooked-tests--text)))))
    (cooked-tests--fontify)
    (should (cooked-tests--settle
             (lambda () (string-match-p "sync" (cooked-tests--text)))))
    (cooked-tests--fontify)
    (let ((at (cooked-tests--link-at "https://example.com/bbb")))
      (should (equal (get-text-property at 'cooked-link-url)
                     "https://example.com/bbb"))
      (should (equal (get-text-property (+ at 22) 'cooked-link-url)
                     "https://example.com/bbb")))))

(provide 'cooked-tests-link)
;;; cooked-tests-link.el ends here
