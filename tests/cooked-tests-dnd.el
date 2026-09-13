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

The session is taken to be live with the child owning the line, which is the
state a drop is pasted in.  The child is not involved: what is under test is the text handed to the paste
path, and going as far as the PTY would only add a round trip to read it back
out of the grid."
  (declare (indent 0))
  `(let ((pasted nil))
     (cl-letf (((symbol-function 'cooked--send-paste)
                (lambda (text) (push text pasted)))
               ((symbol-function 'cooked--live-session) (lambda () t))
               ((symbol-function 'cooked--input-state-p) #'ignore))
       ,@body
       (nreverse pasted))))

(ert-deftest cooked-dnd-types-a-dropped-name-shell-quoted ()
  "A name with a space in it must arrive as one argument."
  (with-temp-buffer
    (should (equal (cooked-tests--capturing-paste
                     (cooked-dnd--insert (list "/tmp/two words.png")))
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
                          (cooked-dnd--insert (list name))))))
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
                     (cooked-dnd--insert (list "/ssh:host:/tmp/x.png")))
                   '("/tmp/x.png ")))
    ;; A multi-hop name resolves to the same localname, so the feature does not
    ;; quietly stop working on the hop that needed it most.
    (should (equal (cooked-tests--capturing-paste
                     (cooked-dnd--insert (list "/ssh:jump|ssh:host:/tmp/x.png")))
                   '("/tmp/x.png ")))
    ;; And a local name is used as it stands.
    (should (equal (cooked-tests--capturing-paste
                     (cooked-dnd--insert (list "/tmp/x.png")))
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
    ;; The plain event is the port's own; see
    ;; `cooked-dnd-leaves-the-text-area-drop-to-the-port'.
    (should-not (lookup-key cooked-dnd-map [drag-n-drop])))
  (with-temp-buffer
    (should-not cooked-dnd--active)
    (should-not (assoc "^file:" (default-value 'dnd-protocol-alist)))))

(ert-deftest cooked-dnd-answers-a-drop-on-the-mode-line ()
  "Those events arrive under their own prefixes and a mode map never sees them."
  (dolist (prefix '(mode-line header-line left-fringe right-fringe
                              left-margin right-margin))
    (should (eq (lookup-key cooked-dnd-map (vector prefix 'drag-n-drop))
                #'cooked-dnd-drop))))

(defun cooked-tests--drop-event (area arg)
  "A `drag-n-drop' event carrying ARG, landing in AREA of the selected window.

The shape is what keyboard.c's `make_lispy_event' gives a DRAG_N_DROP_EVENT:
(drag-n-drop POSITION ARG).  POSITION is built as `posn-at-x-y' would build it
for a click in AREA, which is enough for `posn-window' and `posn-area'.  ARG is
the port's own payload; see `cooked-dnd--payload'."
  (list 'drag-n-drop
        (list (selected-window) area '(0 . 0) 0 nil nil '(0 . 0) nil '(0 . 0) '(1 . 1))
        arg))

(defmacro cooked-tests--with-dnd-session (&rest body)
  "Run BODY in a live session with the dnd layer on, shown in the selected window.

The child owns the line, so a drop is pasted; `cooked--send-paste' records into
`pasted' rather than writing."
  (declare (indent 0))
  `(cooked-tests--with-echoing-child ""
     (cooked-dnd-setup)
     (set-window-buffer (selected-window) (current-buffer))
     (let ((pasted nil))
       (cl-letf (((symbol-function 'cooked--send-paste)
                  (lambda (text) (push text pasted))))
         ,@body))))

(ert-deftest cooked-dnd-parses-an-ns-drop-on-the-mode-line ()
  "Every NS payload shape reaches the right delivery, and a hover does nothing.

The shapes are nsterm.m's, as `ns-drag-n-drop' in term/ns-win.el reads them:
the argument is (TYPE OPERATIONS . OBJECTS), with TYPE `file' for Finder files,
`url' for a URL and nil for text, and the bare symbol `lambda' while the drag
is only moving.  The old handler looped over the argument as a list of names,
so the symbol `file' went to `shell-quote-argument' and signalled."
  (cooked-tests--with-dnd-session
    (should (eq (key-binding [mode-line drag-n-drop]) #'cooked-dnd-drop))
    (cooked-dnd-drop (cooked-tests--drop-event
                      'mode-line
                      '(file (ns-drag-operation-copy ns-drag-operation-generic)
                             "/Users/me/two words.png" "/Users/me/b.txt")))
    (should (equal pasted '("/Users/me/two\\ words.png /Users/me/b.txt ")))
    (setq pasted nil)
    (cooked-dnd-drop (cooked-tests--drop-event
                      'left-fringe '(nil (ns-drag-operation-copy) "echo hi")))
    (should (equal pasted '("echo hi")))
    (setq pasted nil)
    (let ((file (make-temp-file "cooked-dnd")))
      (unwind-protect
          (progn
            (cooked-dnd-drop (cooked-tests--drop-event
                              'mode-line
                              `(url (ns-drag-operation-copy) ,(concat "file://" file))))
            (should (equal pasted (list (concat file " ")))))
        (delete-file file)))
    (setq pasted nil)
    (cooked-dnd-drop (cooked-tests--drop-event
                      'mode-line '(url (ns-drag-operation-copy) "https://example.com/")))
    (should (equal pasted '("https://example.com/")))
    (setq pasted nil)
    (cooked-dnd-drop (cooked-tests--drop-event 'mode-line 'lambda))
    (should-not pasted)))

(ert-deftest cooked-dnd-parses-a-w32-drop-on-the-mode-line ()
  "A w32 text drop is a string, a file drop a list of names, a hover nil.

Those are the three shapes `w32-drag-n-drop' in term/w32-win.el tells apart,
and w32term.c builds from WM_EMACS_DROP and WM_EMACS_DRAGOVER.  The old handler
took `car' of the string and signalled."
  (cooked-tests--with-dnd-session
    (cooked-dnd-drop (cooked-tests--drop-event 'header-line "some text"))
    (should (equal pasted '("some text")))
    (setq pasted nil)
    (cooked-dnd-drop (cooked-tests--drop-event 'right-margin '("/c/Users/me/a.png")))
    (should (equal pasted '("/c/Users/me/a.png ")))
    (setq pasted nil)
    (cooked-dnd-drop (cooked-tests--drop-event 'mode-line nil))
    (should-not pasted)))

(ert-deftest cooked-dnd-leaves-the-text-area-drop-to-the-port ()
  "A drop on the text reaches the handler through the port's own dispatch.

`ns-drag-n-drop' and `w32-drag-n-drop' both turn a file drop into file: URLs
and hand them to `dnd-handle-multiple-urls' in the drop window, which reads
that buffer's `dnd-protocol-alist'.  Neither port file loads on this machine,
so the test starts at that shared last step.  With the plain event unbound in
`cooked-dnd-map', the global handler is the one that runs."
  (cooked-tests--with-dnd-session
    (should-not (eq (key-binding [drag-n-drop]) #'cooked-dnd-drop))
    (let ((file (make-temp-file "cooked-dnd")))
      (unwind-protect
          (with-temp-buffer
            (dnd-handle-multiple-urls (selected-window)
                                      (list (concat "file:" file)) 'private))
        (delete-file file))
      (should (equal pasted (list (concat file " ")))))))

(ert-deftest cooked-dnd-inserts-at-a-prompt-emacs-owns ()
  "At a prompt Emacs is editing, a dropped name joins the pending input.

Pasting it to the child instead typed it underneath the line Emacs shows, and
RET then submitted both."
  (cooked-tests--with-session '("/bin/sh" "-c" "printf '$ '; cat")
    (should (cooked-tests--settle
             (lambda () (and (cooked--input-state-p) (cooked--input-start-position)))))
    (cooked-dnd-setup)
    (let (pasted)
      (cl-letf (((symbol-function 'cooked--send-paste)
                 (lambda (text) (push text pasted))))
        (cooked-dnd--insert (list "/tmp/two words.png")))
      (should-not pasted))
    (should (equal (cooked--pending-input) "/tmp/two\\ words.png "))))

(ert-deftest cooked-dnd-opens-the-file-once-the-child-has-exited ()
  "With no child to type to, a drop visits the file as it would elsewhere."
  (cooked-tests--with-session '("/bin/sh" "-c" "exit 0")
    (should (cooked-tests--settle (lambda () (not (cooked--live-session)))))
    (cooked-dnd-setup)
    (let ((url (concat "file:" (make-temp-file "cooked-dnd")))
          (opened nil))
      (unwind-protect
          (cl-letf (((symbol-function 'dnd-open-local-file)
                     (lambda (url action) (push url opened) action)))
            (should (eq (cooked-dnd-handle-url url 'copy) 'copy)))
        (delete-file (dnd-get-local-file-name url)))
      (should (equal opened (list url))))
    (should-error (cooked-dnd-yank-media 'image/png "x") :type 'user-error)))

(ert-deftest cooked-dnd-writes-yanked-media-on-the-remote-host ()
  "Over TRAMP the image is written through TRAMP, and its remote name is typed.

`cooked-dnd-image-directory' used to default to the variable
`temporary-file-directory', which is always local, so a remote shell was handed
a /tmp path that did not exist on its host.  The function of that name answers
for `default-directory', and the write goes through the TRAMP handler."
  (cooked-tests--with-mock-tramp remote
    ;; The option is left at its default, which is the thing under test.
    (let ((default-directory remote)
          (written nil)
          (write-region (symbol-function 'write-region)))
      (cl-letf (((symbol-function 'write-region)
                 (lambda (start end file &rest rest)
                   (push file written)
                   (apply write-region start end file rest))))
        (let* ((typed (car (cooked-tests--capturing-paste
                             (cooked-dnd-yank-media 'image/png "png"))))
               (name (string-trim typed)))
          (should (seq-some #'file-remote-p written))
          (should-not (file-remote-p name))
          (should (string-prefix-p "cooked-" (file-name-nondirectory name)))
          (delete-file (concat (file-remote-p remote) name)))))))

(provide 'cooked-tests-dnd)
;;; cooked-tests-dnd.el ends here
