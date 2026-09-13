;;; cooked-secret.el --- Collecting a password the child is reading -*- lexical-binding: t; -*-

;;; Commentary:

;; ICANON on with ECHO off is `getpass(3)\=': the child is reading a line and does
;; not want it seen.  cooked answers that in the minibuffer rather than in the
;; buffer, which is what lets the answer come from `auth-source\=' instead of being
;; typed -- and, more to the point, what keeps a typed secret out of the buffer
;; text, the scrollback and the undo history.
;;
;; The prompt is scheduled rather than raised on the spot, because programs
;; disagree about whether they clear ECHO before or after printing the prompt they
;; want answered; see `cooked-secret-debounce\='.  The epoch is what makes a stale
;; answer unsendable when the read it was for has already ended.

;;; Code:

(require 'cooked)

(cooked--declare-core)

(defcustom cooked-password-function nil
  "Function called with the prompt string to supply a password non-interactively.
Should return a string, or nil to fall back to `read-passwd\='.  Lets auth-source
or `pass\=' answer a prompt no ordinary terminal could even detect.

The returned string is not modified: cooked copies it before writing it to the
child and clears only that copy, because a backend is free to return the very
string its own cache holds.  A source that would rather cooked did not keep the
plaintext alive at all can return a `copy-sequence\=' and clear its own.

A single slot, kept for the configuration already using it.
`cooked-password-functions\=' is the composing form and is asked first."
  :type '(choice (const nil) function) :group 'cooked)

(defcustom cooked-password-functions nil
  "Abnormal hook asked for a password, first non-nil answer winning.

Each entry is called with the prompt string, in the session\='s buffer, and
returns the password or nil to let the next one try.  The chain is the point:
auth-source for the hosts it knows, `pass\=' for the rest, and `read-passwd\='
at the tail is what cooked does anyway when every entry declines.

A single =cooked-password-function= cannot compose -- a second source means
writing a dispatcher, and every user who wants two writes the same one.  This is
the seam idiom the rest of cooked uses, and it is asked *before*
`cooked-password-function\=' so an existing configuration keeps working as the
last word rather than the first.

Two things worth knowing before writing an entry. Returning the empty string
counts as an *answer*, not a decline -- some prompts genuinely take one, so
cooked cannot guess, and an entry that means \"I have nothing\" must return
nil. And whatever is returned is copied before it reaches the child and only the
copy is cleared, for the reason `cooked-password-function\=' gives.

Run through `cooked--run-seam-until-success\=', so an entry that signals has
given no answer and the next is asked -- a broken auth-source backend does not
take the prompt down with it."
  :type 'hook :group 'cooked)

(defun cooked--password-from-sources (prompt)
  "Ask every configured source for the password PROMPT wants, or nil.

The chain first, then the single slot: an existing `cooked-password-function\='
keeps working, and keeps its meaning as the answer of last resort rather than
becoming one voice among several."
  (or (cooked--run-seam-until-success 'cooked-password-functions prompt)
      (and cooked-password-function (funcall cooked-password-function prompt))))

(defcustom cooked-secret-debounce 0.03
  "Seconds to wait before prompting for a secret.
Programs differ on whether they clear ECHO before or after printing the prompt;
this lets the prompt text arrive first."
  :type 'number :group 'cooked)

(defvar-local cooked--secret-timer nil)

(defvar-local cooked--secret-read nil
  "The minibuffer of the password read in flight, if there is one.")

(defvar-local cooked--secret-epoch 0
  "Counter bumped every time the child stops asking for a secret.
A read that finishes holding a stale epoch is answering a question nobody
is waiting on any more, and must not touch the child -- see
`cooked--cancel-secret'.")

(defcustom cooked-password-prompt-regexp comint-password-prompt-regexp
  "What a password prompt looks like, for a child the termios probe cannot see.

Only consulted on a *foreign host*, and that gate is the whole of why this is
safe to have at all.

cooked normally detects a password prompt from the terminal itself: the child
puts the tty into canonical mode with echo off, which is what `sudo\\=', `ssh\\='
and `gpg\\=' all do and what no ordinary program does by accident.  That is a
fact, not a guess, and it needs no pattern.

It is also invisible through a *remote* shell.  `ssh host sudo …\\=' puts the
*far* tty into secret mode; the local one this session owns never changes, so
the detector never fires and the password is typed into the buffer in the clear.
A regex is the only thing left, and matching one against every line of local
output would false-positive on `less\=' reading a file that merely mentions
a password -- which is exactly why it is gated rather than merely
lower-priority.

Defaults to `comint-password-prompt-regexp\\=', which Emacs already maintains
for this purpose and which `comint-watch-for-password-prompt\\=' matches
case-insensitively; so does this."
  :type 'regexp :group 'cooked)

(defun cooked--secret-prompt-on-row-p ()
  "Whether the cursor's row looks like a password prompt from a foreign host.

The second arm of the detector, and the only one that can reach a remote
child.  Asked of the *cursor's* row rather than of the whole screen: a prompt is
where the cursor is waiting, and a screenful of a build log mentioning passwords
is not one."
  (and (cooked--foreign-host-p)
       (when-let* ((position (cooked--cursor-position))
                   (case-fold-search t))
         (save-excursion
           (goto-char position)
           (string-match-p cooked-password-prompt-regexp
                           (buffer-substring-no-properties
                            (line-beginning-position) (line-end-position)))))))

(defun cooked--schedule-secret ()
  "Prompt for a secret once the prompt text has had time to arrive.

Not while the user is looking at something else.  `read-passwd\=' takes the
minibuffer of whatever frame is selected, which for a buffer nobody is in means
a masked prompt appearing under the cursor in an unrelated buffer -- and then
the next thing typed there, whatever it was meant for, is sent to this child
followed by a newline.  A password prompt that arrives late is a small thing; a
password prompt that quietly redirects the keys you are already typing is not,
and the second is what this used to do.

So the read is held instead, and `cooked--resume-secret\=' raises it when
attention comes back.  Nothing else is deferred with it: `cooked--mode\=' is
already `secret', the keymap has already been swapped, and the child is
blocked in a `getpass\=' that will wait as long as it takes.

Said out loud rather than held silently, because the buffer is off screen and
the alternative is a session that has stopped for no visible reason.  A message
is the smallest thing that cannot steal a keystroke; a notification is the
better one, and is `cooked-command-finished-functions\=' territory rather than
this function\='s."
  (cooked--cancel-secret)
  (if (eq cooked--attention 'away)
      (message "cooked: %s is asking for a password" (buffer-name))
    (setq cooked--secret-timer
          (run-with-timer cooked-secret-debounce nil
                          (let ((buffer (current-buffer)))
                            (lambda () (cooked--prompt-secret buffer)))))))

(defun cooked--resume-secret ()
  "Raise a secret prompt that was held back while the user was elsewhere.

Called as attention returns, and only then.  Three things have to be true and
each rules out a different way of prompting for nothing: the child must still
be asking, or the prompt would be answered by whatever it is running now; no
timer may be pending, or `cooked--schedule-secret\=' has already been through
here and rescheduling would bump the epoch out from under it; and no read may
be on screen, which is the case of leaving the buffer *while* the minibuffer
was up and coming back to it, where cancelling and re-asking would dismiss a
prompt the user is part-way through answering."
  (when (and cooked--session
             (eq cooked--mode 'secret)
             (not cooked--secret-timer)
             (not cooked--secret-read))
    (cooked--schedule-secret)))

(defun cooked--cancel-secret ()
  "Abandon any pending or on-screen secret prompt.

Called whenever the child stops asking: it left secret mode, it exited, or the
buffer was killed.  The pending timer is the easy half.  The hard half is a
read already on screen -- `sudo\=' interrupted from the terminal window leaves
the minibuffer sitting there, and answering it later would hand a password, or
a `C-c\=', to whatever the child is running by then.  That is not a stale
window; it is the wrong program being killed.

So two things happen.  The epoch moves, which is what makes the read harmless
whatever it does next: `cooked--prompt-secret\=' compares before it sends
anything.  Then the minibuffer is dismissed from a zero-delay timer, because it
is a recursive edit this is not inside -- the timer runs in that recursive
edit\='s command loop, where `abort-recursive-edit\=' has a tag to throw to.  It
is allowed to fail: if the user has since opened a minibuffer of their own on
top of ours, both are left alone and the epoch carries the safety."
  (setq cooked--secret-epoch (1+ cooked--secret-epoch))
  (when cooked--secret-timer
    (cancel-timer cooked--secret-timer)
    (setq cooked--secret-timer nil))
  (when-let* ((minibuffer cooked--secret-read))
    (setq cooked--secret-read nil)
    (run-at-time 0 nil #'cooked--dismiss-secret minibuffer)))

(defun cooked--dismiss-secret (minibuffer)
  "Abort the password read in MINIBUFFER, if it is still the one on screen."
  (when-let* ((window (active-minibuffer-window)))
    (when (eq (window-buffer window) minibuffer)
      (with-selected-window window
        (abort-recursive-edit)))))

(defvar cooked-secret-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'cooked-secret-abort)
    map)
  "Keys layered over the map `read-passwd\=' installs.

`C-c C-c\=' only: the read is a minibuffer, so `C-g\=' already aborts it, but
the prompt on screen is sudo\='s rather than Emacs\=', and the key that gets you
out of a program asking for a password on a terminal is the interrupt.  It is
spelled the same here as in the buffer, where `C-c C-c\=' is
`cooked-interrupt\=', so the answer does not depend on which window point
happens to be in.")

(defun cooked-secret-abort ()
  "Abandon the password read, leaving the child to be interrupted.

Signals quit rather than sending anything itself; `cooked--prompt-secret\=' is
already handling quit by sending the child `C-c\=', and that is the one place
that knows which buffer\='s child is waiting."
  (interactive)
  (abort-minibuffers))

(defun cooked--read-passwd (prompt)
  "Read a secret for PROMPT with `cooked-secret-map\=' in force.

The minibuffer is recorded on the session\='s buffer for as long as the read
lasts, which is what lets `cooked--cancel-secret\=' take it back down when the
child stops asking."
  (let ((buffer (current-buffer)))
    (unwind-protect
        (minibuffer-with-setup-hook
            (lambda ()
              (use-local-map
               (make-composed-keymap cooked-secret-map (current-local-map)))
              (let ((minibuffer (current-buffer)))
                (with-current-buffer buffer (setq cooked--secret-read minibuffer))))
          (read-passwd prompt))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (setq cooked--secret-read nil))))))

(defun cooked--prompt-secret (buffer)
  "Read a secret for BUFFER and send it, without it touching the buffer.

The secret never reaches the buffer, and the copies cooked itself makes
are cleared: it is sent as two writes rather than one `concat', which a
child reading canonically cannot distinguish, and the native core zeroes
its byte buffer after writing.

Only cooked's own copies, though.  A string handed over by
`cooked-password-function' belongs to whoever supplied it -- an
auth-source backend may return the plaintext its cache is holding -- so
zeroing that one would corrupt the cache rather than the secret.  The
copy written to the child is made here for exactly that reason.

That is the honest limit of it.  `read-passwd' builds the string in
Emacs' own heap, the garbage collector relocates and compacts small
strings so earlier copies survive in freed blocks that `clear-string'
never sees, and an auth-source backend caches plaintext by design.
cooked cannot promise a password leaves no trace in Emacs' address
space, and does not."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq cooked--secret-timer nil)
      (when (eq cooked--mode 'secret)
        (let* ((prompt (or (cooked--prompt-text cooked--session) "Password"))
               (prompt (if (string-suffix-p ":" prompt) (concat prompt " ") (concat prompt ": ")))
               ;; Read before the prompt is answered and compared after, in both
               ;; the answered and the quit branch below.
               (epoch cooked--secret-epoch))
          (condition-case nil
              ;; `supplied' is kept separate from `secret' because only one of
              ;; the two is ours to destroy; see the comments on the two
              ;; `clear-string' calls below.
              (let* ((supplied (cooked--password-from-sources prompt))
                     (secret (or supplied (cooked--read-passwd prompt))))
                (unwind-protect
                    ;; The wire copy is freshly allocated here and nothing else
                    ;; can be holding it, so zeroing it is unconditionally safe.
                    ;; Its `unwind-protect' is nested inside the outer one so
                    ;; that a PTY write which throws -- a child that exited
                    ;; between the prompt and the answer is enough -- still
                    ;; clears it on the way out.
                    (let ((wire (copy-sequence secret)))
                      (unwind-protect
                          (if (/= epoch cooked--secret-epoch)
                              (message "Nothing is asking for that any more; not sent")
                            (cooked--send-to-child wire)
                            (cooked--send-to-child "\n"))
                        (clear-string wire)))
                  ;; What `read-passwd' returns was allocated for this call and
                  ;; nobody else has a reference, so it is ours to zero.  What
                  ;; `cooked-password-function' returns is not: an auth-source
                  ;; backend caches plaintext by design and may hand out the very
                  ;; string sitting in that cache, so zeroing it corrupts the
                  ;; cache in place and the next lookup answers with NULs.
                  (unless supplied (clear-string secret))))
            ;; C-g or C-c C-c at the prompt should interrupt the child's read
            ;; rather than leave it blocked on a `getpass' nobody is going to
            ;; answer -- but only while it is still that read we would be
            ;; interrupting.  A prompt the child abandoned on its own leaves a
            ;; minibuffer that outlives it, and sending the interrupt anyway is
            ;; how quitting a dead password prompt kills the command typed after
            ;; it.
            (quit
             (when (= epoch cooked--secret-epoch)
               (cooked--send-if-live "\C-c"))
             (signal 'quit nil))))))))

(defun cooked--check-secret-prompt ()
  "Arm the secret read for a prompt only the regex arm can see.

The termios detector fires from `cooked--set-mode\=', on a *change* of what the
local tty is doing.  A remote child changes the far tty and the local one never
moves, so that path is never reached and there is no state transition to hang
this off -- the question has to be asked per drain instead.

Cheap where it does not apply, which is the point of the ordering:
`cooked--secret-prompt-on-row-p\=' asks `cooked--foreign-host-p\=' first, so a
local session pays one string comparison and no regexp at all.  Nothing is armed
while a read is already in flight, or while the tty *has* gone into secret mode
and the first arm has it."
  (when (and cooked--session
             (not (eq cooked--mode 'secret))
             (not cooked--secret-read)
             (cooked--secret-prompt-on-row-p))
    (cooked--schedule-secret)))

(provide 'cooked-secret)
;;; cooked-secret.el ends here
