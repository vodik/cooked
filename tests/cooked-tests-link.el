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
    (let* ((at (cooked-tests--link-at "https://example.com/"))
           (overlay (seq-find (lambda (o) (overlay-get o 'goto-address))
                              (overlays-at at))))
      (should overlay)
      (should (overlay-get overlay 'follow-link))
      ;; The keymap is ours, not goto-addr's: a `keymap' property outranks
      ;; `emulation-mode-map-alists', so the gate has to be in the command that
      ;; property names.  See `cooked-follow-link'.
      (should (eq (overlay-get overlay 'keymap) cooked-link-map)))))

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
      (should-not (seq-find (lambda (o) (overlay-get o 'goto-address))
                            (overlays-at at))))))

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
      (should-not (seq-find (lambda (o) (overlay-get o 'goto-address))
                            (overlays-at (cooked-tests--link-at "https://")))))))


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
     (let ((cooked-link-follow-function #'cooked-file-link-follow)
           (cooked-link-scan-function #'cooked-file-link-scan))
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
  (let ((cooked-link-follow-function nil)
        (cooked-link-scan-function nil)
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
            (should (funcall cooked-link-follow-function))
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
        (funcall cooked-link-scan-function (point-min) (point-max))
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
        (funcall cooked-link-scan-function (point-min) (point-max))
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
        (funcall cooked-link-scan-function (point-min) (point-max))
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

(provide 'cooked-tests-link)
;;; cooked-tests-link.el ends here
