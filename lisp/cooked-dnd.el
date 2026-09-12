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
;; Two delivery paths, because the Emacs ports genuinely disagree about how a drop
;; arrives, and neither is a fallback for the other:
;;
;;   * X11 and pgtk deliver a drop through `dnd-protocol-alist', keyed on the URL scheme.
;;   * NS and w32 deliver it as a `[drag-n-drop]' *event*, which never reaches
;;     `dnd-protocol-alist' at all.
;;
;; Both are installed unconditionally rather than chosen by `window-system'.  The one
;; that does not apply on a given port is never consulted, and an Emacs that can be
;; started with `-nw' on one machine and pgtk on another should not need the layer
;; reloaded in between.
;;
;; Plus an emulation keymap, for the drop that lands on the *mode line* or the *fringe*
;; rather than on the text.  Those are separate event prefixes -- `[mode-line
;; drag-n-drop]' and friends -- and a binding in the major-mode map does not see them.  A
;; drop on the mode line of a terminal is plainly meant for that terminal, so it is
;; answered rather than ignored.
;;
;; What is deliberately *not* here: any attempt to send the file's contents.  A drop is a
;; name, always.  If you want the bytes on the far end you have a shell in front of you
;; and it already knows how to do that.

;;; Code:

(require 'dnd)
(require 'yank-media)
(require 'cooked-util)
(require 'cooked-keys)

(declare-function cooked--send-paste "cooked-keys")

(defgroup cooked-dnd nil
  "Dropping files and images into a terminal."
  :group 'cooked)

(defcustom cooked-dnd-image-directory temporary-file-directory
  "Where `yank-media\=' and a dropped image write the file whose name is typed.

`temporary-file-directory\=' because the file exists to have a name, and the
name is being handed to a program that will read it and be done.  Point it
somewhere durable if you would rather the drops accumulated."
  :type 'directory
  :group 'cooked-dnd)

(defun cooked-dnd--insert (file)
  "Type FILE's name at the prompt, shell-quoted, as if it had been pasted.

Through `cooked--send-paste\=' rather than `cooked--send-to-child\=' so a drop
is subject to exactly the hygiene a paste is -- the control-byte strip in
particular, which matters here because a file name is attacker-controlled far
more often than a paste is: a name can contain ESC as easily as it can contain a
space, and `shell-quote-argument\=' protects the *shell* from it, not the
terminal.

`file-remote-p ... \\='localname\\=' is what makes this correct over TRAMP for
free, and it is the whole of the remote story.  When `default-directory\=' is
remote the child is running on the far host, so the name it needs is the path
*there* -- `/ssh:host:/tmp/x.png\\=' means nothing to a shell on host, while
`/tmp/x.png\\=' is exactly right.  When it is local the call returns nil and the
name is used as it stands.

A trailing space, because the overwhelmingly common case is a name being added
to a command that is still being typed."
  (let ((name (or (file-remote-p file 'localname) file)))
    (cooked--send-paste (concat (shell-quote-argument name) " "))))

(defun cooked-dnd-handle-url (url _action)
  "Type the file URL names, for `dnd-protocol-alist\='.

Returns `private\=', which is dnd's way of saying the drop was consumed and no
copy or move should be attempted: nothing was moved anywhere, a name was typed."
  (when-let* ((file (dnd-get-local-file-name url t)))
    (cooked-dnd--insert file)
    'private))

(defun cooked-dnd-drop (event)
  "Handle a `[drag-n-drop]\=' EVENT, which is how NS and w32 deliver a drop.

The event carries a list of file names rather than a URL, so it cannot go
through `dnd-protocol-alist\=' and has to be bound as a command.  Point is moved
to the drop position first for the same reason any mouse command does it -- and
then immediately overridden by `cooked--snap-to-cursor\=' inside the paste,
because what a terminal does with typed text does not depend on where you
dropped it.  Moving point anyway keeps the event handled the way Emacs expects."
  (interactive "e")
  (when-let* ((posn (event-start event)))
    (when (posn-point posn) (posn-set-point posn)))
  (dolist (file (car (cdr (cdr event))))
    (cooked-dnd--insert file)))

(defun cooked-dnd-yank-media (type data)
  "Write DATA, an image of mime TYPE, to a file and type its name.

`yank-media\=' hands over the *bytes* of an image on the clipboard, and there is
nowhere to put bytes on a PTY -- see this file's Commentary.  So they become a
file, and the file's name is what crosses.

The extension is taken from the mime subtype, which is what makes the result
useful: a program told to open `x.png\=' behaves differently from one told to
open `x\=', and the subtype is the only thing here that knows which it is."
  (let* ((extension (replace-regexp-in-string "\\`.*/" "" (symbol-name type)))
         (file (make-temp-file (expand-file-name "cooked-" cooked-dnd-image-directory)
                               nil (concat "." extension))))
    ;; `no-conversion' both ways: this is a PNG, not text, and letting
    ;; `coding-system-for-write' have an opinion about it corrupts it silently.
    (let ((coding-system-for-write 'no-conversion))
      (with-temp-file file (set-buffer-multibyte nil) (insert data)))
    (cooked-dnd--insert file)))

(defvar-keymap cooked-dnd-map
  :doc "Every prefix a drop can arrive under, bound to the same command.

An emulation keymap rather than bindings in `cooked-mode-map\=', for two
separate reasons that happen to have one answer.

The mode line, the fringes and the margins deliver their events under their own
prefixes, and a binding in the major-mode map never sees them -- so they need
naming whatever mechanism is used.  A drop on the mode line of a terminal buffer
is unambiguously meant for that terminal, so it is answered rather than ignored.

And the *plain* `[drag-n-drop]\=' cannot go in `cooked-mode-map\=' either,
because this is an optional layer: writing into the mode map at load time would
turn the feature on for every cooked buffer including ones made before the file
was loaded, and `local-set-key\=' -- the obvious alternative -- mutates
`current-local-map\=', which for a derived mode *is* the shared mode map.  A
buffer-local flag gating an emulation entry keeps the layer per-buffer, which is
what the rest of cooked's optional layers do."
  "<drag-n-drop>"                #'cooked-dnd-drop
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
