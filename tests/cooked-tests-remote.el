;;; cooked-tests-remote.el --- Starting a session on a TRAMP host -*- lexical-binding: t; -*-

;;; Commentary:

;; No sshd is needed.  The argument vector is checked as data, and the far end
;; is played by a fake `ssh' on PATH that logs its arguments and runs the
;; command it was given under `sh -c' in an emptied environment, which is what
;; sshd does with it.  A hop runs the fake again from inside that environment,
;; so a two-hop name goes through two logins.  What that cannot show is a real
;; sshd's pty request, its authentication, and a real far ncurses.

;;; Code:

(require 'cooked-tests-helpers)

(defun cooked-tests--remote-argv (directory)
  "The argv `cooked--remote-invocation' builds for DIRECTORY, or nil.
`tramp-default-proxies-alist' is bound, since TRAMP records an ad-hoc hop in
it."
  (require 'tramp)
  (let ((tramp-default-proxies-alist nil)
        (tramp-verbose 0))
    (car (cooked--remote-invocation directory nil))))

(ert-deftest cooked-remote-argv-comes-from-the-tramp-method ()
  "The login program and its arguments are TRAMP's, with -t added in front.

The user and port come out of the name, `-e none' out of the method's own
`tramp-login-args', and the placeholders that expand to nothing drop their
argument.  sshx names the remote shell in `-o RemoteCommand=\"%l\"', which would
contradict the command after the host, and that argument is dropped whole."
  (let ((argv (cooked-tests--remote-argv "/ssh:me@box.example#2222:/srv/app/")))
    (should (equal (butlast argv)
                   '("ssh" "-t" "-l" "me" "-p" "2222" "-e" "none" "box.example")))
    (should (string-prefix-p "exec /bin/sh -c cd\\ /srv/app/\\ " (car (last argv)))))
  (let ((argv (cooked-tests--remote-argv "/sshx:box.example:/srv/")))
    (should (equal (butlast argv) '("ssh" "-t" "-e" "none" "-t" "-t" "box.example")))
    (should-not (seq-some (lambda (arg) (string-search "RemoteCommand" arg)) argv))))

(ert-deftest cooked-remote-hops-nest-each-login-inside-the-last ()
  "/ssh:jump|ssh:box: logs in to jump and runs ssh to box from there.

That is how TRAMP reaches box itself, with jump's configuration and keys, so a
name TRAMP can open is one a shell can start in.  The inner login is quoted for
jump's login shell, and `exec' so that nothing waits on jump."
  (let ((argv (cooked-tests--remote-argv
               "/ssh:jump.example|ssh:me@box.example#2222:/srv/")))
    (should (equal (butlast argv) '("ssh" "-t" "-e" "none" "jump.example")))
    (should (string-prefix-p
             "exec ssh -t -l me -p 2222 -e none box.example exec\\ /bin/sh\\ -c\\ "
             (car (last argv))))
    ;; No TRAMP text properties ride along from the ad-hoc hop.
    (should-not (seq-some (lambda (arg) (text-properties-at 0 arg)) argv))))

(ert-deftest cooked-remote-refuses-what-it-cannot-start-over-ssh ()
  "A method that does not log in with ssh, in any hop, is refused by name.

So is a host holding TRAMP punctuation, which is how a%7Csudo arrives from a
hostile OSC 7 report.  The refusal is a message and nil, and the session then
starts on this machine."
  (dolist (case '(("/ssh:box.example|sudo:box.example:/etc/" . "sudo")
                  ("/ssh:a%7Cb:/" . "a%7Cb")))
    (let ((messages nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args)
                   (when format
                     (push (apply #'format-message format args) messages)))))
        (should-not (cooked-tests--remote-argv (car case))))
      (should (string-search (cdr case) (car messages)))))
  ;; TRAMP's mock method logs in with `sh -i', so it is refused too, and the
  ;; session it was asked for starts locally with no remote state.
  (cooked-tests--with-mock-tramp remote
    (let ((default-directory remote)
          (cooked-shell "/bin/sh")
          (messages nil)
          buffer)
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'message)
                       (lambda (format &rest args)
                         (when format
                           (push (apply #'format-message format args) messages)))))
              (setq buffer (cooked--start-session)))
            (should (seq-some (lambda (m) (string-match-p "method .mock" m)) messages))
            (with-current-buffer buffer
              (should cooked--session)
              (should-not cooked--host)))
        (when buffer
          (with-current-buffer buffer (cooked--cleanup))
          (kill-buffer buffer))))))

(ert-deftest cooked-remote-terminfo-is-the-compiled-entry-inline ()
  "TERMINFO=b64: carries the bytes of our compiled entry, and ncurses reads it.

The far host is played by a local infocmp with HOME emptied and TERMINFO
naming nothing else, which is a host that has never heard of cooked."
  :tags '(infocmp)
  (let* ((term (cooked--terminfo))
         (payload (cooked--remote-terminfo term)))
    (skip-unless (equal term cooked-term-name))
    (should (string-prefix-p "b64:" payload))
    (should (equal (base64-decode-string (substring payload 4))
                   (with-temp-buffer
                     (set-buffer-multibyte nil)
                     (insert-file-contents-literally
                      (cooked--terminfo-entry (cooked--terminfo-database) term))
                     (buffer-string))))
    (should-not (cooked--remote-terminfo "xterm-256color"))
    (skip-unless (executable-find "infocmp"))
    (let ((home (make-temp-file "cooked-home" t)))
      (unwind-protect
          (let ((process-environment
                 (append (list (concat "HOME=" home) (concat "TERMINFO=" payload))
                         process-environment)))
            (let ((default-directory "/"))
              (should (eq 0 (call-process "infocmp" nil nil nil term)))))
        (delete-directory home t)))))

(defmacro cooked-tests--with-fake-ssh (spec &rest body)
  "Run BODY with a fake ssh on PATH, binding the names in SPEC.

SPEC is (LOG DIRECTORY &key LOGIN INFOCMP).  LOG is bound to a function
returning the logged logins, one list of arguments per login with the command
left off.  DIRECTORY is bound to a fresh local directory whose name holds a
space and a quote.  LOGIN is the far login shell, /bin/sh unless given.  With
INFOCMP nil the far host has no infocmp that finds our entry unless TERMINFO
supplies it; with `fail' its infocmp finds nothing at all, which is a host
whose ncurses cannot read `b64:'.

The far shell prints what it was given, one field per line, and sleeps."
  (declare (indent 1))
  (pcase-let ((`(,log ,directory . ,keys) spec)
              (root (make-symbol "root")))
    `(let* ((,root (make-temp-file "cooked-fake-ssh" t))
            (,directory (file-name-as-directory
                         (expand-file-name "far dir's" ,root)))
            (,log (lambda ()
                    (with-temp-buffer
                      (insert-file-contents (expand-file-name "log" ,root))
                      (mapcar (lambda (line) (split-string line "|" t))
                              (split-string (buffer-string) "\n" t))))))
       (unwind-protect
           (cl-flet ((script (name text)
                       (let ((file (expand-file-name name ,root)))
                         (make-directory (file-name-directory file) t)
                         (with-temp-file file (insert "#!/bin/sh\n" text))
                         (set-file-modes file #o755))))
             (make-directory ,directory t)
             (write-region "" nil (expand-file-name "log" ,root))
             (script "bin/ssh"
                     (concat
                      "n=$#; i=0; line=\n"
                      "for a; do i=$((i+1)); if [ $i -lt $n ]; then line=\"$line$a|\"; fi; last=$a; done\n"
                      "printf '%s\\n' \"$line\" >> \"$FAKE_ROOT/log\"\n"
                      "exec env -i HOME=\"$FAKE_ROOT/home\" PATH=\"$FAKE_PATH\" SHELL=\"$FAKE_ROOT/far-shell\" "
                      "TERM=\"$TERM\" FAKE_ROOT=\"$FAKE_ROOT\" FAKE_PATH=\"$FAKE_PATH\" FAKE_LOGIN=\"$FAKE_LOGIN\" "
                      "\"$FAKE_LOGIN\" -c \"$last\"\n"))
             (script "far/uname" "echo far-host-1\n")
             (script "far/infocmp"
                     ,(if (eq (plist-get keys :infocmp) 'fail)
                          "exit 1\n"
                        `(concat "[ -n \"$TERMINFO\" ] || exit 1\nexec "
                                 (shell-quote-argument (executable-find "infocmp"))
                                 " \"$@\"\n")))
             (script "far-shell"
                     (concat "printf 'dir=%s\\n' \"$PWD\"\n"
                             "printf 'term=%s\\n' \"$TERM\"\n"
                             "printf 'terminfo=%.4s\\n' \"$TERMINFO\"\n"
                             "printf 'program=%s\\n' \"$TERM_PROGRAM\"\n"
                             "printf 'features=%s\\n' \"${COOKED_SHELL_INTEGRATION_FEATURES:+set}\"\n"
                             "printf 'login=%s\\n' \"$1\"\n"
                             "exec sleep 30\n"))
             (make-directory (expand-file-name "home" ,root))
             (let* ((far-path (concat (expand-file-name "far" ,root) ":"
                                      (expand-file-name "bin" ,root) ":/usr/bin:/bin"))
                    (process-environment
                     (append
                      (list (concat "PATH=" (expand-file-name "bin" ,root) ":" (getenv "PATH"))
                            (concat "FAKE_ROOT=" ,root)
                            (concat "FAKE_PATH=" far-path)
                            (concat "FAKE_LOGIN=" (or ,(plist-get keys :login) "/bin/sh")))
                      process-environment)))
               ,@body))
         (delete-directory ,root t)))))

(defun cooked-tests--start-remote (directory predicate)
  "Start a session at DIRECTORY and return it once PREDICATE holds in it.
The buffer is killed by `cooked-tests--kill-session'."
  (require 'tramp)
  (let* ((default-directory directory)
         (tramp-default-proxies-alist nil)
         (tramp-verbose 0)
         (buffer (cooked--start-session)))
    (with-current-buffer buffer
      (should (cooked-tests--settle (lambda () (funcall predicate)) 10)))
    buffer))

(defun cooked-tests--kill-session (buffer)
  "Stop BUFFER's child and kill BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer (cooked--cleanup))
    (kill-buffer buffer)))

(ert-deftest cooked-remote-start-lands-in-the-directory-on-the-far-host ()
  "\\[cooked] at /ssh:jump|ssh:me@box#2222:DIR/ runs the far login shell in DIR.

Two logins, in order, each with the method's arguments; the far shell in the
directory, with a quote and a space in its name surviving three layers of
quoting; TERM as cooked set it, readable through TERMINFO=b64: because the far
host has no entry of its own; and the variables ssh does not forward exported.
The OSC 7 the spawn sends reports the far host by its own name, far-host-1."
  :tags '(infocmp)
  (skip-unless (and (executable-find "infocmp") (equal (cooked--terminfo) cooked-term-name)))
  (cooked-tests--with-fake-ssh (log far)
    (let* ((name (concat "/ssh:jump.invalid|ssh:me@box.invalid#2222:" far))
           (buffer (cooked-tests--start-remote
                    name (lambda () (string-search "login=" (cooked-tests--text))))))
      (unwind-protect
          (with-current-buffer buffer
            (let ((text (cooked-tests--text)))
              (should (string-search (concat "dir=" (directory-file-name far)) text))
              (should (string-search (concat "term=" cooked-term-name) text))
              (should (string-search "terminfo=b64:" text))
              (should (string-search "program=cooked" text))
              (should (string-search "features=set" text))
              (should (string-search "login=-l" text)))
            (should (equal (funcall log)
                           '(("-t" "-e" "none" "jump.invalid")
                             ("-t" "-l" "me" "-p" "2222" "-e" "none" "box.invalid"))))
            (should (equal cooked--host "far-host-1")))
        (cooked-tests--kill-session buffer)))))

(ert-deftest cooked-remote-create-runs-an-argv-on-the-far-host ()
  "`cooked-create' with an argv and a TRAMP directory runs that argv over there.

The public entry point goes through `cooked--start-session', so a program named
by its argv, (\"sh\" \"-c\" SCRIPT) here, is started on the far host in the
directory rather than refused or run locally."
  (skip-unless (equal (cooked--terminfo) cooked-term-name))
  (cooked-tests--with-fake-ssh (log far)
    (require 'tramp)
    (let* ((tramp-default-proxies-alist nil)
           (tramp-verbose 0)
           (buffer (cooked-create
                    '("sh" "-c" "printf 'argv=%s on %s\\n' \"$0\" \"$(uname -n)\"; exec sleep 30")
                    (concat "/ssh:box.invalid:" far))))
      (unwind-protect
          (with-current-buffer buffer
            (should (cooked-tests--settle
                     (lambda () (string-search "argv=sh on far-host-1" (cooked-tests--text)))
                     10))
            (should (equal (funcall log) '(("-t" "-e" "none" "box.invalid")))))
        (cooked-tests--kill-session buffer)))))

(ert-deftest cooked-remote-falls-back-to-xterm-where-b64-is-not-read ()
  "A far infocmp that cannot read TERMINFO=b64: leaves TERM=xterm-256color.

That is a host whose ncurses is older than 6.1, where the inline entry would
leave TERM naming nothing, and TERMINFO is unset again so it does not linger."
  (skip-unless (equal (cooked--terminfo) cooked-term-name))
  (cooked-tests--with-fake-ssh (_log far :infocmp fail)
    (let ((buffer (cooked-tests--start-remote
                   (concat "/ssh:box.invalid:" far)
                   (lambda () (string-search "login=" (cooked-tests--text))))))
      (unwind-protect
          (with-current-buffer buffer
            (should (string-search "term=xterm-256color" (cooked-tests--text)))
            (should (string-search "terminfo=\n" (cooked-tests--text))))
        (cooked-tests--kill-session buffer)))))

(ert-deftest cooked-remote-command-survives-a-fish-login-shell ()
  "The far login shell parses the command before sh does, and fish is common.

fish reads backslash quoting as sh does, which is the assumption
`cooked--remote-invocation' makes, and it does not read a quoted newline as sh
does, which is why the script is joined with semicolons."
  :tags '(fish)
  (skip-unless (executable-find "fish"))
  (cooked-tests--with-fake-ssh (_log far :login (executable-find "fish"))
    (let ((buffer (cooked-tests--start-remote
                   (concat "/ssh:box.invalid:" far)
                   (lambda () (string-search "login=" (cooked-tests--text))))))
      (unwind-protect
          (with-current-buffer buffer
            (should (string-search (concat "dir=" (directory-file-name far))
                                   (cooked-tests--text))))
        (cooked-tests--kill-session buffer)))))

(provide 'cooked-tests-remote)
;;; cooked-tests-remote.el ends here
