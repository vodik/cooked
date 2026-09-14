;;; cooked-remote.el --- Starting a session on the host a TRAMP directory names -*- lexical-binding: t; -*-

;;; Commentary:

;; M-x cooked from a buffer at /ssh:box:/srv/ starts the shell on box, in /srv.
;; The pty is still cooked's own, on this machine, and what runs in it is
;; `ssh -t'.  That is the child a user typing `ssh box' at a local prompt gets,
;; so what docs/DESIGN.md says about that case holds here unchanged: termios
;; describes the local ssh rather than the far shell, the OSC 133 marks and the
;; line announcement cross as bytes, and a password prompt is read by the local
;; ssh with echo off, which the core reports as a secret without a regexp.
;;
;; vterm, eat and ghostel take the other route, TRAMP's own `make-process' with
;; Emacs holding the pty.  cooked declines it, because it would be a second
;; kind of session with no reader thread and no backpressure, kept alive for
;; every method TRAMP has.  The cost is coverage: only a method that logs in
;; with ssh is started here, and any other, such as /docker:web:/ or
;; /sudo::/etc/, is refused with a message naming it.
;;
;; Nothing about the connection is parsed again here.  The hops come from
;; `tramp-compute-multi-hops', and each hop's program and arguments from its
;; own entry in `tramp-methods', so a name TRAMP can open is a name a shell can
;; be started on, `tramp-default-proxies-alist' included.
;;
;; Two things have to reach the far shell that ssh does not carry.  The
;; terminfo entry travels inline, as `TERMINFO=b64:...', and only when the far
;; host lacks it; see `cooked--remote-script'.  Shell integration does not
;; travel at all: the far rc sources the snippet, as it must for a manual
;; `ssh', and the variables it reads are exported so that it can.

;;; Code:

(require 'cl-lib)
(require 'format-spec)
(require 'url-util)
(require 'cooked-util)
(require 'cooked-module)
(require 'cooked-osc)
(require 'cooked-session)
(require 'cooked-shell-integration)

(declare-function tramp-dissect-file-name "tramp" (name &optional nodefault))
(declare-function tramp-compute-multi-hops "tramp" (vec))
(declare-function tramp-get-method-parameter "tramp" (vec param &optional default))
(declare-function tramp-format-spec "tramp" (format specification))
(declare-function tramp-sh-file-name-handler-p "tramp-sh" (vec))
(declare-function tramp-file-name-method "tramp" (vec))
(declare-function tramp-file-name-user "tramp" (vec))
(declare-function tramp-file-name-host "tramp" (vec))
(declare-function tramp-file-name-port "tramp" (vec))
(declare-function tramp-file-name-localname "tramp" (vec))

(defun cooked--remote-hop-argv (hop command)
  "The argv that logs in to HOP with ssh and runs COMMAND there, or nil.

HOP is a dissected TRAMP file name and COMMAND a string for the login shell at
the far end.  The program and its arguments are HOP's own `tramp-login-program'
and `tramp-login-args', expanded as TRAMP expands them, so /ssh:me@box#2222:
gives ssh -t -l me -p 2222 -e none box COMMAND.  nil means HOP does not log in
with ssh, or is not a tramp-sh method at all, and the caller refuses it.

Three placeholders are given nothing, and TRAMP drops an argument whose
placeholder expands to nothing.  %c is TRAMP\\='s ControlMaster options, left
out because with ControlPersist=no a terminal that became the master would hold
its own exit until every TRAMP operation sharing its socket had finished.  %w
is TRAMP\\='s -o SetEnv=TERM=dumb, which is right for the shell TRAMP drives and
wrong for this one.  %l is the remote shell TRAMP logs in to, and an argument
that names it is left out whole rather than emptied, which is what makes sshx
work: its -o RemoteCommand=\"%l\" would contradict COMMAND after the host.

-t is added in front, because TRAMP drives its shell without a terminal and
this one needs a pty at the far end.

The host has to pass `cooked--host-name-regexp\\=' and the port has to be
digits, or this signals.  TRAMP does not allow either to begin with a hyphen,
but the host may have come from an OSC 7 report through
`cooked--remote-directory\\=', and a host decoded as a%7Cb is one no machine
has."
  (let ((program (tramp-get-method-parameter hop 'tramp-login-program))
        (host (tramp-file-name-host hop))
        (port (tramp-file-name-port hop)))
    (when (and (tramp-sh-file-name-handler-p hop)
               (stringp program)
               (equal (file-name-nondirectory program) "ssh"))
      (unless (and host (string-match-p cooked--host-name-regexp host))
        (user-error "cooked: refused the host `%s'" host))
      (unless (or (null port) (string-match-p "\\`[0-9]+\\'" port))
        (user-error "cooked: refused the port `%s'" port))
      (let ((spec (format-spec-make ?h host ?u (or (tramp-file-name-user hop) "")
                                    ?p (or port "") ?c "" ?w "" ?l "")))
        ;; Without properties, since TRAMP marks the parts of an ad-hoc hop
        ;; with `tramp-ad-hoc' and nothing past this point wants them.
        (mapcar
         #'substring-no-properties
         `(,program
           "-t"
           ,@(mapcan (lambda (group)
                       (unless (seq-some (lambda (arg) (string-search "%l" arg)) group)
                         (let ((expanded (mapcar (lambda (arg) (tramp-format-spec arg spec))
                                                 group)))
                           (unless (member "" expanded) expanded))))
                     (tramp-get-method-parameter hop 'tramp-login-args))
           ,command))))))

(defun cooked--remote-terminfo (term)
  "Our compiled entry for TERM as a `TERMINFO\\=' value, or nil.

The value is `b64:\\=' and the entry\\='s bytes in base64, which ncurses 6.1
and later read as the entry itself rather than as a directory to look in, as
ncurses(3X) says: \"If the value of TERMINFO begins with hex: or b64:\".  That
is what lets the entry reach a remote host without writing a file there.  nil
when TERM is not one of ours, as when `cooked-term-name\\=' is nil and TERM is
xterm-256color, which every host already describes."
  (when-let* ((database (cooked--terminfo-database))
              (entry (cooked--terminfo-entry database term)))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally entry)
      (concat "b64:" (base64-encode-string (buffer-string) t)))))

(defun cooked--remote-cd (localname)
  "The shell command that moves the far shell to LOCALNAME, or nil for home.

An absolute LOCALNAME is also reported back as OSC 7 once the `cd\\=' has
worked, with the host as the far machine names itself, so the buffer learns
where its shell is before a shell has sourced anything, and even when its rc
sources nothing.  A name under ~, which TRAMP allows as in
/ssh:box:~/src/, is left to the shell to expand and is not reported, since
only the far end knows what it expands to."
  (cond
   ((member localname '("" "~" "~/")) nil)
   ((string-prefix-p "~/" localname)
    (concat "cd ~/" (shell-quote-argument (substring localname 2) t)))
   (t
    (concat "cd " (shell-quote-argument localname t)
            " && printf " (shell-quote-argument "\\033]7;file://%s%s\\033\\\\" t)
            " \"$(uname -n)\" "
            (shell-quote-argument (url-hexify-string localname url-path-allowed-chars)
                                  t)))))

(defun cooked--remote-script (localname command)
  "The POSIX sh script that turns a login on the far host into the session.

It moves to LOCALNAME, see `cooked--remote-cd\\=', makes TERM usable, exports
what ssh does not carry, and execs COMMAND, or the far user\\='s own login
shell when COMMAND is nil.  COMMAND is a program name or an argv list, so
\(\"htop\" \"-d\" \"5\") runs htop on the far host with those arguments.
`cooked-shell\\=' names a program on this machine, so it is not what runs
there.

TERM arrives on its own: ssh sends the local value with its pty request, so the
far end sees cooked-256color whether or not it has heard of it.  The script asks
`infocmp\\=' whether it has.  If not, `cooked--remote-terminfo\\=' is exported
as TERMINFO, and asked about again, so a host whose ncurses is older than 6.1
falls back to xterm-256color rather than keeping a TERM nothing there
describes.  A host with no `infocmp\\=' at all keeps the inline entry, because
there is no way to ask and a host modern enough to lack ncurses-bin is modern
enough to read it.  A host that has the entry installed keeps its own.

TERM_PROGRAM, TERM_PROGRAM_VERSION and COLORTERM are exported with the values
`cooked--child-environment\\=' gives a local child, because SendEnv is not
configured anywhere by default.  So is COOKED_SHELL_INTEGRATION_FEATURES, which
`cooked-shell-integration-features\\=' explains.  The snippet itself is not
sent.  Getting it sourced would take files written on the far host for its rc
to find, and cleaning them up afterwards over a connection that may be gone,
which is the apparatus the inline TERMINFO exists to avoid.  The line in the
far rc that a manual `ssh\\=' already needs is what loads it, and the mode line
says `bare\\=' until it does.

Joined with `;\\=' rather than newlines, because the far login shell parses the
quoted script before sh does, and a quoted newline is not read the same way by
fish or csh as by sh."
  (let* ((env (cooked--child-environment))
         (term (cdr (assoc "TERM" env)))
         (payload (cooked--remote-terminfo term))
         (features (cooked--integration-environment))
         (quote-arg (lambda (string) (shell-quote-argument string t))))
    (string-join
     (delq nil
           (list
            (cooked--remote-cd localname)
            (when payload
              (let ((term (funcall quote-arg term)))
                (format (concat "if ! infocmp %s >/dev/null 2>&1; then "
                                "TERMINFO=%s; export TERMINFO; "
                                "if command -v infocmp >/dev/null 2>&1 && ! infocmp %s >/dev/null 2>&1; then "
                                "unset TERMINFO; TERM=xterm-256color; export TERM; "
                                "fi; fi")
                        term (funcall quote-arg payload) term)))
            (concat "export "
                    (mapconcat (lambda (pair)
                                 (concat (car pair) "=" (funcall quote-arg (cdr pair))))
                               `(,@(mapcar (lambda (name) (assoc name env))
                                           '("COLORTERM" "TERM_PROGRAM" "TERM_PROGRAM_VERSION"))
                                 ,@(and features
                                        `(("COOKED_SHELL_INTEGRATION_FEATURES" . ,features))))
                               " "))
            (if command
                (concat "exec " (mapconcat quote-arg (ensure-list command) " "))
              "exec \"${SHELL:-/bin/sh}\" -l")))
     "; ")))

(defun cooked--remote-invocation (directory command)
  "Return (ARGV EXTRA-ENV SCRATCH) that starts a shell on DIRECTORY\\='s host.

DIRECTORY is a TRAMP name and COMMAND the program or argv to run there, or nil
for the far login shell.  The result has the shape of
`cooked--shell-invocation\\=' so that `cooked--start-session\\=' can take
either, with nothing in the other two.

nil, after a message, when any hop cannot be started this way: a method that
does not log in with ssh, a host `cooked--remote-hop-argv\\=' refuses, or a name
TRAMP itself rejects.  /ssh:box|sudo:box:/etc/ is refused for its sudo hop, and
the message names the method, so the user knows why the shell is local.

A hop is nested rather than turned into ssh -J.  /ssh:jump|ssh:box:/srv/ runs
ssh -t jump, and on jump ssh -t box, which is what TRAMP does itself: box is
reached with jump\\='s ssh configuration and keys, so a directory TRAMP can
open is one a shell can be started in.  Each inner command is quoted with
`shell-quote-argument\\=' for the login shell of the hop before it, which is
assumed to understand POSIX backslash quoting, as sh, bash, zsh and fish all
do."
  (condition-case err
      (progn
        (require 'tramp)
        (let* ((target (tramp-dissect-file-name directory))
               (quote-argv (lambda (argv)
                             (mapconcat (lambda (arg) (shell-quote-argument arg t))
                                        argv " ")))
               ;; `exec' at every level, so that no login shell is left waiting
               ;; on the far host or on any hop in between.
               (command (concat "exec "
                                (funcall quote-argv
                                         (list (or (tramp-get-method-parameter
                                                    target 'tramp-remote-shell)
                                                   "/bin/sh")
                                               "-c"
                                               (cooked--remote-script
                                                (tramp-file-name-localname target)
                                                command)))))
               argv)
          (dolist (hop (reverse (tramp-compute-multi-hops target)) (list argv nil nil))
            (setq argv (or (cooked--remote-hop-argv hop command)
                           (user-error "cooked: cannot start a shell over the TRAMP method `%s', only over ssh"
                                       (tramp-file-name-method hop)))
                  command (concat "exec " (funcall quote-argv argv))))))
    (error
     (message "%s; starting on this machine instead" (error-message-string err))
     nil)))

(provide 'cooked-remote)
;;; cooked-remote.el ends here
