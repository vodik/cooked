;;; cooked-tests-dnd.el --- drops and yank-media  -*- lexical-binding: t; -*-

;;; Commentary:

;; `cooked-dnd.el' is an optional layer, so these load it the way the link tests load
;; `cooked-file-link': explicitly, and with the buffer-local state it installs confined
;; to the buffer under test.  What every test here is really about is the one thing that
;; can go wrong -- a PTY carries no file, only a *name*, so the whole feature is the
;; construction of that name and it has to survive quoting, TRAMP and a hostile file.

;;; Code:

(require 'ert)
(require 'cooked-tests-helpers)
(require 'cooked-dnd)

(defmacro cooked-tests--capturing-paste (&rest body)
  "Run BODY with `cooked--send-paste\=' recording into `pasted\=' instead of writing.

The child is not involved: what is under test is the text handed to the paste
path, and going as far as the PTY would only add a round trip to read it back
out of the grid."
  (declare (indent 0))
  `(let ((pasted nil))
     (cl-letf (((symbol-function 'cooked--send-paste)
                (lambda (text) (push text pasted))))
       ,@body
       (nreverse pasted))))

(ert-deftest cooked-dnd-types-a-dropped-name-shell-quoted ()
  "A name with a space in it must arrive as one argument."
  (with-temp-buffer
    (should (equal (cooked-tests--capturing-paste
                     (cooked-dnd--insert "/tmp/two words.png"))
                   '("/tmp/two\\ words.png ")))))

(ert-deftest cooked-dnd-quotes-a-name-that-would-run-a-command ()
  "The case that makes the quoting a security property rather than a nicety.

A file name is attacker-controlled far more often than a paste is -- it can be
chosen by whoever wrote the archive you just unpacked -- so a drop of
`;rm -rf ~\=' must reach the shell as an argument and not as a second command.
Command substitution, a quote and a glob are here for the same reason: each is a
different thing `sh\=' would otherwise do to the name before the program saw
it."
  (dolist (name '("/tmp/;rm -rf ~"
                  "/tmp/$(id)"
                  "/tmp/`id`"
                  "/tmp/two words.png"
                  "/tmp/it's here"
                  "/tmp/*"))
    (with-temp-buffer
      (let ((typed (car (cooked-tests--capturing-paste
                          (cooked-dnd--insert name)))))
        ;; Asked of a real shell rather than of a regexp, because what is being
        ;; claimed is a fact about how `sh' parses this and nothing else is
        ;; evidence for it.  `printf %s' with the typed text as the argument:
        ;; one argument out, byte for byte, or the quoting failed.
        (should (equal (with-output-to-string
                         (with-current-buffer standard-output
                           (call-process "/bin/sh" nil t nil "-c"
                                         (concat "printf %s " typed))))
                       name))))))

(ert-deftest cooked-dnd-sends-the-remote-localname-over-tramp ()
  "The whole of the remote story, and it is one function call.

When `default-directory\=' is remote the child runs on the far host, so the name
it needs is the path *there*: `/ssh:host:/tmp/x.png\=' means nothing to a shell
on host, while `/tmp/x.png\=' is exactly right.  Nothing here opens a
connection -- `file-remote-p\=' is pure string surgery on the name."
  (with-temp-buffer
    (should (equal (cooked-tests--capturing-paste
                     (cooked-dnd--insert "/ssh:host:/tmp/x.png"))
                   '("/tmp/x.png ")))
    ;; A multi-hop name resolves to the same localname, so the feature does not
    ;; quietly stop working on the hop that needed it most.
    (should (equal (cooked-tests--capturing-paste
                     (cooked-dnd--insert "/ssh:jump|ssh:host:/tmp/x.png"))
                   '("/tmp/x.png ")))
    ;; And a local name is used as it stands.
    (should (equal (cooked-tests--capturing-paste
                     (cooked-dnd--insert "/tmp/x.png"))
                   '("/tmp/x.png ")))))

(ert-deftest cooked-dnd-writes-yanked-media-and-types-its-name ()
  "Clipboard bytes become a file, because a name is the only thing that crosses.

Asserts the bytes land unmangled: `yank-media\=' hands over binary, and letting
`coding-system-for-write\=' have an opinion about a PNG corrupts it silently --
the kind of bug that shows up as a viewer refusing the file rather than as an
error here."
  (let ((cooked-dnd-image-directory (make-temp-file "cooked-dnd" t))
        ;; The first bytes of a real PNG, including the \r\n pair the header
        ;; carries specifically to catch mangling.
        (png (string-to-unibyte "\x89PNG\r\n\x1a\n")))
    (unwind-protect
        (with-temp-buffer
          (let* ((typed (car (cooked-tests--capturing-paste
                               (cooked-dnd-yank-media 'image/png png))))
                 (file (string-trim typed)))
            ;; Named for its subtype, which is what makes the result useful: a
            ;; program told to open `x.png' behaves differently from one told to
            ;; open `x'.
            (should (string-suffix-p ".png" file))
            (should (file-exists-p file))
            (with-temp-buffer
              (set-buffer-multibyte nil)
              (let ((coding-system-for-read 'no-conversion))
                (insert-file-contents-literally file))
              (should (equal (buffer-string) png)))))
      (delete-directory cooked-dnd-image-directory t))))

(ert-deftest cooked-dnd-handlers-do-not-answer-for-other-buffers ()
  "`dnd-protocol-alist\=' is global; a cooked handler must not be.

Otherwise a drop on any buffer at all would type a file name into whichever
terminal happened to have been set up last."
  (cooked-tests--with-session '("/bin/sh" "-c" "sleep 5")
    (cooked-dnd-setup)
    (should cooked-dnd--active)
    (should (local-variable-p 'dnd-protocol-alist))
    (should (assoc "^file:" dnd-protocol-alist))
    (should (eq (lookup-key cooked-dnd-map [drag-n-drop]) #'cooked-dnd-drop)))
  (with-temp-buffer
    (should-not cooked-dnd--active)
    (should-not (assoc "^file:" (default-value 'dnd-protocol-alist)))))

(ert-deftest cooked-dnd-answers-a-drop-on-the-mode-line ()
  "Those events arrive under their own prefixes and a mode map never sees them."
  (dolist (prefix '(mode-line header-line left-fringe right-fringe
                              left-margin right-margin))
    (should (eq (lookup-key cooked-dnd-map (vector prefix 'drag-n-drop))
                #'cooked-dnd-drop))))

(provide 'cooked-tests-dnd)
;;; cooked-tests-dnd.el ends here
