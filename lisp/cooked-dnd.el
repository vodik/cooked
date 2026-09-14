;;; cooked-dnd.el --- drop files and images into a cooked buffer -*- lexical-binding: t; -*-

;;; Commentary:

;; Opt-in:
;;
;;   (use-package cooked
;;     :commands (cooked cooked-other-window)
;;     :config (require 'cooked-dnd))
;;
;; Drag a file onto a cooked buffer and its name is typed at the prompt, shell-quoted.
;; Yank an image from the clipboard with `yank-media' and the same thing happens, by way
;; of a temp file.
;;
;; The insight the whole file rests on: *a PTY has no inbound channel for a file*.  Emacs
;; has the bytes -- a PNG on the clipboard, a path from the window system -- and the
;; child has a byte stream that only carries what a keyboard could have typed.  So the
;; only thing that can cross is a *name*, and anything that is not already a file on disk
;; has to become one first.  That is not a limitation being worked around; it is what
;; dropping a file on a terminal has always meant, and it is why this is forty lines
;; rather than a subsystem.
;;
;; Every port delivers a drop on the text area through `dnd-protocol-alist', which
;; is why a buffer-local entry there is the whole of the ordinary case:
;;
;;   * X11, pgtk and haiku handle their drop events in `special-event-map' and
;;     dispatch file URLs through the alist.
;;   * NS and w32 bind a `[drag-n-drop]' event globally, to `ns-drag-n-drop' and
;;     `w32-drag-n-drop', and both end in `dnd-handle-multiple-urls', which
;;     consults the alist of the drop window's buffer.
;;
;; A drop on the *mode line*, a fringe or a margin is the exception.  On NS and w32
;; those events arrive under their own prefixes -- `[mode-line drag-n-drop]' and
;; friends -- which nothing binds globally, so the drop would be ignored.  An
;; emulation keymap answers them, since a drop on a terminal's mode line is plainly
;; meant for that terminal.  The plain `[drag-n-drop]' is deliberately left to the
;; port: binding it here would replace a handler that works with a second parser of
;; the same payload.
;;
;; What is deliberately *not* here: any attempt to send the file's contents.  A drop is a
;; name, always.  If you want the bytes on the far end you have a shell in front of you
;; and it already knows how to do that.

;;; Code:

(require 'dnd)
(require 'yank-media)
(require 'cooked-util)
(require 'cooked-keys)
(require 'cooked-pending)

(defgroup cooked-dnd nil
  "Dropping files and images into a terminal."
  :group 'cooked)

(defcustom cooked-dnd-image-directory nil
  "Where `yank-media\=' writes the image whose name is typed, or nil.

nil means the temporary directory of the host the shell runs on, asked of the
function `temporary-file-directory\=' when the image is yanked.  In a session
whose `default-directory\=' is /ssh:host:/srv/ that is /ssh:host:/tmp/, so
the file is written through TRAMP and the remote shell is given
/tmp/cooked-XXXX.png, which exists there.  The variable of the same name is
always local, and a local path typed to a remote shell names nothing.

A directory is used as it is.  Point it somewhere durable if you would rather
the images accumulated."
  :type '(choice (const :tag "The session host's temporary directory" nil)
                 directory)
  :group 'cooked-dnd)

(defun cooked-dnd--quote (file)
  "FILE\='s name as the shell running in this buffer should see it, quoted.

`file-remote-p ... \='localname\=' is what makes a TRAMP name right.  When
`default-directory\=' is remote the child is running on the far host, so the
name it needs is the path there: /ssh:host:/tmp/x.png means nothing to a shell
on host, while /tmp/x.png is exactly right.  A local name is used as it stands.

A file on a different host from the shell\='s is refused with a `user-error\='
rather than typed.  Dropping ~/notes.txt on a session whose `default-directory\='
is /ssh:host:/srv/ would type /home/me/notes.txt to a shell on host, where it
names nothing or, worse, a different file.  Copying the file there through TRAMP
would make the name true, but it is a transfer of unbounded size started by a
drag, and a session started over ssh by `cooked--remote-invocation\=' changes
nothing about that: the copy would go through TRAMP either way."
  (let ((host (file-remote-p default-directory 'host)))
    (unless (equal (file-remote-p file 'host) host)
      (user-error "cooked: %s is not on %s, where the shell runs; copy it there"
                  file (or host "this machine"))))
  (shell-quote-argument (or (file-remote-p file 'localname) file)))

(defun cooked-dnd--insert (files)
  "Type the names of FILES, a list, shell-quoted and separated by spaces.

Through `cooked--deliver-paste\=', and so through `cooked--send-paste\=' when
the child owns the line, because a file name is attacker-controlled far more
often than a paste is.  A name can contain ESC as easily as a space, and
`shell-quote-argument\=' protects the shell from it but not the terminal; the
paste path\='s control-byte strip does that, and at a prompt the name is marked
as pasted so the same strip applies when the line is submitted.

A trailing space, because the common case is a name being added to a command
that is still being typed."
  (cooked--deliver-paste
   (concat (mapconcat #'cooked-dnd--quote files " ") " ")))

(defun cooked-dnd-handle-url (url action)
  "Type the file URL names, for `dnd-protocol-alist\='.

Returns `private\=', which is dnd\='s way of saying the drop was consumed and no
copy or move should be attempted: nothing was moved anywhere, a name was typed.

Once the child has exited there is no line to type on, so the file is visited
with `dnd-open-local-file\=' and ACTION, as a drop on any other buffer would."
  (when-let* ((file (dnd-get-local-file-name url t)))
    (if (cooked--live-session)
        (progn (cooked-dnd--insert (list file)) 'private)
      (dnd-open-local-file url action))))

(defun cooked-dnd--payload (arg)
  "What the `drag-n-drop\=' event argument ARG carries, as (KIND . VALUE).

KIND is `files\=' with a list of file names, `text\=' with a string, or nil
for an event that is not a drop.  ARG is the third element of the event, and
its shape is the port\='s own.

On NS, `ns-drag-n-drop\=' in term/ns-win.el reads it as (TYPE OPERATIONS .
OBJECTS), which nsterm.m builds in performDragOperation.  TYPE is `file\=' for
file names, `url\=' for URLs and nil for text, so a Finder drop of two files is
\\(file (ns-drag-operation-copy) \"/Users/me/a.png\" \"/Users/me/b.png\").
While the drag is still moving over the frame ARG is the symbol `lambda\='.

On w32, `w32-drag-n-drop\=' in term/w32-win.el reads it as a list of file
names for a file drop, a string for a text drop, and nil while the drag is
moving; w32term.c builds it from the WM_EMACS_DROP message.

A `file:\=' URL on NS is taken as the file it names, and any other URL as text."
  (pcase arg
    ((or 'nil 'lambda) nil)
    ((pred stringp) (cons 'text arg))
    (`(file ,_operations . ,objects) (cons 'files objects))
    (`(url ,_operations . ,objects)
     (let ((files (delq nil (mapcar (lambda (url) (dnd-get-local-file-name url t))
                                    objects))))
       (if (= (length files) (length objects))
           (cons 'files files)
         (cons 'text (mapconcat #'identity objects "\n")))))
    (`(nil ,_operations . ,objects)
     (cons 'text (mapconcat #'identity objects "\n")))
    ((pred (lambda (arg) (and (consp arg) (seq-every-p #'stringp arg))))
     (cons 'files arg))))

(defun cooked-dnd-drop (event)
  "Handle a drop EVENT on a cooked buffer\='s mode line, fringe or margin.

Those drops arrive as `drag-n-drop\=' events under an area prefix, which the
ports' own handlers are not bound to; see this file\='s Commentary.  The
event\='s payload is parsed by `cooked-dnd--payload\=', whose docstring gives
the NS and w32 shapes.  Files have their names typed and text is delivered as it
is, in the buffer of the window the drop landed on rather than whichever buffer
is current.  An event that is only a drag moving across the frame does nothing."
  (interactive "e")
  (when-let* ((payload (cooked-dnd--payload (nth 2 event))))
    (let ((window (posn-window (nth 1 event))))
      (with-current-buffer (if (windowp window) (window-buffer window) (current-buffer))
        (pcase-exhaustive payload
          (`(files . ,files) (cooked-dnd--insert files))
          (`(text . ,text) (cooked--deliver-paste text)))))))

(defun cooked-dnd-yank-media (type data)
  "Write DATA, an image of mime TYPE, to a file and type its name.

`yank-media\=' hands over the *bytes* of an image on the clipboard, and there is
nowhere to put bytes on a PTY -- see this file's Commentary.  So they become a
file, and the file's name is what crosses.

The extension is taken from the mime subtype, which is what makes the result
useful: a program told to open `x.png\=' behaves differently from one told to
open `x\=', and the subtype is the only thing here that knows which it is.

The file is written on the host the shell runs on; see
`cooked-dnd-image-directory\='."
  (unless (cooked--live-session)
    (user-error "No live session"))
  (let* ((extension (replace-regexp-in-string "\\`.*/" "" (symbol-name type)))
         (directory (or cooked-dnd-image-directory (temporary-file-directory)))
         (file (make-temp-file (expand-file-name "cooked-" directory)
                               nil (concat "." extension))))
    ;; `no-conversion' both ways: this is a PNG, not text, and letting
    ;; `coding-system-for-write' have an opinion about it corrupts it silently.
    (let ((coding-system-for-write 'no-conversion))
      (with-temp-file file (set-buffer-multibyte nil) (insert data)))
    (cooked-dnd--insert (list file))))

(defvar-keymap cooked-dnd-map
  :doc "The area prefixes a drop can arrive under, bound to `cooked-dnd-drop\='.

The mode line, the header line, the fringes and the margins deliver their
events under their own prefixes, such as [mode-line drag-n-drop], and nothing
binds those globally.  The plain `[drag-n-drop]\=' is not here: on NS and w32
its global binding already reaches `cooked-dnd-handle-url\=' through
`dnd-protocol-alist\='.

An emulation keymap rather than bindings in `cooked-mode-map\=', because this is
an optional layer: writing into the mode map at load time would turn the feature
on for every cooked buffer, including ones made before the file was loaded, and
`local-set-key\=' mutates `current-local-map\=', which for a derived mode is
the shared mode map.  A buffer-local flag gating an emulation entry keeps the
layer per-buffer, which is what the rest of cooked\='s optional layers do."
  "<mode-line> <drag-n-drop>"    #'cooked-dnd-drop
  "<header-line> <drag-n-drop>"  #'cooked-dnd-drop
  "<left-fringe> <drag-n-drop>"  #'cooked-dnd-drop
  "<right-fringe> <drag-n-drop>" #'cooked-dnd-drop
  "<left-margin> <drag-n-drop>"  #'cooked-dnd-drop
  "<right-margin> <drag-n-drop>" #'cooked-dnd-drop)

(defvar cooked-dnd--emulation-alist
  (list (cons 'cooked-dnd--active cooked-dnd-map))
  "`emulation-mode-map-alists\=' entry, live only where the flag is set.")

(defvar-local cooked-dnd--active nil
  "Whether `cooked-dnd-map\=' applies to this buffer.")

(defun cooked-dnd-setup ()
  "Install the drop handlers in this buffer.

Buffer-locally throughout, which is the point of the layer being loadable at
all: `dnd-protocol-alist\=' and `yank-media\='s handler table are global, and a
cooked handler answering for some other buffer would type a file name into
whatever happened to be there."
  (setq cooked-dnd--active t)
  (setq-local dnd-protocol-alist
              (cons (cons "^file:" #'cooked-dnd-handle-url) dnd-protocol-alist))
  (add-to-list 'emulation-mode-map-alists 'cooked-dnd--emulation-alist)
  ;; Every raster type Emacs is likely to be handed from a clipboard.  SVG is
  ;; deliberately included: it is a file with a name like any other, and what the
  ;; child does with it is the child's business.
  (yank-media-handler "image/.*" #'cooked-dnd-yank-media))

;; The file being loaded *is* the feature being on, on the model of
;; `cooked-osc-eval.el' and `cooked-shell-completion.el' -- so the hook is added here
;; rather than left for the user to add, and buffers made from now on have it.
(add-hook 'cooked-mode-hook #'cooked-dnd-setup)

(provide 'cooked-dnd)
;;; cooked-dnd.el ends here
