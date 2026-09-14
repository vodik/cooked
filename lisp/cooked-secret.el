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

(require 'comint)
(require 'cooked-util)
(require 'cooked-state)
(require 'cooked-screen)

(cooked--declare-core)

(declare-function cooked--resample-mode "cooked-mode")

(defcustom cooked-password-function nil
  "Function called with the prompt string to supply a password non-interactively.
Should return a string, or nil to fall back to `read-passwd'.  Lets auth-source
or `pass' answer a prompt no ordinary terminal could even detect.

The returned string is not modified: cooked copies it before writing it to the
child and clears only that copy, because a backend is free to return the very
string its own cache holds.  A source that would rather cooked did not keep the
plaintext alive at all can return a `copy-sequence' and clear its own.

A single slot, kept for the configuration already using it.
`cooked-password-functions' is the composing form and is asked first."
  :type '(choice (const nil) function) :group 'cooked)

(defcustom cooked-password-functions nil
  "Abnormal hook asked for a password, first non-nil answer winning.

Each entry is called with the prompt string, in the session's buffer, and
returns the password or nil to let the next one try.  The chain is the point:
auth-source for the hosts it knows, `pass' for the rest, and `read-passwd'
at the tail is what cooked does anyway when every entry declines.

A single `cooked-password-function' cannot compose -- a second source means
writing a dispatcher, and every user who wants two writes the same one.  This is
the seam idiom the rest of cooked uses, and it is asked *before*
`cooked-password-function' so an existing configuration keeps working as the
last word rather than the first.

Two things worth knowing before writing an entry. Returning the empty string
counts as an *answer*, not a decline -- some prompts genuinely take one, so
cooked cannot guess, and an entry that means \"I have nothing\" must return
nil. And whatever is returned is copied before it reaches the child and only the
copy is cleared, for the reason `cooked-password-function' gives.

Run through `cooked--run-seam-until-success', so an entry that signals has
given no answer and the next is asked -- a broken auth-source backend does not
take the prompt down with it."
  :type 'hook :group 'cooked)

(defun cooked--password-from-sources (prompt)
  "Ask every configured source for the password PROMPT wants, or nil.

The chain first, then the single slot: an existing `cooked-password-function'
keeps working, and keeps its meaning as the answer of last resort rather than
becoming one voice among several.

An answer that is a function is called for the string.  That is auth-source's
own convention -- the `:secret' of what `auth-source-search' finds is a
closure, so that the plaintext is not lying about in the result -- and a source
written as (plist-get (car (auth-source-search ...)) :secret) returns it as it
stands.  It used to reach `copy-sequence', which signals on a function, and
only quit was handled, so the child was left blocked on a read nobody would
answer.  Any other answer that is not a string is dropped with a message and
`read-passwd' asks instead, which leaves the child with something to wait for."
  (let ((answer (or (cooked--run-seam-until-success 'cooked-password-functions prompt)
                    (and cooked-password-function
                         (funcall cooked-password-function prompt)))))
    (when (functionp answer)
      (setq answer (funcall answer)))
    (if (or (null answer) (stringp answer))
        answer
      (message "cooked: a password source answered with a %s, not a string"
               (type-of answer))
      nil)))

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

(defvar-local cooked--secret-asking nil
  "Which detector is asking for the secret being collected, or nil.

`termios' from the moment the tty goes into secret mode, `regex' from the
drain whose cursor row first looks like a remote password prompt, and nil again
once the read returns or the child stops asking.  It covers the whole of one
prompt -- the debounce, a read held while the user is elsewhere, and the read
itself -- which is what makes the regex arm fire on a rising edge: a row that
goes on matching for fifty drains is asked about once, not fifty times.")

(defvar-local cooked--secret-answered nil
  "The (ROW . COL) screen cell the cursor was on when the last read returned.

A remote child goes on showing its prompt after it has been answered, for as
long as the round trip takes: `sudo' at the far end of an `ssh' prints the
newline that moves the cursor off `[sudo] password for simon: ' only once the
password has crossed the network and been read.  Every drain in that window
would look like a fresh prompt to the regex arm, and a second read answered
there sends the password to whatever reads the line after it -- the remote
shell, which echoes it.  So the cell is remembered, and the regex arm stays
quiet while the cursor is still on it.

The same wait follows a password the *termios* arm collected, which is why both
arms set this.  The prompt `ssh' prints for its own password is read with
echo off, and once it is answered `ssh' puts the local tty into raw mode while
that prompt is still on the row and still matches.

Forgotten as soon as the row stops matching, and whenever a drain scrolls: the
cell is a screen coordinate, and a scroll puts a different line under it.  That
second reset is what lets a retry at the bottom of the screen through, where
`Sorry, try again.' and the next prompt can arrive in one drain and leave the
cursor on exactly the cell it was on before.")

(defcustom cooked-password-remote-programs '("ssh" "mosh-client")
  "Programs that carry a password prompt from a tty cooked cannot see.

While one of these is in the foreground, the cursor row is matched against
`cooked-password-prompt-regexp'.  `ssh -t host sudo …' needs this: `sudo'
turns echo off on the far tty, the local one stays in the raw mode `ssh' put
it in, and no shell on the far end sends the OSC 7 that would mark the host as
foreign.

Names are compared against the foreground process group's `comm', as
`cooked--foreground-program' reports it.  Add `docker', `kubectl' or
`tmux' to catch prompts inside those too, at the cost of matching the row
while they run a pager or an editor that shows a line ending in `Password:'."
  :type '(repeat string) :group 'cooked)

(defcustom cooked-password-prompt-regexp comint-password-prompt-regexp
  "What a password prompt looks like, for a child the termios probe cannot see.

Only consulted for a remote child: a *foreign host*, or one of
`cooked-password-remote-programs' in the foreground.  That gate is the whole of
why this is safe to have at all.

cooked normally detects a password prompt from the terminal itself: the child
puts the tty into canonical mode with echo off, which is what `sudo\\=', `ssh\\='
and `gpg\\=' all do and what no ordinary program does by accident.  That is a
fact, not a guess, and it needs no pattern.

It is also invisible through a *remote* shell.  `ssh -t host sudo …\\=' puts
the *far* tty into secret mode; the local one this session owns never changes,
so the detector never fires and the password is typed into the buffer in the
clear.
A regex is the only thing left, and matching one against every line of local
output would false-positive on `less' reading a file that merely mentions
a password -- which is exactly why it is gated rather than merely
lower-priority.

Defaults to `comint-password-prompt-regexp\\=', which Emacs already maintains
for this purpose and which `comint-watch-for-password-prompt\\=' matches
case-insensitively; so does this."
  :type 'regexp :group 'cooked)

(defun cooked--remote-child-p ()
  "Whether what the child is running reads from a tty cooked cannot sample.

Two ways to know it, because they fail in different places.  A foreign host
from OSC 7 covers a shell at the far end that runs cooked's integration, and
keeps covering it through `sudo -i' or a nested shell whose name says nothing.
A remote client in the foreground covers `ssh -t host sudo apt upgrade', where
nothing at the far end speaks OSC 7 and the only local evidence is that
`ssh' is running.

A local `sudo' in a trusted shell passes neither, and that matters: it is the
termios arm's case, and a regex match on the same
`[sudo] password for simon: ' row would otherwise ask for the password a
second time.

The host is asked first, being a string comparison; the foreground program
costs a `tcgetpgrp' per drain, and a `process-attributes' only when the
foreground changes."
  (or (cooked--foreign-host-p)
      (and cooked-password-remote-programs
           (member (cooked--foreground-program) cooked-password-remote-programs)
           t)))

(defun cooked--secret-prompt-on-row-p ()
  "Whether the cursor's row looks like a password prompt from a remote child.

The second arm of the detector, and the only one that can reach a remote
child; see `cooked--remote-child-p' for what counts as one.  Asked of the
*cursor's* row rather than of the whole screen: a prompt is where the cursor is
waiting, and a screenful of a build log mentioning passwords is not one."
  (and (cooked--remote-child-p)
       (when-let* ((position (cooked--cursor-position))
                   (case-fold-search t))
         (save-excursion
           (goto-char position)
           (string-match-p cooked-password-prompt-regexp
                           (buffer-substring-no-properties
                            (line-beginning-position) (line-end-position)))))))

(defun cooked--schedule-secret (origin)
  "Prompt for a secret once the prompt text has had time to arrive.

ORIGIN is the detector asking, `termios' or `regex', and is kept in
`cooked--secret-asking' until the read returns or the child stops asking.

Not while the user is looking at something else.  `read-passwd' takes the
minibuffer of whatever frame is selected, which for a buffer nobody is in means
a masked prompt appearing under the cursor in an unrelated buffer -- and then
the next thing typed there, whatever it was meant for, is sent to this child
followed by a newline.  A password prompt that arrives late is a small thing; a
password prompt that quietly redirects the keys you are already typing is not.

So the read is held instead, and `cooked--resume-secret' raises it when
attention comes back.  Nothing else is deferred with it: `cooked--mode' is
already `secret', the keymap has already been swapped, and the child is
blocked in a `getpass' that will wait as long as it takes.

Said out loud rather than held silently, because the buffer is off screen and
the alternative is a session that has stopped for no visible reason.  A message
is the smallest thing that cannot steal a keystroke; a notification is the
better one, and is `cooked-command-finished-functions' territory rather than
this function's.  It is posted once per prompt, because each detector
schedules on a rising edge rather than on every drain the prompt is still there
for."
  (cooked--cancel-secret)
  (setq cooked--secret-asking origin)
  (if (eq cooked--attention 'away)
      (message "cooked: %s is asking for a password" (buffer-name))
    (setq cooked--secret-timer
          (run-with-timer cooked-secret-debounce nil
                          (let ((buffer (current-buffer)))
                            (lambda () (cooked--prompt-secret buffer)))))))

(defun cooked--resume-secret ()
  "Raise a secret prompt that was held back while the user was elsewhere.

Called as attention returns, and only then.  Three things have to be true and
each rules out a different way of prompting for nothing: a detector must still
be asking, or the prompt would be answered by whatever the child is running now,
or a second time after it was already answered; no
timer may be pending, or `cooked--schedule-secret' has already been through
here and rescheduling would bump the epoch out from under it; and no read may
be on screen, which is the case of leaving the buffer *while* the minibuffer
was up and coming back to it, where cancelling and re-asking would dismiss a
prompt the user is part-way through answering."
  (when (and cooked--session
             cooked--secret-asking
             (not cooked--secret-timer)
             (not cooked--secret-read))
    (cooked--schedule-secret cooked--secret-asking)))

(defun cooked--cancel-secret ()
  "Abandon any pending or on-screen secret prompt.

Called whenever the child stops asking: it left secret mode, the remote prompt
left the cursor row, it exited, or the buffer was killed.  The pending timer is
the easy half.  The hard half is a read already on screen -- `sudo'
interrupted from the terminal window leaves the minibuffer sitting there, and
answering it later would hand a password, or a `C-c', to whatever the child is
running by then.  That is not a stale window; it is the wrong program being
killed.

So two things happen.  The epoch moves, which is what makes the read harmless
whatever it does next: `cooked--prompt-secret' compares before it sends
anything.  Then the minibuffer is dismissed from a zero-delay timer, because it
is a recursive edit this is not inside -- the timer runs in that recursive
edit's command loop, where `abort-recursive-edit' has a tag to throw to.  It
is allowed to fail: if the user has since opened a minibuffer of their own on
top of ours, both are left alone and the epoch carries the safety."
  (setq cooked--secret-epoch (1+ cooked--secret-epoch)
        cooked--secret-asking nil)
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
  "Keys layered over the map `read-passwd' installs.

`C-c C-c' only: the read is a minibuffer, so `C-g' already aborts it, but
the prompt on screen is sudo's rather than Emacs', and the key that gets you
out of a program asking for a password on a terminal is the interrupt.  It is
spelled the same here as in the buffer, where `C-c C-c' is
`cooked-interrupt', so the answer does not depend on which window point
happens to be in.")

(defun cooked-secret-abort ()
  "Abandon the password read, leaving the child to be interrupted.

Signals quit rather than sending anything itself; `cooked--prompt-secret' is
already handling quit by sending the child `C-c', and that is the one place
that knows which buffer's child is waiting."
  (interactive)
  (abort-minibuffers))

(defun cooked--read-passwd (prompt)
  "Read a secret for PROMPT with `cooked-secret-map' in force.

The minibuffer is recorded on the session's buffer for as long as the read
lasts, which is what lets `cooked--cancel-secret' take it back down when the
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

Only cooked's own copies, though.  A string handed over by an entry on
`cooked-password-functions', or by `cooked-password-function', belongs to
whoever supplied it -- an auth-source backend may return the plaintext its
cache is holding -- so zeroing that one would corrupt the cache rather than the
secret.  The copy written to the child is made here for exactly that reason.

That is the honest limit of it.  `read-passwd' builds the string in
Emacs' own heap, the garbage collector relocates and compacts small
strings so earlier copies survive in freed blocks that `clear-string'
never sees, and an auth-source backend caches plaintext by design.
cooked cannot promise a password leaves no trace in Emacs' address
space, and does not.

Nothing is read unless the detector that scheduled it is still asking: the
termios arm while the tty is still in secret mode, the regex arm while the
cursor row still looks like a remote prompt.  A read that returns, answered or
quit, ends the prompt and leaves the cursor cell in
`cooked--secret-answered', so the next drain does not take the prompt still on
screen for a new one."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq cooked--secret-timer nil)
      (when (pcase cooked--secret-asking
              ('termios (eq cooked--mode 'secret))
              ;; The termios sample trails output by up to `RESAMPLE_DELAY',
              ;; longer than the debounce, so `ssh' asking for its own
              ;; password in the foreground shows a matching row first.
              ;; Asking the tty now hands a local secret read to the termios
              ;; arm, which schedules its own prompt, instead of reading it
              ;; here and then again when the sample lands.
              ('regex (cooked--resample-mode)
                      (and (eq cooked--secret-asking 'regex)
                           (cooked--secret-prompt-on-row-p))))
        (let* ((prompt (or (cooked--prompt-text cooked--session) "Password"))
               (prompt (if (string-suffix-p ":" prompt) (concat prompt " ") (concat prompt ": ")))
               ;; Read before the prompt is answered and compared after, in both
               ;; the answered and the quit branch below.
               (epoch cooked--secret-epoch))
          (unwind-protect
              (condition-case nil
                  ;; `supplied' is kept separate from `secret' because only one
                  ;; of the two is ours to destroy; see the comments on the two
                  ;; `clear-string' calls below.
                  (let* ((supplied (cooked--password-from-sources prompt))
                         (secret (or supplied (cooked--read-passwd prompt))))
                    (unwind-protect
                        ;; The wire copy is freshly allocated here and nothing
                        ;; else can be holding it, so zeroing it is
                        ;; unconditionally safe.  Its `unwind-protect' is nested
                        ;; inside the outer one so that a PTY write which throws
                        ;; -- a child that exited between the prompt and the
                        ;; answer is enough -- still clears it on the way out.
                        (let ((wire (copy-sequence secret)))
                          (unwind-protect
                              (if (/= epoch cooked--secret-epoch)
                                  (message "Nothing is asking for that any more; not sent")
                                (cooked--send-to-child wire)
                                (cooked--send-to-child "\n"))
                            (clear-string wire)))
                      ;; What `read-passwd' returns was allocated for this call
                      ;; and nobody else has a reference, so it is ours to zero.
                      ;; What a password source returns is not: an
                      ;; auth-source backend caches plaintext by design and may
                      ;; hand out the very string sitting in that cache, so
                      ;; zeroing it corrupts the cache in place and the next
                      ;; lookup answers with NULs.
                      (unless supplied (clear-string secret))))
                ;; C-g or C-c C-c at the prompt should interrupt the child's
                ;; read rather than leave it blocked on a `getpass' nobody is
                ;; going to answer -- but only while it is still that read we
                ;; would be interrupting.  A prompt the child abandoned on its
                ;; own leaves a minibuffer that outlives it, and sending the
                ;; interrupt anyway is how quitting a dead password prompt kills
                ;; the command typed after it.
                (quit
                 (when (= epoch cooked--secret-epoch)
                   (cooked--send-if-live "\C-c"))
                 (signal 'quit nil)))
            ;; Only for the prompt this read was for.  A stale epoch means the
            ;; child stopped asking while the read was up, and a detector may
            ;; since have scheduled a new prompt that this must not end.
            (when (= epoch cooked--secret-epoch)
              (setq cooked--secret-asking nil
                    cooked--secret-answered (cooked--cursor-cell)))))))))

(defun cooked--check-secret-prompt (scrolled)
  "Follow the edges of a prompt only the regex arm can see.

The termios detector fires from `cooked--set-mode', on a *change* of what the
local tty is doing.  A remote child changes the far tty and the local one never
moves, so that path is never reached and there is no state transition to hang
this off -- the question has to be asked per drain instead, and the edges found
here.  ghostel's `ghostel--detect-password-prompt' is the same machine.

- The rising edge is the first drain whose cursor row matches while nothing is
  asking.  It schedules the read, once, however many drains the prompt then
  sits through.
- The falling edge is the first drain whose row does not match.  It forgets the
  answered cell, and if the regex arm was still asking -- a read pending, held,
  or on screen -- it cancels that read, which is `sudo' timing out at the far
  end while the minibuffer was up.
- A row that matches on the cell in `cooked--secret-answered' is the prompt
  just answered, still on screen until the far end reads the password.

SCROLLED is non-nil when this drain moved rows into the scrollback, which puts
a different line under every cell and so forgets the answered one.

None of this runs while the tty is in secret mode: that is the termios arm's
prompt, and the answered cell it leaves behind has to survive until the tty
leaves secret mode for it to mean anything.

Cheap where it does not apply: `cooked--secret-prompt-on-row-p' asks whether
the child is remote before it builds the row, so a local shell pays no regexp."
  (when (and cooked--session (not (eq cooked--mode 'secret)))
    (when scrolled (setq cooked--secret-answered nil))
    (cond ((not (cooked--secret-prompt-on-row-p))
           (setq cooked--secret-answered nil)
           (when (eq cooked--secret-asking 'regex)
             (cooked--cancel-secret)))
          (cooked--secret-asking nil)
          ((equal (cooked--cursor-cell) cooked--secret-answered) nil)
          (t (setq cooked--secret-answered nil)
             (cooked--schedule-secret 'regex)))))

(provide 'cooked-secret)
;;; cooked-secret.el ends here
