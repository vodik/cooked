;;; cooked-tests-link.el --- Links in terminal output -*- lexical-binding: t; -*-

;;; Commentary:

;; Both halves of link detection, end to end: the `OSC 8' sequences a program
;; actually emits, and the guess `goto-address-fontify-region' makes about text that
;; merely looks like a URL.  The pure-Rust half -- interning, eviction, what closes a
;; link and what must not -- is tested in src/emu/link.rs and src/emu/term.rs; what is
;; here is what only a real buffer can show: that the id reaches the text, that the
;; two passes agree about who wins, and that a link cannot steal a click from a child
;; holding the mouse.

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
            (list (cons 'osc-8 (lambda (pos) (memq pos claimed)))
                  (cons 'goto-addr (lambda (pos) (memq (1+ pos) claimed)))
                  (cons 'guessed (lambda (pos) (memq (+ 2 pos) claimed))))))
      ;; Nothing registered a claim yet.
      (should-not (cooked-link--claimed-p 1))
      ;; The top source claims, and is named -- the return value is the symbol,
      ;; so a caller can say *which* source outranked it rather than only that
      ;; one did.
      (setq claimed '(1))
      (should (eq (cooked-link--claimed-p 1) 'osc-8))
      ;; The guessing layer asks as itself and is still blocked, because OSC 8
      ;; outranks it.
      (should (eq (cooked-link--claimed-p 1 'guessed) 'osc-8))
      ;; ... and OSC 8 asking as itself is *not* told it claimed its own span.
      (should-not (cooked-link--claimed-p 1 'osc-8))
      ;; A claim held only by the lowest source does not block the ones above
      ;; it: the walk stops at the asking source's own entry.
      (setq claimed '(3))
      (should (eq (cooked-link--claimed-p 1) 'guessed))
      (should-not (cooked-link--claimed-p 1 'goto-addr))
      (should-not (cooked-link--claimed-p 1 'osc-8)))))

(ert-deftest cooked-the-file-link-layer-registers-itself-below-the-others ()
  "cooked-file-link.el appends its own rank rather than the base layer naming it."
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
  ;; rows go through the same `Row::runs' -- which is also why `Extra::Link' needed no
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


(ert-deftest cooked-the-url-scheme-regexp-is-built-once ()
  ;; `bounds-of-thing-at-point' is asked about every match, and thingatpt rebuilds
  ;; the ninety-scheme alternation on each call unless
  ;; `thing-at-point-beginning-of-url-regexp' is already set.  Binding it is the
  ;; whole of the fix, so what is pinned here is that no pass rebuilds it.
  (setq cooked--url-scheme-regexp nil)
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

(provide 'cooked-tests-link)
;;; cooked-tests-link.el ends here
